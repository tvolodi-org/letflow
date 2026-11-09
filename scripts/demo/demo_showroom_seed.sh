#!/usr/bin/env bash
# demo_showroom_seed.sh -- the showroom demo tenant (D-108): ONE tenant with invented, showroom-quality data.
#
# Every step goes through the tenant's own HTTP API (nothing is written to the database directly), so the
# script runs against any build, and it is safe to run again after every upgrade: a second run changes
# nothing, a run after a half-failed first run fills in what is missing. See docs/runbooks/demo-showroom.md.
#
# What the tenant ends up with (all names, numbers and BINs are invented; e-mails only @example.com):
#   modules org, locations, catalog_items, codes, stock (and assets when the build has it); a legal entity,
#   a site, org units, 5 employees; locations Kazakhstan > Almaty > Central warehouse > Rack 01, Rack 02, and
#   Showroom, Astana > Branch warehouse; 12 catalog items named in English, Russian and Kazakh (the catalog
#   has no photo field), lots of milk, scanner codes; stock documents of every kind, POSTED (receipts, issue,
#   transfer, hand over, return, write off, an opening balance); a stock count taken through to signed
#   differences (Inv-10 / Inv-18 forms print from it), left unposted; a second count left ordered;
#   asset cards with a commission, a hand over and a write off document.
#
# Inputs (environment only, nothing secret in this file):
#   BASE_URL         the instance, for example https://demo.example.org (the API is $BASE_URL/api/v1)   [required]
#   TENANT_SLUG      slug of the demo tenant, default "showroom"
#   DEMO_TAG         lowercase letters and digits, default "demo". All codes, external refs and idempotency keys
#                    derive from it: the same tag again = the same requests.
#   Sign-in of the tenant administrator (an interactive user; the stock routes answer 404 to an API token):
#     ACCESS_TOKEN                                   a ready bearer token, or
#     ADMIN_USERNAME + ADMIN_PASSWORD + ADMIN_REALM  password grant (BPM_IDP_BASE_URL, BPM_IDP_CLIENT_ID)
#     ADMIN_USERNAME is also needed with ACCESS_TOKEN: it is linked to the storekeeper employee (chair of the count).
#   Optional second administrator (the opening balance needs a second person to approve it):
#     ACCESS_TOKEN2 or ADMIN2_USERNAME + ADMIN2_PASSWORD (+ ADMIN2_REALM). Without it the opening stays issued.
#   Optional demo logins made by infra (usernames only, never passwords; each needs one sign-in first, otherwise skipped):
#     ADMIN_LOGIN_USERNAME  linked to DEMO-E005 (Aigerim Sadykova, Head office); USER_LOGIN_USERNAME to DEMO-E004
#     (Arman Kassymov, Sales team). demo-smoke is never linked.
#     Each linked login also gets open tasks (D-113): 3 and 2 stock receipts left issued, their post task addressed
#     to the login, never claimed or completed (needs the TENANT_ADMIN role of the seed administrator).
#   Optional tenant creation (platform administrator): PLATFORM_ACCESS_TOKEN + DEMO_REALM + DEMO_HOSTNAME.
#     Created through POST /api/v1/onboarding when TENANT_SLUG does not exist. The realm and the Keycloak
#     accounts are infra's job (D-016, D-018); this script never creates them.
#   SKIP_DOCS=1      masters, codes and assets cards only: no stock documents, no counts, no asset documents.
#
# Output: step names and record codes on stderr; at the end the demo logins WITHOUT passwords on stdout.
# Exit codes: 0 done, 1 a step failed ("STOP: ..."), 2 a missing tool or a bad input (before any request).
# Safety: passwords go to curl on stdin, tokens through a 0600 config file in a 0700 temporary directory that is
# removed on exit; nothing secret is printed; xtrace is never on. Needs: bash, curl, jq, date (GNU), cksum.
set -euo pipefail
set +x

# ---------------------------------------------------------------------------------------------
# inputs (checked before any request)
# ---------------------------------------------------------------------------------------------
fail_input() { printf 'input error: %s\n' "$*" >&2; exit 2; }
for tool in curl jq cksum date mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail_input "missing tool: $tool"
done
[ -n "${BASE_URL:-}" ] || fail_input "set BASE_URL, for example https://demo.example.org"
TENANT_SLUG="${TENANT_SLUG:-showroom}"
DEMO_TAG="${DEMO_TAG:-demo}"
[[ "$DEMO_TAG" =~ ^[a-z0-9]{1,20}$ ]] || fail_input "DEMO_TAG must be 1-20 lowercase letters or digits"
[[ "$TENANT_SLUG" =~ ^[A-Za-z0-9_-]{1,63}$ ]] || fail_input "TENANT_SLUG has unexpected characters"
if [ -z "${ACCESS_TOKEN:-}" ]; then
  [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ] && [ -n "${ADMIN_REALM:-}" ] \
    || fail_input "no sign-in: set ACCESS_TOKEN, or ADMIN_USERNAME, ADMIN_PASSWORD and ADMIN_REALM"
