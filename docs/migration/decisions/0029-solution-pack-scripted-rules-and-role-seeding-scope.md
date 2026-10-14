# 0029 — SolutionPack scope: scripted rules and role seeding both stay OUT of the pack; the section set stays closed

Superseded in part by 0053 (`0053-tenant-scripted-rules.md`): §1 (scripted rules stay out; no provisioning path) and the related §3/§4 sentences are superseded for tenant scripted rules; the pack `scripts` section itself is decided in a follow-up record (0053 'Record P'). §2 (role seeding) stands.

Status: decided (2026-09-12, `CODE-DESIGNER`, REQ-325), pending its own
`SECURITY-REVIEWER` and `REVIEWER` gates (sections below, left as explicit
PENDING placeholders for those roles to fill in).
Owner: `ORCH` (this record settles what the pack phase's deliverable list
actually is for S10 gap 16 and S10 gap 17; it produces no implementation and
none is scheduled by it).

## Re-verification performed (before deciding anything)

All of the following was read in full, in the current tree, on this branch,
on 2026-09-12 — not assumed from the requirement text, which itself warns
main moves quickly:

- `lib/letflow/definitions/solution_pack.ex`:
  - `pack_document` `@type` (lines 222-232): confirmed **five** content keys
    today — `definitions`, `service_catalog_entries` (`[]`, permanently
    rejected non-empty per decision 0027), `variable_schemas`,
    `entity_definitions` (added by decision 0026 / REQ-303 through REQ-306,
    now `done`), and `manifest: %{required_roles: [String.t()]}`. No
    scripted-rule/script-payload key exists anywhere in this type.
  - `grep -in lua lib/letflow/definitions/solution_pack.ex` returns **zero
    hits** — confirmed directly, matching the requirement's own claim
    exactly. There is no script payload field on `packed_definition` or
    anywhere else in this module.
  - The moduledoc's `manifest.required_roles` bullet (lines 69-71), quoted
    verbatim: *"`manifest.required_roles` — supported, **read-only**: it
    produces the advisory `role_mapping_checklist` (see `install/3`). No
    role is created and no install is ever rejected because of it."*
  - The moduledoc's "Known gap" section (lines 166-171), quoted verbatim:
    *"`manifest.required_roles` is always `[]` on export: nothing in
    Letflow declares per-definition roles yet. The field exists so the wire
    shape is stable and so an install document that *does* carry required
    roles (from another system, or a future Letflow that populates them)
    produces a meaningful checklist."*
  - `check_unsupported_sections/1` (lines 896-897): confirmed the same
    two-clause shape decision 0027 already documented —
    `%{service_catalog_entries: []} -> :ok` / anything else ->
    `{:error, :unsupported_pack_section}`. It gates only
    `service_catalog_entries`; a non-empty `entity_definitions` is not
    rejected by it (matching 0026's own account of how that section ended
    up actually supported rather than needing the interim reject clause
    long-term).
- `lib/letflow/engine/lua_script_audit.ex`, read in full: confirmed its
  moduledoc's own words, quoted directly: *"This module is a MINIMAL,
  deliberately narrow engine-side call path that (a) invokes an injected
  script executor and (b) persists the resulting manifest hash to a
  queryable audit record... It is NOT the SERVICE_TASK script-execution
  handler and must not be called from processServiceTaskRuntimeInTx or any
  other normal process-execution flow."* Its "No caller yet" section states
  plainly: *"nothing in this codebase calls `execute_script_for_audit/6`."*
  Confirmed by grep: no call site of `execute_script_for_audit` exists
  outside this file itself and `lib/letflow/audit.ex`'s prose reference to
  it.
  - Its `Executor.script_ref` typedoc (lines 90-96) confirms `@type
    script_ref :: term()` is **deliberately opaque** — *"pinning a concrete
    type here would constrain a decision that belongs to the Executor
    module"* — so `LuaScriptAudit` accepting a pack-shaped script term is
    not, by itself, an obstacle; it accepts any term by construction. The
    real obstacles are the two named in the requirement: (a) no pack-side
    script payload exists to pass, and (b) the audit path is fenced off
    from normal flow with no caller.
  - `lib/letflow/engine/lua/executor.ex` line 258, confirmed: the concrete
    `script_ref :: binary() | %{manifest: Manifest.t(), script_source:
    binary()}` shape lives in this DIFFERENT module (the real `Executor`
    implementation), not in `LuaScriptAudit`.
  - Confirmed (grep across `lib/letflow/routers/`) there is no HTTP route
    anywhere that registers, uploads, or otherwise provisions a Lua script
    of any kind — no out-of-band path for scripted rules exists today, in
    contrast to both `service_catalog_entries` (0027: `POST
    /service-catalog`) and roles (this record, §2 below: `POST /roles`).
