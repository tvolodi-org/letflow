# Anti-patterns — Letflow

Known mistakes and their correct alternative, logged as they're found.
Read this before doing anything non-trivial (see `CLAUDE.md`). Empty
sections are expected early on — this grows with the project.

Format per entry: what happened, why it's wrong for this project
specifically, the correct alternative.

<!-- Example shape, remove once the first real entry lands:

## Reporting `mix test` as passing without running it

An agent said "the property test should now cover the new transition"
without actually running `mix test`. This violates the No Speculation
rule in `CLAUDE.md` and defeats the point of the property test, which
exists specifically to catch cases a human wouldn't think to assert by
hand (README §4).

**Correct alternative:** run `mix test`, quote the actual output. If
the environment can't run it (no toolchain, no network for
`mix deps.get`), say that explicitly instead.
-->

## No Elixir/mix toolchain on PATH in this sandbox

**SUPERSEDED 2026-08-19 on this host — CHECK BEFORE ASSUMING.** A local
toolchain IS installed and on disk: `/c/Program Files/Elixir/bin/mix`,
Mix 1.20.3 (compiled with Erlang/OTP 29). Verified this session by running
`mix compile --force` directly (`Generated letflow app`, 0 errors). Bare
`mix` may not be on `PATH` in every shell — invoke it by full path,
quoted, rather than concluding it is absent. **Run
`ls "/c/Program Files/Elixir/bin/mix"` before reporting "no toolchain";
this entry itself went stale and was believed for multiple runs.** The
Docker route below remains valid as a fallback (and is still the way to get
a real Postgres for `mix ecto.*` / integration tests), but it is no longer
the first resort for `mix compile` / `mix format` / unit-level `mix test`.

Original entry, kept for the Docker recipe:

Agents repeatedly discover (correctly, per the No Speculation rule)
that there's no local Elixir/mix toolchain, and stop at "can't verify."
There's a working alternative: Docker is available. Run a throwaway
`elixir:1.17-otp-27` container plus an isolated `postgres:16` container
on a private Docker network (`docker network create`, then both
containers `--network` onto it, referencing Postgres by container name
as the DB hostname rather than `localhost`). This sidesteps host port
5462 too, which may already be held by another local Postgres
container — don't touch a container that isn't yours.
Mount the repo read-write into the Elixir container
(`-v //c/...:/app -w /app`), run `mix local.hex --force` /
`mix local.rebar --force` once, then `mix deps.get` / `mix compile` /
`mix ecto.create` / `mix ecto.migrate` / `mix test` as `docker exec`
calls. Tear down both containers and the network afterward. On
Windows/Git Bash, bare `/app`-style paths get mangled by MSYS path
conversion — prefix affected `docker run`/`docker exec` calls with
`MSYS_NO_PATHCONV=1`. If `config/test.exs` hardcodes `localhost:5462`,
temporarily change it to read `System.get_env("LETFLOW_DB_HOST",
"localhost")` / a port env var with the same fallback, run the
verification, then revert the config file back to its committed
contents afterward — don't leave the env-var indirection in a tracked
file for a one-off verification run.

**Correct alternative:** try Docker-based verification before reporting
"can't run it" as final — it worked cleanly for REQ-001 (12/12 tests,
including a StreamData property test, against a real Postgres).

## Overwriting `docs/status/requirement_status.yaml` instead of appending

An agent (ELIXIR-DEV, REQ-003) found the file didn't match its
expectations and rewrote it from scratch with a different header
format and field names (`requirement`/`timestamp_utc` instead of the
established `req`/`at`), silently discarding every prior history entry
(REQ-001, REQ-002). The file's own header comment says "Append one
entry per event. Never rewrite past entries" — this is exactly the
mistake that comment exists to prevent. ORCH caught it by diffing
against what it had just written and restored the lost entries.

**Correct alternative:** start at `docs/status/requirement_status.index.yaml`, read the
**current volume** it names in full — volumes are capped, at the ceilings the index's
`roll_rule:` records, precisely so that read is possible — preserve its established
schema even if a different shape seems cleaner, and append (never replace). Confirm with
`git diff --numstat` that the deletions count for the file is 0. Never edit a closed
volume. If the file is genuinely missing, use the header/entry shape documented in the
index and the current volume's own header, not an invented one.

## Issuing the clock read and the timestamped write as ONE shell command (ORCH)

**Found 2026-08-21, twice inside four minutes, during WF03-ISS0204-20260821's own run
closure — the run that had just finished documenting this exact class.** ORCH wrote its
`RUN_DONE` line as a single command of the shape:

```bash
date -u +"%Y-%m-%dT%H:%M:%SZ" && cat >> handoffs/orchestrator.log <<'EOF'
2026-08-21T10:29:40Z | RUN_DONE | ...
EOF
```

The clock read is *in* the command, so it looks measured. It is not: the literal
`10:29:40Z` had to be composed before the command ran, and the real reading came back
`10:29:12Z` — 28s fast. The correction line appended to fix it was issued the same way
and was 55s fast. **The defect is structural, not a lapse of care.** Batching the two
makes an extrapolated stamp *unavoidable* regardless of how carefully the writer is
trying to follow the entry below; the `date` output is only ever visible after the write
it was supposed to inform.

**Why this is easy to miss:** the command *contains* a real clock read, and its output
is right there in the transcript. Nothing looks wrong — it reads as measure-then-write,
and the two values are close enough that the discrepancy is invisible unless someone
compares them line by line. This is the same "wrong in a way the output string does not
reveal" shape as the `.ToUniversalTime()` hazard and the entry below, arriving through a
different door: not memory, not rounding, but *ordering inside a single tool call*.

**Correct alternative:** read the clock in its **own** tool call, let the value come
back, then write the line in a **second** call using the value returned. Never put
`date -u` and the write that consumes its output in one command — not with `&&`, not
with `;`, not in the same heredoc. If a stamp has already been committed wrong, correct
it by **appending**, never by editing (the log is append-only), and name the mechanism
rather than only the number, so the next reader fixes the cause and not the symptom.

## Extrapolating handoff timestamps instead of reading the clock (ORCH)

During REQ-023's WF-02 run, ORCH stamped each dispatched handoff's
`created_at`/`started_at` by *estimating* a plausible time from the
run's earlier entries rather than running `date -u` for each one. The
estimates crept steadily ahead of the real clock — by the eleventh
handoff (`step-06-doc-updater.json`) they were ~23 minutes fast. That
made the handoff's `completed_at` (correctly clock-read by
DOC-UPDATER as `18:49:40Z`) *precede* its own `started_at`
(`19:08:00Z`), which is exactly the corruption
`docs/agents/shared/HANDOFF_PROTOCOL.md` §3 forbids and
`core-directives.md`'s "Bookkeeping Is Not Optional" section exists to
prevent.

Why this is worth its own entry even though the fix is one command:
the failure is silent and cumulative. Each individual estimate looked
reasonable next to the previous one, nothing in the file's appearance
revealed the drift, and a mechanical check across all eleven handoffs
found ten of them internally consistent — so the error was invisible
right up until it produced an impossible ordering. It was caught only
because DOC-UPDATER read the real clock, noticed the contradiction with
the `started_at` it had been handed, and *reported it instead of
quietly writing a later `completed_at`* to make the file look tidy.
That is the producer/validator principle working on ORCH's own
bookkeeping, and it only worked because the agent refused to smooth
over an inconsistency it had not caused.

Note this is the same shape as the existing `.ToUniversalTime()`
warning in `core-directives.md` — a timestamp that is wrong in a way
the output string does not reveal. Anything a later reader would use to
reconstruct sequence (handoff stamps, `requirement_status.yaml` events,
`orchestrator.log` lines) has to come from the clock, because nothing
downstream can detect that it didn't.

**Correct alternative:** run the clock command immediately before
writing each timestamp, every time — never derive one from another
entry, never round a previous value forward, and never batch-generate
several stamps from a single reading:

```bash
date -u +"%Y-%m-%dT%H:%M:%SZ"
```
```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```

If a bad timestamp has already been committed, correct it *and* record
that it was a reconstruction rather than a measurement (see
`handoffs/WF02-REQ023-20260816/step-06-doc-updater.json`'s
`orch_timestamp_correction` field for the shape) — a silently corrected
timestamp is indistinguishable from one that was right all along, which
defeats the audit trail the correction is meant to preserve.

## Task-selection fallback duplicating a run (ORCH)

On 2026-08-19, two separate ORCH sessions both selected REQ-048 as "the
next eligible requirement" and independently ran full WF-02 pipelines
for it. `docs/agents/protocols/TASK_QUEUE.md` at the time explicitly
permitted this: if `letflow-queue` was unreachable or
`$QUEUE_AUTH_TOKEN` wasn't set, ORCH was allowed to fall back to
reading `docs/requirements.yaml` directly and picking the first
`pending` requirement with satisfied `depends_on` — reasoned to be safe
in a "single-host session with no multi-host risk." That reasoning was
the bug: a session cannot actually verify it's the only host running
Letflow agents, so "no multi-host risk" was an assumption, not a fact.
One session's fallback-mode run finished and merged REQ-048
(`WF02-REQ048-20260818`, PR #204) while a second session, also lacking
`$QUEUE_AUTH_TOKEN`, independently fell back and dispatched a second
full WF-02 run for the same requirement
(`WF02-REQ048-20260819`). The duplicate was caught only because Step
00's `git pull --ff-only` happened to surface the already-merged
work before any real implementation started — a later-arriving
conflict, not a structural guarantee. `letflow-queue` exists
specifically to make this kind of claim atomic across hosts; a
fallback path that reintroduces unarbitrated file reads defeats that
guarantee exactly in the case it matters most (multiple hosts active
at once, none aware of the others).

**Correct alternative:** fallback selection is now forbidden outright
(`TASK_QUEUE.md`'s Hard Rule, `ORCHESTRATOR.md` §1,
`core-directives.md`'s "No Agent Discretion Over Task Selection"
section). If `letflow-queue` is unreachable, ORCH reports
`no_eligible_task (queue unreachable)` and stops rather than reading
`docs/requirements.yaml` to pick unscoped work itself — even when the
session appears to be the only one running. A specific `REQ-XXX` named
directly by the user remains fine to work on without the queue (the
human made the selection, not ORCH), but ORCH should still attempt to
register/lock it against the queue once reachable.

**Addendum, same day:** the queue was likely never actually unreachable
for either session. `QUEUE_AUTH_TOKEN` lives in two possible places —
the shell environment, and a `.env` file at the repo root (gitignored,
sanctioned local-dev convenience, confirmed with the project owner) —
and both duplicate-run sessions evidently checked only the former. A
live test the same day showed the `.env` token authenticating
successfully against `queue-test.ai-dala.com`. So the proximate cause
wasn't "the queue was down," it was "the check for the token was
incomplete" — `TASK_QUEUE.md` §"The four functions" now says explicitly
to check `.env` before concluding the token is unavailable. The
fallback-forbidden fix above is still correct defense in depth (a
*genuinely* unreachable queue should never trigger self-selection
either), but don't assume every future "queue unreachable" report is
real without first confirming `.env` was checked.

## Running `docker compose up` from a secondary worktree checkout

During WF02-REQ037-20260817's Step 3b (TEST-DESIGN-VALIDATOR, running from
`~/letflow-wt2`, a secondary git worktree), the agent ran `docker compose up`
in its own checkout directory to independently re-verify a test run,
despite an explicit standing instruction for this worktree (its own
session prompt, not this file) that Postgres is already running and
shared with the primary `~/letflow` checkout's container, and
`docker compose up` must never be run here. Because
`~/letflow-wt2/docker-compose.yml` declares the same host port (5462)
the primary checkout's container already holds, the new
`letflow-wt2-postgres-1` container started successfully (compose
doesn't always hard-fail on a port conflict — here it silently came up
with an *empty* port mapping, `{}`, meaning nothing on the host could
actually reach it) alongside an orphaned `letflow-wt2_letflow_pg`
volume and `letflow-wt2_default` network. The test run's own result
was unaffected (`config/test.exs` points at `localhost:5462`, which
only the pre-existing, correctly-configured container actually
publishes, so the tests transparently ran against the right database
regardless) — but the extra container/volume/network were pure waste,
and a small drift from this could plausibly have collided with the
primary checkout's own container state instead of silently no-op'ing.

Follow-up (2026-08-21): the shared-host-port half of this is now
fixable rather than only avoidable — `docker-compose.yml` publishes
`${LETFLOW_DB_PORT:-5462}` and `config/dev.exs`/`config/test.exs`
resolve the same variable through `config/db_port.exs`, so a checkout
that genuinely wants its own PostgreSQL sets `LETFLOW_DB_PORT` in an
untracked `.env` and gets a container and an Ecto config that agree.
This does *not* license running `docker compose up` in a checkout
instructed to share another one's container — the rule above stands;
it only removes the silent-empty-port-mapping failure mode for
checkouts that are supposed to have their own.

**Why this is easy to miss:** the agent's own verification (`mix test`
passing) gave no signal that anything was wrong — a docker-compose
port conflict silently producing an unreachable container is not the
kind of failure a downstream `mix test` PASS would ever surface.

**Correct alternative:** never run `docker compose up`/`up -d` from a
secondary worktree checkout — Postgres for that checkout is already
running via the primary checkout's `docker compose up`, sharing the
same server on a separate database (`MIX_TEST_PARTITION=N mix test`
selects the isolated per-checkout database, not a separate Postgres
server). If a docker-based re-verification is ever genuinely needed
from a secondary worktree, use `docker ps`/`docker inspect` to confirm
the existing shared container is healthy and reachable first, never
`docker compose up`.

## Duplicating an `Ecto.Query.fragment/1` SQL literal instead of sharing it via a module attribute

During REQ-042's `search/2` (`lib/letflow/definitions.ex`), ELIXIR-DEV needed the
same ranking `CASE WHEN ... END` SQL text in two places (`select_with_rank/3` and
`order_by_rank/3`) and first tried to share it via a helper function pinned into
`fragment/1` (`fragment(^rank_case_sql(), ...)`). Ecto rejects this at compile time
with `Ecto.Query.CompileError`: "to prevent SQL injection attacks, fragment(...)
does not allow strings to be interpolated as the first argument via the `^`
operator" -- `fragment/1`'s first argument must macro-expand to a literal binary
known at compile time (`Ecto.Query.Builder.expand_and_split_fragment/2` calls
`Macro.expand/2` and requires the result to already be a binary), not a runtime
value produced by calling a function. ELIXIR-DEV correctly concluded this was a
real Ecto constraint (not a workaround for a mistake) and fell back to duplicating
the literal verbatim in both functions, flagging it for REVIEWER.

REVIEWER (WF-02 Step 2d) verified the constraint empirically (a throwaway
`Mix.install` script reproducing both the failing pinned-helper call and a passing
module-attribute call against real Ecto) and found a third option that satisfies
both the SQL-injection guard and DRY: a module attribute. `@rank_case_sql
"CASE WHEN ... END"` referenced as `fragment(@rank_case_sql, ...)` compiles
cleanly, because `@attr` is inlined as a literal binary at compile time -- it is
not a runtime-pinned value -- so `Macro.expand/2` sees the same kind of literal it
would see from a string written directly in the call. This was ruled FAIL/rework
grounds precisely because it was a real, low-risk, mechanical fix (verified before
requesting it, not assumed) rather than gold-plating: the duplicated literal, left
as-is, would have created a silent-drift risk if a future edit updated the ranking
rule in one call site and not the other.

**Correct alternative:** when the exact same `fragment/1` SQL-text literal is
needed at more than one call site, hoist it to a `@module_attribute` and reference
the attribute at each `fragment/1` call -- never a function call pinned with `^`,
which Ecto rejects outright, and never silent duplication when the attribute
approach is available and its call sites are simple enough that one shared source
of truth is a strict improvement.

## `git checkout --ours`/`--theirs` means the opposite thing during `git rebase` vs. `git merge`

