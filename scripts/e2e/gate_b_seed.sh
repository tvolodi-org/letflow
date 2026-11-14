#!/usr/bin/env bash
# gate_b_seed.sh -- master data for the GATE B browser e2e (web/tests/e2e/gate-b-stock.e2e.spec.ts) on ONE tenant.
#
# Derived from the team's gate_b_demo_seed.sh (steps 0 to 7 only). It creates NO stock document and NO count
# order: the click-through spec makes those on the screen. Every step goes through the tenant's own HTTP API as
# an interactive user (the stock routes answer 404 to an API token).
#
# What it does: installs the modules org, locations, catalog_items, codes, stock when missing; 1 legal entity,
# 1 site, 3 org units (Head office > Warehouse team, Sales team); 4 employees, the sign-in user linked to the
# storekeeper; locations Kazakhstan > Almaty > Central warehouse > Rack 01, Rack 02, Showroom; org unit <-> location
# links; units of measure and 4 catalog items (Milk is lot tracked); 2 lots of Milk; scanner codes.
#
# Inputs (environment only):
#   BASE_URL (API is $BASE_URL/api/v1), TENANT_SLUG, ADMIN_USERNAME, ADMIN_PASSWORD, ADMIN_REALM,
#   ADMIN2_USERNAME / ADMIN2_PASSWORD (optional second administrator), BPM_IDP_BASE_URL, BPM_IDP_CLIENT_ID,
#   RUN_TAG (lowercase letters and digits, default "gateb"; same tag again = same requests, safe re-run).
# Safety: the password goes to curl on stdin, the token through a 0600 config file in a temporary directory.
# Nothing secret is printed. Needs: bash, curl, jq, date (GNU), cksum.
set -euo pipefail

: "${TENANT_SLUG:?set TENANT_SLUG to the slug of the test tenant}"
for tool in curl jq cksum date; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done

API="${BASE_URL%/}/api/v1"
RUN_TAG="${RUN_TAG:-gateb}"
[[ "$RUN_TAG" =~ ^[a-z0-9]{1,20}$ ]] || { echo "RUN_TAG must be 1-20 lowercase letters or digits" >&2; exit 2; }
IDP="${BPM_IDP_BASE_URL:-https://auth.qa.bizdala.com}"
CLIENT_ID="${BPM_IDP_CLIENT_ID:-letflow-web}"

EXT="gate-b-${RUN_TAG}"
TAG="${RUN_TAG^^}"
TAG_NUM=$(printf '%s' "$RUN_TAG" | cksum | cut -d' ' -f1)

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
AUTH_CFG="$WORK/auth.cfg"
AUTH2_CFG="$WORK/auth2.cfg"
AUTH_USE="$AUTH_CFG"
RESP="$WORK/resp.json"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# sign-in (password grant, client letflow-web; same as gate_a_demo_seed.sh)
# ---------------------------------------------------------------------------------------------
get_token() { # user password realm
  local user="$1" pw="$2" realm="$3" resp token
  [ -n "$user" ] && [ -n "$pw" ] && [ -n "$realm" ] || die "no sign-in: set ADMIN_USERNAME, ADMIN_PASSWORD, ADMIN_REALM"
  [[ "$user" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "username has unexpected characters"
  [[ "$realm" =~ ^[A-Za-z0-9_.-]+$ ]] || die "realm has unexpected characters"
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
  tok=$(get_token "${ADMIN_USERNAME:-}" "${ADMIN_PASSWORD:-}" "${ADMIN_REALM:-}")
  printf 'header = "Authorization: Bearer %s"\n' "$tok" >"$AUTH_CFG"
  unset tok
  HAVE_ADMIN2=0
  if [ -n "${ADMIN2_USERNAME:-}" ] && [ -n "${ADMIN2_PASSWORD:-}" ]; then
    tok=$(get_token "$ADMIN2_USERNAME" "$ADMIN2_PASSWORD" "${ADMIN2_REALM:-${ADMIN_REALM:-}}")
    printf 'header = "Authorization: Bearer %s"\n' "$tok" >"$AUTH2_CFG"
    unset tok
    HAVE_ADMIN2=1
  fi
}

# ---------------------------------------------------------------------------------------------
# HTTP helpers. api METHOD PATH [BODY]: body to $RESP, status in $STATUS. Nothing secret is printed.
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

# write PATH BODY LABEL -> prints the record id on stdout; stops on anything but 200/201.
write() {
  local path="$1" body="$2" label="$3" id
  api POST "$path" "$body"
  case "$STATUS" in
    200 | 201) ;;
    401) die "$label: 401, the token was refused" ;;
    403) die "$label: 403, the user lacks the permission (is it the tenant administrator?)" ;;
    404) die "$label: 404 (module not installed, or a referenced record not found)" ;;
    *) die "$label: HTTP $STATUS $(reason)" ;;
  esac
  id=$(jq -r '.record_id // .id // empty' "$RESP")
  [ -n "$id" ] || die "$label: no record_id in the answer"
  log "ok   $label"
  printf '%s' "$id"
}

