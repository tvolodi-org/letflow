#!/usr/bin/env bash
# demo_upgrade_chain.sh -- APPLY the module upgrade chain to the demo tenants (T-1480, D-108)
#
#   BASE_URL=https://demo.example.org TENANT_SLUG=showroom ACCESS_TOKEN=... demo_upgrade_chain.sh
#
# For every demo tenant (TENANT_SLUG: a list separated by commas or spaces, default "showroom") and every installed
# module: ask the read-only plan (REQ-768, POST /api/v1/tenant/modules/:module_id/upgrade/plan); if it is pending and
# a path is available, apply it (REQ-770, POST /api/v1/tenant/modules/:module_id/upgrade, with the plan_hash of the
# plan and a rationale); ask the plan again and require up_to_date. Idempotent: a second run finds everything
# up_to_date, sends no apply and exits 0. It never sends ack_destructive: a class B step stays the administrator's
# decision and is reported as pending. It is the script infra's promote-demo.sh calls; the read-only smoke check around
# it is scripts/demo/demo_upgrade_check.sh. See docs/runbooks/demo-upgrade-notes.md.
#
# Which admin: both routes are tenant routes (:ModulesManage); the caller must be signed in INTO the demo tenant (its
# TENANT_ADMIN). A token minted through another tenant's issuer reaches that tenant (X-Tenant-Slug is read only for API
# tokens); then the first call is refused and the script stops with a STOP line.
#
# Inputs (environment only): BASE_URL; TENANT_SLUG; ACCESS_TOKEN or ADMIN_USERNAME + ADMIN_PASSWORD + ADMIN_REALM
#   (BPM_IDP_BASE_URL, BPM_IDP_CLIENT_ID); UPGRADE_RATIONALE (default "demo promote: module upgrade chain");
#   DRY_RUN=1 plans only and prints "would apply". One token serves every slug (one demo realm).
# Output (stderr): one line per tenant and module: "ok", "applied", "would apply", "pending" or "DIFF", then "RESULT:".
#   Only slugs, module ids, versions, status codes and the answer's "code" field are printed; no token, no record content.
# Exit codes (as demo_upgrade_check.sh): 0 every module upgraded or already current; 1 a DIFF line (after the apply the
#   plan still says pending); 2 a missing tool or a bad input (nothing was requested); 3 a module is still pending (no
#   path, or the apply was refused: an administrator must act); 4 a request failed (STOP line, immediate).
# Safety: the token goes through a 0600 config file in a 0700 temporary directory removed on exit; xtrace is never on.
# Needs: bash, curl, jq, mktemp.
set -euo pipefail
set +x

fail_input() { printf 'input error: %s\n' "$*" >&2; exit 2; }
for tool in curl jq mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail_input "missing tool: $tool"
done
[ -n "${BASE_URL:-}" ] || fail_input "set BASE_URL, for example https://demo.example.org"
SLUGS="${TENANT_SLUG:-showroom}"
SLUGS="${SLUGS//,/ }"
read -r -a SLUG_LIST <<<"$SLUGS"
[ "${#SLUG_LIST[@]}" -gt 0 ] || fail_input "TENANT_SLUG is empty"
for s in "${SLUG_LIST[@]}"; do
  [[ "$s" =~ ^[A-Za-z0-9_-]{1,63}$ ]] || fail_input "TENANT_SLUG has unexpected characters"
