#!/usr/bin/env bash
# scripts/lib/seed_service_task_base.sh
#
# Shared helper for the QA seed scripts (seed_meridian_definition.sh,
# seed_vortex_definition.sh, seed_swiftroute_definition.sh). Meant to be
# `source`d, not executed. Contains no secrets.
#
# Provides:
#   - SERVICE_TASK_MOCK_BASE_URL handling (env var, optional). The QA fixtures
#     bake in the default base below; the env var is a seed-time override so a
#     self-hosted echo endpoint can be substituted with no fixture edit.
#     Validated on source, before any network call: must start with https://,
#     contain no whitespace; a single trailing "/" is stripped. Otherwise an
#     ERROR line goes to stderr and the shell exits 1. (http:// is refused
#     up front: the engine's SSRF gate, Letflow.Webhooks.UrlValidator, would
#     reject it anyway.)
#   - rewrite_service_task_base <payload-json>  -> payload-json on stdout
#   - version_is_older <a> <b>                  -> exit 0 iff a < b (sort -V)
#
# Issue: ISS-0930. Design: lib/letflow/design/iss0930-seed-service-task-endpoints.md

SERVICE_TASK_DEFAULT_BASE_URL="https://httpbin.org/anything"

_st_base="${SERVICE_TASK_MOCK_BASE_URL:-${SERVICE_TASK_DEFAULT_BASE_URL}}"
# _st_redact <url>: the URL with any userinfo (credentials) removed, safe to print.
_st_redact() {
  local u="$1" scheme="" rest
  if [[ "${u}" == *://* ]]; then scheme="${u%%://*}://"; u="${u#*://}"; fi
  rest="${u#*/}"; [[ "${u}" == */* ]] || rest=""
  local auth="${u%%/*}"
  auth="${auth##*@}"
  if [[ -n "${rest}" || "${u}" == */* ]]; then printf '%s%s/%s' "${scheme}" "${auth}" "${rest}"; else printf '%s%s' "${scheme}" "${auth}"; fi
}

if [[ "${_st_base}" =~ [[:space:]] || "${_st_base}" != https://* ]]; then
  echo "ERROR: SERVICE_TASK_MOCK_BASE_URL must be an https:// URL with no whitespace (got: '$(_st_redact "${_st_base}")')." >&2
  exit 1
fi
# Strip a single trailing slash.
_st_base="${_st_base%/}"
if [[ "${_st_base}" != https://?* ]]; then
  echo "ERROR: SERVICE_TASK_MOCK_BASE_URL has no host (got: '$(_st_redact "${_st_base}")')." >&2
  exit 1
fi
SERVICE_TASK_EFFECTIVE_BASE_URL="${_st_base}"
# Printable form: never echo SERVICE_TASK_EFFECTIVE_BASE_URL itself (it may carry userinfo).
SERVICE_TASK_DISPLAY_BASE_URL="$(_st_redact "${_st_base}")"
unset _st_base

# rewrite_service_task_base <payload-json>
# Replaces the leading default-base prefix of every SERVICE_TASK node's
# attributes.endpoint with the effective base. Identity when the effective
# base equals the default. Everything else in the payload is left untouched.
rewrite_service_task_base() {
  local payload="$1"
  if [[ "${SERVICE_TASK_EFFECTIVE_BASE_URL}" == "${SERVICE_TASK_DEFAULT_BASE_URL}" ]]; then
    printf '%s' "${payload}"
    return 0
  fi
  printf '%s' "${payload}" | jq \
    --arg old "${SERVICE_TASK_DEFAULT_BASE_URL}" \
    --arg new "${SERVICE_TASK_EFFECTIVE_BASE_URL}" \
    '.graph.nodes |= map(
       if .node_type == "SERVICE_TASK"
          and ((.attributes.endpoint? // null) | type == "string")
          and (.attributes.endpoint | startswith($old))
       then .attributes.endpoint = $new + .attributes.endpoint[($old | length):]
       else . end)'
}

# version_is_older <a> <b>
# True (exit 0) iff <a> sorts strictly before <b> by dotted numeric components
# (sort -V), so 1.9 < 1.10. The server treats version as an opaque string, so
# ordering is decided client-side here.
version_is_older() {
  local a="$1" b="$2"
  [[ "${a}" != "${b}" ]] || return 1
  [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | head -n1)" == "${a}" ]]
}
