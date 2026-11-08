#!/usr/bin/env bash
# demo_upgrade_check.sh -- smoke test: did the module upgrade chain keep the showroom demo data? (T-1471, D-108)
#
#   demo_upgrade_check.sh snapshot FILE   BEFORE promote: write a fingerprint of the tenant to FILE
#   demo_upgrade_check.sh verify   FILE   AFTER promote:  read the tenant again, compare with FILE, check the chain is complete
#
# HTTP only (the tenant's own API, read routes plus the read-only upgrade plan route); it never calls the apply
# route (promote-demo.sh does the upgrade) and never writes a record. See docs/runbooks/demo-upgrade-notes.md.
#
# Fingerprint (counts and checksums, no record content is printed; the FILE holds only names, counts, checksums):
#   installed modules (ids), the records of every active entity type (count and checksum of id + field values),
#   stock documents, counts, balances, movements (count and checksum of every row), the Inv-10 print of the first
#   count (HTTP 200 and %PDF). Module versions and manifest hashes are NOT compared: an upgrade changes them.
# verify also asks for the upgrade plan of every installed module: "up_to_date" means the chain is complete.
#
# Inputs (environment only, same as demo_showroom_seed.sh; the stock routes answer 404 to an API token):
#   BASE_URL, TENANT_SLUG (default "showroom"), ACCESS_TOKEN or ADMIN_USERNAME + ADMIN_PASSWORD + ADMIN_REALM
#   (BPM_IDP_BASE_URL, BPM_IDP_CLIENT_ID).
# Exit codes: 0 all equal and no upgrade pending; 1 a difference (the check, before and after, is printed);
#   2 a missing tool or a bad input (nothing was requested); 3 data equal but an upgrade is still pending
#   (a module needs an administrator, see the notes); 4 a request failed (cannot judge).
# Safety: the token goes through a 0600 config file in a 0700 temporary directory removed on exit; password on stdin;
# nothing secret is printed; xtrace is never on. Needs: bash, curl, jq, cksum, date, mktemp.
set -euo pipefail
set +x

fail_input() { printf 'input error: %s\n' "$*" >&2; exit 2; }
for tool in curl jq cksum date mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail_input "missing tool: $tool"
done
MODE="${1:-}"
FILE="${2:-}"
case "$MODE" in snapshot | verify) ;; *) fail_input "usage: demo_upgrade_check.sh snapshot|verify FILE" ;; esac
[ -n "$FILE" ] || fail_input "usage: demo_upgrade_check.sh snapshot|verify FILE"
if [ "$MODE" = verify ]; then [ -r "$FILE" ] || fail_input "cannot read $FILE"; fi
[ -n "${BASE_URL:-}" ] || fail_input "set BASE_URL, for example https://demo.example.org"
TENANT_SLUG="${TENANT_SLUG:-showroom}"
[[ "$TENANT_SLUG" =~ ^[A-Za-z0-9_-]{1,63}$ ]] || fail_input "TENANT_SLUG has unexpected characters"
if [ -z "${ACCESS_TOKEN:-}" ]; then
  [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ] && [ -n "${ADMIN_REALM:-}" ] \
    || fail_input "no sign-in: set ACCESS_TOKEN, or ADMIN_USERNAME, ADMIN_PASSWORD and ADMIN_REALM"
fi
[[ -z "${ADMIN_USERNAME:-}" || "${ADMIN_USERNAME:-}" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail_input "ADMIN_USERNAME has unexpected characters"
[[ "${ADMIN_REALM:-x}" =~ ^[A-Za-z0-9_.-]+$ ]] || fail_input "realm has unexpected characters"

API="${BASE_URL%/}/api/v1"
IDP="${BPM_IDP_BASE_URL:-https://auth.example.org}"
CLIENT_ID="${BPM_IDP_CLIENT_ID:-letflow-web}"
MAX_PAGES=200

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
AUTH_CFG="$WORK/auth.cfg"
RESP="$WORK/resp.json"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 4; }

get_token() { # user password realm (password grant, same as the seed script)
  local user="$1" pw="$2" realm="$3" resp token
  resp=$(curl -s --max-time 30 --config - "$IDP/realms/$realm/protocol/openid-connect/token" <<EOF
data-urlencode = "password=$pw"
data = "grant_type=password"
data-urlencode = "client_id=$CLIENT_ID"
data-urlencode = "username=$user"
EOF
  ) || die "token request failed (network)"
  token=$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null || true)
  [ -n "$token" ] || die "no access token for $user (wrong password or realm?)"
  printf '%s' "$token"
}

