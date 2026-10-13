#!/usr/bin/env bash
# gh_work.sh -- read-only view of the GitHub work board (ISS-1073 / GH #2430).
#
# The board is defined in docs/agents/protocols/WORK_BOARD.md. This script only
# READS (gh api GET); it never labels, comments, assigns, closes or creates. The
# supervisor (or the user) is the only one who changes claim state, by hand.
#
# Usage:
#   scripts/gh_work.sh ready  [--for CHECKOUT]   open, state:ready, unclaimed, every
#                                                'Depends on:' issue closed; ordered
#                                                prio asc, then issue number asc
#   scripts/gh_work.sh claims                    every open issue that is in progress
#                                                or carries a claimed:* label, with
#                                                last activity and linked open PRs
#   scripts/gh_work.sh stale  [--hours N]        claims with no PR and no activity for
#                                                more than N hours (default 4)
#   scripts/gh_work.sh graph                     'Depends on:' edges between open
#                                                issues, plus cycles and blocked ones
#   scripts/gh_work.sh check                     board-script check: exit 1 on a label
#                                                violation, including a claimed:<checkout>
#                                                label the supervisor/user did not set
#
# Environment:
#   GH_REPO        owner/name (default: tvolodi/letflow)
#   GH_BIN         the gh executable (default: gh; tests point it at a stub)
#   GH_WORK_NOW    epoch seconds to use as "now" (tests only)
#   STALE_HOURS    default for `stale --hours` (default 4)
#
# Pagination: every list call walks ?page=1,2,... at per_page=100 until a short
# page, so a board of more than 100 open issues is read completely (the queue's
# 100-issue cap was failure class F8 of the replacement study).
#
# Requires: gh (authenticated) and jq.

set -euo pipefail

REPO="${GH_REPO:-tvolodi/letflow}"
STALE_HOURS="${STALE_HOURS:-4}"
CHECKOUTS="letflow letflow-2 letflow-3 letflow-4 remote"
MAX_PAGES=100

die() { echo "gh_work.sh: $*" >&2; exit 2; }

GH_BIN="${GH_BIN:-gh}"
command -v "$GH_BIN" >/dev/null 2>&1 || die "$GH_BIN not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

# jq.exe (Windows Git Bash) writes CRLF; strip CR so TSV fields and `read` loops
# behave the same everywhere. pipefail (above) keeps a jq failure fatal.
jq() { command jq "$@" | tr -d '\r'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# paged ENDPOINT -> prints one JSON array holding every page's items.
paged() {
  local endpoint="$1" sep="?" page=1 n body
  case "$endpoint" in *\?*) sep="&" ;; esac
  : >"$TMP/pages"
  while :; do
    [ "$page" -le "$MAX_PAGES" ] || die "refusing to read more than $MAX_PAGES pages of $endpoint"
    body="$("$GH_BIN" api "${endpoint}${sep}per_page=100&page=${page}")" || die "gh api failed for $endpoint page $page"
    n="$(printf '%s' "$body" | jq 'if type == "array" then length else error("expected an array") end')" \
      || die "unexpected response for $endpoint page $page"
    printf '%s\n' "$body" >>"$TMP/pages"
    [ "$n" -ge 100 ] || break
    page=$((page + 1))
  done
  jq -s 'add // []' "$TMP/pages"
}

# Open issues (pull requests are excluded: the issues API returns both).
load_issues() {
  paged "repos/${REPO}/issues?state=open" \
    | jq 'map(select(has("pull_request") | not)
              | {number, title, updated_at, body: (.body // ""),
                 labels: [.labels[].name]})'
}

load_prs() {
  paged "repos/${REPO}/pulls?state=open" \
    | jq 'map({number, title, updated_at, body: (.body // "")})'
}

# jq prelude shared by every subcommand.
read -r -d '' PRELUDE <<'JQ' || true
def lab($p): [.labels[] | select(startswith($p))];
def val($p): lab($p) | map(.[($p | length):]);
def deps: (.body | gsub("\r"; ""))
          | [match("^[ \\t]*depends on:(.*)$"; "gi").captures[0].string
             | scan("#([0-9]+)") | .[0] | tonumber] | unique;
