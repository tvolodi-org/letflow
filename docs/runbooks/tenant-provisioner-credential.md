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

- Can: create (idempotent by the caller's `tenant_id`), get, suspend, resume, expire. Each answers `{ error, message }` on failure with the
  codes `invalid_request`, `unauthorized`, `rate_limited`, `not_found`, `conflict`, `internal_error`.
- Cannot: call any `/api/v1` route, read tenant data, act as an administrator, create or list credentials, users or tenants, delete or purge
  (a later slice). A read-only credential gets 403 on every route but GET.
- Rate limit: 60 accepted requests per credential class per minute; over it, 429 with `Retry-After`. Bad credentials do not consume the budget.

## Retry after a failed create

Every create step is repeatable. After a 500, repeat the same request with the same `tenant_id`; it completes the missing steps and answers 200.
A create for a suspended or expired tenant answers 409: resume it, then repeat.

## The reaper's rule

A realm may be deleted only when `GET /admin/v1/tenants/:id` shows `status` other than `active` **and** a non-null `purged_at`. Until the purge slice is built,
`purged_at` is always null, so the reaper deletes nothing.

The lifecycle runtime release (admission eviction and the realm key provider stop) is node-local; the QA deployment is one node.
