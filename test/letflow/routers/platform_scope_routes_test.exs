defmodule Letflow.Routers.PlatformScopeRoutesTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 items 5 and 14, A2 ENFORCING (spec
  `test/specs/ISS-0993-A2.md`): the 22 platform-scope routes (design 7.1 plus ISS-1030's bind-realm) of the five platform
  routers (`tenants`, `onboarding`, `platform_migrations`, `event_retention`, `admin_services`).
  The uniform-403 behaviour of the prefixes and of the router catch-alls (item 19) lives in
  `test/letflow/api/platform_prefix_uniform_403_test.exs`.

  Cases per route (tenants: P = platform tenant, A = ordinary):

    * (a) A `PLATFORM_ADMIN`, pin set to P: 403, no identifier in the body, no row written;
    * (b) P `PLATFORM_ADMIN`: reaches the handler (not 403, no 5xx);
    * (c) P and A `PROCESS_DESIGNER`: 403;
    * (d) pin unset, P `PLATFORM_ADMIN`: 403 (fail closed);
    * (e) a token minted in A and presented with P's slug: 401 (the token is unknown in P's schema).

  Handlers are reached only with nonexistent ids and empty bodies, so no row is written; the
  tenant row count is asserted unchanged around every group. Item 14 (through the FULL
  `Letflow.Router`, real bearer tokens): `GET /tenants` is 403 for A's legacy `PLATFORM_ADMIN` token
  (which now holds nothing) and 200 for P's, while a tenant-scope route is 200 for A's `TENANT_ADMIN`
  and 403 for A's legacy `PLATFORM_ADMIN` token (REQ-447 PR 2: the own-tenant power is removed).

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @unused_uuid "00000000-0000-4000-8000-000000000001"

  # {router, method, declared local pattern, concrete local path, body, policy key}
  @routes [
    {Letflow.Routers.Tenants, :post, "/", "/", %{}, :TenantsManage},
    {Letflow.Routers.Tenants, :get, "/", "/", nil, :TenantsManage},
    {Letflow.Routers.Tenants, :get, "/:slug", "/no-such-slug", nil, :TenantsManage},
    {Letflow.Routers.Tenants, :patch, "/:slug", "/no-such-slug", %{}, :TenantsManage},
    {Letflow.Routers.Tenants, :post, "/:slug/deactivate", "/no-such-slug/deactivate", nil,
     :TenantsManage},
    {Letflow.Routers.Tenants, :post, "/:slug/reactivate", "/no-such-slug/reactivate", nil,
     :TenantsManage},
    {Letflow.Routers.Onboarding, :post, "/", "/", %{}, :TenantsManage},
    {Letflow.Routers.Onboarding, :get, "/:id", "/" <> @unused_uuid, nil, :TenantsManage},
    {Letflow.Routers.Onboarding, :post, "/:id/bind-realm", "/" <> @unused_uuid <> "/bind-realm",
     %{"idp_realm_id" => "iss1030-routes"}, :TenantsManage},
    {Letflow.Routers.Onboarding, :get, "/", "/", nil, :TenantsManage},
    {Letflow.Routers.PlatformMigrations, :post, "/rollouts", "/rollouts", %{}, :TenantsManage},
    {Letflow.Routers.PlatformMigrations, :get, "/rollouts/:id", "/rollouts/" <> @unused_uuid, nil,
     :TenantsManage},
    {Letflow.Routers.PlatformMigrations, :post, "/rollouts/:id/resume",
     "/rollouts/" <> @unused_uuid <> "/resume", nil, :TenantsManage},
    {Letflow.Routers.EventRetention, :get, "/summary", "/summary", nil, :TenantsManage},
    {Letflow.Routers.EventRetention, :post, "/retirements", "/retirements", %{}, :TenantsManage},
    {Letflow.Routers.EventRetention, :get, "/retirements/:id", "/retirements/" <> @unused_uuid,
     nil, :TenantsManage},
    {Letflow.Routers.AdminServices, :get, "/", "/", nil, :AdminServicesRead},
    {Letflow.Routers.AdminServices, :post, "/", "/", %{}, :AdminServicesManage},
    {Letflow.Routers.AdminServices, :patch, "/:service_id", "/no-such-service", %{},
     :AdminServicesManage},
    {Letflow.Routers.AdminServices, :delete, "/:service_id", "/no-such-service", nil,
     :AdminServicesManage},
    {Letflow.Routers.AdminServices, :post, "/:service_id/versions", "/no-such-service/versions",
     %{}, :AdminServicesManage},
    {Letflow.Routers.AdminServices, :post, "/:service_id/retire", "/no-such-service/retire", nil,
     :AdminServicesManage}
  ]

  @groups @routes |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  defp dispatch(router, conn), do: router.call(conn, router.init([]))

  defp request({router, method, _pattern, path, body, _key}, fixture, roles) do
    dispatch(router, Fixture.router_conn(method, path, fixture, roles, body))
  end

  defp tenant_count, do: Repo.aggregate(Tenant, :count, :id)

  # REQ-447 PR 2: `Identity.create_token/3` refuses PLATFORM_ADMIN outside the platform tenant's
  # schema, so a LEGACY (pre-PR 2) tenant-schema PLATFORM_ADMIN token is a raw insert.
  defp mint_legacy_platform_admin_token!(fixture) do
    user =
      %Letflow.Identity.User{}
      |> Ecto.Changeset.change(%{
        username: "legacy-pa-#{Ecto.UUID.generate()}",
        display_name: "Legacy Platform Admin",
        email: "legacy-pa-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: fixture.schema_name)

    plaintext = "lf_tok_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    %Letflow.Identity.ApiToken{}
    |> Letflow.Identity.ApiToken.insert_changeset(%{
      user_id: user.id,
      name: "legacy-platform-admin",
      token_hash: :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower),
      roles: ["PLATFORM_ADMIN"],
      expires_at: nil
    })
    |> Repo.insert!(prefix: fixture.schema_name)

    plaintext
  end

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  describe "declared routes" do
    test "the 22 snapshot rows declare the expected policy keys" do
      assert length(@routes) == 22

      for {router, method, pattern, _path, _body, key} <- @routes do
        verb = method |> Atom.to_string() |> String.upcase()

        assert {verb, pattern, key} in router.__authz_routes__(),
               "#{inspect(router)} does not declare #{verb} #{pattern} with #{inspect(key)}"
      end
    end
  end

  for router <- @groups do
    @router router

    describe "items 5 A2 enforcing: #{inspect(router)} platform routes" do
      test "A PLATFORM_ADMIN (a tenant that is not the platform tenant) is denied 403 on every route, no row written",
           ctx do
        before = tenant_count()

        for route <- @routes, elem(route, 0) == @router do
          resp = request(route, ctx.a, ["PLATFORM_ADMIN"])
          label = "#{elem(route, 1)} #{elem(route, 3)}"

          assert resp.status == 403, "#{label}: A's PLATFORM_ADMIN answered #{resp.status}"

          for secret <- [ctx.a.tenant_id, ctx.b.tenant_id, ctx.p.tenant_id, ctx.a.tenant.slug] do
            refute resp.resp_body =~ secret, "the 403 must carry no identifier: #{label}"
          end
        end

        assert tenant_count() == before
      end

      test "the platform tenant's PLATFORM_ADMIN reaches the handler (not 403)", ctx do
        before = tenant_count()

        for route <- @routes, elem(route, 0) == @router do
          resp = request(route, ctx.p, ["PLATFORM_ADMIN"])
          label = "#{elem(route, 1)} #{elem(route, 3)}"

          refute resp.status == 403, label
          assert resp.status < 500, "#{label} answered #{resp.status}"
        end

        assert tenant_count() == before
      end

      test "a PROCESS_DESIGNER of the platform tenant or of an ordinary tenant is denied 403",
           ctx do
        for route <- @routes, elem(route, 0) == @router, fixture <- [ctx.p, ctx.a] do
          resp = request(route, fixture, ["PROCESS_DESIGNER"])
          label = "#{elem(route, 1)} #{elem(route, 3)}"

          assert resp.status == 403, label

          body = Jason.decode!(resp.resp_body)
          assert body["status"] == 403
          refute Map.has_key?(body, "items")
          refute resp.resp_body =~ ctx.a.tenant.slug
          refute resp.resp_body =~ ctx.b.tenant.slug
        end
      end

      test "pin unset: the would-be operator is denied 403 on every route (fail closed)", ctx do
        Fixture.unpin!()
        before = tenant_count()

        for route <- @routes, elem(route, 0) == @router do
          resp = request(route, ctx.p, ["PLATFORM_ADMIN"])
          assert resp.status == 403, "#{elem(route, 1)} #{elem(route, 3)}"
        end

        assert tenant_count() == before
      end
    end
  end

  describe "item 14: GET /tenants through the full pipeline (real bearer tokens)" do
    test "A's legacy PLATFORM_ADMIN token and A's TENANT_ADMIN get 403; P PLATFORM_ADMIN gets 200",
         ctx do
      token_a = mint_legacy_platform_admin_token!(ctx.a)
      token_a_admin = Fixture.mint_token!(ctx.a, ["TENANT_ADMIN"])
      token_p = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])

      resp_a =
        Fixture.api_conn(:get, "/api/v1/tenants", token_a, ctx.a.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert resp_a.status == 403
      refute resp_a.resp_body =~ ctx.b.tenant.slug
      refute resp_a.resp_body =~ ctx.p.tenant.slug

      resp_a_admin =
        Fixture.api_conn(:get, "/api/v1/tenants", token_a_admin, ctx.a.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert resp_a_admin.status == 403

      resp_p =
        Fixture.api_conn(:get, "/api/v1/tenants", token_p, ctx.p.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert resp_p.status == 200
    end

    test "a tenant-scope route is 200 for a TENANT_ADMIN and 403 for a legacy tenant PLATFORM_ADMIN",
         ctx do
      token_a = Fixture.mint_token!(ctx.a, ["TENANT_ADMIN"])
      legacy_a = mint_legacy_platform_admin_token!(ctx.a)

      resp =
        Fixture.api_conn(:get, "/api/v1/promotions", token_a, ctx.a.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert resp.status == 200

      legacy_resp =
        Fixture.api_conn(:get, "/api/v1/promotions", legacy_a, ctx.a.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert legacy_resp.status == 403
    end
  end

  describe "item 5(e): a token minted in tenant A presented with the platform tenant's slug" do
    test "is rejected 401 and does not reach any platform route", ctx do
      token_a = Fixture.mint_token!(ctx.a, ["TENANT_ADMIN"])

      token_p = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])

      for path <- [
            "/api/v1/tenants",
            "/api/v1/admin/services",
            "/api/v1/onboarding",
            "/api/v1/platform-migrations/rollouts/#{@unused_uuid}",
            "/api/v1/event-retention/summary"
          ] do
        resp =
          Fixture.api_conn(:get, path, token_a, ctx.p.tenant.slug, nil) |> Fixture.dispatch_api()

        assert resp.status == 401, "#{path}: #{resp.status}"

        # controls: the same token with its own slug is a 403 (authenticated, wrong scope), and the
        # platform tenant's own token with P's slug is authenticated (not 401, not 403)
        own =
          Fixture.api_conn(:get, path, token_a, ctx.a.tenant.slug, nil) |> Fixture.dispatch_api()

        assert own.status == 403, "#{path}: A's token with A's slug answered #{own.status}"

        operator =
          Fixture.api_conn(:get, path, token_p, ctx.p.tenant.slug, nil) |> Fixture.dispatch_api()

        refute operator.status in [401, 403], "#{path}: operator answered #{operator.status}"
      end
    end
  end
end
