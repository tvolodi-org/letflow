# Backup and restore (Postgres, Keycloak) — runbook

Application side: [`scripts/backup/`](../../scripts/backup/README.md) (T-1568). Host side — timers, disk,
alert delivery — is infra's (ai-dala-infra-18). The scripts exit non-zero and write a status file; they
send nothing anywhere.

## 1. Status and scope

* **Wired by infra:** demo and QA. **Production is not approved** (portfolio decision D-019, QA only).
* Storage today is **local disk only**, one disk per host (demo and QA keep that rule). A backup
  therefore protects against a **logical error or a bad deploy**. It does **not** protect against loss
  of the host or its disk. **For production the owner lifted the local-disk-only rule in principle on
  2026-11-10 (portfolio D-115): an off-site copy is wanted** (section 11; plan in
  `docs/uat/ba-decisions/T-1600.md`). The off-site step is **not built yet**; until it exists and a
  restore from it has passed, production must not go live.
* No failure alerting exists on any host yet: infra polls `status/*.json` (section 4).
* Backups hold every tenant's data including personal data (e-mail addresses). They are kept 0600 in a
  0700 tree, may be encrypted to a public key (`BACKUP_ENCRYPT=gpg`), and print no record content.
  A purge does not erase backups or replicas (`tenant-provisioner-credential.md`, "Delete"): the
  retention number (`DUMP_KEEP_DAYS`, 14) is the longest a purged tenant's data survives in backups.
  A purged tenant is never restored.

## 2. What is backed up

| What | How | Restore source for |
|---|---|---|
| Letflow PostgreSQL: the `public` schema and **every tenant schema** (`tenant_<id>`, registered in `public.tenant_schemas`) | **one `pg_dump -n <schema> -Fc` per registered tenant schema, one for `public`, and `pg_dumpall --globals-only`** (`backup.sh dump`, never a whole-database dump; T-3149), daily; optional WAL + weekly `pg_basebackup` | tenants, definitions, events, ledger, secrets (ciphertext) |
| Keycloak database (`keycloak_<env>`) | the same dump job (list it in `BACKUP_DATABASES`; one whole `pg_dump -Fc`, no manifest, checksum only) | users, credentials, realms |
| Keycloak realm JSON export | **proposed** weekly step by infra (admin REST needs credentials this repo does not hold); infra's existing weekly Keycloak tar is the QA basis | realm settings / the realm template; not users |
| `LETFLOW_SECRETS_MASTER_KEY` | **never in a backup.** Kept apart from the database backup (decision 0016, sections A and B: [secrets storage](../migration/decisions/0016-secrets-storage-backend.md)) | decrypting stored secrets |

A database backup without `LETFLOW_SECRETS_MASTER_KEY` restores fine but **cannot decrypt stored
secrets**: store the key in a second place and check it in the drill. `.env` files and container images
are not in the backup set. Check with infra whether the host keeps uploaded files on disk outside
PostgreSQL; if so they need their own entry.

## 3. Targets (proposed, owner to accept)

| Environment | RPO (data lost at most) | RTO (time to be back) | How |
|---|---|---|---|
| demo | 24 h (1 h with an hourly timer) | 1 h | daily `dump`; 7 sets + one before each promote |
| QA | none (disposable) | — | a dump is taken only for the weekly drill |
| production (not approved) | 15 min | 1–2 h, same host | WAL archive + daily dump + weekly restore drill |
| **host or disk loss** | demo/QA: **not covered**; production: age of the last off-site copy (proposal: up to 24 h) | demo/QA: —; production: half a day on a new server (proposal, the drill measures it) | production needs the off-site copy (section 11) |

These are proposals. The weekly restore test measures the real restore time (`seconds=` in its line):
compare it with the RTO.

## 4. Schedule and layout

