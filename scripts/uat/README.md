# UAT process runner (D-167, spike M0)

A deterministic runner for ONE business process at a time: no model, Python 3.11, standard library only. It
reads a process file (`test/uat/processes/BP-xx-*.json`), runs its steps over HTTP against a tenant, checks every
answer, cleans up and writes a log. Design note: `project/uat-process-runner.md` in the team repository.

M0 proves the idea for `BP-01 Receive goods`. It is not an engine step and writes no task state.

## Run it

The caller's environment must hold what `uat_creds.sh` needs (the `.env.uat` of the team: `UAT_QA_ACTOR_*`
variables) and `TEAM_ROOT` (the team repository; the runner calls
`bash "$TEAM_ROOT/project/scripts/uat_creds.sh" token <user>` once per actor, the password never goes into argv and
the token stays in memory).

```
python3 scripts/uat/runner.py run test/uat/processes/BP-01-receive-goods.json \
  --tenant qoimeks-qa2 \
  --base-url https://qoimeks-qa2.letflow.qa.bizdala.com \
  --actors admin=<tenant admin user>,storekeeper=<storekeeper user> \
  --input item=<item id> place=<location id> org_unit=<org unit id> responsible=<responsible id> \
  --run-dir /tmp/uat-bp01
```

Inputs are the ids the stock API takes (not codes). Pick an item and a place that already have stock, so the
balance read at the start has a row. `uom` (the item's base unit id) is read from that balance row; give
`--input uom=<id>` when the start balance is empty. `quantity` defaults to 5. More options: `--input-file F` (a
JSON object, for example the `context.json` of an earlier run: the outputs of one process are the inputs of the
next; `--input` wins), `--health-url` (default `<base-url>/health`), `--poll-interval` (seconds between task polls).

Exit code 0: every step, every cleanup step and the build check passed. 1: a verdict failed. 2: bad command line
or process file, nothing was run.

## What a run does

1. Preflight: `GET /health`, records the build `sha`. No sha, no run.
2. The steps in order. The first failing step stops the steps (the rest are logged `skipped`).
3. The cleanup steps ALWAYS run (also after a failure or an exception). A cleanup step with `requires: [names]`
   is skipped while one of the names is not in the context yet, so nothing is reversed that was never posted.
   A failing cleanup step does not stop the next one, and it fails the run.
4. `GET /health` again: a different sha is "build moved" and fails the run.
5. `outputs` are evaluated into the context, `context.json` and `summary.md` are written.

BP-01: read the balance, create a receipt (storekeeper), issue it, the admin finds the Post task of the document
(inbox -> instance variable `document_id`), claims and completes it (body `{}`), the balance is `before + quantity`,
the document is `posted`. Cleanup: reverse it (`reason_code` `other` plus text), complete the Reverse task, the
balance equals the start again.

Known limit of the spike: when a run dies between `issue` and the completion of the Post task, the issued document
and its pending Post task stay; the cleanup does not touch them (`posted_doc_id` is not set). The operator cancels
them by hand.

## The process file

JSON, the same fields as the YAML example of the design note:

```
{ "id": "BP-01", "title": "...", "description": "...", "tenant": "${tenant}",
  "inputs": ["item", ...],            // required names (from --input / --input-file / defaults)
  "defaults": {"quantity": "5"},      // optional inputs with a value
  "steps": [ {step}, ... ],
  "outputs": {"receipt_doc_id": "${doc_id}"},
  "cleanup": [ {step}, ... ] }
```

A step: `id`, `actor` (a name from `--actors`), `do`, `expect`, `save`, optional `requires`.

* `do: {"api": "POST", "path": "/api/v1/...", "body": {...}, "headers": {...}}`: one HTTP call as the actor. The
  `Authorization` header is always the actor's token.
* `do: {"wait_task": {"for_document": "${doc_id}", "step": "post", "within_s": 30, "interval_s": 2}, "claim": true,
  "complete": {"body": {}}}`: poll `GET /api/v1/tasks/inbox` as the actor for a PENDING task with node id `step`
  whose instance has `variables.document_id` equal to the document, then claim and complete it. The answer of the
  complete call is what `expect` checks. `step` is `post` for receipt, issue, transfer; `reverse` for a reversal.
* `expect: {"status": 200 | [200, 201], "json": {...}}`. Without `status` any 2xx passes. `json` keys are paths
  (`$.rows[0].quantity`; a key without `$` is `$.key`). A value is compared with `equals`: numbers and plain decimal
  strings compare as numbers (`"10.000000000"` equals `"10"`), everything else exactly. Operators in an object:
  `{"equals": x}`, `{"contains": x}`, `{"regex": "..."}`, `{"absent": true}`, `{"exists": true}` and `"default": x`
  (the value used when the path is missing, for example an empty balance).
* `save: {name: ...}`, applied only when the step passed: `"$.id"` (a path in the answer), `{"pick": "$.rows[0].quantity",
  "default": "0", "if_unset": true}` (`if_unset`: keep an input of that name), `{"api": "GET", "path": "...",
  "pick": "$.x"}` (an extra read as the same actor), or any other string/value (substituted and stored).
* `${name}` is replaced from the context (inputs, defaults, saved values, `tenant`, `run_id`, `now_utc`). A string that
  is only `${name}` keeps the variable's type. `${a + 5}`, `${(a - b) * 2}`: numbers with `+ - * /` and parentheses,
  Decimal arithmetic, the result is a plain decimal string. An undefined name fails the step.

## Reading the run directory

* `run.jsonl`: one JSON line per step: `phase` (`preflight`, `step`, `cleanup`, `outputs`), `step`, `actor`, `method`,
  `path`, `request` (the body; keys that look like secrets are `***`), `status`, `asserted` (each check: `what`,
  `expected`, `actual`, `ok`), `verdict` (`pass`, `fail` = an answer was not as expected, `error` = the step could not
  run or the answer could not be read, `skipped`), `error`, `ms`. A failing line also carries `response_excerpt`
  (first 2000 characters). A `wait_task` line has `task_id` and `polls`.
* `summary.md`: verdict, the sha at start and end, a table of all lines, the outputs and balances.
* `context.json`: every value of the run (inputs, saved values, outputs). It holds no token.

Nothing secret is written: tokens are kept in memory, never put in the log, and every token the runner has seen plus
anything shaped like a JWT is replaced by `***` in every file before it is written.

## Add a process

Copy `BP-01-receive-goods.json`, change the steps. Check the request body and the answer in
`lib/letflow/modules/stock/router.ex` and the router tests first; a UAT process names only calls that exist. Put the
reverse-the-effect steps in `cleanup` with `requires` on a name that is saved only when the effect really exists.

## Tests

```
python3 -B -m unittest -v scripts/uat/tests/test_runner.py
```

A fake HTTP server (a thread) and a fake token command stand in for QA: no network, no model.
