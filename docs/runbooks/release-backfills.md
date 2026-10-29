# Runbook: operator backfills in a release (GH #2567)

A release has no Mix. Run the backfills through `Letflow.Release`, with `bin/letflow eval`.
Do not call `Mix.Tasks.*` modules from a release, and do not use `rpc` for these: on a
failure they call `System.halt(1)`, which would stop a live node.

Each wrapper loads the app, starts only `Letflow.Repo` (a pool of 2) and the applications it
needs, runs the same core function as its Mix task, prints counts and exits non-zero if any
tenant failed. Output is counts only: no key, pepper, email address or tenant id. Every
wrapper is idempotent, so it is safe to re-run (a re-run reports `created = 0`).

## Script HMAC secrets (GH 2534 7b-1)

Creates the per-tenant script-input HMAC key for every tenant that has none.

    bin/letflow eval "Letflow.Release.backfill_script_hmac_secrets()"

Fresh run, 6 tenants:

    script HMAC backfill: 6 tenant(s) processed, 6 created, 0 already present, 0 failed

Re-run:

    script HMAC backfill: 6 tenant(s) processed, 0 created, 6 already present, 0 failed

Dev form: `mix letflow.backfill_script_hmac_secrets`.

## Login directory (REQ-435)

Backfills the tenant-login directory from each tenant's active users. Needs the
`LETFLOW_LOGIN_DIRECTORY_PEPPER*` variables, as the running node does. `created` counts
inserted directory rows, `already present` counts keys that already had a row.

    bin/letflow eval "Letflow.Release.backfill_login_directory()"

Expected: `login directory backfill: 6 tenant(s) processed, 40 created, 0 already present, 0 failed`;
a re-run shows `0 created` and the same total under `already present`. A dry run (writes
nothing): `bin/letflow eval "Letflow.Release.backfill_login_directory(dry_run: true)"`.
Dev form: `mix letflow.backfill_login_directory` (prints per-tenant ids as well).

## Platform role groups (T-0934)

A new tenant gets every built-in role group (`TENANT_ADMIN`, `TENANT_AUDITOR`, and the rest) from
`Letflow.TenantOnboarding.provision_and_migrate/1`. A tenant that existed before a release added a
built-in role does not, and its users then authenticate but get 403 (no app role resolved, for
example `GET /api/v1/me/modules`). After any release that adds a built-in role, check, then heal:

    bin/letflow eval "Letflow.Release.check_platform_role_groups()"
    bin/letflow eval "Letflow.Release.backfill_platform_roles()"

The check is read-only: it prints one `MISSING_ROLE_GROUPS schema=<schema> roles=<names>` line per
tenant with a gap and a `SUMMARY` line, and exits non-zero if any tenant has a gap. The backfill
runs `Letflow.Identity.RoleBackfill.run/1` (the core of `mix letflow.backfill_platform_roles`); it
is idempotent, and for a tenant it seeds it resets that tenant's `role_claims_synced_at` markers so
the next login re-syncs roles. A tenant that already has every group is untouched. Dev form:
`mix letflow.backfill_platform_roles`. (On QA on 2026-10-30 infra ran `RoleBackfill.run()` after
`TENANT_AUDITOR` was missing in 6 tenant schemas.)

## Failure

`N failed` with N > 0 means those tenants were skipped and the others completed; the command
exits with status 1. The output does not name the tenant. Re-run once (safe); if the count
stays, use the Mix-task form on a checkout, which prints the failed tenant ids. A missing
pepper prints `the login directory pepper configuration is missing` and exits 1.

## PLATFORM_ADMIN tokens with no expiry (GH #2579)

The inventory of standing PLATFORM_ADMIN tokens with no expiry, and the explicit act that replaces
one, are operator wrappers too (`Letflow.Release.platform_admin_token_inventory()` and
`Letflow.Release.reissue_platform_admin_token/4`). They are described in
`docs/runbooks/platform-admin-token-reissue.md`.
