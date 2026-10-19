# Runbook: turning scope enforcement on (REQ-519)

GH #2535, decision 0051 D12 and amendments A8-A10. The checklist and facts an operator needs before and
after a tenant is set to `on`. `docs/roles.md` carries the same text for readers of the role charter.

**No production tenant is set to `on` until the supervisor says so.** Flipping a production tenant is a
UAT/infra step that needs the user's written approval. It is not done by an implementation agent as part of
any PR of REQ-519, and no test, seed, migration or script of that requirement flips a production tenant.
Pilot tenants only until RA-6 (REQ-525, REQ-526, REQ-527) and the task scope writer exist.

## Turning scope enforcement on and off (operator procedure)

`PUT /api/v1/tenant/scope-enforcement` with `{"mode": "off" | "shadow" | "on", "reason": string?}` (REQ-519). Only an interactive (OIDC) user who holds TENANT_ADMIN tenant-wide can call it. API tokens, scoped admins, and a platform-tenant PLATFORM_ADMIN without TENANT_ADMIN get the uniform 403, for every transition (earlier releases let tokens and a platform admin move `off` to `shadow`; that is closed). The flag route for ANOTHER tenant from the platform scope is not built.

| From to | Result |
|---|---|
| `off` to `shadow` | the three stage-1 facts must hold (no binding without a grant row, scope tree consistent, no token above its owner) |
| `shadow` to `on` | the six gate facts below must hold |
| `off` to `on` | 409 `shadow_required`: `on` is reached only from `shadow` |
| `on` to `shadow` | no precondition; a `reason` is mandatory |
| `shadow` to `off`, `on` to `off` | no precondition; a `reason` is mandatory |

A refusal is a 409 `enforcement_precondition_failed` whose `failed` array lists every failing code, with the counts (`report`) and the evidence summary (`evidence`); a refused flip to `on` writes one `scope.enforcement_refused` audit entry. A successful flip writes `scope.enforcement_enabled` (the mode went up: off < shadow < on) or `scope.enforcement_disabled` (it went down) in the same transaction as the change.

The gate for `shadow` to `on`, stable codes: `bindings_without_row`, `org_inconsistent`, `tokens_exceed_owner` (tokens of a flagged service principal still count; the flagged-service-principal exemption covers only the mint subset check), `zero_tenant_wide_admins` (at least one active, interactive human with an explicit tenant-wide TENANT_ADMIN grant is required: token owners and flagged service principals do not count, because only such a user can turn enforcement off), `scoped_approvers_without_task_scope` (see the scoped approvers limitation above), `shadow_evidence_insufficient` (the tenant has been in `shadow` for at least `scope_shadow_min_days` days, default 7; at least `scope_shadow_min_requests` requests, default 100, over the window; requests on every date of the window; no `no_grant_rows` or `grants_unavailable` would-deny). The thresholds are server configuration only. `GET /api/v1/tenant/scope-enforcement/integrity` shows the same facts as a lock-free snapshot in its `on_gate` block (`findings` is the older informational list; `on_gate.blocking` is what the `on` flip will check).

The shadow period proves only the denials of tenant-wide and admin-plane routes; denials on the data path (compiler predicate, 404 equivalence, writes, bulk and import, F1) are proven by the REQ-518 tests and the end-to-end suite, not by shadow.

The flip request itself counts as a shadow request, and request counts include every authorized request of any principal, the flipping admin's own included, so the evidence rule is an operator-safety control, not an adversarial one.

## What `on` means in production today

Read this before flipping any tenant. Only pilot tenants may be flipped, and pilot use must wait for the open items: the tenant-level metadata reads for scoped users (RA-6, REQ-525..527, filed in #2862); the last-admin gap (#2869: a tenant stored `on` can end with nobody able to turn it off; a guard extension or a break-glass is still undecided); and the writer of `tasks.scope_node_id` (W3b, #2870). The decision-record amendment is 0051 A8-A10 (PR #2871).

1. A tenant that passes the gate can be set to `on` by an interactive tenant-wide TENANT_ADMIN, only from `shadow`, with an audit trail.
2. `on` delivers: the admin plane is closed to scoped admins, scoped users get a uniform 403 on every tenant-wide route, binding writers and IdP sync no longer widen anyone, and the grant tables fail closed.
3. `on` does NOT deliver data-level scoping in production. No installed module declares scope, so a scoped user sees no entity data; and no writer sets `tasks.scope_node_id`, so a scoped task worker sees no task and a scoped approver cannot claim or complete one.
4. The shadow period proves only the denials of tenant-wide and admin-plane routes (the sentence above).
5. Scoped users lose definitions, entity-definition, instance and service reads until the tenant-level metadata follow-up (RA-6) ships.
6. Do not scope the CANDIDATE binding: the exam routes stay tenant-wide, so a scoped CANDIDATE gets 403 and exam sessions break.
7. To turn `on` off: an interactive tenant-wide TENANT_ADMIN, with a mandatory reason. Tokens cannot. There is no platform-scope break-glass in this release.
8. A platform tenant stored as `on` does not restrict its PLATFORM_ADMIN on platform-scope routes; grants never decide platform scope.

The scoped-approver blocker is evaluated at flip time only: a scoped approver created after `on` is fail-closed and shown in the `on_gate` information count of the integrity report.

## Known limitations of an enforced tenant

- LIMIT-IDP-SYNC-WHOLE-GROUP: in an `on` tenant the IdP role-claims sync adds NO membership to a group that binds a platform role which would make the user tenant-wide for that role. A membership cannot be split by role, so the non-widening roles of that group are withheld too (SEC A-7). The audit entry is `grant.sync_suppressed` when the user already holds scoped rows for the role and `binding.pending_scope` when the user holds none. Login still succeeds.
- LIMIT-POST-ROLES-409: `POST /roles` answers 409 `scope_required` in an enforced tenant for a new platform-role binding (or a routing-role binding converted to a platform role). Remedy: create the binding before enabling enforcement, or set enforcement to off with a reason, create it, narrow its scope, and enable again.
- LIMIT-IMPORT-UPSERT-404: a scoped caller's import in `upsert_by external_ref` mode is refused with the generic 404 (the generic not-found answer), even for rows inside its scope, because the upsert primitive (`Records.upsert_record_by_external_ref`) is not scope-aware. The refusal is in the entities router (`import_scope_check/6`, `lib/letflow/routers/entities.ex`, which does not match `create` for it and falls through to `:scope_refused`, mapped to the 404), not in the Records primitive, so tenant-wide callers are unchanged. Only `create` mode imports are offered to a scoped caller. A scope-aware upsert is not built.
- LIMIT-ON-FLAG: `on` is settable only from `shadow`, by an interactive tenant-wide TENANT_ADMIN, after the gate passes (REQ-519 2f-b); `off` to `on` is refused as `shadow_required`. The three limitations above still hold once `on` is settable.
