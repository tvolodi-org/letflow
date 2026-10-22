#!/usr/bin/env bash
# Regenerates and extends the backend test shard manifest (scripts/test_shard_manifest.txt).
#
# GH #2380 step 2. The manifest assigns every test/**/*_test.exs file to one of P global
# partitions (P = TEST_PARALLEL_N x M). scripts/test_parallel.sh reads it when
# TEST_PARALLEL_MANIFEST is set, and then runs each partition on exactly the files listed for it.
#
# Modes (exactly one):
#   --from-tsv RUN.tsv...  Build a manifest from per-module timings. Each RUN.tsv has the
#                          columns run, job, partition, module, ms, file (the step-1 log
#                          instrumentation, one row per module, extracted from the job logs).
#                          A file's weight is the mean of its share of each run's total,
#                          scaled to the total of the LAST run given. Files are placed with
#                          LPT (longest processing time first) into --partitions bins. Files
#                          with no timing get weight 0. Manifest to stdout, balance table to
#                          stderr.
#   --append MANIFEST      Keep the manifest in step with the test tree without a rebuild:
#                          drop lines whose file no longer exists, and add each test file on
#                          disk that is missing, with the median weight, to the partition with
#                          the lowest weight (lowest index on a tie). Updated manifest to stdout.
#
# Options:
#   --partitions P         bins for --from-tsv (default 16, the M=4 layout). --append reads
#                          the partition count from the manifest header.
#   --root DIR             repository root holding test/ (default: current directory)
#
# Deterministic: the same inputs give the same bytes. Ties sort by path, and bins by index.
# No Python on this host, so this is bash and awk only. Run from the repository root.
set -euo pipefail

mode=""
partitions=16
root="."
inputs=()

usage() {
  echo "usage: $0 --from-tsv RUN.tsv... [--partitions P] [--root DIR]" >&2
  echo "       $0 --append MANIFEST [--root DIR]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from-tsv) mode=from-tsv; shift ;;
    --append) mode=append; shift ;;
    --partitions) partitions="${2:-}"; shift 2 ;;
    --root) root="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) inputs+=("$1"); shift ;;
  esac
done

