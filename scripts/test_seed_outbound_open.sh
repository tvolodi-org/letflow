#!/usr/bin/env bash
# Self-test for scripts/lib/seed_outbound_open.sh and its use in the four QA seed scripts
# (T-2730). A fake `curl` on PATH plays the API; no network, no real token.
set -u
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail=0
CANARY="SECRET_CANARY_T2730"

mkdir -p "$t/bin"
cat > "$t/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Fake curl: logs "METHOD path [body]" to $FAKE_LOG; the allow-list lives in $FAKE_STATE (JSON lines).
method=GET; body=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) [[ "$2" == "@-" ]] && body=$(cat); shift 2 ;;
    -H|-o) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="/${url#*//*/}"
echo "$method $path $body" >> "$FAKE_LOG"
case "$method $path" in
  "GET /api/v1/me/access") echo "{\"permissions\":$FAKE_PERMS}" ;;
  "GET /api/v1/outbound-destinations")
    jq -cs '{entries: .}' "$FAKE_STATE" ;;
  "POST /api/v1/outbound-destinations")
    printf '%s' "$body" | jq -c '{channel, destination: (.destination // null)}' >> "$FAKE_STATE"
    echo '{}' ;;
  "GET /api/v1/definitions?"*) echo '{"items":[]}' ;;
  "POST /api/v1/definitions") echo '{"id":"def-1","status":"draft"}' ;;
  "POST /api/v1/definitions/def-1/activate")
    if [[ "${FAKE_STRICT:-1}" == 1 ]] && ! grep -q '"destination":null' "$FAKE_STATE"; then
      echo "curl: (22) The requested URL returned error: 422 ${FAKE_URL_LEAK:-}" >&2; exit 22
    fi
    echo '{"id":"def-1","name":"n","version":"1","status":"active"}' ;;
  *) echo '{}' ;;
esac
FAKE
chmod +x "$t/bin/curl"

ok() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

setup_run() {
  : > "$t/log"; : > "$t/state"
  export FAKE_LOG="$t/log" FAKE_STATE="$t/state"
  export FAKE_PERMS='["DefinitionsRead","DefinitionsWrite","OutboundDestinationsManage"]'
  export PATH="$t/bin:$PATH" QA_URL="https://qa.example.test" QA_AUTH_TOKEN="tok"
}

# --- 1. host collection: every endpoint of the payload, userinfo/port stripped, dynamic skipped
two='{"graph":{"nodes":[
 {"node_type":"SERVICE_TASK","attributes":{"endpoint":"https://'$CANARY'@Host-A.example:8443/x"}},
 {"node_type":"SERVICE_TASK","attributes":{"endpoint":"https://host-b.example/y?z=1"}},
 {"node_type":"SERVICE_TASK","attributes":{"endpoint":"https://{{variables.h}}/dyn"}},
 {"node_type":"HUMAN_TASK","attributes":{}}]}}'
(
  setup_run
  # shellcheck source=lib/seed_outbound_open.sh
  source "$here/lib/seed_outbound_open.sh"
  hosts=$(seed_payload_hosts "$two")
  [ "$hosts" = $'host-a.example\nhost-b.example' ]
); ok "two-host payload yields both bare hosts" $?

# --- 2. seed_open_outbound opens channel and both hosts; second run adds nothing
(
  setup_run
  AUTH_HEADER="Authorization: Bearer tok"; API="$QA_URL/api/v1"
  source "$here/lib/seed_token_check.sh"
  source "$here/lib/seed_outbound_open.sh"
  out=$(seed_open_outbound "$two" 2>&1) || exit 1
  [ "$(grep -c '^POST /api/v1/outbound-destinations' "$t/log")" = 3 ] || exit 1
  grep -q '"destination":"host-a.example"' "$t/state" && grep -q '"destination":"host-b.example"' "$t/state" || exit 1
  [[ "$out" != *"$CANARY"* ]] || exit 1
  : > "$t/log"
  out2=$(seed_open_outbound "$two" 2>&1) || exit 1
  [ "$(grep -c '^POST' "$t/log")" = 0 ] && [[ "$out2" != *"$CANARY"* ]]
); ok "channel + both hosts opened, idempotent second run, no canary" $?

