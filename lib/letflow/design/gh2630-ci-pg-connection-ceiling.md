# GH #2630 design: CI backend shards hit Postgres `max_connections` (FATAL 53300)

Design only: no implementation code. Status: for CODE-DESIGN-VALIDATOR. "Read" means read from a
file or CI log in this session; anything else is labelled hypothesis or "needs live proof".
Logs: run 38686125506 (`r1`, 542,268 log lines) and run 38551753468 (`r2`, 427,128 lines),
fetched with `gh run view <id> --log`; line numbers below are lines of that fetched output.

## 1. What the evidence says (re-verified)

| # | Fact | Source |
|---|---|---|
| E1 | All three legs of both runs read back `live max_connections=100, superuser_reserved_connections=3` and computed `TEST_POOL_SIZE=20 (N=4, headroom=10, nonpool_reserve=5, per_partition_headroom=0)`. So the ceiling is really 100, and 4 x 20 = 80 pooled connections. | r1:6002-6003, 7693-7694, 541683-4; r2:1366-7, 2538-9, 426165-6 |
| E2 | Formula: `usable = max-superuser_reserved (97)`, `budget = 97 - 10 - 5 - N*0 = 82`, `pool = floor(82/4) = 20`. Pooled 80 leaves 2 inside the budget and 20 of the raw 100. | scripts/test_parallel.sh:331-337, 355-356, 369 |
| E3 | `config/test.exs` sizes `Letflow.Repo` from `TEST_POOL_SIZE`, and tags every connection `application_name = letflow_mixtest_<ospid>[_grp<group>]`. | config/test.exs:91-101 (pool_size), the `parameters:` block that follows it |
| E4 | Server-side `too many clients already` lines per leg (whole-log grep): r1 shard 1 = 8 (05:22:03-05:22:11 UTC; dump r1:540150-540160); r2 shard 2 = 8 (r2:1498-1514), shard 3 = 77 (25 client `db_conn_1 ... 53300` errors r2:2916-2964, plus the dump r2:420652+). Other legs: 0. | greps of r1, r2 |
| E5 | The failing r1 line is a client-side `db_conn_1 ... FATAL 53300` at 05:22:11.295, immediately after `sweep_template_build_orphans` and a `tenant_template_build_*` CREATE SCHEMA (r1:142775 and the lines above it). In r2 shard 3, ten distinct pids (`#PID<0.1446.0>` .. `<0.1464.0>`) fail at 10:47:39.484 within 10 ms, then retry at :40, :48-50, :58-59, 10:48:01-02, :12, :20. | r1:142760-142775, r2:2916-2964 |
| E6 | Server-side FATAL timestamps in r1 are about 2 s apart (03.372, 05.458, 07.192, 07.520, 09.533, 09.583, 11.294), and in r2 shard 2 too (24.726, 26.828, 33.169, 35.315, 37.482, 38.293, 43.793, 43.939). The service container probes every 2 s (`--health-interval 2s`, ci.yml:411 and :613 area). **Inference, not proven:** many server FATALs are the health probe's own `psql` being refused, which means the server stayed at 100 for seconds (r1: at least 03.4-11.3 = 8 s), not for a millisecond burst. | ci.yml:400-414, 602-616 |
| E7 | The `TEST_POOL_SIZE=6 (caller override)` and `could not reach Postgres at localhost:1` lines (r1:72288-72289, 72553-72554) are NOT a leak: they are `test/scripts/test_parallel_watchdog_diag_test.exs` running `scripts/test_parallel.sh` with `TEST_POOL_SIZE=6`, `LETFLOW_DB_PORT=1` (that test file :229-234; same `LETFLOW_DB_PORT=1` pattern in test_parallel_shard_test.exs:117, test_parallel_race_regression_test.exs:181). Port 1 is unreachable, so they open zero server connections. | as cited |
| E8 | `grep -c 53300` over-counts. In r1 it returns 8, and 7 of those lines are timestamps such as `05:26:12.5330055Z` (r1:257522, 305849, 353151, 421879, 428436, 433243). The issue's "zero 53300 lines" command is therefore unusable as written; see section 4. | r1 greps |
| E9 | The sampler is `TEST_PARALLEL_SAMPLE_CONNECTIONS`-gated (scripts/test_parallel.sh:752), counts only `application_name LIKE 'letflow_mixtest_%'` (:761), writes to `$tmp_dir/connection_samples.log`, which `cleanup_tmp_dir` deletes on a clean exit (:444, :513-514). Nothing in `.github/workflows/*.yml` sets the variable (grep: no hit). So on CI no connection count has ever been recorded. This is hypothesis (c), and it is proven as "never measured", not as "undercounts". | scripts/test_parallel.sh |