key() { printf 'gate-b:%s:%s' "$RUN_TAG" "$1"; }

code_state() { # exact value -> "record_id status" (empty when not found)
  local body
  body=$(jq -nc --arg v "$1" '{entity_type:"code_tag", filters:[{field:"value", op:"eq", value:$v}]}')
  api POST /entities/query "$body"
  [ "$STATUS" = 200 ] || die "query code_tag: HTTP $STATUS $(reason)"
  jq -r '.items[0] // empty | "\(.record_id) \(.field_values.status)"' "$RESP"
}

# ---------------------------------------------------------------------------------------------
# 0. modules
# ---------------------------------------------------------------------------------------------
log "== 0. modules"
api GET /me/modules
[ "$STATUS" = 200 ] || die "GET /me/modules: HTTP $STATUS (token or tenant problem)"
installed=$(jq -r '.installed_modules[].module_id' "$RESP")
for m in org locations catalog_items codes stock assets; do   # stock depends on the other four, assets on those and stock
  if printf '%s\n' "$installed" | grep -qx "$m"; then
    log "skip module $m (installed)"
    continue
  fi
  api POST /tenant/modules "$(jq -nc --arg m "$m" '{module_id:$m, rationale:"GATE B demo tenant (gate_b_seed.sh)"}')"
  case "$STATUS" in
    201) log "ok   module $m installed" ;;
    409) log "skip module $m (already installed)" ;;
    *) die "install $m: HTTP $STATUS $(reason)" ;;
  esac
done

# ---------------------------------------------------------------------------------------------
# 1. legal entity, site, org units
# ---------------------------------------------------------------------------------------------
log "== 1. organization"
BASE10=$(printf '%010d' $((TAG_NUM % 10000000000)))
BIN1="${BASE10}01"

LE1=$(write /modules/org/legal-entities "$(jq -nc --arg c "${TAG}-LE1" --arg n "Demo Trading LLP" --arg b "$BIN1" --arg s "$EXT" --arg k "$(key le1)" \
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
# 2. employees (no positions needed for the stock screens)
# ---------------------------------------------------------------------------------------------
log "== 2. employees"
employee() { # code full_name org_unit_id
  write /modules/org/employees "$(jq -nc --arg c "$1" --arg n "$2" --arg u "$3" --arg s "$EXT" --arg k "$(key "emp:$1")" \
    '{code:$c, full_name:$n, org_unit_id:$u, external_ref_system:$s, external_ref_id:$c, idempotency_key:$k}')" "employee $1"
}
E_KEEP=$(employee "${TAG}-E001" "Saule Zhumabek" "$U_WH")      # storekeeper, chair of the count
E_WH2=$(employee "${TAG}-E002" "Yerlan Mukanov" "$U_WH")
E_SALES=$(employee "${TAG}-E003" "Dana Omarova" "$U_SALES")    # sales manager, member of the commission
E_SALES2=$(employee "${TAG}-E004" "Arman Kassymov" "$U_SALES")

# Link the sign-in users to employees. A count needs a chair with a user (chair_without_user), and only
# the chair or a commission member may type quantities. The accounts exist after the first sign-in.
link_user() { # username employee_id label
  local uid
  api GET "/identity/users?search=$1&page_size=50"
  [ "$STATUS" = 200 ] || die "find user $1: HTTP $STATUS $(reason)"
  uid=$(jq -r --arg u "$1" '[.items[] | select(.username == $u)][0].id // empty' "$RESP")
  [ -n "$uid" ] || { log "skip link $3: no account $1 yet (sign in once as that user, then run again)"; return 0; }
  api PATCH "/modules/org/employees/$2" "$(jq -nc --arg u "$uid" --arg k "$(key "link:$3")" '{user_id:$u, idempotency_key:$k}')"
  case "$STATUS" in
    200) log "ok   $3 linked to a user account" ;;
    *) die "link $3: HTTP $STATUS $(reason)" ;;
  esac
}
link_user "${ADMIN_USERNAME:-}" "$E_KEEP" "storekeeper"
if [ "$HAVE_ADMIN2" = 1 ]; then
  # the second user must have signed in once for the account to exist
  AUTH_USE="$AUTH2_CFG"; api GET /me/modules; AUTH_USE="$AUTH_CFG"
  link_user "$ADMIN2_USERNAME" "$E_SALES" "sales-manager"
