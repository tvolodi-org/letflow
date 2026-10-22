#!/usr/bin/env bash
# seed_uat_email_verified_for_group.sh <scenarios dir>
#
# Seed step of the acceptance workflow (GH #2503, T-0206; wired from project/scripts/uat.sh seed).
# Derives the realm:username pairs from the scenarios of one group and runs
# scripts/seed_uat_email_verified.sh (true) for them. A scenario names its accounts under the line
# "UAT_EMAIL_VERIFIED_USERS), are exactly:" as indented realm:username lines; nothing else is read.
#
# - No scenario names an account: nothing to do, exit 0.
# - Accounts named but UAT_KC_ADMIN_CLIENT_ID/SECRET absent: one clear message, exit 1 (the
#   preparation fails; no retry loop). The values are only tested for presence, never printed.
# - Idempotent: the seed leaves an account already verified alone. Realm and IdP refusals are the
#   seed script's own.
# The environment's UAT_EMAIL_VERIFIED_USERS is ignored on purpose: the scenarios are the source.
set -euo pipefail

dir="${1:-}"
[ -d "$dir" ] || { echo "usage: seed_uat_email_verified_for_group.sh <scenarios dir>" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pairs=""
for f in "$dir"/*.yaml; do
  [ -f "$f" ] || continue
  found=$(awk '
    /UAT_EMAIL_VERIFIED_USERS\), are exactly:/ { on = 1; next }
    on && /^[[:space:]]+[A-Za-z0-9_-]+:[A-Za-z0-9_.@-]+[[:space:]]*\r?$/ { gsub(/[[:space:]]/, ""); print; next }
    on { on = 0 }
  ' "$f")
  pairs="$pairs $found"
done
pairs=$(printf '%s\n' $pairs | sort -u | tr '\n' ' ' | sed 's/ *$//')

if [ -z "$pairs" ]; then
  echo "seed: no email_verified accounts named by the scenarios in $dir"
  exit 0
fi

if [ -z "${UAT_KC_ADMIN_CLIENT_ID:-}" ] || [ -z "${UAT_KC_ADMIN_CLIENT_SECRET:-}" ]; then
  echo "seed: email_verified seed needs UAT_KC_ADMIN_CLIENT_ID and UAT_KC_ADMIN_CLIENT_SECRET in the environment (.env.uat); not set, preparation fails" >&2
  exit 1
fi

echo "seed: seed_uat_email_verified.sh true for: $pairs"
UAT_EMAIL_VERIFIED_USERS="$pairs" bash "$here/seed_uat_email_verified.sh" true