fi
ADMIN_USERNAME="${ADMIN_USERNAME:-}"
[[ -z "$ADMIN_USERNAME" || "$ADMIN_USERNAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail_input "ADMIN_USERNAME has unexpected characters"
ADMIN2_USERNAME="${ADMIN2_USERNAME:-}"
[[ -z "$ADMIN2_USERNAME" || "$ADMIN2_USERNAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail_input "ADMIN2_USERNAME has unexpected characters"
ADMIN_LOGIN_USERNAME="${ADMIN_LOGIN_USERNAME:-}"
[[ -z "$ADMIN_LOGIN_USERNAME" || "$ADMIN_LOGIN_USERNAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail_input "ADMIN_LOGIN_USERNAME has unexpected characters"
USER_LOGIN_USERNAME="${USER_LOGIN_USERNAME:-}"
[[ -z "$USER_LOGIN_USERNAME" || "$USER_LOGIN_USERNAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail_input "USER_LOGIN_USERNAME has unexpected characters"
for _v in ADMIN_LOGIN_USERNAME USER_LOGIN_USERNAME; do   # a user belongs to one employee
  [ -z "${!_v}" ] || { [ "${!_v}" != "$ADMIN_USERNAME" ] && [ "${!_v}" != "$ADMIN2_USERNAME" ]; } \
    || fail_input "$_v must not equal ADMIN_USERNAME or ADMIN2_USERNAME (a user belongs to one employee)"
done
[ -z "$ADMIN_LOGIN_USERNAME" ] || [ "$ADMIN_LOGIN_USERNAME" != "$USER_LOGIN_USERNAME" ] \
  || fail_input "ADMIN_LOGIN_USERNAME and USER_LOGIN_USERNAME must differ"
[[ "${ADMIN_REALM:-x}" =~ ^[A-Za-z0-9_.-]+$ && "${ADMIN2_REALM:-x}" =~ ^[A-Za-z0-9_.-]+$ ]] || fail_input "realm has unexpected characters"

API="${BASE_URL%/}/api/v1"
IDP="${BPM_IDP_BASE_URL:-https://auth.example.org}"
CLIENT_ID="${BPM_IDP_CLIENT_ID:-letflow-web}"
EXT="demo-${DEMO_TAG}"
TAG="${DEMO_TAG^^}"
TAG_NUM=$(printf '%s' "$DEMO_TAG" | cksum | cut -d' ' -f1)

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
AUTH_CFG="$WORK/auth.cfg"
AUTH2_CFG="$WORK/auth2.cfg"
PLAT_CFG="$WORK/plat.cfg"
AUTH_USE="$AUTH_CFG"
RESP="$WORK/resp.json"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }

get_token() { # user password realm (password grant, same as the e2e seed)
  local user="$1" pw="$2" realm="$3" resp token
  [ -n "$user" ] && [ -n "$pw" ] && [ -n "$realm" ] || die "no sign-in for $user"
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

write_cfg() { # file token
  printf 'header = "Authorization: Bearer %s"\n' "$2" >"$1"
}

HAVE_ADMIN2=0
{
  umask 077
  if [ -n "${ACCESS_TOKEN:-}" ]; then
    write_cfg "$AUTH_CFG" "$ACCESS_TOKEN"
  else
    tok=$(get_token "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "$ADMIN_REALM")
    write_cfg "$AUTH_CFG" "$tok"; unset tok
  fi
  if [ -n "${ACCESS_TOKEN2:-}" ]; then
    write_cfg "$AUTH2_CFG" "$ACCESS_TOKEN2"; HAVE_ADMIN2=1
  elif [ -n "$ADMIN2_USERNAME" ] && [ -n "${ADMIN2_PASSWORD:-}" ]; then
    tok=$(get_token "$ADMIN2_USERNAME" "$ADMIN2_PASSWORD" "${ADMIN2_REALM:-${ADMIN_REALM:-}}")
    write_cfg "$AUTH2_CFG" "$tok"; unset tok; HAVE_ADMIN2=1
  fi
  if [ -n "${PLATFORM_ACCESS_TOKEN:-}" ]; then write_cfg "$PLAT_CFG" "$PLATFORM_ACCESS_TOKEN"; fi
}

# ---------------------------------------------------------------------------------------------
# HTTP helpers. api METHOD PATH [BODY]: answer to $RESP, status in $STATUS. Nothing secret is printed.
# ---------------------------------------------------------------------------------------------
STATUS=""
api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    STATUS=$(printf '%s' "$body" | curl -sS --max-time 60 -o "$RESP" -w '%{http_code}' -K "$AUTH_USE" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      -H "X-Tenant-Slug: $TENANT_SLUG" -X "$method" --data-binary @- "$API$path") || STATUS="000"
  else
    STATUS=$(curl -sS --max-time 60 -o "$RESP" -w '%{http_code}' -K "$AUTH_USE" \
      -H 'Accept: application/json' -H "X-Tenant-Slug: $TENANT_SLUG" -X "$method" "$API$path") || STATUS="000"
  fi
}

reason() { jq -r '[.reason, .field, (.fields // empty | join(",")), .detail, .title] | map(select(. != null and . != "")) | join(" ")' "$RESP" 2>/dev/null || echo "?"; }

# write PATH BODY LABEL -> record id on stdout; stops on anything but 200/201.
write() {
  local path="$1" body="$2" label="$3" id
  api POST "$path" "$body"
  case "$STATUS" in
    200 | 201) ;;
    401) die "$label: 401, the token was refused" ;;
    403) die "$label: 403, the user lacks the permission (is it the tenant administrator?)" ;;
    404) die "$label: 404 (module not installed, an API token instead of a signed-in user, or a referenced record not found)" ;;
    *) die "$label: HTTP $STATUS $(reason)" ;;
  esac
  id=$(jq -r '.record_id // .id // empty' "$RESP")
  [ -n "$id" ] || die "$label: no record id in the answer"
  log "ok   $label"
  printf '%s' "$id"
}

key() { printf 'demo:%s:%s' "$DEMO_TAG" "$1"; }

code_state() { # exact value -> "record_id status" (empty when not found)
  api POST /entities/query "$(jq -nc --arg v "$1" '{entity_type:"code_tag", filters:[{field:"value", op:"eq", value:$v}]}')"
  [ "$STATUS" = 200 ] || die "query code_tag: HTTP $STATUS $(reason)"
  jq -r '.items[0] // empty | "\(.record_id) \(.field_values.status)"' "$RESP"
}

# ---------------------------------------------------------------------------------------------
# T. the tenant (optional creation)
# ---------------------------------------------------------------------------------------------
if [ -n "${PLATFORM_ACCESS_TOKEN:-}" ]; then
  log "== T. tenant $TENANT_SLUG"
  [ -n "${DEMO_REALM:-}" ] && [ -n "${DEMO_HOSTNAME:-}" ] || die "PLATFORM_ACCESS_TOKEN needs DEMO_REALM and DEMO_HOSTNAME"
  AUTH_USE="$PLAT_CFG"
  api GET "/tenants/$TENANT_SLUG"
  case "$STATUS" in
    200) log "skip tenant $TENANT_SLUG (exists)" ;;
    404)
      api POST /onboarding "$(jq -nc --arg s "$TENANT_SLUG" --arg h "$DEMO_HOSTNAME" --arg r "$DEMO_REALM" \
        '{slug:$s, display_name:"Ai-Dala Showroom", hostname:$h, idp_realm_id:$r}')"
      case "$STATUS" in 200 | 201 | 202) log "ok   tenant $TENANT_SLUG created" ;; *) die "create tenant: HTTP $STATUS $(reason)" ;; esac ;;
    *) die "tenant lookup: HTTP $STATUS $(reason)" ;;
  esac
  AUTH_USE="$AUTH_CFG"
fi

# ---------------------------------------------------------------------------------------------
# 0. modules
# ---------------------------------------------------------------------------------------------
log "== 0. modules"
api GET /me/modules
case "$STATUS" in
  200) ;;
  401 | 403 | 404) die "GET /me/modules: HTTP $STATUS. Tenant '$TENANT_SLUG' not found or not signed in (the tenant must exist and its administrator must be able to sign in)." ;;
  *) die "GET /me/modules on tenant '$TENANT_SLUG': HTTP $STATUS $(reason) (token or tenant problem)" ;;
esac
installed=$(jq -r '.installed_modules[].module_id' "$RESP")
install_module() { # module_id; returns 0 when installed afterwards
  local m="$1"
  if printf '%s\n' "$installed" | grep -qx "$m"; then log "skip module $m (installed)"; return 0; fi
  api POST /tenant/modules "$(jq -nc --arg m "$m" '{module_id:$m, rationale:"Showroom demo tenant (demo_showroom_seed.sh)"}')"
  case "$STATUS" in
    201) log "ok   module $m installed"; return 0 ;;
    409) log "skip module $m (already installed)"; return 0 ;;
    *) log "note module $m not installed: HTTP $STATUS $(reason)"; return 1 ;;
  esac
}
for m in org locations catalog_items codes stock; do   # stock depends on the other four
  install_module "$m" || die "install $m: HTTP $STATUS $(reason)"
done
HAVE_ASSETS=1
install_module assets || HAVE_ASSETS=0

# ---------------------------------------------------------------------------------------------
# 1. legal entity, site, org units
# ---------------------------------------------------------------------------------------------
log "== 1. organization"
BASE10=$(printf '%010d' $((TAG_NUM % 10000000000)))
BIN1="${BASE10}01"

LE1=$(write /modules/org/legal-entities "$(jq -nc --arg c "${TAG}-LE1" --arg n "Altyn Tulpar LLP" --arg b "$BIN1" --arg s "$EXT" --arg k "$(key le1)" \
  '{code:$c, name:$n, bin:$b, external_ref_system:$s, external_ref_id:$c, idempotency_key:$k}')" "legal entity ${TAG}-LE1")
S1=$(write /modules/org/sites "$(jq -nc --arg c "${TAG}-S-ALA" --arg n "Almaty office" --arg l "$LE1" --arg s "$EXT" --arg k "$(key site1)" \
  '{code:$c, name:$n, legal_entity_id:$l, external_ref_system:$s, external_ref_id:$c, idempotency_key:$k}')" "site ${TAG}-S-ALA")
