# UAT process runner (D-167, M1)

A runner that plays a **business process** against a running Letflow tenant step by step, checks every answer
and writes a log. No model is involved: the same file gives the same result every time, so it can be repeated
on every release candidate. Python 3.11, standard library only. It is not an engine step and writes no task
state. Design note: `project/uat-process-runner.md` in the team repository.

What is here:

| file | what it is |
|---|---|
| `runner.py` | the runner: `run` (one process), `chain` (several processes sharing one context), `cleanup` (undo an aborted run), `dry-run` (the changed process files) |
| `check_processes.py` | the static check of process and chain files (no network) |
| `../../test/uat/processes/*.json` | the process files (one business process each), for example `BP-01-receive-goods.json` |
| `../../test/uat/chains/*.json` | the chain files (an ordered list of processes) |
| `../../test/uat/fixtures/*.json` | the fixture files (records a process needs to exist: section 2a) |
| `tests/` | the tests, with a fake server |

The sections 1 to 4 are for the **business analyst**: how to describe a process so that the runner can play it.
The sections 5 to 9 are for whoever runs it and for developers.

---

## 1. What a process file says (for the business analyst)

A process file is a plain text file (JSON) that says, in order, **who does what, and what the system must answer**.
Think of it as the written scenario of a walkthrough, with every sentence made exact:

* **who**: an *actor*, a role of the test roster (`admin`, `storekeeper`, `admin2`: the last word of an entry
  `actor-<tenant>-<role>` in `test/fixtures/uat/actors.yaml`);
* **what**: one call of the application (create a document, issue it, read the balance), or "wait for the task
  of this document in My Tasks, take it and complete it";
* **what is expected**: the answer code (for example `201` created) and the values that must be in the answer
  (for example the document is `posted`, the balance is the old balance plus 5);
* **what is remembered**: values from an answer that later steps need (the id of the document that was created).

If an answer is not as expected the step is *failed*, the rest of the steps are *skipped*, and the process cleans up
after itself (it reverses what it posted), so the test tenant is left as it was found.

### The parts of a file

```json
{
  "id": "BP-01",
  "bp_entry": "BP-01",
  "title": "Receive goods",
  "description": "A storekeeper receives 5 units; the balance grows by 5; the cleanup reverses the receipt.",
  "inputs": ["item", "place", "org_unit", "responsible"],
  "defaults": {"quantity": "5"},
  "dry_run": {
    "tenant": "qoimeks-qa2",
    "actors": {"admin": "qoimeks-qa2-admin", "storekeeper": "qoimeks-qa2-storekeeper"},
    "inputs": {"item": "<id>", "place": "<id>", "org_unit": "<id>", "responsible": "<id>"}
  },
  "steps":   [ ... ],
  "outputs": {"receipt_doc_id": "${doc_id}"},
  "cleanup": [ ... ]
}
```

| part | meaning |
|---|---|
| `id`, `title`, `description` | what the process is, in your words |
| `bp_entry` | the id of the entry of the business-process map that this file implements (the same id as in the map) |
| `inputs` | the names of the things the process needs from outside: the item, the place, a document of an earlier process. The person who starts the run gives their values |
| `defaults` | an input with a value already filled in (here `quantity` 5) |
| `dry_run` | what the **dry run on QA** uses: the tenant, a user name for each actor, and a value for each input. Needed on every file the BA writes, see section 4 |
| `steps` | the story, in order |
| `outputs` | the names this process hands to the next process of a chain |
| `cleanup` | the steps that undo the effect. They run at the end, also after a failure |

### One step

```json
{
  "id": "s1",
  "actor": "storekeeper",
  "do": {"api": "POST", "path": "/api/v1/modules/stock/documents",
         "body": {"kind": "receipt", "location_id": "${place}", "lines": [{"catalog_item_id": "${item}", "quantity": "${quantity}"}]}},
  "expect": {"status": 201, "json": {"state": "draft"}},
  "save": {"doc_id": "$.id"}
}
```

Read it as: *"The storekeeper creates a receipt. The system must answer 201 and the document must be a draft.
Remember the id of the document as `doc_id`."*

