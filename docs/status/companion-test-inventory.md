# Companion test inventory (S1-prep C, T-1676)

Which test files read paths that would move to a companion repo in the source/companion split.
Input to T-1599 section 6 and stage 0. Nothing was moved, tagged or deleted; no test changed.

Produced by `scripts/companion/test_inventory.sh` (read-only, `git grep -lIE` over tracked
files, ~0.3 s). Re-run it for current numbers; `--list` prints every file, `--files FAMILY`
prints one family. Measured on main at the time of writing (2026-11-11).

Scope: executable test files only (2063 tracked): `*_test.exs` under `test/` (1421), `*.test.ts`,
`*.test.tsx`, `*.spec.ts` under `web/tests/` (126) and `*.test.ts(x)` colocated under `web/src/` (425),
`*_test.dart` under `apps/mobile/test/` (91). Data artefacts are not counted even when they name a
path: `test/reports/`, `test/specs/`, `test/uat-reports/`, `test/fixtures/` (incl. `*_fixture.exs`),
`test/support/` helpers, `test/shard_manifest.txt`. Those are companion candidates themselves, moving
with their family rather than being tagged. A file counts when its text contains the family's path
pattern anywhere (code, comment or string), so counts are an upper bound on "reads at runtime".

## Counts by family

Families overlap (a runbook test also names `docs/`), so rows do not add up.

| Family | Pattern (ERE) | Files | `test/` | `web/tests/` | `web/src/` | `apps/mobile/test/` |
|---|---|---:|---:|---:|---:|---:|
| docs | `docs/` | 254 | 214 | 22 | 12 | 6 |
| handoffs | `handoffs/` | 27 | 27 | 0 | 0 | 0 |
| claude | `\.claude/` | 5 | 5 | 0 | 0 | 0 |
| requirements_yaml | `requirements\.yaml` | 29 | 24 | 1 | 4 | 0 |
| decisions | `migration/decisions\|decisions/[0-9]{4}-` | 19 | 17 | 2 | 0 | 0 |
| runbooks | `runbooks/` | 42 | 42 | 0 | 0 | 0 |
| uat_fixtures | `fixtures/uat\|docs/uat\|uat-reports\|ba-decisions` | 34 | 16 | 17 | 1 | 0 |
| **union (distinct)** | | **295** | | | | |
| docs and no other family | | 156 | | | | |

The union, 295 of 2063 test files (14 %), is the real figure behind T-1599's "about 955". That
count overlapped families and included data artefacts (the first version of this report, 875,
also did: 443 of its docs hits were `test/reports/` and `test/specs/` files, and it missed the
425 colocated `web/src` tests).

Test files naming each `docs/` subtree (a file is counted once per subtree, from the 254
docs files): guides 114, issues 37, requirements 26, migration 25, anti-patterns 14, roles 12,
frontend 10, assets 8, agents 8, status 7, mobile 3, testing 4, runbooks 42 (the runbooks family).

## Proposed `:companion` tag rule per family

Rule of thumb: a test is `@tag :companion` (runs only when the companion checkout is present,
excluded from the source-only gate) when it reads the family path as an input and its
subject is that content. A test that only mentions the path in a comment or message, or whose
subject is a lib/ lint that takes the path as a parameter, stays a source test.

| Family | Rule | Note |
|---|---|---|
| handoffs (27) | Tag all. | `handoffs/` is the pipeline's own record; no source behaviour depends on it. Files in `test/letflow/engine` (4), `event_store` (2), `mix/tasks` (3), `test/support` (2) need a read first: the path may be a fixture string, not an input. |
| requirements_yaml (29) | Tag when the test opens `docs/requirements.yaml`; keep when a literal is only an id or message. | The registration lints (`letflow.check_requirements_registration`) read it: they move with it, or get a fixture copy (stage 0 decision). |
| decisions (19) | Tag when a test greps a decision record's text; keep when it only cites a record number in a moduledoc/comment. | Decision records are load-bearing for review, not for runtime. |
| runbooks (42) | Tag all. | Runbook tests match exact lines of `docs/runbooks/*` (CRLF sensitive); pure documentation checks. |
| claude (5) | Tag all except tests whose subject is a lib/ or script path filter that merely lists `.claude/` patterns (for example `ci_backend_path_filter_test`, `risk_tier_test`): those stay source and get a literal fixture. | |
| uat_fixtures (34) | Tag when the test loads files from `test/fixtures/uat` or `docs/uat`; the UAT scenario schema lint and simulation runner tests follow the fixtures. | Fixtures move first; tag follows the fixture. |
| docs (254, 156 only here) | Two steps. (1) The 98 files that also hit a narrower family above take that family's rule. (2) The 156 "docs only" files are classified by subtree: `docs/issues`, `docs/status`, `docs/guides`, `docs/anti-patterns`, `docs/agents`, `docs/roles`, `docs/migration` read companion content: tag; `docs/frontend`, `docs/mobile`, `docs/assets`, `docs/testing`, `docs/open-source` and any docs path listed in `BACKEND_PATHS_RE` need a per-file call, because the product's own gates read some of them by name. | The generic `docs/` match is the noisiest; it must not be tagged wholesale. |

## Caveats for stage 0

- Pattern match is text-based: a file naming a path in a comment counts. Expect the true
  "reads at runtime" number to be lower; confirm with a per-file read before tagging.
- `BACKEND_PATHS_RE` in `scripts/ci_changed_paths.sh` already names several docs files the
  backend gate reads; those paths stay on the source side (or the regex changes with them).
- Hits such as `docs/requirement_status_invariants_test` are test file names, false positives of the `docs/` pattern.
- The 12 `web/src` and 22 `web/tests` docs hits (for example `processDesignerNote.test.ts`, which reads `docs/design/process-designer.md`) need the frontend gate's path rule decided too.
- Data artefacts (`test/reports`, `test/specs`, `test/uat-reports`, `test/fixtures/uat`) are out of this count by design; stage 0 decides their move separately.
- Tests of `lib/mix/tasks` lints that scan the repo tree (not a fixed path) are not caught by
  a path grep; they need a separate pass.
