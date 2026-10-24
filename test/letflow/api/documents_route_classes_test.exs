defmodule Letflow.Api.DocumentsRouteClassesTest do
  @moduledoc """
  REQ-536 / GH #3106, criteria 6 and 11 (decision 0063 S7, S8; test A9; design
  state/tasks/T-0393/design.md IDs M1, M2, R0):

    * M1 `:DocumentHold` and `:DocumentsRetentionManage` are core permissions of TENANT scope;
      TENANT_ADMIN holds both; every other role holds neither; PLATFORM_ADMIN is denied outside
      the platform tenant (0046 D4: it is never evaluated as an admin of a tenant);
    * M2 the three routes of `Letflow.Routers.Documents` are declared, none is default-sourced,
      the policy route is `:tenant_wide`, the hold routes are resolver routes with the exported
      `Letflow.Documents.ScopeResolver.document_scope/1`; the walk audits to `[]`; the routes are
      not in the committed default snapshot.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Api.RouteScope
  alias Letflow.Support.RouteInventory

  @permissions [:DocumentHold, :DocumentsRetentionManage]
  @resolver {:resolver, {Letflow.Documents.ScopeResolver, :document_scope}}

  @hold_lines [
    "POST /documents/:document_id/hold DocumentHold",
    "POST /documents/:document_id/hold/release DocumentHold"
  ]

  describe "M1 permissions" do
    test "both are core permissions of tenant scope, appended after ScriptsPublish" do
      core = Authorization.core_permissions()

      for p <- @permissions do
        assert p in core
        assert Authorization.permission_scope(p) == :tenant
        assert Authorization.required_permission(p) == p
      end

      assert Enum.take(core, -2) == @permissions
    end

    test "TENANT_ADMIN holds both; every other role holds neither" do
      for p <- @permissions do
        assert Authorization.role_allows?(:TENANT_ADMIN, p)

        for role <- Authorization.roles(), role not in [:TENANT_ADMIN, :PLATFORM_ADMIN] do
          refute Authorization.role_allows?(role, p), "#{role} #{p}"
        end
      end
    end

    test "PLATFORM_ADMIN is denied both outside the platform tenant" do
      for {key, p} <- [
            {:DocumentHold, :DocumentHold},
            {:DocumentsRetentionManage, :DocumentsRetentionManage}
          ] do
        assert Authorization.required_permission(key) == p

        outside = %AccessContext{
          user_id: "u-536",
          roles: [:PLATFORM_ADMIN],
          platform_tenant?: false
        }

        assert Authorization.evaluate_access(outside, key).kind == :Deny403

        admin = %AccessContext{user_id: "u-536", roles: [:TENANT_ADMIN], platform_tenant?: false}
        assert Authorization.evaluate_access(admin, key).kind == :Allow

        worker = %AccessContext{user_id: "u-536", roles: [:TASK_WORKER], platform_tenant?: false}
        assert Authorization.evaluate_access(worker, key).kind == :Deny403
      end
    end

    test "the three routes resolve their policy keys" do
      assert Authorization.endpoint_policy_key("PUT", "/documents/types/:key/retention") ==
               :DocumentsRetentionManage

      assert Authorization.endpoint_policy_key("POST", "/documents/:document_id/hold") ==
               :DocumentHold

      assert Authorization.endpoint_policy_key("POST", "/documents/:document_id/hold/release") ==
               :DocumentHold
    end
  end

  describe "M2 route classes" do
    setup do
      routes = RouteInventory.routes()

      {:ok,
       routes: routes, doc_routes: Enum.filter(routes, &(&1.router == Letflow.Routers.Documents))}
    end

    test "exactly three routes, all declared and none admin-plane", %{doc_routes: rows} do
      assert length(rows) == 3
      assert Enum.all?(rows, &(&1.source == :declared))
      refute Enum.any?(rows, &(&1.class == :admin_plane))
    end

    test "the policy route is tenant-wide; the hold routes are resolver routes", %{
      doc_routes: rows
    } do
      policy = Enum.find(rows, &(&1.method == "PUT"))
      assert policy.path == "/documents/types/:key/retention"
      assert policy.class == :tenant_wide
      assert policy.key == :DocumentsRetentionManage

      holds = Enum.filter(rows, &(&1.method == "POST"))
      assert holds |> Enum.map(&RouteScope.snapshot_line/1) |> Enum.sort() == @hold_lines
      assert Enum.all?(holds, &(&1.class == @resolver))
      assert function_exported?(Letflow.Documents.ScopeResolver, :document_scope, 1)
    end

    test "the walk audits to [] and the default snapshot holds none of the routes", %{
      routes: routes
    } do
      snapshot = RouteInventory.read_snapshot()
      assert RouteScope.audit_routes(routes, snapshot) == []
      refute Enum.any?(snapshot, &String.contains?(&1, "/documents"))
    end
  end

  test "R0: document_scope/1 is pure and fail-closed" do
    alias Letflow.Documents.Document
    alias Letflow.Documents.ScopeResolver

    node = Ecto.UUID.generate()
    assert ScopeResolver.document_scope(%Document{issuing_org_unit_id: node}) == {:node, node}
    assert ScopeResolver.document_scope(%Document{issuing_org_unit_id: nil}) == :unresolvable
    assert ScopeResolver.document_scope(%Document{issuing_org_unit_id: ""}) == :unresolvable
    assert ScopeResolver.document_scope(:not_a_document) == :unresolvable
  end
end
