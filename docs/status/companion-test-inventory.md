# Companion test inventory (S1-prep C, T-1676)

Which test files read paths that would move to a companion repo in the source/companion split.
Input to T-1599 section 6 and stage 0. Nothing was moved, tagged or deleted; no test changed.

Produced by `scripts/companion/test_inventory.sh` (read-only, `git grep -lIE` over tracked
files, ~0.3 s). Re-run it for current numbers; `--list` prints every file, `--files FAMILY`
prints one family. Measured on main at the time of writing (2026-11-11).

Scope: test files under `test/`, `web/tests/`, `apps/mobile/test/` (3101 tracked files).
`test/fixtures/uat/**` (396 data files) is excluded from the scan: it is fixture data, a
companion candidate itself, not a test. A file counts when its text contains the family's
path pattern anywhere (code, comment or string), so counts are an upper bound on "reads at runtime".

## Counts by family

Families overlap (a runbook test also names `docs/`), so rows do not add up.

| Family | Pattern (ERE) | Files | `test/` | `web/tests/` | `apps/mobile/test/` |
|---|---|---:|---:|---:|---:|
| docs | `docs/` | 740 | 711 | 23 | 6 |
| handoffs | `handoffs/` | 210 | 210 | 0 | 0 |
| claude | `\.claude/` | 16 | 16 | 0 | 0 |
| requirements_yaml | `requirements\.yaml` | 234 | 233 | 1 | 0 |
| decisions | `migration/decisions\|decisions/[0-9]{4}-` | 44 | 42 | 2 | 0 |
| runbooks | `runbooks/` | 49 | 49 | 0 | 0 |
| uat_fixtures | `fixtures/uat\|docs/uat\|uat-reports\|ba-decisions` | 138 | 120 | 18 | 0 |
| **union (distinct)** | | **875** | | | |
| docs and no other family | | 309 | | | |

The union, 875 of 3101 test files (28 %), is the real figure behind T-1599's "about 955"
(that count overlapped families and included fixtures).

Largest `docs/` subtrees by number of test files naming them (a file is counted once per
subtree): issues 229, requirements 227, guides 161, status 109, anti-patterns 72, agents 67,
migration 61, runbooks 49, roles 37, mobile 14, frontend 13, assets 7, testing 4.
(A few hits such as `docs/requirement_status_invariants_test` are test file names, not paths.)

## Proposed `:companion` tag rule per family

Rule of thumb: a test is `@tag :companion` (runs only when the companion checkout is present,
excluded from the source-only gate) when it reads the family path as an input and its
subject is that content. A test that only mentions the path in a comment or message, or whose
subject is a lib/ lint that takes the path as a parameter, stays a source test.

| Family | Rule | Note |
|---|---|---|
| handoffs (210) | Tag all. | `handoffs/` is the pipeline's own record; no source behaviour depends on it. Files in `test/letflow/engine`, `event_store`, `mix/tasks`, `support` need a read first: the path may be a fixture string, not an input. |
| requirements_yaml (234) | Tag when the test opens `docs/requirements.yaml`; keep when a literal is only an id or message. | The registration lints (`letflow.check_requirements_registration`) read it: they move with it, or get a fixture copy (stage 0 decision). |
| decisions (44) | Tag when a test greps a decision record's text; keep when it only cites a record number in a moduledoc/comment. | Decision records are load-bearing for review, not for runtime. |
| runbooks (49) | Tag all. | Runbook tests match exact lines of `docs/runbooks/*` (CRLF sensitive); pure documentation checks. |
| claude (16) | Tag all except tests whose subject is a lib/ or script path filter that merely lists `.claude/` patterns (for example `ci_backend_path_filter_test`, `risk_tier_test`): those stay source and get a literal fixture. | |
| uat_fixtures (138) | Tag when the test loads files from `test/fixtures/uat` or `docs/uat`; the UAT scenario schema lint and simulation runner tests follow the fixtures. | Fixtures move first; tag follows the fixture. |
| docs (740, 309 only here) | Two steps. (1) The 431 files that also hit a narrower family above take that family's rule. (2) The 309 "docs only" files are classified by subtree: `docs/issues`, `docs/status`, `docs/guides`, `docs/anti-patterns`, `docs/agents`, `docs/roles`, `docs/migration` read companion content: tag; `docs/frontend`, `docs/mobile`, `docs/assets`, `docs/testing`, `docs/open-source` and any docs path listed in `BACKEND_PATHS_RE` need a per-file call, because the product's own gates read some of them by name. | The generic `docs/` match is the noisiest; it must not be tagged wholesale. |

## Caveats for stage 0

- Pattern match is text-based: a file naming a path in a comment counts. Expect the true
  "reads at runtime" number to be lower; confirm with a per-file read before tagging.
- `BACKEND_PATHS_RE` in `scripts/ci_changed_paths.sh` already names several docs files the
  backend gate reads; those paths stay on the source side (or the regex changes with them).
- `docs/requirement_status_invariants_test` style hits are false positives of the `docs/` pattern.
- Tests of `lib/mix/tasks` lints that scan the repo tree (not a fixed path) are not caught by
  a path grep; they need a separate pass.
