defmodule Letflow.Identity.LastAdminPaths do
  @moduledoc """
  The inventory of every write path that takes the tenant admin lock (lock A,
  `Letflow.Identity.lock_tenant_admins!/1`) and what the last-interactive-admin guard of
  GH #2869 (a) does about it (design
  `lib/letflow/design/gh2869-last-interactive-admin-guard.md` section 3.6, D-9).

  DATA ONLY: no DB access, no side effects. One row per CALL SITE of `lock_tenant_admins!/1`
  in `lib/` (the definition excluded); the completeness scan compares the multiset of
  `{file, function}` of the call sites to `rows/0`, so a new lock-A writer that is not
  registered here fails the scan and must be given a class (and, for `:guarded`, a guard
  call).

  Classes:

    * `:guarded` (G): the path can lower the interactive explicit tenant-wide admin count and
      calls the second guard. `:action` is the `tenant_admin.guard_refused` action;
      `:guard` names the function (in the same file) that holds the guard call and
      `:guard_call` the `TenantAdminGuard` function it calls
      (`ensure_interactive_admin_remains!/4`, or `interactive_admin_check/2` for the one
      `Ecto.Multi` step of `update_locked_user`).
    * `:no_lower` (N): takes lock A but cannot lower the count (adds only, or skipped in
      `on`, or the token half which is never counted); `:reason` says why.
    * `:not_admin_writer` (X): takes lock A but writes no user, group, membership, binding,
      grant or token row; `:reason` says why.
  """

  @type site :: %{file: String.t(), function: {atom(), arity()}}
  @type row :: %{
          id: atom(),
          site: site(),
          class: :guarded | :no_lower | :not_admin_writer,
          action: atom() | nil,
          guard: {atom(), arity()} | nil,
          guard_call: atom() | nil,
          reason: String.t() | nil
        }

  @identity "lib/letflow/identity.ex"
  @role_registry "lib/letflow/identity/role_registry.ex"
  @scoped_grants "lib/letflow/identity/scoped_grants.ex"
  @service_principal "lib/letflow/identity/service_principal.ex"
  @pending "lib/letflow/identity/pending_admin_grants.ex"
  @tam "lib/letflow/identity/tenant_admin_migration.ex"
  @backfill "lib/letflow/identity/role_scope_grants/backfill.ex"
  @scope_enforcement "lib/letflow/scope_enforcement.ex"
  @policy "lib/letflow/scripts/policy.ex"
  @scripts "lib/letflow/scripts.ex"

  @doc "Every lock-A call site, in the order of design section 3.6."
  @spec rows() :: [row()]
  def rows do
    [
      guarded(
        :p1,
        @identity,
        {:update_locked_user, 6},
        :deactivate_user,
        {:interactive_guard, 3},
        :interactive_admin_check
      ),
      guarded(
        :p2,
        @identity,
        {:do_remove_group_member, 4},
        :remove_tenant_admin_member,
        {:do_remove_group_member, 4},
        :ensure_interactive_admin_remains!
      ),
      guarded(
        :p3,
        @role_registry,
        {:do_upsert_role, 4},
        :unbind_tenant_admin,
        {:guard_unbind_interactive_admin, 3},
        :ensure_interactive_admin_remains!
      ),
      guarded(
        :p4,
        @role_registry,
        {:rebind_transaction, 7},
        :rebind_tenant_admin,
        {:move_role, 6},
        :ensure_interactive_admin_remains!
      ),
      guarded(
        :p5,
        @scoped_grants,
        {:delete, 3},
        :revoke_tenant_admin_grant,
        {:delete, 3},
        :ensure_interactive_admin_remains!
      ),
      guarded(
        :p6,
        @service_principal,
        {:do_set_flag, 5},
        :flag_service_principal,
        {:do_set_flag, 5},
        :ensure_interactive_admin_remains!
      ),
      other(
        :p7,
        @identity,
        {:do_add_group_member, 6},
        :no_lower,
        "adds a membership; the recovery move"
      ),
      other(
        :p8,
        @identity,
        {:delete_group, 2},
        :no_lower,
        "deletes only a memberless group; the bound admin group cannot be deleted"
      ),
      other(
        :p9,
        @identity,
        {:sync_role_claims_report, 3},
        :no_lower,
        "inserts memberships, never removes; suppressed when widening in on"
      ),
      other(
        :p10,
        @identity,
        {:insert_token, 6},
        :no_lower,
        "token rows are never in the interactive count"
      ),
      other(
        :p11,
        @scoped_grants,
        {:lock_writers!, 2},
        :no_lower,
        "create (scoping) cannot lower the count and make_tenant_wide only adds"
      ),
      other(
        :p12,
        @identity,
        {:revoke_locked_token, 4},
        :no_lower,
        "tokens are never counted; the token guard is unchanged"
      ),
      other(
        :p13,
        @pending,
        {:revoke, 3},
        :no_lower,
        "a pending grant is not an interactive admin"
      ),
      other(
        :p14,
        @pending,
        {:transact_bind, 8},
        :no_lower,
        "adds the TENANT_ADMIN membership; a recovery move"
      ),
      other(
        :p15,
        @role_registry,
        {:ensure_platform_role_binding, 2},
        :no_lower,
        "seeding creates or repairs a binding, never removes one"
      ),
      other(
        :p16,
        @tam,
        {:real_tenant, 4},
        :no_lower,
        "the whole plan is skipped in an on tenant"
      ),
      other(
        :p17,
        @backfill,
        {:repair_tenant, 2},
        :no_lower,
        "skipped in an on tenant; inserts missing group rows otherwise"
      ),
      other(
        :p18,
        @scope_enforcement,
        {:lock_tenant_row!, 2},
        :not_admin_writer,
        "flip and break-glass write the flag and its audit entry only"
      ),
      other(
        :p19a,
        @policy,
        {:solo_gate, 3},
        :not_admin_writer,
        "writes policy rows only; reads the counted-admin count"
      ),
      other(
        :p19b,
        @policy,
        {:set_sod, 4},
        :not_admin_writer,
        "writes policy rows only"
      ),
      other(
        :p19c,
        @policy,
        {:set_platform_solo_audited, 5},
        :not_admin_writer,
        "writes policy rows only"
      ),
      other(
        :p19d,
        @scripts,
        {:publish_transaction, 6},
        :not_admin_writer,
        "writes script rows and policy latches only"
      ),
      other(
        :p19e,
        @scripts,
        {:confirm, 5},
        :not_admin_writer,
        "writes script rows only"
      )
    ]
  end

  defp guarded(id, file, function, action, guard, guard_call) do
    %{
      id: id,
      site: %{file: file, function: function},
      class: :guarded,
      action: action,
      guard: guard,
      guard_call: guard_call,
      reason: nil
    }
  end

  defp other(id, file, function, class, reason) do
    %{
      id: id,
      site: %{file: file, function: function},
      class: class,
      action: nil,
      guard: nil,
      guard_call: nil,
      reason: reason
    }
  end
end
