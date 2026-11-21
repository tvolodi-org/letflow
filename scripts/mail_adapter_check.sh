#!/usr/bin/env bash
# mail_adapter_check.sh - report whether Letflow's OWN mail (the notifier mail adapter) can reach a
# mail trap, and whether the trap can be read by the UAT tooling.
#
# Letflow's own mail is the "task assigned" copy, the exam notifications and (from the pilot's
# notification step) the process notification: they go through Letflow.LoginDiscovery.Notifier,
# whose adapter is selected at boot by LETFLOW_MAIL_ADAPTER. Keycloak's mail is a different path
# with its own SMTP settings; the trap has always caught Keycloak's mail.
#
# Usage:
#   scripts/mail_adapter_check.sh [--env-file FILE | --container NAME]
#                                 [--trap-url URL] [--smtp-host HOST] [--smtp-port PORT]
#
#   --env-file FILE   read the variables from a .env file (as the deployment's compose env_file)
#   --container NAME  read them from a running container (docker inspect), the deployment's view
#   (neither)         read them from the environment of this process
#   --trap-url URL    the trap's HTTP API (default http://127.0.0.1:8025, MAIL_TRAP_URL overrides)
#   --smtp-host HOST  the host to probe the trap's SMTP port on (default 127.0.0.1)
#   --smtp-port PORT  the port to probe (default 1025)
#
# What it prints:
#   * every REQ-441 mail variable NAME and whether it is SET or UNSET. A VALUE is never printed,
#     except the two closed-set modes (the adapter mode and the TLS mode), which name no secret.
#   * whether the trap's HTTP API answers (the runner reads the trap through it) and which
#     capabilities the trap's SMTP port advertises (STARTTLS, AUTH).
#   * the verdict: every blocker that stands between the adapter and the trap.
#
# Environment:
#   CURL   curl binary override (the tests use it)
#   NC     nc binary override (the tests use it)
#   DOCKER docker binary override (the tests use it)
#
# Exit codes: 0 ready (no blocker), 1 a blocker stands, 2 usage error, 3 the trap is unreachable.
#
# The rules it reports are the product's own: config/runtime.exs and
# Letflow.LoginDiscovery.Notifier.Smtp.Config (REQ-441, decision 0045) select and validate the
# adapter at boot, and Letflow.LoginDiscovery.Notifier.Smtp.Transport is strict about TLS and
# auth. This script only reads and reports; it changes nothing.
set -uo pipefail

trap_url="${MAIL_TRAP_URL:-http://127.0.0.1:8025}"
smtp_host_override=""
smtp_port_override=""
source_kind="current"
env_file=""
container=""
curl_bin="${CURL:-curl}"
nc_bin="${NC:-nc}"
docker_bin="${DOCKER:-docker}"
smtp_timeout="${MAIL_ADAPTER_CHECK_TIMEOUT:-10}"

usage() {
  echo "usage: mail_adapter_check.sh [--env-file FILE | --container NAME]" \
       "[--trap-url URL] [--smtp-host HOST] [--smtp-port PORT]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file)
      [ "$#" -ge 2 ] || usage
      env_file="$2"
      source_kind="file"
      shift 2
      ;;
    --container)
      [ "$#" -ge 2 ] || usage
      container="$2"
      source_kind="container"
      shift 2
      ;;
    --trap-url)
      [ "$#" -ge 2 ] || usage
      trap_url="$2"
      shift 2
      ;;
    --smtp-host)
      [ "$#" -ge 2 ] || usage
      smtp_host_override="$2"
      shift 2
      ;;
    --smtp-port)
      [ "$#" -ge 2 ] || usage
      smtp_port_override="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      echo "mail_adapter_check.sh: unknown argument: $1" >&2
      usage
      ;;
  esac
done

mail_vars=(
  LETFLOW_MAIL_ADAPTER
  LETFLOW_SMTP_HOST
  LETFLOW_SMTP_PORT
  LETFLOW_SMTP_TLS
  LETFLOW_SMTP_USERNAME
  LETFLOW_SMTP_PASSWORD
  LETFLOW_MAIL_FROM
  LETFLOW_PUBLIC_BASE_URL
  LETFLOW_MAIL_TIMEOUT_MS
)

# The variables the smtp adapter requires (config/runtime.exs refuses to boot without them).
required_vars=(
  LETFLOW_SMTP_HOST
  LETFLOW_SMTP_PORT
  LETFLOW_SMTP_USERNAME
  LETFLOW_SMTP_PASSWORD
  LETFLOW_MAIL_FROM
  LETFLOW_PUBLIC_BASE_URL
)

dump_env() {
  case "$source_kind" in
    current)
      printenv 2>/dev/null
      ;;
    file)
      if [ ! -r "$env_file" ]; then
        echo "mail_adapter_check.sh: cannot read $env_file" >&2
        exit 2
      fi

      cat "$env_file"
      ;;
    container)
      "$docker_bin" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null
      ;;
  esac
}

