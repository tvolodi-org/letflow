#!/usr/bin/env bash
# T-1568 -- wal_archive.sh <path> <name>: PostgreSQL archive_command helper.
#   archive_command = '/path/to/scripts/backup/wal_archive.sh "%p" "%f"'
#
# Copies the segment to $WAL_ARCHIVE_DIR (default $BACKUP_ROOT/wal, i.e. /opt/backups/<env>/wal)
# through a temp name + sync + rename, so a half-copied segment is never visible. Idempotent: an
# identical file already there is success; a DIFFERENT file with the same name is refused (exit 1,
# so PostgreSQL retries and the problem stays visible). Runs where the server's WAL directory is
# visible; it writes no status file (PostgreSQL calls it per segment) -- failures go to the
# server log and pg_stat_archiver.
#
# Exit codes: 0 ok; 1 copy failed or name collision with different content; 2 bad input.
set -euo pipefail
set +x
umask 077

src="${1:-}"
name="${2:-}"
[[ -n "$src" && -n "$name" ]] || {
  echo "usage: wal_archive.sh <path> <name>" >&2
  exit 2
}
# Only plain WAL / history / backup-label file names; no path separators.
[[ "$name" =~ ^[0-9A-F]{8,24}(\.partial|\.history|\.[0-9A-F]{8}\.backup)?$ ]] || {
  echo "wal_archive: unexpected file name" >&2
  exit 2
}
dest_dir="${WAL_ARCHIVE_DIR:-}"
if [[ -z "$dest_dir" ]]; then
  [[ -n "${BACKUP_ROOT:-}" || -n "${BACKUP_ENV:-}" ]] || {
    echo "wal_archive: set WAL_ARCHIVE_DIR or BACKUP_ENV/BACKUP_ROOT" >&2
    exit 2
  }
  dest_dir="${BACKUP_ROOT:-/opt/backups/$BACKUP_ENV}/wal"
fi
[[ "$dest_dir" == /* ]] || {
  echo "wal_archive: WAL_ARCHIVE_DIR must be absolute" >&2
  exit 2
}
mkdir -p -m 0700 "$dest_dir"
[[ -f "$src" ]] || {
  echo "wal_archive: source segment not found" >&2
  exit 1
}

dest="$dest_dir/$name"
if [[ -e "$dest" ]]; then
  if cmp -s -- "$src" "$dest"; then exit 0; fi
  echo "wal_archive: $name already archived with different content" >&2
  exit 1
fi
tmp="$dest_dir/.$name.tmp.$$"
trap 'rm -f -- "$tmp"' EXIT
cp -- "$src" "$tmp"
sync -- "$tmp" 2>/dev/null || sync
mv -T -- "$tmp" "$dest"
