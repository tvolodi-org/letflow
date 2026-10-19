# Runbook: turning scope enforcement on (REQ-519)

GH #2535, decision 0051 D12 and amendments A8-A10. The checklist and facts an operator needs before and
after a tenant is set to `on`. `docs/roles.md` carries the same text for readers of the role charter.

**No production tenant is set to `on` until the supervisor says so.** No `on` flip in any customer tenant, pilot included, until GH #2869 and GH #2883 are implemented. Flipping a production tenant is a
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

The gate for `shadow` to `on`, stable codes: `bindings_without_row`, `org_inconsistent`, `tokens_exceed_owner` (tokens of a flagged service principal still count; the flagged-service-principal exemption covers only the mint subset check), `zero_tenant_wide_admins` (at least one active, interactive human with an explicit tenant-wide TENANT_ADMIN grant is required: token owners and flagged service principals do not count, because only such a user can turn enforcement off), `scoped_approvers_without_task_scope` (see "What `on` means in production today", item 3, below), `shadow_evidence_insufficient` (the tenant has been in `shadow` for at least `scope_shadow_min_days` days, default 7; at least `scope_shadow_min_requests` requests, default 100, over the window; requests on every date of the window; no `no_grant_rows` or `grants_unavailable` would-deny). The thresholds are server configuration only. `GET /api/v1/tenant/scope-enforcement/integrity` shows the same facts as a lock-free snapshot in its `on_gate` block (`findings` is the older informational list; `on_gate.blocking` is what the `on` flip will check).

The shadow period proves only the denials of tenant-wide and admin-plane routes; denials on the data path (compiler predicate, 404 equivalence, writes, bulk and import, F1) are proven by the REQ-518 tests and the end-to-end suite, not by shadow.

The flip request itself counts as a shadow request, and request counts include every authorized request of any principal, the flipping admin's own included, so the evidence rule is an operator-safety control, not an adversarial one.

## What `on` means in production today

