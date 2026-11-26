#!/usr/bin/env bash
# The QA deploy gate for the platform step runner (T-2707).
#
# The platform step runner (T-2703) is the worker that runs a `platform_call` step of a
# process definition. Its only switch is the environment variable
# LETFLOW_START_PLATFORM_STEP_RUNNER, read once at boot by `config/runtime.exs`: exactly
# "true" turns the runner on, anything else (an unset variable included) leaves it off.
#
# The variable must be in BOTH host-local files of the QA host:
#
#   $APP_DIR/qa.env        the file `deploy/redeploy-qa.sh` sources;
#   $APP_DIR/deploy/.env   the compose `env_file` of `deploy/docker-compose.qa.yml`, the
#                          file the app container actually boots with.
#
# qa.env alone does not reach the container: the app reads its environment from the
# compose env_file, so a value that is only in qa.env leaves the runner off.
#
# With the runner off a pilot instance of a platform step STARTS and NEVER RUNS: the
# dispatch row stays `pending`, the instance waits at the node, and no error and no DLQ
# entry says why. The gate therefore refuses to let a QA deploy proceed with the runner
# off, and names the file that is wrong.
#
# The accepted value is exactly `true` -- no quotes, no spaces, no other word. That is
# the same word `Letflow.Supervisor.Pollers.parse_platform_step_runner/1` turns on, so a
# deploy that passes this gate and a container that boots from the file agree.
#
# Usage:  bash check_platform_step_runner.sh <app-dir>
# Exit:   0 when both files carry exactly "true"; 1 with a named error otherwise;
#         2 when called with the wrong number of arguments.
set -uo pipefail

VAR=LETFLOW_START_PLATFORM_STEP_RUNNER

if [ "$#" -ne 1 ]; then
  echo "usage: check_platform_step_runner.sh <app-dir>" >&2
  exit 2
fi

APP_DIR=$1
QA_ENV="$APP_DIR/qa.env"
COMPOSE_ENV="$APP_DIR/deploy/.env"

# The value the file carries for the variable, or nothing (and a non-zero exit) when the
# file is unreadable or does not carry the key at all. The last assignment wins, the way
# a shell file and a compose env_file read it.
value_in() {
  local file=$1
  [ -r "$file" ] || return 1
  local raw
  raw=$(sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?${VAR}[[:space:]]*=(.*)\$/\2/p" "$file" | tail -n 1)
  [ -n "$raw" ] || return 1
  # a file written on Windows keeps its carriage return
  printf '%s' "${raw%$'\r'}"
}

rc=0

for file in "$QA_ENV" "$COMPOSE_ENV"; do
  if [ ! -r "$file" ]; then
    echo "ERROR: $file is missing or unreadable." >&2
    rc=1
    continue
  fi

  if ! value=$(value_in "$file"); then
    echo "ERROR: $VAR is not set in $file." >&2
    rc=1
    continue
  fi

  if [ "$value" != "true" ]; then
    echo "ERROR: $VAR in $file is not exactly 'true'." >&2
    rc=1
  fi
done

if [ "$rc" -ne 0 ]; then
  {
    echo
    echo "ERROR: the QA deploy stops here. $VAR must be exactly 'true' in BOTH"
    echo "         $QA_ENV (sourced by deploy/redeploy-qa.sh) and"
    echo "         $COMPOSE_ENV (the compose env_file: what the app container boots with)."
    echo "       qa.env alone does not reach the container."
    echo "       With the runner off a platform_call instance STARTS and NEVER RUNS:"
    echo "       it waits at the node, with no error and no DLQ entry."
  } >&2
fi

exit "$rc"
