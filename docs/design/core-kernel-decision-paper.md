# Working paper: the HELD document and posting kernel (preparation for a decision record)

Written 2026-11-12, task T-1789 (item 4 of `docs/uat/ba-decisions/T-1785.md`), from `origin/main` at
94e956ca5. **This is a working paper, not a decision record. Nothing here is decided.** It changes no
code, no schema and no tenant data. It prepares the record that section 7 of
`docs/design/core-extraction-design.md` asks for before inventory rows 6 and 9 to 13 (and `find` of row 14)
of `docs/design/core-extraction-inventory.md` may move.

- **Number for the record:** the next free number in `docs/migration/decisions/` is **0087**
  (`git ls-tree --name-only origin/main docs/migration/decisions/ | tail -1` prints
  `0086-saved-stock-balance-report.md`; no open team branch or sibling worktree adds a file there, checked
  2026-11-12). The record is not written under that number by this task: re-check the number when the
  record is written.
- **Who decides:** the owner, or the delegate named in portfolio decision D-118 (cited from the task text
  and the design note; `ai-dala-portfolio/DECISIONS.md` was not opened for this paper). A recommendation
  below is the analyst's proposal only.
- **What stays outside the kernel record:** the open slices S7f, S8, S9 of design section 6 and the web
  document screens (row 25) are not part of it.

## 1. What the kernel is today (measured on this tree)

Shared lines are measured as the inventory measures them (its "Commands behind the numbers"): both files
with the module names replaced by one placeholder, leading spaces, comments, blank and bare
`end`/`do`/`else`/`)` lines dropped, then `comm -12` of the sorted unique lines. It counts lines that read
the same, not proven-equal functions.

| Row | Part | Assets file (lines) | Stock file (lines) | Shared lines now | Inventory (2026-11-11) | Why HELD |
|---|---|---|---|---|---|---|
| 6 | Document context (save, replace, discard, issue, fetch, list) | `lib/letflow/modules/assets/documents.ex` (948) | `lib/letflow/modules/stock/documents.ex` (925) | 366 | 369 | writes tenant records and document tables |
| 7 | Kinds table | `.../assets/documents/kinds.ex` (303) | `.../stock/documents/kinds.ex` (255) | 60 | 60 | not HELD itself; design section 5 puts it with the kernel |
| 8 | Shape parsing | `.../assets/documents/shape.ex` (365) | `.../stock/documents/shape.ex` (375); plus `opening_shape.ex` (241) | 89 | 89 | not HELD itself; with the kernel (section 5) |
| 9 | Checks | `.../assets/documents/checks.ex` (358) | `.../stock/documents/checks.ex` (218) | 31 | 34 | reads tenant masters |
| 9 | Opening checks | `.../assets/documents/opening_checks.ex` (134) | `.../stock/documents/opening_checks.ex` (81) | 10 | 13 | reads tenant masters |
| 10 | Posting and reversal | `.../assets/documents/posting.ex` (768) | `.../stock/documents/posting.ex` (892); plus `opening_posting.ex` (79) | 300 | 300 | writes ledger entries and process instances |
| 11 | Ledger policy | `.../assets/ledger_policy/declare.ex` (231) | `.../stock/ledger_policy/declare.ex` (236) | 71 | 71 | counted by the policy allowlist |
| 12 | Write handlers | `.../assets/handlers.ex` (311) | `.../stock/handlers.ex` (206) | 78 | 78 | tenant writes; handler purity scan H4 |
| 13 | Opening-balance import | `.../assets/documents/opening_import.ex` (198) | `.../stock/documents/opening_import.ex` (168) | 75 | 75 | writes tenant drafts |

HELD rows 6 and 9 to 13 together: 366 + 31 + 10 + 300 + 71 + 78 + 75 = **931 shared lines** (the design's
"about 1000"); with rows 7 and 8, 1080. The small drops in rows 6 and 9 come from slices S1 to S3, which
moved the number label and import helpers out. `find` of row 14 (about 17 lines, two copies in the
master-data imports) is not re-measured here; the record treats it with question 6.

What the kernel calls today (grep of `posting.ex` in both modules): `Letflow.Engine.create`,
`Letflow.Engine.complete_task`, `Engine.cancel_instance`, `Letflow.Ledger.entries`, `Documents.fetch`,
`Documents.cancel`, `Repo.one`, `Repo.all`, `Repo.aggregate`. The handlers call `HandlerWrites.create`,
`HandlerWrites.post`, `HandlerWrites.update` and `HandlerWrites.next_record_id`, and otherwise only `Map`,
`Enum` and `Ecto.Multi` types.

Surfaces any option below touches:

