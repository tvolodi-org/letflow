#!/usr/bin/env bash
# T-1674 (T-1599 stage 1 preparation): READ-ONLY dry-run report of the companion move list.
#
# Reads the tracked paths of a git working tree (`git ls-files`) and scripts/companion/move_list.tsv,
# and prints how many files and bytes fall in each class (source, companion, stays, drop), per rule
# and per top-level path. It never writes into the tree, never moves or deletes a file, calls no
# network and no history command (only `git ls-files`).
#
# Usage:
#   dry_run.sh [--root DIR] [--list FILE]     report; exit 1 when a tracked path matches no rule,
#                                             a rule has an unknown class, or the list is malformed
#   dry_run.sh --paths CLASS [...]            print the tracked paths of one class, one per line
#   dry_run.sh --recipe                       print the stage 1 'diff -r' proof recipe (prints only)
# Defaults: --root is the repository containing this script, --list is move_list.tsv next to it.
# Rule order of precedence: the LONGEST matching path wins (see move_list.tsv header).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
list="$here/move_list.tsv"
mode=report
want=""

while [ $# -gt 0 ]; do
  case "$1" in
    --root) root=$(cd "$2" && pwd); shift 2 ;;
    --list) list=$2; shift 2 ;;
    --paths) mode=paths; want=$2; shift 2 ;;
    --recipe) mode=recipe; shift ;;
    -h|--help) sed -n 2,17p "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "dry_run.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$mode" = recipe ]; then
  cat <<'EOF'
Stage 1 proof recipe (T-1599 section 10: "companion tree equals the product tree at those paths").
Nothing below is run by dry_run.sh; run it by hand in stage 1, after the companion repo has been filled.
  P=<product checkout, clean, at the commit the companion was cut from>
  C=<companion checkout, the same commit of its main>
  T=$(mktemp -d)                               # outside both trees
  bash "$P/scripts/companion/dry_run.sh" --root "$P" --paths companion > "$T/companion.lst"
  mkdir "$T/expected"
  (cd "$P" && tar -cf - -T "$T/companion.lst") | tar -xf - -C "$T/expected"
  diff -r -x .git -x COMPANION.md -x .github "$T/expected" "$C"
Pass = diff prints nothing and exits 0. The excluded names are the only files the companion adds
(COMPANION.md, its lint workflow, .git). Also compare counts:
  wc -l < "$T/companion.lst"; (cd "$C" && git ls-files | grep -v -e '^COMPANION.md$' -e '^\.github/' | wc -l)
Files classed 'drop' must be absent from $C; files classed 'source' or 'stays' must not be copied there.
EOF
  exit 0
fi

[ -r "$list" ] || { echo "dry_run.sh: cannot read move list: $list" >&2; exit 2; }
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "dry_run.sh: not a git work tree: $root" >&2; exit 2; }

# size<TAB>path for every tracked path (0 when the file is absent from the disk); stat only reads.
sizes() {
  git -C "$root" ls-files -z | while IFS= read -r -d '' p; do
    if [ -f "$root/$p" ]; then printf '%s\t%s\n' "$(stat -c %s "$root/$p")" "$p"; else printf '0\t%s\n' "$p"; fi
  done
}

awk -F'\t' -v mode="$mode" -v want="$want" -v listfile="$list" '
  BEGIN {
    bad = 0
    while ((getline line < listfile) > 0) {
      if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) continue
      n = split(line, f, "\t")
      if (n != 3 || f[1] == "" || f[3] == "") { printf "ERROR bad move list row (need path, class, reason): %s\n", line; bad++; continue }
      if (f[2] !~ /^(source|companion|stays|drop)$/) { printf "ERROR unknown class \"%s\" for %s\n", f[2], f[1]; bad++; continue }
      if (f[1] in cls) { printf "ERROR duplicate path in move list: %s\n", f[1]; bad++; continue }
      nr++; rp[nr] = f[1]; cls[f[1]] = f[2]
    }
    close(listfile)
  }
  {
    size = $1; path = substr($0, length($1) + 2)
    best = 0; bl = -1
    for (i = 1; i <= nr; i++) {
      r = rp[i]; last = substr(r, length(r), 1)
      if (last == "/" || last == "*") { p = substr(r, 1, length(r) - 1); ok = (substr(path, 1, length(p)) == p) }
      else ok = (path == r)
      if (ok && length(r) > bl) { best = i; bl = length(r) }
    }
    if (best == 0) { unclassified[++nu] = path; next }
    c = cls[rp[best]]
    if (mode == "paths") { if (c == want) print path; next }
    files[rp[best]]++; bytes[rp[best]] += size; cf[c]++; cb[c] += size
    top = path; sub(/\/.*/, "", top)
    if (path !~ /\//) top = "(root files)"
    tf[top "\t" c]++; tb[top "\t" c] += size
    total++; totalb += size
  }
  function mb(x) { return sprintf("%.1f MB", x / 1048576) }
  END {
    if (mode == "paths") { if (nu > 0 || bad > 0) exit 1; exit 0 }
    print "Companion move list dry run (read-only; nothing is moved, copied or deleted)"
    printf "List: %s (%d rules)\n\n", listfile, nr
    print "Per class:"
    split("source companion stays drop", order, " ")
    for (k = 1; k <= 4; k++) { c = order[k]; printf "  %-10s %7d files %10s\n", c, cf[c] + 0, mb(cb[c] + 0) }
    printf "  %-10s %7d files %10s\n\n", "total", total + 0, mb(totalb + 0)
    print "Per rule (files, size), rules that match nothing are marked unused:"
    for (i = 1; i <= nr; i++) {
      r = rp[i]
      if (files[r] > 0) printf "  %-10s %7d %10s  %s\n", cls[r], files[r], mb(bytes[r]), r
      else printf "  %-10s %7d %10s  %s  (unused)\n", cls[r], 0, mb(0), r
    }
    print "\nPer top-level path and class:"
    for (key in tf) { split(key, kc, "\t"); printf "  %-16s %-10s %7d %10s\n", kc[1], kc[2], tf[key], mb(tb[key]) | "sort"; }
    close("sort")
    print ""
    if (nu > 0) {
      printf "ERROR %d tracked path(s) match no rule (first 20):\n", nu
      for (i = 1; i <= nu && i <= 20; i++) printf "  %s\n", unclassified[i]
    }
    if (nu > 0 || bad > 0) { print "RESULT: FAIL"; exit 1 }
    print "RESULT: OK, every tracked path is classified"
  }
' <(sizes)