done
if [ -z "${ACCESS_TOKEN:-}" ]; then
  [ -n "${ADMIN_USERNAME:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ] && [ -n "${ADMIN_REALM:-}" ] \
    || fail_input "no sign-in: set ACCESS_TOKEN, or ADMIN_USERNAME, ADMIN_PASSWORD and ADMIN_REALM"
fi
[[ -z "${ADMIN_USERNAME:-}" || "${ADMIN_USERNAME:-}" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail_input "ADMIN_USERNAME has unexpected characters"
[[ "${ADMIN_REALM:-x}" =~ ^[A-Za-z0-9_.-]+$ ]] || fail_input "realm has unexpected characters"
RATIONALE="${UPGRADE_RATIONALE:-demo promote: module upgrade chain}"
DRY_RUN="${DRY_RUN:-0}"

API="${BASE_URL%/}/api/v1"
IDP="${BPM_IDP_BASE_URL:-https://auth.example.org}"
CLIENT_ID="${BPM_IDP_CLIENT_ID:-letflow-web}"

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
SLUG=""
api() { # METHOD PATH [BODY] -> answer in $RESP, status in $STATUS
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    STATUS=$(printf '%s' "$body" | curl -sS --max-time 120 -o "$RESP" -w '%{http_code}' -K "$AUTH_CFG" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      -H "X-Tenant-Slug: $SLUG" -X "$method" --data-binary @- "$API$path") || STATUS="000"
  else
    STATUS=$(curl -sS --max-time 120 -o "$RESP" -w '%{http_code}' -K "$AUTH_CFG" \
      -H 'Accept: application/json' -H "X-Tenant-Slug: $SLUG" -X "$method" "$API$path") || STATUS="000"
  fi
}

refusal_code() { jq -r '(.code // .error.code // .error // "unknown") | tostring | .[0:60]' "$RESP" 2>/dev/null || printf 'unknown'; }

# installed modules of the current tenant in dependency order (the rest after)
ORDER="org locations catalog_items codes stock assets"
modules_installed() {
  api GET /me/modules
  [ "$STATUS" = 200 ] || die "GET /me/modules for '$SLUG': HTTP $STATUS (tenant not found, or the token is not an administrator of this tenant)"
  jq -r --arg o "$ORDER" '([.installed_modules[].module_id]) as $ids | ($o | split(" ")) as $ord
    | (($ord | map(select(. as $x | $ids | index($x)))) + ($ids - $ord))[]' "$RESP"
}

PENDING=0
DIFF=0

plan() { # MODULE -> plan answer in $RESP; STOP when the route did not answer 200
  api POST "/tenant/modules/$1/upgrade/plan" '{}'
  [ "$STATUS" = 200 ] || die "plan of $SLUG/$1: HTTP $STATUS (token not accepted by this tenant, or the route failed)"
}

chain_module() { # MODULE
  local m="$1" from to hash body
  plan "$m"
  if [ "$(jq -r '.up_to_date' "$RESP")" = true ]; then
    log "ok      $SLUG/$m: up_to_date $(jq -r '.to_version // .from_version' "$RESP")"
    return 0
  fi
  from=$(jq -r '.from_version' "$RESP")
  to=$(jq -r '.to_version' "$RESP")
  if [ "$(jq -r '.upgrade_path_available' "$RESP")" != true ]; then
    log "pending $SLUG/$m: $from -> $to (path available: false, $(jq -r '.path_error // "no path" | tostring | .[0:80]' "$RESP"))"
    PENDING=1
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log "would apply $SLUG/$m: $from -> $to"
    PENDING=1
    return 0
  fi
  hash=$(jq -r '.plan_hash // empty' "$RESP")
  [ -n "$hash" ] || { log "pending $SLUG/$m: $from -> $to (no plan_hash in the plan)"; PENDING=1; return 0; }
  body=$(jq -nc --arg h "$hash" --arg r "$RATIONALE" '{plan_hash:$h, rationale:$r}')
  api POST "/tenant/modules/$m/upgrade" "$body"
  case "$STATUS" in
    200) ;;
    409 | 422)
      log "pending $SLUG/$m: $from -> $to (apply refused HTTP $STATUS $(refusal_code))"
      PENDING=1
      return 0
      ;;
    *) die "apply of $SLUG/$m: HTTP $STATUS" ;;
  esac
  plan "$m"
  if [ "$(jq -r '.up_to_date' "$RESP")" = true ]; then
    log "applied $SLUG/$m: $from -> $to"
  else
    log "DIFF    $SLUG/$m: after apply the plan still says $(jq -r '.from_version' "$RESP") -> $(jq -r '.to_version' "$RESP")"
    DIFF=1
  fi
}

for SLUG in "${SLUG_LIST[@]}"; do
  mods=$(modules_installed)
  [ -n "$mods" ] || log "ok      $SLUG: no installed modules"
  while read -r m; do
    [ -n "$m" ] || continue
    chain_module "$m"
  done <<<"$mods"
done

if [ "$DIFF" = 1 ]; then log "RESULT: DIFF, a plan is still pending after the apply"; exit 1; fi
if [ "$PENDING" = 1 ]; then log "RESULT: an upgrade is still pending (needs an administrator, or DRY_RUN)"; exit 3; fi
log "RESULT: every module of ${SLUG_LIST[*]} is upgraded or already current"
