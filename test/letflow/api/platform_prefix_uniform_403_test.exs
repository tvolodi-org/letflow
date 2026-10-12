defmodule Letflow.Api.PlatformPrefixUniform403Test do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 19, NAMED TEST `uniform_403_platform_prefixes_for_non_operators`,
  A2 ENFORCING variant (spec `test/specs/ISS-0993-A2.md`): the five platform prefixes
  (`/tenants`, `/onboarding`, `/platform-migrations`, `/event-retention`, `/admin/services`).

  For each NON-operator caller

    * A's `PLATFORM_ADMIN` (platform tenant configured, A is not it),
    * A's `PROCESS_DESIGNER`,
    * P's `PROCESS_DESIGNER`,
    * P's `PLATFORM_ADMIN` with no platform tenant configured (nobody is the operator),

  and each prefix, the requests

    (a) a matched platform route with an EXISTING resource (for `/tenants`, B's slug and, as the
  tenant-admin case of item 5(a), A's OWN slug on GET, PATCH, deactivate and reactivate),
    (b) a matched platform route with a NONEXISTENT resource id or slug,
    (c) an unmatched sub-path,
    (d) a bare unmatched path directly under the prefix,

  all return status 403 with byte-identical bodies and the same content-type header (the request-id
  header is excluded), so a non-operator learns nothing from the shape of the answer, and no row
  changes: the tenant registry rows and the service catalogue are snapshotted around every caller.
  Mutating methods are included in the matched-route shapes (a state change on an existing resource
  is the case where a leak would hurt). Row 34 (the promote route) is not a platform route and is
  covered by `promote_source_tenant_test.exs` and `promotion_scope_test.exs`.

  Companion cases: the platform tenant's `PLATFORM_ADMIN` is NOT given a 403 on an unmatched path
  under any of the five prefixes (it keeps the router's zero-detail 404), and neither is the
  platform tenant's `PLATFORM_ADMIN` under an ordinary router (`:UnmatchedRoute`), where every
  other caller gets 403 (REQ-447 PR 2: that includes a `PLATFORM_ADMIN` of an ordinary tenant and a
  `TENANT_ADMIN` of any tenant).
  The `:UnmatchedPlatformPath` / `:UnmatchedRoute` decision grid (roles x `platform_tenant?`) is
  covered by `authorization_test.exs`.

  INV-5 / INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @unused_uuid "00000000-0000-4000-8000-000000000003"

  # {router, [{label, method, path, body}]} -- the four request shapes per prefix
  # (a: existing resource, also with a mutating method; b: nonexistent; c: unmatched sub-path;
  # d: bare unmatched path).
  defp prefix_shapes(ctx) do
    [
      {Letflow.Routers.Tenants,
       [
         {:matched_existing, :get, "/" <> ctx.b.tenant.slug, nil},
         {:matched_existing_mutating, :post, "/" <> ctx.b.tenant.slug <> "/deactivate", nil},
         {:matched_existing_patch, :patch, "/" <> ctx.b.tenant.slug,
          %{"display_name" => "Hijacked"}},
         # A's OWN slug (design item 5(a): "including when the path slug is A's own slug")
         {:own_slug_get, :get, "/" <> ctx.a.tenant.slug, nil},
         {:own_slug_patch, :patch, "/" <> ctx.a.tenant.slug, %{"display_name" => "Self Rename"}},
         {:own_slug_deactivate, :post, "/" <> ctx.a.tenant.slug <> "/deactivate", nil},
         {:own_slug_reactivate, :post, "/" <> ctx.a.tenant.slug <> "/reactivate", nil},
         {:matched_nonexistent, :get, "/no-such-slug", nil},
         {:unmatched_subpath, :get, "/x/y/z/w", nil},
         {:unmatched_bare, :delete, "/", nil}
       ]},
      {Letflow.Routers.Onboarding,
       [
         {:matched_existing, :get, "/", nil},
         {:matched_existing_mutating, :post, "/",
          %{"slug" => "uniform-403-created", "display_name" => "Uniform 403"}},
         {:matched_nonexistent, :get, "/" <> @unused_uuid, nil},
         {:matched_bind_realm, :post, "/" <> @unused_uuid <> "/bind-realm",
          %{"idp_realm_id" => "iss1030-uniform-403"}},
         {:unmatched_subpath, :get, "/x/y/z/w", nil},
         {:unmatched_bare, :delete, "/", nil}
       ]},
      {Letflow.Routers.PlatformMigrations,
       [
         {:matched_existing, :get, "/rollouts/" <> @unused_uuid, nil},
         {:matched_existing_mutating, :post, "/rollouts", %{}},
         {:matched_nonexistent, :post, "/rollouts/" <> @unused_uuid <> "/resume", nil},
         {:unmatched_subpath, :get, "/x/y/z/w", nil},
         {:unmatched_bare, :delete, "/", nil}
       ]},
      {Letflow.Routers.EventRetention,
       [
         {:matched_existing, :get, "/summary", nil},
         {:matched_existing_mutating, :post, "/retirements", %{}},
         {:matched_nonexistent, :get, "/retirements/" <> @unused_uuid, nil},
         {:unmatched_subpath, :get, "/x/y/z/w", nil},
         {:unmatched_bare, :delete, "/", nil}
       ]},
      {Letflow.Routers.AdminServices,
       [
         {:matched_existing, :get, "/", nil},
         {:matched_existing_mutating, :post, "/", %{}},
         {:matched_nonexistent, :patch, "/no-such-service", %{}},
         {:matched_nonexistent_delete, :delete, "/no-such-service", nil},
         {:unmatched_subpath, :get, "/x/y/z/w", nil},
         {:unmatched_bare, :delete, "/", nil}
       ]}
    ]
  end

  # {label, fixture selector, roles, pinned?}
  defp callers(ctx) do
    [
      {"A PLATFORM_ADMIN", ctx.a, ["PLATFORM_ADMIN"], true},
      {"A PROCESS_DESIGNER", ctx.a, ["PROCESS_DESIGNER"], true},
      {"P PROCESS_DESIGNER", ctx.p, ["PROCESS_DESIGNER"], true},
      {"P PLATFORM_ADMIN, platform tenant not configured", ctx.p, ["PLATFORM_ADMIN"], false}
    ]
  end

  defp dispatch(router, conn), do: router.call(conn, router.init([]))

  defp send_request(router, {_label, method, path, body}, fixture, roles) do
    dispatch(router, Fixture.router_conn(method, path, fixture, roles, body))
  end

  defp set_pin(ctx, true), do: Fixture.pin!(ctx.p.tenant_id)
  defp set_pin(_ctx, false), do: Fixture.unpin!()

  # Every row a platform route could write that a test can observe from here.
  defp state_snapshot do
    tenants =
      Tenant
      |> Repo.all()
      |> Enum.map(&{&1.id, &1.slug, &1.display_name, &1.status, &1.updated_at})
      |> Enum.sort()

    %{rows: [[services]]} = Repo.query!("SELECT count(*) FROM service_catalog")
    %{tenants: tenants, services: services}
  end

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  test "uniform_403_platform_prefixes_for_non_operators", ctx do
    before = state_snapshot()

    for {caller, fixture, roles, pinned?} <- callers(ctx),
        {router, shapes} <- prefix_shapes(ctx) do
      set_pin(ctx, pinned?)

      responses =
        for shape <- shapes, do: {elem(shape, 0), send_request(router, shape, fixture, roles)}

      for {label, resp} <- responses do
        assert resp.status == 403,
               "#{caller} #{inspect(router)} #{label}: expected 403, got #{resp.status}"
      end

      bodies = responses |> Enum.map(fn {_l, r} -> r.resp_body end) |> Enum.uniq()

      types =
        responses |> Enum.map(fn {_l, r} -> get_resp_header(r, "content-type") end) |> Enum.uniq()

      assert length(bodies) == 1,
             "#{caller} #{inspect(router)}: the 403 bodies differ between request shapes: #{inspect(bodies)}"

      assert [[type]] = types
      assert type =~ "application/problem+json"

      body = Jason.decode!(hd(bodies))
      assert body["status"] == 403

      for secret <- [ctx.a.tenant_id, ctx.b.tenant_id, ctx.p.tenant_id, ctx.b.tenant.slug] do
        refute hd(bodies) =~ secret, "#{caller} #{inspect(router)}: the 403 leaks an identifier"
      end

      assert state_snapshot() == before,
             "#{caller} #{inspect(router)}: a request changed a row"
    end
  end

  test "the 403 is the same bytes for every non-operator caller and every prefix shape", ctx do
    all =
      for {_caller, fixture, roles, pinned?} <- callers(ctx),
          {router, shapes} <- prefix_shapes(ctx),
          shape <- shapes do
        set_pin(ctx, pinned?)
        resp = send_request(router, shape, fixture, roles)
        {resp.status, resp.resp_body, get_resp_header(resp, "content-type")}
      end

    assert all |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == [403]
    assert length(Enum.uniq(all)) == 1
  end

  describe "companions" do
    test "the platform tenant's PLATFORM_ADMIN keeps the router's 404 on an unmatched path under each prefix",
         ctx do
      for {router, shapes} <- prefix_shapes(ctx),
          {label, method, path, body} <-
            Enum.filter(shapes, &(elem(&1, 0) in [:unmatched_subpath, :unmatched_bare])) ++
              [{:unmatched_post, :post, "/x/y/z/w", %{}}] do
        resp =
          dispatch(router, Fixture.router_conn(method, path, ctx.p, ["PLATFORM_ADMIN"], body))

        assert resp.status == 404, "#{inspect(router)} operator #{label}: #{resp.status}"
        refute resp.status == 403
      end
    end

    test "the operator's 404 is the zero-detail not-found response", ctx do
      resp =
        dispatch(
          Letflow.Routers.Tenants,
          Fixture.router_conn(:get, "/x/y/z/w", ctx.p, ["PLATFORM_ADMIN"], nil)
        )

      body = Jason.decode!(resp.resp_body)
      assert body["status"] == 404
      assert body["title"] == "Not Found"
    end

    test "ordinary routers (:UnmatchedRoute): only the platform tenant's PLATFORM_ADMIN reaches the 404, every other caller gets 403",
         ctx do
      ordinary = [
        Letflow.Routers.Identity,
        Letflow.Routers.Audit,
        Letflow.Routers.Definitions,
        Letflow.Routers.Promotions,
        Letflow.Routers.Services,
        Letflow.Routers.TenantSettings
      ]

      for router <- ordinary, fixture <- [ctx.a, ctx.p] do
        admin =
          dispatch(
            router,
            Fixture.router_conn(:get, "/x/y/z/w", fixture, ["PLATFORM_ADMIN"], nil)
          )

        # REQ-447 PR 2: the 404 pass-through is the PLATFORM tenant's PLATFORM_ADMIN only (ctx.p is
        # pinned); an ordinary tenant's PLATFORM_ADMIN holds nothing and is denied (legacy removed).
        expected_admin_status = if fixture == ctx.p, do: 404, else: 403

        assert admin.status == expected_admin_status,
               "#{inspect(router)} PLATFORM_ADMIN: #{admin.status}"

        for role <- ["PROCESS_DESIGNER", "TENANT_ADMIN"] do
          denied =
            dispatch(router, Fixture.router_conn(:get, "/x/y/z/w", fixture, [role], nil))

          assert denied.status == 403, "#{inspect(router)} #{role}: #{denied.status}"
        end
      end
    end
  end
end
