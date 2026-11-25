#!/usr/bin/env bash
# qa_upgrade_chain.sh -- after a QA deploy, apply the SAFE module upgrade chain to the QA test tenants (T-2746)
#
#   BASE_URL=https://qa.example.org <TOKEN_VAR>=... [TENANTS_FILE=deploy/qa-upgrade-tenants.txt] qa_upgrade_chain.sh
#
# Same chain as scripts/demo_upgrade_chain.sh (plan, apply, plan again) for every installed module of every tenant
# listed in ONE file (one line per tenant: '<slug> <TOKEN_VAR>', '#' comments, blank lines ignored). Each tenant has its
# OWN credential (an API token is verified inside the slug's schema, an OIDC token reaches only its issuer tenant), so
# the file holds the NAME of the environment variable carrying that tenant's administrator token, never the token.
# A tenant whose variable is empty or unset is 'not run: no credential for <slug>' (nothing sent, exit 0, behind count 'unknown'). QA ONLY: it refuses a BASE_URL that is
# not a QA host (needs "qa" in the host name, override with QA_HOST_PATTERN) so production and demo never run it.
#
# It NEVER sends ack_destructive. A plan with a class B or class C entity row (a destructive / data-step change)
# FAILS the step with one line "<tenant>/<module>: <from> -> <to> needs an administrator acknowledgement" and
# nothing is applied for that module. Other modules and tenants still run.
#
# Output (stderr): one line per module ("ok", "applied", "REFUSED", "pending"), then
#   "QA tenants behind the build: N"   (N = tenants with a module still behind after the chain)
# Exit: 0 all current; 1 a DIFF (plan still pending after apply) or any behind/refused tenant; 2 bad input; 4 request failed.
# Needs: bash, curl, jq, mktemp. The token goes through a 0600 curl config file; xtrace is never on.
set -euo pipefail
set +x

fail_input() { printf 'input error: %s\n' "$*" >&2; exit 2; }
for tool in curl jq mktemp; do command -v "$tool" >/dev/null 2>&1 || fail_input "missing tool: $tool"; done
[ -n "${BASE_URL:-}" ] || fail_input "set BASE_URL, for example https://qa.example.org"
HOST="${BASE_URL#*://}"; HOST="${HOST%%/*}"; HOST="${HOST%%:*}"
PATTERN="${QA_HOST_PATTERN:-qa}"
[[ "$HOST" == *"$PATTERN"* || "$HOST" == "127.0.0.1" || "$HOST" == "localhost" ]] \
  || fail_input "BASE_URL is not a QA host (QA only; production and demo ask before run)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TENANTS_FILE="${TENANTS_FILE:-$HERE/../deploy/qa-upgrade-tenants.txt}"
[ -r "$TENANTS_FILE" ] || fail_input "tenants file not readable"
RATIONALE="${UPGRADE_RATIONALE:-qa deploy: safe module upgrade chain}"

SLUG_LIST=(); TOKEN_VARS=()
while IFS= read -r line; do
  line="${line%%#*}"
  read -r slug tvar extra <<<"$line" || true
  [ -n "$slug" ] || continue
  [[ "$slug" =~ ^[A-Za-z0-9_-]{1,63}$ ]] || fail_input "tenants file has an unexpected slug"
  [[ "$tvar" =~ ^[A-Z][A-Z0-9_]{0,63}$ && -z "${extra:-}" ]] || fail_input "tenants file: '$slug' needs exactly one token variable name"
  SLUG_LIST+=("$slug"); TOKEN_VARS+=("$tvar")
done <"$TENANTS_FILE"
[ "${#SLUG_LIST[@]}" -gt 0 ] || fail_input "tenants file lists no tenant"

API="${BASE_URL%/}/api/v1"
WORK=$(mktemp -d); chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
AUTH_CFG="$WORK/auth.cfg"; RESP="$WORK/resp.json"
log() { printf '%s\n' "$*" >&2; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 4; }

STATUS=""; SLUG=""
api() { # METHOD PATH [BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    STATUS=$(printf '%s' "$body" | curl -sS --max-time 120 -o "$RESP" -w '%{http_code}' -K "$AUTH_CFG" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' -H "X-Tenant-Slug: $SLUG" \
      -X "$method" --data-binary @- "$API$path") || STATUS="000"
  else
    STATUS=$(curl -sS --max-time 120 -o "$RESP" -w '%{http_code}' -K "$AUTH_CFG" \
      -H 'Accept: application/json' -H "X-Tenant-Slug: $SLUG" -X "$method" "$API$path") || STATUS="000"
  fi
}
plan() {
  api POST "/tenant/modules/$1/upgrade/plan" '{}'
  [ "$STATUS" = 200 ] || die "plan of $SLUG/$1: HTTP $STATUS"
}