unit() { # code name parent_id|""
  write /modules/org/units "$(jq -nc --arg c "$1" --arg n "$2" --arg l "$LE1" --arg st "$S1" --arg p "$3" --arg s "$EXT" --arg k "$(key "unit:$1")" \
    '{code:$c, name:$n, legal_entity_id:$l, site_id:$st, external_ref_system:$s, external_ref_id:$c, idempotency_key:$k}
     + (if $p == "" then {} else {parent:$p} end)')" "org unit $1"
}
U_HQ=$(unit "${TAG}-U-HQ" "Head office" "")
U_WH=$(unit "${TAG}-U-WH" "Warehouse team" "$U_HQ")
U_SALES=$(unit "${TAG}-U-SALES" "Sales team" "$U_HQ")

# ---------------------------------------------------------------------------------------------
# 2. employees (invented names)
# ---------------------------------------------------------------------------------------------
log "== 2. employees"
employee() { # code full_name org_unit_id
  write /modules/org/employees "$(jq -nc --arg c "$1" --arg n "$2" --arg u "$3" --arg s "$EXT" --arg k "$(key "emp:$1")" \
    '{code:$c, full_name:$n, org_unit_id:$u, external_ref_system:$s, external_ref_id:$c, idempotency_key:$k}')" "employee $1"
}
E_KEEP=$(employee "${TAG}-E001" "Saule Zhumabek" "$U_WH")      # storekeeper, chair of the count
E_WH2=$(employee "${TAG}-E002" "Yerlan Mukanov" "$U_WH")       # second storekeeper
E_SALES=$(employee "${TAG}-E003" "Dana Omarova" "$U_SALES")    # sales manager, member of the commission
E_SALES2=$(employee "${TAG}-E004" "Arman Kassymov" "$U_SALES") # sales assistant
E_ACC=$(employee "${TAG}-E005" "Aigerim Sadykova" "$U_HQ")     # accountant

# A count needs a chair with a user (chair_without_user); the accounts exist after the first sign-in.
LINKED_KEEP=0
LINK_UID=""   # account id of the login just linked (empty: skipped or refused)
link_user() { # username employee_id label [soft]
  local uid
  LINK_UID=""
  [ -n "$1" ] || { log "skip link $3: no username given"; return 0; }
  api GET "/identity/users?search=$1&page_size=50"
  [ "$STATUS" = 200 ] || die "find user $1: HTTP $STATUS $(reason)"
  uid=$(jq -r --arg u "$1" '[.items[] | select(.username == $u)][0].id // empty' "$RESP")
  [ -n "$uid" ] || { log "skip link $3: no account $1 yet (sign in once as that user, then run again)"; return 0; }
  api PATCH "/modules/org/employees/$2" "$(jq -nc --arg u "$uid" --arg k "$(key "link:$3")" '{user_id:$u, idempotency_key:$k}')"
  case "$STATUS" in
    200) log "ok   $3 linked to a user account"; LINK_UID="$uid" ;;
    *) if [ "${4:-}" = soft ]; then log "note link $3: HTTP $STATUS $(reason) (optional link, continuing)"; else die "link $3: HTTP $STATUS $(reason)"; fi ;;
  esac
  return 0
}
link_user "$ADMIN_USERNAME" "$E_KEEP" "storekeeper"
if [ "$HAVE_ADMIN2" = 1 ]; then
  AUTH_USE="$AUTH2_CFG"; api GET /me/modules; AUTH_USE="$AUTH_CFG"   # the account exists after one request
  link_user "$ADMIN2_USERNAME" "$E_SALES" "sales-manager"
fi
# The logins infra made for the owner and clients (optional, soft): the accounts exist after their first sign-in.
link_user "$ADMIN_LOGIN_USERNAME" "$E_ACC" "admin-login" soft
AL_UID="$LINK_UID"
link_user "$USER_LOGIN_USERNAME" "$E_SALES2" "user-login" soft
UL_UID="$LINK_UID"

# ---------------------------------------------------------------------------------------------
# 3. location tree
# ---------------------------------------------------------------------------------------------
log "== 3. locations"
node_lookup() { # code -> record_id of an existing location node (re-run safety), empty when none
  api POST /entities/query "$(jq -nc --arg v "$1" '{entity_type:"location_node", filters:[{field:"code", op:"eq", value:$v}]}')"
  [ "$STATUS" = 200 ] && jq -r '.items[0].record_id // empty' "$RESP"
}
node() { # code name kind parent_id|"" segment|"" pattern|""
  # A replay of a composed-address node is refused as idempotency_key_reuse (409): look it up by code first.
  local have; have=$(node_lookup "$1" || true)
  if [ -n "$have" ]; then log "ok   location $1 (exists)"; printf '%s' "$have"; return 0; fi
  write /modules/locations/nodes "$(jq -nc --arg c "$1" --arg n "$2" --arg kd "$3" --arg p "$4" --arg sg "$5" --arg ap "$6" --arg s "$EXT" --arg k "$(key "node:$1")" \
    '{code:$c, name:$n, node_kind:$kd, external_ref_system:$s, external_ref_id:$c, idempotency_key:$k}
     + (if $p == "" then {} else {parent_id:$p} end)
     + (if $sg == "" then {} else {segment:$sg} end)
     + (if $ap == "" then {} else {address_pattern:$ap} end)')" "location $1"
}
L_KZ=$(node "${TAG}-L-KZ" "Kazakhstan" "country" "" "" "")
L_ALA=$(node "${TAG}-L-ALA" "Almaty" "city" "$L_KZ" "" "")
L_WH=$(node "${TAG}-L-WH" "Central warehouse" "warehouse" "$L_ALA" "WH${TAG}" "segments")
L_R1=$(node "${TAG}-L-WH-R1" "Rack 01" "rack" "$L_WH" "01" "segments")
L_R2=$(node "${TAG}-L-WH-R2" "Rack 02" "rack" "$L_WH" "02" "segments")
L_SHOW=$(node "${TAG}-L-SHOW" "Showroom" "shop" "$L_ALA" "" "")
L_AST=$(node "${TAG}-L-AST" "Astana" "city" "$L_KZ" "" "")
L_BR=$(node "${TAG}-L-BRANCH" "Branch warehouse" "warehouse" "$L_AST" "" "")

# ---------------------------------------------------------------------------------------------
# 4. links org unit <-> location
# ---------------------------------------------------------------------------------------------
log "== 4. links"
link() { # unit_id location_id label
  write /modules/locations/links "$(jq -nc --arg u "$1" --arg l "$2" --arg k "$(key "link:$3")" \
    '{org_unit_id:$u, location_id:$l, idempotency_key:$k}')" "link $3" >/dev/null
}
link "$U_WH" "$L_WH" "WH-WH"
link "$U_WH" "$L_R1" "WH-R1"
link "$U_WH" "$L_R2" "WH-R2"
link "$U_SALES" "$L_SHOW" "SALES-SHOW"

# ---------------------------------------------------------------------------------------------
# 5. units of measure and catalog items (import route, upsert by external ref)
# ---------------------------------------------------------------------------------------------
log "== 5. catalog"
import_json() { # entity_type records-json label -> prints the results array
  local body
  body=$(jq -nc --arg t "$1" --argjson r "$2" \
    '{record_export_schema_version:"entities/record-export/v1", entity_type:$t, upsert_by:"external_ref", records:$r}')
  api POST "/entities/records/$1/import" "$body"
  [ "$STATUS" = 200 ] || die "$3: HTTP $STATUS $(reason)"
  if jq -e '[.results[] | select(.status != "ok")] | length > 0' "$RESP" >/dev/null; then
    die "$3: refused rows: $(jq -c '[.results[] | select(.status != "ok") | {line, reason: .reason.type, header: .reason.header}]' "$RESP")"
  fi
  log "ok   $3: $(jq -r '[.results[].outcome] | group_by(.) | map("\(.[0]) \(length)") | join(", ")' "$RESP")"
  jq -c '.results' "$RESP"
}
uoms=$(jq -nc --arg s "$EXT" --arg t "$TAG" '[
  ["PCS","Piece"], ["KG","Kilogram"], ["L","Litre"], ["BOX","Box"]
] | map({external_ref:{system:$s, id:.[0]}, field_values:{code:($t + "-" + .[0]), name:.[1], active:true}})')
uom_results=$(import_json catalog_uom "$uoms" "units of measure")
uom_id() { printf '%s' "$uom_results" | jq -r --arg id "$1" '.[] | select(.external_ref.id == $id) | .record_id // empty'; }
UOM_PCS=$(uom_id PCS); UOM_KG=$(uom_id KG); UOM_L=$(uom_id L); UOM_BOX=$(uom_id BOX)
for v in UOM_PCS UOM_KG UOM_L UOM_BOX; do [ -n "${!v}" ] || die "units: no record id for $v in the import answer"; done

