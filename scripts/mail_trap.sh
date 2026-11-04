#!/usr/bin/env bash
# mail_trap.sh - read UAT mail through the QA mail trap (Mailpit), never a human mailbox.
#
# Usage:
#   scripts/mail_trap.sh purge                     delete every message in the trap (run before a scenario)
#   scripts/mail_trap.sh wait ADDR [SECONDS]       wait for a mail to ADDR (default 60 s), print its link
#   scripts/mail_trap.sh subject ADDR [SECONDS]    same wait, print the subject instead
#
# ADDR must end in @uat.letflow.internal (the trap's test domain; it does not resolve). The link
# printed is the first http(s) URL of the newest mail's text body, preferring a Keycloak action
# link (invite / verify e-mail / reset password). Exit codes: 0 ok, 1 timeout or no link,
# 2 usage or refused address, 3 trap unreachable.
#
# Environment:
#   MAIL_TRAP_URL   trap HTTP API, default http://127.0.0.1:8025 (off-host: open the ssh tunnel
#                   `ssh -N -L 8025:127.0.0.1:8025 ubuntu-16gb-nbg1-1` first)
#   CURL            curl binary override (tests use it)
#
# Realms wired to the trap by infra: see docs/testing/uat-mail-trap.md. A scenario for a realm that
# is not wired yet is reported as waiting for infra, not run against a human mailbox.
set -euo pipefail

base="${MAIL_TRAP_URL:-http://127.0.0.1:8025}"
curl_bin="${CURL:-curl}"
domain="uat.letflow.internal"

usage() { echo "usage: mail_trap.sh purge | wait ADDR [SECONDS] | subject ADDR [SECONDS]" >&2; exit 2; }

api() { # api METHOD PATH [curl args]
  local method="$1" path="$2"; shift 2
  $curl_bin -sS --max-time 10 -X "$method" "$@" "$base$path" || { echo "mail trap unreachable at $base" >&2; exit 3; }
}

check_addr() {
  case "$1" in
    *[!A-Za-z0-9._+@-]*|"") echo "refused address: $1" >&2; exit 2 ;;
    *@"$domain") ;;
    *) echo "refused address (must end in @$domain): $1" >&2; exit 2 ;;
  esac
}

# newest message id for ADDR, empty when none
newest_id() {
  api GET "/api/v1/search?query=to:$1&limit=1" | python3 -I -c '
import sys, json
m = json.load(sys.stdin).get("messages") or []
print(m[0]["ID"] if m else "")'
}

cmd="${1:-}"
case "$cmd" in
  purge)
    api DELETE /api/v1/messages >/dev/null
    echo "mail trap purged"
    ;;
  wait|subject)
    addr="${2:-}"; timeout="${3:-60}"
    [ -n "$addr" ] || usage
    check_addr "$addr"
    case "$timeout" in *[!0-9]*|"") usage ;; esac
    deadline=$((SECONDS + timeout))
    id=""
    while :; do
      id="$(newest_id "$addr")"
      [ -n "$id" ] && break
      if [ "$SECONDS" -ge "$deadline" ]; then echo "no mail to $addr within ${timeout}s" >&2; exit 1; fi
      sleep 2
    done
    api GET "/api/v1/message/$id" | python3 -I -c '
import sys, json, re
mode = sys.argv[1]
m = json.load(sys.stdin)
if mode == "subject":
    print(m.get("Subject", ""))
    sys.exit(0)
text = m.get("Text") or ""
urls = re.findall(r"https?://[^\s<>\")]+", text)
if not urls:
    urls = re.findall(r"https?://[^\s<>\")]+", (m.get("HTML") or "").replace("&amp;", "&"))
if not urls:
    sys.stderr.write("mail has no link\n"); sys.exit(1)
pref = [u for u in urls if "action-token" in u or "login-actions" in u or "execute-actions" in u]
print((pref or urls)[0])' "$cmd"
    ;;
  *) usage ;;
esac
