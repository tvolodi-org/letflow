defmodule Letflow.Routers.TenantAdminRoutesTest do
  @moduledoc """
  REQ-447 PR 1, AC2 (`lib/letflow/design/req447-tenant-admin-role.md` sections 2.3 and 11;
  spec `test/specs/REQ-447-PR1.md`): what a `TENANT_ADMIN` of an ORDINARY (non-platform) tenant can
  and cannot reach. Real Postgres, real routers, the platform tenant pinned on a third tenant.

    * 2xx: one named line per route family in the AC (users, groups, roles, tokens, audit,
      `PATCH /tenant/settings`, `POST /tenant/modules`, `POST /tenant/solutions`, promotions list
      and review read, definition rollback), dispatched directly into the owning router with a
      hand-assigned `auth_context` (the style of the whole router suite), plus the same decision
      through the FULL `Letflow.Router` pipeline with a real API token.
    * 403: EVERY platform-scope route (the 21-row inventory of
      `platform_scope_inventory_test.exs`, enumerated here from the routers' own route tables and
      classified by `permission_scope/1`, with the count pinned at 21), covering `/tenants`,
      `/onboarding`, `/platform-migrations`, `/event-retention` and `/admin/services`; the
      tenant registry and service catalogue are unchanged after the denied requests.
    * A TENANT_ADMIN of a tenant gets 403 (not the router 404) on an unmatched ordinary path.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Authorization
  alias Letflow.Identity.Group
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  @pipeline_source File.read!("lib/letflow/plugs/api_pipeline.ex")
  @unused_uuid "00000000-0000-4000-8000-000000000003"
  @admin ["TENANT_ADMIN"]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp call(router, method, path, fixture, roles, body) do
    router.call(Fixture.router_conn(method, path, fixture, roles, body), router.init([]))
  end

  defp insert_user!(fixture) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req447-#{Ecto.UUID.generate()}",
      display_name: "REQ-447 User",
      email: "req447-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  defp insert_group!(fixture) do
    %Group{}
    |> Ecto.Changeset.change(%{name: "req447-g-#{System.unique_integer([:positive])}"})
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  # --- AC2: 2xx ------------------------------------------------------------------------------

  describe "AC2: a TENANT_ADMIN of an ordinary tenant is allowed (2xx), router by router" do
    test "GET and POST /identity/users", ctx do
      assert %{status: 200} = call(Letflow.Routers.Identity, :get, "/users", ctx.a, @admin, nil)

      conn =
        call(Letflow.Routers.Identity, :post, "/users", ctx.a, @admin, %{
          "username" => "req447-new-#{System.unique_integer([:positive])}",
          "display_name" => "New User",
          "email" => "req447-new-#{System.unique_integer([:positive])}@example.com"
        })

      assert conn.status == 201, conn.resp_body
    end

    test "GET and POST /identity/groups", ctx do
      assert %{status: 200} = call(Letflow.Routers.Identity, :get, "/groups", ctx.a, @admin, nil)

      conn =
        call(Letflow.Routers.Identity, :post, "/groups", ctx.a, @admin, %{
          "name" => "req447-group-#{System.unique_integer([:positive])}"
        })

      assert conn.status == 201, conn.resp_body
    end

    test "GET and POST /identity/roles", ctx do
      group = insert_group!(ctx.a)
      assert %{status: 200} = call(Letflow.Routers.Identity, :get, "/roles", ctx.a, @admin, nil)

      conn =
        call(Letflow.Routers.Identity, :post, "/roles", ctx.a, @admin, %{
          "name" => "req447-routing-#{System.unique_integer([:positive])}",
          "kind" => "process_routing_role",
          "group_id" => group.id
        })

      assert conn.status in [200, 201], conn.resp_body
    end

    test "GET and POST /identity/tokens (a TENANT_ADMIN may mint a TENANT_ADMIN token)", ctx do
      user = insert_user!(ctx.a)
      assert %{status: 200} = call(Letflow.Routers.Identity, :get, "/tokens", ctx.a, @admin, nil)

      conn =
        call(Letflow.Routers.Identity, :post, "/tokens", ctx.a, @admin, %{
          "user_id" => user.id,
          "roles" => ["TENANT_ADMIN"]
        })

      assert conn.status == 201, conn.resp_body
    end

    test "GET /audit", ctx do
      assert %{status: 200} = call(Letflow.Routers.Audit, :get, "/", ctx.a, @admin, nil)
    end

    test "PATCH /tenant/settings", ctx do
      conn =
        call(Letflow.Routers.TenantSettings, :patch, "/", ctx.a, @admin, %{
          "app_name" => "REQ-447 Renamed"
        })

      assert conn.status == 200, conn.resp_body
    end

    test "POST /tenant/modules", ctx do
      conn =
        call(Letflow.Routers.TenantModules, :post, "/", ctx.a, @admin, %{
          "module_id" => "fixture",
          "rationale" => "test: module install"
        })

      assert conn.status == 201, conn.resp_body
    end

    test "POST /tenant/solutions", ctx do
      conn =
        call(Letflow.Routers.TenantSolutions, :post, "/", ctx.a, @admin, %{
          "solution_id" => "fixture-bundle",
          "rationale" => "test: solution install"
        })

      assert conn.status == 201, conn.resp_body
    end

    test "promotions: list, and reads of a review of its own tenant",
         ctx do
      assert %{status: 200} = call(Letflow.Routers.Promotions, :get, "/", ctx.a, @admin, nil)

      %{review: review} = Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id)

      assert %{status: 200} =
               call(Letflow.Routers.Promotions, :get, "/#{review.id}", ctx.a, @admin, nil)

      conn = call(Letflow.Routers.Promotions, :get, "/#{review.id}/context", ctx.a, @admin, nil)
      assert conn.status == 200, conn.resp_body
      assert Jason.decode!(conn.resp_body)["review_id"] == review.id
    end

    test "POST /definitions/:process_key/rollback", ctx do
      key = Scope.unique_key("req447-rollback")
      Scope.two_version_history!(ctx.a, key)

      conn =
        call(Letflow.Routers.Definitions, :post, "/#{key}/rollback", ctx.a, @admin, %{
          "target_version" => "1.0.0"
        })

      assert conn.status == 200, conn.resp_body
      assert Jason.decode!(conn.resp_body)["version"] == "1.0.0"
    end
  end

  describe "AC2: the same decisions through the FULL Letflow.Router pipeline with a real API token" do
    test "TENANT_ADMIN token: 200 tenant routes, 403 platform prefixes and unmatched path",
         ctx do
      token = Fixture.mint_token!(ctx.a, @admin)
      slug = ctx.a.tenant.slug

      for {method, path, body} <- [
            {:get, "/api/v1/identity/users", nil},
            {:get, "/api/v1/identity/groups", nil},
            {:get, "/api/v1/audit", nil},
            {:patch, "/api/v1/tenant/settings", %{"app_name" => "Via Pipeline"}}
          ] do
        conn = Fixture.api_conn(method, path, token, slug, body) |> Fixture.dispatch_api()
        assert conn.status == 200, "#{method} #{path}: #{conn.status} #{conn.resp_body}"
      end

      for {method, path, body} <- [
            {:get, "/api/v1/tenants", nil},
            {:get, "/api/v1/onboarding", nil},
            {:post, "/api/v1/platform-migrations/rollouts", %{}},
            {:get, "/api/v1/event-retention/summary", nil},
            {:get, "/api/v1/admin/services", nil},
            {:get, "/api/v1/identity/no-such-route-req447", nil}
          ] do
        conn = Fixture.api_conn(method, path, token, slug, body) |> Fixture.dispatch_api()
        assert conn.status == 403, "#{method} #{path}: #{conn.status} #{conn.resp_body}"
      end
    end

    test "platform tenant's own TENANT_ADMIN token: tenant route 200, platform prefixes 403",
         ctx do
      token = Fixture.mint_token!(ctx.p, @admin)
      slug = ctx.p.tenant.slug

      ok =
        Fixture.api_conn(:get, "/api/v1/identity/users", token, slug, nil)
        |> Fixture.dispatch_api()

      assert ok.status == 200

      for path <- ["/api/v1/tenants", "/api/v1/onboarding", "/api/v1/admin/services"] do
        conn = Fixture.api_conn(:get, path, token, slug, nil) |> Fixture.dispatch_api()
        assert conn.status == 403, path
      end
    end
  end

  # --- AC2: 403 on every platform-scope route --------------------------------------------------

  # {router module, mount prefix} from the `forward("<prefix>", to: <Module>)` lines.
  defp mounts do
    ~r/forward\(\s*"([^"]+)"\s*,\s*to:\s*([A-Za-z0-9_.]+)\s*\)/
    |> Regex.scan(@pipeline_source)
    |> Map.new(fn [_all, prefix, module] -> {Module.concat([module]), prefix} end)
  end

  # [{router, method, local_path, full_path}] for every route whose permission is platform scope.
  defp platform_routes do
    mounts = mounts()

    for {router, prefix} <- mounts,
        Code.ensure_loaded?(router),
        function_exported?(router, :__authz_routes__, 0),
        {method, local, key} <- router.__authz_routes__(),
        Authorization.permission_scope(Authorization.required_permission(key)) == :platform do
      {router, method, local, if(local == "/", do: prefix, else: prefix <> local)}
    end
  end

  defp concrete(path), do: Regex.replace(~r/:[a-z_]+/, path, @unused_uuid)

  defp state_snapshot do
    tenants =
      Tenant
      |> Repo.all()
      |> Enum.map(&{&1.id, &1.slug, &1.display_name, &1.status, &1.updated_at})
      |> Enum.sort()

    %{rows: [[services]]} = Repo.query!("SELECT count(*) FROM service_catalog")
    %{tenants: tenants, services: services}
  end

  describe "AC2: every platform-scope route answers 403 to a TENANT_ADMIN" do
    test "the inventory is the 26 platform routes (GH 2534 7b-2a added the two script-policy routes under /tenants) and spans exactly the five platform prefixes" do
      routes = platform_routes()
      assert length(routes) == 26

      prefixes =
        routes
        |> Enum.map(fn {_r, _m, _local, full} ->
          full |> String.split("/", trim: true) |> hd()
        end)
        |> Enum.uniq()
        |> Enum.sort()

      assert prefixes ==
               Enum.sort([
                 "tenants",
                 "onboarding",
                 "platform-migrations",
                 "event-retention",
                 "admin"
               ])
    end

    test "all 26 routes answer 403 (ordinary and platform tenant TENANT_ADMIN), no row changes",
         ctx do
      before = state_snapshot()
      routes = platform_routes()
      assert length(routes) == 26

      for {fixture, label} <- [{ctx.a, "ordinary tenant"}, {ctx.p, "platform tenant"}],
          {router, method, local, full} <- routes do
        verb = method |> to_string() |> String.downcase() |> String.to_atom()
        body = if verb in [:post, :patch, :put], do: %{}, else: nil
        conn = call(router, verb, concrete(local), fixture, @admin, body)

        assert conn.status == 403,
               "#{label} TENANT_ADMIN: #{method} #{full} answered #{conn.status}"
      end

      assert state_snapshot() == before
    end

    test "unmatched paths are 403, not 404, for a TENANT_ADMIN",
         ctx do
      for {router, path} <- [
            {Letflow.Routers.Tenants, "/x/y/z"},
            {Letflow.Routers.Onboarding, "/x/y/z"},
            {Letflow.Routers.PlatformMigrations, "/x/y/z"},
            {Letflow.Routers.EventRetention, "/x/y/z"},
            {Letflow.Routers.AdminServices, "/x/y/z"},
            {Letflow.Routers.Identity, "/x/y/z"},
            {Letflow.Routers.Audit, "/x/y/z"}
          ] do
        conn = call(router, :get, path, ctx.a, @admin, nil)
        assert conn.status == 403, "#{inspect(router)} #{path}: #{conn.status}"
      end
    end
  end
end