# The catalog item has no photo field and no per-language name: clean names, some English, some Russian,
# some Kazakh. tracking_policy: none | lot. base_uom_id holds the EXTERNAL id of the unit.
items=$(jq -nc --arg s "$EXT" --arg t "$TAG" '[
  ["LAPTOP","Laptop 14\"","PCS","none"],
  ["MONITOR","Монитор 27\"","PCS","none"],
  ["CHAIR","Office chair","PCS","none"],
  ["DRILL","Дрель аккумуляторная","PCS","none"],
  ["HELMET","Safety helmet","PCS","none"],
  ["GLOVES","Перчатки рабочие","PCS","none"],
  ["WATER","Ауыз су 19 л","PCS","none"],
  ["TEA","Қара шай 100 г","PCS","none"],
  ["CEMENT","Цемент М400","KG","none"],
  ["PAINT","Краска белая 10 кг","KG","none"],
  ["MILK","Сүт 2,5% 1 л","L","lot"],
  ["PAPER","Бумага А4, пачка 500 л.","BOX","none"]
] | map({external_ref:{system:$s, id:("ITM-" + .[0])},
         field_values:{code:($t + "-ITM-" + .[0]), name:.[1], base_uom_id:.[2], kind:"material", active:true, tracking_policy:.[3]}})')
item_results=$(import_json catalog_item "$items" "catalog items")
item_id() { local v; v=$(printf '%s' "$item_results" | jq -r --arg id "ITM-$1" '.[] | select(.external_ref.id == $id) | .record_id // empty'); [ -n "$v" ] || die "catalog items: no record id for $1"; printf '%s' "$v"; }
I_LAPTOP=$(item_id LAPTOP); I_MONITOR=$(item_id MONITOR); I_CEMENT=$(item_id CEMENT); I_MILK=$(item_id MILK)
I_HELMET=$(item_id HELMET); I_DRILL=$(item_id DRILL); I_PAPER=$(item_id PAPER); I_TEA=$(item_id TEA)
I_WATER=$(item_id WATER); I_GLOVES=$(item_id GLOVES); I_PAINT=$(item_id PAINT); I_CHAIR=$(item_id CHAIR)

# ---------------------------------------------------------------------------------------------
# 6. lots of milk, relative to today (a lot is created once; a re-run replays it)
# ---------------------------------------------------------------------------------------------
log "== 6. lots"
lot_lookup() { # code -> record id of an existing lot, empty when none
  api POST /entities/query "$(jq -nc --arg v "$1" '{entity_type:"catalog_lot", filters:[{field:"code", op:"eq", value:$v}]}')"
  [ "$STATUS" = 200 ] && jq -r '.items[0].record_id // empty' "$RESP"
}
lot() { # item_id code producer mark expiry_offset
  local have; have=$(lot_lookup "$2" || true)
  if [ -n "$have" ]; then log "ok   lot $2 (exists)"; printf '%s' "$have"; return 0; fi
  write /modules/catalog_items/lots "$(jq -nc --arg i "$1" --arg c "$2" --arg p "$3" --arg m "$4" --arg e "$(date -u -d "$5" +%F)" --arg s "$EXT" --arg k "$(key "lot:$2")" \
    '{item_id:$i, code:$c, producer:$p, mark:$m, expiry_date:$e, external_ref_system:$s, external_ref_id:$c, idempotency_key:$k}')" "lot $2"
}
LOT_M1=$(lot "$I_MILK" "${TAG}-M-A" "Foodmaster" "2.5% fat" "+60 days")
LOT_M2=$(lot "$I_MILK" "${TAG}-M-B" "Foodmaster" "2.5% fat" "+90 days")

# ---------------------------------------------------------------------------------------------
# 7. codes for the keyboard scanner
# ---------------------------------------------------------------------------------------------
log "== 7. codes"
BC_LAPTOP="${TAG}-BC-LAPTOP"; BC_CEMENT="${TAG}-BC-CEMENT"; BC_MILK="${TAG}-BC-MILKA"; QR_R1="${TAG}-QR-RACK01"
entries=$(jq -nc --arg a "$BC_LAPTOP" --arg b "$BC_CEMENT" --arg c "$BC_MILK" --arg q "$QR_R1" \
  '[{value:$a,kind:"barcode"},{value:$b,kind:"barcode"},{value:$c,kind:"barcode"},{value:$q,kind:"qr"}]')
api POST /modules/codes/receive "$(jq -nc --argjson e "$entries" --arg k "$(key "receive:1")" '{entries:$e, idempotency_key:$k}')"
case "$STATUS" in
  200 | 201) log "ok   received 4 codes" ;;
  *) die "receive codes: HTTP $STATUS $(reason)" ;;
esac
assign_if_free() { # value target_type target_id label
  local id st state body
  state=$(code_state "$1")
  read -r id st <<<"$state" || true
  if [ -z "${id:-}" ]; then log "skip $4: code not found"; return 0; fi
  if [ "$st" != "not_assigned" ]; then log "skip $4: code is '$st'"; return 0; fi
  body=$(jq -nc --arg tt "$2" --arg t "$3" --arg k "$(key "assign:$1")" '{target_type:$tt, target_id:$t, idempotency_key:$k}')
  api POST "/modules/codes/$id/assign" "$body"
  [ "$STATUS" = 200 ] || die "$4: HTTP $STATUS $(reason)"
  log "ok   $4"
}
assign_if_free "$BC_LAPTOP" catalog_item "$I_LAPTOP" "barcode $BC_LAPTOP to Laptop"
assign_if_free "$BC_CEMENT" catalog_item "$I_CEMENT" "barcode $BC_CEMENT to Cement"
assign_if_free "$BC_MILK" catalog_lot "$LOT_M1" "barcode $BC_MILK to Milk lot ${TAG}-M-A"
assign_if_free "$QR_R1" location_node "$L_R1" "QR $QR_R1 to Rack 01"

# ---------------------------------------------------------------------------------------------
# documents: guard by a marker note, then issue and post. A document has no idempotency key, so each one is
# found again by its note ("demo:<tag>:<name>"); a half-finished first run is completed, nothing is doubled.
# ---------------------------------------------------------------------------------------------
# find_doc BASE KIND MARKER -> "id state" of the document of that kind whose note is MARKER (empty: none)
find_doc() {
  local base="$1" kind="$2" marker="$3" cursor="" q ids id st note
  while :; do
    q="$base/documents?kind=$kind&limit=100"
    [ -z "$cursor" ] || q="$q&cursor=$cursor"
    api GET "$q"
    [ "$STATUS" = 200 ] || die "list $kind documents: HTTP $STATUS $(reason)"
    ids=$(jq -r '.rows[] | "\(.id) \(.state)"' "$RESP")
    cursor=$(jq -r '.next_cursor // empty' "$RESP")
    while read -r id st; do
      [ -n "${id:-}" ] || continue
      api GET "$base/documents/$id"
      [ "$STATUS" = 200 ] || die "read $kind document: HTTP $STATUS $(reason)"
      note=$(jq -r '.note // empty' "$RESP")
      if [ "$note" = "$marker" ] || [[ "$note" == "$marker | "* ]]; then printf '%s %s' "$id" "$st"; return 0; fi
    done <<<"$ids"
    [ -n "$cursor" ] || return 0
  done
}