- `grep -rn upsert_role lib/` — run directly, full output quoted verbatim in
  the "Caller walk" subsection immediately below, which walks every `.ex`
  hit individually. **Conclusion, stated here and justified there:
  `Letflow.Identity.RoleRegistry.upsert_role/2` is not uncalled.** The one
  live, executing call site is `lib/letflow/routers/identity.ex`'s `authz_post
  "/roles", :RolesManage` (line 208), documented in that router's own
  moduledoc line 35: `POST /roles -> Letflow.Identity.RoleRegistry.upsert_role/2
  (REQ-076)`. No call site lies on the `SolutionPack.install/3` path — grepped
  `lib/letflow/definitions/solution_pack.ex` for `upsert_role`/`RoleRegistry`:
  zero hits.

### Caller walk for `grep -rn upsert_role lib/`

Full, verbatim output, run directly on this branch on 2026-09-12:

```
lib/letflow/design/identity-schema.md:307:decide when it writes `upsert_role`'s group-existence check, since REQ-020 is where
lib/letflow/design/identity-schema.md:342:| — | | | `inserted_at` only, no `updated_at` — REQ-015's description lists only `inserted_at` for this table, matching `transition_events`' precedent of `timestamps(updated_at: false)` for an insert-oriented table. Note: `tenant_role` is not append-only/event-sourced like `transition_events` (REQ-020's `upsert_role` does update the `group_id` binding), so this is a description-driven choice, not a Decision-C append-only classification — REQ-020 will need `Repo.update/1` or an upsert `on_conflict:` clause on `group_id`/`name` even without an `updated_at` column tracking it. **Open question, not silently resolved:** should `tenant_role` also get `updated_at`? REQ-015's description explicitly lists only `id, name, group_id, inserted_at` — this design follows that literally rather than adding a field the requirement didn't ask for, but flags it since REQ-020's upsert-by-name will change `group_id` without a timestamp recording when. If REQ-020 needs it, add `updated_at` there rather than assuming its absence is permanent. |
lib/letflow/design/identity-schema.md:369:# src/identity/role_registry.zig's TenantRoleStore (list_roles, upsert_role),
lib/letflow/design/identity-schema.md:492:consumer this schema's shape is built for (REQ-020 implements list_roles/upsert_role
lib/letflow/design/identity-schema.md:509:- `upsert_role/2 :: (name :: String.t(), group_id :: Ecto.UUID.t()) :: {:ok, %TenantRole{}} | {:error, Ecto.Changeset.t()}`
lib/letflow/design/identity-schema.md:576:   group lookups) to decide when it implements `upsert_role`'s group-existence check.
lib/letflow/design/identity-schema.md:578:   follows that literally but flags that REQ-020's `upsert_role` will mutate
lib/letflow/identity/role_registry.ex:5:  `upsert_role`) and `resolveRoleInTx` — see also
lib/letflow/identity/role_registry.ex:50:  @spec upsert_role(name :: String.t(), group_id :: Ecto.UUID.t() | String.t()) ::
lib/letflow/identity/role_registry.ex:52:  def upsert_role(name, group_id) do
lib/letflow/identity/role_registry.ex:55:      do_upsert_role(name, normalized_group_id)
lib/letflow/identity/role_registry.ex:83:  defp do_upsert_role(name, group_id) do
lib/letflow/design/req020-role-registry.md:6:(`list_roles`, `upsert_role`, `resolve_role_in_tx`), the upsert transaction shape, the
lib/letflow/design/req020-role-registry.md:35:  moduledoc states explicitly "REQ-020 owns `list_roles`/`upsert_role` and their
lib/letflow/design/req020-role-registry.md:59:  REQ-020 to decide "when it implements `upsert_role`'s group-existence check" — resolved
lib/letflow/design/req020-role-registry.md:66:  itself and the "REQ-020 owns list_roles/upsert_role" ownership statement.
lib/letflow/design/req020-role-registry.md:99:**Decision: REQ-020's three functions (`list_roles`, `upsert_role`,
lib/letflow/design/req020-role-registry.md:108:   `src/identity/role_registry.zig`'s `TenantRoleStore` (`list_roles`, `upsert_role`) and
lib/letflow/design/req020-role-registry.md:154:| `lib/letflow/identity/role_registry.ex` | `Letflow.Identity.RoleRegistry` | `list_roles/0`, `upsert_role/2`, `resolve_role_in_tx/1` |
lib/letflow/design/req020-role-registry.md:220:## 3. `upsert_role/2`
lib/letflow/design/req020-role-registry.md:223:@spec upsert_role(name :: String.t(), group_id :: Ecto.UUID.t() | String.t()) ::
lib/letflow/design/req020-role-registry.md:312:**Note — does `upsert_role/2` need the same insert-vs-update disambiguation dance
lib/letflow/design/req020-role-registry.md:316:not ask `upsert_role/2` to report whether it created vs. updated — "upsert_role/2 called
lib/letflow/design/req020-role-registry.md:331:defined here — REQ-020 owns `list_roles/upsert_role` and their validation logic" — this
lib/letflow/design/req020-role-registry.md:335:passed a bare struct or a changeset, but a changeset gives `upsert_role/2` a clean place
lib/letflow/design/req020-role-registry.md:356:- `validate_required/2`: both fields (defensive — `upsert_role/2`'s own pre-validation
lib/letflow/design/req020-role-registry.md:359:  `upsert_role/2`'s own checks — consistent with this project's general preference for
lib/letflow/design/req020-role-registry.md:366:  enforced by `upsert_role/2` itself *before* the changeset/transaction is ever reached
lib/letflow/design/req020-role-registry.md:430:`upsert_role/2` calls `Ecto.UUID.cast(group_id)` as its second pre-validation step (after
lib/letflow/design/req020-role-registry.md:445:`upsert_role/2`'s "no unhandled raise on external input" property hold, matching this
lib/letflow/design/req020-role-registry.md:463:   `upsert_role/2` (§2, §3), which both leave a genuine connection-level failure
lib/letflow/design/req020-role-registry.md:557:- No function in this design (`list_roles/0`, `upsert_role/2`, `resolve_role_in_tx/1`)
lib/letflow/design/req020-role-registry.md:604:    have a unique index**, confirmed directly — this is the exact index `upsert_role/2`'s
lib/letflow/design/req020-role-registry.md:617:    but `upsert_role/2`'s own explicit pre-check (§3.1 step a, `Repo.get(Group,
lib/letflow/design/req020-role-registry.md:648:precedent), plus one function-specific strengthening.** `upsert_role/2` returns typed
lib/letflow/design/req020-role-registry.md:656:paths of `upsert_role/2` do **not** add this same blanket rescue for a genuine
lib/letflow/design/req020-role-registry.md:671:| "upsert_role/2 with a non-existent group_id returns an error tuple rather than inserting a dangling reference" | §3.1 step a: `Repo.get(Group, group_id)` inside the transaction, `Repo.rollback(:group_not_found)` on `nil` → `{:error, :group_not_found}`; §8's confirmation that the DB-level FK also defends this at the constraint layer, with the pre-check being what makes it a typed, non-raising error |
lib/letflow/design/req020-role-registry.md:672:| "upsert_role/2 called twice with the same name and a different group_id updates the existing binding rather than creating a duplicate row" | §3.1 step b: `conflict_target: :name` + `on_conflict: [set: [group_id: group_id]]` against REQ-015's `unique_index(:tenant_role, [:name])` (confirmed in §8) — structurally prevents a duplicate `name` row, updates `group_id` in place |
lib/letflow/design/req020-role-registry.md:704:4. **OQ-4 — should `upsert_role/2`'s changeset (§3.2) also declare
lib/letflow/design/req076-identity-tokens-roles-onboarding.md:24:  `upsert_role/2`), `lib/letflow/api/authorization.ex`, `lib/letflow/api/response.ex`,
lib/letflow/design/req076-identity-tokens-roles-onboarding.md:494:`POST /identity/roles` → `Letflow.Identity.RoleRegistry.upsert_role/2`.
lib/letflow/design/req076-identity-tokens-roles-onboarding.md:533:`RoleRegistry.list_roles/0` and `upsert_role/2` take **no** `opts`/`:prefix` parameter —
lib/letflow/design/req076-identity-tokens-roles-onboarding.md:609:`{:errors, field_errors}` → same problem-document path. `RoleRegistry.upsert_role(name,
lib/letflow/design/req076-identity-tokens-roles-onboarding.md:618:  (defensive, matching `RoleRegistry.upsert_role/2`'s own doc — every named path above
lib/letflow/design/req076-identity-tokens-roles-onboarding.md:769:One accepted, one rejected test, both through `RoleRegistry.upsert_role/2` (or the HTTP
lib/letflow/design/req076-identity-tokens-roles-onboarding.md:774:  assert {:ok, %TenantRole{name: "CUSTOM_APPROVER"}} = RoleRegistry.upsert_role("CUSTOM_APPROVER", group.id)
lib/letflow/design/req076-identity-tokens-roles-onboarding.md:778:  assert {:error, :invalid_role_name} = RoleRegistry.upsert_role("", group.id)
lib/letflow/design/req076-identity-tokens-roles-onboarding.md:779:  assert {:error, :invalid_role_name} = RoleRegistry.upsert_role(String.duplicate("a", 129), group.id)
lib/letflow/design/req076-identity-tokens-roles-onboarding.md:780:  assert {:error, :invalid_role_name} = RoleRegistry.upsert_role("bad\x01name", group.id)
lib/letflow/design/req083-task-routes-read.md:384:   (`upsert_role/2` still owns every write to `tenant_role`; this function only ever
lib/letflow/design/promotion_plan.md:86:  and nothing more: `list_roles/0`, `upsert_role/2`, `resolve_role_in_tx/1`. **There is
lib/letflow/design/promotion_plan.md:617:`role_name -> group_id` binding registry (`list_roles/0`, `upsert_role/2`,
lib/letflow/routers/identity.ex:35:  * POST   /roles                        -> Letflow.Identity.RoleRegistry.upsert_role/2 (REQ-076)
lib/letflow/routers/identity.ex:54:  read). `Letflow.Identity.RoleRegistry.upsert_role/2` (REQ-020,
lib/letflow/routers/identity.ex:208:    handle_upsert_role(conn)
lib/letflow/routers/identity.ex:658:  @upsert_role_schema [
lib/letflow/routers/identity.ex:663:  defp handle_upsert_role(conn) do
lib/letflow/routers/identity.ex:664:    case Validation.validate(@upsert_role_schema, conn.body_params) do
lib/letflow/routers/identity.ex:669:        case RoleRegistry.upsert_role(name, group_id) do
lib/letflow/identity/tenant_role.ex:6:  `upsert_role`), which REQ-020 implements against this schema.
lib/letflow/identity/tenant_role.ex:25:  enforced by `RoleRegistry.upsert_role/2` itself, before this changeset is ever built —
lib/letflow/identity/tenant_role.ex:47:  `references(:groups, ...)`) — not a re-implementation of `RoleRegistry.upsert_role/2`'s
```

