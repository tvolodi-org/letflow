#!/usr/bin/env bash
# T-1683 (T-1599 stage 1 preparation D): companion bootstrap, DRY-RUN ONLY.
#
# Copies the paths classed 'companion' in scripts/companion/move_list.tsv (listed by dry_run.sh --paths)
# from a git work tree into a fresh temp directory, runs the stage 1 'diff -r' proof against the source
# tree, prints a report and deletes the temp directory (also on error or interrupt).
# It never creates or pushes a repository: it runs no `git init/remote/push/commit`, no `gh`, no network.
# Any argument that asks for more than a dry run (--execute, --create, --push, --remote, --repo, ...)
# is refused with exit 2. The only git command used is `git ls-files` (inside dry_run.sh).
#
# Usage:
#   bootstrap.sh [--dry-run] [--root DIR] [--list FILE]
# Exit: 0 proof passed; 1 proof failed (missing file, diff, or a non-companion path copied); 2 usage/refused.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
list="$here/move_list.tsv"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) shift ;;
    --root) root=$(cd "$2" && pwd); shift 2 ;;
    --list) list=$2; shift 2 ;;
    -h|--help) sed -n 2,13p "${BASH_SOURCE[0]}"; exit 0 ;;
    --execute|--create|--push|--remote|--repo|--init|--apply|--no-dry-run|--keep)
      echo "bootstrap.sh: refused: $1 (this script is dry-run only; it creates and pushes nothing)" >&2; exit 2 ;;
    *) echo "bootstrap.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/companion-bootstrap.XXXXXX")
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

dry="$here/dry_run.sh"
lst="$tmp/companion.lst"
bash "$dry" --root "$root" --list "$list" --paths companion > "$lst" || { echo "bootstrap.sh: move list does not classify every path; run dry_run.sh" >&2; exit 1; }
for c in drop source stays; do bash "$dry" --root "$root" --list "$list" --paths "$c" > "$tmp/$c.lst"; done

count=$(wc -l < "$lst")
fail=0
missing=0
: > "$tmp/present.lst"
while IFS= read -r p; do
  if [ -f "$root/$p" ]; then printf '%s\n' "$p" >> "$tmp/present.lst"; else missing=$((missing + 1)); echo "MISSING on disk: $p"; fi
done < "$lst"
[ "$missing" -eq 0 ] || fail=1

mkdir "$tmp/companion" "$tmp/expected"
# Two independent copy routes, so the diff compares real bytes: tar into the companion, cp --parents into expected.
(cd "$root" && tar -cf - -T "$tmp/present.lst") | tar -xf - -C "$tmp/companion"
while IFS= read -r p; do (cd "$root" && cp --parents -p -- "$p" "$tmp/expected/"); done < "$tmp/present.lst"

diffout=$(diff -r "$tmp/expected" "$tmp/companion" 2>&1) && drc=0 || drc=$?
[ "$drc" -eq 0 ] || fail=1

copied=$(cd "$tmp/companion" && find . -type f | wc -l)
leak=0
for c in drop source stays; do
  while IFS= read -r p; do
    if [ -e "$tmp/companion/$p" ]; then leak=$((leak + 1)); echo "LEAK: $c path copied: $p"; fi
  done < "$tmp/$c.lst"
done
[ "$leak" -eq 0 ] || fail=1

bytes=$(du -sb "$tmp/companion" | cut -f1)
echo "Companion bootstrap DRY RUN (nothing is created or pushed; temp dir is deleted)"
echo "Root:            $root"
echo "List:            $list"
echo "Companion paths: $count (missing on disk: $missing)"
echo "Files copied:    $copied ($bytes bytes)"
echo "diff -r:         $([ "$drc" -eq 0 ] && echo identical || echo DIFFERENT)"
[ "$drc" -eq 0 ] || printf '%s\n' "$diffout" | head -20
echo "Leaked paths:    $leak (drop/source/stays paths found in the copy)"
for c in drop source stays; do echo "Not copied:      $c $(wc -l < "$tmp/$c.lst") files"; done
if [ "$fail" -eq 0 ]; then echo "RESULT: OK, dry run passed (no repository created, nothing pushed)"; else echo "RESULT: FAIL"; fi
exit "$fail"
