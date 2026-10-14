defmodule Letflow.Api.PlatformScopeAuthorizationTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 3 and section 6 rule 1a (spec
  `test/specs/ISS-0993-A1.md`): the pure permission-scope surface of `Letflow.Api.Authorization`
  as shipped in A1 --

    * every core permission has exactly one scope (the scope table); the platform list is exact;
      Catalog (module) permissions are `:tenant`; any other atom is `:platform` (fail closed);
    * `has_permission_in_scope?/3` (REQ-447 PR 2: the C6 own-tenant switch is deleted, a non-platform
      tenant's `PLATFORM_ADMIN` confers nothing, tenant-scope included);
    * `evaluate_access/2` grid roles x `platform_tenant?` x keys, including the two catch-all
      marker keys (rule 1a);
    * `:Unknown` (A2 state): denied for every role, in and out of the platform tenant (see the
      test of that name below);
    * key and permission resolution for the new keys, table-driven.

  INV-10 check, enforced from the merge of Q-960 PR A (the scope-table completeness check).

  `async: false`: kept from the era when one test toggled the (now deleted) C6 application-config
  switch; the module no longer touches global state.
  """

  use ExUnit.Case, async: false

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Modules.Catalog

  @tenant_scope_core [
    :DefinitionsWrite,
    :DefinitionsRead,
    :DefinitionsRollback,
    :InstancesStart,
    :InstancesCancel,
    :InstancesRead,
    :InstancesAdvanceTimer,
    :TasksRead,
    :TasksComplete,
    :TasksAssign,
    :UsersGroupsRolesManage,
    :TokensManage,
    :RolesManage,
    :AuditRead,
    :DlqOperate,
    :MetricsRead,
    :WebhooksManage,
    :AttachmentsManage,
    :AttachmentsRead,
    :EntitiesDefinitionsRead,
    :EntitiesDefinitionsWrite,
    :EntitiesRecordsWrite,
    :EntitiesQuery,
    :EntitiesAggregate,
    :EntitiesRecordsExport,
    :EntitiesRecordsExportUnredacted,
    :EntitiesRecordsImport,
    :EntitiesAttachmentsManage,
    :EntitiesAttachmentsRead,
    :EntitiesRestrictionsManage,
    :PublicReadHandlesIssue,
    :HelpRead,
    :MembershipsRead,
    :MyModulesRead,
    :ModulesManage,
    :TenantSettingsManage,
    :PromotionsRead,
    :PromotionsManage,
    # REQ-448 (L1)
    :AttachmentLinksIssue,
    # GH 2534 PR 7b-1
    :ScriptsWrite,
    :ScriptsPublish
  ]

  @new_permissions [
    :PlatformServicesManage,
    :TenantSettingsManage,
    :PromotionsRead,
    :PromotionsManage,
    :DefinitionsRollback
  ]

  defp ctx(roles, platform_tenant?),
    do: %AccessContext{user_id: "u", roles: roles, platform_tenant?: platform_tenant?}

  describe "scope table" do
    test "every core permission has exactly one scope: the platform pair, and the tenant-scope permissions" do
      core = Authorization.core_permissions()

      assert core == Enum.uniq(core)

      platform = Enum.filter(core, &(Authorization.permission_scope(&1) == :platform))
      tenant = Enum.filter(core, &(Authorization.permission_scope(&1) == :tenant))

      assert Enum.sort(platform) == Enum.sort([:TenantsManage, :PlatformServicesManage])
      assert Enum.sort(tenant) == Enum.sort(@tenant_scope_core)
      assert length(platform) + length(tenant) == length(core)
    end

    test "the new core permissions are present in core_permissions/0" do
      for permission <- @new_permissions do
        assert permission in Authorization.core_permissions()
      end
    end

    test "platform_permissions/0 is the exact platform list" do
      assert Enum.sort(Authorization.platform_permissions()) ==
               Enum.sort([:TenantsManage, :PlatformServicesManage])
    end

    test "every Catalog (module) permission is tenant scope" do
      catalog = Catalog.permissions()
      assert catalog != []

      for permission <- catalog do
        assert Authorization.permission_scope(permission) == :tenant,
               "#{inspect(permission)} must be tenant scope"
      end
    end

    test "any unclassified term is platform scope (fail closed), never raises" do
      for term <- [:NoSuchPermission, :Unknown, :UnmatchedRoute, nil, "TenantsManage", 5, %{}] do
        assert Authorization.permission_scope(term) == :platform, "term: #{inspect(term)}"
      end
    end

    test "permissions/0 is the core list followed by the Catalog list" do
      assert Authorization.permissions() ==
               Authorization.core_permissions() ++ Catalog.permissions()
    end
  end

  describe "role holders of the new permissions (REQ-447: PLATFORM_ADMIN and TENANT_ADMIN)" do
    test "only PLATFORM_ADMIN and TENANT_ADMIN hold each new (tenant-scope) permission through the role matrix" do
      for permission <- @new_permissions do
        assert Authorization.role_allows?(:PLATFORM_ADMIN, permission)

        # :PlatformServicesManage is platform scope (literal, not derived): TENANT_ADMIN is denied it.
        # ISS-1109: TENANT_AUDITOR additionally holds :PromotionsRead (read-only grant).
        holders =
          cond do
            permission == :PlatformServicesManage -> [:PLATFORM_ADMIN]
            permission == :PromotionsRead -> [:PLATFORM_ADMIN, :TENANT_ADMIN, :TENANT_AUDITOR]
            true -> [:PLATFORM_ADMIN, :TENANT_ADMIN]
          end

        assert Authorization.role_allows?(:TENANT_ADMIN, permission) == :TENANT_ADMIN in holders

        for role <- Authorization.roles() -- holders do
          refute Authorization.role_allows?(role, permission),
                 "#{role} must not hold #{permission}"
        end
      end
    end
  end

  describe "has_permission_in_scope?/3" do
    test "platform scope: PLATFORM_ADMIN only, and only with platform_tenant? true" do
      for permission <- [:TenantsManage, :PlatformServicesManage] do
        assert Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], permission, true)
        refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], permission, false)
        refute Authorization.has_permission_in_scope?([], permission, true)

        for role <- Authorization.roles() -- [:PLATFORM_ADMIN], flag <- [true, false] do
          refute Authorization.has_permission_in_scope?([role], permission, flag)
        end
      end
    end

    test "platform scope: a PLATFORM_ADMIN among other roles still needs the platform tenant" do
      refute Authorization.has_permission_in_scope?(
               [:PROCESS_DESIGNER, :PLATFORM_ADMIN],
               :TenantsManage,
               false
             )

      assert Authorization.has_permission_in_scope?(
               [:PROCESS_DESIGNER, :PLATFORM_ADMIN],
               :TenantsManage,
               true
             )
    end

    test "tenant scope follows the role matrix unchanged, in and out of the platform tenant" do
      for permission <- [
            :TenantSettingsManage,
            :PromotionsManage,
            :DefinitionsRollback,
            :UsersGroupsRolesManage
          ] do
        # REQ-447 PR 2: PLATFORM_ADMIN holds tenant-scope permissions in the platform
        # tenant only; outside it the role confers NOTHING (legacy own-tenant powers gone).
        assert Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], permission, true),
               "#{permission} platform tenant"

        refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], permission, false),
               "#{permission} non-platform tenant must NOT be honoured"

        # TENANT_ADMIN holds them everywhere.
        for flag <- [true, false] do
          assert Authorization.has_permission_in_scope?([:TENANT_ADMIN], permission, flag),
                 "TENANT_ADMIN #{permission} flag=#{flag}"
        end
      end

      assert Authorization.has_permission_in_scope?([:PROCESS_DESIGNER], :DefinitionsWrite, false)
      refute Authorization.has_permission_in_scope?([:TASK_WORKER], :DefinitionsWrite, false)
    end

    test "REQ-447 PR 2: the C6 switch is gone, and a non-platform tenant's PLATFORM_ADMIN confers NOTHING (tenant scope included)" do
      refute function_exported?(Authorization, :tenant_platform_admin_own_tenant_powers?, 0)

      # Even with the former config key set to true, nothing is honoured: the key is dead.
      original = Application.fetch_env(:letflow, :tenant_platform_admin_own_tenant_powers)

      on_exit(fn ->
        case original do
          {:ok, value} ->
            Application.put_env(:letflow, :tenant_platform_admin_own_tenant_powers, value)

          :error ->
            Application.delete_env(:letflow, :tenant_platform_admin_own_tenant_powers)
        end
      end)

      Application.put_env(:letflow, :tenant_platform_admin_own_tenant_powers, true)

      # Every permission, tenant scope and platform scope, is denied to a lone
      # PLATFORM_ADMIN outside the platform tenant...
      for permission <- Authorization.permissions() do
        refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], permission, false),
               "#{inspect(permission)} must not be conferred by a non-platform PLATFORM_ADMIN"
      end

      # ...and the platform tenant's PLATFORM_ADMIN is unchanged (control).
      for permission <- Authorization.permissions() do
        assert Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], permission, true),
               "#{inspect(permission)} must stay held by the platform tenant's PLATFORM_ADMIN"
      end

      # Other roles keep what they hold, including alongside a (dropped) PLATFORM_ADMIN.
      assert Authorization.has_permission_in_scope?([:PROCESS_DESIGNER], :DefinitionsWrite, false)

      assert Authorization.has_permission_in_scope?(
               [:PROCESS_DESIGNER, :PLATFORM_ADMIN],
               :DefinitionsWrite,
               false
             )

      refute Authorization.has_permission_in_scope?(
               [:TASK_WORKER, :PLATFORM_ADMIN],
               :DefinitionsWrite,
               false
             )
    end

    test "role_allows?/2 is the unchanged role matrix: PLATFORM_ADMIN holds the platform permissions there" do
      assert Authorization.role_allows?(:PLATFORM_ADMIN, :TenantsManage)
      assert Authorization.role_allows?(:PLATFORM_ADMIN, :PlatformServicesManage)
    end
  end

  describe "evaluate_access/2" do
    test "platform keys: allowed only for PLATFORM_ADMIN with platform_tenant? true" do
      for key <- [:TenantsManage, :AdminServicesRead, :AdminServicesManage] do
        assert Authorization.evaluate_access(ctx([:PLATFORM_ADMIN], true), key).kind == :Allow
        assert Authorization.evaluate_access(ctx([:PLATFORM_ADMIN], false), key).kind == :Deny403

        for role <- Authorization.roles() -- [:PLATFORM_ADMIN], flag <- [true, false] do
          assert Authorization.evaluate_access(ctx([role], flag), key).kind == :Deny403
        end
      end
    end

    test "tenant keys of the new permissions: TENANT_ADMIN allowed in and out of the platform tenant, PLATFORM_ADMIN only in it, others denied" do
      for key <- [:TenantSettingsManage, :PromotionsRead, :PromotionsManage, :DefinitionsRollback],
          flag <- [true, false] do
        # REQ-447 PR 2: PLATFORM_ADMIN is honoured only in the platform tenant.
        expected_platform_admin = if flag, do: :Allow, else: :Deny403

        assert Authorization.evaluate_access(ctx([:PLATFORM_ADMIN], flag), key).kind ==
                 expected_platform_admin

        assert Authorization.evaluate_access(ctx([:TENANT_ADMIN], flag), key).kind == :Allow

        # ISS-1109: TENANT_AUDITOR is the one other role that holds :PromotionsRead.
        expected_auditor = if key == :PromotionsRead, do: :Allow, else: :Deny403

        assert Authorization.evaluate_access(ctx([:TENANT_AUDITOR], flag), key).kind ==
                 expected_auditor,
               "TENANT_AUDITOR on #{key}"

        for role <- Authorization.roles() -- [:PLATFORM_ADMIN, :TENANT_ADMIN, :TENANT_AUDITOR] do
          assert Authorization.evaluate_access(ctx([role], flag), key).kind == :Deny403,
                 "#{role} on #{key}"
        end
      end
    end

    test "a context built without the platform flag fails closed on platform keys" do
      ctx = %AccessContext{user_id: "u", roles: [:PLATFORM_ADMIN]}
      assert ctx.platform_tenant? == false
      assert Authorization.evaluate_access(ctx, :TenantsManage).kind == :Deny403
    end

    test "catch-all marker :UnmatchedPlatformPath (rule 1a): Allow only for a platform-tenant PLATFORM_ADMIN" do
      assert Authorization.evaluate_access(ctx([:PLATFORM_ADMIN], true), :UnmatchedPlatformPath).kind ==
               :Allow

      assert Authorization.evaluate_access(ctx([:PLATFORM_ADMIN], false), :UnmatchedPlatformPath).kind ==
               :Deny403

      for role <- Authorization.roles() -- [:PLATFORM_ADMIN], flag <- [true, false] do
        assert Authorization.evaluate_access(ctx([role], flag), :UnmatchedPlatformPath).kind ==
                 :Deny403
      end

      assert Authorization.evaluate_access(ctx([], true), :UnmatchedPlatformPath).kind == :Deny403
    end

    test "catch-all marker :UnmatchedRoute (rule 1a, REQ-447 PR 2): Allow only for a platform-tenant PLATFORM_ADMIN, others denied" do
      assert Authorization.evaluate_access(ctx([:PLATFORM_ADMIN], true), :UnmatchedRoute).kind ==
               :Allow

      # Changed assertion: this used to be :Allow for a PLATFORM_ADMIN of ANY tenant.
      assert Authorization.evaluate_access(ctx([:PLATFORM_ADMIN], false), :UnmatchedRoute).kind ==
               :Deny403

      for flag <- [true, false] do
        for role <- Authorization.roles() -- [:PLATFORM_ADMIN] do
          assert Authorization.evaluate_access(ctx([role], flag), :UnmatchedRoute).kind ==
                   :Deny403
        end
      end
    end

    test "A2: :Unknown is denied for every role, PLATFORM_ADMIN included" do
      # Design section 6 rule 1.
      for flag <- [true, false], role <- Authorization.roles() do
        assert Authorization.evaluate_access(ctx([role], flag), :Unknown).kind == :Deny403
      end
    end
  end

  describe "key and permission resolution" do
    @pairs [
      {"PATCH", "/tenant/settings", :TenantSettingsManage},
      {"POST", "/promotions", :PromotionsManage},
      {"POST", "/promotions/plan", :PromotionsManage},
      {"GET", "/promotions/platform-events", :PromotionsRead},
      {"GET", "/promotions/:id", :PromotionsRead},
      {"GET", "/promotions/:id/context", :PromotionsRead},
      {"POST", "/promotions/:id/approve", :PromotionsManage},
      {"POST", "/promotions/:id/reject", :PromotionsManage},
      {"POST", "/promotions/:id/apply", :PromotionsManage},
      {"POST", "/promotions/:review_id/run-assertions", :PromotionsManage},
      {"GET", "/promotions", :PromotionsRead},
      {"POST", "/definitions/:process_key/rollback", :DefinitionsRollback},
      {"POST", "/tenants/:test_tenant_id/promote/:process_key", :PromotionsManage}
    ]

    for {method, path, key} <- @pairs do
      test "#{method} #{path} resolves to #{key}, and the key's permission has tenant scope" do
        assert Authorization.endpoint_policy_key(unquote(method), unquote(path)) == unquote(key)

        permission = Authorization.required_permission(unquote(key))
        assert permission == unquote(key)
        assert Authorization.permission_scope(permission) == :tenant
      end
    end

    test "the global service catalogue keys map to the platform permission" do
      for key <- [:AdminServicesRead, :AdminServicesManage] do
        assert Authorization.required_permission(key) == :PlatformServicesManage
        assert Authorization.permission_scope(:PlatformServicesManage) == :platform
      end
    end

    test "the six /tenants routes, /onboarding, /platform-migrations and /event-retention keep :TenantsManage (platform scope)" do
      for {method, path} <- [
            {"POST", "/tenants"},
            {"GET", "/tenants"},
            {"GET", "/tenants/:slug"},
            {"PATCH", "/tenants/:slug"},
            {"POST", "/tenants/:slug/deactivate"},
            {"POST", "/tenants/:slug/reactivate"},
            {"POST", "/onboarding"},
            {"GET", "/onboarding/:id"},
            {"POST", "/onboarding/:id/bind-realm"},
            {"GET", "/onboarding"},
            {"POST", "/platform-migrations/rollouts"},
            {"GET", "/platform-migrations/rollouts/:id"},
            {"POST", "/platform-migrations/rollouts/:id/resume"},
            {"GET", "/event-retention/summary"},
            {"POST", "/event-retention/retirements"},
            {"GET", "/event-retention/retirements/:id"}
          ] do
        key = Authorization.endpoint_policy_key(method, path)
        assert key == :TenantsManage, "#{method} #{path} -> #{inspect(key)}"
      end

      assert Authorization.permission_scope(:TenantsManage) == :platform
    end

    test "PATCH /tenant/settings is no longer the platform registry permission" do
      refute Authorization.required_permission(
               Authorization.endpoint_policy_key("PATCH", "/tenant/settings")
             ) == :TenantsManage
    end
  end
end
