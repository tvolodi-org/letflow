defmodule Letflow.Api.AuthorizationOverlayTest do
  @moduledoc "T-1570 (D-097) A1..A3 and G6: the pure grant overlay; baseline unchanged, closed list."

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.TenantGrants

  @assets [:AssetsRead, :AssetsPost, :AssetsReverse, :AssetsReconcile, :AssetsCardWrite]

  test "A1 an empty overlay equals the baseline for every role and permission" do
    for role <- Authorization.roles(), p <- Authorization.permissions() do
      assert Authorization.role_allows?(role, p, %{}) == Authorization.role_allows?(role, p)
    end

    for p <- Authorization.permissions(), plat <- [true, false] do
      assert Authorization.has_permission_in_scope?([:STOREKEEPER], p, plat, %{}) ==
               Authorization.has_permission_in_scope?([:STOREKEEPER], p, plat)
    end
  end

  test "A2 the baseline storekeeper holds no asset atom; the overlay adds read and post only" do
    overlay = %{STOREKEEPER: [:AssetsRead, :AssetsPost]}

    for p <- @assets, do: refute(Authorization.role_allows?(:STOREKEEPER, p), inspect(p))

    assert Authorization.role_allows?(:STOREKEEPER, :AssetsRead, overlay)
    assert Authorization.role_allows?(:STOREKEEPER, :AssetsPost, overlay)

    for p <- [:AssetsReverse, :AssetsReconcile, :AssetsCardWrite],
        do: refute(Authorization.role_allows?(:STOREKEEPER, p, overlay), inspect(p))
  end

  test "A3 anything outside grantable/0 is ignored: other roles, other atoms, bad shapes" do
    wide = %{
      STOREKEEPER: [:AssetsReverse, :AssetsReconcile, :AssetsCardWrite, :TenantsManage],
      TASK_WORKER: [:AssetsRead],
      CANDIDATE: [:AssetsRead, :AssetsPost]
    }

    assert Authorization.sanitize_overlay(wide) == %{}
    assert Authorization.sanitize_overlay(nil) == %{}
    assert Authorization.sanitize_overlay(%{STOREKEEPER: :all}) == %{}
    refute Authorization.role_allows?(:TASK_WORKER, :AssetsRead, wide)
    refute Authorization.role_allows?(:STOREKEEPER, :TenantsManage, wide)
  end

  test "G6 every role x asset atom, overlay off and on: only the storekeeper's read and post move" do
    on = %{STOREKEEPER: [:AssetsRead, :AssetsPost]}

    for role <- Authorization.roles(), p <- @assets do
      assert Authorization.role_allows?(role, p, %{}) == Authorization.role_allows?(role, p)

      expected =
        Authorization.role_allows?(role, p) or
          (role == :STOREKEEPER and p in [:AssetsRead, :AssetsPost])

      assert Authorization.role_allows?(role, p, on) == expected, "#{role} #{p}"
    end
  end

  test "evaluate_access is a pure function of the context, the overlay included" do
    ctx = %AccessContext{user_id: "u", roles: [:STOREKEEPER]}
    assert Authorization.evaluate_access(ctx, :AssetsRead).kind == :Deny403

    on = %{ctx | role_overlay: %{STOREKEEPER: [:AssetsRead]}}
    assert Authorization.evaluate_access(on, :AssetsRead).kind == :Allow
    assert Authorization.evaluate_access(on, :AssetsPost).kind == :Deny403
    assert Authorization.evaluate_access(on, :RoleGrantsManage).kind == :Deny403
  end

  test "stored settings map to atoms through the closed list only" do
    assert TenantGrants.overlay_from_settings(%{
             "storekeeper_grants" => ["AssetsPost", "AssetsRead"]
           }) ==
             %{STOREKEEPER: [:AssetsRead, :AssetsPost]}

    assert TenantGrants.overlay_from_settings(%{"storekeeper_grants" => ["AssetsReverse", "x"]}) ==
             %{}

    assert TenantGrants.overlay_from_settings(%{"storekeeper_grants" => "AssetsRead"}) == %{}
    assert TenantGrants.overlay_from_settings(%{}) == %{}
    assert TenantGrants.overlay_from_settings(nil) == %{}
  end
end