Output (default `BACKUP_ROOT=/opt/backups/<BACKUP_ENV>`): `dump/<db>/<stamp>/`, `dump/<db>/LATEST`,
`base/<stamp>/`, `wal/`, `status/<job>.json`. The full variable list is in
[`scripts/backup/README.md`](../../scripts/backup/README.md); the names are `BACKUP_ENV`, `BACKUP_ROOT`,
`BACKUP_DATABASES`, `LETFLOW_DATABASE`, `PG_EXEC`, `BACKUP_ENCRYPT`, `BACKUP_GPG_RECIPIENT`, `BACKUP_PRUNE`,
`RETENTION_FILE`, `WAL_ARCHIVE_DIR`, `WAL_KEEP_DAYS`, `BACKUP_MAX_AGE_HOURS`, `RESTORE_TARGET`,
`RESTORE_PG_IMAGE`, `RESTORE_DOCKER_ARGS`, `RESTORE_GPG_HOME`, `RESTORE_DATABASE_URL_BASE`, `RELEASE_BIN`, `RESTORE_SMOKE_CMD`,
`RESTORE_SMOKE`, `RESTORE_ALLOW_NO_SMOKE`. Secrets go in the unit's `EnvironmentFile=` (mode 0600), never
inline.

`PG_EXEC` examples: `docker exec -i -e PGUSER=letflow letflow-postgres` (Postgres in a container);
empty when the client tools are on the host `PATH`.

Unit examples (infra installs them; paths are examples):

```ini
# /etc/systemd/system/letflow-backup-dump.service
[Unit]
Description=Letflow daily database dump
[Service]
Type=oneshot
EnvironmentFile=/etc/letflow/backup.env
ExecStart=/opt/letflow/scripts/backup/backup.sh dump
```

```ini
# /etc/systemd/system/letflow-backup-dump.timer
[Timer]
OnCalendar=*-*-* 01:45:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/letflow-restore-test.service  (weekly drill: a fresh dump, then its restore test)
[Unit]
Description=Letflow weekly restore test
[Service]
Type=oneshot
EnvironmentFile=/etc/letflow/backup.env
ExecStart=/opt/letflow/scripts/backup/backup.sh dump
ExecStart=/opt/letflow/scripts/backup/restore_test.sh
```

```ini
# /etc/systemd/system/letflow-restore-test.timer
[Timer]
OnCalendar=Sun 03:30 UTC
Persistent=true
[Install]
WantedBy=timers.target
```

WAL mode (optional, production): `archive_mode = on` and
`archive_command = '/opt/letflow/scripts/backup/wal_archive.sh "%p" "%f"'` (the script must see the
server's WAL directory and `WAL_ARCHIVE_DIR`; with Postgres in a container, mount `/opt/backups/<env>/wal`
into it), plus a weekly `backup.sh base`. Retention is `scripts/backup/retention.conf` (`DUMP_KEEP_DAYS=14`,
`DUMP_KEEP_MIN=7`, `BASE_KEEP=2`, `WAL_KEEP_DAYS=14`); `prune.sh --dry-run` shows what would go. Pruning
never leaves fewer than `DUMP_KEEP_MIN` sets and never deletes the newest set that passed a restore test.

**What infra polls.** `status/dump.json`, `status/base.json`, `status/prune.json` and
`status/restore_test.json`: alert on `"ok":false`, and on a `ts` older than the schedule (8 days for the
restore test: then the drill did not run). The weekly result is "posted" as that file plus the journal
line; the scripts make no outbound call. The restore test runs on the host because GitHub runners cannot
reach QA or demo (local disk only).

The application also reads these files (T-1607) for the platform operator's Health page, as a hint only:
set `LETFLOW_BACKUP_STATUS_DIR` to `$BACKUP_ROOT/status` (mounted read-only into the web process); unset means
"not configured here". The line shows ok / failed / too old / no report per job (`GET /api/v1/platform-status/backup`,
platform operator only). Its age limits are fixed: dump 30 h, base and restore test 8 days, prune none. Infra's own
alerting stays the authority. `GET /ready` (public) names the failing part of the node: database, migrations,
secrets key, identity provider.

## 5. Interface for infra

