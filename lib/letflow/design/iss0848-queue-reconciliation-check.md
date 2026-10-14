# ISS-0848 — queue/yaml reconciliation check (design)

> REMOVED at cutover 2026-10-14 (decision 0049): the task and its test were deleted; this design is kept as history.

Queue task 848 (`Q-848`), GH-1846, S11, BLOCKER. This design covers **AC2** only
(step 1/AC1 and AC4 are already done directly by ORCH — see the issue's own
`progress_2026_09_26:` note and `docs/anti-patterns.md`'s two ISS-0848 entries).
AC3 (a live run reporting no mismatches) is ELIXIR-DEV's job once the check
exists, not designed here.

## 0. Traceability

| AC | Covered by |
|---|---|
| AC2a — "the reconciliation check exists" | §2, §3: `Mix.Tasks.Letflow.CheckQueueReconciliation`, a standalone mix task (§1 explains why it is *not* wired into `mix letflow.check`). |
| AC2b — "a test proves it flags (i) a status mismatch ... using fixtures, not the live service" | §3.2 `reconcile/2`, a pure function of `(yaml_entries, issue_entries, queue_tasks)` — no I/O, no network, fixture-friendly by construction. §5 test plan. |
| AC2c — "... and (ii) a queue_ref to a non-existent task, using fixtures" | §3.2's `:dangling_queue_ref` finding kind, produced by the same pure function. §5 test plan. |
| AC3 (not this design's job, but the tool must support it) | §4 `run/1`'s human-readable report is what ELIXIR-DEV quotes as "output" when running it live post-step-1. |

## 1. Where it runs

**Decision: a new standalone mix task, `mix letflow.check_queue_reconciliation`,
is NOT added to the `letflow.check` alias in `mix.exs`.** It is run directly —
by ORCH at session start, or on demand — never as part of the CI/local gate
sequence.

### Reasoning

- Every existing `letflow.check_*` task is a pure, hermetic, no-network scan.
  `Mix.Tasks.Letflow.CheckRequirementsRegistration`'s own moduledoc states this
  as a discipline, not an incidental fact: *"It never writes to
  `docs/requirements.yaml`, never assigns or suggests an `impl_order` value,
  and makes no network call — in particular none to letflow-queue."* Adding a
  task to the `letflow.check` alias that reaches an external HTTP service over
  the network breaks that discipline for the whole alias: `mix letflow.check`
  is the project's only CI gate (no separate CI config exists — same
  moduledoc), and CI is not a host `docs/agents/protocols/TASK_QUEUE.md`
  guarantees carries `$QUEUE_AUTH_TOKEN` — the token is documented as *"a
  sanctioned local-dev convenience"* on specific workstations' `.env` files,
  explicitly not a thing every host has. An unconditional network dependency
  in the CI gate would make `mix letflow.check` flaky (or permanently red) on
  any host/CI runner without that token or without egress to
  `queue-test.ai-dala.com`.
- `docs/migration/decisions/0017-task-queue-selection-model.md`'s own
  Consequences section anticipates exactly this fork: *"`mix
  letflow.check_requirements_registration` and `mix
  letflow.check_deferral_staleness` ... *may* now verify against the live
  queue. Not required by this record, and deliberately not scoped here."* This
  design treats ISS-0848 as the follow-up that *does* scope it, but as an
  independent task rather than folding it into either existing one — neither
  of those tasks' own hermetic contract should be broken to add a network
  call, and this check's concerns (queue liveness, not requirements-file
  shape) are a different axis from either.
- The fix_direction text itself frames this as a real choice ("CODE-DESIGNER
  decides ... a mix task ORCH runs at session start, or inside mix
  letflow.check when QUEUE_AUTH_TOKEN is present"). Making it conditional
  *inside* the alias (skip the step silently when no token) was considered and
  rejected: a step that is sometimes present and sometimes absent from the
  same named gate, depending on an environment variable no other alias step
  depends on, is a harder thing for a future reader to reason about than a
  separate task with its own name and its own "run me when you have queue
  access" contract. A standalone task is also easier to invoke ad hoc — this
  is explicitly a "run before trusting `get_next_task`" tool (per the
  adjacent anti-patterns.md entry's closing line), not a per-commit gate.

### What the task does when the token is unavailable

Per `TASK_QUEUE.md`'s own "Before concluding the token is unavailable" section,
the task's token-resolution step (§4 `resolve_queue_auth_token/0`) checks, in
order:

1. `System.get_env("QUEUE_AUTH_TOKEN")`.
2. A `QUEUE_AUTH_TOKEN=` line in a `.env` file at the repo root (read directly
   off disk — this task must not assume `.env` has been loaded into the OS
   environment by anything else).

If neither yields a token, the task prints a clear, unambiguous
`SKIPPED — no $QUEUE_AUTH_TOKEN (checked shell env and ./.env)` line and exits
**0**, not 1 — an unreachable/uncredentialed queue is a known, expected state
on many hosts (this mirrors `TASK_QUEUE.md`'s own "genuine unreachable case"
framing), and this being a standalone task never wired into any gate makes a
soft-skip safe: nothing downstream silently treats "skipped" as "passed the
gate," because there is no gate here to begin with. It is not a hard failure,
in contrast to e.g. `check_toolchain`'s `bash`-not-found case, because a
missing dev-only credential is not itself evidence of a code defect the way a
missing toolchain binary is.

## 2. Module: `Mix.Tasks.Letflow.CheckQueueReconciliation`

`lib/mix/tasks/letflow.check_queue_reconciliation.ex` (new file). Follows the
established shape of the sibling `letflow.check_*` tasks: one `Mix.Task`
module, pure logic exposed as public functions (fixture-testable, no
`Mix.shell()`/network inside them), I/O and CLI/report concerns kept in
`run/1` and its immediate helpers.

### 2.1 Reused parsing (per instructions: don't reinvent)

- **Requirements-file parsing**: reuses
  `Mix.Tasks.Letflow.CheckRequirementsRegistration.scan/1` (already public,
  already returns `%{entries: [entry()], ...}` with `id`, `status`,
  `impl_order`, `state` per entry — exactly the `{id, status, impl_order}`
  triples this check needs for every `:registered` entry). This check does
  **not** re-parse `docs/requirements.yaml` itself; it calls that module's
  `scan/1` and filters to `state == :registered` entries (a `:deferred` or
  `:neither` entry has no `impl_order` to reconcile against, by construction —
  that absence is `check_requirements_registration`'s own concern, not this
  one's).
- **Issues-directory parsing**: `Mix.Tasks.Letflow.CheckIssueRefs` exposes
  `issue_files/1` (directory listing) and `audit/2` (ref-format lints) but
  **no function that returns `{id, status, queue_ref}` triples** — its `audit/2`
  returns violations only, not parsed field values, and its `capture/2`
  helper for reading a field's value is private. This check therefore adds
  its own small line-oriented extractor, `parse_issue_file/1` (§2.2), reusing
  `CheckIssueRefs`'s established *conventions* (column-0 `key: value` lines
  only, `strip_comment/1`-equivalent quote/comment stripping, `Q-<n>`
  well-formedness via the same `~r/^Q-[1-9]\d*$/` shape) rather than its code,
  since the actual return shape needed doesn't exist yet in that module.
  (Open question §6.1: whether `CheckIssueRefs` should later be extended with
  a public `parse/1` that both tasks share — not done here, to keep this
  design's diff scoped to ISS-0848.)

### 2.2 Types

```
@type yaml_status :: String.t()   # requirements.yaml's own status: vocabulary
                                    # (done | in_progress | pending | blocked | cancelled, unvalidated beyond being a string)
@type queue_status :: String.t()   # queue's own status: vocabulary (open | blocked | done), per decision 0017 §B
@type source_kind  :: :requirement | :issue

@type source_ref :: %{
  kind: source_kind(),
  id: String.t(),               # "REQ-405" | "ISS-0848"
  yaml_status: yaml_status(),
  queue_task_id: pos_integer()  # from impl_order: (requirement) or queue_ref: "Q-<n>" (issue)
}

@type queue_task :: %{
  id: pos_integer(),
  status: queue_status(),
  title: String.t()
}
# ^ the subset of decision 0017 §B's documented GET /tasks fields this check
#   actually needs (id, status). Extra fields (locked_by, depends_on,
#   blocked_by, eligible, ...) are accepted and ignored -- see §3.1.

@type finding ::
  %{kind: :status_mismatch, source: source_ref(), queue_status: queue_status(), reason: String.t()}
  | %{kind: :dangling_queue_ref, source: source_ref()}
  | %{kind: :unrecognized_yaml_status, source: source_ref(), reason: String.t()}
# ^ AMENDMENT (live-run gap, §3.3b): a yaml_status value this check has no
#   mapping for at all -- for EITHER source kind -- is its own finding kind,
#   never folded into :status_mismatch. See §3.3b for why this was added and
#   what it replaces.

@type report :: %{
  sources_checked: non_neg_integer(),
  queue_tasks_seen: non_neg_integer(),
  findings: [finding()]
}
```

`source_ref` deliberately carries both `kind` and `id` (never conflates a
requirement and an issue by numeric id alone) — a requirement's `impl_order`
and an issue's `queue_ref` both resolve to the same queue-task-id space, but
`REQ-405` and `ISS-0405` are unrelated records that happen to reference
different queue tasks; findings must always be traceable back to which yaml
file/entry produced them.

## 3. Pure core (fixture-testable, no I/O)

### 3.1 `parse_issue_file/1`

```
@spec parse_issue_file(content :: String.t(), path :: String.t()) ::
        source_ref() | :unregistered | {:error, String.t()}
```

Extracts `id:`, `status:`, `queue_ref:` (column-0 fields, same convention as
`CheckIssueRefs`). Returns:

- `{:error, reason}` if `id:` is missing/malformed, or `status:` is missing.
- `:unregistered` if `queue_ref:` is `null` (an issue never registered in the
  queue — not a finding, just out of scope for this check, same as
  `check_requirements_registration`'s `:deferred` state being out of scope for
  requirements. A `null` `queue_ref` is not itself a defect;
  `check_issue_refs` R4 already gates that it carries an explaining comment).
- Otherwise a `source_ref` with `kind: :issue`, `queue_task_id` parsed from
  `Q-<n>` (strip prefix, `String.to_integer/1`).

### 3.2 `reconcile/2` — the core comparison, and the whole reason this is
testable against fixtures

```
@spec reconcile(sources :: [source_ref()], queue_tasks :: [queue_task()]) :: report()
```

Pure. Takes already-parsed data on both sides — no file reads, no HTTP. This
is the function AC2's test targets directly, per the requirement that "the
check's core logic must be testable against FAKE/fixture queue data."

Algorithm, per `source_ref`:

1. Look up `queue_task_id` in `queue_tasks` (by `id`).
2. Not found → `{:dangling_queue_ref, source: source_ref}`. This is
   `check_queue_reconciliation`'s reading of the fix_direction's "must also
   flag a queue_ref whose task does not exist" clause, generalized to both
   requirements (`impl_order`) and issues (`queue_ref`) — ISS-0848's own
   description shows both directions of drift (issues with fabricated
   `queue_ref`s *and* requirements whose `impl_order` task silently vanished
   would be equally invisible otherwise), so this finding kind is not
   issue-only despite the fix_direction wording naming only `queue_ref`.
3. Found → compare `yaml_status` against the found task's `status`. **AMENDMENT
   (§3.3b):** the mapping consulted now depends on `source.kind` -- a
   `:requirement` source uses §3.3's table, an `:issue` source uses §3.3b's
   table. This was originally a single kind-blind `status_compatible?/2`
   (§3.3); that was the live-run defect this amendment fixes (see §3.3b's
   opening for the full account). Three outcomes, not two:
   - No mapping recognizes `yaml_status` at all (for the source's kind) →
     `{:unrecognized_yaml_status, source: ..., reason: ...}` naming the
     unrecognized value and the source's kind.
   - A mapping exists but does not list the found task's `status` →
     `{:status_mismatch, source: ..., queue_status: ..., reason: ...}` with a
     human-readable `reason` string naming which mapping rule was violated
     (e.g. `"yaml status \"done\" maps to queue {done, blocked}; queue task
     796 reports \"open\""`).
   - A mapping exists and lists the found task's `status` → compatible, no
     finding.
4. Compatible → no finding for that source.

`report.findings` is the concatenation across all sources; `sources_checked`
and `queue_tasks_seen` are plain counts, printed unconditionally by `run/1`
even on a clean pass (same "always printed, never silent" discipline as
`check_requirements_registration`'s totality line).

### 3.3 `status_compatible?/2` — the mapping table

```
@spec status_compatible?(yaml_status :: yaml_status(), queue_status :: queue_status()) :: boolean()
```

| yaml `status:` | compatible queue `status:` values | rationale |
|---|---|---|
| `done` | `done`, `blocked` | **ISS-0836/REQ-406/REQ-407 precedent**: a requirement's yaml status was flipped to `done` before its actual completion was validated; the queue side was corrected to `blocked` (not re-opened to `open`) specifically to record "this is disputed, not simply unfinished," while the yaml itself still reads `done` pending a separate correction. A strict `done ⟺ done`-only mapping would make this check fail permanently on exactly the two records ISS-0848's own resolution intentionally left in this state, which is not a defect to keep re-reporting — it is the documented outcome. `open` is NOT compatible with yaml `done`: that is the undetected-drift shape ISS-0848 was filed over in the first place (14 tasks silently left `open` while yaml already said `done`), and must keep failing loudly. |
| `in_progress` | `open`, `blocked` | Work claimed/in flight is legitimately `open` (unclaimed-but-not-yet-picked-up is a narrower case this check doesn't distinguish — see §6.2) or `blocked` (blocked on a dependency, or blocked pending review per the ISS-0836 pattern generalized to non-done states). `done` is NOT compatible: a requirement the queue already considers finished but the yaml still calls "in progress" is worth surfacing (either the yaml is stale, or the release was premature). |
| `pending` | `open` | The queue's own "not yet started, not blocked" state. `done`/`blocked` both indicate real queue-side activity a `pending` yaml entry doesn't yet reflect — worth surfacing. |
| `blocked` | `blocked`, `open` | A yaml-side `blocked` (dependency unmet, or a human/process block) is compatible with a queue `blocked` (the direct match) and also with `open` — decision 0017 §B's own `blocked_by` field means a dependency-blocked task can still show queue `status: open` with a non-empty `blocked_by`, since `status` and eligibility are tracked separately in the queue's model; this check does not fetch/compare `blocked_by` (§6.3), so it treats yaml `blocked` loosely rather than risk a false mismatch it cannot actually resolve without that extra field. `done` is NOT compatible: a genuinely-completed queue task under a yaml entry still marked `blocked` is stale in the yaml, worth surfacing. |
| `cancelled` | `open`, `blocked`, `done` | Cancelled work has no reliable queue-side counterpart in this project's current registration flow (queue tasks are never registered as "cancelled" — `letflow-queue`'s status vocabulary per decision 0017 §B is `open`/`blocked`/`done` only). Any queue status is accepted for a cancelled yaml entry rather than inventing a rule this check can't actually verify; effectively a no-op comparison, documented as such rather than silently matching by accident. Flagged as an open question (§6.4) rather than resolved further, since ORCH/REVIEWER may want a stricter rule once cancelled-with-a-real-queue-task becomes a real, observed case. |

Every mapping direction not listed above (i.e. anything not explicitly
compatible) is a `:status_mismatch`. **AMENDMENT (see §3.3b for the full
account): this table, and the "unrecognized" handling described in this
paragraph, apply to `:requirement` sources only.** The table is total over
the five yaml statuses observed in `docs/requirements.yaml` today (`done`,
`in_progress`, `pending`, `blocked`, `cancelled`); a requirement `yaml_status`
value this table doesn't recognize is now a `:unrecognized_yaml_status`
finding (§2.2, §3.2) rather than a `:status_mismatch` — this is a
reclassification of the *finding kind* used for that fallthrough case, made
uniform with §3.3b's issue-side handling below; it is not a change to this
table's rows, which are unchanged from the original design and its two prior
CODE-DESIGN-VALIDATOR passes. Never silently passed either way — same "no
everything-else-is-fine branch" discipline `check_requirements_registration`'s
moduledoc calls out for its own classifier.

## 3.3b. Issue-status compatibility mapping — AMENDMENT (live-run gap)

**The gap this closes.** §3.3's table was built and twice validated against
only `docs/requirements.yaml`'s status vocabulary. `reconcile/2` (§3.2) never
branched on `source.kind` before comparing — every source, `:requirement` and
`:issue` alike, was run through the same kind-blind `compatible_queue_statuses/1`
lookup. Running the implemented check (`lib/mix/tasks/letflow.check_queue_reconciliation.ex`,
commit `2b3d51ea`) against the live queue produced roughly 40 `:status_mismatch`
findings, every one of them for an `:issue` source, because §3.3's table has
no key for `resolved`, `open` (as an *issue* value — it happens to share a
spelling with nothing in §3.3, but `open` alone was never the actual reported
false-positive path; see below), `instrumented`, or `no_defect` — every real
issue-status value fell through to `compatible_queue_statuses(_unrecognized)
-> nil`, which §3.2's original algorithm turned into a `:status_mismatch`
with `queue_status: "n/a"`, not a distinguishable "nobody taught this check
about this value" finding. That conflated two very different situations
(a known status legitimately disagreeing with the queue, vs. a status this
check has simply never heard of) under one finding kind, and made every
issue-backed source in the corpus report as a false positive.

**The real on-disk vocabulary** (`grep -h '^status:' docs/issues/*.yaml | sort
| uniq -c`, run fresh during this amendment — not trusted from
`ISSUE_QUEUE.md`'s prose alone, per instruction):

| yaml `status:` value | count | documented in `ISSUE_QUEUE.md`'s canonical list (~line 248)? |
|---|---|---|
| `resolved` | 406 | yes |
| `open` | 37 | yes |
| `no_defect` | 8 | yes |
| `instrumented` | 8 | yes |
| `reopened` | 2 | **no** |
| `in_progress` | 2 | yes |
| `fixed` | 2 | **no** |
| `declined` | 2 | **no** |
| `closed_not_applicable` | 2 | **no** |
| `resolved_via_duplicate` | 1 | **no** |
| `resolved_not_applicable` | 1 | **no** |
| `duplicate` | 1 | **no** |
| `done` | 1 | **no** (this is a requirements-vocabulary spelling that leaked into one issue file — not itself part of either canonical list) |

`ISSUE_QUEUE.md`'s own canonical list (the section literally titled "Issue
status vocabulary," ~line 248) documents exactly five values: `open`,
`in_progress`, `resolved`, `instrumented`, `no_defect`. The other eight
values above appear on disk but nowhere in that list or anywhere else in
`docs/agents/protocols/*.md` searched for this amendment (`reopened`,
`fixed`, `declined`, `closed_not_applicable`, `resolved_via_duplicate`,
`resolved_not_applicable`, `duplicate`, `done`) — they are undocumented,
almost certainly pre-standardization/legacy spellings (12 records total,
~2.5% of the corpus) that predate `ISSUE_QUEUE.md`'s current vocabulary
section. This design does **not** attempt to map them, for the same reason
§3.3's `cancelled` row was left as an explicit no-op rather than a guessed
rule: inventing compatibility for a value nobody has defined the meaning of
would risk silently passing (or silently failing) records this check cannot
actually reason about. They are exactly the case the new `:unrecognized_yaml_status`
finding kind exists for (see below) — surfaced, not guessed at.

**The mapping table**, keyed on the five documented values plus an explicit
row for every undocumented value actually found on disk:

| yaml `status:` value (issue) | compatible queue `status:` values | rationale |
|---|---|---|
| `open` | `open` | Mirrors §3.3's `done`/`open` asymmetry in spirit but is *not* the same rule: an issue still marked `open` in yaml whose queue task reports `done` is exactly the undetected-drift shape ISS-0848 exists to catch (a run resolved the queue task and forgot to update the yaml, or vice-versa) — it must keep failing loudly, the same as `pending` does not tolerate `done` in §3.3. `blocked` is also NOT compatible: an `open` issue has not yet had any run touch it, per `ISSUE_QUEUE.md`'s own definition ("filed, not yet being worked"), so a queue-side `blocked` implies something happened this yaml has no record of. |
| `in_progress` | `open`, `blocked` | Same reasoning §3.3 already applies to the requirement table's `in_progress` row: a run has locked the issue and is actively working it, which reads as queue `open` (claimed, in flight) or `blocked` (blocked on a dependency mid-work). `done` is NOT compatible — a queue task already marked done while the issue yaml still says a run is actively working it is worth surfacing, not waving through. |
| `resolved` | `done`, `blocked` | Same ISS-0836/REQ-406/REQ-407-style precedent §3.3 already established for the requirement table's `done` row, applied to the issue vocabulary's own terminal-success value: `ISSUE_QUEUE.md`'s "Picking up a queued issue later" section documents the normal path as `status: resolved` in yaml paired with `release_lock(status: "done")` on the queue — the expected 1:1 case. `blocked` is also accepted for the same disputed-outcome reason §3.3's `done` row accepts it (a resolution later contested/re-opened for review without the yaml being touched yet). `open` is NOT compatible: a `resolved` issue whose queue task still reads `open` is undetected drift (the queue side was never released), the exact shape this check exists to catch. |
| `instrumented` | `blocked` | **Deliberately excludes `done`.** `ISSUE_QUEUE.md`'s own `instrumented` definition is explicit and non-negotiable: "Release the queue task with `release_lock(status: \"blocked\")`, not `\"done\"` and not no-status." An `instrumented` yaml status paired with a `done` queue status is not a compatibility gap this check should paper over — it is itself a real, catchable defect: someone released (or a prior bug released) the queue task as `done` on a run that `ISSUE_QUEUE.md` explicitly says must never be marked done, since the underlying root cause was never removed. That must surface as `:status_mismatch`, not pass silently. `open` is also not compatible — an `instrumented` record is terminal (a completed run produced it), so an `open` queue task under it is stale on the queue side. |
| `no_defect` | `blocked` | Identical reasoning to `instrumented` immediately above, and for the same textual reason: `ISSUE_QUEUE.md` states the identical rule for `no_defect` verbatim ("Release the queue task with `release_lock(status: \"blocked\")`, not `\"done\"` and not no-status"). `done` is deliberately excluded for the same reason — a `no_defect` verdict paired with a `done` queue release would misrepresent a "nothing was there to fix" outcome as a completed fix, which is precisely the false signal `ISSUE_QUEUE.md`'s `no_defect` section spends several paragraphs warning against. `open` is not compatible for the same terminal-record reasoning as `instrumented`. |
| `fixed`, `duplicate` | *(none — always `:unrecognized_yaml_status`)* | Not in `ISSUE_QUEUE.md`'s canonical vocabulary and not confirmed against any live record as of the ISS-0870 amendment below (neither appears on any current file). Rather than guess a mapping for a value nobody has actually used yet, these still produce `:unrecognized_yaml_status` unconditionally. |

**AMENDMENT (ISS-0870, 2026-09-27): six of the eight originally-unmapped values above are now recognized**, after case-by-case review confirmed each is a real, deliberate terminal disposition in live use (not a typo), and `docs/agents/protocols/ISSUE_QUEUE.md`'s "Issue status vocabulary" section was updated to define them canonically (this table now mirrors that definition rather than diverging from it):

| yaml `status:` value (issue) | compatible queue `status:` values | rationale |
|---|---|---|
| `done` | `done`, `blocked` | A requirements-vocabulary spelling of `resolved` that has since spread to several issue files (ISS-0836, ISS-0838..0844, ISS-0849..0851) rather than staying a single leaked one-off — same terminal-success bar as `resolved`, same acceptance of `blocked` for a disputed-outcome re-review, same rejection of `open` as undetected drift. |
| `resolved_via_duplicate` | `done`, `blocked` | The defect really was removed, just under a different issue's run — the record MUST carry `superseded_by:` naming that run's issue. Queue-release-wise this is indistinguishable from `resolved`: the underlying problem is gone, so `open` is still undetected drift. |
| `closed_not_applicable`, `resolved_not_applicable`, `declined` | `done`, `blocked` | Terminal-but-not-a-fix outcomes (out of scope, superseded direction, or explicitly rejected) — accepted at either `done` (fully settled) or `blocked` (shelved, same asymmetry §3.3's `done` row already tolerates for requirements) depending on the record's own text; `open` is not compatible, since all three assert the run reached a real terminal verdict. |
| `reopened` | `open` | The mirror of `open`, not of `resolved` — an issue explicitly un-terminaled after a prior resolution didn't hold. `done`/`blocked` are NOT compatible: a `reopened` record asserts the defect is back, so a queue task still reporting `done` is exactly the drift this check exists to catch (confirmed live during ISS-0870 against ISS-0287 and ISS-0340 — both genuinely still-broken, their queue tasks incorrectly `done`). |

**Why an unrecognized value is its own finding kind, not folded into
`:status_mismatch` and not silently passed.** The original algorithm's only
fallthrough (`compatible_queue_statuses(_unrecognized) -> nil`, folded into
`:status_mismatch` with `queue_status: "n/a"`) is exactly what produced the
~40 false positives this amendment fixes: every real issue-status value fell
through that same branch and was reported as if it disagreed with a *known*
mapping, when in fact no mapping existed to disagree with. `:unrecognized_yaml_status`
(§2.2) is deliberately a **different** finding kind so a human/agent triaging
the report can immediately tell "this source's status disagrees with the
queue" (`:status_mismatch,` actionable by fixing the drift) apart from "this
check doesn't know what this status value means yet" (`:unrecognized_yaml_status`,
actionable by extending this table — or by tracking down and fixing/retiring
the stray legacy value at the source). Neither is treated as a pass; an
unrecognized status is not evidence of "no problem," it is evidence of
"this check cannot currently form an opinion," which must never be silent.

**Dispatch.** §3.2's `reconcile/2` picks the table by `source.kind`:
`:requirement` sources consult §3.3's table (unchanged), `:issue` sources
consult this section's table. A `source.kind` value other than these two
cannot occur by construction (`@type source_kind :: :requirement | :issue`,
§2.2) and is not a case this design provides for.

**Open question (added by this amendment):** should the eight undocumented
legacy values found on disk (12 records total) be normalized to the five
documented values as a one-time data-cleanup pass (e.g. `fixed`/`duplicate`
→ `resolved`-with-a-`superseded_by`-style note, `declined`/`closed_not_applicable`
→ something closer to `no_defect`), or left as-is with this check permanently
reporting them as `:unrecognized_yaml_status`? Not resolved here — flagging so
ELIXIR-DEV/ORCH don't assume either direction was silently decided. Until
resolved, every run of this check will keep reporting exactly these 12
records, which is expected and not itself a new defect to chase.

## 4. I/O wrapper: `run/1`

```
@impl Mix.Task
@spec run([String.t()]) :: :ok
```

1. `resolve_queue_auth_token/0` (§1) — on `:none`, print the SKIPPED line and
   return `:ok` (exit 0).
2. On a token: read `docs/requirements.yaml` via
   `CheckRequirementsRegistration.scan/1`, filter to `:registered` entries,
   map each to a `source_ref` (`kind: :requirement`).
3. Read every `docs/issues/*.yaml` file (reusing
   `CheckIssueRefs.issue_files/1` for the directory listing), run
   `parse_issue_file/1` on each, keep only the real `source_ref`s (drop
   `:unregistered` silently — expected state, not a finding; hard-fail
   immediately on any `{:error, reason}`, printing which file and why, same
   as the sibling tasks' R6-style "can't even read the input" failure mode).
4. `fetch_queue_tasks/1` (the only network call in this module): `GET
   https://queue-test.ai-dala.com/tasks` via `:httpc` (mirrors
   `Letflow.Webhooks.do_dispatch_http/3`'s own use of `:httpc` — no new HTTP
   client dependency), `Authorization: Bearer <token>` header, decode with
   `Jason.decode!/1` (already a project dependency), reading the task list
   from the **`"tasks"`** key — per REQ-222's own acceptance criterion
   (`docs/requirements.yaml`: "GET /tasks with a valid bearer token returns
   200 and a JSON body with a `\"tasks\"` key whose value is a list covering
   every task in the database"), and independently confirmed empirically:
   ORCH's own live `GET /tasks` call earlier in this same session parsed the
   response as `%{"tasks" => [...]}`, not `%{"data" => [...]}`. **This is a
   DIFFERENT envelope shape from `register_task`'s POST response**
   (`{"error": ..., "data": {...}}`, a single created-task object) — do not
   assume the two endpoints share a shape; `docs/anti-patterns.md`'s
   "Retrying a `register_task` POST after misreading its success response"
   entry is about that other, `data`-keyed endpoint and does not apply here
   directly, though the general lesson (read the actual documented/observed
   key, don't assume) is the same one this correction re-applies. A non-2xx
   response, a JSON-decode failure, or a response missing the `"tasks"` key
   entirely is a hard `Mix.raise` (network/service failure or an unexpected
   response shape is not a clean "no mismatches" pass).
5. `reconcile/2` on the combined `sources` and the fetched `queue_tasks`.
6. Print the report (counts + full finding list, same "always printed"
   discipline as the sibling checks) and exit `0` iff `findings == []`,
   `Mix.raise/1` otherwise, naming every finding (kind, source id, queue task
   id, reason) so the raised message alone is enough to act on without
   re-running.

### 4.1 `resolve_queue_auth_token/0`

```
@spec resolve_queue_auth_token() :: {:ok, String.t()} | :none
```

Checks `System.get_env("QUEUE_AUTH_TOKEN")` first, then a `QUEUE_AUTH_TOKEN=`
line in `./.env` (plain line-oriented read, matching this project's existing
"no YAML/dotenv dependency for a lint-adjacent tool" discipline — see
`check_requirements_registration`'s own "Parsing model" section reasoning
applied here to `.env` instead of YAML).

## 5. Test design pointers (for TEST-DESIGNER, not written here)

AC2's own wording ("using fixtures, not the live service") is satisfied
entirely through `reconcile/2` (§3.2), which never touches the network or the
filesystem:

- **Fixture (i) — status mismatch**: a `source_ref` with `kind: :requirement,
  yaml_status: "done", queue_task_id: 999` against a `queue_tasks` fixture
  list containing `%{id: 999, status: "open", ...}` (mirrors the ISS-0848
  finding shape verbatim: yaml says done, queue says open). Assert
  `reconcile/2`'s result contains exactly one `:status_mismatch` finding for
  that source. A companion fixture using `status: "blocked"` instead of
  `"open"` for the same `yaml_status: "done"` source must assert **zero**
  findings — this is the ISS-0836/REQ-406/REQ-407 precedent case, and a test
  suite that only exercises the mismatch direction would not actually prove
  the mapping table's most load-bearing exception is implemented correctly.
- **Fixture (ii) — dangling queue_ref**: a `source_ref` with `queue_task_id:
  99999` against a `queue_tasks` fixture list that does not contain id
  `99999`. Assert exactly one `:dangling_queue_ref` finding.
- Both fixtures constructed as plain `source_ref()`/`queue_task()` maps
  in-test — no `docs/issues/` or `docs/requirements.yaml` fixture files needed
  for these two cases, since `reconcile/2`'s inputs are already the parsed
  shape.
- Separately (still fixture-based, not live-service): `parse_issue_file/1`
  against small in-memory YAML-ish strings, mirroring
  `CheckAsyncSandboxReachability.async_true_file?/1`'s own "pass a synthetic
  string, not a file" pattern — covering a well-formed `queue_ref: "Q-N"`
  line, a `queue_ref: null` line (→ `:unregistered`), and a missing/malformed
  `id:` line (→ `{:error, _}`).
- **Fixture (iii) — AMENDMENT, issue-kind mapping (§3.3b)**: a `source_ref`
  with `kind: :issue, yaml_status: "resolved", queue_task_id: 500` against
  `%{id: 500, status: "open", ...}` must assert exactly one `:status_mismatch`
  (the resolved/open drift case §3.3b's `resolved` row calls out); the same
  source against `%{id: 500, status: "done", ...}` must assert **zero**
  findings. A third fixture with `kind: :issue, yaml_status: "instrumented",
  queue_task_id: 501` against `%{id: 501, status: "done", ...}` must assert
  exactly one `:status_mismatch` — this is the `instrumented`/`no_defect`
  "must never be released as done" rule (§3.3b) and is the row most likely to
  be silently broken by a future edit, so it needs its own explicit,
  never-passing-by-accident test.
- **Fixture (iv) — AMENDMENT, unrecognized yaml status (§3.3b)**: a
  `source_ref` with `kind: :issue, yaml_status: "declined", queue_task_id:
  502` against any `queue_tasks` fixture containing id `502` (any status)
  must assert exactly one `:unrecognized_yaml_status` finding, and must NOT
  produce a `:status_mismatch` — this is the direct regression test for the
  live-run bug this amendment fixes (all ~40 false positives were exactly
  this shape, just misclassified). A companion fixture with `kind:
  :requirement, yaml_status: "not_a_real_status", queue_task_id: 503`
  against any fixture containing id `503` must also assert exactly one
  `:unrecognized_yaml_status` — proving the requirement side's fallthrough
  was reclassified too (§3.3's closing paragraph), not just the issue side.
- `fetch_queue_tasks/1` and `resolve_queue_auth_token/0` (the two I/O-touching
  functions) are deliberately **not** unit-tested against the live service
  from `mix test` — consistent with this project's established
  discipline against network calls inside the test suite. If TEST-DESIGNER
  wants coverage of the JSON-envelope-unwrapping logic specifically, it
  should be factored as its own pure function (e.g. `decode_tasks_response/1`
  taking a raw JSON string) so it can be fixture-tested the same way — flagged
  here as a recommendation, not mandated, since AC2 only requires the two
  named scenarios.

## 6. Open questions (deliberately not resolved here)

1. **`CheckIssueRefs` reuse gap** (§2.1): should it later grow a shared
   `parse/1` returning structured fields, so this check and any future one
   don't each hand-roll a column-0 extractor? Not done here to keep this
   change scoped to ISS-0848; flagging so ELIXIR-DEV doesn't assume it was
   considered and rejected.
2. **`in_progress` vs. `open`-but-unclaimed**: this check's mapping table
   (§3.3) does not distinguish a queue task that is `open` and genuinely
   unclaimed from one that's `open` but a stale lock was force-cleared — both
   read as plain `status: "open"` from `GET /tasks` per decision 0017 §B's
   field list (which separately exposes `locked_by`/`locked_at`, not folded
   into `status`). This check does not fetch or reason about `locked_by`; a
   task locked by a long-dead session still reads as a clean `open`/`done`
   compatibility match. Left as a real gap, not a silent assumption.
3. **`blocked_by` not fetched**: §3.3's `blocked` row's looseness (accepting
   `open` for yaml `blocked`) is a direct consequence of not reading
   `blocked_by`. A future revision could fetch it and require it be
   non-empty for `open` to count as compatible with yaml `blocked` —
   tightening the rule — but that's out of scope for this pass.
4. **`cancelled` mapping is a no-op** (§3.3's last row): revisit if a
   genuinely cancelled requirement/issue is ever found still holding a live,
   non-`done` queue task — this design has no case to learn from yet.
5. **Filtering `GET /tasks` server-side**: decision 0017 §B says the endpoint
   is "filterable by `status`, `task_type`, `stage`, `eligible`." This design
   fetches the full unfiltered list once per run (simpler, and the corpus is
   currently ~850 tasks — cheap for a single GET) rather than filtering
   server-side or paginating; revisit if task volume makes an unfiltered pull
   noticeably slow.
6. **Legacy/undocumented issue-status values** (§3.3b, added by this
   amendment): whether the 8 undocumented values found on disk (`reopened`,
   `fixed`, `declined`, `closed_not_applicable`, `resolved_via_duplicate`,
   `resolved_not_applicable`, `duplicate`, and a stray `done`; 12 records
   total) should be normalized to `ISSUE_QUEUE.md`'s five documented values,
   or left to permanently report as `:unrecognized_yaml_status`. Not decided
   here — see §3.3b's own open-question paragraph for the full framing.
