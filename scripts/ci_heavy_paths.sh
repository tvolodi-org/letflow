#!/usr/bin/env bash
# T-1139: which backend test files are "heavy" (exam tests and :slow-tagged files) and when
# a pull request must run them. Two modes, one source of the heavy-file definition:
#
#   ci_heavy_paths.sh files   prints the heavy test files, one repo-relative path per line:
#                             every *_test.exs under a modules/exam directory, every test file
#                             naming exam in its path, and every *.exs holding `@moduletag :slow`.
#                             Consumer: scripts/test_parallel.sh (TEST_PARALLEL_SKIP_HEAVY=1).
#   ci_heavy_paths.sh        reads the changed-file list on stdin (read in full, Q-1110) and
#                             prints exactly one line, `heavy=true|false`. true when a changed
#                             path is exam code, a heavy test file itself, or a path the heavy
#                             tests depend on (test/support, migrations, config, mix files,
#                             the test runner and CI files). Consumer: ci.yml, job `changes`,
#                             pull_request and merge_group events only. Push to main, the
#                             nightly schedule, workflow_dispatch and every fail-safe run all.
#
# Separate from ci_changed_paths.sh on purpose: that script's three-line output is a pinned
# contract (gh2622_ci_push_concurrency_test.exs).

set -uo pipefail

heavy_files() {
  {
    find test -type f -name '*_test.exs' \( -path '*/modules/exam/*' -o -path '*exam*' \)
    grep -rlE '^[[:space:]]*@moduletag :slow' test --include='*.exs'
  } | sort -u
}

if [ "${1:-}" = "files" ]; then
  heavy_files
  exit 0
fi

if [ "$#" -ne 0 ]; then
  echo "ci_heavy_paths.sh: usage: ci_heavy_paths.sh [files] (changed-file list on stdin)" >&2
  exit 2
fi

CHANGED=$(cat) || exit 1

HEAVY_DEPS_RE='^(lib/letflow/modules/exam/|test/support/|priv/repo/migrations/|config/|mix\.exs$|mix\.lock$|\.tool-versions$|test/test_helper\.exs$|test/shard_manifest\.txt$|scripts/test_parallel\.sh$|scripts/ci_heavy_paths\.sh$|\.github/workflows/)'

if grep -qE "$HEAVY_DEPS_RE" <<<"$CHANGED"; then
  echo "heavy=true"
  exit 0
fi

HEAVY=$(heavy_files) || exit 1
if [ -n "$HEAVY" ] && grep -qxFf <(printf '%s\n' "$HEAVY") <<<"$CHANGED"; then
  echo "heavy=true"
else
  echo "heavy=false"
fi
exit 0