* `id`: a short unique name of the step (`s1`, `s2`...; cleanup steps `c1`, `c2`...). It appears in the log.
* `actor`: who does it.
* `do`: the call. `api` is the method (`GET` read, `POST` create or act, `PUT` change, `DELETE` remove),
  `path` the address, `body` what is sent. The address and the body come from the application's API: copy them
  from the API description or from the existing tests of the screen, never invent them. `check_processes.py`
  tells you when an address does not exist.
* `${name}` is replaced by the value of that name: an input, something an earlier step saved, or one of the
  built-in names `${tenant}`, `${TENANT}`, `${run_id}` (the id of this run: put it into notes so that test data is
  recognisable), `${now_utc}` (the time now), `${old_base_url}` and `${uuid1}` .. `${uuid12}`. Each UUID name is a
  fresh UUID for the run, different from the other names, and keeps the same value wherever it is used, including a
  `repeat` retry. You may add and subtract numbers: `${balance_before + quantity}`.
  Using a name that nobody gave or saved is a mistake that the static check reports.
* `expect`: what a good answer is. `status` is the answer code (one code or a list: `[200, 201]`; without it any
  `2xx` is good). `json` lists values that must be in the answer: the key is a path (`$.state`,
  `$.rows[0].quantity`), the value is what it must be. Numbers compare as numbers (`"10.000000000"` equals `"10"`).
  Besides "equals" you may write `{"contains": "text"}`, `{"regex": "..."}`, `{"exists": true}`, `{"absent": true}`,
  and `{"equals": "0", "default": "0"}` ("an empty list counts as 0").
* `save`: remember something from the answer: `"doc_id": "$.id"`. `{"pick": "$.rows[0].quantity", "default": "0"}`
  remembers the first balance row or `0` when there is none. `{"api": "GET", "path": "...", "pick": "$.x"}` reads
  something else as the same actor and remembers it.
* `requires` (optional): `"requires": ["doc_id"]` runs the step only if that name was saved. Use it on every cleanup
  step, so nothing is reversed that was never created.

### Special steps

| you want to say | write |
|---|---|
| the person takes the task of a document in My Tasks and completes it | `"do": {"wait_task": {"for_document": "${doc_id}", "step": "post", "within_s": 30}, "claim": true, "complete": {"body": {}}}`. `step` is `post` for a receipt, issue or transfer and `reverse` for a reversal |
| only look and check (no change) | `"do": {"assert_only": {"path": "/api/v1/..."}}` and an `expect`. A read, never a body |
| the same request twice (a retry: the system must not do it twice) | `"do": {"repeat": {"api": "POST", "path": "...", "body": {...}}}`, `"expect"` for the first answer and `"expect_repeat"` for the second (default: the same as the first) |
| two people press at the same moment (concurrency) | `"do": {"parallel": [{...call 1...}, {...call 2...}]}` and `"expect": {"unordered": [{"status": 201}, {"status": 409}]}`: one wins, one is refused, in any order. A list `"expect": [e1, e2]` fixes the order |
| the system must refuse | `"expect_refused": {"status": 422, "code": "output_refused"}` instead of `expect`: any `4xx` (or the given status) whose answer names the code. `"expect_refused": "output_refused"` is the short form |
| the old phone address (shared access) | see below |

**Shared access (the old address).** The process creates the shared access value itself, uses it as the old app does,
and revokes it in the cleanup. The value is kept in the memory of the runner only: it is never written to a file or
printed.

```json
{"id": "s1", "actor": "admin", "do": {"api": "POST", "path": "/api/v1/identity/shared-stock-access", "body": {}},
 "expect": {"status": 201}, "save": {"shared_created": "yes", "shared_access": {"secret": "$.value"}}},
{"id": "s2", "http_as": "shared_access", "do": {"api": "GET", "path": "/movements"}, "expect": {"status": 200}}
...
"cleanup": [{"id": "c1", "actor": "admin", "requires": ["shared_created"],
             "do": {"api": "DELETE", "path": "/api/v1/identity/shared-stock-access"}, "expect": {"status": 204}}]
```

