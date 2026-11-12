defmodule Letflow.Api.ModuleGuardTest do
  @moduledoc """
  CORE slice S8 canary: `Letflow.Api.ModuleGuard.check/2`, the guard moved out of
  `Assets.Access` and `Stock.Access`. Conns carry a hand-built `auth_context` with pre-loaded
  grants, so no database row is read. The old per-module guards must give the same answers
  (both now delegate here).
  """

  use ExUnit.Case, async: false

  alias Letflow.Api.Authorization
  alias Letflow.Api.ModuleGuard
  alias Letflow.Api.Scope.Grants
  alias Letflow.Modules.Assets.Access, as: AssetsAccess
  alias Letflow.Modules.Stock.Access, as: StockAccess

  @tenant "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f"
  @prefix "tenant_9c1d2e3f4a5b4c6d8e7f0a1b2c3d4e5f"
  @user "44444444-4444-4444-8444-444444444444"

  defp grants(user, rows), do: %Grants{user_id: user, rows_by_role: rows}

  defp tw_rows(role),
    do: %{role => [%{principal_type: :user, tenant_wide: true, scope_node_id: nil}]}

  defp conn(opts) do
    role = Keyword.get(opts, :role, "TENANT_ADMIN")
    user = Keyword.get(opts, :user_id, @user)

    ctx = %{
      credential: Keyword.get(opts, :credential, :oidc),
      user_id: user,
      tenant_id: @tenant,
      roles: [role],
      scope_grants: Keyword.get(opts, :grants, grants(user, tw_rows(role)))
    }

    %Plug.Conn{}
    |> Plug.Conn.assign(:auth_context, ctx)
    |> Plug.Conn.assign(:scoped_opts, prefix: Keyword.get(opts, :prefix, @prefix))
    |> Plug.Conn.assign(:role_overlay, Keyword.get(opts, :overlay, %{}))
  end

  test "an interactive user whose role holds the permission tenant-wide is allowed" do
    for p <- [:AssetsRead, :AssetsCardWrite, :StockRead, :StockPost] do
      assert {:ok, %{prefix: @prefix, actor_id: @user}} = ModuleGuard.check(conn([]), p), "#{p}"
    end
  end

  test "an API token is refused even with a role that holds the permission" do
    c = conn(credential: :api_token, grants: :token)
    assert :error = ModuleGuard.check(c, :AssetsRead)
  end

  test "no principal (no auth_context) is refused" do
    assert :error = ModuleGuard.check(%Plug.Conn{}, :AssetsRead)
  end

  test "a role without the permission is refused" do
    c = conn(role: "TASK_WORKER")
    assert :error = ModuleGuard.check(c, :AssetsRead)
    assert :error = ModuleGuard.check(c, :StockPost)
  end

  test "the tenant overlay grants the storekeeper read and post, nothing else" do
    base = conn(role: "STOREKEEPER")
    assert :error = ModuleGuard.check(base, :AssetsRead)

    on = conn(role: "STOREKEEPER", overlay: %{STOREKEEPER: [:AssetsRead, :AssetsPost]})
    assert {:ok, _} = ModuleGuard.check(on, :AssetsRead)
    assert {:ok, _} = ModuleGuard.check(on, :AssetsPost)
    assert :error = ModuleGuard.check(on, :AssetsReverse)
  end

  test "a grant that is not tenant-wide is refused: the guard needs tenant-wide" do
    scoped = %{
      "TENANT_ADMIN" => [%{principal_type: :user, tenant_wide: false, scope_node_id: nil}]
    }

    assert :error = ModuleGuard.check(conn(grants: grants(@user, scoped)), :AssetsRead)
  end

  test "a ScopeSetError fails closed to :error" do
    bad = %{
      "TENANT_ADMIN" => [%{principal_type: :user, tenant_wide: false, scope_node_id: :not_an_id}]
    }

    assert :error = ModuleGuard.check(conn(grants: grants(@user, bad)), :AssetsRead)
  end

  test "a user id that is not a uuid is refused" do
    c = conn(user_id: "not-a-uuid")
    assert :error = ModuleGuard.check(c, :AssetsRead)
  end

  test "the prefix is the plug's, a mismatch with the tenant is refused (INV-10)" do
    assert :error = ModuleGuard.check(conn(prefix: "tenant_other"), :AssetsRead)
  end

  test "Authorization.grantable/0 holds no Stock atom (role_allows?/2 equals /3 for Stock)" do
    atoms = Authorization.grantable() |> Map.values() |> List.flatten()
    refute Enum.any?(atoms, &String.starts_with?(Atom.to_string(&1), "Stock"))
  end

  test "both module guards answer exactly as the shared guard" do
    ok = conn([])
    assert AssetsAccess.check(ok, :read) == ModuleGuard.check(ok, :AssetsRead)
    assert AssetsAccess.check(ok) == ModuleGuard.check(ok, :AssetsCardWrite)
    assert StockAccess.check(ok, :post) == ModuleGuard.check(ok, :StockPost)
    assert StockAccess.check(ok, :reverse) == ModuleGuard.check(ok, :StockReverse)

    worker = conn(role: "TASK_WORKER")
    assert :error = AssetsAccess.check(worker, :read)
    assert :error = StockAccess.check(worker, :read)
  end
end
