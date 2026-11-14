#!/usr/bin/env bash
# T-1383: decides whether the job "Stock browser e2e (playwright)" runs on a pull request or a merge-queue entry.
# Consumer: .github/workflows/ci.yml, job `stock_e2e`, step "Decide". Nightly and manual runs always run it (decided in ci.yml).
#
# Contract:
#   stdin  : the changed-file list, one path per line (may be empty); read in full before matching (no SIGPIPE).
#   stdout : exactly one line, `stock_web=true|false`; exit 0.
#   No arguments, no environment reads.
#
# The rule: the stock screens and routes, the task inbox pages the click-through drives, the two GATE B specs and
# their helpers, the e2e stack scripts. One single-quoted assignment line.
set -uo pipefail

if [ "$#" -ne 0 ]; then
  echo "ci_stock_e2e_paths.sh: takes no arguments (reads the changed-file list on stdin)" >&2
  exit 2
fi

CHANGED=$(cat) || exit 1

STOCK_E2E_RE='^(web/src/modules/stock/|web/src/modules/assets/|web/src/pages/tasks/|web/tests/e2e/gate-b-|web/tests/e2e/support/|web/tests/e2e/helpers\.ts$|web/playwright\.config\.ts$|scripts/e2e/|scripts/ci_stock_e2e_paths\.sh$)'

grep -qE "$STOCK_E2E_RE" <<<"$CHANGED"
case "$?" in
  0) echo "stock_web=true" ;;
  1) echo "stock_web=false" ;;
  *)
    echo "ci_stock_e2e_paths.sh: grep failed" >&2
    exit 1
    ;;
esac
exit 0