`http_as: shared_access` sends the step to the old address (`--old-base-url`, for example
`https://qa.bizdala.com/qoimeks/<slug>/api`) with the value as the bearer. Such a step has no `actor`. The path is
the path of the old app (`/movements`), checked against `lib/letflow/routers/shared_stock_access.ex`.

### Do and do not

* One file = one business process, from the first action to the check of the result. Name an input for every id the
  process cannot know.
* Every step has an `expect`. A step without one is reported.
* Put every undo in `cleanup`, with `requires`. A process that cannot undo something says so in its `description`.
* Never put a password, a token or a secret into a file. The runner gets tokens from the environment.
* Run the static check before you hand the file over: `python3 scripts/uat/check_processes.py --strict <file>`.

---

## 2. Chains (several processes, one context)

A **chain file** lists processes in order. The outputs of a process become the inputs of the next ones: a receipt
(`BP-01`) hands its document id to the reversal (`BP-05`).

```json
{
  "id": "rc-sss",
  "title": "Release candidate run for SSS",
  "processes": ["BP-01", "BP-02", "BP-05"],
  "tenant": "sss-rehearsal2",
  "actors": {"admin": "sss-rehearsal2-admin", "storekeeper": "sss-rehearsal2-storekeeper"},
  "inputs": {"item": "<id>", "place": "<id>", "org_unit": "<id>", "responsible": "<id>"},
  "dry_run": {"tenant": "sss-rehearsal2", "actors": {"admin": "..."}, "inputs": {"item": "..."}}
}
```

* `processes` are looked up in `test/uat/processes/` by the id (`BP-01` finds `BP-01-receive-goods.json`), by the
  file name, or by a path relative to the chain file.
* `tenant`, `actors`, `inputs`, `base_url`, `old_base_url` in the chain file are defaults; the command line wins.
* A process may read a name only if the chain gives it, an earlier process saved it as an `output`, or it is a
  default. `check_processes.py` and the runner check this before the first request.
* **A failing process stops the chain** (the rest are logged *skipped*), unless `--keep-going`.
* **Cleanup of a chain runs at the END, process by process in reverse order**, each with the values it had when
  it finished. So `BP-05` can still reverse the document of `BP-01`, and `BP-01`'s own cleanup then finds it already
  reversed: give such a cleanup step a tolerant `expect` (`{"status": [200, 409, 422]}`) or leave the undo to the
  later process. Cleanup of the processes that already ran always happens, also after a failure.

---

## 2a. Fixtures (records a process needs to exist)

Some cases (the security negatives of assets, for example) need a record that does not exist on a QA tenant: an
asset card, an opening document. A **fixture** is a small reusable file that makes it. A process (or a chain)
names the fixtures it needs: `"fixtures": ["asset_opening_doc"]`.

* The runner runs the fixtures **before** the steps, once per run (a fixture named by two processes runs once),
  in the order given, after the fixtures they `need`. They share the context: what a fixture `provides` (for
  example `asset_card_id`, `asset_doc_id`) can be used as `${asset_card_id}` by the processes and is in `context.json`.
* Their cleanup runs **after** every process cleanup, in reverse order, always (also after a failure).
* An unknown fixture name is exit 2 before anything runs; `check_processes.py` checks the names, that every
  `${name}` is provided by a fixture or an input, and the fixture files themselves.

A fixture file is process-like (`steps`, `cleanup`, `inputs`, the same step kinds), plus:

| key | meaning |
|---|---|
| `id` | the file name without `.json` |
| `description` | what it makes |
| `leaves` | what stays on the tenant if the cleanup cannot remove it (for example a retired card) |
| `provides` | the context names it saves (each must be saved by a step) |
| `needs` | fixtures that run before it (optional) |
| `inputs` | ids it needs from outside (the person who runs gives them with `--input`) |

**Rules for writing one** (idempotent, self-cleaning):

