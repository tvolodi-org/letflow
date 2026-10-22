defmodule Letflow.Routers.EntitiesQueryRestrictedWalkerTest do
  @moduledoc """
  GH #2697 PR 1 -- HTTP-level tests for the restricted-field request walker
  (`Letflow.Entities.FieldPolicy.check_request/4` +
  `Letflow.Entities.Query.RequestGuard`) on `POST /entities/query` (plain and
  join) and `POST /entities/records/:entity_type/export`. Companion of
  `entities_query_restricted_filter_test.exs` (the 11-test reproduction) and
  `test/letflow/entities/query_request_guard_test.exs` (unit level). Spec:
  `test/specs/GH2697-query-restricted.md`.

  No restricted VALUE is ever asserted on except where a test proves a grant
  makes it visible; refusals assert status/detail/absence of rows only.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Query.RequestGuard
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @detail "one or more requested fields are restricted for this caller"
  @hidden %{"items" => [], "next_cursor" => nil}
  @audit_action "entities.export.unredacted_restricted_clause"

  # -- request plumbing -----------------------------------------------------

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  # trace id pinned so whole-response byte comparisons are genuine (the header
  # is per-request correlation data, see entities_test.exs REQ-394 tests).
  defp request(method, path, ctx, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", "gh2697-pinned-trace")
    |> dispatch()
  end

  defp query(ctx, body), do: request(:post, "/api/v1/entities/query", ctx, body)

  defp aggregate(ctx, body), do: request(:post, "/api/v1/entities/query/aggregate", ctx, body)

  defp export(ctx, entity_type, body),
    do: request(:post, "/api/v1/entities/records/#{entity_type}/export", ctx, body)

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  defp whole(conn), do: {conn.status, conn.resp_body, Enum.sort(conn.resp_headers)}

  defp problem(conn),
    do: conn |> body_of() |> Map.take(["status", "type", "title", "detail"])

  defp texts(conn), do: Enum.map(body_of(conn)["items"], & &1["field_values"]["text"])

  # A refusal: 403, the shared detail, no row-bearing key, and none of the
  # `leaks` strings anywhere in the body.
  defp assert_refused(conn, leaks) do
    assert conn.status == 403
    doc = body_of(conn)
    assert doc["detail"] == @detail
    refute Map.has_key?(doc, "items")
    refute Map.has_key?(doc, "records")
    refute Map.has_key?(doc, "results")

    for leak <- leaks do
      refute conn.resp_body =~ leak
    end

    conn
  end

  # -- fixtures -------------------------------------------------------------

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "walker-#{Ecto.UUID.generate()}",
      display_name: "Walker Test User",
      email: "walker-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp tenant_ctx(slug_prefix, roles) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "Restricted Walker Test Tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      tenant_id: tenant.tenant_id,
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp create_active_definition!(ctx, definition) do
    {:ok, entity_definition} =
      Definitions.create_definition(
        %{definition: definition, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, activated} =
      Definitions.activate_definition(
        entity_definition.name,
        ctx.user_id,
        "walker go-live",
        ctx.schema_name
      )

    activated
  end

  defp seed_record!(ctx, entity_type, field_values) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: entity_type,
          field_values: field_values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  defp insert_restriction!(ctx, entity_type, field_name) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  defp insert_grant!(ctx, user_id, entity_type, field_name) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  defp insert_type_restriction!(ctx, entity_type) do
    Repo.insert_all(
      "entity_type_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  # Real exam shape restricted through Exam.on_install/2. `hidden_queried` sets
  # `queried` for likert_weight / likert_polarity / question.explanation (the
  # shipped pack has false; true is the "tenant flipped it" live-leak variant).
  defp exam_ctx!(slug_prefix, roles, hidden_queried) do
    ctx = tenant_ctx(slug_prefix, roles)

    create_active_definition!(ctx, %{
      name: "question",
      display_name: "Question",
      fields: [
        %{name: "stem", type: :string, queried: true},
        %{name: "explanation", type: :string, queried: hidden_queried}
      ]
    })

    create_active_definition!(ctx, %{
      name: "answer_option",
      display_name: "Answer Option",
      fields: [
        %{name: "question_id", type: :string, queried: true},
        %{name: "text", type: :string, queried: true},
        %{name: "is_correct", type: :boolean, queried: true},
        %{
          name: "likert_weight",
          type: :decimal,
          decimal_precision: 5,
          decimal_scale: 2,
          queried: hidden_queried
        },
        %{
          name: "likert_polarity",
          type: :enum,
          enum_values: ["positive", "negative"],
          queried: hidden_queried
        }
      ]
    })

    :ok = Exam.on_install(ctx.schema_name, %{})

    question = seed_record!(ctx, "question", %{"stem" => "2 + 2 = ?", "explanation" => "x"})

    for {text, correct?} <- [{"A", true}, {"B", false}, {"C", false}] do
      seed_record!(ctx, "answer_option", %{
        "question_id" => question.record_id,
        "text" => text,
        "is_correct" => correct?
      })
    end

    ctx
  end

  defp promote_and_create_table!(ctx, entity_type, attribute, pg_type, references_entity) do
    on_exit(fn ->
      Repo.delete_all(
        from(cp in Letflow.TenantProvisioning.ColumnPromotion,
          where: cp.tenant_id == ^ctx.tenant_id
        )
      )
    end)

    column_spec =
      if references_entity do
        %{pg_type: pg_type, nullable: true, references_entity: references_entity}
      else
        %{pg_type: pg_type, nullable: true}
      end

    {:ok, [row]} =
      TenantProvisioning.register_column_promotion(
        entity_type,
        attribute,
        column_spec,
        [ctx.tenant_id]
      )

    {:ok, %{status: "ddl_applied"}} = TenantProvisioning.run_column_promotion(row.id)
    :ok
  end

  # question (stem) <- answer_option (text, question_id fk "question_fk").
  # `restrictions` is a list of {entity_type, field}.
  defp fk_ctx!(slug_prefix, roles, restrictions) do
    ctx = tenant_ctx(slug_prefix, roles)

    create_active_definition!(ctx, %{
      name: "question",
      display_name: "Question",
      fields: [%{name: "stem", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "question", "stem", "text", nil)

    create_active_definition!(ctx, %{
      name: "answer_option",
      display_name: "Answer Option",
      fields: [
        %{name: "text", type: :string, queried: true},
        %{name: "question_id", type: :string}
      ],
      foreign_keys: [
        %{name: "question_fk", field: "question_id", references_entity: "question"}
      ]
    })

    promote_and_create_table!(ctx, "answer_option", "question_id", "uuid", "question")

    for {entity_type, field} <- restrictions, do: insert_restriction!(ctx, entity_type, field)

    q1 = seed_record!(ctx, "question", %{"stem" => "alpha"})
    q2 = seed_record!(ctx, "question", %{"stem" => "beta"})
    seed_record!(ctx, "answer_option", %{"text" => "x", "question_id" => q1.record_id})
    seed_record!(ctx, "answer_option", %{"text" => "y", "question_id" => q2.record_id})
    ctx
  end

  # question_m2m <- question_tags_m2m (question_id near hop, tag_id far hop) -> tag_m2m
  defp m2m_ctx!(slug_prefix, roles, restrictions) do
    ctx = tenant_ctx(slug_prefix, roles)

    create_active_definition!(ctx, %{
      name: "question_m2m",
      display_name: "Question M2M",
      fields: [%{name: "stem", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "question_m2m", "stem", "text", nil)

    create_active_definition!(ctx, %{
      name: "tag_m2m",
      display_name: "Tag M2M",
      fields: [%{name: "label", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "tag_m2m", "label", "text", nil)

    create_active_definition!(ctx, %{
      name: "question_tags_m2m",
      display_name: "Question Tags M2M",
      fields: [%{name: "question_id", type: :string}, %{name: "tag_id", type: :string}],
      foreign_keys: [
        %{name: "fk_question", field: "question_id", references_entity: "question_m2m"},
        %{name: "fk_tag", field: "tag_id", references_entity: "tag_m2m"}
      ]
    })

    promote_and_create_table!(ctx, "question_tags_m2m", "question_id", "uuid", "question_m2m")
    promote_and_create_table!(ctx, "question_tags_m2m", "tag_id", "uuid", "tag_m2m")

    for {entity_type, field} <- restrictions, do: insert_restriction!(ctx, entity_type, field)

    q = seed_record!(ctx, "question_m2m", %{"stem" => "linked"})
    t = seed_record!(ctx, "tag_m2m", %{"label" => "math"})

    seed_record!(ctx, "question_tags_m2m", %{
      "question_id" => q.record_id,
      "tag_id" => t.record_id
    })

    ctx
  end

  @filter_true [%{"field" => "is_correct", "op" => "eq", "value" => true}]
  @sort_is_correct [%{"field" => "is_correct", "dir" => "desc"}]
  @fk_join [%{"entity_type" => "answer_option", "fk" => "question_fk"}]
  @fk_join_reverse [%{"entity_type" => "question", "fk" => "question_fk"}]
  @m2m_join [
    %{"entity_type" => "tag_m2m", "through" => "question_tags_m2m", "fk" => "fk_tag"}
  ]

  # ==========================================================================
  # T-07 / T-08: filter and sort, restricted + permitted twin
  # ==========================================================================

  describe "filter and sort on /query (answer_option, TASK_WORKER)" do
    test "T-07 filter on restricted is_correct -> 403; filter on permitted text -> 200" do
      ctx = exam_ctx!("w-filter", ["TASK_WORKER"], false)

      query(ctx, %{"entity_type" => "answer_option", "filters" => @filter_true})
      |> assert_refused(["is_correct", "answer_option"])

      ok =
        query(ctx, %{
          "entity_type" => "answer_option",
          "filters" => [%{"field" => "text", "op" => "eq", "value" => "B"}]
        })

      assert ok.status == 200
      assert texts(ok) == ["B"]
    end

    test "T-08 sort on restricted is_correct -> 403; sort on permitted text -> 200" do
      ctx = exam_ctx!("w-sort", ["TASK_WORKER"], false)

      query(ctx, %{"entity_type" => "answer_option", "sort" => @sort_is_correct})
      |> assert_refused(["is_correct", "answer_option"])

      ok =
        query(ctx, %{
          "entity_type" => "answer_option",
          "sort" => [%{"field" => "text", "dir" => "asc"}]
        })

      assert ok.status == 200
    end

    test "T-22 row order: permitted sort orders rows; restricted sort yields no rows" do
      ctx = exam_ctx!("w-order", ["TASK_WORKER"], false)

      desc =
        query(ctx, %{
          "entity_type" => "answer_option",
          "sort" => [%{"field" => "text", "dir" => "desc"}]
        })

      asc =
        query(ctx, %{
          "entity_type" => "answer_option",
          "sort" => [%{"field" => "text", "dir" => "asc"}]
        })

      assert texts(desc) == ["C", "B", "A"]
      assert texts(asc) == ["A", "B", "C"]

      refused = query(ctx, %{"entity_type" => "answer_option", "sort" => @sort_is_correct})
      assert_refused(refused, ["is_correct"])
    end

    test "restricted field in a later position of a multi-clause filter/sort still refuses" do
      ctx = exam_ctx!("w-multi", ["TASK_WORKER"], false)

      query(ctx, %{
        "entity_type" => "answer_option",
        "filters" => [
          %{"field" => "text", "op" => "neq", "value" => "Z"},
          %{"field" => "is_correct", "op" => "eq", "value" => true}
        ]
      })
      |> assert_refused(["is_correct"])

      query(ctx, %{
        "entity_type" => "answer_option",
        "sort" => [
          %{"field" => "text", "dir" => "asc"},
          %{"field" => "is_correct", "dir" => "asc"}
        ]
      })
      |> assert_refused(["is_correct"])
    end
  end

  # ==========================================================================
  # T-19..T-21b: queried:false restricted fields (403 now, was 422)
  # ==========================================================================

  describe "restricted fields that are queried:false in the shipped pack" do
    @hidden_cases [
      {"answer_option", "likert_weight", %{"op" => "eq", "value" => 1}},
      {"answer_option", "likert_polarity", %{"op" => "eq", "value" => "positive"}},
      {"question", "explanation", %{"op" => "eq", "value" => "x"}}
    ]

    for {entity, field, clause} <- @hidden_cases do
      test "T-19..21 #{entity}.#{field}: filter and sort -> 403 (queried:false)" do
        ctx =
          exam_ctx!(
            "w-hid-#{String.slice(unquote(entity), 0, 3)}-#{String.slice(unquote(field), -6, 6)}",
            ["TASK_WORKER"],
            false
          )

        filter = [Map.put(unquote(Macro.escape(clause)), "field", unquote(field))]
        sort = [%{"field" => unquote(field), "dir" => "asc"}]

        query(ctx, %{"entity_type" => unquote(entity), "filters" => filter})
        |> assert_refused([unquote(field)])

        query(ctx, %{"entity_type" => unquote(entity), "sort" => sort})
        |> assert_refused([unquote(field)])
      end

      test "T-21b #{entity}.#{field} flipped to queried:true: 403 for restricted caller; a grant makes it 200" do
        ctx =
          exam_ctx!(
            "w-flip-#{String.slice(unquote(entity), 0, 3)}-#{String.slice(unquote(field), -6, 6)}",
            ["TASK_WORKER"],
            true
          )

        filter = [Map.put(unquote(Macro.escape(clause)), "field", unquote(field))]
        sort = [%{"field" => unquote(field), "dir" => "asc"}]

        query(ctx, %{"entity_type" => unquote(entity), "filters" => filter})
        |> assert_refused([unquote(field)])

        query(ctx, %{"entity_type" => unquote(entity), "sort" => sort})
        |> assert_refused([unquote(field)])

        # the definition really is queryable: with a grant the same sort is 200
        insert_grant!(ctx, ctx.user_id, unquote(entity), unquote(field))
        assert query(ctx, %{"entity_type" => unquote(entity), "sort" => sort}).status == 200
      end
    end

    test "an unknown field still answers 422 (documents the restricted-vs-unknown decision)" do
      ctx = exam_ctx!("w-unknown", ["TASK_WORKER"], false)

      conn =
        query(ctx, %{
          "entity_type" => "answer_option",
          "filters" => [%{"field" => "nope", "op" => "eq", "value" => 1}]
        })

      assert conn.status == 422

      conn =
        query(ctx, %{
          "entity_type" => "answer_option",
          "sort" => [%{"field" => "nope", "dir" => "asc"}]
        })

      assert conn.status == 422
    end
  end

  # ==========================================================================
  # Export (default mode)
  # ==========================================================================

  describe "export, default mode (TENANT_ADMIN)" do
    test "T-09/T-10 restricted filter and sort -> 403; permitted twins -> 200" do
      ctx = exam_ctx!("w-exp", ["TENANT_ADMIN"], false)

      export(ctx, "answer_option", %{"filters" => @filter_true})
      |> assert_refused(["is_correct", "answer_option"])

      export(ctx, "answer_option", %{"sort" => @sort_is_correct})
      |> assert_refused(["is_correct", "answer_option"])

      ok =
        export(ctx, "answer_option", %{
          "filters" => [%{"field" => "text", "op" => "eq", "value" => "B"}],
          "sort" => [%{"field" => "text", "dir" => "desc"}]
        })

      assert ok.status == 200
      assert length(body_of(ok)["records"]) == 1
    end

    test "T-35/T-23 a user_entity_grants row for the caller makes filter and sort 200 (export and query)" do
      ctx = exam_ctx!("w-granted", ["TENANT_ADMIN"], false)
      insert_grant!(ctx, ctx.user_id, "answer_option", "is_correct")

      conn = export(ctx, "answer_option", %{"filters" => @filter_true})
      assert conn.status == 200
      assert length(body_of(conn)["records"]) == 1
      assert export(ctx, "answer_option", %{"sort" => @sort_is_correct}).status == 200

      conn = query(ctx, %{"entity_type" => "answer_option", "filters" => @filter_true})
      assert conn.status == 200
      assert length(body_of(conn)["items"]) == 1

      assert query(ctx, %{"entity_type" => "answer_option", "sort" => @sort_is_correct}).status ==
               200
    end

    test "T-36 a grant that belongs to ANOTHER user does not help the caller (query and export)" do
      ctx = exam_ctx!("w-other", ["TENANT_ADMIN"], false)
      other = insert_user!(%{schema_name: ctx.schema_name})
      insert_grant!(ctx, other.id, "answer_option", "is_correct")

      query(ctx, %{"entity_type" => "answer_option", "filters" => @filter_true})
      |> assert_refused(["is_correct"])

      export(ctx, "answer_option", %{"filters" => @filter_true})
      |> assert_refused(["is_correct"])

      export(ctx, "answer_option", %{"sort" => @sort_is_correct})
      |> assert_refused(["is_correct"])
    end
  end

  # ==========================================================================
  # Cursor / pagination sort keys
  # ==========================================================================

  describe "T-25 cursor sort keys" do
    test "resuming a permitted cursor with a restricted sort -> 403; permitted resend -> 200" do
      ctx = exam_ctx!("w-cursor", ["TASK_WORKER"], false)
      sort_text = [%{"field" => "text", "dir" => "asc"}]

      page1 =
        query(ctx, %{"entity_type" => "answer_option", "sort" => sort_text, "page_size" => 1})

      assert page1.status == 200
      cursor = body_of(page1)["next_cursor"]
      assert is_binary(cursor)

      query(ctx, %{
        "entity_type" => "answer_option",
        "sort" => @sort_is_correct,
        "page_size" => 1,
        "cursor" => cursor
      })
      |> assert_refused(["is_correct"])

      page2 =
        query(ctx, %{
          "entity_type" => "answer_option",
          "sort" => sort_text,
          "page_size" => 1,
          "cursor" => cursor
        })

      assert page2.status == 200
      assert texts(page2) == ["B"]
    end

    test "a cursor whose sort key is restricted is refused even with a garbage cursor (guard runs before decode)" do
      ctx = exam_ctx!("w-cursor2", ["TASK_WORKER"], false)

      query(ctx, %{
        "entity_type" => "answer_option",
        "sort" => @sort_is_correct,
        "cursor" => "not-a-cursor"
      })
      |> assert_refused(["is_correct"])
    end
  end

  # ==========================================================================
  # Join `on` fields (T-11, T-12, T-13)
  # ==========================================================================

  describe "join on fields use the DECLARING entity's own restrictions" do
    test "T-11 declaring side = PRIMARY: restricted fk on the primary -> 403; no restriction -> 200" do
      ctx = fk_ctx!("w-on-primary", ["TASK_WORKER"], [{"answer_option", "question_id"}])

      query(ctx, %{"entity_type" => "answer_option", "join" => @fk_join_reverse})
      |> assert_refused(["question_id", "question_fk"])

      twin = fk_ctx!("w-on-primary-ok", ["TASK_WORKER"], [])
      ok = query(twin, %{"entity_type" => "answer_option", "join" => @fk_join_reverse})
      assert ok.status == 200
      assert length(body_of(ok)["items"]) == 2
    end

    test "T-12 declaring side = JOIN TARGET: restriction on the target's fk (not the primary's) -> 403" do
      ctx = fk_ctx!("w-on-target", ["TASK_WORKER"], [{"answer_option", "question_id"}])

      query(ctx, %{"entity_type" => "question", "join" => @fk_join})
      |> assert_refused(["question_id", "question_fk"])

      # control: a restriction on an UNRELATED field of the primary does not
      # refuse a join (the fk is not touched)
      twin = fk_ctx!("w-on-target-ok", ["TASK_WORKER"], [{"question", "stem"}])
      ok = query(twin, %{"entity_type" => "question", "join" => @fk_join})
      assert ok.status == 200
    end

    test "T-12b a grant on the declaring entity's fk makes the join 200; another user's grant does not" do
      ctx = fk_ctx!("w-on-grant", ["TASK_WORKER"], [{"answer_option", "question_id"}])
      other = insert_user!(%{schema_name: ctx.schema_name})
      insert_grant!(ctx, other.id, "answer_option", "question_id")

      query(ctx, %{"entity_type" => "question", "join" => @fk_join})
      |> assert_refused(["question_id"])

      insert_grant!(ctx, ctx.user_id, "answer_option", "question_id")
      assert query(ctx, %{"entity_type" => "question", "join" => @fk_join}).status == 200
    end

    test "T-13 declaring side = THROUGH entity: near-hop fk restricted -> 403" do
      ctx = m2m_ctx!("w-on-near", ["TASK_WORKER"], [{"question_tags_m2m", "question_id"}])

      query(ctx, %{"entity_type" => "question_m2m", "join" => @m2m_join})
      |> assert_refused(["question_id", "fk_question", "question_tags_m2m"])
    end

    test "T-13 declaring side = THROUGH entity: far-hop fk restricted -> 403" do
      ctx = m2m_ctx!("w-on-far", ["TASK_WORKER"], [{"question_tags_m2m", "tag_id"}])

      query(ctx, %{"entity_type" => "question_m2m", "join" => @m2m_join})
      |> assert_refused(["tag_id", "fk_tag", "question_tags_m2m"])
    end

    test "T-13 twin: no restriction on either hop -> 200" do
      ctx = m2m_ctx!("w-on-ok", ["TASK_WORKER"], [])
      ok = query(ctx, %{"entity_type" => "question_m2m", "join" => @m2m_join})
      assert ok.status == 200
      assert length(body_of(ok)["items"]) == 1
    end

    test "export with a join refuses a restricted fk on the declaring entity (default mode)" do
      ctx = fk_ctx!("w-on-export", ["TENANT_ADMIN"], [{"answer_option", "question_id"}])

      export(ctx, "answer_option", %{"join" => @fk_join_reverse})
      |> assert_refused(["question_id"])
    end
  end

  # ==========================================================================
  # T-31 far-side redaction (guards the redact/3 refactor)
  # ==========================================================================

  describe "T-31 joined response redaction per entity" do
    defp sentinel, do: Atom.to_string(FieldGrants.redacted_sentinel())

    test "far-side restricted field comes back as the sentinel; a grant shows the value" do
      ctx = fk_ctx!("w-far", ["TASK_WORKER"], [{"answer_option", "text"}])

      conn = query(ctx, %{"entity_type" => "question", "join" => @fk_join})
      assert conn.status == 200
      items = body_of(conn)["items"]
      assert length(items) == 2

      for item <- items do
        assert item["answer_option"]["field_values"]["text"] == sentinel()
        # primary side is not restricted -> visible
        assert item["primary"]["field_values"]["stem"] in ["alpha", "beta"]
      end

      insert_grant!(ctx, ctx.user_id, "answer_option", "text")
      conn = query(ctx, %{"entity_type" => "question", "join" => @fk_join})

      assert conn
             |> body_of()
             |> Map.fetch!("items")
             |> Enum.map(& &1["answer_option"]["field_values"]["text"])
             |> Enum.sort() ==
               ["x", "y"]
    end

    test "primary-side restricted field is the sentinel while the far side stays visible" do
      ctx = fk_ctx!("w-prim", ["TASK_WORKER"], [{"question", "stem"}])

      conn = query(ctx, %{"entity_type" => "question", "join" => @fk_join})
      assert conn.status == 200

      for item <- body_of(conn)["items"] do
        assert item["primary"]["field_values"]["stem"] == sentinel()
        assert item["answer_option"]["field_values"]["text"] in ["x", "y"]
      end
    end

    test "plain (non-join) response still redacts from the guard's sets" do
      ctx = exam_ctx!("w-plain-red", ["TASK_WORKER"], false)
      conn = query(ctx, %{"entity_type" => "answer_option"})
      assert conn.status == 200

      for item <- body_of(conn)["items"] do
        assert item["field_values"]["is_correct"] == sentinel()
        assert item["field_values"]["text"] in ["A", "B", "C"]
      end
    end

    test "joined sets are keyed per join target: a restriction on the primary's twin field does not hide the target's same-named field" do
      # restrict question.stem only; answer_option.text must stay visible
      ctx = fk_ctx!("w-keyed", ["TASK_WORKER"], [{"question", "stem"}])
      conn = query(ctx, %{"entity_type" => "question", "join" => @fk_join})

      assert Enum.all?(
               body_of(conn)["items"],
               &(&1["answer_option"]["field_values"]["text"] in ["x", "y"])
             )
    end
  end

  # ==========================================================================
  # Type hidden (T-24, T-34, B1)
  # ==========================================================================

  describe "type-hidden envelope is preserved" do
    test "T-24 type-denied caller with a restricted filter: byte-equal to an unrestricted filter" do
      ctx = exam_ctx!("w-denied", ["TASK_WORKER"], false)
      insert_type_restriction!(ctx, "answer_option")

      restricted = query(ctx, %{"entity_type" => "answer_option", "filters" => @filter_true})

      unrestricted =
        query(ctx, %{
          "entity_type" => "answer_option",
          "filters" => [%{"field" => "text", "op" => "eq", "value" => "B"}]
        })

      assert restricted.status == 200
      assert body_of(restricted) == @hidden
      assert whole(restricted) == whole(unrestricted)

      sorted = query(ctx, %{"entity_type" => "answer_option", "sort" => @sort_is_correct})
      assert whole(sorted) == whole(unrestricted)
    end

    test "T-34a nonexistent primary type: restricted-looking filter, sort and direct join all give the plain hidden 200" do
      ctx = fk_ctx!("w-ghost", ["TASK_WORKER"], [])

      baseline = query(ctx, %{"entity_type" => "ghost_type"})
      assert baseline.status == 200
      assert body_of(baseline) == @hidden

      for extra <- [
            %{"filters" => @filter_true},
            %{"sort" => @sort_is_correct},
            %{"join" => @fk_join},
            %{"join" => @fk_join, "filters" => @filter_true}
          ] do
        conn = query(ctx, Map.put(extra, "entity_type", "ghost_type"))
        assert whole(conn) == whole(baseline)
      end
    end

    test "T-34b type-denied caller with a direct join gets the hidden 200" do
      ctx = fk_ctx!("w-denied-join", ["TASK_WORKER"], [{"answer_option", "question_id"}])
      insert_type_restriction!(ctx, "question")

      conn = query(ctx, %{"entity_type" => "question", "join" => @fk_join})
      assert conn.status == 200
      assert body_of(conn) == @hidden
    end

    test "B1 nonexistent primary + THROUGH join (through entity exists) == type-denied existing primary == plain nonexistent" do
      ctx = m2m_ctx!("w-b1", ["TASK_WORKER"], [])
      insert_type_restriction!(ctx, "question_m2m")

      ghost_through = query(ctx, %{"entity_type" => "ghost_q", "join" => @m2m_join})
      ghost_plain = query(ctx, %{"entity_type" => "ghost_q"})
      denied_through = query(ctx, %{"entity_type" => "question_m2m", "join" => @m2m_join})

      assert ghost_through.status == 200
      assert body_of(ghost_through) == @hidden
      assert whole(ghost_through) == whole(ghost_plain)
      assert whole(ghost_through) == whole(denied_through)
    end

    test "B1 export: nonexistent primary + through join answers exactly like the nonexistent primary without a join (404, as on main)" do
      ctx = m2m_ctx!("w-b1-exp", ["TENANT_ADMIN"], [])

      plain = export(ctx, "ghost_q", %{})
      with_join = export(ctx, "ghost_q", %{"join" => @m2m_join})
      with_filter = export(ctx, "ghost_q", %{"join" => @m2m_join, "filters" => @filter_true})

      assert plain.status == 404
      assert whole(with_join) == whole(plain)
      assert whole(with_filter) == whole(plain)
    end
  end

  describe "B1 export, DIRECT join" do
    test "nonexistent primary + a real direct join answers exactly like the nonexistent primary without a join (404)" do
      ctx = fk_ctx!("w-b1-exp-direct", ["TENANT_ADMIN"], [])

      plain = export(ctx, "ghost_q", %{})
      assert plain.status == 404

      assert whole(export(ctx, "ghost_q", %{"join" => @fk_join})) == whole(plain)

      assert whole(export(ctx, "ghost_q", %{"join" => @fk_join, "filters" => @filter_true})) ==
               whole(plain)
    end
  end

  # ==========================================================================
  # Uniform refusal (T-15), inert extra keys (T-14), unknown fields (T-16)
  # ==========================================================================

  describe "uniform refusal" do
    test "T-15 filter, sort, join on, export and aggregate refusals share status/type/title/detail" do
      exam = exam_ctx!("w-uni-exam", ["TENANT_ADMIN"], false)
      fk = fk_ctx!("w-uni-fk", ["TASK_WORKER"], [{"answer_option", "question_id"}])

      refusals = [
        query(exam, %{"entity_type" => "answer_option", "filters" => @filter_true}),
        query(exam, %{"entity_type" => "answer_option", "sort" => @sort_is_correct}),
        query(fk, %{"entity_type" => "question", "join" => @fk_join}),
        export(exam, "answer_option", %{"filters" => @filter_true}),
        export(exam, "answer_option", %{"sort" => @sort_is_correct}),
        aggregate(exam, %{
          "entity_type" => "answer_option",
          "aggregates" => [%{"fn" => "count"}],
          "filters" => @filter_true
        })
      ]

      docs = Enum.map(refusals, &problem/1)
      assert Enum.all?(refusals, &(&1.status == 403))
      assert [first | rest] = docs
      assert first["detail"] == @detail
      assert Enum.all?(rest, &(&1 == first))
    end
  end

  describe "T-14 unlisted body keys are inert" do
    test "query/export/aggregate answer the same with and without having/distinct/search" do
      ctx = exam_ctx!("w-inert", ["TENANT_ADMIN"], false)
      extras = %{"having" => [%{"field" => "is_correct"}], "distinct" => true, "search" => "A"}

      q = %{"entity_type" => "answer_option"}
      assert query(ctx, Map.merge(q, extras)).status == query(ctx, q).status

      assert body_of(query(ctx, Map.merge(q, extras))) == body_of(query(ctx, q))

      assert export(ctx, "answer_option", extras).status ==
               export(ctx, "answer_option", %{}).status

      a = %{"entity_type" => "answer_option", "aggregates" => [%{"fn" => "count"}]}
      assert aggregate(ctx, Map.merge(a, extras)).status == aggregate(ctx, a).status
    end

    test "T-18a unredacted:true in a /query body is inert: a restricted filter still 403, a permitted one still 200" do
      ctx = exam_ctx!("w-inert-unred", ["TENANT_ADMIN"], false)

      query(ctx, %{
        "entity_type" => "answer_option",
        "filters" => @filter_true,
        "unredacted" => true
      })
      |> assert_refused(["is_correct"])

      ok =
        query(ctx, %{
          "entity_type" => "answer_option",
          "filters" => [%{"field" => "text", "op" => "eq", "value" => "A"}],
          "unredacted" => true
        })

      assert ok.status == 200
    end

    test "T-16 unknown field on export and aggregate stays 422" do
      ctx = exam_ctx!("w-unk2", ["TENANT_ADMIN"], false)

      assert export(ctx, "answer_option", %{
               "filters" => [%{"field" => "nope", "op" => "eq", "value" => 1}]
             }).status == 422

      assert aggregate(ctx, %{
               "entity_type" => "answer_option",
               "aggregates" => [%{"fn" => "count"}],
               "filters" => [%{"field" => "nope", "op" => "eq", "value" => 1}]
             }).status == 422
    end
  end

  # ==========================================================================
  # Aggregate route on the shared walker (GH #2699, PR 2); the join-clause
  # tests live in entities_aggregate_restricted_join_test.exs
  # ==========================================================================

  describe "aggregate route uses the shared walker (PR 2)" do
    test "restricted group_by / measure / filter still 403, permitted twin 200" do
      ctx = exam_ctx!("w-agg", ["TASK_WORKER"], false)

      for extra <- [
            %{"group_by" => [%{"field" => "is_correct"}], "aggregates" => [%{"fn" => "count"}]},
            %{"aggregates" => [%{"fn" => "count"}], "filters" => @filter_true}
          ] do
        aggregate(ctx, Map.put(extra, "entity_type", "answer_option"))
        |> assert_refused(["is_correct"])
      end

      ok =
        aggregate(ctx, %{
          "entity_type" => "answer_option",
          "aggregates" => [%{"fn" => "count"}],
          "group_by" => [%{"field" => "text"}]
        })

      assert ok.status == 200
    end
  end

  # ==========================================================================
  # Unredacted-export exemption (T-17, T-18, T-32, T-33, T-37, T-38)
  # ==========================================================================

  defp audit_rows(ctx) do
    Repo.all(
      from(e in "audit_entries",
        where: e.action == ^@audit_action,
        select: %{
          actor_id: e.actor_id,
          resource_type: e.resource_type,
          resource_id: e.resource_id,
          after_state: e.after_state
        }
      ),
      prefix: ctx.schema_name
    )
  end

  defp audit_count(ctx),
    do: Repo.aggregate(from(e in "audit_entries", select: e.id), :count, prefix: ctx.schema_name)

  def record_query(_event, _measurements, %{query: sql}, %{pid: pid}) do
    if self() == pid and is_binary(sql), do: send(pid, {:recorded_query, sql})
    :ok
  end

  defp drain_queries(acc) do
    receive do
      {:recorded_query, sql} -> drain_queries([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "unredacted-export exemption" do
    test "T-17 unredacted:true + restricted filter and sort -> 200 and ONE audit entry with names only" do
      ctx = exam_ctx!("w-ex", ["TENANT_ADMIN"], false)
      seed_record!(ctx, "answer_option", %{"text" => "needle-xyz", "is_correct" => false})

      before = audit_count(ctx)

      log =
        capture_log([level: :info], fn ->
          conn =
            export(ctx, "answer_option", %{
              "unredacted" => true,
              "filters" => [
                %{"field" => "is_correct", "op" => "eq", "value" => false},
                %{"field" => "text", "op" => "eq", "value" => "needle-xyz"}
              ],
              "sort" => [%{"field" => "is_correct", "dir" => "asc"}]
            })

          assert conn.status == 200
          assert [record] = body_of(conn)["records"]
          assert record["field_values"]["text"] == "needle-xyz"
          # unredacted: the real value, not the sentinel
          assert record["field_values"]["is_correct"] == false
        end)

      assert [entry] = audit_rows(ctx)
      assert audit_count(ctx) == before + 1
      assert Ecto.UUID.cast!(entry.actor_id) == ctx.user_id
      assert entry.resource_type == "entity_type"
      assert entry.resource_id == "answer_option"
      assert entry.after_state["filter_fields"] == ["is_correct"]
      assert entry.after_state["sort_fields"] == ["is_correct"]
      assert entry.after_state["restricted_fields_used"] == ["is_correct"]

      assert Enum.sort(Map.keys(entry.after_state)) == [
               "filter_fields",
               "restricted_fields_used",
               "sort_fields"
             ]

      encoded = Jason.encode!(entry.after_state)
      refute encoded =~ "needle-xyz"
      refute log =~ "needle-xyz"
    end

    test "T-37 exempted export with a join: audit names include the join fk field, no values" do
      ctx = fk_ctx!("w-ex-join", ["TENANT_ADMIN"], [{"answer_option", "question_id"}])

      conn = export(ctx, "answer_option", %{"unredacted" => true, "join" => @fk_join_reverse})
      assert conn.status == 200

      assert [entry] = audit_rows(ctx)
      assert "question_id" in entry.after_state["restricted_fields_used"]
      assert "question_id" in entry.after_state["filter_fields"]
      assert entry.after_state["sort_fields"] == []
      refute Jason.encode!(entry.after_state) =~ "alpha"
    end

    test "audit insert happens BEFORE the records query (audit-before-pagination ordering)" do
      ctx = exam_ctx!("w-ex-order", ["TENANT_ADMIN"], false)
      id = "gh2697-order-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        id,
        [:letflow, :repo, :query],
        &__MODULE__.record_query/4,
        %{pid: parent}
      )

      try do
        conn = export(ctx, "answer_option", %{"unredacted" => true, "filters" => @filter_true})
        assert conn.status == 200
      after
        :telemetry.detach(id)
      end

      sqls = drain_queries([])

      audit_idx =
        Enum.find_index(sqls, &(&1 =~ "INSERT INTO" and &1 =~ ~s("audit_entries")))

      records_idx =
        Enum.find_index(
          sqls,
          &(String.starts_with?(&1, "SELECT") and &1 =~ "entity_record_latest")
        )

      assert is_integer(audit_idx), "no audit insert observed"
      assert is_integer(records_idx), "no records query observed"
      assert audit_idx < records_idx
    end

    test "T-33 a non-exempt export writes NO audit entry (default mode and unredacted with unrestricted fields)" do
      ctx = exam_ctx!("w-noaudit", ["TENANT_ADMIN"], false)
      before = audit_count(ctx)

      assert export(ctx, "answer_option", %{
               "filters" => [%{"field" => "text", "op" => "eq", "value" => "A"}]
             }).status == 200

      assert export(ctx, "answer_option", %{
               "unredacted" => true,
               "filters" => [%{"field" => "text", "op" => "eq", "value" => "A"}],
               "sort" => [%{"field" => "text", "dir" => "asc"}]
             }).status == 200

      assert audit_rows(ctx) == []
      assert audit_count(ctx) == before
    end

    test "a refused export writes no audit entry and a failed compile (422) writes none either" do
      ctx = exam_ctx!("w-noaudit2", ["TENANT_ADMIN"], false)

      export(ctx, "answer_option", %{"filters" => @filter_true}) |> assert_refused(["is_correct"])

      conn =
        export(ctx, "answer_option", %{
          "unredacted" => true,
          "filters" => [
            %{"field" => "is_correct", "op" => "eq", "value" => true},
            %{"field" => "nope", "op" => "eq", "value" => 1}
          ]
        })

      assert conn.status == 422
      assert audit_rows(ctx) == []
    end

    test "T-18b export WITHOUT the unredacted flag is not exempt" do
      ctx = exam_ctx!("w-ex-b", ["TENANT_ADMIN"], false)
      conn = export(ctx, "answer_option", %{"unredacted" => false, "filters" => @filter_true})
      assert_refused(conn, ["is_correct"])
      assert audit_rows(ctx) == []
    end

    test "T-18c a caller failing the route-level :EntitiesRecordsExport gate (TASK_WORKER) sending unredacted:true gets 403, no records, no audit (asserts the route gate, not the unredacted-permission check)" do
      ctx = exam_ctx!("w-ex-c", ["TASK_WORKER"], false)
      conn = export(ctx, "answer_option", %{"unredacted" => true, "filters" => @filter_true})
      assert conn.status == 403
      refute Map.has_key?(body_of(conn), "records")
      assert audit_rows(ctx) == []
    end

    test "T-32 audit failure -> detail-free 500 with no records (fail closed)" do
      ctx = exam_ctx!("w-ex-fail", ["TENANT_ADMIN"], false)

      Repo.query!(
        ~s(ALTER TABLE "#{ctx.schema_name}".audit_entries RENAME TO audit_entries_broken)
      )

      log =
        capture_log(fn ->
          conn =
            export(ctx, "answer_option", %{"unredacted" => true, "filters" => @filter_true})

          assert conn.status == 500
          doc = body_of(conn)
          refute Map.has_key?(doc, "records")
          refute conn.resp_body =~ "is_correct"
          refute conn.resp_body =~ "audit"
        end)

      refute log =~ "is_correct"
    end

    test "T-38 no 403 path logs the refused field name or a filter value" do
      ctx = exam_ctx!("w-logs", ["TENANT_ADMIN"], false)

      log =
        capture_log(fn ->
          query(ctx, %{
            "entity_type" => "answer_option",
            "filters" => [%{"field" => "is_correct", "op" => "eq", "value" => "sekret-value"}]
          })
          |> assert_refused([])

          query(ctx, %{"entity_type" => "answer_option", "sort" => @sort_is_correct})
          |> assert_refused([])

          export(ctx, "answer_option", %{
            "filters" => [%{"field" => "is_correct", "op" => "eq", "value" => "sekret-value"}]
          })
          |> assert_refused([])
        end)

      refute log =~ "is_correct"
      refute log =~ "sekret-value"
    end
  end

  # ==========================================================================
  # T-26 builders vs registry (observed by tracing the compile/aggregate calls)
  # ==========================================================================

  describe "T-26 registry equals the keys the router builders emit" do
    # A process never receives trace messages about itself, so a helper
    # process is the tracer and forwards the calls it sees.
    defp trace_loop(parent) do
      receive do
        {:trace, _pid, :call, {_m, _f, _args} = mfa} ->
          send(parent, {:traced_call, mfa})
          trace_loop(parent)

        :stop ->
          :ok

        _other ->
          trace_loop(parent)
      end
    end

    defp traced_request(module, fun, arity, run) do
      Code.ensure_loaded!(module)
      parent = self()
      tracer = spawn_link(fn -> trace_loop(parent) end)
      assert :erlang.trace_pattern({module, fun, arity}, true, [:global]) == 1
      :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, tracer}])

      try do
        run.()
      after
        :erlang.trace(self(), false, [:call, :set_on_spawn])
        :erlang.trace_pattern({module, fun, arity}, false, [:global])
        send(tracer, :stop)
      end

      receive do
        {:traced_call, {^module, ^fun, [request | _]}} -> request
      after
        1000 -> flunk("#{inspect(module)}.#{fun}/#{arity} was never called")
      end
    end

    test "query and export builders emit exactly the :row registry for a maximal body" do
      ctx = fk_ctx!("w-reg", ["TENANT_ADMIN"], [])

      body = %{
        "entity_type" => "question",
        "filters" => [%{"field" => "stem", "op" => "eq", "value" => "alpha"}],
        "sort" => [%{"field" => "stem", "dir" => "asc"}],
        "join" => @fk_join,
        "having" => 1,
        "distinct" => true,
        "search" => "x"
      }

      q = traced_request(Compiler, :compile, 3, fn -> assert query(ctx, body).status == 200 end)
      assert Enum.sort(Map.keys(q)) == Enum.sort(RequestGuard.registry_keys(:row))

      export_body = Map.delete(body, "entity_type")

      e =
        traced_request(Compiler, :compile, 3, fn ->
          assert export(ctx, "question", export_body).status == 200
        end)

      assert Enum.sort(Map.keys(e)) == Enum.sort(RequestGuard.registry_keys(:row))
    end

    test "the aggregate builder emits exactly the :aggregate registry for a maximal body" do
      ctx = fk_ctx!("w-reg-agg", ["TASK_WORKER"], [])

      body = %{
        "entity_type" => "question",
        "aggregates" => [%{"fn" => "count"}],
        "group_by" => [%{"field" => "stem"}],
        "filters" => [%{"field" => "stem", "op" => "eq", "value" => "alpha"}],
        "join" => @fk_join,
        "having" => 1,
        "distinct" => true,
        "search" => "x",
        "unredacted" => true
      }

      a =
        traced_request(Compiler, :run_aggregate, 3, fn ->
          assert aggregate(ctx, body).status == 200
        end)

      assert Enum.sort(Map.keys(a)) == Enum.sort(RequestGuard.registry_keys(:aggregate))

      # GH #2699 A-13: the unlisted keys are inert -- same status as the
      # body without them
      bare = Map.drop(body, ["having", "distinct", "search", "unredacted"])
      assert aggregate(ctx, bare).status == 200
    end
  end

  # ==========================================================================
  # T-30 restriction-load count
  # ==========================================================================

  describe "T-30 restriction loads" do
    def handle_query(_event, _measurements, %{query: sql}, %{pid: pid}) do
      if self() == pid and is_binary(sql) and sql =~ "entity_field_restrictions" do
        send(pid, :restriction_query)
      end

      :ok
    end

    defp count_restriction_queries(fun) do
      id = "gh2697-#{System.unique_integer([:positive])}"
      :telemetry.attach(id, [:letflow, :repo, :query], &__MODULE__.handle_query/4, %{pid: self()})

      try do
        fun.()
      after
        :telemetry.detach(id)
      end

      count_messages(0)
    end

    defp count_messages(n) do
      receive do
        :restriction_query -> count_messages(n + 1)
      after
        0 -> n
      end
    end

    test "plain query loads exactly one set; a one-target join loads exactly two (redact reuses the guard's)" do
      plain = exam_ctx!("w-cnt-plain", ["TASK_WORKER"], false)

      assert count_restriction_queries(fn ->
               assert query(plain, %{"entity_type" => "answer_option"}).status == 200
             end) == 1

      joined = fk_ctx!("w-cnt-join", ["TASK_WORKER"], [])

      assert count_restriction_queries(fn ->
               assert query(joined, %{"entity_type" => "question", "join" => @fk_join}).status ==
                        200
             end) == 2
    end
  end

  # ==========================================================================
  # T-39 router architecture
  # ==========================================================================

  describe "T-39 router architecture (GH #2700 T-18: one type+field gate)" do
    @router "lib/letflow/routers/entities.ex"

    # code lines of every clause of `defp name(` (comments stripped)
    defp function_code(source, name) do
      source
      |> String.split("\n")
      |> Enum.reduce({false, []}, fn line, {capturing?, acc} ->
        cond do
          String.starts_with?(line, "  defp #{name}(") -> {true, [line | acc]}
          String.match?(line, ~r/^  (defp|def|defmacro) /) -> {false, acc}
          capturing? -> {true, [line | acc]}
          true -> {false, acc}
        end
      end)
      |> elem(1)
      |> Enum.reverse()
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.join("\n")
    end

    defp router_code_lines(source),
      do: source |> String.split("\n") |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))

    # every function of the router as %{name => code} (all clauses joined,
    # comments stripped); a handler is anything with its own `defp`/`def` head.
    defp router_functions(source) do
      source
      |> String.split("\n")
      |> Enum.reduce({nil, []}, fn line, {current, acc} ->
        case Regex.run(~r/^  (?:defp|def) ([a-z_0-9?!]+)\(/, line) do
          [_, name] -> {name, [{name, line} | acc]}
          nil when current != nil -> {current, [{current, line} | acc]}
          nil -> {current, acc}
        end
      end)
      |> elem(1)
      |> Enum.reverse()
      |> Enum.reject(fn {_name, line} -> String.starts_with?(String.trim(line), "#") end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {name, lines} -> {name, Enum.join(lines, "\n")} end)
    end

    test "T-18 run_query, run_export, run_query_aggregate and redact obtain restriction sets only through RequestAccess" do
      source = File.read!(@router)

      for name <- ["run_query", "run_export", "run_query_aggregate", "redact", "export_redact"] do
        code = function_code(source, name)
        assert code != "", "#{name} not found in #{@router}"
        refute code =~ "load_restrictions", "#{name} calls FieldGrants.load_restrictions directly"
      end

      for name <- ["run_query", "run_export", "run_query_aggregate"] do
        assert function_code(source, name) =~ "RequestAccess.check(", name
      end
    end

    test "T-18 the router file has ZERO direct FieldPolicy.check_request / load_restrictions / guard_row_request calls; TypeAccess.authorized? only in render_get_definition" do
      source = File.read!(@router)
      code_lines = router_code_lines(source)

      assert Enum.count(code_lines, &(&1 =~ "FieldGrants.load_restrictions(")) == 0
      assert Enum.count(code_lines, &(&1 =~ "FieldPolicy.check_request(")) == 0
      refute Enum.any?(code_lines, &(&1 =~ "guard_row_request"))

      for deleted <- [
            "check_aggregate_field_restrictions",
            "aggregate_request_field_names",
            "aggregate_field_restricted"
          ] do
        refute Enum.any?(code_lines, &(&1 =~ deleted)), "#{deleted} is still in code"
      end

      holders =
        for {name, code} <- router_functions(source), code =~ "TypeAccess.authorized?(", do: name

      assert holders == ["render_get_definition"]
    end

    test "T-18 no handler can reach Compiler.compile / Compiler.run_aggregate without RequestAccess.check ahead of it" do
      source = File.read!(@router)

      compiling =
        for {name, code} <- router_functions(source),
            code =~ "Compiler.compile(" or code =~ "Compiler.run_aggregate(",
            do: {name, code}

      # the three query-shaped handlers are among them (the test is not vacuous)
      names = Enum.map(compiling, &elem(&1, 0))
      assert Enum.all?(["run_query", "run_export", "run_query_aggregate"], &(&1 in names))

      for {name, code} <- compiling do
        gate_at =
          case :binary.match(code, "RequestAccess.check(") do
            :nomatch -> flunk("#{name} compiles a request without RequestAccess.check(")
            {at, _} -> at
          end

        compile_at =
          [
            :binary.match(code, "Compiler.compile("),
            :binary.match(code, "Compiler.run_aggregate(")
          ]
          |> Enum.reject(&(&1 == :nomatch))
          |> Enum.map(&elem(&1, 0))
          |> Enum.min()

        assert gate_at < compile_at, "#{name}: Compiler runs before RequestAccess.check("
      end
    end

    test "GH #2699 A-12 / T-18: the aggregate route goes through the single gate; its result is bound {:ok, _..} and its only else clause renders an error" do
      source = File.read!(@router)
      agg = function_code(source, "run_query_aggregate")

      assert agg =~ "RequestAccess.check("
      assert agg =~ ":aggregate"
      assert agg =~ "exempt?: false"
      assert agg =~ ~r/\{:ok, _\w*\} <-\s+RequestAccess\.check/
      assert agg =~ "{:error, reason} -> render_aggregate_error(conn, reason)"
      refute agg =~ ~r/else\s+_\s*->/
      refute agg =~ ~r/\n\s+_(other|reason|error)?\s*->/

      {guard_at, _} = :binary.match(agg, "RequestAccess.check(")
      {compile_at, _} = :binary.match(agg, "Compiler.run_aggregate")
      assert guard_at < compile_at
    end

    test "only run_export passes a non-literal exempt? and only the unredacted flag" do
      source = File.read!(@router)
      assert function_code(source, "run_export") =~ "exempt?: unredacted?"
      assert function_code(source, "run_query") =~ "exempt?: false"
      assert function_code(source, "run_query_aggregate") =~ "exempt?: false"

      exempt_lines = Enum.filter(router_code_lines(source), &(&1 =~ "exempt?:"))
      assert exempt_lines != []

      assert exempt_lines
             |> Enum.map(&String.trim/1)
             |> Enum.all?(&(&1 =~ "exempt?: false" or &1 =~ "exempt?: unredacted?"))
    end
  end

  # ==========================================================================
  # GH #2698 -- counts and pagination metadata
  # ==========================================================================

  describe "GH #2698 pagination metadata carries no total" do
    test "a query page is items and next_cursor only: no total, no count, no aggregate of hidden rows" do
      ctx = exam_ctx!("w-meta", ["TASK_WORKER"], false)

      conn =
        query(ctx, %{
          "entity_type" => "answer_option",
          "sort" => [%{"field" => "text", "dir" => "asc"}],
          "page_size" => 1
        })

      assert conn.status == 200
      doc = body_of(conn)
      assert Enum.sort(Map.keys(doc)) == ["items", "next_cursor"]
      assert is_binary(doc["next_cursor"])
    end
  end

  # ==========================================================================
  # GH #2698 -- a next cursor is bound to the request that minted it
  #
  # The cursor carries the sort values of its last row. Replayed under another
  # sort (or on another entity type) those values become a threshold on a
  # field the replaying caller may read, which is an oracle on the restricted
  # value. The walker checks the replayed request's own sort, so the binding
  # must refuse the mismatch.
  # ==========================================================================

  describe "GH #2698 cursor binding" do
    setup do
      ctx = tenant_ctx("w-bind", ["TASK_WORKER"])

      create_active_definition!(ctx, %{
        name: "question",
        display_name: "Question",
        fields: [
          %{name: "stem", type: :string, queried: true},
          %{name: "explanation", type: :string, queried: true}
        ]
      })

      create_active_definition!(ctx, %{
        name: "note",
        display_name: "Note",
        fields: [%{name: "stem", type: :string, queried: true}]
      })

      insert_restriction!(ctx, "question", "explanation")
      insert_grant!(ctx, ctx.user_id, "question", "explanation")

      seed_record!(ctx, "question", %{"stem" => "a", "explanation" => "m-secret"})
      seed_record!(ctx, "question", %{"stem" => "z", "explanation" => "x"})
      seed_record!(ctx, "note", %{"stem" => "q"})

      %{ctx: ctx}
    end

    test "a cursor minted under a sort on a field the caller lost is refused under another sort",
         %{ctx: ctx} do
      by_explanation = [%{"field" => "explanation", "dir" => "asc"}]
      by_stem = [%{"field" => "stem", "dir" => "asc"}]

      page1 =
        query(ctx, %{"entity_type" => "question", "sort" => by_explanation, "page_size" => 1})

      assert page1.status == 200
      cursor = body_of(page1)["next_cursor"]
      assert is_binary(cursor)

      # The minting request still resumes under its own sort (positive control).
      same_sort =
        query(ctx, %{
          "entity_type" => "question",
          "sort" => by_explanation,
          "page_size" => 1,
          "cursor" => cursor
        })

      assert same_sort.status == 200

      # The grant goes away: explanation is restricted for this caller again.
      Repo.delete_all("user_entity_grants", prefix: ctx.schema_name)

      query(ctx, %{
        "entity_type" => "question",
        "sort" => by_explanation,
        "page_size" => 1,
        "cursor" => cursor
      })
      |> assert_refused(["m-secret"])

      # Under a permitted sort the restricted value must not become a threshold.
      replay =
        query(ctx, %{
          "entity_type" => "question",
          "sort" => by_stem,
          "page_size" => 10,
          "cursor" => cursor
        })

      assert replay.status == 400
      assert body_of(replay)["detail"] == "invalid cursor"
    end

    test "a cursor minted on one entity type is refused on another", %{ctx: ctx} do
      by_stem = [%{"field" => "stem", "dir" => "asc"}]

      page1 = query(ctx, %{"entity_type" => "question", "sort" => by_stem, "page_size" => 1})
      cursor = body_of(page1)["next_cursor"]
      assert is_binary(cursor)

      replay =
        query(ctx, %{
          "entity_type" => "note",
          "sort" => by_stem,
          "page_size" => 10,
          "cursor" => cursor
        })

      assert replay.status == 400
      assert body_of(replay)["detail"] == "invalid cursor"
    end
  end
end
