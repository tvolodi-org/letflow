# CI minutes (T-1614, B4#9), 2026-11-10

Measured on the last 30 `main` CI runs (job `completed_at - started_at`).

| Job | median s | max s |
|---|---|---|
| Backend shards 1..8 | 899, 820, 1144, 766, 904, 849, 758, 801 | 928-1550 |
| Backend static + isolated tails | 401 | 439 |
| Mobile gate | 403 | 520 |
| Frontend gate | 338 | 415 |

Full push run about 141 job-min; docs-only selective run 22-33 job-min.

## Applied
Push to `main` runs the Frontend and Mobile gates only when the push range (`before..sha`) matches the
path rules (`scripts/ci_changed_paths.sh`, same as the merge queue). Backend always runs. Fail-safes
(zero/unreachable base, script failure) run everything; nightly and `workflow_dispatch` run everything.

Saved: mobile 6.3 + frontend 4.3 = about 10.6 job-min per main push (about 15 min of a 33-min
docs-only run). Minutes, not wall time. Residual risk: a regression in a path the filter misses is
bounded by the merge queue (same rule, same tree) and the nightly run.
Operator check: the first post-merge push run of a docs-only commit shows both gates `skipped`.

## Proposals not applied
1. Re-balance `test/shard_manifest.txt` for 8 shards: shard 3 median 1144 s vs 758-904 s (about 4 min wall).
2. Shallow checkout (8 s x 10 jobs): unverified against history-reading tests.
3. Share Rust/Elixir/cache set-up (about 41 s x 10 jobs, 4 %).
4. Skip `backend_static` tails (275 s) on docs-only pushes: register checks must run; not shown safe.
5. Anything paid (bigger runners, more shards): owner decision.