# complete_task DOC_ID NODE LABEL: claim and complete the pending task of that node that belongs to the document.
complete_task() {
  local doc="$1" node="$2" label="$3" cand iid tid found=""
  api GET "/tasks/inbox?page_size=100"
  [ "$STATUS" = 200 ] || die "$label: GET /tasks/inbox HTTP $STATUS $(reason)"
  cand=$(jq -r --arg n "$node" '.items[] | select(.status == "PENDING" and .node_id == $n) | "\(.id) \(.instance_id)"' "$RESP")
  while read -r tid iid; do
    [ -n "${tid:-}" ] || continue
    api GET "/instances/$iid"
    [ "$STATUS" = 200 ] || continue
    if jq -e --arg d "$doc" '.variables | tostring | contains($d)' "$RESP" >/dev/null; then found="$tid"; break; fi
  done <<<"$cand"
  [ -n "$found" ] || die "$label: no pending '$node' task for the document in the inbox of this user"
  api POST "/tasks/$found/claim"
  case "$STATUS" in 200 | 201 | 204 | 409) ;; *) die "$label: claim HTTP $STATUS $(reason)" ;; esac
  api POST "/tasks/$found/complete" '{"output_variables":{}}'
  case "$STATUS" in
    200 | 201) log "ok   $label (task completed)" ;;
    403) die "$label: complete refused 403 (a different person must do this step?)" ;;
    *) die "$label: complete HTTP $STATUS $(reason)" ;;
  esac
}

# make_doc BASE KIND NAME BODY [NODE] [APPROVER]: create (when missing), issue (when a draft), complete the task.
make_doc() {
  local base="$1" kind="$2" name="$3" body="$4" node="${5:-post}" approver="${6:-1}" found id st label="$2 $3"
  found=$(find_doc "$base" "$kind" "$(key "$name")")
  if [ -n "$found" ]; then
    read -r id st <<<"$found"
  else
    api POST "$base/documents" "$body"
    case "$STATUS" in 200 | 201) ;; *) die "$label: create HTTP $STATUS $(reason)" ;; esac
    id=$(jq -r '.id // empty' "$RESP"); [ -n "$id" ] || die "$label: no id in the answer"
    st=draft
  fi
  case "$st" in
    posted | reversed | cancelled) log "ok   $label (exists, $st)"; return 0 ;;
    draft)
      api POST "$base/documents/$id/issue" ""
      case "$STATUS" in 200) log "ok   $label issued: $(jq -r '.number // "?"' "$RESP")" ;; *) die "$label: issue HTTP $STATUS $(reason)" ;; esac ;;
  esac
  if [ "$approver" = 2 ]; then
    if [ "$HAVE_ADMIN2" = 1 ]; then
      AUTH_USE="$AUTH2_CFG"; complete_task "$id" "$node" "$label posted (second person)"; AUTH_USE="$AUTH_CFG"
    else
      log "note $label stays ISSUED: no second administrator given (ACCESS_TOKEN2 or ADMIN2_*). A second person completes the task '$node' in My Tasks."
    fi
  else
    complete_task "$id" "$node" "$label posted"
  fi
}

# assign_open_task DOC_ID UID LABEL: address the pending post task of the document to the user. Never claims,
# never completes. Already addressed to that user: no write.
assign_open_task() {
  local doc="$1" uid="$2" label="$3" cand iid tid ty ref found="" fty="" fref=""
  api GET "/tasks/inbox?page_size=100"
  [ "$STATUS" = 200 ] || die "$label: GET /tasks/inbox HTTP $STATUS $(reason)"
  cand=$(jq -r '.items[] | select(.status == "PENDING" and .node_id == "post") | "\(.id) \(.instance_id) \(.assignee_type // "-") \(.assignee_ref // "-")"' "$RESP")
  while read -r tid iid ty ref; do
    [ -n "${tid:-}" ] || continue
    api GET "/instances/$iid"
    [ "$STATUS" = 200 ] || continue
    if jq -e --arg d "$doc" '.variables | tostring | contains($d)' "$RESP" >/dev/null; then found="$tid"; fty="$ty"; fref="$ref"; break; fi
  done <<<"$cand"
  if [ -z "$found" ]; then log "note $label: no pending post task (already posted or withdrawn)"; return 0; fi
  if [ "$fty" = USER ] && [ "$fref" = "$uid" ]; then log "ok   $label (open task already addressed)"; return 0; fi
  if [ "$fty" = USER ]; then log "note $label: task addressed to someone else, left as is"; return 0; fi
  api POST "/tasks/$found/reassign" "$(jq -nc --arg u "$uid" '{user_id:$u}')"
  case "$STATUS" in
    200 | 201) log "ok   $label (open task addressed to the login)" ;;
    *) die "$label: reassign HTTP $STATUS $(reason) (the seed administrator needs the TENANT_ADMIN role)" ;;
  esac
}

# open_doc BASE KIND NAME BODY UID LABEL: create (when missing), issue (when a draft), address the task. Never posts.
open_doc() {
  local base="$1" kind="$2" name="$3" body="$4" uid="$5" label="$6" found id st
  found=$(find_doc "$base" "$kind" "$(key "$name")")
  if [ -n "$found" ]; then
    read -r id st <<<"$found"
  else
    api POST "$base/documents" "$body"
    case "$STATUS" in 200 | 201) ;; *) die "$label: create HTTP $STATUS $(reason)" ;; esac
    id=$(jq -r '.id // empty' "$RESP"); [ -n "$id" ] || die "$label: no id in the answer"
    st=draft
  fi
  case "$st" in
    posted | reversed | cancelled) log "ok   $label (exists, $st)"; return 0 ;;
    draft)
      api POST "$base/documents/$id/issue" ""
      case "$STATUS" in 200) log "ok   $label issued: $(jq -r '.number // "?"' "$RESP")" ;; *) die "$label: issue HTTP $STATUS $(reason)" ;; esac ;;
  esac
  assign_open_task "$id" "$uid" "$label"
}

COUNT_ID=""
if [ "${SKIP_DOCS:-0}" = 1 ]; then
  log "== SKIP_DOCS=1: no stock documents, no counts"
