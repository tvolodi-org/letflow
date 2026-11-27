# UAT process runner (D-167, M1)

A runner that plays a **business process** against a running Letflow tenant step by step, checks every answer
and writes a log. No model is involved: the same file gives the same result every time, so it can be repeated
on every release candidate. Python 3.11, standard library only. It is not an engine step and writes no task
state. Design note: `project/uat-process-runner.md` in the team repository.

What is here:

| file | what it is |
|---|---|
| `runner.py` | the runner: `run` (one process), `chain` (several processes with isolated working contexts and explicit `pass` lists), `cleanup` (undo an aborted run), `dry-run` (the changed process files) |
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
| `dry_run` | what the **dry run on QA** uses: the tenant, a user name for each actor, and a value for each input. Needed on every file the BA writes, see section 4. An actor may be an object instead of a user name, see "An actor of another tenant" below |
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
* `poll` (optional, a GET step with an `expect`): `"poll": {"within_s": 60, "interval_s": 2}` repeats the read until
  the `expect` holds or `within_s` ran out; the last answer is judged and the log row says `polls`. It is for a read
  right after the start of an instance (the engine runs its steps afterwards), for example "the instance is
  COMPLETED". Both times may be a `${name}` of the context. A POST step or a step without an `expect` is refused.
* `requires` (optional): `"requires": ["doc_id"]` runs the step only if that name was saved. Use it on every cleanup
  step, so nothing is reversed that was never created. List every value the cleanup assertion needs (for example both
  `posted_doc_id` and `balance_to_before`): when any one is missing the step is **skipped**, not failed, and the log's
  `requires ...` note names the missing values.

### Special steps

