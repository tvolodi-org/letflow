#!/usr/bin/env bash
# scripts/lib/seed_outbound_open.sh
#
# Shared helper for the QA seed scripts (seed_swiftroute_definition.sh,
# seed_swiftroute_incident_definition.sh, seed_meridian_definition.sh,
# seed_vortex_definition.sh). Meant to be `source`d, not executed. Contains no secrets.
#
# Since G14 a definition is switched on only when the tenant's outbound allow-list
# (docs/outbound-destinations.md) lists its channel and every literal host; on a demo
# tenant the list is empty and activation answers 422 outbound_destinations_invalid.
# The seed therefore opens the `http` channel and every host of the payload it is about
# to deploy, through the existing authorized route POST /api/v1/outbound-destinations
# (:OutboundDestinationsManage), BEFORE the first activate call.
#
# Provides:
#   - seed_payload_hosts <payload-json>   -> one host per line on stdout (sorted, unique).
#       Hosts of every node's attributes.endpoint in the payload AS GIVEN (call it on the
#       payload AFTER rewrite_service_task_base). Userinfo and port are stripped, the host
#       is lower-cased; a dynamic host ({{...}}) is skipped.
#   - seed_open_outbound <payload-json>   -> opens channel + hosts; idempotent (entries
#       already on the list are not added again). No-op when the payload has no host.
#
# Output: only bare hosts and the channel name are ever printed, never a URL, so a
# credential in the userinfo of SERVICE_TASK_MOCK_BASE_URL cannot reach any output.
#
# The sourcing script must set QA_URL, API, AUTH_HEADER and source seed_token_check.sh.

seed_payload_hosts() {
  printf '%s' "$1" | jq -r '
    [ .graph.nodes[]?
      | .attributes.endpoint? // empty
      | select(type == "string")
      | capture("^https://(?<auth>[^/?#]*)")?
      | .auth
      | sub("^.*@"; "")
      | sub(":[0-9]*$"; "")
      | ascii_downcase
      | select(length > 0 and (test("[{}]") | not)) ]
    | unique | .[]' 2>/dev/null
}

# _seed_outbound_post <json-body> <label>
_seed_outbound_post() {
  local body="$1" label="$2"
  if ! printf '%s' "${body}" | curl -s -o /dev/null -f \
    -X POST \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${API}/outbound-destinations"; then
    echo "ERROR: could not open outbound ${label} (POST /api/v1/outbound-destinations failed)." >&2
    echo "       The token needs the OutboundDestinationsManage permission (least role: TENANT_ADMIN); see docs/outbound-destinations.md." >&2
    exit 1
  fi
  echo "  Opened outbound ${label}"
}

seed_open_outbound() {
  local payload="$1"
  local hosts
  hosts=$(seed_payload_hosts "${payload}")
  if [[ -z "${hosts}" ]]; then
    echo "--- Outbound allow-list: payload reaches no literal host; nothing to open ---"
    return 0
  fi

  echo "--- Opening the outbound allow-list (http channel + payload hosts) ---"
  seed_require_permissions TENANT_ADMIN OutboundDestinationsManage

  local listed
  listed=$(curl -s -f -H "${AUTH_HEADER}" "${API}/outbound-destinations") || {
    echo "ERROR: GET /api/v1/outbound-destinations failed." >&2
    exit 1
  }

  if echo "${listed}" | jq -e '[.entries[]? | select(.channel == "http" and .destination == null)] | length > 0' >/dev/null; then
    echo "  Outbound channel http already open"
  else
    _seed_outbound_post '{"channel":"http"}' "channel http"
  fi

  local host
  while IFS= read -r host; do
    [[ -n "${host}" ]] || continue
    if echo "${listed}" | jq -e --arg h "${host}" '[.entries[]? | select(.channel == "http" and .destination == $h)] | length > 0' >/dev/null; then
      echo "  Outbound host ${host} already allowed"
    else
      _seed_outbound_post "$(jq -cn --arg h "${host}" '{channel: "http", destination: $h}')" "host ${host}"
    fi
  done <<< "${hosts}"
}