else
  # -------------------------------------------------------------------------------------------
  # 8. stock documents (all POSTED). Event times are inside the 96-hour window and increase, so
  # every document finds the stock the earlier ones put there.
  # -------------------------------------------------------------------------------------------
  log "== 8. stock documents"
  SM="/modules/stock"
  api GET "$SM/movements?limit=1"
  case "$STATUS" in
    200) ;;
    404) die "GET $SM/movements: 404. Sign in as the tenant administrator with a password (an API token answers 404), and check that module stock is installed." ;;
    *) die "GET $SM/movements: HTTP $STATUS $(reason)" ;;
  esac
  ev() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S+00:00; }
  RECEIVED=$(date -u -d '-3 days' +%F)

  make_doc "$SM" receipt receipt-1 "$(jq -nc --arg u "$U_WH" --arg l "$L_R1" --arg e "$E_KEEP" --arg t "$(ev '-30 hours')" --arg ro "$RECEIVED" --arg note "$(key receipt-1)" \
    --arg i1 "$I_LAPTOP" --arg i2 "$I_CEMENT" --arg i3 "$I_MILK" --arg i4 "$I_MONITOR" --arg uk "$UOM_PCS" --arg ug "$UOM_KG" --arg ul "$UOM_L" --arg lot "$LOT_M1" '
    {kind:"receipt", org_unit_id:$u, location_id:$l, responsible_id:$e, event_time:$t, received_on:$ro, supplier_document_ref:"SUP-0001", note:$note,
     lines:[{catalog_item_id:$i1, catalog_uom_id:$uk, quantity:"20", unit_price:"450000", line_value:"9000000"},
            {catalog_item_id:$i4, catalog_uom_id:$uk, quantity:"12", unit_price:"160000", line_value:"1920000"},
            {catalog_item_id:$i2, catalog_uom_id:$ug, quantity:"100", unit_price:"90", line_value:"9000"},
            {catalog_item_id:$i3, catalog_uom_id:$ul, quantity:"60", catalog_lot_id:$lot}]}')"

  make_doc "$SM" receipt receipt-2 "$(jq -nc --arg u "$U_WH" --arg l "$L_R2" --arg e "$E_WH2" --arg t "$(ev '-29 hours')" --arg ro "$(date -u -d '-2 days' +%F)" --arg note "$(key receipt-2)" \
    --arg i3 "$I_MILK" --arg i4 "$I_HELMET" --arg i5 "$I_DRILL" --arg i6 "$I_PAPER" --arg uk "$UOM_PCS" --arg ul "$UOM_L" --arg ub "$UOM_BOX" --arg lot "$LOT_M2" '
    {kind:"receipt", org_unit_id:$u, location_id:$l, responsible_id:$e, event_time:$t, received_on:$ro, supplier_document_ref:"SUP-0002", note:$note,
     lines:[{catalog_item_id:$i3, catalog_uom_id:$ul, quantity:"40", catalog_lot_id:$lot},
            {catalog_item_id:$i4, catalog_uom_id:$uk, quantity:"30", unit_price:"3200", line_value:"96000"},
            {catalog_item_id:$i5, catalog_uom_id:$uk, quantity:"10", unit_price:"28000", line_value:"280000"},
            {catalog_item_id:$i6, catalog_uom_id:$ub, quantity:"50", unit_price:"2400", line_value:"120000"}]}')"

  make_doc "$SM" transfer transfer-1 "$(jq -nc --arg u "$U_WH" --arg fl "$L_R1" --arg fe "$E_KEEP" --arg tu "$U_SALES" --arg tl "$L_SHOW" --arg te "$E_SALES" --arg t "$(ev '-28 hours')" --arg note "$(key transfer-1)" \
    --arg i1 "$I_LAPTOP" --arg uk "$UOM_PCS" '
    {kind:"transfer", org_unit_id:$u, from_location_id:$fl, from_responsible_id:$fe, to_org_unit_id:$tu, to_location_id:$tl, to_responsible_id:$te, event_time:$t, note:$note,
     lines:[{catalog_item_id:$i1, catalog_uom_id:$uk, quantity:"4"}]}')"

  make_doc "$SM" issue issue-1 "$(jq -nc --arg u "$U_WH" --arg l "$L_R1" --arg e "$E_KEEP" --arg t "$(ev '-27 hours')" --arg note "$(key issue-1)" \
    --arg i2 "$I_CEMENT" --arg ug "$UOM_KG" '
    {kind:"issue", org_unit_id:$u, location_id:$l, responsible_id:$e, event_time:$t, reason_text:"Site repair, Almaty branch", note:$note,
     lines:[{catalog_item_id:$i2, catalog_uom_id:$ug, quantity:"20"}]}')"

  make_doc "$SM" hand_over handover-1 "$(jq -nc --arg u "$U_WH" --arg fl "$L_R2" --arg fe "$E_WH2" --arg tu "$U_SALES" --arg tl "$L_SHOW" --arg te "$E_SALES2" --arg t "$(ev '-26 hours')" --arg note "$(key handover-1)" \
    --arg i4 "$I_HELMET" --arg i5 "$I_DRILL" --arg uk "$UOM_PCS" '
    {kind:"hand_over", org_unit_id:$u, from_location_id:$fl, from_responsible_id:$fe, to_org_unit_id:$tu, to_location_id:$tl, to_responsible_id:$te, event_time:$t, note:$note,
     lines:[{catalog_item_id:$i4, catalog_uom_id:$uk, quantity:"6"}, {catalog_item_id:$i5, catalog_uom_id:$uk, quantity:"2"}]}')"

  make_doc "$SM" return return-1 "$(jq -nc --arg u "$U_WH" --arg fu "$U_SALES" --arg fl "$L_SHOW" --arg fe "$E_SALES" --arg tl "$L_R1" --arg te "$E_KEEP" --arg t "$(ev '-25 hours')" --arg note "$(key return-1)" \
    --arg i1 "$I_LAPTOP" --arg uk "$UOM_PCS" '
    {kind:"return", org_unit_id:$u, from_org_unit_id:$fu, from_location_id:$fl, from_responsible_id:$fe, to_location_id:$tl, to_responsible_id:$te, event_time:$t, note:$note,
     lines:[{catalog_item_id:$i1, catalog_uom_id:$uk, quantity:"1"}]}')"

  make_doc "$SM" write_off writeoff-1 "$(jq -nc --arg u "$U_WH" --arg l "$L_R2" --arg e "$E_WH2" --arg t "$(ev '-24 hours')" --arg note "$(key writeoff-1)" \
    --arg i3 "$I_MILK" --arg ul "$UOM_L" --arg lot "$LOT_M2" '
    {kind:"write_off", org_unit_id:$u, location_id:$l, responsible_id:$e, event_time:$t, reason_code:"damaged", reason_text:"Packs damaged in transit", note:$note,
     lines:[{catalog_item_id:$i3, catalog_uom_id:$ul, quantity:"2", catalog_lot_id:$lot}]}')"

  # Opening balance of the Sales team at the Showroom: issued by the first user, approved by a second person.
  make_doc "$SM" opening opening-1 "$(jq -nc --arg u "$U_SALES" --arg l "$L_SHOW" --arg e "$E_SALES" --arg ro "$(date -u -d '-30 days' +%F)" --arg note "$(key opening-1)" \
    --arg i1 "$I_LAPTOP" --arg i4 "$I_HELMET" --arg i7 "$I_GLOVES" --arg uk "$UOM_PCS" '
    {kind:"opening", org_unit_id:$u, note:$note,
     lines:[{location_id:$l, responsible_id:$e, catalog_item_id:$i1, catalog_uom_id:$uk, received_on:$ro, quantity:"3", unit_price:"430000", line_value:"1290000"},
            {location_id:$l, responsible_id:$e, catalog_item_id:$i4, catalog_uom_id:$uk, received_on:$ro, quantity:"15"},
            {location_id:$l, responsible_id:$e, catalog_item_id:$i7, catalog_uom_id:$uk, received_on:$ro, quantity:"40"}]}')" approve 2

  # -------------------------------------------------------------------------------------------
  # 9. stock count: Warehouse team, taken through to signed differences; NOT posted (a partner presses Post).
  # -------------------------------------------------------------------------------------------
  log "== 9. stock counts"
  find_count() { # marker -> "id status" (empty: none)
    local cursor="" q ids id note
    while :; do
      q="$SM/counts?org_unit_id=$U_WH&limit=100"; [ -z "$cursor" ] || q="$q&cursor=$cursor"
      api GET "$q"
      [ "$STATUS" = 200 ] || die "list counts: HTTP $STATUS $(reason)"
      ids=$(jq -r '.rows[].id' "$RESP")
      cursor=$(jq -r '.next_cursor // empty' "$RESP")
      while read -r id; do
        [ -n "${id:-}" ] || continue
        api GET "$SM/counts/$id"
        [ "$STATUS" = 200 ] || die "read count: HTTP $STATUS $(reason)"
        note=$(jq -r '.note // empty' "$RESP")
        if [ "$note" = "$1" ]; then printf '%s %s' "$id" "$(jq -r '.status' "$RESP")"; return 0; fi
      done <<<"$ids"
      [ -n "$cursor" ] || return 0
    done
  }
  count_step() { # METHOD PATH BODY LABEL
    api "$1" "$2" "$3"
    case "$STATUS" in 200 | 201) log "ok   $4" ;; *) die "$4: HTTP $STATUS $(reason)" ;; esac
  }
  # count 1: the full count of the Warehouse team
  found=$(find_count "$(key count-1)")
  if [ -z "$found" ]; then
    START=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S+00:00)   # in the past, so "Open" works at once
    END=$(date -u -d '+23 hours' +%Y-%m-%dT%H:%M:%S+00:00)
    members=$(jq -nc --arg a "$E_WH2" --arg b "$E_SALES" '[$a,$b]')
    count_step POST "$SM/counts" "$(jq -nc --arg u "$U_WH" --arg s "$START" --arg e "$END" --arg ch "$E_KEEP" --argjson m "$members" --arg loc "$L_WH" --arg note "$(key count-1)" \
      '{org_unit_id:$u, kind:"full", planned_start:$s, planned_end:$e, chair_employee_id:$ch, member_employee_ids:$m, location_ids:[$loc], note:$note}')" "count 1 ordered"
    COUNT_ID=$(jq -r '.id // empty' "$RESP"); [ -n "$COUNT_ID" ] || die "count 1: no id"
    count_step POST "$SM/counts/$COUNT_ID/issue" "" "count 1 issued"
    CSTATUS=ordered
  else
    read -r COUNT_ID CSTATUS <<<"$found"
    log "ok   count 1 (exists, $CSTATUS)"
  fi
  if [ "$CSTATUS" = ordered ]; then
    count_step POST "$SM/counts/$COUNT_ID/open" "" "count 1 opened"; CSTATUS=counting
  fi
  if [ "$CSTATUS" = counting ]; then
    api GET "$SM/counts/$COUNT_ID/lines?limit=200"; [ "$STATUS" = 200 ] || die "count 1 lines: HTTP $STATUS $(reason)"
    lines_json=$(jq -c '.rows' "$RESP")
    if [ "$(printf '%s' "$lines_json" | jq 'length')" = 0 ]; then die "count 1: the sheet has no lines (are the receipts posted?)"; fi
    # most lines match the books; the Laptop line is one short (a shortage in the differences sheet)
    while read -r no counted; do
      [ -n "${no:-}" ] || continue
      count_step PUT "$SM/counts/$COUNT_ID/lines/$no/count" "$(jq -nc --arg q "$counted" '{counted_quantity:$q}')" "count 1 line $no entered ($counted)"
    done < <(printf '%s' "$lines_json" | jq -r --arg laptop "$I_LAPTOP" '.[] | select(.counted_quantity == null) |
        "\(.line_no) \(if .catalog_item_id == $laptop then ((.book_quantity | tonumber) - 1 | tostring) else .book_quantity end)"')
    # a surplus line: a stock item the books do not know here (printer paper found on Rack 01)
    if [ "$(printf '%s' "$lines_json" | jq '[.[] | select(.kind == "surplus")] | length')" = 0 ]; then
      count_step POST "$SM/counts/$COUNT_ID/surplus-lines" "$(jq -nc --arg l "$L_R1" --arg i "$I_TEA" --arg u "$UOM_PCS" --arg e "$E_KEEP" \
        '{location_id:$l, catalog_item_id:$i, unit_ref:$u, counted_quantity:"3", responsible_employee_id:$e}')" "count 1 surplus line"
    fi
    count_step POST "$SM/counts/$COUNT_ID/close" "" "count 1 closed"; CSTATUS=counted
  fi
  if [ "$CSTATUS" = counted ]; then
    api GET "$SM/counts/$COUNT_ID"; [ "$STATUS" = 200 ] || die "read count 1: HTTP $STATUS $(reason)"
    sheet_signed=$(jq -r '.sheet_signed_at // empty' "$RESP"); diff_doc=$(jq -r '.differences_document_id // empty' "$RESP")
    api GET "$SM/counts/$COUNT_ID/lines?limit=200"; [ "$STATUS" = 200 ] || die "count 1 lines: HTTP $STATUS $(reason)"
    # signers: the chair, every commission member, every responsible employee of a sheet line
    signers=$(jq -c --arg ch "$E_KEEP" --arg a "$E_WH2" --arg b "$E_SALES" \
      '[$ch, $a, $b] + [.rows[].responsible_employee_id | select(. != null)] | unique' "$RESP")
    if [ -z "$sheet_signed" ]; then
      count_step POST "$SM/counts/$COUNT_ID/sheet-signatures" "$(jq -nc --argjson s "$signers" '{signer_employee_ids:$s}')" "count 1 sheet signed"
    fi
    if [ -z "$diff_doc" ]; then
      count_step POST "$SM/counts/$COUNT_ID/differences" "" "count 1 differences sheet issued"
    fi
    api GET "$SM/counts/$COUNT_ID/differences"; [ "$STATUS" = 200 ] || die "count 1 differences: HTTP $STATUS $(reason)"
    dsigners=$(jq -c --arg ch "$E_KEEP" --arg a "$E_WH2" --arg b "$E_SALES" \
      '[$ch, $a, $b] + [.lines[]?.responsible_employee_id | select(. != null)] | unique' "$RESP")
    count_step POST "$SM/counts/$COUNT_ID/differences-signatures" "$(jq -nc --argjson s "$dsigners" '{signer_employee_ids:$s}')" "count 1 differences signed"
    CSTATUS=signed
  fi
  # No second count: two open counts of one unit may not share a location, and the Sales team's count needs
  # a chair with a user account. A partner orders one on the screen.
fi

# ---------------------------------------------------------------------------------------------
# 10. assets (only when the build has the module)
# ---------------------------------------------------------------------------------------------
if [ "$HAVE_ASSETS" = 1 ]; then
  log "== 10. assets"
  AM="/modules/assets"
  api GET "$AM/balances?limit=1"
  case "$STATUS" in
    200) ;;
    404) log "skip assets: the asset routes answer 404 on this build"; HAVE_ASSETS=0 ;;
    *) die "GET $AM/balances: HTTP $STATUS $(reason)" ;;
  esac
