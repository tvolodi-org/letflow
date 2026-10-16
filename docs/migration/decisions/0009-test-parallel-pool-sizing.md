# 0009 — `scripts/test_parallel.sh` per-partition pool_size vs Postgres max_connections

Status: confirmed — self-reviewed (ORCH acting alone; this execution context
cannot spawn a separate REVIEWER pass, stated explicitly per
`core-directives.md`'s No Speculation / Zero Manual Work discipline rather than
silently skipped). Owner: ORCH.

## Question

ISS-0194 (filed by RELEASE-VALIDATOR during `WF02-REQ113-20260821` Step 5
re-run): `scripts/test_parallel.sh` derives its partition count `N` from
`nproc`/`getconf`, and `config/test.exs` sizes each partition's own Ecto pool
as `System.schedulers_online() * 2`. Both numbers scale with the same
quantity (core count), so `N * pool_size` scales **quadratically** with core
count while Postgres's `max_connections` does not scale at all. Measured
2026-08-21 on this host: `nproc` = 16, so `N` = 16 and `pool_size` = 32,
wanting 512 simultaneous connections against `letflow-2-postgres-1`'s actual
`max_connections` of 100 (`docker exec letflow-2-postgres-1 psql -U letflow
-d letflow_dev -tAc "show max_connections;"`). The issue's own filing
independently measured the same class of failure at N=8/pool_size=16=128 on
the host that first hit it — the ratio is the defect, not a specific core
count.

This is not a REQ-113 script defect: the script correctly reports the real
failures/aborts it observes when connections are refused. It is a genuine
resource-budgeting gap between two independently-derived numbers that were
never checked against the shared ceiling they both draw from.

## Options considered

- **(A) Hard-fail if `N * pool_size` would exceed a configured budget.**
  Simplest to reason about, but means every host with more than ~6 cores
  (at the current `pool_size = cores*2` formula and a 100-connection
  Postgres) cannot run `test_parallel.sh` at its default N at all without
  manual intervention — a regression from REQ-113's whole point (use all
  available cores automatically).
- **(B) Clamp per-partition `pool_size` down to fit the budget, computed
  from `N` and a configured connection ceiling, with a floor.** Keeps `N`
  at its natural, fully-parallel value and instead shrinks each partition's
  own concurrency (how many of that partition's own async tests can hold a
  checked-out connection at once) just enough that the product fits.
  Degrades gracefully: a partition with a smaller pool still runs, just
  with more internal serialization among its own async tests, rather than
  failing to start.
- **(C) Reduce `N` instead of `pool_size` to fit the budget.** Rejected:
  this throws away the parallelism REQ-113 was built to add (running fewer
  partitions than available cores), where (B) throws away only some
  intra-partition concurrency, which is the smaller sacrifice for the
  common case (a fast local Postgres easily absorbing a few dozen
  connections).
- **(D) Raise Postgres `max_connections` in the dev/test `docker-compose`
  config instead of touching the script/config at all.** Rejected as the
  sole fix (though not incompatible with (B) — the `TEST_MAX_CONNECTIONS`
  knob below can reflect a raised ceiling): it doesn't scale — the ratio
  problem recurs on any host with enough cores, and it's this repo's own
  container, not something every future host running the script is
  guaranteed to have adjusted the same way.

## Decision: (B), with a floor and an explicit override escape hatch

`scripts/test_parallel.sh` now computes, unless the caller already set
`TEST_POOL_SIZE` explicitly:

```
budget       = TEST_MAX_CONNECTIONS (default 100) - TEST_CONNECTION_HEADROOM (default 10)
computed     = budget / N                                    (integer division)
TEST_POOL_SIZE = computed, or TEST_MIN_POOL_SIZE (default 2) if computed is smaller, with a WARN
```

and exports `TEST_POOL_SIZE` for every partition's `mix test` subprocess.
`config/test.exs` reads it (`System.get_env("TEST_POOL_SIZE")`) and falls
back to the original `schedulers_online() * 2` when unset — so a plain
`mix test` invocation (not run through `test_parallel.sh`) is byte-for-byte
unchanged.

**Why a floor rather than a hard failure when the budget is very tight.**
Ecto's Sandbox pool at `pool_size = 1` still functions — it serializes that
partition's own async tests onto one connection rather than deadlocking or
refusing to start. A floor of 2 keeps every host runnable at its full
natural `N`, at the cost of a WARN telling the operator the computed value
was clamped and that `N*floor` may still exceed the budget (in which case
reducing `N` via `TEST_PARALLEL_N` is the documented next step) — never a
silent, unexplained slowdown.

**Why three separate env knobs (`TEST_MAX_CONNECTIONS`,
`TEST_CONNECTION_HEADROOM`, `TEST_MIN_POOL_SIZE`) instead of one.** Each
answers a different question a future operator might need to override
independently: what the actual Postgres ceiling is (varies by host/container
config), how much of it to reserve for non-partition connections (a `psql`
session, LiveDashboard, `iex -S mix` left open), and how low intra-partition
concurrency is allowed to go before it's not worth running that partition at
all. Collapsing them into one number would force every override to
re-derive the other two from scratch.

**Verification.** With this host's real numbers (`N`=16, `max_connections`
=100, default `headroom`=10): `budget` = 90, `computed` = 90/16 = 5,
`TEST_POOL_SIZE`=5 (no clamp needed), `N*pool_size` = 80 ≤ 90. Confirmed by
running `scripts/test_parallel.sh` for real post-fix — see the run's own
handoff/PR for the quoted output.

