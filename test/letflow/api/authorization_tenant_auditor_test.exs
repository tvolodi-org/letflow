defmodule Letflow.Api.AuthorizationTenantAuditorTest do
  @moduledoc """
  REQ-448 AC1 (`lib/letflow/design/req448-tenant-auditor-role.md` sections 2 and 8; spec
  `test/specs/REQ-448.md`): the read-only `TENANT_AUDITOR` role and its grant rule in
  `Letflow.Api.Authorization`, plus the new `:AttachmentLinksIssue` permission (item L1).

  Decision 0046 D6 lists 14 atoms for the auditor and the effective grant is exactly those 14
  (13 explicit core atoms plus the role-agnostic `:MyModulesRead`). `:PromotionsRead` was
  withheld by REQ-448 until the stored-tenant check of Q-1011 / ISS-1029 merged and was granted
  by ISS-1109 / GH #2489. `:EntitiesRecordsExport` is not granted (supervisor decision).

  Both expectation lists are literal (not derived from `role_allows?/2`), so a drift of the
  grant rule is caught here and not silently followed.

  Pure (no database, no pin): `async: true` is safe. Router-level proofs live in
  `test/letflow/routers/tenant_auditor_routes_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Modules.Catalog

  @auditor_granted [
    :DefinitionsRead,
    :InstancesRead,
    :TasksRead,
    :AuditRead,
    :MetricsRead,
    :AttachmentsRead,
    :EntitiesDefinitionsRead,
    :EntitiesQuery,
    :EntitiesAggregate,
    :EntitiesAttachmentsRead,
    :HelpRead,
    :MembershipsRead,
    :PromotionsRead,
    :MyModulesRead,
    :MyAccessRead
  ]

  # The 27 core permissions the auditor does NOT hold (41 core permissions minus the 14 above).
  @auditor_refused_core [
    :DefinitionsWrite,
    :InstancesStart,
    :InstancesCancel,
    :TasksComplete,
    :TasksAssign,
    :UsersGroupsRolesManage,
    :TokensManage,
    :DlqOperate,
    :WebhooksManage,
    :TenantsManage,
    :RolesManage,
    :AttachmentsManage,
    :InstancesAdvanceTimer,
    :EntitiesDefinitionsWrite,
    :EntitiesRecordsWrite,
    :EntitiesRecordsExport,
    :EntitiesRecordsExportUnredacted,
    :EntitiesRecordsImport,
    :EntitiesAttachmentsManage,
    :PublicReadHandlesIssue,
    :ModulesManage,
    :EntitiesRestrictionsManage,
    :PlatformServicesManage,
    :TenantSettingsManage,
    :PromotionsManage,
    :DefinitionsRollback,
    :AttachmentLinksIssue,
    # GH 2534 PR 7b-1 (decision 0053 D6): the auditor holds neither script permission
    # (the auditor source read is GH 2548).
    :ScriptsWrite,
    :ScriptsPublish,
    :DocumentHold,
    :DocumentsRetentionManage,
    :IntegrationMappingsManage
  ]

  @link_route {"POST", "/instances/:id/attachments/:attachment_id/link"}

  defp ctx(roles, platform_tenant?),
    do: %AccessContext{user_id: "u-req448", roles: roles, platform_tenant?: platform_tenant?}

  describe "roles/0" do
    test "returns eight atoms ending in TENANT_AUDITOR, the seven existing roles first and unchanged" do
      roles = Authorization.roles()

      assert length(roles) == 8
      assert List.last(roles) == :TENANT_AUDITOR

      assert Enum.take(roles, 7) == [
               :PLATFORM_ADMIN,
               :PROCESS_DESIGNER,
               :PROCESS_OPERATOR,
               :TASK_WORKER,
               :AGENT_RUNNER,
               :CANDIDATE,
               :TENANT_ADMIN
             ]
    end
  end

  describe "AC1: the grant rule" do
    test "for every p in permissions/0, role_allows?(:TENANT_AUDITOR, p) is true exactly for the 15 literal atoms and false for every other core and Catalog permission" do
      permissions = Authorization.permissions()
      assert length(permissions) > length(Authorization.core_permissions())

      for permission <- permissions do
        expected = permission in @auditor_granted

        assert Authorization.role_allows?(:TENANT_AUDITOR, permission) == expected,
               "role_allows?(:TENANT_AUDITOR, #{inspect(permission)}) expected #{expected}"
      end

      granted = Enum.filter(permissions, &Authorization.role_allows?(:TENANT_AUDITOR, &1))
      assert Enum.sort(granted) == Enum.sort(@auditor_granted)
      assert length(granted) == 15
    end

    test "the refused core set is the literal 32, EntitiesRecordsExport among them (PromotionsRead is granted), and it partitions core_permissions/0 together with the granted set" do
      core = Authorization.core_permissions()
      granted_core = Enum.filter(core, &Authorization.role_allows?(:TENANT_AUDITOR, &1))
      refused_core = core -- granted_core

      assert length(@auditor_refused_core) == 32
      assert Enum.sort(refused_core) == Enum.sort(@auditor_refused_core)
      assert Enum.sort(granted_core ++ @auditor_refused_core) == Enum.sort(core)

      refute :PromotionsRead in refused_core
      assert :PromotionsRead in granted_core
      assert :EntitiesRecordsExport in refused_core
      assert :EntitiesRecordsExportUnredacted in refused_core
    end

    test "every write-class, manage-class, start/cancel/complete/assign, import/export and platform-scope permission is refused" do
      for permission <- Authorization.core_permissions(),
          name = Atom.to_string(permission),
          String.ends_with?(name, [
            "Write",
            "Manage",
            "Start",
            "Cancel",
            "Complete",
            "Assign",
            "Import"
          ]) or
            String.contains?(name, "Export") or String.ends_with?(name, "Issue") or
            Authorization.permission_scope(permission) == :platform do
        refute Authorization.role_allows?(:TENANT_AUDITOR, permission), inspect(permission)
      end
    end

    test "no Catalog (module) permission is granted: no manifest role_grants names TENANT_AUDITOR" do
      assert Catalog.role_grants(:TENANT_AUDITOR) == []
      assert :FixtureRead in Catalog.permissions()
      refute Authorization.role_allows?(:TENANT_AUDITOR, :FixtureRead)

      for permission <- Catalog.permissions() do
        refute Authorization.role_allows?(:TENANT_AUDITOR, permission), inspect(permission)
      end
    end

    test "the grant is not vacuous and not a scope rule: it differs from TENANT_ADMIN's tenant-scope rule on every write permission" do
      for permission <- [
            :DefinitionsWrite,
            :InstancesStart,
            :UsersGroupsRolesManage,
            :TokensManage
          ] do
        assert Authorization.role_allows?(:TENANT_ADMIN, permission)
        refute Authorization.role_allows?(:TENANT_AUDITOR, permission)
      end

      for permission <- @auditor_granted do
        assert Authorization.role_allows?(:TENANT_AUDITOR, permission), inspect(permission)
      end
    end
  end

  describe "evaluate_access/2 for TENANT_AUDITOR" do
    test ":Unknown is denied, platform_tenant? true or false" do
      for flag <- [true, false] do
        assert Authorization.evaluate_access(ctx([:TENANT_AUDITOR], flag), :Unknown).kind ==
                 :Deny403
      end
    end

    test "the router catch-all markers deny TENANT_AUDITOR (403, not the router 404), platform_tenant? true or false" do
      for marker <- [:UnmatchedRoute, :UnmatchedPlatformPath], flag <- [true, false] do
        assert Authorization.evaluate_access(ctx([:TENANT_AUDITOR], flag), marker).kind ==
                 :Deny403,
               "#{inspect(marker)} platform_tenant?=#{flag}"
      end
    end

    test "TENANT_AUDITOR is never allowed a platform-scope permission or key, with platform_tenant? true or false" do
      for permission <- Authorization.platform_permissions(), flag <- [true, false] do
        refute Authorization.has_permission_in_scope?([:TENANT_AUDITOR], permission, flag),
               "has_permission_in_scope? #{inspect(permission)} flag=#{flag}"
      end

      for key <- [:TenantsManage, :AdminServicesRead, :AdminServicesManage],
          flag <- [true, false] do
        assert Authorization.evaluate_access(ctx([:TENANT_AUDITOR], flag), key).kind == :Deny403,
               "#{inspect(key)} platform_tenant?=#{flag}"
      end
    end

    test "the read keys are Allow and the write keys are Deny403, in and out of the platform tenant" do
      for flag <- [true, false] do
        for key <- [
              :DefinitionsRead,
              :InstancesRead,
              :AuditRead,
              :AttachmentsRead,
              :EntitiesQuery,
              :EntitiesAggregate,
              :HelpRead,
              :MembershipsRead,
              :PromotionsRead,
              :MyModulesRead,
              :MyAccessRead
            ] do
          assert Authorization.evaluate_access(ctx([:TENANT_AUDITOR], flag), key).kind == :Allow,
                 "#{inspect(key)} platform_tenant?=#{flag}"
        end

        for key <- [
              :DefinitionsWrite,
              :InstancesStart,
              :InstancesCancel,
              :TasksComplete,
              :TasksAssign,
              :PromotionsManage,
              :DefinitionsRollback,
              :AttachmentLinksIssue,
              :EntitiesRecordsExport,
              :EntitiesRecordsImport
            ] do
          assert Authorization.evaluate_access(ctx([:TENANT_AUDITOR], flag), key).kind ==
                   :Deny403,
                 "#{inspect(key)} platform_tenant?=#{flag}"
        end
      end
    end
  end

  describe "role string parsing" do
    test "roles_from_strings/1 parses TENANT_AUDITOR exactly; lower-case, mixed-case, padded and hyphenated forms parse to nothing" do
      assert Authorization.roles_from_strings(["TENANT_AUDITOR"]) == [:TENANT_AUDITOR]

      for variant <- [
            "tenant_auditor",
            "Tenant_Auditor",
            " TENANT_AUDITOR",
            "TENANT_AUDITOR ",
            "TENANT-AUDITOR",
            "TENANTAUDITOR",
            ""
          ] do
        assert Authorization.roles_from_strings([variant]) == [], inspect(variant)
      end
    end

    test "effective_roles/2 keeps TENANT_AUDITOR in and out of the platform tenant (it is not the PLATFORM_ADMIN drop)" do
      for flag <- [true, false] do
        assert Authorization.effective_roles(["TENANT_AUDITOR"], flag) == [:TENANT_AUDITOR]
      end
    end

    test "TENANT_AUDITOR is a built-in role name (the H2 POST /roles guard, case-folded) but not a platform-admin name" do
      assert Authorization.builtin_role_name?("TENANT_AUDITOR")
      assert Authorization.builtin_role_name?(" tenant_auditor ")
      refute Authorization.platform_admin_name?("TENANT_AUDITOR")
      refute Authorization.platform_admin_name?("tenant_auditor")
    end
  end

  describe "is_task_worker_only?/1 and the task scope" do
    test "false for TENANT_AUDITOR alone and for TENANT_AUDITOR + TASK_WORKER (either order); true for TASK_WORKER alone" do
      refute Authorization.is_task_worker_only?([:TENANT_AUDITOR])
      refute Authorization.is_task_worker_only?([:TENANT_AUDITOR, :TASK_WORKER])
      refute Authorization.is_task_worker_only?([:TASK_WORKER, :TENANT_AUDITOR])
      assert Authorization.is_task_worker_only?([:TASK_WORKER])
    end

    test "GET /tasks (:TasksList) is Allow with task_scope :all for TENANT_AUDITOR alone and with TASK_WORKER, row-filtered for TASK_WORKER alone" do
      for roles <- [
            [:TENANT_AUDITOR],
            [:TENANT_AUDITOR, :TASK_WORKER],
            [:TASK_WORKER, :TENANT_AUDITOR]
          ] do
        decision = Authorization.evaluate_access(ctx(roles, false), :TasksList)
        assert decision.kind == :Allow, inspect(roles)
        assert decision.task_scope == :all, inspect(roles)
      end

      worker = Authorization.evaluate_access(ctx([:TASK_WORKER], false), :TasksList)
      assert worker.kind == :AllowWithRowFilter
      assert worker.task_scope == {:own_user_and_groups, "u-req448"}
    end

    test "holding TASK_WORKER does not give the auditor any write permission: mutations still come only from the roles held" do
      roles = [:TENANT_AUDITOR, :TASK_WORKER]

      # TASK_WORKER's own grant (complete) is held; the auditor adds nothing to it and loses nothing.
      assert Authorization.has_permission_in_scope?(roles, :TasksComplete, false)
      refute Authorization.has_permission_in_scope?(roles, :TasksAssign, false)
      refute Authorization.has_permission_in_scope?(roles, :InstancesStart, false)
      refute Authorization.has_permission_in_scope?([:TENANT_AUDITOR], :TasksComplete, false)
    end
  end

  describe "item L1: :AttachmentLinksIssue" do
    test "is a core permission of tenant scope" do
      assert :AttachmentLinksIssue in Authorization.core_permissions()
      assert Authorization.permission_scope(:AttachmentLinksIssue) == :tenant
      refute :AttachmentLinksIssue in Authorization.platform_permissions()
    end

    test "the link-ISSUE route is keyed :AttachmentLinksIssue; link-content and storage-usage stay :AttachmentsRead" do
      {method, path} = @link_route
      assert Authorization.endpoint_policy_key(method, path) == :AttachmentLinksIssue
      assert Authorization.required_permission(:AttachmentLinksIssue) == :AttachmentLinksIssue

      for path <- [
            "/instances/:id/attachments/:attachment_id/link-content",
            "/instances/storage-usage",
            "/instances/:id/attachments"
          ] do
        assert Authorization.endpoint_policy_key("GET", path) == :AttachmentsRead, path
      end
    end

    test "is held by PLATFORM_ADMIN (in the platform tenant only), PROCESS_DESIGNER, PROCESS_OPERATOR, TASK_WORKER, TENANT_ADMIN and by no other role" do
      holders =
        for role <- Authorization.roles(),
            Authorization.has_permission_in_scope?([role], :AttachmentLinksIssue, true),
            do: role

      assert Enum.sort(holders) ==
               Enum.sort([
                 :PLATFORM_ADMIN,
                 :PROCESS_DESIGNER,
                 :PROCESS_OPERATOR,
                 :TASK_WORKER,
                 :TENANT_ADMIN
               ])

      refute Authorization.has_permission_in_scope?(
               [:PLATFORM_ADMIN],
               :AttachmentLinksIssue,
               false
             )

      for role <- [:AGENT_RUNNER, :CANDIDATE, :TENANT_AUDITOR], flag <- [true, false] do
        refute Authorization.has_permission_in_scope?([role], :AttachmentLinksIssue, flag),
               "#{role} flag=#{flag}"
      end
    end

    test "every role that reached the link route before L1 (the five) still does, and the auditor, AGENT_RUNNER and CANDIDATE do not" do
      {method, path} = @link_route
      key = Authorization.endpoint_policy_key(method, path)

      # Literal: the roles that held :AttachmentsRead and so reached this route before REQ-448.
      for role <- [
            :PLATFORM_ADMIN,
            :PROCESS_DESIGNER,
            :PROCESS_OPERATOR,
            :TASK_WORKER,
            :TENANT_ADMIN
          ] do
        assert Authorization.evaluate_access(ctx([role], true), key).kind == :Allow,
               "#{role} must still reach the link route"
      end

      for role <- [:TENANT_AUDITOR, :AGENT_RUNNER, :CANDIDATE], flag <- [true, false] do
        assert Authorization.evaluate_access(ctx([role], flag), key).kind == :Deny403,
               "#{role} flag=#{flag}"
      end
    end

    test "the auditor still reaches the sibling read routes: link-content, the attachment list and storage-usage" do
      for flag <- [true, false] do
        assert Authorization.evaluate_access(ctx([:TENANT_AUDITOR], flag), :AttachmentsRead).kind ==
                 :Allow
      end
    end
  end
end