# --- 3. token without the permission: refuses, nothing posted
(
  setup_run
  export FAKE_PERMS='["DefinitionsRead","DefinitionsWrite"]'
  AUTH_HEADER="Authorization: Bearer tok"; API="$QA_URL/api/v1"
  source "$here/lib/seed_token_check.sh"
  source "$here/lib/seed_outbound_open.sh"
  ( seed_open_outbound "$two" ) >/dev/null 2>&1 && exit 1
  ! grep -q '^POST /api/v1/outbound-destinations' "$t/log"
); ok "token without OutboundDestinationsManage is refused before any POST" $?

# --- 4. the four seed scripts: allow-list opened before the first activate, canary absent
for s in swiftroute swiftroute_incident meridian vortex; do
  (
    setup_run
    export SERVICE_TASK_MOCK_BASE_URL="https://$CANARY@httpbin.org/anything"
    export FAKE_URL_LEAK="https://$CANARY@httpbin.org/anything"
    out=$(bash "$here/seed_${s}_definition.sh" 2>&1); rc=$?
    [ "$rc" = 0 ] || { echo "$out" | tail -5; exit 1; }
    [[ "$out" != *"$CANARY"* ]] || { echo "canary in output"; exit 1; }
    first_act=$(grep -n '/activate' "$t/log" | head -1 | cut -d: -f1)
    last_open=$(grep -n '^POST /api/v1/outbound-destinations' "$t/log" | tail -1 | cut -d: -f1)
    [ -n "$first_act" ] && [ -n "$last_open" ] && [ "$last_open" -lt "$first_act" ]
  ); ok "seed_${s}_definition.sh: opens list before activate, no canary" $?
done

# --- 5. a failing outbound POST never echoes the credential
(
  setup_run
  export QA_URL="https://$CANARY@qa.example.test"
  cat > "$t/bin/curl" <<'F2'
#!/usr/bin/env bash
case "$*" in *me/access*) echo '{"permissions":["OutboundDestinationsManage"]}'; exit 0 ;; esac
case "$*" in *GET*|*outbound-destinations*) [[ "$*" == *-X* ]] || { echo '{"entries":[]}'; exit 0; } ;; esac
echo "curl: (22) The requested URL returned error: 403" >&2; exit 22
F2
  AUTH_HEADER="Authorization: Bearer tok"; API="https://qa.example.test/api/v1"
  source "$here/lib/seed_token_check.sh"
  source "$here/lib/seed_outbound_open.sh"
  out=$( ( seed_open_outbound "$two" ) 2>&1 ); rc=$?
  [ "$rc" != 0 ] && [[ "$out" != *"$CANARY"* ]]
); ok "failing POST exits non-zero without leaking the canary" $?

# --- 6. query / fragment / encoded credentials never reach the printable base URL
(
  source "$here/lib/seed_service_task_base.sh" 2>/dev/null
  for u in "https://httpbin.org/anything?api_key=$CANARY" \
           "https://httpbin.org/anything?api%5Fkey=%53ECRET_CANARY_T2730&k=$CANARY" \
           "https://httpbin.org/anything#tok=$CANARY" \
           "https://u:$CANARY@httpbin.org/a/b?x=1"; do
    r=$(_st_redact "$u")
    [[ "$r" != *"$CANARY"* && "$r" != *"?"* && "$r" != *"#"* && "$r" != *"%53"* ]] || { echo "leak: $r"; exit 1; }
    [ "$r" = "https://httpbin.org" ] || { echo "unexpected: $r"; exit 1; }
  done
); ok "_st_redact keeps scheme://host only (query, fragment, userinfo dropped)" $?

for s in swiftroute swiftroute_incident meridian vortex; do
  (
    setup_run
    export SERVICE_TASK_MOCK_BASE_URL="https://httpbin.org/anything?api_key=$CANARY"
    export FAKE_URL_LEAK="$SERVICE_TASK_MOCK_BASE_URL"
    out=$(bash "$here/seed_${s}_definition.sh" 2>&1)
    [[ "$out" != *"$CANARY"* ]] || { echo "query canary in output"; exit 1; }
  ); ok "seed_${s}_definition.sh: query canary absent from output" $?
done

exit "$fail"