| Item | Value |
|---|---|
| Scripts | `scripts/backup/backup.sh dump\|base`, `wal_archive.sh %p %f`, `prune.sh [--dry-run]`, `restore_test.sh [--set DIR] [--tenant SCHEMA]` |
| Output dir | `/opt/backups/<env>/` (`dump`, `base`, `wal`, `status`) |
| Exit codes | `backup.sh` 0 ok, 2 input, 3 dump failed / busy, 4 base refused, 5 encryption, 6 prune; `restore_test.sh` 0 pass, 1 content, 2 input, 3 no fresh backup, 4 checksum, 5 restore, 6 smoke; `prune.sh` 0, 2, 6; `wal_archive.sh` 0, 1, 2 |
| Report | `restore_test.sh` prints one line (`restore_test PASS ...` / `restore_test FAIL step=... exit=... detail=...`) |
| Throwaway target | `RESTORE_TARGET=container` (default) starts `postgres:<major>` on a random loopback port and removes it on exit, with `--cpus=1 --memory=1g --memory-swap=1g --pids-limit=512` unless `RESTORE_DOCKER_ARGS` replaces them (`--flag=value` tokens only; host-reaching flags are refused, exit 2); `existing` uses a scratch database `restore_test_<stamp>_<pid>` it creates and drops itself — it never writes to the source |
| Smoke | `RELEASE_BIN eval "Letflow.Release.restore_smoke()"` against the scratch database (`DATABASE_URL`); the release needs its usual runtime environment in the unit's `EnvironmentFile=` |

## 6. Restore the whole database

1. Run `restore_test.sh` first if the backup was not tested this week (a damaged backup shows up here, not during the incident).
2. **Take a fresh dump of the broken state** (`backup.sh dump`) before changing anything: it is the only way back from a wrong restore.
3. Stop the application (and Keycloak clients that write).
4. Restore into a **new** database, never over the live one:
   `createdb letflow_restored` then `pg_restore --exit-on-error --no-owner -d letflow_restored dump/<db>/<stamp>/<db>.dump`
   (an encrypted set: `gpg --decrypt <file>.gpg | pg_restore ...` with `RESTORE_GPG_HOME`).