1. **Look first.** Step 1 looks for the record by a deterministic reference, for example the external reference
   `UAT-FIX-<name>-${tenant}`, and saves the id with `"save": {"x_id": {"pick": "$.items[0].record_id", "optional": true}}`
   (`optional`: nothing found leaves the name unset instead of failing).
2. **Create only if not found:** the create step has `"skip_if": ["x_id"]` (skipped when the name is already set)
   and saves the id plus a mark: `"save": {"x_id": "$.record_id", "x_created": "yes"}`.
3. **Remove only what you created:** every cleanup step has `"requires": ["x_created"]`. A record that was found
   (made by an earlier run) is never touched. `check_processes.py` fails a fixture cleanup step with no `requires`.
4. Mark everything you create with the same reference, so a human can recognise it; say in `leaves` what stays.
5. Never read or write a record that is not yours.

Shipped: `asset_card` (provides `asset_card_id`; a minimal fixed-asset card without photo) and `asset_opening_doc`
(needs `asset_card`; inputs `org_unit`, `location`, `responsible`; provides `asset_doc_id`; a draft opening document
with one line, never issued). Run them on QA with real tokens like any process.

---

## 3. Running

The environment must hold what `project/scripts/uat_creds.sh` needs (the `.env.uat` of the team) and `TEAM_ROOT`
(the team repository). For every actor the runner calls `bash "$TEAM_ROOT/project/scripts/uat_creds.sh" token <user>`;
the password never goes into the command line and the token stays in memory.

```
# one process
python3 scripts/uat/runner.py run test/uat/processes/BP-01-receive-goods.json \
  --tenant qoimeks-qa2 --actors admin=<user>,storekeeper=<user> \
  --input item=<id> place=<id> org_unit=<id> responsible=<id> --run-dir /tmp/uat-bp01

# a chain on a release candidate
python3 scripts/uat/runner.py chain test/uat/chains/rc-sss.json --build-sha <sha> --file-issues --repo tvolodi-org/letflow

# undo what an aborted run left
python3 scripts/uat/runner.py cleanup /tmp/uat-bp01        # same as: runner.py --cleanup /tmp/uat-bp01

# the files that differ from origin/main, each with its own dry_run block
python3 scripts/uat/runner.py dry-run --changed
```

Common options: `--tenant`, `--base-url` (default `https://<tenant>.letflow.qa.bizdala.com`, or
`--base-url-template` / env `UAT_BASE_URL_TEMPLATE`), `--actors a=user,b=user`, `--input NAME=VALUE ...`,
`--input-file F` (JSON, for example the `context.json` of an earlier run; `--input` wins), `--run-dir`,
`--health-url`, `--poll-interval`, `--build-sha`, `--no-stable-check`, `--old-base-url`, `--file-issues`,
`--repo`, `--gh`. Inputs are the ids the API takes (not codes).

Exit code **0**: every step, every cleanup step and the build check passed. **1**: a verdict failed (or the preflight
refused to start). **2**: bad command line or process file, nothing was run (`dry-run` never uses 2 for a failure:
the `bp_dryrun` capability reads exit 2 as "this runner has no dry-run command yet").

### Preflight: the run starts only when all of this is true

1. `GET /health` gives a build `sha`.
2. With `--build-sha`: the sha is that build (a prefix is enough). Otherwise the run is for another build: it does
   not start.
3. When `TEAM_ROOT` is set (and `project/scripts/qa_stable.sh` exists): `qa_stable.sh --wait` says the sha has been
   stable for a few minutes, and it is the same sha. `--no-stable-check` skips it.
4. The tenant answers at its base url.
5. **Every actor gets a token before the first step.** A missing token stops the run with no change made.

The sha is read again at the end: **a different sha ("build moved") fails the run**, whatever the steps said.

### What a run does

1. Preflight (above). 2. For each process: its steps in order; the first failing step stops its steps (the rest are
logged `skipped`); its `outputs` are evaluated. 3. All recorded cleanups, newest process first. A cleanup step with
`requires: [names]` is skipped while one of the names is not in the context yet. A failing cleanup step does not
stop the next one, and it fails the run. 4. `GET /health` again. 5. With `--file-issues`: the issues. 6. The log.