def prio: (val("prio:") | map(tonumber? // 9) | min) // 9;
def iso: fromdateiso8601;
JQ

cmd="${1:-}"
[ -n "$cmd" ] || die "usage: gh_work.sh ready|claims|stale|graph|check (see header)"
shift || true

case "$cmd" in
  ready)
    for_checkout=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --for) for_checkout="${2:-}"; shift 2 ;;
        *) die "unknown option for ready: $1" ;;
      esac
    done
    if [ -n "$for_checkout" ]; then
      case " $CHECKOUTS " in *" $for_checkout "*) ;; *) die "--for must be one of: $CHECKOUTS" ;; esac
    fi
    load_issues | jq -r --arg for "$for_checkout" "$PRELUDE"'
      . as $all
      | ($all | map(.number)) as $open
      | $all
      | map(select(.labels | index("state:ready")))
      | map(select((lab("claimed:") | length) == 0))
      | map(select(($for == "") or (.labels | index("next:" + $for))))
      | map(select(((deps) - ((deps) - $open) | length) == 0))
      | sort_by([prio, .number])
      | (["#", "prio", "type", "stage", "lane", "next", "title"] | @tsv),
        (.[] | [("#" + (.number | tostring)),
                (prio | tostring),
                (val("type:") | join(",")),
                (val("stage:") | join(",")),
                (val("lane:") | join(",")),
                (val("next:") | join(",")),
                .title] | @tsv)'
    ;;

  claims|stale)
    hours="$STALE_HOURS"
    if [ "$cmd" = "stale" ]; then
      while [ $# -gt 0 ]; do
        case "$1" in
          --hours) hours="${2:-}"; shift 2 ;;
          *) die "unknown option for stale: $1" ;;
        esac
      done
      case "$hours" in ''|*[!0-9]*) die "--hours must be a whole number" ;; esac
    fi
    now="${GH_WORK_NOW:-$(date -u +%s)}"
    load_prs >"$TMP/prs.json"
    load_issues | jq -r --argjson now "$now" --argjson hours "$hours" \
      --arg mode "$cmd" --slurpfile prs "$TMP/prs.json" "$PRELUDE"'
      def linked($n): $prs[0] | map(select((.title + " " + .body) | test("#" + ($n | tostring) + "([^0-9]|$)")));
      map(select((.labels | index("state:in-progress")) or (lab("claimed:") | length) > 0))
      | map(. as $i
            | linked($i.number) as $pr
            | ([$i.updated_at] + ($pr | map(.updated_at)) | map(iso) | max) as $last
            | {number: $i.number,
               claimed: (val("claimed:") | join(",") | if . == "" then "UNCLAIMED" else . end),
               state: (val("state:") | join(",")),
               prs: ($pr | map("#" + (.number | tostring)) | join(",") | if . == "" then "-" else . end),
               age_h: ((($now - $last) / 3600) | floor),
               title: $i.title})
      | (if $mode == "stale" then map(select(.age_h >= $hours and .prs == "-")) else . end)
      | sort_by(.number)
      | (["#", "claimed", "state", "open PR", "idle h", "title"] | @tsv),
        (.[] | [("#" + (.number | tostring)), .claimed, .state, .prs, (.age_h | tostring), .title] | @tsv)'
    ;;

  graph)
    load_issues | jq -r "$PRELUDE"'
      . as $all
      | ($all | map(.number)) as $open
      | ($all | map({key: (.number | tostring), value: (deps)}) | from_entries) as $d
      # Kahn-style peel: repeatedly drop issues whose open dependencies are all dropped.
      | ($open | map(tostring)) as $nodes
      | ({rest: $nodes}
         | until((.rest | length) == 0 or .done;
                 . as $s
                 | ($s.rest | map(select(. as $k | ($d[$k] // []) | map(tostring)
                                          | all(. as $x | ($s.rest | index($x)) == null)))) as $free
                 | if ($free | length) == 0 then .done = true
                   else .rest = ($s.rest - $free) end)
         | .rest) as $cyclic
      | ($all | sort_by(.number)[]
         | select((deps | length) > 0)
         | . as $i
         | (deps[] | . as $t
            | "#\($i.number) depends on #\($t)  [" + (if ($open | index($t)) then "open" else "closed-or-absent" end) + "]")),
        (if ($cyclic | length) > 0
         then "CYCLE among: " + ($cyclic | map("#" + .) | join(" "))
         else "no cycles" end)'
    ;;

  check)
    load_issues >"$TMP/issues.json"
    violations=0
    # Static label rules (no per-issue calls).
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      echo "VIOLATION: $line"
      violations=$((violations + 1))
    done < <(jq -r --arg checkouts "$CHECKOUTS" "$PRELUDE"'
      ($checkouts | split(" ")) as $ok
      | .[]
      | . as $i
      | (val("state:")) as $state
      | (val("claimed:")) as $claimed
      | (val("next:")) as $next
      | (if ($state | length) > 1 then "#\($i.number): more than one state: label (\($state | join(",")))" else empty end),
        (if ($claimed | length) > 1 then "#\($i.number): more than one claimed: label (\($claimed | join(",")))" else empty end),
        (if ($next | length) > 1 then "#\($i.number): more than one next: label (\($next | join(",")))" else empty end),
        ($claimed[] | select(. as $c | $ok | index($c) | not)
           | "#\($i.number): claimed:\(.) is not a checkout (\($ok | join(", ")))"),
        ($next[] | select(. as $c | $ok | index($c) | not)
           | "#\($i.number): next:\(.) is not a checkout (\($ok | join(", ")))"),
        (if ($claimed | length) > 0 and ($state | index("in-progress") | not)
         then "#\($i.number): claimed:\($claimed | join(",")) without state:in-progress" else empty end),
        (if ($state | index("in-progress")) and ($claimed | length) == 0
         then "#\($i.number): state:in-progress without a claimed:<checkout> label" else empty end)
    ' "$TMP/issues.json")
    # Provenance rule: every claimed:<checkout> label must be backed by the
    # supervisor's (or the user's) claim comment for the SAME checkout, and no
    # later claim comment may name another checkout. All sessions share one
    # GitHub login, so the label's actor cannot prove who set it; the comment is
    # the recorded act (WORK_BOARD.md "Claim record").
    while IFS=$'\t' read -r number checkout; do
      [ -n "$number" ] || continue
      comments="$(paged "repos/${REPO}/issues/${number}/comments")"
      last="$(printf '%s' "$comments" | jq -r '
        [ .[] | (.body // "") | gsub("\r"; "")
          | match("^CLAIM (letflow(-[234])?|remote) by (supervisor|user)\\b"; "gm").captures[0].string ]
        | last // ""')"
      if [ -z "$last" ]; then
        echo "VIOLATION: #${number}: claimed:${checkout} has no 'CLAIM ${checkout} by supervisor|user' comment (set by someone else?)"
        violations=$((violations + 1))
      elif [ "$last" != "$checkout" ]; then
        echo "VIOLATION: #${number}: claimed:${checkout} but the latest claim comment names ${last}"
        violations=$((violations + 1))
      fi
    done < <(jq -r '.[] | . as $i | .labels[] | select(startswith("claimed:"))
                    | [$i.number, .[8:]] | @tsv' "$TMP/issues.json")
    if [ "$violations" -gt 0 ]; then
      echo "gh_work.sh check: FAILED -- ${violations} violation(s)"
      exit 1
    fi
    echo "gh_work.sh check: OK -- no label violations on $(jq 'length' "$TMP/issues.json") open issue(s)"
    ;;

  *)
    die "unknown subcommand '$cmd' (ready|claims|stale|graph|check)"
    ;;
esac
