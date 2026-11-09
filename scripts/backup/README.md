# scripts/backup — database backups and the restore test

Application side of the backup work (T-1568). The host side (timers, disk, who is told when a
status file is red) is infra's; the runbook [`docs/runbooks/backup-restore.md`](../../docs/runbooks/backup-restore.md)
has the unit examples, the targets and the restore procedures. Everything here is bash, needs
only PostgreSQL client tools (reached through `PG_EXEC` when Postgres runs in a container),
`sha256sum`, `flock`, and `gpg` / `docker` for the options that use them.

| Script | Purpose |
|---|---|
| `backup.sh dump` | daily: one `pg_dump -Fc` set per database in `BACKUP_DATABASES`, sha256, manifest (Letflow database), prune |
| `backup.sh base` | weekly (WAL mode only): `pg_basebackup`; refuses while `archive_mode` is off |
| `wal_archive.sh %p %f` | the `archive_command` helper (WAL mode only) |
| `prune.sh [--dry-run]` | retention from `retention.conf` |
| `restore_test.sh [--set DIR]` | restore the latest dump set into a throwaway database and check it; one report line |
| `manifest.sql` | the read-only count/digest query used by both backup and restore test |
| `retention.conf` | retention policy (`KEY=number` lines, parsed, never sourced) |

## Output layout (default `BACKUP_ROOT=/opt/backups/<BACKUP_ENV>`, dirs 0700, files 0600)

```
dump/<db>/<UTC stamp>/<db>.dump[.gpg]  <db>.dump[.gpg].sha256  manifest.txt (Letflow db only)  VERIFIED (after a passed restore test)
dump/<db>/LATEST -> <stamp>
base/<UTC stamp>/base.tar.gz[.gpg]  .sha256  base.info
wal/<segment>
status/<job>.json      job = dump | base | prune | restore_test
```

A set is written as `.tmp-<stamp>` and renamed when complete, so a half set is never picked up.

## Environment

No secrets live in the repo: the password comes from libpq's `PGPASSFILE` / `PGPASSWORD` in the
unit's `EnvironmentFile=`. Every name below is new; the reason is in the second column.

| Variable | Default | Meaning / reason |
|---|---|---|
| `BACKUP_ENV` | required | `demo`, `qa`, `prod`: labels the output dir and the status file |
| `BACKUP_ROOT` | `/opt/backups/$BACKUP_ENV` | output root (infra's layout) |
| `BACKUP_DATABASES` | required | space-separated database names, e.g. `letflow_demo keycloak_demo` |
| `LETFLOW_DATABASE` | first of `BACKUP_DATABASES` | the one database that gets a manifest and is restore-tested |
| `PG_EXEC` | empty | command prefix reaching the client tools, e.g. `docker exec -i -e PGUSER=letflow letflow-postgres` |
| `PGHOST` `PGPORT` `PGUSER` `PGPASSFILE` | libpq | connection (with `PG_EXEC` they apply inside the container) |
| `BACKUP_ENCRYPT` | `none` | `none` or `gpg` |
| `BACKUP_GPG_RECIPIENT` | — | public key id/e-mail when `gpg`; the host holds no private key |
| `BACKUP_PRUNE` | `1` | run `prune.sh` at the end of `backup.sh` |
| `RETENTION_FILE` | `retention.conf` next to the scripts | policy file; keys `DUMP_KEEP_DAYS`, `DUMP_KEEP_MIN`, `BASE_KEEP`, `WAL_KEEP_DAYS` |
| `WAL_ARCHIVE_DIR` | `$BACKUP_ROOT/wal` | destination of `wal_archive.sh` |
| `BACKUP_MAX_AGE_HOURS` | `30` | `restore_test.sh` refuses (exit 3) an older newest set |
| `RESTORE_TARGET` | `container` | `container` (throwaway `docker run`) or `existing` (a scratch database on the `PG_EXEC` server) |
| `RESTORE_PG_IMAGE` | `postgres:<major in manifest>` | image of the throwaway container |
| `RESTORE_DOCKER_ARGS` | `--cpus=1 --memory=1g --memory-swap=1g --pids-limit=512` | `container` target: extra `docker run` args, split on spaces; replaces the default limits when set. Only `--flag` / `--flag=value` tokens (`--cpus=2`, not `--cpus 2`); `--privileged`, `--volume`/`--mount`/`--volumes-from`, `--device`, `--cap-add`, `--security-opt` and host `--network`/`--net`/`--pid`/`--ipc` are refused with exit 2 |
| `RESTORE_GPG_HOME` | — | `GNUPGHOME` holding the private key, for an encrypted set |
| `RESTORE_DATABASE_URL_BASE` | — | `existing` target: `ecto://user:pw@host:port` the release uses to reach the scratch database |
| `RELEASE_BIN` | — | path of `bin/letflow`; runs `eval "Letflow.Release.restore_smoke()"` against the scratch database |
| `RESTORE_SMOKE_CMD` | — | replaces the release smoke (gets `DATABASE_URL`, `RESTORE_DB_NAME`) |
| `RESTORE_SMOKE` / `RESTORE_ALLOW_NO_SMOKE` | `run` / `0` | `skip` is accepted only together with `RESTORE_ALLOW_NO_SMOKE=1` |

## Exit codes

| Script | Codes | Meaning |
|---|---|---|
| `backup.sh` | `0 2 3 4 5 6` | 0 ok; 2 bad input / missing tool; 3 dump failed or another run holds the lock; 4 base backup refused or failed; 5 encryption failed; 6 prune failed (the backup is kept) |
| `prune.sh` | `0 2 6` | 0 ok; 2 bad input; 6 a deletion failed or was refused |
| `restore_test.sh` | `0 1 2 3 4 5 6` | 0 pass; 1 content check failed; 2 bad input / tool / version mismatch; 3 no fresh backup; 4 checksum mismatch; 5 restore failed; 6 smoke failed or not configured |
| `wal_archive.sh` | `0 1 2` | 0 ok; 1 copy failed or a different file has that name; 2 bad input |

## Status file (what infra polls)

`$BACKUP_ROOT/status/<job>.json`, one line, written atomically (temp file + `mv`) from an `EXIT`
trap, so a crash also leaves it: `{"job":"dump","env":"qa","ts":"2026-11-09T01:45:03Z","exit":0,"ok":true,"detail":"sets=2 bytes=5802 stamp=..."}`.
`ts` older than the schedule (8 days for the weekly restore test) means the job did not run.
`detail` holds fixed tokens and counts only. `restore_test.sh` also prints its one-line report:

```
restore_test PASS env=qa db=letflow_qa set=20261109T014500Z tenants=3 ledger_pairs=12 replay_diff=0 modules=ok smoke=ok seconds=41
restore_test FAIL step=content exit=1 detail=manifest_differs:tenant_x.events
```
