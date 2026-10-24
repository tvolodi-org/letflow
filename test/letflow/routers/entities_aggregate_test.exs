defmodule Letflow.Routers.EntitiesAggregateTest do
  @moduledoc """
  Tests for REQ-315's `POST /entities/query/aggregate` route
  (`Letflow.Routers.Entities`), written by ELIXIR-DEV at WF-02 Step 2a. See
  `lib/letflow/design/req312-query-aggregation.md` for the design these
  tests exercise -- in particular §4's final, SECURITY-REVIEWER-cleared
  INV-2 mechanism, the hardest part of this requirement.

  ## Every request goes through the full pipeline, not the router in isolation

  Same discipline as `test/letflow/routers/entities_test.exs`: dispatched via
  `Letflow.Router.call/2` with a real API-token bearer credential, so
  `Letflow.Plugs.AuthPipeline` -> `Letflow.Plugs.TenantStatus` ->
  `Letflow.Plugs.Authorize` -> the router all genuinely run.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  `async: false` because `TenantFixture.provisioned_tenant!/1` switches the
  sandbox to global `:auto` mode. Self-sufficient: does not depend on any
  fixture defined in `entities_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  # ── Full-pipeline dispatch ─────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body, opts) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> maybe_pin_trace_id(Keyword.get(opts, :trace_id))
    |> dispatch()
  end

  # Same rationale as entities_test.exs's own helper: `Letflow.Api.Error`'s
  # `trace_id` is per-request correlation data, not per-resource -- pinning
  # it to one fixed value across a pair of requests makes `resp_body ==
  # resp_body` a genuine byte-for-byte comparison of the whole document
  # rather than one that happens to pass because trace_id was never compared.
  defp maybe_pin_trace_id(conn, nil), do: conn
  defp maybe_pin_trace_id(conn, trace_id), do: put_req_header(conn, "x-trace-id", trace_id)

  defp aggregate(ctx, body, opts \\ []),
    do: request(:post, "/api/v1/entities/query/aggregate", ctx, body, opts)

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req315-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-315 Aggregate Route Test User",
      email: "req315-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp tenant_ctx(slug_prefix, roles \\ ["TENANT_ADMIN"]) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "REQ-315 Aggregate Route Test Tenant"
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
        "req315 go-live",
        ctx.schema_name
      )

    activated
  end

  defp seed_widget!(ctx) do
    create_active_definition!(ctx, %{
      name: "widget",
      display_name: "Widget",
      fields: [
        %{name: "title", type: :string, queried: true},
        %{name: "category", type: :string, queried: true},
        %{name: "quantity", type: :integer, queried: true},
        %{
          name: "secret_cost",
          type: :decimal,
          queried: true,
          decimal_precision: 10,
          decimal_scale: 2
        }
      ]
    })
  end

  defp seed_record!(ctx, field_values) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: "widget",
          field_values: field_values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  defp insert_field_restriction!(ctx, entity_type, field_name) do
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

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- permission gating: 403 without :EntitiesAggregate, non-403 with it.
  # ═══════════════════════════════════════════════════════════════════════

  describe "permission gating" do
    test "AGENT_RUNNER (holds none of the Entities* permissions) gets 403" do
      ctx = tenant_ctx("req315-perm-none", ["AGENT_RUNNER"])
      seed_widget!(ctx)

      conn = aggregate(ctx, %{"entity_type" => "widget", "aggregates" => [%{"fn" => "count"}]})
      assert conn.status == 403
    end

    test "TENANT_ADMIN succeeds" do
      ctx = tenant_ctx("req315-perm-admin", ["TENANT_ADMIN"])
      seed_widget!(ctx)

      conn = aggregate(ctx, %{"entity_type" => "widget", "aggregates" => [%{"fn" => "count"}]})
      assert conn.status == 200
    end

    test "TASK_WORKER (holds :EntitiesQuery, so also :EntitiesAggregate) succeeds" do
      ctx = tenant_ctx("req315-perm-worker", ["TASK_WORKER"])
      seed_widget!(ctx)

      conn = aggregate(ctx, %{"entity_type" => "widget", "aggregates" => [%{"fn" => "count"}]})
      assert conn.status == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- response shape per design §5.
  # ═══════════════════════════════════════════════════════════════════════

  describe "response shape" do
    test "no group_by -> exactly one results entry, no group key, values keyed by label" do
      ctx = tenant_ctx("req315-shape-nogroup")
      seed_widget!(ctx)
      seed_record!(ctx, %{"title" => "a", "quantity" => 3})
      seed_record!(ctx, %{"title" => "b", "quantity" => 4})

      conn =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "aggregates" => [%{"fn" => "count"}, %{"fn" => "sum", "field" => "quantity"}]
        })

      assert conn.status == 200
      body = body_of(conn)
      assert %{"results" => [entry]} = body
      refute Map.has_key?(entry, "group")
      assert entry["values"]["count_none"] == 2
      # SUM over this JSON field's ::bigint cast returns Postgres NUMERIC
      # (SQL-standard overflow avoidance), which Jason encodes as a quoted
      # JSON string via Decimal's own Jason.Encoder impl -- real behavior,
      # not a bug to work around.
      assert entry["values"]["sum_quantity"] == "7"
    end

    test "group_by -> one entry per distinct group, each carrying a group map" do
      ctx = tenant_ctx("req315-shape-group")
      seed_widget!(ctx)
      seed_record!(ctx, %{"title" => "a", "category" => "tools", "quantity" => 1})
      seed_record!(ctx, %{"title" => "b", "category" => "tools", "quantity" => 2})
      seed_record!(ctx, %{"title" => "c", "category" => "parts", "quantity" => 10})

      conn =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "aggregates" => [%{"fn" => "count"}],
          "group_by" => [%{"field" => "category"}]
        })

      assert conn.status == 200
      results = body_of(conn)["results"] |> Enum.sort_by(& &1["group"]["category"])

      assert [
               %{"group" => %{"category" => "parts"}, "values" => %{"count_none" => 1}},
               %{"group" => %{"category" => "tools"}, "values" => %{"count_none" => 2}}
             ] = results
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # ⛔ AC -- THE §4 INV-2 MECHANISM. Three independent 403 tests: restricted
  # aggregate target, restricted group_by target, restricted filter field.
  # Plus both named variants of the filters-composed-with-aggregate channel:
  # count/group_by, and sum/avg/min/max.
  # ═══════════════════════════════════════════════════════════════════════

  describe "INV-2 -- field-restriction check runs before compilation, no exemption for filters on this route" do
    test "a restricted AGGREGATE TARGET field -> 403" do
      ctx = tenant_ctx("req315-inv2-target")
      seed_widget!(ctx)
      insert_field_restriction!(ctx, "widget", "secret_cost")

      conn =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "aggregates" => [%{"fn" => "sum", "field" => "secret_cost"}]
        })

      assert conn.status == 403
      refute conn.status == 200
    end

    test "a restricted GROUP_BY field -> 403" do
      ctx = tenant_ctx("req315-inv2-groupby")
      seed_widget!(ctx)
      insert_field_restriction!(ctx, "widget", "secret_cost")

      conn =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "aggregates" => [%{"fn" => "count"}],
          "group_by" => [%{"field" => "secret_cost"}]
        })

      assert conn.status == 403
      refute conn.status == 200
    end

    test "a restricted FILTER field, paired with count + an unrestricted group_by -> 403, not a redacted/partial 200" do
      ctx = tenant_ctx("req315-inv2-filter-count")
      seed_widget!(ctx)
      insert_field_restriction!(ctx, "widget", "secret_cost")

      seed_record!(ctx, %{
        "title" => "a",
        "category" => "tools",
        "quantity" => 1,
        "secret_cost" => 9.99
      })

      conn =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "secret_cost", "op" => "eq", "value" => "9.99"}],
          "aggregates" => [%{"fn" => "count"}],
          "group_by" => [%{"field" => "category"}]
        })

      assert conn.status == 403
      refute conn.status == 200
    end

    test "a restricted FILTER field, paired with sum on an UNRESTRICTED numeric field -> 403 identically -- proves the check is not exempted for sum either" do
      ctx = tenant_ctx("req315-inv2-filter-sum")
      seed_widget!(ctx)
      insert_field_restriction!(ctx, "widget", "secret_cost")

      seed_record!(ctx, %{
        "title" => "a",
        "quantity" => 5,
        "secret_cost" => 9.99
      })

      conn =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "secret_cost", "op" => "eq", "value" => "9.99"}],
          "aggregates" => [%{"fn" => "sum", "field" => "quantity"}]
        })

      assert conn.status == 403
      refute conn.status == 200
    end

    test "the SAME field restricted, but the caller holds a user_entity_grants row for it -> not restricted, request succeeds" do
      ctx = tenant_ctx("req315-inv2-granted")
      seed_widget!(ctx)
      insert_field_restriction!(ctx, "widget", "secret_cost")

      Repo.insert_all(
        "user_entity_grants",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            user_id: Ecto.UUID.dump!(ctx.user_id),
            entity_type: "widget",
            field_name: "secret_cost",
            inserted_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema_name
      )

      conn =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "aggregates" => [%{"fn" => "sum", "field" => "secret_cost"}]
        })

      assert conn.status == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- arity/type-mismatch error mapping (design §2/§4 -- 422s).
  # ═══════════════════════════════════════════════════════════════════════

  describe "error mapping -- 422s" do
    test "sum over the wrong field type -> 422 {:aggregate_type_not_valid, ...}" do
      ctx = tenant_ctx("req315-422-type")
      seed_widget!(ctx)

      conn =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "aggregates" => [%{"fn" => "sum", "field" => "title"}]
        })

      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "sum"
    end

    test "sum naming no field -> 422 {:aggregate_field_required, ...}" do
      ctx = tenant_ctx("req315-422-required")
      seed_widget!(ctx)

      conn = aggregate(ctx, %{"entity_type" => "widget", "aggregates" => [%{"fn" => "sum"}]})

      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "requires a field"
    end

    test "count naming a field -> 422 {:aggregate_field_not_allowed, ...}" do
      ctx = tenant_ctx("req315-422-notallowed")
      seed_widget!(ctx)

      conn =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "aggregates" => [%{"fn" => "count", "field" => "quantity"}]
        })

      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "does not accept a field"
    end

    test "an unresolvable aggregate target field -> 422 {:field_not_allowed, _}" do
      ctx = tenant_ctx("req315-422-fieldnotallowed")
      seed_widget!(ctx)

      conn =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "aggregates" => [%{"fn" => "sum", "field" => "not_a_real_field"}]
        })

      assert conn.status == 422
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- INV-5: cross-tenant entity_type is byte-identical to a nonexistent
  # one.
  # ═══════════════════════════════════════════════════════════════════════

  describe "INV-5" do
    test "a nonexistent entity_type and a cross-tenant entity_type produce byte-identical 404 responses" do
      ctx1 = tenant_ctx("req315-inv5-a")
      ctx2 = tenant_ctx("req315-inv5-b")
      seed_widget!(ctx2)

      trace_id = Ecto.UUID.generate()

      nonexistent =
        aggregate(
          ctx1,
          %{"entity_type" => "widget", "aggregates" => [%{"fn" => "count"}]},
          trace_id: trace_id
        )

      cross_tenant =
        aggregate(
          ctx1,
          %{
            "entity_type" => "widget_only_in_tenant_b",
            "aggregates" => [%{"fn" => "count"}]
          },
          trace_id: trace_id
        )

      assert nonexistent.status == 404
      assert cross_tenant.status == 404
      assert nonexistent.resp_body == cross_tenant.resp_body
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- INV-1: tenant_id/schema/slug in the body change nothing; the
  # Repo. grep count is checked separately at the file level (see the
  # ELIXIR-DEV report for this requirement -- the design's own §4 text
  # instructs a direct Repo.all/2 call in this handler, which increases that
  # grep's count from its pre-REQ-315 baseline of zero; flagged to
  # SECURITY-REVIEWER/REVIEWER rather than silently resolved either way).
  # ═══════════════════════════════════════════════════════════════════════

  describe "INV-1" do
    test "tenant_id/schema/slug in the body change nothing" do
      ctx = tenant_ctx("req315-inv1")
      seed_widget!(ctx)
      seed_record!(ctx, %{"title" => "a", "quantity" => 1})

      plain =
        aggregate(ctx, %{"entity_type" => "widget", "aggregates" => [%{"fn" => "count"}]})

      with_extra_fields =
        aggregate(ctx, %{
          "entity_type" => "widget",
          "aggregates" => [%{"fn" => "count"}],
          "tenant_id" => Ecto.UUID.generate(),
          "schema" => "some_other_schema",
          "slug" => "some-other-tenant"
        })

      assert plain.status == with_extra_fields.status
      assert plain.resp_body == with_extra_fields.resp_body
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC -- moduledoc route table carries the new row.
  # ═══════════════════════════════════════════════════════════════════════

  describe "moduledoc" do
    test "the route table names POST /entities/query/aggregate and :EntitiesAggregate" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _fn_docs} =
        Code.fetch_docs(Letflow.Routers.Entities)

      assert moduledoc =~ "POST /entities/query/aggregate"
      assert moduledoc =~ "EntitiesAggregate"
    end
  end
end