- `mix letflow.check_boundaries` (`lib/mix/tasks/letflow.check_boundaries.ex`): rule 5 (core may not
  reference a module file), rule 7 and 7b (neutral vocabulary and no `Letflow.Modules.*` reference in
  `ledger_scan_paths/0`, which takes `lib/letflow/ledger/**/*.ex`), rule 8 (scans `lib/letflow/modules/<id>/**`;
  `lib/letflow/ledger/**` is exempt by construction), the policy allowlist (`policy_paths/0` =
  `lib/letflow/modules/*/ledger_policy/**/*.ex`; today 2 files).
- Scan H4, handler purity, in `test/letflow/entities/handler_writes_callers_test.exs`: the handler files are
  derived at run time from the compiled manifests (`Catalog.all_manifests/0` and each handler module's
  source), and may not reference `Repo`, `Ecto.Query`, `Records` and the other names listed in its header.
- `Letflow.Modules.ManifestHash.compute/1` (`lib/letflow/modules/manifest_hash.ex`): hashes, per write handler,
  `inspect(module)` and the function name, and the whole `ledger` map including the policy module and
  function (stock: `policy: {Letflow.Modules.Stock.LedgerPolicy, :declare}` in
  `lib/letflow/modules/stock/stock.ex`). It does not hash handler code; its moduledoc sets the discipline
  "bump `:version` whenever handler code changes". Versions today: assets `0.16.0`, stock `0.17.0`.
- The upgrade chain U1 to U4 (decision 0080 and `docs/migration/decisions/0055-module-upgrade-migration-uninstall.md`):
  a changed hash makes every installed tenant answer the U3 409 on module writes until U1 and U2 run.

## 2. The six questions, with the options found

### Q1. The kernel API: a behaviour or plain functions with a kind table

| Option | What it means | Cost in files | Tests and lints moved |
|---|---|---|---|
| A. Behaviour | A new behaviour under `lib/letflow/documents/` (for example `Letflow.Documents.Kind`, planned, not yet on main) with callbacks for kinds, shape and checks; each module's `documents/kinds.ex`, `shape.ex` and `checks.ex` implement it | new core file; the six module files of rows 7 to 9 gain `@behaviour` and lose the shared bodies; `documents.ex` of both modules calls the kernel | none of the boundary rules move (core takes no module name: rule 5 holds as long as the behaviour module is passed in by the module). Existing `documents_router_test.exs`, `opening_shape_test.exs`, `opening_checks_test.exs` of both modules must pass unchanged. A precedent for a behaviour in that directory exists: `Letflow.Documents.OrgResolver` and `Letflow.Documents.Renderer` (`@callback` in `lib/letflow/documents/org_resolver.ex`, `renderer.ex`) |
| B. Plain functions with a kind table | Core functions that take the module's kind table (a map) and callbacks as arguments, as design section 5 does for the router kit | same files; no behaviour file | same; the compiler does not check that a module supplies every entry (no `@callback` warning), so a canary per kind must |
| C. No kernel API | Leave rows 6 to 9 in the modules; extract only pure sub-functions as further small slices | none beyond the slices | none |