Read this before flipping any tenant. Only pilot tenants may be flipped, and pilot use must wait for the open items: the tenant-level metadata reads for scoped users (RA-6, REQ-525..527, filed in #2862); the last-admin gap (#2869: a tenant stored `on` can end with nobody able to turn it off; the operator break-glass is built, GH #2883, and the guard that prevents the gap is still open); and the writer of `tasks.scope_node_id` (W3b, #2870). The decision-record amendment is 0051 A8-A10 (PR #2871); A11 records the GH #2883 break-glass.

1. A tenant that passes the gate can be set to `on` by an interactive tenant-wide TENANT_ADMIN, only from `shadow`, with an audit trail.
2. `on` delivers: the admin plane is closed to scoped admins, scoped users get a uniform 403 on every tenant-wide route, binding writers and IdP sync no longer widen anyone, and the grant tables fail closed.
3. `on` does NOT deliver data-level scoping in production. No installed module declares scope, so a scoped user sees no entity data; and no writer sets `tasks.scope_node_id`, so a scoped task worker sees no task and a scoped approver cannot claim or complete one.
4. The shadow period proves only the denials of tenant-wide and admin-plane routes (the sentence above).
5. Scoped users lose definitions, entity-definition, instance and service reads until the tenant-level metadata follow-up (RA-6) ships.
6. Do not scope the CANDIDATE binding: the exam routes stay tenant-wide, so a scoped CANDIDATE gets 403 and exam sessions break.
7. To turn `on` off: an interactive tenant-wide TENANT_ADMIN, with a mandatory reason. Tokens cannot. When no such admin can log in, use the platform-operator break-glass command `Letflow.Release.ScopeBreakGlass` (`mix letflow.scope_enforcement.break_glass`), which has no HTTP route and needs a mandatory reason and an operator label.
8. A platform tenant stored as `on` does not restrict its PLATFORM_ADMIN on platform-scope routes; grants never decide platform scope.

The scoped-approver blocker is evaluated at flip time only: a scoped approver created after `on` is fail-closed and shown in the `on_gate` information count of the integrity report.

**Conditions and cautions for any flip** (they are not numbered items above and not limitations):

**Service accounts, several nodes, window restart.** They are the last three items of the section "Known limitations of an enforced tenant" below, and they are conditions for any flip.

**Refusal audit.** The `scope.enforcement_refused` entry is best-effort, written in its own transaction after the rollback. A refusal can therefore go unrecorded (the 409 is still returned and one constant log line `scope_enforcement_refusal_not_recorded` is written). A successful flip is audited in the same transaction and cannot go unrecorded.

**Gate #2869 (last admin).** Before ANY production or pilot `on`, #2869 must be resolved: a guard that refuses the removal, demotion, deactivation, scoping or service-flagging of the last interactive explicit tenant-wide TENANT_ADMIN of a tenant stored `on` (still open). The other half, a platform-operator break-glass with no HTTP route, a mandatory reason and an audit entry, is delivered by GH #2883, and 0051 A11 records that the 0051 A7 token break-glass covers grant writes only.

## Break-glass: turning an on tenant off without an admin (platform operator)

Use this ONLY when a tenant stored `on` has nobody who can turn enforcement off through the API (an interactive tenant-wide TENANT_ADMIN is required for the PUT, and tokens cannot). Typical cause: the identity provider no longer lets the admins log in, which Letflow cannot see. There is NO HTTP route for this and it is not a role: it is a command on the release host, authorised by access to that host (decision 0051 A11).

Before you start: you hold shell access to the running node; you have an incident ticket id; you know the tenant slug exactly. Choose your label: your personal handle as it appears in the infrastructure access log (letters, digits and `. _ @ + -`, at most 64 characters). The reason MUST start with the incident ticket id, as `<ticket id>: <short reason>`: the ticket, the infrastructure access log and the node name recorded in the audit entry are how the label is matched to a person. Do NOT put secrets, personal data or quotes in the reason; the reason and your label are readable in the tenant's audit log by anyone with AuditRead.

The Mix form is for dev and CI hosts ONLY. Do not run `mix` on a production host: `app.start` there boots a second full Letflow application against the same database as the running node. On a deployed release use the `rpc` form below.

1. Dry run (writes nothing). Release form (stdin, `docs/runbooks/login-directory-pepper-rotation.md` section 0; `bin/letflow eval` is not supported): `Letflow.Release.ScopeBreakGlass.run("<slug>", "shadow", "<ticket id>: <short reason>", "<your label>", dry_run: true)`. Mix form (dev and CI only): `mix letflow.scope_enforcement.break_glass <slug> --to shadow --reason "<text>" --operator <label> --dry-run`. Read the `TARGET` line: the tenant must be `current_mode=on`. A dry run and every refusal leave one constant line in the node log (`scope_break_glass_dry_run`, `scope_break_glass_refused`, with your label when it is valid). Any `ERROR` line means nothing was changed; fix the input.
2. Choose the target. `shadow`: enforcement stops denying, shadow counters keep counting; the shadow window RESTARTS, so returning to `on` needs a full new window (default 7 days) and the six gate facts, including at least one interactive explicit tenant-wide TENANT_ADMIN who can log in. `off`: enforcement and counting stop; returning needs `off` to `shadow` (three facts), a full window, then `on`. Prefer `shadow` unless the counters themselves are the problem.
3. Real run: the same expression with `confirm: "<slug>"` instead of `dry_run: true` (Mix: `--confirm <slug>`). Pass/fail is the printed line: `OK ... mode=<shadow|off> action=scope.enforcement_disabled` is success; `ERROR <tag>` is a refusal and nothing changed (`not_enforced`: the tenant is not `on`, maybe someone already fixed it; `lock_conflict`: another admin operation holds the tenant, retry; `server_fault`: stop, the flag was NOT changed, escalate). The exit status of `rpc` is not meaningful.
4. Verify: the change is effective on every node from the next request. An admin who can log in reads `GET /api/v1/tenant/scope-enforcement`; the audit log (`GET /api/v1/audit`, resource type `tenant`) holds one `scope.enforcement_disabled` entry with a null actor and, in its state, your label, your reason, `"source": "operator_break_glass"` and the name of the node that ran it.
5. Then fix the root cause (restore an admin at the identity provider). Do not repeat the command for the same incident.

Never write the column with SQL: that skips the audit entry and the locks. If the node cannot start at all, fix that first; the command needs the running application. The single exception is the last-resort paragraph below.

**Audit-chain fault (last resort).** Use this ONLY when BOTH hold: (a) the break-glass command answered `ERROR server_fault` with the log line `scope_break_glass_failed reason=audit_failed` on TWO attempts at least 1 minute apart (the retry rules out a transient lock timeout); and (b) infrastructure has CONFIRMED, and written down, a fault in the application's audit INSERT path (an application bug, a configuration fault, or a stuck lock held by a named database backend) that the SQL below does NOT share. A damaged OLD chain (a corrupt tail or a hash mismatch in history) does NOT block the command, because `Letflow.Audit.insert_entry/3` chains the new entry onto the stored tail, and it is NEVER a trigger: damage that `verify_chain/2` reports goes into its own defect issue and never through this path. Every other case uses the command. All of the following conditions apply:

1. Trigger: (a) and (b) above, both, nothing else.
2. Written sign-off by the USER (the platform owner) directly. The decision owner is the user, never an agent, and a sign-off relayed through another session does not count. Without it nobody runs the SQL.
3. Infrastructure executes ONE transaction that writes the column AND inserts the audit row, with the user's sign-off reference as the reason (`<sign-off reference>`: ASCII letters, digits, spaces and `. , : ; _ @ + / ( ) # -` only, no quote, backslash or control character, 2 to 500 characters, starting with a letter or digit and ending with a letter, digit, `.` or `)`). The SQL below is run VERBATIM after the named placeholders are replaced: nothing else is improvised. It is a single `DO` statement, so it is ONE atomic transaction and any error aborts the whole of it. Placeholders: `<TENANT_ID>` (tenant id), `<SCHEMA_NAME>` (its `tenant_<32 hex>` schema), `<LOCK_KEY>` (the tenant-admin advisory lock key, a signed 64-bit integer, possibly negative), `<MODE>` (`shadow` or `off`), `<OPERATOR>` (your label, same rule as the command), `<REASON>` (the sign-off reference). The checks inside the SQL run AFTER the statement is parsed and do NOT neutralise quotes or `$`, so infrastructure must check EVERY placeholder value BEFORE substituting it: `<TENANT_ID>` a UUID, `<SCHEMA_NAME>` matching `tenant_[0-9a-f]{32}`, `<LOCK_KEY>` matching `-?[0-9]{1,19}`, `<MODE>` exactly `shadow` or `off`, `<OPERATOR>` the operator-label rule of the command, `<REASON>` the reason rule above; NO placeholder may contain a quote (`'` or `"`) or `$`. The three per-tenant constants are pasted ONLY from the output of the `rpc` expression below, never typed or edited. Get the three per-tenant constants from the running node with Letflow's own functions: `{:ok, t} = Letflow.Identity.get_tenant_by_slug("<slug>"); {:ok, s} = Letflow.TenantProvisioning.registered_schema(t.id); IO.inspect({t.id, s, Letflow.Identity.tenant_admin_lock_key(s)})`. The statement refuses unless the tenant is stored `on`, the schema matches the registration, the placeholders obey their rules and the clock is after the chain tail. It takes the locks in the command's order (tenant-admin lock A, the `tenants` row, then the audit chain lock), writes the AUDIT ROW FIRST and only then runs `UPDATE tenants`, so no column write exists without its audit row. If the audit table, the lock table or the permissions are broken the SQL fails too and the column stays as it is: that is the intended outcome. It computes the chain hash exactly as `Letflow.Audit` does (SHA-256 over the 11 length-prefixed canonical fields, previous entry taken from the stored tail) and writes `scope.enforcement_disabled` with a null actor and `"source":"last_resort_sql"`.

```sql
DO $last_resort$
DECLARE
  v_tenant   constant uuid := '<TENANT_ID>';
  v_schema   constant text := '<SCHEMA_NAME>';
  v_lock_key constant bigint := <LOCK_KEY>;
  v_mode     constant text := '<MODE>';
  v_operator constant text := '<OPERATOR>';
  v_reason   constant text := '<REASON>';
  v_registered text;
  v_stored     text;
  v_prev       text;
  v_prev_ts    timestamp(6);
  v_id       uuid := gen_random_uuid();
  v_ts       timestamp(6) := clock_timestamp() AT TIME ZONE 'UTC';
  v_micros   bigint;
  v_trace    text;
  v_before   constant text := '{"mode":"on"}';
  v_after    text;
  v_canon    text;
BEGIN
  IF v_mode NOT IN ('shadow', 'off') THEN RAISE EXCEPTION 'mode must be shadow or off'; END IF;
  IF v_operator !~ '^[A-Za-z0-9][A-Za-z0-9._@+-]{0,63}$' THEN RAISE EXCEPTION 'bad operator label'; END IF;
  IF length(v_reason) > 500 OR v_reason !~ '^[A-Za-z0-9][A-Za-z0-9 .,:;_@+/()#-]*[A-Za-z0-9.)]$' THEN RAISE EXCEPTION 'bad reason'; END IF;
  PERFORM set_config('lock_timeout', '10s', true);
  PERFORM pg_advisory_xact_lock(v_lock_key);
  SELECT schema_name INTO v_registered FROM public.tenant_schemas WHERE tenant_id = v_tenant;
  IF v_registered IS DISTINCT FROM v_schema THEN RAISE EXCEPTION 'schema name does not match the registration'; END IF;
  SELECT scope_enforcement INTO v_stored FROM public.tenants WHERE id = v_tenant FOR UPDATE;
  IF v_stored IS DISTINCT FROM 'on' THEN RAISE EXCEPTION 'tenant is not stored on'; END IF;
  EXECUTE format('INSERT INTO %I.audit_chain_locks (tenant_id) VALUES ($1) ON CONFLICT DO NOTHING', v_schema) USING v_tenant;
  EXECUTE format('SELECT 1 FROM %I.audit_chain_locks WHERE tenant_id = $1 FOR UPDATE', v_schema) USING v_tenant;
  EXECUTE format('SELECT chain_hash, timestamp FROM %I.audit_entries ORDER BY timestamp DESC, id DESC LIMIT 1', v_schema)
    INTO v_prev, v_prev_ts;
  IF v_prev_ts IS NOT NULL AND v_prev_ts >= v_ts THEN RAISE EXCEPTION 'clock is not after the chain tail'; END IF;
  v_micros := extract(epoch FROM date_trunc('second', v_ts))::bigint * 1000000
              + (extract(microseconds FROM v_ts)::bigint % 1000000);
  v_trace := 'last-resort-' || replace(gen_random_uuid()::text, '-', '');
  v_after := '{"mode":"' || v_mode || '","node":"sql","operator":"' || v_operator
             || '","reason":"' || v_reason || '","source":"last_resort_sql"}';
  v_canon :=
    octet_length(v_id::text) || ':' || v_id::text ||
    octet_length(v_tenant::text) || ':' || v_tenant::text ||
    '-1:' ||
    octet_length('scope.enforcement_disabled') || ':' || 'scope.enforcement_disabled' ||
    octet_length('tenant') || ':' || 'tenant' ||
    octet_length(v_tenant::text) || ':' || v_tenant::text ||
    octet_length(v_micros::text) || ':' || v_micros::text ||
    octet_length(v_before) || ':' || v_before ||
    octet_length(v_after) || ':' || v_after ||
    octet_length(v_trace) || ':' || v_trace ||
    CASE WHEN v_prev IS NULL THEN '-1:' ELSE octet_length(v_prev) || ':' || v_prev END;
  EXECUTE format(
    'INSERT INTO %I.audit_entries (id, tenant_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state, trace_id, chain_hash, prev_chain_hash, inserted_at) '
    || 'VALUES ($1, $2, NULL, ''scope.enforcement_disabled'', ''tenant'', $3, $4, $5::jsonb, $6::jsonb, $7, $8, $9, date_trunc(''second'', clock_timestamp() AT TIME ZONE ''UTC''))',
    v_schema)
    USING v_id, v_tenant, v_tenant::text, v_ts, v_before, v_after, v_trace,
          encode(sha256(convert_to(v_canon, 'UTF8')), 'hex'), v_prev;
  UPDATE public.tenants
     SET scope_enforcement = v_mode, updated_at = date_trunc('second', clock_timestamp() AT TIME ZONE 'UTC')
   WHERE id = v_tenant AND scope_enforcement = 'on';
  IF NOT FOUND THEN RAISE EXCEPTION 'tenant is not stored on'; END IF;
END
$last_resort$;
```

4. Within 24 hours afterwards SECURITY-REVIEWER reviews the event, and a defect issue is filed for the audit-table fault (GH #2896, preparedness: docs plus tests). Then run the audit-chain verification (`Letflow.Audit.verify_chain/2` through `bin/letflow rpc`) once the fault is repaired.
5. This paragraph is the only exception to `Never write the column with SQL`; it is absolute everywhere else.

If the SQL raises `clock is not after the chain tail`, wait (at least until the database clock is past the tail) and re-run the SAME SQL; never edit it. If it still raises after 10 minutes, escalate to the platform owner: the clock skew is itself an incident.

## Known limitations of an enforced tenant

- LIMIT-IDP-SYNC-WHOLE-GROUP: in an `on` tenant the IdP role-claims sync adds NO membership to a group that binds a platform role which would make the user tenant-wide for that role. A membership cannot be split by role, so the non-widening roles of that group are withheld too (SEC A-7). The audit entry is `grant.sync_suppressed` when the user already holds scoped rows for the role and `binding.pending_scope` when the user holds none. Login still succeeds.
- LIMIT-POST-ROLES-409: `POST /roles` answers 409 `scope_required` in an enforced tenant for a new platform-role binding (or a routing-role binding converted to a platform role). Remedy: create the binding before enabling enforcement, or set enforcement to off with a reason, create it, narrow its scope, and enable again.
- LIMIT-IMPORT-UPSERT-404: a scoped caller's import in `upsert_by external_ref` mode is refused with the generic 404 (the generic not-found answer), even for rows inside its scope, because the upsert primitive (`Records.upsert_record_by_external_ref`) is not scope-aware. The refusal is in the entities router (`import_scope_check/6`, `lib/letflow/routers/entities.ex`, which does not match `create` for it and falls through to `:scope_refused`, mapped to the 404), not in the Records primitive, so tenant-wide callers are unchanged. Only `create` mode imports are offered to a scoped caller. A scope-aware upsert is not built.
- LIMIT-ON-FLAG: `on` is settable only from `shadow`, by an interactive tenant-wide TENANT_ADMIN, after the gate passes (REQ-519 2f-b); `off` to `on` is refused as `shadow_required`. The three limitations above still hold once `on` is settable.
- LIMIT-MULTI-NODE-SHADOW-FLUSH: the evidence flush before an `on` flip (`ShadowWindow.flush_evidence/0`) flushes only the local node's in-memory counters. With several nodes, the other nodes' unflushed would-deny counters are invisible to the gate (a failed flush only makes the gate stricter on that node). CONDITION: a multi-node deployment needs a cross-node flush of ShadowWindow counters before an `on` flip.
- LIMIT-IDP-SERVICE-ACCOUNT-ADMIN: "interactive" means the credential is `:oidc`. An unflagged IdP service account holding TENANT_ADMIN passes the flip PUT and is counted by gate fact 4 (`zero_tenant_wide_admins`) as an interactive admin. Flag every such account as a service principal (`PUT /users/:id/service-principal`) before any pilot.
- LIMIT-EMERGENCY-RESHADOW: the shadow window starts at the latest flip entry (both `scope.enforcement_enabled` and `scope.enforcement_disabled`), so an emergency `on` to `shadow` makes the shadow window restart: a full new window is needed before `on` can be set again. This is safe by design.