| you want to say | write |
|---|---|
| the person takes the task of a document in My Tasks and completes it | `"do": {"wait_task": {"for_document": "${doc_id}", "step": "post", "within_s": 30}, "claim": true, "complete": {"body": {}}}`. `step` is `post` for a receipt, issue or transfer and `reverse` for a reversal |
| the system must send a mail and the process waits for it | `"do": {"wait_mail": {"recipient": "${admin_email}", "subject": "Tenant registered", "within_s": 60, "interval_s": 2}}` and `"expect": {"status": 200}`. See "Waiting for a mail" below |
| a user of a realm made DURING the run signs in (the new tenant admin of a sign-up) | a step `"do": {"login": {"realm": "${tenant_realm}", "username": "...", "password": "${signup_password}"}}` (password grant of the identity provider, `BPM_IDP_BASE_URL`, default QA; the realm is the one the provisioner issued (save it from the registry's `idp_realm_id`), the password must be a `${name}` reference, `BPM_IDP_BASE_URL` must be https; the token stays a secret, never in the log) with actor `anonymous`; later steps name it with `"bearer": "session"` (the API of the run, that token; `"bearer_base": "<saved name>"` sends the call to a URL an earlier step saved, such as the new tenant's `tenant_url`) |
| the provisioner route 3 (`POST /admin/v1/tenants` answers 202, then poll `GET /admin/v1/tenants/:id`) (T-3108) | a step flagged `"platform_route": true` with `"bearer_env": "UAT_QA_PROVISIONER_<NAME>"`: the NAME of an environment variable (from `.env.uat`) that holds the provisioner credential (`LETFLOW_PROVISIONER_CREDENTIAL_SHA256` of the deployment is its hash, `lib/letflow/plugs/provisioner_auth.ex`); only the name is in the file, the value is a registered secret and never logged; a missing variable fails the step naming the variable. `check_processes.py` accepts a path under `/admin/v1/` only on such a step. `bearer` also stays on `upload`, `repeat` and `page_through`. A JSON body can be read from a file with `"body_file": "<relative name under test/uat>"` (not with `body`; no `..`, no symlink out of test/uat, 2 MiB at most) |
| a file goes up (the Excel load of Client 1) | `"do": {"upload": {"api": "POST", "path": "/api/v1/...?dry_run=true", "field": "file", "file": "generated/client1/03-items-01.xlsx", "content_type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "fields": {"mode": "check"}}}` with `expect` and `save` as any step. See "Uploading a file" below |
| only look and check (no change) | `"do": {"assert_only": {"path": "/api/v1/..."}}` and an `expect`. A read, never a body |
| the same request twice (a retry: the system must not do it twice) | `"do": {"repeat": {"api": "POST", "path": "...", "body": {...}}}`, `"expect"` for the first answer and `"expect_repeat"` for the second (default: the same as the first) |
| two people press at the same moment (concurrency) | `"do": {"parallel": [{...call 1...}, {...call 2...}]}` and `"expect": {"unordered": [{"status": 201}, {"status": 409}]}`: one wins, one is refused, in any order. A list `"expect": [e1, e2]` fixes the order |
| the system must refuse | `"expect_refused": {"status": 422, "code": "output_refused"}` instead of `expect`: any `4xx` (or the given status) whose answer names the code. `"expect_refused": "output_refused"` is the short form |
| the old phone address (shared access) | see below |

**Waiting for a mail (`wait_mail`).** The step waits for a mail in the **mail trap** (Mailpit, the same trap
`scripts/mail_trap.sh` reads) and matches it itself: the trap is asked by **recipient** only
(`GET /api/v1/search?query=to:<recipient>`), and the **subject** of the message must be exactly the one the
process names. A mail to somebody else, or with another subject, is not the mail: the step keeps waiting until
`within_s` is over and then fails with `timeout: no mail to ... with the subject ...`.

```json
{"id": "s1", "actor": "platform-admin",
 "do": {"wait_mail": {"recipient": "${admin_email}", "subject": "Tenant registered", "within_s": 60, "interval_s": 2}},
 "expect": {"status": 200},
 "save": {"mail_id": "$.message_id"}}
```

| key | meaning |
|---|---|
| `recipient` | the address the mail goes to (the trap accepts every address; the test uses `@uat.letflow.internal`) |
| `subject` | the subject the mail must have, character for character. `"subject_contains": true` matches a subject that *contains* it (a mail with a prefix) |
| `within_s`, `interval_s` | how long to wait (default 60 s) and how often to look (default 2 s; `--poll-interval` wins). A number, a numeric text or a `${name}` of the context (the value is read after the substitution) |
| `trap_url` | the trap to read, when it is not the one of the run. A plain http(s) address: a credential in it, a query or a fragment is refused (the trap needs none of them, and urllib cannot even connect through a credential) |

The trap of the run is `--mail-trap-url`, else the environment variable `MAIL_TRAP_URL`, else
`http://127.0.0.1:8025` (the local trap; off the host open the tunnel of `docs/testing/uat-mail-trap.md` first).

**The body of a mail never reaches the log.** The step logs the recipient, the subject and the id of the message
that matched, and nothing else: the body of a mail carries links and tokens, so it is never read into a record.

**The recipient and the trap address are masked too.** A mailbox is a personal datum, and the address of the
trap may carry a credential, so neither is written in clear text:

* the recipient is masked (its shape stays visible, its value does not), in the record, in the error of a
  timeout and in the answer of the step (`"to"` holds the masked form, `"subject"` and `"message_id"` the real
  ones);
* the address of the trap is written without its userinfo, its query and its fragment: the search of a trap
  carries the recipient in its query, so an error of the transport names the origin of the trap and the path,
  never the address as it was configured.

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

### Uploading a file (T-2864)

An `upload` step sends one file as `multipart/form-data`: `field` (the form field name), `file` (a relative name under
`test/uat/fixtures`; no absolute path, no `..`), `content_type`, optional `fields` (one-line text parts), `api` POST
(default) or PUT. The run log records the field, the file name, the byte count and the file's **SHA-256**, never the
content. Refusals before anything is sent carry a class at the start of the error: `upload_fixture_missing`,
`upload_fixture_path_invalid`, `upload_fixture_too_big` (over 25 MiB, the server's cap). A refusal by the server (wrong
type, too big) is an expected negative: `"expect": {"status": 415}` as for any step.

**A raw upload (T-2857).** The stock-workbook `check` and `apply` routes and the records import routes read the xlsx as the
WHOLE request body of its media type (`Letflow.Plugs.XlsxBodyParser`), and answer `xlsx_unreadable` to a multipart form.
`"raw": true` (no `field`, no `fields`) sends the file bytes as the body with `content_type` as the media type; the log
keeps the same SHA-256 and byte count with `"raw": true`.

**Client 1 tools (T-2857).** `save_response: true` on an `upload` keeps the response body as `<run dir>/responses/<file stem>.json`;
`page_through` with `save_as: <name>` keeps each page as `<run dir>/pages/<name>/page-NNN.json`; `client1_workbook.build` keeps the
generated extract under `generated-fixtures/client1/csv/`. `do: {client1_tool: {tool}}` runs one of a FIXED set
(`headers` with `org_unit_id` and `responsible_id`, `balances_compare`, `masters_compare`) as `python3 -I scripts/pilot/<tool>.py`;
the arguments come only from the run dir and the two ids (no free text). Exit 1 or 2 fails the step; the log keeps the `RESULT`/`DIFF`
lines only. The counts compare (`qoimeks_compare.sh`) needs a database snapshot and is not a tool of the runner.

**The Client 1 workbook set** is synthetic (D-050: no real data) and is generated, not committed: a file named
`generated/client1/<name>` is built on first use under `<run dir>/generated-fixtures/client1` by `client1_workbook.py`,
which runs `scripts/pilot/qoimeks_gen.py` (seed 42: 134 places, 666 items, 600 balances) and
`scripts/pilot/qoimeks_convert.py` (the same converter a real load uses). The set is byte-identical for one seed
(`expected_counts.txt` in it lists 666 items, 142 location nodes, 603 opening lines). Build it by hand with
`python3 -I scripts/uat/client1_workbook.py --out DIR`. The check-only run, the load and the reconciliation read-backs
are ordinary steps around the upload; cleanup of what a load wrote is the process file's `cleanup` (a throwaway tenant
needs none).

### An actor of another tenant (the platform administrator)

An actor is normally a user name: `"admin": "qoimeks-qa2-admin"`. Such an actor lives on the tenant of the run.
An actor may instead be an **object** that says where it lives:

```json
"actors": {
  "admin": "qoimeks-qa2-admin",
  "platform-admin": {"user": "admin-user", "tenant": "bpm-default", "base_url": "https://qa.bizdala.com"}
}
```