5. Check it with the manifest (`manifest.sql` against `letflow_restored`, compare with `manifest.txt` of the set).
6. Swap by renaming (`ALTER DATABASE ... RENAME`), start the application, run `scripts/demo_smoke_read.sh` (or the environment's smoke).

**Point of no return.** Renaming the old database away is reversible; **dropping it is the point of no
return**: do it only after the drill checks pass and the new copy has run for the agreed period. Writes
made after the dump's time are lost (RPO). The events and the ledger are append-only: there is no merging
the lost part back, and the ledger tables cannot be partly restored (migration `create_ledger_tables`).

## 7. Restore a single tenant (schema-per-tenant)

Tenants live in schemas named `tenant_<id>`. The dump set has one file per schema (T-3149), so one tenant
restores alone. Supported only for a tenant whose data was lost by an operator mistake; never for a
purged tenant. The drill is automated against a scratch database; the live replacement is manual and
needs its own review.

**Drill (scratch database only):** `restore_test.sh --tenant tenant_<id>`. Order: `public` (the platform
schema, registry) first, then that tenant's file, then the registry rows are reconciled to that tenant
(the other `public.tenant_schemas` rows are deleted in the scratch copy). No other tenant's schema is
ever created; the script fails (exit 1) if one is present. The check is the manifest lines of that
tenant. A one-tenant drill does not write `VERIFIED` (the set is not verified as a whole).

**Live restore:**

1. Run the drill above; keep the scratch database for step 2 (`RESTORE_TARGET=existing`, do not drop).
2. Verify that the rows of `public.tenants` and `public.tenant_schemas` for that tenant are equal in the live and the scratch database. The dumps of `public` and the tenant are taken moments apart (per-schema snapshots, not one global snapshot): reconcile the registry rows by hand if they differ.
3. Take a dump of the live tenant first: `pg_dump -n tenant_<id> -Fc`.
4. Suspend the tenant, then in the live database `DROP SCHEMA tenant_<id> CASCADE` and `pg_restore --no-owner -d <live> tenant_<id>.dump` (the file from the set, decrypted with `gpg --decrypt` when encrypted). **The whole schema is replaced, never single tables** (the ledger cannot be merged).
5. Platform-level rows in `public` (users, role groups) are **not** restored by this; check them by hand. Resume the tenant and run its smoke.

Everything written to that tenant after the dump is lost. Dropping the schema is the point of no return:
keep the scratch copy and a dump of the live tenant until the tenant confirms.

### Per-schema dump: how it fails, sizes, locks

* `backup.sh dump` reads the schema list from `public.tenant_schemas` (the registry), never from a
  whole-database dump. It **fails loudly** (exit 3, status detail `registry_mismatch missing=... extra=...`,
  the named lists on stderr) when a registered tenant has no schema, or a `tenant_*` schema is not in
  the registry; also on an empty registry or a registry name that is not a plain tenant schema.
* `BACKUP_JOBS` (default 2) schema dumps run in parallel; each is its own transaction with its own
  exported snapshot, so one dump never holds more than one schema's locks (about 650 relations).
* The manifest `manifest.tsv` has one row per file: schema, file, bytes, sha256, UTC timestamp, format
  (`custom` or `sql` for globals), Postgres major, schema version (max `public.schema_migrations` version),
  modules digest. Cross-schema consistency is per schema: `public` and each tenant are dumped at slightly
  different moments.
* **Server setting.** `max_locks_per_transaction = 256` for production, set by infra in the production
  `db` service `command:` args next to `max_connections=100` (infra plan, step 04e section 5; it needs
  a restart, so it goes in with the first production start). With per-schema dumps even the default 64
  fits; 256 is the headroom for the restore and for any tool that still touches many tables.
* **Sizes.** Assumptions: about 650 tables per tenant schema (current product figure), `max_connections=100`,
  about 270 bytes per lock slot (estimate), the whole-database dump needing at least one slot per table.

| Tenants | Tables (about) | Lock slots one dump needs | Whole-database dump | Per-schema dump |
|---|---|---|---|---|
| 1 | 650 | 650 | fits (default 64 x 100 = 6,400) | fits |
| 10 | 6,500 | 6,500 | fails on the default 6,400 | fits (650 per dump) |
| 100 | 65,000 | 65,000 | needs about 650 per slot: not a setting to rely on | fits (650 per dump); at 256 the table has 25,600 slots |

  Measured on the fake dataset of the test (`test/scripts/backup_scripts_test.exs`, T1): 32 schemas
  (`public`, `tenant_a` and 30 synthetic `tenant_NNN`, one tiny table each): the set is 67,786 bytes on disk (33 dump files incl. globals, 53,313 bytes of dump data, about 1.6 KB per schema), 32 `pg_dump -n` calls, no call without `-n`. This only proves the call pattern and the manifest, not production size: a real tenant schema of about 650 tables dumps far larger, so size the disk from the previous night's `manifest.tsv` (`bytes` column).
  Real figures depend on the tenants' data; the dump count grows linearly with the number of tenants and
  the wall time with it divided by `BACKUP_JOBS`.
* **Retention and encryption are unchanged.** Current text: "Backups ... are kept 0600 in a 0700 tree, may
  be encrypted to a public key (`BACKUP_ENCRYPT=gpg`), and print no record content ... the retention number
  (`DUMP_KEEP_DAYS`, 14) is the longest a purged tenant's data survives in backups." Retention is
  `scripts/backup/retention.conf` (`DUMP_KEEP_DAYS=14`, `DUMP_KEEP_MIN=7`, `BASE_KEEP=2`, `WAL_KEEP_DAYS=14`).
* **When.** This does not block the first client's go-live (one tenant fits a whole-database dump), but it
  must be in place before the second production tenant.

## 8. Restore Keycloak

Restore the `keycloak_<env>` database like section 6 (stop Keycloak first), or import the realm JSON into
a clean Keycloak when only settings are lost (users are not in a partial export). Then check a login with
[`scripts/demo_smoke_read.sh`](../../scripts/demo_smoke_read.sh) and the tenant realm steps in
[`onboarding-new-tenant-realm.md`](onboarding-new-tenant-realm.md). A Keycloak restore does not change
`LETFLOW_SECRETS_MASTER_KEY` and is independent of the Letflow database restore, but restore both from the
same day so the realm ids in `tenants.idp_realm_id` match.

## 9. Point-in-time recovery (WAL mode)

Only after the first successful drill in WAL mode. Restore the newest `base/<stamp>` into an empty data
directory, set `restore_command` to copy from `wal/` and `recovery_target_time`, start, check, promote.
`prune.sh` keeps WAL from the oldest kept base's `start_wal`. The positive `backup.sh base` path needs a
server with `archive_mode = on` and is **not** exercised in CI; it is a drill step here.

## 10. Drill checklist

Weekly (automatic): `restore_test.sh` on a fresh dump; it checks the checksum, restores into a throwaway
target, compares tenant, event-store and ledger counts, module versions and the ledger replay digest with
the manifest taken in the same snapshot, runs the smoke through the release, and writes
`status/restore_test.json`.

Quarterly (manual): 
- [ ] restore the newest set onto a different host or container, boot the release against it with the real `LETFLOW_SECRETS_MASTER_KEY`, run the smoke script
- [ ] decrypt a stored secret to prove the key matches
- [ ] restore Keycloak and log in
- [ ] time it and compare with the RTO; record the result in the ticket
- [ ] WAL mode: one `base` + replay to a `recovery_target_time`

## 11. Open owner questions

**Off-site copy. Decided by the owner, 2026-11-10 (D-115):** production gets an off-site backup copy.
Updated 2026-11-16 (D-152, `docs/uat/ba-decisions/T-1600.md`, sections 2 and 3): production runs on the existing
bizdala.com host next to QA (no new server, no new money), data in Germany. The copy on the QA host is the same
machine and is **not** off-site. Off-site copies are the agent host (pull, twice a day) and the owner's PC (weekly
push over the tunnel, best effort). Not yet built: the pull/push step and its status file; every build step is
announced before it runs.