fi
if [ "$HAVE_ASSETS" = 1 ]; then
  card_lookup() { # inventory_number -> record id, empty when none
    api POST /entities/query "$(jq -nc --arg v "$1" '{entity_type:"assets_card", filters:[{field:"inventory_number", op:"eq", value:$v}]}')"
    [ "$STATUS" = 200 ] && jq -r '.items[0].record_id // empty' "$RESP"
  }
  card() { # number name kind cost
    local have; have=$(card_lookup "$1" || true)
    if [ -n "$have" ]; then log "ok   asset card $1 (exists)"; printf '%s' "$have"; return 0; fi
    write "$AM/cards" "$(jq -nc --arg n "$1" --arg nm "$2" --arg k "$3" --arg c "$4" --arg d "$(date -u -d '-200 days' +%F)" --arg ik "$(key "card:$1")" \
      '{inventory_number:$n, name:$nm, kind:$k, acquisition_date:$d, acquisition_cost:$c, book_value:$c, idempotency_key:$ik}')" "asset card $1"
  }
  A1=$(card "${TAG}-A-001" "Принтер лазерный HP" fixed "180000")
  A2=$(card "${TAG}-A-002" "Laptop Lenovo T14" fixed "520000")
  A3=$(card "${TAG}-A-003" "Стеллаж металлический" fixed "95000")
  A4=$(card "${TAG}-A-004" "Office chairs" low_value "25000")
  A5=$(card "${TAG}-A-005" "Сканер штрихкодов" low_value "38000")
  A6=$(card "${TAG}-A-006" "Бухгалтерская программа, лицензия" intangible "300000")
  if [ "${SKIP_DOCS:-0}" != 1 ]; then
    ev() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S+00:00; }
    make_doc "$AM" commission commission-1 "$(jq -nc --arg u "$U_WH" --arg l "$L_R1" --arg e "$E_KEEP" --arg t "$(ev '-20 hours')" --arg note "$(key commission-1)" \
      --arg a1 "$A1" --arg a2 "$A2" --arg a3 "$A3" --arg a4 "$A4" --arg a5 "$A5" '
      {kind:"commission", org_unit_id:$u, location_id:$l, material_responsible_id:$e, event_time:$t, note:$note,
       lines:[{asset_id:$a1, quantity:"1"}, {asset_id:$a2, quantity:"1"}, {asset_id:$a3, quantity:"1"}, {asset_id:$a4, quantity:"4"}, {asset_id:$a5, quantity:"2"}]}')"
    make_doc "$AM" handover handover-1 "$(jq -nc --arg u "$U_WH" --arg fl "$L_R1" --arg fe "$E_KEEP" --arg tu "$U_SALES" --arg tl "$L_SHOW" --arg te "$E_SALES" --arg t "$(ev '-19 hours')" --arg note "$(key handover-1)" \
      --arg a2 "$A2" --arg a5 "$A5" '
      {kind:"handover", org_unit_id:$u, from_location_id:$fl, from_material_responsible_id:$fe, to_org_unit_id:$tu, to_location_id:$tl, to_material_responsible_id:$te, event_time:$t, note:$note,
       lines:[{asset_id:$a2, quantity:"1"}, {asset_id:$a5, quantity:"1"}]}')"
    make_doc "$AM" writeoff writeoff-1 "$(jq -nc --arg u "$U_WH" --arg l "$L_R1" --arg e "$E_KEEP" --arg t "$(ev '-18 hours')" --arg note "$(key writeoff-1)" --arg a4 "$A4" '
      {kind:"writeoff", org_unit_id:$u, location_id:$l, material_responsible_id:$e, event_time:$t, reason_code:"broken", reason_text:"Broken during the move", note:$note,
       lines:[{asset_id:$a4, quantity:"1"}]}')"
  fi
