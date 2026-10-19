# GH #2883: operator break-glass for an `on` tenant (REQ-519 GATE, part (b) of GH #2869)

AGENT: CODE-DESIGNER. Workflow WF-02, run `WF02-GH2883-BREAKGLASS-20261019`, step 01.
Base: `origin/main` 5f7ad82f7 (REQ-519 2e-a, 2e-b, 2f-a merged). Branch `feature/WF02-REQ519-2883-BREAKGLASS-20261019`.
Builds on REQ-519 2f-b = PR #2882 (enqueued, NOT yet on main), read on `origin/feature/WF02-REQ519-2FB-ON-SETTABLE-20261019`.
Design only: signatures are `@spec`-shaped text, queries and flows are prose, no function bodies, no `.ex` blocks.

Sources read in full: GH #2883 and GH #2869 (bodies and comments; #2535 body and the REQ-519 AC 23 and AC 24 text in
`docs/requirements.yaml`), decision 0051 A6 and A7, 0046 D4 and D9 (as quoted in 0053), `docs/agents/instructions/security-invariants.md`
INV-10, the design `req519-enforced-writers-and-flag-on.md` (sections 3.7, 4.1, 4.2, 4.2a, 4.3, 4.9, 9, 10, 11, 13, 14), and, as built on
the 2f-b branch: `lib/letflow/scope_enforcement.ex`, `scope_enforcement/on_gate.ex`, `scope_enforcement/shadow_window.ex` (T0),
`routers/tenant_scope_enforcement.ex`, `docs/runbooks/scope-enforcement-on.md`, `docs/roles.md` items 7 and 8,
`test/letflow/scope_enforcement/on_flip_guards_test.exs`, `test/letflow/scope_enforcement_flip_authority_test.exs`,
`test/letflow/docs/roles_on_flip_docs_test.exs`. On `main`: `Letflow.Audit` (`insert_entry/3`, chain lock), `Audit.Entry`,
`Audit.Reason`, `Letflow.Identity` (`lock_tenant_admins!/1`, `get_tenant_by_slug/1`), `Identity.Tenant`, `TenantProvisioning`
(`registered_schema/1`, `schema_name_for_tenant/1`), `PlatformTenant`, `Plugs.AuthPipeline` (flag read per request),
`Letflow.Release.IdempotencySquats` + `Letflow.Idempotency.SquatRemediation` + `Mix.Tasks.Letflow.RemediateIdempotencySquat` (the operator
precedent), `Mix.Tasks.Letflow.BackfillRoleScopeGrants`, `docs/runbooks/idempotency-key-squat-audit.md`,
`docs/runbooks/login-directory-pepper-rotation.md` section 0. Nothing was run (no `mix`, no tests), as instructed.

## Changelog

| Rev | Date (UTC) | Change |
|---|---|---|
| r0 | 2026-10-19 | Initial design. |
| r0a | 2026-10-19 | CODE-DESIGN-VALIDATOR PASS_WITH_FINDINGS, four small fixes applied inline (marked "Validator fix r0a" in 3.4, 3.9 and 10.1, plus the pinned `Tokens cannot` claim). Kept in r1. |
| r1 | 2026-10-19 | SEC design gate PASS_WITH_FINDINGS folded (`step-03-security-reviewer-design.json`). F-1 (MEDIUM): explicit transaction timeout derived from the lock timeout (3.4 step 3, 3.5, T-BG-14c, MU-BG-27, R-BG-10). F-2 (MEDIUM): text scan over ALL of `lib/` limited to the allowed files, `apply/3` and capture forms covered, each scan proven live (6, MU-BG-16). F-3 (LOW): `after_state["node"]` added (3.7, T-BG-4); the operator label appears in the refusal and fault log lines ONLY when it passes the label rule (3.9, T-BG-22, T-BG-24, T-BG-25, MU-BG-11). F-4 (LOW): Mix form is dev and CI only (3.2, 10.1, T-BG-27). RA-B1 accepted as 0051 A11 with three edits (13). S-BG1..S-BG12 and OQ-1..OQ-10 accepted as built. |

---

## 0. Findings against the issue text and the as-built code (read first)

* F1. `flip/4` already implements the de-escalations the break-glass needs (`on -> shadow` with a mandatory reason, `* -> off` with a
  mandatory reason, no precondition, audit action `scope.enforcement_disabled`, same transaction). What it cannot do is run WITHOUT
  an interactive tenant admin: its only caller is the router, whose authority check
  (`Scope.require_interactive_tenant_admin/1`) needs an OIDC TENANT_ADMIN, and its `attrs.actor_id` is a user id. So the break-glass
  is NOT a new transition rule; it is a new AUTHORITY PATH to a subset of the existing transitions. That is what the design builds.
* F2. The audit actor cannot be a label. `audit_entries.actor_id` is a `:binary_id` (UUID) column and is part of the hashed form
  (`Letflow.Audit` moduledoc, field 3: canonical UUID string or the NULL sentinel). Every system or operator action in the codebase
  therefore writes `actor_id: nil` and puts the human label in the entry payload; the direct precedent is
  `Letflow.Idempotency.SquatRemediation` (`actor_id: nil`, `"operator" => label` in `before_state`, operator validated as 1..N printable
  bytes). The issue wording "the actor recorded as the operator" is met as: `actor_id` NULL (no user) plus a mandatory, validated
  `operator` label in the entry payload. No schema or migration change is needed or proposed.
* F3. A release container has NO Mix and `bin/letflow eval` does not start `Letflow.Repo` (`docs/runbooks/idempotency-key-squat-audit.md`,
  `login-directory-pepper-rotation.md` section 0, verified on QA by infra T-0154). The only way to run operator code on a deployed node is
  `bin/letflow rpc "<one line expression>"` against the RUNNING node, with a public function that prints its own result. `System.halt`
  inside `rpc` would stop the live node, so the release function never halts. The Mix task is a thin wrapper for dev and CI hosts.
  The same pattern is used by `Letflow.Release.IdempotencySquats`; this design follows it exactly.
* F4. `rpc` runs INSIDE the node's VM. `System.get_env("USER")`, `System.cmd("whoami")` etc. there describe the node's service
  account (one account for every operator), not the human, and the environment is the node's, not the caller's. So no
  environment-derived identity is available in the release form; the operator must be named in the call (3.3).
* F5. The flag is read per request from the `tenants` row by both auth paths, uncached (`Plugs.AuthPipeline.attach_auth_context/6` and
  the comment at lines 444-449 and 479-481; no ETS or cache there). A committed break-glass is therefore effective on the next
  request on EVERY node. There is no cross-node step (3.11).
* F6. T0 of the shadow window is the latest `scope.enforcement_enabled` or `scope.enforcement_disabled` entry of the tenant whose
  `after_state["mode"]` is `"shadow"` (`ShadowWindow.shadow_since/2`, 2f-b branch). An out-of-band `on -> shadow` entry that uses the
  same action name and the same `after_state["mode"]` restarts the window by construction, with no change to `ShadowWindow`. This
  confirms REQ-519 AC 23 limitation LIMIT-EMERGENCY-RESHADOW; it is by design (3.8).
* F7. The 2f-b scans are stricter than the issue assumes: `scope_enforcement_flip_authority_test.exs` pins "the `tenants.scope_enforcement`
  column is written by `Tenant.scope_enforcement_changeset/2`, called only by `lib/letflow/scope_enforcement.ex`", and
  `on_flip_guards_test.exs` pins "only the router calls `ScopeEnforcement.flip/4` from `lib/`" with an AST scan that matches the
  function name `flip` EXACTLY (`flip_call?/1`). A function named `flip_out_of_band` is not matched by that scan, so that existing
  assertion stays true without edit; the changeset scan stays true because the new function lives in the same file. The tests that DO
  change are listed in 6.
* F8. The docs are pinned: `test/letflow/docs/roles_on_flip_docs_test.exs` (2f-b branch) requires item 7 of the ON_IN_PRODUCTION list in
  `docs/roles.md` to contain the substrings `mandatory reason`, `Tokens cannot` and `no platform-scope break-glass`. This design makes that
  sentence false ("There is no platform-scope break-glass in this release"), so the docs and that test change in the same PR (6, 10).
  AC 23 also pins exactly seven `LIMIT-*` items, each token once, in both docs: the break-glass must NOT add an eighth `LIMIT-*` item.
* F9. The gate fact 4 (`zero_tenant_wide_admins`, interactive explicit admins only) cannot see an IdP-side login loss, and nothing in
  Letflow can detect "the admin exists in the database but cannot log in". So the break-glass must not depend on any admin, user, token
  or group row existing, and must not consult them (3.12).
* F10. 0051 A6 says the platform-scope ROUTE that flips ANOTHER tenant's flag stays unbuilt and needs its own decision record. A release
  command is not a route, and is not authorised by a role. The decision record question is therefore different from A6 (the command has
  no platform-scope HTTP authority at all). It still deserves a one-paragraph amendment so the next reader does not read A6 as "no
  break-glass exists" (proposed as RA-B1, section 13).

## 1. PR split and boundary

ONE PR (size: one new module in `lib/letflow/release/`, one Mix task, one public function plus two private helpers in
`scope_enforcement.ex`, docs, tests). Depends on PR #2882 (2f-b) being merged first: the design edits the 2f-b files
(`scope_enforcement.ex`, `scope_enforcement_flip_authority_test.exs`, `roles_on_flip_docs_test.exs`, `docs/roles.md`,
`docs/runbooks/scope-enforcement-on.md`). If #2882 is not merged when the build starts, the build branch is rebased on it; do not
re-create its files.

