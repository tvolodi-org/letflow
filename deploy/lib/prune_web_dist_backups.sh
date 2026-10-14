#!/usr/bin/env bash
# Retention for the web-dist-backup-<stamp> directories that deploy/redeploy-qa.sh
# creates (step 7: `mv web-dist web-dist-backup-<TIMESTAMP>` on every CD run).
# GH 2352; the host had 283 of them (472 MiB, ~25 MB/day) and nothing removed them.
#
# Sourced by redeploy-qa.sh, which runs under `set -euo pipefail`. Defines one function and
# runs nothing on its own, so it is also sourced by the stub-tree test
# (test/scripts/prune_web_dist_backups_test.exs).
#
#   prune_web_dist_backups <app_dir> [keep]
#
# Keeps the newest <keep> (default 20, the figure proposed in infra T-0179) and removes the
# older ones. Only a real directory (not a symlink) directly inside <app_dir> whose name is
# exactly `web-dist-backup-YYYYMMDD-HHMMSS` is a candidate. `web-dist`, `web-dist-staging-*`,
# `web-dist-backup-keep-me-not`, plain files and symlinks are never touched. The stamp is
# zero-padded, so the glob's lexical order is chronological order.
#
# Never fails the caller: any problem is a warning on stderr and a 0 return. A bad <keep>
# (empty, non-numeric, 0) prunes nothing.
prune_web_dist_backups() {
  local app_dir="${1:-}" keep="${2:-20}"
  local -a found=()
  local d i total

  if [[ -z "$app_dir" || ! -d "$app_dir" ]]; then
    echo "WARN: web-dist-backup prune skipped: app dir '${app_dir}' is not a directory" >&2
    return 0
  fi
  if [[ ! "$keep" =~ ^[0-9]+$ ]] || (( 10#$keep < 1 )); then
    echo "WARN: web-dist-backup prune skipped: keep='${keep}' is not a positive integer" >&2
    return 0
  fi
  keep=$((10#$keep))

  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  for d in "$app_dir"/web-dist-backup-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]; do
    if [[ -d "$d" && ! -L "$d" ]]; then
      found+=("$d")
    fi
  done
  (( had_nullglob )) || shopt -u nullglob

  total=${#found[@]}
  if (( total <= keep )); then
    echo "web-dist-backup prune: ${total} backup(s), keeping up to ${keep}; nothing to remove"
    return 0
  fi

  for (( i = 0; i < total - keep; i++ )); do
    rm -rf -- "${found[i]}" || echo "WARN: could not remove ${found[i]}" >&2
  done
  echo "web-dist-backup prune: removed $(( total - keep )) of ${total}, kept the newest ${keep}"
  return 0
}