## What this does not change

- `config/dev.exs`'s pool sizing (unaffected; `TEST_POOL_SIZE` is read only
  in `config/test.exs`).
- The N-derivation logic itself (`nproc`/`getconf`/`TEST_PARALLEL_N`
  override) — untouched, per option (B) over (C) above.
- Postgres's actual `max_connections` setting in `docker-compose` — not
  raised here; `TEST_MAX_CONNECTIONS` lets an operator tell this script
  about a raised ceiling if one is made later, but making that change is
  out of this issue's scope.

## Addendum (2026-08-23, ISS-0287) — superuser-reserved and non-pooled-connection
   headroom

ISS-0287 (queue task 287, GH#569): even with N=4 (ISS-0219's documented remedy for
this project's own dev hosts), a same-day full-suite run hit a mid-run,
timing-dependent `too_many_connections`/`DBConnection.ConnectionError` failure —
distinct from ISS-0194 (the original quadratic-scaling defect this decision fixes)
and from ISS-0222 (the launch-time spike noted in the script's own comments).

Root cause: the Decision above's `budget = TEST_MAX_CONNECTIONS -
TEST_CONNECTION_HEADROOM` formula treats TEST_MAX_CONNECTIONS as the full usable
ceiling. It is not: Postgres reserves `superuser_reserved_connections` (measured
live = 3 on this project's dev/test Postgres) off the top, unusable by the test
role's regular connections regardless of headroom — silently shrinking the
formula's effective margin by that amount. Separately, exactly one test in this
suite (`test/support/tenant_schema_reaper_test.exs`'s ISS-0110 liveness-guard test)
opens a real Postgrex connection outside `Letflow.Repo`'s Ecto pool entirely, so it
is invisible to the `N × TEST_POOL_SIZE` arithmetic — at most 1 concurrently,
confirmed by grep across `test/` for `Postgrex.start_link` finding no other
occurrence. Neither gap is a defect in the connections themselves: both are
deliberate and load-bearing for their own test's acceptance criteria (see
`lib/letflow/design/iss0287-connection-pool-headroom-fix.md` §1). The gap is that
the clamp formula never accounted for either quantity.

**This addendum does not reopen Option B vs. A/C/D above** — the clamp-not-hard-fail
shape stands; this only corrects two under-counted terms feeding its `budget`
computation.

Formula, extended (full derivation and per-knob rationale:
`lib/letflow/design/iss0287-connection-pool-headroom-fix.md` §2):

    usable_ceiling = TEST_MAX_CONNECTIONS − TEST_SUPERUSER_RESERVED   (default 3)
    budget         = usable_ceiling − TEST_CONNECTION_HEADROOM − TEST_NONPOOL_CONNECTION_RESERVE   (default 2)
    computed       = budget / N
    TEST_POOL_SIZE = computed, or TEST_MIN_POOL_SIZE if computed is smaller, with a WARN

Two new knobs, each answering a question distinct from the three this decision
already separates (deliberately not folded into `TEST_CONNECTION_HEADROOM`, whose
meaning — ad-hoc human/tooling connections — is unchanged):

- `TEST_SUPERUSER_RESERVED` (default 3): what Postgres itself reserves
  (`superuser_reserved_connections`), a server-config fact, not a test-suite fact.
- `TEST_NONPOOL_CONNECTION_RESERVE` (default 2): connections the test suite opens
  outside the Ecto pool, a test-suite-shape fact, not a server-config fact.

**Verification, at this decision's own documented remedy value (N=4).**
`usable_ceiling` = 100 − 3 = 97. `budget` = 97 − 10 − 2 = 85. `computed` = 85 / 4 =
21 (integer division). `TEST_POOL_SIZE` = 21 (no floor clamp: 21 > TEST_MIN_POOL_SIZE
default 2). `N × TEST_POOL_SIZE` = 84. Worst-case accounted demand — every
partition's pool simultaneously saturated (the AC1/AC4 scenario) plus the one
non-pooled connection actually observed — is 84 + 1 = 85, against a real usable
ceiling of 97: **12 connections of genuine slack**, not merely a looser-looking
number. Even under the pessimistic case of the *full* `TEST_NONPOOL_CONNECTION_RESERVE`
budget consumed (2, not just the 1 ever measured) plus the *full*
`TEST_CONNECTION_HEADROOM` ad-hoc budget consumed (10, an interactive `psql`/
LiveDashboard session concurrently open) at the same moment as full N×pool_size
saturation: 84 + 2 + 10 = 96 ≤ 97 — still inside the true ceiling by 1 connection,
which is the case this decision's own floor-and-WARN escape hatch (reduce
`TEST_PARALLEL_N`) exists for if a host needs more margin than that.

Compare to the pre-addendum formula at the same N=4: `budget` = 100 − 10 = 90,
`computed` = 90 / 4 = 22, `N × TEST_POOL_SIZE` = 88. Nominally 88 + 1 = 89 ≤ 100,
which looks safe under the (wrong) assumption that all 100 connections are usable
— but only 97 actually are, so the *effective* margin the operator believed was 10
(headroom) was actually 7 (headroom minus the unaccounted superuser reservation),
and shrinks further once the one non-pooled connection is drawn against it. That
narrowed, uncounted-for margin is what a timing coincidence between AC1/AC4's
saturation and the ISS-0110 test's connection could exhaust intermittently — this
addendum's fix is not a larger safety margin chosen because it "feels safer," it is
the same nominal margin now computed against the real ceiling.

Confirmed for N=16 (this decision's own original verification host) that the
addendum does not regress the general case: `usable_ceiling` = 97, `budget` = 97 −
10 − 2 = 85, `computed` = 85 / 16 = 5 (integer division) — identical to the
pre-addendum `computed` = 5 this decision already verified, so no behavior change
for that host's own documented case.

**What this addendum does not change.** `TEST_MIN_POOL_SIZE`'s meaning and default;
`TEST_CONNECTION_HEADROOM`'s meaning (still ad-hoc human/tooling connections only);
`N`-derivation; anything in `test/support/tenant_schema_reaper_test.exs` or
`test/letflow/engine_concurrency_test.exs` (both explicitly out of scope — see
`lib/letflow/design/iss0287-connection-pool-headroom-fix.md`'s own scope
statement).

## Addendum (2026-09-06, ISS-0515/ISS-0426) — a second non-pooled source: the
   isolated-partition self-check's nested `mix test` subprocess

ISS-0515 (`feature/WF03-ISS0515-20260906`) fixed a `tenant_template` build race by
adding one synchronous call, `Letflow.Test.TenantTemplate.ensure_template!()`, to
`test/test_helper.exs` — run unconditionally, before any test dispatches, in
**every** `mix test` invocation (see this file's own moduledoc and
`lib/letflow/design/iss0515-tenant-template-build-race-fix.md`). That fix was
independently re-verified correct (REVIEWER PASS,
`handoffs/WF03-ISS0515-20260906/step-04-reviewer.json`) and passed local review,
but its PR (#1033) then failed CI with a NEW `too_many_connections` failure not
present before — isolated to exactly one test:
`Letflow.Engine.Lua.ExecutorTest`'s ISS-0426 partition self-check
(`test/letflow/engine/lua/executor_test.exs:1432`), which spawns a **nested**
`mix test --only lua_wallclock_race ...` subprocess via `System.cmd/3` to prove
that isolated partition still passes.

Root cause: that nested subprocess is a genuinely separate OS process / BEAM VM.
Before ISS-0515, it never touched `Letflow.Test.TenantTemplate` at all (the 11
`:lua_wallclock_race`-tagged tests don't use a tenant fixture — see this test
module's own moduledoc, "INV-LSA-1 / INV-LSA-2 paths short-circuit before any
Repo insert"). After ISS-0515, `test_helper.exs`'s unconditional pre-build call
now also runs inside that nested subprocess — and because `:persistent_term` is
per-BEAM-VM, `template_ready?/0` (which only reads `:persistent_term`) is `false`
there even though the template schema already physically exists in Postgres
(built moments earlier by the parent process), forcing the nested subprocess down
the advisory-lock-check path. That is a small, bounded query cost by itself —
but the bigger and actually decisive cost is structural, not query-count: left
unconfigured, that nested subprocess's own `Application` start sizes its own
`Letflow.Repo` Ecto pool from `TEST_POOL_SIZE`, which it inherits from whichever
`scripts/test_parallel.sh` partition spawned it (`System.cmd/3`'s `:env` option
ADDS to the inherited environment; it does not replace it). That means the
nested subprocess opened an entire EXTRA sibling-partition-sized pool of live
Postgres connections — on top of its parent partition's own pool, which stays
open/idle (not closed) for the whole time the parent test blocks on
`System.cmd/3` — landing exactly when CI's connection budget was already fully
booked by this decision's `N * TEST_POOL_SIZE` arithmetic, which has no term for
an (N+1)th, unplanned pool.

**This addendum does not reopen the ISS-0287 addendum's two-knob split, and does
not change `ensure_template!/0` or the ISS-0515 `test_helper.exs` mechanism
itself** — both are correct and out of scope here; this is purely a
connection-budget-accounting follow-up to a fix that was otherwise right.

**Fix, at the one call site that creates the extra process (not in this
script or in `ensure_template!/0`):** `executor_test.exs`'s `System.cmd/3` call
first passed `env: [{"TEST_POOL_SIZE", "1"}]`, capping the nested subprocess to
a single-connection pool, on the reasoning that (per the module's own
moduledoc note above) neither the pre-build check nor the 11 tests need
concurrent DB access. **That first attempt was itself wrong and CI caught it**:
PR #1033's next CI run failed with a *different*, related error —
`DBConnection.ConnectionError: ... queued and checked out the connection for
longer than 15000ms` — from inside that same nested subprocess. The module's
own `async: true` (line 11) means the nested subprocess's `test_helper.exs`
pre-build calls (`sweep_orphans/0`, `sweep_service_catalog_orphans/1`,
`ensure_template!/0`) and Ecto's Sandbox/DBConnection checkout+checkin
machinery can transiently need a second connection concurrently with the
first even though the 11 tagged tests never touch the DB themselves (e.g. an
asynchronous `on_exit` checkin from one caller overlapping the next caller's
checkout) — a pool of exactly 1 gives DBConnection's checkout queue nowhere to
put that second, genuinely concurrent request, so it queues past the 15s
default and the subprocess dies. The call now passes
`env: [{"TEST_POOL_SIZE", "4"}]` instead: still a small, fixed cap — nowhere
near an uncapped sibling-partition-sized pool (`schedulers_online()*2`,
typically 8–32) — but wide enough to absorb that kind of transient overlap
across the 11 sequentially-dispatched tests in this one module.

`TEST_NONPOOL_CONNECTION_RESERVE`'s default is bumped from 3 to 5 in
`scripts/test_parallel.sh`, to reserve room for both named non-pooled sources
at their own worst case at once: the ISS-0287 reaper-test connection (at most
1 concurrently) plus this nested-subprocess pool (up to 4 concurrently, by the
`TEST_POOL_SIZE=4` cap above) = 5. They don't overlap in practice (different
tests, and the nested subprocess runs a single time near the end of one
partition's own run), but the reserve is sized for the case where they do, not
the common case.

**Verification, at N=4 (this decision's documented remedy value), with the new
default:** `usable_ceiling` = 100 − 3 = 97 (unchanged). `budget` = 97 − 10 − 5 =
82 (nonpool_reserve now 5, was 84 before this follow-up). `computed` = 82 / 4 =
20 (integer division; down from 21 under the prior nonpool_reserve=3, since the
reserve grew by 2). `N × TEST_POOL_SIZE` = 80. Worst case — full N-partition
saturation (80) + the ISS-0287 connection (1) + this addendum's capped nested
pool (4) + full ad-hoc headroom (10) = 95 ≤ 97: still inside the true ceiling,
with a 2-connection margin (slightly wider than the ISS-0287 addendum's own
1-connection pessimistic-case margin), now correctly covering the nested
subprocess's actual 4-connection worst case instead of its previously
undersized 1-connection cap.

**What this addendum does not change.** `TEST_SUPERUSER_RESERVED`'s meaning and
default; `TEST_CONNECTION_HEADROOM`'s meaning; `TEST_MIN_POOL_SIZE`'s meaning and
default; `N`-derivation; the ISS-0515 `test_helper.exs` pre-build mechanism
itself (correct, unmodified); `Letflow.Test.TenantTemplate.ensure_template!/0`'s
own logic (correct, unmodified) — this addendum only (a) caps one test's own
nested-subprocess pool size at its own call site (now at 4, not 1), and (b)
updates this script's connection-budget accounting to reserve room for that
corrected cost.

## Addendum (2026-09-06, ISS-0515 third rework) — raise the server-side
   ceiling instead of reslicing it again

PR #1033 failed CI a **third** time, with the identical failure signature as
the second failure this file's own ISS-0515 addendum above describes fixing:
a `DBConnection.ConnectionError` client timing out at exactly 15000ms, stack
rooted in `:prim_inet.recv0/3` (a raw TCP-level socket-receive — i.e. a
stalled connection *establishment* attempt, not a wait for an already-open
pool slot to free up), from the same ISS-0426 nested-subprocess self-check.

The two prior attempts each reslice the **same** 100-connection server-side
budget differently: `TEST_POOL_SIZE=1` (rework 1) then `TEST_POOL_SIZE=4` with
`TEST_NONPOOL_CONNECTION_RESERVE` bumped 3→5 (rework 2, this file's addendum
directly above). Both hit the *exact same* failure signature — same timeout
duration, same client identifier, same stack location. Two different internal
splits producing an identical symptom is evidence against "the split is
wrong" and for "the thing being split is itself too small": Postgres's own
`max_connections=100` ceiling is plausibly near-exhausted at that moment in a
real CI run by the outer N partitions' own legitimate concurrent connection
usage, independent of anything this script's arithmetic controls. A third
reslice of an already-thin 100-connection budget was judged unlikely to
change that outcome.

**Fix: raise the actual server-side ceiling, not the internal split.**
`.github/workflows/ci.yml`'s `services.postgres` block now sets
`command: postgres -c max_connections=200`, using GitHub Actions' native
`services.<id>.command` key (added to the runner in 2026-04, Linux-runner-only
— `ubuntu-latest` qualifies) to override the official `postgres:16` image's
default `CMD` and pass a real `postgresql.conf` override as the server's own
argv (confirmed via GitHub's "About service containers" docs and the
`docker-entrypoint.sh` behavior of the official image: a `command:` beginning
with `postgres` is treated as the server process's own flags, not a
`docker create`/`docker run` flag — that's what the pre-existing, unrelated
`options:` key is for). This doubles the real ceiling from 100 to 200.

The "Run backend gate" step also now sets `TEST_MAX_CONNECTIONS=200` (an
env var `scripts/test_parallel.sh` already reads, previously only ever
exercised at its own default of 100 in CI) so this script's own budget
arithmetic recomputes against the real, raised ceiling rather than silently
leaving the extra 100 connections of headroom unused while still computing
`TEST_POOL_SIZE` as if the ceiling were still 100.

**The prior reworks' internal tuning is left in place, unchanged, as an
additive safety margin — not reverted.** `TEST_POOL_SIZE=4` for the ISS-0426
nested subprocess and `TEST_NONPOOL_CONNECTION_RESERVE`'s default of 5 were
never *wrong*; they were insufficient *alone* against a genuinely
near-exhausted 100-connection ceiling. Both values are still individually
reasoned and correct, and now sit inside a budget twice the size, so their
existing margin is only more comfortable, not made moot or contradictory.
Nothing about reverting them would improve safety, and reverting would
reintroduce dependence on a single un-doubled fix path if the 200-connection
raise alone still proves marginal.

**Verification at `max_connections=200`, `TEST_MAX_CONNECTIONS=200`, N=4
(other defaults unchanged):** `usable_ceiling` = 200 − 3 = 197. `budget` =
197 − 10 − 5 = 182. `computed` = 182 / 4 = 45 (up from 20 at the
100-connection ceiling — the outer partitions now get a much larger own pool
too, not just more slack for the nested subprocess). `N × TEST_POOL_SIZE` =
180. Worst case — full N-partition saturation (180) + the ISS-0287 connection
(1) + the ISS-0426 nested subprocess's capped pool (4) + full ad-hoc headroom
(10) = 195 ≤ 197: holds, with the same 2-connection margin as before
(unchanged relative proportions — the fix doubles the numerator and
denominator alike — but now against a ceiling with 100 more absolute
connections of real slack for the outer partitions' own transient
concurrent-connection spikes, which is the actual, previously-unaddressed
constraint this addendum targets).

**Why not the queue-timeout/retry fallback instead.** The task brief for this
rework offered two fallback directions if raising `max_connections` proved
infeasible in GitHub Actions' `services:` syntax: (a) lengthen the nested
subprocess's own Ecto `:queue_target`/`:queue_interval`, or retry the
`System.cmd/3` call once on transient failure; or (b) treat the pool-tuning
path as exhausted and escalate differently. Neither was needed:
`services.<id>.command` is genuinely supported (confirmed via GitHub's own
docs, not assumed), so the decisive fix — enlarging the actual scarce
resource — was available and was taken. A queue-timeout increase would have
masked the same underlying scarcity by making callers wait longer for a
connection that may still not arrive in time under real exhaustion, rather
than removing the exhaustion; a retry would have hidden a real, recurring
resource constraint behind non-determinism (sometimes green on retry,
sometimes not) instead of fixing it. Both remain reasonable to revisit as a
belt-and-suspenders addition if `max_connections=200` also proves marginal,
but are not needed as the primary fix now that the real ceiling could be
raised directly.

**What this addendum does not change.** `TEST_POOL_SIZE=4` for the ISS-0426
nested subprocess; `TEST_NONPOOL_CONNECTION_RESERVE`'s default of 5;
`TEST_SUPERUSER_RESERVED`, `TEST_CONNECTION_HEADROOM`, `TEST_MIN_POOL_SIZE`'s
meanings and defaults; `N`-derivation; the ISS-0515 `test_helper.exs`
pre-build mechanism; `Letflow.Test.TenantTemplate.ensure_template!/0`'s own
logic — all correct and unmodified. This addendum only (a) raises the actual
Postgres server's `max_connections` in CI via `services.postgres.command`,
and (b) sets `TEST_MAX_CONNECTIONS=200` in the same CI step so this script's
arithmetic uses the real, raised ceiling instead of continuing to compute
against the old, unchanged 100 default while the real server allows more.

**UPDATE (2026-09-06, fourth rework): the third rework's fix above did NOT
work, and has been reverted — see the addendum below.**

## Addendum (2026-09-06, ISS-0515 fourth rework) — the `services.command`
   ceiling raise was disproven by live CI evidence; fix the actual root
   cause instead

PR #1033 failed CI a **fourth** time, with the identical
`DBConnection.ConnectionError` signature as all three prior failures, despite
the third rework's `max_connections=200` override supposedly doubling the
server-side ceiling. This time the CI run's own Postgres container logs were
inspected directly, and they settle the question conclusively:

- `FATAL: sorry, too many clients already` — repeated many times in the
  Postgres container's log for this run, confirming the server was still
  being driven into real connection exhaustion.
- `selecting default max_connections ... 100` — from the SAME container's own
  `initdb` bootstrap log, i.e. the server itself started at the untouched
  default of 100, not 200.

This is direct, live evidence that `command: postgres -c
max_connections=200` did **not** take effect at the server level in this
actual runner/image invocation, despite REVIEWER independently confirming
from GitHub's own documentation (in the third rework) that the
`services.<id>.command` YAML key is real, is Linux-runner-supported, and
should — per that documentation — have worked exactly this way. Two
independent, correctly-cited sources being right about the mechanism's
existence does not guarantee the mechanism actually fires in every runner
image/version combination; something about this specific invocation (a YAML
subtlety, a runner-version gap, or a precedence issue with an implicit
default `CMD`/entrypoint winning over the declared `command:`) prevented the
override from reaching the running `postgres` process. The exact mechanism
was NOT conclusively identified — ORCH made the deliberate call to stop
debugging `services.command` itself after four consecutive identical
failures and pursue a different, locally-verifiable fix instead, rather than
spend a fifth rework chasing the same non-working lever.

**This addendum records the disproven attempt rather than deleting it**, so
a future session facing the same `too many clients` symptom does not
re-attempt `services.postgres.command` expecting a different result without
first understanding why it failed here.

**Fix actually taken: eliminate the nested subprocess's need for the
connection budget entirely, rather than continuing to try to enlarge or
reslice it.** `.github/workflows/ci.yml`'s `services.postgres.command` key
and the "Run backend gate" step's `TEST_MAX_CONNECTIONS: "200"` env var have
both been **removed** (reverted to the pre-third-rework state), since live
evidence shows the override never actually changed server behavior and
leaving it in place would misleadingly document a mechanism as working when
it demonstrably was not in this environment.

Root-cause re-examination: the actual, avoidable cost every prior rework
worked around rather than removed was `test/test_helper.exs`'s unconditional
`Letflow.Test.TenantTemplate.ensure_template!()` call running a second time
inside executor_test.exs's ISS-0426 nested `mix test --only
lua_wallclock_race` subprocess (see this file's first ISS-0515 addendum
above for the original root-cause writeup). That subprocess's own 11 tagged
tests are, by this test module's own moduledoc, guaranteed DB-access-free —
they have no tenant-fixture dependency for `ensure_template!/0` to protect in
the first place — and the tenant_template schema it builds was, by
construction, ALREADY built by the enclosing partition's own test_helper.exs
run before this nested test process could even exist (the nested subprocess
only re-attempts the advisory-lock-check path because its own fresh
`:persistent_term` cache is per-BEAM-VM and starts empty). Every prior
rework treated the resulting extra connection pressure as a budget-sizing
problem to be resolved with a bigger or better-sliced pool; this rework
instead removes the unnecessary work generating that pressure.

`test/letflow/engine/lua/executor_test.exs`'s `System.cmd/3` call (the one
spawning the nested subprocess) now also passes
`env: [{"LETFLOW_SKIP_TENANT_TEMPLATE_PREBUILD", "1"}]` alongside the
existing `{"TEST_POOL_SIZE", "4"}`. `test/test_helper.exs` checks this env
var and skips its `ensure_template!()` call when set — an explicitly narrow,
one-call-site escape hatch (not a general opt-out; every other invocation
shape this project uses — plain `mix test`, `mix test <path>`,
`scripts/test_parallel.sh` partitions, `mix letflow.check.test` — is
unaffected and still runs the pre-build unconditionally, per this file's
original design §7 reasoning).

**Why `TEST_POOL_SIZE=4` is left unchanged, not reduced further or removed.**
`test/test_helper.exs`'s `sweep_orphans/0` and
`sweep_service_catalog_orphans/1` calls remain unconditional regardless of
this new flag — they still open real `Letflow.Repo` checkouts inside the
nested subprocess. Skipping `ensure_template!/0` removes the heaviest,
advisory-lock-contending DB path from that subprocess, not all DB access
from it, so a zero-size or removed pool is not safe here. `TEST_POOL_SIZE=4`
was never wrong for the residual load these two sweep calls plus Ecto
Sandbox/DBConnection checkout+checkin overlap can still transiently need
(per the second addendum above); it remains correct and is kept as-is.

**Verification (this rework, own output):**
- `mix compile --warnings-as-errors`: clean.
- `mix format --check-formatted`: clean.
- `mix test test/letflow/engine/lua/executor_test.exs` (run twice locally):
  the ISS-0426 self-check test passed both times, confirming the nested
  subprocess still reports `Result: 11 passed` with the pre-build skipped —
  the skip logic itself is correct and does not affect the 11 tagged tests'
  own pass/fail outcome (consistent with their documented DB-independence).
- `mix test test/support/tenant_template_test.exs`: passed, confirming the
  original ISS-0515 mechanism — still used unconditionally by every OTHER
  invocation shape — is untouched by this change.
- As with every prior rework, the original CI-only connection-scarcity
  failure does not reproduce in this local sandbox (more headroom than a
  busy CI runner); this fix's correctness rests on removing a demonstrably
  unnecessary DB-touching call from the nested subprocess, not on a local
  repro of the exhaustion.

**What this addendum does not change.** `TEST_POOL_SIZE=4` for the nested
subprocess; `TEST_NONPOOL_CONNECTION_RESERVE`'s default of 5;
`TEST_SUPERUSER_RESERVED`, `TEST_CONNECTION_HEADROOM`, `TEST_MIN_POOL_SIZE`'s
meanings and defaults; `N`-derivation; `Letflow.Test.TenantTemplate
.ensure_template!/0`'s own logic (correct, unmodified — it is skipped at one
call site, not changed); the ISS-0515 `test_helper.exs` pre-build mechanism
for every other invocation shape. This addendum (a) reverts the third
rework's `services.postgres.command`/`TEST_MAX_CONNECTIONS=200` CI change,
recording why with live evidence, and (b) adds a narrowly-scoped
`LETFLOW_SKIP_TENANT_TEMPLATE_PREBUILD` env-var escape hatch used by exactly
one call site (the ISS-0426 nested subprocess) to remove its one avoidable
source of real DB connection pressure.

## Addendum (2026-09-28, ISS-0287 reopened again — N-scaling gap) —
   instrumentation-first response; decision (B)'s rejection of Option (C)
   upheld, no ceiling added

ISS-0287 reopened a second time (2026-08-28, TEST-RUNNER, WF02-REQ165-20260828):
the same `too_many_connections`/`DBConnection.ConnectionError` signature as the
original ISS-0287 fix reproduced 1-of-3 consecutive `scripts/test_parallel.sh`
runs, this time at N=8 (auto-derived from `nproc` on that host), a value the
formula's own regression test had never covered (only N=4 and N=16 were
checked). See `lib/letflow/design/iss0287-pool-headroom-n-scaling.md` for the
full design (CODE-DESIGN-VALIDATOR-PASSed) this addendum records the outcome of.

**This reopening's own hypothesis was checked and disproven, not assumed.**
The reopening's own stated theory — that each of the N partitions
independently runs a copy of `tenant_schema_reaper_test.exs`'s ISS-0110 guard
test, so the non-pooled-connection reserve should scale with N — is false as
literally stated: `mix test --partitions N` (Mix's own source,
`filter_by_partition/3`) assigns whole test **files**, not individual tests,
to exactly one partition each, so that file (and the nested ISS-0426
subprocess, the suite's only other non-pooled source) can only ever be loaded
by one of the N partitions regardless of N. Multiplying
`TEST_NONPOOL_CONNECTION_RESERVE` by N would have reserved against a scenario
that structurally cannot occur.

**The formula's own worst-case arithmetic was also re-derived algebraically,
not just re-checked at a few points, and found NOT to degrade with N.** For
any fixed `budget` (N-independent), `computed_pool = ⌊budget / N⌋` satisfies
`N × computed_pool ≤ budget` for every positive integer N — the accounted
margin (`usable_ceiling − N×TEST_POOL_SIZE − nonpool_reserve − headroom`) is a
near-constant 2 connections at N=4, N=8, and N=16 alike under today's
defaults, not a margin that shrinks as N grows. The literal premise "the
reservation doesn't scale with N so it runs out at higher N" is not supported
by the formula's own arithmetic — see the design doc §2/§3 for the full
derivation.

**What plausibly does scale with N, per the design's §3.1, is something the
formula's four inputs cannot see at all: host oversubscription (more
concurrent BEAM VMs contending for the same core count) and a
birthday-paradox-shaped rise in the *observed* failure rate from running more
concurrent partitions, each an independent chance at a transient
one-connection overshoot — a timing effect, not an arithmetic one — plus,
orthogonally, the possibility that a given host's real `max_connections`
simply doesn't match the formula's assumed default at all.** None of these
three candidate mechanisms was proven by this design; §5's measurement plan
is designed to distinguish them empirically rather than guess.

**Decision: instrumentation-first, per the design's exact recommendation — no
N-ceiling added, decision (B) above (clamp `pool_size`, never reduce `N`)
stands, unchanged and un-reopened.** Three additions were made to
`scripts/test_parallel.sh`, all inert or opt-in at their shipped defaults:

1. `TEST_PER_PARTITION_HEADROOM` (default 0): a new term in Step 1.5's
   formula, `budget = usable_ceiling − headroom − nonpool_reserve − (N ×
   per_partition_headroom)` — the structurally correct place for a margin
   that scales with concurrently-running-partition count, once §5's
   measurement produces a real, non-guessed value for it. Defaulting to 0
   (not a guessed positive number) is deliberate: `N × 0 = 0` reduces the
   formula to exactly today's behavior — verified directly, not merely
   argued, by diffing this script's pre- and post-change Step 1.5 output at
   N ∈ {1..32} with the knob unset; every value matched byte-for-byte.
2. A host Postgres ceiling verification step (before Step 1.5, ISS-0287
   §4.2): queries the live server's real `max_connections` and
   `superuser_reserved_connections` (via `psql`, if available) and WARNs —
   never hard-fails — on a mismatch against `TEST_MAX_CONNECTIONS`/
   `TEST_SUPERUSER_RESERVED`'s configured/default values. This addresses the
   third candidate mechanism above (an unverified, possibly wrong, ceiling
   assumption) directly, without touching the clamp arithmetic at all.
   Degrades silently-but-loudly (one WARN, script continues) when `psql`
   isn't installed or the DB isn't reachable — this is evidence-gathering,
   not a gate, and must never block a run that would otherwise pass.
3. `TEST_PARALLEL_SAMPLE_CONNECTIONS` (default unset/off): an opt-in
   `pg_stat_activity` connection-count sampler, polling once per second while
   partitions run and logging to the run's own tmp_dir, to gather the
   missing empirical evidence needed to distinguish the oversubscription/
   collision-probability mechanism from the ceiling-mismatch mechanism the
   next time this reopens. Zero cost unless explicitly enabled.

**Why not decision (C) (cap auto-derived N) this time either.** The design's
own §6 weighs this honestly rather than deferring: capping N would sidestep
exactly the oversubscription mechanism a headroom term structurally cannot
compensate for (it lives in OS/BEAM scheduling, not connection-count
arithmetic) — but decision (B) above already rejected reducing N once, on the
grounds that it throws away the parallelism REQ-113 was built to add, and
this reopening's own evidence does not yet show that a per-partition headroom
term (once measured) can't practically absorb the effect. Re-deciding (C) now
would be exactly the "silently re-decide a locked decision" anti-pattern
core-directives.md warns against — REQ-113's parallelism goal, and 0009's own
prior weighing of it, are still on record and still apply. If §5's
measurement later shows a per-partition headroom term would have to shrink
`TEST_POOL_SIZE` to uselessly small values at high N to compensate, that
would be new evidence changing the calculus 0009 already recorded, and
belongs as a formal addendum proposal to REVIEWER at that point — not a
unilateral implementation decision made here.

**What this addendum does not change.** Decision (B) itself (clamp
`pool_size`, never `N`); `TEST_MAX_CONNECTIONS`, `TEST_CONNECTION_HEADROOM`,
`TEST_MIN_POOL_SIZE`, `TEST_SUPERUSER_RESERVED`, or
`TEST_NONPOOL_CONNECTION_RESERVE`'s meanings or defaults; `N`-derivation;
anything under `test/support/tenant_schema_reaper_test.exs` or
`test/letflow/engine_concurrency_test.exs` (both out of scope per the design's
own scope statement). `TEST_PER_PARTITION_HEADROOM` ships at 0 — an operator
or a future addendum sets it nonzero only once §5's empirical runs produce a
measured value, not before.

**Verification (this addendum's own).** `test/scripts/test_parallel_pool_sizing_test.sh`
(the existing regression suite, unmodified) — 5/5 passing, unchanged from
before this change. (Historical: the suite was later removed as red on main by PR #2459, GH #2442; its coverage gap is tracked as GH #2460; the file is at commit a9af273a0.) Direct no-op check: extracted Step 1.5's arithmetic block
from the pre- and post-change script and `eval`'d both at N ∈ {1, 2, 3, 4, 5,
6, 7, 8, 9, 12, 16, 24, 32} with `TEST_PER_PARTITION_HEADROOM` unset — every
`TEST_POOL_SIZE` output matched exactly (e.g. N=8: 10 both before and after).
Confirmed the new knob is not dead code: at `TEST_PER_PARTITION_HEADROOM=1`,
N=4/8/16 compute `TEST_POOL_SIZE`=19/9/4 respectively (down from 20/10/5),
matching `budget − N` exactly at each N. A full `scripts/test_parallel.sh`
run (N=2, real Postgres, real test files) confirmed the host-ceiling-check
and sampler-gating additions don't break a real invocation: the script ran
Step 1.4 (WARNed and continued, since this verification host has no `psql`
installed), computed `TEST_POOL_SIZE` correctly, and one real partition ran
its real tests to completion (4/4 passed).
TEST-DESIGNER extends the regression test with the N-sweep and dedicated N=8
case the design's §5 calls for, and runs the empirical N=8/`TEST_PARALLEL_N`-unset
verification passes against a real host — not repeated here.

## Addendum (2026-10-16, GH #2630) -- hosted-CI shards exceeded `max_connections`: nested app-starting children, reserve 5 -> 16

**Symptom.** Backend shard legs intermittently failed with `FATAL 53300 (too_many_connections)` /
`sorry, too many clients already` (design: `lib/letflow/design/gh2630-ci-pg-connection-ceiling.md`).

**Measured facts** (hosted CI run 38764249729; each leg has its own Postgres container):

| Quantity | Value |
|---|---|
| `max_connections` / `superuser_reserved_connections` | 100 / 3; the CI role is a superuser, so the usable ceiling was 100 |
| Computed `TEST_POOL_SIZE` (N=4, headroom 10, reserve 5) | 20, i.e. 80 pooled connections per shard |
| Shard 1 peak | four partitions at 19-20 each (~77) PLUS a fifth `mix` process (pid 27329) holding 19 idle connections: ~96 pool connections + ~5 active + 4 non-client background rows; client backends reached ~101 > 100; 132 refused sampler connects and 153 server FATALs in one sustained window |
| Shard 2 peak | three partitions at 19 and one process holding 30 (10 beyond its 20-pool, same BEAM) |
| Shard 3 peak | 88 |

**Cause (hypothesis b', consistent with the table).** `test/mix/tasks/letflow.login_directory_tasks_test.exs`
(`key_status`, `retire_key`) and `letflow.migrate_tenant_admins_test.exs` spawn `mix` children with
`System.cmd/3`; each child runs `app.start`, and `config/test.exs` sizes its `Letflow.Repo` pool from the inherited
`TEST_POOL_SIZE=20`. Four partitions at 20 plus one such child at 20 is already at the ceiling. The earlier
reserve of 5 was sized for one reaper connection plus the 4-slot `executor_test.exs` child (ISS-0287/ISS-0515);
the ISS-0287 addendum's "one file, one partition" argument does not cover three different files each spawning
a child. Children of `mix run --no-start` / `mix compile` open no pool and are unchanged.

**Change (F2 + F4, no retry, no skip).**
- F2: `Letflow.Test.NestedMix.cmd/3` (`test/support/nested_mix.ex`) forces `TEST_POOL_SIZE=4` for test-spawned
  children that start the app; the two task tests use it and `executor_test.exs` reads the same constant.
- F4: `TEST_NONPOOL_CONNECTION_RESERVE: 16` in `.github/workflows/ci.yml`'s "Run test shard" step env (not the
  script default: the default stays 5 so local runs and every other caller are untouched). 16 = 4 partitions x
  the 4-slot child cap, the worst case of one child per partition at once.

**Arithmetic.** `usable = 100 - 3 = 97`; `budget = 97 - 10 (headroom) - 16 = 71`; `TEST_POOL_SIZE = floor(71/4) = 17`.
Worst case at once: 4 x 17 pool + 4 x 4 children + 2 external (probe, Postgres tune) = 86 of 97, a spare of 11.
(Before: 80 + one uncapped child of 20 = 100, with no spare, measured above to overshoot.)
Pinned by `test/scripts/test_parallel_pool_clamp_test.exs` and `test/letflow/nested_mix_test.exs`.

**Not claimed.** Raising `max_connections` is NOT claimed to work here. The "tried and reverted" history in
`ci.yml` stands: its cited evidence (the `initdb` line `selecting default max_connections ... 100`) is printed before
the server starts with its arguments and so does not show the flag was ignored, but no `SHOW max_connections`
read-back ever proved it either way; both remain unproven. Also unverified until a CI run: that three consecutive
runs show zero `53300` (the design's section 4 evidence plan), and the peak connection count after the change.
