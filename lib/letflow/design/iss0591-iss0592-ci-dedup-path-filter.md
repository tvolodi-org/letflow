# Design: ISS-0591 (duplicate CI runs) + ISS-0592 (no path filter) — `.github/workflows/ci.yml`

Status: design, not yet implemented. Target file: `.github/workflows/ci.yml`.
Branch: `fix/ISS0592-20260911`.

> **Addendum 2026-10-21, GH #2412 (supersedes the job-level-`if:` rule below).** Everything
> in this document that forbids a job-level path-filter `if:` on a required context
> (§0/§3 "step-level, never job-level", "this rule is unchanged and still holds", the
> REVIEWER check "(b) is never skipped via job-level `if:`") is **superseded for job-level
> `if:`** and kept below as history. `frontend` (required context "Frontend gate (npm run
> check)") and `mobile` now use `if: ${{ !cancelled() && needs.changes.outputs.<x> != 'false' }}`
> at job level, so a docs-only PR starts no runner for them. GitHub documents: "If a job in a
> workflow is skipped due to a conditional, it will report its status as "Success"", so the
> check name is still reported and satisfied. This is unlike a `paths:`-filtered workflow,
> whose checks never report; the ban on `paths:`/`paths-ignore:` in `on:` still holds. The
> fail-open rule is kept (an empty output from a failed `changes` job is `!= 'false'`, so
> the jobs run) and the `backend` aggregator does not depend on either job. **Open risk:**
> that the merge queue / `main-queue` ruleset accepts a skipped "Frontend gate" has not been
> verified. A docs-only PR after merge must show it; if the queue does not accept it, revert
> only the `frontend` job's `if:`. REVIEWER check (b) now applies to `backend` only.

## 0. Scope and risk framing (read this first)

This is infrastructure-as-config, not `lib/letflow/` or `web/` code, so per
`.claude/agents/code-designer.md` this design shows literal proposed YAML — the YAML
*is* the design here, the way a migration's SQL is shown directly in an Elixir design.
It still explains reasoning throughout; it is not a bare diff dump.

**SECURITY-REVIEWER scope**: explicitly out of scope. This change touches no tenant-data
path (no API route, no migration, no secret, no response shaping) — it is CI trigger and
job-conditional logic only. State this in the handoff so WF-03 does not stall waiting for
a security review that does not apply.

**REVIEWER scope**: unusually high-stakes here despite being "just YAML." The one
property that must never regress is stated in both issues and in
`docs/migration/decisions/0018-branch-protection-posture.md`: `main`'s branch protection
requires two exact status-check contexts —

```
Backend gate (mix letflow.check)
Frontend gate (npm run check)
```

— and a required context that stops being *reported* (not: reported as failing —
literally absent, or reported with conclusion `skipped` instead of `success`/`failure`)
reads to GitHub as **MISSING**, which blocks every future PR from merging, permanently,
with no self-correcting path short of an admin editing branch protection again. REVIEWER
must re-derive, independently, that every job whose `name:` is one of the two strings
above (a) still exists as a job in every workflow run triggered by `push`/`pull_request`,
(b) is never skipped via job-level `if:`, and (c) always reaches an explicit `success` or
`failure` conclusion, never `skipped`, for both required jobs specifically — not
"passing" in the sense CI going green, but "reporting at all" in the sense the GitHub
Checks API distinguishes.

## 1. What changes and why (design intent, both issues together)

Two independent fixes to the same file, both scoped to the `on:` block, a new
`concurrency:` block, and the internal structure of the `backend`/`frontend` jobs. No
job is renamed, added as a third *required* context, or removed.

