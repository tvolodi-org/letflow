defmodule Letflow.Api.ImportAnyTypeScopeTest do
  @moduledoc """
  Roles stage 0 S0-1: the scope set of the import route for a type other than the opening line is
  computed for `:EntitiesRecordsImportAnyType`. It must equal what
  `ScopeGate.scope_set_without_role/3` (STOREKEEPER excluded) returned before, on every grant shape.

    * Q1 refused widening: a tenant-wide STOREKEEPER does not widen a scoped TENANT_ADMIN;
    * Q2 refused: a node-scoped STOREKEEPER holds nothing for the wide permission;
    * Q3 allowed: a tenant-wide TENANT_ADMIN gets `:all`;
    * Q4 allowed, scoped: a node-scoped TENANT_ADMIN gets its node;
    * Q5 not on: `:all` with the marker set.

  `async: false`: a real tenant with committed grant rows.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.Api.ScopeGate
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S

  @import :EntitiesRecordsImport
  @any :EntitiesRecordsImportAnyType

  setup do
    {:ok, fx: S.tenant!("t1853-any")}
  end

  defp conn_for(fx, user_id, roles, mode) do
    ctx = fx |> S.ctx(user_id, roles, :oidc) |> Map.put(:scope_enforcement, mode)

    :post
    |> Fixture.router_conn("/", fx, roles, nil)
    |> assign(:auth_context, ctx)
    |> assign(:scoped_opts, prefix: fx.schema_name)
  end

  # both sets for the same grants, from fresh conns (the memo is per conn)
  defp both(fx, user_id, roles, mode) do
    {_, new} = ScopeGate.scope_set(conn_for(fx, user_id, roles, mode), @any)

    {_, old} =
      ScopeGate.scope_set_without_role(conn_for(fx, user_id, roles, mode), @import, :STOREKEEPER)

    {new, old}
  end

  test "Q1 a tenant-wide STOREKEEPER does not widen a scoped TENANT_ADMIN", %{fx: fx} do
    s = fx.schema_name
    user = RSG.user!(s)
    node = RSG.node!(s)
    :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", node)
    :ok = RSG.raw_user_row!(s, user.id, "STOREKEEPER", nil)
    roles = ["TENANT_ADMIN", "STOREKEEPER"]

    # the widening, for the opening-line key
    assert {_, :all} = ScopeGate.scope_set(conn_for(fx, user.id, roles, :on), @import)

    {new, old} = both(fx, user.id, roles, :on)
    assert {:nodes, ids} = new
    assert node in ids
    assert new == old
  end

  test "Q2 a node-scoped STOREKEEPER holds nothing for the wide permission", %{fx: fx} do
    s = fx.schema_name
    user = RSG.user!(s)
    node = RSG.node!(s)
    :ok = RSG.raw_user_row!(s, user.id, "STOREKEEPER", node)

    {new, old} = both(fx, user.id, ["STOREKEEPER"], :on)
    assert new == :none
    assert new == old
  end

  test "Q3 a tenant-wide TENANT_ADMIN gets :all next to a node-scoped STOREKEEPER", %{fx: fx} do
    s = fx.schema_name
    user = RSG.user!(s)
    node = RSG.node!(s)
    :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", nil)
    :ok = RSG.raw_user_row!(s, user.id, "STOREKEEPER", node)

    {new, old} = both(fx, user.id, ["TENANT_ADMIN", "STOREKEEPER"], :on)
    assert new == :all
    assert new == old
  end

  test "Q4 a node-scoped TENANT_ADMIN gets its node", %{fx: fx} do
    s = fx.schema_name
    user = RSG.user!(s)
    node = RSG.node!(s)
    :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", node)

    {new, old} = both(fx, user.id, ["TENANT_ADMIN"], :on)
    assert {:nodes, ids} = new
    assert node in ids
    assert new == old
  end

  test "Q5 not on: :all and the marker is set", %{fx: fx} do
    conn = conn_for(fx, Ecto.UUID.generate(), ["TENANT_ADMIN", "STOREKEEPER"], :off)
    assert {conn, :all} = ScopeGate.scope_set(conn, @any)
    assert ScopeGate.applied?(conn)
  end
end