Recommendation (analyst's proposal): **A**, because the kernel needs several per-kind answers at once
(type keys, sides, header fields, required lines), the directory already uses behaviours for exactly this
kind of per-module plug-in, and a missing callback is then a compile warning, which the static checks fail
on. The behaviour is not a callback of `Letflow.Modules.Module`, so the manifest shape does not change
(design section 3).

### Q2. Where shared posting code lives without leaving rule 8's coverage

Row 10 is the largest copy (300 lines). Rule 8 forbids, in module files, any call of `Letflow.Ledger.post`
and `Capability.mint` and any `Letflow.Ledger.*` call except the listed reads and `Letflow.Ledger.Policy`;
it exempts `lib/letflow/ledger/**` by construction.

| Option | What it means | Cost | Tests and lints moved |
|---|---|---|---|
| A. Under `lib/letflow/ledger/` | A neutral helper (for example `Letflow.Ledger.DocumentPosting`, planned) | the helper file, both `posting.ex` | the file enters rule 7/7b scope (neutral words only, no `Letflow.Modules.*`), and leaves rule 8: the ledger's own single-call-site guarantee would then rest on review, not on the scan. `ledger_scan_paths/0` count rises by one |
| B. Under `lib/letflow/documents/` | A neutral posting helper beside the document context (planned) | the helper file, both `posting.ex` | the file is in neither rule 8 nor rule 7 scope today: rule 8 must be extended to it (`rule_8_paths/0`), or the helper must stay free of every rule-8 call by construction (it builds the command, the module still calls the engine) |
| C. Split: pure builders in core, calls in the module | The core helper builds lines, legs and reversal data (pure); `start_post`, `start_reversal` and every `Engine`/`Ledger` call stay in each module's `posting.ex` | helper file; the modules keep a thinner `posting.ex` | rule 8 unchanged (calls stay in scanned module files); the helper is pure, so it can be added to rule 7 scope voluntarily |

Recommendation: **C**, then decide whether it is worth also moving the calls. It keeps every rule-8 call
where the scan already looks, and removes most of the 300 lines (builders and consistency checks are the
bulk of the named functions). Names follow rule 7's denylist even where rule 7 does not scan, as design
section 2 asks.

### Q3. Shared policy helpers: into `Letflow.Ledger.Policy`, or widen the allowlist

`Letflow.Ledger.Policy` (`lib/letflow/ledger/policy.ex`) is already a behaviour (`@callback declare/2`) with
pure helpers (`decimal/2`, `uuid/1`, `token/2`, `leg/1`, `posting/1`); both `ledger_policy/declare.ex` files use it.

| Option | What it means | Cost | Tests and lints moved |
|---|---|---|---|
| A. Add helpers to `Letflow.Ledger.Policy` | The 71 shared lines that are generic (legs, sides, quantity, reversal) become functions of that module | `lib/letflow/ledger/policy.ex`, both `declare.ex` | policy allowlist unchanged (that module is already allowed); `policy.ex` is in rule 7 scope, so the helpers must use neutral names |
| B. Widen the allowlist | Add a new core module (for example a policy helper module, planned) to the allowed list of `policy_violations/1` | the check task, its test, the new file | the allowlist and rule 8 clause `:e` both change; a security-relevant lint changes, so it needs its own review |
| C. Leave as is | Each module keeps its `declare.ex` | none | none |

Recommendation: **A**. It changes no lint. The policy module and function named in the manifest
(`{...LedgerPolicy, :declare}`) stay, so the hash does not move.

### Q4. Whether handler code moves at all

The manifest names each handler module and function (for example
`function: {Letflow.Modules.Stock.Handlers, :post_document}`), and the hash covers them.

| Option | What it means | Cost | Tests and lints moved |
|---|---|---|---|
| A. Move handlers into core | The manifest names a core module | both manifests, both `handlers.ex` | the hash changes for both modules: version bumps (assets past `0.16.0`, stock past `0.17.0`), and on QA every installed tenant answers the U3 409 on writes until an administrator runs U1 and U2 (U4 is off by default). Registration tests that pin handler names move (`documents_registration_test.exs`, `posting_registration_test.exs` and similar). H4 would scan the core file instead |
| B. Handlers stay, bodies call a pure core helper | The handler module and function names stay; shared pure logic (argument checks such as `valid_args?`, mark building) moves to core | both `handlers.ex`, a helper file | hash unchanged. But H4 scans only the handler files it derives from the manifests: code moved out of them into a core helper is no longer scanned for purity. H4 must then also read the helper file (design rule 6, "source scans follow the code"), or it passes while checking nothing |
| C. Handlers stay as they are | 78 shared lines stay copied | none | none |

Recommendation: **B with the H4 extension written into the record**, or **C** if the owner prefers no
change on the write path. A is not behaviour-neutral for installed tenants (design section 3) and should
only come with its own upgrade plan. Moved handler code without a version bump would break the "bump on
handler code change" rule of `ManifestHash`; under B the record must say whether moving a pure helper
counts as "handler code changes" (the analyst reads it as no, since the handler's behaviour is unchanged
and the canary proves it, but this is for the decider).

### Q5. The proof of neutrality

| Option | What it means | Cost |
|---|---|---|
| A. Golden comparison through the real HTTP routes | Before the move, run posting and reversal of every document kind of both modules through the real routes (issue, claim and complete of the post task with a real token, as owner request D-098 asks, quoted in the REQ-770 entry of `docs/requirements.yaml`), record ledger rows, document rows and audit entries with ids and times normalised, paste as literals; after the move the same run must give the same literals | one new golden test per module; the fixtures exist (`test/letflow/modules/stock/posting_fixture.exs`, `test/letflow/modules/assets/documents_fixture.exs`) |
| B. Existing tests only | Rely on the current suites (`posting_test.exs`, `reversal_test.exs`, `opening_posting_test.exs`, `two_side_posting_test.exs`, `two_side_reversal_test.exs`, `receipt_posting_test.exs`, `count_posting_test.exs` in stock; `posting_test.exs`, `reversal_test.exs`, `kinds_posting_test.exs`, `kind_change_posting_test.exs` in assets) | none |
| C. A plus per-function canaries | As design rule 4 for each moved function, plus A | most |

Recommendation: **C**. The existing suites assert outcomes per case, not complete row sets, so B would not
catch an extra or missing audit entry. The golden test of A is written and merged **before** the first
kernel slice, as its own test-only slice, so it runs unchanged against the old and the new code.

### Q6. Security review of every tenant-data path it moves

| Option | What it means |
|---|---|
| A. One review for the whole kernel | One large review; too big for one review of one change |
| B. A review per slice | Every kernel slice that moves a function with a `prefix:` read or write (rows 6, 9, 10, 13 and `find` of row 14) goes through the security gate for INV-1 (the prefix still comes from the caller's scoped options, never from the request), INV-6 (the new path proves its scoping with a test) and INV-10 (the existing other-company cases of both modules' router tests run unchanged) |

Recommendation: **B**, with a fixed list in the record of which slices touch tenant data. Rows 7, 8 and 11
are pure and need the normal review only.

## 3. A possible slice order once the record is taken (not decided)

1. Golden neutrality tests for both modules (Q5), test-only.
2. Shape parsing (row 8) and kinds lookups (row 7) under the Q1 behaviour: pure.
3. Policy helpers into `Letflow.Ledger.Policy` (row 11, Q3): pure, no lint change.
4. Pure posting builders (row 10, Q2 option C).
5. Checks and opening checks (row 9), with security review.
6. Document context (row 6), with security review; it is the largest after posting.
7. Opening import (row 13) and `find` of row 14, with security review.
8. Handler helpers (row 12, Q4 option B) with the H4 extension, or nothing (Q4 option C).

Each is one pull request with the rules of design section 1 (canary, hashes quoted before and after,
boundary check output, no version bump unless the record says so).

## 4. Open points for the decider

- Q4: does moving a pure helper out of a handler file count as "handler code changes" for the
  `ManifestHash` version discipline?
- Q2: is option C enough, or should the record also allow moving `Engine`/`Ledger` calls into core with
  rule 8 extended?
- Whether the record covers `find` of row 14 (master-data imports of assets, locations, org and
  catalog_items) or leaves it to a separate small record, since it is not document code.
- No schema change was found to be needed by any option; if a later slice finds one, design section 3 says
  it stops and waits for the upgrade chain.

## Sources opened

`docs/design/core-extraction-design.md` (sections 1 to 8), `docs/design/core-extraction-inventory.md`
(header, rows 5 to 14, observations, commands), `docs/uat/ba-decisions/T-1785.md`,
`lib/mix/tasks/letflow.check_boundaries.ex` (moduledoc of rules 7, 8, policy allowlist; `ledger_scan_paths/0`,
`policy_paths/0`), `lib/letflow/modules/manifest_hash.ex` (moduledoc "Hashed surface"),
`lib/letflow/ledger/policy.ex` (callbacks and public functions), `test/letflow/entities/handler_writes_callers_test.exs`
(header and the H4 section), `lib/letflow/modules/stock/stock.ex` (write handlers, `policy:` line, `version:`),
`lib/letflow/modules/assets/assets.ex` (`version:`), the REQ-770 entry text in `docs/requirements.yaml`
(D-098 wording). Not opened: `ai-dala-portfolio/DECISIONS.md`, the bodies of the S1 to S7 pull requests.

## Commands behind the facts

```
git ls-tree --name-only origin/main docs/migration/decisions/ | tail -2
for b in $(git branch -r | grep 'origin/team/'); do git diff --name-only origin/main...$b -- docs/migration/decisions docs/design; done | sort -u
n(){ sed -E 's/Assets|Stock/X/g;s/assets|stock/x/g;s/^ *//' "$1" | grep -vE '^(#|$|end|\)|do|else|""")' | sort -u; }
for p in documents.ex documents/kinds.ex documents/shape.ex documents/checks.ex documents/opening_checks.ex documents/posting.ex ledger_policy/declare.ex handlers.ex documents/opening_import.ex; do a=lib/letflow/modules/assets/$p; s=lib/letflow/modules/stock/$p; echo "$p $(wc -l <$a) $(wc -l <$s) $(comm -12 <(n $a) <(n $s) | wc -l)"; done
wc -l lib/letflow/modules/stock/documents/opening_{shape,posting}.ex
grep -ohE '(Letflow\.)?(Ledger|Engine|Records|Documents|HandlerWrites|Repo|Audit)\.[a-z_!?]+' lib/letflow/modules/{assets,stock}/documents/posting.ex | sort | uniq -c
grep -ohE '[A-Z][A-Za-z]+\.[a-z_!?]+\(' lib/letflow/modules/{assets,stock}/handlers.ex | sort | uniq -c
grep -rn '@callback\|@behaviour' lib/letflow/documents* ; grep -n '@callback\|  def ' lib/letflow/ledger/policy.ex
grep -n 'version:' lib/letflow/modules/{assets/assets,stock/stock}.ex
```