fi

# ---------------------------------------------------------------------------------------------
# 3. location tree
# ---------------------------------------------------------------------------------------------
log "== 3. locations"
node_lookup() { # code -> record_id of an existing location node (re-run safety), empty when none
  api POST /entities/query "$(jq -nc --arg v "$1" '{entity_type:"location_node", filters:[{field:"code", op:"eq", value:$v}]}')"
  [ "$STATUS" = 200 ] && jq -r '.items[0].record_id // empty' "$RESP"
}
node() { # code name kind parent_id|"" segment|"" pattern|""
  # A re-run: the server refuses a replay of a composed-address node as idempotency_key_reuse (409);
  # then the existing node is looked up by its code and reused.
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

# ---------------------------------------------------------------------------------------------
# 4. links org unit <-> location. Sales team is linked to the Showroom only.
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
  ["PCS","Piece"], ["KG","Kilogram"], ["L","Litre"]
] | map({external_ref:{system:$s, id:.[0]}, field_values:{code:($t + "-" + .[0]), name:.[1], active:true}})')
uom_results=$(import_json catalog_uom "$uoms" "units of measure")
uom_id() { printf '%s' "$uom_results" | jq -r --arg id "$1" '.[] | select(.external_ref.id == $id) | .record_id // empty'; }
UOM_PCS=$(uom_id PCS); UOM_KG=$(uom_id KG); UOM_L=$(uom_id L)
for v in UOM_PCS UOM_KG UOM_L; do [ -n "${!v}" ] || die "units: no record_id for $v in the import answer"; done

# tracking_policy: none | lot | serial | expiry. Milk needs a lot (the receipt then refuses a line without
# one: "This item needs a lot."); the others take no lot ("This item does not take a lot.").
# base_uom_id holds the EXTERNAL id of the unit (same system), not its record id.
items=$(jq -nc --arg s "$EXT" --arg t "$TAG" '[
  ["LAPTOP","Laptop 14 inch","PCS","none"],
  ["CEMENT","Cement M400","KG","none"],
  ["MILK","Milk 2.5% 1 l","L","lot"],
  ["HELMET","Safety helmet","PCS","none"]
] | map({external_ref:{system:$s, id:("ITM-" + .[0])},
         field_values:{code:($t + "-ITM-" + .[0]), name:.[1], base_uom_id:.[2], kind:"material", active:true, tracking_policy:.[3]}})')
item_results=$(import_json catalog_item "$items" "catalog items")
item_id() { printf '%s' "$item_results" | jq -r --arg id "ITM-$1" '.[] | select(.external_ref.id == $id) | .record_id // empty'; }
I_LAPTOP=$(item_id LAPTOP); I_CEMENT=$(item_id CEMENT); I_MILK=$(item_id MILK); I_HELMET=$(item_id HELMET)
for v in I_LAPTOP I_CEMENT I_MILK I_HELMET; do [ -n "${!v}" ] || die "catalog items: no record_id for $v in the import answer"; done

# ---------------------------------------------------------------------------------------------
# 6. lots of Milk
# ---------------------------------------------------------------------------------------------
log "== 6. lots"
lot() { # item_id code producer mark expiry
  write /modules/catalog_items/lots "$(jq -nc --arg i "$1" --arg c "$2" --arg p "$3" --arg m "$4" --arg e "$5" --arg s "$EXT" --arg k "$(key "lot:$2")" \
    '{item_id:$i, code:$c, producer:$p, mark:$m, expiry_date:$e, external_ref_system:$s, external_ref_id:$c, idempotency_key:$k}')" "lot $2"
}
EXP1=$(date -u -d '+60 days' +%F); EXP2=$(date -u -d '+90 days' +%F)
LOT_M1=$(lot "$I_MILK" "${TAG}-M-A" "Foodmaster" "2.5% fat" "$EXP1")
LOT_M2=$(lot "$I_MILK" "${TAG}-M-B" "Foodmaster" "2.5% fat" "$EXP2")

# ---------------------------------------------------------------------------------------------
# 7. codes for the keyboard scanner (the count scan resolves them)
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

log "== done (masters and codes). Data set '$RUN_TAG': codes start with $TAG-, external ref system $EXT."
log "   Barcodes: $BC_LAPTOP, $BC_CEMENT, $BC_MILK. Location QR: $QR_R1 (Rack 01)."