### Nested sources (per-process upper bound; "partition" = one of N=4 mix-test VMs)

| Source | Where | Connections | Upper bound |
|---|---|---|---|
| Letflow.Repo pool, one per partition | config/test.exs:91-101 | `TEST_POOL_SIZE` (20) | 80 per shard |
| Dedicated `Postgrex.start_link` lock connection | test/support/bpm_default_realm_displacement.ex:227 (opts :209-218 drop `:pool_size`, so Postgrex default pool of 1) | 1 | 1 per partition; 7 test files, all `async: false` (grep) so serial inside a partition |
| `FakeInvocationConnection.start!` | test/support/fake_invocation_connection.ex:66 (tag overrides `application_name`, so NOT matched by E9's filter); callers: fake_invocation_connection_test.exs (up to 2 live at once, :151-152), 3 reaper tests | 1-2 | 2 per partition |
| Tenant clone / template build | test/support/tenant_template.ex:139 (`Repo.checkout`, pinned), :677, :1331 (`Repo.transaction`); lib/letflow/tenant_provisioning.ex:318 | 0 extra (pool); `Ecto.Migrator`'s inner `Task.async` also goes through the pool (lib/letflow/sandbox_pool.ex:66) | inside the 20 |
| TenantSchemaReaper | test/support/tenant_schema_reaper.ex (no `Postgrex`/`start_link` in it; queries via Repo, :349, :450) | 0 extra | inside the 20 |
| executor self-check, nested `mix test` | test/letflow/engine/lua/executor_test.exs:1497 caps `TEST_POOL_SIZE=4` | 4 | 4, one file, one partition |
| **`mix letflow.migrate_tenant_admins` child** | test/mix/tasks/letflow.migrate_tenant_admins_test.exs:171-182: `System.cmd(mix, ..., env: [MIX_ENV=test, ...])` (no `TEST_POOL_SIZE` override), task calls `Mix.Task.run("app.start")` at lib/mix/tasks/letflow.migrate_tenant_admins.ex:46 | **inherits `TEST_POOL_SIZE=20`, so a full 20-connection Repo pool** | 20 per child (9 `mix_task(` calls, some refuse before app start) |
| **`login_directory.key_status` / `retire_key` child** | test/mix/tasks/letflow.login_directory_tasks_test.exs:53-58 (`env: [{"MIX_ENV","test"}]` only), `app.start` at lib/mix/tasks/letflow.login_directory.key_status.ex:26 and ...retire_key.ex:37 | inherits 20 | 20 per child |
| `mix run --no-start`, `mix compile`, `check_boundaries` children | client_ip / login_discovery / mail / platform_tenant / secrets runtime_config tests, tenant_slug_test.exs:362, check_boundaries_test.exs:432 | `--no-start` or no app, so no Repo | 0 (to be confirmed by the measurement) |
| Docker health probe, `Tune Postgres` psql | ci.yml:400-414, 458-480 | 1 transient | 1 each |
| `lib/mix/tasks/letflow.check.test.ex:569, 764, 802` mix children | run by the orchestrating `mix` outside the partitions, sequentially | plain `schedulers*2` | not concurrent with the partitions (to confirm) |

Each matrix leg and `backend_static` has its OWN `services.postgres` container on its own runner VM
(ci.yml:400, 602; comment ci.yml:~555 "Each leg has its own Postgres service"). So legs do not
share a server and the per-shard ceiling applies per leg.

**Working hypothesis (not a finding):** (b'), the real cause is the `app.start` children inheriting
`TEST_POOL_SIZE=20`. Arithmetic from the table: 80 pooled + one child (20) = 100 = the server's
whole ceiling before the probe, the dedicated connection or a second child. The existing reserve of
5 (scripts/test_parallel.sh:336) was sized for "one reaper connection + a pool of 4"
(the same file's ISS-0515 comment, ~:310-326, which assumes one nested source), and decision 0009's
ISS-0287 addendum (:509-535) argued the reserve need not scale with N because one file maps to
one partition. That argument does not cover three different files each spawning a child (at most
min(N, 3 files) = 3 concurrent children). Not proven until Section 2 runs.

## 2. AC1: measurement plan (throwaway; the smallest option)

**Chosen: a step-level background sampler in `ci.yml` on a draft PR, no change to any script.** It
beats extending `test_parallel.sh` because: no script test needs touching
(test/scripts/test_parallel_*), the sampler stays outside the clamp arithmetic it measures, and the
branch is deleted afterwards. The existing script sampler stays as is.

Design (shapes, not code), added only in job `backend_shard` and, to compare, `backend_static`:
1. Step A, after "Tune Postgres" (ci.yml:660) and before "Run test shard" (:687), `run:` on one
   `psql -h 127.0.0.1 -p 5462 -U letflow -d postgres` session in the background (`nohup`,
   `$RUNNER_TEMP/pgsample.log`), repeating a single `SELECT` every 0.25 s. Cadence 0.25 s because
   E5's burst is ~10 ms and E6 suggests seconds-long saturation; 1 s would miss the shape. One
   long-lived session costs 1 connection and excludes itself with `pid <> pg_backend_pid()`.
   Fallback if `\watch` is rejected in non-interactive mode: a bounded `for` loop with `sleep 0.25`.
2. Each sample is one line: `clock_timestamp()` (UTC), `total`, `mixtest` (count of
   `application_name LIKE 'letflow_mixtest_%'`), `rolsuper` of `letflow`, and a `string_agg` of
   `application_name:state:usename=count`, i.e. the `GROUP BY application_name, state, usename`
   breakdown, with `COALESCE(application_name,'')` so the empty-name clients are visible.
3. Step C, `if: always()`, after "Run test shard": kills the sampler, then prints into the job log
   (no artifact): `show max_connections`, `show superuser_reserved_connections`, `total`
   peak and its timestamp, the top 5 samples by `total` with full breakdown, the number of samples
   with `total >= 95`, the longest run of consecutive samples with `total >= 97`, the peak
   `D` (count of distinct `letflow_mixtest_%` names), and `docker logs` of the service container
   filtered to `too many clients` with first and last timestamps. Server-log timestamps and sampler
   timestamps are both UTC, so they can be joined.
4. Draft PR content: only `.github/workflows/ci.yml`, no merge; rerun the three legs up to 6 times
   (`gh run rerun`), well inside the machine load limits (one hosted job at a time per session).
   Mark "needs live proof": that `nohup` background processes survive across steps on the hosted
   runner, and that `psql \watch 0.25` runs under `-f -`.

**Decision rules.** Let `partition names` = the four `letflow_mixtest_*_grp<tp...>` names with
the highest modal counts; `E(t)` = `total(t) - sum(partition names)(t)`; `T*` = peak of `total`.
Evaluate over the sample window that is within +/-2 s of any server FATAL (from step C).

- **(b) nested subprocess pools outside the clamp** is selected when: in at least one window
  `D > 4` (more `letflow_mixtest_` names than partitions) AND `E(t) >= 15` AND `T* >= 95`.
  Child pool size is then read from that name's count (expect 20 for the `app.start` tasks, 4 for
  executor). Falsified if `T* >= 95` happens with `D <= 4`.
- **(a) `TEST_POOL_SIZE x partitions` plus in-process extras alone exceed 100** is selected when:
  `D <= 4` in every window AND `sum(partition names) >= 95`. By the table in section 1 this needs
  about 15 in-partition extra connections, which the code does not allow, so (a) is expected to be
  falsified; a hit would point at a pool growing past `pool_size` and be reopened as a new issue.
- **(c) sampler gating hides load** is selected when `T* - peak(mixtest) >= 5` (the nonpool
  reserve's size). It is orthogonal: it says the existing filtered sampler would have understated
  peaks and that the reserve should be sized from `total`, not from `mixtest`.
- **(d) transient pool-open burst below the sampling period**: FATALs present but `T* < 95` for all
  samples within +/-2 s. Then the cause is opens that overlap faster than 0.25 s (E5's 10 ms);
  the response is a launch-stagger or admission cap, not a raise.
- No FATAL in 6 reruns x 3 legs: `T*` and `D` are still usable, but then only the structural bound
  of section 1 can justify a fix; a zero-FATAL run never counts as "found the ceiling".

Deliverable (quoted in the PR): per leg `max_connections`, `T*`, `peak(mixtest)`, `D`, per-source
counts at `T*`, `#FATAL`, `#samples >= 95`.

## 3. Candidate fixes (configuration, not retries) and selection

Notation: `P` pool per partition, `N=4`, `c` child pool, `d` dedicated per partition (<=2),
`x` external (probe, tune, sampler) = 2. Because all conflicting test modules are `async: false`,
a partition runs one `async: false` module at a time, so per partition at an instant the worst case
is `P + max(c, d)`.

| Fix | Arithmetic | Selected when the measurement shows |
|---|---|---|
| **F1 lower `P`** (`TEST_PER_PARTITION_HEADROOM`, :354-356, or `TEST_MAX_CONNECTIONS` assumption) | worst case with uncapped children `N*(P+P)+x <= 100` gives `P <= 12`; `P=10`: 80+2 = 82 | (a); or (b) and F2 is rejected. Risk: pool starvation, same class as #2314 (`dropped from queue after 4000ms`); needs a suite time check. |
| **F2 cap the child's pool** in the two `mix_task` helpers, `{"TEST_POOL_SIZE", "4"}` exactly as executor_test.exs:1497 does | `N*(P+4)+x = 4*24+2 = 98` at the current `P=20`; with F4 below, `P=17`: `4*21+2 = 86` | (b). In-repo, deterministic, no CI-infra dependency. Cost: the children run a 4-slot pool, as the executor child already does. |
| **F4 raise `TEST_NONPOOL_CONNECTION_RESERVE`** in the `Run test shard` env (ci.yml:687-693) to `N*max(c,d)` = 16 | `budget = 97-10-16 = 71`, `P = 17`, `4*17 = 68`; worst `68+16+2 = 86 <= 97` | (b) with F2 (`c=4`). Alone (children uncapped at 20) it is infeasible: reserve 80 gives `P=1` (floored at `TEST_MIN_POOL_SIZE=2`, :334). |
| **F3 verified `max_connections=200`** (section 3.1) | `budget = 200-3-10-5 = 182`, `P = 45`; or keep `P=20`: 80 + 3*20 children = 140 < 197 | (b) or (d), as defence in depth, only once the mechanism is proven on a draft PR. It cures the symptom for uncapped children; F2 cures the cause. |
| Cap tenant-clone concurrency (`TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS`, :641, default 4) | clone work runs inside the pool, so it cannot raise `total` above `N*P`; lowering it changes only latency | Selected only if E(t) at `T*` is dominated by names present during template builds (then no F-fix of the pool helps and a launch stagger is the lever); otherwise rejected as not addressing a measured source. |

**Recommendation (conditional): if (b), ship F2 + F4 together** (children capped at 4; reserve 16),
leaving `max_connections` at 100 and no new infra. Add F3 as a second PR only when 3.1 is proven
and a margin target is wanted (spare after F2+F4 is 11 of 97). If (a), F1. If (d), a stagger.
If the measurement shows nothing near 95, do not change the constants; file the evidence.

### 3.1 Raising `max_connections`: what provably applies

- What failed before: ci.yml:100-130 reverted `services.postgres.command: postgres -c
  max_connections=200`, citing the container log line `selecting default max_connections ... 100`
  and `too many clients`. That line is printed by `initdb` (an image's first-start bootstrap,
  before the server is launched with its arguments; the same line is in every container log here,
  e.g. r2:424975 for `backend_static`), so it does not show the `-c` flag was ignored, and the
  history cites no `show max_connections` read-back: never disproven, only never read back.
  Whether Actions honours `services.<id>.command`: the key list I recall is `image`, `credentials`,
  `env`, `ports`, `volumes`, `options` (no `command`); **needs live proof on a draft PR**.
- `options` takes only `docker create` flags (no arguments after the image); an initdb script needs
  a host file that does not exist before checkout.
- **Proposed mechanism M2 (smallest diff, self-verifying):** in the existing "Tune Postgres"
  step (ci.yml:458, :660), add `ALTER SYSTEM SET max_connections = <n>` to the same `psql` call
  (accepted, takes effect at restart), then `docker restart` the one service container (found with
  `docker ps --filter ancestor=postgres:16 -q`; one per VM), then a bounded wait (`pg_isready`,
  max ~30 s) and `SHOW max_connections` that must equal `<n>` or the step exits 1 with an
  `::error::`, mirroring the existing fsync read-back loop (ci.yml:463-480). `postgresql.auto.conf`
  lives in PGDATA inside the container filesystem, which persists across `docker restart`, as do
  the published port and the previous reload-only ALTER SYSTEMs. Needs live proof: that the hosted
  runner user may run `docker restart` on a service container. Restart time is to be recorded.
- **Fallback M3:** replace the `services:` block with a `docker run -d -p 5462:5432 ... postgres:16
  -c max_connections=<n>` step plus the same read-back: deterministic argv, larger diff.
- In both: set `TEST_MAX_CONNECTIONS=<n>` in the `Run test shard` env so the formula and the live
  read-back (scripts/test_parallel.sh:271-288) agree.

## 4. AC "3 consecutive green runs, zero 53300": evidence plan

- Do not use the issue's `grep -c 53300` (E8). Use the exact signatures, per job log:
  `gh run view <id> --log | grep -c -E "FATAL 53300 \(too_many_connections\)|sorry, too many clients already"`
  and require `0` for all three shard legs and `backend_static` of each of three consecutive runs
  of the fix commit (PR head or main), with each run's `conclusion=success`.
- Positive controls so a "0" cannot be a missing log: the log must contain the
  `host ceiling verified -- live max_connections=<n>` line (E1 pattern), and (if F3 is chosen)
  the M2 read-back line; and `grep -c "test_parallel: TEST_POOL_SIZE="` must be `>= 1` per leg.
- Margin evidence (flake frequency unknown, two recorded occurrences): keep the step-A/C sampler
  in the fix PR for its first three runs and quote `T*` per leg; acceptance also requires
  `T* <= 90` (a proposal, open question 3). The PR quotes the section 2 table before and after.

## 5. Documentation

- Decision 0009 (docs/migration/decisions/0009-test-parallel-pool-sizing.md, last addendum :509): new
  "GH #2630" addendum with E1-E9, the section 2 table, the chosen limit and arithmetic, a correction
  of the fourth addendum (:392-430: the `initdb` line is not evidence about `-c`) and of the ISS-0287
  addendum's "one file, one partition" claim (three child-spawning files exist).
- ci.yml header (:100-130) and the comments at :455, :657: keep the history, add a pointer; change
  "TRIED AND REVERTED" to "superseded by GH #2630" **only if** a green run shows the `SHOW
  max_connections` read-back of M2/M3. Otherwise add that the cited evidence was inconclusive.

## 6. Test plan (repo guards must stay green)

- `test/letflow/gh2622_ci_cd_timeouts_test.exs:18-37` pins the whole job map and timeouts
  (`backend_shard` 45, `backend_static` 30): add steps, never a job. Shard wall time is about 7 min
  (r2 10:46:19 to 10:53).
- `test/letflow/api/permission_matrix_test.exs:766-791` splits ci.yml on `"\n  backend_static:\n"`
  and `"\n  backend_shard:\n"`, pins the permission-matrix step and the cache block, and forbids
  `!_build/dev`: keep job order, those steps and the cache block byte-identical.
- `test/letflow/gh2622_ci_push_concurrency_test.exs:183-300`: `changes` job steps, env map, job-name
  table (:289): do not touch.
- `test/letflow/ci_backend_path_filter_test.exs`: ci.yml is a backend path (:43, :106); layer 3
  (:375-430) scans paths named in gate steps, so do not reference a new `scripts/` file in a gate
  step. Here-string rule (:302-330): no list piped into `grep -q` under `pipefail`; use `grep -c`.
- New tests (fix PR): static assertion that both `mix_task` helpers pass `TEST_POOL_SIZE`; the
  formula block at `TEST_NONPOOL_CONNECTION_RESERVE=16, N=4, max=100` yields 17 (style of
  test/scripts/test_parallel_*.exs); if M2, a static pin on the `SHOW max_connections` compare and
  `exit 1`. ELIXIR-DEV runs `mix letflow.check`; this design did not run mix.

## 7. Security (SECURITY-REVIEWER mandatory: ci.yml, #2586 trust boundary)

Check: (1) no new secrets, `permissions:` unchanged, only the existing literal `PGPASSWORD: letflow`;
(2) no `${{ }}` in any `run:`, no `github.event.*` read in new steps; (3) the container id for
`docker restart` comes from the runner's own `docker ps`, quoted, nothing from the PR; (4) no
artifact upload or `GITHUB_OUTPUT` write of sampler data, and never `pg_stat_activity.query`;
(5) triggers and checkout refs unchanged (no `pull_request_target`); (6) change is confined to the
job's own container; (7) required-check job names and the merge-queue ruleset unchanged (AC6;
names pinned by gh2622 test :283-289).

## 8. Order of work

1. Measurement PR first: separate, draft, ci.yml steps only, closed unmerged. It cannot live inside
   the fix PR: the fix choice depends on its output, and a raised ceiling would hide the composition.
2. Fix PR (F2+F4 if (b)) with the sampler kept for its first 3 runs (section 4); M2/F3 as a third
   PR only after a draft proves the mechanism. Docs addendum ships with the fix PR.
3. #2622 is already in this tree (its guard tests exist): no ordering conflict.

## 9. Open questions for the supervisor

1. Is `letflow` a superuser in the CI container (usable ceiling 100, not 97)? The sampler logs it.
2. May the runner user `docker restart` a service container, and does Actions accept
   `services.<id>.command`? Both "needs live proof"; one draft run answers both.
3. `T* <= 90` as an acceptance margin is a proposal, not a measured number.
4. Flake frequency is unknown (2 recorded occurrences): are 6 reruns enough, or watch main merges?
5. `backend_static` has no recorded FATAL: sampler there too, or shards only?
6. Does a child's `app.start` open the whole pool eagerly? `D` and `E(t)` answer it; if lazy, (b')
   weakens.
