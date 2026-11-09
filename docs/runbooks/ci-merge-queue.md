# Runbook: CI path filter and merge queue

What to do when `main` is red, when the merge queue ejects a group, or when a PR cannot be
merged. Companion to `docs/merge-queue.md` (the queue's setup and the selective-test scheme).
Cites symbols and step names, not line numbers.

## 1. Which gates run: `scripts/ci_changed_paths.sh`

Job `changes` in `.github/workflows/ci.yml` (step "Compute changed paths") pipes the changed-file
list into `scripts/ci_changed_paths.sh`. It prints three lines: `backend=`, `frontend=`, `mobile=`
(`true|false`). Each is one regex over the list:

| Gate | Regex | Runs when a change touches |
|---|---|---|
| backend | `BACKEND_PATHS_RE` | `lib/`, `priv/`, `test/`, `config/`, `mix.*`, `scripts/*.sh`, `deploy/`, `.github/workflows/`, `docs/requirements.yaml`, `docs/roles.md`, `docs/runbooks/` and the other docs the suite reads by name |
| frontend | `FRONTEND_PATHS_RE` | `web/`, `priv/labels/`, `ci.yml`, the script itself, and the two **kinds files** (below) |
| mobile | `MOBILE_PATHS_RE` | `apps/mobile/`, `ci.yml`, the script itself |

**The kinds-files rule (T-1509).** `lib/letflow/modules/assets/documents/kinds.ex` and
`lib/letflow/modules/stock/documents/kinds.ex` (their `header_keys`) are mirrored by the web
`DOC_KINDS` (test `documentsModel M1`). A backend-only change to them used to skip the frontend
gate and turn `main` red twice (#4024, T-1508). Both files are now in `FRONTEND_PATHS_RE`, so such
a change runs the frontend gate. Add another mirrored backend file the same way: put it in the
frontend regex, keep the rule one single-quoted line.

Rules to remember:

- Anything the backend gate reads **by name** must match `BACKEND_PATHS_RE`, or a change confined
  to that path merges without the gate. The guard test `test/letflow/ci_backend_path_filter_test.exs`
  checks this; a new fixture or doc the suite reads counts too.
- Editing the script or `ci.yml` runs every gate.
- Fail-safe: if the diff, the script, or its output fails, the step exits non-zero and CI runs
  every gate. A push to `main`, the nightly and `workflow_dispatch` never say `false`.
- Docs-only changes: `scripts/ci_docs_only.sh` decides; shard 1 runs the docs tests, shards 2-6 skip.
- The required checks (`Backend gate (mix letflow.check)`, `Frontend gate (npm run check)`) are
  always reported; a gate that is not needed reports success without work.

## 2. Main is red

A failing backend run on `main` (push, nightly, dispatch) makes job `full_run_marker` write the
tag **`ci-main-red`** on that commit. While the tag exists, step "Main red guard (merge queue)"
fails every merge-group run fast with "main full CI red (since <sha>)". Pull-request runs are not
blocked, so authors can keep working; only landing stops.

Steps:

1. Read the failure: `gh run list --branch main --workflow CI --limit 5`, then the failing job's
   log (`gh run view <id> --log-failed`; add `--allow-escape-sequences` if the API refuses ANSI).
   `git rev-parse refs/tags/ci-main-red` (after `git fetch --tags`) is the first red commit.
2. Classify it: your change broke it (fix forward), a path-filter gap (section 1), or a flaky test
   (section 4). Do not just re-run.
3. Land the fix through the queue with the **`[main-fix]` title rule**: the queue entry's commit
   subject must start with `fix` followed by `(`, `:` or `!` (for example `fix(GH #N): ...`), or
   contain `[main-fix]` anywhere (case-insensitive). The guard then sets `force_full`: that group
   runs the **full** backend suite (not the selective one) and is allowed to land. A subject like
   `Fix the ...` without the bracket form does not match (`fix` must be followed by `(`, `:`, `!`
   or end of line); add `[main-fix]` when unsure.
4. When the fix is merged and its push run on `main` is green, `full_run_marker` deletes
   `ci-main-red` (it is an ancestor of the new HEAD). A failed or timed-out run counts as red; a
   cancelled one does not.
5. Operator escape (only if the tag is stale, for example the red commit was reverted and the run
   was cancelled): `git push origin :refs/tags/ci-main-red`. Say why in the PR or report.

Do not queue unrelated work as `[main-fix]` to jump the guard: a fix group runs the whole suite
and delays everyone.

## 3. The queue ejects a group, or a PR is unmergeable

The queue builds a temporary branch `gh-readonly-queue/main/pr-<n>-<sha>` (the PR merged on top of
the groups ahead of it) and runs the required checks on it. A red group is ejected and the PRs
behind it are rebuilt without it.

Reading a failed merge-group run:

1. Find it: `gh run list --event merge_group --limit 10`, or the PR's checks link. The run's head
   branch is the `gh-readonly-queue/...` name.
2. Job `changes` first. Its step summary says the mode (`Backend tests: selective|full`), the
   docs-only decision, and whether the Main red guard fired. A "main full CI red" error means you
   are blocked by section 2, not by your change.
3. Then the red leg: `backend_static`, one of the 8 `backend_shard` jobs, or the frontend gate.
   List the failures: grep the shard log for `^  [0-9]+) test` and `Result:`. CI logs of the
   gate job do not name the failing test by themselves.
4. Compare with the PR run. Passes on the PR but fails in the group means one of: a combination
   with a PR ahead of you (two modules break each other, the "accepted risk" in
   `docs/merge-queue.md`), a path-filter gap (the PR run skipped a gate the group ran), a
   time-of-day or load-dependent test (section 4), or a pin that a sibling change moved
   (counts, migration version, permission golden). Merge `origin/main`, re-take the pins, push.
5. A shard cancelled at its time limit with no failed test is not a content fault; re-run it once.
6. A Hex timeout in `mix deps.get` is infrastructure; re-run.

Unmergeable PR checklist: merge conflict (merge `origin/main`; for registries keep both sides'
entries), PR body fails `scripts/check_pr_gates.sh` (the `## Gates` block), a required check missing
(a path rule skipped it wrongly, or a job was renamed: the job `name:` strings are required-check
contexts, see decision 0018), or the ruleset `main-queue` itself is broken (admin only, see
`docs/merge-queue.md` "Emergency"). Re-enqueue after fixing; do not bypass the queue.

## 4. Flaky tests

A test is flaky only after you have read the failure and tied it to untouched code. One failure of
several is often yours. An ejected group is not proof of a flake.

Two worked examples from 2026-11-08:

- **Time-of-day (T-1505, #4046):** `test/letflow/ledger/as_of_date_test.exs` failed for every PR
  between **15:00Z and 23:00Z**. The cause was a date taken in Tokyo (+09:00) used against a
  tenant defaulting to Asia/Almaty (+05:00); from 15:00Z to 19:00Z the Tokyo date is ahead, so the
  product correctly answered `as_of_date_in_future`. Fixed by computing each date in the zone
  under test. The wait for the window to pass is gone. Lesson: a failure that appears at the
  same hour every day is the clock; do not wait it out, and note that a repro attempt outside the
  window passes (the first attempt at 19:04Z did).
- **Timing (T-1507, #4048):** `CompleteTaskFormHookCrashTest` (F4-08a/b/c, backend shard 7/8)
  ejected merge-group runs. The spin script had a 50 ms timeout while a separate process polled
  for the worker and killed it; on a loaded runner the killer lost the race. Fixed by a longer
  killer deadline and an explicit `timeout_ms`. It could not be reproduced on a quiet host, so
  the fix is by reading the code; say so in the PR instead of claiming a red proof.

Handling:

1. Quote the failing test name and the sibling tests' durations from the same log. Do not name
   "load" as the cause without them, and do not raise a timeout as the fix without evidence of
   load rather than a hang.
2. Prefer making the test deterministic (inject the clock, wait on a condition with a bounded
   poll, no sleeps) over retries. Never skip or delete the test.
3. A repeat of the same failure is a defect, not noise: fix it before the next unrelated merge.
4. If the flake keeps `main` red, follow section 2 and land the fix with `[main-fix]`.
5. Cluster-wide guards on the team's shared Postgres (`pg_stat_activity` reaper tests,
   `admin_shutdown`) can fail from sibling tasks; that is not CI's flake, say so in findings.

## 5. Quick reference

| Symptom | Look at | Do |
|---|---|---|
| Merge-group run fails in 1 minute with "main full CI red" | tag `ci-main-red`, section 2 | land a `[main-fix]` / `fix(...)` entry |
| Frontend gate skipped, `main` red on a web test | `FRONTEND_PATHS_RE` | add the mirrored backend file to the regex |
| Group red, PR was green | shard log, `Result:` lines | section 3 step 4 |
| Fails only at certain hours | test uses wall clock / zones | section 4, T-1505 |
| Shard timed out, no failed test | job status | re-run once |
| Tag stale after revert | `git push origin :refs/tags/ci-main-red` | report why |
