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

  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @path "/api/v1/platform-functions"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)

    %{platform: tenants.p, company: tenants.a}
  end

  defp read(token, slug, suffix \\ "") do
    :get
    |> Fixture.api_conn(@path <> suffix, token, slug, nil)
    |> Fixture.dispatch_api()
  end

  describe "the platform administrator of the platform tenant" do
    test "reads the catalogue", ctx do
      token = Fixture.mint_token!(ctx.platform, ["PLATFORM_ADMIN"])

      conn = read(token, ctx.platform.tenant.slug)

      assert conn.status == 200, conn.resp_body
      items = Jason.decode!(conn.resp_body)["items"]

      # The count is DERIVED from the compiled catalogue (seven entries today:
      # the pilot's tenant family of six plus the registration family's
      # `platform.validate_registration`), not pinned as a literal: the
      # catalogue grows with every family, and the invariant this route
      # carries is "the platform administrator reads EXACTLY the compiled
      # catalogue -- nothing more, nothing less". The catalogue's own set is
      # pinned in `test/letflow/platform_functions/catalog_test.exs`.
      assert length(items) == length(Catalog.names())
      assert Enum.map(items, & &1["name"]) == Catalog.names()
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

  describe "an unmatched path under the mount" do
    # INV-8: Plug's generated `do_match/4` has one clause per route and NO fallback, so a
    # mount without the `authz_unmatched/1` catch-all RAISES on an unmatched path instead of
    # answering. The catch-all answers the uniform 403 for a non-operator and the router's
    # zero-detail 404 for the platform tenant's operator.
    test "a company tenant is refused with the uniform 403, naming no function", ctx do
      token = Fixture.mint_token!(ctx.company, ["TENANT_ADMIN"])

      conn = read(token, ctx.company.tenant.slug, "/a/b/c")

      assert conn.status == 403, conn.resp_body
      refute conn.resp_body =~ "tenant.create"
    end

    test "the platform administrator of the platform tenant gets the zero-detail 404", ctx do
      token = Fixture.mint_token!(ctx.platform, ["PLATFORM_ADMIN"])

      conn = read(token, ctx.platform.tenant.slug, "/a/b/c")

      assert conn.status == 404, conn.resp_body

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 404
      assert body["title"] == "Not Found"
      refute conn.resp_body =~ "tenant.create"
    end
  end
end
