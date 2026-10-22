#!/usr/bin/env bash
# seed_uat_email_verified.sh
#
# UAT-only seed (GH #2503, T-0179). Sets emailVerified on the named seeded UAT test accounts
# through the Keycloak admin REST API. The first-login admin binding (GH #2493) fires only on a
# strict email_verified == true claim, so a binding scenario run against an unverified seeded
# user passes, or fails, for the wrong reason. Precondition for that scenario: the accounts it
# signs in with have emailVerified=true (run this seed first, on QA only).
#
# Usage:
#   scripts/seed_uat_email_verified.sh [true|false]   (default true)
#
# Environment (the acceptance workflow's env_file, .env.uat in the team root; never committed):
#   BPM_IDP_BASE_URL             must be the QA identity provider, https://auth.qa.bizdala.com
#   UAT_KC_ADMIN_CLIENT_ID       a confidential client in each named realm, with service account
#                                and the manage-users role in that realm only
#   UAT_KC_ADMIN_CLIENT_SECRET   that client's secret; read here, never printed, never in argv
#   UAT_EMAIL_VERIFIED_USERS     space-separated realm:username pairs, the seeded UAT test accounts
#                                and nothing else (e.g. "bilimbaga:candidate-user")
#
# Guarantees:
#   - Refuses, before any request, a realm outside the UAT allowlist or an identity provider
#     other than the QA one. Production realms are never named here.
#   - Idempotent: an account already at the target value is left alone, so a re-run converges.
#   - Rollback: run with `false` to set the same accounts back to unverified.
#   - CURL overrides the curl binary (tests use it). The secret and the token reach curl on
#     stdin, never in argv, and are not echoed.
set -euo pipefail

# The QA realms of the acceptance corpus (uat_creds.sh, .env.uat). Anything else is refused.
uat_realms="bpm-default bilimbaga meridian swiftroute vortex"
qa_idp="https://auth.qa.bizdala.com"

mode="${1:-true}"
case "$mode" in
  true)  target=true ;;
  false) target=false ;;
  *) echo "usage: seed_uat_email_verified.sh [true|false]" >&2; exit 2 ;;
esac

idp="${BPM_IDP_BASE_URL:-}"
[ "$idp" = "$qa_idp" ] || { echo "refusing: BPM_IDP_BASE_URL is not the QA identity provider ($qa_idp)" >&2; exit 1; }
[ -n "${UAT_KC_ADMIN_CLIENT_ID:-}" ] && [ -n "${UAT_KC_ADMIN_CLIENT_SECRET:-}" ] \
  || { echo "refusing: UAT_KC_ADMIN_CLIENT_ID and UAT_KC_ADMIN_CLIENT_SECRET must be set (.env.uat)" >&2; exit 1; }
[ -n "${UAT_EMAIL_VERIFIED_USERS:-}" ] \
  || { echo "refusing: UAT_EMAIL_VERIFIED_USERS names no accounts" >&2; exit 1; }

# Validate every pair before the first request, so a bad entry changes nothing.
pairs=()
for pair in $UAT_EMAIL_VERIFIED_USERS; do
  realm="${pair%%:*}"; user="${pair#*:}"
  [ "$realm" != "$pair" ] && [ -n "$user" ] || { echo "refusing: '$pair' is not realm:username" >&2; exit 1; }
  case " $uat_realms " in
    *" $realm "*) ;;
    *) echo "refusing: '$realm' is not a UAT realm (allowed: $uat_realms)" >&2; exit 1 ;;
  esac
  [[ "$user" =~ ^[A-Za-z0-9_.@-]+$ ]] || { echo "refusing: username '$user' has unexpected characters" >&2; exit 1; }
  pairs+=("$realm:$user")
done

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl_bin="${CURL:-curl}"
failed=0

# token <realm>: client-credentials grant against the realm's own token endpoint.
token_for() {
  local realm="$1" resp tok
  resp=$($curl_bin -s --max-time 30 --config - "$idp/realms/$realm/protocol/openid-connect/token" <<EOF
data = "grant_type=client_credentials"
data-urlencode = "client_id=$UAT_KC_ADMIN_CLIENT_ID"
data-urlencode = "client_secret=$UAT_KC_ADMIN_CLIENT_SECRET"
EOF
  ) || return 1
  tok=$(printf '%s' "$resp" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
  [ -n "$tok" ] || return 1
  printf '%s' "$tok"
}

for pair in "${pairs[@]}"; do
  realm="${pair%%:*}"; user="${pair#*:}"
  label="$realm/$user"
  tok=$(token_for "$realm") || { echo "$label: no admin token for realm $realm"; failed=1; continue; }
  api="$idp/admin/realms/$realm/users"

  body=$($curl_bin -s --max-time 30 --config - "$api?username=$user&exact=true" <<EOF
header = "Authorization: Bearer $tok"
EOF
  ) || { echo "$label: user lookup failed"; failed=1; continue; }
  if [ "$(grep -o '"username":"' <<<"$body" | wc -l)" != 1 ]; then
    echo "$label: no such seeded user in realm $realm"; failed=1; continue
  fi

  current=$(grep -o '"emailVerified":\(true\|false\)' <<<"$body" | head -1 | cut -d: -f2)
  id=$(grep -o '"id":"[^"]*"' <<<"$body" | head -1 | sed 's/^"id":"\(.*\)"$/\1/')
  [ -n "$current" ] && [ -n "$id" ] || { echo "$label: unexpected user representation"; failed=1; continue; }

  if [ "$current" = "$target" ]; then
    echo "$label: already emailVerified=$target"
    continue
  fi

  # Write the full representation back with only emailVerified changed (no partial PUT).
  rep="${body#[}"; rep="${rep%]}"
  if [ "$target" = true ]; then
    rep=${rep/\"emailVerified\":false/\"emailVerified\":true}
  else
    rep=${rep/\"emailVerified\":true/\"emailVerified\":false}
  fi
  printf '%s' "$rep" > "$tmp"

  code=$($curl_bin -s -o /dev/null -w '%{http_code}' --max-time 30 -X PUT \
    -H 'Content-Type: application/json' -d "@$tmp" --config - "$api/$id" <<EOF
header = "Authorization: Bearer $tok"
EOF
  ) || code=000
  if [ "$code" = 204 ]; then
    echo "$label: emailVerified $current -> $target"
  else
    echo "$label: update failed (HTTP $code)"; failed=1
  fi
done

exit "$failed"
