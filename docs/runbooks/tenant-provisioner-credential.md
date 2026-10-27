# Tenant provisioner credential (QA only)

REQ-572 / GH #3252, decision 0072 D6. **QA only. Production is not approved** (portfolio decision D-019).
Code: `Letflow.Plugs.ProvisionerAuth`, `Letflow.Routers.AdminV1`, `Letflow.TenantProvisioner`.

The provisioner credential is not a role and not a user. It is a bearer secret whose SHA-256 is configured on the
server; it opens exactly five routes under `/admin/v1` and nothing else.

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `LETFLOW_PROVISIONER_CREDENTIAL_SHA256` | unset: `/admin/v1` answers 404 | SHA-256 of the write credential (64 lowercase hex) |
| `LETFLOW_PROVISIONER_READONLY_CREDENTIAL_SHA256` | unset: no read class | SHA-256 of the read-only credential; it may call `GET /admin/v1/tenants/:id` only (the realm reaper) |
| `LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES` | empty: every hostname refused | comma-separated suffixes; a tenant hostname is one label plus one of them |
| `LETFLOW_PROVISIONER_DEMO_LIFETIME_DAYS` | 14 | default `expires_at` of a created tenant |
| `LETFLOW_PROVISIONER_RETENTION_DAYS` | 30 | days a deactivated tenant's data is kept before it is purged (0..3650; REQ-580) |
| `LETFLOW_PROVISIONER_DEMO_CAP` | 30 | most demo tenants (tier demo, lifecycle not deleted) at once; a create beyond it answers 409 `conflict` (0..100000; GH 3292) |
| `LETFLOW_PROVISIONER_DEMO_ALARM` | 25 | when a create leaves the demo count at or above it, one warning log line names the count and the cap (0..100000) |
| `LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES` | 60 | minutes between scheduled sweeps (1..10080) |
| `LETFLOW_PUBLIC_BASE_URL` | unset: create answers 500 | the `server_url` of the create answer (the same variable the mail adapter reads) |

Boot stops, naming the variable and never its value, when a hash is not exactly 64 lowercase hex or when the write and read
hashes are equal.

## Generate and configure

1. Generate a secret of at least 256 bits: `openssl rand -hex 32`. A shorter secret is not accepted by this runbook.
2. Compute its hash: `printf '%s' "$SECRET" | openssl dgst -sha256 | awk '{print $NF}'` (lowercase hex).
3. Put only the hash in the deployment environment. Give the secret to the portfolio front door (or, for the read-only
   one, to the realm reaper) through its own secret store. Never commit either value.
4. Restart. Without a configured hash the mount answers 404, byte for byte like an unknown path.

Rotation: replace one hash and restart; the old secret stops working at once. The write and read secrets are separate; rotate
them separately.

## What the credential can and cannot do

- Can: create (idempotent by the caller's `tenant_id`), get, suspend, resume, expire, delete (`DELETE /admin/v1/tenants/:id`: 202 while the
  tenant is deactivated and waiting for its retention, 200 `status: "deleted"` once purged, 409 for a production tenant; QA only). Each answers `{ error, message }` on failure with the
  codes `invalid_request`, `unauthorized`, `rate_limited`, `not_found`, `conflict`, `internal_error`.
- Cannot: call any `/api/v1` route, read tenant data, act as an administrator, create or list credentials, users or tenants, purge before the retention has run out
  (the purge refuses it, 409 `not_eligible`). A read-only credential gets 403 on every route but GET.
- Rate limit: 60 accepted requests per credential class per minute; over it, 429 with `Retry-After`. Bad credentials do not consume the budget.

## Retry after a failed create

Every create step is repeatable. After a 500, repeat the same request with the same `tenant_id`; it completes the missing steps and answers 200.
A create for a suspended or expired tenant answers 409: resume it, then repeat.

## The reaper's rule

A realm may be deleted only when `GET /admin/v1/tenants/:id` shows `status: "deleted"` **and** a non-null `purged_at`. A purged tenant still answers
that route (200, never 404); `purged_at` is the purge marker and holds no personal data. A purge runs when the tenant is deactivated, its deletion was requested
(`DELETE`) and the retention has run out (`DELETE` on a deactivated tenant, or `POST /api/v1/tenants/:slug/purge` by a PLATFORM_ADMIN of the platform tenant); the
scheduled sweep (below). A purge does not erase backups or replicas, and a purged tenant is never reactivated.

The lifecycle runtime release (admission eviction and the realm key provider stop) is node-local; the QA deployment is one node.

## Scheduled sweep

`Letflow.TenantProvisioner.Sweep` is one timer process (`Letflow.Supervisor.Pollers`, key `:start_provisioner_sweep`, off in the test env) that runs
every `LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES` minutes (default 60); the first run is one interval after boot. Each run:

1. expires a demo tenant whose `expires_at` has passed (the same function as `POST /admin/v1/tenants/:id/expire`);
2. purges a `suspended` or `expired` tenant, not production, whose retention has run out (`expires_at` for an expired tenant, `deletion_requested_at` for a
   suspended one, plus `LETFLOW_PROVISIONER_RETENTION_DAYS`), through `Letflow.TenantPurge.purge/3` with trigger `sweep` (the audit entry says so).

It never touches an active tenant (other than step 1), a suspended tenant with neither `deletion_requested_at` nor `expires_at`, a production tenant, or a
purged one. One tenant's failure is logged as `provisioner sweep failed for tenant (tenant_id=..., step=..., reason=...)` (no tenant data) and the run goes on.
Find a stuck tenant by that line.

The sweep is on by default outside the test env, and it purges data: any deployment that has provisioner-created demo tenants sweeps them without further
action. There is no environment variable to turn it off; set `config :letflow, start_provisioner_sweep: false` in the deployment's config to stop it.

The cap answers a create beyond `LETFLOW_PROVISIONER_DEMO_CAP` with the same 409 `conflict` body as the exists-conflict (REQ-572 criterion 19; it reveals no
tenant data). The alarm variable is named `LETFLOW_PROVISIONER_DEMO_ALARM`, as in decision 0072.

The demo cap: a create of a new tenant is refused with 409 `conflict` while the demo count (tier `demo`, lifecycle not `deleted`) is at
`LETFLOW_PROVISIONER_DEMO_CAP`. The alarm is the warning `provisioner: demo tenant count reached the alarm threshold (count=N, cap=M)`; raise the cap or
let the sweep purge expired demos when you see it.
