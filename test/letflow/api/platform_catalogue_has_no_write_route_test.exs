defmodule Letflow.Api.PlatformCatalogueHasNoWriteRouteTest do
  @moduledoc """
  S13 of the platform-call authority rule (T-2588, "Register a tenant" pilot, gap
  G2; decision record `docs/migration/decisions/0094-platform-call-authority.md`,
  decision (a)): the catalogue has NO write route.

  The threat S13 names: run-time catalogue tampering -- a person, not a review,
  decides what a function name does. It is the threat of option (b) of decision
  (a), and the mitigation is that the catalogue is COMPILED: an entry exists
  only if it is compiled into the build, and nothing in the HTTP surface can add
  one.

  The proof is the route inventory: the catalogue's mount holds one route, and
  it is a GET. A POST/PUT/PATCH/DELETE under the same prefix would be a write
  path, and this test fails if one ever appears.

  No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.Routers.PlatformFunctions
  alias Letflow.Support.RouteInventory

  @mount "/platform-functions"

  test "S13-a: the route inventory holds ONE catalogue route and it is a GET" do
    catalogue =
      for route <- RouteInventory.routes(),
          String.starts_with?(route.path, @mount),
          do: {route.method, route.path}

    assert catalogue == [{"GET", @mount}]
  end

  test "S13-b: the catalogue's router declares no write method at all" do
    for {method, _path, _key} <- PlatformFunctions.__authz_routes__() do
      assert method == "GET"
    end
  end

  test "S13-c: the catalogue is compiled into the build, and the entries are declarations only" do
    assert "tenant.create" in Catalog.names()

    {:ok, entry} = Catalog.fetch("tenant.create")
    assert entry.permission == :TenantsManage
    assert entry.platform_tenant_only == true
    assert entry.family == :platform
  end

  test "S13-d: an unknown function is not in the catalogue (nothing registers one at run time)" do
    assert {:error, :not_found} = Catalog.fetch("does.not_in_the_catalogue")
  end

  test "S13-e: a platform-only entry is hidden from a caller outside the platform tenant" do
    outside = Catalog.list(platform_tenant?: false)
    inside = Catalog.list(platform_tenant?: true)

    assert Enum.all?(outside, &(&1.platform_tenant_only == false))
    assert Enum.any?(inside, &(&1.platform_tenant_only == true))
  end
end
