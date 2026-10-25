#!/usr/bin/env bash
# GH #2622: the ONE source of CI's path rules (design lib/letflow/design/gh2622-ci-push-concurrency-and-cd-tip.md §2).
#
# Consumer: .github/workflows/ci.yml, job `changes`, step "Compute changed paths" (the only
# caller; CD has no path rules since GH #2622). Kept under scripts/ because `scripts/.*\.sh$`
# is in BACKEND_PATHS_RE, and the frontend/mobile rules name this file too, so editing a rule
# runs every gate. Trust boundary: a pull request runs its own copy of this file, as for ci.yml
# (WF-02 Step 2c, GH #2586 list).
#
# Contract:
#   stdin  : the changed-file list, one path per line (may be empty). Read IN FULL before any
#            match, so no reader exits early on a pipe (no SIGPIPE under pipefail, Q-1110).
#   stdout : exactly three lines, `backend=true|false`, `frontend=true|false`,
#            `mobile=true|false`; exit 0.
#   error  : non-zero exit (the caller then exits 1 and CI's fail-safe step runs every gate).
#   No arguments and no environment reads.
#
# Q-1059 / GH #2411: the backend gate reads more than lib/ and test/. Every repo path it reads by
# name must match BACKEND_PATHS_RE, or a change confined to that path merges without the gate
# (letflow.check.* reads docs/requirements.yaml, docs/issues, docs/status, handoffs/ via
# lint_handoffs, .formatter.exs via mix format; tests read priv/**, deploy/, docs/roles.md,
# docs/runbooks/ and a few web/ files). The guard test test/letflow/ci_backend_path_filter_test.exs
# parses the BACKEND_PATHS_RE line below and fails when a path the gate reads is missing. Keep
# each rule ONE single-quoted line, assigned exactly as below, so the tests can extract it.
# Known gap: no_smtp_secret_guard_test greps the whole tracked tree, so no path list can be
# complete; the push-to-main always-run rule (ISS-0840, in ci.yml) is the backstop.
#
# Q-1110 / GH #2492: match with a here-string, never `echo "$CHANGED" | grep -q`. grep -q exits
# on the first match; under `set -o pipefail` a still-writing echo then dies of SIGPIPE on a
# large list (> pipe buffer), the pipeline reports 141 and the gate is silently skipped.

set -uo pipefail

if [ "$#" -ne 0 ]; then
  echo "ci_changed_paths.sh: takes no arguments (reads the changed-file list on stdin)" >&2
  exit 2
fi

CHANGED=$(cat) || exit 1

BACKEND_PATHS_RE='^(lib/|priv/|test/|config/|mix\.exs|mix\.lock|\.tool-versions|\.formatter\.exs$|\.gitattributes$|\.env\.example$|scripts/.*\.sh$|deploy/|\.github/workflows/|\.claude/agents/uat-runner\.md$|web/\.env|web/vite\.config\.ts$|web/tests/e2e/env04\.e2e\.spec\.ts$|web/tests/e2e/pipelines/onboarding-wizard\.pipeline\.e2e\.spec\.ts$|docs/requirements\.yaml$|docs/issues/[^/]+\.yaml$|docs/status/requirement_status[^/]*\.yaml$|docs/status/work_board_cutover\.yaml$|docs/roles\.md$|docs/frontend/x-ui-widget-vocabulary\.md$|docs/migration/stage-7-simulation-uat-parity\.md$|docs/runbooks/|docs/agents/shared/HANDOFF_PROTOCOL\.md$|handoffs/registry\.json$|handoffs/(.*/)?step[^/]*\.[^/]*$)'
FRONTEND_PATHS_RE='^(web/|priv/labels/|\.github/workflows/ci\.yml|scripts/ci_changed_paths\.sh$)'
MOBILE_PATHS_RE='^(apps/mobile/|\.github/workflows/ci\.yml|scripts/ci_changed_paths\.sh$)'

# grep status: 0 = a path matched, 1 = none matched, anything else = error (bad regex, ...).
emit() {
  case "$2" in
    0) echo "$1=true" ;;
    1) echo "$1=false" ;;
    *)
      echo "ci_changed_paths.sh: grep failed for $1 (status $2)" >&2
      exit 1
      ;;
  esac
}

grep -qE "$BACKEND_PATHS_RE" <<<"$CHANGED"
emit backend "$?"

grep -qE "$FRONTEND_PATHS_RE" <<<"$CHANGED"
emit frontend "$?"

grep -qE "$MOBILE_PATHS_RE" <<<"$CHANGED"
emit mobile "$?"

exit 0
