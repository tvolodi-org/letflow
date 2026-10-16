# Runbook: audit and remediate pre-#2550 idempotency-key squats (GH #2597)

## Purpose

Before GH #2550 namespaced caller idempotency keys, an authenticated writer could send a bare
key such as `certificate:issue:<session id>` and claim it in `event_idempotency` before the
server did. The legitimate writer (for example a candidate asking for a certificate) is then
answered with `idempotency_key_reuse` for ever. This runbook finds such rows (read-only) and
removes a confirmed one (explicit, audited, one key at a time).

Design: `lib/letflow/design/gh2597-pre-namespace-squat-audit.md`.

Running this on QA or production is an infra request through the normal flow. It is not part of
the PR that added the tooling.

## Prerequisites

- A release (or checkout) that contains the GH #2597 PR.
- Access to the running node (`bin/letflow rpc`) or, on a dev checkout, `mix`.
- You are a platform operator. There is deliberately no HTTP route and no tenant-admin path.

`bin/letflow eval` is NOT supported: it does not start `Letflow.Repo`. Use `rpc` against the
running node. For the exact `ssh` / `docker exec` stdin form, see section 0 of
`docs/runbooks/login-directory-pepper-rotation.md`. The expression must be ONE line and the
functions print their own result.

## Step 1: audit (read-only)

Release form:

```elixir
Letflow.Release.IdempotencySquats.audit()
```

Dev form: `mix letflow.audit_idempotency_squats`

Output: one `FLAG` line per flagged row (`verdict=flagged`; grep `^FLAG ` for the rows to review), one
`FINDING` line per report-only row (`verdict=report_only`), one `TENANT`
line per tenant with counts, and a final `SUMMARY` line. Pass is a `SUMMARY` line with
`errored=0`; a tenant with `errored=1` could not be audited (retry, a lock timeout is retry-safe).
The audit makes no write: Postgres runs it in a read-only transaction that is always rolled back.
Output never contains a payload or field values; keys are printed escaped.

Verdicts:

- `flagged`: positive mismatch against the verified legitimate writer (wrong event type, wrong
  entity type, stored actor is not the session's user, a non-platform actor on a platform key).
  These are candidates for step 3, after step 2.
- `report_only`: cannot be judged by rule (`event_missing`, `session_not_found`,
  `target_not_uuid`, `payload_unresolved`, `derived_key`, `no_rule`, `reserved_prefix_present`).
  The tool cannot remove these; remediation refuses them.

## Step 2: confirm every flagged row by hand (mandatory)

A flag is a prompt for review, never an instruction. For each flagged row:

1. Compare `stored_actor` with `expected_actor` and read `reason`.
2. Read the squat record named by `squat_entity_type` and `squat_record_id` (through the normal
   entity API). Confirm it is not the real record.
3. For a `certificate:issue:` flag, rule out a LATER edit of the session's `user_id`. The rule
   compares to the session's current owner, so an edited session can make a legitimate row look
   like a mismatch, and removing it would allow a second certificate for that session. The tool
   cannot check session history; you must.

## Step 3: remediate one key

Release form (one line, exact key, your name or ticket as operator):

```elixir
Letflow.Release.IdempotencySquats.remediate("<tenant_id>", "<exact key>", "<operator>")
```

Dev form: `mix letflow.remediate_idempotency_squat <tenant_id> "<exact key>" "<operator>"`

First check the printed `TARGET tenant=... schema=...` line is the tenant you meant. The tool
re-runs the flag rule on the locked row and removes ONLY that `event_idempotency` row, writing an
`idempotency_squat.remediated` audit entry in the same transaction. The squatter's event and
entity record are NOT deleted; the audit entry carries `squat_entity_type` and `squat_record_id`
so you can delete the orphan record through the normal entity API if wanted.

Results:

- `OK outcome=removed`: done.
- `OK outcome=already_clear`: no such row; nothing written (safe to re-run).
- `ERROR not_flagged ...`: the row exists but is not flagged. A legitimate row, a report-only
  row, a derived key, or the legitimate writer has since re-claimed the key. Nothing deleted.
- `ERROR lock_conflict`: another transaction held the row; nothing was written, retry.
- `ERROR unknown_tenant | invalid_key | invalid_operator`: nothing was written.

## Step 4: verify

Re-run step 1: a removed key is no longer listed. Ask the affected user to retry (for example the
candidate re-requests the certificate).

Safe to re-run any step.