**`.md` hits dismissed in one line, as they are non-executing:** every hit
under `lib/letflow/design/*.md` (`identity-schema.md`,
`req020-role-registry.md`, `req076-identity-tokens-roles-onboarding.md`,
`req083-task-routes-read.md`, `promotion_plan.md`) is design-doc prose
describing, specifying, or testing `upsert_role/2` — none of it executes,
so none of it is a caller.

**Every `.ex` hit walked individually, none on a pack-install path:**

- **`lib/letflow/identity/role_registry.ex` (lines 5, 50, 52, 55, 83).**
  This is the function's OWN definition, not a caller: line 5 is the
  module's moduledoc mentioning `upsert_role`, line 50 is the `@spec`, line
  52 is `def upsert_role(name, group_id) do`, line 55 calls the module's own
  private `do_upsert_role/2`, and line 83 is that private function's own
  `defp do_upsert_role(name, group_id) do` head. None of these five lines
  is a call site external to the module; they are the implementation being
  called, not evidence of a caller. Not on a pack-install path.
- **`lib/letflow/identity/tenant_role.ex` (lines 6, 25, 47).** All three
  are moduledoc/comment prose referencing `RoleRegistry.upsert_role/2` by
  name to explain this schema's own validation division of labor (line 6:
  "which REQ-020 implements against this schema"; line 25: "enforced by
  `RoleRegistry.upsert_role/2` itself, before this changeset is ever
  built"; line 47: "not a re-implementation of
  `RoleRegistry.upsert_role/2`'s [FK behavior]"). None of the three is
  executable code — no `def`, `case`, or function call appears at any of
  these three line numbers, only doc comments. Not a caller, and not on a
  pack-install path.
- **`lib/letflow/routers/identity.ex` (lines 35, 54, 208, 658, 663, 664,
  669).** This is the live call site. Lines 35 and 54 are moduledoc prose
  documenting the route (`* POST /roles -> Letflow.Identity.RoleRegistry.upsert_role/2
  (REQ-076)`); line 658 is `@upsert_role_schema [` (a validation-schema
  module attribute, not a call); line 663 is the handler's own
  `defp handle_upsert_role(conn) do` head; line 664 validates the request
  body against that schema; and **line 669,
  `case RoleRegistry.upsert_role(name, group_id) do`, is the actual call**,
  reached from `authz_post "/roles", :RolesManage do handle_upsert_role(conn) end`
  (line 207-209, re-verified above) — the live, authenticated `POST /roles`
  route this record's §2 discusses at length. This router is not
  `lib/letflow/definitions/solution_pack.ex`, is never invoked by
  `SolutionPack.install/3`, and is reached only via its own independent
  HTTP route — **not on a pack-install path.**

**Conclusion of the caller walk: none of the three `.ex` call sites lies on
`SolutionPack.install/3`'s path.** The only genuine external call to
`upsert_role/2` is `lib/letflow/routers/identity.ex`'s `POST /roles` route
handler, entirely independent of pack install, which is exactly the
out-of-band route §2 analyzes.
- `lib/letflow/api/authorization.ex`: confirmed the permission-resolution
  chain for `POST /roles`, which turns out to differ materially from
  0027's `POST /service-catalog` case:
  - `endpoint_policy_key("POST", "/roles")` -> `:RolesManage` (line 498), with
    an inline comment (lines 492-495) stating this is *"a new, distinct
    `:RolesManage` permission"*, deliberately not folded into
    `:UsersGroupsRolesManage`.
  - `required_permission(:RolesManage)` -> `:RolesManage` (line 708) — it
    resolves to itself, unlike `:AdminServicesManage`, which resolves to
    `:UsersGroupsRolesManage`.
  - `role_allows?(:PROCESS_DESIGNER, permission)` (lines 756-780) **includes
    `:RolesManage`** in its permission list (confirmed directly in the
    `case`/list literal). `:PROCESS_DESIGNER` is the SAME role that holds
    `:DefinitionsWrite` -> `:DefinitionsCreate`, the permission
    `POST /solution-packs/install` requires (`lib/letflow/routers/solution_packs.ex`
    line 167, `authz_post "/install", :DefinitionsCreate`).
  - **This is the opposite asymmetry from 0027's.** In 0027, the actor who
    could install a pack (`:DefinitionsCreate`) could NOT reach the
    out-of-band route (`:AdminServicesManage`/`:UsersGroupsRolesManage`,
    `:PLATFORM_ADMIN`-only) — that gap was 0027's own justification for
    requiring a second, conjunctive permission on any hypothetical
    permissive design. Here, the SAME `:PROCESS_DESIGNER` actor who can
    install a pack already holds `:RolesManage` directly and can already
    call `POST /roles` with no additional gate. There is no privilege-
    escalation question to solve for a permissive design here at all — see
    §2 below for why this strengthens, rather than weakens, the case for
    NO.
- `docs/migration/decisions/0027-solution-pack-service-catalog-install-policy.md`,
  read in full: confirmed §1's holding, quoted directly: *"NOT PERMITTED.
  The rejection is the permanent, documented stance, not an interim one...
  A solution-pack document may not carry `service_catalog_entries`. This is
  a permanent policy decision, not a placeholder awaiting a future
  requirement."* And its "Out-of-band provisioning path" line: *"the
  existing `POST /service-catalog` route... is the sole path by which a
  service-catalog entry is registered."*
- `docs/migration/decisions/0026-solution-pack-entity-definitions-section.md`,
  read in full: confirmed as the precedent this record's §4 (structural
  question) measures against — it is the record that added
  `entity_definitions` as the pack's most recent new section, and the one
  the requirement's own "gap 13" citation names as the first occurrence of
  this recurring shape.