{
  umask 077
  if [ -n "${ACCESS_TOKEN:-}" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" >"$AUTH_CFG"
  else
    tok=$(get_token "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "$ADMIN_REALM")
    printf 'header = "Authorization: Bearer %s"\n' "$tok" >"$AUTH_CFG"; unset tok
  fi
}

STATUS=""
api() { # METHOD PATH [BODY] -> answer in $RESP, status in $STATUS
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    STATUS=$(printf '%s' "$body" | curl -sS --max-time 120 -o "$RESP" -w '%{http_code}' -K "$AUTH_CFG" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      -H "X-Tenant-Slug: $TENANT_SLUG" -X "$method" --data-binary @- "$API$path") || STATUS="000"
  else
    STATUS=$(curl -sS --max-time 120 -o "$RESP" -w '%{http_code}' -K "$AUTH_CFG" \
      -H 'Accept: application/json' -H "X-Tenant-Slug: $TENANT_SLUG" -X "$method" "$API$path") || STATUS="000"
  fi
}

sum_of() { cksum | awk '{print $1 "-" $2}'; }  # stdin -> "crc-bytes"

# ROWS_FILE receives one canonical JSON row per line, sorted; returns 0, 1 when the route did not answer 200.
# paged_get GET PATH ROWS_JQ  (cursor in the query string)    paged_query ENTITY_TYPE (cursor in the body)
paged_get() {
  local path="$1" rows_jq="$2" out="$3" cursor="" q n=0
  : >"$out.raw"
  while :; do
    q="$path"
    [ -z "$cursor" ] || { case "$q" in *\?*) q="$q&cursor=$cursor" ;; *) q="$q?cursor=$cursor" ;; esac; }
    api GET "$q"
    [ "$STATUS" = 200 ] || return 1
    jq -S -c "$rows_jq" "$RESP" >>"$out.raw"
    cursor=$(jq -r '.next_cursor // empty' "$RESP")
    n=$((n + 1))
    [ -n "$cursor" ] || break
    [ "$n" -lt "$MAX_PAGES" ] || die "more than $MAX_PAGES pages of $path"
  done
  sort "$out.raw" >"$out"
}

paged_query() {
  local type="$1" out="$2" cursor="" body n=0
  : >"$out.raw"
  while :; do
    body=$(jq -nc --arg t "$type" --arg c "$cursor" \
      '{entity_type:$t, page_size:100} + (if $c == "" then {} else {cursor:$c} end)')
    api POST /entities/query "$body"
    [ "$STATUS" = 200 ] || return 1
    jq -S -c '.items[] | {record_id, field_values}' "$RESP" >>"$out.raw"
    cursor=$(jq -r '.next_cursor // empty' "$RESP")
    n=$((n + 1))
    [ -n "$cursor" ] || break
    [ "$n" -lt "$MAX_PAGES" ] || die "more than $MAX_PAGES pages of $type"
  done
  sort "$out.raw" >"$out"
}

# put NAME VALUE -> one line "name<TAB>value" in $WORK/fp.tsv
put() { printf '%s\t%s\n' "$1" "$2" >>"$WORK/fp.tsv"; }
put_rows() { # NAME ROWS_FILE
  put "$1" "$(wc -l <"$2" | tr -d ' ') rows, sum $(sum_of <"$2")"
}

modules_installed() {
  api GET /me/modules
  [ "$STATUS" = 200 ] || die "GET /me/modules: HTTP $STATUS (tenant '$TENANT_SLUG' not found, or not signed in)"
  jq -r '.installed_modules[].module_id' "$RESP" | sort
}

