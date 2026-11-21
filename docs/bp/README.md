# Business-process map (D-168 / D-169)

A **business process** is made of **tasks**. Each task uses **screen forms** and **system functions**
(engine functions, scripts, business rules). A thing that no process uses has no user, needs no
development and no test: it is either given a process or listed as an **orphan**.

This folder holds the map; `scripts/uat/` holds its two tools.

| File | What it is |
|---|---|
| `docs/bp/<area>.json` | the processes of one area: a JSON list of entries (schema below) |
| `docs/bp/orphans-<area>.md` | the inventory items of the area that no process uses (format below) |
| `scripts/uat/bp_inventory.py <area\|all>` | lists everything a process could use, mechanically |
| `scripts/uat/check_catalog.py [area ...\|all]` | validates the files and computes COVERAGE |
| `scripts/uat/check_routes.py` | the mechanical route inventory (D-170): authentication, tenant scope and permission of every API route |
| `docs/bp/public-routes.json` | the allow-list of declared routes (public, shared-secret, exempt), each with reason and owner |
| `docs/bp/route-gaps.md` | the first run of `check_routes.py`: the routes that fail (a to-do list, generated with `--gaps-md`) |

Areas: `stock`, `assets`, `procurement`, `maintenance`, `master` (org, locations, catalog_items, codes),
`exam`, `mes`, `tenant-admin`, `platform`, `designer`. The table that maps an area to its source paths is
`AREAS` in `scripts/uat/bp_inventory.py`; `python3 scripts/uat/bp_inventory.py --unassigned` lists router
files, module directories and web routes that no area owns (a gap in that table).

Commands (standard library only, run from the repository root):

```
python3 scripts/uat/bp_inventory.py stock            # JSON list of the inventory of one area
python3 scripts/uat/bp_inventory.py stock --summary  # counts per kind
python3 scripts/uat/check_catalog.py                 # every area that has a file under docs/bp/
python3 scripts/uat/check_catalog.py stock assets    # named areas
python3 scripts/uat/check_catalog.py all             # every area; an area without a file is 0% and fails
```

`check_catalog.py` prints one `COVERAGE <area>: n/m = p%` line per area, the uncovered items, every error,
and ends with `check_catalog: PASS` or `FAIL`. Exit code 0 only when there is no error and every checked
area is at 100%.

`public-routes.json`, `dead-code.json`, `dead-code-allow.json` and `dead-code-baseline.json` are support files,
**not area catalogs**; `route-gaps*.md` is not a catalog either. With no area argument, `check_catalog.py` skips
these files silently. Any other `docs/bp/*.json` file whose name is not an area is still an error, and every area
catalog is validated as usual.

## The inventory (what `bp_inventory.py` lists)

Output: a JSON list of `{id, kind, path, line, name, end, aliases, area, ...}`; `end` is the last line the item
covers (the line before the next item of the same file, or the end of the file). Ids are stable:
`<kind>:<path>:<name>`.

| kind | mechanical source | `name` | other names (`aliases`) |
|---|---|---|---|
| `screen` | `path:` entries of `web/src/router.tsx` (core pages, split to areas by the `web` regexes of `AREAS`) and of `web/src/modules/<m>/*Routes.tsx`; the page is the first capitalised JSX tag after the path that is not `RequirePermission`/`ModuleGuard` | `<route path> -> <PageComponent>` | the route path (with and without `/`), the component name |
| `route` | `authz_get/post/put/patch/delete "<path>", :Permission` (and plain `get/post/...` macros) in `lib/letflow/routers/*.ex`, `lib/letflow/router.ex` and `lib/letflow/modules/<m>/router.ex`; the mount prefix comes from the `forward` lines of `lib/letflow/router.ex` and `lib/letflow/plugs/api_pipeline.ex` (module routers: `/api/v1/modules/<m>`); extra field `permission` | `<VERB> <full path>` | none (a task names it in `route`) |
| `pack_node` | a node of a process definition in `priv/modules/<m>/pack.json` (the file `generate_pack.exs` writes) that is not START, END or SCRIPT_TASK | `<process_key>/<node id>` | `<m>:<process_key>/<node id>` |
| `handler` | a `%WriteHandlerSpec{name: ...}` under `lib/letflow/modules/<m>/`: the **module write handler** that a pack's `module_writes` line calls. These are the "engine functions called by packs"; the function behind it is the spec's `function:` | `<m>.<handler name>` | `<m>:<handler name>` |
| `script` | a SCRIPT_TASK node of a pack, a `*.lua` file of a module, and (area `designer`) every file of `lib/letflow/scripts/` | module or file name | file stem, file name |
| `rule` | **business rule = a public `def`** (first clause of each name) of the area's rule files: a module's `ledger_policy/*.ex` (the `declare` posting policy) and any `*rules*.ex`, `*checks*.ex`, `*guard*.ex`, `*policy*.ex` under `lib/letflow/modules/<m>/`, plus the extra files named in `AREAS[...]["rules"]` (area `tenant-admin`: approval rules, separation of duties) | `<Module>.<function>` | none |

