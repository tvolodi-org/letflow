#!/usr/bin/env bash
# Test inventory for the source/companion split (T-1676, S1-prep C).
#
# Read-only: only `git grep` over tracked files; writes nothing, changes no test.
# Counts the test files (under TEST_ROOTS) whose text names a path of a "companion" family:
# docs/, handoffs/, .claude/, requirements.yaml, migration/decisions, runbooks, uat fixtures.
# Families overlap (a runbook test also names docs/), so the per-family counts do not add up;
# the distinct union is printed separately.
#
# Usage:
#   scripts/companion/test_inventory.sh            # counts per family and per test root
#   scripts/companion/test_inventory.sh --list     # also list the files of every family
#   scripts/companion/test_inventory.sh --files F  # list only the files of family F
#
# Families (name:ERE, matched against file contents; fixed here so the report is reproducible):
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

TEST_ROOTS=(test web/tests apps/mobile/test)

FAMILIES=(
  'docs:docs/'
  'handoffs:handoffs/'
  'claude:\.claude/'
  'requirements_yaml:requirements\.yaml'
  'decisions:migration/decisions|decisions/[0-9]{4}-'
  'runbooks:runbooks/'
  'uat_fixtures:fixtures/uat|docs/uat|uat-reports|ba-decisions'
)

mode=counts
only=""
case "${1:-}" in
  --list) mode=list ;;
  --files) mode=files; only="${2:?family name required}" ;;
  "") ;;
  *) echo "usage: $0 [--list | --files FAMILY]" >&2; exit 2 ;;
esac

roots=()
for r in "${TEST_ROOTS[@]}"; do
  [ -d "$r" ] && roots+=("$r")
done

total=$(git ls-files -- "${roots[@]}" | wc -l)

# Fixture data under test/fixtures/uat is itself a companion artefact, not a test file; exclude
# it from the scan so a fixture that names a path does not count as a test.
scan() { # $1 = ERE
  git grep -lIE -e "$1" -- "${roots[@]}" ':!test/fixtures/uat' || true
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ "$mode" = files ]; then
  for f in "${FAMILIES[@]}"; do
    if [ "${f%%:*}" = "$only" ]; then scan "${f#*:}" | sort; exit 0; fi
  done
  echo "unknown family: $only" >&2; exit 2
fi

echo "test inventory (git grep, tracked files only)"
echo "roots: ${roots[*]}   tracked files under roots: $total"
echo
printf '%-20s %8s' family files
for r in "${roots[@]}"; do printf ' %12s' "$r"; done
printf '\n'

for f in "${FAMILIES[@]}"; do
  name=${f%%:*}; re=${f#*:}
  scan "$re" | sort > "$tmp/$name.txt"
  printf '%-20s %8d' "$name" "$(wc -l < "$tmp/$name.txt")"
  for r in "${roots[@]}"; do
    printf ' %12d' "$(grep -c "^$r/" "$tmp/$name.txt" || true)"
  done
  printf '\n'
done

cat "$tmp"/*.txt | sort -u > "$tmp/union.txt"
printf '%-20s %8d\n' "UNION (distinct)" "$(wc -l < "$tmp/union.txt")"

# Files that name ONLY the docs/ family generic path (no narrower family): the hard core of
# the "docs/" count, useful to judge whether a generic tag rule is needed.
narrow=$(ls "$tmp"/*.txt | grep -v -e '/docs.txt$' -e '/union.txt$' | xargs cat | sort -u)
printf '%-20s %8d\n' "docs-only (no other)" "$(comm -23 "$tmp/docs.txt" <(printf '%s\n' "$narrow") | wc -l)"

if [ "$mode" = list ]; then
  for f in "${FAMILIES[@]}"; do
    name=${f%%:*}
    echo
    echo "== $name =="
    cat "$tmp/$name.txt"
  done
fi
