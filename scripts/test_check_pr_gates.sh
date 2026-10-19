#!/usr/bin/env bash
# Self-test for check_pr_gates.sh (local fixtures only; no network, no gh).
set -u
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail=0

printf 'lib/letflow/x.ex\n' > "$t/files"
printf 'README.md\n' > "$t/docs_only"
valid='## Summary
x

## Gates
Tier: FULL
- CODE-DESIGN-VALIDATOR: PASS — evidence: docs/design.md:12, mix test test/x_test.exs rc=0
- SECURITY-REVIEWER: PASS_WITH_FINDINGS — evidence: lib/letflow/x.ex:40
- REVIEWER: N/A (docs only helper)
- TEST-DESIGN-VALIDATOR: PASS — evidence: test/x_test.exs:7
- CI: https://github.com/o/r/actions/runs/123 success
'
fixrefs='Introduced-by: #2700
Missed-by: REVIEWER
'
highfix=${valid/Tier: FULL/Tier: HIGH}

# check <name> <expected rc> <body> <files> [title]
check() {
  printf '%s' "$3" > "$t/body"
  out=$("$here/check_pr_gates.sh" --body-file "$t/body" --files "$4" --title "${5:-feat: x}")
  rc=$?
  if [ "$rc" = "$2" ]; then echo "PASS $1 (rc=$rc)"; else echo "FAIL $1 (rc=$rc expected $2)"; fail=1; fi
  if [ -n "$out" ]; then echo "     $out" | head -3; fi
}

check "valid body" 0 "$valid" "$t/files"
check "docs-only PR needs no block" 0 "no block" "$t/docs_only"
check "missing block" 1 "just prose" "$t/files"
check "bad verdict" 1 "${valid/PASS_WITH_FINDINGS/LGTM}" "$t/files"
check "missing evidence" 1 "${valid/ — evidence: lib\/letflow\/x.ex:40/}" "$t/files"
check "missing CI line" 1 "${valid/- CI: https:\/\/github.com\/o\/r\/actions\/runs\/123 success/}" "$t/files"
check "CI without conclusion" 1 "${valid/runs\/123 success/runs/123}" "$t/files"
check "bad tier" 1 "${valid/Tier: FULL/Tier: FULL | SHORT}" "$t/files"
check "missing gate line" 1 "${valid/- REVIEWER: N\/A (docs only helper)/}" "$t/files"
check "HIGH without outside review" 1 "$highfix" "$t/files"
check "HIGH with outside review" 0 "${highfix}- Outside review: advisor PASS — evidence: lib/letflow/x.ex:1
" "$t/files"
check "fix PR without R4 lines" 1 "$valid" "$t/files" "fix(GH #1): y"
check "fix PR with R4 lines" 0 "$valid$fixrefs" "$t/files" "fix(GH #1): y"
check "fix PR with bad Missed-by" 1 "${valid}Introduced-by: unknown
Missed-by: nobody
" "$t/files" "fix: y"

"$here/check_pr_gates.sh" > /dev/null
rc=$?
if [ "$rc" = 2 ]; then echo "PASS no arguments (rc=2)"; else echo "FAIL no arguments (rc=$rc)"; fail=1; fi
exit $fail