An area whose inventory is empty (today `mes`: no router, screen, rule or handler yet) has nothing to
cover and reads 100%.

## The process entry (`docs/bp/<area>.json`)

The file is a JSON list. One entry per business process, written in the user's words.

```json
{
  "id": "BP-STOCK-01",
  "area": "stock",
  "title": "Receive goods",
  "description": "The storekeeper records goods received at a place; a tenant administrator posts it from My Tasks; the balance rises.",
  "actors": [
    {"role": "STOREKEEPER", "permission": "StockWrite"},
    {"role": "TENANT_ADMIN", "permission": "StockApprove"}
  ],
  "preconditions": ["module stock installed", "item, place, org unit and responsible exist"],
  "tasks": [
    {
      "actor": "STOREKEEPER",
      "forms": ["admin/stock/documents/new"],
      "functions": ["stock.post_document"],
      "route": "POST /api/v1/modules/stock/documents",
      "code_refs": ["lib/letflow/modules/stock/router.ex:120"],
      "result": "a draft receipt with a document id"
    }
  ],
  "inputs": ["item_code", "place_code"],
  "outputs": ["doc_id", "balance_after"],
  "refusals": ["a role without StockWrite is refused with 403"],
  "scenario": "test/uat/processes/BP-STOCK-01.json",
  "status": "implemented"
}
```

| field | type | rule |
|---|---|---|
| `id` | text | `BP-<AREA>-nn` for the area of the file (`BP-TENANT-ADMIN-03`); unique across all files |
| `area` | text | one of the areas; equal to the file name |
| `title`, `description` | text | not empty |
| `actors` | list of `{role, permission}` | at least one; the role by name, the permission atom that grants the work |
| `preconditions`, `inputs`, `outputs`, `refusals` | list of text | may be empty; `refusals` = what the process refuses and with which answer |
| `tasks` | list | see below; at least one unless the status is `planned` |
| `scenario` | text or `null` | repo-relative path of the runner script (`test/uat/processes/<id>.json`); must exist when not null |
| `status` | `implemented` \| `partial` \| `planned` | `implemented` only when code **and** a test exist; `planned` needs the extra field `requirement` (a REQ id) |

A **task** is one step of the process done by one actor:

| field | type | meaning |
|---|---|---|
| `actor` | text | who does it (a role) |
| `forms` | list of text | the screens used: a route path (`admin/stock/documents/new`) or a page component name (`DocumentNewPage`) |
| `functions` | list of text | the system functions used: a handler (`stock.post_document`), a pack node (`stock_receipt/post`), a rule (`Letflow.Modules.Stock.PostingRules.negative_allowed?`), a script; the exact `name` or an alias of the inventory item |
| `route` | text, list of text or `null` | the API call(s), `VERB /full/path` (`POST /api/v1/modules/stock/documents/:id/issue`); parameter names do not matter |
| `code_refs` | list of `path:line` | where the task is implemented; every one must resolve (the file exists, the line is inside it); required for `implemented` and `partial` |
| `result` | text | what the actor gets |

## How coverage is counted

