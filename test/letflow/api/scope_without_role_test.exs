defmodule Letflow.Api.ScopeWithoutRoleTest do
  @moduledoc """
  T-1317 / D-093 / decision 0081 D4: `Letflow.Api.ScopeGate.scope_set_without_role/3`.

    * S-1 a TENANT_ADMIN scoped to one node who also holds a tenant-wide STOREKEEPER: the union
      scope for the import permission is `:all` (the widening), the set without STOREKEEPER is the
      admin's own nodes, so an import of another type stays inside the admin's node;
    * S-2 a node-scoped STOREKEEPER (D-067) is narrowed on the stock read permission and on the
      import permission to its node (never `:all`);
    * S-3 not `on` -> `:all` with the marker set.

  `async: false`: a real tenant with committed grant rows.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.Api.ScopeGate
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @import :EntitiesRecordsImport

  setup do
    {:ok, fx: S.tenant!("t1317-sw")}
  end

  defp conn_for(fx, user_id, roles, mode) do
    ctx = fx |> S.ctx(user_id, roles, :oidc) |> Map.put(:scope_enforcement, mode)

    :post
    |> Fixture.router_conn("/", fx, roles, nil)
    |> assign(:auth_context, ctx)
    |> assign(:scoped_opts, prefix: fx.schema_name)
  end

  test "S-1 a tenant-wide STOREKEEPER does not widen a scoped TENANT_ADMIN's import scope", %{
    fx: fx
  } do
    s = fx.schema_name
    user = RSG.user!(s)
    node = RSG.node!(s)
    :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", node)
    :ok = RSG.raw_user_row!(s, user.id, "STOREKEEPER", nil)
    roles = ["TENANT_ADMIN", "STOREKEEPER"]

    # the union: the widening the security review found
    assert {_, :all} = ScopeGate.scope_set(conn_for(fx, user.id, roles, :on), @import)

    assert {_, {:nodes, ids}} =
             ScopeGate.scope_set_without_role(
               conn_for(fx, user.id, roles, :on),
               @import,
               :STOREKEEPER
             )

    assert node in ids
  end

  test "S-2 a node-scoped STOREKEEPER sees only its node on stock read and on import", %{fx: fx} do
    s = fx.schema_name
    user = RSG.user!(s)
    node = RSG.node!(s)
    :ok = RSG.raw_user_row!(s, user.id, "STOREKEEPER", node)

    for key <- [:StockRead, @import] do
      assert {_, {:nodes, ids}} =
               ScopeGate.scope_set(conn_for(fx, user.id, ["STOREKEEPER"], :on), key)

      assert node in ids
    end

    # without the role it holds nothing (it is the only import role)
    assert {_, :none} =
             ScopeGate.scope_set_without_role(
               conn_for(fx, user.id, ["STOREKEEPER"], :on),
               @import,
               :STOREKEEPER
             )
  end

  test "S-3 not on: :all and the marker is set", %{fx: fx} do
    conn = conn_for(fx, Ecto.UUID.generate(), ["STOREKEEPER"], :off)
    assert {conn, :all} = ScopeGate.scope_set_without_role(conn, @import, :STOREKEEPER)
    assert ScopeGate.applied?(conn)
  end
end