In scope: the flag change `on -> shadow` or `on -> off` out of band, its audit entry, the operator identity, the command surface, tests,
docs. Out of scope (stated so the builder does not drift): the last-admin guard (#2869 part (a)), the decision record (#2869 part (c),
proposed text in 13), any HTTP route or permission, any change to `flip/4` behaviour or its router, any change to the gate or
`ShadowWindow`, granting or restoring an admin, a cross-node anything.

Gate: after this PR AND #2869 (a) and (c) are implemented, the "no `on` flip in any customer tenant" gate of REQ-519 AC 24 may be
lifted by the supervisor. This PR alone does not lift it.

## 2. Decision summary

| Id | Decision | Default built | Needs |
|---|---|---|---|
| D-1 | Mechanism | A public release function `Letflow.Release.ScopeBreakGlass.run/5` (called with `bin/letflow rpc`) and a Mix task `mix letflow.scope_enforcement.break_glass` that only parses argv and calls it. Never halts in the function; only the Mix task halts. | none |
| D-2 | Writer | A NEW public function `Letflow.ScopeEnforcement.flip_out_of_band/3` in `scope_enforcement.ex`, sharing two private helpers (`lock_tenant_row!/2` and `write_flag_and_audit!/6`) with `flip/4`. `flip/4` is NOT called with a new attrs shape. | SEC S-BG1 |
| D-3 | Operator identity | Mandatory `operator` label argument; `actor_id` NULL; label validated and stored in `after_state["operator"]` with `after_state["source"] = "operator_break_glass"`. No environment or OS identity. | SEC S-BG2, S-BG3 |
| D-4 | Allowed transitions | ONLY from a tenant stored `on`, to `shadow` or `off`. Stored `off` or `shadow` is refused `{:not_enforced, mode}`. Target `on` is `:invalid_target`. | SEC S-BG5 |
| D-5 | Reason | Mandatory for both targets, same rule as `flip/4` (`Letflow.Audit.Reason.validate/1`), checked before the transaction. | none |
| D-6 | Lock order | `lock_timeout` set, then lock A, then the `tenants` row `FOR UPDATE` (T), then the audit chain lock (C) inside `Audit.insert_entry/3`. No S: de-escalation takes no scope-tree lock (same as `flip/4`). | none |
| D-7 | Wrong-tenant guard | The real run needs `confirm: <slug>` equal to the slug argument; `dry_run: true` reads and validates and writes nothing. No interactive prompt, no `--yes`. | OQ-3 |
| D-8 | Restart of the shadow window | Yes, for `on -> shadow` (F6). For `on -> off` there is no window; re-enabling needs `off -> shadow` (three facts) and a full new window. | accepted (AC 23 LIMIT-EMERGENCY-RESHADOW) |
| D-9 | Platform tenant | Allowed (it is a flag change, not a platform-scope act; refusing would strand the platform tenant's own TENANT_ADMIN). | SEC S-BG4 |
| D-10 | Refusals | Not audited (nothing changed); one constant log line each. A server fault is never a refusal. | SEC S-BG6 |
| D-11 | Zero-admin operation | The function reads no user, group, token or binding row; the only lock is the lock-A advisory key. | none |
| D-12 | HTTP | None. No route, no permission, no entry in the route snapshot, no router references the new modules (scanned, 6). | none |

## 3. Design

### 3.1 Module map

| Module / file | New or changed | Role |
|---|---|---|
| `lib/letflow/scope_enforcement.ex` | CHANGED | adds `flip_out_of_band/3`, its error type, two private shared helpers; `flip/4` behaviour byte-identical |
| `lib/letflow/release/scope_break_glass.ex` (`Letflow.Release.ScopeBreakGlass`) | NEW | operator entry point: validates the call, resolves the slug, prints, maps results; ONE caller of `flip_out_of_band/3` |
| `lib/mix/tasks/letflow.scope_enforcement.break_glass.ex` (`Mix.Tasks.Letflow.ScopeEnforcement.BreakGlass`) | NEW | argv parsing, `app.start`, calls the release module, halts non-zero on error |
| `lib/letflow/audit/reason.ex` | UNCHANGED | the reason rule is reused |
| `lib/letflow/identity/tenant.ex` | UNCHANGED | `scope_enforcement_changeset/2` keeps its one caller file |
| `ShadowWindow`, `OnGate`, `RefusedAudit`, router | UNCHANGED | |
| `docs/runbooks/scope-enforcement-on.md`, `docs/roles.md` | CHANGED | section 10 |
| tests | NEW and CHANGED | sections 5 and 6 |

The name `Letflow.Release.ScopeBreakGlass` sits under `Letflow.Release.` without defining `Letflow.Release`, like
`IdempotencySquats` (no collision with the wrapper module of GH #2567).

### 3.2 The mechanism: how it runs in a release

Release form (one line, printed result, no Mix): the operator calls through the running node, feeding the expression on STDIN as the
login-directory runbook section 0 prescribes:

```
Letflow.Release.ScopeBreakGlass.run("<slug>", "shadow", "<reason>", "<operator>", dry_run: true)
Letflow.Release.ScopeBreakGlass.run("<slug>", "shadow", "<reason>", "<operator>", confirm: "<slug>")
```

Dev and CI hosts ONLY (F-4): `mix letflow.scope_enforcement.break_glass <slug> --to shadow|off --reason "<text>" --operator <label>
(--confirm <slug> | --dry-run)`. The Mix task is a wrapper of the same function; it uses `OptionParser` with `strict:` options, rejects
any unknown switch, any missing mandatory switch and any extra positional (`Mix.raise` with the usage line), runs `Mix.Task.run("app.start")`
(same as `letflow.backfill_role_scope_grants`) and halts with status 1 on an `ERROR` result (status 0 for `OK` and `DRYRUN`).
`bin/letflow eval` is NOT supported (no Repo); this is stated in the function moduledoc and the runbook. In a release the exit status of
`rpc` is not meaningful: pass/fail is the printed `OK` / `DRYRUN` / `ERROR` line (precedent).

Why both: the release form is the only one that works on a deployed container (F3); the Mix form exists so CI, dev and the test suite
exercise the same function and so a dev checkout has a usable command. The Mix form is for dev and CI only and must not be used on a production
host: `Mix.Task.run("app.start")` boots a SECOND full Letflow application (supervision tree, listeners, schedulers) against the same database as the
running node. The Mix task moduledoc states this in its first paragraph, and the runbook says it (10.1); a test pins both sentences (T-BG-27). There is no `Letflow.Release` migrator-style module on main
to extend (verified: `lib/letflow/release/` holds `exam_snapshot.ex`, `idempotency_squats.ex`, `managed_types.ex` only).

```
Letflow.Release.ScopeBreakGlass
  @spec run(slug :: String.t(), target :: String.t(), reason :: term(), operator :: term(), opts :: keyword()) ::
          {:ok, %{outcome: :applied | :dry_run, previous: :on, mode: :shadow | :off}} | {:error, release_error()}
  # opts, strict: dry_run :: boolean() (default false), confirm :: String.t() (default nil). An unknown key is ignored.
  @type release_error ::
          :unknown_tenant | :invalid_target | :confirm_required | :confirm_mismatch
        | ScopeEnforcement.out_of_band_error()
  @spec exit_code(run_result :: {:ok, map()} | {:error, release_error()}) :: 0 | 1     # used by the Mix task only
```

Print protocol (precedent: `IdempotencySquats`): every call prints exactly one result line and returns the same information.

| Line | When |
|---|---|
| `TARGET slug=<inspect slug> current_mode=<on\|shadow\|off> target=<shadow\|off>` | after slug resolution and the target and reason and operator checks, before any write (also in dry run) |
| `DRYRUN would_change=true` | `dry_run: true` and the tenant is stored `on` |
| `OK slug=<inspect slug> previous=on mode=<shadow\|off> action=scope.enforcement_disabled shadow_window_restarted=<true\|false>` | applied |
| `ERROR <tag>` and, for `not_enforced`, ` current_mode=<off\|shadow>` | any refusal or fault; tags in 3.9 |

What is printed: the slug the operator typed (escaped through `inspect/1`, because slug format is not constrained by the schema: `Tenant.create_changeset/3`
only requires presence and uniqueness), the three modes, the audit action name and a boolean. NEVER printed: a tenant id, a schema
name, a user, group or token id or name, the reason text, the operator label, an exception message, an entry id, a trace id. A test
asserts no UUID-shaped string and no `tenant_<32 hex>` string appears in captured output (T-BG-22).

### 3.3 How the operator is identified and recorded

Facts: no user exists in this path (F9), the audit actor column is a UUID (F2), the environment is the node's (F4).

Design:

* The operator is a MANDATORY argument. Missing, `nil`, non-binary or blank is `{:error, :operator_required}`; present but not matching
  the label rule is `{:error, :invalid_operator}`. Label rule (pure, in `ScopeEnforcement`): a binary of 1 to 64 bytes matching the anchored
  expression of an ASCII letter or digit followed by up to 63 of letters, digits and `. _ @ + -` (anchored with `\A` and `\z`, so a trailing
  newline is rejected). That excludes whitespace, control, format and bidi characters, quotes and `#{`, so the label cannot spoof an audit
  reader or inject into a log line or a shell/rpc line. The label is stored as given (no trimming, no downcasing).
* There is NO default, NO fallback to `$USER`, `whoami`, the node name or the first admin, and the Mix task has no default either. A
  default would make the field optional in practice and in `rpc` would record the shared service account (F4).
* Stored in the audit entry: `actor_id` NULL; `after_state["operator"]` = label; `after_state["source"]` = the constant
  `"operator_break_glass"`. `actor_id` is never read from `attrs`: the function reads exactly two keys, `:operator` and `:reason` (an
  `:actor_id`, `:now` or `:trace_id` key in `attrs` is ignored; test T-BG-12). That makes it impossible to record a human user as the
  author of a break-glass, and impossible to inject a clock.
* Trace id: generated inside `flip_out_of_band/3` as a constant-prefix random id (`"break-glass-" <> 32 hex characters`), stored in the entry's
  `trace_id`, not printed. It lets support correlate with log lines of the same run (the success log line carries the operator label,
  not the trace id; the entry carries both). If you want the trace id on the console too, that is OQ-6.

What this does and does not prove (stated for SECURITY-REVIEWER, not hidden): the label is an ATTESTATION by someone who already holds
the authority (3.4); it is not authenticated. Anyone who can run `bin/letflow rpc` can run arbitrary code on the node, including a direct
`UPDATE` of the column, so no label check can add security against such a person. What the label adds is accountability: the entry, which
is inside the tamper-evident hash chain (`Audit.verify_chain/2`), says who the operator CLAIMED to be, with a reason, at a time. The
runbook requires the label to be the operator's personal handle as it appears in the infrastructure access log and the reason to carry
the incident ticket id, so the two records can be matched. An allow-list of operators (for example a deployment variable) was considered
and not built by default (OQ-2): it would be configuration that can be absent in exactly the emergency, and it is forgeable by the same
host access.

The authority is therefore the OS and container access control of the platform operator, NOT a Letflow role, permission, token or
group: no `PLATFORM_ADMIN` is needed or consulted (INV-10: a role name never confers platform authority, and none is used), and
the command grants no role (flag only; no conflict with 0046 D4: it reads no tenant content, prints none, and changes one flag).

### 3.4 Decision: `flip_out_of_band/3` versus `flip/4` with a new attrs shape

Chosen: a new public function `Letflow.ScopeEnforcement.flip_out_of_band/3`, sharing a transaction core with `flip/4`.

Why not extend `flip/4`'s attrs:

1. `flip/4` is the router-facing API and its authority is established by its CALLER (the router checks the interactive admin). A new
   attrs key that switches it into "operator mode" would turn every `flip/4` call into a call that can bypass that assumption if one
   attrs map is ever built from a less trusted source; the 2f-b scan ("attrs is ONE literal three-key map") was written exactly to
   rule that out. Keeping the two authorities in two functions keeps both scans simple.
2. The transitions differ: `flip/4` allows `off -> shadow`, `shadow -> on`, same-mode no-ops and `shadow -> off`. The break-glass allows
   only `on -> shadow` and `on -> off`. A separate function states the narrower table in one place and makes "never reaches `on`" a
   property of the function (its target type excludes `:on`) rather than a runtime check inside the broad one.
3. The prefix: `flip/4` takes a caller-supplied `prefix` and re-checks it (`:tenant_prefix_mismatch`). `flip_out_of_band/3` takes NO prefix:
   it derives it from the tenant's registration, so there is no prefix argument to get wrong.

Shared core (private, in `scope_enforcement.ex`; the refactor must leave `flip/4`'s observable behaviour, return values, audit shapes,
lock order, flush and refusal recording byte-identical, which the existing `scope_enforcement_transitions_test.exs`,
`scope_enforcement_test.exs`, `scope_enforcement_on_test.exs` and `on_flip_guards_test.exs` prove unchanged):

```
@spec lock_tenant_row!(tenant_id :: Ecto.UUID.t(), prefix :: String.t()) :: Tenant.t()      # private
  # inside a transaction: Identity.lock_tenant_admins!(prefix) FIRST (A), then the tenants row FOR UPDATE (T);
  # rolls back :tenant_not_found when the row is absent. Used by do_flip (flip/4) and by the out-of-band transaction.
@spec write_flag_and_audit!(tenant :: Tenant.t(), tenant_id, prefix, previous :: mode(), target :: mode(), entry :: map()) ::
        %{mode: mode(), previous: mode(), changed: true}                                       # private
  # the ONE call site of Tenant.scope_enforcement_changeset/2 (Repo.update!), then Audit.insert_entry/3 in the same transaction;
  # a failed audit insert is Repo.rollback({:audit_failed, error}). Used by both writers.
```

Consequence for the "ONE caller" assertions: `Tenant.scope_enforcement_changeset/2` still has exactly one caller FILE
(`scope_enforcement.ex`) and, after the refactor, exactly one CALL EXPRESSION (inside `write_flag_and_audit!/6`); the new scan counts
expressions, not only files (6, T-BG-31). There is still no second writer of `tenants.scope_enforcement`.

Public surface:

```
Letflow.ScopeEnforcement
  @type out_of_band_target :: :shadow | :off
  @type out_of_band_error ::
          :invalid_target
        | :operator_required | :invalid_operator
        | :reason_required   | :invalid_reason
        | :tenant_not_found
        | {:not_enforced, :off | :shadow}
        | :lock_conflict
        | {:audit_failed, term()}
        | {:transaction_failed, Exception.t()}
  @spec flip_out_of_band(
          tenant_id :: Ecto.UUID.t(),
          target :: out_of_band_target(),
          attrs :: %{required(:operator) => term(), required(:reason) => term()}      # exactly these two keys are read
        ) :: {:ok, %{mode: out_of_band_target(), previous: :on, changed: true}} | {:error, out_of_band_error()}
  @spec parse_out_of_band_target(term()) :: {:ok, out_of_band_target()} | {:error, :invalid_target}   # exactly "shadow" | "off"
  @spec valid_operator_label?(term()) :: boolean()                                                     # pure, the 3.3 rule
```

`changed` is always `true` on success (a same-mode request cannot occur: the previous mode must be `on` and the target is `shadow` or `off`).

Sequence of `flip_out_of_band/3`:

1. Pre-transaction checks, in this order (the same order as the release function, 3.9), each a distinct error and no database access:
   target (`:invalid_target`), reason (`nil`, a non-binary, or a binary that is empty after `String.trim/1` is `:reason_required`, decided
   BEFORE `Audit.Reason.validate/1` is called because `validate/1` answers `:error` for blank input; any other reason failing
   `Audit.Reason.validate/1` is `:invalid_reason`; the trimmed reason is what is stored), then operator (`:operator_required` /
   `:invalid_operator`). The reason is mandatory for BOTH targets. (Validator fix r0a: order aligned with 3.9, blank rule made explicit.)
2. Resolve the schema with `TenantProvisioning.registered_schema(tenant_id)`; `{:error, :not_found}` or an invalid id is
   `:tenant_not_found` (no raise). This is the registration table, so an id with a `tenants` row but no provisioned schema is also
   `:tenant_not_found`.
3. One transaction (the `rescue` encloses the whole transaction as in `flip/4`, so a raise anywhere is a rolled-back fault, never a
   refusal):
   a. constant `set_config('lock_timeout', <bound text of milliseconds>, true)` (transaction-local; bound parameter, nothing interpolated, INV-7);
      the value L is the application key `:scope_break_glass_lock_timeout_ms`, default `10_000`, read per call, set by tests only (scanned: not set in
      `config/runtime.exs` or `config/prod.exs`, like the shadow thresholds of 2f-b section 4.9 item 4c). SEC F-1: up to THREE waits can each last L (lock A,
      the `tenants` row, the audit chain lock), so the sum can reach 3 x L = 30 s, above the DBConnection default of 15 s; with the default a
      connection timeout could fire first and be printed as `server_fault` instead of `lock_conflict`. Therefore the transaction is opened with an
      EXPLICIT `timeout:` option of `3 x L + 10_000` ms (40 s by default), derived from the same key by one pure private function
      (`transaction_timeout_ms/1`) so a test override stays consistent. The explicit option is pinned by an AST scan and the formula by a unit test
      (T-BG-14c);
   b. `lock_tenant_row!/2` (A, then T);
   c. `previous` is read FROM THE LOCKED ROW (never from an earlier read); if `previous` is not `:on`, roll back `{:not_enforced, previous}`;
   d. build the entry (3.7) and call `write_flag_and_audit!/6`.
4. Error mapping outside the transaction: a `Postgrex.Error` whose code is `lock_not_available` or `deadlock_detected` (the squat remediation
   precedent) is `:lock_conflict` (safe to retry; nothing was written); any other raise is `{:transaction_failed, exception}`; a failed audit
   write is `{:audit_failed, error}` (the flag change is rolled back with it).
5. NO shadow flush, NO gate, NO `OnGate.evaluate`, NO `ScopeNodePaths.lock!` (S). A de-escalation never runs a precondition (same as
   `flip/4`, REQ-519 AC 13), so it succeeds with every gate fact failing (zero admins, T9 gaps, inconsistent tree).

### 3.5 Lock order

Global ranks (REQ-519 design 3.7): **A** < R < G < N < B < T < S < C. `flip/4` takes A, T, S (escalations only), C. The break-glass takes
A, then T, then C (inside `Audit.insert_entry/3`), and skips R, G, N, B and S. It takes A FIRST, before any read of the tenant row, so:

* a writer holding A (a binding writer, IdP sync, `TenantAdminGuard`-covered writers, and the future #2869 (a) guard paths) finishes before
  the break-glass reads `previous`; the break-glass then sees the committed mode;
* a concurrent `flip/4` (PUT) serialises on A: exactly one of the two commits first; the second sees the new mode under its own lock
  (`flip/4`: same-mode `changed: false` or its table; break-glass: `{:not_enforced, mode}`);
* `lock_timeout` bounds each wait so an emergency command never hangs behind a stuck sweep; on expiry it answers `:lock_conflict`, rolled back.
  This also bounds the audit chain lock wait. The transaction timeout (3.4 step 3a, SEC F-1) is strictly larger than the sum of the three waits, so
  a lock expiry is always the lock error and never a connection timeout.

The mode is not read before A (mutant MU-BG-8, test T-BG-14b: while the command waits for A, a second connection can still take the
`tenants` row `FOR UPDATE NOWAIT`, proving T is not yet held).

### 3.6 Transition table (out of band)

| stored previous | target `shadow` | target `off` | target `on` |
|---|---|---|---|
| `on` | applied; audit `scope.enforcement_disabled`; window restarts | applied; audit `scope.enforcement_disabled` | `:invalid_target` (never reached) |
| `shadow` | `{:not_enforced, :shadow}` | `{:not_enforced, :shadow}` | `:invalid_target` |
| `off` | `{:not_enforced, :off}` | `{:not_enforced, :off}` | `:invalid_target` |

Why `shadow -> off` is refused here: the lock-out #2869 describes exists only under `on`. In `shadow` nothing is denied, so nobody is
locked out of anything, and a human admin can always flip `shadow -> off` through the API if one exists. Giving the operator command a
wider table widens the footprint of the one command that has no role check. The cost is one extra, harmless `ERROR not_enforced` line
for an operator who ran it on the wrong mode; the dry run tells them first. Default; OQ-1 asks if `shadow -> off` is wanted.

### 3.7 The audit entry

One entry, written by `Audit.insert_entry/3` inside the flip transaction (rank C):

| Field | Value |
|---|---|
| `actor_id` | NULL |
| `action` | `scope.enforcement_disabled` (the existing constant, `ScopeEnforcement.flip_actions/0`; the action rule `rank(target) < rank(previous)` yields it for both targets) |
| `resource_type` | `"tenant"` (`flip_resource_type/0`) |
| `resource_id` | the tenant id |
| `before_state` | `%{"mode" => "on"}` |
| `after_state` | `%{"mode" => "shadow" or "off", "reason" => <trimmed reason>, "operator" => <label>, "source" => "operator_break_glass", "node" => Atom.to_string(node())}` (SEC F-3: `node` is the name of the VM that executed the write, a fact the operator cannot choose in the call; `"nonode@nohost"` in tests; readable by tenant audit readers, R-BG-4) |
| `trace_id` | `"break-glass-" <> 32 hex characters`, generated per call |

Notes: the interactive `flip/4` disabled entries keep their shape unchanged (`"mode"`, `"reason"` only); the three extra keys (`operator`, `source`, `node`) exist ONLY
on out-of-band entries and are how an audit reader tells them apart (together with `actor_id` NULL). No separate action name is
introduced, because `ShadowWindow` T0 and `flip_actions/0` consumers read the two existing actions (F6); a new action would silently
fail to restart the window (a test pins this). The entry holds no id of a person, no token data, no count that is not already in
a flip entry (INV-2, INV-4). The reason and the operator label are readable by tenant members who hold `AuditRead`; the runbook forbids
secrets and personal data in the reason (R-BG-4).

### 3.8 Does an emergency `on -> shadow` restart the shadow window?

Yes, by construction (F6) and by REQ-519 AC 23 LIMIT-EMERGENCY-RESHADOW: the entry is a `scope.enforcement_disabled` whose
`after_state["mode"]` is `"shadow"`, hence the new T0; the next `shadow -> on` needs `scope_shadow_min_days` days (default 7) of evidence
again, with requests on every date. This is safe by design: a tenant that had to be broken open is not allowed to go straight back to
`on` on stale evidence. The out-of-band `OK` line prints `shadow_window_restarted=true` for `shadow` and `false` for `off`. For `on -> off`
there is no window; the path back is `off -> shadow` (the three stage-1 facts) and then a full window. The break-glass does not clear,
shorten or bypass any of that, and no parameter can (test T-BG-13).

### 3.9 Failure behaviour (fail closed, INV-8)

| Condition | Result | Printed | Logged (ONE constant line) | Written |
|---|---|---|---|---|
| reason missing / blank / wrong type | `:reason_required` | `ERROR reason_required` | `scope_break_glass_refused reason=reason_required [operator=<label>]` | nothing |
| reason fails the rule | `:invalid_reason` | `ERROR invalid_reason` | same shape | nothing |
| operator missing / blank | `:operator_required` | `ERROR operator_required` | same shape | nothing |
| operator fails the label rule | `:invalid_operator` | `ERROR invalid_operator` | same shape | nothing |
| target not exactly `"shadow"` or `"off"` (`"on"`, `"ON"`, atom, nil) | `:invalid_target` | `ERROR invalid_target` | same shape | nothing |
| slug not found in the public `tenants` table, or not a binary, or not valid UTF-8, or over 128 bytes, or tenant not registered | `:unknown_tenant` | `ERROR unknown_tenant` | same shape | nothing |
| tenant stored `off` or `shadow` | `{:not_enforced, mode}` | `ERROR not_enforced current_mode=<m>` | same shape | nothing |
| real run without `confirm` / with a different `confirm` | `:confirm_required` / `:confirm_mismatch` | `ERROR confirm_required` / `confirm_mismatch` | same shape | nothing |
| lock wait expired / deadlock | `:lock_conflict` | `ERROR lock_conflict` | same shape | nothing (retry-safe) |
| audit insert failed | `{:audit_failed, _}` | `ERROR server_fault` | `scope_break_glass_failed reason=audit_failed exception=none [operator=<label>]` | flag change rolled back |
| any raise in the transaction | `{:transaction_failed, e}` | `ERROR server_fault` | `scope_break_glass_failed reason=transaction_failed exception=<module> [operator=<label>]` | rolled back |
| success | `{:ok, ...}` | `OK ...` | `scope_break_glass_applied previous=on mode=<m> operator=<label>` | flag + one entry |

* Tag mapping (validator fix r0a): the release function prints `unknown_tenant` for BOTH its own slug failure and the core's `:tenant_not_found`;
  `{:audit_failed, _}` and `{:transaction_failed, _}` print `server_fault`; every other tag prints as named. The TARGET line's `current_mode` in a REAL run
  comes from the same single plain unlocked read of `tenants.scope_enforcement` by id as the dry run (informational only; the core re-reads `previous`
  from the locked row and is the authority); a real run on a tenant not stored `on` may therefore stop at the core with `not_enforced`.
* Order of checks in the release function: target, reason, operator, slug resolution, then (real run only) `confirm`, then the core. The
  first failing check answers; none writes. `unknown_tenant` is uniform: a UUID or a schema name passed as the slug, an uppercase variant of
  a real slug, or a slug with whitespace all resolve through exact match on `tenants.slug` and fail the same way, so the command is not an
  oracle for tenant existence beyond what the operator, who has the database, already has.
* The fault line is exactly one `Logger.error` call per fault and contains the reason tag, the exception MODULE and (SEC F-3) the operator label
  ONLY WHEN `valid_operator_label?/1` accepts it: no slug, tenant id, reason, message or stacktrace, and never a label that fails the rule (it is
  omitted, the `operator=` key is absent), so a probe with a hostile label cannot inject into the log (INV-4; captured-log test T-BG-24).
  Refusals use `Logger.warning` with the constant shape above and the same conditional `operator=<label>` suffix, so a refusal is attributable when
  the label is valid. A refusal and a server fault never share a line.
* A refusal is NOT audited (D-10): nothing changed and the failing inputs are operator mistakes, not attacks on a gate. Unlike the `on`
  flip refusal (`RefusedAudit`), there is no gate whose near-misses are worth keeping. SEC may overrule (S-BG6): auditing a refusal
  would add a second write path with its own best-effort semantics.

### 3.10 Slug resolution and the safe-by-design checks

* The operator names the tenant by SLUG only. The release function resolves it with `Identity.get_tenant_by_slug/1`, i.e. one `Repo.get_by`
  on the PUBLIC `tenants` table by exact match; there is no tenant-id argument, no schema-name argument, no pattern or multiple-tenant form
  (no "all tenants" sweep: the blast radius is exactly one tenant per call). The tenant id comes from the row; the schema from the
  registration (`flip_out_of_band/3` step 2). Nothing the operator types is ever used as a schema name (INV-1/INV-7 spirit: the only
  input that selects data is matched against a table, never interpolated).
* `confirm:` is a typo and mixup guard: a real run must repeat the slug (`confirm: "<slug>"`, `--confirm <slug>`), and must equal it exactly.
  Rationale: the dangerous mistake is switching enforcement off for the WRONG tenant, and the cost of undoing it is a full new shadow
  window; the guard is non-interactive so it works over `rpc` stdin and in scripts. There is no `--yes` (it would guard nothing) and no
  interactive prompt (impossible over `rpc`). `dry_run: true` needs no `confirm`, performs steps 1 to 4 of 3.9 plus the mode read (one
  plain read of `tenants.scope_enforcement` by id, no lock, no transaction), prints `TARGET` and `DRYRUN`, and writes NOTHING (no audit entry, no
  flag change, no log other than none); a dry run on a tenant not stored `on` prints `ERROR not_enforced`.
* The `TARGET` line is printed before the write so the operator's console shows what was resolved even if the write then fails.

### 3.11 Multi-node note

* The command runs on whichever node `rpc` connects to. It does not need any other node: the write is a single database transaction and the
  flag is read per request, uncached, from the `tenants` row by both auth paths (F5), so every node enforces the new mode from its next
  request after the commit.
* Lock A is a Postgres advisory transaction lock, global across nodes; the audit chain lock is a row lock. So the serialisation of 3.5 holds
  across nodes.
* `ShadowWindow` counters are node-local and flushed periodically (LIMIT-MULTI-NODE-SHADOW-FLUSH). They are irrelevant to the break-glass
  (no gate runs, no flush needed). After an `on -> shadow` the window restarts from the DATABASE entry (T0), and every node's shadow
  counters start counting shadow traffic again; the multi-node flush condition for a later `shadow -> on` is unchanged.
* The command must run once, on one node. Running it twice is safe: the second run finds the tenant no longer `on` and answers
  `ERROR not_enforced current_mode=<shadow|off>` without a write.

### 3.12 Works when no interactive admin exists (the point)

The path touches: the `tenants` table (read slug, lock row, update one column), `tenant_schemas` (registration read), the advisory lock key
for A, and the tenant's `audit_entries` / `audit_chain_locks`. It reads no `users`, `groups`, `group_members`, role binding,
`role_scope_grants`, `api_tokens` or IdP state, and it does not call `Identity.count_*`. There is no `auth_context`, no plug, no
credential, no permission check. So the command works identically whether the tenant has zero users, only token owners, only a flagged
service principal, or an admin who exists in the database but cannot log in at the IdP (F9). Test T-BG-8 builds the three database shapes.

### 3.13 Relationship to #2869 part (a) and part (c), interface assumptions only

Not designed here. Assumptions the (a) and (c) designs may rely on, and that this design commits to:

* Break-glass writes ONLY `tenants.scope_enforcement` and one audit entry. It does not insert, update, delete, demote, deactivate, scope,
  flag or unbind any admin, binding, group membership or grant. So no guard of (a) can ever need to "allow the break-glass through", and
  (a)'s guard must not special-case it.
* It takes lock A through `Identity.lock_tenant_admins!/1`. If (a) renames or re-keys that function, the break-glass follows the rename
  and keeps taking A FIRST. (a)'s guarded writers that read the mode under A (`ScopeEnforcement.mode_under_lock!/1`) see the break-glass
  result consistently: a writer that wins A first is judged against `on`, a writer that wins A after the commit sees `shadow` or `off` and
  its `on`-only refusal no longer applies.
* The break-glass is the recovery path for the case (a) cannot prevent (an admin who exists in the database but cannot log in), and it
  does not make (a) unnecessary: it is slow, needs host access and restarts the window.
* (c) decision record: proposed text in 13 (RA-B1): the 0051 A7 token break-glass covers GRANT writes only (the flag route is
  interactive-only); the operator command is the only recovery for the FLAG, has no HTTP surface, and is authorised by host access.
* Neither (a) nor (c) changes `flip_out_of_band/3`'s signature. If (a) introduces a typed refusal that the operator would trip over
  (it cannot: the break-glass changes no admin row), nothing here changes.

## 4. Data model

No migration, no new table, no new column, no new index, no new constraint. The existing CHECK `tenants_scope_enforcement_check` still
holds (the command writes only `shadow` or `off`). The audit table's shape is unchanged (`actor_id` NULL is already legal; the hash form
encodes it with the NULL sentinel).

## 5. Tests (TEST-DESIGNER writes them; ids are the contract)

Files: `test/letflow/scope_enforcement_out_of_band_test.exs` (DB, `async: false`: committed writes, advisory locks, an audit fault trigger),
`test/letflow/release/scope_break_glass_test.exs` (DB, `async: false`, `ExUnit.CaptureIO` / `CaptureLog`),
`test/mix/tasks/letflow_scope_enforcement_break_glass_test.exs` (argv, no DB beyond the call), and the scan and docs tests of section 6.
Fixtures: the 2f-b `OnGateFixture` / `SyncScopeFixture` helpers (`admin_tenant!`, `create_audit_fault!` / `drop_audit_fault!`); a tenant is put
in `on` by test-only SQL in the fixture (the authority scan reads `lib/`, `priv/`, `config/`, `scripts/`, `.github/`, `mix.exs`, not `test/`).
Sandbox note (as 2f-b): any test that asserts the inside-transaction behaviour or concurrency runs on committed state.

Core, `flip_out_of_band/3`:

| Id | Test |
|---|---|
| T-BG-1 | `reason` missing, `nil`, `""`, whitespace-only, non-binary, for BOTH targets: `:reason_required`; flag still `on`; audit entry count unchanged |
| T-BG-2 | reason with control / format / bidi characters, 501 codepoints: `:invalid_reason`; no write |
| T-BG-3 | operator missing, `nil`, blank, 65 bytes, containing a space, a newline, a trailing `\n`, a bidi mark, a quote or `#{`: `:operator_required` / `:invalid_operator`; no write; a valid label with `. _ @ + -` passes |
| T-BG-4 | success `on -> shadow`: stored mode `shadow`; exactly ONE new `audit_entries` row: `actor_id` NULL, action `scope.enforcement_disabled`, resource_type `tenant`, resource_id the tenant id, `before_state %{"mode" => "on"}`, `after_state` exactly `%{"mode" => "shadow", "reason" => <trimmed>, "operator" => label, "source" => "operator_break_glass", "node" => Atom.to_string(node())}` (SEC F-3), trace_id matching `break-glass-` + 32 hex; a padded reason is stored trimmed |
| T-BG-5 | success `on -> off`: same shape with `"mode" => "off"`; returns `{:ok, %{mode: :off, previous: :on, changed: true}}` |
| T-BG-6 | same transaction: with an audit fault trigger (as `on_flip_guards_test`) the result is `{:audit_failed, _}`, the flag is STILL `on`, no entry; without the fault the flag and the entry are both present (they cannot diverge) |
| T-BG-7 | changes only the flag: snapshot (row contents or content hash) of `tenants` (all columns except `scope_enforcement` and `updated_at`), `users`, `groups`, `group_members`, role bindings, `role_scope_grants`, `api_tokens`, `scope_node_paths`, `tenant_schemas` before and after: identical; `audit_entries` +1; no role or grant row created |
| T-BG-8 | works with no interactive admin, three fixtures stored `on`: (i) zero `users` rows; (ii) the only TENANT_ADMIN is a token owner; (iii) the only TENANT_ADMIN is a flagged service principal; plus (iv) a tenant whose gate facts all fail (T9 gaps, zero admins): success each time, no precondition consulted |
| T-BG-9 | stored `off` and stored `shadow`, targets `shadow` and `off`: `{:not_enforced, mode}`; flag unchanged; no entry |
| T-BG-10 | target `:on`, `"on"`, `"ON"`, `nil`, an unknown atom: `:invalid_target`; no atom is minted from a string (the parser takes exactly `"shadow"` / `"off"`) |
| T-BG-11 | unknown tenant id (random UUID), malformed id, id with a `tenants` row but no `tenant_schemas` row: `:tenant_not_found`, no raise, no write |
| T-BG-12 | `attrs` carrying `:actor_id` (a real user id), `:now`, `:trace_id`, `:mode`: ignored; entry `actor_id` NULL, trace id generated, behaviour identical |
| T-BG-13 | restart: after `on -> shadow`, `ShadowWindow.evaluate/3` reports `shadow_since` == the entry timestamp and the duration criterion false at once; an interactive `flip/4` `shadow -> on` is `{:on_precondition_failed, [... :shadow_evidence_insufficient ...], _}`; after `on -> off`, `flip/4` `off -> on` is `:shadow_required` |
| T-BG-14a | serialisation: hold lock A in another process; the command blocks; releasing A lets it commit; result `{:ok, ...}` |
| T-BG-14b | lock order: while the command waits for A, a second connection takes the `tenants` row `FOR UPDATE NOWAIT` successfully (T not held before A) |
| T-BG-14c | `lock_timeout` and transaction timeout (SEC F-1): (i) with `:scope_break_glass_lock_timeout_ms` set small and A held, result `:lock_conflict` (never `{:transaction_failed, _}`), no write, no entry; (ii) the same with the `tenants` row held (second wait) and with the audit chain lock held by another transaction (third wait); (iii) pure unit test of `transaction_timeout_ms/1`: strictly greater than `3 x L` for the default and for the small test value, and greater than the DBConnection default of 15 s for the default; (iv) AST scan: the `Repo.transaction` call of `flip_out_of_band/3` carries a `timeout:` option; (v) the application key is unset in production config |
| T-BG-15 | race with `flip/4`: an interactive `on -> off` (by an admin) and the break-glass `on -> shadow` issued together: exactly one effective change; the loser is `{:not_enforced, _}` (break-glass) or `changed: false` / its table (flip); the audit has exactly one entry |
| T-BG-16 | platform tenant (pinned via `PlatformTenantFixture`) stored `on`: success, flag only; its PLATFORM_ADMIN platform-scope access is unaffected before and after |
| T-BG-17 | inactive tenant (`status: :inactive`) stored `on`: success |
| T-BG-18 | effect on the next request: after the commit the auth pipeline context carries `scope_enforcement: :shadow` / `:off` (a fresh request), uncached |
| T-BG-19 | `flip/4` regression: the unmodified `scope_enforcement_transitions_test.exs`, `scope_enforcement_test.exs`, `scope_enforcement_on_test.exs`, `on_flip_guards_test.exs` (flip part) pass unchanged after the shared-core refactor |

Release module and Mix task:

| Id | Test |
|---|---|
| T-BG-20 | slug resolution: exact slug resolves; unknown slug, uppercase variant, slug with surrounding space, a tenant UUID, a `tenant_<hex>` schema name, `nil`, a non-binary, an over-long string, invalid UTF-8: `ERROR unknown_tenant`, nothing written |
| T-BG-21 | `confirm`: missing -> `ERROR confirm_required`; different slug -> `ERROR confirm_mismatch`; correct -> applies; `dry_run: true` needs no confirm, prints `TARGET` and `DRYRUN would_change=true`, and writes nothing (entry count, flag, `updated_at` identical); dry run on a non-`on` tenant prints `ERROR not_enforced`; a dry run with a missing reason or operator also fails closed |
| T-BG-22 | output: captured output of success, dry run and each error contains the escaped slug at most, the modes and the action name; NO UUID-shaped string, NO `tenant_` + 32 hex, NO reason text, NO operator label, NO node name, NO exception message (the operator label and the node appear in the audit entry and in log lines only, never in console output) |
| T-BG-23 | order of checks: a call with a bad target AND a bad reason answers the target error; unknown slug with a good everything answers `unknown_tenant`; no database write in any refusal |
| T-BG-24 | fault: with the audit fault trigger the printed line is `ERROR server_fault`, the log capture holds exactly ONE error line `scope_break_glass_failed reason=audit_failed exception=none`, containing no slug, tenant id, reason or message, and the operator label ONLY if it passes the label rule (with a valid label the line ends `operator=<label>`; with a label that fails the rule the label substring and the `operator=` key are absent); a raised exception gives `reason=transaction_failed exception=<module>`; the flag is unchanged; the fault is never logged as a refusal and a refusal never as a fault |
| T-BG-25 | success log: one `scope_break_glass_applied previous=on mode=<m> operator=<label>` line, no slug, id or reason; each refusal tag of 3.9 logs one `scope_break_glass_refused reason=<tag>` line that carries `operator=<label>` iff the label passes the rule (an invalid label, including one with a newline or bidi mark, is absent, so no log injection) |
| T-BG-26 | `exit_code/1`: 0 for `{:ok, _}` (applied and dry run), 1 for every `{:error, _}`; the release module never calls `System.halt` (AST scan, proven live on a seeded halt) |
| T-BG-27 | Mix task argv: missing `--to`, `--reason`, `--operator`, or both/neither of `--confirm` / `--dry-run`: `Mix.raise` with the usage line; unknown switch, extra positional, empty value: raise; no `$USER` default for the operator; a valid argv reaches `run/5` (stubbed or against the DB); the task moduledoc (via `Code.fetch_docs`) says that the Mix form is for dev and CI only and that `app.start` on a production host boots a second application against the same database (SEC F-4) |
| T-BG-28 | idempotence: a second identical run answers `ERROR not_enforced current_mode=<shadow\|off>`, one entry total |

Scans and docs (section 6): T-BG-29 (no HTTP route and single caller), T-BG-30 (docs), T-BG-31 (single writer expression), T-BG-32 (config).

## 6. Existing tests that change, and new scans

| File | Change |
|---|---|
| `test/letflow/scope_enforcement_flip_authority_test.exs` (2f-b) | EXTENDED. (1) its list of "only the router calls `flip/4`" stays; (2) NEW assertion: `files_calling(lib_files, :flip_out_of_band)` == `["lib/letflow/release/scope_break_glass.ex"]` (AST, name-keyed like `calls?/2`); (2b) NEW, SEC F-2, a TEXT scan over ALL of `lib/**/*.ex` (comments and strings included, so it also catches `apply(Mod, :flip_out_of_band, args)`, `&Mod.flip_out_of_band/3`, `Kernel.apply/3`, an alias or an import): the substring `flip_out_of_band` may occur ONLY in `lib/letflow/scope_enforcement.ex` (defines it) and `lib/letflow/release/scope_break_glass.ex`; the substring `ScopeBreakGlass` may occur ONLY in the release module itself and `lib/mix/tasks/letflow.scope_enforcement.break_glass.ex`; the substring `out_of_band` (case-sensitive) may occur ONLY in those three files (the module defining it, the release module, the Mix task wrapper); so a caller anywhere else in `lib/`, not only under routers, api or plugs, fails the scan; (3) NEW: within `lib/letflow/scope_enforcement.ex` exactly ONE call expression of `scope_enforcement_changeset` (T-BG-31) while the existing "called only by that file" stays; (4) NEW: no file under `lib/letflow/routers/`, `lib/letflow/api/`, `lib/letflow/plugs/`, and no `lib/letflow/routers/tenant_scope_enforcement.ex`, references `flip_out_of_band`, `ScopeBreakGlass` or `Letflow.Release.ScopeBreakGlass` (alias forms included, via AST on `__aliases__`); (5) NEW: no file in `scripts/`, `.github/`, `config/`, `priv/` contains `break_glass`, `ScopeBreakGlass` or `flip_out_of_band` (text); (6) NEW: the `:ScopeEnforcementManage` key still has exactly one route (existing) and NO route, permission atom or `RouteInventory` entry contains `break` (T-BG-29); (7) NEW: `config/runtime.exs` and `config/prod.exs` never name `:scope_break_glass_lock_timeout_ms` (T-BG-32); (8) every NEW scan, (2), (2b), (3), (4), (5), (6), (7), is proven live on a seeded offender (as the file already does); for (2b) one seeded source per form (a plain call from a new `lib/` file, an `apply(Mod, :flip_out_of_band, [...])`, a capture `&Mod.flip_out_of_band/3`, a mention in a comment of an unlisted file, a call from a plugin or engine module) must each be reported, and the three allowed files seeded alone must pass |
| `test/letflow/scope_enforcement/on_flip_guards_test.exs` (2f-b) | NO assertion changes: its `flip_callers/0` matches `ScopeEnforcement.flip` by exact function name, so `flip_out_of_band` neither satisfies nor violates "only the router calls `flip/4`". The builder must re-run it and must not weaken it. Its source-scan moduledoc gains one sentence naming the new scans |
| `test/letflow/docs/roles_on_flip_docs_test.exs` (2f-b) | CHANGED: item 7 claims `["mandatory reason", "Tokens cannot", "no platform-scope break-glass"]` become `["mandatory reason", "Tokens cannot", "letflow.scope_enforcement.break_glass", "Letflow.Release.ScopeBreakGlass", "no HTTP route"]` (the phrase `no platform-scope break-glass` is removed from the docs, so it must be removed from the test, not kept); the eight-item numbering, the seven `LIMIT-*` tokens (each once, in both docs) and the other claims are untouched; add a claim that the runbook contains a heading `Break-glass` (T-BG-30) |
| `test/letflow/routers/tenant_scope_enforcement_*` | NO change (the route is unchanged); re-run |
| `test/fixtures/route_scope/tenant_wide_default_routes.txt` and the permission matrix | NO change expected; `mix letflow.permission_matrix --check` must stay green (a diff means a route or permission was added: a defect) |
| `test/letflow/scope_enforcement/` moduledoc pins | grep for sentences quoting "written ONLY by `flip/4`" before editing the `ScopeEnforcement` moduledoc; none found in `test/` on the 2f-b branch, but the builder re-greps |

## 7. Mutants (the suite must kill each)

| Id | Mutation | Killed by |
|---|---|---|
| MU-BG-1 | reason optional for one target, or accepted blank | T-BG-1 |
| MU-BG-2 | audit entry written after commit or in a separate transaction | T-BG-6 |
| MU-BG-3 | `actor_id` taken from `attrs`, or the operator not recorded / recorded outside `after_state` | T-BG-4, T-BG-12 |
| MU-BG-4 | `shadow -> off` (or `off -> *`) allowed | T-BG-9 |
| MU-BG-5 | target `on` accepted, or a string target minted into an atom | T-BG-10 |
| MU-BG-6 | lock A not taken | T-BG-14a, T-BG-15 |
| MU-BG-7 | lock T before A | T-BG-14b |
| MU-BG-8 | `previous` read before the locks (TOCTOU) | T-BG-15 |
| MU-BG-9 | a second writer of the column (`update_all`, second changeset call) | T-BG-31, existing `@bulk_setter` scan |
| MU-BG-10 | output prints a tenant id, schema, reason, operator or exception text | T-BG-22, T-BG-24 |
| MU-BG-11 | a fault logged as a refusal, a second log line, a line carrying the slug or reason, or a line carrying an operator label that fails the rule | T-BG-24, T-BG-25 |
| MU-BG-12 | operator label unvalidated (newline, bidi, quote) | T-BG-3 |
| MU-BG-13 | reason stored untrimmed | T-BG-4 |
| MU-BG-14 | dry run writes (flag or audit) | T-BG-21 |
| MU-BG-15 | `confirm` skipped or compared case-insensitively / by prefix | T-BG-21 |
| MU-BG-16 | an HTTP route, router, plug, script or ANY other `lib/` file (including via `apply/3` or a capture) references the command | T-BG-29 (scans 2, 2b, 4, 5, 6) |
| MU-BG-17 | unknown tenant raises (or is a 500-style fault) | T-BG-11, T-BG-20 |
| MU-BG-18 | a gate fact consulted (the de-escalation refused when a fact fails, or a flush run) | T-BG-8 (iv) |
| MU-BG-19 | the entry uses `scope.enforcement_enabled` or a new action (window does not restart) | T-BG-4, T-BG-13 |
| MU-BG-20 | the release function calls `System.halt` | T-BG-26 |
| MU-BG-21 | operator defaults to `$USER`, the node name or an admin | T-BG-3, T-BG-27 |
| MU-BG-22 | no `lock_timeout` (hang behind a held lock) or a timeout read from `runtime.exs` | T-BG-14c, T-BG-32 |
| MU-BG-27 | no explicit transaction `timeout:` or one not above 3 x `lock_timeout` (a lock expiry surfaces as `server_fault`) | T-BG-14c (ii, iii, iv) |
| MU-BG-28 | node name omitted from the entry, or taken from `attrs` | T-BG-4, T-BG-12 |
| MU-BG-23 | `flip/4` altered by the refactor (return values, audit shapes, lock order, refusal recording) | T-BG-19 |
| MU-BG-24 | break-glass touches a user, group, binding or grant row | T-BG-7 |
| MU-BG-25 | refusal recorded as an audit entry or an entry written for a no-op | T-BG-9, T-BG-28 |
| MU-BG-26 | slug resolved by prefix, case-folded, or accepted as a tenant id or schema name | T-BG-20 |

## 8. Acceptance-criteria map

| Source | Requirement text | Design element | Tests |
|---|---|---|---|
| #2883 Requirement 1 | release command or mix task | 3.2 (`Letflow.Release.ScopeBreakGlass.run/5`, Mix task) | T-BG-26, T-BG-27 |
| #2883 Requirement 1 | NO HTTP route (0051 A6) | D-12, 6 scans | T-BG-29 |
| #2883 Requirement 2 | mandatory reason | 3.4 step 1, 3.9 | T-BG-1, T-BG-2 |
| #2883 Requirement 2 | actor recorded as the operator | 3.3, 3.7 | T-BG-3, T-BG-4, T-BG-12 |
| #2883 Requirement 2 | audited `scope.enforcement_disabled` in the same transaction as the flag | 3.4 step 3d, 3.7 | T-BG-4, T-BG-5, T-BG-6 |
| #2883 Requirement 3 | flag only, grants no role (0046 D4) | 3.3, 3.12, 4 | T-BG-7 |
| #2883 Acceptance 1 | names the mechanism | 3.2 | n/a (this document) |
| #2883 Acceptance 1 | how the operator is identified and recorded | 3.3, 3.7 | T-BG-3, T-BG-4 |
| #2883 Acceptance 1 | the lock order of `flip/4` | 3.4, 3.5 | T-BG-14a, T-BG-14b, T-BG-15 |
| #2883 Acceptance 1 | whether an emergency `on -> shadow` restarts the window | 3.8 (yes) | T-BG-13 |
| #2883 Acceptance 2 | refuses a missing or blank reason | 3.9 | T-BG-1 |
| #2883 Acceptance 2 | writes the audit entry with the operator as actor | 3.7 | T-BG-4 |
| #2883 Acceptance 2 | changes only the flag | 3.12, 4 | T-BG-7 |
| #2883 Acceptance 2 | works when no interactive admin exists | 3.12 | T-BG-8 |
| #2883 Acceptance 3 | SECURITY-REVIEWER gate (authorization path; 0051 flip route) | 12 | design gate and code gate |
| Brief: refuses non-`on` | 3.6 | T-BG-9 |
| Brief: unknown tenant, platform tenant (INV-10) | 3.9, D-9 | T-BG-11, T-BG-16, T-BG-20 |
| Brief: one constant log line on fault | 3.9 | T-BG-24 |
| Brief: multi-node note | 3.11 | T-BG-18 |
| Brief: prints no ids beyond slug | 3.2 | T-BG-22 |
| Brief: scan that no HTTP route calls it | 6 | T-BG-29 |
| Brief: the 2f-b flip-authority scan updated | 6 | T-BG-29, T-BG-31 |
| AC 23 (docs of known limitations) | 8 `LIMIT-*` items unchanged; item 7 of the production list and the runbook change | T-BG-30 |
| AC 24 (process gate) | the PR body repeats both gate sentences (12) | PR checklist |

## 9. Gates and commands

`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix letflow.check`, `mix letflow.check_boundaries`,
`mix letflow.permission_matrix --check`, `mix letflow.check_requirements_registration`, `mix letflow.check_role_scope_grants_writers`,
and the scoped `mix test` over the new files, `test/letflow/scope_enforcement*`, `test/letflow/docs/roles_on_flip_docs_test.exs`,
`test/letflow/routers/tenant_scope_enforcement*` and `test/letflow/api` (real output quoted). Tests with committed writes and advisory locks run one
file at a time (machine constraint). The PR body states: "NO production tenant is set to on until the supervisor says so" and "no on flip in
any customer tenant, pilot included, until GH #2869 and GH #2883 are implemented", and that no migration, seed or config sets a tenant to `on`.
Run the command against a production tenant is an infra request through the normal flow, never part of the PR.

## 10. Runbook and docs text

### 10.1 `docs/runbooks/scope-enforcement-on.md`: new section (after "What `on` means in production today"), and edits

New heading (the docs test requires it): `## Break-glass: turning an on tenant off without an admin (platform operator)`.

Text to ship (the builder may tighten wording, not drop a rule):

> Use this ONLY when a tenant stored `on` has nobody who can turn enforcement off through the API (an interactive tenant-wide TENANT_ADMIN is
> required for the PUT, and tokens cannot). Typical cause: the identity provider no longer lets the admins log in, which Letflow cannot see. There
> is NO HTTP route for this and it is not a role: it is a command on the release host, authorised by access to that host.
>
> Before you start: you hold shell access to the running node; you have an incident ticket id; you know the tenant slug exactly. Choose your
> label: your personal handle as it appears in the infrastructure access log (letters, digits and `. _ @ + -`, at most 64 characters). Do NOT put
> secrets, personal data or quotes in the reason; the reason and your label are readable in the tenant's audit log by anyone with AuditRead.
>
> The Mix form is for dev and CI hosts ONLY. Do not run `mix` on a production host: `app.start` there boots a second full Letflow application
> against the same database as the running node. On a deployed release use the `rpc` form below.
>
> 1. Dry run (writes nothing). Release form (stdin, `docs/runbooks/login-directory-pepper-rotation.md` section 0; `bin/letflow eval` is not supported):
>    `Letflow.Release.ScopeBreakGlass.run("<slug>", "shadow", "<ticket id>: <short reason>", "<your label>", dry_run: true)`.
>    Mix form (dev and CI only): `mix letflow.scope_enforcement.break_glass <slug> --to shadow --reason "<text>" --operator <label> --dry-run`.
>    Read the `TARGET` line: the tenant must be `current_mode=on`. Any `ERROR` line means nothing was changed; fix the input.
> 2. Choose the target. `shadow`: enforcement stops denying, shadow counters keep counting; the shadow window RESTARTS, so returning to `on` needs a
>    full new window (default 7 days) and the six gate facts, including at least one interactive explicit tenant-wide TENANT_ADMIN who can log in.
>    `off`: enforcement and counting stop; returning needs `off` to `shadow` (three facts), a full window, then `on`. Prefer `shadow` unless the
>    counters themselves are the problem.
> 3. Real run: the same expression with `confirm: "<slug>"` instead of `dry_run: true` (Mix: `--confirm <slug>`). Pass/fail is the printed line:
>    `OK ... mode=<shadow|off> action=scope.enforcement_disabled` is success; `ERROR <tag>` is a refusal and nothing changed
>    (`not_enforced`: the tenant is not `on`, maybe someone already fixed it; `lock_conflict`: another admin operation holds the tenant, retry;
>    `server_fault`: stop, the flag was NOT changed, escalate). The exit status of `rpc` is not meaningful.
> 4. Verify: the change is effective on every node from the next request. An admin who can log in reads `GET /api/v1/tenant/scope-enforcement`;
>    the audit log (`GET /api/v1/audit`, resource type `tenant`) holds one `scope.enforcement_disabled` entry with a null actor and, in its
>    state, your label, your reason, `"source": "operator_break_glass"` and the name of the node that ran it.
> 5. Then fix the root cause (restore an admin at the identity provider). Do not repeat the command for the same incident.
>
> Never write the column with SQL: that skips the audit entry and the locks. If the node cannot start at all, fix that first; the command needs
> the running application.

Edits: item 7 of "What `on` means in production today" becomes: "To turn `on` off: an interactive tenant-wide TENANT_ADMIN, with a mandatory reason. Tokens cannot. When no such admin can log in, use the platform-operator break-glass command `Letflow.Release.ScopeBreakGlass` (`mix letflow.scope_enforcement.break_glass`), which has no HTTP route and needs a mandatory reason and an operator label." (Validator fix r0a: the pinned claim is the capitalised substring `Tokens cannot`; the first draft wrote lowercase `tokens cannot` and would have failed the docs test it keeps.) Keep it ONE numbered item (the docs test counts eight items). The sentence "(#2869: ... a guard extension or a break-glass is still undecided)" is updated to say the break-glass is built (GH #2883) and the guard is still open; the "Gate #2869" paragraph keeps the guard half and states the break-glass half is delivered by #2883. The first paragraph's "The flag route for ANOTHER tenant from the platform scope is not built" stays (still true). No new `LIMIT-*` item.

### 10.2 `docs/roles.md`

The identical edit to item 7 and the gate sentence (the runbook "carries the same text for readers of the role charter"; `roles_on_flip_docs_test.exs` compares the production section of both files, so both change together).

### 10.3 `ScopeEnforcement` moduledoc

Replace "written ONLY by `flip/4`, which only `Letflow.Routers.TenantScopeEnforcement` calls" by: written only through the one shared write helper, used by `flip/4` (called only by the router; interactive tenant-wide TENANT_ADMIN) and by `flip_out_of_band/3` (called only by `Letflow.Release.ScopeBreakGlass`; platform operator, `on` to `shadow` or `off` only, no gate). Add the out-of-band row to the transition table text.

## 11. Security: INV analysis and residual risks

| INV | Where | Statement |
|---|---|---|
| INV-1 | slug argument | the operator selects the tenant by slug, matched exactly against the public `tenants` table; the schema comes from the registration; nothing typed is interpolated; no multi-tenant form |
| INV-2 | output, audit, logs | output and logs hold slug (escaped), modes, an action name, booleans; the audit entry holds mode, trimmed reason, operator label, constant source; no id of a person, no counts of others |
| INV-4 | logs, output | no token, hash, secret, reason, operator, exception message or id in a log line or output; one constant fault line; the label rule excludes control, format and bidi characters |
| INV-7 | SQL | `lock_timeout` set with `set_config` and a bound parameter; the tenant row and audit via Ecto; no string-built SQL |
| INV-8 | every failure | refuses or rolls back, never changes the flag on a failure; an unreadable mode or a missing row is an error, not a default; a server fault is never recorded as a refusal |
| INV-10 | authority | a platform-scope ACTION by an operator is authorised by host access, not by a role or a request; no HTTP route exists (scanned); the tenant's own `tenants` row is the only data touched; the command reads and prints no tenant content |
| 0046 D4 | flag only | grants no role, reads no tenant content; the data touched is a configuration flag of the tenant's own enforcement |
| 0051 A6 | no route | the platform-scope flip ROUTE stays unbuilt (scanned) |
| 0051 A7 | tokens | tokens remain unable to flip (the PUT is interactive-only); the break-glass is the only non-interactive way and has no token path |

Residual risks (for SECURITY-REVIEWER):

* R-BG-1 (accepted, stated): the operator label is an attestation, not authentication; authority is host access (3.3). A person with host access can
  also bypass the command with SQL. Mitigation: the hash chain makes later tampering with entries detectable; the runbook ties the label and ticket to the
  infrastructure access log. A second factor (an allow-list, a four-eyes confirm) is OQ-2.
* R-BG-2 (accepted): the command disables a security control for one tenant; an attacker with host access could use it. Same host access already
  allows reading or editing any data; the command adds an audit entry that SQL would not.
* R-BG-3 (accepted): wrong-tenant mistakes are bounded by `confirm`, the dry run, one-tenant-per-call, and the fact that `on -> shadow` loses
  only enforcement and a shadow window, never data.
* R-BG-4 (documented): reason, label and node name are readable by tenant audit readers; the runbook forbids secrets and personal data.
* R-BG-5 (accepted): refusals are not audited (D-10); a hostile operator probing leaves only log lines. A server fault leaves one constant log line.
* R-BG-6 (accepted): the command needs the running application (a Repo); if the node cannot boot, there is no sanctioned recovery; direct SQL is
  forbidden by the runbook because it skips the audit. A boot-less fallback is not designed.
* R-BG-7 (documented): quoting hazards in the `rpc` line (a `"` or `#{` in the reason); the runbook feeds the expression on stdin, and the reason rule rejects
  control and bidi characters but not quotes (the label rule rejects both).
* R-BG-8 (accepted): `shadow -> off` and `off -> shadow` remain interactive-only; a tenant stuck in `shadow` with no admin cannot be set to `off` by
  this command (it cannot lock anyone out; OQ-1).
* R-BG-9 (accepted): the break-glass does not repair the missing admin (#2869 (a) prevents removal, the IdP repair is outside Letflow); after `shadow`/`off`
  the tenant is in a weaker mode until an admin returns and the gate passes again.
* R-BG-10 (accepted): one `lock_timeout` L applies to each of up to three waits; a stuck holder past it gives `lock_conflict`, retry-safe; the explicit transaction timeout of 3 x L + 10 s keeps that classification (SEC F-1).

## 12. SECURITY-REVIEWER rulings requested at the design gate

| Id | Question | Default built |
|---|---|---|
| S-BG1 | Authority path: a release function / Mix task authorised by host access only (no Letflow role, token, permission or HTTP surface), with a NEW writer function `flip_out_of_band/3` sharing a write helper with `flip/4` instead of widening `flip/4`'s attrs. Does this satisfy 0051 A6, A7, 0046 D4 and INV-10? | accepted if ruled; decision record RA-B1 |
| S-BG2 | Operator identification: mandatory attested label (charset rule), no environment/OS identity, no allow-list. Accept, or require an allow-list / second factor? | attested label, OQ-2 |
| S-BG3 | `actor_id` NULL with the operator in `after_state["operator"]` and `after_state["source"]`, versus a new action name or an audit schema change | NULL actor + payload keys, existing action name |
| S-BG4 | Platform tenant stored `on` may be broken open by the command | allowed |
| S-BG5 | Only `on` is a legal source; `shadow -> off` and `off -> *` refused | `on` only, OQ-1 |
| S-BG6 | Refusals are not audited (log line only); server faults never audited as refusals | as stated |
| S-BG7 | `confirm: <slug>` guard plus dry run in place of an interactive prompt | as stated, OQ-3 |
| S-BG8 | `lock_timeout` 10 s (`:scope_break_glass_lock_timeout_ms`, test-only override, scanned out of runtime/prod config) with `:lock_conflict` | as stated |
| S-BG9 | Window restart on `on -> shadow` and no shortcut (REQ-519 AC 23 LIMIT-EMERGENCY-RESHADOW) | accepted |
| S-BG10 | The documentation change that retires the sentence "There is no platform-scope break-glass in this release" and the proposed 0051 amendment | as 10 and 13 |
| S-BG11 | Reason and operator label visible to AuditRead holders of the tenant | accepted with the runbook rule |
| S-BG12 | The command reveals `current_mode` and existence of a slug to its operator only (host access); uniform `unknown_tenant` | accepted |

## 13. Requirement and record amendments proposed (REQ-ANALYST / letflow-2; not edited here)

| # | Amendment | Source |
|---|---|---|
| RA-B1 | ACCEPTED (SEC) as decision amendment A11 of 0051 (A10 is the last existing amendment). Text: "An operator break-glass for the enforcement FLAG exists as a release command with no HTTP route (GH #2883). It is authorised by host access, not by any role, token or permission; it changes `tenants.scope_enforcement` from `on` to `shadow` or `off` and writes one `scope.enforcement_disabled` audit entry with a null actor, the operator label and the node name; it grants no role, reads no tenant content and is not the platform-scope flip route of A6, which stays unbuilt. The operator label is an ATTESTATION by someone who already holds host access, not an authenticated identity. The A7 token break-glass covers GRANT writes only: the flag route is interactive-only, so for the flag the operator command is the only recovery. A10's gap (a tenant stored `on` with nobody able to turn it off) is only PARTLY answered by this command: the last-admin guard (GH #2869 part (a)) stays open and is still required before any customer `on`. Any HTTP route, or any role-, token- or permission-based entry to this capability, needs a NEW decision record." | F10, #2869 (c), SEC step-03 |
| RA-B2 | REQ-519 AC 23/24: after this PR the AC 24 gate text may say "GH #2883 implemented"; the `LIMIT-*` list stays at seven items. The AC 23 sentence "(g) an emergency `on` to `shadow` ... restarts the window" is now backed by a named command | AC 23 (g) |
| RA-B3 | `docs/roles.md` and the runbook item 7 changes of section 10 are part of the PR; the pinned docs test changes with them | F8 |

## 14. Open questions (with the default this design builds)

| # | Question | Default built | Needs |
|---|---|---|---|
| OQ-1 | Should `shadow -> off` (and `off -> off`) be allowed out of band? | no, `on` only (3.6) | SEC S-BG5 |
| OQ-2 | Operator allow-list or second factor (deployment variable of permitted labels, or a four-eyes confirmation)? | no; attested label; reasons in 3.3 | SEC S-BG2 |
| OQ-3 | `confirm: <slug>` plus dry run, or a different guard (for example the dry run must have been run within N minutes)? | `confirm` + dry run, stateless | SEC S-BG7 |
| OQ-4 | Audit refused attempts (mode mismatch is harmless; a hostile probe is not)? | no, log lines only | SEC S-BG6 |
| OQ-5 | Platform tenant allowed? | yes | SEC S-BG4 |
| OQ-6 | Print the generated trace id on the console to ease correlation? | no (brief: no ids beyond the slug) | product |
| OQ-7 | Should the success line also print the count of interactive tenant-wide admins as context? | no (keeps the command from reading any identity table, 3.12) | product |
| OQ-8 | Mix task name: `letflow.scope_enforcement.break_glass` (dotted, like `letflow.login_directory.key_status`)? | yes | none |
| OQ-9 | Lock timeout of 10 s: right for an emergency path? | 10 s | SEC S-BG8 |
| OQ-10 | A boot-less recovery (application will not start)? | not designed (R-BG-6) | product |

## 15. Interplay with open issues

#2869 (a) last-admin guard: independent; assumptions in 3.13. #2869 (c) decision record: RA-B1 (A11) provides the text and states that A10's gap is only partly answered while (a) is open. #2535 / REQ-519: this PR does not
change the gate, `ShadowWindow` or `flip/4`; it uses the existing audit vocabulary. #2882 (2f-b) must merge first (section 1). The pilot-only and
no-customer-`on` rules of AC 24 are unchanged by this PR alone.

## 16. Self-review against the brief

* Mechanism named and justified against the existing operator precedents (Release module plus Mix task, rpc, no eval): 3.2, F3.
* Operator identification and recording (actor NULL, label in the payload, not environment-derived, mandatory, validated, attestation limits stated): 3.3, F2, F4.
* Lock order of `flip/4` (A, T, S, C) and the break-glass (A, T, C): 3.4, 3.5; the `flip_out_of_band/3` versus `flip/4` decision with reasons: 3.4; tests that change: 6.
* Emergency `on -> shadow` restarts the window, from code (`ShadowWindow.shadow_since/2`): 3.8, F6.
* `on -> off`, same-mode, non-`on` refusals, missing / blank reason, unknown tenant, platform tenant, fault logging, multi-node, printing, no-admin: 3.6, 3.9 to 3.12.
* Safe-by-design checks (slug against the public table, `confirm`, dry run): 3.10.
* Tests, mutants, AC map, runbook text, residual risks, SEC rulings, relationship to #2869 (a) and (c): sections 5, 7, 8, 10, 11, 12, 3.13.
* No implementation code: signatures, shapes and prose only; the two usage lines in 3.2 and 10.1 are operator-facing command text, not source.
* Every claim about the code was read (2f-b files through `git show` of the branch; main files directly). NOT verified by running anything (no `mix`), as instructed.
  Not read: the 2f-b `RefusedAudit` module body beyond its use, `Audit.latest_matching/4` body (only its call in `ShadowWindow`), and the exact text of 0046
  D4 and D9 (taken from their quotations in 0053 and the REQ-519 requirement text).
