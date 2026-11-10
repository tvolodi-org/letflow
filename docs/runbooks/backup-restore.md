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
| Letflow PostgreSQL: the `public` schema and **every tenant schema** (`tenant_<id>`, registered in `public.tenant_schemas`) | one `pg_dump -Fc` per database (`backup.sh dump`), daily; optional WAL + weekly `pg_basebackup` | tenants, definitions, events, ledger, secrets (ciphertext) |
| Keycloak database (`keycloak_<env>`) | the same dump job (list it in `BACKUP_DATABASES`; no manifest, checksum only) | users, credentials, realms |
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

## 5. Interface for infra

| Item | Value |
|---|---|
| Scripts | `scripts/backup/backup.sh dump\|base`, `wal_archive.sh %p %f`, `prune.sh [--dry-run]`, `restore_test.sh [--set DIR]` |
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

Tenants live in schemas named `tenant_<id>`. Supported only for a tenant whose data was lost by an
operator mistake; never for a purged tenant. There is no automated command: a single-tenant restore
writes into live tenant data and needs its own review.

1. Restore the whole dump into a scratch database (section 6, step 4, another name).
2. Verify that the rows of `public.tenants` and `public.tenant_schemas` for that tenant are equal in the live and the scratch database.
3. `pg_dump -Fc -n tenant_<id> scratch > tenant.dump`.
4. Suspend the tenant, then in the live database `DROP SCHEMA tenant_<id> CASCADE` and `pg_restore -d <live> tenant.dump`. **The whole schema is replaced, never single tables** (the ledger cannot be merged).
5. Platform-level rows in `public` (users, role groups) are **not** restored by this; check them by hand. Resume the tenant and run its smoke.

Everything written to that tenant after the dump is lost. Dropping the schema is the point of no return:
keep the scratch copy and a dump of the live tenant until the tenant confirms.

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

**Off-site copy. Decided by the owner, 2026-11-10 (D-115):** production gets an off-site backup copy, on another server
or the owner's PC; details with infra (ai-dala-infra-18). Production runs on a new small Hetzner server
(ceiling about EUR 40 per month until the first paying customer), data in Germany, and the on-call is an
AI agent (no human pager). Not yet built: the push/pull step and its status file.

Rules for the off-site copy (proposal in `docs/uat/ba-decisions/T-1600.md`, section 3; owner and infra confirm):

* **Encrypted before it leaves the server** (`BACKUP_ENCRYPT=gpg`). The private key is not on the production
  server nor on the off-site target. `LETFLOW_SECRETS_MASTER_KEY` is never in the off-site copy of the database.
* **A broken-into production server must not be able to delete the off-site copy:** the target pulls, or the key
  on the server can only append.
* **Recommended target:** a second small server or storage box in another location (about EUR 4–6 per month,
  an estimate). The owner's PC over a tunnel is allowed only as an extra copy: it is off part of the time, has
  a limited home link for a restore, and needs a human at restore time.
* **Retention** at the target is not shorter than `DUMP_KEEP_DAYS` and is the longest a purged tenant's data
  survives there too (see section 1); the privacy notice names it.
* **Infra polls** one more status file for the off-site job like the four in section 4: alert on `"ok":false`
  and on a `ts` older than 26 hours. Each alert has its own runbook; the AI on-call reads an alert log.
* **Drill:** the quarterly drill in section 10 is done **from the off-site copy** onto a different host, by the
  agent, and timed against the RTO. The first one must pass before the first paying customer.

Update 2026-11-10 (plan v2.1, `docs/uat/ba-decisions/T-1605.md`; infra facts, prices are third-party estimates):

* **Off-site is allowed for Letflow production only, and only pull-based** (the Hetzner hosts cannot dial the
  agent host behind the PC NAT). Two copies recommended: the agent host pulls twice a day, and the QA host
  (113 GB free) or a later second VPS. The owner's PC and hetzner-prod are poor targets. Bandwidth is about
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
2. Which off-site target (second server or storage box, or the owner's PC as an extra), and where it lives (the owner accepted data in Germany; a target outside it needs a new answer).
3. Retention vs. purge: 14 days is the longest a purged tenant's data survives in backups — acceptable? Off-site copies follow the same number.
4. Who holds the gpg private key and the second copy of `LETFLOW_SECRETS_MASTER_KEY`, and how the agent on call gets them when needed.
5. The Keycloak realm JSON export: infra owns it; confirm the weekly schedule.
