#!/usr/bin/env bash
# Regression test for ISS-0699: scripts/test_parallel.sh's Step 1.7 `tmp_dir`
# (mktemp -d, holding per-partition create/migrate + test logs) was never
# removed on ANY exit path -- no trap existed anywhere in the file -- leaking
# one directory per invocation (~280 accumulated on the host that filed the
# issue). See docs/issues/ISS-0699.yaml and
# lib/letflow/design/iss0699-test-parallel-tmpdir-cleanup-fix.md. The fix adds
# a `cleanup_tmp_dir` function plus `trap cleanup_tmp_dir EXIT`, registered
# immediately after `tmp_dir` is created: on a clean run (exit 0) with
# TEST_PARALLEL_KEEP_LOGS unset, tmp_dir is removed; on any nonzero exit, or
# on a clean exit with TEST_PARALLEL_KEEP_LOGS set, tmp_dir is preserved.
#
# Same extraction technique as test/scripts/test_parallel_pool_sizing_test.sh
# (ISS-0287): this does NOT hand-duplicate the trap/cleanup logic. It
# extracts the real `cleanup_tmp_dir` function + `tmp_dir=$(mktemp -d ...)` +
# `trap cleanup_tmp_dir EXIT` + the following echo line VERBATIM out of the
# real scripts/test_parallel.sh (bounded between the `cleanup_tmp_dir() {`
# line and the following `max_concurrent_creates=` line), and `eval`s that
# extracted block in a controlled subshell that fakes a fast exit (0 or 1)
# instead of actually running mix/postgres -- per this handoff's own
# instruction that a full real invocation isn't available in this
# environment. A real `mktemp -d` directory IS created by the extracted
# block itself (that line is part of what's under test), so this test
# verifies the real mechanism end to end: does a real directory that the
# real extracted code created actually get removed, or not, under each of
# the three dispositions.
#
# Usage: test/scripts/test_parallel_tmpdir_cleanup_test.sh
# Optional: TEST_PARALLEL_SCRIPT=<path> to point at a different copy of
# test_parallel.sh (used for this test's own pre-fix/post-fix fail-then-pass
# verification -- see the WF-03 handoff for how this was invoked against a
# pre-fix copy of the script).

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
target="${TEST_PARALLEL_SCRIPT:-$repo_root/scripts/test_parallel.sh}"

if [ ! -f "$target" ]; then
  echo "FAIL: target script not found: $target" >&2
  exit 1
fi

# --- Extract the cleanup_tmp_dir function + tmp_dir/trap lines verbatim ---
#
# Start marker: the literal `cleanup_tmp_dir() {` function-definition line.
# End marker: the literal `max_concurrent_creates=` line that immediately
# follows the block under test in the real script (see script lines
# 261-278 as of this writing). Two independent guards close the
# over-capture gap, same shape as test_parallel_pool_sizing_test.sh's own
# guards:
#
#   1. The awk program tracks whether it was still "flag"-active when it hit
#      the end marker (closed=1, explicit exit 0) vs. ran off EOF without
#      ever closing (END block, explicit exit 1) -- checked via awk's own
#      process exit code, not inferred from the captured text.
#   2. Even if (1) were bypassed, the captured block is positively bounded
#      before eval: it must be <= 150 lines (the real block is ~85 lines as of
#      ISS-1080; 150 gives margin for comment growth while remaining far
#      short of what an EOF over-capture into Step 2/3/4/5 would produce),
#      and must NOT contain any token unique to Step 1.7's create/migrate
#      loop or later ("ecto.create", "ecto.migrate", "declare -A",
#      "wait -n", "# --- Step 2", "# --- Step 3", "# --- Step 4",
#      "# --- Step 5"). Either check tripping is a hard, loud failure with
#      no eval attempted.
#
# Against the PRE-FIX script (no cleanup_tmp_dir function, no trap
# anywhere), the start marker is never found, `flag` is never set, `closed`
# stays unset, and the awk program exits 1 off EOF -- this test correctly
# FAILS against pre-fix code via this same extraction step, not just via a
# separate "trap missing" assertion.