An inventory item is **covered** when at least one task of any process (any area's file) names it by
one of:

1. a `code_refs` entry `path:line` with the item's path and a line from `line` to `end` of the item;
2. a `route` equal to the item's `name` (route items only; verb case and `:param` names are ignored);
3. an entry of `forms` or `functions` equal to the item's `name` or one of its `aliases`;

or when the area's orphan file lists it (an orphan row whose `file:line` falls inside the item).
Coverage of an area = covered items / inventory items. The tool lists the uncovered items.

## Orphans (`docs/bp/orphans-<area>.md`)

A function that no process uses is **not deleted and not judged by the writer**: it goes into the orphan
file as one row of a Markdown table with exactly these columns, none empty:

```
| function | file:line | what it does | history | why it exists | proposed action |
|---|---|---|---|---|---|
| Letflow.Modules.Stock.Handlers.post_kind_change_out | lib/letflow/modules/stock/stock.ex:657 | posts the out leg of a kind change | REQ-NNN, git log -S ... | needed by the kind-change flow | give a process |
```

- `history`: the requirement or the `git log -S` result the function came from.
- `proposed action`: exactly one of `give a process`, `keep as a platform function`, `remove`. Only
  dead code with no caller, no requirement and no test may be proposed for removal, and the owner sees it first.
- A row whose `file:line` matches no inventory item of the area is a stale row and an error.

## Statuses and checks the validator repeats

`check_catalog.py` checks the form (fields, types, ids, statuses, resolving `code_refs`, existing
`scenario` paths, coverage). It cannot check that a `code_refs` line really does what the task says:
the `ba-validator` gate opens the file at the line and confirms it.

## The route inventory (`check_routes.py`, D-170)

`python3 scripts/uat/check_routes.py [--gaps-md FILE] [--json]` lists every route of `lib/letflow/router.ex`,
`lib/letflow/routers/*.ex` and `lib/letflow/modules/<m>/router.ex` (old-address, public, signup, webhook and
upload routes included) with three facts and fails when one is missing:

| fact | derived when | otherwise |
|---|---|---|
| authentication (`oidc-or-api-token`, `shared-access`, `shared-secret`, `api-token`, `none-by-design`) | the route is mounted under `/api/v1` (ApiPipeline) | declared in `public-routes.json` |
| tenant scope (`tenant-prefix`, `platform-level`, `host`, `none-by-design`) | under `/api/v1`: `tenant-prefix`, `platform-level` in a router of area `platform` | declared |
| permission | the policy atom of an `authz_*` macro | declared as a name or `exempt` |

`public-routes.json` is a JSON list of `{route (text or list), authentication?, tenant_scope?, permission?, reason, owner}`;
a `none-by-design` or `exempt` value needs a reason and an owner, a route outside `/api/v1` that is not listed is an
unknown public route, and an entry that names no existing route is stale. Coverage: every route must also be
referenced by a process task or be on the orphan list. The same run scans the packs (WRITE-TARGETS): a variable a
`module_writes` argument reads must not be a completer input of any node (the T-2299 hole; the scan test
`test/letflow/modules/write_target_sources_scan_test.exs` is the Elixir twin, fixtures `test/fixtures/t2299_hole/`).
Exit code 0 only when nothing fails. The routes that fail today are in `docs/bp/route-gaps.md`.

## The dead-code inventory (`dead_code.py`, D-172)

`bp_inventory.py` lists routes, screens, pack nodes, write handlers, scripts and rule files. It has no
function-level items for the context modules, so a public function of `lib/letflow/` that nothing calls is
invisible to it (`project/bp-orphans.md`, "LIMIT OF THE TOOL"). `dead_code.py` closes that hole.

```
python3 scripts/bp/dead_code.py                # the report and the counts per area
python3 scripts/bp/dead_code.py --area stock   # one area of the shared table
python3 scripts/bp/dead_code.py --json         # the report as JSON on stdout
python3 scripts/bp/dead_code.py --check        # the CI gate: a NEW dead function fails
```

| file | what it is |
|---|---|
| `docs/bp/dead-code.json` | the report: every public function of `lib/letflow/` with no caller, with its reason |
| `docs/bp/dead-code-allow.json` | the allow-list: `{module, function, arity, reason}`; the business analyst fills it in, the tool never writes to it |
| `docs/bp/dead-code-baseline.json` | the functions that were dead at the first run; `--check` fails only when a NEW dead function appears |

One entry of the report: `{area, module, function, arity, file, line, kind, reason}`. `area` comes from the
same table as the inventory (`AREAS` of `bp_inventory.py`, by path); a file no area owns is `unassigned`.
The reasons:

| reason | meaning |
|---|---|
| `no_caller` | no caller in `lib/` and no caller in `test/` |
| `test_only` | a caller in `test/`, none in `lib/` |
| `dynamic_suspect` | no caller at all, but the module is the target of a dynamic dispatch, so the tool cannot prove the function is dead |

The callers come from `mix xref` (`scripts/bp/xref_calls.exs`, the runtime call graph of the compiled
project) and from the source of `lib/` and `test/` (the local calls, the calls through an `import`, the
calls the compiler cannot see and the calls of the test files). A caller is matched by module and function
NAME, not by arity: the tool errs towards "not dead".

A function is never reported when it is a callback (`@impl`, `@behaviour`, `use GenServer`, a Plug's
`init/1` and `call/2`, a Mix task's `run/1`), a protocol implementation, a reference as a value
(`&Mod.fun/n`, `{Mod, :fun, args}`, `apply(Mod, :fun, args)`, a `{Mod, :fun}` of the config), a function
named by a string of a pack or of the config, or an entry of the allow-list.

Nothing is deleted and nothing in `lib/` is changed: the tool writes the report, and the business analyst
decides what happens to a function (the orphan files of the area). `--check` is the gate: it fails when a
dead function that is in neither the baseline nor the allow-list appears, so the number of dead functions
cannot grow; removing one from the baseline is allowed.

The web app has no unused-export tool (no knip, no ts-prune, no eslint `no-unused-modules`), so the report
says `not covered` for it; the task forbids adding a dependency.

### The first run (2026-11-21)

15 dead functions of the 3329 public functions of `lib/letflow/`: 5 `no_caller`, 6 `test_only`,
4 `dynamic_suspect`; 25 dynamic call sites. Per area: `procurement` 8, `unassigned` 5, `designer` 1,
`master` 1. The baseline (`docs/bp/dead-code-baseline.json`) holds those 15; `--check` fails from now
on when a NEW dead function appears.