### Undoing an aborted run

The run records every cleanup list, with the context it needs, in `cleanup.json` of the run directory as it goes,
and what it needs to log in again in `meta.json`. If the run died (a crash, a kill), `runner.py cleanup <run-dir>`
logs in again, replays the lists not yet `done` newest first, and writes `summary-cleanup.md`. It never touches
`context.json`. Replaying twice does nothing the second time. Known limit: a document issued but not yet posted when
the run died is not cancelled by a cleanup that needs `posted_doc_id`; cancel it by hand.

### Issues (`--file-issues`)

After the run the runner opens **one GitHub issue per failed process** with `gh issue create` (the label
`uat-regression`):

* title: `UAT BP-01 s3: expected 200 got 409` (process, first failing step, what was expected and what came);
* body: the table of that process's steps, the failing request and response (secret-looking keys masked, tokens and
  JWTs removed, the first 2000 characters of the answer), the build sha, the run id and the path of `run.jsonl`;
* **once per run**: `issues.json` in the run directory remembers what was filed, so asking again files nothing new;
* a failed preflight (wrong build, unstable build, no token) and "build moved" are not product regressions: no issue.

`--repo OWNER/NAME` (env `UAT_ISSUE_REPO`) names the repository; `--gh` (env `UAT_GH`) the gh command. A failing `gh`
is recorded as `NOT FILED` in `issues.json` and does not change the exit code.

### Dry run of changed files (`dry-run --changed`)