cleanup_block=$(awk '
  /^cleanup_tmp_dir\(\) \{/ { flag=1 }
  flag { print }
  /^max_concurrent_creates=/ { if (flag) { closed=1; exit 0 } }
  END { if (!closed) exit 1 }
' "$target")
awk_rc=$?

pass=0
fail=0

if [ "$awk_rc" -ne 0 ]; then
  echo "FAIL: could not extract cleanup_tmp_dir block from $target -- no 'cleanup_tmp_dir() {' start marker followed by a 'max_concurrent_creates=' end marker found (pre-fix script has no trap/cleanup mechanism at all)" >&2
  fail=$((fail + 1))
  echo "---"
  echo "test_parallel_tmpdir_cleanup_test: $pass passed, $fail failed"
  exit 1
fi

if [ -z "$cleanup_block" ] || ! printf '%s' "$cleanup_block" | grep -q 'trap cleanup_tmp_dir EXIT'; then
  echo "FAIL: extracted block from $target does not contain 'trap cleanup_tmp_dir EXIT' (marker found but mechanism shape changed?)" >&2
  fail=$((fail + 1))
  echo "---"
  echo "test_parallel_tmpdir_cleanup_test: $pass passed, $fail failed"
  exit 1
fi

if ! printf '%s' "$cleanup_block" | grep -q '^tmp_dir=\$(mktemp -d'; then
  echo "FAIL: extracted block from $target does not contain the expected 'tmp_dir=\$(mktemp -d ...)' line" >&2
  fail=$((fail + 1))
  echo "---"
  echo "test_parallel_tmpdir_cleanup_test: $pass passed, $fail failed"
  exit 1
fi

block_line_count=$(printf '%s\n' "$cleanup_block" | wc -l | tr -d ' ')
if [ "$block_line_count" -gt 150 ]; then
  echo "FAIL: extracted cleanup_tmp_dir block from $target is $block_line_count lines (> 150) -- refusing to eval a suspiciously large capture; end marker may be misplaced/renamed" >&2
  fail=$((fail + 1))
  echo "---"
  echo "test_parallel_tmpdir_cleanup_test: $pass passed, $fail failed"
  exit 1
fi

for telltale in 'ecto.create' 'ecto.migrate' 'declare -A' 'wait -n' '# --- Step 2' '# --- Step 3' '# --- Step 4' '# --- Step 5'; do
  if printf '%s' "$cleanup_block" | grep -qF "$telltale"; then
    echo "FAIL: extracted cleanup_tmp_dir block from $target contains '$telltale', a token unique to Step 1.7's create/migrate loop or later -- extraction over-captured; refusing to eval" >&2
    fail=$((fail + 1))
    echo "---"
    echo "test_parallel_tmpdir_cleanup_test: $pass passed, $fail failed"
    exit 1
  fi
done

# --- run_case NAME SIMULATED_EXIT KEEP_LOGS(0|1) EXPECT(removed|preserved) -

run_case() {
  local name="$1" sim_exit="$2" keep_logs="$3" expect="$4"

  local out rc tmpdir_path
  out=$(
    (
      set -u
      unset TEST_PARALLEL_KEEP_LOGS
      if [ "$keep_logs" -eq 1 ]; then
        export TEST_PARALLEL_KEEP_LOGS=1
      fi
      eval "$cleanup_block"
      exit "$sim_exit"
    ) 2>&1
  )
  rc=$?

  tmpdir_path=$(printf '%s\n' "$out" | grep -oE 'partition logs in .*' | sed 's/^partition logs in //' | tail -n 1)

  if [ -z "$tmpdir_path" ]; then
    echo "FAIL: $name -- could not recover tmp_dir path from subshell output:"
    echo "$out" | sed 's/^/    /'
    fail=$((fail + 1))
    return
  fi

  if [ "$rc" -ne "$sim_exit" ]; then
    echo "FAIL: $name -- subshell exit code $rc did not match simulated exit $sim_exit (trap called \`exit\` itself?)"
    fail=$((fail + 1))
    rm -rf "$tmpdir_path"
    return
  fi

  case "$expect" in
    removed)
      if [ ! -d "$tmpdir_path" ]; then
        echo "PASS: $name (tmp_dir removed, as expected)"
        pass=$((pass + 1))
      else
        echo "FAIL: $name -- expected tmp_dir removed, but $tmpdir_path still exists"
        fail=$((fail + 1))
        rm -rf "$tmpdir_path"
      fi
      ;;
    preserved)
      if [ -d "$tmpdir_path" ]; then
        echo "PASS: $name (tmp_dir preserved, as expected)"
        pass=$((pass + 1))
        rm -rf "$tmpdir_path"
      else
        echo "FAIL: $name -- expected tmp_dir preserved, but $tmpdir_path was removed"
        fail=$((fail + 1))
      fi
      ;;
    *)
      echo "FAIL: $name -- bad expectation spec '$expect' in test itself" >&2
      fail=$((fail + 1))
      ;;
  esac
}

# --- Cases (the 3 dispositions this handoff's own acceptance criteria name) -

# (a) Simulated clean exit (0), TEST_PARALLEL_KEEP_LOGS unset -> removed.
run_case "clean exit, KEEP_LOGS unset -> tmp_dir removed" 0 0 removed

# (b) Simulated clean exit (0), TEST_PARALLEL_KEEP_LOGS set -> preserved.
run_case "clean exit, KEEP_LOGS set -> tmp_dir preserved" 0 1 preserved

# (c) Simulated failing exit (1), KEEP_LOGS unset -> preserved regardless.
run_case "failing exit, KEEP_LOGS unset -> tmp_dir preserved" 1 0 preserved

# (c cont'd) Simulated failing exit (1), KEEP_LOGS set -> still preserved
# (failure preservation is not merely a side effect of KEEP_LOGS being
# unset in the previous case -- this proves the exit-code check is checked
# first / independently).
run_case "failing exit, KEEP_LOGS set -> tmp_dir preserved" 1 1 preserved

echo "---"
echo "test_parallel_tmpdir_cleanup_test: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
