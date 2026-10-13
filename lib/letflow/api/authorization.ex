defmodule Letflow.Api.Authorization do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Role/permission authorization matrix and 403 decision contract — ports
  `src/api/authorization.zig` (281 lines, R-Co). Pure module: no `Plug.Conn`,
  no I/O, never raises on any input. See
  `lib/letflow/design/req069-authorization.md` for the full design.

  ## Seven roles (REQ-447)

  `role/0` has seven members: `PLATFORM_ADMIN`, `PROCESS_DESIGNER`,
  `PROCESS_OPERATOR`, `TASK_WORKER`, `AGENT_RUNNER`, `CANDIDATE`, and
  `TENANT_ADMIN`. `TENANT_ADMIN` is allowed a permission iff
  `permission_scope/1` of it is `:tenant`; never a platform-scope permission,
  never `:Unknown` (see the `TENANT_ADMIN` clause of `core_role_allows?/2`).

  ## Untrusted input: roles are caller-influenced strings, not R-Co's enum

  `Letflow.Plugs.AuthPipeline` populates `conn.assigns[:auth_context][:roles]`
  from `Letflow.Oidc.ClaimMapping.resolve_roles/2`, whose contract is
  `[String.t()]` — an arbitrary list of strings taken from the bearer token's
  own claims. `roles_from_strings/1` converts that untrusted list into the
  closed `role/0` atom set: an unrecognized string is silently dropped (never
  raises, never widens to any role), and an all-unrecognized or empty input
  list both correctly yield `[]`, which `evaluate_access/2` treats identically
  to "the caller holds no role at all." `String.to_existing_atom/1` is
  deliberately NOT used for this conversion — it would let attacker-controlled
  token content reach the atom table, an unbounded-atom-creation vector.

  ## SECURITY (INV-2, INV-5)

  * **INV-2** — every decision `evaluate_access/2` returns is a pure function
    of its two arguments (`AccessContext.t()`, `endpoint_policy_key()`). There
    is no third parameter through which request-derived data (a query string,
    a body field, an `assignee_id` filter) could reach this function, so
    `AllowWithRowFilter`'s row scope can only ever be the `AccessContext`'s own
    `user_id` — never anything a caller supplies elsewhere in the same
    request. This is structural, not merely tested.
  * **INV-5** — this module answers only "is this action allowed," never
    "does this resource exist." A cross-tenant resource lookup must be
    resolved to 404 by REQ-072's request-context/scoping layer BEFORE
    `evaluate_access/2` is ever called with that resource in scope — routing a
    cross-tenant lookup through this module and returning its `Deny403` to the
    caller would let a prober distinguish "exists, not yours" from "never
    existed," which is exactly what INV-5 forbids. Wrong role, right tenant is
    correctly `Deny403`; any resource outside the caller's own tenant is
    REQ-072's 404, never this module's `Deny403`.

  ## Ported-but-currently-unreachable entries

  `AGENT_RUNNER` (role) and `DlqOperate`/`WebhooksManage` (permissions) have no
  S4 route consumer today — runtime agent orchestration, the DLQ, and webhook
  dispatch are all deferred subsystems. Ported anyway so the matrix matches
  R-Co's exactly, and so a later reader doesn't have to rediscover the gap.

  ## `AttachmentsManage`/`AttachmentsRead` (REQ-212) — genuinely new, not pre-ported

  Unlike `DlqOperate`/`WebhooksManage` above (ported ahead of their consuming
  routes, matching R-Co's matrix exactly even before any route consumed them),
  `AttachmentsManage` and `AttachmentsRead` have **no R-Co counterpart at
  all** — `instance_attachments` (REQ-211) is new functionality this
  migration invents, not a ported R-Co subsystem. Added *for*
  `Letflow.Routers.Instances`'s four `/instances/:id/attachments...` routes,
  immediately consumed, never in a "ported but currently unreachable" state.
  Two permissions, not one collapsed permission, is also a deliberate split
  (unlike `DlqOperate`/`WebhooksManage`'s single-permission precedent):
  `AttachmentsManage` gates upload/delete (mutation), `AttachmentsRead` gates
  list/download (read) — REQ-212's own acceptance criteria require the split
  kept, not collapsed. See design
  `lib/letflow/design/req212-instance-attachments-routes.md` §6.

  ## `Entities*` (REQ-309) — added ahead of their consuming router

  `:EntitiesDefinitionsRead`, `:EntitiesDefinitionsWrite`,
  `:EntitiesRecordsWrite` and `:EntitiesQuery` (plus their identically-named
  `endpoint_policy_key/0` values and the ten `endpoint_policy_key/2` clauses for
  `/entities/...`) are added by REQ-309 **before** `Letflow.Routers.Entities`
  exists — REQ-310 creates that router and mounts it. This is a compile-time
  precondition, not an oversight: `Letflow.Api.AuthorizedRouter`'s `authz_*`
  macros take the policy key as a literal and
  `test/letflow/api/authorization_enforcement_test.exs` asserts every declared
  route resolves to a real, non-`:Unknown` key, so a router declaring
  `:EntitiesDefinitionsRead` before that clause exists would fail immediately.
  Same "added ahead of its consuming route" state `:DlqOperate`/
  `:WebhooksManage` above already sat in. There is deliberately **no**
  `:EntitiesRecordsRead` atom — `Letflow.Entities.Records` exposes no read
  function and record reads happen only through `POST /entities/query`, so an
  `:EntitiesRecordsRead` would be dead vocabulary. See
  `lib/letflow/design/req308-entity-http-surface.md` §1 and §3.

  ## `EntitiesRecordsExport`/`EntitiesRecordsExportUnredacted`/`EntitiesRecordsImport` (REQ-318) — added ahead of their consuming routes

  Three more atoms, minted ahead of REQ-319/REQ-320's routes, the same
  "ported/added ahead of its consuming route" state `:DlqOperate`/
  `:WebhooksManage` and REQ-309's four `Entities*` atoms above already sat in
  — see `lib/letflow/design/req314-entity-record-bulk-export-import.md` §5.

  * `:EntitiesRecordsExport` — route-level, gates
    `POST /entities/records/:entity_type/export` (REQ-319). Real
    `endpoint_policy_key/2` clause.
  * `:EntitiesRecordsExportUnredacted` — **deliberately NOT route-level**.
    No `(method, path)` pair resolves to it via `endpoint_policy_key/2` — no
    route exists whose method+path maps to it, since it is checked a SECOND
    time, in-handler, only when an export request body carries
    `unredacted: true` (design §6 INV-2's two-tier mechanism). It still has a
    `required_permission/1` identity clause and a place in `permission()`/
    `endpoint_policy_key()`/`@permissions`, because REQ-319's handler calls
    `evaluate_access/2` against it directly, positionally, exactly as this
    module's own INV-2 moduledoc section above already establishes nothing
    requires the atom passed to `evaluate_access/2` to be one
    `endpoint_policy_key/2` itself resolves.
  * `:EntitiesRecordsImport` — route-level, gates
    `POST /entities/records/:entity_type/import` (REQ-320). Real
    `endpoint_policy_key/2` clause. Deliberately a genuinely separate grant
    from `:EntitiesRecordsWrite` — not a policy-key-only divergence mapped
    back onto it the way `:DefinitionsImport` maps back onto
    `:DefinitionsWrite` above (design §5 states why bulk record import is
    materially riskier than a single `create_record/2` call).

  Per design §5, this requirement deliberately adds **no** new
  `role_allows?/2` clause for `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, or
  `TASK_WORKER` against any of the three — only `PLATFORM_ADMIN`'s existing
  catch-all grants them today. A future REVIEWER-led role-matrix pass decides
  wider role assignment once REQ-319/REQ-320 ship; `:EntitiesRecordsExportUnredacted`
  in particular is flagged (design §5) as reserved for a break-glass/
  platform-administrative role, never bundled into an ordinary tenant role's
  default grant set.

  ## `EntitiesAttachmentsManage`/`EntitiesAttachmentsRead` (REQ-317) — genuinely new, not pre-ported

  Added *for* `Letflow.Routers.Entities`'s four
  `/entities/records/:entity_type/:record_id/attachments...` routes, per
  design `lib/letflow/design/req313-entity-record-attachments.md` §3/§4. Two
  NEW atoms, not a reuse of `:AttachmentsManage`/`:AttachmentsRead` (those
  gate `Letflow.Repository.Attachments`' instance_id-scoped table only) nor
  of `:EntitiesRecordsWrite` (that gates the record's own `field_values`
  payload, a different capability). Create/delete (mutation) map to
  `:EntitiesAttachmentsManage`; list/get-content (read) map to
  `:EntitiesAttachmentsRead`, matching REQ-212's own manage/read split. See
  design §7 (OQ-2) for the role matrix.

  ## `ExamSession*` (REQ-335) — genuinely new, not pre-ported, and CANDIDATE-reachable

  Five new atoms for `Letflow.Modules.Exam.Router`'s five routes
  (`:ExamSessionStart`, `:ExamSessionRead`, `:ExamSessionSave`,
  `:ExamSessionSubmit`, `:ExamSessionReportEvent`), each with a real
  `endpoint_policy_key/2` clause and an identity `required_permission/1`
  clause, the same shape as `Entities*` above.

  `CANDIDATE` (added by ISS-0646, see decision 0013's addendum) is a new,
  dedicated role holding exactly these five permissions and nothing else;
  `TASK_WORKER` no longer holds them. A candidate sitting an exam is an
  ordinary authenticated tenant user reaching their OWN session (every
  delegate call is additionally ownership-checked inside
  `Letflow.Modules.Exam.Session`/`Letflow.Modules.Exam.AntiCheat` themselves, ownership never
  being a function of role). `:PROCESS_DESIGNER`/`:PROCESS_OPERATOR`
  continue to not hold them, for the same reason as before — sitting an exam
  is not part of either role's existing grant shape; `PLATFORM_ADMIN`'s
  catch-all still covers an operator who also needs to probe a session.

  ## `PublicReadHandlesIssue` (REQ-352) — genuinely new, not pre-ported

  One new atom for `Letflow.Routers.PublicReadHandles`'s single
  `POST /public-read-handles` route (design
  `lib/letflow/design/req352-unauthenticated-read-platform.md` §13.1). Names
  the generic registry table (`public_read_handles`) and the one write
  operation it exposes (`issue`) — no vertical named, per that design's own
  vocabulary rule (§14/§15). Minted here, in the same diff as the route
  consuming it, since decision 0028's standing prohibition already places
  the writer this permission gates on this requirement's side of the
  read/write split. **Deliberately no `role_allows?/2` clause added for it
  against any non-`PLATFORM_ADMIN` role** — only `PLATFORM_ADMIN`'s existing
  catch-all grants it today; which role(s) beyond that hold it is left to
  the requirement that authors the first concrete issue path consuming this
  permission (REQ-355, per the design's §13.1).

  ## `HelpRead` (REQ-366 §1) — genuinely new, CANDIDATE deliberately excluded

  One new atom for `Letflow.Routers.Help`'s single `GET /help/resolved`
  route (design `lib/letflow/design/req366-help-display-panel.md` §1.3).
  Real `endpoint_policy_key/2` clause and identity `required_permission/1`
  clause, same shape as `Entities*`/`ExamSession*` above.

  Design §1.3 states this permission is "granted to all six roles...
  unconditionally on any recognized role" and flags that as its own **OQ-2**,
  explicitly inviting REVIEWER to judge a narrower grant instead. This
  module implements a **deliberate, flagged deviation** from that literal
  instruction: `role_allows?/2` grants `:HelpRead` to `PLATFORM_ADMIN`,
  `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`, and `AGENT_RUNNER`,
  but **not** `CANDIDATE`. Reason: `test/letflow/api/authorization_test.exs`'s
  ISS-0646 closed-set invariant test ("CANDIDATE must hold exactly its six
  ExamSession*/ExamCertificateIssue permissions and nothing else",
  decision 0013's addendum) already settled that `CANDIDATE`'s permission
  set is closed — silently widening it here would be exactly the "don't
  silently re-decide what a decision record already settled" case this
  project's core directives forbid. Flagged for SECURITY-REVIEWER/REVIEWER
  (this run's own next two gates) to make the actual call between keeping
  `CANDIDATE` excluded (this implementation) and widening ISS-0646's closed
  set for `:HelpRead` specifically (design §1.3's literal instruction). See
  `Letflow.Routers.Help`'s own moduledoc for the same note.

  ## `MembershipsRead` (REQ-384 Part A) — genuinely new, CANDIDATE excluded for the same reason as `HelpRead`

  One new atom for `Letflow.Routers.Identity`'s `GET /me/memberships` route
  (design `lib/letflow/design/req384-tenant-switcher-cache-isolation.md`
  §2.2). Real `endpoint_policy_key/2` clause and identity
  `required_permission/1` clause, same shape as `HelpRead`/`Entities*` above.

  Design §2.2 states this is "any authenticated user, no extra role gate —
  a user reading their own membership list is not a privileged operation."
  This module implements that as widely as `HelpRead`'s own precedent
  allows: `role_allows?/2` grants `:MembershipsRead` to `PLATFORM_ADMIN`,
  `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`, and `AGENT_RUNNER`,
  but **not** `CANDIDATE` — for the identical reason `HelpRead` excludes it
  (see that section above): `test/letflow/api/authorization_test.exs`'s
  ISS-0646 closed-set invariant ("CANDIDATE must hold exactly its six
  ExamSession*/ExamCertificateIssue permissions and nothing else") already
  settled `CANDIDATE`'s permission set as closed, so widening it here would
  silently re-decide that closed-set invariant rather than route it through
  REVIEWER/SECURITY-REVIEWER, which is exactly the deviation `HelpRead`
  already flags and defers to those two gates. A candidate account
  switching tenants was not named by any of REQ-384's acceptance criteria
  either. Flagged the same way as `HelpRead`'s section above, not silently
  narrowed.

  ## `:ModulesManage` (REQ-401) — same non-pattern as `:TenantsManage`

  One new core permission, added by REQ-401 to implement
  `docs/migration/decisions/0039-platform-module-solution-layering.md` D5.
  It gates module install (REQ-403, now wired — see `endpoint_policy_key/2`'s
  `"POST", "/tenant/modules"` clause and `required_permission/1`'s
  `:ModulesManage` identity clause below), solution install (REQ-415), and
  module-settings writes (REQ-414) — the latter two do not exist yet.
  Granted only via `PLATFORM_ADMIN`'s existing unconditional `true` clause —
  there is no explicit `role_allows?(some_role, :ModulesManage)` clause
  anywhere, exactly the way `:TenantsManage` is granted (its own total
  absence from every other role's clause, not a positive grant to imitate).

  ## `:MyModulesRead` (REQ-403) — role-agnostic, granted to every role including CANDIDATE

  One new core permission for `Letflow.Routers.Me`'s `GET /me/modules`
  route (design `lib/letflow/design/req403-module-install-route.md` §5.2,
  decided by ORCH 2026-09-24). Unlike `:MembershipsRead`/`:HelpRead` above,
  this permission is deliberately granted to **every** role, including
  `CANDIDATE` — it grows CANDIDATE's ISS-0646 closed permission set by
  exactly this one atom rather than leaving CANDIDATE excluded the way
  `:MembershipsRead` does. The grant is a single new **public**
  `role_allows?/2` clause — wildcard first argument, literal
  `:MyModulesRead` second argument, unconditional `true` body (see the real
  clause itself, below, for the exact text; not reproduced verbatim here so
  this doc paragraph itself does not count as a second grep hit for AC6's
  contract) — placed as the very first `def role_allows?/2` clause in this
  module —
  above the existing generic `role, permission` clause — so it short-
  circuits before `core_role_allows?/2`'s five per-role `defp` clauses (and
  before the Catalog `role_grants/1` fallback) are ever consulted for this
  one permission. No per-role list in `core_role_allows?/2` gains
  `:MyModulesRead` — this is intentional, not an oversight (AC6's grep
  contract checks exactly this).

  ## Catalog-sourced permissions and role grants (REQ-401, D4)

  `permissions/0` and `role_allows?/2` are both widened by REQ-401 to also
  recognize permissions declared by `Letflow.Modules.Catalog`'s registered
  modules (REQ-400) — atoms typed `atom()` at that boundary, never members
  of this module's own closed `permission()` union. `core_permissions/0`
  keeps returning the closed, core-only list `permissions/0` itself used to
  return before this requirement. See `core_permissions/0`, `permissions/0`,
  and the public `role_allows?/2` (which delegates to the renamed private
  `core_role_allows?/2`) below for the mechanics.
  """

  @type role ::
          :PLATFORM_ADMIN
          | :PROCESS_DESIGNER
          | :PROCESS_OPERATOR
          | :TASK_WORKER
          | :AGENT_RUNNER
          | :CANDIDATE
          | :TENANT_ADMIN

  @type permission ::
          :DefinitionsWrite
          | :DefinitionsRead
          | :InstancesStart
          | :InstancesCancel
          | :InstancesRead
          | :TasksRead
          | :TasksComplete
          | :TasksAssign
          | :UsersGroupsRolesManage
          | :TokensManage
          | :AuditRead
          | :DlqOperate
          | :MetricsRead
          | :WebhooksManage
          | :TenantsManage
          | :RolesManage
          | :AttachmentsManage
          | :AttachmentsRead
          | :InstancesAdvanceTimer
          | :EntitiesDefinitionsRead
          | :EntitiesDefinitionsWrite
          | :EntitiesRecordsWrite
          | :EntitiesQuery
          | :EntitiesAggregate
          | :EntitiesRecordsExport
          | :EntitiesRecordsExportUnredacted
          | :EntitiesRecordsImport
          | :EntitiesAttachmentsManage
          | :EntitiesAttachmentsRead
          | :EntitiesRestrictionsManage
          | :PublicReadHandlesIssue
          | :HelpRead
          | :MembershipsRead
          | :ModulesManage
          | :MyModulesRead
          | :PlatformServicesManage
          | :TenantSettingsManage
          | :PromotionsRead
          | :PromotionsManage
          | :DefinitionsRollback

  @type access_decision_kind :: :Allow | :Deny403 | :AllowWithRowFilter

  @type endpoint_policy_key ::
          :DefinitionsCreate
          | :DefinitionsUpdate
          | :DefinitionsPatch
          | :DefinitionsActivate
          | :DefinitionsDeprecate
          | :DefinitionsArchive
          | :DefinitionsDelete
          | :DefinitionsImport
          | :DefinitionsRead
          | :InstancesStart
          | :InstancesCancel
          | :InstancesRead
          | :TasksList
          | :TasksGetById
          | :TasksComplete
          | :TasksAssign
          | :TasksReassign
          | :UsersManage
          | :GroupsManage
          | :TokensManage
          | :AuditRead
          | :DlqReadRetryDiscard
          | :MetricsRead
          | :WebhookSubscriptionsManage
          | :ServicesRead
          | :AdminServicesManage
          | :AdminServicesRead
          | :TenantsManage
          | :RolesManage
          | :AttachmentsManage
          | :AttachmentsRead
          | :InstancesAdvanceTimer
          | :EntitiesDefinitionsRead
          | :EntitiesDefinitionsWrite
          | :EntitiesRecordsWrite
          | :EntitiesQuery
          | :EntitiesAggregate
          | :EntitiesRecordsExport
          | :EntitiesRecordsExportUnredacted
          | :EntitiesRecordsImport
          | :EntitiesAttachmentsManage
          | :EntitiesAttachmentsRead
          | :EntitiesRestrictionsManage
          | :PublicReadHandlesIssue
          | :HelpRead
          | :MembershipsRead
          | :ModulesManage
          | :MyModulesRead
          | :TenantSettingsManage
          | :PromotionsRead
          | :PromotionsManage
          | :DefinitionsRollback
          | :UnmatchedPlatformPath
          | :UnmatchedRoute
          | :Unknown

  @type task_row_scope :: :all | {:own_user_and_groups, String.t()}

  @roles [
    :PLATFORM_ADMIN,
    :PROCESS_DESIGNER,
    :PROCESS_OPERATOR,
    :TASK_WORKER,
    :AGENT_RUNNER,
    :CANDIDATE,
    :TENANT_ADMIN
  ]

  @permissions [
    :DefinitionsWrite,
    :DefinitionsRead,
    :InstancesStart,
    :InstancesCancel,
    :InstancesRead,
    :TasksRead,
    :TasksComplete,
    :TasksAssign,
    :UsersGroupsRolesManage,
    :TokensManage,
    :AuditRead,
    :DlqOperate,
    :MetricsRead,
    :WebhooksManage,
    :TenantsManage,
    :RolesManage,
    :AttachmentsManage,
    :AttachmentsRead,
    :InstancesAdvanceTimer,
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
    :PublicReadHandlesIssue,
    :HelpRead,
    :MembershipsRead,
    :ModulesManage,
    :MyModulesRead,
    :EntitiesRestrictionsManage,
    # ISS-0993 (design iss0993-platform-scope-separation.md section 5)
    :PlatformServicesManage,
    :TenantSettingsManage,
    :PromotionsRead,
    :PromotionsManage,
    :DefinitionsRollback
  ]

  # ISS-0993 section 5: every core permission has exactly one scope. A test
  # asserts this map's key set equals core_permissions/0, so a new core
  # permission without a scope fails the suite. :MetricsRead is TENANT scope
  # (OQ-13, ratified: /health and /metrics routes are global-public and stay
  # outside the pin; only the permission atom is classified).
  @platform_permissions [:TenantsManage, :PlatformServicesManage]

  @permission_scope Map.new(
                      @permissions,
                      fn permission ->
                        {permission,
                         if(permission in @platform_permissions, do: :platform, else: :tenant)}
                      end
                    )

  @doc "All seven `Role` values, R-Co's exact names plus ISS-0646's `CANDIDATE` and REQ-447's `TENANT_ADMIN` (every tenant-scope permission, never a platform-scope one). See `roles_from_strings/1` for untrusted-input conversion."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc """
  All forty core `Permission` values — R-Co's fourteen, plus REQ-075's
  `:TenantsManage`, plus REQ-076's `:RolesManage`, plus REQ-212's
  `:AttachmentsManage`/`:AttachmentsRead`, plus ISS-0389's
  `:InstancesAdvanceTimer`, plus REQ-309's four entity-subsystem permissions
  (`:EntitiesDefinitionsRead`, `:EntitiesDefinitionsWrite`,
  `:EntitiesRecordsWrite`, `:EntitiesQuery`), plus REQ-315's
  `:EntitiesAggregate`, plus REQ-318's three entity-record export/import
  permissions (`:EntitiesRecordsExport`, `:EntitiesRecordsExportUnredacted`,
  `:EntitiesRecordsImport`), plus REQ-317's `:EntitiesAttachmentsManage`/
  `:EntitiesAttachmentsRead`, plus REQ-352's `:PublicReadHandlesIssue`, plus
  REQ-366's `:HelpRead`, plus REQ-384's `:MembershipsRead`, plus REQ-401's
  `:ModulesManage`, plus REQ-403's `:MyModulesRead`, plus ISS-0935's
  `:EntitiesRestrictionsManage` (the new `POST /entities/restrictions/import`
  bulk write path for `entity_field_restrictions`/`user_entity_grants`/
  `entity_type_restrictions`/`user_entity_type_grants` — a distinct
  permission from `:EntitiesDefinitionsWrite`, per
  `lib/letflow/design/iss0935-vortex-entity-seed.md` §1.3's own
  justification for not reusing it), plus ISS-0993's `:PlatformServicesManage`,
  `:TenantSettingsManage`, `:PromotionsRead`, `:PromotionsManage` and
  `:DefinitionsRollback`. Each has exactly one scope, see `permission_scope/1`.

  The stated core count is asserted against `length(core_permissions())` by
  `test/letflow/api/authorization_test.exs` (REQ-309 AC1), computed rather than
  hardcoded, so it cannot go stale again the way "eighteen" did (the list held
  nineteen entries before REQ-309).
  """
  @spec core_permissions() :: [permission()]
  def core_permissions, do: @permissions

  @doc """
  Every permission the platform recognizes: the core
  `Permission` values above (`core_permissions/0`), followed by every
  registered module's own declared permissions
  (`Letflow.Modules.Catalog.permissions/0`, REQ-400/REQ-401, D4) — computed,
  not a second hardcoded list. A module's own permission atoms are typed
  `atom()` at the Catalog boundary, never members of this module's closed
  `permission()` union, hence the widened `@spec`. No dedup is performed
  between the two halves here — `Letflow.Modules.Catalog.validate/1`'s
  `{:core_permission_collision, _}` rule (checked against
  `core_permissions/0`, not this function) is what keeps them disjoint.
  """
  @spec permissions() :: [permission() | atom()]
  def permissions, do: core_permissions() ++ Letflow.Modules.Catalog.permissions()

  @doc """
  The scope of a permission, `:platform` or `:tenant` (ISS-0993 section 5; pure
  and total). A core permission is looked up in the compile-time table; an atom
  in `Letflow.Modules.Catalog.permissions/0` is `:tenant` (every module
  permission is tenant scope, REQ-445 D3); ANY OTHER term is `:platform`
  (fail closed: an unclassified permission is never honoured outside the
  platform tenant).
  """
  @spec permission_scope(permission() | atom() | term()) :: :platform | :tenant
  def permission_scope(permission) do
    case Map.fetch(@permission_scope, permission) do
      {:ok, scope} ->
        scope

      :error ->
        if is_atom(permission) and permission in Letflow.Modules.Catalog.permissions(),
          do: :tenant,
          else: :platform
    end
  end

  @doc "The permissions of `:platform` scope, derived from the scope table."
  @spec platform_permissions() :: [permission()]
  def platform_permissions, do: @platform_permissions

  defmodule AccessContext do
    # PROVENANCE (historical, not current decision authority):
    @moduledoc """
    Ports `authorization.zig`'s `AccessContext` struct. ISS-0993 adds
    `platform_tenant?` (default `false`, not enforced, so every existing
    construction stays valid and fails closed): whether the caller's
    database-resolved tenant is the configured platform tenant.
    """
    @enforce_keys [:user_id, :roles]
    defstruct [:user_id, :roles, platform_tenant?: false]

    @type t :: %__MODULE__{
            user_id: String.t(),
            roles: [Letflow.Api.Authorization.role()],
            platform_tenant?: boolean()
          }
  end

  defmodule AccessDecision do
    # PROVENANCE (historical, not current decision authority):
    @moduledoc "Ports `authorization.zig`'s `AccessDecision` struct."
    @enforce_keys [:kind]
    defstruct kind: nil, task_scope: nil

    @type t :: %__MODULE__{
            kind: Letflow.Api.Authorization.access_decision_kind(),
            task_scope: Letflow.Api.Authorization.task_row_scope() | nil
          }
  end

  @doc """
  Converts an untrusted list of role strings (as read from
  `conn.assigns[:auth_context][:roles]`) into the closed `role/0` atom set.
  An unrecognized string is silently dropped — never raises, never widens to
  any role. `String.to_existing_atom/1` is deliberately not used (see
  moduledoc). An empty or all-unrecognized input list both correctly yield
  `[]`.
  """
  @spec roles_from_strings([String.t()]) :: [role()]
  def roles_from_strings(role_strings) when is_list(role_strings) do
    Enum.reduce(role_strings, [], fn s, acc ->
      case role_from_string(s) do
        nil -> acc
        role -> [role | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  @doc """
  REQ-447 PR 2 (design section 3.5): the ONE shared resolution of a caller's
  roles. Parses `role_strings` with `roles_from_strings/1` and, unless
  `platform_tenant?` is exactly `true`, removes `:PLATFORM_ADMIN`, so a stored
  row, a token claim or a hand-built context confers nothing of `PLATFORM_ADMIN`
  outside the platform tenant (0046 D2/D4). A non-list input is `[]`.
  """
  @spec effective_roles([String.t()] | term(), boolean() | term()) :: [role()]
  def effective_roles(role_strings, platform_tenant?) when is_list(role_strings) do
    roles = roles_from_strings(role_strings)

    if platform_tenant? == true,
      do: roles,
      else: List.delete(roles, :PLATFORM_ADMIN)
  end

  def effective_roles(_other, _platform_tenant?), do: []

  @doc """
  ISS-0993 hardening H1 (design section 10): true iff `name` is, or could be
  mistaken for, the `PLATFORM_ADMIN` role name. ONE predicate for the
  `POST /roles` guard: it is built on `roles_from_strings/1` (the parser that
  turns stored and token role strings into roles, so any alias the parser later
  accepts is covered by construction) OR a deliberately stricter fold
  (`String.trim/1` + `String.upcase/1`) so a later loosening of the parser
  cannot open a bypass. A non-binary `name` is `false` (the handler 422s it
  before this check).
  """
  @spec platform_admin_name?(term()) :: boolean()
  def platform_admin_name?(name) when is_binary(name) do
    :PLATFORM_ADMIN in roles_from_strings([name]) or
      name |> String.trim() |> String.upcase() == "PLATFORM_ADMIN"
  end

  def platform_admin_name?(_other), do: false

  @doc """
  REQ-447 H2 (design section 3.6): true iff `name` is the name of ANY role of
  `roles/0` (so `TENANT_ADMIN`, `PLATFORM_ADMIN` and any later built-in), compared
  after the same stricter trim + upcase fold as `platform_admin_name?/1`, or when
  `platform_admin_name?/1` is true. A non-binary `name` is `false`. ONE predicate
  for the `POST /roles` built-in-name guard.
  """
  @spec builtin_role_name?(term()) :: boolean()
  def builtin_role_name?(name) when is_binary(name) do
    folded = name |> String.trim() |> String.upcase()

    platform_admin_name?(name) or
      Enum.any?(@roles, &(Atom.to_string(&1) == folded))
  end

  def builtin_role_name?(_other), do: false

  defp role_from_string("PLATFORM_ADMIN"), do: :PLATFORM_ADMIN
  defp role_from_string("PROCESS_DESIGNER"), do: :PROCESS_DESIGNER
  defp role_from_string("PROCESS_OPERATOR"), do: :PROCESS_OPERATOR
  defp role_from_string("TASK_WORKER"), do: :TASK_WORKER
  defp role_from_string("AGENT_RUNNER"), do: :AGENT_RUNNER
  defp role_from_string("CANDIDATE"), do: :CANDIDATE
  defp role_from_string("TENANT_ADMIN"), do: :TENANT_ADMIN
  defp role_from_string(_other), do: nil

  @doc """
  PROVENANCE (historical, not current decision authority):
  Maps an HTTP method + path template to an `endpoint_policy_key/0`. Ports
  `endpointPolicyKey/2` (authorization.zig L77-112) exactly, including the
  SVC-04 service-catalog entries.
  """
  @spec endpoint_policy_key(String.t(), String.t()) :: endpoint_policy_key() | atom()
  def endpoint_policy_key(method, path_template)

  def endpoint_policy_key("POST", "/definitions"), do: :DefinitionsCreate
  def endpoint_policy_key("PUT", "/definitions/:id"), do: :DefinitionsUpdate
  def endpoint_policy_key("PATCH", "/definitions/:id"), do: :DefinitionsPatch
  def endpoint_policy_key("POST", "/definitions/:id/activate"), do: :DefinitionsActivate

  # PROVENANCE (historical, not current decision authority):
  # REQ-082 -- deprecate/archive/delete/import. authorization.zig has NO
  # entries for these four (confirmed by grep against that source, zero hits) --
  # same "no endpoint_policy_key clause, not permission-gated" pattern REQ-078/079
  # already established for rebind-pins/reconstruct. REQ-082's own acceptance
  # criterion 7 ("a caller without DefinitionsWrite receives 403 on all eight
  # endpoints") is a DELIBERATE Letflow-side divergence from that R-Co gap, not an
  # oversight -- these four route-local mutations are exactly the kind of state
  # change REQ-131's future policy work is meant to generalize, but REQ-082's own
  # acceptance criteria require the gate now rather than deferring it, so these four
  # get real endpoint_policy_key clauses (all mapping to :DefinitionsWrite, same as
  # the four R-Co-sourced ones above) instead of joining the rebind-pins/reconstruct
  # no-clause precedent.
  def endpoint_policy_key("POST", "/definitions/:id/deprecate"), do: :DefinitionsDeprecate
  def endpoint_policy_key("POST", "/definitions/:id/archive"), do: :DefinitionsArchive
  def endpoint_policy_key("DELETE", "/definitions/:id"), do: :DefinitionsDelete
  def endpoint_policy_key("POST", "/definitions/import"), do: :DefinitionsImport

  def endpoint_policy_key("GET", path) when path in ["/definitions", "/definitions/:id"],
    do: :DefinitionsRead

  # REQ-081 -- same permission, three more path templates, no new atom.
  # REQ-125 adds a fourth (/definitions/delta), same permission, still no
  # new atom.
  def endpoint_policy_key("GET", path)
      when path in [
             "/definitions/active/:name",
             "/definitions/search",
             "/definitions/:id/export",
             "/definitions/delta"
           ],
      do: :DefinitionsRead

  def endpoint_policy_key("POST", "/instances"), do: :InstancesStart
  def endpoint_policy_key("POST", "/instances/:id/cancel"), do: :InstancesCancel

  # ISS-0389 -- a genuine new permission, fully wired (not the
  # rebind-pins/reconstruct ad-hoc route-declared-atom pattern; see
  # lib/letflow/design/iss0389-advance-timer-endpoint.md Decision 2).
  def endpoint_policy_key("POST", "/instances/:id/advance-timer"),
    do: :InstancesAdvanceTimer

  def endpoint_policy_key("GET", path)
      when path in [
             "/instances",
             "/instances/:id",
             "/instances/:id/history",
             "/instances/:id/timeline",
             "/instances/:id/pins"
           ],
      do: :InstancesRead

  def endpoint_policy_key("GET", "/tasks"), do: :TasksList

  # PROVENANCE (historical, not current decision authority):
  # REQ-083 (OQ-8) -- GET /tasks/inbox maps to the same :TasksList policy key
  # as GET /tasks, because there is only one evaluateAccess call site for
  # this whole flow: handleInbox (tasks.zig L960-982) builds a
  # ListTasksParams and calls handleList itself, which is where that ONLY
  # evaluateAccess call happens -- handleInbox performs no authorization
  # call of its own. Additive-only: changes no existing clause's behavior, since every
  # endpoint_policy_key/2 call site is matched by exact string.
  def endpoint_policy_key("GET", "/tasks/inbox"), do: :TasksList

  def endpoint_policy_key("GET", "/tasks/:id"), do: :TasksGetById
  def endpoint_policy_key("POST", "/tasks/:id/complete"), do: :TasksComplete

  # REQ-085 (design doc §2) -- claim is gated by the SAME :TasksComplete
  # permission /complete uses, not :TasksAssign (same as handleClaim's own
  # evaluateAccess(..., .TasksComplete) call): TASK_WORKER holds
  # :TasksComplete but not :TasksAssign, and a task worker claiming a
  # group/role-assigned task before completing it is exactly the caller this
  # endpoint exists for. Additive-only, no existing clause's behavior changes.
  def endpoint_policy_key("POST", "/tasks/:id/claim"), do: :TasksComplete
  def endpoint_policy_key("POST", "/tasks/:id/assign"), do: :TasksAssign
  def endpoint_policy_key("POST", "/tasks/:id/reassign"), do: :TasksReassign

  def endpoint_policy_key("POST", "/users"), do: :UsersManage
  def endpoint_policy_key("GET", path) when path in ["/users", "/users/:id"], do: :UsersManage
  def endpoint_policy_key("PATCH", "/users/:id"), do: :UsersManage
  def endpoint_policy_key("POST", "/users/:id/status"), do: :UsersManage

  def endpoint_policy_key(method, "/groups" <> _rest)
      when method in ["POST", "DELETE", "GET"],
      do: :GroupsManage

  def endpoint_policy_key(method, "/tokens" <> _rest)
      when method in ["POST", "GET", "DELETE"],
      do: :TokensManage

  def endpoint_policy_key("GET", "/audit"), do: :AuditRead

  def endpoint_policy_key(method, "/dlq" <> _rest) when method in ["GET", "POST"],
    do: :DlqReadRetryDiscard

  def endpoint_policy_key("GET", "/metrics"), do: :MetricsRead

  def endpoint_policy_key(method, "/webhooks/subscriptions")
      when method in ["POST", "GET"],
      do: :WebhookSubscriptionsManage

  def endpoint_policy_key("GET", "/webhooks/subscriptions/:id/deliveries"),
    do: :WebhookSubscriptionsManage

  # REQ-182 -- the PATCH route this requirement adds
  # (Letflow.Routers.Webhooks) was, until now, the one confirmed real gap in
  # this endpoint-policy-key table: no clause existed for
  # PATCH "/webhooks/subscriptions/:id" even though GET/POST on the
  # collection and DELETE on the member route were already mapped below and
  # above. Same policy key as the other three /webhooks/subscriptions...
  # clauses -- no new permission atom, no new required_permission/1 clause.
  def endpoint_policy_key("PATCH", "/webhooks/subscriptions/:id"),
    do: :WebhookSubscriptionsManage

  def endpoint_policy_key("DELETE", "/webhooks/subscriptions/:id"),
    do: :WebhookSubscriptionsManage

  def endpoint_policy_key("GET", "/services"), do: :ServicesRead
  def endpoint_policy_key("GET", "/admin/services"), do: :AdminServicesRead

  def endpoint_policy_key(method, "/admin/services" <> _rest)
      when method in ["POST", "PATCH", "DELETE"],
      do: :AdminServicesManage

  # REQ-075 — tenant administration (Letflow.Routers.Tenants), a top-level
  # sibling router, NOT under Letflow.Routers.Identity's own /identity mount
  # (see that router's own moduledoc for why). One permission
  # (:TenantsManage), granted to PLATFORM_ADMIN only via the existing
  # catch-all clause in role_allows?/2 — no new role clauses added anywhere.
  def endpoint_policy_key("POST", "/tenants"), do: :TenantsManage

  def endpoint_policy_key("GET", path) when path in ["/tenants", "/tenants/:slug"],
    do: :TenantsManage

  def endpoint_policy_key("PATCH", "/tenants/:slug"), do: :TenantsManage
  def endpoint_policy_key("POST", "/tenants/:slug/deactivate"), do: :TenantsManage
  def endpoint_policy_key("POST", "/tenants/:slug/reactivate"), do: :TenantsManage

  # REQ-382 / ISS-0993 -- authenticated write path onto the caller's OWN
  # tenant.settings (Letflow.Routers.TenantSettings), mounted at /tenant/settings
  # (no target-tenant parameter: the tenant patched is always the caller's own,
  # from conn.assigns.auth_context.tenant_id). Own-tenant, TENANT scope: the
  # dedicated :TenantSettingsManage permission (it was :TenantsManage, which is
  # now the PLATFORM-scope registry permission).
  def endpoint_policy_key("PATCH", "/tenant/settings"), do: :TenantSettingsManage

  # REQ-076 -- onboarding (Letflow.Routers.Onboarding), a top-level sibling
  # router mounted at /onboarding (not under Letflow.Routers.Identity's own
  # /identity mount). Reuses the existing :TenantsManage permission -- same
  # risk class and same PLATFORM_ADMIN-only intent as Letflow.Routers.Tenants
  # (design doc §8.3). No new permission added for onboarding.
  def endpoint_policy_key("POST", "/onboarding"), do: :TenantsManage
  def endpoint_policy_key("GET", "/onboarding/:id"), do: :TenantsManage
  def endpoint_policy_key("GET", "/onboarding"), do: :TenantsManage
  # ISS-1030 -- bind-once realm route; same gate as the three above.
  def endpoint_policy_key("POST", "/onboarding/:id/bind-realm"), do: :TenantsManage

  # REQ-374 -- platform-wide tenant-migration fanout runner
  # (Letflow.Routers.PlatformMigrations), a top-level sibling router mounted
  # at /platform-migrations (not under Letflow.Routers.Identity's own
  # /identity mount). Reuses the existing :TenantsManage permission -- same
  # risk class and same PLATFORM_ADMIN-only intent as Letflow.Routers.Tenants
  # and Letflow.Routers.Onboarding (design doc §7). No new permission added.
  def endpoint_policy_key("POST", "/platform-migrations/rollouts"), do: :TenantsManage
  def endpoint_policy_key("GET", "/platform-migrations/rollouts/:id"), do: :TenantsManage

  def endpoint_policy_key("POST", "/platform-migrations/rollouts/:id/resume"),
    do: :TenantsManage

  # REQ-377 -- platform-wide event-history retirement screen
  # (Letflow.Routers.EventRetention), a top-level sibling router mounted at
  # /event-retention (not under Letflow.Routers.Identity's own /identity
  # mount). Reuses the existing :TenantsManage permission -- same risk
  # class and same PLATFORM_ADMIN-only intent as Letflow.Routers.Tenants,
  # Letflow.Routers.Onboarding, and Letflow.Routers.PlatformMigrations
  # (design doc §2.3). No new permission added.
  def endpoint_policy_key("GET", "/event-retention/summary"), do: :TenantsManage
  def endpoint_policy_key("POST", "/event-retention/retirements"), do: :TenantsManage
  def endpoint_policy_key("GET", "/event-retention/retirements/:id"), do: :TenantsManage

  # ISS-0993 -- the twelve routes that used to be declared with plain
  # get/post macros (no policy key -> :Unknown) now carry explicit keys, all
  # TENANT scope (design iss0993-platform-scope-separation.md section 7.2, rows
  # 23-34). Cross-tenant naming (a source/target tenant other than the caller's)
  # is separately operator-only (Letflow.PlatformTenant.cross_tenant_promotion_operator_only?/0,
  # OQ-2); own-tenant review lifecycle and definition rollback stay tenant scope.
  def endpoint_policy_key("POST", path) when path in ["/promotions", "/promotions/plan"],
    do: :PromotionsManage

  def endpoint_policy_key("POST", path)
      when path in [
             "/promotions/:id/approve",
             "/promotions/:id/reject",
             "/promotions/:id/apply",
             "/promotions/:review_id/run-assertions"
           ],
      do: :PromotionsManage

  def endpoint_policy_key("GET", path)
      when path in [
             "/promotions",
             "/promotions/platform-events",
             "/promotions/:id",
             "/promotions/:id/context"
           ],
      do: :PromotionsRead

  def endpoint_policy_key("POST", "/definitions/:process_key/rollback"),
    do: :DefinitionsRollback

  def endpoint_policy_key("POST", "/tenants/:test_tenant_id/promote/:process_key"),
    do: :PromotionsManage

  # REQ-076 -- role registry routes (Letflow.Routers.Identity, mounted
  # relative to /identity, matching the "/tokens" convention above). A new,
  # distinct :RolesManage permission -- see role_allows?/2's PROCESS_DESIGNER
  # clause below for why :UsersGroupsRolesManage cannot be reused here
  # (design doc §4 point 2).
  def endpoint_policy_key("GET", "/roles"), do: :RolesManage
  def endpoint_policy_key("POST", "/roles"), do: :RolesManage

  # REQ-212 — instance-attachment routes (Letflow.Routers.Instances), mounted
  # under /instances/:id/attachments... See design §6.3.
  def endpoint_policy_key("POST", "/instances/:id/attachments"), do: :AttachmentsManage

  def endpoint_policy_key("DELETE", "/instances/:id/attachments/:attachment_id"),
    do: :AttachmentsManage

  def endpoint_policy_key("GET", "/instances/:id/attachments"), do: :AttachmentsRead

  def endpoint_policy_key("GET", "/instances/:id/attachments/:attachment_id"),
    do: :AttachmentsRead

  # REQ-386 — signed, time-limited attachment links. Same :AttachmentsRead
  # permission as the existing content route (see design
  # lib/letflow/design/req386-attachment-signed-links.md §5).
  def endpoint_policy_key("POST", "/instances/:id/attachments/:attachment_id/link"),
    do: :AttachmentsRead

  def endpoint_policy_key("GET", "/instances/:id/attachments/:attachment_id/link-content"),
    do: :AttachmentsRead

  # REQ-392 — tenant-wide storage-usage figure (Letflow.Routers.Instances),
  # design lib/letflow/design/req392-attachment-management-ui.md §1.2. Reuses
  # :AttachmentsRead (attachment-adjacent read, no new permission class) —
  # same reasoning as the /link-content route above.
  def endpoint_policy_key("GET", "/instances/storage-usage"), do: :AttachmentsRead

  # REQ-309 — entity-subsystem routes (the future `Letflow.Routers.Entities`,
  # mounted at `/entities`), per design
  # `lib/letflow/design/req308-entity-http-surface.md` §1's route table and §3's
  # permission vocabulary. Path templates are the FULL external paths as seen
  # after the `/api/v1` prefix is stripped — the same convention every clause
  # above uses ("/instances/:id/attachments", not a router-local
  # "/:id/attachments").
  #
  # These four atoms are minted AHEAD of the router that consumes them
  # (REQ-310 creates `lib/letflow/routers/entities.ex`), the same
  # "ported/added ahead of its consuming route" state `:DlqOperate` and
  # `:WebhooksManage` sat in — see this module's moduledoc. Until that router
  # exists, `authorization_enforcement_test.exs` simply never walks these
  # clauses (it iterates the routers that exist), which is the deliberate,
  # temporary end state of REQ-309.
  #
  # One policy key per permission (no `:DefinitionsCreate`/`:DefinitionsUpdate`-
  # style split collapsing into one permission), so the endpoint_policy_key
  # names and the permission names are identical — required_permission/1's four
  # identity clauses below, same shape as `:AttachmentsManage`/`:AttachmentsRead`.
  def endpoint_policy_key("GET", path)
      when path in [
             "/entities/definitions",
             "/entities/definitions/:id",
             "/entities/definitions/active/:name",
             "/entities/definitions/by-name/:name"
           ],
      do: :EntitiesDefinitionsRead

  def endpoint_policy_key("POST", "/entities/definitions"), do: :EntitiesDefinitionsWrite

  def endpoint_policy_key("POST", "/entities/definitions/:name/activate"),
    do: :EntitiesDefinitionsWrite

  def endpoint_policy_key("POST", "/entities/records/:entity_type"), do: :EntitiesRecordsWrite

  def endpoint_policy_key("PUT", "/entities/records/:entity_type/:record_id"),
    do: :EntitiesRecordsWrite

  def endpoint_policy_key("DELETE", "/entities/records/:entity_type/:record_id"),
    do: :EntitiesRecordsWrite

  # Non-mutating read declared on POST because the query DSL's request shape
  # needs a body (design §4), so :EntitiesQuery is classified read (design §3)
  # despite gating a POST. NOTE: an earlier draft of this comment cited POST
  # /definitions/:id/validate as precedent for a POST carrying a read
  # permission. That is wrong and was corrected here — that route has no
  # endpoint_policy_key/2 clause at all and resolves to :Unknown (asserted in
  # authorization_test.exs). This clause is the first POST-with-read-permission
  # in this module, justified on design §4's own reasoning, not on precedent.
  def endpoint_policy_key("POST", "/entities/query"), do: :EntitiesQuery

  # REQ-315 — aggregation/reporting query route (design
  # lib/letflow/design/req312-query-aggregation.md §3). A distinct atom, not
  # :EntitiesQuery reused — see that design's §3 for why (an aggregate can
  # disclose tenant-wide statistical information a row-level, individually
  # redactable read does not, so the two capabilities stay independently
  # grantable). Classified read, same POST-with-a-body reasoning as
  # :EntitiesQuery immediately above.
  def endpoint_policy_key("POST", "/entities/query/aggregate"), do: :EntitiesAggregate

  # REQ-318 — entity-record bulk export/import routes (REQ-319/REQ-320
  # implement the routers that consume these; see this module's moduledoc and
  # design `lib/letflow/design/req314-entity-record-bulk-export-import.md` §4/§5).
  # `:EntitiesRecordsExportUnredacted` deliberately gets NO clause here — no
  # (method, path) pair resolves to it; it is checked a second time, in-handler,
  # only when the export request body carries `unredacted: true`.
  def endpoint_policy_key("POST", "/entities/records/:entity_type/export"),
    do: :EntitiesRecordsExport

  def endpoint_policy_key("POST", "/entities/records/:entity_type/import"),
    do: :EntitiesRecordsImport

  # ISS-0935 — bulk-import write route for the four restriction/grant
  # tables (design `lib/letflow/design/iss0935-vortex-entity-seed.md` §1.3).
  # A NEW, distinct atom — not a reuse of `:EntitiesDefinitionsWrite` — see
  # that design doc's §1.3 for the full "why a new permission" reasoning.
  def endpoint_policy_key("POST", "/entities/restrictions/import"),
    do: :EntitiesRestrictionsManage

  # REQ-317 — record-attachment routes (Letflow.Routers.Entities), per
  # design `lib/letflow/design/req313-entity-record-attachments.md` §3's
  # route table and §4's permission vocabulary. Two NEW atoms
  # (`:EntitiesAttachmentsManage`/`:EntitiesAttachmentsRead`), not a reuse of
  # `:AttachmentsManage`/`:AttachmentsRead` (those gate
  # Letflow.Repository.Attachments' instance_id-scoped table only) nor of
  # `:EntitiesRecordsWrite` (that gates the record's own field_values
  # payload, a different capability) — see design §4 for the full
  # not-reused reasoning. Create/delete (mutation) map to
  # :EntitiesAttachmentsManage; list/get-content (read) map to
  # :EntitiesAttachmentsRead, matching REQ-212's own manage/read split.
  def endpoint_policy_key(
        "POST",
        "/entities/records/:entity_type/:record_id/attachments"
      ),
      do: :EntitiesAttachmentsManage

  def endpoint_policy_key(
        "GET",
        "/entities/records/:entity_type/:record_id/attachments"
      ),
      do: :EntitiesAttachmentsRead

  def endpoint_policy_key(
        "GET",
        "/entities/records/:entity_type/:record_id/attachments/:attachment_id"
      ),
      do: :EntitiesAttachmentsRead

  def endpoint_policy_key(
        "DELETE",
        "/entities/records/:entity_type/:record_id/attachments/:attachment_id"
      ),
      do: :EntitiesAttachmentsManage

  # REQ-352 — the generic, kind-agnostic authenticated issue route
  # (Letflow.Routers.PublicReadHandles), mounted at /public-read-handles.
  # See design lib/letflow/design/req352-unauthenticated-read-platform.md §13.1.
  def endpoint_policy_key("POST", "/public-read-handles"), do: :PublicReadHandlesIssue

  # REQ-366 §1 — Letflow.Routers.Help's single route, mounted at /help. See
  # this module's moduledoc "HelpRead" section and
  # lib/letflow/design/req366-help-display-panel.md §1.1/§1.3.
  def endpoint_policy_key("GET", "/help/resolved"), do: :HelpRead

  # REQ-384 Part A — Letflow.Routers.Me's single route, mounted at /me by
  # Letflow.Plugs.ApiPipeline (full path /api/v1/me/memberships, per design
  # §2.2's explicit route). See this module's moduledoc "MembershipsRead"
  # section.
  def endpoint_policy_key("GET", "/me/memberships"), do: :MembershipsRead

  # REQ-403 — Letflow.Routers.TenantModules' single route, mounted at
  # /tenant/modules. See this module's moduledoc "MyModulesRead" section and
  # lib/letflow/design/req403-module-install-route.md §5.3.
  def endpoint_policy_key("POST", "/tenant/modules"), do: :ModulesManage

  # REQ-414 — settings write for an installed module.
  def endpoint_policy_key("PUT", "/tenant/modules/:module_id/settings"), do: :ModulesManage

  # REQ-415 — solution install: one atomic call installs a bundle of modules
  # in dependency order. Same :ModulesManage gate as the per-module install
  # route above (PLATFORM_ADMIN-only, per REQ-401/D5).
  def endpoint_policy_key("POST", "/tenant/solutions"), do: :ModulesManage

  # REQ-403 — Letflow.Routers.Me's new route, mounted at /me (full path
  # /api/v1/me/modules). See this module's moduledoc "MyModulesRead" section
  # and lib/letflow/design/req403-module-install-route.md §5.3.
  def endpoint_policy_key("GET", "/me/modules"), do: :MyModulesRead

  # REQ-401 §4 — the Catalog-module route fallback. Every module route is
  # mounted at `/modules/<id>/<rest>` (relative to `/api/v1`, same convention
  # every clause above uses). Resolves to the permission atom the module's
  # own manifest `route_policies` declares for `(method, "/" <> rest)`, or
  # `:Unknown` if the module id is unregistered or no route_policies entry
  # matches — see `module_route_permission/3` below. Inserted immediately
  # before the final catch-all; every clause above keeps its exact position
  # and body, so no existing (method, path) pair's result changes.
  def endpoint_policy_key(method, "/modules/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [module_id, sub_path] -> module_route_permission(method, module_id, "/" <> sub_path)
      [_module_id] -> :Unknown
    end
  end

  def endpoint_policy_key(_method, _path), do: :Unknown

  @spec module_route_permission(String.t(), String.t(), String.t()) :: atom()
  defp module_route_permission(method, module_id, sub_path) do
    case Letflow.Modules.Catalog.fetch(module_id) do
      {:error, :not_found} ->
        :Unknown

      {:ok, entry_module} ->
        entry_module.manifest().route_policies
        |> Enum.find(fn {route_method, path_pattern, _permission} ->
          route_method == method and path_pattern == sub_path
        end)
        |> case do
          nil -> :Unknown
          {_method, _path_pattern, permission} -> permission
        end
    end
  end

  @doc """
  PROVENANCE (historical, not current decision authority):
  Ports `evaluateAccess/2` (authorization.zig L114-139) exactly, branch order
  included.
  """
  @spec evaluate_access(AccessContext.t(), endpoint_policy_key()) :: AccessDecision.t()
  def evaluate_access(%AccessContext{} = ctx, endpoint) do
    cond do
      # ISS-0993 rule 1 (design section 6, A2): `:Unknown` is denied for EVERY
      # role, PLATFORM_ADMIN included. Every route declares an explicit key;
      # router catch-alls carry the markers below instead.
      endpoint == :Unknown ->
        %AccessDecision{kind: :Deny403, task_scope: nil}

      # ISS-0993 rule 1a (design section 6/7.5): router catch-all markers (not
      # permissions, not routes). :UnmatchedPlatformPath (the five platform
      # prefixes) lets only a platform-tenant PLATFORM_ADMIN reach the router's
      # 404, so every other caller gets the same 403 as a matched platform
      # route (OQ-4). :UnmatchedRoute needs the platform flag too (REQ-447 LOW-3).
      endpoint == :UnmatchedPlatformPath ->
        if ctx.platform_tenant? == true and has_role?(ctx.roles, :PLATFORM_ADMIN),
          do: %AccessDecision{kind: :Allow, task_scope: nil},
          else: %AccessDecision{kind: :Deny403, task_scope: nil}

      endpoint == :UnmatchedRoute ->
        if ctx.platform_tenant? == true and has_role?(ctx.roles, :PLATFORM_ADMIN),
          do: %AccessDecision{kind: :Allow, task_scope: nil},
          else: %AccessDecision{kind: :Deny403, task_scope: nil}

      endpoint == :MetricsRead ->
        %AccessDecision{kind: :Allow, task_scope: :all}

      true ->
        # REQ-447 PR 2: the same non-platform PLATFORM_ADMIN drop as effective_roles/2,
        # applied to the atom roles before BOTH the grant and the task scope.
        roles =
          if ctx.platform_tenant? == true,
            do: ctx.roles,
            else: List.delete(ctx.roles, :PLATFORM_ADMIN)

        required = required_permission(endpoint)
        # ISS-0993 rule 3: a platform-scope permission is denied unless the
        # caller is a PLATFORM_ADMIN of the platform tenant; evaluated before
        # the role matrix so the PLATFORM_ADMIN catch-all cannot bypass it.
        if not has_permission_in_scope?(roles, required, ctx.platform_tenant?) do
          %AccessDecision{kind: :Deny403, task_scope: nil}
        else
          if endpoint == :TasksList and is_task_worker_only?(roles) do
            %AccessDecision{
              kind: :AllowWithRowFilter,
              task_scope: {:own_user_and_groups, ctx.user_id}
            }
          else
            %AccessDecision{kind: :Allow, task_scope: :all}
          end
        end
    end
  end

  @doc "Ports `isTaskWorkerOnly/1` (L141-146) exactly."
  @spec is_task_worker_only?([role()]) :: boolean()
  def is_task_worker_only?(roles) do
    has_role?(roles, :TASK_WORKER) and
      not has_role?(roles, :PLATFORM_ADMIN) and
      not has_role?(roles, :PROCESS_DESIGNER) and
      not has_role?(roles, :PROCESS_OPERATOR) and
      not has_role?(roles, :TENANT_ADMIN)
  end

  @doc """
  Ports `requiredPermission/1` (L148-169) exactly, including the SVC-04
  entries. REQ-404 broadened the domain/range beyond the closed
  `endpoint_policy_key()`/`permission()` sets: the final clause (see below)
  is an identity fallback for any Catalog-sourced permission atom (e.g.
  `:FixtureRead`) not already matched by a clause above it.
  """
  @spec required_permission(endpoint_policy_key() | atom()) :: permission() | atom()
  def required_permission(endpoint)

  def required_permission(key)
      when key in [
             :DefinitionsCreate,
             :DefinitionsUpdate,
             :DefinitionsPatch,
             :DefinitionsActivate,
             :DefinitionsDeprecate,
             :DefinitionsArchive,
             :DefinitionsDelete,
             :DefinitionsImport
           ],
      do: :DefinitionsWrite

  def required_permission(:DefinitionsRead), do: :DefinitionsRead
  def required_permission(:InstancesStart), do: :InstancesStart
  def required_permission(:InstancesCancel), do: :InstancesCancel
  def required_permission(:InstancesRead), do: :InstancesRead
  def required_permission(:InstancesAdvanceTimer), do: :InstancesAdvanceTimer
  def required_permission(key) when key in [:TasksList, :TasksGetById], do: :TasksRead
  def required_permission(:TasksComplete), do: :TasksComplete
  def required_permission(key) when key in [:TasksAssign, :TasksReassign], do: :TasksAssign

  def required_permission(key) when key in [:UsersManage, :GroupsManage],
    do: :UsersGroupsRolesManage

  def required_permission(:TokensManage), do: :TokensManage
  def required_permission(:AuditRead), do: :AuditRead
  def required_permission(:DlqReadRetryDiscard), do: :DlqOperate
  def required_permission(:MetricsRead), do: :MetricsRead
  def required_permission(:WebhookSubscriptionsManage), do: :WebhooksManage
  # any authenticated role — matches Zig's comment on this branch
  def required_permission(:ServicesRead), do: :DefinitionsRead
  # ISS-0993: the global service catalogue is PLATFORM scope. These keys used to
  # map to :UsersGroupsRolesManage (a tenant permission) by accident; no
  # non-PLATFORM_ADMIN role held it, so no grant changes.
  def required_permission(key) when key in [:AdminServicesManage, :AdminServicesRead],
    do: :PlatformServicesManage

  def required_permission(:TenantsManage), do: :TenantsManage
  # ISS-0993 identity clauses (policy-key name == permission name).
  def required_permission(:TenantSettingsManage), do: :TenantSettingsManage
  def required_permission(:PromotionsRead), do: :PromotionsRead
  def required_permission(:PromotionsManage), do: :PromotionsManage
  def required_permission(:DefinitionsRollback), do: :DefinitionsRollback
  def required_permission(:RolesManage), do: :RolesManage
  def required_permission(:AttachmentsManage), do: :AttachmentsManage
  def required_permission(:AttachmentsRead), do: :AttachmentsRead

  # REQ-309 — identity clauses (policy-key name == permission name), design §3.
  def required_permission(:EntitiesDefinitionsRead), do: :EntitiesDefinitionsRead
  def required_permission(:EntitiesDefinitionsWrite), do: :EntitiesDefinitionsWrite
  def required_permission(:EntitiesRecordsWrite), do: :EntitiesRecordsWrite
  def required_permission(:EntitiesQuery), do: :EntitiesQuery
  # REQ-315 — identity clause (policy-key name == permission name), design §3.
  def required_permission(:EntitiesAggregate), do: :EntitiesAggregate

  # REQ-318 — identity clauses (policy-key name == permission name), design §5.
  # :EntitiesRecordsExportUnredacted has no endpoint_policy_key/2 clause (see
  # that function above) but still needs this identity clause: REQ-319's
  # handler calls evaluate_access/2 against it directly, positionally.
  def required_permission(:EntitiesRecordsExport), do: :EntitiesRecordsExport

  def required_permission(:EntitiesRecordsExportUnredacted),
    do: :EntitiesRecordsExportUnredacted

  def required_permission(:EntitiesRecordsImport), do: :EntitiesRecordsImport

  # REQ-317 — identity clauses (policy-key name == permission name), design
  # §4, same shape as :AttachmentsManage/:AttachmentsRead above.
  def required_permission(:EntitiesAttachmentsManage), do: :EntitiesAttachmentsManage
  def required_permission(:EntitiesAttachmentsRead), do: :EntitiesAttachmentsRead
  def required_permission(:EntitiesRestrictionsManage), do: :EntitiesRestrictionsManage

  # REQ-352 — identity clause (policy-key name == permission name), same
  # shape as Entities*/ExamSession* above.
  def required_permission(:PublicReadHandlesIssue), do: :PublicReadHandlesIssue

  # REQ-366 — identity clause (policy-key name == permission name), same
  # shape as Entities*/ExamSession*/PublicReadHandlesIssue above.
  def required_permission(:HelpRead), do: :HelpRead
  def required_permission(:MembershipsRead), do: :MembershipsRead

  # REQ-403 — identity clauses (policy-key name == permission name), same
  # shape as HelpRead/MembershipsRead above.
  def required_permission(:ModulesManage), do: :ModulesManage
  def required_permission(:MyModulesRead), do: :MyModulesRead

  def required_permission(:Unknown), do: :MetricsRead

  # REQ-404 (design lib/letflow/design/req404-module-router-mount.md §0.2) --
  # identity fallback for a Catalog-sourced permission atom (e.g.
  # :FixtureRead), the first requirement to actually mount a module's own
  # router/0 behind Letflow.Plugs.Authorize. Placed last, after every
  # existing identity/core clause above (none of which change position or
  # body), so this only ever resolves an atom no clause above already
  # matched. Safe because Letflow.Modules.Catalog.validate/1's
  # {:core_permission_collision, _} rule (REQ-400/401) guarantees a module's
  # own declared permissions never intersect Authorization.core_permissions/0
  # -- so this fallback can never accidentally resolve a core permission
  # atom via the wrong path; it only ever resolves a genuinely
  # Catalog-sourced atom to itself, the same "policy-key name == permission
  # name" identity-clause pattern already used above for :EntitiesQuery,
  # :HelpRead, :ModulesManage, etc.
  def required_permission(endpoint), do: endpoint

  @doc "Ports `hasPermission/2` (L171-176) exactly."
  @spec has_permission?([role()], permission()) :: boolean()
  def has_permission?(roles, permission) do
    Enum.any?(roles, &role_allows?(&1, permission))
  end

  @doc """
  ISS-0993 rule 3 plus `has_permission?/2`: a `:platform`-scope permission is
  honoured only when `platform_tenant?` is `true` AND `:PLATFORM_ADMIN` is among
  `roles`. A tenant-scope permission follows the role matrix; REQ-447 PR 2
  deleted the C6 own-tenant switch, so `:PLATFORM_ADMIN` counts only when
  `platform_tenant?` is `true` (resolution through `effective_roles/2` already
  drops it elsewhere; the delete here keeps a hand-built context fail closed).
  `role_allows?/2` is unchanged. Fail closed on a non-`true` `platform_tenant?`.
  """
  @spec has_permission_in_scope?([role()], permission() | atom(), boolean()) :: boolean()
  def has_permission_in_scope?(roles, permission, platform_tenant?) do
    case permission_scope(permission) do
      :platform ->
        platform_tenant? == true and has_role?(roles, :PLATFORM_ADMIN) and
          has_permission?(roles, permission)

      :tenant ->
        scoped_roles =
          if platform_tenant? == true,
            do: roles,
            else: List.delete(roles, :PLATFORM_ADMIN)

        has_permission?(scoped_roles, permission)
    end
  end

  @doc "Ports `hasRole/2` (L178-183) exactly."
  @spec has_role?([role()], role()) :: boolean()
  def has_role?(roles, target) do
    target in roles
  end

  @doc """
  Ports `roleAllows/2` (L185-222) exactly, the full 6-role permission matrix,
  then (REQ-401, D4) falls back to `Letflow.Modules.Catalog.role_grants/1`
  for any permission the core matrix itself denies. `or` short-circuits on a
  truthy left side, so:

    * every pair `core_role_allows?/2` already answers `true` for (in
      particular every `PLATFORM_ADMIN` pair, via its unconditional `true`
      clause) is unaffected by the Catalog side — `PLATFORM_ADMIN`'s
      existing catch-all therefore also covers module permissions;
    * every pair `core_role_allows?/2` answers `false` for falls through to
      `permission in Letflow.Modules.Catalog.role_grants(role)` — this can
      only ever flip a pair from `false` to `true` for a permission atom a
      registered module actually grants that role, never for a core
      permission (`Letflow.Modules.Catalog.validate/1`'s
      `{:core_permission_collision, _}` rule keeps the two atom sets
      disjoint, checked against `core_permissions/0`).

  A Catalog-granted permission is typed `atom()` at the Catalog boundary
  (D4), not a member of the closed `permission()` union, hence the widened
  `@spec`.
  """
  @spec role_allows?(role(), permission() | atom()) :: boolean()
  # REQ-403 — :MyModulesRead is granted to every role, CANDIDATE included
  # (design §5.2, this module's moduledoc "MyModulesRead" section). Must
  # stay the FIRST def role_allows?/2 clause in this module (above the
  # generic clause below) so a call with :MyModulesRead as its second
  # argument matches here before core_role_allows?/2 or
  # Letflow.Modules.Catalog.role_grants/1 are ever consulted (AC6's grep
  # contract).
  def role_allows?(_role, :MyModulesRead), do: true

  def role_allows?(role, permission) do
    core_role_allows?(role, permission) or permission in Letflow.Modules.Catalog.role_grants(role)
  end

  @spec core_role_allows?(role(), permission()) :: boolean()
  defp core_role_allows?(role, permission)

  defp core_role_allows?(:PLATFORM_ADMIN, _permission), do: true

  # REQ-447 (design req447-tenant-admin-role.md section 3.1): TENANT_ADMIN holds
  # exactly the tenant-scope permissions. permission_scope/1 classifies every
  # unclassified atom (including :Unknown and the Unmatched* markers) as
  # :platform, so this clause fails closed and never grants a platform-scope
  # permission. Catalog permissions are tenant scope and are covered here.
  defp core_role_allows?(:TENANT_ADMIN, permission),
    do: permission_scope(permission) == :tenant

  defp core_role_allows?(:PROCESS_DESIGNER, permission),
    do:
      permission in [
        :DefinitionsWrite,
        :DefinitionsRead,
        :InstancesStart,
        :InstancesRead,
        :TasksRead,
        :RolesManage,
        :AttachmentsRead,
        # REQ-309 (design §3 role matrix): schema authoring tracks this role's
        # existing :DefinitionsWrite ("author a definition"); record authoring
        # (:EntitiesRecordsWrite) deliberately does NOT — that is
        # PROCESS_OPERATOR's "operate on live tenant data" class.
        :EntitiesDefinitionsRead,
        :EntitiesDefinitionsWrite,
        :EntitiesQuery,
        # REQ-315 (design §3 role matrix): every role holding :EntitiesQuery
        # also gets :EntitiesAggregate -- a role already trusted to read
        # individual rows for an entity type is, at minimum, equally trusted
        # to read an aggregate over the same rows.
        :EntitiesAggregate,
        # REQ-317 (design §7 OQ-2 role matrix): read only -- this role holds
        # :EntitiesQuery/:EntitiesDefinitionsRead/:EntitiesDefinitionsWrite
        # but not :EntitiesRecordsWrite (a schema-authoring role, not the
        # "operate on live tenant data" class Manage is reserved for).
        :EntitiesAttachmentsRead,
        # REQ-366 (design §1.3, this module's moduledoc "HelpRead" section):
        # help content is a read-only UI affordance meant to assist every
        # authenticated user regardless of role.
        :HelpRead,
        # REQ-384 (design §2.2, this module's moduledoc "MembershipsRead"
        # section): a user reading their own membership list is not a
        # privileged operation, same "assist every authenticated user"
        # class as :HelpRead above.
        :MembershipsRead
      ]

  defp core_role_allows?(:PROCESS_OPERATOR, permission),
    do:
      permission in [
        :DefinitionsRead,
        :InstancesStart,
        :InstancesCancel,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :TasksAssign,
        :AuditRead,
        :DlqOperate,
        :MetricsRead,
        :WebhooksManage,
        :AttachmentsManage,
        :AttachmentsRead,
        :InstancesAdvanceTimer,
        # REQ-309 (design §3 role matrix): record authoring tracks this role's
        # existing InstancesStart/InstancesCancel/AttachmentsManage grants;
        # schema authoring (:EntitiesDefinitionsWrite) is deliberately withheld
        # — that is PROCESS_DESIGNER's class.
        :EntitiesDefinitionsRead,
        :EntitiesRecordsWrite,
        :EntitiesQuery,
        # REQ-315 (design §3 role matrix): mirrors :EntitiesQuery, see the
        # PROCESS_DESIGNER clause's comment above.
        :EntitiesAggregate,
        # REQ-317 (design §7 OQ-2 role matrix): both -- this role holds
        # :EntitiesRecordsWrite and both instance-scoped
        # :AttachmentsManage/:AttachmentsRead already, tracking the same
        # "operate on live tenant data" class :EntitiesRecordsWrite itself
        # was assigned to for this role.
        :EntitiesAttachmentsManage,
        :EntitiesAttachmentsRead,
        # REQ-366 (design §1.3): see PROCESS_DESIGNER clause's comment above.
        :HelpRead,
        # REQ-384: see PROCESS_DESIGNER clause's comment above.
        :MembershipsRead
      ]

  defp core_role_allows?(:TASK_WORKER, permission),
    do:
      permission in [
        :DefinitionsRead,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :AttachmentsRead,
        # REQ-309 (design §3 role matrix): read-only in this subsystem — every
        # role that can read anything here also holds :EntitiesQuery, mirroring
        # how every role holding :InstancesRead also holds :AttachmentsRead.
        :EntitiesDefinitionsRead,
        :EntitiesQuery,
        # REQ-315 (design §3 role matrix): mirrors :EntitiesQuery, see the
        # PROCESS_DESIGNER clause's comment above.
        :EntitiesAggregate,
        # REQ-317 (design §7 OQ-2 role matrix): read only -- no write-class
        # entity permission at all is granted to this role, mirroring its
        # existing instance-scoped :AttachmentsRead-only grant.
        :EntitiesAttachmentsRead,
        # REQ-366 (design §1.3): see PROCESS_DESIGNER clause's comment above.
        :HelpRead,
        # REQ-384: see PROCESS_DESIGNER clause's comment above.
        :MembershipsRead
      ]

  # REQ-366 -- the one exception to this role's otherwise total, unconditional
  # `false` (see the clause below): help content is a read-only UI affordance
  # meant to assist every authenticated user regardless of role, and
  # AGENT_RUNNER has no ISS-0646-style closed-set invariant blocking it the
  # way CANDIDATE does (see this module's moduledoc "HelpRead" section for
  # why CANDIDATE is deliberately excluded instead).
  defp core_role_allows?(:AGENT_RUNNER, :HelpRead), do: true
  # REQ-384: see this module's moduledoc "MembershipsRead" section -- same
  # "assist every authenticated user regardless of role" exception as
  # :HelpRead above.
  defp core_role_allows?(:AGENT_RUNNER, :MembershipsRead), do: true
  defp core_role_allows?(:AGENT_RUNNER, _permission), do: false

  # REQ-413 — CANDIDATE's six exam-session grants (ExamSessionStart,
  # ExamSessionRead, ExamSessionSave, ExamSessionSubmit,
  # ExamSessionReportEvent, ExamCertificateIssue) moved out of core to
  # Letflow.Modules.Exam's manifest role_grants. The fallback in
  # role_allows?/2 (`permission in Letflow.Modules.Catalog.role_grants(role)`)
  # now supplies them, so core_role_allows?(:CANDIDATE, _) is uniformly
  # false — the Catalog side handles the grant.
  defp core_role_allows?(:CANDIDATE, _permission), do: false
end