fi

# ---------------------------------------------------------------------------------------------
# 11. open tasks for the demo logins (D-113): stock receipts left ISSUED, their post task addressed to the
# linked login, unclaimed and uncompleted. Found again by the marker "<marker> | <text>"; a re-run writes nothing.
# ---------------------------------------------------------------------------------------------
log "== 11. open tasks for the demo logins"
if [ "${SKIP_DOCS:-0}" = 1 ]; then
  log "skip open tasks: SKIP_DOCS=1"
else
  SM="/modules/stock"
  ev() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S+00:00; }
  open_receipt() { # name uid label unit location employee supplier_ref text item1 uom1 qty1 price1 item2 uom2 qty2 price2
    local name="$1" uid="$2" label="$3"
    open_doc "$SM" receipt "$name" "$(jq -nc --arg u "$4" --arg l "$5" --arg e "$6" --arg t "$(ev '-2 hours')" --arg ro "$(date -u -d '-1 day' +%F)" \
      --arg sr "$7" --arg note "$(key "$name") | $8" --arg i1 "$9" --arg u1 "${10}" --arg q1 "${11}" --arg p1 "${12}" \
      --arg i2 "${13}" --arg u2 "${14}" --arg q2 "${15}" --arg p2 "${16}" '
      {kind:"receipt", org_unit_id:$u, location_id:$l, responsible_id:$e, event_time:$t, received_on:$ro, supplier_document_ref:$sr, note:$note,
       lines:[{catalog_item_id:$i1, catalog_uom_id:$u1, quantity:$q1, unit_price:$p1, line_value:(($q1|tonumber) * ($p1|tonumber) | tostring)},
              {catalog_item_id:$i2, catalog_uom_id:$u2, quantity:$q2, unit_price:$p2, line_value:(($q2|tonumber) * ($p2|tonumber) | tostring)}]}')" \
      "$uid" "$label"
  }
  if [ -z "$AL_UID" ]; then log "skip open tasks admin-login: not linked"; else
    open_receipt open-al-1 "$AL_UID" "open task admin-login 1" "$U_WH" "$L_R2" "$E_ACC" SUP-0101 \
      "Office paper from Altyn Paper LLP: check and post" "$I_PAPER" "$UOM_BOX" 20 2400 "$I_GLOVES" "$UOM_PCS" 40 350
    open_receipt open-al-2 "$AL_UID" "open task admin-login 2" "$U_WH" "$L_R2" "$E_ACC" SUP-0102 \
      "Поступление перчаток и касок от ТОО «Алтын Қағаз»: проверить и провести" "$I_GLOVES" "$UOM_PCS" 60 350 "$I_HELMET" "$UOM_PCS" 15 3200
    open_receipt open-al-3 "$AL_UID" "open task admin-login 3" "$U_WH" "$L_R2" "$E_ACC" SUP-0103 \
      "«Алтын Қағаз» ЖШС-нен су мен шай түсімі: тексеріп, өткізіңіз" "$I_WATER" "$UOM_PCS" 30 900 "$I_TEA" "$UOM_PCS" 50 700
  fi
  if [ -z "$UL_UID" ]; then log "skip open tasks user-login: not linked"; else
    open_receipt open-ul-1 "$UL_UID" "open task user-login 1" "$U_SALES" "$L_SHOW" "$E_SALES2" SUP-0104 \
      "Шоурум үшін шай мен су: өткізуді күтуде" "$I_TEA" "$UOM_PCS" 24 700 "$I_WATER" "$UOM_PCS" 12 900
    open_receipt open-ul-2 "$UL_UID" "open task user-login 2" "$U_SALES" "$L_SHOW" "$E_SALES2" SUP-0105 \
      "Showroom restock: gloves and paper, waiting to be posted" "$I_GLOVES" "$UOM_PCS" 20 350 "$I_PAPER" "$UOM_BOX" 6 2400
  fi
fi

# ---------------------------------------------------------------------------------------------
# done: the demo logins WITHOUT passwords
# ---------------------------------------------------------------------------------------------
log "== done. Data set '$DEMO_TAG' on tenant '$TENANT_SLUG': codes start with $TAG-, external ref system $EXT."
{
  echo "Demo logins (passwords are kept by the operator, never printed):"
  echo "  ${ADMIN_USERNAME:-<token user>}   tenant administrator; storekeeper Saule Zhumabek, chair of the count"
  [ -z "$ADMIN2_USERNAME" ] || echo "  $ADMIN2_USERNAME   second administrator; sales manager Dana Omarova, approves the opening balance"
  [ -z "$ADMIN_LOGIN_USERNAME" ] || echo "  $ADMIN_LOGIN_USERNAME   organisation administrator; linked to Aigerim Sadykova (Head office); 3 open post tasks in My Tasks"
  [ -z "$USER_LOGIN_USERNAME" ] || echo "  $USER_LOGIN_USERNAME   task worker; linked to Arman Kassymov (Sales team); 2 open post tasks in My Tasks"
  echo "Scanner codes: $BC_LAPTOP, $BC_CEMENT, $BC_MILK; location QR: $QR_R1 (Rack 01)"
  echo "Open first: Stock balances, Movements journal, Documents (every kind), the stock count (Inv-10 / Inv-18 print), Asset cards."
}
