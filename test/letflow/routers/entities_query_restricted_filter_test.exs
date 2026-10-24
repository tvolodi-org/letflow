defmodule Letflow.Routers.EntitiesQueryRestrictedFilterTest do
  @moduledoc """
  Leak reproduction (suspected, GH #2682 / req511 T-31 scope-4): the aggregate
  route (`POST /entities/query/aggregate`) rejects a request that names a
  field restricted for the caller with 403 (ISS-0647; since GH #2699 through
  the shared walker, `Letflow.Entities.FieldPolicy.check_request/4`). The plain
  query route (`POST /entities/query`), its join variant and the bulk export
  route (`POST /entities/records/:entity_type/export`) only REDACT the
  returned `field_values`; they do not look at the request's `filters` /
  `sort` fields at all. A caller can therefore filter or sort by a restricted
  field and learn its values from WHICH rows come back / their ORDER.

  Every test asserts on HTTP status and a minimal "which rows came back"
  signal only; no restricted value is ever printed. A test that asserts 403
  and gets 200 FAILS = the leak is proven on this code.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp query(ctx, body), do: request(:post, "/api/v1/entities/query", ctx, body)

  defp query_aggregate(ctx, body),
    do: request(:post, "/api/v1/entities/query/aggregate", ctx, body)

  defp export(ctx, entity_type, body),
    do: request(:post, "/api/v1/entities/records/#{entity_type}/export", ctx, body)

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "restricted-filter-#{Ecto.UUID.generate()}",
      display_name: "Restricted Filter Test User",
      email: "restricted-filter-#{Ecto.UUID.generate()}@example.com",
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
        display_name: "Restricted Filter Leak Test Tenant"
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
      Letflow.ManagedTypesSupport.create_definition(
        %{definition: definition, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, activated} =
      Definitions.activate_definition(
        entity_definition.name,
        ctx.user_id,
        "restricted filter go-live",
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

  # The real exam answer_option shape (see ISS-0647's test), restricted via
  # Exam.on_install/2 exactly as production seeds it.
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

    question = seed_record!(ctx, "question", %{"stem" => "2 + 2 = ?"})

    for {text, correct?} <- [{"A", true}, {"B", false}, {"C", false}] do
      seed_record!(ctx, "answer_option", %{
        "question_id" => question.record_id,
        "text" => text,
        "is_correct" => correct?
      })
    end

    ctx
  end

  defp insert_user_grant!(ctx, entity_type, field_name) do
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

  defp item_count(conn), do: length(body_of(conn)["items"])

  @filter_true [%{"field" => "is_correct", "op" => "eq", "value" => true}]
  @sort_is_correct [%{"field" => "is_correct", "dir" => "desc"}]

  describe "plain route, restricted caller (TASK_WORKER) on answer_option.is_correct" do
    test "(1) CONTROL: aggregate filtered by the restricted field -> 403" do
      ctx = exam_ctx!("rf-agg", ["TASK_WORKER"])

      conn =
        query_aggregate(ctx, %{
          "entity_type" => "answer_option",
          "aggregates" => [%{"fn" => "count"}],
          "filters" => @filter_true
        })

      assert conn.status == 403
    end

    test "(1b) CONTROL: plain query WITHOUT filter/sort still 200 (and field redacted)" do
      ctx = exam_ctx!("rf-plain-ctl", ["TASK_WORKER"])
      conn = query(ctx, %{"entity_type" => "answer_option"})
      assert conn.status == 200
      assert item_count(conn) == 3
    end

    test "(2) plain query FILTERED by the restricted field -> expected 403" do
      ctx = exam_ctx!("rf-plain-filter", ["TASK_WORKER"])

      conn = query(ctx, %{"entity_type" => "answer_option", "filters" => @filter_true})

      # status first: on a leak this is 200, and the rows-returned signal
      # below (1 of 3 rows = the filter was evaluated) is in the failure text.
      assert {conn.status, conn.status == 200 && item_count(conn)} == {403, false}
    end

    test "(3) plain query SORTED by the restricted field -> expected 403" do
      ctx = exam_ctx!("rf-plain-sort", ["TASK_WORKER"])

      conn = query(ctx, %{"entity_type" => "answer_option", "sort" => @sort_is_correct})

      assert {conn.status, conn.status == 200 && item_count(conn)} == {403, false}
    end
  end

  describe "export route, restricted caller (TENANT_ADMIN, the only role holding :EntitiesRecordsExport)" do
    test "(5a) export FILTERED by the restricted field -> expected 403" do
      ctx = exam_ctx!("rf-exp-filter", ["TENANT_ADMIN"])

      conn = export(ctx, "answer_option", %{"filters" => @filter_true})

      assert {conn.status, conn.status == 200 && length(body_of(conn)["records"])} ==
               {403, false}
    end

    test "(5b) export SORTED by the restricted field -> expected 403" do
      ctx = exam_ctx!("rf-exp-sort", ["TENANT_ADMIN"])

      conn = export(ctx, "answer_option", %{"sort" => @sort_is_correct})

      assert {conn.status, conn.status == 200 && length(body_of(conn)["records"])} ==
               {403, false}
    end
  end

  describe "(6) CONTROL: an unrestricted caller / unrestricted field still filters" do
    test "caller holding a user_entity_grants row for is_correct can filter by it (200, 1 row)" do
      ctx = exam_ctx!("rf-granted", ["TASK_WORKER"])
      insert_user_grant!(ctx, "answer_option", "is_correct")

      conn = query(ctx, %{"entity_type" => "answer_option", "filters" => @filter_true})
      assert conn.status == 200
      assert item_count(conn) == 1
    end

    test "restricted caller can still filter by an UNRESTRICTED field (text)" do
      ctx = exam_ctx!("rf-unrestricted-field", ["TASK_WORKER"])

      conn =
        query(ctx, %{
          "entity_type" => "answer_option",
          "filters" => [%{"field" => "text", "op" => "eq", "value" => "B"}]
        })

      assert conn.status == 200
      assert item_count(conn) == 1
    end
  end

  # ── (4) join variant ──────────────────────────────────────────────────
  #
  # Join-fixture shape of test/letflow/routers/entities_test.exs (REQ-311):
  # primary "question" joined to "answer_option" via fk question_fk. The
  # restricted field is the PRIMARY's `stem` (filters/sort resolve against the
  # primary's allowlist in compile_joined/6).

  defp promote_and_create_table!(ctx, entity_type, attribute, pg_type, opts \\ []) do
    references_entity = Keyword.get(opts, :references_entity)

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

  defp join_ctx!(slug_prefix) do
    ctx = tenant_ctx(slug_prefix, ["TASK_WORKER"])

    create_active_definition!(ctx, %{
      name: "question",
      display_name: "Question",
      fields: [%{name: "stem", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "question", "stem", "text")

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

    promote_and_create_table!(ctx, "answer_option", "question_id", "uuid",
      references_entity: "question"
    )

    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: "question",
          field_name: "stem",
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )

    q1 = seed_record!(ctx, "question", %{"stem" => "alpha"})
    q2 = seed_record!(ctx, "question", %{"stem" => "beta"})
    seed_record!(ctx, "answer_option", %{"text" => "x", "question_id" => q1.record_id})
    seed_record!(ctx, "answer_option", %{"text" => "y", "question_id" => q2.record_id})
    ctx
  end

  @join [%{"entity_type" => "answer_option", "fk" => "question_fk"}]

  describe "(4) join route, restricted primary field" do
    test "CONTROL: join query without filter/sort -> 200" do
      ctx = join_ctx!("rf-join-ctl")
      conn = query(ctx, %{"entity_type" => "question", "join" => @join})
      assert conn.status == 200
    end

    test "(4a) joined query FILTERED by the restricted field -> expected 403" do
      ctx = join_ctx!("rf-join-filter")

      conn =
        query(ctx, %{
          "entity_type" => "question",
          "filters" => [%{"field" => "stem", "op" => "eq", "value" => "alpha"}],
          "join" => @join
        })

      assert {conn.status, conn.status == 200 && item_count(conn)} == {403, false}
    end

    test "(4b) joined query SORTED by the restricted field -> expected 403" do
      ctx = join_ctx!("rf-join-sort")

      conn =
        query(ctx, %{
          "entity_type" => "question",
          "sort" => [%{"field" => "stem", "dir" => "desc"}],
          "join" => @join
        })

      assert {conn.status, conn.status == 200 && item_count(conn)} == {403, false}
    end
  end
end