- Decision 0022 (`docs/migration/decisions/`), read in full:
  confirmed the bucket rule (rule 1) and confirmed bucket A's own
  definition: *"a solution-pack document, installed via
  `Letflow.Definitions.SolutionPack.install/3`"*.
- The S10 stage file (`docs/migration/`): confirmed the pack
  phase's current phase-table row lists exactly four deliverables — entity
  definitions, process definitions, role-registry seed, and (by name only,
  per the stage file's own text, not repeated here) scripted rules
  — and confirmed its "Open questions" section already records the audit
  question for scripted rules as carrying a `SECURITY-REVIEWER` interest,
  not yet answered.

**Conclusion of re-verification: the requirement's own framing holds in
full**, with one refinement this record makes explicit: the `:RolesManage`
permission chain is NOT structurally identical to 0027's
`:AdminServicesManage` chain — it is actually a cleaner case for NO, because
there is no cross-actor privilege gap to close. See §2.

## Question

Five concrete sub-questions, per the requirement:

1. Does a pack carry scripted rules at all?
2. Does a pack seed roles, or is the read-only checklist the permanent,
   documented stance?
3. If either answer to 1 or 2 is YES: which audit mechanism — reuse
   `LuaScriptAudit`, or model a new record on it?
4. Is the twice-recurring "bucket A's delivery vehicle can't carry
   everything bucket A consists of" pattern itself a structural problem
   with `pack_document`'s closed-struct shape?
5. What is the pack phase's corrected deliverable list, given the answers
   to 1 and 2?

## Decision

### 1. Scripted rules: NO. A pack does not carry scripted rules today. The alternative provisioning path does not exist yet and must be built, by a later bucket-B requirement, once there is something for it to feed

**A solution-pack document does not, and today cannot, carry a scripted
rule.** `pack_document`'s five keys (re-verified above) have no
script-payload field, `grep -in lua` over `solution_pack.ex` is empty, and
this record does not add one.

**Decision 0027 is the standing precedent that a NO here is fully
legitimate, not a deferral or a failure.** Quoting 0027 §1 directly: *"NOT
PERMITTED. The rejection is the permanent, documented stance, not an
interim one... This is a permanent policy decision, not a placeholder
awaiting a future requirement."* The same posture — a pack section
declining to exist, on the merits, rather than merely not-yet-built — is
available here and this record adopts it.

**Whether the SAME reasoning applies, in one sentence: only partially — 0027's
reasoning rests on "an authenticated route already provisions this
out-of-band," and that clause is false here, but 0027's SECOND,
independent argument ("no operational upside today to offset the added
surface," 0027 §7 point 2) applies to scripted rules with MORE force than
it applied to `service_catalog_entries`, and that second argument is what
this record's NO actually rests on.** Concretely: 0027's dispatch side was
merely *stubbed* (`catalog_lookup_stub/2` unconditionally returns
`{:error, :not_registered}`, a shape that could be replaced by a real
lookup at any time); here, there is no dispatch stub to replace at all —
`LuaScriptAudit` (the only engine-side path that touches a script's
identity for auditing) has zero callers, and the general
SERVICE_TASK-with-script integration its own moduledoc names as the thing
that would supersede it ("R-Co's `src/design/lua-integration.md` section
25") is itself unbuilt. Building a pack section for content that no
execution or audit path can yet consume would add parsing surface, a new
`pack_document` key, and a security-relevant ingestion point for content
this codebase cannot yet do anything with end-to-end — the same "no
operational upside, real added surface" calculus 0027 used to keep
`service_catalog_entries` rejected even though its dispatch stub was
closer to being replaceable than anything on the scripted-rules side is
today.

**The asymmetry the requirement names is real and does not flip the
conclusion — it changes what "the alternative" is.** For
`service_catalog_entries` and roles (§2), the alternative is an EXISTING
authenticated route the pack declines to duplicate. For scripted rules,
there is no existing alternative of any kind: nothing calls
`execute_script_for_audit/6`, no HTTP route registers a script, and no
"scripted-rule registry" context module exists. **Naming the alternative
concretely, per the requirement's own instruction: the alternative
provisioning path is a new, dedicated, authenticated out-of-band route
(structurally the analogue of `POST /service-catalog` and `POST /roles` —
an admin/design-time HTTP surface over a new context module, e.g. a
"scripted-rule registry" the same shape as `Letflow.ServiceCatalog`) that
does NOT exist today and must be built, by `ELIXIR-DEV` against a
`CODE-DESIGNER` design, as its own bucket-B requirement — and not before
that requirement also answers what invokes the rule at runtime (the
unbuilt SERVICE_TASK-with-script integration) and what audits it (§3
below, left unresolved here because neither trigger condition fires). This
record does not file that requirement; it only names the shape a later one
would need.**

### 2. Role seeding: NO. The read-only checklist is the permanent, documented stance, and `POST /roles` is the out-of-band analogue 0027 already established the pattern for — confronted directly, not merely cited

**A solution-pack document does not seed roles. `manifest.required_roles`
stays read-only.** Quoting `solution_pack.ex`'s own moduledoc directly
(lines 69-71): *"`manifest.required_roles` — supported, **read-only**: it
produces the advisory `role_mapping_checklist` (see `install/3`). No role
is created and no install is ever rejected because of it."* And its "Known
gap" section (lines 166-171): *"`manifest.required_roles` is always `[]`
on export: nothing in Letflow declares per-definition roles yet."* Both
statements are the module's own documented position, not an oversight —
this record treats a decision to KEEP it that way as equally deliberate as
a decision to change it, exactly as the requirement itself instructs.

**Because the pack phase's phase-table row currently lists "role-registry
seed" as a deliverable, and the answer here is NO, that entry is
misstated. Corrected wording, verbatim, for the phase-table owner to
apply: replace "role-registry seed" with "role mapping checklist
(advisory, read-only — no role is created by pack install; any role a
tenant's process definitions reference is provisioned via the existing
`POST /roles` route, out-of-band from pack install)."**

**Explicit position on the analogy the requirement demands: YES, `POST
/roles` (`lib/letflow/routers/identity.ex`'s `authz_post "/roles",
:RolesManage`, calling `Letflow.Identity.RoleRegistry.upsert_role/2`) is
the out-of-band role-provisioning analogue of the `POST /service-catalog`
route 0027 grounded its permanent NO in, and 0027's reasoning transfers
here directly — in fact more cleanly than in its original case.** Both
routes share the structural shape 0027's decision rests on: an existing,
authenticated, tenant-agnostic-at-the-route-layer HTTP surface that
already performs, in one call, exactly the write a permissive pack design
would otherwise need a new install-time code path to perform. The
difference this record found during re-verification (§ above) makes the
NO answer STRONGER here, not weaker: 0027 had to reason about a
privilege-escalation gap (`:DefinitionsCreate`-only actor gaining
`:AdminServicesManage`-class access) and design a conjunctive permission
check as a safeguard should the restriction ever lift. Here, no such gap
exists — `:PROCESS_DESIGNER` (the role holding `:DefinitionsCreate`, the
permission `POST /solution-packs/install` requires) ALREADY holds
`:RolesManage` directly (`lib/letflow/api/authorization.ex`'s
`role_allows?(:PROCESS_DESIGNER, ...)` clause, confirmed above) and can
already call `POST /roles` with no additional gate of any kind. A
permissive pack design here would not be closing a privilege gap the way
0027's hypothetical had to — it would purely be offering a second way for
an actor to do something they can already do directly, in one call, today.
That is exactly the "marginal value is convenience, not new capability"
conclusion 0027 §7 point 3 reached about its OWN rejected design, restated
here with an even flatter authorization landscape (no gate needed at all,
versus 0027's gate-conditioned convenience).

**A NO on this sub-question was genuinely available, not argued away, and
0027 is the standing precedent for exactly that kind of permanent NO** —
this record states so explicitly, per the requirement's own instruction,
and does not treat either NO (this one or §1's) as a deferral or a
failure to design something.

### 3. The audit question does not arise. Both answers 1 and 2 are NO, so there is no pack-supplied script content and no pack-seeded role for any audit mechanism to attach to

Per the requirement's own framing, sub-question 3 is conditional on EITHER
answer to 1 or 2 being YES. Both are NO. **This record does not pick
between reusing `Letflow.Engine.LuaScriptAudit` and modelling a new record
on it, because there is no pack-supplied script content for either
mechanism to audit — nothing this record's §1/§2 decisions produce reaches
a `pack_document`, an install transaction, or a runtime executor.** The
stage file's own "Open questions" entry naming this as a
`SECURITY-REVIEWER`-interest item stays open for the DIFFERENT,
not-yet-filed requirement §1 names (a scripted-rule out-of-band
provisioning route) — that future requirement inherits the audit question
in full, including the security framing this record states for its
benefit without resolving it: **pack-supplied script content, if it is
ever built, would be durable, tenant-supplied content that CAUSES LATER
EXECUTION — a different threat model than a definition graph, which is
inert data interpreted by the engine's own fixed process-execution
semantics, never by an embedded interpreter running tenant-authored
instructions.** `LuaScriptAudit`'s own moduledoc words, quoted above,
describe a MINIMAL, deliberately narrow audit-persistence path against an
INJECTED executor, explicitly NOT the general script-execution handler —
whichever future requirement answers this question must pick, by name,
between "reuse `LuaScriptAudit`" and "model a new record on it" against
those exact words, because they describe two different answers with
different consequences, not one answer stated two ways. This record
declines to pre-empt that pick, because doing so now, with no concrete
ingestion or execution path to design against, would be exactly the kind
of speculative mechanism-before-need decision 0027 §7 point 2 already
warned against for a structurally similar case.

### 4. Yes, the recurrence is a structural signal worth naming — but the answer is to keep the type closed, because a closed set is what forces each new section's install policy to be decided by name rather than defaulted

**In one unambiguous sentence: `pack_document`'s content sections should
stay a closed, exhaustively-enumerated struct type, not become an open
registry, because every proposal to add a key has turned out to need its
own bespoke, individually-reviewed install policy rather than a
mechanical extension, and a closed set is what forces that policy
decision to be made explicitly, by a named decision record, before any
tenant-supplied content under that key can ever reach an install
transaction — which a generically-dispatched open registry would not
force.**

Supporting this by naming every section added or wanted since the type
was first written, and what each required changing:

- **`definitions`** (original, R-Co-ported) — required no new-section
  decision; it was the type's founding key.
- **`service_catalog_entries`** (original key, present in the type since
  before it was supported) — required `pack_document`'s type, a
  `check_unsupported_sections/1` hard-reject clause, and, per 0027, a full
  decision record settling that it stays permanently unsupported, with an
  authorization/scope/audit/conflict analysis (0027 §§2-5) written and
  then explicitly NOT built.
- **`variable_schemas`** (REQ-109) — required the type, `parse_document/1`,
  an export helper, and an install-side `register_variable_schemas/3` step
  — the one section among the five that shipped as a mechanical,
  uncontested extension with no rejected-design analysis attached.
- **`manifest.required_roles`** — required the type and
  `parse_required_roles/1`, but explicitly did NOT get an install-side
  write step; it shipped read-only by design (moduledoc, re-verified
  above), and this record is the second decision record (after the
  moduledoc's own original design) to consider and re-affirm keeping it
  that way.
- **`entity_definitions`** (0026, REQ-303 through REQ-306) — required
  editing the type, `parse_document/1`, `check_unsupported_sections/1`
  (considered, per 0026 §1(c), though the shipped clause did not end up
  needing to gate it), a new export helper, and a new install-side
  `create_packed_entity_definitions/3`-shaped step — the fullest section
  addition to date, and the one the requirement's own "gap 13" citation
  names as the first occurrence of this pattern.
- **Scripted rules** (gap 16, this record) — WANTED, not added; this
  record's own analysis (§1) shows it would require the type, a parser, a
  brand-new out-of-band provisioning route (since no in-pack path is
  adopted), and an unresolved audit-mechanism pick (§3) — the heaviest
  hypothetical addition of the six, and the one this record declines.
- **Role seeding** (gap 17, this record) — WANTED, not added; unlike every
  other entry here, the FIELD (`manifest.required_roles`) already exists
  in the type — what was wanted was a change in installation SEMANTICS
  (read-only checklist -> upsert_role/2-driven write), not a new key. This
  record declines that too (§2).

**Six proposals against one five-key type since it was founded is the
concrete count behind "twice-recurring" becoming, by this record's count,
closer to a running pattern than an outlier — but the pattern each time
is "this needs a decision, not a schema change," and three of the six
(this record's two, plus `service_catalog_entries`) resolved to NOT
building the section at all.** An open registry would have made adding
a section mechanically cheaper in exactly the cases where mechanical
cheapness was the wrong thing to optimize for — `service_catalog_entries`
and, by this record's own two answers, scripted rules and role seeding
all needed a REVIEWER/SECURITY-REVIEWER-gated decision record BEFORE any
schema change, not instead of one, and a closed type is what makes an
undecided key impossible to silently start accepting. Keeping it closed
does not eliminate the cost 0026/0027/this record each paid — writing a
decision record — because that cost was never the type's own openness or
closedness to begin with; it is inherent to any new tenant-content section
under bucket A's own security posture (0022's bucket rule; INV-1/INV-9
apply per-section, not to the pack format generically).

### 5. Corrected pack-phase deliverable list

The pack phase's phase-table row currently lists four items. Given §1
(scripted rules: NO) and §2 (role seeding: NO), **two of the four are not
pack deliverables at all as currently worded, and the corrected list, for
the phase-table owner to apply, is:**

1. **Entity definitions** — unchanged; a genuine pack deliverable
   (`entity_definitions` section, decision 0026).
2. **Process definitions** — unchanged; a genuine pack deliverable
   (`definitions` section, the type's founding key).
3. ~~Role-registry seed~~ -> **Role mapping checklist (advisory,
   read-only)** — corrected per §2: the pack produces a checklist naming
   roles a tenant's installed definitions reference; it does not create,
   upsert, or otherwise seed any row in the role registry. Any actual role
   provisioning happens out-of-band, through the existing `POST /roles`
   route, which this record confirms `:PROCESS_DESIGNER` (the same actor
   who can install the pack) can already call directly.
4. ~~Scripted rules~~ -> **REMOVED from the pack phase's own
   deliverable list.** Per §1, no pack section carries scripted rules
   today, and this record does not adopt one. If a scripted-rule
   provisioning route is later built (§1's named, not-yet-filed
   alternative), it is a SEPARATE deliverable, on a SEPARATE provisioning
   path, not a pack-document section — the phase-table owner should track
   it (if at all) as its own row, not as a sub-item of the pack phase's
   deliverable list, since "pack phase" deliverables are, per this
   record's own scope, things `Letflow.Definitions.SolutionPack.install/3`
   actually installs.

**This record states the correction; it does not edit the S10 stage file
— that edit is left to that file's owner, per this record's own scope
fence.**

## Reasoning

Each sub-question's justification is stated inline with its answer above,
because each turns on a different piece of the codebase (the absence of
any script payload or callable audit path for §1, the `:RolesManage`
permission-resolution chain for §2, `LuaScriptAudit`'s own narrow-scope
statement for §3, and the section-by-section install-policy history for
§4). The one cross-cutting principle, shared with 0027: **"no operational
upside today, plus an already-adequate out-of-band path or plainly
insufficient runtime support, is sufficient reason to keep new
tenant-content surface out of the pack" — this record's contribution is
applying that same posture to two more sections, and, new to this record,
observing that the posture generalizes into a reason to keep the section
SET closed too, not only each section's own content decision.**

## Consequences

- **No code changes anywhere.** `pack_document`'s five keys, `check_unsupported_sections/1`,
  and every other line of `lib/letflow/definitions/solution_pack.ex` are
  untouched by this record.
- **`manifest.required_roles` stays exactly as documented** — read-only,
  advisory, no role created, no install ever rejected because of it.
- **No new pack section for scripted rules.** S10 gap 16 stays open until a
  separate, not-yet-filed bucket-B requirement builds the out-of-band
  provisioning route §1 names, and that requirement inherits the audit
  question (§3) unresolved by this record.
- **The pack phase's phase-table row needs the correction stated in §5** —
  left for that file's owner to apply; this record does not touch the S10
  stage file.
- **No design artefact is produced under `lib/letflow/design/`.** Both
  sub-question 1 and sub-question 2 resolved NO, and per this requirement's
  own instruction a design artefact is warranted only when the answers
  reached actually require one — with no pack-carried scripted rule and no
  pack-seeded role, there is no new function signature, schema field, or
  install-path step for a design doc to specify. This mirrors 0027's own
  "no design artefact" consequence for the same reason.
- **Bucket A's meaning under 0022 is UNCHANGED, and this record says so in
  those terms rather than leaving it to inference.** 0022 defines bucket A
  as "definitions installed via `Letflow.Definitions.SolutionPack.install/3`."
  Since this record adds no new section and no new install-side write, the
  set of things `install/3` actually installs is identical after this
  record to what it was before — bucket A's boundary does not move. (Had
  either answer been YES, bucket A would have grown to include that new
  installed content; a NO/NO answer is precisely the case that leaves the
  boundary where 0026 last left it.)

## What this record does not decide

- **Whether or when a scripted-rule out-of-band provisioning route is
  built.** That is a separate, unscheduled, not-yet-filed bucket-B
  requirement this record names the shape of (§1) but does not file.
- **The audit mechanism for pack-adjacent (or any other) scripted-rule
  content** — explicitly left open per §3, for the requirement named in §1
  to resolve when it exists, against `LuaScriptAudit`'s own moduledoc words
  quoted here for its benefit.
- **Correcting the S10 stage file's phase-table
  row.** §5 states the corrected wording; applying it is left to that
  file's owner, per this record's own scope fence.
- **Whether the general SERVICE_TASK-with-script integration
  (`LuaScriptAudit`'s own "No caller yet" note; R-Co's
  `src/design/lua-integration.md` section 25) is ever built, or when.**
  Unrelated to and not assumed by this record.
- **Implementation of any kind.** No file under `lib/letflow/definitions/`,
  `lib/letflow/identity/`, `lib/letflow/engine/`, `priv/repo/migrations/`,
  or `test/` is touched by this record.

## SECURITY-REVIEWER sign-off

**Verdict: PASS** (2026-09-12, `SECURITY-REVIEWER`, REQ-325).

**Scope note.** Per this requirement's own framing, this is a
design-time/policy-time review, not a review of running code —
`git status --porcelain` on this branch shows only the new,
untracked `0029-*.md` file; every `.ex` file this sign-off cites was
read read-only and is unmodified. INV-1 applies (S1/S2 are done and
this record touches reasoning about tenant-scoped identity/role
data), so it is addressed by name below rather than dismissed by the
stale "almost always NOT-APPLICABLE" framing. INV-2/INV-3/INV-5
(S4/S5-scoped) are NOT-APPLICABLE — no migration, no API route, and
no response-shaping code is added or changed by this record.

**1. Pack-supplied executable content, addressed by name and
independently re-verified, not taken on the record's word.**
`grep -in lua lib/letflow/definitions/solution_pack.ex` was re-run
directly by this review and returns zero hits, matching the record's
claim exactly. `pack_document`'s `@type` (lines 222-232, re-read in
full) carries exactly the five keys the record lists — `definitions`,
`service_catalog_entries` (`[]` only, per 0027), `variable_schemas`,
`entity_definitions`, `manifest: %{required_roles: [String.t()]}` —
and none of them is, or wraps, a script payload. `packed_definition`
(re-read) carries `definition_id`, `process_key`, `name`, `version`,
`graph` — no script field. **Conclusion, stated explicitly as this
sign-off's answer to the question this decision record exists to
settle: this record's §1/§2 NO/NO answers admit no durable,
tenant-supplied, pack-install-reachable content that causes later
execution.** A definition graph installed via `install/3` is inert
data interpreted by the engine's own fixed process-execution
semantics; nothing an installed pack carries today is handed to an
interpreter, an executor, or any script-identity path. This record
adds no code and no new `pack_document` key, so this conclusion holds
for the tree as it stands both before and after this record merges.

**2. `LuaScriptAudit`'s characterization, independently re-verified.**
`lib/letflow/engine/lua_script_audit.ex`'s moduledoc, read in full,
confirms the record's characterization verbatim: it is a "MINIMAL,
deliberately narrow engine-side call path," explicitly "NOT the
SERVICE_TASK script-execution handler," and its "No caller yet"
section states plainly "nothing in this codebase calls
`execute_script_for_audit/6`." `grep -rn execute_script_for_audit
lib/` was re-run directly and confirms every hit outside
`lua_script_audit.ex` itself is either `.ex` code that documents or
consumes the *audit path's own contract* without calling it
(`lib/letflow/engine/lua/manifest.ex:195`, `lib/letflow/engine/lua/platform.ex:240`,
both prose/reference, not call sites) or `lib/letflow/design/*.md`
prose — no executing call site exists anywhere in `lib/`. This
matters for the FUTURE requirement §1 names, not for this one: if a
future requirement ever adds a pack-supplied-script provisioning
route, that requirement's own SECURITY-REVIEWER gate must resolve, by
name, (a) which of the two options this record correctly declines to
pick — reuse `LuaScriptAudit` as-is, or model a new audit record on
it — given that `LuaScriptAudit` is deliberately fenced off from
normal execution flow and has no caller to inherit an ingestion
contract from, and (b) what boundary prevents a pack-installed script
from reaching execution through any route OTHER than the deliberately
narrow, injected-executor path that requirement would build — i.e.
that a general SERVICE_TASK-with-script integration is a distinct,
unbuilt, separately-gated surface, not something this record's NO
leaves implicitly half-open. This record's own threat-model framing
(pack-supplied script content would be durable, tenant-supplied,
content that CAUSES LATER EXECUTION — a different threat model from
an inert definition graph) is accurate and is the correct starting
point for that future gate; it does not, and could not, resolve the
audit-mechanism pick itself, and this sign-off agrees that resolving
it now, with no concrete ingestion path to design against, would be
premature rather than conservative.

**3. Asymmetry with 0027, assessed for security posture, not just
consistency.** Independently confirmed: unlike `service_catalog_entries`,
there is no existing out-of-band route for scripted rules today (no
HTTP route registers a script anywhere under `lib/letflow/routers/`,
confirmed by grep). The record's NO here rests on "no operational
upside, real added surface" rather than "an existing route already
covers it." **This sign-off agrees this is the MORE conservative
posture of the two, not a weaker one**: 0027's NO left a designated
redirect target (`POST /service-catalog`) for anyone asking "where
does this content actually go instead?" This record's NO leaves no
redirect target at all — scripted rules go nowhere, in-pack or
out-of-band, until a separate, not-yet-filed requirement builds one
under its own gate. A NO with no substitute path closes the surface
entirely rather than relocating it; that is a smaller, not larger,
attack surface than 0027's NO, and the record is correct to say so.

**4. `:RolesManage`/`:PROCESS_DESIGNER` permission-chain finding,
independently re-verified in `lib/letflow/api/authorization.ex`.**
`endpoint_policy_key("POST", "/roles")` (line 498) resolves to
`:RolesManage`; `required_permission(:RolesManage)` (line 708)
resolves to itself, not through `:UsersGroupsRolesManage`. The
`role_allows?(:PROCESS_DESIGNER, permission)` clause (lines 756-780,
re-read directly) lists `:RolesManage` in its literal permission list
(line 758) alongside `:DefinitionsWrite` — the same role that holds
`:DefinitionsCreate`, which `POST /solution-packs/install` requires
(`lib/letflow/routers/solution_packs.ex` line 167, re-confirmed).
**This independently confirms the record's finding: `:PROCESS_DESIGNER`
holds `:RolesManage` directly, with no additional gate, and can already
call `POST /roles` today.** This does remove the privilege-escalation
question 0027 had to design a conjunctive-permission safeguard for —
here there is no cross-actor gap a permissive pack design would need to
close, only a convenience a permissive design would duplicate. The
record's permission-matrix characterization is accurate, not
mischaracterized.

**Residual security-gap check on the role-seeding NO.** `POST /roles`
(`lib/letflow/routers/identity.ex` line 207, `authz_post "/roles",
:RolesManage`, dispatching to `Letflow.Identity.RoleRegistry.upsert_role/2`)
is genuinely already gated by `:RolesManage`, confirmed above.
Declining to add a pack-based role-seeding path forces no workaround:
the actor who can install a pack (`:PROCESS_DESIGNER`) already holds
`:RolesManage` and can provision any role the installed definitions
reference through the existing, already-authenticated route, in one
call, with no privilege elevation and no new code path. No residual
gap is left open by this NO.

**5. Explicit answer to whether this record itself introduces,
permits, or leaves open any durable tenant-supplied content that
causes later execution: NO.** Both §1 and §2 resolve NO; this record
adds zero lines to `lib/`, zero new `pack_document` keys, and zero
new install-side write steps (confirmed via `git status --porcelain`
above and via the re-read of `pack_document`'s type, unchanged from
before this record). Since nothing this record does reaches a
`pack_document`, an install transaction, or a runtime executor, there
is no new ingestion point for tenant-supplied executable content, and
none of the content installed via `install/3` today (inert
definitions, variable schemas, entity definitions, an advisory
read-only role-mapping checklist) is itself executable — it is data
interpreted by the engine's fixed, non-tenant-authored semantics, not
tenant-authored instructions handed to an interpreter. The only path
by which pack-supplied executable content could ever exist is the
separate, not-yet-filed, bucket-B requirement this record names but
does not file — and that requirement inherits its own
SECURITY-REVIEWER gate in full, unweakened by anything decided here.

**INV-1, addressed by name.** This record introduces no new
caller-supplied tenant identifier and no code of any kind — consistent
with "No code changes anywhere" in its own Consequences section,
independently confirmed via `git status --porcelain`/`git diff` on
this branch (only the new `.md` file is untracked; no tracked file
carries a diff). NOT-APPLICABLE is the correct verdict for a decision
record that ships no implementation, and this sign-off treats that as
independently confirmed rather than assumed from the record's own
claim.

**No defects found. This gate PASSes.** Ready for `REVIEWER`'s gate
and then ORCH to commit/push/merge.

*(SECURITY-REVIEWER, 2026-09-12.)*

## REVIEWER sign-off

**Verdict: PASS (2026-09-12, `REVIEWER`, REQ-325).**

**1. Decision-record consistency — `0022`.** Read `0022` in full,
independently, not from this record's citations of it. Bucket A's own
definition, quoted directly from `0022`'s bucket table: "Pure
definitions — no Elixir, no TypeScript... a solution-pack document,
installed via `Letflow.Definitions.SolutionPack.install/3`." This
record's Consequences section states explicitly, not left for the
reader to infer: *"Bucket A's meaning under 0022 is UNCHANGED... Since
this record adds no new section and no new install-side write, the set
of things `install/3` actually installs is identical after this record
to what it was before — bucket A's boundary does not move."* I checked
that reasoning rather than accepting it: both §1 and §2 resolve NO, this
record's own "Consequences" confirms zero lines added to
`lib/letflow/definitions/solution_pack.ex` (re-confirmed independently
below via `git status --porcelain`), and `pack_document`'s five-key
`@type` is unchanged. Since bucket A is defined by what `install/3`
*actually installs*, and nothing this record does changes that set, the
stated conclusion is correct, not merely asserted. This record also
does not touch `0022`'s vertical/fork/federate decision or its bucket
table — it only produces the bucket-B decision-record artefact `0022`
already authorizes for a bucket-B requirement (REQ-325's own
`description` declares bucket B).

**2. Decision-record consistency — `0026`.** Read `0026` in full. `0026`
adds `entity_definitions` as a new `pack_document` key and, across its
five numbered sub-questions and its "Consequences" section, never states
or implies a position on whether the section set should be open or
closed — its only structural claim is that the *new key* follows the
same reject-until-supported pattern `service_catalog_entries` already
established (`0026` §4), which is a section-content-policy question, not
a schema-openness question. This record's §4 (keep `pack_document`
closed) is therefore not a re-decision of anything `0026` settled: `0026`
took no position for this record to contradict, and this record's own
history table (§4) correctly lists `entity_definitions` as the *fullest*
section addition to date rather than pretending `0026` argued for
closedness. `0026`'s own five-question structure, its
`## Re-verification performed` → `## Question` → `## Decision` →
`## Reasoning` → `## Consequences` → `## What this record does not
decide` → `## SECURITY-REVIEWER sign-off` → `## REVIEWER sign-off`
section order, and its "no implementation, only design-doc signatures"
discipline are the format this record (and `0027`) both follow — matched
here too (see point 5 below).

**3. Decision-record consistency — `0027`.** Read `0027` in full,
independently. `0027` §1's holding — permanent rejection of
`service_catalog_entries`, grounded in an *existing* out-of-band route
(`POST /service-catalog`, `:AdminServicesManage`) that already performs
the write a permissive pack design would duplicate — is the precedent
this record's §2 (role seeding) invokes for `POST /roles`, and correctly
so: both routes are existing, authenticated, tenant-scoped-at-write-time
HTTP surfaces that already perform, in one call, exactly the write a
permissive pack design would otherwise add. I independently re-checked
the permission chain this record's §2 rests on in
`lib/letflow/api/authorization.ex`: `endpoint_policy_key("POST",
"/roles")` resolves to `:RolesManage` (a distinct permission, not folded
into `:UsersGroupsRolesManage`), and `role_allows?(:PROCESS_DESIGNER,
...)` includes `:RolesManage` in its literal list alongside
`:DefinitionsWrite` — confirming `:PROCESS_DESIGNER` (the actor who can
install a pack) already holds `:RolesManage` directly. That is a
*stronger* case for NO than `0027`'s own `:AdminServicesManage`
asymmetry (where the pack-installing actor could NOT reach the
out-of-band route directly), and this record says so explicitly rather
than overstating the parallel as identical. For §1 (scripted rules), the
record correctly identifies the transfer as *partial*: `0027`'s NO rests
in part on "an existing route already covers it," and that clause is
false for scripted rules (confirmed independently — `grep` across
`lib/letflow/routers/` shows no route registers a script). The record
does not paper over this; it correctly relocates the NO's justification
onto `0027`'s *second*, independent argument ("no operational upside
today to offset the added surface," `0027` §7 point 2), which does
transfer, and states plainly that this makes §1's NO leave "no redirect
target" — a real, named asymmetry, not a suppressed one. Neither
transfer is overstated or understated.

**4. `0022`'s bucket rule 1 (no single-vertical vocabulary).**
Independently re-ran `grep -inE 'bilimbaga|exam|question bank|certificate'`
over this record: zero hits. The only domain-adjacent references are the
bare, by-number citations "S10 gap 16" and "S10 gap 17" and generic
phrases ("the pack phase," "that file's owner") — exactly what rule 1
requires. Confirmed no vertical is nameable from this record's text.

**5. No implementation code.** Independently scanned for `def `, `case
`, `with `, `defp ` and pipeline-shaped fragments. Two matches: line 270
("...with `pack_document`'s closed-struct shape?", a sub-question in
prose, not a `with` block) and a citation of the record's own
"Consequences" wording ("...with 'No code changes anywhere' in its own
Consequences section...") inside its own §5 explicit-answer paragraph —
both are prose, not executable Elixir. No `@type`/`@spec`/function head
of any kind appears anywhere in the document. This matches CODE-DESIGN-
VALIDATOR's characterization; not taken on trust.

**6. `upsert_role` caller-walk evidence, independently re-verified —
genuinely accurate.** Ran `grep -rn upsert_role lib/` directly and
sorted both the record's quoted output and my own independent run:
**byte-for-byte identical, 62 lines each, zero diff.** Walked the
record's own attribution of each `.ex` hit against the actual files:
`lib/letflow/identity/role_registry.ex` lines 5/50/52/55/83 are the
function's own definition (moduledoc, `@spec`, `def upsert_role`, the
call to its own private `do_upsert_role/2`, and that private function's
head) — confirmed not a caller. `lib/letflow/identity/tenant_role.ex`
lines 6/25/47 are moduledoc/comment prose only — confirmed no `def`,
`case`, or call appears at those line numbers. `lib/letflow/routers/
identity.ex` lines 35/54/208/658/663/664/669 — confirmed line 669
(`case RoleRegistry.upsert_role(name, group_id) do`) is the one live
call site, reached from `authz_post "/roles", :RolesManage` (line
207-209), and confirmed this router is never invoked by
`SolutionPack.install/3`. The record's conclusion — the only external
call to `upsert_role/2` is `POST /roles`, entirely independent of pack
install — holds. This is the third independent check of this evidence
(after CODE-DESIGNER's own and CODE-DESIGN-VALIDATOR's), per this
project's redundancy principle, and it found nothing to correct.

**7. §4's structural history, cross-checked against `0026`/`0027`
directly.** Independently verified each line of the six-entry table:
`entity_definitions` (`0026`) did require the type, `parse_document/1`,
a `check_unsupported_sections/1` clause considered (though not ultimately
needed to gate it — confirmed via `0026` §1(c)), a new export helper, and
a new install-side create step — matching `0026`'s own "Consequences"
section exactly. `service_catalog_entries` did require the type, the
hard-reject clause, and `0027`'s own full authorization/scope/audit/
conflict analysis before being permanently declined — matching `0027`'s
"Consequences" exactly. The record's count ("six proposals against one
five-key type... three of six resolved to NOT building the section at
all") is arithmetically consistent with what `0026`/`0027`/this record
each actually did. The §4 conclusion (keep the type closed because each
addition needs its own reviewed policy decision, not a mechanical
extension) does not contradict anything `0026` or `0027` decided about
their own sections — it only observes the pattern across all three.

**8. Confirmed this record does not edit the S10 stage file.**
Independently re-read the record's "Consequences" and "What this record
does not decide" sections: both state the corrected phase-table wording
(§5) is "for the phase-table owner to apply" and that "this record does
not touch the S10 stage file." Independently confirmed via `git status
--porcelain` and `git diff --name-only`: the only change in the working
tree is this one file,
`docs/migration/decisions/0029-solution-pack-scripted-rules-and-role-
seeding-scope.md` — `docs/migration/stage-10-bilimbaga-vertical.md` does
not appear in either. The record's self-description matches its actual
diff footprint.

**9. Scope.** `git status --porcelain` shows exactly one untracked file,
this record; `git diff --name-only` against the working tree shows no
tracked file modified. No `lib/`, `priv/repo/migrations/`, or `test/`
path is touched, consistent with the record's own "No code changes
anywhere" and "Implementation of any kind" scope fences.

**10. Idiom/supervision/scope-creep gate, applied to this record's own
conclusion (per this role's mandate beyond decision-record consistency).**
This record produces no `gen_statem`, no supervisor, and no OTP process
of any kind — it is a decision record, not code, so questions 1–2 of this
role's standard checklist (idiomatic `gen_statem` usage, per-instance
supervision) do not apply to it directly. On scope creep (question 4):
this record's own §4 conclusion is itself an argument *against* adding
abstraction (an open pack-section registry) ahead of need, in favor of
keeping the existing closed-struct shape until a decision record justifies
each addition by name — that is the correct posture, not scope creep in
either direction. No new type-safety gap worth filing under
`docs/issues/` was found: this record adds no transition logic, no new
`@type`, and no new state.

**No defects found. This gate PASSes.** Ready for ORCH to
commit/push/merge.

*(REVIEWER, 2026-09-12, REQ-325.)*
