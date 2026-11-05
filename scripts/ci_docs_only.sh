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

# T-1363: a test file is docs-related when it names docs/requirements.yaml, a decision record or the
# "docs" dir anywhere, or when it READS a docs file (a File./Path. call or a module attribute on the
# same line as the docs/<x>.md|yaml literal). A bare mention of a docs path in a comment, moduledoc or
# error message no longer counts: that alternative matched 162 of the 1100 test files, among them the
# engine, router and entity suites, and the docs-only step then ran ~27 min instead of a few.
docs_tests() {
  {
    git grep -lE 'requirements\.yaml|docs/migration/decisions|docs/status/|"docs"' -- 'test/*_test.exs'
    git grep -lE '(File\.|Path\.|read_doc|@[a-z_]+ +).*"[^"]*docs/[a-z_/.-]+\.(md|yaml)' -- 'test/*_test.exs'
  } | sort -u
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