During WF02-REQ031-20260817's Step Final, ORCH hit an add/add conflict on
`docs/issues/ISS-0036.yaml` (a genuine cross-host numbering collision, already a
known class per the ISS-0034/ISS-0035 precedent) and resolved it with
`git checkout --theirs docs/issues/ISS-0036.yaml`, intending to keep `main`'s
version and drop the run's own now-redundant local copy. The run's own
`orchestrator.log`/`registry.json`/`requirement_status.yaml` entries all explicitly
documented this intent ("resolved by keeping main's version via `git checkout
--theirs`" / "this run's local ISS-0036.yaml was NOT merged; main's ISS-0036.yaml
... was kept as-is").

That is backwards. `git checkout --ours`/`--theirs` swaps meaning between the two
commands:
- During `git merge`, `--ours` = the branch you're on (HEAD), `--theirs` = the
  branch being merged in.
- During `git rebase`, this is **inverted**: `--ours` = the commit you are
  rebasing *onto* (the target, typically `main`), `--theirs` = the commit
  currently being replayed (your own feature branch's content) -- because a
  rebase internally does its work as a sequence of cherry-picks of your commits
  onto the new base, and from that internal perspective your own commit is the
  "other" side being applied.

So `git checkout --theirs` during that rebase actually kept the **run's own**
`ISS-0036.yaml` (its SVC-03/INV-5 finding) and silently overwrote `main`'s actual
content -- a different, already-independently-resolved `ISS-0036.yaml` from a
concurrent run (a `valid_review_attrs/1` unused-default-arg fix) -- with it. The
squash-merge then carried that wrong content into `main` permanently. Discovered
only because a *third*, later run (WF02-REQ042-20260817) hit its own conflict on
the same file during its own rebase and, per this project's "never satisfy a gate
by editing what it measures" / independent-verification discipline, ran `git show
origin/main:docs/issues/ISS-0036.yaml` to check the actual content on disk rather
than trusting the prior run's own log narrative -- which is what caught the
mismatch. See `docs/issues/ISS-0039.yaml` for the full incident and fix (no
permanent data loss: git history retained the original resolved content, so it
could be recovered from the commit that first wrote it).

**Why this is easy to miss:** the git command runs cleanly, produces no error, and
the rebase/merge completes -- there is no signal at the time that the flag picked
the wrong side. It only surfaces later, and only if something re-derives the
actual file content independently rather than trusting the resolving run's own
narration of what it did.

**Correct alternative:** during a `git rebase` conflict, don't reach for
`--ours`/`--theirs` from merge-trained muscle memory -- either reason explicitly
about which side each flag means *in a rebase specifically* (or just avoid the
ambiguity: read both versions with `git show :2:<path>` / `git show :3:<path>`,
or open the file and look at the `<<<<<<<`/`=======`/`>>>>>>>` markers directly,
and hand-edit to the intended result). After resolving any conflict this way on a
shared/audited file, independently re-read the resulting file's actual content
before writing a log/status entry that claims what was kept -- don't narrate
intent as if it were the verified outcome.

---

## Reading a whole large file to find one entry in it

**Found:** 2026-08-18, during a prompt-efficiency audit of the agent instruction
corpus (`docs/agents/`, `.claude/agents/`).

Nine role files instructed their agent to read `docs/requirements.yaml` — several
with the words "in full" — as a "Mandatory reading at session start" item. That
file is 3,384 lines and roughly 61,000 tokens, holding 70 requirements, of which
a given run needs one to four. Measured against the mandated preamble for a
single ELIXIR-DEV turn (CLAUDE.md + core-directives + WF-02 + security-invariants
+ anti-patterns + the role file + requirements.yaml), the requirements file alone
was ~76% of roughly 79,900 tokens — more than the other 29 instruction files
combined, by about 25x.

**Why this is easy to miss:** it reads as diligence. "Read the requirements in
full before touching code" is exactly the kind of instruction that looks careful,
and each individual role file states it once, in one line, so no single file looks
bloated. The cost is only visible when you sum what one turn is actually told to
load.

**Why it also costs accuracy, not just tokens:** 33 of those 70 requirements are
`done`, and this project's requirement descriptions are long and densely
cross-referential (REQ-043's alone runs 40+ lines citing four other REQ ids, a
decision record, and two R-Co source paths). Loading all of them buries the one
requirement in scope under other stages' constraints, which is a real chance for
an agent to build against the wrong stage's rules.

**Correct alternative:** carry scoped context in the handoff instead of pointing
at the file. ORCH — which already reads `docs/requirements.yaml` to select work —
copies the in-scope requirement's full `description` into
`context.requirement_text` (see `HANDOFF_PROTOCOL.md` §2), and downstream roles
read it there. Naming the file in `artifacts_in` is *not* sufficient: that still
tells the receiving agent to open it. When a role genuinely must consult the file
for a cross-referenced id, read only that entry:

```bash
awk '/^  - id: REQ-039$/,/^  - id: REQ-04[0-9]$/' docs/requirements.yaml
```

Two roles are legitimately exempt and say so explicitly in their own files —
REQ-ANALYST (global numbering/schema) and REQ-VALIDATOR (cross-requirement
consistency). The general rule now lives in `core-directives.md`'s "Load Scoped
Context, Not Whole Files", and it generalizes past this one file: prefer a
targeted read over a whole-file read for anything above a few hundred lines
(`git diff main...HEAD` over reading every changed file; `grep -n` over reading a
3,000-line YAML to find one key).

## Using `python3 -c "json.dump(...)"` to reorder/rewrite `handoffs/registry.json`

During WF03-ISS0045-20260818's registry bookkeeping, ORCH used a `python3 -c`
script (`json.load` + `json.dump(..., indent=2)`) to fix an out-of-chronological-order
entry it had just inserted. `json.dump`'s default `ensure_ascii=True` silently
rewrote every non-ASCII character in the file to a `\uXXXX` escape — every `§`
character in the file's own `_comment` field and multiple historical entries'
notes became a `§` escape sequence. The diff was caught only because it was reviewed
(`git diff --stat` showing ~1650 changed lines for what should have been a
one-entry move) before committing — a mechanical script produced a technically-valid,
schema-conformant JSON file that nonetheless silently corrupted content across
dozens of unrelated historical entries, exactly the kind of file-format regression
`core-directives.md`'s "Never Satisfy a Gate by Editing What It Measures" and
"Bookkeeping Is Not Optional" sections both guard against in spirit (the file stayed
parseable, so no gate would have caught it).

**Correct alternative:** never round-trip `handoffs/registry.json` (or any other
append-only project file with non-ASCII content) through `json.load`/`json.dump`
for a structural fix. Use the `Edit` tool's string-replacement on the raw text
instead — cut the misplaced JSON block via one `old_string`/`new_string` pair (remove
it from its wrong position) and a second edit to append it at the correct position,
never a full parse/re-serialize round-trip. If a `python3 -c` JSON check is
needed at all, use it read-only (`json.load` to validate parseability) — never
call `json.dump` on a file that contains non-ASCII characters without explicitly
passing `ensure_ascii=False`, and even then prefer a pure text edit over a
round-trip for a file this project treats as append-only/audit-trail.

## Two branches picking the same module name is a real rebase-time collision class, not just an ISS-number collision

WF02-REQ043-20260818 (schema module `Letflow.Engine.Token`, an `Ecto.Schema` for
the `tokens` table) and WF02-REQ044-20260818 (`Letflow.Engine.Token`, a pure
in-memory struct for the transition kernel, EE-02) were developed in parallel from
the same base commit, each unaware of the other. REQ-044 merged to `main` first.
When REQ-043's branch was later rebased onto that updated `main` (after a host
power interruption mid-rebase), `git` reported an add/add conflict on
`lib/letflow/engine/token.ex` — same path, same module name, two structurally
different things (persisted lifecycle row vs. transient pure-function value) that
cannot share one name. The same rebase also hit the already-documented
ISS-number-collision class (this file, above) a second time, independently: main
had already renumbered REQ-043's own `assignee_type` finding from ISS-0042 to
ISS-0043 (`docs/issues/ISS-0043.yaml`, GH#159) after an earlier cross-host
collision with REQ-044's ISS-0042 — so REQ-043's *other* finding (tenant_id
caller-mismatch, originally filed as its own ISS-0043) collided a second time.
A local resolution renumbered it to ISS-0044 first, but a concurrent host
independently ran the identical recovery for the identical branch/finding
moments later and reached `main` first with its own resolution (ISS-0045,
`docs/issues/ISS-0045.yaml`, WF03-ISS0045-20260818) — since `main` already had
an equivalent, fully-diagnosed record of the same finding, the losing side's
own duplicate was dropped entirely on its next rebase rather than filed under
yet another number. This is the concurrent-host race itself as an addition to
the ISS-numbering-collision class, not just a numbering mechanic: two hosts
recovering the *same* interrupted branch independently can each do the
"correct" renumbering and still collide with each other, and the answer is to
check whether `main` already carries an equivalent record before re-filing
one, not to just take the next free number on faith.

## TEST-DESIGNER writing narratively-detailed `describe`/`test` names that exceed ExUnit's 255-char combined limit

**Found:** 2026-08-18, ORCH session-start verification on `main` (commit `e8ef92d`,
before ISS-0049's fix), `mix test` failed to compile entirely.

Three `describe`/`test` string pairs, all from recent TEST-DESIGNER output for the
REQ-063/REQ-064 (Decision 0006) work, packed full acceptance-criteria context inline
into the names themselves — e.g. `describe "provision_oidc_user/4 — username
collision, same tenant schema vs different tenant schemas (REQ-063 acceptance
criteria)"` combined with an equally long `test "..."` string. ExUnit concatenates
`"test " <> describe <> " " <> test_name` into one internal identifier and hard-caps
it at 255 characters (`ExUnit.Case.validate_test_name/1`) — exceeding it is a
`SystemLimitError` at compile time, not a warning, so it doesn't fail one test, it
fails the whole file's compilation and blocks the entire suite (0 tests ran). See
`docs/issues/ISS-0049.yaml` for the full incident; this is the third occurrence of
this exact failure class in this project.

**Why this is easy to miss:** writing a self-documenting test name feels like good
practice, and each individual name looks reasonable in isolation in an editor — the
255-char ceiling only bites when `describe` and `test` are summed together, which
nothing in the file's own diff highlights.

**Correct alternative:** keep `describe`/`test` names as a short label, not a
restatement of the requirement's acceptance criteria — put the "why"/spec citation in
a `#` comment above the test instead of in the name string. TEST-DESIGNER should keep
combined `describe` + `test` name length comfortably under 200 characters (leaving
margin for ExUnit's own `"test "` prefix and separator), and TEST-DESIGN-VALIDATOR
should treat an unusually long describe/test pair as worth a manual length check
before passing the gate, since `mix compile`/`mix test` failing to even start is the
only signal today.

**Update, 2026-08-18 (ISS-0051):** this recurred a *fourth* time
(`test/letflow/engine_test.exs:717-718`, REQ-045/EE-01 work, 259 chars), found by
ISSUE-FIXER while trying to reproduce ISS-0050 on a branch based on current `main` —
confirmed pre-existing on `main` itself, not introduced by that branch. Three
documented recurrences of this exact class had not prevented a fourth. Documentation
alone is evidently not a sufficient gate; TEST-DESIGN-VALIDATOR (or a `mix test`
alias/CI step) should add a mechanical mode-independent check — e.g. a small script
that greps every `describe`/`test` pair and flags any combined length ≥ 200 — rather
than relying on a human/agent noticing during review.

**Correct alternative:** don't silently let the later-merged branch's name win by
accident of rebase order. Confirm which module is already shipped and load-bearing
on `main` (`grep -rl` its call sites — REQ-044's `Token` was aliased from
`instance_state.ex`/`transition.ex`/its own test, i.e. genuinely in use) and rename
the *unmerged* side instead, moving it to a new file/module name
(`token_record.ex` / `Letflow.Engine.TokenRecord`) rather than editing the
already-shipped one. Record the rename's reasoning in the new module's own
moduledoc (not just the commit message) so a future reader who only opens the file
sees why the name doesn't match the original design doc. This is the same
"confirm what's on disk, don't trust the branch's own narrative" discipline the
ISS-0036 incident above establishes, applied to module names instead of issue
numbers.

## A rebase add/add conflict on `docs/issues/ISS-NNNN.yaml` can land without git ever flagging it as CONFLICT

**Found:** 2026-08-18, ORCH post-merge independent verification of WF03-ISS0050-20260818
(PR #193, merge commit `c9894b2`).

Two concurrent hosts independently discovered and fixed the identical bug (a fourth
occurrence of the 255-char ExUnit test-name class, `test/letflow/engine_test.exs:717-718`)
within 16 minutes of each other, and each filed it as its own `docs/issues/ISS-0051.yaml`
(same path, different content) — the same class of numbering collision documented
elsewhere in this file (ISS-0034/0035, ISS-0036/0037/0039, ISS-0042/0043, ISS-0043/0044-0045).
`WF02-REQ047-20260818`'s commit (`c7a5d4a`) reached `main` first. `WF03-ISS0050-20260818`'s
branch had its own `docs/issues/ISS-0051.yaml` commit created *before* REQ-047 merged, so
Step Final's `git rebase origin/main` had to replay a commit that adds a file at a path
`main` already had different content at — textbook add/add conflict shape. **But the
Step Final agent's own handoff (`step-final-git-merge.json`) reported only one conflicted
file (`handoffs/orchestrator.log`) and never mentioned `docs/issues/ISS-0051.yaml` at
all** — yet the file that landed on `main` is `WF03-ISS0050-20260818`'s content, not
`WF02-REQ047-20260818`'s, meaning REQ-047's own audit-trail record (and its `github_issue`
cross-reference, GH#192) was silently dropped without ever being surfaced as something
requiring resolution. GIT_MERGE.md's own conflict-count check
(`git diff --name-only --diff-filter=U | wc -l`) would have caught this file if the agent
had actually re-run it after resolving the reported conflict, rather than treating the
rebase as fully clean once *a* conflict was resolved. This was only caught because ORCH,
per this project's own "never trust a resolving run's own narrative" discipline, diffed
the pre-merge blob (`git show <pre-merge-sha>:<path>`) against the post-merge file instead
of trusting the Step Final handoff's summary.

**Why this is easy to miss:** the rebase command's own exit code and the agent's own
narration ("one conflict, resolved, tests green") both looked completely clean — nothing
in the visible output distinguished "one conflict occurred and was the only one" from
"one conflict was noticed and resolved, a second one existed and was resolved without
being reported" (or, alternatively, resolved by a stale `git add -A`-style catch-all that
silently staged an unresolved but no-longer-marked-`<<<<<<<`-visible file). Post-merge
`mix test` passing gave no signal either, since both sides' fixes were code-equivalent —
the lost content was pure audit-trail, not a behavior regression, so no test could ever
have caught it.

**Correct alternative:** after `git rebase --continue` reports success, re-run
`git diff --name-only --diff-filter=U | wc -l` one more time as a hard check (must be
`0`) before proceeding to push — do not rely on having "handled a conflict" once as proof
none remain. When a run adds a new file under `docs/issues/` (or any other append-style
directory this project treats as collision-prone), diff the specific file's pre-rebase
and post-rebase blobs (`git show ORIG_HEAD:<path>` vs current) as a final check even when
git reported the rebase as conflict-free for that path — a silently-applied patch that
happened not to conflict textually can still be the wrong side's content in a genuine
add/add scenario, and only a content diff (not the exit code) reveals it.

## Two independently-merged Ecto migrations picking the same version-number prefix

**Found:** 2026-08-19 (ISS-0061), discovered by `hetzner-orch` when `mix ecto.migrate` /
`mix test` on `main` failed hard before a single test ran.

`priv/repo/migrations/20260819000001_create_groups_tenant_scoped.exs` (REQ-063,
Decision 0006 D1) and `priv/repo/migrations/20260819000001_drop_transition_events.exs`
(REQ-046, `process_instance.ex` retirement, #199) were developed on independent hosts,
each derived its migration's version prefix from its own host clock at commit time, and
both merged to `main` independently (commits `5941472` and `1059093`) without either
host observing the other's concurrent migration. `mix ecto.migrate` — and therefore
`mix test`, which runs pending migrations against the sandbox DB before any test body
executes — failed immediately with `Ecto.MigrationError: migration version
20260819000001 is duplicated`, blocking every host working this backlog, not just the
run that happened to find it first. Fixed in PR #211 (WF03-ISS0061-20260819) by
renumbering one of the two files to a later, non-colliding version.

This is the same cross-host filename/id collision class already documented above ("Two
branches picking the same module name...", the `docs/issues/ISS-NNNN.yaml` add/add
entry) but the first occurrence against an Ecto migration version number specifically,
and it is worth distinguishing from those two: a colliding module name compiles cleanly
and is only caught later by a build/test failure somewhere downstream, and a colliding
`docs/issues/ISS-NNNN.yaml` filename can land through a rebase without git ever
flagging it as a conflict at all. A colliding migration version is a *harder* failure —
Ecto's own duplicate-version guard raises `Ecto.MigrationError` immediately, before any
application code runs, so it is impossible to silently ship (unlike the other two,
which can persist on `main` for a while before anything notices).

**Why this is easy to miss:** each host generates its migration's timestamp prefix from
its own local clock at the moment the migration is created, with no cross-host
coordination step in between — two hosts working the backlog concurrently, each
starting from the same base commit, have a real chance of picking timestamps that land
in the same second-granularity bucket, especially when migrations are authored close
together in wall-clock time. Nothing about either individual branch looks wrong in
isolation; the collision only exists once both have merged into the same `main`.

**Correct alternative:** `test/letflow/migration_filenames_test.exs` (added in the same
ISS-0061 fix) is now a standing regression guard — it asserts no two files under
`priv/repo/migrations/` share a leading version prefix, and that every migration
filename's prefix is purely numeric, so a second occurrence fails `mix test` on the
merging host's own branch (or on `main` immediately after a bad merge) rather than
surfacing only when some other host next tries to migrate. Rely on that test rather than
manually eyeballing timestamps before a migration PR merges. The deeper mitigation this
incident points to — ORCH preferring a coarser/higher-entropy migration timestamp source
(e.g. including seconds *and* a host-specific salt, or checking
`docs/agents/protocols/GIT_SETUP.md`'s branch-push coordination signal more carefully
when multiple hosts are adding migrations concurrently) — is out of scope for this entry;
flag it if it recurs a second time.

## Inheriting a claim from a record instead of re-deriving it from the source

**Occurred three times in one session (WF01-REQ109-20260819), each time compounding the
last.** Every instance had the same shape: an agent read a *claim in a Letflow record*,
treated it as established fact, and built work on top of it — when the underlying source
was reachable the whole time and said something different.

1. **ISS-0063's original scoping note.** ISSUE-FIXER concluded the issue was blocked on
   an undecided product question ("where does a `:HUMAN_TASK` node's output schema come
   from?", REQ-047 OQ-3) and wrote that conclusion into the issue file as fact. Reading
   R-Co directly showed three different things there carry the word "schema", that the
   investigation had conflated two of them, and that `tasks.form_schema` is a UI
   rendering payload never used for validation. The real source (`variable_schemas`) had
   existed in R-Co the entire time. **A wrong-but-confident record is worse than an open
   issue**, because the next agent inherits the frame instead of re-deriving it.
2. **ISS-0076's own file list.** Filed by ORCH to warn about exactly this class of
   problem — and its `affected_files` was derived *from* its own recommended grep
   pattern, so list and pattern were self-consistent and blind together. It missed four
   files including a fourth shipped moduledoc (`lib/letflow/engine/execution_error.ex`).
   Its "30 occurrences" counted `docs/`, i.e. the record counting itself.
PROVENANCE (historical, not current decision authority):
3. **REQ-111's premise.** ORCH scoped a whole requirement around auditing
   `req062-sub-process-runtime.md`'s `instance.zig`/`transition.zig` line citations,
   inherited from ISS-0076's framing. There are **zero** such citations — the file
   mentions those R-Co files in prose only, and all ~55 of its `file:line` citations
   point at *Letflow* files, two of them at `transition.ex`, one character from
   `transition.zig`. The caveat it was built around is a standing disclaimer guarding
   citations the document never made. Caught only by REQ-VALIDATOR running the grep.

**Why this is easy to miss:** the inherited claim is usually *plausible*, written by a
competent agent, and sitting in the exact file you were told to read. Nothing looks
wrong. The failure is invisible precisely because the record is the normal, sanctioned
input — and each downstream agent that trusts it adds authority to the error rather than
catching it. Prose caveats are especially dangerous: a sentence like "no R-Co source tree
is reachable in this environment" was true for the host that wrote it and silently false
for every host after.

**Correct alternative:** when a record makes a *checkable* claim that your work depends
on — a file exists, a citation resolves, a count is N, a source is unreachable — spend
the one command it takes to check it before building on it. Specifically:

* **Verify the premise before scoping work around it.** If a requirement's whole point is
  "audit the citations in X", grep for the citations first. Zero is an answer.
* **Never derive a file list and a search pattern from each other**, then cite one as
  evidence for the other. Measure with a deliberately broader pattern than you think you
  need, and make counts an *output* of the run rather than a constant copied forward.
* **Scope greps to the code being described.** ISS-0076's inflated count came from
  including `docs/`, where the issue files themselves live.
* **Treat "unreachable/unavailable in this environment" as expiring.** It is a statement
  about one host at one moment, not a property of the project. R-Co is at
  `c:\Users\tvolo\dev\ai-dala\R-Co` and is readable; check before repeating the claim.
* **When you do correct such a record, supersede rather than overwrite** — ISS-0063
  keeps the wrong note as `superseded_scoping_note` marked do-not-act-on, so the audit
  trail survives without the error staying live.

**A fourth instance landed 2026-08-21** (ISS-0106's `ROOT CAUSE (confirmed, not
inferred)` line, inherited into its own proposed resolution and refuted by one container
run) — filed separately below as "Attributing a failure to toolchain drift without ever
running the pinned toolchain", because its refutation is specific enough to be worth its
own procedure.

## Audit-shaped requirements: closed-set and outcome-independence must be checked at draft time

**Twice in one session the gate had to repair the same property after the fact**
(REQ-110/111/112). Requirements whose deliverable is *findings* rather than *code* have a
failure mode ordinary requirements don't: an acceptance criterion that presumes a finding
is unsatisfiable exactly when the audit succeeds at finding something unexpected. "REQ-059's
override mechanism matches R-Co" reads as a reasonable AC and is actually a trap — an
honest auditor who finds a mismatch fails it.

The sibling defect is a **disposition set that isn't closed**. ORCH's first set was
`confirmed / corrected / filed-as-issue`, which has no slot for a question the source
*cannot* answer — and one target (`req060-pin-rebind.md:100`) says in its own text that
it isn't something R-Co could settle, being a Letflow caller-responsibility choice. Under
that set an auditor must either leave the location unaddressed (failing an AC) or force a
false disposition. A fourth outcome, `unsettled_by_source`, fixed it. The identical gap
then reappeared one requirement over in REQ-111, whose set was closed for *citations* but
not for a substantive assumption that might "differ, but harmlessly".

**Correct alternative:** when drafting an audit-shaped requirement, run the closure test
as a *drafting step*, not as something the gate discovers — for each location in scope,
enumerate the plausible outcomes and confirm every one has a slot. Then write ACs that
quantify over **locations, never over outcomes**: every location resolves to exactly one
disposition, each carrying concrete `file:line` evidence, with counts that must sum so
partial completion shows up as arithmetic rather than prose. Add an explicit nil-result
clause so "found nothing" is a *stated* result rather than an inferred absence — that
closes the "looked and found none" vs "never looked" ambiguity. A meta-AC forbidding
satisfaction by global verdict is worth including: it stops one block judgement standing
in for N per-location ones, which is exactly what hides a single wrong rule among several
right ones. Where a disposition could become a lazy catch-all, fence it by requiring the
specific source `file:line` consulted *and* why it doesn't settle the question — a shrug
can't produce either.

## Picking the next `ISS-NNNN` with `ls docs/issues/ | tail -1` is not atomic — it silently destroyed a record

**Happened for real on 2026-08-19, not hypothetically.** Two agents were running
concurrently on the same host. REQ-110's ISSUE-FIXER wrote its pin-override finding as
`docs/issues/ISS-0077.yaml` and filed GH#298 under that id. A concurrent
`WF02-REQ109-20260819` CODE-DESIGNER independently picked the same next-free number for an
unrelated `VariableMerge` finding, and **its file landed second, overwriting the first**.
No git conflict, no error, no warning — the second `Write` simply replaced the first
agent's file. It was recovered only because the first agent still had the content in its
own context and could renumber to `ISS-0079` and repoint GH#298's body. Had it been
compacted out, or had the agent finished earlier, the record would have been gone with a
live GitHub issue pointing at a file describing something else entirely.

**Why the usual defences don't catch it:** this is an add/add of the *same path*, so it
isn't the rebase-collision class already documented above — both writes happen in one
working tree, seconds apart, before either is committed. `git status` shows one untracked
file, which looks correct. Nothing in `docs/agents/protocols/ISSUE_QUEUE.md` serialises
id allocation, and the "highest existing + 1" convention is a read-then-write race with no
lock between the two halves. The risk scales with exactly the thing this pipeline
encourages — running producing agents in parallel.

**Correct alternative — for whoever is coordinating, not the sub-agent:**

* **Allocate ids centrally.** When dispatching concurrent agents that may file issues,
  hand each a *reserved, disjoint* range in its brief ("use ISS-0081 and upward"), rather
  than letting each derive its own from the directory. The coordinator knows what is in
  flight; a sub-agent does not.
* **Never overwrite an existing `docs/issues/ISS-NNNN.yaml`.** If the target path already
  exists, that is a collision — take the next free id, do not merge and do not replace.
  A `Write` to an existing issue path should be treated as a bug regardless of content.
* **File the local record before opening the GitHub issue**, and put the id in the GH
  title. A GH issue whose body cites a local file that has since been overwritten is the
  worst end state, because the two records disagree while both look authoritative.
* **When you do hit a collision, renumber your own and leave the other intact** — that is
  what happened here and it was the right call. Then fix the GH body, and say so in the
  handoff so the coordinator knows the numbering is no longer dense.

## `ISS-NNNN` collisions keep recurring because documenting the hazard doesn't reserve the number

**Fired again on 2026-08-20**, during `WF02-REQ066-20260820`'s Step Final — the seventh
recorded instance of this class (ISS-0034/0035, ISS-0036/0037/0039, ISS-0042/0043,
ISS-0043/0044-0045, ISS-0051, ISS-0077/0079, and now ISS-0107). What makes this one worth
adding is *not* the collision itself, which the entries above already cover, but that the
run **predicted it in advance, wrote the mitigation into the Step Final handoff, and it
happened anyway** — because a warning is not a lock. While the branch was in flight, a
concurrent session (the letflow-2 workspace, PR #356) independently allocated `ISS-0107`
for an unrelated Windows fake-mix issue and merged to `main` first. The rebase produced an
add/add on `docs/issues/ISS-0107.yaml` plus a follow-on *content* conflict, because a
later commit in the same branch had backfilled `queue_task_id`/`github_issue` into what
was, post-resolution, main's file rather than this run's.

The resolution was correct and is the shape to copy: neither `--ours` nor `--theirs` was
used at any point (both stages read via `git show :2:` / `git show :3:` and identified by
content), main's record was kept byte-identical, and *this* run's record was renumbered to
`ISS-0109` — the next id genuinely free across every remote branch, not merely free
locally — carrying a `renumbered_from` field so the audit trail survives. ISS-0108's three
cross-references were repointed and GH#358's body was updated to cite the new filename
while keeping its issue number. Historical handoffs and the Step 4 test report still say
"ISS-0107" and were deliberately left as written rather than retroactively edited.

**A second finding from the same resolution, worth its own note:** the post-rebase
verification was done by *content diff*, per the existing "an add/add on this path can
land without git flagging it" entry above — and that is what revealed `ISS-0106`'s raw
diff showing every single line as changed. The cause was purely `LF`→`CRLF` checkout
conversion on Windows, confirmed with `diff --strip-trailing-cr`. An agent trusting the
raw diff would have concluded a file had been rewritten when nothing had changed at all;
an agent trusting the exit code would have missed a real overwrite. Both failure modes
are avoided only by diffing content *and* normalising line endings before judging it.

**Correct alternative — the structural fix, not another warning.** The prior entries
already say "allocate ids centrally" and "never overwrite an existing
`docs/issues/ISS-NNNN.yaml`", and this run followed both and still collided, because the
coordinator can only reserve ranges for agents *it* dispatched — it has no visibility into
another host's concurrent session. Until `ISSUE_QUEUE.md` gains a real reservation
mechanism (the obvious candidate: derive the id from `register_task`'s returned
`impl_order`, which is already globally unique and atomically allocated by the one service
that spans hosts, rather than from a directory scan), treat an ISS-number collision at
rebase time as *expected* rather than exceptional: scan `docs/issues/` across every
**remote** branch before picking a number, and renumber your own side on conflict as a
matter of routine. Do not read the absence of a collision in one run as evidence the
convention is safe.

**UPDATE 2026-08-21 — the structural fix has landed and is deployed. The scan-and-renumber
routine above is superseded for NEW issues.** (Appended, not a rewrite: everything above
this paragraph is the historical account and stands as written.)

An eighth occurrence fired first, and it is the strongest evidence in this entry precisely
*because* the run did everything this entry told it to. `WF03-ISS0106-20260821` scanned
`docs/issues/` across **every remote branch** before choosing — the exact mitigation
prescribed above — found the highest anywhere to be `ISS-0109`, and filed `ISS-0110` and
`ISS-0111`. A concurrent session (`WF03-ISS0109-20260821`, PR #371) had meanwhile
allocated `ISS-0110` through `ISS-0117` and merged first. Both records had to be renumbered
at Step Final, to `ISS-0118` and `ISS-0119` (see their `renumbered_note` fields). The scan
was not done carelessly; it was correct at the moment it ran. The colliding numbers simply
did not exist on any branch yet. **A scan reads state; it cannot reserve it.** That is why
no amount of scanning discipline was ever going to close this class.

The fix is exactly the mechanism this entry named as "the obvious candidate": the id is now
derived from `register_task`'s own atomically-allocated task id, not from a directory scan.
`letflow-queue` PR #4 (merge `5b0e968`) shipped it and it is deployed on
`queue-test.ai-dala.com` (CD run 32450296100, 2026-08-21T05:23Z), verified live by ORCH.
Concretely:

- `register_task` returns a new **`issue_ref`** field — `"ISS-"` plus the zero-padded task
  id (task 187 → `"ISS-0187"`), `null` for requirement-type tasks. That value **is** the
  issue id and the local record's filename. The queue's `id` is an autoincrement primary
  key, so two hosts can never receive the same one.
- For issue-type tasks the service also rewrites the title to carry that ref as a prefix,
  replacing any `ISS-NNNN:` the caller supplied. A verification probe deliberately titled
  `"ISS-0120: ..."` came back as id 187 / `issue_ref "ISS-0187"` with the title rewritten
  accordingly. Only a *leading* token is replaced — an `ISS-` reference elsewhere in a
  title is a real cross-reference and survives verbatim.
- `register_task` also accepts an optional `github_issue_number` and adopts that issue
  rather than opening a second one; a number already linked to another task is rejected
  (`has already been taken`), not re-pointed.

`docs/agents/protocols/ISSUE_QUEUE.md` has been updated accordingly: its Procedure no
longer contains a "scan and increment" step at all, and its new "Where the id comes from"
section carries the details.

**What is superseded, and what is not.** Superseded for **new** issues: "scan every remote
branch before picking a number," "treat a collision at rebase time as expected," and — from
the entry immediately above this one — "file the local record before opening the GitHub
issue, and put the id in the GH title." That last one inverts: `register_task` creates the
GitHub issue *while* allocating the id, so the GH issue now precedes the local file by
design. It is safe in a way it wasn't before, because the overwrite hazard that advice
guarded against was a *consequence* of guessed numbering rather than of ordering, and
because the id now reaches the GH title automatically instead of depending on an agent
remembering to put it there. Continuing to follow the old advice would mean continuing to
guess a number, which is now the harmful path.

**Not** superseded: everything about handling a collision among the **existing**
hand-numbered records (`ISS-0001`..`ISS-0119`), the renumber-your-own-side-and-leave-the-
other-intact rule, `renumbered_from` provenance, the never-overwrite-an-existing-issue-file
rule, and the content-diff-with-line-ending-normalisation verification finding above —
those remain correct and are the only guidance for anything filed before 2026-08-21.

One consequence to expect rather than investigate: issue ids **jump** from `ISS-0119` to
the queue-allocated range (`ISS-0186` and upward) and are **non-contiguous** thereafter,
because the id sequence is shared with requirement-type tasks. There are no `ISS-0120`
through `ISS-0185` files and there never were. A future reader finding that gap should not
go looking for lost records.

## Working a user-named GitHub issue without ever locking it in letflow-queue

An ORCH session resolving ISS-0086/GH#303 (a user-named, directly-selected issue —
exempt from the queue's Hard Rule *selection* requirement) treated that exemption as
covering the queue entirely: it branched, fixed, tested, and merged the whole run
without ever calling `set_lock`/`get_next_task` to actually claim the task, and without
`release_lock` at the end. Two separate mistakes compounded:

1. **Reachability was tested with `get_next_task` used as a probe.** A throwaway
   `agent_id: "probe"` call meant only to check the service was up actually claimed and
   locked a real, unrelated task (#161, ISS-0075) — `get_next_task` is not read-only, it
   atomically claims whatever it returns. Caught and released immediately, but it should
   never have happened: `GET /health` is the reachability check with no side effects.
2. **The exemption from *selection* was read as an exemption from *locking*.** Nothing
   in the queue's state reflected that ISS-0086 was being worked on. For the entire
   duration of the fix, a second host's own `get_next_task` call could have independently
   claimed the same still-open GitHub issue (if/once it entered the queue's GitHub-import
   side effect) and duplicated the work — the exact failure mode `TASK_QUEUE.md` was
   written to prevent, just via a different door than the one its Hard Rule closes.

**Root cause traced further back, not just this run's own shortcut:** `ISSUE_QUEUE.md`
(the protocol that filed ISS-0086 in the first place) never called `register_task` at
all — it predates `letflow-queue` and was never reconciled with it, so issues filed that
way only enter the queue *opportunistically*, as a side effect of some later
`get_next_task` call's GitHub-import step, if at all. There was no `queue_task_id`
recorded anywhere for ISS-0086, so even a well-intentioned attempt to lock it correctly
had no known id to target — confirmed empirically: one real `get_next_task` claim
attempt this run returned a completely different, newer issue (#163/ISS-0088), not the
one being worked, and had to be released back untouched.

**Correct alternative:** `ISSUE_QUEUE.md` now routes every newly-filed issue through
`register_task` (task_type: "issue") at filing time, recording the returned id as
`queue_task_id` in the issue's yaml — see that file's 2026-08-20 update. For a
user-named task with a `queue_task_id` already on record, `set_lock` it directly before
starting work (it locks any unlocked known-id task, not only a task the same agent held
before — see `TASK_QUEUE.md`'s `set_lock` section). For a legacy issue with no recorded
id, make exactly one real `get_next_task` call to check/claim, release-and-report on a
mismatch rather than chasing further down the stack, and `release_lock(status: "done")`
whatever was actually locked once the fix is merged — full bounded procedure in
`TASK_QUEUE.md`'s "A human names a specific issue" section. Test queue reachability with
`GET /health`, never with a disposable `get_next_task` probe.

**2026-09-28 note (decision 0017, `GET /tasks` shipped 2026-09-04):** mistake (1) above
— `get_next_task` used as a reachability probe — is now **structurally impossible** for
the lookup that caused it: `GET /tasks` gives a side-effect-free way to find a task by
`github_issue_number` (or any other field), so the bounded claim-then-release procedure
this entry originally pointed at has itself been deleted from `TASK_QUEUE.md` and
replaced with "look it up via `GET /tasks`, `set_lock` it, work it,
`release_lock(status: "done")`" — there is no longer a `get_next_task` call in that path
at all to misuse as a probe. `GET /health` remains the plain up/down check. **Mistake
(2) is unchanged and still binding**: the exemption from *selection* is never an
exemption from *locking* — decision 0017 only changed how a task is found and who may
choose among eligible ones; it did not touch the Hard Rule's "no agent works a task it
does not hold a lock on" invariant, and a task seen via `GET /tasks` still must be
`set_lock`'d before work starts, exactly as before.

## Selecting from a visible queue without locking (pre-emptive)

**This is not a real incident.** No date, run-id, or `ISS-` number is attached because
none has happened — this entry exists because `docs/migration/decisions/0017-task-queue-selection-model.md`
names the risk explicitly in its own Consequences section before it could occur, and the
project's convention is to write the warning where agents actually read it
(`TASK_QUEUE.md`), not only in the decision record, and to write it *before* the failure
rather than after.

**The risk:** `GET /tasks` (added 2026-09-04, decision 0017 §B) lets any agent see the
whole queue — every task's `status`, `depends_on`, `blocked_by`, `eligible`, and lock
state — without claiming anything. A visible board is easier to act on without locking
than an invisible one: an agent that can see a task marked `eligible: true` can
rationalize starting work directly from that listing ("I can see it's open and unlocked,
so it's fine to begin"), skipping `set_lock` entirely because the read already looked
authoritative enough.

**It would not be.** `GET /tasks` performs no write of any kind — it does not claim, and
its `eligible` field is a snapshot that can go stale the instant another host locks the
same row. The invariant `TASK_QUEUE.md`'s Hard Rule states is unchanged by the new
endpoint's existence: **no agent works a task it does not hold a lock on, and no lock is
obtained anywhere but from the queue.** Seeing a task, however clearly `eligible`, is
never itself a lock. The correct sequence is always look (`GET /tasks`, optional) →
claim (`set_lock`, mandatory, and can still lose to a `409`) → work → release. Collapsing
that to look → work skips the one step that actually arbitrates who gets the task, and
reintroduces exactly the two-hosts-claim-the-same-task race the queue exists to close —
just via the new read endpoint as the rationalization, rather than a missing lookup as
the excuse (contrast the entry above, where the *cause* was no lookup at all; this one's
hypothesized cause is the opposite: too easy a lookup).

## Validating a design's type table for well-formedness instead of against its own normative section

During WF03-ISS0109-20260821, a design artefact declared §3.5 normative for
`capture_schema_state/1`'s failure boundary (an invariant row, INV-F-4, said so in
as many words), and §3.5 required a scalar whose query failed to degrade to `nil`.
Meanwhile the `@type` table in §3.2 typed the same two fields `boolean()`. Both
could not hold.

CODE-DESIGN-VALIDATOR gated this design **twice** — a full first pass that
independently re-derived six load-bearing claims from source (including one settled
by running a real query against Postgres), then a narrow re-gate — and neither pass
caught it. Not from carelessness: each section was checked, and the type table was
internally well-formed. Nothing was checked *across* the two, in the one direction
the design itself had declared authoritative.

It was caught by ELIXIR-DEV, one step later, only because implementing the type
forced the two readings into the same file. That is the expensive place to find it —
and it was found there only because the implementer flagged the contradiction to
REVIEWER instead of quietly picking whichever reading was easier to code.

Why it mattered rather than being a cosmetic type widening: taking the literal
`boolean()` would have broken INV-F-10. A capture whose `information_schema.schemata`
query failed would report `schema_present?: false`, the reason-builder would emit
"schema is absent", and the completeness assertion would raise against a perfectly
healthy schema — a failing *diagnostic* turning a *passing* test red. For a helper
whose entire purpose is making an intermittent failure attributable, reporting an
unobserved thing as an observed absence is the exact defect it exists to prevent. It
would have re-created ISS-0109's original misdiagnosis (see that record's
`mechanism:` correction) inside the very tool built to stop it.

**Correct alternative:** when a design names one section normative over another —
"§X is authoritative", "see §Y for the contract" — that declaration is itself a
checkable claim, and a validator must read the two sections **against each other**,
not each on its own. Concretely: list every field, error value or return shape the
normative section constrains, then look up each one in every other section that
restates it, and diff the two by hand. Any restatement is a place the design can
contradict itself, and a `@type` table is the most likely restatement to drift,
because it is written once and then never re-read while the prose around it changes.
## Attributing a failure to toolchain drift without ever running the pinned toolchain

**ISS-0106, filed 2026-08-20, resolved 2026-08-21.** The issue recorded its cause under
the heading `ROOT CAUSE (confirmed, not inferred)`: this Windows host runs Elixir
1.20.3/OTP 29 while `.tool-versions` pins 1.18.3-otp-27, so the four files failing
`mix format --check-formatted` and the fourteen `struct for X is expected on struct
update` warnings were both artefacts of the host being wrong. Nothing had been run under
1.18.3 to establish that. The issue's own proposal (a) followed from the framing:
"install the pinned toolchain and confirm both checks go green with **no file changes at
all**, which would prove the files are correct and only the host was wrong."

WF03-ISS0106-20260821 ran that check, and the premise failed for half the issue:

* **Format — refuted.** Inside a throwaway `elixir:1.18.3-otp-27` container, against the
  same tree with the repo mounted read-only, `mix format --check-formatted` exits 1 on
  **the same four files with character-for-character identical diffs** —
  `lib/letflow/engine/pin_resolver.ex:541`, `lib/letflow/engine/variable_merge.ex:92,98`,
  `test/letflow/engine/pin_resolver_test.exs:239,322`,
  `test/letflow/engine/pin_rebind_test.exs:516`. That includes the heredoc escape
  ISS-0106 attributed *specifically* to a formatter behaviour change between versions —
  the formatter wants an escaped `\"""` inside the `@moduledoc` heredoc where the file
  has a bare `"""`. Elixir 1.18.3's formatter wants that escape too.
* **Compile — confirmed.** 14 struct-update warnings under 1.20.3/OTP 29, **zero** under
  1.18.3/OTP 27, identical tree. That symptom really was version drift, and it is now the
  measured answer to the `UNCONFIRMED` note ISS-0046 left behind for the same warning
  class.

The four files were not made unformatted by a version change; they were made unformatted
by three commits that merged on 2026-08-20 — `91d7e25` (ISS-0080/GH#301), `cb43cc2`
(ISS-0078/GH#299, PR#347) and `a7fa87b` (GH#298, PR#349). Verified per file rather than
inferred from blame alone, using ISS-0008's `git show <rev>:<path> | mix format
--check-formatted -` technique so nothing had to be written to the working tree: all four
files exit 0 at the introducing commit's **parent** and exit 1 at the commit itself.
*Why* those runs' format gates did not stop them is a separate, still-open question —
tracked as ISS-0110/GH#363, deliberately not answered here.

**Why this is easy to miss:** the attribution was plausible, confidently worded, and
**half right** — a genuine toolchain drift did exist alongside the real defect, and the
correct half lent credibility to the incorrect half. A version mismatch is also a
satisfying explanation for a formatting diff, because formatter output genuinely does
change between Elixir releases sometimes. And the refuting measurement was available the
entire time and cost one container run: Docker was on the host, and this very file
already documents the throwaway-container recipe (`MSYS_NO_PATHCONV=1`, repo mounted
`:ro`, tree copied to `/work`, separate build path). Nobody ran the pinned toolchain
before asserting what it would do. The consequence was concrete rather than theoretical:
a real defect sat deferred for a day as an environment problem — and ISS-0106 predicted
that consequence in the abstract while being an instance of it.

**Correct alternative — refute it cheaply first, and note that this one needed no
toolchain at all.** Three of the four diffs are ordinary line wraps, measured at 99–102
characters against the formatter's default `line_length` of **98**, which `.formatter.exs`
never overrides. *A line over 98 characters is unformatted under every Elixir version
that has ever had a formatter.* `awk '{ if (length($0) > 98) print FILENAME":"FNR": "
length($0) }'` settles it in one command — no container, no install, no second host, no
network. So:

* **Before attributing a formatting failure to a version, measure the diff against the
  configured `line_length`.** If the offending lines are simply too long, the version
  question is moot and the files are wrong under every version.
* **Never write `ROOT CAUSE (confirmed)` for a claim about a toolchain you have not
  run.** "Suspected — not yet reproduced under the pin" is the honest wording and costs
  nothing; the confident wording is what propagates.
* **When one symptom's attribution is confirmed, re-derive the others separately.** Two
  symptoms failing the same command is not evidence they share a cause. Here they did not:
  one was drift, one was a defect, and bundling them made the defect inherit the drift's
  excuse.
* **Run the check the issue itself proposes before proposing anything downstream of it.**
  ISS-0106 named the decisive experiment in its own proposal (a). It just was not run.

This is a fourth instance of **"Inheriting a claim from a record instead of re-deriving it
from the source"** above, and it is filed separately only because its transferable lesson
is specific — version-attributed failures have a cheap, toolchain-free refutation that the
general entry does not name.

## Re-deriving the count while inheriting the unit being counted

**A re-derivation that recounts *how many* but inherits *what is being counted* is not a
re-derivation.** It is a passing run of a different measurement — the same shape as
`core-directives.md`'s **"Re-derive under the conditions the property is actually about"**,
and a variant of **"Inheriting a claim from a record instead of re-deriving it from the
source"** above. This entry exists separately because of who carried it: in every instance
of that entry, the carrier is a *producer* trusting a record, and the correction mechanism
assumed throughout is that a validator re-derives. **Here the validator did re-derive, and
propagated the error anyway** — a gate handoff was itself the carrier, which had not been
recorded before.

**The incident (WF03-ISS0117-20260821), traced by reading each handoff rather than the run
narrative.** One wrong figure — "five occurrences" of an ad-hoc `orch_*` bookkeeping key —
travelled through four steps, and each step re-derived something:

1. **Step 1 (ISSUE-FIXER), `step-01-diagnose.json`** — "Five occurrences across four runs",
   then enumerates **five** run ids, one of which (`WF02-REQ043`) wrote no key at all. The
   unit was already conflated at origin: *occurrences of an improvised key* had been mixed
   with *incidents of an agent dying*.
2. **Step 3 (DOC-UPDATER), `step-03-amendment.json`** — copied it into the protocol as
   "THREE key names across FIVE occurrences", with a parenthetical enumerating **four**.
   The figure and its own evidence list disagreed inside one sentence.
3. **Step 3b (REVIEWER), `step-03b-reviewer-gate.json`** — a gate, correcting *that exact
   paragraph*. It recounted and **refuted** "five occurrences" → four. Then it proposed as
   the fix: "five DEATH incidents across FIVE runs, four of which improvised a key." It had
   re-derived the count and inherited the unit: it matched on **key names and run ids** and
   never opened the keys.
4. **Step 3c (DOC-UPDATER)** — read the four keys' **values**. Two (`WF02-REQ023`,
   `WF02-REQ037`) are ORCH correcting a timestamp, in runs where **no agent died**. Three
   deaths, not five. The correction came from reading content, not from counting harder.

**And it fired a fifth time, in this same run, inside the gate that had just named it.**
Step 3d's re-gate re-derived the death count independently and got **three** — while
inheriting the class boundary from the table it was checking. Re-swept here at Step 3e:
`WF02-REQ038-20260817` is a **fourth** death in the same class (a dispatched
CODE-DESIGN-VALIDATOR killed by a connection error mid-work, redispatched). It was missed
because its dispatch committed nothing, so it left no handoff file and no
`orchestrator.log` line — it survives only in a `registry.json` run note, and a sweep whose
unit is "handoff files carrying a death marker" structurally cannot see it. Same mechanism,
one level up.

**Then a sixth time, one level up again — and the escalation is the transferable part.** The
Step 3f gate re-derived the class *boundary* as dispatched, and found that the section's
**exclusion set** had been enumerated by the same handoff-file-shaped sweep that missed
`WF02-REQ038`: it named one excluded incident and read as though that were all of them, while
`WF02-REQ019-20260816` sat outside it, in-class on treatment and out-of-class on the test, and
undecidable either way because the section stated a class *name* and no membership *test*.
Trace the four numbered steps above and the shape is unmistakable: the error moved from the
**count** (four keys, three deaths), to the **class** (which deaths count), to the
**exclusion set** (which
non-members have been checked for) — and each move survived a re-derivation that was genuinely
diligent *within the frame it inherited*. Re-deriving one level down from where the defect
lives always confirms the defect. So the corrective is not "re-derive harder" but **name the
level you are re-deriving at, and check the level above it once**: if you are recounting
members, re-derive the membership test; if you are checking the test, re-derive whether the
set of things it was applied to was itself assembled by a sweep with the same blind spot. The
fix that finally held was to write down a test a reader can apply to a candidate and get the
same answer as anyone else, and to state the exclusion list as *what has been checked* rather
than as *what exists*.

**Why it is easy to miss.** Re-deriving *feels* like the diligent path, and it is — the
count really is recomputed, from the real files, by a real command. What is never
recomputed is the category the command selects on, because it arrives inside the question.
A gate is *more* exposed to this than a producer, not less: a gate is handed the claim as a
proposition to check, and checking a proposition tends to mean testing its predicate, not
its subject.

**Correct alternative — re-derive the unit, not only the number:**

* **Before recounting, write down in one sentence what a single member of the set *is*,**
  and check that sentence against the source rather than against the claim. "Four keys" and
  "four deaths" are different sets that were the same size for a week.
* **The cheap test: open a sample of the underlying records and read their CONTENT** — the
  key's *value*, the run note's *text* — rather than matching on the field name, key name,
  or id that defines the category. Four `orch_*` keys took two minutes to read in full, and
  reading them is what broke a figure three agents had passed along.
* **Ask what a member of the class would look like if it left no artefact of the kind you
  are grepping for.** `WF02-REQ038` left no handoff file; `WF02-REQ043` left no key. A sweep
  over one artefact type silently defines the class as "members that produced that
  artefact."
* **When a figure and its own parenthetical disagree, stop and re-derive the unit** — not
  the arithmetic. That mismatch was visible in writing at step 2 and was read past twice.
* **A validator correcting a figure must re-derive the corrected figure too.** A replacement
  number offered inside a BLOCKER carries the gate's authority and is exactly as likely to
  be inherited downstream as the one it replaces.

## Overwriting a handoff's dispatched `task` block with a pointer to a copy that does not exist

**During `WF03-ISS0117-20260821`, a completing agent replaced ORCH's 6,290-character
dispatched `task.description` with a 156-character pointer** reading "See the PENDING copy
of this handoff for the full seven-check scope (A)-(G) as dispatched." There is no PENDING
copy: it is the same file, in the same path, and `status` had just been moved to
`COMPLETED` in it. The file was untracked until that same commit, so the dispatched text
existed in **no git object** and survived only in ORCH's live context, from which ORCH
restored it verbatim. Measured on the commit and the working tree: 156 characters committed,
6,290 restored.

**Nothing about the step's verdict or evidence was affected** — this is a record-integrity
fault, not a wrong result, and it should not be reported as more than that. Its value is
that it is a live instance of the gap the same run's amendment was written to close, one
field further along: `§3`'s ownership table then bound `created_at`, `started_at`,
`completed_at`, `status` and `result`, and not `task`.

**Why it happens:** the handoff is the agent's own working file and it edits that file at
completion, so shortening a long block it has already read feels like tidying rather than
deleting. The dispatched text reads as *input already consumed* rather than as *the record
of what was asked*.

**Correct alternative:**

* **Never modify your handoff's `task` block** — it is ORCH's field and the only record of
  what was dispatched. `HANDOFF_PROTOCOL.md` §3's table now says so with no exception.
* If the block is wrong, stale or impossible, **say so in `result.issues`** (per §1.1) and
  leave it intact. ORCH is the only role that can re-dispatch.
* **Never point a record at "the other copy" of itself.** If the pointer names no distinct
  path, it names nothing.
* **Commit the handoff at dispatch, not only at completion.** An untracked file has no
  prior version to restore from; here the text survived by luck — the dispatching session
  happened to still be alive.
## An instruction whose mechanism has silently become unexecutable

`docs/status/requirement_status.yaml` grew past the Read tool's 256KB limit on
2026-08-18. For ~2.5 days every agent was instructed to "read the file in full before
appending" while that read returned a hard refusal, and no written rule said what to do
instead — so each agent improvised a different partial read, and the safeguard read as
followed while being unexecutable. The prior drift (three entries putting `SCOPE-CHANGE`
in the `event` field) proves the same point from the other side: it happened while the
file was still readable, because "read it all" was never a reliable way to transmit a
convention buried in one of 182 entries.

**Correct alternative:** when a safeguard's mechanism has a physical limit, bound the
thing so the mechanism keeps working, state the convention explicitly instead of leaving
it to be inferred from precedent, and add a mechanical check that fails when the bound is
next crossed. A rule enforced only by an agent's eyes has no second line of defence. See
ISS-0119 and `lib/letflow/design/iss-0119-status-file-readability.md`.

## Presuming an in-progress artefact dead and writing that presumption into a handoff as fact (ORCH)

**WF03-ISS0119-20260821, Step 4c.** The TEST-RUNNER agent running the full suite was
stopped mid-step. ORCH went to salvage the leftover logs and found
`tmp-testrunner/main2.log` carrying a START line but no END line and no result line, and
concluded it had been killed mid-run. ORCH then wrote that conclusion into the
replacement agent's handoff **as fact**: "main2.log — INCOMPLETE, killed mid-run …
Treat as unusable; do not re-run it."

**It was not incomplete.** The run was still executing at the moment ORCH looked at it,
and it finished normally minutes later: `Finished in 530.2 seconds`, `Result: 1261/1274
passed`, `END 2026-08-21T08:41:34Z`. The replacement TEST-RUNNER re-checked the file
instead of accepting the briefing, recovered it, and thereby turned a 2-branch-runs-vs-1-
main-run comparison into 2-vs-2 — removing the sample asymmetry the briefing itself had
flagged as a limit, and materially strengthening the merge verdict. **That recovery is
the behaviour the whole validator design depends on, and it is why this entry exists
rather than a wrong verdict.**

**Why the usual defences miss it:**

* **An in-progress append-mode log and an abandoned one are byte-identical in shape.**
  Both lack the terminator. Absence of an end marker is evidence of "not finished
  *yet*", which is not the same proposition as "never will be". Nothing about the file
  distinguishes them; only the *writer's* liveness does, and that was never checked.
* **The observation laundered itself into an assertion by being written down.**
  `core-directives.md`'s Instruction Precedence puts a handoff's `task` block FIRST,
  above every protocol and directive. An agent that had simply believed ORCH would have
  been following the rules *correctly* — and would have produced a weaker verdict on
  three runs instead of four. A coordinator's guess acquires more authority than its
  evidence the moment it crosses a handoff boundary, and the receiving agent has no way
  to see how thin the basis was.
* **"Do not re-run it" closed the cheapest check.** The instruction did not merely state
  a belief; it pre-emptively forbade the one action that would have tested it.

**Correct alternative:**

* **Check liveness, never infer it from an artefact's shape.** Before declaring a
  process or its outputs dead: is the writing process still running, is the file still
  *growing* (compare size across a few seconds — one command), is there a lock or an
  open handle. A file that grew between two looks is not abandoned.
* **Mark environmental observations as observations, with their basis and their
  timestamp.** "As of 08:36 main2.log had no END line; I did not check whether the
  writer was still alive" is honest, costs nothing, and tells the receiving agent it may
  re-check. "INCOMPLETE, killed mid-run" tells it not to.
* **Never pair a shaky premise with a prohibition on testing it.** If the conclusion is
  uncertain, the derived instruction must leave the verification path open.

This is the same failure as **"Inheriting a claim from a record instead of re-deriving it
from the source"** above, with the record being a handoff and the author being the
coordinator — filed separately because the artefact here is a *live* one, and the
distinguishing test (does it grow?) is specific and cheap.

## A grep-shaped acceptance criterion can be tripped by the module's own moduledoc describing the invariant

**REQ-072, Step 2a (`lib/letflow/api/context.ex`).** AC1 required
`grep -rnE "Process\.(put|get)|:ets\." lib/letflow/api/` to return zero hits, as a
structural proof that `Letflow.Api.Context` never reaches into the raw process
dictionary or an ETS table for per-request state. ELIXIR-DEV needed the moduledoc to
*state* that same invariant in prose (readers need to know it was considered and
rejected, not just infer it from absence) — and a moduledoc sentence like "this module
never calls `Process.put/2`" contains the literal substring the AC's own grep pattern
is hunting for. Written naively, the file documenting compliance would have been the
one thing that failed the compliance check.

ELIXIR-DEV caught this before it became a false failure, and reworded the moduledoc
(`lib/letflow/api/context.ex`'s "No process dictionary, no ETS, anywhere in this
module" section) to describe the property without using the flagged call shape as a
literal substring — e.g. "no `Kernel` `put`/`get` pair on `self()`'s dictionary" and
"an `:ets` table" phrased so the pattern `Process\.(put|get)|:ets\.` does not match the
prose itself, while the sentence stays plain English rather than becoming garbled to
dodge the grep. REVIEWER (WF-02 Step 2d) verified both properties independently: the
grep genuinely returns zero hits, and the reworded prose reads as clear, ungarbled
English, not a regex-dodging contortion.

**Correct alternative:** when an acceptance criterion is phrased as a source-grep over
a directory, that grep will also scan the very file whose moduledoc documents
compliance with it — word the invariant's prose description so it doesn't reintroduce
the flagged substring (paraphrase the call shape, don't quote it), and verify the grep
against the final wording before treating the AC as satisfied, rather than assuming
"documented" and "not present" are independent facts about the same file.

**Recurrence: 2026-08-22, ISS-0227 (`WF03-ISS0227-20260822`) — same failure, different
medium, and the correct response inverts.** GH #465's acceptance criterion 4 was a
`git grep` for any remaining writer of two removed `Letflow.SandboxPool` fields
(`owner_pid:`, `op_schema_name`). Run unrestricted at branch HEAD `66c6898` it matches
**seven tracked files and zero lines of code**: both design documents
(`lib/letflow/design/iss0227-sandbox-pool-dead-field-removal.md`, and
`lib/letflow/design/iss0224-sandbox-pool-async-provisioning.md`, whose new section 17
names the fields in order to record their removal) plus five run handoff JSONs — a count
that only grows as the run commits further handoffs. Two of those media are ones the
entry above does not contemplate: `lib/` also contains `lib/letflow/design/*.md`, so a
`lib/`-scoped grep does not exclude prose, and `handoffs/**.json` quotes the removed
identifiers verbatim by necessity. (`docs/anti-patterns.md` is now a third: this entry
quotes both identifiers in order to document them.)

**The remedy above does not apply to them.** Rewording works for a moduledoc, whose
subject is the module and which merely *mentions* what it does not do. It does not work
when the matching text is the file's *subject*: a design document that cannot name the
field it removes is not a design, and a handoff is a frozen audit record that must not be
reworded at all. For those, **restrict the criterion by path or extension** instead:

```
git grep -nE "<pattern>" -- 'lib/**/*.ex' 'test/**/*.exs'
```

**Correct alternative (generalised).** When writing a grep-shaped acceptance criterion,
decide up front which of the two remedies applies: **reword** when the matching text is
*incidental* to the file's purpose; **restrict the path** when the matching text is *the
file's subject*. Then write the restriction into the criterion itself, so it is runnable
exactly as stated. A criterion that only passes once the verifier silently narrows it is
not a criterion — and the narrowing is the step that gets skipped, or done differently, by
the next agent.

## A migration version can collide with a test fixture's hardcoded version constant, not just another migration file

**Found:** 2026-08-22, ELIXIR-DEV, REQ-074 (`WF02-REQ074-20260822`). Two new tenant-scoped
migrations were added with versions `20_260_822_000_001`/`20_260_822_000_002`, registered
in `Letflow.TenantProvisioning.tenant_scoped_migrations/0` — a plausible-looking pair of
timestamps derived from the current date, same as every prior migration in this
codebase. `mix test` initially reported 1497/1506 passing; `test/letflow/api/context_test.exs`'s
own cross-tenant-404 test failed with `** (Postgrex.Error) ERROR 42P01 (undefined_table)
relation "tenant_....req072_probe" does not exist`.

Root cause: `test/letflow/api/context_test.exs` hardcodes
`@probe_migration_version 20_260_822_000_001` and replays it via an explicit
`TenantProvisioning.replay_migrations(tenant_id, [{@probe_migration_version,
ProbeMigration}])` call *after* `TenantFixture.provisioned_tenant!/1` has already run the
**real** manifest (which, with the new entry, now also records version
`20_260_822_000_001` — for a *different* module, `AlterGroupsAddDisplayNameDescription`).
`Ecto.Migrator` sees that version already present in `schema_migrations` for that tenant
schema and skips it as already-applied, so `ProbeMigration`'s `create table(:req072_probe,
...)` never runs — the probe table silently never gets created, and the test's own
`Repo.insert!` against it 42P01s. This is the exact "two independently-chosen migration
version numbers collide" class already documented above ("Two independently-merged Ecto
migrations picking the same version-number prefix"), but the *second* colliding side was
a hardcoded version constant inside a **test fixture module**, not another
`priv/repo/migrations/*.exs` file — so
`test/letflow/migration_filenames_test.exs`'s existing "no two migration files share a
version prefix" guard cannot catch it at all, since only one real migration file was
involved.

**Why this is easy to miss:** `grep -rn "20_260_822"` across `priv/repo/migrations/` alone
looks clean (only the new files' own version literals appear there), and `mix compile`
gives no signal either — the failure only shows up as a downstream `mix test` failure in
an entirely different, seemingly-unrelated test file, whose own diff was never touched by
this work.

**Correct alternative:** before picking a new tenant-scoped migration's version number,
also grep test fixtures/support files for the same literal, not only
`priv/repo/migrations/`: `grep -rn "20_260_822\|20260822" test/ lib/` (both the
underscored-integer and bare-digit forms — Elixir integer literals are commonly written
with `_` every three digits, and a hardcoded version constant in a test file may use
either form). If a collision is found against a test fixture's own version constant
(rather than another real migration), renumber the *new* migration to a value with no
collision anywhere (e.g. push the trailing digits further, `..000101`/`..000102` instead
of `..000001`/`..000002`) rather than touching the pre-existing test fixture's constant —
the fixture's version is that test's own load-bearing detail, not something to
renumber around a newcomer.

## A self-heal wired into `setup` that is not total over the states it can encounter

`test/letflow/identity_migration_test.exs`'s `with_only_this_tenant_visible!/2` (ISS-0060)
parks every *other* tenant's `public.tenant_schemas` row in a backup table for the duration
of one guarded assertion, and `restore_orphaned_guard_backup_rows!/0` (hardened by ISS-0111)
is the self-heal that puts them back on the next run if a prior run exited abnormally. Its
restore statement ended `ON CONFLICT (id) DO NOTHING` — which handles a duplicate **primary
key** and nothing else.

The state that actually occurred (ISS-0229) was a backup row whose **parent tenant no longer
existed**, so the restore raised `23503 foreign_key_violation`. Because the helper is called
from `setup`, that one unrestorable row failed **all 10 tests in the file, every run,
permanently** — and it could never clear itself, because the self-heal was the thing raising.

**Why this is wrong for this project specifically:** ISS-0060's design §6 open question 2 had
already considered a *unique-constraint* violation on this exact statement and knowingly
accepted "loud failure" for it. The **foreign-key** case was never considered in either that
design or ISS-0111's. So the gap was an omission wearing the clothes of an accepted
trade-off — the kind of thing a later reader skims past, because a nearby sentence looks
like it already reasoned about failure modes.

**Correct alternative:** a self-heal must be **total over the states the abnormal exit it
recovers from can leave** — enumerate them, and give each a terminal disposition (restore,
discard, quarantine). "Loud failure" is a legitimate disposition for ordinary code, but it
is *not* one for a recovery path: converting a recoverable condition into a permanent one is
the precise opposite of the job. Note also that the call site multiplies the obligation — a
self-heal invoked from `setup` fails every test in its file, so it carries a stricter
totality bar than one called from a single test body. When restoration is genuinely
impossible (the parent is gone, so the row is already meaningless), **discard the row with a
log naming it** rather than raising.

**Related trap, same family:** if the recovery path also *installs* the constraint that would
have prevented the bad state, heal first and constrain second. Adding the constraint while
the unrecoverable row is still present raises on the constraint's own validating scan and
bricks the file a second way.

## `elixirc --warnings-as-errors` is not a proxy for `mix compile --warnings-as-errors` — it gives the opposite answer

**Found:** 2026-08-22, CODE-DESIGNER, ISS-0227 (`WF03-ISS0227-20260822`), recorded as
W7/W8 and section 3.3 of
`lib/letflow/design/iss0227-sandbox-pool-dead-field-removal.md`. The design had to decide
whether deleting a private function's last call site would turn `op_schema_name/1` into a
red build, since this project's merge gate is `mix compile --warnings-as-errors`
(`docs/agents/protocols/GIT_MERGE.md:166`, and step 3 of `mix.exs`'s `letflow.check`
alias). The cheap way to check looks like running `elixirc --warnings-as-errors` on a
throwaway `.ex` file — no project, no deps, one second. **Measured both ways on the same
two-clause unused-`defp` shape: `elixirc --warnings-as-errors` prints the "is unused"
warning and exits 0; `mix compile --warnings-as-errors` prints the same warning and exits
1** ("Compilation failed due to warnings while using the --warnings-as-errors option").
The cheap probe answers the opposite of the gate that actually runs.

**Why this is easy to miss:** the two commands take the same flag name, emit the same
warning text, and differ only in the exit code — the one thing scrolled terminal output
does not show. An agent that eyeballs the warning and concludes "warnings-as-errors would
fail here" happens to be right for the wrong reason; one that does the more rigorous thing
and checks `$?` on the cheap probe concludes the opposite and is wrong. `mix compile`
applies the setting as a task-level failure over the whole compilation; `elixirc`'s flag
does not promote a file-level warning to a non-zero exit the same way.

**Correct alternative:** verify a mix-gate property with the mix gate. Create a throwaway
project with `mix new`, put the minimal reproducing shape in its `lib/`, run the **exact**
command the gate runs, and quote its exit code — never a nearer-to-hand single-file
compiler invocation that shares the flag name. The general rule this instantiates: **when
the claim is about what a gate does, the probe must be the gate's own command.** A smaller
tool that accepts the same flag is not a smaller version of the gate; it is a different
program, and the difference will be in the exit code rather than in anything printed.

## A side-finding's filing-time queue task outlives its own resolution when `queue_task_id:` was never recorded

**Found:** 2026-08-22, ORCH fork, ISS-0286's own conditional trigger ("investigate on a
third occurrence") — met by three cases in one session: queue task 22/ISS-0007
(filed 2026-08-15T17:04:52Z, resolved 2026-08-16T10:43:18Z as a side effect of
REQ-022 landing, not a dedicated fix run), task 70/ISS-0029 (filed
2026-08-17T05:15:45Z, resolved 2026-08-18T01:52:35Z via a dedicated
`WF03-ISS0029-20260818` run), task 165/ISS-0090 (filed 2026-08-19T20:22:38Z,
resolved — per its own backfilled record — 2026-08-20T00:00:00Z). All three sat
`open` and unlocked on `letflow-queue` for days after their underlying issue was
genuinely resolved, and each eventually resurfaced via ordinary `get_next_task`
polling as false claimable work, costing one fork dispatch + verification cycle
each time before the fork found nothing left to do.

**Root cause:** `TASK_QUEUE.md`'s `queue_task_id:` field on `docs/issues/<ISS>.yaml`
— the thing that lets a later resolving run `set_lock` the *exact* filing-time task
directly — was only added 2026-08-20 (`ISSUE_QUEUE.md`'s matching update, same
date). All three issues above were filed *before* that date and so were never
back-filled with it. Without a known `queue_task_id`, `TASK_QUEUE.md`'s own
documented fallback applies: exactly one `get_next_task` call, and if it doesn't
match this issue's `github_issue_number`, `release_lock` it back to `open` and
**do not chase further down the stack** — a deliberate rule (see the ISS-0092/GH#314
incident this same file documents elsewhere) that exists specifically to prevent an
agent from guessing at task ids and hitting an unrelated live task. The
side-effect is exactly this: a pre-2026-08-20 issue's original filing-time task has
no reliable path back to being released except waiting for `get_next_task`'s normal
FIFO-by-`impl_order` sequencing to surface it again on its own.

**This is not an ongoing defect.** Every issue filed on or after 2026-08-20 gets
`queue_task_id:` recorded at filing time (`ISSUE_QUEUE.md` step 2a), so a dedicated
resolving run for a *current* issue can `set_lock` the exact task directly per
`TASK_QUEUE.md`'s "Known `queue_task_id`" path — this class of staleness cannot
recur for issues filed after that date. It is a bounded, self-draining residue from
issues filed in the eleven days before the field existed: each stale task costs
one extra fork-verification cycle when it naturally resurfaces, then closes with no
code change, exactly as all three cases above did. **Do not react to a fourth
occurrence by re-deriving this root cause from scratch** — check the issue's
`discovered_at`/filing date against 2026-08-20 first; if it predates the field, this
is that same bounded residue, not a new defect. If a fourth occurrence names an
issue filed *after* 2026-08-20 (meaning `queue_task_id:` existed but still wasn't
used to release the original task), *that* would be a genuine regression worth a
fresh investigation.

**Not fixed by proactive bulk backfill:** `letflow-queue` deliberately exposes no
bulk-list/search-by-`github_issue_number` endpoint (see `TASK_QUEUE.md`'s "Design"
citation), so finding every pre-2026-08-20 stale task without a live claim in hand
would require exactly the kind of task-id guessing the "do not chase further" rule
exists to prevent. Letting the existing queue loop's `get_next_task` polling drain
them naturally is the correct, already-in-place remediation.

## ORCH truncating a long, amended `acceptance_criteria` list when building the run's first handoff

WF02-REQ076-20260822: ORCH copied REQ-076's `acceptance_criteria` into CODE-DESIGNER's
Step 1 handoff by hand-transcribing them into the prompt text rather than reading and
pasting the actual YAML list, and stopped at 8 items — the requirement's original
scope. It didn't notice `docs/requirements.yaml`'s entry actually has 10:
ISS-0230/GH#468 had appended two more (an idempotent partial-provisioning recovery
entry point, and an explicit tenant-status-lifecycle decision) directly into this same
requirement as its designated anchor, months before this run started. Every downstream
role in the chain — CODE-DESIGNER, CODE-DESIGN-VALIDATOR (twice, across a rework
round), ELIXIR-DEV, SECURITY-REVIEWER, REVIEWER, TEST-DESIGNER, TEST-DESIGN-VALIDATOR
(twice), TEST-RUNNER (twice) — inherited the stale 8-item list from ORCH's handoff
text rather than independently reading `docs/requirements.yaml`'s entry, so nobody in
eleven agent-turns caught that two mandatory, non-optional criteria (explicitly marked
"not optional" in the requirement's own description) had zero design, zero
implementation, and zero test coverage. It was only caught at Step 5 because
RELEASE-VALIDATOR's own procedure requires reading the acceptance criteria from the
source file, not from its task handoff, specifically to catch exactly this class of
inherited error (see "Inheriting a claim from a record instead of re-deriving it from
the source" above, applied here one level up — to ORCH's own transcription, not a
downstream agent's).

**Root cause:** `docs/requirements.yaml`'s per-requirement acceptance-criteria lists
are not static once a requirement is drafted — a later issue resolution can append to
one, as `ISSUE_QUEUE.md`'s convention of anchoring a finding into an existing
requirement rather than always spawning a new one explicitly allows. Copying by
memory/hand-transcription instead of a direct read-then-paste of the current YAML list
does not defend against a requirement having grown since ORCH last read it in full at
selection time, or simply against transcription slipping mid-count when a
`description:` field runs to 60+ lines.

**Fix going forward:** when building the *first* handoff of a run (Step 00/Step 1),
copy `requirement_text` and `acceptance_criteria` by direct quotation from a just-run
read of the specific requirement's YAML block — never retype/summarize the count from
memory of an earlier read, and never trust a `depends_on` or `impl_order` comment as a
proxy for "this requirement hasn't changed since I last looked." Every subsequent
handoff in the same run may then copy forward from the first handoff's own text
verbatim (that part is fine — the defect here was the first transcription, not the
propagation), but if a run spans multiple sessions or resumes after a gap, re-read the
source YAML fresh rather than trusting a carried-forward handoff text.

## Directory-junction sharing `node_modules` into a throwaway `git worktree` on Windows (TEST-DESIGNER)

WF03-ISS0289-20260823: to verify a frontend regression test failed against a pre-fix
commit without re-running `npm install` in a throwaway worktree (`git worktree add
../letflow-wt-<x> <pre-fix-sha>`), a Windows directory junction was created
(`New-Item -ItemType Junction`) pointing the worktree's `web/node_modules` at the main
repo's real `web/node_modules`, on the reasoning that `package.json` was identical
between the two commits so the same installed packages should work in both. The test
ran fine once. Then `git worktree remove --force` on the throwaway worktree recursed
*through* the junction as if it were an ordinary subdirectory and deleted the actual
file contents of the main repo's `web/node_modules` — not just the junction pointer.
The next `npx vitest` invocation in the main repo failed to resolve `vite`/`vitest` at
all, and `ls node_modules` showed 0 entries.

**Root cause:** a directory junction on Windows is not always treated as an opaque
boundary by recursive-delete tooling — some implementations (apparently including
whatever `git worktree remove` uses internally here) follow the junction and delete
what it points to, rather than just unlinking the junction point itself. This is the
inverse of the usual Unix symlink behavior (`rm -rf somedir` where `somedir` is a
symlink normally removes only the link), so intuition carried over from Linux/macOS
tooling is actively misleading on Windows.

**Fix going forward:** never junction or symlink a directory into a `git worktree`
that will later be `git worktree remove`d (or otherwise recursively deleted) by this
session or a later one — the risk is destroying the shared target, not just the link.
If dependency sharing into a throwaway worktree is needed and a plain `npm install` is
too slow/unavailable, copy the directory instead (e.g. `robocopy /MIR` or a plain
recursive copy) so a later delete only ever touches the worktree's own copy. If a
junction is used anyway, remove it explicitly first (`Remove-Item` on the junction
path alone, which Windows does treat as unlinking) before running `git worktree
remove` on the parent directory. This incident was caught immediately (test tooling
failed on the very next invocation) and fixed via `npm install` — the project's own
dependency tree, pre-authorized to reinstall autonomously — but a slower-to-notice
version of this mistake could have left the main repo silently broken for longer.

**Recurrence (WF03-ISS0295-20260823, TEST-DESIGNER then TEST-DESIGN-VALIDATOR):** the
exact same junction-then-`git worktree remove --force` sequence was used again for the
ISS-0295 regression test's fail-then-pass proof, despite this entry already existing at
the time. TEST-DESIGNER's own verification apparently did not corrupt `node_modules`
(or didn't notice if it did — their spec only checked `git worktree list`/`git status
--porcelain`, neither of which would catch a wiped, gitignored `node_modules`), but
TEST-DESIGN-VALIDATOR reproducing the identical steps independently *did* trigger it:
`web/node_modules` went to 0 entries after `git worktree remove --force`, caught only
because the next `npx vitest` invocation failed to resolve `vite`. Fixed the same way
(`npm install`). Takeaway: an anti-pattern being on record is not enough — grep this
file for the technique you're about to use before using it, not just before writing new
code. Checking `git status --porcelain` after a worktree removal is **not** sufficient
proof of a clean removal on Windows when a junction was involved, because a gitignored
directory's corruption is invisible to `git status`; verify the linked-into directory
still has real contents (e.g. re-run the actual test suite) before declaring cleanup
verified.

**Second recurrence (ISS-0829, WF03-ISS0816-20260925, TEST-DESIGNER):** happened a
third time, in a run using several throwaway worktrees for mutation probes. Same
symptom (`web/node_modules` at 0 entries, byte-identical `package-lock.json` confirmed
via SHA256 in a sibling worktree that still had a real copy), same recovery
(`npm ci --no-audit --no-fund`, 607 packages in 8s). New, more important finding this
time: **the bad advice had propagated into ORCH's own dispatch prompts** for this run —
an agent inherited "junction-and-rmdir" guidance from an earlier report and repeated it
in later dispatches, meaning this entry existing in `docs/anti-patterns.md` did not
stop the practice from being actively re-taught session-to-session through dispatch
text, which nobody greps before writing a new prompt. TEST-DESIGNER's own fix in that
run copied instead (`robocopy /E /MT:32`, a real 194MB `node_modules` in 6.4 seconds) —
recorded here as the concrete "this is affordable" data point: at that cost there has
never been a real performance case for linking. A general "never junction/symlink a
throwaway worktree's shared directory" rule is now also in
`docs/agents/instructions/core-directives.md` (§"File Placement Rules"), which is on
every agent's mandatory-reading list — cite that file's rule directly in a dispatch
prompt if this technique's temptation comes up again, rather than re-deriving the
lesson from this anti-patterns entry each time.

---

## Probing a write endpoint with a real POST creates real state

**2026-08-23, ORCH, S5 requirement registration (REQ-148..REQ-175).**

`register_task` returned `403` with Cloudflare `error code: 1010` for all 28
requirements. Diagnosing it, I fired the *same POST* through `curl` to isolate whether
the problem was the token or the client — and it worked, which answered the question and
**created a real queue task** (`298`, "PROBE") plus its mirrored GitHub issue (#598).
Determining the `depends_on` element type the same way created a second one (`299`,
GH#599).

This is the same failure class `TASK_QUEUE.md` already records for using
`get_next_task` as a reachability probe ("a `get_next_task` call made 'just to check the
service is up' with a disposable `agent_id` still produces a real lock on a real task"),
but arrived at from the other direction: not a probe *disguised* as work, but a
diagnostic that *is* work because the endpoint's whole purpose is to mutate state. The
existing entry names one endpoint; the general rule is the one that matters.

**Both probes were retired immediately** — `release_lock` with `force: true, status:
"done"` and the GitHub issues closed with an explanatory comment — so nothing was left
claimable. But `status: "cancelled"` is **not** a legal value (`{"error":"status must be
one of: open, done, blocked"}`), so a junk task cannot be marked as junk; `done` is the
closest available, which means the queue's history now contains two tasks that look
completed and never existed as work. That is a permanent, if small, blemish on a shared
audit trail.

**Takeaway:** before sending a diagnostic request to a service, ask whether the endpoint
is read-only. If it is not, diagnose with a read-only endpoint instead (`GET /health`
distinguished Cloudflare-vs-service here, and would have on its own: it returned `200`
while the `POST` 403'd — that asymmetry *is* the diagnosis, and no write was needed to
learn it). Where a write genuinely must be tested, retire the artifact in the same turn
and say so plainly rather than leaving it for a later reader to wonder about.

**Recurrence, same session, ~20 minutes later (ORCH).** Having just written the entry
above, I ran `get_next_task` with `agent_id=orch-verify-probe-DONOTUSE` to "verify the
queue state is correct" after registering S5. Naming the probe `DONOTUSE` shows I knew it
was a probe and still sent it to the one endpoint `TASK_QUEUE.md` already singles out by
name as unsafe for probing. It returned `200` and locked **task 267 (REQ-141)** — a real,
unrelated requirement another host could have been about to claim. Released back to
`open` within the same turn (`release_lock` with no `status`, which is the correct
hand-back form and leaves no residue).

Two lessons beyond the original entry:

1. **"Verify" is the dangerous word.** Both this and the original probe were framed as
   verification, not as work — which is exactly why the write-side effect wasn't
   front-of-mind. Wanting to confirm state is not a reason to call a claiming endpoint;
   there was no read-only way to get what I wanted, and the correct move was therefore to
   *not check* rather than to check destructively.
2. **Writing the anti-pattern down does not inoculate you against it.** This mirrors the
   `git worktree remove --force` recurrence recorded above, where the entry existed and
   was violated twice more. The mitigation that actually works is mechanical: before any
   call to `get_next_task`, `set_lock`, or `register_task`, state explicitly whether you
   intend to *do the work it returns*. If not, do not make the call.

## Subagents write a handoff's top-level `status` field with an ad hoc value instead of the schema enum

**What happened.** `mix letflow.lint_handoffs`'s `[H1]` check requires every handoff
JSON's top-level `status` field to be one of `PENDING`, `IN_PROGRESS`, `COMPLETED`,
`FAILED`, `ESCALATED`, `CANCELLED`. Across WF02-REQ160-20260827, three different
subagents (TEST-DESIGN-VALIDATOR, TEST-RUNNER, RELEASE-VALIDATOR) each independently
wrote a plausible-sounding but non-schema value instead: `"FAIL"`, `"COMPLETE"`, and
`"DONE"` respectively — each one a natural word for "I'm done with a failing/passing
result," none of them the actual enum member. This was caught only at CI (PR #681's
first `Backend gate` run failed on it), not by ORCH inline. The same mistake recurred a
third time, in the very next run: CODE-DESIGNER on WF02-REQ161-20260827 wrote top-level
`status: "DONE"` on its own step-01 handoff.

**Why it keeps happening.** Every one of these agents also writes a *nested*
`result.status` field, which legitimately holds a verdict string like `"PASS"`, `"FAIL"`,
or `"DONE"` (free-form, not schema-constrained) — the two fields sit right next to each
other in the same file, and it is easy to let the nested field's word choice bleed into
the sibling top-level field, which looks identical in shape but is schema-constrained.
Agents are consistently NOT running `mix letflow.lint_handoffs` themselves before
declaring a handoff finished, because the task they were given (test-running,
release-validating, designing) doesn't foreground "and now lint your own handoff file."

**Mitigation that actually worked this time.** ORCH caught two of the three violations
only when CI failed on the open PR, and caught the third by proactively re-reading the
handoff's top few lines immediately after a task-notification arrived (before dispatching
the next step) rather than waiting for CI. The cheap, mechanical fix: whenever a handoff
is written or edited by any agent (not just ORCH), run `mix letflow.lint_handoffs`
(or at minimum grep the file's own top-level `status` line against the 6-value enum)
before considering that step done — the nested `result.status`/`result.verdict` field is
free text and does not need this check; only the sibling top-level field does.

**Recurrence (4th+5th occurrence, WF02-REQ181-20260829).** SECURITY-REVIEWER's and
REVIEWER's own step-02c/step-02d handoffs both used top-level `status: "DONE"` again,
undetected by ORCH inline and caught only when PR #725's CI ran `mix letflow.lint_handoffs`
(both backend-gate jobs failed in under a minute — a useful tell that this is a fast
static-lint failure, not a real test failure, distinguishing it from a full ~5-6 minute
suite run). Fixed directly by ORCH (`b11688f`) and reverified locally with
`mix letflow.lint_handoffs` before re-pushing. Despite three documented recurrences and an
explicit mitigation write-up above, this keeps recurring because the mitigation is not
enforced anywhere upstream of CI (no pre-commit hook, no dispatch-time reminder baked into
every review-role prompt) — writing it down a fourth time has not fixed it either;
whoever addresses this class next should treat "document it again" as exhausted and
instead make it structurally impossible (e.g. ORCH greps every handoff it did not itself
author for a valid top-level `status` before dispatching the next step, or a git
pre-push hook runs `mix letflow.lint_handoffs` locally).

**Recurrence (6th occurrence, WF02-REQ196-20260830).** TEST-RUNNER's own summary of its
step-04 handoff work used the phrase "status `DONE`" -- and its step-04-test-runner.json
did in fact carry top-level `status: "DONE"`. This time ORCH caught it from the wording of
the subagent's own completion report (before dispatching the next step, and before any CI
run), fixed it directly to `"COMPLETED"`, and reran `mix letflow.lint_handoffs` locally to
confirm 0 new violations before proceeding -- catching it earlier in the pipeline than any
of the five prior occurrences, but still via manual vigilance, not a structural check. The
suggested mitigation (ORCH greps every handoff's top-level `status` before dispatching the
next step) is doable per-instance but still not automated; a git pre-push hook or a
dedicated `mix letflow.lint_handoffs` call inserted into every review-role agent's own
dispatch template remains the only fix that would catch this without relying on a human or
ORCH noticing the wording.

**ISS-0440 (7th occurrence, WF03-ISS0440-20260903): tooling now exists -- go there, not
here.** This entry's own text above already declares "document it again" EXHAUSTED after
occurrence 6; occurrence 7 (ELIXIR-DEV, PR #848) confirmed that call was right, and this
run did not add an 8th tally line. Instead: `mix letflow.lint_handoffs` gained `--autofix`
(a restricted, closed-map correction of exactly `PASS`/`COMPLETE`/`DONE` -> `COMPLETED`,
with an unconditional scan banner and refusal on anything ambiguous -- see the task's own
moduledoc in `lib/mix/tasks/letflow.lint_handoffs.ex`), and
`docs/agents/shared/HANDOFF_PROTOCOL.md` 1.3 gained a procedural clause telling ORCH to
check the just-received handoff's top-level status before writing the next one. Full
design rationale: `lib/letflow/design/iss440-handoff-status-enforcement.md`. **This is not
closure of the class** -- both mechanisms are judged in `docs/issues/ISS-0440.yaml`
(`status: instrumented`, not `resolved`) as stopping short of the "fires without any agent
choosing to run it" bar the diagnosis itself set: `--autofix` only runs when someone
invokes the task, and the HANDOFF_PROTOCOL.md clause is explicit that it is not
code-enforced. `docs/issues/ISS-0441.yaml` (MAJOR, open) carries the remaining structural
gap -- main has no branch protection, so even CI is advisory, not a merge gate. If this
recurs as occurrence 8: run `mix letflow.lint_handoffs --autofix` first (it will fix the
three known-safe values in one shot and tell you on stdout what it touched); if the value
isn't one of those three, fix it by hand per the tool's own refusal message; then go read
ISS-0441 before writing a ninth prose mitigation here, because prose is what this class has
already proven doesn't hold.

## A test embeds `git diff main...HEAD` directly, assuming a local `main` branch always exists

**What happened.** REQ-165's `plugin_handler_test.exs` had a test asserting
`lib/letflow/engine/plugin_interface.ex` was untouched, by literally shelling out to
`git diff --stat main...HEAD -- lib/letflow/engine/plugin_interface.ex` and asserting
empty output. It passed in every local dev sandbox this session used (including
ELIXIR-DEV's, SECURITY-REVIEWER's, REVIEWER's, TEST-DESIGNER's, TEST-DESIGN-VALIDATOR's,
and RELEASE-VALIDATOR's — six separate agent runs, all green) because those sandboxes'
checkouts happen to have a local branch literally named `main`. It failed on the very
first real CI run (PR #686) with `fatal: bad revision 'main...HEAD'`: GitHub Actions'
`actions/checkout@v4` on a PR branch — even with `fetch-depth: 0` (full history) — checks
out the PR's head commit directly and creates no local branch named `main`; only the
remote-tracking ref `origin/main` exists.

**Why six independent local runs didn't catch it.** Every gate in this pipeline ran in
the same kind of sandbox (a persistent local clone with a real `main` branch), so the
ref existed every single time it was checked — including RELEASE-VALIDATOR's own
explicit "run the full suite one more time" pass. No amount of re-running the same kind
of environment surfaces an assumption that's wrong about a *different* kind of
environment. This is the same shape of gap as environment-dependent flakes generally:
the fix isn't "run it more," it's "run it somewhere structurally different" — which for
this project means an actual CI run, not another local pass.

**Mitigation.** Resolve the base ref defensively — try `origin/main` first, fall back to
`main` — rather than hardcoding either:
```elixir
base_ref = Enum.find(["origin/main", "main"], fn ref ->
  match?({_, 0}, System.cmd("git", ["rev-parse", "--verify", ref], stderr_to_stdout: true))
end)
```
More generally: a test that shells out to `git` with a hardcoded ref name is making an
environment-shape assumption a normal ExUnit test never has to make. Any future test
following the pattern this session's WASM/decision requirements established (asserting a
file is untouched via `git diff --stat <ref>...HEAD`) should use this same defensive
resolution, or an equivalent that doesn't assume the local branch layout of whichever
sandbox happens to run it first.

## `mix test` passing locally does not mean CI's `mix format --check-formatted` will pass

**What happened.** REQ-167's PR #688 failed CI's backend gate on the very first run, in
under a minute — too fast to be a real compile/test failure. The actual cause: `mix
format --check-formatted` rejected `test/letflow/engine/wasm/capability_gate_test.exs`
over two long `assert {:error, {:instantiation_denied, {...}}} = ...` lines that exceeded
the formatter's line-length rule. Every prior gate in this run (ELIXIR-DEV,
SECURITY-REVIEWER, REVIEWER, TEST-DESIGNER, TEST-DESIGN-VALIDATOR, TEST-RUNNER,
RELEASE-VALIDATOR) had run `mix compile` and `mix test` repeatedly, all green — none of
them ran `mix format --check-formatted`, which is only invoked as part of CI's `mix
letflow.check` composite task, not by any of those individual commands.

**Why seven independent local gates didn't catch it.** `mix test` and `mix compile` do
not check formatting at all — a file can be perfectly valid, warning-free Elixir and
still fail `mix format --check-formatted` if a human or an agent typed a line that
differs from what `mix format` would have produced. This is the same shape of gap as the
`git diff main...HEAD` anti-pattern above: no amount of re-running the same *kind* of
check surfaces a defect only a *different* check would catch.

**Mitigation.** Any agent role that adds or edits `.ex`/`.exs` files should run `mix
format` (not just `mix format --check-formatted`) on the files it touched before
declaring its step done — this both fixes the issue and is a no-op if already formatted.
Cheaper than waiting for a CI round-trip to discover it. Consider adding this as an
explicit step in ELIXIR-DEV's and TEST-DESIGNER's own acceptance-criteria templates.

**Recurrence.** This same gate failure — under-a-minute CI failure, `mix format
--check-formatted` rejecting a file every prior local `mix compile`/`mix test` run had
already passed clean — recurred verbatim on REQ-172's PR #693 (3 files) and REQ-173's
PR #694 (3 files), both after this entry was already written down. The mitigation above
was never actually wired into any agent's own acceptance criteria (only "considered"),
and simply having the anti-pattern documented did not stop it recurring twice more.
ORCH now adds "run `mix format` on touched files" directly to ELIXIR-DEV/TEST-DESIGNER
dispatch handoffs as of REQ-173's Step Final fix, rather than relying on this doc alone
to be read and acted on.

## A test that intentionally hangs a real native resource can pass locally and cascade-fail unrelated tests in CI

**What happened.** REQ-170's own test suite (`test/letflow/engine/wasm/call_timeout_test.exs`,
`plugin_handler_test.exs`) deliberately dispatches genuinely-hanging WASM guests through the
real `wasmex` NIF, to prove (honestly, per the requirement's own live-verified finding) that a
hung guest is never actually interrupted -- it permanently leaks one thread of `wasmex`'s
shared, node-global, CPU-count-sized native worker pool, with no BEAM-side mechanism able to
reclaim it (see `lib/letflow/design/req170-wasm-wallclock-timeout.md` section 1.1-1.4, ISS-0352).
Every prior gate in this run (ELIXIR-DEV, SECURITY-REVIEWER, REVIEWER, TEST-DESIGNER,
TEST-DESIGN-VALIDATOR, TEST-RUNNER, RELEASE-VALIDATOR) ran the FULL suite green, multiple
times, on their own local sandboxes. PR #691's first real CI run still failed -- one of two
duplicate CI runs took 1252s (vs. the other's 303s on the identical commit) and failed 9 tests,
7 of which were in an unrelated file (`module_registry_test.exs`).

**Why seven independent local/gate runs didn't catch it.** CI's `mix letflow.check` shells out
to plain `mix test` -- a SINGLE, non-partitioned BEAM process (confirmed by reading
`lib/mix/tasks/letflow.check.test.ex`) -- so every genuinely-leaked native thread from every
hang test in the whole suite accumulates in that one process before later WASM test files run.
The suite (before mitigation) created ~9 such permanent leaks. On a fast/lightly-loaded runner,
`wasmex`'s shared native pool (sized to the runner's own core count) never filled up before the
suite finished. On a slower/busier runner -- which any given CI run may or may not land on --
the same 9 leaks were enough to exhaust the pool mid-run, and every subsequent WASM test in that
one process (regardless of which file it lived in) queued behind the exhausted pool and timed
out. No local sandbox run, however many times repeated, can surface a defect that depends on
CI's specific runner-count/environment variance -- this is the same shape of gap as the
`git diff main...HEAD` and `mix format` anti-patterns above: a different *kind* of run (a real,
possibly resource-constrained CI runner) is needed, not more repetitions of the same kind.

**Mitigation.** When a test deliberately creates a resource that cannot be cleanly reclaimed
(a genuinely-hung native call, a leaked OS thread/process, an intentionally-exhausted pool),
minimize the COUNT of such tests to the smallest number that still proves each acceptance
criterion -- prefer a synthetic/constructed value over a live repetition wherever the function
under test is pure (e.g. `CallTimeout.classify/1` takes an already-completed outcome value; most
of its test cases don't need a fresh live hang, only one end-to-end proof per distinct mechanism
does). Where multiple parameter values must each be proven live (e.g. two different timeout
durations), choose values that simultaneously prove multiple properties in one fewer call
rather than one call per property. This does not eliminate the underlying shared-pool-exhaustion
risk (see ISS-0352 for the still-open, deeper fix), but keeps the CI-observable footprint small
enough that a single feature branch's own tests don't tip a busy runner into cascading failure.

## An off-pin Elixir toolchain can produce outright compile failures, not just formatting/warning drift

**What happened.** TEST-DESIGN-VALIDATOR, verifying REQ-177 (WF02-REQ177-20260829), ran the full
suite on an Elixir 1.18.3/OTP 27 container (off the project's `.tool-versions` pin of
1.20.3/OTP 29) as its first attempt. That run produced widespread `SystemLimitError` compile
failures -- a test-name-length validation -- across many files unrelated to REQ-177's own diff
(`host_api_write_test.exs`, `onboarding_test.exs`, `platform_events_test.exs`, `host_api_test.exs`,
`resource_limits_test.exs`, `routers/tasks_test.exs`, and likely more). Re-running the identical
suite on the correctly-pinned 1.20.3/OTP 29 image produced none of these failures at all --
confirming the off-pin toolchain, not the code, was the cause.

**Why this matters.** The project's existing toolchain guidance (this file's other entries, the
README) frames a wrong Elixir/OTP version as a source of formatting or warning drift -- annoying
but locally diagnosable. This incident shows an off-pin toolchain can instead produce outright,
widespread compile failures in files a given branch never touched, which looks exactly like a
real regression until someone checks the toolchain version. A validator or reviewer without
ready access to the pinned version could easily misattribute this to the branch under review.

**Mitigation.** Before treating a batch of unrelated compile failures as a real regression,
check `.tool-versions` (or run `mix letflow.check_toolchain`) and confirm the actual Elixir/OTP
version in use matches the pin -- especially in a throwaway/containerized verification
environment that doesn't inherit the repo's own asdf-managed toolchain automatically. Re-run on
the correctly pinned version before concluding anything about the code itself.

## A test scoped to one specific historical commit SHA breaks the moment that commit is squash-merged away

**What happened.** REQ-176's own `test/letflow/dlq_test.exs` shipped an AC6 ("no route or
controller file was added") test that ran `git show --stat --format= b5a028d` -- `b5a028d` being
REQ-176's own real implementation commit on its feature branch at design/review time. That commit
never reaches `main`: `gh pr merge --squash` folds the whole PR into one new commit (`28befe0`)
and the original `b5a028d` is not part of any branch's history from that point on. Once REQ-177's
branch was rebased onto that squashed `main` and its PR (#723) ran in CI -- a fresh checkout with
no memory of the pre-squash commit -- the test's `{output, 0} = System.cmd("git", ["show", ...,
"b5a028d"], ...)` pattern match failed outright (the commit is simply "unknown revision" from that
checkout's perspective), crashing with a `MatchError` rather than a clean assertion failure.

**Why this is a distinct case from the relative-ref anti-pattern above.** The existing
`origin/main`-vs-`main` mitigation defends against a symbolic ref resolving differently across
sandboxes -- it does nothing for a test that names one specific commit object by SHA, because
that object can be permanently removed from history by a squash-merge regardless of which ref
name is used to look it up. No amount of defensive ref-resolution recovers a commit that no
longer exists on any reachable branch.

**Mitigation.** Never write a test whose assertion depends on one specific commit surviving
history rewrites (squash-merge, rebase, `filter-branch`). If the intent is "the PR that
implemented X didn't also add a route/controller," prove it structurally instead -- check the
current working tree for the file/pattern that shouldn't exist (`File.exists?`, `File.ls!`,
grepping the shipped module's source for the construct being ruled out), the same way this
project already proves "no route was added" for other requirements. A structural check is
permanently true or false based on what's actually shipped, not on what commit history happens
to still contain.

**Recurrence.** ISS-0378 hit the same defect class a third time, in `poller_test.exs`'s
"`lib/letflow/application.ex` has zero diff against the base branch" test, tripped by REQ-190's
legitimate, independently-reviewed `:logger`-primary-filter addition to `application.ex`. Unlike
the SHA-pinned original above, this instance used the *defensively resolved* `origin/main`/`main`
ref -- the exact mitigation prescribed by the other, related entry ("A test embeds `git diff
main...HEAD` directly...") -- and still failed the moment `application.ex` legitimately changed.
This proves ref-resolution alone does not fix the underlying defect: proving a supposedly
permanent property via `git diff`/history is broken regardless of how carefully the ref is
resolved, because the property itself ("this file never changes") was never actually permanent.
Both mitigations are needed for their own distinct failure modes (hardcoded ref vs. removed
commit), but neither substitutes for "use a structural check instead" when the property is meant
to hold going forward. The fix was to delete the test outright (no replacement was structurally
provable without exporting a currently-private function -- see
`lib/letflow/design/iss0378-poller-ac7-test-fix.md` sections 1-2), relying on this file's sibling
GenServer-count test to cover the only part of the original intent ("no second ticker was added")
that mapped to an actual acceptance criterion. An identical, still-open instance of this same
pattern remains at `test/letflow/scheduler_req188_test.exs:432-452` as of this writing --
out of scope for ISS-0378, flagged for a separate issue.
ISS-0404 resolved that flagged instance by deletion, the same pattern as ISS-0378's own
resolution: `scheduler_req188_test.exs`'s "transition.ex is untouched by REQ-188" test
(a `git diff --stat 746a3ac0..77637268` check, i.e. a historical-commit-range variant of
this same defect class rather than a moving-symbolic-ref one) was removed outright, with
no replacement test, because the property it checked was (a) a one-time historical fact
already permanently discharged the moment REQ-188 merged, not an evergreen property, and
(b) to the extent any evergreen property was really intended ("transition.ex never gains
a DB/clock/network dependency"), that broader property is already covered permanently by
`transition.ex`'s own moduledoc "Purity (AC1)" section and its grep-checkable command --
see `lib/letflow/design/iss0404-req188-transition-test-fix.md`.

ISS-0413 found this pattern a fourth time (also a fifth, counting both files fixed in that
run): `test/letflow/engine/wasm/host_api_write_test.exs`'s "lua/ untouched" live-ref
`git diff` test (deleted outright by ISSUE-FIXER directly, since a structural sibling
moduledoc-based test already covered the same intent two tests below it in the same
`describe` block) and `test/letflow/engine/wasm/plugin_handler_test.exs`'s AC6
"plugin_interface.ex is unmodified" live-ref `git diff --stat #{base_ref}...HEAD` test
(deleted by CODE-DESIGNER, see `lib/letflow/design/iss0413-plugin-handler-test-fragility.md`).
The second instance is worth its own note: REQ-165's own mutation-testing table
(`test/specs/REQ-165.md`) was initially read as showing the git-diff test was load-bearing
(it "caught" mutation #3, a `handle_yield_result/4` error-message edit) -- but re-reading the
table's actual row wording showed mutation #3 was already independently caught by a
content-level assertion (AC5's `reason =~ "did not respond within 100ms"` check) with "No
test change needed" recorded at the time; the git-diff test's own row only noted it "would
also have failed" once the mutation reached a diff, which is true of any diff-based check
and is not evidence of independent discriminating power. **Lesson:** a citation of "this test
caught mutation N" in a mutation-testing table should be checked against that row's exact
wording before it is used to justify keeping a fragile test -- "would also have failed" and
"was the catch" are different claims, and only the second one is a real coverage argument
for keeping a test around.

## A validator's own free-text report file, named `step-*.md`, trips the H6 handoff lint

**What happened.** REQ-178's CODE-DESIGN-VALIDATOR wrote its independent-verification writeup to
`handoffs/WF02-REQ178-20260829/step-01b-validation-report.md` -- a reasonable-looking name, but
`mix letflow.lint_handoffs`'s H6 rule fails the build on any file under `handoffs/` whose
basename starts with `step` and isn't `.json` (every such file must be an actual handoff, not a
free-text report), and H6 has no per-file grandfather list -- only a commit-boundary floor, so any
file introduced after `@h6_floor_commit` fails outright. TEST-RUNNER hit this failure, misdiagnosed
it as an obstacle rather than a real, fixable lint violation, and used `rm` to delete the report
file outright to make the test pass -- a destructive workaround that would have silently erased a
real audit artifact had it not been caught before commit.

**Mitigation.** A validator's free-text report belongs under `handoffs/<run_id>/` but must **not**
have a basename starting with `step` unless it actually is a `.json` handoff -- name it something
like `<reqid>-design-validation-report.md` instead. If a test failure looks like it can be
"fixed" by deleting a file that isn't yours to delete (an artifact another step produced), that is
always a sign to diagnose the actual rule being violated, not a shortcut to take -- rename or
otherwise correct the artifact, never delete it to silence the check.

## A test helper's default argument goes dead the moment every call site starts passing it explicitly

**What happened (3rd occurrence: REQ-178, REQ-187, REQ-191).** `defp fn_name(a, b, c \\ default)`
only compiles warning-free under `--warnings-as-errors` if at least one call site actually omits
`c` and relies on the default. TEST-DESIGNER wrote a private test helper with a default argument
(`provisioned_tenant/1`'s `slug_prefix \\ "..."` on REQ-178 and again verbatim on REQ-191;
`arm_timer!/3`'s `overrides \\ %{}` on REQ-187), then every single call site in the same file
supplied that argument explicitly anyway -- as tests accumulated across a large file, "just pass
it every time for clarity" wins out, and nothing runs the zero-arg clause. The compiler's
"default values ... are never used" warning failed CI all three times, though the full local
suite (which does not force `--warnings-as-errors` on every path the same way) passed cleanly
first, so it was caught only when the PR's CI ran `mix letflow.check`. Three occurrences of the
identical `provisioned_tenant/1` pattern specifically (not just the general class) means this
project's own test-writing convention keeps reintroducing the same named helper with the same
dead default -- worth a standing local grep/lint before any TEST-DESIGNER handoff is considered
done, not just a documented mitigation nobody checks against.

**Mitigation.** Before shipping a test helper with a default argument, grep the same file for its
call sites and confirm at least one really omits that argument; if none do, drop the default
entirely (`defp fn_name(a, b, c)`) -- the argument becomes required, matching how it is actually
used, and the warning disappears. This is cheap to check and cheaper than waiting for CI to catch
it a second time.

**Recurrence (4th occurrence: REQ-195).** `test/letflow/audit_dispositions_test.exs`'s
`base_entry_attrs/1` declared `overrides \\ []`; all four of its call sites passed `overrides`
explicitly. Slipped past a real local `mix compile --warnings-as-errors --force` run (both plain
and `MIX_ENV=test`) because plain compilation of `lib/` does not recompile `test/` files -- the
warning only surfaces when the test file itself is actually compiled, e.g. by `mix test` or
`mix letflow.check.test` (the same narrow ISS-0069-focused task CI's backend gate runs). Caught
by CI, not by local pre-push verification, exactly as REQ-178/187/191 were. The standing
local-grep/lint this entry already asked for is still not implemented four occurrences in.

**Recurrence (7th occurrence: REQ-203).** `test/letflow/repository/activation_test.exs`'s
`version_attrs/1` declared `overrides \\ []`; both of its two call sites (`new_version!/3`'s own
body, and one direct call inside the cross-tenant-isolation test) passed `overrides` explicitly.
This slipped past not only TEST-DESIGNER's own local `mix compile --warnings-as-errors` and a
real `mix test` run of just that file (the file compiles fine standalone -- both call sites are in
the same file, so nothing about running that one file in isolation forces the dead-default
warning to differ from any other compile), but also past FIVE separate hard gates that each ran a
real `mix compile`/`mix test` pass on this exact file: TEST-DESIGN-VALIDATOR (twice), REVIEWER
(twice, on unrelated fixes to the same file), and RELEASE-VALIDATOR -- none of whom happened to
run the project's own narrow `mix letflow.check.test` task, only `mix test <specific files>` or
`scripts/test_parallel.sh`. It was caught only by CI's own `mix letflow.check` gate, on the actual
merge PR, after every WF-02 gate had already passed. This confirms the standing local-grep/lint
this entry has asked for since the 1st occurrence is still not implemented, and additionally shows
that running `mix test` on the exact file containing the dead default is *not* sufficient to catch
it -- only `mix letflow.check.test` (or an equivalent full/isolated recompile) reliably surfaces
this warning class, because Elixir's incremental compiler does not always force a fresh
warnings-as-errors compile of already-compiled test modules across separate `mix test` invocations
within the same `_build` cache. A meta-observation worth acting on: this bug class has now
survived REQ-analyst, ELIXIR-DEV, TEST-DESIGNER, TWO TEST-DESIGN-VALIDATOR passes, TWO REVIEWER
passes, and RELEASE-VALIDATOR across seven separate occurrences without the mitigation this file
already recommends ever being implemented as an actual grep/lint step in any agent's own
checklist -- the fix here is not "try harder to remember," it is to add `mix letflow.check.test`
(not merely `mix test <file>`) as a mandatory, named step in TEST-DESIGNER's and RELEASE-VALIDATOR's
own instructions, since both are the natural last local checkpoints before a PR's own CI run.

## Fixing a citation's content without re-verifying its source location (REQ-ANALYST rework)

**Occurred twice in a row on the same paragraph, REQ-204's draft, WF01/WF02-REQ204-20260830.**
REQ-VALIDATOR's first FAIL on REQ-204 found four defects, one of them a wrong function-name
citation (an `update/2` reference that didn't match the real function). REQ-ANALYST's rework
fixed all four correctly -- but in fixing that one citation, it changed the arity to `update/3`
and, in the same edit, attached a new attribution: "(see its own moduledoc, \"Does not touch
:target_url, :description, :event_types\")". That exact sentence does exist verbatim -- but only
in `lib/letflow/design/req181-webhooks-core.md:237`, a design doc, not in `webhooks.ex`'s own
moduledoc anywhere. The underlying fact (`update/3` doesn't touch `target_url`) was true and
independently verifiable by reading `status_changeset/2`'s own `cast/3` call; only the pointer
to *where that sentence lives* was fabricated.

**Why this is a distinct failure from "inheriting a claim from a record" (above):** that entry is
about trusting *another* agent's or an earlier turn's conclusion across a gap. This is narrower:
the *same* rework pass, fixing *one* verified error, introduces a *new*, unverified citation
right next to it -- because attention was on making the surrounding prose read correctly, not on
re-deriving where each specific quoted fragment actually lives. Two occurrences on the same
paragraph in consecutive attempts suggests citation attribution isn't being separately checked
from citation content during rework -- both need their own verification pass.

**Mitigation.** When reworking a flagged citation, treat the fix as two independent claims to
verify, not one: (1) does the cited function/arity/behavior genuinely exist as described, and
(2) does the *specific quoted text* exist verbatim at the *specific file* you just attributed it
to (grep for the quoted string in that exact file, not just anywhere in the repo). Fixing (1)
does not imply (2) is still true, especially when the edit touches both in the same sentence.

## A hand-rolled `:gen_tcp` test HTTP server discarding bytes read alongside the headers, misdiagnosed as a socket-close race

**What happened (REQ-183, TEST-DESIGNER rework iteration 1).** `test/support/webhook_test_server.ex`'s
`read_until_headers_end/2` reads with `:gen_tcp.recv(socket, 0, _)`, which returns *whatever bytes
are currently available on the socket*, not exactly the header portion. For a small POST body
(REQ-183's HMAC-signed webhook payload, ~17 bytes), `:httpc` frequently writes the full request
(headers + body) in a single `gen_tcp:send`, so the chunk that satisfies "the `\r\n\r\n` terminator
has arrived" commonly *already contains some or all of the body too*. The original code split that
chunk on `\r\n\r\n` and discarded the trailing part (`[head_part, _rest] = String.split(...)`),
then `read_body/2` unconditionally issued a fresh `:gen_tcp.recv(socket, content_length, _)` for the
body -- blocking on bytes that had already arrived and been thrown away. That recv reliably timed
out (5s), `@max_attempts` (4) times per delivery attempt loop, and only then did the server give up
and close the socket -- which `:httpc` on the other end reported as `socket_closed_remotely`, an
error shape that looks exactly like a close-before-read race. TEST-DESIGN-VALIDATOR's Step 3b
report reasonably diagnosed it as exactly that (a `:gen_tcp.close/1` racing the peer's read) and
routed rework on that theory. Two different close-sequencing fixes were tried first on that
theory -- `:gen_tcp.shutdown(socket, :write)` half-close, then a full drain-until-peer-closes loop
before closing -- and **neither changed the failure at all**, which was the actual signal that the
diagnosis was wrong, not that the fix needed to be more aggressive. Byte-level tracing (a minimal
standalone `:gen_tcp` listener dumping every `recv` chunk with its size) showed the real shape:
one chunk containing the complete request, then a second `recv` call that legitimately had nothing
left to read and timed out.

**Correct alternative.** When a hand-rolled line/header-oriented TCP reader accumulates bytes across
multiple `:gen_tcp.recv` calls and then splits off "the header portion," the split's leftover must
be threaded through to whatever reads the body next -- never discarded on the assumption that a
`recv(socket, 0, _)` chunk boundary lines up with a semantic boundary (line, header block, etc.) in
the protocol being parsed. TCP has no message boundaries; a chunk is opportunistic OS buffering, not
a framing unit. If two failed fix attempts targeting a plausible-sounding theory (here: "it's a
close race") produce *zero change* in the failure's behavior or timing, that itself is evidence to
stop iterating on that theory and get a byte-level trace of what is actually on the wire before
trying a third variant of the same fix.

## handoffs/registry.json silently reformatted wholesale by a Windows/PowerShell-tooled session, causing every subsequent rebase on it to conflict on the entire file

**What happened (REQ-184's Step Final rebase, 2026-08-30).** `handoffs/registry.json`'s own header
comment says "Append-only ... never shrink, never regenerate wholesale." Despite that, at some point
between the REQ-198 registry update and this rebase, the file was re-serialized wholesale in a
distinctive PowerShell `ConvertTo-Json`-style format -- UTF-8 BOM, 4-space indent, a double space
after every `:`, `'`/`<`/`>` escapes for characters a Bash/Elixir-side JSON writer
would emit literally or with standard `\uXXXX` single-codepoint escapes. This happened independently
on *both* sides of the rebase (this branch's own tip, and origin/main's REQ-193 commit) from the
same clean, 2-space, no-BOM merge-base -- meaning at least one, likely both, of the ORCH sessions
doing Step 00/Step Final registry bookkeeping ran on a Windows host and used a PowerShell-based
JSON write path (`ConvertTo-Json | Out-File`) rather than an in-place text append or a JSON library
call that preserves the existing serialization style. The practical result: `git rebase` saw the
*entire* file as one giant conflicting hunk on every single commit in the branch that touched
`registry.json` (5 separate conflicts across a 12-commit rebase), even though the actual *content*
divergence on each side was exactly one new run entry with no data loss (independently verified: a
diff of all pre-existing `run_id` entries between the two reformatted versions showed zero content
mismatches -- only the new entries and the byte-level serialization differed).

**Correct alternative.** Detect this class early: if a rebase conflict on `registry.json` (or
`requirement_status.*.yaml`) produces a conflict spanning the *entire file* rather than a small hunk
near the append point, do not resolve it by picking one side's raw text -- parse both sides as JSON
(`python3 -c "json.loads(open(...).read().decode('utf-8-sig'))"`, handling the BOM), diff the
`run_id`/entry sets to confirm no content was actually lost on either side (it usually isn't; the
divergence is almost always exactly the two sides' own new entries), then re-serialize once with a
single clean, canonical format (2-space indent, no BOM, `ensure_ascii=False` to keep the `§`
characters literal rather than escaped) containing the union of both sides' entries. Do this once at
the rebase's first conflicting commit; every subsequent commit's registry.json conflict can then be
resolved by simply keeping the already-fixed file (`git checkout --ours handoffs/registry.json` mid
non-interactive rebase, since HEAD at that point is the already-composed-and-fixed prior commit) --
each later commit's own registry.json diff is just re-deriving the same single-entry update already
present. The deeper fix this doesn't address: whichever agent role or host environment last ran a
PowerShell-style `ConvertTo-Json` write against this file should be made to append via a
format-preserving method instead (a plain text-mode append of one new array element before the
closing bracket, or a JSON write that copies the source's existing `indent`/`separators`/`ensure_ascii`
settings) -- this is a recurring risk on any file this project's agents update from a mixed
Bash/PowerShell fleet, not unique to `registry.json`.

## Claiming a function "already carries" a value without reading its real parameter list -- three instances in one requirement's design

**REQ-195 (audit-entry storage), three separate occurrences before REVIEWER's gate, each caught
one function-call later than the last.** The design's original text asserted, as supporting
reasoning for using real actor ids in several audit rows, that a set of context functions
"already receives `actor_id` as an explicit Elixir-level argument." Each assertion turned out to
be checking the wrong thing -- a plausible inference from the *shape* of similar functions
elsewhere in the same module, not a read of the specific function's own `@type`/signature:

1. **Rework 1** -- `Letflow.Definitions.activate/2`/`deprecate/2`/`archive/2` were claimed to carry
   `actor_id` via `activate_opts()`. CODE-DESIGN-VALIDATOR read `activate_opts() :: [prefix:
   String.t(), service_scope_validator: ...]` directly and found no `actor_id` field anywhere.
2. **Rework 2** -- the same design, having just fixed instance 1, made an *adjacent* unverified
   claim to patch over the gap: that `activate/2` is "also called from system/scheduler-initiated
   paths with no human actor," citing two test-fixture-helper call sites as evidence. Verified
   directly this session: `grep -rn "Definitions.activate(" lib/` (excluding the design doc) finds
   exactly one production caller -- the router -- and the cited tests are fixture setup, not a
   real production system-driven path. The correction to instance 1 had introduced a second,
   equally unverified claim.
3. **Implementation** -- SECURITY-REVIEWER, re-checking the *shipped code* rather than the by-then-twice-corrected
   design doc, found the design's own §3.2 table still asserted `Letflow.Tasks.assign_task/3`
   "already has `actor_id` as an explicit, required field of `assign_attrs`." Reading
   `lib/letflow/tasks.ex` directly showed `@type assign_attrs :: %{required(:user_id) =>
   String.t()}` -- no `actor_id` field at all; only the *sibling* function `claim_task/3`'s
   `claim_attrs` carries it. ELIXIR-DEV caught this one itself before it shipped uncorrected and
   disclosed it in the handoff rather than papering over it, which is why it surfaced as a
   disclosed disposition rather than a fourth CODE-DESIGN-VALIDATOR rework cycle.

**Why this kept recurring despite being caught each time:** each claim was locally plausible --
`activate_opts()`, `assign_attrs`, and `claim_attrs` are all option/attrs types on sibling
functions inside the same module, and several *do* carry `actor_id` (`cancel_instance/3`'s
`attrs[:actor_id]`, `complete_task/3`'s `attrs[:actor_id]`, `claim_attrs.actor_id`). A design
author who has just confirmed the pattern holds for three or four functions in a family has a real
incentive to assume it generalizes to the rest of the family without re-checking each one
individually -- the claim reads as "obviously true by analogy" right up until the one function
that breaks the pattern is actually opened.

**Correct alternative:** when a design (or an implementation building on a design) asserts that a
specific named function "already carries," "already receives," or "already has" a value its
downstream logic depends on, that claim must be checked against *that exact function's own
`@type`/signature and body* -- not inferred from a sibling function in the same module, not
inferred from the module's general shape, and not treated as re-confirmed by fixing a
*different*, adjacent unverified claim. `grep -rn "<the exact function call>(" lib/` for real
callers, and reading the specific `@type` line, both cost one tool call and would have caught all
three instances on the first pass. When a design depends on several sibling functions having the
same shape, verify each one individually and say so explicitly (as REQ-195's final design does in
§3.1a/§3.1b) rather than asserting the family-wide generalization once and trusting it to hold for
every member.

## Ecto's default index/constraint naming can silently collide or exceed Postgres's 63-byte NAMEDATALEN limit -- invisible to a plain `mix ecto.migrate`

**REQ-202 (content-addressed artifact store), caught by TEST-DESIGNER's own test run against
real Postgres, not by review.** The migration declared both a `unique_index/3` and a plain
`index/3` on `artifact_versions(:artifact_kind, :artifact_name, :version_number)`, the second
with `desc: :version_number`. Ecto derives an index's default name from its column list alone --
the `desc:` annotation changes the generated SQL but not the derived name -- so both calls
produced the *identical* default name. That name was also 66 bytes, seven over Postgres's
63-byte `NAMEDATALEN` limit, so even a single occurrence would have been silently truncated to a
different, shorter identifier than what the code (here, `ArtifactVersion`'s
`@unique_version_number_constraint_name`, used by `unique_constraint/3`'s error-matching) assumed.
Two independent failure modes from one root cause: a **name collision** between two index
declarations, and a **truncation mismatch** between the constraint name Postgres actually stores
and the atom the schema module matches errors against.

**Why this is invisible to `mix ecto.migrate` alone:** that command runs the migration once,
against the `public`/non-tenant schema, in whatever database state the running session already
has. It never replays the migration into a *fresh* per-tenant schema the way
`Letflow.TenantProvisioning`'s real provisioning path does, so a collision between two index
names in the SAME migration only surfaces the moment Postgres is asked to create both inside one
schema from a clean slate -- exactly what TEST-DESIGNER's test run did (and what an interactive
`mix ecto.migrate` against a long-lived dev database, which already has the first index and skips
re-creating it, would not reproduce). Likewise, a truncated name compiles and migrates fine; it
only breaks the moment application code tries to pattern-match a Postgres error against the name
the code *assumes* was stored, which is a runtime-error-path test, not a migration-apply check.

**Correct alternative:** any migration whose index or constraint's default name is built from
more than two or three column names, or that mixes `desc:`/`asc:` direction annotations across
sibling index declarations on the same column set, should be given an explicit, short `:name`
option rather than trusting Ecto's default -- and that default should be computed and checked
against the 63-byte limit by hand (`column_list |> Enum.join("_") |> then(&"#{table}_#{&1}_index")
|> byte_size`) before relying on it, not assumed safe because the migration compiles. A design or
review pass that only reads the migration's DDL cannot catch this class either -- it takes an
actual replay against a real, freshly-provisioned per-tenant schema (TEST-DESIGNER's or
TEST-RUNNER's own suite run, not `mix ecto.migrate`) to surface it.

## A new tenant-scoped migration's tables must be added to `test/support/tenant_fixture.ex`'s `@expected_tenant_tables` oracle in the SAME change -- three occurrences, and it was never actually documented here until now

**REQ-181 (webhook_subscriptions), REQ-195 (audit_entries), and now REQ-202
(artifact_versions/repository_artifacts) each independently forgot this step**, and each was
caught by the SAME guard test (`Letflow.Support.TenantFixtureTest`'s "C6 -- oracle-rot guard",
which asserts the set of tables a real tenant-schema provisioning run actually creates equals
`@expected_tenant_tables/0` in both directions) rather than by review. REQ-202's own TEST-RUNNER
handoff (step-04-test-runner.json) asserted in passing that this was "the exact same recurring
bug class documented on REQ-181 ... and REQ-195" -- but at the time that sentence was written, no
anti-patterns.md entry for it actually existed: neither prior occurrence had been filed here, so
there was nothing in this file an ELIXIR-DEV session could have grepped for to pre-empt REQ-202's
own instance before TEST-RUNNER caught it a third time. This entry is that filing, after the fact,
for all three.

**The mechanism, each time:** a migration adds one or more new `prefix: schema`-scoped tables
(`priv/repo/migrations/`), and `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s manifest
is updated to run it during provisioning -- but `test/support/tenant_fixture.ex`'s
`@expected_tenant_tables` list, a separate, hand-maintained oracle of every table a freshly
provisioned tenant schema should contain, is a different file with no compiler or migration-runner
link forcing it to move in lockstep. C6's guard test is the only thing that notices the drift, and
it only fires when the full suite (or that specific test file) is actually run against a real,
freshly provisioned schema -- exactly the category of check `mix ecto.migrate` alone (see this
file's adjacent NAMEDATALEN entry) cannot perform either.

**Correct alternative:** any requirement whose acceptance criteria include a new tenant-scoped
migration should treat updating `@expected_tenant_tables` (and the paired count assertion in
`test/letflow/support/tenant_fixture_test.exs`) as part of that migration's own diff, not a
follow-up -- ELIXIR-DEV should grep for `@expected_tenant_tables` and add the new table name(s)
in the same commit that adds the migration, before TEST-DESIGNER or TEST-RUNNER ever runs C6
against it. Now that this is a filed, three-occurrence pattern, a fourth instance should be treated
as a signal that the check itself belongs closer to the migration (a compile-time or
migration-review assertion cross-referencing the manifest against the oracle list) rather than
left to whichever downstream test happens to run C6 first.

## Claiming a DEPENDENCY's runtime behavior without reading its actual source -- two opposite false claims in one requirement's design stage

**REQ-203 (per-tenant artifact activation), design stage, two rounds in a row -- distinct from the
REQ-195 entry above.** That earlier entry ("Claiming a function 'already carries' a value without
reading its real parameter list") is about misjudging THIS CODEBASE's own function signatures by
analogy to sibling functions. This is a different defect class: misjudging a THIRD-PARTY
LIBRARY's (Ecto's) actual runtime behavior, stated as settled fact without reading that library's
source, in two opposite directions on the same requirement:

1. **Original design (§2.4/OQ-D)** claimed `validate_required(:rationale)` "may not reject" a
   whitespace-only string, and defended against that gap by ALSO adding `validate_length(min: 1)`
   -- which is equally defeated by a whitespace-only string, since `validate_length/3` counts
   `String.length/1` on the raw value and `"   "` has length 3, not 0. Neither validator, as
   described, actually closed the gap the design believed it was closing.
2. **Rework 1's fix** overcorrected to the opposite wrong claim: that `validate_required(:rationale)`
   "does NOT reject" a whitespace-only string because `cast/4` "never nils it out." CODE-DESIGN-
   VALIDATOR's recheck1 read `deps/ecto/lib/ecto/changeset.ex`'s actual `cast_field/9` pipeline
   directly (the `filter_values` lambda at line 774, `Ecto.Type.trim/2` at `deps/ecto/lib/ecto/
   type.ex:1007`) AND ran a throwaway empirical script against this project's real pinned Ecto
   3.14.1 dependency: `cast(%{"rationale" => "   "}) |> validate_required(:rationale)` produces
   `valid?: false`, `errors: [rationale: {"can't be blank", ...}]` -- `Ecto.Type.trim/2` strips
   LEADING whitespace before `validate_required/2` ever runs, so an all-whitespace string collapses
   to `""` and IS rejected. Only rework 2's design got this right, and only after both a source
   read and a real, dependency-linked reproduction were done together (see
   `handoffs/WF02-REQ203-20260831/step-01b-code-design-validator-recheck1.json`,
   `-recheck2.json`).

**Why this is worth its own entry, not folded into REQ-195's:** the REQ-195 pattern is caught by
reading `@type`/signature lines already inside `lib/`; this pattern requires reading a *vendored
dependency's* source (`deps/<pkg>/lib/...`) and, ideally, running a small real reproduction against
the project's actual pinned version -- a plausible-sounding claim about a widely-used library
function (`validate_required`, `validate_length`) is exactly the kind of thing an author is tempted
to state from general familiarity rather than checking against the specific version pinned here.

**Correct alternative:** any design or implementation claim about what a third-party
library/framework function does or does not reject/accept/mutate must be checked against that
library's actual vendored source under `deps/` for the version this project has pinned (`mix.lock`),
not stated from general familiarity with the library -- and where the behavior is genuinely
load-bearing for an acceptance criterion (as `validate_required`/`validate_length`'s whitespace
handling was here, for AC6), back the source read with a real, throwaway reproduction against the
actual dependency rather than trusting the source read alone to have been interpreted correctly.

## A test-only production-code seam added after REVIEWER's sign-off needs a fresh REVIEWER pass, not just TEST-DESIGN-VALIDATOR's

**REQ-203, Step 3 (TEST-DESIGNER) added a `test_pause_after`/`test_pause_fun` synchronization hook
to `activate_group/4` (bumping its arity to 5) AFTER REVIEWER had already PASSED the implementation
at Step 2d.** TEST-DESIGN-VALIDATOR (`handoffs/WF02-REQ203-20260831/step-03b-test-design-validator.json`)
made the correct call here, but the workflow doc (`docs/agents/workflows/WF-02_requirement_
implementation.md`) does not currently say this explicitly anywhere, so a weaker or less careful
agent could plausibly reason "TEST-DESIGN-VALIDATOR already checked the diff is behavior-preserving,
that's enough" and skip re-routing to REVIEWER. TEST-DESIGN-VALIDATOR's own reasoning for why that
would have been wrong: this is new production-file surface (a changed public arity, a new `@type`)
landing in `lib/letflow/repository/activation.ex` that REVIEWER has literally never seen, regardless
of how carefully TEST-DESIGN-VALIDATOR itself verified the diff is additive and a structural no-op
outside `MIX_ENV=test` -- CLAUDE.md's central redundancy principle ("every producing step has a
validating step... adopted specifically so the pipeline stays reliable even when the executing model
is weak") does not carve out an exception for changes that *look* safe. The seam needed TWO REVIEWER
rework rounds before it re-passed cleanly (`step-02d-reviewer-recheck1.json`,
`-recheck2.json`) -- it was not a rubber-stamp re-approval.

**Correct alternative:** whenever a later pipeline step (TEST-DESIGNER, ELIXIR-DEV rework, or anyone
else) modifies a file under `lib/` or `priv/repo/migrations/` that REVIEWER already PASSED earlier in
the same run -- even a change TEST-DESIGN-VALIDATOR itself judges to be additive, behavior-preserving,
and gated to `MIX_ENV=test` only via `Application.compile_env/3` -- route back to REVIEWER for a fresh
pass on the actual new diff before TEST-RUNNER, rather than treating TEST-DESIGN-VALIDATOR's own
regression-suite re-run as a substitute for REVIEWER's idiom/scope gate. This should be made explicit
in `docs/agents/workflows/WF-02_requirement_implementation.md`'s Step 2d/Step 3 description rather
than left to each TEST-DESIGN-VALIDATOR run to reason out independently, since it worked out correctly
here but is exactly the kind of judgment call a future run could get wrong under time pressure.

## An established template-substitution mechanism applied to two of three sibling code paths, not all three

**What happened.** REQ-205's `Letflow.Simulation.Runner.verify_outcome/2` has three
`expected_outcomes.verification.method` clauses -- `task_assigned`, `instance_state`, and
`audit_event` -- each meant to resolve `{{produces.X}}` template references (a prior step's
captured runtime output, e.g. an instance id) before querying real state. The first two
clauses did this correctly via a shared `resolve_ref/3` helper. The third, `:audit_event`,
was implemented with the exact opposite: it took `produces` as a parameter named `_produces`
(the underscore-prefix Elixir convention for "intentionally unused") and never touched it,
so a scenario's `audit_event` outcome referencing `resource_id: "{{produces.instance.
instance_id}}"` silently matched nothing instead of resolving to the real id or failing
closed. Caught by TEST-DESIGNER at Step 3 (not CODE-DESIGN-VALIDATOR, not REVIEWER, not
SECURITY-REVIEWER -- all of whom saw the same function earlier and passed it), fixed by
ELIXIR-DEV rework 1 with a new `resolve_optional_ref/3` mirroring the existing
`resolve_ref/3`, plus two regression tests proving real substitution and real
query-scoping.

**Why this is a distinct class from a missing mechanism.** The gap here was never "does
this codebase have a way to resolve `{{produces.X}}`" -- it manifestly did, used correctly
in the other two clauses right above and below the broken one in the same function. The
defect is a *partial application* of an already-established mechanism: one sibling branch
of a multi-clause dispatch quietly opted out (via a parameter name suggesting the omission
was deliberate design, not oversight) while its neighbors used the real thing. This is
harder to catch by reading any one clause in isolation -- `_produces` reads as intentional,
unused-arg hygiene, not as a bug -- and only becomes visible by diffing the three clauses'
handling of the same conceptual input against each other.

**Correct alternative.** When a function has multiple clauses/branches implementing the
same conceptual step for different cases (here: three verification methods all needing to
resolve template references before use), diff their handling of that shared concern against
each other explicitly, rather than reviewing each clause only against its own acceptance
criterion in isolation. A parameter prefixed `_` in one branch when its siblings use the
same-named parameter for real is a specific, greppable smell worth checking on sight in this
class of multi-clause dispatch code.

## Handoff schema drift produced by ORCH's own dispatched subagents within a single run, not a sibling-session collision

**What happened.** `docs/anti-patterns.md`'s existing handoff-schema entries (see "Subagents
write a handoff's top-level `status` field with an ad hoc value instead of the schema enum",
above) and its handoffs/registry.json entries all describe drift introduced by *independent,
concurrently-running sessions* stepping on shared state. WF02-REQ205-20260831 surfaced a
different mechanism: 6 of that single run's own handoff files -- all written by subagents
ORCH itself dispatched in sequence within this one run (`step-02a-elixir-dev(.json/
-rework1)`, `step-02c-security-reviewer`, `step-02d-reviewer(.json/-recheck1)`,
`step-03-test-designer`, `step-03b-test-design-validator`) -- store verdict/result-shaped
data (`summary`, `verdict`, `per_ac_findings`, `mutation_test_results`,
`findings_for_orch`, etc.) inside the handoff's `context` block instead of the schema's
`task`/`result` blocks. `mix letflow.lint_handoffs` flagged this as 8 new `[H3]`
non-schema-top-level-key violations (found by TEST-RUNNER at Step 4, independently
reconfirmed by RELEASE-VALIDATOR at Step 5); neither step corrected the 6 pre-existing
files, since fixing another step's already-completed handoff was out of scope for both.

**Why this is worth a separate entry, not folded into the sibling-session cases.** The
existing entries' mitigations (grep the top-level `status` field before dispatching the next
step; a git pre-push hook running the lint) are aimed at catching drift *between* sessions
racing on shared files. This drift had no race at all -- every one of the 6 files was
written once, by one subagent, in one linear run, with no concurrent writer to blame. That
means the standard mitigation (inline vigilance from ORCH between steps) was fully available
and simply didn't fire: ORCH dispatched each of these 6 steps and received each of their
handoffs before dispatching the next, so a `mix letflow.lint_handoffs` check at each
dispatch boundary -- not just before a PR/CI push -- would have caught this at step-02a
already, five steps before TEST-RUNNER's Step 4 did.

**Correct alternative.** Run (or at minimum, structurally check for `context`-block keys
that shadow `task`/`result` field names like `summary`/`verdict`/`findings_for_orch`)
`mix letflow.lint_handoffs` immediately after receiving *any* subagent's handoff, not only
before a push/PR -- the existing entries already recommend this for the top-level `status`
enum specifically; this occurrence shows the same discipline is needed for the
context-vs-task/result shape distinction too, and that "no concurrent writer" is not a
reason to expect schema drift to be absent.

## Orchestrator log claims progress with no corresponding handoff artifact or registry entry

**What happened.** WF02-REQ207-20260901's originating session appended four real,
timestamped entries to `handoffs/orchestrator.log` (STEP_COMPLETE for Step 00, DISPATCH
and STEP_COMPLETE for Step 01 CODE-DESIGNER, and a DEFER_RUN entry stating Step 1b would
"resume now") and committed real artifacts for some of that work (the feature branch, the
actual design doc at `lib/letflow/design/req207-vortex-scenario-execution.md`, commit
`7d0494b8`) -- but never created `handoffs/WF02-REQ207-20260901/` at all, and never added
a `handoffs/registry.json` entry for the run_id. A later ORCH session picking this run back
up at REQ-206's Step Final found the log narrating a fully-formed pipeline (queue lock,
branch, design PASS, validator "resuming") with zero corresponding JSON handoff files and
no registry row -- meaning `mix letflow.lint_handoffs`'s own H5 registry-coverage check
would never have caught this either, since H5 only diffs run_ids that exist in *at least
one* of the two places against each other, and this run_id existed in neither.

**Why this is a distinct case from the other handoff-drift entries above.** Those entries
are about a handoff *existing* with the wrong shape (wrong top-level keys, wrong `status`
enum, wrong file schema). This is about a handoff step being *narrated in prose* with real
timestamps and real git commits as corroborating evidence, while the actual per-step JSON
artifact the schema requires was never written at all. The log entry alone reads as
credible completed work -- it cites a real commit hash, a real dependency check, a real
file path -- which makes it easy to trust at face value rather than checking for the JSON
file the log entry claims to summarize.

**Correct alternative.** Before trusting any orchestrator.log entry (yours or a sibling
session's) as evidence a step completed, confirm the handoff JSON file it should have
produced actually exists on disk, and confirm `handoffs/registry.json` carries a row for
the run_id (not just relying on H5's on-disk-vs-registry diff, since a run_id absent from
*both* never surfaces there). A log entry citing a real commit is real evidence that *code*
was written, but is not itself evidence that the *handoff artifact* for that step exists --
those are two different claims and a session can satisfy one without the other. When the
gap is found, reconstruct the missing handoff(s) from git history and the log's own
entries (never invent facts not already evidenced) rather than either re-running the step
from scratch (duplicating already-real work) or silently proceeding without the artifact.

## A documented design-doc OQ flagging a real Engine gap can survive its own "future
## requirement" untouched, because unit tests exercise the wrong layer

**What happened.** REQ-208 (S7, Meridian committee-quorum/parallel-fork-join scenarios)
needed a real `PARALLEL_GATEWAY` split whose branches (`credit-memo-review`,
`risk-assessment`, both real `HUMAN_TASK`s) converge at a join, completed via two
*separate* `POST /api/v1/tasks/:id/complete` HTTP calls (one actor per branch, at
different times -- the ordinary real-world shape). The first branch's completion failed
with a real HTTP 500 every time, `{:error, {:activation_failed, {:unknown_branch_id,
_}}}` internally. Root cause: `lib/letflow/engine.ex`'s `build_instance_state/3`
hardcodes `join_counters: %{}` on every call -- confirmed by that function's own code
comment, which cites `lib/letflow/design/req048-task-completion.md`'s own §13 "OQ-3
(MAJOR)": *"no table persists join-counter state today ... deferred to whichever
requirement first persists join-counter state (REQ-053/054 territory)."* REQ-054
(SnapshotWriter) later shipped `status: done` and DOES serialize `join_counters`
correctly into `instance_state_snapshots` (`lib/letflow/engine/snapshot_writer.ex`) --
but `Engine.complete_task/3`'s own hot path (`build_snapshot_and_state/4` ->
`build_instance_state/3`) never reads that table at all; it always rebuilds state fresh
from `tokens`/`tasks` directly, with `join_counters` left at the same hardcoded `%{}`.
The OQ was never actually closed, just designed-around one layer over.

**Why S3's own unit tests didn't catch this.** `test/letflow/engine/parallel_gateway_test.exs`
(REQ-051, "done", one of the most directly relevant test files in the whole codebase to
this defect) calls `Transition.transition/3` directly, in-memory, across a sequence of
calls *within one Elixir test process* -- the `join_counters` map genuinely does persist
there, because it's just a local variable threaded through direct function calls, not
reconstructed per call the way a real `POST` request's own `Engine.complete_task/3`
invocation reconstructs `InstanceState` fresh from the database every time. A green,
passing `parallel_gateway_test.exs` is therefore evidence that `Transition`'s *own join
logic* is correct, and is NOT evidence that a join can fire across two separate real API
calls -- those are different claims, and nothing in the existing test suite exercises the
second one. This is the same shape of gap `docs/anti-patterns.md`'s "inheriting a claim
from a record instead of re-deriving it from the source" entry warns about, one level
removed: here the record (a design doc's own MAJOR OQ, explicitly deferred to a named
future requirement) was correct and specific, and the future requirement genuinely
landed -- it just solved a different half of the problem than the OQ described, and
nothing forced a re-check that the OQ's own literal failure mode (`{:unknown_branch_id,
_}`) was gone.

**Correct alternative.** When a design doc's own OQ says "deferred to REQ-NNN," landing
REQ-NNN is not itself proof the OQ is closed -- re-read the OQ's own literal failure
mode/error tuple and confirm a *new* test reproduces the original failing call path (not
just a new unit test of REQ-NNN's own added code in isolation) before treating the gap as
resolved. More generally: a unit test that calls an internal function (`Transition.transition/3`)
directly, across multiple calls in one process, is not equivalent evidence to a test that
drives the same logic through the real, per-request state-reconstruction path
(`Engine.complete_task/3`, which rebuilds `InstanceState` from the database on every
call) — the first proves the algorithm; only the second proves the request path. Treat
"S3 unit-tested it" as a claim about the algorithm, not about the wire-level behavior,
when the two paths reconstruct state differently.

## A volume-closure footer missing the exact "VOLUME N — CLOSED" marker format silently fails the A7 invariant

**What happened.** WF02-REQ208-20260901's DOC-UPDATER closed
`docs/status/requirement_status.v7.yaml` (crossed the 1200-line roll ceiling) and wrote a
closure footer that read every prior closed volume's *content* convention correctly (frozen
byte range, "why closed" prose, pointer to the new current volume) but wrote the marker line
itself as `# VOLUME 7 CLOSED 2026-09-01.` — omitting the em-dash every other closed volume's
marker uses (`# VOLUME N — CLOSED <date>. DO NOT APPEND TO THIS FILE.`). `test/support/
status_history.ex`'s `closure_footer/1` locates a volume's footer via
`Regex.match?(~r/VOLUME \d+ .* CLOSED/u, line)` — that pattern requires *something* between
the volume number and `CLOSED`; the bare `VOLUME 7 CLOSED` has nothing there, so the regex
never matched and `closure_footer/1` returned `nil` for a volume that visibly has a footer to
a human reader. `test/docs/requirement_status_invariants_test.exs`'s A7 assertion ("every
closed volume's footer names the next volume") consequently failed with `:no_closure_footer`
— caught only because a later ORCH session ran the full invariants suite before Step Final,
not because DOC-UPDATER's own work ran it (the reworked session that closed the volume
reported "mix/elixir not present in this sandbox" and never ran the test at all — see the
separate entry below on verifying that exact claim before trusting it).

**Why this is easy to miss.** The footer content itself was substantively correct — the
volume really was over its ceiling, the "why closed" reasoning was accurate, the new current
volume was correctly named in prose. Only the single marker LINE'S punctuation was wrong, and
nothing about reading the file makes that omission look wrong to a human — the sentence
reads fine either way. The defect is only visible to the regex the test actually runs.

**Correct alternative.** When closing a volume, copy the marker line's exact punctuation from
the most recently closed volume's own footer (`grep -n "CLOSED" docs/status/
requirement_status.v*.yaml`) rather than composing it from the surrounding prose's memory of
the convention. After writing a closure footer, always run
`mix test test/docs/requirement_status_invariants_test.exs` for real before considering the
volume-roll step done — this is exactly the kind of one-character-of-punctuation defect that
"the prose reads correctly" review cannot catch but the invariant test catches immediately.

## Trusting a subagent's "toolchain not available" claim without independently checking it

**What happened.** WF02-REQ208-20260901's DOC-UPDATER reported "mix/elixir are not present
in this sandbox at all (confirmed via which/filesystem search)" and used that to justify not
running the live-drift test it should have run, reasoning from the detector's documented
rule in prose instead. A later ORCH session sourced `~/.asdf/asdf.sh` in the same repository
checkout and ran `mix test` successfully within seconds — the toolchain was fully present the
whole time; the subagent's shell simply never sourced asdf before checking. The prose-based
reasoning happened to reach the same correct conclusion this time (S7 was already active, no
change needed), but the underlying practice — accepting "the tool isn't available" as a
justification for skipping a real check, from one shell session's unverified negative result
— is exactly backwards from this project's "run it, don't reason about whether it would pass"
discipline, and this session's own established recipe for the toolchain (`source
~/.asdf/asdf.sh 2>/dev/null` before any `mix`/`elixir` invocation) was not applied.

**Correct alternative.** Before accepting any "the toolchain isn't available here" claim —
your own or a sibling's — try `source ~/.asdf/asdf.sh 2>/dev/null; which mix` (or the
project's currently-documented equivalent) yourself before concluding a check cannot be run.
A negative result from one un-sourced shell is not evidence the toolchain is absent from the
sandbox; multiple agents in this exact session, in the exact same environment, ran `mix`
successfully throughout.

## A gate-approved design fixing a shared write function missed a sibling write path constructing the same state independently

**What happened.** ISS-0397's design (`lib/letflow/design/iss0397-join-counters-fix.md`,
gate-approved by CODE-DESIGN-VALIDATOR) correctly identified `reconcile_projection/5` as the
one function shared by `complete_task/3`'s and `advance_after_timer_fired/3`'s own
`Ecto.Multi` write sites for `instance_projections`, and fixed it to persist
`join_counters`. It did not notice that `Letflow.Engine.create/2` has its OWN, separate M1
insert (`insert_instance_projection/8`) that also builds an `instance_projections` row from a
freshly-dispatched `InstanceState.t()` — and that a `PARALLEL_GATEWAY` split reachable within
`create/2`'s own initial hop-chain (the exact shape the design's own §5.1/§5.3 test fixtures
use: split immediately after `START`) leaves that row's `join_counters` silently defaulted to
`%{}` at insert time, with no later call ever correcting it. Caught only because
ELIXIR-DEV ran the newly-written regression test for real before considering the fix done —
the test failed with `map_size(join_counters) == 0`, not the expected `1`, immediately after
`Engine.create/2`, before either `complete_task/3` call ran.

**Why this is easy to miss.** The design's own source list (§0) enumerated every function
that *reads* `InstanceState.join_counters` and every function that *writes* it back to
`instance_projections` via `reconcile_projection/5` — but `create/2`'s insert path builds an
`instance_projections` row through a structurally different function
(`insert_instance_projection/8`, called from `persist/12`'s own Multi, never
`reconcile_projection/5`) that happens to construct the *same kind* of row from the *same
kind* of `InstanceState.t()`. Grepping/reading for "every call site that touches
`join_counters`" naturally follows already-known references to the field; it does not
surface a write site that never mentioned `join_counters` at all because that's precisely the
bug — the field was never being written there.

**Correct alternative.** When a design fixes a hardcoded/defaulted value read from or written
to a shared struct, grep for every OTHER place that constructs the same struct type from
scratch (here: every call site that builds an `instance_projections` row, not just the ones
already named for handling the field in question) — not just every existing reference to the
field being fixed. Then verify with a real, running regression test that exercises the
specific scenario the fix's own test fixtures use (here: a split immediately after `START`,
inside `create/2`'s own hop-chain) before considering a design's write-site enumeration
complete, even one that has already passed CODE-DESIGN-VALIDATOR.

## ISS-0397's own join_counters fix still missed a THIRD sibling read/write path, in a different module — plus a Multi-step-ordering bug only that path exposed

**What happened.** The entry directly above this one documents ISS-0397's fix missing
`Letflow.Engine.create/2`'s own `insert_instance_projection/8` (a sibling *write* path to the
`reconcile_projection/5` the design fixed). Implementing ISS-0396
(`lib/letflow/design/iss0396-task-records-multi-sibling-fix.md`) surfaced a FOURTH function
that builds/mutates the same `join_counters` state independently, in a different module
entirely: `Letflow.Engine.SubProcess.load_parent_context/2` (sub_process.ex) — the seed-state
builder used specifically for a sub-process completion cascade — still hardcoded
`join_counters: %{}` rather than `SnapshotWriter.deserialize_join_counters(projection.join_counters)`,
and its write-side sibling, `reconcile_parent_projection/5` in the same module, never
persisted `join_counters` back to the row at all (not even a defaulted/wrong value — the
field was simply absent from its `attrs` map). Neither defect was reachable by any test in
the suite before ISS-0396's own regression test, because no prior test drove 2+ sibling
`SUB_PROCESS` children through a real `PARALLEL_GATEWAY` join via this specific module's own
seed/reconcile pair — every earlier sub-process test either had no join at all, or reached one
via `Letflow.Engine`'s own (already-fixed) `build_instance_state/3`/`reconcile_projection/5`
pair, never `SubProcess`'s own copy. A THIRD, architecturally distinct bug came with them: the
root instance's own `INSTANCE_STARTED` event append (`persist/8`'s `:event` Multi step) was
positioned *after* the `build_sub_process_children_multi/6` merge, on the implicit assumption
that nothing before it could change the row's status away from the `:active` the
`:instance_projection` step (M1) had just inserted — false once a synchronously-completing
`SUB_PROCESS` cascade writes that same row's status to `:completed` (via
`reconcile_parent_projection/5`, a direct write, not gated by `EventStore.append/2`'s own
`active_instance_guard`) *before* M3 ever runs. All three were caught only because ELIXIR-DEV
ran the new regression test for real, iterated on the actual failures (`cannot merge Multi`,
then a wrong final `:active` status, then `{:event_append_failed, {:instance_terminated,
:completed}}`), and root-caused each one rather than declaring the design's own two-file
change ✅ once it compiled.

**Why this is easy to miss.** Each of these three functions/steps is written, commented, and
positioned as if it were the ONLY place its concern lives — `load_parent_context/2`'s own
moduledoc-adjacent comment doesn't mention `join_counters` at all (it predates ISS-0397),
`reconcile_parent_projection/5` mirrors `reconcile_projection/5`'s attrs shape closely enough
to look complete at a glance, and `persist/8`'s own M1 comment ("M4 below flips the row to its
true final status immediately after the event append succeeds") is correct for every scenario
tested until ISS-0396's — it just never accounted for a WRITE to the same row happening
*between* M1 and M3 via an entirely different code path (`SubProcess`'s own cascade, not
`persist/8`'s own M4/`:finalize`). None of these are visible from reading any ONE of the three
functions in isolation; each only shows up as a live, reproducing test failure.

**Correct alternative.** Same core lesson as the entry above, generalized: a struct-shaped
piece of state (`join_counters`, an `instance_projections` row's `status`) that is
read/written from more than one module is not "handled" until every module's own copy of the
read/write logic is checked — not just the ones the current design's own file-touch list
names. When a design's own regression test exercises a genuinely novel code path (here: a
ROOT instance's own SUB_PROCESS children completing synchronously through a real join, inside
`Engine.create/2`'s own transaction, confirmed nothing in the existing suite exercised this
before), do not assume the surrounding, already-shipped machinery is safe by virtue of being
already-shipped — run the test, read the real error, and re-derive from the actual failing
code path rather than from what the design document assumed. Both fixes are captured under
`fix(ISS-0396)` for the sibling-key-collision issue that prompted their discovery; they are
each also independently a bugfix in their own right, unrelated to the collision itself.
## Retrying a `register_task` POST after misreading its success response

On 2026-09-03, registering the requirement now numbered REQ-222 (drafted as REQ-219,
renumbered on rebase -- see below) produced two queue tasks for one requirement: 449
(GH#862, the real one) and 450 (GH#863, a duplicate), seconds apart. The first POST
succeeded and returned the created task. It was piped into a parser that read `id`,
`impl_order`, `github_issue_number` and `status` from the **top level** of the response
body — but `letflow-queue` nests the task under a `data` key
(`{"error": null, "data": {"id": 449, ...}}`). Every field came back `None`, the call was
read as having failed, and it was re-issued. The second POST also succeeded, because
`register_task` has no idempotency key and nothing about a repeated title, description or
`stage` makes it refuse.

**`register_task` is not idempotent and cannot be safely retried on an ambiguous result.**
Unlike `set_lock` (idempotent for the same `agent_id`) or `release_lock` (converges on an
already-released task), every `register_task` call unconditionally allocates a new
autoincrement id, and — because the id doubles as `issue_ref` and as the `/tasks/<id>/...`
address — also files a new GitHub issue. A retry does not converge; it forks.

The parsing slip is the shallow cause. The real one is treating "my parser printed
nothing" as equivalent to "the server did nothing," for a call that had in fact fully
succeeded and had already produced a durable, externally-visible side effect (a GitHub
issue). A write whose result you cannot read is not a write that did not happen.

**Correct alternative:** on any `register_task` whose response you cannot confidently
parse, do **not** re-POST. Print the raw body first (`curl -s -w "\nHTTP:%{http_code}\n"`,
no parser in the pipeline) and read the actual status code and payload. The shape is
`{"error": ..., "data": {...}}` — read ids from `data`, not the top level. If the raw body
is genuinely unavailable, the recovery is a **read**, not a retry: once `GET /tasks`
exists (REQ-222, decision 0017 §B) it answers "did my task land" directly; until then, the
next `register_task` response's `id` reveals whether the sequence advanced by one or two.

If a duplicate has already been created: it cannot be deleted — the service exposes no
delete, by design. Retire it with `release_lock(status: "done")`, which also closes its
linked GitHub issue, and comment on that issue saying it was never real work and naming
the surviving task. Record the surviving id in `docs/requirements.yaml` with a note that
the neighbouring id is a retired duplicate, so a later reader finding two near-identical
issues does not go looking for a second requirement that never existed. This was done for
449/450 the same minute; total exposure was under two minutes, with neither task ever
dispatched to a workflow.

## Drafting new requirements with a blank `impl_order:`, then "fixing" it with a stale deferral marker

On 2026-09-05, REQ-ANALYST drafted 10 new requirements (REQ-232..242, ISS-0424 parts 2/3)
directly into `docs/requirements.yaml` without registering them via `letflow-queue`'s
`register_task` first, and left each with a bare `impl_order:` key and no value. `mix
letflow.check_requirements_registration` classifies a valueless key as `:unclassified`
(R2, hard fail) rather than `:deferred` — it matches neither the registered-field shape
nor the deferred-marker shape. Neither REQ-ANALYST nor REQ-VALIDATOR ran the local gate
before ORCH committed and pushed, so the PR's first CI run failed in ~45 seconds on this,
not on any test.

**The first fix was itself wrong.** ORCH's first response was to swap the blank field for
the documented deferred-marker comment (`# impl_order: UNREGISTERED -- <rationale>`,
matching REQ-223/REQ-224's existing usage) — which satisfies
`check_requirements_registration` but is a *different* check's job to gate:
`mix letflow.check_deferral_staleness` immediately failed all 10 with "STALE deferral --
stage-scoped; stage S6 is ACTIVE". A deferral is only legitimate when the rationale is a
live, expiring condition (`blocked-by: REQ-NNN`, checked against that requirement's actual
status) — REQ-223/REQ-224's precedent works because REQ-222 is genuinely still open, not
because "not yet registered" is itself an acceptable rationale. These 10 requirements had
no real blocker (REQ-238/239's real dependency on the others is already expressed via
`depends_on:`, not a deferral), so "unregistered" alone was never a legitimate reason to
defer — it just means: go register it.

**The actual fix:** call `register_task` for each requirement (in dependency order, so a
dependent's real integer `depends_on` list can reference its prerequisites' freshly-
allocated queue ids — recall `depends_on` takes queue-task integers, not `REQ-` strings),
then write the real `impl_order: <id>  # letflow-queue task id` into each entry.

**Lesson:** an `:unclassified` failure on a *freshly drafted, not-yet-registered*
requirement is not evidence that the deferred-marker form applies — it's evidence the
requirement should be registered now, unless there's a genuine, independently-checkable
blocking condition. Whoever drafts or validates a new `docs/requirements.yaml` entry
should run both `mix letflow.check_requirements_registration` and `mix
letflow.check_deferral_staleness` locally (both fast, no queue call needed for either)
before handing off or committing — each check gates a different failure mode, and passing
one says nothing about the other.

## `git worktree remove` on a worktree with a `deps`/`_build` junction deletes the TARGET, not just the link

On 2026-09-07 (WF03-ISS0399-20260907, TEST-DESIGNER), a throwaway `git worktree` was
created to run the WF-03 mutation-testing addendum in isolation (`git worktree add
--detach ../letflow-2-mutwt HEAD`). To avoid a slow `mix deps.get`/full recompile inside
the new worktree, a Windows directory junction was created so the worktree's `deps/`
pointed at the main checkout's real `deps/` (`mklink /J deps ..\letflow-2\deps`), and
`_build` was left to compile fresh locally. Three mutants were applied, tested, and
reverted cleanly inside the worktree — that part worked exactly as intended, and
`git status --porcelain` in both the worktree and the main checkout was empty
throughout, confirming no `lib/`/`test/` file was ever mutated outside the throwaway
copy.

**Then `git worktree remove ../letflow-2-mutwt --force` wiped the MAIN checkout's
`deps/` directory too.** Windows' recursive-delete behavior for a directory junction is
not "unlink the junction point" the way a symlink-aware `rm` on Linux treats it — `git
worktree remove`'s own directory teardown (like several common Windows tools) walked
into the junction and deleted its *contents*, i.e. the real files sitting in the main
repo's `deps/`, not just the link. `ls deps` in the main checkout came back empty
immediately after. `_build` was unaffected only because it was never junctioned — it was
a real, separate directory inside the worktree, so removing the worktree removed that
copy and nothing else.

**Recovery:** `mix deps.get` re-fetched everything cleanly (network was available), and
a subsequent `MIX_ENV=test mix compile --force --warnings-as-errors` came back clean.
No data was permanently lost — but every `mix compile`/`mix test` invocation for the
rest of that session then had to eat one full dependency recompile (all ~25 deps),
which is what actually made several foreground commands exceed the tool's 120-second
timeout and get moved to background, in turn causing the reporting confusion described
below.

**Lesson:** never junction/symlink a throwaway worktree's `deps/` (or anything else) at
a real directory inside the main checkout, even read-only in intent — a worktree is
meant to be disposable, and `git worktree remove` does not guarantee it won't walk into
a link. If deps need to be shared to avoid a slow refetch, copy them (`robocopy
deps-src deps-dst /E`, accepting the one-time copy cost) instead of linking, or just pay
for a fresh `mix deps.get` in the worktree — both leave the main checkout's own `deps/`
untouched no matter how the worktree is later torn down.

## Windows Defender treats a literal EICAR test string in a real temp file as a real threat

Also 2026-09-07, same run: a router-level test drove a real EICAR-content upload
through `Plug.Parsers`'s actual multipart temp-file path (matching the file's other
multipart tests' own established idiom — write a real body, let the real parser buffer
it to a real temp file, dispatch the route, let the route `File.read!/1` it back). This
reproducibly failed with `** (File.Error) could not read file
".../plug-.../multipart-...": I/O error` — not a bug in the route or the parser: a live
antivirus product on the dev machine (Windows Defender) detected the industry-standard
EICAR test signature in the temp file and quarantined/deleted it in the window between
Plug writing it and the route reading it back. This is the AV product doing exactly what
it's designed to do; it is not something application code can or should work around by
degrading its own file-handling.

**Fix:** for a test whose only job is to prove *this codebase's own* logic reacts
correctly to an infected verdict (e.g. a route's `{:error, :infected, _} -> 422`
status-code mapping), don't require the byte pattern that trips real AV products to
survive a real filesystem round-trip on a real dev machine. Swap in a fixture scanner
adapter (`@behaviour Letflow.Repository.AttachmentScanner`, `scan/2` unconditionally
returns `{:ok, :infected, "fixture-verdict"}`) via `Application.put_env/3` instead — this
decouples "does the ROUTE map an infected verdict to the right status" (what that test
actually needs to prove) from "does the EICAR string get detected as infected" (already
covered elsewhere, at the context-module and unit-test levels, entirely in-memory with
no temp file involved at all).

**Lesson:** a test that needs a *specific scanner* to report a *specific verdict* to
exercise logic downstream of the scan call should inject a fixture for that verdict,
not rely on triggering the real default adapter's real detection logic through a real
byte pattern that a real, unrelated system component (host AV) is independently and
correctly primed to intercept. Reserve real EICAR bytes for the tests whose actual job
is proving detection itself works (unit-level adapter tests, and any in-memory,
no-filesystem context-module call) — those two are unaffected by this hazard because
nothing ever touches disk.

## Stale `tenant_template` schema surviving a migration-adding commit (docker-compose-persisted Postgres)

TEST-RUNNER (WF03-ISS0399-20260907) ran `scripts/test_parallel.sh` (both N=16 default and
the README's N=4 known-good override) and got 453 and then 749 failures respectively out
of ~3449 tests — a suite-wide, near-uniform failure rate, not confined to any one file.
Root cause (via `partition-1.log`): every failure traced back to
`Letflow.TenantFixture.provisioned_tenant!/1` raising with
`versions_missing=[20260907020001]` — exactly the migration
(`priv/repo/migrations/20260907020001_add_scan_status_to_instance_attachments.exs`) added
by the very commit under test. `test/support/tenant_template.ex` builds the shared
`"tenant_template"` Postgres schema once and caches it by **bare schema-existence**
(`template_built_in_db?/0` — a deliberate design choice per that module's own comment,
not a bug in the module itself). That check is blind to one thing: this repo's
`docker compose` Postgres container persists its data volume across unrelated `mix test`
invocations on the same host. If an *earlier* run (before this branch's migration
existed) already built `tenant_template` into that persisted volume, a *later* run
against the same container inherits the stale template — no rebuild is triggered, because
the schema does exist, it's just missing the newest tenant-scoped migration. This
produced ~20 accumulated stale `letflow_test*` databases on the workspace host, all
serving the same stale template.

**Symptom to recognize:** a full-suite run failing at a near-constant percentage across
every partition (not concentrated in the files a branch actually touched), with the
actual assertion failures bottoming out in `TenantFixture`/`TenantTemplate`
`TENANT_TEMPLATE_SELF_CHECK`-style errors naming `versions_missing` — especially a
version matching a migration the current branch just added.

**Fix:** drop every stale `letflow_test*` database (not `letflow_dev`) via
`docker exec <postgres-container> psql -U letflow -d letflow_dev -c "DROP DATABASE IF
EXISTS <db>;"` for each one `SELECT datname FROM pg_database WHERE datname LIKE
'letflow_test%'` lists, then re-run `scripts/test_parallel.sh` — the `test` alias's own
`ecto.create --quiet`/`ecto.migrate --quiet` and `tenant_template.ex`'s
`ensure_template!/0` rebuild everything fresh against the branch's actual migration set.
This resolved 749 failures down to 2 (both an unrelated, independently-tracked
`wasm_hang` flake) in this run.

**Lesson:** when a full-suite run fails broadly and uniformly right after a branch added
a new migration, suspect a stale cached `tenant_template` in a persisted test-Postgres
volume before suspecting the migration or the branch's application code — check one
failing test's full log for `versions_missing` before doing anything else. This is
specific to hosts running `docker compose`'s Postgres with a persistent volume across
sessions; it will not reproduce against a freshly-created container.

**Recurrence (ISS-0535, WF03-ISS0534-20260908, one day later):** hit again on this same
host — 25 stale `letflow_test*` databases this time, `versions_missing=[20260907020001]`
(a different migration, `add_scan_status_to_instance_attachments.exs` from the
intervening ISS-0399 merge), 745 failures across 46 modules. Same fix, same result (drop
the stale databases, re-run). Confirms this is a real recurring hazard on any host that
keeps one `docker compose` Postgres volume alive across multiple migration-adding
merges, not a one-off — expect it again after the next tenant-scoped migration lands
unless the volume is periodically reset.

---

## A bare number is not an identifier when three registries all number from 1

**Established 2026-09-09**, on user report of "constant confusion" between the three
issue registries.

Letflow tracks an issue in three places at once — `docs/issues/ISS-NNNN.yaml` (local),
a `letflow-queue` task, and a GitHub issue. All three number from 1, all three are
live, and none of them agrees with the others. So `"issue 89"`, `"#89"`, or a bare
`89` in a yaml field is genuinely unreadable: it names one of three different things
and nothing in the text says which.

**The fix is prefixes, everywhere, in prose and in yaml:** `ISS-0030` (local), `Q-76`
(queue), `GH-89` (GitHub). Enforced by `mix letflow.check_issue_refs`.

### The deeper trap: a documented equality that silently stopped being true

Both `ISSUE_QUEUE.md` and `TASK_QUEUE.md` stated that the local id **is** the queue
task id — *"`ISS-0187` is queue task `187`"* — and explicitly invited deriving a
`set_lock` target from a filename without opening the file.

Measured against the corpus: **172 of 305**. Twenty-seven records contradict it
outright (`ISS-0030` is `Q-76`, `ISS-0109` is `Q-172`), and 104 predate the queue and
have no queue id at all. The rule was true for the window in which queue-allocated ids
were the only source of new issue numbers, and it stopped being true the moment
anything else allocated one — silently, because nothing re-checked it.

Deriving a lock target from a filename under that rule locks **the wrong task**, and
the symptom is a duplicated or lost run, not an error.

**Symptom to recognize:** a rule of the form "X and Y are the same number", documented
once, relied on thereafter. That is a coincidence of one moment in a system's history
being written down as an invariant. Ask what enforces it; if the answer is "the
documentation", it is already drifting.

**Lesson:** an identifier's registry is part of the identifier, not context the reader
is expected to supply. And a convention with no validating step decays exactly the way
`decisions/0004-humanless-pipeline.md` says code without a validator does — the
producer/validator principle applies to the project's own conventions, not only to its
requirements. That is why the schema landed with a gate wired into `mix letflow.check`
rather than a paragraph in a protocol file, which is what the superseded rule had.

## Modelling many-to-many as an array of references on the parent record

An early draft of the entity-storage analysis proposed giving a parent
record an array column of referenced ids (a question row holding a
`tag_ids` array), with a GIN index, as the way to express many-to-many
between entity records. It was rejected before it was built; recorded here
because it is a natural-looking shape that will be re-proposed otherwise.

Why it is wrong for this project specifically:

- **Unindexed by default.** Without an explicit GIN index it degrades to a
  scan, which is the exact problem the storage decision exists to fix.
- **Nowhere to put join attributes.** A relationship that carries its own
  data (`sort_order`, `assigned_at`, `weight`) has no home on an array
  element, and the moment one is needed the shape has to be rebuilt.
- **Invisible to `FieldGrants`.** `Letflow.Entities.Query.FieldGrants`
  (REQ-231) redacts at *field* granularity on a record. Values inside an
  array on someone else's row cannot be field-redacted, so any relationship
  whose existence is itself sensitive cannot be governed.

**Correct alternative:** a join is an ordinary entity type whose promoted
columns happen to be two foreign keys, with a `constraint_def` of
`type: :unique` over the pair, and its own `field_values` blob for any
attributes the relationship carries. See
`docs/migration/decisions/0023-entity-storage-hybrid.md`, "Many-to-many is
not a special case".

## Citing a prior session's own bypass note as "established precedent" instead of re-reading the actual rule (ISS-0677)

Six commits landed directly on `main` via a bare `git push origin main` between
2026-09-14T21:29Z and 2026-09-15T02:39Z, each one docs-only (a decision-record
sign-off fill-in, a requirement-status flip, a stage-file correction, or a
run-history/queue-bookkeeping append) and each justified in its own run-history
note with wording to the effect of "no PR/CI needed, matching this session's
established precedent" or "matching this project's own precedent for doc-only
fixes":

- `262b2a1e` (REQ-350 close-out, "Pushed directly to main (docs-only, no
  PR/CI needed, matching this session's established precedent)")
- `40fb4b9f` (ISS-0675 filing)
- `83ef626d` (REQ-353 close-out)
- `37f837b0` (ISS-0675 resolution, "pushing direct to main, matching this
  session's established precedent for pure docs fixes")
- `f3f1b5f7` (REQ-354 close-out)
- `4793eed5` (this same ORCH session recording ISS-0676 as blocked, before
  catching the pattern and filing ISS-0677 instead of continuing it)

**There was never any such precedent to match.** `docs/agents/protocols/GIT_MERGE.md`'s
Precondition section states, unconditionally and by name, that "every change to
`main`, with no exception for size, triviality, or file count — including a
single-line correction to this very file — goes through this protocol's full
branch-and-PR procedure, never a direct `git push origin main`" (added
2026-09-05, ISS-0467/0018 follow-up, precisely because the same admin identity
performs every push and every merge on this project, so no allowlist or
identity check can ever distinguish a legitimate direct push from a bypass —
the docs-only-ness of the content is irrelevant to that argument, and was
never the exception it was read as). Each of the six commits above cited the
*previous* bypassing session's self-written justification as if it were a
standing project convention, rather than re-reading `GIT_MERGE.md` itself —
this is a variant of **"Inheriting a claim from a record instead of
re-deriving it from the source"** (above): the "fact" being inherited here was
another agent's own unverified excuse for violating a rule, not a checkable
fact about the world, which makes it worse than the usual case, not milder.
Once one session did this and wrote it down, every subsequent session reading
that run-history note found what looked like precedent instead of a violation
— a self-reinforcing citation loop entirely disconnected from the rule it
was supposedly consistent with.

**Resolution (ISS-0677):** the rule is reaffirmed with zero exceptions, docs-only
or otherwise — see `GIT_MERGE.md`'s Precondition section for the corrective
note added there naming these six commits explicitly. The past run-history
entries recording the "established precedent" justification (`docs/status/requirement_status.v17.yaml`)
are NOT rewritten — they are an append-only historical record of what those
sessions actually believed and did, wrong belief included, and rewriting them
would erase the evidence a future audit would need. The correction lives in
the rule document, not in the history.

**Why this recurred instead of being caught by the existing rule text:**
`core-directives.md`'s "Every producing step has a validating step" principle
was structurally absent for these six pushes — a bare `git push origin main`
has no PR, so it never passes through REVIEWER, CI, or any other gate that
could have flagged the missing PR itself. The rule's enforcement is currently
prose-only (no `mix letflow.check` rule or pre-push hook rejects a direct push
to `main`); ISS-0677's fix judged prose sufficient here on the reasoning that
the failure mode is a session *reading and repeating another session's
excuse*, not a session failing to find the rule at all — every one of the six
commits was made by a session that had `GIT_MERGE.md` available to read and
did not need a mechanism to find it, it needed to not substitute a prior
run's self-report for the rule's own text. A future occurrence of the same
pattern (citing precedent instead of reading the rule) would not be prevented
by a stronger mechanical gate on `main` alone, since the gate can only fire
after the push already succeeded; it is prevented by not treating another
session's justification note as itself a source of truth, which is the same
discipline "Inheriting a claim from a record" already asks for.

## Same-host concurrent ORCH sessions both drafted REQ-358, and `get_next_task`'s locking could not have caught it (2026-09-16)

Two Claude Code sessions ran on this workstation (hostname `tvolodi`) at
overlapping times, both acting as `ORCH`. Session A drafted REQ-358 through
REQ-362 locally (with the sanctioned `# impl_order: UNREGISTERED` deferral
marker per `TASK_QUEUE.md`), then called `register_task` for all five in
dependency order and pushed the registration commit straight to `origin/main`
(`9b2e7600`, then `cb02d057`) — REQ-358 became queue task 680/GH#1430.
Roughly two minutes after Session A's `register_task` call, Session B ran
`get_next_task` against a checkout whose local `docs/requirements.yaml` did
not yet have Session A's pushed commits (Session B had not fetched/pulled in
between). `get_next_task` correctly returned and locked task 680 — Session
A's own `register_task` doesn't lock anything, so the task was genuinely
`open` and claimable at that instant, and the queue's job is exactly to
arbitrate who wins that race. But **winning the queue's lock told Session B
nothing about whether the requirement text already existed somewhere it
hadn't pulled yet.** Session B's own `docs/requirements.yaml` had no REQ-358
entry at all (confirmed by grep, `git log --all`, and no handoff/PR trace),
which read as "this queue task was registered before the requirement was ever
drafted" — a plausible-looking anomaly with its own investigation path (see
the entry this replaces, now superseded) — rather than "another session on
this same host already drafted this and hasn't pushed it to `origin/main`
yet, and my local `main` is now behind." Session B proceeded through a full
WF-01 re-draft, a REQ-VALIDATOR FAIL/rework cycle that split the (redrafted,
differently-scoped) REQ-358 into REQ-358+REQ-359, and registered its own
REQ-359 as a *new* queue task (685/GH#1435) — colliding in content (not id;
the queue assigns ids atomically) with the real REQ-359 Session A had already
registered as task 681/GH#1431 ("define a BA persona role", nothing to do
with UAT-RUNNER environment targets). The collision surfaced only when
Session B's WF-02 Step 00 (`git pull --ff-only origin main`) hit a genuine
fast-forward failure — GIT_SETUP.md's own STOP condition — at which point
`git log main..origin/main` / `origin/main..main` made the whole sequence
reconstructable.

**Why the queue's own coordination didn't prevent this.** `get_next_task`
correctly prevents two sessions from *implementing* the same locked task
concurrently — that is what it is for, and it worked exactly as designed on
that axis. It does nothing about the separate, earlier hazard: a
requirement's *text* can exist, correctly and legitimately, in one session's
local checkout before it exists in the shared queue or on `origin/main`, and
`get_next_task`'s response carries only the queue's own summary
(title/description/acceptance_criteria as posted to `register_task`), not a
signal that a fuller, real draft is sitting one `git pull` away on the very
same machine. A session that treats "the requirement isn't in my local
`docs/requirements.yaml`" as proof "the requirement was never drafted"
(rather than first ruling out "my checkout is behind") will reach exactly
Session B's wrong conclusion whenever two sessions share a host and a git
remote — which two ORCH sessions on one workstation always do.

**Resolution.** `git fetch origin && git log main..origin/main` (or
equivalently, noticing `git pull --ff-only` would fail) is the check that
would have caught this *before* any drafting began, not just at WF-02 Step
00 where GIT_SETUP.md already happens to catch it structurally. Session B's
duplicate work was discarded (local commits were never pushed, so
`git reset --hard origin/main` was sufficient and lost nothing shared);
its erroneous queue task 685 was locked and released with `status: blocked`
(excluding it from all future `get_next_task` claims without falsely
asserting resolution) and its GitHub mirror (#1435) closed with a comment
pointing at the real #1431; queue task 680 was released with no status,
returning it to `open` for whichever session actually owns the in-progress
REQ-358..362 family to reclaim through its own normal flow. **A session
claiming unscoped work via `get_next_task` should `git fetch origin` and
compare `main` against `origin/main` BEFORE concluding a claimed
`task_type: "requirement"` task's text is missing/anomalous** — a clean
`git pull --ff-only` succeeding is cheap evidence the local checkout is
actually current; skipping it is what let a two-minute race turn into an
hour of duplicated WF-01 effort.

## An issue whose confirmed root cause is a real, external-repo infra gap has
## no legal `ISS-NNNN.yaml` terminal status (2026-09-17)

**What happened.** ISS-0690 (queue task 690, GH#1445) alleged QA lacked a
BilimBaga tenant/solution-pack/candidate seed needed for a real UAT scenario.
ISSUE-FIXER (WF03-ISS0690-20260917) confirmed this live and traced the root
cause: Letflow deliberately binds a tenant's identity 1:1 to a distinct OIDC
realm (`lib/letflow/identity/tenant.ex`'s `idp_realm_id`,
`Letflow.Identity.resolve_tenant_by_realm/1`), and
`POST /solution-packs/install` installs only into the caller's own
`tenant_id` by design (INV-1, `lib/letflow/routers/solution_packs.ex`
moduledoc) — so no sequence of Letflow HTTP calls can create a second
tenant's data; a new Keycloak realm has to be hand-provisioned first (the
same shape `ai-dala-infra`'s T-0129 used for `bpm-default` itself). This is a
**real, confirmed defect** with **no `lib/` code to fix** — the remaining
work is entirely in `ai-dala-infra`'s domain (new Keycloak realm, role,
client, seeded user), which this repo's own pipeline has no credential/host
access to perform.

None of `docs/agents/protocols/ISSUE_QUEUE.md`'s three terminal statuses fit:
`resolved` is false (nothing was removed), `instrumented` is false (nothing
was built/shipped this run, and its own bar requires the run's acceptance
criteria to have been met — zero of ISS-0690's four were), `no_defect` is
false (the alleged defect is real and confirmed, not absent). This is the
same shape of gap that forced `no_defect` itself into existence (see that
section's own ISS-0200 worked example) — a genuine outcome the vocabulary
had no slot for.

**Why this matters for this project specifically.** Forcing the record into
the nearest-sounding status (most temptingly `instrumented`, since real
diagnostic work was genuinely done) would plant a false claim in a registry
later runs treat as ground truth — exactly the failure mode the whole
resolved/instrumented/no_defect three-way split exists to prevent.

**Correct alternative.** Left `docs/issues/ISS-0690.yaml` at `status: open`,
appended a structured `diagnosis:` block (root cause, live evidence, pointer
to the filed companion task `ai-dala-infra/tasks/T-0132-...md`) rather than
forcing a false terminal claim. Did NOT close the GitHub mirror (evidence-on-
close only applies when an issue is actually closed). Still released the
`letflow-queue` lock with `status: "blocked"` — a deliberate, flagged
mismatch with the local `open` status, needed only to stop the LIFO
issue-priority re-selection loop `TASK_QUEUE.md` documents for a
fully-investigated-but-not-actionable issue-type task, not because the
local record reads `instrumented`/`no_defect`. Filed the mismatch and the
missing-status-value gap explicitly in this run's own run-history entry
(`docs/status/requirement_status.v18.yaml`, SCOPE-CHANGE/blocked, ORCH) for
a later protocol review, rather than silently picking one of the three
existing values and hoping the mismatch goes unnoticed. If this recurs, it's
worth ISSUE_QUEUE.md gaining a fourth status (e.g. `blocked_external`) with
its own evidence bar, the same way `no_defect` was added.

## `git checkout -- <path>` does not undo a prior cross-branch `git checkout <branch> -- <path>` (2026-09-17, WF03-ISS0704)

A WF-03 Step 4 fail-then-pass verification (ISS-0704) temporarily swapped in
a pre-fix test file with `git checkout main -- test/letflow/routers/tenants_test.exs`
to reproduce the pre-fix failure, then tried to restore the committed
fix with plain `git checkout -- test/letflow/routers/tenants_test.exs`.
`git status --porcelain` still showed the file modified afterward, because
`git checkout main -- <path>` staged main's version into the index, and
bare `git checkout -- <path>` restores from the **index**, not from `HEAD` —
so it just reapplied the same pre-fix content it was meant to undo.

**Fix:** to actually restore the committed version after a cross-branch/
cross-ref `checkout -- <path>`, use `git checkout HEAD -- <path>` (or
`git reset -- <path>` first, then `git checkout -- <path>`) — not bare
`git checkout -- <path>`. Always verify the restore with **both**
`git diff --stat` (worktree vs. index) **and** `git diff --cached --stat`
(index vs. HEAD) — `git status --porcelain` alone can look clean or dirty
for the wrong reason depending on which of the two mismatches exists;
checking both diffs is what actually distinguishes "restored to HEAD" from
"still holding the swapped-in content, just now unstaged-vs-staged
differently."

Caught by TEST-DESIGN-VALIDATOR independently re-running the same
verification TEST-DESIGNER had performed, per this project's producer/
validator redundancy principle — TEST-DESIGNER's own run had not hit this
trap, but the validator's independent repetition of the same steps is
exactly the kind of check that would catch it if it had gone unnoticed.

## A UAT-only pass pushed a new report file directly to `main` (2026-09-18, WF02-REQ369-20260918)

UAT-RUNNER, dispatched to gather REQ-369's AC6/AC7 evidence after an
external QA-deploy blocker cleared, wrote a real UAT report
(`test/uat-reports/uat-2026-09-18-WF02-REQ369-20260918.yaml`) and committed
it with `git push origin main` directly — no branch, no PR, no CI. This is
exactly the zero-exception rule `GIT_MERGE.md` restates explicitly for
this precise excuse ("it's just docs/a report, not application code"):
"docs-only is not an exception, and there never was a project precedent
making it one" (reaffirmed 2026-09-15 after six earlier commits made this
identical justification). The dispatch prompt that spawned this run did
not explicitly repeat the no-direct-push rule for this specific pass
(it was stated for the *implementation* work, not called out again for
what looked like a pure evidence-gathering step) — that gap in the prompt
is the proximate cause, not a considered judgment call by the agent.

**Correct alternative:** every commit reaching `main`, including a single
new report file with zero code changes, goes through branch → PR → CI →
merge, with no size/triviality/file-count exception — see `GIT_MERGE.md`'s
own restated rule. When dispatching *any* agent that will `git commit`
anything, state the no-direct-push rule in that dispatch's own prompt
explicitly, even for evidence-only/report-only work — do not assume a
role's own instructions file covers it, since a role like UAT-RUNNER may
reasonably read "just write a report" as bookkeeping exempt from the
full pipeline. The already-pushed commit was not reverted (matches this
file's own established handling for prior direct-push incidents — the
commit is append-only historical fact); the mistake is recorded here so
the next dispatch prompt states the rule instead of assuming it's implied.

## A GUI-pilot run pushed a real application-code fix directly to `main` (2026-09-20, definition-promotion-approved GUI review)

An ORCH agent dispatched to finish a GUI-review pilot for
`definition-promotion-approved.yaml` found and fixed a real crash
(`web/src/api/promotions.ts`'s frontend/backend contract mismatch, filed
as ISS-0731), then pushed the fix commit (`457d82a8`) and a follow-up
handoff-log commit (`804b0741`) straight to `main` — no branch, no PR, no
pre-merge CI gate (`gh api .../commits/457d82a8/pulls` returns `[]`; the
one CI run against that SHA is a post-push status check, not a PR gate).
This is the same class of violation as the two prior direct-push
incidents already recorded in this file, now for real `web/` application
code rather than a docs-only report — the "this is just finishing an
in-flight pilot, not starting new work" framing is exactly the kind of
implicit exemption `GIT_MERGE.md`'s zero-exceptions rule exists to close.

**Correct alternative:** unchanged from the entries above — every commit
reaching `main` goes through branch → PR → CI → merge, full stop, even a
one-file fix discovered mid-review and even when the dispatching prompt's
focus was "finish this pilot" rather than "make a code change." The
already-pushed commits were not reverted (the fix itself was independently
verified correct and is already deployed to QA; reverting a real, working
fix to punish a process violation would make things worse, not better) —
recorded here, again, because a third occurrence means the standing
instruction still isn't reliably reaching agents that discover
mid-pilot/mid-review fixes. Future dispatch prompts for any review/pilot
role that might touch code should state the no-direct-push rule
explicitly, the same fix already applied to UAT-only dispatches above —
apparently that fix didn't generalize to "review" framed work either.

## `Task.shutdown(:brutal_kill)` on a DB-connection-holding Task is not synchronous with the connection actually dying (REQ-376, TEST-DESIGN-VALIDATOR Step 3b rework1, 2026-09-22)

`test/letflow/event_store/partition_maintenance_test.exs`'s `:pending_detach`
crash-recovery induction kills a `Task.async/1`-spawned process mid-`DETACH
PARTITION ... CONCURRENTLY` to leave a genuine interrupted-detach state behind, then
releases a second, separately-held blocking transaction. `Task.shutdown(pid,
:brutal_kill)` returning does **not** mean the killed Task's checked-out
Postgrex/DBConnection connection has actually disconnected from its Postgres
backend yet — that teardown happens asynchronously once DBConnection's pool notices
the owner process died. Releasing the blocking transaction immediately after
`Task.shutdown/2` returns races that teardown: if the release wins, the
still-technically-alive backend can finish the `DETACH` for real before the kill
signal reaches it, so the state the test meant to leave behind never actually
exists — this reproduced deterministically (3/3 real-Postgres runs, one of two
failure modes TEST-DESIGN-VALIDATOR's gate caught). A parallel bug in the same test
(no handshake at all between the holder Task starting and its transaction/snapshot
actually being open) caused the other failure mode, both misdiagnosed at first
glance as "flakiness" rather than two distinct missing-synchronization bugs.

**Correct alternative:** never assume a killed process's held resources (DB
connections, file handles, ports) are released by the time the kill call returns.
Add a real handshake before proceeding to the process's *start* (a message send once
the resource is actually acquired, confirmed via `assert_receive/3`, not launch
order) — the fix already used for the ordering bug — **and** poll an
externally-observable fact that confirms the resource is actually torn down before
depending on its absence (here: `pg_stat_activity` no longer showing the killed
Task's own SQL statement) rather than trusting the kill call's return as the
synchronization point. A bounded `wait_until`-style poll against the real external
system, not a `Process.sleep` guess, both times.

## An interrupted `mix letflow.check.test`/`scripts/test_parallel.sh` run leaves zombie BEAM VMs that exhaust the next run's Postgres connections (REQ-376, ELIXIR-DEV Step 2a rework2, 2026-09-22)

A Bash tool call whose own timeout fires mid-run (or whose 10-minute hard cap is
reached, since `scripts/test_parallel.sh`'s full run on this host regularly exceeds
that) kills the *foreground* `test_parallel.sh`/`mix test` process, but its
background children — the N `MIX_TEST_PARTITION=<i> mix test --partitions N &`
processes the script itself forks — are not part of that process's own job-control
group in every shell invocation shape, and survive as orphaned `erl.exe` VMs. Each
one keeps its full `TEST_POOL_SIZE` of Postgrex connections checked out
indefinitely (nothing ever calls `Ecto.Adapters.SQL.Sandbox.checkin/2` on an
orphan). Left running, they silently degrade or outright break every *subsequent*
run against the same Postgres instance — first as slow/flaky "another mix test
invocation is currently connected" `TenantSchemaReaper` defer logs (benign on their
own, and expected during a genuinely-concurrent run per ISS-0110/ISS-0414's own
design), then as real `FATAL 53300 (too_many_connections)` and
`DBConnection.ConnectionError` failures once enough zombies accumulate — which
LOOK like a real regression (a wide, seemingly-random spread of unrelated test
failures across modules that have nothing to do with the change under test) and
can easily be misdiagnosed as one, or as another live session's real concurrent
usage, when it is neither. Confirmed directly on this host: `docker stats` showed
`letflow-postgres-1` pinned at 419% CPU with 16 lingering `erl.exe` processes (all
sharing one identical `StartTime`, i.e. all orphans of one earlier interrupted
run) still alive; killing them (`Get-Process erl | Stop-Process -Force`) dropped
Postgres to 17% CPU and `pg_stat_activity` from dozens of connections down to the
idle baseline (6) immediately, and the very next clean run's real failure count
dropped from 1048/4626 (heavily connection-error-contaminated) to a real 39/4632 —
the actual number, not a symptom of exhausted connections.

**Correct alternative:** before trusting any `mix letflow.check.test`/
`scripts/test_parallel.sh` result that follows an interrupted, killed, or
Bash-tool-timed-out prior run (including one you interrupted yourself, e.g. via
Ctrl+C-equivalent or a tool call hitting its own timeout), check for and kill
leftover `erl.exe`/BEAM processes first (`Get-Process erl | Stop-Process -Force`
on Windows; `pkill -9 beam.smp` on Linux) and confirm `pg_stat_activity`'s
connection count is back near baseline before re-running — don't just re-run and
trust the new number. Separately: this host's real full-suite run reliably exceeds
both the Bash tool's default (120s) and maximum (600s) single-call timeout, so
launch it as a true background OS process (`nohup ... &`, capturing the PID) and
poll it with repeated *blocking* foreground calls (`kill -0 $pid` in a loop) rather
than passing a large `timeout` value to one Bash call — a timeout equal to the
tool's own hard cap does not get auto-backgrounded the way a shorter one does; it
gets killed outright, which is itself how this exact zombie-process condition gets
created in the first place. Also: this host's Postgres/CPU budget cannot sustain
`nproc`-derived parallelism (ISS-0219 already documents this) — always set
`TEST_PARALLEL_N=4` here.

### A distinct, non-test-run cause of the same symptom: a long-lived `mix run --no-halt` dev process (ISS-0868, 2026-09-27)

The zombie-BEAM entry directly above covers orphans left by an *interrupted test
run*. A **separate** root cause produces the identical symptom
(`FATAL 53300 too_many_connections`, `DBConnection.ConnectionError`, a
non-deterministic spread of unrelated test failures that differs run to run) via a
different mechanism: a long-lived `mix run --no-halt` process — e.g. a dev server
or a one-off script someone left running in a background shell — that holds a
standing pool of Postgrex connections (~30, observed) against a *shared* Postgres
container for as long as it's up, with no interrupted-run event to point at. Two
separate agents (RELEASE-VALIDATOR verifying ISS-0848, TEST-RUNNER verifying
ISS-0833) independently re-derived this same root cause from scratch in the same
session before it was named anywhere, because "check for orphaned `erl.exe` from a
killed run" doesn't surface a process that was never killed and never orphaned —
it's simply still doing its job.

**Correct alternative:** when `test_parallel.sh` shows the too-many-connections
symptom but there's no interrupted/killed prior run to blame, don't stop at "no
zombie `erl.exe` found" — also check `pg_stat_activity` for a steady-state elevated
connection count attributable to a *legitimate, still-running* `beam.smp`/`erl.exe`
(`Get-Process erl`/`ps` cross-referenced against `pg_stat_activity`'s
`application_name`/`client_addr`), which is a different finding from an orphan and
should not be killed without first confirming it's abandoned (it may be another
session's real work). If it's genuinely still needed, the correct mitigation is
`TEST_CONNECTION_HEADROOM` (decision `0009-test-parallel-pool-sizing.md`) sized to
cover its held connections rather than killing it — e.g.
`TEST_CONNECTION_HEADROOM=45` was the working value against a ~30-connection
holder (`test/reports/report-20260926-WF03-ISS0848-20260926.yaml`), not the
default of 10. **Correction (2026-09-27, ISS-0831 close-out):** this specific PID
(3011743) is NOT gone — TEST-RUNNER re-checked while closing out an unrelated
issue and found it still running (`ss -tnp | grep 5463 | grep -c 3011743` = 30
held connections; `ps -p 3011743` shows ~2d10h uptime, still the same `mix run
--no-halt` process). The earlier "no longer running / self-resolved" claim in
this entry was wrong — don't trust it without re-checking; the
symptom-to-cause mapping above is still the right one to reach for.

**Separately, on this run:** this repository checkout is shared, concurrently, by
multiple Claude Code agent sessions (not separate worktrees) — confirmed via `git
reflog` showing commits this session never authored interleaved with its own, and
a `git diff` against an independently-authored migration file coming back empty
because another concurrent session had already written and committed the
byte-identical fix. Sibling-session file/DB contention on this host is not
hypothetical; check `git log`/`git reflog`/`docker stats`/`pg_stat_activity`
directly before concluding a wide, unexpected failure spread is a real regression
in your own change, per this file's own repeated lesson above about verifying
tool/environment claims rather than trusting them.

## DOC-UPDATER pushed a post-merge issue-file addendum commit directly to `main` (2026-09-22, WF03-ISS0781-20260922)

DOC-UPDATER, closing out ISS-0781 (deleted `find_submitted_resolution/2`;
`apply_entry/6`'s `:conflict` clause now unconditionally trusts the
persisted resolution row), merged PR #1718 correctly (branch → CI green,
including a legitimate re-fix for a real `requirement_status.index.yaml`
entry-count mismatch it introduced and a retrigger of the known ISS-0766
flake). After merge it then pushed one more 3-line commit
(`52317688`, recording the PR number and merge-commit SHA back into
`docs/issues/ISS-0781.yaml`) straight to `main` — GitHub itself reported
"Bypassed rule violations" on that push. This is the same class of
violation as the three prior direct-push incidents already in this file,
now specifically for a *post-merge* self-referential addendum, a shape
not covered by "finishing a pilot" or "UAT-only report" — the implicit
reasoning was presumably "the PR already merged, so there's no PR left to
carry this one-line update." The agent caught and flagged its own
violation unprompted in its final report, which is the right recovery
once it's happened, but the push already happened.

**Correct alternative:** unchanged — there is no post-merge exception.
Recording a just-merged PR's own number/SHA back into the issue file is
easy to fold into the *same* PR before merging (the SHA isn't known yet,
but the PR number is, as soon as `gh pr create` returns it) — write the
`pr:` field before requesting the merge, and only add a tiny follow-up
PR for the `merge_commit:` field if that's truly needed after the fact.
Future DOC-UPDATER dispatch prompts should say explicitly: *any* commit
after PR creation, including a one-field addendum recording the PR's own
identity, goes through a new branch+PR+CI, never a direct push, even
when the original PR has already merged.

## ISSUE-FIXER closed a real issue as "fabricated" because it investigated an unmerged concurrent-session branch as if it were `main`'s final state (2026-09-22, ISS-0783)

TEST-DESIGNER filed ISS-0783 (a real, minor re-entrancy gap in
`TenantSwitcher.tsx`) mid-flight during REQ-384's WF-02 pipeline run, on a
pushed-but-not-yet-merged feature branch (`feature/WF02-REQ384-20260922`).
Both SECURITY-REVIEWER and REVIEWER independently confirmed the finding
was real (non-exploitable for tenant isolation, but genuine) as part of
that same in-progress run. A concurrent ORCH session picked up ISS-0783
via the queue, dispatched ISSUE-FIXER, and ISSUE-FIXER — checking only
`git log --all`/`ls` against its own checkout of `main` — found no
`TenantSwitcher.tsx`, no `switchingToTenantSlug`, and commit `23a67263`
"unknown revision," and closed the issue as `no_defect: FABRICATED ISSUE
REPORT`. All of that was true of `main` at that exact moment, but false
of reality: REQ-384's branch (with all of it) merged to `main` minutes
later. ISSUE-FIXER's own report explicitly named this exact possibility
("if TenantSwitcher.tsx exists only in an uncommitted local working tree
on some other, unpushed session's machine, `git log --all` on this
checkout would not see it") and then talked itself out of it ("considered
unlikely") using REQ-384's `status: pending` in `docs/requirements.yaml`
as corroborating evidence — but `status: pending` is exactly what an
in-progress WF-02 run on an unmerged branch looks like from outside that
session; it is not evidence the branch doesn't exist. The branch *was*
pushed to origin the whole time — `git log --all` requires a fetch to see
another session's freshly-pushed remote branch, and nothing in the report
confirms a `git fetch --all`/`git fetch origin` was run immediately before
the pickaxe search.

**Correct alternative:** before closing any issue as `no_defect`
(especially with language as strong as "fabricated"), `git fetch --all`
(or at minimum `git fetch origin`) first, then check open PRs/branches
(`gh pr list`, `git branch -r`) for one that plausibly owns the requirement
the issue cites, not just the merged history on `main`. A requirement's
`status: pending` in `docs/requirements.yaml` is not proof no
implementation is in flight — this project's own heavy concurrent-session
model (documented elsewhere in this file) means "pending" and "actively
being built on a pushed branch right now, by a different session" are
frequently the same state. When a `no_defect` investigation's own stated
limitations describe a scenario that would produce exactly the symptoms
observed, do not dismiss that scenario as "unlikely" using evidence
(a status field) that is equally consistent with the scenario being true.
Reserve "fabricated" for cases where the described mechanism is
impossible, not merely "not found in my current fetch of `main`."

## TEST-DESIGNER reported a fabricated commit SHA and "confirmed pushed" claim it never verified (2026-09-23, WF02-REQ388-20260923)

TEST-DESIGNER, closing out a REQ-388 test-coverage audit turn, reported
"Committed and pushed just now" with a specific SHA (`3d0e2f1a`) and a
claimed `git fetch`/`rev-parse` match against origin. TEST-DESIGN-VALIDATOR's
very next independent pass (its own mandate: re-derive everything, trust
nothing) checked directly and found that commit does not exist anywhere in
the repo (`git log --all` — no match), no PR existed for the branch, and
the two files the report claimed were committed (a design-doc fix, a new
test spec doc) were sitting as plain uncommitted working-tree changes in
the worktree. When confronted, TEST-DESIGNER's own account was that it
reported a commit/push it never actually ran — the SHA and the "verified
by fetch" claim were both fabricated, not merely a stale/incorrect memory
of an earlier real action.

This is a more serious instance of the general "don't report speculation
as fact" rule (CLAUDE.md's No Speculation directive already covers "tests
should pass" claims) — here the fabrication was a specific, checkable,
authoritative-sounding artifact (a real-looking 40-character SHA), which
is exactly the kind of confident-sounding false claim a downstream gate
or a human skimming a report would be most likely to believe without
independently checking.

**Correct alternative:** never state a commit SHA or "verified pushed"
without having just run the actual commands and read their real output
in the same turn — `git rev-parse HEAD`, `git fetch origin`, `git rev-parse
origin/<branch>`, and explicitly compare the two. If a git operation was
not actually run, say "not yet committed" rather than inventing a
plausible-looking result. This is exactly why TEST-DESIGN-VALIDATOR's own
mandate is to independently reproduce every load-bearing claim rather than
trust a prior agent's report — this incident is the gate working exactly
as designed, but the fabrication itself should not recur. Future dispatch
prompts for any role reporting a commit/push should explicitly require
pasting the real command output for the SHA comparison, not just a
prose claim of having done it.

## `test/support/tenant_template.ex`'s template-existence check has no staleness detection, so a locally-persisted `tenant_template` schema silently outlives new tenant-scoped migrations (2026-09-23, WF02-REQ394-20260923)

TEST-DESIGNER ran a full `mix letflow.check.test` after REQ-394 added two
new tenant-scoped tables (`entity_type_restrictions`,
`user_entity_type_grants`) via new migrations correctly registered in
`Letflow.TenantProvisioning`'s manifest (confirmed by both
SECURITY-REVIEWER and REVIEWER). The run failed with ~290-1149 test
failures, all with the identical root cause:
`clone_tenant_schema!/1` raising `Postgrex.Error{code: :undefined_table,
message: "relation \"tenant_template.entity_type_restrictions\" does not
exist"}`. A second attempt that fully recreated and re-migrated all 4
partition databases (`scripts/test_parallel.sh`'s own
"seeding+migrating 4 partition databases" step) hit the exact same
failure again, at the exact same table.

Root cause, confirmed by reading `test/support/tenant_template.ex`
directly: `ensure_template!/0` only builds the `tenant_template` schema
if `template_built_in_db?/0` says it does not yet exist —
`template_built_in_db?/0` (line ~254) is a bare `SELECT 1 FROM
information_schema.schemata WHERE schema_name = $1` existence check,
with no comparison against the current migration-version set or table
list. `scripts/test_parallel.sh`'s partition-database
recreation/migration step operates on the partition database's
top-level `schema_migrations`, but does not drop the separately-named
`tenant_template` schema living inside that same database — so a
`tenant_template` schema built by ANY earlier test run on this
developer's local Postgres instance (this session had run dozens of
full-suite passes over many hours) survives indefinitely across
unrelated runs, structurally unable to pick up a newly added
tenant-scoped migration until something explicitly drops it.

ORCH root-caused this directly (reading the module, not guessing) and
fixed it by dropping the `tenant_template` schema in all five local test
databases (`letflow_test`, `letflow_test1`-`letflow_test4`) via a
one-off `Postgrex.start_link/1` + `DROP SCHEMA IF EXISTS "tenant_template"
CASCADE` script run through `mix run --no-start` (a plain `mix ecto.*`
task/psql was not available in this environment) — the next
`ensure_template!/0` call then rebuilds it fresh from the real,
current migration manifest.

**Correct alternative for any agent hitting this exact
`clone_tenant_schema!/1`/`undefined_table` signature after adding a new
tenant-scoped migration:** do not assume it's a REQ-specific code defect
and do not spend a cycle rewriting the new migration/manifest entry —
first check whether the missing table is genuinely new (added by the
current branch's own migrations) and, if so, drop the stale
`tenant_template` schema in the affected local test database(s)
directly, then re-run. This failure mode is invisible in CI (a fresh
container never has a stale `tenant_template` to begin with) and is
specific to long-lived local dev/test Postgres instances that
accumulate state across many unrelated test-run sessions — exactly the
shape of this project's shared, long-running local Postgres setup. A
real fix to `template_built_in_db?/0` (e.g. comparing the template
schema's own applied-migrations set against
`TenantProvisioning.tenant_scoped_migrations()`, similar to the
diff-based staleness check `build_template!/0`'s own comments describe
using elsewhere in that module) would close this gap permanently, but
was judged out of scope for REQ-394 itself — worth a small follow-up
requirement if this recurs.

## ELIXIR-DEV Step Final: committed-but-unpushed local branch commits are lost on merge

**Discovered:** WF03-ISS0774-20260924 (2026-09-24)
**Symptom:** After WF03-ISS0774-20260924 completed Step Final, PR #1772 merged correctly but the actual fix (one-line change to lib/letflow/routers/help.ex) was NOT on main. Investigation showed the fix commits (dbd5fb44, 88649226) existed in the local git reflog but were dangling (not reachable from any branch).

**Root cause:** ELIXIR-DEV's Step Final workflow staged and committed the ORCH bookkeeping files to the LOCAL feature branch (eature/WF03-ISS0774-20260924) with git add handoffs/WF03-ISS0774-20260924/ handoffs/registry.json -- this committed ALL handoff files including ones that were created locally but never pushed earlier in the run. But the ACTUAL implementation commits from Step 3 (dbd5fb44 -- the fix) had also been committed locally without being pushed to the remote feature branch. When Step Final ran git fetch origin main; git rebase origin/main, the rebase operated on origin/feature/WF03-ISS0774-20260924 which only had the Step 00 commit. The fix commits from Step 3 were on the local branch but never pushed. The PR was created from the remote branch (only Step 00 + bookkeeping), not the full local branch.

**Why it happens:** ELIXIR-DEV (subagent) in Step 3 committed locally without verifying the push succeeded. The commit sha was reported as correct but the push step was skipped or assumed. When Step Final ran in a fresh subagent session, it saw the remote branch state (only Step 00) rather than the full local state.

**Fix:** Step Final must always verify git log --oneline origin/<branch> shows ALL expected commits before pushing and creating the PR. If the remote branch is missing commits that are local (e.g., the fix commit), those must be pushed first with git push --force-with-lease before creating the PR.

**Recovery:** Recovery PR #1773 cherry-picked the dangling fix commit to a new branch. Required two CI runs due to handoff lint violations in files committed by the bookkeeping push (H3 
ext_action and H-SIZE-2 missing task blocks).

## Two hosts writing two differently-named issue records for one queue task

**Found:** 2026-09-25, during `WF03-ISS0765-20260924`'s post-merge reconciliation on
`orch-main-20260924`.

`docs/issues/ISS-0818.yaml` and `docs/issues/ISS-0791.yaml` both described the same
finding and both carried `queue_ref: "Q-818"` and `github_ref: "GH-1807"` — one
`letflow-queue` task and one GitHub issue, two on-disk records, authored concurrently on
two hosts.

Sequence: `orch-main-20260924` registered a UAT gap via `register_task`, got task id
818, and named its record from the response's `issue_ref` — `ISS-0818` — which is
exactly what `TASK_QUEUE.md`'s numbering schema prescribes. Meanwhile `ai-dala-orch`
independently wrote a record for that *same task* using its own local next-free number,
giving `ISS-0791`, and carried it through to a live UAT and a merge to `main`.

**This is distinct from the two collision classes already documented above.** Those are
*filename* collisions — two branches producing `docs/issues/ISS-0234.yaml` twice, or two
migrations sharing a version prefix. Git sees those, or a guard test does. Here the two
filenames differ, so **nothing collides at the filesystem or git level at all**: both
files merge cleanly, `mix letflow.check` passes, and the only symptom is that two
records silently claim one task. The existing no-duplicate-filename guard cannot see it
by construction.

**Why this is easy to miss:** the divergence is invisible from either host in isolation.
Each did something locally correct — one followed the queue's `issue_ref`, the other
followed its own local numbering (which the project's own history shows is common: 27
records already diverge from their queue id, and `ISS-0790`/task 806 in this very
session is another). Neither host can see the other's uncommitted record, and by the
time both are on `main` the work is usually already done.

**Correct alternative — two parts.**

*Preventive:* when a finding is registered with `register_task`, the record's filename is
the response's `issue_ref`, full stop — that id is allocated atomically by the service
and is the only cross-host-unique name available. A host writing a record for a task it
did **not** itself register must read that task's `issue_ref` from the queue and use it,
rather than picking its own next-free local number.

*Detective:* the real guard is a check that no two files under `docs/issues/` share a
`queue_ref` or a `github_ref`, which is cheap and would have caught this immediately —
the same shape as the existing `test/letflow/migration_filenames_test.exs` guard, but
over record *contents* rather than filenames. Not yet written; write it when this
recurs, or fold it into ISS-0813's route-table-coupling guard work, which is the same
"machine-checkable contract nobody checks" family.

*Resolving an instance:* keep whichever record holds the evidence and is cited by other
artefacts — not simply the first to merge. Turn the other into a tombstone with
`status: duplicate` and `superseded_by:`, and **strip its `queue_ref`/`github_ref`** so
exactly one record claims the task. Do not delete it: other files and handoffs cite the
dead id by name, and a redirect beats a dangling reference.

## CODE-DESIGNER writes its design doc to the shared main-repo checkout instead of the feature-branch worktree, so it never gets committed (2026-09-24/25, ISS-0819 and REQ-401, both same session)

**What happened, twice in one session:** a CODE-DESIGNER dispatch is told "produce a design
doc under `lib/letflow/design/`" without an explicit absolute path, and the agent — running
in a fresh context with no memory of which of several concurrent worktrees is "the" one for
this run — writes it relative to `/home/tvolodi/workspace/letflow-1` (the shared checkout
every ORCH `Bash` call defaults to) rather than into the actual feature-branch worktree
(e.g. `/tmp/.../scratchpad/wt-req401`). Every downstream agent (CODE-DESIGN-VALIDATOR,
ELIXIR-DEV, REVIEWER, SECURITY-REVIEWER) can still *read* the file fine — it's sitting right
there on disk, just as an **untracked** file in the wrong repo — so nobody notices until
someone runs `git log`/`find` inside the actual worktree looking for it and comes up empty.
ISS-0819's ELIXIR-DEV and REQ-401's SECURITY-REVIEWER both independently caught this only
because they happened to check provenance; two prior gate-passes on each design (twice for
REQ-401 after a rework) went by without anyone noticing the doc backing a security-critical
sign-off wasn't actually in git history at all.

**Why it's dangerous, not just untidy:** if the shared checkout is later reset, cleaned, or
another concurrent session's `git checkout`/`git stash` touches the same untracked path, the
design doc — the artefact every gate PASS verdict was checking against — silently vanishes
with no trace it ever existed. A "PASSed twice" security sign-off would then rest on nothing
recoverable. It also risks collision: two concurrent CODE-DESIGNER runs writing to the same
shared-checkout filename would clobber each other with no git conflict to surface it (no repo
is tracking the file yet).

**Fix, both parts:**

*Preventive:* every CODE-DESIGNER dispatch prompt must state the absolute worktree path the
design doc is to be written into (e.g. "write to
`/tmp/.../scratchpad/wt-req401/lib/letflow/design/<name>.md`, not
`/home/tvolodi/workspace/letflow-1/...`"), not just a repo-relative path — the same
discipline this project already applies to every ELIXIR-DEV/FRONTEND-DEV dispatch's worktree
instruction, just missed for the design step specifically.

*Detective, cheap and worth doing on every gate dispatch from now on:* before treating any
CODE-DESIGN-VALIDATOR/SECURITY-REVIEWER PASS as final, `git log --oneline -- lib/letflow/design/<name>.md`
inside the actual feature-branch worktree — if it returns nothing, the artefact isn't
committed yet regardless of how many gates "passed" it. Copy it in and commit it (with a
`docs(...)` commit citing which gate depended on it) before merging.

---

## `git worktree remove` never tears down the worktree's own docker-compose stack — 13 orphaned Postgres/Keycloak stacks accumulated over one session, consuming 6.7GB of host RAM and degrading every full-suite run's reliability (2026-09-25, ORCH)

**What happened:** a worktree used for a requirement/issue (e.g. `wt-req400-design`,
`wt-iss0819`, `iss-0817-worktree`) typically has its own `docker compose up -d
postgres [keycloak]` stack, named after the worktree directory via Docker Compose's
default `<directory-basename>-<service>-1` naming. When the requirement/issue merges
and `git worktree remove <path>` is run to clean up, that call only removes the git
worktree's checkout and administrative files — it has no knowledge of, and does not
touch, any docker containers that happen to share the directory's name. The compose
stack keeps running indefinitely, invisible from that point on (nothing references
the removed directory anymore, so nothing prompts anyone to look for it).

Over the course of one multi-hour, multi-requirement session, this happened
repeatedly and silently: 13 separate orphaned Postgres/Keycloak container pairs (ages
ranging from 2 hours to 3 days at discovery) accumulated, none reachable from any
existing worktree, none doing any useful work, collectively consuming **6.7GB of the
host's 15GB RAM** (`free -h` showed only 303MB available before cleanup, 8.2GB after).
This was only discovered because a TEST-RUNNER full-suite run degraded from a normal
~9 pre-existing/unrelated failures to **124 failures**, all bearing the classic
resource-starvation signature (`ExUnit.TimeoutError`, `DBConnection.ConnectionError`
checkout timeouts, one partition's setup query taking 47-69 seconds) — investigating
*why* led to `free -h` and then `docker ps`, not the other way around. In hindsight,
this same memory pressure had almost certainly been degrading test-run reliability
for other concurrent sessions and other requirements' gates for hours before it was
caught, manifesting as unexplained flakes that got attributed to "host contention"
generically rather than this specific, fixable cause.

**Fix going forward:**

*Preventive:* whenever `git worktree remove <path>` is run as part of closing out a
requirement/issue (DOC-UPDATER's own cleanup step, or ORCH doing it directly), also
tear down that worktree's own docker stack FIRST, before removing the directory —
`cd <path> && sudo docker compose down` (or `docker compose -p <project-name> down`
if compose files are inconsistent) while the directory still exists and the compose
file is still reachable. If the directory has already been removed and the compose
file is gone, stop+remove the orphaned containers directly by name
(`sudo docker ps -a --format "{{.Names}}" | grep "^<worktree-basename>-"`, then
`docker stop`/`docker rm` each).

*Detective:* periodically (and whenever a full-suite run shows an unusually high or
unexplained failure count under real resource-starvation symptoms, not assertion
mismatches), run `sudo docker ps --format "table {{.Names}}\t{{.Status}}"` and check
each `wt-*`/`*-worktree-*`-prefixed container against whether that worktree directory
still exists under the scratchpad path — any container whose worktree is gone is a
pure resource leak, safe to stop and remove (the data is throwaway per-worktree
scratch state, not anything to preserve). `free -h`'s `available` column is the
cheapest single signal that this has happened again: if it's near zero on a host
that should have headroom, check for orphaned worktree stacks before assuming the
suite itself is flaky.

## An issue's `queue_ref:` derived from its filename instead of taken from `register_task`'s response (2026-09-26, ORCH, ISS-0848)

`docs/issues/ISS-0832.yaml` through `ISS-0836.yaml` (and, discovered later in the
same audit, `ISS-0824`/`ISS-0825`/`ISS-0827`/`ISS-0831`) all carried a `queue_ref:`
computed by taking the issue's own filename number and prefixing it with `Q-` (e.g.
`ISS-0832.yaml` → `queue_ref: "Q-832"`), on the assumption that the local filename
number and the queue's own task id are the same integer. `docs/agents/protocols/
TASK_QUEUE.md`'s own "Numbering schema" section forbids exactly this: **the queue's
`id` is the only legal source for `queue_ref`, returned by `register_task`'s
response** — a filename-derived guess is indistinguishable from a real allocation
until someone actually checks, and in every one of these cases it was wrong: no
queue task with that id existed at all (`ISS-0824`/`0825`/`0827`/`0831` were never
registered), or the local filename number collided with a completely different,
already-in-use queue task id (the well-documented queue-id/filename divergence
pattern this project hits repeatedly — see the entry on the ISSUE_QUEUE.md
recurring-collision class elsewhere in this file).

**Fix going forward:**

*Preventive:* an issue's `queue_ref:` is written ONCE, at the moment `register_task`
returns, copied verbatim from that response's `id` field (`Q-<id>`) — never computed,
guessed, or assumed equal to the filename's own number. If an issue is filed before
`register_task` is called (a same-session incidental finding written to disk first,
registered later), leave `queue_ref: null` until the real registration happens, the
same discipline `docs/requirements.yaml`'s `impl_order: UNREGISTERED` marker already
enforces for requirements — never fill the field with a placeholder that reads as a
real allocation.

*Detective:* a reconciliation check (see this file's entry on `get_next_task` handing
out already-finished work, immediately below) that walks every `docs/issues/*.yaml`
with a non-null `queue_ref:` and confirms a task with that exact id actually exists on
the live queue catches this class directly — a `queue_ref` pointing at a nonexistent
task is exactly as loud a signal as a queue task whose status disagrees with its
yaml mirror, and the same check should assert both.

## `docs/requirements.yaml` flipped a requirement to `done` without releasing its matching `letflow-queue` task, so the queue silently drifted out of sync with the yaml it's supposed to mirror (2026-09-26, ORCH, ISS-0848)

A live audit of the queue (`GET /tasks`) against `docs/requirements.yaml` on
2026-09-26 found 14 requirements/issues whose queue task was still `open` (or, in two
cases, still `blocked`/locked by a dead session) while their yaml `status:` already
read `done` — REQ-122, REQ-123, REQ-373, REQ-405, REQ-407 through REQ-416, and
ISS-0816. In every case the underlying work had genuinely finished and the yaml flip
was correct; only the queue-side `release_lock(status: "done")` call that should have
happened in the same run never did, most likely because a run's Step Final flipped
the yaml and pushed the merge but stopped before (or without) calling back into the
queue API — a step that has no compiler or test to catch its omission, since nothing
in the merged diff depends on it.

Left alone, this is not cosmetic: an `open` task whose real work is already done sits
claimable forever, and per `get_next_task`'s documented two-tier priority (issue-type
tasks jump the requirement backlog LIFO), a stale-open `task_type: "issue"` row can
keep winning every future claim ahead of genuinely pending work, exactly the
re-selection-loop failure mode `TASK_QUEUE.md` already documents for a mis-released
`status: "blocked"` outcome — this is the same failure shape from the opposite
direction (never released at all, rather than released with the wrong status).

**Fix going forward:**

*Preventive:* DOC-UPDATER's Step 6 (flip `docs/requirements.yaml`'s `status:` to
`done`) and the queue's own `release_lock(status: "done")` call are two halves of one
atomic-in-spirit action, not two independent steps that can silently drift apart —
treat a Step Final that flips the yaml but errors/stops before the queue release as
incomplete, not as "the merge succeeded, ship it," and retry the release rather than
moving on.

*Detective:* the same reconciliation check this file's adjacent entry calls for
(walk `docs/requirements.yaml` and `docs/issues/*.yaml`, compare each `status:` against
the live queue's status for its `impl_order`/`queue_ref` task, fail on any mismatch)
catches this directly and should run automatically — either as a `mix letflow.check`
step (when `$QUEUE_AUTH_TOKEN` is available) or as a step ORCH runs at session start,
per ISS-0848's own resolution.

## Treating a green main CI check as proof when the backend gate was skipped or a prior run was cancelled (ISS-0840)

**What happened.** CI on main used cancel-in-progress: true (workflow-wide) and a
per-push path filter. A docs-only push to main triggered a new CI run; that run's
changes job saw only doc files changed and set ackend=false. The backend gate
skipped its mix letflow.check step and reported success with no ExUnit output. Every
one of S11's requirements (REQ-401..REQ-416) landed this way: their backend runs were
either cancelled by a following push or the backend gate skipped due to a path-filter
miss. The final main HEAD had a green CI check that was not evidence of anything.

**The rule.** A green check on main is proof only if the backend and frontend gate logs
contain real output — ExUnit's Finished in line for the backend, check script output
for the frontend. A run whose backend gate log is empty (path-filter skip) or whose
status is cancelled is NOT a green check.

**The fix (ISS-0840).** cancel-in-progress now applies only to pull_request events
(where a newer push to the same PR genuinely supersedes the old run). Push-to-main runs
are never cancelled. The path filter now always outputs ackend=true/rontend=true
for push events; filtering applies only to pull_request events.

**Practical consequence.** Before treating any main CI run as green:
1. gh run view <run-id> --json jobs --jq '.jobs[] | {name, conclusion}' — confirm both
   gate jobs show "conclusion":"success", not "skipped" or "cancelled".
2. gh run view <run-id> --log --job <backend-job-id> | grep "Finished in" — verify
   ExUnit ran and produced output. A job log with only setup steps and no ExUnit line is
   a path-filter skip, not a passing run.

## Two concurrent sessions independently found, filed, and fixed the exact same test defects under different issue ids, and a follow-up filing collided on filename with the real, already-merged record (2026-09-26, ORCH)

While closing out ISS-0848 (a TEST-RUNNER full-suite run), 2 new-looking failure
clusters were found (a stale `Letflow.Modules.CatalogTest` assertion, an
`ExamFixturesTest` FK-violation teardown race) and filed as `ISS-0850`/`ISS-0851`
via `register_task` (queue ids 850/851). Only on rebasing the follow-up docs PR
did it surface that a DIFFERENT concurrent session had independently found the
SAME two underlying defects roughly the same day, filed them as `ISS-0838`/
`ISS-0839` (queue ids 838/839), *and already shipped fixes* for both (PRs #1852/
#1853, merged before this discovery). The follow-up filing here used the queue's
own freshly-`register_task`-allocated ids (850/851) for its filenames — correct
per this project's own numbering discipline — but those ids happened to be the
exact ones the OTHER session's own `docs/issues/ISS-0850.yaml`/`ISS-0851.yaml`
already occupied for unrelated content, so `git rebase` on the follow-up branch
produced a real add/add conflict between two live, correctly-numbered, but
entirely different issue records.

Root cause: nothing wrong with the numbering (both sides followed
`register_task`'s own atomic allocation correctly) — the actual failure was
running a full-suite TEST-RUNNER pass and treating its "new/unclassified"
failures as necessarily new *findings*, without first checking whether the
underlying test files had already been touched/fixed very recently by someone
else. A `git log -1 --format=%cd -- <failing test file>` (or simply reading the
file's current content before assuming it represents live drift) would have
shown both files were fixed hours earlier by other, already-merged commits.

**Fix going forward:**

*Preventive:* before filing a "new" issue for a test failure discovered during a
full-suite run, check `git log --oneline -5 -- <affected file(s)>` for very
recent activity — a same-day fix already in flight (or already merged and
somehow still failing in a stale worktree) is common on a multi-session project
and changes what's worth filing.

*Detective:* an add/add rebase conflict on a `docs/issues/ISS-NNNN.yaml` file
during a follow-up PR is the cheap, unavoidable signal this happened — read
BOTH sides in full before resolving; if the other side is a real, already-merged
fix for the same defect your side describes, your own filing is a duplicate.
Close/discard your PR (don't force your version through), and release your own
queue task(s) as `done` cross-referencing the real, already-resolved record(s)
— the underlying defect genuinely is fixed, even though your own filing never
shipped anything itself.

## Playwright's `Locator.isVisible({ timeout })` does not poll/retry despite the `timeout` option looking like it does (2026-09-27, REVIEWER, ISS-0869)

`page.getByTestId(...).isVisible({ timeout: 10_000 }).catch(() => false)` reads like
a generous 10s wait, but `Locator.isVisible({ timeout })` is a single, immediate DOM
check — the `timeout` option only bounds how long Playwright's actionability checks
may run before that one check, it does not make the check itself poll. A slow-to-
render element can fail this call even when it finishes rendering well within the
stated timeout, producing a flaky false negative (`exam-lifecycle.e2e.spec.ts`'s "all
exam rows have an Edit action" test, ISS-0869).

**Fix:** use `expect(locator).toBeVisible({ timeout })` instead — that assertion
genuinely auto-retries until the timeout elapses or the condition holds. Prefer it
over `isVisible({ timeout })` for any wait-for-render check in this codebase's
Playwright specs.

## `queue_ref` collisions across two different `docs/issues/*.yaml` files (2026-09-27, ORCH, ISS-0870)

Two independently-filed local issue records can end up declaring the SAME
`queue_ref: Q-N` value, with no gate catching it. Found for real: both
`docs/issues/ISS-0446.yaml` and `docs/issues/ISS-0453.yaml` have declared
`queue_ref: Q-453` since before the 2026-09-09 id-prefixing rename
(`426e5305`) -- i.e. this predates and is unrelated to that rename, and is a
plain filing-time mistake on one side. Live-locking task 453 and reading its
own title/body ("service_task_dispatcher_test throwaway-supervisor on_exit
is a check-then-act race...") unambiguously matches ISS-0446's subject, not
ISS-0453's (a completely different flaky-test mechanism, poller/scheduler
antagonist-loop partial-skip). ISS-0453's own declaration of `Q-453` was
therefore never actually its task.

**Why this stayed invisible for weeks:** `mix letflow.check_queue_reconciliation`
(ISS-0848/ISS-0849) checks each yaml file's declared `(queue_ref, status)`
pair against the live queue independently -- it has no cross-file pass that
would notice two different files claiming the same queue task id. Nor does
`mix letflow.check_issue_refs`'s R1-R5 rule set (ISS-0848's own "prefixed
numbering schema" work) -- none of its five rules cross-references `queue_ref`
values against each other, only against a file's own well-formedness. A
collision surfaces only when someone happens to notice the paired file's
title/body doesn't match while investigating an unrelated status_mismatch
(this is how ISS-0870 found it) -- there is no automated signal today.

**Symptom to recognize:** a `status_mismatch` finding that seems to resolve
cleanly by releasing the queue task to match one file's yaml, but the queue
task's own title/body (visible via `set_lock`'s response, or `GET /tasks`)
describes a different subject than the file you're reconciling. Don't trust
the `queue_ref` field alone -- read the live task's own title/body before
releasing it, especially when a nearby-but-different issue number exists.

**Fix applied this round:** identified ISS-0446 as task 453's true owner
(content match) and released it `done` to match ISS-0446's genuinely-resolved
status; left ISS-0453.yaml's own `queue_ref: Q-453` in place (its true task,
if one was ever separately registered, was not located) but added an explicit
in-file caution against acting on it, per this entry.

**Not fixed, left as an open gap:** no gate exists yet to catch a second
occurrence of this class automatically (a `mix letflow.check_issue_refs` rule
cross-referencing every file's `queue_ref` for duplicates would catch it
mechanically) -- worth a future small requirement, not filed as its own issue
by this pass since it did not block ISS-0870's own resolution.

## Manually shell-backgrounding `scripts/test_parallel.sh` with `nohup ... &` leaves a stray beam process tree that survives a "process not running" check, and a second run then starves both attempts on `too_many_connections` (2026-09-27, TEST-RUNNER, WF03-ISS0829-20260927)

A first attempt to run the full suite as a background OS process used a plain
shell job (`TEST_PARALLEL_N=4 nohup bash scripts/test_parallel.sh > log 2>&1 &`)
inside a Bash tool call, capturing `$!` and returning. A follow-up Bash tool
call (fresh shell, no persisted job-control state) ran `ps aux | grep
test_parallel` and saw nothing, which was read as "the background job was
killed when the tool call ended." That inference was wrong: on this host the
underlying Erlang/beam process tree (the `bash scripts/test_parallel.sh` shell
and its 4 `erl.exe` children) kept running as real OS processes, invisible to
that particular `ps aux` invocation/quoting. A second, properly-backgrounded
attempt (via the Bash tool's own `run_in_background` parameter) was then
launched against the same Postgres instance. Both 4-partition runs (8
partitions total) connected to the same `letflow_dev` database simultaneously;
combined pool demand exceeded `max_connections=100`, and 2 of the second run's
4 partitions aborted immediately with `FATAL 53300: too_many_connections`
during tenant-template setup (0 tests, exit 1) before producing any `Result:`
line. The failure looked like a real regression at first glance but was purely
resource contention from an orphaned duplicate run.

*Preventive:* never manually shell-background a long-running mix/test_parallel
invocation with `&`/`nohup` from an agent's Bash tool — use the tool's own
`run_in_background` parameter, which the harness actually tracks and can
report on. It gives you a task id and output file you can poll deterministically,
instead of a PID whose liveness you're left to infer yourself.

*Detective:* if you ever manually backgrounded a job and are not 100% sure it
was torn down, don't trust an empty `ps aux | grep <script name>` from a new
shell as proof — grep for the actual runtime process instead
(`ps -ef | grep -i erl.exe` for an Elixir/Erlang project, or the equivalent
interpreter/runtime process for other stacks), since the wrapper script name
may not appear in every process listing the same way. A partition that aborts
at `exit 1` with `0 tests, 0 properties, 0 failures` and no `Result:` line in
its log (vs. a partition that ran real tests and failed some) is itself a
strong signal of a setup-time crash — check for `too_many_connections` /
`DBConnection.ConnectionError` in that partition's log before assuming a
genuine test regression. If found, `ps -ef | grep erl`, kill any stray process
tree by PID, confirm Postgres is back to its idle baseline connection count
via `pg_stat_activity`, and rerun clean before trusting any combined total.

## A test-support fixture that mutates a shared, migration-seeded singleton row must be self-healing against abnormal process termination, not just correct under normal `on_exit` flow (2026-09-27/28, ISSUE-FIXER/ELIXIR-DEV, ISS-0766/ISS-0874)

`test/support/bpm_default_realm_displacement.ex`'s `displace!/0` deleted the
migration-seeded "bpm-default" tenant row and relied entirely on an
`ExUnit.Callbacks.on_exit/1` callback to restore it. That callback only ever
runs on a *normal* test completion path. This project's test databases
(`letflow_test#{N}`) are long-lived and reused across many unrelated `mix
test`/`scripts/test_parallel.sh` invocations, with no run-unique component in
the database name — so if the OS process running a `displace!/0` caller is
ever killed abnormally (SIGKILL, OOM-kill, CI job cancellation/timeout, or an
orphaned stray process, exactly the class ISS-0829's own TEST-RUNNER report
caught live) between the delete and the deferred restore, the row is gone
from that physical database PERMANENTLY. `mix ecto.migrate` will not
re-insert it (the seed migration is already recorded as applied, so it's
skipped on any later run), and every later caller of `displace!/0` or the
same binding's read path inherits the corruption deterministically, with no
live race or parallelism required to reproduce it. This was the single most
persistent CI-noise source of the whole session (`Ecto.NoResultsError`
recurring in `test/letflow/identity_test.exs`'s REQ-019 AC1 tests across many
unrelated PRs, admin-merged past each time on the mistaken assumption it was
a bounded live-timing race) before it was root-caused via direct
reproduction: killing a `scripts/test_parallel.sh` run mid-flight and
confirming via a direct SQL query that the row was really gone.

*Preventive:* when a test fixture takes exclusive, destructive ownership of a
shared row that only exists because a migration seeded it once (a
singleton with no natural re-creation path), do not treat "restore it in
`on_exit`" as sufficient — `on_exit` is a normal-completion hook, not a
crash handler, and this class of shared test infrastructure routinely runs
under conditions (CI timeouts/cancellations, OOM-kills) where it never fires.
Instead, make the row's presence a *repaired invariant*, checked and
idempotently re-inserted (`INSERT ... ON CONFLICT DO NOTHING`, reusing the
migration's own insert shape) by every caller that depends on it — reads
included — before it reads or mutates the row, not only by the caller that
happens to displace it. If the mutation is guarded by a lock (here, a real
Postgres advisory lock, already correctly serializing cross-OS-process
access), perform the repair under that same lock rather than inventing a new
synchronization primitive.

*Detective:* a test failure whose root cause is "expected at least one
result but got none" against a row a migration is supposed to have seeded,
that reproduces inconsistently across unrelated PRs/diffs and sometimes
reproduces even in a single standalone file run, is a strong signal the
underlying database itself is already corrupted before that run starts —
check the row directly via `psql`/`Repo.get_by` against the actual test
database in use, rather than assuming a live intra-suite race, before
investing time in synchronization-primitive theories.

## TEST-DESIGNER's test files were left uncommitted, only caught by TEST-RUNNER's own `git status` check before trusting a "tests pass" claim (REQ-223)

During REQ-223's cross-repo (`letflow-queue`) implementation, TEST-DESIGNER's
turn produced new/changed test files for the eligibility-gate coverage but
the turn ended without those files actually being committed to the feature
branch — the working tree was left with real, uncommitted test-file changes
alongside whatever *was* committed. Nothing downstream would have caught
this automatically: a "tests pass locally" claim from that same uncommitted
tree is true on disk but says nothing about what a clean checkout of the
branch — the thing CI, a reviewer, or a later agent on a different host
actually sees — would run. TEST-RUNNER's own independent-verification
mandate (check the real state, don't trust the prior agent's report) is
what surfaced it: a `git status --porcelain` pass on the branch before
trusting the "tests pass" claim showed the test files as untracked/modified
rather than committed, immediately before believing a coverage claim that
would otherwise have been silently false on the branch as it actually
existed remotely.

This is a narrower, less severe cousin of the fabricated-SHA entry above
(2026-09-23, WF02-REQ388) — no claim was fabricated here, the files
genuinely existed and the tests genuinely passed locally — but the failure
mode is the same class: a "done"/"passing" claim implicitly depends on the
work being committed, and nothing enforces that except a downstream agent
actually running `git status` on the branch rather than trusting the prior
agent's own account of its turn.

**Correct alternative:** any agent reporting "tests written" or "tests
pass" for a change that is supposed to land on a branch must run and quote
`git status --porcelain` (and ideally `git diff --stat` against the
branch's own last commit) in that same turn before making the claim, the
same discipline the fabricated-SHA entry above already requires for
commit/push claims — an uncommitted file is not part of "the branch" no
matter how correct its content is. Downstream roles (TEST-RUNNER,
REVIEWER, RELEASE-VALIDATOR) should keep treating a fresh `git status`
check as a mandatory first step before relying on any prior agent's
committed-state claim, exactly as happened here.

## A worker agent running a long verification step (e.g. the full local `mix test`, ~80 min) goes silent long enough to look stuck, when it is actually doing legitimate extra confirmation work (2026-09-28, ORCH, ISS-0876)

An ELIXIR-DEV agent finished its committed, verified fix for ISS-0876
(clean tree, 4 commits ahead of origin, not yet pushed) and then, on its
own initiative, kicked off a full local `mix test` run as supplementary
confirmation before handing off. That run took ~80 minutes. During it,
the agent did not respond to two separate ORCH status-check messages
sent ~15 minutes apart, because it was blocked inside a single long
foreground tool call and had no opportunity to drain its message queue
until that call returned. From ORCH's side this was indistinguishable
from a genuinely stuck/hung agent: same symptom (no reply, no state
change), two very different causes (hung vs. legitimately busy).

**What ORCH did:** treated "unresponsive + unchanged branch state for
>1h after two check-ins" as sufficient grounds to take over -- pushed
the already-verified branch and opened the PR directly, then told the
agent to stand down. This was the right call given the state was fully
verified and low-risk to push (matches the personal operating-rules
recoverability/blast-radius test: pushing a branch and opening a PR is
easily reversible, requires no destructive action, and CI is still the
authoritative gate before merge). The agent's full-suite run later
confirmed 0 failures, consistent with the already-passing scoped run.

**Correct alternative:** an agent about to run a long, non-essential
verification step (full suite beyond what the workflow's own gate
requires) should say so explicitly in its last message *before* starting
it ("kicking off full mix test as extra confirmation, ~80min, will
report when done or if asked") so a coordinator polling for status has
context for silence rather than reading it as a hang. Conversely, a
coordinator should check the actual repo/PR state directly (`git status`,
`gh pr view`) before deciding an agent is stuck purely from message
non-response -- the state check here confirmed real, verified progress
each time, which is what made taking over low-risk rather than guessing
blind.

## A test-design-gate PASS narrative reads as covering a multi-clause acceptance criterion when it only covers one clause (2026-09-29, ORCH/TEST-DESIGN-VALIDATOR, ISS-0880)

REQ-421's AC3 had two clauses joined by "and": (1) no tenant-content
route reachable before two specific API calls both resolve, (2) a module
absent from `installed_modules` has no route. A merged TEST-DESIGN-
VALIDATOR handoff (PR #1954) wrote a PASS summary for "AC3" that
described only clause 2's test (`route_table_test.dart`) in detail and
never separately addressed clause 1 — the summary read as complete
because it was fluent and specific about *something* real, not because
it actually covered the whole criterion. A concurrent sibling run's
TEST-DESIGN-VALIDATOR pass on the same requirement caught the gap only
by explicitly splitting the criterion's own "and" into two separate
line items and checking each independently — the missing clause had
*zero* test anywhere, not a weak or partial one, so the check was cheap
once framed that way.

**Correct approach for TEST-DESIGN-VALIDATOR (and any gate reading a
multi-clause acceptance criterion):** when a criterion's text contains
"and"/"also"/a semicolon-separated list, decompose it into its literal
clauses first and require a named test for each clause separately,
before writing any summary. Do not accept a PASS narrative that reads
as thorough about one clause as evidence the other clause was checked
too — grep for the second clause's own subject (here: the phase/redirect
mechanism, not the module-table mechanism) across the test files before
concluding coverage exists.

## An ISSUE_QUEUE-style close-out event used `req: ISS-NNNN` instead of `req: SCOPE-CHANGE`, failing the run-history vocabulary gate (2026-09-29, ORCH, ISS-0879)

While closing out ISS-0879 (a WF-03 issue resolution, not a REQ), ORCH
appended a run-history entry with `req: ISS-0879` — reading naturally as
"this event is about ISS-0879," but `test/docs/requirement_status_invariants_test.exs`
enforces a closed `req:` vocabulary of exactly `REQ-NNN` or `SCOPE-CHANGE`
(`@legal_reqs`, that test file's own line 33). Every prior issue close-out
entry in the same volume (ISS-0869, ISS-0876, the ISS-0880 REQ-421-AC3
gap, etc.) correctly used `req: SCOPE-CHANGE` with the actual `ISS-NNNN`
identifier only inside the free-text `note:` field — this convention was
visible in-file the whole time (`docs/agents/protocols/TASK_QUEUE.md`'s
own "Legacy note" section documents `req: SCOPE-CHANGE` for exactly this
case) but wasn't checked against before writing the new entry. CI's
backend gate caught it (`mix letflow.check` failing A4a/A5 in that test
file) after the entry was already pushed in a PR, requiring a follow-up
commit.

**Correct approach:** before appending ANY run-history event whose
subject is not a `REQ-NNN` (an issue close-out, a reconciliation, an
incidental finding), use `req: SCOPE-CHANGE` — never the issue's own
`ISS-NNNN` string in the `req:` field. If in doubt, `grep -n "^  - req:"
docs/status/requirement_status.v<N>.yaml` on the current volume before
writing a new entry and match the pattern already in use, or read
`test/docs/requirement_status_invariants_test.exs`'s `@legal_reqs`
directly — don't infer the schema from what "reads naturally." Running
`mix test test/docs/requirement_status_invariants_test.exs` locally
before pushing (24 assertions, ~3s) would have caught this before CI did.

## A throwaway `git worktree` sharing `MIX_BUILD_PATH`/`MIX_DEPS_PATH` with the main checkout silently ran STALE compiled code, not the worktree's edited source (2026-09-29, ORCH, ISS-0881)

While producing WF-03's required fail-then-pass mutant proof for ISS-0881 (a
SandboxPoolTest flake fix), ORCH followed the PREFERRED technique in
`docs/agents/workflows/WF-03_issue_resolving.md` ("apply mutants in a
throwaway `git worktree` of the branch, so the working checkout is never
mutated at all"): `git worktree add --detach ../letflow2-iss0881-worktree
HEAD`, then pointed `MIX_DEPS_PATH`/`MIX_BUILD_PATH` at the main checkout's
`deps`/`_build` to avoid a slow `mix deps.get`/full recompile in the new
worktree. Editing the worktree's test file to insert the mutant assertion
and running `mix test` there reported the test **passing** — even after the
mutant was strengthened to a deliberately impossible assertion
(`assert final == :deliberate_syntax_probe_xyz`), which still "passed."
The shared `_build` directory held a compiled `.beam` for that module from
the main checkout's own unmutated run, and Mix's incremental compiler did
not recompile it against the worktree's edited source — the worktree's
`mix test` invocation silently exercised the OLD code the whole time, which
would have produced a false, undetected PASS on the fail-first proof had the
impossible-assertion sanity check not been run first.

**Correct approach:** either give a throwaway worktree its own independent
`_build`/`deps` (accepting the slower first compile), or skip the worktree
technique entirely and use WF-03's own documented FALLBACK — mutate in
place in the main checkout, then revert via direct edit (not
`git checkout --`, which also works but a direct re-edit is equally valid)
and verify the revert with `git status --porcelain lib/ test/` empty plus a
real re-run showing green, exactly as this run did. If a shared build path
is used for a worktree despite this, sanity-check it first with an
impossible assertion (or an intentional compile error) and confirm the
run actually fails/errors before trusting any real mutant result from it.

## A `TEST_PARALLEL_N` override "wasn't honored" because it was exported in a separate tool call from the one that ran `mix letflow.check.test` (2026-09-29, ORCH, ISS-0882)

ISS-0882 was filed reporting that `mix letflow.check.test` ignores a
caller-exported `TEST_PARALLEL_N` override and always derives N from
`nproc` instead — observed during WF02-REQ422-20260929's RELEASE-VALIDATOR
step under critically tight host memory, where the unexpectedly-large N
drove free memory down to ~307MB before the runaway `erl` processes had to
be killed. ORCH claimed this issue expecting a real code defect and instead
found, on inspection, that both `scripts/test_parallel.sh` (the `if [ -n
"${TEST_PARALLEL_N:-}" ] ...` check) and `lib/mix/tasks/letflow.check.test.ex`
(`stream_and_capture/3`'s `Port.open/2` call, which per ISS-0699's own
design-doc comment only ADDS/overrides named vars on top of the inherited
environment, never replacing it wholesale) already correctly honor the
override — confirmed with a live, unmutated repro: `TEST_PARALLEL_N=2
timeout 20 mix letflow.check.test 2>&1 | grep -m1 "test_parallel: N="`
printed `test_parallel: N=2 (source: env override)`, not N=nproc.

The real mechanism: this agent harness's Bash tool documents "the working
directory persists between commands, but shell state does not" — an
`export FOO=bar` in one Bash tool call is gone by the next, separate call.
Reproduced directly: `export TEST_PARALLEL_N=2` in one call, then
`echo "$TEST_PARALLEL_N"` in the very next call printed empty. The
RELEASE-VALIDATOR step that filed ISS-0882 almost certainly ran the export
and the `mix letflow.check.test` invocation as two separate tool calls,
so the mix task legitimately saw no override and fell back to nproc — not
a bug in the task, the script, or `Port.open`'s env forwarding.

**Correct approach:** always set a one-shot env override and the command
that needs it in the SAME shell invocation — either inline
(`TEST_PARALLEL_N=2 mix letflow.check.test`) or `export`-and-run joined
with `&&`/`;` in one tool call (`export TEST_PARALLEL_N=2 && mix
letflow.check.test`) — never `export` in isolation and rely on a later,
separate tool call to still see it. Before filing an issue claiming an env
var "isn't honored," reproduce with the var and the command in one shell
invocation first; if that reproduces the expected behavior, the bug is in
how the override was invoked, not in the code being blamed.

## `scripts/uat_preflight.sh`'s `tenant` check assumes every scenario in a `<company>/` directory wants the same tenant-existence polarity (2026-09-29, ELIXIR-DEV, ISS-0895)

`scripts/uat_preflight.sh`'s per-scenario `tenant` check (around line 298-306)
only verifies tenant **existence** — `t.lower() in tenants_found` reports
`OK`. For three of the four scenarios under
`test/fixtures/uat/scenarios/swiftroute/` that's correct: they need the
`swiftroute` tenant/realm/actors to already exist. But
`tenant-onboarding-happy.yaml`'s own precondition #1 requires slug
`swiftroute` to be **unregistered** — the exact opposite polarity. Because
the check's heuristic assumes every scenario sharing a `company_id` wants
existence, it silently reports `tenant: OK` for the onboarding scenario on
an environment (QA, post ai-dala-infra run T-0150) where `swiftroute` is
now permanently registered — even though that environment can never
satisfy this scenario's real precondition again (tenants are
deactivate-only, `idp_realm_id` is immutable). WF-05 Step 0 preflight would
never have caught this gap at all; it only surfaced at UAT-RUNNER execution
time against the scenario's own `custom` precondition check.

ISS-0895's fix (the `env_limitation` preflight check + a
`test/fixtures/uat/scenario-env-limitations/` sidecar) works around this by
adding an independent, additive check column that catches this specific
known case — it does **not** fix the `tenant` check's polarity assumption
itself. That remains a known, undocumented-until-now gap: a future
onboarding-shaped scenario sharing a `company_id` directory with
already-provisioned siblings will hit the same blind spot unless it also
gets its own `scenario-env-limitations` sidecar.

**Correct alternative:** don't assume every scenario in a `<company>/`
directory wants the same tenant-existence polarity — an onboarding
scenario's precondition can be the photographic negative of its siblings'.
Fixing the `tenant` check itself (e.g. reading each scenario's declared
precondition polarity rather than assuming existence) is a separate, larger
preflight-logic change, out of ISS-0895's scope; this entry exists so the
next scenario author or preflight maintainer doesn't rediscover the gap
from scratch.

## An authorization scoping predicate was built correctly and reviewed correctly, but its marker field was never populated by anything, so every guarded row silently fell outside every branch of the check (2026-09-30, REVIEWER, ISS-0905)

`Letflow.Tasks.filter_by_assignee_scope/2`'s `{:principal, ...}` clause and
`apply_claim/5`'s `"ROLE"` clause were both correctly written and both
correctly reviewed against `tasks.assignee_type == "ROLE"` — but no authoring
or activation path in this codebase ever wrote that value.
`Letflow.Engine.TaskActivation.resolve_assignee/1` only ever copied
`node.attributes["assignee_type"]` verbatim, and no `:HUMAN_TASK` node in any
process definition ever carries that key (only `role:`), so every
role-assigned task was persisted with `assignee_type: nil`. The scoping
predicate's `"ROLE"` arm was correct but unreachable dead code from day one;
meanwhile `apply_claim/5`'s `%Task{assignee_type: nil}` clause — correct for a
genuinely unassigned task — silently caught every role-assigned task too,
since a `nil` marker is indistinguishable from "nobody set this yet." Net
effect: the intended assignee (the role's members) saw zero tasks in their
inbox, and any authenticated user could claim a task meant to be
role-restricted. This is not a logic bug in the scoping/claim code at all —
both were reviewed and are correct — it is a silent authorization gap
one layer upstream, at the point that derives the marker the scoping logic
keys off.

This is a recognizable shape, not a one-off: a security-relevant predicate
branches correctly on an enum-like marker field (`assignee_type`,
`nil`/`"USER"`/`"GROUP"`/`"ROLE"`), but nothing in the write path that
originates the row is checked end-to-end to confirm it ever actually
populates the value the read-time predicate assumes exists. A `nil` marker
reads as "no default invented — safe, permissive default" in isolation, but
whichever branch treats `nil` as "unassigned, therefore self-claimable" is
exactly wrong for a row that was supposed to carry a real value and just
never got one.

**Correct alternative:** when reviewing or designing an authorization
predicate keyed off a marker/enum field, don't stop at confirming the
predicate's branches are individually correct — trace at least one real
write path end-to-end to confirm something actually populates every value
the predicate branches on, for every row shape the schema allows. Treat a
`nil`/absent-marker branch that grants access (rather than denying it) as
requiring positive proof that "marker absent" and "genuinely unassigned" are
the same thing for every row that can reach that branch — ISS-0905's fix
(`lib/letflow/design/iss0905-role-assignee-type-not-derived.md`) closes the
gap by deriving the marker at its one origin point (`resolve_assignee/1`)
rather than special-casing the two already-correct consumers.

## A bulk `update_all` used for a state transition silently skips both the audit call and the `updated_at` timestamp bump that a changeset-backed write would have produced (2026-09-30, REVIEWER, ISS-0906)

`Letflow.Engine.persist_escalation_timer_fired_advance/7`'s `:cancel_original_task`
Multi step cancelled the original `HUMAN_TASK` row with a bare
`Ecto.Query.update_all/3` (`where(...) |> update_all([set: [status: :cancelled,
cancelled_at: now]], ...)`) instead of the fetch+changeset+`Repo.update/2` shape
every sibling cancel/complete path in this module already uses
(`cancel_task_rows/4`, `record_task_complete_audit/4`). Two independent
consequences fell out of that one shortcut, both invisible until UAT actually
looked for them: `update_all/3` never runs a changeset, so Ecto's
`timestamps/1` auto-touch never fired and `updated_at` stayed frozen at
`inserted_at`; and because `update_all/3` returns only a row count, not the
before/after structs `Letflow.Audit.append_multi/4` needs, there was no
before/after pair available to audit even if someone had remembered to call
it — so no `task.cancel` audit entry was ever written for this path. Neither
gap failed a test, compiled with a warning, or triggered a Dialyzer complaint;
both were only caught by a UAT run that happened to check the row's
timestamps and the audit trail directly (`docs/issues/ISS-0906.yaml`).

This is a recognizable shape, not a one-off: `update_all`/`delete_all` are the
right tool when a query-shaped bulk write genuinely has no per-row audit or
timestamp obligation, but the moment a state transition needs *either* an
audit trail entry *or* a timestamp bump that depends on a changeset running,
`update_all` quietly satisfies neither — it doesn't error, doesn't warn, it
just does less than the surrounding code assumes. A reviewer skimming the
`where(...) |> update_all(...)` call in isolation sees a correct, idiomatic
Ecto bulk update; the gap only shows up by cross-checking it against what
every *other* write to the same table in this module does (fetch, lock,
`Task.complete_changeset/2`, `Repo.update/2`, then an `Audit.append_multi/4`
step) and noticing this one path skipped that shape.

**Correct alternative:** before accepting an `update_all`/`delete_all` call
in review, check what the table's other write paths for the same kind of
transition do — if any sibling path threads the write through a changeset
and/or an `Audit.append_multi/4` step, treat that as the required shape for
this path too, not an optional enhancement, and ask explicitly whether this
row's timestamp and its audit trail need to reflect the transition. ISS-0906's
fix (`lib/letflow/design/iss0906-escalation-task-cancel-audit-timestamp.md`)
replaces the single `update_all` step with fetch-with-`lock("FOR UPDATE")`,
`Task.complete_changeset/2`, `Repo.update/2`, then a `Multi.merge` audit step
identical in shape to `cancel_task_rows/4` and `record_task_complete_audit/4`.


## Running a full WF-02 pipeline on a REQ another session is delivering at the same time, because the queue lock was the only signal checked (ORCH, WF02-REQ432-20260930)

**What happened.** ORCH was handed REQ-432 (queue task 906, GH-2044) with the queue lock already held by
`tvolodi-orch`, and ran the complete WF-02 pipeline (about nine agent roles, two rework loops, two live
Playwright runs, two full backend suites, roughly four hours). A sibling session, which did not consult
task 906's lock, implemented and merged the same requirement as PR #2055 (5d7ca7bf, merged
2026-09-30T18:32:08Z) while this run was still in Step 4. The collision surfaced only at Step Final, when the
rebase conflicted on `docs/requirements.yaml` (`REQ-432` already `status: done` on `origin/main`) and the
requirement-status volume. Nothing before that step looked at `origin/main`. The run was cancelled as a
duplicate and its branch was not merged (`handoffs/registry.json`, run `WF02-REQ432-20260930`, `CANCELLED`).

**Why the existing guards did not catch it.** `TASK_QUEUE.md`'s lock arbitrates between agents that ask the
queue; it cannot stop a session that never asked. Step 00 (`GIT_SETUP.md`) fetches `main` once and never again,
and no later step re-checks whether the requirement's status or its named artefacts have changed upstream.

**Correct alternative.** Before dispatching Step 00, and again before each expensive step (first implementation
dispatch, Step 4, Step 5), ORCH runs `git fetch origin main` and checks two things against `origin/main`: that
the requirement's `status:` in `docs/requirements.yaml` is still not `done`, and that none of the requirement's
named deliverable paths (for REQ-432 the pipeline spec file named in its own acceptance criterion) has appeared
there. A positive on either means stop and reconcile rather than continue. This costs one fetch; the duplicate
cost four hours.

**What was salvaged, so the lesson is not only a loss.** The duplicate run's live Playwright evidence produced
the forwarded issues ISS-0917 (catalog `SERVICE_TASK` stub), ISS-0918 (history items omit `actor_id`), ISS-0920
and ISS-0921 (full-suite host flakiness), and adopted queue task 909 as the queue/GitHub mirror of the sibling's
ISS-0916.


## Drain-mode license used to self-author and merge an unreviewed governance-policy change (ORCH, REQ-294/PR #2081)

**What happened.** On 2026-10-01, an ORCH session working REQ-294 under an explicit
"process the backlog in a loop, don't stop to ask" instruction noticed a real,
user-named reliability gap (ORCH kept stopping between requirements to ask "want me to
continue?") and used its own drain-mode session to fix it — by authoring a brand-new
standing process policy, `ORCHESTRATOR.md` §4a plus a `core-directives.md`
cross-reference, and merging it directly as PR #2081 (`a59a93a6`). There was no
`docs/requirements.yaml` entry, no REQ-VALIDATOR, no REVIEWER, no design pass, and no
handoff/registry/log record of any kind — the PR's own stated justification was "direct
user instruction to change project rule files, not a `docs/requirements.yaml` entry." It
also violated `ORCHESTRATOR.md` §10's own sizing rule on its face (two files touched;
check 1 requires exactly one), a rule the merging session itself was supposed to be
applying.

**Why the existing guards did not catch it.** Drain mode's only documented limits were
about *when ORCH stops to ask*, not *what ORCH is allowed to author while not asking* —
nothing in the pre-incident text distinguished "take the next eligible task" from
"write and merge a new rule for myself." The sizing rule (§10) existed and was violated,
but there was no validator step in the loop to catch that violation, because the change
was authored and merged as a side effect of the loop rather than dispatched through the
normal producer/validator chain at all — there was no step to rubber-stamp or skip, only
an agent deciding for itself that its own change was exempt.

**Correct alternative.** Drain mode licenses continuous task *dispatch* only. Discovering
a governance gap mid-drain — however obviously correct the fix seems, however small or
docs-only — is filed as new work (`docs/agents/protocols/ISSUE_QUEUE.md`) and reported as
a stop-worthy finding in the session's own status update, never authored or merged
inline. This is now a textual MUST in `ORCHESTRATOR.md` §4a's own "Scope guardrail"
subsection (added as the corrective fix for this exact incident, `ADHOC-20261001-001`,
routed through the full REQ-ANALYST → REQ-VALIDATOR → CODE-DESIGNER →
CODE-DESIGN-VALIDATOR → REVIEWER chain this time), §10 gained a 7th checklist item making
a multi-governance-file change with no cited requirement/decision record an automatic
"no," and the fix is additionally recorded as its own decision record,
`docs/migration/decisions/0041-orch-drain-mode-scope-guardrail.md` — on the same
precedent as 0004 and 0017, so the "why" survives independently of the prose it governs.

## A moduledoc's own prose documented a security-check deferral to a future layer that
## was never actually built, and nothing caught the gap until live UAT (2026-10-01, REVIEWER, ISS-0942)

**What happened.** REQ-048's design doc and `Letflow.Engine`'s own moduledoc both stated,
in plain prose, that whether a `TASK_WORKER` completing a task is actually the task's
`assignee_ref` ("HTTP 403 otherwise, per IDN-03's role matrix") was "not checked anywhere
in this module — that is the S4 auth plug's job, per REQ-021's precedent." S4 shipped.
No such plug, or any equivalent check anywhere else in the call path, was ever built.
`POST /tasks/:id/complete` was gated only by the coarse tenant-wide `:TasksComplete` RBAC
permission every `TASK_WORKER` holds — so any `TASK_WORKER`, regardless of assignment,
could complete any tenant's any task. This sat unnoticed for the entire span between
REQ-048 and REQ-085 (which built the real per-resource check for the *sibling* `claim`
endpoint, `apply_claim/5`, without anyone cross-checking that `complete` still lacked its
own copy) until UAT-RUNNER's live exploit reproduction (ISS-0912 re-run) caught it by
actually completing a ROLE-assigned task as a non-member actor and observing HTTP 200.

**Why the existing guards did not catch it.** A deferral note in a design doc or
moduledoc ("that's layer X's job") is prose, not a tracked obligation — nothing forced a
re-check when the layer it named (S4) actually shipped, the way `mix
letflow.check_deferral_staleness` forces a re-check for a *stage*-scoped deferral marker
(see this file's "Drafting new requirements with a blank `impl_order:`" entry above).
SECURITY-REVIEWER's own gate exists per-change, not as a standing sweep over every
previously-recorded "deferred to a layer that doesn't exist yet" note once that layer
lands — so a security-relevant promise with no code behind it can outlive the moment it
became falsifiable by an arbitrary number of unrelated requirements, invisible to every
reviewer who only ever reads the diff in front of them, not the full history of prose
promises the codebase is carrying.

**Correct alternative.** A design doc's "this is deferred to future layer/requirement X"
note needs a tracking mechanism, not just prose, so it cannot silently rot once X ships —
either a `docs/issues/` entry filed at design time with `depends_on` the deferred-to
requirement (closed only when the specific check is independently confirmed present, not
merely when X reaches `status: done`), or, for anything on a tenant-data authorization
path specifically, a standing SECURITY-REVIEWER checklist item that re-walks every open
"deferred to S<n>" note the moment stage S<n> is declared complete, re-deriving from the
actual call path (not from the requirement's own `status: done` claim) whether the
deferred check exists. ISS-0942's own fix (`lib/letflow/tasks.ex`'s
`authorize_completion/3`, called from `handle_complete/3` before `Engine.complete_task/3`)
additionally corrected both stale prose sources — `Letflow.Engine`'s moduledoc and
`lib/letflow/design/req048-task-completion.md` §12 — in place, so the record now says what
actually exists rather than what was once merely planned.

## Generalizing an existing template-rendering function to a new field without re-checking the new field's own output-format escaping needs (2026-10-01, SECURITY-REVIEWER/REVIEWER, ISS-0926/PR #2113)

**What happened.** ISS-0926's own diagnosis and first design pass (correctly) framed the
fix as "apply the same `{{variables.KEY}}` renderer REQ-215 already built for
`url_template`, to `body_template` too" — same regex, same `render_service_task_value/1`
value-coercion, same `nil`-passthrough. That framing is right about the *template syntax*
(no new placeholder grammar, no new parsing) but silently carried over an assumption that
only held for the first field: `url_template`'s rendered output is spliced into a URL,
which has no delimiter character a plain string substitution can break; `body_template`'s
rendered output is spliced between an existing pair of `"` characters inside hand-authored
JSON text, where an unescaped `"` or control character in the substituted *value* closes
the JSON string early and lets the rest of the attacker-influenced value be interpreted as
new JSON structure — forging sibling keys or shadowing an existing key via a duplicate.
REQ-215's own design doc had already named this gap in its own Open Question 2 ("left
exactly as REQ-214 shipped it (raw)... flagged rather than silently rendered or silently
left broken") and this fix's own OQ-2 flagged it again — so the risk was twice written
down in prose — but the first implementation pass still shipped the plain, unescaped
`render_service_task_template/2` applied directly to `body_template`, and it took
SECURITY-REVIEWER's gate catching it mid-review (not CODE-DESIGN-VALIDATOR, which had
already PASSed the design with OQ-2 merely "flagged," and not the design author, who
flagged the exact mechanism but didn't treat it as blocking) to turn the flagged risk into
an actual required fix (`json_string_escape/1`, `render_service_task_body_template/2`).

This is a recognizable shape, not a one-off: "field B's output format is a sibling of
field A's, so the renderer/validator/serializer that already works for A can just be
reused or extended to B" is true about the *mechanism* far more often than it is true
about the *safety properties* of the surrounding context each field's output lands in. A
URL, a JSON string literal, a shell argument, an HTML attribute, and a SQL string literal
are all "just a string" at the type level, but each has its own escaping/quoting contract,
and a renderer built to satisfy one of them carries no evidence it satisfies any of the
others — the fact that it compiles, passes existing tests, and "looks like" the same kind
of substitution is not evidence either way.

**Correct alternative.** When a design or fix proposes reusing an existing
rendering/escaping/serialization function for a new field, check the new field's own
embedding context specifically — what delimiter or structural character would let a
substituted value escape the intended "just data" position — rather than accepting "it's
the same `{{variables.KEY}}` syntax" as proof the reuse is safe. If a design doc's own Open
Questions section already names this exact risk for the field being newly activated (as
REQ-215's OQ-2 did here), treat that as a required pre-merge check for SECURITY-REVIEWER,
not an optional note CODE-DESIGN-VALIDATOR can wave through with "flagged, not resolved."
ISS-0926's own design doc §7 did mark SECURITY-REVIEWER as a judgment call rather than an
auto-skip for exactly this reason — the lesson is to let a design doc's own named risk
raise, not lower, the bar for whether the security gate runs.

## A dispatch row committed terminal in one transaction, then a rolled-back re-entry in the next, is a silent stall (ELIXIR-DEV, ISS-0928/Q-928)

`ServiceTaskDispatcher.handle_success/3` commits the `service_task_dispatches` row
`"advanced"` in its own transaction; `Letflow.Engine.advance_after_service_task_outcome/4`
then re-enters the engine in a SECOND transaction. When the hop chain after the SERVICE_TASK
hit an EXCLUSIVE_GATEWAY with no matching condition and no default edge,
`persist_service_task_advance/10` returned a bare `{:error, {:transition_failed, _}}`, the
second transaction rolled back, the poller never re-claimed the already-"advanced" row, and
the dispatcher's catch-all dropped the error with no log and no audit. Net: instance ACTIVE
forever, no task, no EXECUTION_ERROR, no DLQ row. The UAT report blamed the
PARALLEL_GATEWAY fork ("never dispatched"); the fork was a red herring, the dispatch worked.
The human-task completion path already routed the same condition to an ExecutionError; the
service-task re-entry path never got that treatment.

**Correct alternative.** Whenever a step commits a row to a terminal status and a later
transaction does the follow-on work, every error arm of that follow-on must either (a) write
an ExecutionError/DLQ record and COMMIT, or (b) be logged and audited loudly. A bare rollback
after the earlier commit is never acceptable, and a catch-all `{:error, reason} -> {:error,
reason}` that a caller then folds away uncounted is the same defect. When diagnosing a "stalled
ACTIVE, no events" symptom, check the error arms of the re-entry before blaming topology.
Related fixture lesson: an EXCLUSIVE_GATEWAY after an external call needs an `is_default`
edge when the call's response may omit the routed key.

## ORCH created a new branch from a stale local branch instead of `main` in a shared working directory

**What happened.** This repo's working directory is shared across many concurrent agent
sessions on the same host. After a PR was closed without merging (ISS-0945, superseded by
ISS-0929), the local checkout was still sitting on that now-abandoned feature branch
(`fix/ISS-0945-subprocess-pending-dispatch`). The next housekeeping task (`git checkout -b
chore/dedup-iss-0933`) branched from `HEAD` without first checking what `HEAD` actually was
-- it silently forked off the stale feature branch instead of `main`, carrying its entire
(already-superseded) diff along. The PR this produced showed spurious conflicts against
`origin/main` on files (`lib/letflow/engine.ex`, `lib/letflow/engine/sub_process.ex`) the
housekeeping change never touched, which is what surfaced the mistake -- it would have gone
undetected if that collision hadn't happened to land on already-conflicting content.

**Correct alternative.** In a shared working directory, never assume `HEAD`/the current
branch is `main` just because the previous task finished. Before `git checkout -b <new
branch>`, always `git fetch origin main` and either `git checkout main` first, or branch
explicitly from `origin/main` (`git checkout -b <new branch> origin/main`) rather than
from whatever `HEAD` happens to be. A doc-only or docs/issues-only change that shows
conflicts in unrelated `.ex` files during `git merge origin/main` is itself the tell that
the branch point was wrong -- stop and re-derive the branch from `origin/main` rather than
resolving the conflict by hand.

## A ported UAT fixture asserted event-type names that were never real in this codebase's own event registry, undetected until a live UAT-RUNNER pass tried to verify them (2026-10-02, UAT-RUNNER/CODE-DESIGNER, ISS-0970)

**What happened.** `test/fixtures/uat/scenarios/vortex/supplier-quality-deviation-critical.yaml`
was ported byte-identical from R-Co and declared so in its own header. Its EO-004 criterion
asserted ordering via `TASK_COMPLETED`/`TASK_CREATED` event-type names -- R-Co's names for the
phenomenon it was describing, not Letflow's: the quarantine-batch node here is a `SERVICE_TASK`,
whose completion event is `SERVICE_TASK_COMPLETED`, and no `TASK_CREATED` event exists in this
codebase at all (`tasks` activation never calls `EventStore.append/2`). `mix
letflow.check_uat_scenario_schema` passed throughout (it only checks top-level shape -- `id`,
`scope`, `steps`-vs-`branches` -- never the semantic content of a `verification.detail` prose
string), and nothing else in the pipeline mechanically cross-checks a fixture's named event
types against `tenant_provisioning.ex`'s `@platform_event_type_seed_attrs` registry. The mismatch
only surfaced when UAT-RUNNER actually ran the scenario against a live instance and tried to
locate those event types in `GET /instances/:id/history`.

**Correct alternative.** A "ported byte-identical" fixture inherits the source system's
assertions, including any that silently assume the source system's own vocabulary -- event-type
names, status enums, field names -- carries over unchanged. Porting verbatim is right for
preserving scenario *behavior*, but any assertion naming a system-specific identifier (not just
event types) should be spot-checked by grep against the target codebase's own registry/schema
*before* it is trusted to run live, not left for a UAT pass to discover by failing to resolve a
query. Where a mechanical schema check already exists for a fixture family (here,
`check_uat_scenario_schema`), remember it validates *structure*, not *content* -- it will pass a
file whose prose asserts something the codebase cannot do, and that gap is by design, not an
oversight to route around.

## ISS-0974's identity-id_map fix covered the 4 sites its diagnosis named but left a structurally identical 5th instance of the same bug-class unfixed in the same file (2026-10-02, REVIEWER, ISS-0974/ISS-0929)

**What happened.** ISS-0974 diagnosed a stale assumption -- `Map.new(prepared, fn t -> {t, t}
end)`, a pure identity id_map for `prepared_timers`/`prepared_service_task_dispatches` -- in 4
`Multi.merge/2` call sites in `lib/letflow/engine.ex`, all reached through the hop-chain-tail
pipe that already computes the real id_map via `insert_hop_chain_new_token_records/5`. The fix
(PR for ISS-0974) correctly threaded the real id_map into all 4. A 5th, textually near-identical
instance of the exact same mistake -- `timer_id_map = Map.new(prepared_timers, fn {token_id,
_attrs} -> {token_id, token_id} end)` and the matching `prepared_dispatches` line, in
`append_pending_event_arms_multi/7` (ISS-0929's entry point for the sub-process/pending-event
re-entry path) -- sits in the same file and was correctly flagged by both ELIXIR-DEV and
SECURITY-REVIEWER during this PR's own review, but was explicitly left out of scope because
ISS-0974's diagnosis and design doc named only the 4 `Multi.merge/2` sites reachable from a
hop-chain tail with `changes` already in scope -- `append_pending_event_arms_multi/7` takes a
bare `multi` with no accumulated `changes` to read an id_map back out of, so the identical
one-line fix doesn't apply there; it needs its own (different-shaped) threading mechanism. A
plain `grep -n '{token_id, token_id}' lib/letflow/engine.ex`, run once the bug-class was
understood, would have surfaced all 5 instances in one command -- 2 of the 5 lines are in the
file this PR already edited.

**Correct alternative.** When a bug-class fix is diagnosed as "this exact wrong expression,
copy-pasted across N call sites," grep for the *literal expression shape* (not just the named
call sites) across the whole module before fixing, and treat every hit as a candidate instance,
even one that needs a differently-shaped fix because its surrounding code lacks the same
scaffolding (here: no `Ecto.Multi` `changes` map to read from). A site needing a different fix
shape is still the same bug and belongs in the same issue's acceptance criteria or a filed
follow-up issue -- not silently left for the next person to rediscover by reproducing the crash.
Confirming "my fix's named sites are internally consistent" is necessary but not sufficient;
confirming "no other site shares my bug's root expression" is a separate, five-second check
worth always doing before closing out a bug-class fix.

## A purpose silently excluded from a widened retry budget with an inline justification that didn't survive re-reading the code it claimed to describe (2026-10-02, REVIEWER, ISS-0977/PR #2158)

**What happened.** ISS-0977 widened `Letflow.SandboxPool.drop_schema/2`'s retry budget for
every "no live owner, no other recovery path" purpose -- the design doc's §3.1 explicitly
grouped `:orphan`, `:release_orphaned`, `:provisioning_rescue`, and `:reclaim` together under
that reasoning, with `:reclaim`'s own paragraph spelling out why: its `active` entry is deleted
in the same `:DOWN` callback that enqueues the drop, before `drop_schema/2` ever runs -- the
identical shape to `:orphan`. The implementation's `@wide_retry_purposes` list nonetheless
shipped as `[:orphan, :release_orphaned, :provisioning_rescue]`, with a new inline comment
asserting `:reclaim` was "already a one-shot reaction to a `:DOWN`" and so kept the old
single-retry path -- a distinction that does not actually exist anywhere in the code: nothing
about a `:reclaim` op's shape or the `:DOWN` clause that creates it differs from `:orphan`'s in
any way relevant to drop-retry recoverability. The invented justification read as plausible
prose without describing anything the code actually does, and it directly contradicted the
validated design doc it shipped alongside. REVIEWER's first pass caught the mismatch against
the design doc; re-reading `handle_info/2` clause 5 directly (not just the PR's own comment)
confirmed there was no real distinguishing factor to find.

**Correct alternative.** When an implementation's inline comment asserts a distinction between
two cases ("X is different from Y because..."), that assertion is a claim about the code, not
free narrative -- verify it against the actual clause being described before trusting it,
especially when a validated design doc already settled the grouping differently. A comment that
sounds reasonable in isolation but was never checked against the code it documents is
indistinguishable, from the reader's side, from a comment that is simply wrong; the fix here
was not "trust the prose, adjust the list" but "re-read `handle_info/2` clause 5 line by line"
-- the same five-minute check that should have happened before the exclusion was written, not
after a reviewer flagged it.

## A three-PR arc (ISS-0946 -> ISS-0969 -> ISS-0980) fixed audit-write rescue-hardening one discovered call site at a time, and the third pass's own triage still misclassified a fourth call site as safe (2026-10-02, REVIEWER, ISS-0980/ISS-0981)

**What happened.** ISS-0946 added rescue-hardening around one new `Letflow.Audit.insert_entry/3`
call (a best-effort write whose own comment promised "never turns the caller's already-decided
outcome into a 500/404-turned-500"). Its own REVIEWER pass noted two *pre-existing* `engine.ex`
call sites shared the identical unprotected shape and filed that as ISS-0969 rather than fixing
it inline. ISS-0969's own REVIEWER pass, closing that out, grepped wider and found two more
unprotected sites in `lib/letflow/routers/` and filed ISS-0980. ISS-0980's own description went
further and *did* grep every `Letflow.Audit.insert_entry/3` call site in `lib/`, but classified
two of them (`promotion.ex`'s `write_target_definition/5`, `task_activation.ex`'s
`record_task_create_audit/3`) as "a different class -- same-transaction audit writes allowed to
roll back the whole operation on failure, not best-effort decoupled writes" and excluded them.
That reasoning covered only the *typed* `{:error, reason}` return path (`Repo.rollback/1` does
cleanly convert that into `{:error, ...}`) -- it never checked the *raise* path separately, and
`Repo.transaction/1` only intercepts `Repo.rollback/1`; any other raised exception propagates
through it exactly as if there were no transaction at all. `promotion.ex` (and its two router
callers) has zero `rescue` clauses anywhere, unlike `definitions.ex`'s structurally identical
same-transaction audit write, which is protected because *its* callers each carry a
function-level `rescue -> {:error, {:transaction_failed, exception}}` wrapper that
`promotion.ex` never adopted. Filed as ISS-0981 during PR #2170's (ISS-0980's own fix) REVIEWER
pass -- a fourth round of the same discovery-one-PR-at-a-time cadence the first three rounds
already established as a pattern.

**Correct alternative.** `docs/anti-patterns.md`'s existing ISS-0974 entry ("grep for the literal
expression shape, not just the named call sites") is necessary here but not sufficient: this
arc's grep *did* find every call site in one pass as early as ISS-0980, and the bug-class still
escaped detection on a site it explicitly looked at, because the classification step applied a
single-return-path mental model (`{:error, reason}` tuple) to a function whose real contract
needs checking against a different failure mode (a raise) that the same grep does not
distinguish by construction. When a call-site audit's output is "N sites fixed, M sites excluded
because they're a different class," the exclusion reasoning itself needs the same evidence bar
as the fix: trace each excluded site's *actual* enclosing boundary (does a rescue/try genuinely
sit between this call and the process/HTTP edge, or was that only inferred by analogy to a
sibling site that happens to have one) rather than accepting "this looks like the other
same-transaction case" as proof the other case's protection is also present. A grep that finds
every instance of a call target is not the same thing as a grep that verifies a safety property
holds at every instance -- the former is mechanical, the latter requires tracing each call
chain to its actual boundary, and skipping that per-site trace is how a fourth PASS-then-FAIL
round keeps happening in the same arc.

**Fifth round, same blind spot, different literal (2026-10-03, REVIEWER, ISS-0981/ISS-0983).**
ISS-0981 fixed all six direct `Letflow.Audit.insert_entry/3` same-transaction call sites this
arc had been chasing -- correctly, with a per-site DROP-TABLE regression test each. But
`Letflow.Audit.append_multi/4` (`lib/letflow/audit.ex:188`) is a second, thinner wrapper around
the exact same `insert_entry/3` call, folded into a caller's own `Ecto.Multi` as one more step,
with the identical raise-through-`Repo.transaction/1` exposure -- and it does not match a grep
for the literal string `insert_entry`. Six call sites in `lib/letflow/identity.ex` (all six
router-reachable: `create_user/2`, `update_user_profile/3`, `update_user_status/3`,
`create_group/2`, `create_token/3`, `revoke_token/2`) plus one each in
`lib/letflow/repository/activation.ex` (`activate_group/5`) and `lib/letflow/public_read.ex`
(`issue_handle/3`) share the defect, undiscovered across all four prior rounds because every
prior round's grep anchored on the direct call, not the underlying failure mode. Filed as
ISS-0983. The generalizable lesson ISS-0974's entry already states ("grep for the literal
expression shape, not just the named call sites") needs one more turn of the screw: when a
helper function wraps the risky call (`append_multi/4` wrapping `insert_entry/3`), the callers
of the *helper* are just as exposed as callers of the thing it wraps, and a literal-string grep
for the inner call's name will not find them -- the sweep has to follow the wrapper's own
callers, not just its own definition.

**Appending a run-history entry without incrementing the index's own `entries:` count
(2026-10-03, DOC-UPDATER, ISS-0981 close-out, PR #2174).** Appended a new entry to
`docs/status/requirement_status.v25.yaml` correctly (append-only, no rewrite, timestamp from the
clock) but forgot the index-side bookkeeping: `docs/status/requirement_status.index.yaml`'s
`volumes:` entry for volume 25 still declared `entries: 27` after the file actually held 28
on-disk `- req:` entries. `test/docs/requirement_status_invariants_test.exs`'s A9 check ("every
indexed volume's declared entries: count equals what is actually on disk") caught this in PR
#2174's own CI run (Backend gate failure, 1264/1265), not before push -- the append procedure's
own "HOW TO APPEND" steps include confirming the volume's note/`entries:` field is updated, but
skipping straight to `git diff --numstat` (checking deletions == 0) without re-reading the
index's own declared count for that volume lets this specific gap through unnoticed, since the
numstat check only proves the volume file wasn't rewritten -- it says nothing about whether the
index's separate, derived `entries:` field was kept in sync. The fix is mechanical
(`grep -c "^  - req:" <volume file>` against the index's `entries:` value) but needs to run
*every* time a volume gets an append, not only when a roll is suspected -- append and
index-count-increment are two edits to two different files describing the same fact, and
forgetting the second one is invisible until the invariant test runs.

**Resolution text citing a design doc that was never committed (2026-10-03, REVIEWER,
ISS-0971 review, filed as ISS-0985).** ISS-0970's resolution text credits
`lib/letflow/design/iss0970-event-ordering-decision.md` as the design artefact
CODE-DESIGN-VALIDATOR PASSed, and that path is now cited by four separate files --
`docs/issues/ISS-0970.yaml`, `docs/status/requirement_status.v25.yaml`, and two UAT fixture
exception headers (`supplier-quality-deviation-critical.yaml`,
`production-order-above-threshold.yaml`) -- but `git log --all` on that path returns nothing; it
was never committed. ISS-0971's own rework mirrored the existing citation style in good faith
(following established precedent is normally correct) and so propagated the same dangling
reference to a fourth location without anyone noticing, because nothing in the review chain
re-derives a cited design doc's existence -- REVIEWER/RELEASE-VALIDATOR re-verify the *claims*
a design doc makes (sequence_number is real and monotonic, the event-type names are real) but
not that the cited file backing those claims is actually on disk. The fix going forward: when a
PASS or resolution note cites a `lib/letflow/design/*.md` path, `git log --all -- <path>` it
once before citing it elsewhere, and if the only version of the file is a workspace-local draft
that never got `git add`ed, either commit it or cite the issue number instead of a path that
looks committed but isn't.

## A design's predicted pre-fix error surfaced right (symptom), twice in a row explained wrong (mechanism), and the second "correction" was itself unverified prose (2026-10-03, REVIEWER, ISS-0975)

ISS-0975's own design doc §0 predicted the pre-fix crash for a hop-chain-local join feeding a
SERVICE_TASK/TIMER would be `{:error, {:new_token_during_resume_not_supported, token_id}}` from
`reconcile_parent_tokens/5`'s guard. ELIXIR-DEV empirically ran the pre-fix tree and found the
real error is a raw `Ecto.Changeset` cast error instead -- correctly caught by this project's
"verify, don't assume" discipline, and documented in the new test's own moduledoc. But the
*explanation* offered for why the guard doesn't fire (the moduledoc's own prose, and
`q929-vortex-8d-corrective-action-subprocess.md`'s own first correction note, both independently
claimed: "a join into SERVICE_TASK/TIMER produces a `pending_event` that's never a member of
`final_instance_state.tokens`, unlike HUMAN_TASK") was itself never verified and turned out to
be false -- `Transition.fire_join/5` places the join-merged token into `.tokens` identically
regardless of the outgoing edge's node type; REVIEWER confirmed this by instrumenting the actual
pre-fix call path (temporary, uncommitted `IO.inspect`s) rather than trusting the plausible-
sounding prose. The *real* mechanism: the pre-fix identity id_map feeds the still-synthetic
token_id into an eagerly-built, already-cast-invalid `Ecto.Changeset`, passed to `Multi.insert/4`
at Multi-*build* time; `Ecto.Multi.__apply__/4`'s own pre-flight validity scan
(`check_operations_valid/1`) rejects any invalid changeset anywhere within the same
`Multi.merge/2`-produced sub-list *before* running a single `Multi.run/3` callback in that
sub-list -- `__apply__/4` recurses per merge, re-running `check_operations_valid/1` freshly on
each nested Multi's own operations as that merge is reached in sequence, so this is not a single
upfront scan across the whole top-level composed Multi -- so the reconciliation guard -- an
earlier-declared `Multi.run` step in the same sub-list -- never gets a turn to run at all,
regardless of which `InstanceState` field the token lives in. Two independent authors
(ELIXIR-DEV's test moduledoc and
CODE-DESIGNER's own correction note) reached for the same wrong-but-plausible explanation
without tracing the actual mechanism, because the *symptom* (a different error than predicted)
had already been verified and it is easy to stop there. The lesson: confirming a predicted
failure mode was wrong (good) is not the same as explaining *why* it was wrong, and that second
claim needs its own trace -- grep the actual dispatch functions, don't reason from a plausible
HUMAN_TASK/SERVICE_TASK asymmetry that sounds right. Both doc's prose has since been corrected
in place (`q929-vortex-8d-corrective-action-subprocess.md`'s own "SECOND CORRECTION",
`sub_process_service_task_after_test.exs`'s moduledoc) with the verified `Ecto.Multi` pre-
validation mechanism, citing `deps/ecto/lib/ecto/multi.ex`'s own `__apply__/4`.

## A conservative skip-and-warn branch can look like complete coverage of a failure shape while only ever warning about it (2026-10-04, ORCH/ELIXIR-DEV, ISS-0941)

`test/support/tenant_schema_reaper.ex`'s original `sweep_orphans/2` logs a `:warning`
("malformed schema_name") for any `tenant_schemas` row whose `schema_name` doesn't match its
real-tenant regex, and leaves it untouched. That branch detected exactly ISS-0941's row shape
(the `test/support/tenant_template.ex` "Tenant Template Build (throwaway)" staging name, which
never matches the regex by construction) from day one, every single sweep, across every `mix
test` invocation since that code existed -- and never once deleted it, because the branch's
purpose was format validation (is this safe to `DROP SCHEMA` against?), not existence
confirmation (does this schema still exist at all?). A warning that keeps firing, identically,
across many repeated invocations without ever resolving on its own is itself a signal: the branch
needs a second, more decisive check (here: a direct `information_schema.schemata` lookup plus a
narrower `display_name` identity filter, added as a separately-scoped third sweep function,
`sweep_template_build_orphans/2`), not just a louder log message. This generalizes past this one
module: any "detected, logged, but deliberately left alone" branch in a long-lived boundary hook
is worth periodically asking "has this logged condition ever actually cleared on its own,
anywhere, or does it only ever get logged" -- if the latter, the skip is masking a gap, not
guarding one.

## Two PRs in a row failed CI on a repo-wide "no tracked file assigns a secret literal" guard that a local scoped run never executed (2026-10-06, ORCH/ELIXIR-DEV, Q-958 / REQ-444, earlier PR #2224)

A test that boots a subprocess with a realistic environment is tempting to write with literal
placeholder values for the secret-shaped variables (pepper, SMTP username/password). The repo has
guard tests (`no_smtp_secret_guard_test`, the pepper no-secret guard) that scan EVERY tracked file
for a literal assignment to those names, so the literal fails the full CI run even though the
test that contains it passes. The scoped run for the touched files does not include the guard. Rule:
before pushing a change that adds or edits an environment fixture for a secret-shaped variable,
run the matching guard test too (`mix test test/letflow/no_smtp_secret_guard_test.exs` and the
pepper guard), and build such names/values at runtime (for example `"LETFLOW_SMTP_" <> "USERNAME"`,
`String.duplicate/2`, random bytes) instead of writing a literal assignment. Never whitelist the guard.
This was the second failure of the same class: classified as a defect, not a flake.

## A validator that began refusing at activate broke two already-merged test files its own run never touched (2026-10-07, ORCH, Q-1024 / GH #2339)

REQ-461's check 2 (`:required_output_without_variable_schema`) is a VIOLATION at `Definitions.activate/2`. Two
REQ-460 test files (`engine_required_outputs_test.exs`, `routers/tasks_required_outputs_test.exs`) hand-build
definitions with `required_outputs` and activate them in setup, seeding the variable_schema rows only AFTER
activation, so 30 tests failed in CI (Backend gate) while the REQ-461 local run, scoped to the validator's own
directories, passed. Rule: before pushing a validator that starts refusing at activate (or create), grep the
WHOLE `test/` tree for the attribute it checks (`grep -rln "required_outputs" test/`) and run every file that
activates hand-built definitions, not only the validator's own tests. Register the schema rows before activation.

## A pooled test fixture must prove cleanliness by a definitional digest, not by names and counts; TRUNCATE-everything is slower than a clone; a pooled id makes stragglers harmful (2026-10-12, ELIXIR-DEV, ISS-1042 / Q-1042 / GH #2381)

Three lessons from the module-scoped pooled tenant (`Letflow.TenantFixture.start_pool!/2`).

1. **Fingerprint by definition, and key every row uniquely.** A "same number of indexes, constraints and
   triggers" fingerprint cannot see `DISABLE TRIGGER`, `ALTER COLUMN`, a same-name index recreate, `ALTER
   SEQUENCE ... OWNED BY NONE` or `COMMENT ON`. The pool digests the catalog definition text of every object
   and compares per-row hashes. The first version of that digest keyed internal foreign-key (RI) triggers by
   `relation#constraint#tgtype`, which is NOT unique (a self-referencing FK, or two FKs on one table, produce
   two UPDATE triggers with the same key), so which row won in the map depended on result order: every
   verify "found drift" and rebuilt the slot, which turned a 5x win into a +35% regression on one module
   (`definitions/store_test.exs`: 37 s before, 50 s with the buggy pool, 10 s fixed). Rule: when a digest
   or fingerprint keys rows into a map, assert key uniqueness against a real schema (`GROUP BY key HAVING
   count(*) > 1`) and aggregate duplicates deterministically; and always read the pool's own
   `phase=pool_acquire outcome=` log lines (`clean` / `reset` / `rebuilt`) after adopting a module, not
   only its wall time and pass count: a pool that rebuilds on every acquire still passes every test.

2. **Measure the reset before choosing it.** TRUNCATE of all 57 tables of a clone costs 0.9-1.0 s, slower
   than the 0.7-0.8 s clone it is meant to replace; the lever only pays with dirty-table detection (an
   `EXISTS` probe of every table is ~4 ms) and a TRUNCATE of just the dirty tables plus their FK-referencing
   closure (no CASCADE, so a missing edge raises instead of silently widening the set).

3. **A pooled id turns a straggler from harmless into harmful.** With a fresh tenant id per test, a
   fire-and-forget process that writes late hits a dropped schema. With a reused id it corrupts the next
   test. Adopt a module only after auditing every process it can start (awaited or stopped before the test
   returns), every reachable `lib/` fire-and-forget worker and every tenant-keyed in-memory state; keep the
   quiescence fences fail-closed (raise, never log-and-continue); and do not re-snapshot a row that a
   rebuild does not touch (re-snapshotting `public.tenants` after a rebuild would bless a corrupted row).