For the `bp_dryrun` capability and for the business analyst before a merge. It finds the `test/uat/processes/*.json`
and `test/uat/chains/*.json` that differ from `origin/main` (committed, edited or new), runs `check_processes.py
--strict` on them (a failure stops everything, nothing is sent to QA), then runs each file on QA with **its own
`dry_run` block** `{tenant, actors, inputs}` (a chain: the chain's block). Every file cleans up after itself. Exit 0
only when all pass, 1 otherwise; no changed file is exit 0 ("nothing to run"). `--files F ...` runs the named files
instead of the changed ones; `--base-url` forces one address for all.

---

## 4. For the business analyst: before you hand a process over

1. `bp_entry` names the map entry; `dry_run` has the tenant, a user for every actor and a value for **every** input
   (use ids that exist on the QA tenant of the dry run).
2. `python3 scripts/uat/check_processes.py --strict test/uat/processes/<file>` says `0 problem(s)`.
3. `python3 scripts/uat/runner.py dry-run --files test/uat/processes/<file>` passes on QA. The engine runs the same
   command for the changed files (`dry-run --changed`) before the work is accepted.

---

## 5. The static check (`check_processes.py`)

```
python3 scripts/uat/check_processes.py [--strict] [--root DIR] [FILE ...]     # no files: all of test/uat
```

It reports, one line per problem (`file: step s3: ...`): invalid JSON; a missing id, steps or `expect` (`expect_refused`
counts); an actor that is not a role of `test/fixtures/uat/actors.yaml` (read as text: the entry `actor-<slug>-<role>`);
a `${name}` that is not an input, a default, a built-in, saved by an **earlier** step, or (in a chain) given by the
chain or an earlier process; an `api` path that does not start with `/api/`, or that matches no route (a loose check
against `lib/letflow/modules/stock/router.ex` and `lib/letflow/routers/*.ex`: the method and the end of the path,
`:id` matches anything; a route made only of `:id` counts only behind its router's mount name; `http_as` steps are
checked against `shared_stock_access.ex`); a chain whose process file is missing; with `--strict` a missing
`bp_entry` or `dry_run`, and a `dry_run` without a user for an actor or a value for an input. Exit 0 or 1.

## 6. Reading the run directory

* `run.jsonl`: one JSON line per step: `phase` (`preflight`, `inputs`, `step`, `cleanup`, `outputs`), `process`,
  `step`, `actor`, `method`, `path`, `request` (the body; secret-looking keys are `***`), `status`, `asserted`
  (each check: `what`, `expected`, `actual`, `ok`), `verdict` (`pass`; `fail` = the answer was not as expected;
  `error` = the step could not run or the answer could not be read; `skipped`), `error`, `ms` (the step's duration).
  A failing line also has `response_excerpt` (first 2000 characters, masked). A `wait_task` line has `task_id` and
  `polls`; a `repeat` or `parallel` line has `calls` (status of each call); a failing line has the failing call's
  answer. A step that handles a secret never shows the answer's values (`***`, `<withheld...>`).
* `summary.md`: the verdict, the sha at start and end, the duration, the **first failing step** (a quote at the top
  and `**>>**` on its row), a table per process (pass/FAIL of steps and cleanup, total ms, first failing step), the
  table of every line, the outputs and **the context at the end**, the issues filed.
* `context.json`: every value of the run (inputs, saved values, outputs). It holds no token and no shared access value.
* `cleanup.json`, `meta.json`: what `runner.py cleanup` replays (section 3). `issues.json`: the issues filed.

Nothing secret is written: tokens and shared access values are kept in memory, never put in the log, and every one
the runner has seen, plus anything shaped like a JWT, is replaced by `***` in every file before it is written.

## 7. How to run it on a release candidate

1. Wait until the QA build is the candidate: `project/scripts/qa_stable.sh --wait` prints `sha=<sha> stable`.
2. `python3 scripts/uat/runner.py chain test/uat/chains/<chain>.json --build-sha <sha> --file-issues --repo <owner/name>
   --run-dir <dir>` with `TEAM_ROOT` and the UAT environment set. The preflight stops the run if the build differs
   or moves.
3. Read `<dir>/summary.md`: the verdict and the first failing step are at the top. The failing request and response
   are in `run.jsonl` (and in the issue). Exit 0 = the candidate passed these processes.
4. If the run was killed: `runner.py cleanup <dir>` before anything else touches the tenant.

## 8. The process file, reference

`{ "id", "bp_entry", "title", "description", "tenant": "${tenant}", "inputs": [names], "defaults": {name: value},
"dry_run": {tenant, actors, inputs, base_url?, old_base_url?}, "steps": [step], "outputs": {name: expression},
"cleanup": [step] }`. A step: `id`, `actor` (not for `http_as`), `do`, one of `expect` / `expect_refused`, optional
`expect_repeat`, `save`, `requires`, `http_as`. `do` is exactly one of: `{api, path, body?, headers?}`,
`{wait_task: {for_document, step, within_s?, interval_s?}, claim?, complete?: {body}}`, `{assert_only: {path, headers?}}`,
`{repeat: {api, path, body?}, times?: 2}`, `{parallel: [call, call, ...]}` (2 to 6 calls; a call may name its own
`actor`). `save` values: a path (`"$.id"`), `{pick, default?, if_unset?, optional?}`, `{api, path, pick}`, `{secret: path}`
(memory only), or a literal / `${...}` expression. `${a + 5}`, `${(a - b) * 2}`: numbers with `+ - * /` and
parentheses in decimal arithmetic. A string that is only `${name}` keeps the type of the value. `outputs` are
evaluated right after the steps, so they may use names saved by steps (not by cleanup steps).

## 9. Tests

One file per command:

```
python3 -B -m unittest -v scripts/uat/tests/test_runner.py          # M0: one process, assertions, secrets, CLI
python3 -B -m unittest -v scripts/uat/tests/test_chain.py           # chains, cleanup replay, preflight, step kinds, log
python3 -B -m unittest -v scripts/uat/tests/test_issues.py          # --file-issues with a fake gh
python3 -B -m unittest -v scripts/uat/tests/test_check_processes.py # the static check
python3 -B -m unittest -v scripts/uat/tests/test_dryrun.py          # dry-run --changed in a temp git repository
python3 -B -m unittest -v scripts/uat/tests/test_fixtures.py        # fixtures: order, idempotent reuse, cleanup, static check
```

`tests/fakes.py` is the shared fake: an HTTP server (a thread) with the stock routes BP-01 needs, the shared access
routes and the old address, a fake token command, a fake `gh` and a fake `qa_stable.sh` written by the tests: no
network, no model.
