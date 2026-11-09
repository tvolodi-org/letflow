#!/usr/bin/env bash
# perf_lines_seed.sh -- the fixed item set of the lines-editor performance run (web/tests/e2e/perf-lines.e2e.spec.ts, T-1533).
#
# Makes (idempotently, upsert by external ref through the import route) one unit of measure PERF-PCS and 190 catalog items
# PERF-0001..PERF-0190 (no lot tracking). The client item picker reads one page of 200 items and the GATE B masters take 4:
# more than 196 perf items would leave codes the editor cannot resolve (T-1533 finding). Run gate_b_seed.sh first: the
# stock module and the receipt's org unit / location come from it.
#
# Inputs (environment only): BASE_URL (API is $BASE_URL/api/v1), TENANT_SLUG, ADMIN_USERNAME, ADMIN_PASSWORD, ADMIN_REALM,
# BPM_IDP_BASE_URL, BPM_IDP_CLIENT_ID. The password goes to curl on stdin, the token through a 0600 config file.
# Needs: bash, curl, jq.
set -euo pipefail

: "${TENANT_SLUG:?set TENANT_SLUG to the slug of the test tenant}"
: "${BASE_URL:?set BASE_URL to the backend, for example http://127.0.0.1:4000}"
for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done

API="${BASE_URL%/}/api/v1"
IDP="${BPM_IDP_BASE_URL:-https://auth.qa.bizdala.com}"
CLIENT_ID="${BPM_IDP_CLIENT_ID:-letflow-web}"
EXT="perf-lines"
ITEMS="${PERF_ITEMS:-190}"

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
AUTH_CFG="$WORK/auth.cfg"
RESP="$WORK/resp.json"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }

user="${ADMIN_USERNAME:-}"; pw="${ADMIN_PASSWORD:-}"; realm="${ADMIN_REALM:-}"
[ -n "$user" ] && [ -n "$pw" ] && [ -n "$realm" ] || die "set ADMIN_USERNAME, ADMIN_PASSWORD, ADMIN_REALM"
[[ "$user" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "username has unexpected characters"
[[ "$realm" =~ ^[A-Za-z0-9_.-]+$ ]] || die "realm has unexpected characters"
resp=$(curl -s --max-time 30 --config - "$IDP/realms/$realm/protocol/openid-connect/token" <<EOF
data-urlencode = "password=$pw"
data = "grant_type=password"
data-urlencode = "client_id=$CLIENT_ID"
data-urlencode = "username=$user"
EOF
) || die "token request failed (network)"
tok=$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null || true)
[ -n "$tok" ] || die "no access token for $user (wrong password or realm?)"
( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$tok" >"$AUTH_CFG" )
unset tok pw

import_json() { # entity_type records-json label
  local body status
  body=$(jq -nc --arg t "$1" --argjson r "$2" \
    '{record_export_schema_version:"entities/record-export/v1", entity_type:$t, upsert_by:"external_ref", records:$r}')
  status=$(printf '%s' "$body" | curl -sS --max-time 120 -o "$RESP" -w '%{http_code}' -K "$AUTH_CFG" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' -H "X-Tenant-Slug: $TENANT_SLUG" \
    -X POST --data-binary @- "$API/entities/records/$1/import") || status="000"
  [ "$status" = 200 ] || die "$3: HTTP $status"
  if jq -e '[.results[] | select(.status != "ok")] | length > 0' "$RESP" >/dev/null; then
    die "$3: refused rows: $(jq -c '[.results[] | select(.status != "ok") | {line, reason: .reason.type, header: .reason.header}]' "$RESP")"
  fi
  log "ok   $3: $(jq -r '[.results[].outcome] | group_by(.) | map("\(.[0]) \(length)") | join(", ")' "$RESP")"
}

import_json catalog_uom "$(jq -nc --arg s "$EXT" \
  '[{external_ref:{system:$s, id:"PCS"}, field_values:{code:"PERF-PCS", name:"Piece", active:true}}]')" "unit PERF-PCS"

import_json catalog_item "$(jq -nc --arg s "$EXT" --argjson n "$ITEMS" \
  '[range(1; $n + 1) | ("PERF-" + (tostring | ("0000" + .)[-4:])) as $c
    | {external_ref:{system:$s, id:$c},
       field_values:{code:$c, name:("Perf item " + $c), base_uom_id:"PCS", kind:"material", active:true, tracking_policy:"none"}}]')" "$ITEMS perf items"

log "== done. Items PERF-0001..PERF-$(printf '%04d' "$ITEMS") (external ref system $EXT)."
