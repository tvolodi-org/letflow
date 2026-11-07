#!/usr/bin/env bash
# stack_up.sh -- bring up the local stack the GATE B browser e2e needs, and print the env the specs read.
#
#   bash scripts/e2e/stack_up.sh          start Postgres + Keycloak (docker compose project letflow-e2e), migrate,
#                                         seed the bpm-default tenant, start the backend on :4000, create the second
#                                         approver in Keycloak, set the access token lifespan, seed the master data
#   bash scripts/e2e/stack_up.sh --down   stop the backend and the containers (volumes removed)
#
# Result: .e2e/env (KEY=VALUE lines, no export) and, when GITHUB_ENV is set, the same lines appended to it.
# The web dev server is started by Playwright itself (web/playwright.config.ts webServer).
#
# The realm template (priv/keycloak/realms/bpm-default.json) is NOT edited: the second approver and the short
# token lifespan are set through the Keycloak admin REST API. The lifespan (E2E_TOKEN_LIFESPAN, default 90 s) is
# the access token lifespan of the realm; oidc-client-ts renews 60 s before expiry, so 60 s would refresh at
# once and prove nothing about "a refresh before expiry".
#
# Local defaults only (throwaway containers): Keycloak admin/admin, tenant-admin-user/tenant-admin-pass from
# the realm template. Needs: docker compose, mix, curl, jq.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT=$(pwd)
OUT="$ROOT/.e2e"
mkdir -p "$OUT"

export LETFLOW_DB_PORT="${LETFLOW_DB_PORT:-5462}"
export LETFLOW_KEYCLOAK_PORT="${LETFLOW_KEYCLOAK_PORT:-8082}"
PROJECT="${E2E_COMPOSE_PROJECT:-letflow-e2e}"
API_PORT="${PORT:-4000}"
IDP="http://localhost:${LETFLOW_KEYCLOAK_PORT}"
REALM="bpm-default"
LIFESPAN="${E2E_TOKEN_LIFESPAN:-90}"
KC_USER="${KC_ADMIN_USER:-admin}"
KC_PASS="${KC_ADMIN_PASSWORD:-admin}"
APPROVER="${E2E_ADMIN2_USER:-e2e-approver}"
APPROVER_PW="${E2E_ADMIN2_PASSWORD:-e2e-approver-pass}"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--down" ]; then
  [ -f "$OUT/backend.pid" ] && kill "$(cat "$OUT/backend.pid")" 2>/dev/null || true
  rm -f "$OUT/backend.pid"
  docker compose -p "$PROJECT" down -v
  exit 0
fi

for tool in docker mix curl jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done

log "== 1. postgres + keycloak"
docker compose -p "$PROJECT" up -d postgres keycloak --wait

log "== 2. migrate and seed the $REALM tenant"
export LETFLOW_DEV_DB_CONFIRMED=1
# Required by Letflow.Secrets in every environment; a throwaway key for this throwaway stack.
export LETFLOW_SECRETS_MASTER_KEY="${LETFLOW_SECRETS_MASTER_KEY:-$(openssl rand -hex 32)}"
export LETFLOW_LOGIN_DIRECTORY_PEPPER="${LETFLOW_LOGIN_DIRECTORY_PEPPER:-$(openssl rand -hex 32)}"
export LETFLOW_LOGIN_DIRECTORY_PEPPER_ID="${LETFLOW_LOGIN_DIRECTORY_PEPPER_ID:-e2e1}"
mix deps.get >&2
mix ecto.setup >&2
mix letflow.seed >&2

log "== 3. backend on :$API_PORT"
if [ -f "$OUT/backend.pid" ] && kill -0 "$(cat "$OUT/backend.pid")" 2>/dev/null; then
  log "backend already running"
else
  # Allow the web dev server origin explicitly; the default dev/test list already has it, this only documents it.
  PORT="$API_PORT" nohup mix run --no-halt >"$OUT/backend.log" 2>&1 &
  echo $! >"$OUT/backend.pid"
