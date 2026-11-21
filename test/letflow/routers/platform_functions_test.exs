defmodule Letflow.Routers.PlatformFunctionsTest do
  @moduledoc """
  The COMPILED platform function catalogue's READ route (T-2588, "Register a
  tenant" pilot, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (a)).

  The route exists so the designer can offer the platform functions a definition
  may call. It is a platform route: it needs `:TenantsManage`, the platform atom
  the tenant lifecycle routes already use, so only a PLATFORM_ADMIN of the
  PLATFORM TENANT reads it.

  The threat the negative tests answer: a company tenant learns which platform
  functions exist. A company administrator is refused with the uniform 403 of a
  denied route, and so is a company tenant whose stored token still carries
  `PLATFORM_ADMIN` -- outside the platform tenant that role holds nothing
  (REQ-447 PR 2), so the catalogue stays invisible to it (INV-10).

  Real Postgres, real tenant schemas, real API tokens through the real
  `Letflow.Router`. `async: false`: the platform pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @path "/api/v1/platform-functions"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)

    %{platform: tenants.p, company: tenants.a}
  end

  defp read(token, slug) do
    :get
    |> Fixture.api_conn(@path, token, slug, nil)
    |> Fixture.dispatch_api()
  end

  describe "the platform administrator of the platform tenant" do
    test "reads the catalogue", ctx do
      token = Fixture.mint_token!(ctx.platform, ["PLATFORM_ADMIN"])

      conn = read(token, ctx.platform.tenant.slug)

      assert conn.status == 200, conn.resp_body
      items = Jason.decode!(conn.resp_body)["items"]

      assert length(items) == 6
      assert Enum.map(items, & &1["name"]) == Enum.sort(Enum.map(items, & &1["name"]))

      for item <- items do
        assert item["permission"] == "TenantsManage"
        assert item["platform_tenant_only"] == true
      end
    end

    test "reads an entry that says how a repeat is recognised", ctx do
      token = Fixture.mint_token!(ctx.platform, ["PLATFORM_ADMIN"])

      conn = read(token, ctx.platform.tenant.slug)

      items = Jason.decode!(conn.resp_body)["items"]
      create = Enum.find(items, &(&1["name"] == "tenant.create"))

      assert create["idempotency_inputs"] == ["slug"]
    end
  end

  describe "a company tenant" do
    test "its administrator is refused the uniform 403", ctx do
      token = Fixture.mint_token!(ctx.company, ["TENANT_ADMIN"])

      conn = read(token, ctx.company.tenant.slug)

      assert conn.status == 403, conn.resp_body
    end

    test "a stored PLATFORM_ADMIN role holds nothing outside the platform tenant (INV-10)", ctx do
      # a raw token row: the role is in the token, the tenant is not the platform one
      token = Fixture.mint_token!(ctx.company, ["PLATFORM_ADMIN"])

      conn = read(token, ctx.company.tenant.slug)

      assert conn.status == 403, conn.resp_body

      # the refusal names no function: a company tenant cannot learn what exists
      refute conn.resp_body =~ "tenant.create"
      refute conn.resp_body =~ "tenant.validate"
    end
  end
end
