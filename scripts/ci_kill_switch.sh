#!/usr/bin/env bash
# T-1311: prints the effective CI_SELECTIVE kill switch. $1 = repository variable value,
# $2 = "true" for a pull request from a `selective-probe/*` branch (a probe PR ignores the switch).
if [ "${2:-}" = true ]; then printf ''; else printf '%s' "${1:-}"; fi
