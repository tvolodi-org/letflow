#!/usr/bin/env bash
# seed_outbound_open.sh
#
# Sourced helper for the scenario seed scripts (T-2724, pilot gap G14). Functions only.
#
# The scenario fixtures (Swiftroute, Meridian, Vortex, incident) are DEMO / QA tenant data:
# their service steps call an inline HTTP host (httpbin.org by default). Since G14 a
# tenant's outbound allow-list is deny by default, so activation is refused
# (outbound_channel_not_allowed) until an administrator opens the `http` channel and the
# host. This helper does that through the public route, BEFORE activation:
#   POST /api/v1/outbound-destinations   (OutboundDestinationsManage -> TENANT_ADMIN)
# It uses QA_ADMIN_AUTH_TOKEN when set (a designer token does not hold the atom), else
# QA_AUTH_TOKEN. The fence is not changed: a token without the atom is refused by the
# route; the helper then warns and the activation reports the refusal itself.
# It is for demo tenants only; never run these seed scripts against a real tenant.
# The sourcing script must set QA_URL, AUTH_HEADER and SERVICE_TASK_EFFECTIVE_BASE_URL.

# seed_open_outbound_http
seed_open_outbound_http() {
  local header="${AUTH_HEADER}"
  if [[ -n "${QA_ADMIN_AUTH_TOKEN:-}" ]]; then
    header="Authorization: Bearer ${QA_ADMIN_AUTH_TOKEN}"
  fi

  local host="${SERVICE_TASK_EFFECTIVE_BASE_URL#*://}"
  host="${host%%/*}"
  host="${host%%:*}"

  local body
  for body in '{"channel":"http"}' "{\"channel\":\"http\",\"destination\":\"${host}\"}"; do
    if ! printf '%s' "${body}" | curl -sf -X POST \
      -H "${header}" -H "Content-Type: application/json" \
      --data-binary @- "${QA_URL}/api/v1/outbound-destinations" >/dev/null; then
      echo "WARNING: could not open the outbound allow-list (${body}); the token needs OutboundDestinationsManage (set QA_ADMIN_AUTH_TOKEN to a TENANT_ADMIN token). Activation may be refused by G14." >&2
    fi
  done
}
