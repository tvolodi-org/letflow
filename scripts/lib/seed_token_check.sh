#!/usr/bin/env bash
# seed_token_check.sh
#
# Sourced helper for the seed scripts (REQ-454). Checks, before the script's first
# call, that QA_AUTH_TOKEN holds every permission the script needs: GET /api/v1/me/access
# (REQ-449) answers the caller's own roles and permissions for any authenticated token.
# A token that lacks one exits 1 naming that permission, and nothing is changed.
#
# Functions only -- no top-level side effects. The sourcing script must set QA_URL and
# AUTH_HEADER and `set -euo pipefail` itself.

# seed_require_permissions <least_role> <permission>...
#   least_role: the built-in role that holds every permission listed (named in the error).
seed_require_permissions() {
  local least_role="$1"
  shift

  local access
  access=$(curl -sf \
    -H "${AUTH_HEADER}" \
    "${QA_URL}/api/v1/me/access") || {
    echo "ERROR: GET /api/v1/me/access failed (HTTP error); cannot check the permissions of QA_AUTH_TOKEN." >&2
    exit 1
  }

  local perm
  for perm in "$@"; do
    if ! echo "${access}" | jq -e --arg p "${perm}" '.permissions | index($p) != null' >/dev/null; then
      echo "ERROR: QA_AUTH_TOKEN lacks the ${perm} permission (least role: ${least_role})." >&2
      echo "       Nothing was changed. Re-run with a token for a user holding ${least_role} in this tenant." >&2
      exit 1
    fi
  done
}
