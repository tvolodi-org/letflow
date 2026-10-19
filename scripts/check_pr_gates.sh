#!/usr/bin/env bash
# check_pr_gates.sh - read-only check of a PR's `## Gates` block (audit #2874 R1, R4).
# Format spec: docs/agents/protocols/GIT_MERGE.md, "Gates block". Run by the supervisor
# before granting a merge slot. NOT wired into CI or the merge queue.
#
# Usage: check_pr_gates.sh <PR number>
#        check_pr_gates.sh --body-file <file> --files <file> [--title <text>]   (local check)
# Limits: `gh pr view --json files` is capped at about 100 files; a `CI: ... failure` line passes
# (the script checks form, not outcome).
# Exit: 0 ok or out of scope, 1 problems (one line each on stdout), 2 bad arguments.
set -u

usage() { echo "usage: $0 <PR number> | --body-file <file> --files <file> [--title <text>]"; exit 2; }

body_file="" files_file="" title="" pr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) [ $# -ge 2 ] || usage; body_file=$2; shift 2 ;;
    --files)     [ $# -ge 2 ] || usage; files_file=$2; shift 2 ;;
    --title)     [ $# -ge 2 ] || usage; title=$2; shift 2 ;;
    -*)          usage ;;
    *)           [ -z "$pr" ] || usage; pr=$1; shift ;;
  esac
done

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

if [ -n "$pr" ]; then
  [ -z "$body_file$files_file" ] || usage
  case "$pr" in *[!0-9]*) usage ;; esac
  gh pr view "$pr" --json body -q .body > "$tmp/body" || { echo "cannot fetch PR $pr body"; exit 2; }
  gh pr view "$pr" --json files -q '.files[].path' > "$tmp/files" || { echo "cannot fetch PR $pr files"; exit 2; }
  title=$(gh pr view "$pr" --json title -q .title) || { echo "cannot fetch PR $pr title"; exit 2; }
  body_file=$tmp/body
  files_file=$tmp/files
else
  [ -n "$body_file" ] && [ -n "$files_file" ] && [ -r "$body_file" ] && [ -r "$files_file" ] || usage
fi

in_scope=0
while IFS= read -r f || [ -n "$f" ]; do
  f=${f%$'\r'}
  case "$f" in lib/*|web/*|apps/*|priv/*|test/*) in_scope=1 ;; esac
done < "$files_file"
if [ "$in_scope" = 0 ]; then
  echo "ok: no change under lib/ web/ apps/ priv/ test/ (Gates block not required)"
  exit 0
fi

problems=0
bad() { echo "PROBLEM: $1"; problems=$((problems + 1)); }

# Gates block = from `## Gates` to the next `## ` heading. body_lines = the whole body.
block=() body_lines=() have_block=0 collecting=0
while IFS= read -r l || [ -n "$l" ]; do
  l=${l%$'\r'}
  body_lines+=("$l")
  if [[ $l =~ ^##[[:space:]]+Gates[[:space:]]*$ ]]; then have_block=1; collecting=1; continue; fi
  if [ "$collecting" = 1 ] && [[ $l =~ ^##[[:space:]] ]]; then collecting=0; fi
  if [ "$collecting" = 1 ]; then block+=("$l"); fi
done < "$body_file"

check_verdict() { # $1 label, $2 text after "NAME:"
  local label=$1 rest=$2
  rest=${rest#"${rest%%[![:space:]]*}"}
  if [[ $rest =~ ^N/A[[:space:]]+\(.+\) ]]; then return 0; fi
  if [[ $rest =~ ^(PASS_WITH_FINDINGS|PASS|FAIL)([[:space:]]|$) ]]; then
    if [[ $rest =~ evidence:[[:space:]]*(\.\.?/|[A-Za-z0-9_/]) ]]; then return 0; fi
    bad "$label: verdict without 'evidence:' citation"
    return 1
  fi
  bad "$label: verdict not in {PASS, PASS_WITH_FINDINGS, FAIL, N/A (<reason>)}"
  return 1
}

find_line() { # $1 role name -> prints the rest of the first "- NAME:" line; status 1 if absent
  local l
  for l in ${block[@]+"${block[@]}"}; do
    if [[ $l =~ ^-[[:space:]]+$1:[[:space:]]*(.*)$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  done
  return 1
}

if [ "$have_block" = 0 ]; then
  bad "no '## Gates' section in the PR body"
else
  tier=""
  for l in ${block[@]+"${block[@]}"}; do
    if [[ $l =~ ^Tier:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then tier=${BASH_REMATCH[1]}; fi
  done
  case "$tier" in
    FULL|SHORT|DIRECT|HIGH) ;;
    "") bad "Tier: line missing" ;;
    *)  bad "Tier: must be one of FULL|SHORT|DIRECT|HIGH (got '$tier')" ;;
  esac

  for role in CODE-DESIGN-VALIDATOR SECURITY-REVIEWER REVIEWER TEST-DESIGN-VALIDATOR; do
    if rest=$(find_line "$role"); then check_verdict "$role" "$rest"; else bad "$role: gate line missing"; fi
  done

  if rest=$(find_line "CI"); then
    if ! [[ $rest =~ https?://[^[:space:]]+[[:space:]]+(success|failure|neutral|cancelled|skipped|timed_out|action_required)([[:space:]]|$) ]]; then
      bad "CI: needs '<run URL> <conclusion>' (success|failure|neutral|cancelled|skipped|timed_out|action_required)"
    fi
  else
    bad "CI: line missing"
  fi

  if [ "$tier" = HIGH ]; then
    if rest=$(find_line "Outside review"); then check_verdict "Outside review" "${rest#* }"; else bad "Outside review: line required when Tier is HIGH"; fi
  fi
fi

case "$title" in
  [Ff][Ii][Xx]*)
    intro="" missed=""
    for l in ${body_lines[@]+"${body_lines[@]}"}; do
      if [[ $l =~ ^Introduced-by:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then intro=${BASH_REMATCH[1]}; fi
      if [[ $l =~ ^Missed-by:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then missed=${BASH_REMATCH[1]}; fi
    done
    if [ -z "$intro" ]; then
      bad "fix PR: Introduced-by: line missing (R4)"
    elif ! [[ $intro =~ ^(#[0-9]+|[0-9a-f]{7,40}|unknown)$ ]]; then
      bad "fix PR: Introduced-by must be '#<PR> | <sha> | unknown' (got '$intro')"
    fi
    missed_ok='^(CODE-DESIGN-VALIDATOR|SECURITY-REVIEWER|REVIEWER|TEST-DESIGN-VALIDATOR|RELEASE-VALIDATOR|REQ-VALIDATOR|CI|unknown|none \(not catchable before merge\))$'
    if [ -z "$missed" ]; then
      bad "fix PR: Missed-by: line missing (R4)"
    elif ! [[ $missed =~ $missed_ok ]]; then
      bad "fix PR: Missed-by must be '<gate role> | CI | none (not catchable before merge) | unknown' (got '$missed')"
    fi
    ;;
esac

if [ "$problems" -gt 0 ]; then exit 1; fi
echo "ok: Gates block valid"
exit 0