**ISS-0591 (duplicate runs)**: two parts, both needed (per ISSUE-FIXER's diagnosis,
authoritative here over the issue's own "and/or" framing):

1. `push:` narrows to `branches: [main]`. Root cause of the duplicate is that a commit on
   a PR branch fires *both* `push` (any branch, today) and `pull_request` — two full runs
   of both jobs on byte-identical code. Restricting `push:` to `main` means a PR-branch
   commit fires only `pull_request`; a `main` commit (post-merge) fires only `push`.
   Neither branch of that split fires both events for the same commit.
2. Add a `concurrency:` group. This does **not** fix the duplicate-event problem above —
   `push` on a branch and `pull_request` for the same commit carry different
   `github.ref` values (`refs/heads/<branch>` vs `refs/pull/<n>/merge`), so they would
   never land in the same concurrency group anyway. It fixes a *different*, real problem:
   rapid re-pushes to the same PR superseding an in-flight run. Without it, three quick
   commits queue three full 8-9-minute backend runs; with it, the first two are
   cancelled the moment the third supersedes them.

**ISS-0592 (no path filter, but not a bare one)**: adding `paths:`/`paths-ignore:` at
the workflow or job level is explicitly rejected — GitHub only reports a required check
for a job that actually *runs* on a given trigger; a path-filtered-out job registers no
check-run at all for that commit, and GitHub renders a required-but-absent context as
permanently blocking. Instead: **both jobs always run, always register their check-run
under their exact required name, and always reach an explicit conclusion** — but a new
upstream `changes` job computes whether backend-relevant / frontend-relevant paths
changed, and `backend`/`frontend` gate only their *expensive* steps
(`mix deps.get`/`mix letflow.check`, `npm ci`/`npm run check`) on that job's output via
**step-level** `if:`, never job-level `if:`. A job whose expensive steps are skipped
still runs its cheap setup steps and finishes with conclusion `success` in well under a
minute — the required context reports, and reports `success`, same as today, just fast.

## 2. The `on:` and `concurrency:` blocks

```yaml
on:
  push:
    branches: [main]
  pull_request:

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
```

Notes:
- `pull_request:` keeps its default types (`opened`, `synchronize`, `reopened`) —
  unchanged, still fires on every new commit pushed to a PR branch (the `synchronize`
  event named in edge case 4).
- The concurrency group key falls back to `github.ref` for the `push` (post-merge to
  `main`) case, where there is no `pull_request.number`. Two rapid pushes to `main`
  itself (rare, since `GIT_MERGE.md`/0018 route all merges through PRs) would still
  dedupe correctly under that fallback.
- `cancel-in-progress: true` only ever cancels a run that is itself superseded by a
  newer run in the *same* group — it cannot cancel the one run that will actually be
  used to satisfy a required check, because by definition the newest run is never
  cancelled by an even-newer one until one exists.

## 3. The new `changes` job

Placed before `backend`/`frontend`; both gain `needs: changes`. It is **not** added to
branch protection's required contexts — it is a plain, non-required job whose only
purpose is producing two boolean outputs.

Design choice — hand-rolled `git diff`, not `dorny/paths-filter@v3`: ISSUE-FIXER's
diagnosis offered either. This design picks the manual script because every edge case
in the brief (zero-SHA new branch, non-push/PR triggers, force-push/`synchronize`) needs
to be reasoned about and verified explicitly on a required-check-blocking change, and a
hand-rolled ~25-line script is fully auditable by REVIEWER by reading the YAML, where a
third-party action's internal edge-case handling is not something this pipeline can
verify without reading its source. If REVIEWER or ELIXIR-DEV prefers `dorny/paths-filter`
after independently confirming its handling of all five edge cases below, that is an
acceptable substitution — but the acceptance bar (all five edge cases explicitly
verified, not assumed from the action's README) is the same either way.

```yaml
jobs:
  changes:
    name: Detect changed paths
    runs-on: ubuntu-latest
    outputs:
      backend: ${{ steps.filter.outputs.backend || steps.fallback.outputs.backend }}
      frontend: ${{ steps.filter.outputs.frontend || steps.fallback.outputs.frontend }}
    steps:
      - name: Check out repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Compute changed paths
        id: filter
        continue-on-error: true
        run: |
          set -uo pipefail

          if [ "${{ github.event_name }}" = "pull_request" ]; then
            BASE_SHA="${{ github.event.pull_request.base.sha }}"
            HEAD_SHA="${{ github.event.pull_request.head.sha }}"
          elif [ "${{ github.event_name }}" = "push" ]; then
            BASE_SHA="${{ github.event.before }}"
            HEAD_SHA="${{ github.event.after }}"
          else
            BASE_SHA=""
            HEAD_SHA=""
          fi

          ZERO_SHA="0000000000000000000000000000000000000000"

          if [ -z "$BASE_SHA" ] || [ -z "$HEAD_SHA" ] || [ "$BASE_SHA" = "$ZERO_SHA" ]; then
            echo "No usable base SHA for event '${{ github.event_name }}' (base='$BASE_SHA') -- assuming everything changed."
            echo "backend=true" >> "$GITHUB_OUTPUT"
            echo "frontend=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
            git fetch --no-tags --depth=50 origin "$BASE_SHA" || true
          fi

          if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
            echo "Base SHA $BASE_SHA not reachable even after a targeted fetch (likely a force-push rewrite) -- assuming everything changed."
            echo "backend=true" >> "$GITHUB_OUTPUT"
            echo "frontend=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          CHANGED=$(git diff --name-only "$BASE_SHA" "$HEAD_SHA")
          echo "Changed files ($BASE_SHA..$HEAD_SHA):"
          echo "$CHANGED"

          if echo "$CHANGED" | grep -qE '^(lib/|priv/repo/migrations/|test/|mix\.exs|mix\.lock|\.tool-versions|config/|\.github/workflows/ci\.yml)'; then
            echo "backend=true" >> "$GITHUB_OUTPUT"
          else
            echo "backend=false" >> "$GITHUB_OUTPUT"
          fi

          if echo "$CHANGED" | grep -qE '^(web/|\.github/workflows/ci\.yml)'; then
            echo "frontend=true" >> "$GITHUB_OUTPUT"
          else
            echo "frontend=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Fail-safe defaults if path detection did not complete cleanly
        id: fallback
        if: steps.filter.outcome != 'success'
        run: |
          echo "Path-detection step outcome was '${{ steps.filter.outcome }}', not 'success' -- defaulting to running both gates in full rather than risking a silent skip."
          echo "backend=true" >> "$GITHUB_OUTPUT"
          echo "frontend=true" >> "$GITHUB_OUTPUT"
```

Line-by-line reasoning for the edge cases in the brief:

1. **PR touching both docs and code** — `backend` and `frontend` are computed by two
   independent `grep -qE` checks over the same `$CHANGED` list, not an if/elif chain.
   A diff touching both `lib/` and `web/` sets both to `true`; a diff touching only
   `docs/` sets both to `false`. They are never forced mutually exclusive.
2. **Diff base differs by event; `before` can be all-zeros** — handled by the explicit
   event-name branch (`pull_request` uses `base.sha`/`head.sha`; `push` uses
   `before`/`after`) and the `ZERO_SHA` check immediately after, which treats an
   all-zero `before` (new branch's first push) as "no usable base" and takes the
   assume-changed exit, never a `git diff` against a real zero-hash object (which
   would error).
3. **Any other trigger type (e.g. `workflow_dispatch`)** — the `else` branch of the
   event-name check leaves both `BASE_SHA`/`HEAD_SHA` empty, which the same "no usable
   base" check below it catches, landing on assume-changed. No trigger type reaches the
   `git diff` line without a resolved, non-zero base.
4. **Force-push / `synchronize`** — the event payload's `before`/`after` (push) or
   `base.sha`/`head.sha` (PR) are used directly, exactly as GitHub reports them for that
   specific event delivery, not a locally-computed guess. `fetch-depth: 0` on this job's
   own checkout step pulls full history so a normal (non-rewritten) base is already
   present; the `git cat-file -e` reachability check plus a targeted
   `git fetch --depth=50 origin "$BASE_SHA"` handles the case where a force-push moved
   the ref away from `before` and the old commit is not on any branch history GitHub
   just checked out — and if that targeted fetch still can't find it (object already
   pruned), assume-changed rather than letting `git diff` fail the step.
5. **The step itself failing for an unanticipated reason** — `continue-on-error: true`
   on the `filter` step means the job does not fail outright even if the script hits an
   unhandled case; `steps.filter.outcome != 'success'` triggers a `fallback` step that
   unconditionally writes `true`/`true`. The job's `outputs:` block ORs the two steps'
   outputs together (`steps.filter.outputs.backend || steps.fallback.outputs.backend`)
   — GitHub Actions expression `||` returns the first non-empty operand, so a real
   `'false'` string from a successful `filter` run is used as-is (non-empty, so it wins),
   and only a genuinely empty/unset `filter` output (the crash case) falls through to
   `fallback`'s `'true'`. **Net effect: every code path that isn't a clean, confident
   "this path definitely didn't change" ends in `true`/`true`** — the same
   fail-open-to-full-gate posture the brief requires for edge cases 2 and 3, extended to
   cover the script's own possible failure too.

## 4. Modified `backend` / `frontend` jobs

Only the additions are shown; every existing step, `name:`, `services:` block, and
`runs-on:` stays byte-for-byte as today. Per ISSUE-FIXER's diagnosis, only the two named
expensive steps per job get the conditional — setup steps (`checkout`, `setup-beam`,
Rust pin/setup, dependency cache restore, `setup-node`) stay unconditional. They are
each in the tens-of-seconds range, not minutes, and keeping them unconditional avoids
adding more branching than the stated risk (a wrongly-skipped required check) justifies.

```yaml
  backend:
    name: Backend gate (mix letflow.check)      # UNCHANGED
    runs-on: ubuntu-latest
    needs: changes                               # NEW
    if: ${{ !cancelled() }}                       # NEW — availability guard, see note below

    services:
      postgres: { ... }                          # UNCHANGED verbatim

    steps:
      - name: Check out repository                # UNCHANGED, unconditional
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Set up Elixir/OTP (from .tool-versions)   # UNCHANGED, unconditional
        ...
      - name: Read pinned Rust version from .tool-versions  # UNCHANGED, unconditional
        ...
      - name: Set up Rust (pinned via .tool-versions)   # UNCHANGED, unconditional
        ...
      - name: Cache deps and _build                      # UNCHANGED, unconditional
        ...

      - name: Install dependencies
        if: needs.changes.outputs.backend != 'false'      # NEW — fail-open, see note below
        run: mix deps.get

      - name: Run backend gate
        if: needs.changes.outputs.backend != 'false'       # NEW — fail-open, see note below
        run: mix letflow.check
        env:
          WASMEX_BUILD: true
```

```yaml
  frontend:
    name: Frontend gate (npm run check)          # UNCHANGED
    runs-on: ubuntu-latest
    needs: changes                                # NEW
    if: ${{ !cancelled() }}                        # NEW — availability guard, see note below
    defaults:
      run:
        working-directory: web

    steps:
      - name: Check out repository                 # UNCHANGED, unconditional
        uses: actions/checkout@v4

      - name: Set up Node.js                        # UNCHANGED, unconditional
        uses: actions/setup-node@v4
        with:
          node-version: "22"
          cache: npm
          cache-dependency-path: web/package-lock.json

      - name: Install dependencies
        if: needs.changes.outputs.frontend != 'false'   # NEW — fail-open, see note below
        run: npm ci

      - name: Run frontend gate
        if: needs.changes.outputs.frontend != 'false'   # NEW — fail-open, see note below
        run: npm run check
```

Why step-level, never job-level, `if:` (on the *path-filter* condition specifically) —
restated precisely because this is the one detail the whole design hinges on: a job
whose `if:` evaluates false gets GitHub Actions conclusion `skipped`, and a `skipped`
conclusion on a job holding a required-check name is treated by GitHub's merge-gate the
same as the check simply never having reported — this is the exact ISS-0592 failure mode
("a path-filtered job that does not run reports its context as MISSING"), just reached
via `if: false` instead of via `paths:`. A job that runs unconditionally and merely skips
two internal steps always reaches job conclusion `success` (skipped steps do not count as
failures and do not change the job's overall conclusion), which is what a required check
needs to see. **This is why the backend/frontend booleans (`needs.changes.outputs.*`)
must never appear in a job-level `if:` — that rule is unchanged and still holds.**

**`if: ${{ !cancelled() }}` at the job level is a different thing, not a reintroduction
of that rule's violation** — CODE-DESIGN-VALIDATOR asked this be named distinctly so
REVIEWER does not conflate the two:

- The forbidden pattern (still forbidden) is gating the job's *existence* on whether the
  changed paths are backend/frontend-relevant — e.g. `if: needs.changes.outputs.backend
  == 'true'` at job level. That is exactly the ISS-0592 failure mode: a legitimate
  "nothing relevant changed" answer would make the required job report `skipped`.
- `if: ${{ !cancelled() }}` gates on nothing about *what* changed — it only overrides
  GitHub's default implicit job condition, which is `success()` (a job with `needs:` runs
  only if every needed job *succeeded*). Without this, a `changes` job that fails for a
  reason unrelated to path detection (its own `checkout` step failing, a runner infra
  fault) makes `backend`/`frontend` inherit the implicit `success()` gate and get skipped
  too — reintroducing the identical reports-as-MISSING failure mode via a completely
  different trigger (a `changes`-job infra flake instead of either issue's original
  symptom).
- **This design deliberately does not use `if: always()`, and an earlier round of this
  design that did was rejected** — `always()` removes the implicit `success()` gate
  entirely, with no exception, which per GitHub Actions' documented behavior also makes
  the job immune to the run's own cancellation signal, including the `cancel-in-progress:
  true` cancellation §2 of this same design adds to fix ISS-0591's duplicate-run problem.
  Concretely, that would mean: on a rapid re-push (§6 PR D), when the concurrency group
  cancels the superseded run, `backend`/`frontend` with `if: always()` would keep running
  to completion instead of being cancelled — directly defeating `cancel-in-progress` and
  contradicting PR D's own expected result below (superseded runs must show `conclusion:
  cancelled`, not `success` after running to completion).
- `!cancelled()` is the narrower, correct form because it distinguishes exactly the two
  cases this design needs distinguished, based on why the run condition evaluates the way
  it does:
  - **`changes` job *fails*** (its own `checkout` step errors, a script bug, runner infra
    fault unrelated to cancellation) → that job's conclusion is `failure`, not
    `cancelled` → `cancelled()` is `false` → `!cancelled()` is `true` → `backend`/
    `frontend` still run. This is the original gap this guard exists to close (an
    upstream failure must not silently skip the required check).
  - **`changes` job, or the whole run, is cancelled** (via this design's own
    `cancel-in-progress: true` on a superseded rapid re-push, or a manual cancel) → the
    run's cancellation status makes `cancelled()` evaluate `true` for jobs in that run →
    `!cancelled()` is `false` → `backend`/`frontend` correctly skip/stop rather than
    running to completion. This preserves ISS-0591's dedup fix instead of defeating it.
  Because the step-level conditions inside the job still fail open (see next paragraph),
  a `changes` job that failed outright (the first case above) still results in the full
  gate running — the safest possible behavior when the upstream signal is unavailable —
  while a genuinely cancelled/superseded run is allowed to actually stop, which is the
  entire point of adding `cancel-in-progress` in the first place.

Fail-open step conditions (`!= 'false'`, not `== 'true'`) — the second required fix:
`needs.changes.outputs.backend` is a GitHub Actions expression over a job output; if the
`changes` job failed before its `filter`/`fallback` steps ever ran (e.g. `checkout`
failed), the output was never set and evaluates as an **empty string**, not `'false'`.
An empty string is neither `'true'` nor `'false'` — under the original `==
'true'` form, an empty/unknown output resolves to *false*, silently skipping the real
gate exactly when the upstream signal is least trustworthy. Under `!= 'false'`, only an
explicit, successfully-computed `'false'` skips the gate; an empty string, `'true'`, or
any other unexpected value all resolve to "run it." This matches the posture the rest of
the design already commits to (§3's edge-case table and §6's verification plan both treat
"couldn't confidently determine nothing changed" as "assume changed") — the original
`== 'true'` step conditions were the one place that posture wasn't actually followed
through, which is what let a `changes`-job failure defeat this design's own fail-open
guarantee.

One accepted cost, stated explicitly rather than hidden: the `postgres:` service under
`backend` is a job-level property and starts unconditionally even when
`needs.changes.outputs.backend == 'false'`, since GitHub Actions has no step-scoped
service containers. This costs roughly the container's boot/health-check time (a few
seconds, bounded by the existing `--health-retries 10` / `--health-interval 2s` options)
on every skip — negligible next to the 8-9 minutes it replaces, and not worth the added
complexity of trying to avoid it.

## 5. Full resulting `on:`/jobs skeleton (for orientation, not a literal second copy)

```
on: {push: {branches: [main]}, pull_request: {}}
concurrency: {group: ..., cancel-in-progress: true}
jobs:
  changes:  (new, not required)
  backend:  (needs: changes; if: ${{ !cancelled() }}; name unchanged; 2 steps gain step-level if != 'false')
  frontend: (needs: changes; if: ${{ !cancelled() }}; name unchanged; 2 steps gain step-level if != 'false')
```

No third job is added to branch protection. `docs/migration/decisions/0018-*.md`'s
`contexts` list (`Backend gate (mix letflow.check)`, `Frontend gate (npm run check)`)
needs **no edit** — both strings are untouched by this design.

## 6. Verifying the required-context-preservation property before merging to `main`

This cannot be unit-tested locally (no ExUnit/mix test surface — it's GitHub's own Checks
API behavior). The verification bar is the same standard 0018's own Step 4 already set
for exactly this class of claim ("a claim of verified with no quoted command output does
not satisfy the acceptance criterion") — cite that record as precedent, don't re-derive
a lighter standard here.

**Mandatory, before this branch is merged to `main`** (owner: whoever implements —
ELIXIR-DEV per the roster, since this is repo/CI config, not `lib/letflow/` code, but
the implementing step regardless of which agent runs it):

1. **Static confirmation the two required strings are untouched.** Diff `ci.yml` against
   `main` and confirm the only `name:` lines under `jobs:` that read exactly
   `Backend gate (mix letflow.check)` and `Frontend gate (npm run check)` are the same
   two lines that existed before, unmodified, and that no job-level `if:` key was added
   anywhere under `jobs.backend` or `jobs.frontend`.

2. **Real dry-run PRs on this same branch, before it merges** — each one a genuine PR
   against this repo (scratch commits are fine, per 0018's own precedent of using a
   real, disposable PR rather than reasoning in the abstract):
   - **PR A — docs-only change** (e.g. a one-line edit to this very design file, on top
     of this branch once pushed, or a separate scratch branch layered on it). Expect:
     `gh api repos/tvolodi/letflow/commits/<sha>/check-runs --jq '.check_runs[] |
     {name,status,conclusion}'` shows both required names with `status: completed`,
     `conclusion: success`, completing in roughly the setup-step time, not 8-9 minutes.
     Quote the actual JSON in the handoff.
   - **PR B — backend-only change** (any `lib/` edit). Expect: `Backend gate` runs the
     full suite (same duration as today); `Frontend gate` still reports `success`
     quickly (its `npm ci`/`npm run check` steps show `conclusion: skipped` in the run's
     own step list, but the **job's** conclusion is `success`). Quote both the check-run
     JSON and a screenshot-equivalent (`gh run view <run-id> --json jobs` or the step
     list) showing the frontend job's steps as skipped-but-job-succeeded.
   - **PR C — frontend-only change** (any `web/` edit). Mirror of B.
   - **PR D — duplicate-run regression check for ISS-0591.** Push 2-3 rapid commits to
     the PR D branch; confirm via `gh run list --branch <branch>` that each commit
     produces exactly one counted run per event type reaching completion (superseded
     runs show `conclusion: cancelled`, attributable to `cancel-in-progress`), and that
     no commit produces both a `push` run and a `pull_request` run (the original
     ISS-0591 symptom). **Additionally, and specifically because `backend`/`frontend`
     carry `if: ${{ !cancelled() }}` rather than `if: always()`**: for the superseded
     run(s), quote `gh run view <superseded-run-id> --json jobs` and confirm the
     `backend` and `frontend` jobs themselves show `conclusion: cancelled` — not
     `success` after having run to completion. This is the check that would have caught
     the rejected `always()` version of this guard (which is immune to
     `cancel-in-progress` and would show those jobs finishing with `conclusion: success`
     instead of being cancelled); it must be quoted, not assumed, before this branch
     merges.
   - **PR E — brand-new branch's first push (all-zero `before`).** Create a genuinely
     new branch with no prior push, push one commit, open it as a PR (or inspect the
     `push` run alone if one fires). Confirm the `changes` job's log contains the
     "assuming everything changed" line (proves the zero-SHA fallback fired, not that it
     happened to compute the right answer some other way) and that both `backend`/
     `frontend` outputs came out `true`.
   - **PR F — deliberately break the `changes` job itself, not the path-detection
     script.** This scenario exists specifically to prove the `if: ${{ !cancelled() }}`
     job-level guard and the `!= 'false'` fail-open step conditions actually work together, not
     just the `continue-on-error`/`fallback` path inside the `filter` step (that inner
     failure mode is already covered by edge case 5 in §3 and is a different thing from
     this scenario). On a scratch branch layered on this one, break the `changes` job's
     own `checkout` step so it fails before `filter` ever runs — e.g. temporarily point
     it at `uses: actions/checkout@v4` with a bogus `ref:` that doesn't exist, or add a
     step before it that exits non-zero — and push it as a PR. Expect, and quote via
     `gh api repos/tvolodi/letflow/commits/<sha>/check-runs --jq '.check_runs[] |
     {name,status,conclusion}'`:
     - The `changes` job itself shows `conclusion: failure` (confirming the break
       actually took effect and this is a real test of the failure path, not a no-op).
     - `Backend gate (mix letflow.check)` and `Frontend gate (npm run check)` both show
       `status: completed`, `conclusion: success` — not `skipped`, not absent.
     - Additionally quote `gh run view <run-id> --json jobs` (or the step list) for the
       `backend`/`frontend` jobs showing their `Install dependencies`/`Run backend
       gate`/`Run frontend gate` steps as actually **executed** (not `skipped`) — this is
       the fail-open check specifically: because `needs.changes.outputs.backend` and
       `.frontend` are empty strings (the `changes` job died before setting any output),
       the `!= 'false'` condition must resolve true and run the real gate, proving the
       fix is not merely "job reports success" but "job reports success because it did
       real work," which is what actually keeps the branch-protection guarantee honest
       under this failure mode. Revert the scratch breakage before merging any of this
       branch's history to `main`.

3. **Re-confirm branch protection is unaffected.**
   `gh api repos/tvolodi/letflow/branches/main/protection --jq
   '.required_status_checks.contexts'` before and after this branch merges — must be
   byte-identical (`["Backend gate (mix letflow.check)", "Frontend gate (npm run
   check)"]`), proving nothing about this change required touching 0018's configuration.

Record the actual quoted output of 2A-2F and 3 in the implementing agent's handoff
(e.g. `result.live_verification`), the same field convention 0018 itself used — a
narrative claim of "verified" with no quoted `gh` output does not satisfy this design's
own bar, consistent with core-directives' "Never Call a Red Pipeline OK Without a
Source."

## 7. Open questions

None load-bearing enough to block CODE-DESIGN-VALIDATOR, but flagged rather than
silently resolved:

- **Path list completeness.** The backend/frontend regexes in §3 are derived from this
  repo's current top-level layout (`lib/`, `priv/repo/migrations/`, `test/`, `web/`,
  plus toolchain files). If a future requirement adds a new top-level directory that
  should gate one of the two jobs (e.g. a `scripts/` change that backend tests exercise),
  that directory must be added to the relevant regex explicitly — this design does not
  attempt a self-updating or wildcard-everything-except-docs approach, since a
  too-broad "everything except an explicit docs allowlist" inversion risks silently
  under-triggering if a new non-docs, non-code top-level directory is added later and
  nobody updates either list. Whoever adds a new top-level directory that affects either
  gate should treat updating this regex as part of that change.
- **`dorny/paths-filter@v3` substitution.** Noted in §3 as an acceptable alternative if
  its handling of all five edge cases is independently verified rather than assumed —
  this design does not pre-approve that substitution without that verification having
  actually been done and quoted, for the same "no source, no claim" reason as §6.
