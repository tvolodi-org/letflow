#!/usr/bin/env bash
# T-1568 -- prune.sh [--dry-run]: apply the retention policy (retention.conf) under $BACKUP_ROOT.
#
# Rules: a dump set is deleted only when it is older than DUMP_KEEP_DAYS AND at least DUMP_KEEP_MIN
# newer sets remain; the newest set carrying a VERIFIED file (a passed restore test) is never
# deleted; base backups beyond BASE_KEEP go; a WAL file goes when it is older than WAL_KEEP_DAYS AND
# sorts before the oldest kept base backup's start_wal (nothing is deleted from wal/ while no base
# backup exists).
# A path is removed only after it is shown to be a real (non-symlink) direct child of
# $BACKUP_ROOT/{dump/<db>,base,wal}.
#
# Exit codes: 0 ok; 2 bad input; 6 a deletion failed.
set -euo pipefail
set +x
# shellcheck source=scripts/backup/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *)
    log "usage: prune.sh [--dry-run]"
    exit 2
    ;;
esac

status_begin prune
common_env
load_retention

removed=0
failed=0
now="$(date -u +%s)"

# safe_rm <parent dir> <path>: delete <path> only if it is a real direct child of <parent>.
safe_rm() {
  local parent="$1" path="$2" real_parent real
  [[ -e "$path" && ! -L "$path" ]] || return 0
  real_parent="$(cd "$parent" && pwd -P)"
  real="$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
  if [[ "$(dirname "$real")" != "$real_parent" || "$real_parent" != "$BACKUP_ROOT"/* ]]; then
    log "prune: refusing to delete outside the backup tree"
    failed=$((failed + 1))
    return 0
  fi
  if [[ "$DRY" -eq 1 ]]; then
    log "prune: would delete ${real#"$BACKUP_ROOT"/}"
  else
    rm -rf --one-file-system -- "$real" || failed=$((failed + 1))
  fi
  removed=$((removed + 1))
}

# list real (non-symlink) set directories of <dir> with a stamp name, newest first
list_sets() {
  local dir="$1" e
  [[ -d "$dir" ]] || return 0
  for e in "$dir"/*; do
    [[ -d "$e" && ! -L "$e" && "$(basename "$e")" =~ $STAMP_RE ]] && basename "$e"
  done | sort -r
  return 0
}

# --- dump sets, per database
for db in $BACKUP_DATABASES; do
  dir="$BACKUP_ROOT/dump/$db"
  [[ -d "$dir" ]] || continue
  protected=""
  idx=0
  mapfile -t sets < <(list_sets "$dir")
  for s in "${sets[@]}"; do
    if [[ -z "$protected" && -f "$dir/$s/VERIFIED" ]]; then protected="$s"; fi
  done
  for s in "${sets[@]}"; do
    idx=$((idx + 1))
    age_days=$(((now - $(stamp_epoch "$s")) / 86400))
    if [[ "$idx" -gt "$DUMP_KEEP_MIN" && "$age_days" -gt "$DUMP_KEEP_DAYS" && "$s" != "$protected" ]]; then
      safe_rm "$dir" "$dir/$s"
    fi
  done
done

# --- base backups: keep the newest BASE_KEEP
if [[ -d "$BACKUP_ROOT/base" ]]; then
  mapfile -t bases < <(list_sets "$BACKUP_ROOT/base")
  idx=0
  oldest_kept=""
  for b in "${bases[@]}"; do
    idx=$((idx + 1))
    if [[ "$idx" -gt "$BASE_KEEP" ]]; then
      safe_rm "$BACKUP_ROOT/base" "$BACKUP_ROOT/base/$b"
    else
      oldest_kept="$b"
    fi
  done
  # --- WAL: nothing is removed without a kept base backup that tells where replay starts
  if [[ -n "$oldest_kept" && -d "$BACKUP_ROOT/wal" && -f "$BACKUP_ROOT/base/$oldest_kept/base.info" ]]; then
    start_wal="$(sed -n 's/^start_wal=\([0-9A-F]\{24\}\)$/\1/p' "$BACKUP_ROOT/base/$oldest_kept/base.info" | head -n1)"
    if [[ -n "$start_wal" ]]; then
      for f in "$BACKUP_ROOT"/wal/*; do
        n="$(basename "$f")"
        [[ -f "$f" && ! -L "$f" && "$n" =~ ^[0-9A-F]{24}$ && "$n" < "$start_wal" ]] || continue
        age_days=$(((now - $(stat -c %Y "$f")) / 86400))
        [[ "$age_days" -gt "$WAL_KEEP_DAYS" ]] && safe_rm "$BACKUP_ROOT/wal" "$f"
      done
    fi
  fi
fi

STATUS_DETAIL="removed=$removed failed=$failed dry_run=$DRY"
[[ "$failed" -eq 0 ]] || die 6 "removed=$removed failed=$failed" "some deletions failed or were refused"
log "prune: removed=$removed dry_run=$DRY"