| key | meaning |
|---|---|
| `user` | the Keycloak user name: `uat_creds.sh token <user>` mints its token, for the realm of that user (`admin-user` is the realm `bpm-default`, the platform tenant) |
| `tenant` | the tenant the actor lives on: its token, its retired-tenant guard and its residue check belong to that tenant |
| `base_url` | the address its requests go to; without it the address of the run is used |

Such an actor reaches **its own** tenant and address; the tenant of the process (`${tenant}`) does not change. The
preflight checks every tenant of the run (health, reachable, a token for every actor of that tenant), the
retired-tenant guard refuses an actor that names a retired tenant (exit 2, before any request), and the residue
check covers every tenant an actor names: a tenant with a plain actor holds business data (documents, open tasks),
a tenant with an actor object may be the platform tenant, which holds throwaway **platform tenants** - see the
residue section at the end of this file.

The same object may be given on the command line as one JSON map:
`--actors '{"admin": "adm", "platform-admin": {"user": "admin-user", "tenant": "bpm-default"}}'`.

### The anonymous caller (public routes)

A step with `"actor": "anonymous"` sends no `Authorization` header and needs no user, no roster entry and no
`dry_run.actors` row; it goes to the address of the run. It is for the public routes (`/api/signup`, T-2749).

### Do and do not

* One file = one business process, from the first action to the check of the result. Name an input for every id the
  process cannot know.
* Every step has an `expect`. A step without one is reported.
* Put every undo in `cleanup`, with `requires`. A process that cannot undo something says so in its `description`.
* Every document the process creates (a POST to a document collection: `/documents`, `/quick-counts`, `/counts`; derived
  from the routers, a collection whose router has `:id/reverse` or `:id/cancel`) needs a `cleanup` step that reverses,
  cancels or deletes that collection, or a top-level `"residue_allow": [{"type": "stock/documents[:kind]", "reason": "...",
  "owner": "..."}]` entry. `check_processes.py --strict` fails the file, the step and the type otherwise (T-2885).
* Never put a password, a token or a secret into a file. The runner gets tokens from the environment.
* Never leave a literal `REPLACE-WITH-*` marker in a process, chain or fixture. The static check rejects it and the
  loader exits 2 before any request; provide the value as an input or by a fixture instead.
* Run the static check before you hand the file over: `python3 scripts/uat/check_processes.py --strict <file>`.

---

## 2. Chains (several processes, explicit hand-off)

A **chain file** lists processes in order. Each process gets a **fresh working context** containing the chain inputs,
built-ins, fixture values and only the earlier outputs explicitly handed on by `pass`. Working names such as `doc_id`,
`posted_doc_id`, `balance_before` and `quantity` are private to the process that saved them: a later process (and its
cleanup) cannot accidentally reuse them. The final `context.json` still reports all declared outputs.

`pass` maps the id of the producing process to the list of its `outputs` that later processes may read. For example,
a receipt (`BP-01`) hands only its document id to the reversal (`BP-05`):

```json
{
  "id": "rc-sss",
  "title": "Release candidate run for SSS",
  "processes": ["BP-01", "BP-02", "BP-05"],
  "pass": {"BP-01": ["receipt_doc_id"]},
  "fixtures": ["second_place"],
  "tenant": "sss-rehearsal2",
  "actors": {"admin": "sss-rehearsal2-admin", "storekeeper": "sss-rehearsal2-storekeeper"},
  "inputs": {"item": "<id>", "place": "<id>", "org_unit": "<id>", "responsible": "<id>"},
  "dry_run": {"tenant": "sss-rehearsal2", "actors": {"admin": "..."}, "inputs": {"item": "..."}}
}
```

* `processes` are looked up in `test/uat/processes/` by the id (`BP-01` finds `BP-01-receive-goods.json`), by the
  file name, or by a path relative to the chain file.
