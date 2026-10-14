# Merge queue on tvolodi-org/letflow

The repository moved to `tvolodi-org/letflow` on 2026-10-14 (T-0165). The old
`tvolodi/letflow` name redirects.

`main` is governed by the ruleset `main-queue` with a merge queue:

- merge method: squash;
- no bypass actors: direct pushes to `main` are refused for everyone;
- required checks: `Backend gate (mix letflow.check)` and `Frontend gate (npm run check)`.

## How to land a change

1. Open a pull request against `main` and wait for the required checks to pass.
2. Enqueue it: use "Merge when ready" in the pull request UI, or the GraphQL
   mutation `enqueuePullRequest`.
3. GitHub runs the same checks on a temporary `gh-readonly-queue/main/...` branch
   and squash-merges the pull request when they pass.

## Emergency

If the queue itself is broken, a repository admin can disable the ruleset
temporarily. See the infrastructure runbook for the procedure.
