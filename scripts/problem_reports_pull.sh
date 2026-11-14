#!/usr/bin/env bash
# T-1948 (maintenance slice 1): the forwarder's tool of the problem-report handoff.
# See docs/runbooks/problem-report-handoff.md.
#
#   problem_reports_pull.sh pull            fetch the reports after the cursor, print one plain-text block each
#   problem_reports_pull.sh ack <n>         move the cursor to <n> (forward only)
#   problem_reports_pull.sh render <file>   print the blocks of a saved JSON answer (no network)
#
# Environment:
#   LETFLOW_URL                base URL of the backend (required for pull)
#   REPORT_EXPORT_TOKEN_FILE   default $HOME/.config/letflow/problem-report-export.token (mode 600 or 400)
#   REPORT_CURSOR_FILE         default $HOME/.local/state/letflow/problem-reports.cursor
#   REPORT_OUT_DIR             optional: write one SR-<n>.md per report instead of printing (fallback mode)
#
# The token is read from the file only, never printed, never on a command line.
# Exit codes: 0 ok, 1 HTTP or network failure, 2 usage or config error.

set +x
set -u
umask 077

TOKEN_FILE="${REPORT_EXPORT_TOKEN_FILE:-$HOME/.config/letflow/problem-report-export.token}"
CURSOR_FILE="${REPORT_CURSOR_FILE:-$HOME/.local/state/letflow/problem-reports.cursor}"

die() { # die <code> <message>
  echo "problem_reports_pull: $2" >&2
  exit "$1"
}

read_cursor() {
  local c=0
  if [ -f "$CURSOR_FILE" ]; then
    c="$(tr -d '[:space:]' <"$CURSOR_FILE")"
  fi
  case "$c" in
    '' | *[!0-9]*) c=0 ;;
  esac
  echo "$c"
}

# One report (a JSON object on stdin) as a plain-text block.
render_report() {
  local host="$1"
  jq -r --arg host "$host" '
    def j(a): (a // []) | join(", ");
    def v(a): (a // "-");
    "=== Letflow problem report \(.number) (\($host)) received \(.received_at) ===",
    "From: \(v(.reporter.name)) (user \(v(.reporter.user_id))), company \(v(.reporter.tenant_name)) (\(v(.reporter.tenant_id)))",
    "Roles: \(j(.reporter.roles))   Permissions: \((.reporter.permissions // []) | length)",
    "Screen: \(v(.context.route))   Language: \(v(.context.ui_language))   Browser: \(v(.context.browser.user_agent)) \(.context.browser.viewport // "")",
    "Server version: \(v(.server_version))   Report trace: \(v(.trace_id))",
    "Text:",
    .text,
    (if .context.crash then "Crash: \(v(.context.crash.name)): \(v(.context.crash.message))" else empty end),
    "Last actions: \((.context.actions // []) | map("\(v(.at)) \(.kind) \(.name)") | join("; "))",
    "Last requests:",
    ((.context.requests // [])[] | "  \(.method) \(v(.path)) -> \(v(.status)) trace=\(v(.trace_id)) code=\(v(.error_code))")
  '
}

# Blocks of a saved answer (file) to stdout, or one file per report in REPORT_OUT_DIR.
render_file() {
  local file="$1" host="$2" line number
  jq -e '.reports | arrays' "$file" >/dev/null 2>&1 || die 2 "not a report list: $file"
  if [ -n "${REPORT_OUT_DIR:-}" ]; then
    mkdir -p "$REPORT_OUT_DIR" || die 2 "cannot create REPORT_OUT_DIR"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -n "${REPORT_OUT_DIR:-}" ]; then
      number="$(printf '%s' "$line" | jq -j '.number' | tr -c 'A-Za-z0-9-' '_')"
      if [ ! -e "$REPORT_OUT_DIR/$number.md" ]; then
        (
          umask 027
          printf '%s' "$line" | render_report "$host" >"$REPORT_OUT_DIR/$number.md"
        )
      fi
    else
      printf '%s' "$line" | render_report "$host"
      echo
    fi
  done < <(jq -c '.reports[]' "$file")
  echo "NEXT_AFTER=$(jq -r '.next_after' "$file")"
}

host_of() {
  printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://##; s#[/:?].*$##'
}

cmd_pull() {
  [ -n "${LETFLOW_URL:-}" ] || die 2 "LETFLOW_URL is not set"
  [ -f "$TOKEN_FILE" ] || die 2 "token file not found: $TOKEN_FILE"
  local mode
  mode="$(stat -c %a "$TOKEN_FILE")"
  case "$mode" in
    600 | 400) ;;
    *) die 2 "token file $TOKEN_FILE must have mode 600 or 400 (found $mode)" ;;
  esac

  local cursor tmp status
  cursor="$(read_cursor)"
  tmp="$(mktemp -d)" || die 2 "mktemp failed"
  trap 'rm -rf "$tmp"' EXIT

  status="$(curl -sS --max-time 20 -o "$tmp/answer.json" -w '%{http_code}' \
    -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$TOKEN_FILE")") \
    "${LETFLOW_URL%/}/maintenance/v1/problem-reports?after=$cursor&limit=20")" ||
    die 1 "request failed (network error)"
  # Only the status is reported, never the response body.
  [ "$status" = "200" ] || die 1 "request failed (HTTP $status)"

  render_file "$tmp/answer.json" "$(host_of "$LETFLOW_URL")"
}

cmd_ack() {
  local n="${1:-}"
  case "$n" in
    '' | *[!0-9]*) die 2 "ack needs a non-negative integer" ;;
  esac
  local current
  current="$(read_cursor)"
  if [ "$n" -lt "$current" ]; then
    die 2 "ack $n is behind the cursor ($current); unchanged"
  fi
  if [ "$n" -gt "$current" ]; then
    mkdir -p "$(dirname "$CURSOR_FILE")" || die 2 "cannot create the cursor directory"
    printf '%s\n' "$n" >"$CURSOR_FILE"
  fi
  echo "cursor=$n"
}

cmd_render() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || die 2 "render needs an existing JSON file"
  render_file "$file" "${LETFLOW_URL:+$(host_of "$LETFLOW_URL")}"
}

case "${1:-}" in
  pull) cmd_pull ;;
  ack) shift; cmd_ack "${1:-}" ;;
  render) shift; cmd_render "${1:-}" ;;
  *) die 2 "usage: problem_reports_pull.sh pull | ack <n> | render <file.json>" ;;
esac
