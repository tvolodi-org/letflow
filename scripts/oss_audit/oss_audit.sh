#!/usr/bin/env bash
# Read-only secrets / internal-text audit of the tracked tree and the full git history (T-1597).
# Usage: scripts/oss_audit/oss_audit.sh [--tree] [--history] [--rev-range R] [--budget-seconds N]
#        [--format tsv|json] [--out FILE] [--include-noise] [--repo DIR]
# Prints path, commit, rule id, severity and a masked hint only; never the matched text.
# See scripts/oss_audit/README.md. OSS_AUDIT_GIT overrides the git binary (tests only).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$here/scanner.py" "$@"
