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

## Failure

`N failed` with N > 0 means those tenants were skipped and the others completed; the command
exits with status 1. The output does not name the tenant. Re-run once (safe); if the count
stays, use the Mix-task form on a checkout, which prints the failed tenant ids. A missing
pepper prints `the login directory pepper configuration is missing` and exits 1.
