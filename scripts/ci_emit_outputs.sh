#!/usr/bin/env bash
# T-1311: writes the outputs of the "Select backend tests" step of ci.yml to $GITHUB_OUTPUT.
# Usage: ci_emit_outputs.sh MODE REASON SKIP PLAN
# The multi-line `plan` value is written as `plan<<DELIM`, the value, then DELIM on a line of its
# own. The runner fails the step ("Matching delimiter not found") when the delimiter shares a line
# with the last plan line, so the value always ends with a newline before the delimiter.
set -u
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
echo "mode=$1" >> "$GITHUB_OUTPUT"
echo "reason=$2" >> "$GITHUB_OUTPUT"
echo "skip_shards=$3" >> "$GITHUB_OUTPUT"
{
  echo "plan<<PLAN_EOF"
  if [ -n "$4" ]; then printf '%s\n' "${4%$'\n'}"; fi
  echo "PLAN_EOF"
} >> "$GITHUB_OUTPUT"