Rules for the off-site copy (proposal in `docs/uat/ba-decisions/T-1600.md`, section 3; owner and infra confirm):

* **Encrypted before it leaves the server** (`BACKUP_ENCRYPT=gpg`). The private key is not on the production
  server nor on the off-site target. `LETFLOW_SECRETS_MASTER_KEY` is never in the off-site copy of the database.
* **A broken-into production server must not be able to delete the off-site copy:** the target pulls, or the key
  on the server can only append.
* **Targets (D-152):** the agent host is the primary off-site copy; the owner's PC over the tunnel is a second
  copy, weekly and best effort (it is off part of the time and has a limited home link for a restore). No second
  server or storage box is bought.
* **Retention** at the target is not shorter than `DUMP_KEEP_DAYS` and is the longest a purged tenant's data
  survives there too (see section 1); the privacy notice names it.
* **Infra polls** one more status file for the off-site job like the four in section 4: alert on `"ok":false`
  and on a `ts` older than 26 hours. Each alert has its own runbook; the AI on-call reads an alert log.
* **Drill:** the quarterly drill in section 10 is done **from the off-site copy** onto a different host, by the
  agent, and timed against the RTO. The first one must pass before the first paying customer.

Update 2026-11-10 (plan v2.1, `docs/uat/ba-decisions/T-1605.md`; infra facts, prices are third-party estimates):

* **Off-site is allowed for Letflow production only, and only pull-based** (the Hetzner hosts cannot dial the
  agent host behind the PC NAT). Superseded 2026-11-16 (D-152): the agent host pulls twice a day and the owner's PC
  gets a weekly push; a copy on the QA host is the same machine as production and is not counted; hetzner-prod
  is a poor target. Bandwidth is about
  76/27 Mbit/s (one sample). Alert on a newest copy older than about 30 hours.
* **Encryption:** production gets only the public gpg key; the private key lives on the agent host plus one
  offline owner copy; restore tests run on the agent host. **Gap:** `scripts/backup/wal_archive.sh` has no
  encryption step; fix it before WAL mode is switched on (no WAL now, D-116).
* **No on-call or night service for non-paying clients (D-116):** the `alerts.log` idea is preparation only.
* **Dry run** on the QA host (22:00-23:00 UTC, 2 CPU / 3 GB, loopback, abort rules) waits for the stage-1 stack
  definition and the user's go.
* **VPS prices** (third-party blogs, EU, excluding VAT, estimates): CX23 about EUR 5.49, CX33 about 8.49,
  CAX11 (ARM) about 5.99, IPv4 about +0.50; arm64 image support is unknown.

Open owner questions:

1. Accept the RPO/RTO numbers of section 3 (production: 15 min / 1–2 h on the same host; host loss: up to 24 h / half a day).
2. Off-site target: decided by D-152 (agent host plus the owner's PC); nothing is asked.
3. Retention vs. purge: 14 days is the longest a purged tenant's data survives in backups — acceptable? Off-site copies follow the same number.
4. Who holds the gpg private key and the second copy of `LETFLOW_SECRETS_MASTER_KEY`, and how the agent on call gets them when needed.
5. The Keycloak realm JSON export: infra owns it; confirm the weekly schedule.