[ -n "$mode" ] || usage
[ -d "$root/test" ] || { echo "test_shard_plan: ERROR no test/ directory under '$root'" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Every test file on disk, repo-relative, sorted in the C locale so the output does not depend on the host locale.
(cd "$root" && find test -name '*_test.exs' | LC_ALL=C sort) > "$tmp/universe"

if [ "$mode" = from-tsv ]; then
  printf '%s' "$partitions" | grep -Eq '^[1-9][0-9]*$' || { echo "test_shard_plan: ERROR --partitions '$partitions' is not a positive integer" >&2; exit 2; }
  [ "${#inputs[@]}" -gt 0 ] || usage
  for f in "${inputs[@]}"; do
    [ -r "$f" ] || { echo "test_shard_plan: ERROR cannot read '$f'" >&2; exit 2; }
  done

  # Share of each run per file, averaged over the runs that contain the file, scaled to the last run's total.
  cat "${inputs[@]}" | tr -d '\r' | awk -F'\t' -v weights="$tmp/weights" -v sources="$tmp/sources" '
    NF >= 6 {
      run = $1; job = $2; file = $6; ms = $5 + 0
      sum[run SUBSEP file] += ms
      runtot[run] += ms
      if (!((run SUBSEP job) in jobseen)) { jobseen[run SUBSEP job] = 1; jobs[run] = jobs[run] " " job }
      if (!(run in runseen)) { runseen[run] = 1; runorder[++nruns] = run }
      last = run
    }
    END {
      for (k in sum) {
        split(k, parts, SUBSEP)
        share[parts[2]] += sum[k] / runtot[parts[1]]
        count[parts[2]] += 1
      }
      for (f in share) printf "%s\t%.6f\n", f, share[f] / count[f] * runtot[last] > weights
      for (i = 1; i <= nruns; i++) printf "%s\t%s\n", runorder[i], jobs[runorder[i]] > sources
      printf "%s\n", last > (sources ".last")
    }
  '
  headrun=$(cat "$tmp/sources.last")

  # Weights only for files on disk: a timed file that is gone is ignored, not an error.
  awk -F'\t' 'FNR == NR { w[$1] = $2; next } { print $1 "\t" (($1 in w) ? w[$1] : 0) }' \
    "$tmp/weights" "$tmp/universe" | LC_ALL=C sort -t$'\t' -k2,2gr -k1,1 > "$tmp/ranked"

  # LPT: each file, heaviest first, goes to the currently lightest bin (lowest index on a tie).
  awk -F'\t' -v P="$partitions" -v loads="$tmp/loads" '
    BEGIN { for (i = 1; i <= P; i++) load[i] = 0 }
    {
      b = 1
      for (i = 2; i <= P; i++) if (load[i] < load[b]) b = i
      load[b] += $2
      printf "%d\t%s\t%.2f\n", b, $1, $2
    }
    END { for (i = 1; i <= P; i++) printf "%d\t%.2f\n", i, load[i] > loads }
  ' "$tmp/ranked" | LC_ALL=C sort -t$'\t' -k1,1n -k2,2 > "$tmp/sorted"

  echo "# partitions: $partitions"
  echo "# weights: estimated ms (mean share of each run's module total, scaled to run $headrun)"
  echo "# update: --append when test files are added or removed; --from-tsv to rebuild from fresh timings"
  while IFS=$'\t' read -r run jobs; do
    echo "# source: run $run jobs$jobs"
  done < "$tmp/sources"
  awk -F'\t' '{ printf "%d %s %s\n", $1, $2, $3 }' "$tmp/sorted"

  # Balance table (stderr): partition loads in seconds, and the shard sums when P is a multiple of 4
  # (each shard runs 4 consecutive partitions, as scripts/test_parallel.sh slices them).
  awk -F'\t' -v P="$partitions" '
    { load[$1] = $2 / 1000 }
    END {
      for (p = 1; p <= P; p++) printf "test_shard_plan: partition %d load %.0f s\n", p, load[p] | "cat 1>&2"
      if (P % 4 == 0) {
        for (s = 1; s <= P / 4; s++) {
          # A shard runs its 4 partitions in parallel, so its time is the heaviest of them.
          slowest = 0
          for (p = (s - 1) * 4 + 1; p <= s * 4; p++) if (load[p] > slowest) slowest = load[p]
          printf "test_shard_plan: shard %d/%d (partitions %d..%d) slowest partition %.0f s, wall ~%.0f s\n", s, P / 4, (s - 1) * 4 + 1, s * 4, slowest, slowest * 1.14 | "cat 1>&2"
        }
      }
    }
  ' "$tmp/loads"
  exit 0
fi

# --append
[ "${#inputs[@]}" -eq 1 ] || usage
manifest="${inputs[0]}"
[ -r "$manifest" ] || { echo "test_shard_plan: ERROR cannot read '$manifest'" >&2; exit 2; }

tr -d '\r' < "$manifest" > "$tmp/manifest"
grep '^#' "$tmp/manifest" > "$tmp/header" || true
partitions=$(sed -n 's/^# partitions: \([1-9][0-9]*\)$/\1/p' "$tmp/header" | head -n 1)
[ -n "$partitions" ] || { echo "test_shard_plan: ERROR '$manifest' has no '# partitions: N' header" >&2; exit 2; }
grep -v '^#' "$tmp/manifest" | grep -v '^[[:space:]]*$' > "$tmp/body" || true

# Drop stale lines (file no longer on disk) and keep the rest exactly as written.
: > "$tmp/kept"
while IFS=' ' read -r part path weight; do
  if [ -f "$root/$path" ]; then
    printf '%s\t%s\t%s\n' "$part" "$path" "$weight" >> "$tmp/kept"
  else
    echo "test_shard_plan: dropped stale manifest line for $path (file not on disk)" >&2
  fi
done < "$tmp/body"

# Median weight of the kept lines (lower median on an even count), used for the new files.
median=$(cut -f3 "$tmp/kept" | LC_ALL=C sort -g | awk '{ v[NR] = $1 } END { if (NR == 0) print 0; else print v[int((NR + 1) / 2)] }')

cut -f2 "$tmp/kept" | LC_ALL=C sort > "$tmp/listed"
LC_ALL=C comm -23 "$tmp/universe" "$tmp/listed" > "$tmp/missing"

# Partition loads from the kept lines; each new file goes to the lightest partition, with the median weight.
awk -F'\t' -v med="$median" -v P="$partitions" '
  FNR == NR { load[$1 + 0] += $3; next }
  {
    p = 1
    for (i = 2; i <= P; i++) if (load[i] < load[p]) p = i
    load[p] += med
    printf "%d\t%s\t%s\n", p, $1, med
    print "test_shard_plan: added " $1 " to partition " p " with weight " med | "cat 1>&2"
  }
' "$tmp/kept" "$tmp/missing" > "$tmp/added"

cat "$tmp/header"
cat "$tmp/kept" "$tmp/added" | LC_ALL=C sort -t$'\t' -k1,1n -k2,2 | awk -F'\t' '{ printf "%d %s %s\n", $1, $2, $3 }'