dump="$(dump_env)"

lookup() { # lookup NAME -> the value, empty when the variable is unset
  printf '%s\n' "$dump" | grep -m1 "^$1=" | cut -d= -f2-
}

is_set() {
  [ -n "$(lookup "$1")" ]
}

probe_smtp() { # probe_smtp HOST PORT -> the server's EHLO answer, empty when it does not answer
  if command -v timeout >/dev/null 2>&1; then
    timeout "$smtp_timeout" "$nc_bin" "$1" "$2" 2>/dev/null
  else
    "$nc_bin" "$1" "$2" 2>/dev/null
  fi
}

echo "== Letflow's own mail adapter: the variable names and their state =="
for v in "${mail_vars[@]}"; do
  if is_set "$v"; then
    echo "$v: SET"
  else
    echo "$v: UNSET"
  fi
done

adapter="$(lookup LETFLOW_MAIL_ADAPTER)"
tls_mode="$(lookup LETFLOW_SMTP_TLS)"
mix_env="$(lookup MIX_ENV)"

case "$adapter" in
  "")
    adapter_state="unset (the Noop adapter of config/config.exs stands: Letflow sends no mail of its own)"
    ;;
  smtp) adapter_state="smtp" ;;
  noop) adapter_state="noop (Letflow sends no mail)" ;;
  *) adapter_state="a value other than smtp/noop (the value is not printed)" ;;
esac
echo "adapter mode: $adapter_state"

case "$tls_mode" in
  "") tls_state="unset (the adapter's default is starttls)" ;;
  starttls | tls | none) tls_state="$tls_mode" ;;
  *) tls_state="a value other than starttls/tls/none (the value is not printed)" ;;
esac
echo "tls mode: $tls_state"

echo ""
echo "== the trap =="

trap_http="unreachable"
if "$curl_bin" -sS --max-time 10 -o /dev/null "$trap_url/api/v1/messages?limit=1" 2>/dev/null; then
  trap_http="reachable"
fi
echo "http api: $trap_http ($trap_url/api/v1/messages)"

smtp_host="${smtp_host_override:-127.0.0.1}"
smtp_port="${smtp_port_override:-1025}"
ehlo="$(printf 'EHLO mail-adapter-check\r\nQUIT\r\n' | probe_smtp "$smtp_host" "$smtp_port")"

smtp_state="unreachable"
smtp_starttls="no"
smtp_auth="no"
if [ -n "$ehlo" ]; then
  smtp_state="reachable"
  if printf '%s' "$ehlo" | grep -qi '^250[- ]STARTTLS'; then smtp_starttls="yes"; fi
  if printf '%s' "$ehlo" | grep -qi '^250[- ]AUTH'; then smtp_auth="yes"; fi
fi
echo "smtp port: $smtp_state (probed at $smtp_host:$smtp_port), STARTTLS: $smtp_starttls, AUTH: $smtp_auth"

blockers=()
notes=()

if [ "$adapter" != "smtp" ]; then
  blockers+=(
    "LETFLOW_MAIL_ADAPTER is not smtp: Letflow's own mail is not delivered, the Noop adapter stands"
  )
else
  for v in "${required_vars[@]}"; do
    if ! is_set "$v"; then
      blockers+=(
        "$v is not set: with the smtp adapter the application refuses to start and names the variable"
      )
    fi
  done
fi

if [ "$tls_mode" = "none" ] && [ "$mix_env" = "prod" ]; then
  blockers+=(
    "LETFLOW_SMTP_TLS=none is refused in a prod build and this deployment runs MIX_ENV=prod"
  )
fi

if [ "$smtp_starttls" != "yes" ]; then
  blockers+=(
    "the trap's smtp port does not advertise STARTTLS: the adapter upgrades with tls: :always and never falls back to plaintext"
  )
fi

if [ "$smtp_auth" != "yes" ]; then
  blockers+=(
    "the trap's smtp port does not advertise AUTH: the adapter sends the credentials with auth: :always"
  )
fi

if [ "$trap_http" != "reachable" ]; then
  blockers+=("the trap's http api does not answer: the runner cannot read the trap")
else
  notes+=("the trap's http api answers: the runner can read the trap")
fi

echo ""
echo "== verdict =="
if [ "${#blockers[@]}" -eq 0 ]; then
  echo "ready: Letflow's own mail can reach the trap and the trap can be read"
else
  echo "blockers:"
  for b in "${blockers[@]}"; do echo "  - $b"; done
fi

if [ "${#notes[@]}" -gt 0 ]; then
  echo "notes:"
  for n in "${notes[@]}"; do echo "  - $n"; done
fi

if [ "$trap_http" != "reachable" ] && [ "$smtp_state" != "reachable" ]; then
  echo "the trap is unreachable at $trap_url and $smtp_host:$smtp_port"
  exit 3
fi

if [ "${#blockers[@]}" -gt 0 ]; then
  exit 1
fi

exit 0