fingerprint() {
  : >"$WORK/fp.tsv"
  local mods types t f first_count
  mods=$(modules_installed)
  put "modules" "$(printf '%s' "$mods" | tr '\n' ',')"

  # records of every active entity type
  : >"$WORK/types.txt"
  local cursor="" n=0
  while :; do
    if [ -z "$cursor" ]; then api GET "/entities/definitions?page_size=100"; else api GET "/entities/definitions?page_size=100&cursor=$cursor"; fi
    [ "$STATUS" = 200 ] || die "GET /entities/definitions: HTTP $STATUS"
    jq -r '.items[] | select(.status == "active") | .name' "$RESP" >>"$WORK/types.txt"
    cursor=$(jq -r '.next_cursor // empty' "$RESP"); n=$((n + 1))
    [ -n "$cursor" ] || break
    [ "$n" -lt "$MAX_PAGES" ] || die "more than $MAX_PAGES pages of definitions"
  done
  types=$(sort -u "$WORK/types.txt")
  while read -r t; do
    [ -n "$t" ] || continue
    f="$WORK/rec.$t"
    if paged_query "$t" "$f"; then put_rows "records:$t" "$f"; else put "records:$t" "not readable (HTTP $STATUS)"; fi
  done <<<"$types"

  # stock: documents, counts, balances, movements (the screens read the same routes)
  if printf '%s\n' "$mods" | grep -qx stock; then
    local SM=/modules/stock
    paged_get "$SM/documents?limit=100" '.rows[]' "$WORK/docs" || die "GET $SM/documents: HTTP $STATUS"
    put_rows "stock documents" "$WORK/docs"
    paged_get "$SM/counts?limit=100" '.rows[]' "$WORK/counts" || die "GET $SM/counts: HTTP $STATUS"
    put_rows "stock counts" "$WORK/counts"
    paged_get "$SM/balances?limit=100" '.rows[]' "$WORK/bal" || die "GET $SM/balances: HTTP $STATUS"
    put_rows "stock balances" "$WORK/bal"
    paged_get "$SM/movements?limit=100" '.rows[]' "$WORK/mov" || die "GET $SM/movements: HTTP $STATUS"
    put_rows "stock movements" "$WORK/mov"
    # human-readable totals (floating point, for the log only; the equality above is exact)
    put "info:balance quantity total" "$(jq -s '[.[] | (.quantity // 0 | tonumber? // 0)] | add // 0' "$WORK/bal")"
    first_count=$(jq -r -s 'map(.id) | sort | .[0] // empty' "$WORK/counts")
    if [ -n "$first_count" ]; then
      api GET "$SM/counts/$first_count/print/sheet?form=inv10&lang=ru&format=pdf"
      if [ "$STATUS" = 200 ] && head -c 4 "$RESP" | grep -q '%PDF'; then put "print inv10" "200 pdf"; else put "print inv10" "HTTP $STATUS"; fi
    else
      put "print inv10" "no count"
    fi
  fi
}

fp_json() { # fp.tsv -> {"name": "value"}
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add // {}' "$WORK/fp.tsv"
}

pending_modules() { # prints "module: reason" lines for every installed module whose plan is not up_to_date
  local m mods
  mods=$(modules_installed)
  while read -r m; do
    [ -n "$m" ] || continue
    api POST "/tenant/modules/$m/upgrade/plan" '{}'
    if [ "$STATUS" != 200 ]; then printf '%s: plan answered HTTP %s\n' "$m" "$STATUS"; continue; fi
    if [ "$(jq -r '.up_to_date' "$RESP")" != true ]; then
      printf '%s: pending %s -> %s (path available: %s, steps: %s)\n' "$m" "$(jq -r '.from_version' "$RESP")" \
        "$(jq -r '.to_version' "$RESP")" "$(jq -r '.upgrade_path_available' "$RESP")" "$(jq -r '.steps | length' "$RESP")"
    fi
  done <<<"$mods"
}

case "$MODE" in
  snapshot)
    fingerprint
    { fp_json | jq -S --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg slug "$TENANT_SLUG" \
        '{format:"demo-upgrade-check/v1", tenant:$slug, taken_at:$at, checks:.}'; } >"$FILE"
    log "snapshot written to $FILE: $(jq -r '.checks | length' "$FILE") checks"
    jq -r '.checks | to_entries[] | "  \(.key): \(.value)"' "$FILE" >&2
    ;;
  verify)
    jq -e '.format == "demo-upgrade-check/v1" and (.checks | type == "object")' "$FILE" >/dev/null 2>&1 \
      || fail_input "$FILE is not a snapshot of this script"
    [ "$(jq -r '.tenant' "$FILE")" = "$TENANT_SLUG" ] || fail_input "the snapshot is of tenant '$(jq -r '.tenant' "$FILE")', not '$TENANT_SLUG'"
    fingerprint
    fp_json >"$WORK/after.json"
    differ=0
    while IFS= read -r name; do
      before=$(jq -r --arg n "$name" '.checks[$n] // "(absent)"' "$FILE")
      after=$(jq -r --arg n "$name" '.[$n] // "(absent)"' "$WORK/after.json")
      if [[ "$name" == info:* ]]; then
        log "info  $name: $before -> $after"
      elif [ "$before" = "$after" ]; then
        log "equal $name: $after"
      else
        log "DIFF  $name: before [$before] after [$after]"; differ=1
      fi
    done < <( (jq -r '.checks | keys[]' "$FILE"; jq -r 'keys[]' "$WORK/after.json") | sort -u )
    pending=$(pending_modules)
    if [ -n "$pending" ]; then printf '%s\n' "$pending" | sed 's/^/pending /' >&2; fi
    if [ "$differ" = 1 ]; then log "RESULT: data differs from the snapshot"; exit 1; fi
    if [ -n "$pending" ]; then log "RESULT: data equal, but an upgrade is still pending (needs an administrator)"; exit 3; fi
    log "RESULT: data equal, upgrade chain complete"
    ;;
esac