* `tenant`, `actors`, `inputs`, `base_url`, `old_base_url` in the chain file are defaults; the command line wins.
* An entry of `processes` may be an object, `{"process": "BP-08", "dry_run": true}` (tenant, actors, `base_url`,
  `old_base_url` and inputs from the process's own `dry_run` block) or `{"process": ..., "tenant": ..., "actors": ...,
  "old_base_url": ...}`. That process runs on its own tenant with only its own inputs (no ids of the chain's tenant;
  only the chain's `pass` lists hand outputs on). The preflight (reachable, tokens) runs per distinct tenant, the
  retired-tenant guard applies to every entry, and `summary.md` lists the tenant of each process.
* A process may read a name only if the chain or a fixture gives it, it is a default, or an earlier process declares
  it as an `output` **and** the chain's `pass` list names it. An empty or absent `pass` hands on nothing. A `pass`
  entry that names an unknown process or a non-output is a usage error; `check_processes.py` and the runner check
  this before the first request.
* **A failing process stops the chain** (the rest are logged *skipped*), unless `--keep-going`.
* **Cleanup of a chain runs at the END, process by process in reverse order**, each with the frozen working context
  of that process alone. So a failed process that never saved `posted_doc_id` skips its reversal even when an earlier
  process did save a same-named value. Give each cleanup step a `requires` list covering the ids and baseline values
  it reads. A document deliberately reversed by a later process needs a tolerant `expect`
  (`{"status": [200, 409, 422]}`), or the undo belongs only to that later process. Cleanup of the processes that
  already ran always happens, also after a failure.
* The chain file may say **`"cleanup": "per_process"`**: the cleanup of a process then runs **right after that
  process** (pass or fail), with the frozen working context of that process alone, and the working values the process
  created leave the chain context afterwards (the outputs the chain hands on in `pass` stay). A failing cleanup fails
  that process and the run, but the next processes still run. Use it when a process leaves something on the tenant that
  the next one must not meet: the tenant's one shared access value, for example (a file that expects that no value
  exists needs the file before it cleaned up). The cleanups of the fixtures still run at the end of the chain.
  `"cleanup": "end"` (or no key at all) is the default and changes nothing.

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

**Step markers** (optional keys of a step):

- `blocked_by`: a text naming what the step waits for (a task or piece not built yet). The runner does not run
  the step: it prints `not run: blocked by <text>`, records the verdict `blocked`, counts it in the summary
  (`steps not run`, and `PASS (N steps NOT RUN, blocked)`), and a blocked step never passes and never fails.
  Removing the marker is an acceptance line of the task that builds the piece.
- `refusal_probe`: `true` only on an `expect_refused` step that probes a refusal on a create route
  (POST /api/v1/tenants). It exempts the step from the tenant-create gate, which otherwise skips a tenant create
  unless the run allows it; the refusal itself is then sent and checked.

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

Shipped: `asset_card` (provides `asset_card_id`; a minimal fixed-asset card without photo), `asset_opening_doc`
(needs `asset_card`; inputs `org_unit`, `location`, `responsible`; provides `asset_doc_id`; a draft opening document
with one line, never issued) and `second_place` (inputs `place`, `org_unit`; provides `place_from`, `place_to`; an
active stock location linked to the org unit). `second_place` leaves a found location and link untouched, retires a
link and location it created, and ignores its retired fixtures on later runs. Run fixtures on QA with real tokens like
any process.

### QA tenant setup through the runner (module_installed, tenant_onboarded)

Owner order D-174: module installs, tenant setup and QA tenant data are product processes, run through the
runner, not by infra. Two parameterised fixtures take over the **local** modes of infra's `qa-tenant-onboard.py`
(they talk to the product over the public API as the tenant admin actor; no ssh, no sudo). They are declared in
the `fixtures` list of a process or chain as objects, next to the file-name fixtures:

```json
"fixtures": [
  {"fixture": "module_installed", "module": ["org", "assets"]},
  {"fixture": "tenant_onboarded", "legal_entity": "QOIMEKS", "modules": ["assets"],
   "actors": {"storekeeper": {"roles": ["STOREKEEPER"], "permissions": ["StockQuickCount"]}}}
]
```

| fixture | replaces | what it does |
|---|---|---|
| `module_installed` (`module`: a name or a list, in order; `tenant`: optional guard) | `modules <slug> [--module a,b]` | as the `admin` actor: `GET /api/v1/me/modules`; if the module is absent `POST /api/v1/tenant/modules` (`module_id`, `rationale`); 409 = already installed = OK; reads `/me/modules` again and fails when the module is still absent. Names are checked (`^[a-z][a-z0-9_]{0,63}$`, no empty or duplicate name) before any request. An unknown name or an unmet dependency fails the step with the product's own answer (status and code), never retried. The installed version is in the run log (`module_installed.version`, as numbers: the log masks a dotted number as a phone number) and in the context as `module_<name>_version`. **There is no cleanup: a module install is not removed by a test.** |
| `tenant_onboarded` (`legal_entity`, `app_name`, `modules`, `actors`, `tenant`: all optional) | `config <slug>` and `verify <slug>` (the read-only parts) | a read-only assertion, never creates a tenant, a user or a record: a legal entity exists (`POST /api/v1/entities/query`, `org_legal_entity`, by code when given), `app_name` is set (`GET /api/v1/tenant/config-bundle`, `tenant_settings.app_name`; equal to `app_name` when given), the listed modules are installed, and each listed actor's `GET /api/v1/me/access` holds the roles and permissions. It fails naming **every** missing item. |

`tenant` (optional) is a guard: the fixture is refused when the admin actor is not on that tenant (per-actor tenants
as in section 1, the retired-tenant guard still applies to the run). Both fixtures are idempotent: a second run
changes nothing.

**What stays with infra** (platform work, not the runner's): the identity realm, the users and their passwords, the
onboarding registry row, DNS, nginx hosts and certificates. **What is not ported**: the `config` writes (legal
entity create, `PATCH /api/v1/tenant/settings`), which need owner input (the BIN, `ONBOARD_LEGAL_BIN`); the
four-eyes switch and ledger settings, which only an OIDC browser session may change.

---

## 3. Running

The environment must hold what `project/scripts/uat_creds.sh` needs (the `.env.uat` of the team) and `TEAM_ROOT`
(the team repository). For every actor the runner calls `bash "$TEAM_ROOT/project/scripts/uat_creds.sh" token <user>`
at preflight and again at the start of each process (including each process of a dry-run batch), so a long chain does
not reuse an expired token. A 401 causes one re-login and one retry of that request, including cleanup and residue
checks; the step's log row has `retried: true`, and a second 401 fails it. The password never goes into the command
line, tokens stay in memory, and mint/retry rows never contain token text.

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
`--base-url-template` / env `UAT_BASE_URL_TEMPLATE`), `--actors a=user,b=user` (or one JSON map with the actor
objects, see section 1), `--input NAME=VALUE ...`,
`--input-file F` (JSON, for example the `context.json` of an earlier run; `--input` wins), `--run-dir`,
`--health-url`, `--poll-interval`, `--build-sha`, `--no-stable-check`, `--old-base-url`, `--file-issues`,
`--repo`, `--gh`, `--allow-create`. Inputs are the ids the API takes (not codes).

**`--allow-create` and the platform tenants.** A step that creates a tenant (`POST /api/v1/tenants`) is **skipped
with a visible reason** ("creating a tenant needs --allow-create") unless the run was started with `--allow-create`:
a run never leaves a new company behind by accident. With the flag, a throwaway tenant of the day
(`uat-tmp-<yyyymmdd>-<n>`) is created only once a day: when a tenant of the same date already exists, the step is
skipped with "already created today" (not failed).

Run output never defaults to a path inside the product checkout. Without `--run-dir` (or `--run-dir-root` for a dry
run), the runner uses `$UAT_RUN_DIR_ROOT` when set, then `$TEAM_TASKDIR/uat-runs` when set, and otherwise
`<system temp directory>/letflow-uat-runs`. Each run gets its own run id below that root; a dry run uses a
`dry-run-<timestamp>` id and its final line names the directory. The repository's top-level `/uat-runs/` is ignored:
request and response excerpts are run output, not source, and must not be committed.

Exit code **0**: every step, every cleanup step and the build check passed. **1**: a verdict failed (or the preflight
refused to start). **2**: bad command line or process file, nothing was run (`dry-run` never uses 2 for a failure:
the `bp_dryrun` capability reads exit 2 as "this runner has no dry-run command yet").

### Retired tenants and blocked files (T-2538)

`test/uat/retired-tenants.json` lists the **retired QA tenants: `qoimeks-qa` (retired, never touch it) and
`qoimeks-client1-qa` (client1, read-only: no runner run at all)**. `runner.py run|chain|cleanup`, `dry-run` and
`check_processes.py` refuse a process, chain or fixture file, a `--tenant`, a `--actors` user (the slug or
`<slug>-...`) or a base url that names one: **exit 2 before any request**, the message names the file and the tenant.
An actor object is checked as well: the tenant it lives on, the user it names and its own base url.
One retired file refuses the whole `dry-run` batch (exit 2; this is the one case where `dry-run` exits 2, the
`bp_dryrun` capability must treat it as a refusal, not as a missing command). Before a batch runs, one line per
distinct tenant (`batch tenant <slug>: actors ...; N file(s)`) is printed, so nobody has to remember the list.

A file whose `dry_run` block has `"blocked_by": "<reason>"` is **skipped with that reason** by `dry-run` and by a chain,
and refused (exit 2) by `run`. SEC-ASSETS-01..04 carry `blocked_by: assets-module-on-active-tenant` until the assets
module is installed on `qoimeks-qa2` (infra); then their `dry_run` tenant is `qoimeks-qa2` and the block goes.

### Preflight: the run starts only when all of this is true

1. `GET /health` gives a build `sha`.
2. With `--build-sha`: the sha is that build (a prefix is enough). Otherwise the run is for another build: it does
   not start.
3. When `TEAM_ROOT` is set (and `project/scripts/qa_stable.sh` exists): `qa_stable.sh --wait` says the sha has been
   stable for a few minutes, and it is the same sha. `--no-stable-check` skips it.
4. The tenant answers at its base url.
5. **Every actor gets a token before the first step.** A missing token stops the run with no change made.

Steps 1 to 5 run **per tenant of the run**: the tenant of the process, the tenants of the chain's entries and the
tenants the actors name. The log names them: `tenant` and `token:<role>` for the tenant of the process,
`tenant:<slug>`, `health:<slug>` and `token:<slug>:<role>` for every other one.

The sha is read again at the end: **a different sha ("build moved") fails the run**, whatever the steps said.

### What a run does

1. Preflight (above). 2. For each process: its steps in order; the first failing step stops its steps (the rest are
logged `skipped`); its `outputs` are evaluated. 3. All recorded cleanups, newest process first. A cleanup step with
`requires: [names]` is skipped while one of the names is not in the context yet. A failing cleanup step does not
stop the next one, and it fails the run. 4. `GET /health` again. 5. With `--file-issues`: the issues. 6. The log.
With `"cleanup": "per_process"` in the chain file, step 3 happens after every process instead of at the end of the
chain (the cleanups of the fixtures still at the end).

### Undoing an aborted run

The run records every cleanup list, with the context it needs, in `cleanup.json` of the run directory as it goes,
and what it needs to log in again in `meta.json`. If the run died (a crash, a kill), `runner.py cleanup <run-dir>`
logs in again, replays the lists not yet `done` newest first, and writes `summary-cleanup.md`. It never touches
`context.json`. Replaying twice does nothing the second time. The replay makes the same safety checks as the
run itself (the preflight of every tenant, the build that must not move, the residue check) and judges the run
against the baselines the run promised in `safety.json`; a baseline that is gone fails the replay closed (exit 1,
the row `tenant residue check` says that the replay cannot judge the run). Known limit: a document issued but not
yet posted when the run died is not cancelled by a cleanup that needs `posted_doc_id`; cancel it by hand.

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
chain, a fixture or an earlier output named by `pass`; a literal `REPLACE-WITH-*` placeholder anywhere in a process,
chain or fixture; an invalid `pass` list; an `api` path that does not start with `/api/`, or that matches no route (a
loose check against `lib/letflow/modules/stock/router.ex` and `lib/letflow/routers/*.ex`: the method and the end of
the path; `:id` matches anything; a route made only of `:id` counts only behind its router's mount name; `http_as` steps are
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
* `context.json`: the run's shared inputs, fixture values and explicitly passed values, plus all declared outputs in
  the final report. Private working values of one process never become another process's inputs. It holds no token and
  no shared access value.
* `cleanup.json`, `meta.json`: what `runner.py cleanup` replays (section 3). `safety.json`: what the run promises
  its cleanup replay (the baselines the replay has to find and the platform watch it has to keep). `issues.json`:
  the issues filed.

Nothing secret is written: tokens and shared access values are kept in memory, never put in the log, and every one
the runner has seen is replaced by `***` in every file before it is written. Secret-looking fields (password, passwd,
secret, token, api key, authorization, credential and access), every Authorization or Bearer value and every JWT-shaped
string are masked. E-mail addresses and phone-number-shaped strings are masked character by character so their shape
remains visible without retaining the address or number.

## 7. How to run it on a release candidate

1. Wait until the QA build is the candidate: `project/scripts/qa_stable.sh --wait` prints `sha=<sha> stable`.
2. `python3 scripts/uat/runner.py chain test/uat/chains/<chain>.json --build-sha <sha> --file-issues --repo <owner/name>
   --run-dir <dir>` with `TEAM_ROOT` and the UAT environment set. The preflight stops the run if the build differs
   or moves.
3. Read `<dir>/summary.md`: the verdict and the first failing step are at the top. The failing request and response
   are in `run.jsonl` (and in the issue). Exit 0 = the candidate passed these processes.
4. If the run was killed: `runner.py cleanup <dir>` before anything else touches the tenant.

## 7a. The release-candidate chain for SSS (`test/uat/chains/rc-sss.json`)

The chain plays, in this order: BP-01 receive, BP-02 issue, BP-03 transfer, BP-04 count, BP-05 reversal, BP-06 Excel
load, BP-08 old-app phone operations, BP-09 crafted requests refused, BP-07 onboarding. Every process undoes what it
posted (a reversal and its task), and the cleanup of the chain runs at the end in reverse order, so the stock of the
tenant ends where it started (each process that moves stock ends with a check of the start balance).

How to run the RC:

1. `project/scripts/qa_stable.sh --wait` prints `sha=<sha> stable`.
2. The chain declares `fixtures: ["second_place"]`; no manual second-place id is needed. The fixture supplies
   `place_from` from the chain's `place` and creates or reuses `place_to`, linked to the same org unit. The other ids
   are the SSS fixture of `sss-rehearsal2`.
3. `TEAM_ROOT=<team repository> python3 scripts/uat/runner.py chain test/uat/chains/rc-sss.json --build-sha <sha>
   --file-issues --repo tvolodi-org/letflow --run-dir <dir>`
4. Read `<dir>/summary.md`. Exit 0 on one sha = the candidate passed. A failure stops the chain (add `--keep-going`
   to see the rest); `runner.py cleanup <dir>` undoes an aborted run.
5. Prove repeatability by running the same command twice in a row with two new run directories. Both runs must pass;
   the second must find no residue of the first (created fixture locations are retired, stock and documents are
   cleaned up).
6. BP-08 calls the old address of the tenant: pass `--old-base-url https://qa.bizdala.com/qoimeks/<slug>/api` (or set
   `old_base_url` in the chain file) for the tenant under test.

## 8. The process file, reference

`{ "id", "bp_entry", "title", "description", "tenant": "${tenant}", "inputs": [names], "defaults": {name: value},
"dry_run": {tenant, actors, inputs, base_url?, old_base_url?}, "steps": [step], "outputs": {name: expression},
"cleanup": [step], "platform_residue": {definitions?: [names], instances?: [names]} }`. A step: `id`, `actor` (not for
`http_as`), `do`, one of `expect` / `expect_refused`, optional
`expect_repeat`, `save`, `requires`, `http_as`. `do` is exactly one of: `{api, path, body?, headers?}`,
`{wait_task: {for_document, step, within_s?, interval_s?}, claim?, complete?: {body}}`,
`{wait_mail: {recipient, subject, within_s?, interval_s?, subject_contains?, trap_url?}}`,
`{assert_only: {path, headers?}}`,
`{sweep: {prefix, exclude_contains: "${run_id}", accept?}}` (T-2898: DELETEs the definitions on the platform tenant
whose name starts with the throwaway prefix `uat-tmp-<kind>-` and does not contain this run's id, listed through
`GET /api/v1/definitions?name=<prefix>` paged; one line per definition, `accept` default 200/204/404/409, any other
status fails; give it `expect: {status: 200}`),
`{page_through: {path, page_size?, cursor?: "next_cursor", items?: "items", max_pages?}}` (T-2941: follows the cursor
of a list route, at most 15 pages; per page status 200 and `count` (when present) equal to the items returned, else
the step errors; the answer is the collected `{items, pages, truncated}`; the step's `expect` may also carry
`age_at_least: {seconds, field?: created_at}` (no item old enough = the step is NOT RUN, "inconclusive: no old
rows", never a pass) and `unique_ids: true | <field>` (no id twice across pages)),
`{repeat: {api, path, body?}, times?: 2}`, `{parallel: [call, call, ...]}` (2 to 6 calls; a call may name its own
`actor`). `save` values: a path (`"$.id"`), `{pick, default?, if_unset?, optional?}`, `{api, path, pick}`, `{secret: path}`
(memory only), or a literal / `${...}` expression. `${a + 5}`, `${(a - b) * 2}`: numbers with `+ - * /` and
parentheses in decimal arithmetic. A string that is only `${name}` keeps the type of the value. `outputs` are
evaluated right after the steps, so they may use names saved by steps (not by cleanup steps). A chain additionally has
`processes`, optional `fixtures`, and `pass: {process_id: [output_name, ...]}`; only those outputs cross a process
boundary.

## 9. Tests

One file per command:

```
python3 -B -m unittest -v scripts/uat/tests/test_runner.py          # M0: one process, assertions, secrets, CLI
python3 -B -m unittest -v scripts/uat/tests/test_chain.py           # chains, cleanup replay, preflight, step kinds, log
python3 -B -m unittest -v scripts/uat/tests/test_issues.py          # --file-issues with a fake gh
python3 -B -m unittest -v scripts/uat/tests/test_check_processes.py # the static check
python3 -B -m unittest -v scripts/uat/tests/test_upload.py          # upload step, Client 1 workbook set
python3 -B -m unittest -v scripts/uat/tests/test_dryrun.py          # dry-run --changed in a temp git repository
python3 -B -m unittest -v scripts/uat/tests/test_fixtures.py        # fixtures: order, idempotent reuse, cleanup, static check
python3 -B -m unittest -v scripts/uat/tests/test_platform_actors.py # an actor of another tenant: its address, its token, the residue
python3 -B -m unittest -v scripts/uat/tests/test_wait_mail.py       # the wait_mail step: the trap by recipient and subject, the body and the address stay out of the log
python3 -B -m unittest -v scripts/uat/tests/test_platform_residue.py # the residue of a platform run: the definition, the instances, the tenant
```

`tests/fakes.py` is the shared fake: an HTTP server (a thread) with the stock routes BP-01 needs, the shared access
routes and the old address, a fake token command, a fake `gh` and a fake `qa_stable.sh` written by the tests: no
network, no model.

The whole suite runs in the product CI too: `scripts/uat/` is a backend path (`scripts/ci_changed_paths.sh`), and
`test/scripts/uat_tooling_test.exs` runs `python3 -B -m unittest discover -s scripts/uat/tests`, so a change of the
runner is checked by the backend gate and not only by the team locally.

## Tenant residue check (T-2548)

Before the first process the runner lists, per tenant it touches, up to 200 newest non-final stock documents with
their `state` (`GET /api/v1/modules/stock/documents`) and the pending tasks through the status-filtered
`GET /api/v1/tasks?status=PENDING` endpoint, and writes them to `residue_before.json` in the run dir. Closed task
history is never paged. If an open-task cursor expires (HTTP 410), the listing restarts from the first page; after
three restarts the baseline or final listing fails as unavailable. After the last cleanup the runner lists again:
every document that was not there before and is not `reversed`, `cancelled` or `rejected`, and every new pending task,
is residue. The run then FAILS with the row `tenant residue check` (tenant, number, kind, state). Documents that
existed before are never reported. An unreadable baseline or final listing (including any non-2xx answer or a
timeout) also FAILS with `tenant residue check` and `baseline unavailable` or `final listing unavailable`: it is
never passed or skipped. `runner.py cleanup <run dir>` reads `residue_before.json` and runs the same comparison after
the replay, so an interrupted run is judged too. `"residue_check": false` in a chain or process file turns it off
(default on).

**What the run promises its cleanup replay.** The run writes `safety.json` in the run dir: the baselines the
replay has to find (`residue_tenants`, `platform_tenants`) and the platform watch it has to keep (`watch`). A
replay that cannot find one of them **fails closed**: the row `tenant residue check` says that the replay
cannot judge the run and the replay exits 1. It never passes a run it cannot judge (the T-2606 defect: the
replay omitted the platform residue check and reported PASS with an instance still ACTIVE). The cleanup itself
still runs: the replay undoes what it can and then says that it cannot judge the rest.

**The platform tenants.** An actor object (the platform administrator) lives on the platform tenant, and what a
platform run can leave behind there is not a document but a **tenant**: the runner lists the tenant registry
(`GET /api/v1/tenants`) before the first process and after the last cleanup - when an actor of that tenant may
read it (a tenant administrator may not: there is no platform registry for it, and that is not a failure). A
throwaway tenant (its slug starts with
`uat-tmp-`) that was not there before the run and is still **active** is residue: the run FAILS with the row
`tenant residue check` and the text `leftover platform tenant <slug>`. A tenant that existed before the run is
never reported, a **deactivated** one is final (QA cannot purge a tenant without a lifecycle row), and the fixed
fixture tenant `uat-tmp-fixture` is never residue. The baseline of the platform tenants is in `platform_before.json`
of the run directory.

### The platform residue check of a platform run (G18)

A platform run (the pilot of the tenant registration: the process runs in the platform tenant as the platform
administrator) leaves more behind than a document: a **definition version** and an **instance**. A process says
what the run watches in a `platform_residue` block:

```json
{
  "id": "BP-PLATFORM-01",
  "platform_residue": {
    "definitions": ["platform.register_tenant"],
    "instances": ["${instance_id}"]
  },
  "steps": [ ... ]
}
```

| key | meaning |
|---|---|
| `definitions` | the names of the definitions of the platform tenant whose active version must be the one the run found |
| `instances` | the instances of the platform tenant that must not be left open (a name the process saved, or the id itself) |

The runner watches nothing until a process says so: a run without the block behaves exactly as before.

**What the check does.**

1. **The definition is back on its previous version.** Before the first process the runner reads the active
   version rows of every named definition of the platform tenant (`GET /api/v1/definitions?status=active`) and
   writes them to `platform_before.json`. After the last cleanup it reads them again: the run must have left the
   definition on the version it found. The **id of the active version row** is what is compared, because a
   rollback activates the row it had before (the same row, the same id) - and because the version string itself
   (`1.0.0`) has the shape of a token and is therefore masked in a log. A definition left on another version is
   residue: the row `tenant residue check` says `definition <name> was on the version <id> before the run, it is
   on the version <id> now`.
2. **No instance is left open.** Every instance the run started (the answer of a start carries its
   `instance_id`) and every instance the block names is read after the last cleanup
   (`GET /api/v1/instances/<id>`): an instance that is still `ACTIVE` is residue, the row says
   `instance <id> is still open`. An instance that does not exist (it was deleted) is not left open.
3. **No active throwaway tenant is left.** The tenant rule of the section above: a `uat-tmp-` tenant that the run
   created and left **active** is residue. QA cannot purge a tenant that was created through
   `POST /api/v1/tenants`, so a **deactivated** one is final.

A baseline or a final listing that cannot be read fails the row (`baseline unavailable`, `final listing
unavailable`): the check is never passed silently. The run FAILS with the row `tenant residue check` and the
text of every finding.

**Who must be able to read the registry.** The check needs an actor that may read the tenant registry (the
platform administrator). A tenant of the run whose actors may **not** read it is not a failure of the run: the
platform tenant of the run is watched, and it is watched correctly. Only a run in which **no** group of actors can
read the registry cannot watch the platform tenant; that run FAILS with `baseline unavailable: the tenant registry
is not readable ..., no actor of this run reads the platform tenant, the run cannot watch it`.

**The cleanup replay judges the same run.** `runner.py cleanup <run dir>` replays the cleanup list of an
interrupted run and runs the same comparison after it. The watch of the run (the `platform_residue` block) and the
instances the run started are kept in `platform_watch.json` of the run directory, so the replay does not pass while
an instance of that run is still open: the row `tenant residue check` says `instance <id> is still open` and the
replay FAILS.

## residue-sweep (T-2869, D-208)

One-shot removal of the residue of a discarded walk from ONE QA tenant, by a reviewed list file (no SQL, no clicks):

    python3 -B scripts/uat/runner.py residue-sweep test/uat/sweeps/residue-sweep-qoimeks-qa2.json --tenant qoimeks-qa2

The list file names the tenant, its admin user, the documents to reverse (reason "D-208 discarded walk") and the tasks
to complete. Exit 2 and no request for a retired tenant, a tenant other than the list file's, or a base url that is not
the tenant's QA host. One line per item (done / already gone / refused (status)); "already gone" never fails the run.
It ends by re-reading the residue baseline and printing its sha256. Run it ONCE before the next RC regression.

**Stale shared-stock-access (T-2980).** On a QA tenant of the sweep list (`SHARED_ACCESS_SWEEP_TENANTS`, qoimeks-qa2) the runner retires a shared-stock-access object created before the run started (GET exists + created_at older than the run, then DELETE as admin; 404 = already gone) before the first step of any run whose scenarios use that route. The line `retired shared-stock-access (created_at ..., created_by ...)` is logged. The reviewed sweep list can ask for the same with `"shared_stock_access": true`.

## definition-report (T-2982)

Read-only report of the stock process definitions of one QA tenant (every version row with status, owner stamp,
activation state, creator and times, and one verdict per name: ok / foreign / no-active / dead-newest, the paths of
`Posting.ensure_active/3`). Use it to read why a stock route answers 409 `definition_not_active`:

    python3 -B scripts/uat/runner.py definition-report --tenant qoimeks-qa2 --admin qoimeks-qa2-admin

Output also goes to `<run-dir>/definition_report.json`. The definitions API has no status-change history.
