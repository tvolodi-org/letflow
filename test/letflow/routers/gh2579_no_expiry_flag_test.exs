defmodule Letflow.Routers.Gh2579NoExpiryFlagTest do
  @moduledoc """
  GH 2579 (T11): the token list (`GET /tokens`) flags a PLATFORM_ADMIN token with no expiry with
  `"no_expiry": true`, and reports `false` for every other token. The flag is additive to the
  item shape pinned by `identity_test.exs` and `tenant_scope_enforcement_test.exs`.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TokenMintFixture, as: Mint

  @trace "gh2579-trace-0001"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    tenants
  end

  defp call_as(method, path, fx, user_id, roles, body) do
    method
    |> Fixture.router_conn(path, fx, roles, body)
    |> Plug.Conn.assign(:auth_context, %{user_id: user_id, tenant_id: fx.tenant_id, roles: roles})
    |> Plug.Conn.assign(:trace_id, @trace)
    |> Letflow.Routers.Identity.call(Letflow.Routers.Identity.init([]))
  end

  test "T11: GET /tokens sets no_expiry true only for a non-expiring PLATFORM_ADMIN token", %{
    p: p
  } do
    caller = Mint.role_holder!(p.schema_name, ["TENANT_ADMIN", "PLATFORM_ADMIN"])
    owner = Mint.role_holder!(p.schema_name, ["PLATFORM_ADMIN"])

    expires_at =
      DateTime.utc_now() |> DateTime.add(30 * 86_400, :second) |> DateTime.truncate(:second)

    {:ok, %{token: legacy}} =
      Identity.create_token(owner.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
        prefix: p.schema_name
      )

    {:ok, %{token: expiring}} =
      Identity.mint_token(
        owner.id,
        owner.id,
        %{roles: ["PLATFORM_ADMIN"], expires_at: expires_at},
        prefix: p.schema_name
      )

    {:ok, %{token: no_expiry_other_role}} =
      Identity.create_token(owner.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: p.schema_name
      )

    conn = call_as(:get, "/tokens", p, caller.id, ["TENANT_ADMIN", "PLATFORM_ADMIN"], nil)
    assert conn.status == 200, conn.resp_body

    items = Map.new(Jason.decode!(conn.resp_body)["items"], &{&1["id"], &1})

    assert items[legacy.id]["no_expiry"] == true
    assert items[expiring.id]["no_expiry"] == false
    assert items[no_expiry_other_role.id]["no_expiry"] == false
  end
end
