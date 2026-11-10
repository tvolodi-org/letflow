#!/usr/bin/env bash
# qoimeks_compare.sh -- compare the converter's expected counts with a tenant snapshot (T-1616, B4#11). Read-only.
#
#   qoimeks_compare.sh EXPECTED SNAPSHOT TENANT_SLUG
#
# EXPECTED is `expected_counts.txt` written by qoimeks_convert.py (`key value` lines: records.<type>, documents).
# SNAPSHOT is the output of `scripts/demo/demo_counts.sh snapshot` taken after the uploads. The key `K` of EXPECTED is
# compared with `tenant.<slug>.K` of the snapshot, for EXACT equality (the QA copy tenant is empty before the
# rehearsal). The snapshot has no `records.<type>` line for a type with no live rows, so an absent key counts as 0.
# A snapshot without `tenant.<slug>.modules_active` (wrong slug, truncated file) is bad input, not a zero.
# Prints `DIFF key expected actual` per difference. Exit codes: 0 equal, 1 any difference, 2 bad input.
# No password or connection string is read here.
set -euo pipefail
set +x

usage() { printf 'usage: qoimeks_compare.sh EXPECTED SNAPSHOT TENANT_SLUG\n' >&2; exit 2; }

[ "$#" -eq 3 ] || usage
expected="$1" snapshot="$2" slug="$3"

case "$slug" in
  '' | *[!a-zA-Z0-9_-]*) echo "compare: tenant slug is empty or has unexpected characters" >&2; exit 2 ;;
esac
[ -s "$expected" ] || { echo "compare: expected file is missing or empty" >&2; exit 2; }
[ -s "$snapshot" ] || { echo "compare: snapshot file is missing or empty" >&2; exit 2; }

if ! grep -q -E "^tenant\.${slug}\.modules_active [0-9]+\$" "$snapshot"; then
  echo "compare: snapshot has no tenant.${slug}.modules_active line (wrong slug or truncated snapshot)" >&2
  exit 2
fi

diffs=$(LC_ALL=C awk -v prefix="tenant.${slug}." '
  FNR == NR { n = split($0, f, " "); if (n >= 2) e[f[1]] = f[2]; next }
  { n = split($0, f, " "); if (n >= 2) a[f[1]] = f[2] }
  END {
    for (k in e) {
      act = ((prefix k) in a) ? a[prefix k] : 0
      if (e[k] + 0 != act + 0) printf "DIFF %s %s %s\n", k, e[k], act
    }
  }' "$expected" "$snapshot" | LC_ALL=C sort)

if [ -n "$diffs" ]; then printf '%s\n' "$diffs"; exit 1; fi
echo "OK counts equal"
