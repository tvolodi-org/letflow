defmodule Letflow.Routers.Req442ModeExposureTest do
  @moduledoc """
  REQ-442 AC3 / INV-2: `login_disclosure_mode` must not appear, at byte level, in
  any pre-authentication, tenant-admin-readable or ordinary-user tenant response,
  for a tenant with the value unset and set to each mode. The platform-admin
  shape (which MAY carry it) is covered in `req442_tenants_mode_test.exs`.
  See `test/specs/REQ-442.md`.

  The assertion is a raw-body substring search (not a decoded-key check) for BOTH
  the attribute name and the two mode values, so a leak under a renamed key, in a
  nested map or inside a string would still be caught.

  `async: false`: provisions real tenant schemas (`Sandbox.mode(:auto)`).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture

  @router_opts Letflow.Router.init([])
  @states [nil, "uniform_plus_email", "redirect_single"]
  @forbidden ["login_disclosure_mode", "uniform_plus_email", "redirect_single"]

  defp assert_no_mode_bytes(body, context) do
    assert is_binary(body)

    for needle <- @forbidden do
      refute body =~ needle, "#{context}: response body leaks #{inspect(needle)}: #{body}"
    end
  end

  defp set_mode!(tenant_id, mode) do
    {1, _} =
      Repo.update_all(from(t in Tenant, where: t.id == ^tenant_id),
        set: [login_disclosure_mode: mode]
      )

    :ok
  end

  defp insert_bound_tenant!(prefix) do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug(prefix),
        display_name: "REQ-442 exposure",
        idp_realm_id: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp get_public(path) do
    conn = conn(:get, path)
    assert get_req_header(conn, "authorization") == []
    Letflow.Router.call(conn, @router_opts)
  end

  describe "pre-authentication endpoints" do
    for state <- @states do
      test "GET /api/tenant-config?realm=<slug> with mode #{inspect(state)}: exactly the four keys, no mode bytes" do
        tenant = insert_bound_tenant!("req442-tc")
        set_mode!(tenant.id, unquote(state))

        conn = get_public("/api/tenant-config?realm=#{URI.encode_www_form(tenant.slug)}")

        assert conn.status == 200

        assert Jason.decode!(conn.resp_body) |> Map.keys() |> Enum.sort() ==
                 ["branding", "client_id", "oidc_authority", "tenant_type"]

        assert_no_mode_bytes(conn.resp_body, "tenant-config")
      end

      test "GET /api/mobile/tenant-config?slug=<slug> with mode #{inspect(state)}: exact shape, no mode bytes" do
        tenant = insert_bound_tenant!("req442-mtc")
        set_mode!(tenant.id, unquote(state))

        conn = get_public("/api/mobile/tenant-config?slug=#{URI.encode_www_form(tenant.slug)}")

        assert conn.status == 200

        assert Jason.decode!(conn.resp_body) |> Map.keys() |> Enum.sort() ==
                 [
                   "branding",
                   "client_id",
                   "default_locale",
                   "environment_kind",
                   "locales",
                   "realm_url"
                 ]

        assert_no_mode_bytes(conn.resp_body, "mobile tenant-config")
      end
    end

    test "the default (no realm / unknown realm) responses carry no mode bytes either" do
      for path <- [
            "/api/tenant-config",
            "/api/tenant-config?realm=does-not-exist-442",
            "/api/mobile/tenant-config",
            "/api/mobile/tenant-config?slug=does-not-exist-442"
          ] do
        conn = get_public(path)
        assert_no_mode_bytes(conn.resp_body, path)
      end
    end
  end

  describe "tenant-admin write path: PATCH /tenant/settings response" do
    for state <- @states do
      test "with stored mode #{inspect(state)}: response and the persisted settings blob carry no mode bytes" do
        t = TenantFixture.provisioned_tenant!(slug_prefix: "req442-ts")
        set_mode!(t.tenant_id, unquote(state))

        resp =
          conn(:patch, "/")
          |> Map.put(:body_params, %{"app_name" => "Exposure 442"})
          |> put_req_header("content-type", "application/json")
          |> assign(:auth_context, %{
            user_id: Ecto.UUID.generate(),
            tenant_id: t.tenant_id,
            roles: ["TENANT_ADMIN"]
          })
          |> assign(:trace_id, "req442-exposure-trace")
          |> Letflow.Routers.TenantSettings.call(Letflow.Routers.TenantSettings.init([]))

        assert resp.status == 200
        assert Jason.decode!(resp.resp_body)["settings"]["app_name"] == "Exposure 442"
        assert_no_mode_bytes(resp.resp_body, "tenant settings PATCH")

        assert_no_mode_bytes(
          Jason.encode!(Repo.get!(Tenant, t.tenant_id).settings),
          "stored settings blob"
        )

        # the mode column itself is untouched by the tenant-admin path
        assert Repo.get!(Tenant, t.tenant_id).login_disclosure_mode == unquote(state)
      end
    end
  end

  describe "ordinary authenticated users: GET /me/memberships" do
    for state <- @states do
      test "with stored mode #{inspect(state)}: home tenant and membership entries carry no mode bytes" do
        suffix = System.unique_integer([:positive])

        %{tenant_id: tenant_id, schema_name: schema_name} =
          TenantFixture.provisioned_tenant!(slug_prefix: "req442-me-#{suffix}")

        set_mode!(tenant_id, unquote(state))

        assert {:ok, user} =
                 Identity.create_user(
                   %{
                     "username" => "req442-user-#{suffix}",
                     "display_name" => "REQ-442 User",
                     "email" => "req442-user-#{suffix}@example.com"
                   },
                   prefix: schema_name,
                   tenant_id: tenant_id
                 )

        for roles <- [
              ["PROCESS_OPERATOR"],
              ["TENANT_ADMIN"],
              ["PLATFORM_ADMIN"],
              ["TASK_WORKER"]
            ] do
          resp =
            conn(:get, "/memberships")
            |> assign(:auth_context, %{user_id: user.id, tenant_id: tenant_id, roles: roles})
            |> assign(:trace_id, "req442-me-trace")
            |> Letflow.Routers.Me.call(Letflow.Routers.Me.init([]))

          # PROCESS_OPERATOR must really get the 200 shape (so the refute is not vacuous);
          # the other roles may be refused by the permission model -- no mode bytes either way.
          if roles == ["PROCESS_OPERATOR"], do: assert(resp.status == 200)
          assert resp.status in [200, 403]
          assert_no_mode_bytes(resp.resp_body, "me/memberships #{inspect(roles)}")
        end
      end
    end
  end
end
