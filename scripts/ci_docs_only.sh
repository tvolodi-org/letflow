#!/usr/bin/env bash
# T-1249: docs-only pull requests run the static checks and the docs-related tests, not the
# four full backend shards. Two modes, one source of the docs-test definition (same shape as
# scripts/ci_heavy_paths.sh):
#
#   ci_docs_only.sh files   prints the docs-related test files, one repo-relative path per line:
#                           every test/**/*_test.exs that names docs/requirements.yaml, a docs
#                           file path (docs/<x>.md|yaml), decision records or the "docs" dir.
#                           Consumer: ci.yml, job `backend_shard`, step "Run docs tests".
#   ci_docs_only.sh         reads the changed-file list on stdin (read in full, Q-1110) and
#                           prints exactly one line, `docs_only=true|false`. true only when the
#                           list is non-empty and EVERY path is under docs/. Consumer: ci.yml,
#                           job `changes`, pull_request and merge_group events only; push to main,
#                           schedule, workflow_dispatch and every fail-safe path say false.
#
# Separate from ci_changed_paths.sh on purpose: that script's three-line output is a pinned
# contract (gh2622_ci_push_concurrency_test.exs). Safety: anything outside docs/ (even one
# file) gives false, so a mixed or code change runs the full shards as before.

set -uo pipefail

# T-1363: a test file is docs-related when it names docs/requirements.yaml, a decision record,
# docs/status/ or the "docs" dir, or any other docs/<x>.md|yaml path EXCEPT the boilerplate
# `docs/guides/test_developer_guide.md`. Nearly every DB-backed suite cites that guide in its
# moduledoc ("Uses DataCase per ..."); counting those mentions selected 173 of ~1100 test files
# (engine, router, entity suites; measured one by one at 3000 s serial, none hangs), so the
# docs-only step ran 24-36 min and, printing nothing until the end, looked hung. Every other docs
# path mention (read through a helper, a multi-line call, a variable) is still selected.
# Root cause is plausible, not proven: E1/C4 ran the same 173 files in 1-5 min, so the slow runs
# (E2, C6) probably also depended on runner load or the shard split; the per-step timeout is a
# separate task.
# T-1404: the 79 files left after T-1363 still ran 575 s on main (a 600 s step timeout, PR #3858
# attempt 2 failed with 124 although its E2 entry changes nothing: three DB suites, records_test,
# help_test and instances_test, take 80 s each and were selected by a docs path in a moduledoc or
# a `#` comment). A mention counts only when it sits in a string literal on a code line: a comment
# line (first non-blank character `#`) and a backtick-quoted path in prose are prose, not a read.
docs_tests() {
  local pat='requirements\.yaml|docs/migration/decisions|docs/status/|docs/[a-z_/.-]+\.(md|yaml)'
  {
    git grep -nE "$pat|\"docs\"" -- 'test/*_test.exs'
  } | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
    grep -E "(\"|~[sS][|(/\\[{<])[^\"\`]*(${pat})|\"docs\"" |
    grep -v 'docs/guides/test_developer_guide\.md' | cut -d: -f1 | sort -u
}

if [ "${1:-}" = "files" ]; then
  docs_tests
  exit 0
fi

if [ "$#" -ne 0 ]; then
  echo "ci_docs_only.sh: usage: ci_docs_only.sh [files] (changed-file list on stdin)" >&2
  exit 2
fi

CHANGED=$(cat) || exit 1

if [ -z "${CHANGED//[[:space:]]/}" ]; then
  echo "docs_only=false"
  exit 0
fi

# grep -v status: 0 = some path is NOT under docs/, 1 = all are, else error.
grep -qvE '^(docs/.+|)$' <<<"$CHANGED"
case "$?" in
  0) echo "docs_only=false" ;;
  1) echo "docs_only=true" ;;
  *) exit 1 ;;
esac
exit 0
