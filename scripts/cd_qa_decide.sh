#!/usr/bin/env bash
# GH #2622: CD (QA) "tip rule" decision (design lib/letflow/design/gh2622-ci-push-concurrency-and-cd-tip.md §3).
#
# Called by .github/workflows/cd.yml, job `deploy`, step `decide`, from a checkout of `main`
# (trusted merged code) after `git fetch origin main`. Decides whether to deploy main's tip
# to QA. It never deploys anything itself and has no path rules (REQ-367's CD path gate is
# superseded: CD deploys the tested main tip whenever QA differs).
#
# Inputs, environment only (no arguments), plus the local git repository (the cwd):
#   RUN_SHA    head sha of the CI push run that fired this CD run
#   TIP        main's tip from the GitHub API (empty on error)
#   TIP_GIT    `git rev-parse origin/main` after the fetch
#   TIP_RUN    the tip's latest CI push run: its conclusion if completed, else its status;
#              `none` if there is no run, `error` if the lookup failed (unused when RUN_SHA == TIP)
#   QA_HEALTH  body of QA's GET /health (UNTRUSTED; empty when unreachable). Parsed with jq,
#              hex-validated before any git call, and never printed.
#
# Output: exactly two lines, `deploy=true|false` and `reason=cd-qa: <text>`. <text> is a fixed
# phrase plus validated shas or a word from a fixed list; nothing else.
# Exit: 0 = a decision (deploy or skip); 3 = red decision (rows 1-3: the step must fail, the
# two lines are still printed, deploy=false); anything else = script error (the caller reports
# `cd-qa: decide error` and fails). The caller never deploys unless exit is 0 AND deploy=true.
#
# First match wins. Rows 1-4 (tip and run checks) come BEFORE rows 5-9 on purpose: a reachable
# or unreachable QA must never turn a non-green or unknown tip into a deploy. Only the health
# signal (rows 5, 6, 8) fails toward deploying.

set -uo pipefail

if [ "$#" -ne 0 ]; then
  echo "cd_qa_decide.sh: takes no arguments (inputs come from the environment)" >&2
  exit 2
fi

RUN_SHA="${RUN_SHA:-}"
TIP="${TIP:-}"
TIP_GIT="${TIP_GIT:-}"
TIP_RUN="${TIP_RUN:-}"
QA_HEALTH="${QA_HEALTH:-}"

HEX40='^[0-9a-f]{40}$'
HEXQ='^[0-9a-f]{7,40}$'

decide() {
  printf 'deploy=%s\nreason=cd-qa: %s\n' "$1" "$2"
  exit "$3"
}
deploy() { decide true "$1" 0; }
skip() { decide false "$1" 0; }
red() { decide false "$1" 3; }

command -v jq >/dev/null 2>&1 || {
  echo "cd_qa_decide.sh: jq not found" >&2
  exit 1
}
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "cd_qa_decide.sh: not inside a git repository" >&2
  exit 1
}

# Row 1
[[ $RUN_SHA =~ $HEX40 ]] || red "invalid run sha"

# Row 2
[[ $TIP =~ $HEX40 ]] || red "tip unreadable"
[[ $TIP_GIT =~ $HEX40 ]] || red "tip unreadable"
[[ $TIP == "$TIP_GIT" ]] || red "tip unstable (api $TIP, git $TIP_GIT)"

# Rows 3-4
if [[ $RUN_SHA != "$TIP" ]]; then
  [[ $TIP_RUN == error ]] && red "tip run unreadable (tip $TIP)"
  if [[ $TIP_RUN != success ]]; then
    case "$TIP_RUN" in
      none | completed | action_required | cancelled | failure | neutral | skipped | stale | \
        timed_out | startup_failure | in_progress | queued | requested | waiting | pending)
        word="$TIP_RUN"
        ;;
      *) word=other ;;
    esac
    skip "not tip (run sha $RUN_SHA, tip $TIP); tip run $word"
  fi
fi

# Row 5: the health signal. jq -j prints no trailing newline (and no CR on Windows hosts).
[[ -n $QA_HEALTH ]] || deploy "QA sha unknown (unreachable), deploying tip $TIP"

kind=$(printf '%s' "$QA_HEALTH" | jq -j '
  if type != "object" then "notjson"
  elif .sha == null then "null"
  elif (.sha | type) != "string" then "nothex"
  else "string" end' 2>/dev/null) || kind=notjson

case "$kind" in
  string) ;;
  null) deploy "QA sha unknown (null), deploying tip $TIP" ;;
  nothex) deploy "QA sha unknown (not-hex), deploying tip $TIP" ;;
  *) deploy "QA sha unknown (not-json), deploying tip $TIP" ;;
esac

q=$(printf '%s' "$QA_HEALTH" | jq -j '.sha' 2>/dev/null) || q=""
[[ $q =~ $HEXQ ]] || deploy "QA sha unknown (not-hex), deploying tip $TIP"

# Row 6: resolve against the fetched repository only (never a string-prefix comparison). A short
# sha that is ambiguous or unknown fails `--verify`.
full=$(git rev-parse --verify --quiet "${q}^{commit}" 2>/dev/null) || full=""
[[ $full =~ $HEX40 ]] || deploy "QA sha $q unresolvable, deploying tip $TIP"

# Row 7
[[ $full != "$TIP" ]] || skip "QA already at tip $TIP"

# Row 8
git merge-base --is-ancestor "$full" "$TIP" >/dev/null 2>&1 ||
  deploy "QA sha $q not an ancestor of tip $TIP, deploying tip"

# Row 9
deploy "QA sha $q behind tip $TIP, deploying tip"
