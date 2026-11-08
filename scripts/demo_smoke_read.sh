#!/usr/bin/env bash
# demo_smoke_read.sh -- smoke check of a Letflow instance over its real HTTP path (T-1473, O2).
#
# Signs in as the smoke user with the Keycloak password grant, then reads ONE authenticated endpoint
# (default GET /api/v1/me/modules: every role may call it, it is tenant-scoped through the token's realm, so
# one call proves realm discovery, token verification, user provisioning and the tenant schema).
#
# Inputs (environment only; nothing secret in this file):
#   SMOKE_PASSWORD_FILE  file holding the smoke user's password (one line)                  [required]
#   BASE_URL             the backend, default http://127.0.0.1:3311
#   KEYCLOAK_URL         the identity provider, default https://auth-demo.letflow.ai-dala.com
#   SMOKE_REALM          default demo-showroom
#   SMOKE_CLIENT_ID      default letflow-demo-smoke (the client with direct grants)
#   SMOKE_USER           default demo-smoke
#   SMOKE_READ_PATH      default /api/v1/me/modules
#   EXPECT_JQ            jq filter that must be true on the answer,
#                        default '(.installed_modules | length) >= 1'
# Output: one line, `PASS login+read <path> modules=<n>` or `FAIL <step>: HTTP <code>`. Never the password, the
# token or the answer body. Exit 0 pass, 1 fail, 2 bad input (nothing was requested).
# Needs: bash, curl, jq, mktemp.
set -euo pipefail
set +x

fail_input() { printf 'input error: %s\n' "$*" >&2; exit 2; }
for tool in curl jq mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail_input "missing tool: $tool"
done

BASE_URL="${BASE_URL:-http://127.0.0.1:3311}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://auth-demo.letflow.ai-dala.com}"
SMOKE_REALM="${SMOKE_REALM:-demo-showroom}"
SMOKE_CLIENT_ID="${SMOKE_CLIENT_ID:-letflow-demo-smoke}"
SMOKE_USER="${SMOKE_USER:-demo-smoke}"
SMOKE_READ_PATH="${SMOKE_READ_PATH:-/api/v1/me/modules}"
EXPECT_JQ="${EXPECT_JQ:-(.installed_modules | length) >= 1}"

[ -n "${SMOKE_PASSWORD_FILE:-}" ] || fail_input "set SMOKE_PASSWORD_FILE to the file holding the smoke user's password"
[ -f "$SMOKE_PASSWORD_FILE" ] && [ -r "$SMOKE_PASSWORD_FILE" ] || fail_input "SMOKE_PASSWORD_FILE is not a readable regular file"
[ -s "$SMOKE_PASSWORD_FILE" ] || fail_input "SMOKE_PASSWORD_FILE is empty"
[[ "$SMOKE_REALM" =~ ^[A-Za-z0-9_.-]+$ ]] || fail_input "SMOKE_REALM has unexpected characters"
[[ "$SMOKE_CLIENT_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || fail_input "SMOKE_CLIENT_ID has unexpected characters"
[[ "$SMOKE_USER" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail_input "SMOKE_USER has unexpected characters"
[[ "$SMOKE_READ_PATH" =~ ^/[A-Za-z0-9_./?=\&-]*$ ]] || fail_input "SMOKE_READ_PATH has unexpected characters"

# The password: strip a trailing CR/LF only; an inner newline means the wrong file.
PW=$(cat "$SMOKE_PASSWORD_FILE")
PW="${PW%$'\r'}"
case "$PW" in *$'\n'*) fail_input "SMOKE_PASSWORD_FILE holds more than one line" ;; esac
[ -n "$PW" ] || fail_input "SMOKE_PASSWORD_FILE holds an empty password"

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
umask 077
RESP="$WORK/resp.json"

# Token request: every field goes to curl on stdin, nothing secret on argv.
code=$(curl -sS --max-time 30 -o "$RESP" -w '%{http_code}' --config - \
  "${KEYCLOAK_URL%/}/realms/$SMOKE_REALM/protocol/openid-connect/token" <<EOF || true
data-urlencode = "password=$PW"
data = "grant_type=password"
data-urlencode = "client_id=$SMOKE_CLIENT_ID"
data-urlencode = "username=$SMOKE_USER"
EOF
)
unset PW
[ "${code:-000}" = "200" ] || { printf 'FAIL login: HTTP %s\n' "${code:-000}"; exit 1; }
token=$(jq -r '.access_token // empty' "$RESP" 2>/dev/null || true)
[ -n "$token" ] || { printf 'FAIL login: HTTP %s (no access token in the answer)\n' "$code"; exit 1; }
printf 'header = "Authorization: Bearer %s"\n' "$token" >"$WORK/auth.cfg"
unset token

code=$(curl -sS --max-time 30 -o "$RESP" -w '%{http_code}' -K "$WORK/auth.cfg" \
  -H 'Accept: application/json' "${BASE_URL%/}$SMOKE_READ_PATH" || true)
[ "${code:-000}" = "200" ] || { printf 'FAIL read: HTTP %s\n' "${code:-000}"; exit 1; }
jq -e "$EXPECT_JQ" "$RESP" >/dev/null 2>&1 || { printf 'FAIL read: HTTP 200 but the answer does not satisfy EXPECT_JQ\n'; exit 1; }
n=$(jq -r '(.installed_modules // []) | length' "$RESP" 2>/dev/null || echo 0)
printf 'PASS login+read %s modules=%s\n' "$SMOKE_READ_PATH" "$n"