BEHIND_SLUGS=" "
mark_behind() { case "$BEHIND_SLUGS" in *" $SLUG "*) ;; *) BEHIND_SLUGS="$BEHIND_SLUGS$SLUG " ;; esac; }
DIFF=0; NOTRUN=0

chain_module() {
  local m="$1" from to hash body destructive
  plan "$m"
  if [ "$(jq -r '.up_to_date' "$RESP")" = true ]; then
    log "ok      $SLUG/$m: up_to_date $(jq -r '.to_version // .from_version' "$RESP")"; return 0
  fi
  from=$(jq -r '.from_version' "$RESP"); to=$(jq -r '.to_version' "$RESP")
  destructive=$(jq -r '[(.entity_types // [])[] | select(.class == "B" or .class == "C")] | length' "$RESP")
  if [ "$destructive" != 0 ]; then
    log "REFUSED $SLUG/$m: $from -> $to needs an administrator acknowledgement"
    mark_behind; return 0
  fi
  if [ "$(jq -r '.upgrade_path_available' "$RESP")" != true ]; then
    log "pending $SLUG/$m: $from -> $to (no upgrade path)"; mark_behind; return 0
  fi
  hash=$(jq -r '.plan_hash // empty' "$RESP")
  [ -n "$hash" ] || { log "pending $SLUG/$m: $from -> $to (no plan_hash)"; mark_behind; return 0; }
  body=$(jq -nc --arg h "$hash" --arg r "$RATIONALE" '{plan_hash:$h, rationale:$r}')
  api POST "/tenant/modules/$m/upgrade" "$body"
  case "$STATUS" in
    200) ;;
    409 | 422) log "pending $SLUG/$m: $from -> $to (apply refused HTTP $STATUS)"; mark_behind; return 0 ;;
    *) die "apply of $SLUG/$m: HTTP $STATUS" ;;
  esac
  plan "$m"
  if [ "$(jq -r '.up_to_date' "$RESP")" = true ]; then
    log "applied $SLUG/$m: $from -> $to"
  else
    log "DIFF    $SLUG/$m: after apply the plan still says pending"; DIFF=1; mark_behind
  fi
}

ORDER="org locations catalog_items codes stock assets"
for i in "${!SLUG_LIST[@]}"; do
  SLUG="${SLUG_LIST[$i]}"; tvar="${TOKEN_VARS[$i]}"
  token="${!tvar:-}"
  if [ -z "$token" ]; then
    log "not run: no credential for $SLUG"; NOTRUN=$((NOTRUN + 1)); continue
  fi
  if [[ "$token" == *[$'\r\n"\\']* ]]; then
    log "REFUSED $SLUG: no usable credential in $tvar (nothing sent)"; mark_behind; continue
  fi
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$token" >"$AUTH_CFG" )
  unset token
  api GET /me/modules
  [ "$STATUS" = 200 ] || die "GET /me/modules for '$SLUG': HTTP $STATUS"
  mods=$(jq -r --arg o "$ORDER" '([.installed_modules[].module_id]) as $ids | ($o | split(" ")) as $ord
    | (($ord | map(select(. as $x | $ids | index($x)))) + ($ids - $ord))[]' "$RESP")
  while read -r m; do [ -n "$m" ] || continue; chain_module "$m"; done <<<"$mods"
done

N=$(printf '%s' "$BEHIND_SLUGS" | wc -w)
if [ "$NOTRUN" != 0 ]; then
  log "QA tenants behind the build: unknown"
  [ "$N" = 0 ] || log "behind among the tenants that ran: $N"
else
  log "QA tenants behind the build: $N"
fi
if [ "$N" != 0 ] || [ "$DIFF" = 1 ]; then log "RESULT: QA upgrade chain incomplete"; exit 1; fi
if [ "$NOTRUN" != 0 ]; then log "RESULT: $NOTRUN tenant(s) not run (no credential); the ones that ran are current"; exit 0; fi
log "RESULT: every module of ${SLUG_LIST[*]} is current"