fi
for _ in $(seq 1 90); do
  curl -fsS "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1 || { tail -n 40 "$OUT/backend.log" >&2; die "backend did not answer /health"; }

log "== 4. keycloak: second approver, token lifespan $LIFESPAN s"
KCT=$(curl -fsS "$IDP/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d grant_type=password --data-urlencode "username=$KC_USER" --data-urlencode "password=$KC_PASS" | jq -r .access_token)
[ -n "$KCT" ] && [ "$KCT" != null ] || die "no Keycloak admin token"
kc() { curl -sS -H "Authorization: Bearer $KCT" -H 'Content-Type: application/json' "$@"; }

# Realm lifespan. A client attribute access.token.lifespan would override it: clear it on letflow-web.
kc -X PUT "$IDP/admin/realms/$REALM" -d "$(jq -nc --argjson l "$LIFESPAN" '{accessTokenLifespan:$l}')" -o /dev/null -w '%{http_code}\n' >&2
CID=$(kc "$IDP/admin/realms/$REALM/clients?clientId=letflow-web" | jq -r '.[0].id')
CLIENT=$(kc "$IDP/admin/realms/$REALM/clients/$CID")
OVERRIDE=$(jq -r '.attributes["access.token.lifespan"] // empty' <<<"$CLIENT")
if [ -n "$OVERRIDE" ]; then
  log "client letflow-web overrides the lifespan ($OVERRIDE s): clearing it"
  kc -X PUT "$IDP/admin/realms/$REALM/clients/$CID" -d "$(jq -c 'del(.attributes["access.token.lifespan"])' <<<"$CLIENT")" -o /dev/null
fi

if [ "$(kc "$IDP/admin/realms/$REALM/users?username=$APPROVER&exact=true" | jq 'length')" = 0 ]; then
  kc -X POST "$IDP/admin/realms/$REALM/users" -o /dev/null -d "$(jq -nc --arg u "$APPROVER" --arg p "$APPROVER_PW" \
    '{username:$u, email:($u+"@letflow.local"), firstName:"E2E", lastName:"Approver", enabled:true, emailVerified:true,
      requiredActions:[], credentials:[{type:"password", value:$p, temporary:false}]}')"
fi
UID2=$(kc "$IDP/admin/realms/$REALM/users?username=$APPROVER&exact=true" | jq -r '.[0].id')
ROLE=$(kc "$IDP/admin/realms/$REALM/roles/TENANT_ADMIN")
kc -X POST "$IDP/admin/realms/$REALM/users/$UID2/role-mappings/realm" -d "[$ROLE]" -o /dev/null

log "== 5. master data (scripts/e2e/gate_b_seed.sh)"
RUN_TAG="${E2E_SEED_TAG:-gateb}" BASE_URL="http://127.0.0.1:${API_PORT}" TENANT_SLUG="$REALM" \
  ADMIN_USERNAME=tenant-admin-user ADMIN_PASSWORD=tenant-admin-pass ADMIN_REALM="$REALM" \
  ADMIN2_USERNAME="$APPROVER" ADMIN2_PASSWORD="$APPROVER_PW" BPM_IDP_BASE_URL="$IDP" \
  bash scripts/e2e/gate_b_seed.sh

cat >"$OUT/env" <<EOF
E2E_BASE_URL=http://127.0.0.1:4173
E2E_TENANT_SLUG=$REALM
E2E_ADMIN_USER=tenant-admin-user
E2E_ADMIN_PASSWORD=tenant-admin-pass
E2E_ADMIN2_USER=$APPROVER
E2E_ADMIN2_PASSWORD=$APPROVER_PW
E2E_SEED_TAG=${E2E_SEED_TAG:-gateb}
BPM_IDP_BASE_URL=$IDP
EOF
[ -n "${GITHUB_ENV:-}" ] && cat "$OUT/env" >>"$GITHUB_ENV"
log "== stack is up. Env for the specs: $OUT/env"
