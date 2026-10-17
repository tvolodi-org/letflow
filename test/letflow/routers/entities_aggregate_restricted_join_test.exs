defmodule Letflow.Routers.EntitiesAggregateRestrictedJoinTest do
  @moduledoc """
  GH #2699 (PR 2 of #2697) -- HTTP-level tests that `POST /entities/query/aggregate`
  runs the shared restricted-field walker over its `join` clause. Closes the
  presence oracle: `count` over a join through a restricted fk used to answer
  how many primary rows have the fk set (inner join drops NULL fks) without
  ever returning the fk value. Spec: `test/specs/GH2699-aggregate-join-restricted.md`.
  Design: `lib/letflow/design/gh2699-aggregate-join-restricted.md`.

  Companion of `entities_query_restricted_walker_test.exs` (T-39 / A-12 source
  assertions, A-13, A-16 live there) and `entities_aggregate_test.exs`.
  No restricted VALUE is ever asserted on; refusals assert status/detail and
  absence of any count only.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @detail "one or more requested fields are restricted for this caller"
  @count [%{"fn" => "count"}]

  # -- request plumbing -----------------------------------------------------

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  # trace id pinned so whole-response byte comparisons are genuine
  defp request(method, path, ctx, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", "gh2699-pinned-trace")
    |> dispatch()
  end

  defp query(ctx, body), do: request(:post, "/api/v1/entities/query", ctx, body)
  defp aggregate(ctx, body), do: request(:post, "/api/v1/entities/query/aggregate", ctx, body)

  defp export(ctx, entity_type, body),
    do: request(:post, "/api/v1/entities/records/#{entity_type}/export", ctx, body)

  defp count_of(ctx, entity_type, extra) do
    conn = aggregate(ctx, agg_count(entity_type, extra))
    assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
    assert %{"results" => [%{"values" => %{"count_none" => n}}]} = body_of(conn)
    n
  end

  defp agg_count(entity_type, extra),
    do: Map.merge(%{"entity_type" => entity_type, "aggregates" => @count}, extra)

  defp body_of(conn), do: Jason.decode!(conn.resp_body)
  defp whole(conn), do: {conn.status, conn.resp_body, Enum.sort(conn.resp_headers)}

  defp problem(conn),
    do: conn |> body_of() |> Map.take(["status", "type", "title", "detail"])

  # 403, the shared detail, no result-bearing key, no number-bearing count
  # label, none of the `leaks` anywhere in the body.
  defp assert_refused(conn, leaks) do
    assert conn.status == 403, "expected 403, got #{conn.status}: #{conn.resp_body}"
    doc = body_of(conn)
    assert doc["detail"] == @detail
    refute Map.has_key?(doc, "results")
    refute Map.has_key?(doc, "items")
    refute conn.resp_body =~ "count_none"

    for leak <- leaks do
      refute conn.resp_body =~ leak
    end

    conn
  end

  # -- fixtures -------------------------------------------------------------

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "aggjoin-#{Ecto.UUID.generate()}",
      display_name: "Aggregate Join Test User",
      email: "aggjoin-#{Ecto.UUID.generate()}@example.com",
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
        display_name: "Aggregate Restricted Join Test Tenant"
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
        "aggjoin go-live",
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

  # Replace the tenant's whole restriction set with `restrictions`
  # ([{entity_type, field}]); reads are uncached so the next request sees it.
  defp set_restrictions!(ctx, restrictions) do
    Repo.delete_all("entity_field_restrictions", prefix: ctx.schema_name)
    for {entity_type, field} <- restrictions, do: insert_restriction!(ctx, entity_type, field)
    :ok
  end

  defp insert_grant!(ctx, entity_type, field_name) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(ctx.user_id),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
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

  # question (stem) <- answer_option (text, nullable question_id fk "question_fk").
  # Seeds q1, q2; answer_options x -> q1, y -> q2, z -> NO question (NULL fk).
  # N (unjoined answer_option count) = 3, K (fk present) = 2.
  defp define_fk_entities!(ctx) do
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

    q1 = seed_record!(ctx, "question", %{"stem" => "alpha"})
    q2 = seed_record!(ctx, "question", %{"stem" => "beta"})
    seed_record!(ctx, "answer_option", %{"text" => "x", "question_id" => q1.record_id})
    seed_record!(ctx, "answer_option", %{"text" => "y", "question_id" => q2.record_id})
    seed_record!(ctx, "answer_option", %{"text" => "z"})
    :ok
  end

  # question_m2m <- question_tags_m2m (question_id near hop, tag_id far hop) -> tag_m2m.
  # Two questions, only one linked: unjoined N = 2, through-joined K = 1.
  defp define_m2m_entities!(ctx) do
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

    q = seed_record!(ctx, "question_m2m", %{"stem" => "linked"})
    seed_record!(ctx, "question_m2m", %{"stem" => "unlinked"})
    t = seed_record!(ctx, "tag_m2m", %{"label" => "math"})

    seed_record!(ctx, "question_tags_m2m", %{
      "question_id" => q.record_id,
      "tag_id" => t.record_id
    })

    :ok
  end

  # fk + m2m entities in one tenant, restricted as given.
  defp combo_ctx!(slug_prefix, roles, restrictions) do
    ctx = tenant_ctx(slug_prefix, roles)
    define_fk_entities!(ctx)
    define_m2m_entities!(ctx)
    set_restrictions!(ctx, restrictions)
    ctx
  end

  # A-6 fixture: P(p_ref) <- J(p_ref fk "j_p_fk" -> P); T(p_id -> P "t_p_fk",
  # f_id -> F "t_f_fk"); F(f_id). The same field NAME appears on both sides of
  # several hops on purpose.
  defp owner_ctx!(slug_prefix) do
    ctx = tenant_ctx(slug_prefix, ["TASK_WORKER"])

    create_active_definition!(ctx, %{
      name: "p_ent",
      display_name: "P",
      fields: [%{name: "p_ref", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "p_ent", "p_ref", "text", nil)

    create_active_definition!(ctx, %{
      name: "f_ent",
      display_name: "F",
      fields: [%{name: "f_id", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "f_ent", "f_id", "text", nil)

    create_active_definition!(ctx, %{
      name: "j_ent",
      display_name: "J",
      fields: [%{name: "p_ref", type: :string}],
      foreign_keys: [%{name: "j_p_fk", field: "p_ref", references_entity: "p_ent"}]
    })

    promote_and_create_table!(ctx, "j_ent", "p_ref", "uuid", "p_ent")

    create_active_definition!(ctx, %{
      name: "t_ent",
      display_name: "T",
      fields: [%{name: "p_id", type: :string}, %{name: "f_id", type: :string}],
      foreign_keys: [
        %{name: "t_p_fk", field: "p_id", references_entity: "p_ent"},
        %{name: "t_f_fk", field: "f_id", references_entity: "f_ent"}
      ]
    })

    promote_and_create_table!(ctx, "t_ent", "p_id", "uuid", "p_ent")
    promote_and_create_table!(ctx, "t_ent", "f_id", "uuid", "f_ent")

    p1 = seed_record!(ctx, "p_ent", %{"p_ref" => "r1"})
    f1 = seed_record!(ctx, "f_ent", %{"f_id" => "x"})
    seed_record!(ctx, "j_ent", %{"p_ref" => p1.record_id})
    seed_record!(ctx, "t_ent", %{"p_id" => p1.record_id, "f_id" => f1.record_id})
    ctx
  end

  defp exam_ctx!(slug_prefix, roles) do
    ctx = tenant_ctx(slug_prefix, roles)

    create_active_definition!(ctx, %{
      name: "question",
      display_name: "Question",
      fields: [
        %{name: "stem", type: :string, queried: true},
        %{name: "explanation", type: :string, queried: false}
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
          queried: false
        },
        %{
          name: "likert_polarity",
          type: :enum,
          enum_values: ["positive", "negative"],
          queried: false
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

  @fk_join [%{"entity_type" => "answer_option", "fk" => "question_fk"}]
  @fk_join_reverse [%{"entity_type" => "question", "fk" => "question_fk"}]
  @m2m_join [%{"entity_type" => "tag_m2m", "through" => "question_tags_m2m", "fk" => "fk_tag"}]
  @j_join [%{"entity_type" => "j_ent", "fk" => "j_p_fk"}]
  @t_join [%{"entity_type" => "f_ent", "through" => "t_ent", "fk" => "t_f_fk"}]

  # ==========================================================================
  # A-1 / A-2 / A-3 / A-4 / A-9: the presence oracle is closed
  # ==========================================================================

  describe "count over a join through a restricted fk is refused (presence oracle)" do
    test "A-1/A-9 direct fk declared on the PRIMARY, nullable fk with some NULL rows: 403, no number; the permitted twin shows the oracle was real" do
      ctx = combo_ctx!("aj-direct", ["TASK_WORKER"], [{"answer_option", "question_id"}])

      # the oracle: with the join the count is K (2); without it N (3)
      assert count_of(ctx, "answer_option", %{}) == 3

      refused = aggregate(ctx, agg_count("answer_option", %{"join" => @fk_join_reverse}))
      assert_refused(refused, ["question_id", "question_fk", "answer_option"])

      # identical to a restricted FILTER field refusal on the same fixture
      by_filter =
        aggregate(
          ctx,
          agg_count("answer_option", %{
            "filters" => [%{"field" => "question_id", "op" => "eq", "value" => "x"}]
          })
        )

      assert by_filter.status == 403
      assert problem(refused) == problem(by_filter)
      assert refused.resp_body == by_filter.resp_body

      # permitted twin: the SAME request with the fk unrestricted answers 2
      set_restrictions!(ctx, [{"answer_option", "text"}])
      assert count_of(ctx, "answer_option", %{"join" => @fk_join_reverse}) == 2
      # and the unjoined count is unaffected by any of this
      assert count_of(ctx, "answer_option", %{}) == 3
    end

    test "A-2 fk declared on the JOINED entity (reverse direction): 403; a grant for the caller makes it 200" do
      ctx = combo_ctx!("aj-target", ["TASK_WORKER"], [{"answer_option", "question_id"}])

      assert_refused(
        aggregate(ctx, agg_count("question", %{"join" => @fk_join})),
        ["question_id", "question_fk", "answer_option"]
      )

      # a restriction on an UNRELATED primary field does not refuse the join
      set_restrictions!(ctx, [{"question", "stem"}])
      assert count_of(ctx, "question", %{"join" => @fk_join}) == 2

      set_restrictions!(ctx, [{"answer_option", "question_id"}])
      insert_grant!(ctx, "answer_option", "question_id")
      assert count_of(ctx, "question", %{"join" => @fk_join}) == 2
    end

    test "A-3 through join, NEAR hop restricted: 403; twin 200" do
      ctx = combo_ctx!("aj-near", ["TASK_WORKER"], [{"question_tags_m2m", "question_id"}])

      assert_refused(
        aggregate(ctx, agg_count("question_m2m", %{"join" => @m2m_join})),
        ["question_id", "fk_question", "question_tags_m2m"]
      )

      set_restrictions!(ctx, [])
      assert count_of(ctx, "question_m2m", %{"join" => @m2m_join}) == 1
    end

    test "A-3/A-9 through join, ONLY the FAR hop restricted: 403, no number (kills near-hop-only checking); twin shows the oracle; unjoined count unaffected" do
      ctx = combo_ctx!("aj-far", ["TASK_WORKER"], [{"question_tags_m2m", "tag_id"}])

      assert count_of(ctx, "question_m2m", %{}) == 2

      assert_refused(
        aggregate(ctx, agg_count("question_m2m", %{"join" => @m2m_join})),
        ["tag_id", "fk_tag", "question_tags_m2m"]
      )

      set_restrictions!(ctx, [])
      assert count_of(ctx, "question_m2m", %{"join" => @m2m_join}) == 1
      assert count_of(ctx, "question_m2m", %{}) == 2
    end

    test "A-4 permitted keys: a restriction on an unrelated field of every entity leaves direct and through joins at 200" do
      ctx =
        combo_ctx!("aj-permitted", ["TASK_WORKER"], [
          {"answer_option", "text"},
          {"question", "stem"},
          {"tag_m2m", "label"}
        ])

      assert count_of(ctx, "answer_option", %{"join" => @fk_join_reverse}) == 2
      assert count_of(ctx, "question", %{"join" => @fk_join}) == 2
      assert count_of(ctx, "question_m2m", %{"join" => @m2m_join}) == 1
    end
  end

  # ==========================================================================
  # A-5: PR 1 / ISS-0647 controls stay green
  # ==========================================================================

  describe "A-5 restricted measure, group_by and filter are still refused" do
    test "403 for sum/group_by/filter on a restricted field; count + unrestricted group_by 200" do
      ctx = combo_ctx!("aj-ctl", ["TASK_WORKER"], [{"answer_option", "question_id"}])

      for extra <- [
            %{"group_by" => [%{"field" => "question_id"}]},
            %{"filters" => [%{"field" => "question_id", "op" => "eq", "value" => "x"}]}
          ] do
        assert_refused(aggregate(ctx, agg_count("answer_option", extra)), ["question_id"])
      end

      assert_refused(
        aggregate(ctx, %{
          "entity_type" => "answer_option",
          "aggregates" => [%{"fn" => "min", "field" => "question_id"}]
        }),
        ["question_id"]
      )

      ok =
        aggregate(ctx, agg_count("answer_option", %{"group_by" => [%{"field" => "text"}]}))

      assert ok.status == 200
    end
  end

  # ==========================================================================
  # A-6: the DECLARING entity's restrictions govern each hop
  # ==========================================================================

  describe "A-6 each hop is governed by the entity that declares the fk" do
    test "(a)-(e) near/far/owner vs same-named field on the other side" do
      ctx = owner_ctx!("aj-owner")

      # (a) restriction on J.p_ref only, join J via j_p_fk -> 403
      set_restrictions!(ctx, [{"j_ent", "p_ref"}])
      assert_refused(aggregate(ctx, agg_count("p_ent", %{"join" => @j_join})), ["p_ref"])

      # (b) same NAME restricted on P (the non-owner) only: the hop is governed
      # by J, so the join is 200 -- while a FILTER on P.p_ref is 403
      set_restrictions!(ctx, [{"p_ent", "p_ref"}])
      assert count_of(ctx, "p_ent", %{"join" => @j_join}) == 1

      p_filter = [%{"field" => "p_ref", "op" => "eq", "value" => "r1"}]
      filtered = aggregate(ctx, agg_count("p_ent", %{"filters" => p_filter}))

      assert_refused(filtered, ["p_ref"])

      # (c) restriction on T.f_id only, through join -> 403 (far hop)
      set_restrictions!(ctx, [{"t_ent", "f_id"}])
      assert_refused(aggregate(ctx, agg_count("p_ent", %{"join" => @t_join})), ["f_id"])

      # (d) same NAME restricted on F (the non-owner) only -> 200
      set_restrictions!(ctx, [{"f_ent", "f_id"}])
      assert count_of(ctx, "p_ent", %{"join" => @t_join}) == 1

      # (e) restriction on T.p_id only, same join -> 403 (near hop)
      set_restrictions!(ctx, [{"t_ent", "p_id"}])
      assert_refused(aggregate(ctx, agg_count("p_ent", %{"join" => @t_join})), ["p_id"])
    end
  end

  # ==========================================================================
  # A-7 / A-10: unknown and joined-only names stay 422 echoing the string
  # ==========================================================================

  describe "unknown and joined-entity-only names" do
    test "A-7 a filter / group_by naming a field that exists only on the JOINED entity is 422 (primary allowlist), never evaluated against the joined entity" do
      ctx = combo_ctx!("aj-joinedonly", ["TASK_WORKER"], [])

      for extra <- [
            %{"filters" => [%{"field" => "text", "op" => "eq", "value" => "x"}]},
            %{"group_by" => [%{"field" => "text"}]}
          ] do
        conn = aggregate(ctx, agg_count("question", Map.put(extra, "join", @fk_join)))
        assert conn.status == 422
        assert body_of(conn)["detail"] == ~s(field is not queryable: "text")
      end
    end

    test "A-10 unknown field in filter / group_by / measure, with and without a join, is 422 echoing the caller's string" do
      ctx = combo_ctx!("aj-unknown", ["TASK_WORKER"], [{"answer_option", "question_id"}])

      bodies = [
        %{"filters" => [%{"field" => "nope", "op" => "eq", "value" => 1}]},
        %{"group_by" => [%{"field" => "nope"}]}
      ]

      for extra <- bodies, join <- [[], @fk_join_reverse] do
        extra = if join == [], do: extra, else: Map.put(extra, "join", join)
        conn = aggregate(ctx, agg_count("answer_option", extra))
        assert conn.status == 422
        assert body_of(conn)["detail"] == ~s(field is not queryable: "nope")
      end

      for join <- [nil, @fk_join_reverse] do
        body = %{
          "entity_type" => "answer_option",
          "aggregates" => [%{"fn" => "sum", "field" => "nope"}]
        }

        body = if join, do: Map.put(body, "join", join), else: body
        conn = aggregate(ctx, body)
        assert conn.status == 422
        assert body_of(conn)["detail"] == ~s(field is not queryable: "nope")
      end
    end
  end

  # ==========================================================================
  # A-8: nonexistent / cross-tenant primary stays a byte-identical 404
  # ==========================================================================

  describe "A-8 nonexistent primary answers 404 byte-identically with or without a join" do
    test "no join / direct join / through join / cross-tenant primary, restrictions on every hop" do
      ctx =
        combo_ctx!("aj-ghost", ["TASK_WORKER"], [
          {"answer_option", "question_id"},
          {"question_tags_m2m", "tag_id"},
          {"question_tags_m2m", "question_id"}
        ])

      other = tenant_ctx("aj-ghost-b", ["TASK_WORKER"])

      create_active_definition!(other, %{
        name: "only_in_b",
        display_name: "Only In B",
        fields: [%{name: "title", type: :string, queried: true}]
      })

      plain = aggregate(ctx, agg_count("ghost_q", %{}))
      assert plain.status == 404

      direct = aggregate(ctx, agg_count("ghost_q", %{"join" => @fk_join}))
      through = aggregate(ctx, agg_count("ghost_q", %{"join" => @m2m_join}))
      cross = aggregate(ctx, agg_count("only_in_b", %{}))
      cross_joined = aggregate(ctx, agg_count("only_in_b", %{"join" => @m2m_join}))

      # with a restricted filter the missing type must not turn into a 403
      filtered =
        aggregate(
          ctx,
          agg_count("ghost_q", %{
            "join" => @m2m_join,
            "filters" => [%{"field" => "question_id", "op" => "eq", "value" => "x"}]
          })
        )

      for conn <- [direct, through, cross, cross_joined, filtered] do
        assert conn.status == 404, "expected 404, got #{conn.status}: #{conn.resp_body}"
        assert whole(conn) == whole(plain)
      end
    end
  end

  # ==========================================================================
  # restricted + invalid join; A-10b parse order
  # ==========================================================================

  describe "ordering" do
    test "a restricted field TOGETHER WITH an invalid join answers the join error, exactly as the invalid join alone (no 403)" do
      ctx = combo_ctx!("aj-order", ["TASK_WORKER"], [{"answer_option", "question_id"}])

      bad_join = [%{"entity_type" => "question", "fk" => "no_such_fk"}]
      restricted = [%{"field" => "question_id", "op" => "eq", "value" => "x"}]

      alone = aggregate(ctx, agg_count("answer_option", %{"join" => bad_join}))
      both_body = agg_count("answer_option", %{"join" => bad_join, "filters" => restricted})
      both = aggregate(ctx, both_body)

      assert alone.status in 400..499
      refute alone.status == 403
      assert both.status == alone.status
      assert both.resp_body == alone.resp_body
    end

    test "A-10b a malformed body clause is a 400 even with a restricted filter; a non-object body is a 400" do
      ctx = exam_ctx!("aj-parse", ["TASK_WORKER"])
      restricted = [%{"field" => "is_correct", "op" => "eq", "value" => true}]
      base = %{"entity_type" => "answer_option", "filters" => restricted}

      bad = [
        Map.put(base, "aggregates", [%{"fn" => "bogus"}]),
        base |> Map.put("aggregates", @count) |> Map.put("group_by", [%{"nofield" => 1}]),
        base |> Map.put("aggregates", @count) |> Map.put("join", [%{"entity_type" => 1}])
      ]

      for body <- bad do
        conn = aggregate(ctx, body)
        assert conn.status == 400, "expected 400, got #{conn.status}: #{conn.resp_body}"
      end

      # control: the same body made well-formed IS the 403
      assert_refused(aggregate(ctx, Map.put(base, "aggregates", @count)), ["is_correct"])

      array = aggregate(ctx, [1, 2])
      assert array.status == 400
      assert body_of(array)["detail"] =~ "request body must be a JSON object"
    end
  end

  # ==========================================================================
  # A-14 uniform refusal incl. the join; A-15 response shape
  # ==========================================================================

  describe "uniform refusal and response shape" do
    test "A-14 aggregate join refusal equals the /query filter, /query join and export refusals field by field and leaks no names" do
      ctx = combo_ctx!("aj-uniform", ["TENANT_ADMIN"], [{"answer_option", "question_id"}])

      refusals = [
        aggregate(ctx, agg_count("answer_option", %{"join" => @fk_join_reverse})),
        aggregate(ctx, agg_count("question", %{"join" => @fk_join})),
        query(ctx, %{"entity_type" => "question", "join" => @fk_join}),
        query(ctx, %{
          "entity_type" => "answer_option",
          "filters" => [%{"field" => "question_id", "op" => "eq", "value" => "x"}]
        }),
        export(ctx, "answer_option", %{"join" => @fk_join_reverse})
      ]

      assert Enum.all?(refusals, &(&1.status == 403))
      [first | rest] = Enum.map(refusals, &problem/1)
      assert first["detail"] == @detail
      assert Enum.all?(rest, &(&1 == first))

      for conn <- refusals do
        refute conn.resp_body =~ "question_id"
        refute conn.resp_body =~ "question_fk"
        refute conn.resp_body =~ "answer_option"
      end
    end

    test "A-15 an aggregate over an exam type with restricted fields returns only group/values envelopes and no redaction sentinel" do
      ctx = exam_ctx!("aj-shape", ["TASK_WORKER"])

      conn =
        aggregate(ctx, agg_count("answer_option", %{"group_by" => [%{"field" => "text"}]}))

      assert conn.status == 200
      assert %{"results" => results} = body_of(conn)
      assert length(results) == 3

      for entry <- results do
        assert entry |> Map.keys() |> Enum.sort() == ["group", "values"]
      end

      refute conn.resp_body =~ Atom.to_string(FieldGrants.redacted_sentinel())
      refute conn.resp_body =~ "is_correct"
    end
  end
end
