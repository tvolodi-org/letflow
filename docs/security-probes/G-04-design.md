# G-04 design — canary/taint harness (design only, no code)

Gap **G-04** of the team repository's `docs/security-coverage.md` §4:

> Canary-secret/taint harness from every input encoding to every
> response/log/error/audit/DLQ/webhook/UAT artifact, including message
> interpolation and URL forms.

This file is the **design** for that harness. It contains no code. The build
task (T-2628) writes the probe from it, and it also writes
`docs/security-probes/G-04.md`, the case table of what it built, in the same
shape as `G-05.md` and `G-06.md`. When this file and `G-04.md` disagree after
the build, `G-04.md` describes the code and this file describes the intent; the
build says which rows it changed and why.

Class: **TOOL** (D-184/D-186 ratchet). The probe is mechanical: no model, no
network beyond 127.0.0.1, no wall clock, fixed seeds.

## 0. Leaks the probe must catch

Each one was found by a reviewer reading the code. The probe exists so that no
reviewer has to find them again:

| # | Leak | Input form | Surface | Probe case |
|---|---|---|---|---|
| L1 | T-2606: when Mailpit could not be reached, the runner wrote the recipient **percent-encoded** (`person%40example.test`) into `run.jsonl` | percent-encoded email in a URL query | UAT run artifact | C-30 |
| L2 | T-2606: the credential of the mail trap URL (`http://user:trap-secret@…`) reached the run artifacts | URL userinfo | UAT run artifact | C-31 |
| L3 | T-2724 (24 Nov): `seed_outbound_open.sh` echoed `SERVICE_TASK_MOCK_BASE_URL=https://SECRET@httpbin.org/…` to stderr when curl failed | URL userinfo in an env var | shell seed script stderr | C-33 |
| L4 | T-2704/T-2734: with `LOG_LEVEL=debug`, `admin_email` and the realm id of a tenant registration appear verbatim in the **Ecto SQL debug log** (query parameters). The existing canary test captured only `:info` | plain JSON start variable | application log, `:debug`, SQL | C-01 |

Facts on main (checked on 1ec454da5, re-checked from 3981d83be) that the design depends on. The build re-checks each
one before it relies on it (§9):

- `config/runtime.exs` (REQ-193): the Logger level is `:debug` in test
  (`LOG_LEVEL` unset) and `:info` in prod unless `LOG_LEVEL=debug`.
- `Letflow.Repo` has no `log:` option in any config file, so Ecto logs every
  query at `:debug`, and the message text includes the parameters.
- `Letflow.Secrets.LogFilter` (a `:logger` primary filter, registered in
  `Letflow.Application.start/2`) redacts **metadata by key name only**
  (`Letflow.Secrets.Redaction`). It does not redact the message string. So L4
  is live on main today.
- The `/api/v1` `Plug.Parsers` list (`Letflow.Plugs.ApiPipeline`) is `:json`,
  `:multipart`, `CsvBodyParser`, `XlsxBodyParser`, `LogoBodyParser`. There is
  **no `:urlencoded` body parser**.
- No module in `lib/` reads or sets a cookie:
  `git grep -nE "fetch_cookies|put_resp_cookie|req_cookies" -- lib/` hits
  nothing (exit 1).
- Base64 reaches the server only as opaque tokens: pagination cursors
  (`Letflow.Api.Pagination`, `Letflow.Entities.Query.CursorSeal`) and JWT
  bearer segments.
- The notification port's test double is
  `Letflow.LoginDiscoveryNotifierDouble` (`config/test.exs`). It sends every
  `deliver_message/1` to an owner pid.
- `Letflow.ErrorCapture` is off by default (`:error_capture, enabled: false`).
  It keeps code names, the route template and a server-shaped trace id only.
- Tests that already cover part of this, and that the probe reuses rather than
  copies: `test/letflow/instances/step_log_secret_test.exs` (step log,
  timeline, DLQ payload); `g06_outbound_dispatch_probes_test.exs` P3
  (transport error text); `scripts/uat/tests/test_wait_mail.py`
  `TheTrapStaysOutOfTheLog` (L1/L2); `test/letflow/secrets/log_filter_test.exs`.

## 1. The canary

### 1.1 The core

Each case gets its own canary. The heart of a canary is its **core**: 16
characters from the lowercase base32 alphabet (`a-z2-7`), derived
deterministically:

```
core(case_id) = "q" <> first 15 chars of lowercase base32(sha256("letflow-g04:" <> case_id))
```

The core always starts with `q`, so it can never begin with a digit. This rule
is what makes detection independent of encoding. The core uses only unreserved
ASCII letters and digits, so percent-encoding, double percent-encoding, JSON
escaping, HTML/XML entity escaping, Elixir `inspect/1`, SQL quoting, CSV
quoting, case folding and Unicode normalisation (NFC, NFKC) leave it
**byte-identical**. Whatever an output path does to the special characters
around the core, the core survives. Detection therefore keys on the core
(§2), and the punctuation the canary carries around the core is there only to
exercise the encoders on the way out.

No randomness and no clock. A hit names its case exactly, because no two cases
share a core.

### 1.2 Canary kinds (what is planted)

| kind | planted value | where it is planted | may legitimately appear (§3) |
|---|---|---|---|
| `secret` | `lfs-<core>-"\/%+&é` (quote, backslash, slash, percent, plus, ampersand, non-ASCII) | a `Letflow.Secrets` value (webhook signing secret `Letflow.Webhooks` → `Secrets.put/1`; a service-task header held by reference) | nowhere outside the secrets ciphertext (which the detector cannot read by construction) |
| `credential_url` | `https://u<core>:p<core>@127.0.0.1:<port>/x?token=<core>#f<core>` | a stored outbound URL (webhook `target_url`, service-task endpoint, outbound destination), an env base URL of a UAT/seed script | only the outbound request to its own host, as that request's credential (E-10) |
| `token` | `Bearer lft.<core>.sig` | the `Authorization` header; a UAT token env var (`QA_ADMIN_AUTH_TOKEN` and the like) | nowhere |
| `email` | `lfe+<core>@example.test` | a recipient, `admin_email`, a user's email, a signup email | the record it belongs to and that record's authorised reads (E-01..E-06) |
| `name` | `Lfn <core> Ǆ̈ ﬁ` (a NFC/NFKC-sensitive tail: a digraph, a combining mark, a ligature) | a person or record display name, a free-text field, a filename | the same as `email` |
| `header` | `lfh-<core>` | `X-Request-Id`, `traceparent`, `User-Agent`, `Idempotency-Key`, a custom outbound header | the outbound request it was configured for (E-10). `User-Agent` only in the problem report the user filed (E-08) |

### 1.3 Input encodings (how the planted value is sent)

Each encoding below is a way of **sending** a canary. The same kind can be
sent in several encodings, and each pair (encoding, entry path) is one case
(§5).

| id | input encoding | how the case builds it |
|---|---|---|
| I1 | plain JSON string | `Jason.encode!` of the value in the body |
| I2 | percent-encoded | `URI.encode_www_form/1` in a query param, a path segment, or a URL that is itself a JSON value (`?to=lfe%2B…%40example.test`) |
| I3 | double percent-encoded | I2 applied twice (`%2540`) |
| I4 | base64 | std and url-safe base64 of the value as a cursor or a JWT segment |
| I5 | JSON-escaped | every non-alnum char of the punctuation written as `\uXXXX` in the raw body (`@` for `@`), plus `\/` |
| I6 | Unicode forms | the `name` kind sent as NFC, as NFD and with a U+200B zero-width space after the core (never inside it) |
| I7 | URL userinfo / query / fragment | the `credential_url` value |
| I8 | message interpolation template | a canary in a variable rendered by a notification template (`{{var}}`), a service-task endpoint/header template, a Logger message (`"… #{x}"`), a problem `detail` |
| I9 | header | `Authorization`, `X-Request-Id`, `traceparent`, `User-Agent`, `Idempotency-Key`, a configured outbound header |
| I10 | cookie | `Cookie: lf=<canary>` on every case that sends headers |
| I11 | multipart | a text part, a filename (`Content-Disposition` `filename=` and `filename*=UTF-8''…`), a CSV/XLSX import cell |
| I12 | form-urlencoded | an `application/x-www-form-urlencoded` body, and the query string (which is the same format) |
| I13 | URL path segment | a canary used as an id or slug in the path |

## 2. What counts as a leak

### 2.1 The haystack and its normalisation

Each surface collector (§4) returns a list of `{surface, locator, bytes}`.
Here `locator` names the place (for example `audit_entries.after_state row 3`
or `log :debug Ecto.Adapters.SQL`). The detector searches each `bytes` after
these steps, applied in order. Each step is applied to a copy, and **all**
copies are searched:

1. raw bytes;
2. if the bytes start with a zip signature (`PK\x03\x04`: docx, xlsx): every
   member, from `:zip.unzip(bytes, [:memory])`, as its own haystack (the steps
   apply again to each one);
3. if the bytes start with `%PDF`: each `FlateDecode` stream, inflated with
   `:zlib.uncompress/1` (a stream that will not inflate is skipped and noted
   as such in the run line);
4. percent-decoding, up to two rounds (lenient: an invalid `%` sequence is
   left as it is);
5. JSON `\uXXXX` and `\/` unescaping, and HTML/XML entity decoding (`&amp;`,
   `&#64;`, `&#x40;`);
6. Unicode NFKC, then removal of default-ignorable code points (U+200B..U+200D,
   U+2060, U+FEFF, U+00AD), then `String.downcase/1`.

Steps 4–6 are not needed to find the core (it survives them). They are there
so that the **partial** and **decoded** forms in §2.2 are also found when an
encoder broke the core apart, for example `%71` for `q` from an over-eager
encoder, or a soft hyphen inserted by a renderer.

### 2.2 Needles: a hit is any of these

For a canary with core `c` and planted value `v`:

| form | needle | why it counts as a leak |
|---|---|---|
| exact | `v` (after the same normalisation) | the value itself |
| substring / core | `c` | the value survived with its punctuation changed (covers every percent, JSON, entity and case form) |
| partial / truncated | any 10-character window of `c` | the value was cut (`String.slice/2`, a 64-byte column, a log line truncated), split across two fields, or masked badly. 10 base32 chars carry 50 bits, so a chance match is negligible |
| decoded-to-encoded | base64 std and url-safe of `v` and of `c`, at the three byte alignments (encode `v`, `"x" <> v`, `"xx" <> v` and search the stable inner part, dropping the first and last 4 output chars) | a value that was base64-wrapped on the way out (a JWT-like blob, a `Basic` header, a cursor) |
| hex | lowercase and uppercase hex of `v` and of `c` | bytea columns rendered by `row_to_json` (`\\x…`), `Base.encode16` debug output |
| hashed | hex and base64 of `sha256`, `sha1` and `md5` of `v` and of `c` | an unsalted hash of a secret can be checked offline, and an unsalted hash of a personal datum links that person across tables. Both count as a leak. A keyed hash (HMAC with a server pepper, `Letflow.LoginDiscovery`) cannot be computed by the probe and is not a hit |

**Not a leak:** a masked form that keeps no 10-char window of the core (`l***@example.test`,
`https://***@127.0.0.1/…`); a reference to the value (`secret_ref`, a record
id); the field **name** (`admin_email`); a length or a count.

The detector reports every hit as `{case_id, kind, surface, locator, form}`.
The verdict compares the hits with the exceptions list (§3): an unlisted hit
fails the probe, and so does a listed baseline row that no longer matches
(ratchet, §3.2).

### 2.3 Non-vacuity: a seeded failing case per surface

A probe that finds nothing can mean the output is clean, or that the collector
read nothing. To rule out the second, each surface S1–S14 has a **seeded
leak** that is driven through the same collector and the same
`G04Canary.verdict/2` the real cases use. The seeded leak writes the canary
straight into that surface, and the test asserts the verdict names exactly
that surface and that form:

| surface | seeded leak (in `test/support/g04_canary.ex`, function `seed_leak/2`) |
|---|---|
| S1 response body | a test-only `Plug` mounted in the test that answers `200` with `v` in the body |
| S2 response headers | the same plug, with `v` percent-encoded in a `location` header |
| S3 error response | the same plug, answering `422` problem+json with `c` in `detail` |
| S4 log, every level | `Logger.debug/1` with `v` in the message; `Logger.info/2` with `c` under the non-sensitive metadata key `:data`; and one `Repo.query!("SELECT $1::text", [v])` (proves that the SQL debug line is captured) |
| S5 audit | `Audit.insert_entry/3` with `c` in `after_state` |
| S6 DLQ | `Letflow.Dlq.enqueue/2` with `v` in `error_detail` |
| S7 webhook / outbound request | a webhook delivery to the 127.0.0.1 listener with `c` in the payload |
| S8 UAT / run artifact | a run directory with `c` written to `run.jsonl` by the Python fake (`scripts/uat/tests/test_g04_canary.py`, case `seeded`) |
| S9 notification | `LoginDiscoveryNotifierDouble` receiving a message whose body holds the base64 of `v` |
| S10 instance variables / events | `POST /instances` with `v` as an `initial_variables` value (expected to hit; the seeded case asserts the hit is reported, before E-02 excuses it in the real cases) |
| S11 exported file | an xlsx-shaped zip built in the test with `:zip.create/3` (`[:memory]`) holding `c` in `xl/sharedStrings.xml`, and a one-stream PDF whose `FlateDecode` stream holds `c`, so the zip and PDF steps are proven |
| S12 error capture | `ErrorCapture.record/1` with an entry whose route template holds `c`, then `Buffer.flush/0` |
| S13 step log | a step row whose outcome text holds `c`, inserted the way `step_log_secret_test.exs` builds its dispatch row, read through `Letflow.Instances.StepLog.steps/2` |
| S14 shell script output | a stub script that echoes `v` to stderr |

The seeded leaks also prove the `part` rule of §3.1: a personal canary in
`audit_entries.action`, in an audit `resource_id`, and in a 2xx body read by a
caller the case declares unauthorised must each FAIL the verdict although E-01
and E-03 exist (three seeded cases, run through `verdict/2` with the real
exceptions file).

The seeded leaks also prove the forms: one each for exact, core, partial (the
first 12 chars of `c`), base64, hex and sha256. There is also one **near-miss**
that must NOT hit: a 9-char window of `c`, and a masked form.

A mutation check is recorded in `G-04.md`. It removes each collector from the
aggregate, then each normalisation step, and both times the seeded case of
that surface or form must go red. The build runs it once and quotes the
results, as G-06 did.

## 3. The exceptions list

### 3.1 File and format

The list lives in `test/fixtures/security_probes/g04/exceptions.txt`, one row
per line, `|`-separated, `#` for comments:

```
id | type | canary_kind | surface | case | part | reason (one line) | decided by
```

- `type` is `legit` (the value may appear there) or `baseline` (a known leak
  awaiting its fix).
- `case` is a case id or `*`.
- `decided by` is the task that reviewed the row (T-number). The §3.3 rows
  carry it as their last column; a row withdrawn in §3.3 (E-09) is a gap in
  the numbering and is NOT copied into the fixture.
- `part` says WHERE inside the surface the hit sits. It is a closed vocabulary
  per surface, and every collector tags each hit with one `part` value:
  S1 `body_2xx_authorised` | `body_2xx_other`;
  S2 `resp_headers`; S3 `detail` | `errors` | `raw_body`;
  S5 `before_after_state` | `action` | `resource_id` | `trace_id` | `other_column`;
  S7 `request_headers` | `request_body` | `request_path_query`;
  S10 `event_variables` | `event_other` | `read_answer`; every other surface
  `any`. A row may list several parts, and several surfaces; each listed part
  must belong to the vocabulary of at least one listed surface (`any` counts
  as the vocabulary of an `any` surface) and the row matches a hit whose part
  is in the list. The case definition declares whether its caller is authorised to read
  the record, and that decides `body_2xx_authorised` against `body_2xx_other`.
  A hit whose `part` the collector cannot classify is `other_*`, never `any`.
- A row matches a hit when `canary_kind`, `surface`, `case` AND `part` match.
  `part` may be `any` only on a surface whose vocabulary above is `any`. The
  `locator` is NOT part of the key: a row decides a class, and a sibling merge
  that adds a column or a table does not invalidate it (SF-10, "exception list
  of decisions, not a snapshot").
- `secret` and `token` canaries **cannot** have a `legit` row. The loader
  refuses such a row, and a test proves the refusal.
- The loader also refuses (test per rule): a `legit` row for a personal kind
  (`email`, `name`) on any surface with `case = *` unless every listed part is
  a named part of S1, S5 or S10 (so on every surface whose vocabulary is
  `any`, a personal-kind row must name case ids); a `legit` row for a
  personal kind on S1, S5 or S10 whose `part` is `any` or an `other_*` value;
  and a row whose `part` is outside the vocabularies of its listed surfaces.
  The reason text is documentation, never a matcher: a constraint is carried
  by `case` and `part`. Every shipped row of §3.3 (E-09 excepted, which is not copied) passes these rules, and
  the refusal tests use them as the passing fixture. So a canary in `audit_entries.action`, an
  audit `resource_id`, or a 2xx body of an unauthorised caller is not excused by
  any `*` row, and each of those has a seeded-leak case (§2.3).
- The cross-tenant and unauthorised-read class (a foreign tenant's or another
  scope node's datum in an answer) is owned by **G-01** (rules M4 and M6 of
  `docs/security-probes/G-01.md`). G-04 plants and reads inside one tenant and
  does not see a foreign datum; no G-04 row covers it, and E-01 must never be
  widened to compensate.

### 3.2 Rules

- An unlisted hit fails the probe. The failure names the case, surface,
  locator and form.
- A `baseline` row that matches no hit in the run fails the probe as
  **stale**. A fixed leak must be removed from the list, so the list can only
  shrink (ratchet).
- A `legit` row that matches no hit is reported as a warning line, not a
  failure: a legitimate home can be empty for a given case.
- Every change to `exceptions.txt` is a security-relevant change. The PR that
  adds a row names the row in its Gates block. The file sits under
  `test/fixtures/security_probes/`, next to the G-01 ratchet and the G-11
  triage list. Whether to add that directory to the team's `[sensitive]` paths
  (`project/team.toml`, a team-repo file) is the operator's decision.

### 3.3 The initial rows (reviewed here; T-2628 copies them)

| id | type | canary_kind | surface | case | part | reason | decided by |
|---|---|---|---|---|---|---|---|
| E-01 | legit | email, name | S1 | * | body_2xx_authorised | the 2xx read of the record that owns the value, by a caller the case declares authorised to read it (decides `body_2xx_authorised`) | T-2735 |
| E-02 | legit | email, name | S10 | * | event_variables, read_answer | a start or completion variable is business data stored by design in the instance's events and returned by its own reads | T-2735 |
| E-03 | legit | email, name | S5 | * | before_after_state | the audit `before_state`/`after_state` of the record whose field it is (the audit records what changed); `action`, `resource_id`, `trace_id` have no row | T-2735 |
| E-04 | legit | email, name | S7 | C-12 | request_body | a variable of an event the tenant subscribed to, in the payload sent to the tenant's own webhook endpoint | T-2735 |
| E-05 | legit | email, name | S9 | C-14, C-15 | any | the recipient address in the adapter's `to`, and a template field rendered for that recipient | T-2735 |
| E-06 | legit | email, name | S11 | C-20 | any | the tenant's own data export of its own records | T-2735 |
| E-07 | legit | name | S8 | C-32 | any | the evidence line of the UAT step that created the named record. `email` has no row: the T-2606 recipient rule stands | T-2735 |
| E-08 | legit | header | S1, S5 | C-24 | body_2xx_authorised, before_after_state | the `User-Agent` stored in the problem report the user filed, and that report's audit row | T-2735 |
| E-09 | withdrawn | | | | | withdrawn before review (a duplicate of E-10); the id is not reused, the row is not copied to the fixture | |
| E-10 | legit | credential_url, header | S7 | C-10, C-11, C-13 | request_headers | the outbound request to the host the credential or header was configured for (the 127.0.0.1 listener), in its `Authorization`/configured header; the body and the path/query have no row | T-2735 |
| B-01 | baseline | email | S4 | C-01 | any | L4: Ecto `:debug` logs the parameters of the registration insert. The fix (parameter redaction of logged statements, or `log: false` on those statements) is the T-2704/T-2734 finding. T-2628 records the row if that fix has not landed when it builds | T-2735 |

T-2628 adds every further `baseline` row it finds on the first run on main,
one per class, each reported in its findings (as G-05 recorded its baseline).
It does not fix the leaks in the probe task. It adds no `legit` row beyond
this table without a `decided by` that is not T-2628 itself: a new legitimate
home needs a security reviewer's line in the build's own review.

## 4. Surfaces and how each is collected

All collectors take a case context (`tenant prefix`, `case_id`, the test's
listener and notifier pids) and return `{surface, locator, bytes}` items. The
tables and modules each collector reads are **derived at run time**. None of
them is a hand list:

| id | surface | collector |
|---|---|---|
| S1 | HTTP response body (2xx) | parts `body_2xx_authorised`/`body_2xx_other`; every `Plug.Test` response the case received through `Letflow.Router` (the real router, a real token) |
| S2 | HTTP response headers | part `resp_headers`; the same responses' `resp_headers` (all of them, including `location`, `content-disposition`, `x-request-id`) |
| S3 | error responses (4xx/5xx) | parts `detail`, `errors`, `raw_body`; the same, status ≥ 400. Problem+json `detail`, `errors` and the raw body |
| S4 | application logs, every level, including Ecto SQL debug and Plug/Bandit request logs | a test-attached `:logger` handler (`G04Canary.LogSink`, `level: :all`, added in `setup`, removed in `on_exit`). It receives the event **after** the primary filters (so `LogFilter` has run, as in production) and records the formatted message, `inspect(meta)`, and the output of `Letflow.Obs.Logger.format/2` (the production formatter). The test first asserts `Logger.level() == :debug` and that the SQL seeded leak is caught. A config change that raises the level then fails the probe; it cannot pass quietly |
| S5 | audit events | every `audit_entries` row of the tenant prefix and of the platform prefix inserted during the case, as `row_to_json` text |
| S6 | DLQ entries | every `dlq` row of the case, all columns (`reason`, `full_reason`, `error_detail`, `error_chain`, `source_payload`, `context_json`, `retry_history`) |
| S7 | webhook payloads / outbound requests | a 127.0.0.1 Bandit listener started per test file that records method, path, query (part `request_path_query`), headers (`request_headers`) and body (`request_body`) of each request it receives. The same listener is the target of webhooks and service tasks |
| S8 | UAT/run artifacts | every file under the run directories that the Python fake runs wrote (`run.jsonl`, `summary.md`, `context.json`, issue bodies), read recursively |
| S9 | notification bodies | every message the notifier double sent to the test pid (subject, body, `to`), plus `user_notifications` rows (title), plus `notification_files` bytes (with the zip step) |
| S10 | process/instance variables | the tenant's event rows of the case's instances, and the answers of `GET /instances/:id`, `/history` and `/timeline` |
| S11 | exported files | the response bytes of `POST /api/v1/data-export`, document print routes and import templates the case called (with the zip and PDF steps) |
| S12 | error capture | with `ErrorCapture` enabled for the file (`Application.put_env`, restored `on_exit`): the ETS tables `ErrorCapture.main_table/0` and `samples_table/0`, and `error_groups` rows after a forced flush |
| S13 | step log | `Letflow.Instances.StepLog.steps/2` for each instance of the case, as `inspect` text |
| S14 | shell script output | stdout and stderr of each script run, plus every file the script wrote under its temp `HOME`/`TMPDIR` |
| S* | the database, catch-all | every table of the tenant schema and of the `public` schema (from `information_schema.tables`, excluding `schema_migrations`), as `SELECT row_to_json(t)::text FROM <prefix>.<table> t`. This catches a surface nobody listed (a new column, a new table). A hit in a table with no surface id is reported as `S*:<table>` and needs a row of its own |

S* is what makes the surface list a floor rather than a ceiling. The fresh
tenant per test file keeps it small (measured on the build host; the cost
budget in §6 includes it).

## 5. The cell table: input encoding × output surface

`P` = reachable: there is a case that plants the canary in this encoding and
every collector is run on it. A hit then fails unless an exceptions row
excuses it.
`–n` = not reachable, with the reason `n` below. Unreachable cells still have
a **guard** case where noted, so a change that makes the cell reachable fails
until it is classified.

Every case runs **all** collectors (§4), not only the `P` cells of its row.
The table says where a hit is possible and what the case list must cover. It
does not limit what is scanned.

| input \ surface | S1 body | S2 headers | S3 errors | S4 logs | S5 audit | S6 DLQ | S7 webhook/out | S8 UAT | S9 notify | S10 vars | S11 export | S12 errcap | S13 step log | S14 shell |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| I1 plain JSON | P | P | P | P | P | P | P | P | P | P | P | P | P | –a |
| I2 percent | P | P | P | P | P | P | P | P | P | P | –b | P | P | P |
| I3 double percent | –c | P | P | P | –c | P | P | P | –c | –c | –c | P | –c | P |
| I4 base64 | –d | –d | P | P | –d | –d | –d | –d | –d | –d | –d | P | –d | –a |
| I5 JSON-escaped | P | P | P | P | P | P | P | –e | P | P | P | P | P | –a |
| I6 Unicode forms | P | P | P | P | P | –f | P | P | P | P | P | –f | P | –a |
| I7 URL userinfo/query | P | P | P | P | P | P | P | P | –g | P | P | P | P | P |
| I8 interpolation | P | –h | P | P | P | P | P | P | P | P | P | –h | P | P |
| I9 header | P | P | P | P | P | P | P | P | –g | –i | –b | P | P | P |
| I10 cookie | –j | –j | –j | –j | –j | –j | –j | –j | –j | –j | –j | –j | –j | –a |
| I11 multipart | P | P | P | P | P | –k | –k | –e | –k | P | P | P | –k | –a |
| I12 form-urlencoded body | –l | –l | P | P | –l | –l | –l | –e | –l | –l | –l | P | –l | –a |
| I12 query string | P | P | P | P | P | –k | –k | P | –k | P | P | P | –k | –a |
| I13 path segment | P | P | P | P | P | –k | –k | P | –k | –k | –k | P | –k | –a |

Reasons:

- **a** — S14 takes its input from env vars and argv, not HTTP. Only I2, I3,
  I7, I8 and I9 have a shell form (an env URL, a templated curl header).
- **b** — no export or import template copies a raw query or header into the
  file. Guard: the S* catch-all would still report it.
- **c** — a double-encoded value is stored as its once-decoded text (`%40`),
  which still contains the core. Its I2 row covers those surfaces. The cells
  where the double form behaves differently (logs of the raw request line,
  errors, outbound URL rendering, error capture) are `P`.
- **d** — base64 arrives only as a cursor or a bearer token. A refused cursor
  or token writes no row and sends nothing out. Guard case C-23 asserts
  "no write" with the S* catch-all.
- **e** — the UAT runner does not send JSON, multipart or form bodies from
  raw tenant input. It builds them from the process file, whose values are
  I1/I7/I8 cases.
- **f** — the DLQ and error capture keep machine reasons and code names. A
  Unicode name reaches them only through I1/I8, which cover them.
- **g** — notification bodies come from templates and variables, not from
  URLs or request headers. I8 covers template rendering.
- **h** — templates do not render into response headers or route templates.
  `content-disposition` from a filename is I11.
- **i** — headers do not become variables. `Idempotency-Key` is a column, and
  the S* catch-all covers it.
- **j** — no code in `lib/` reads a cookie (§0 fact). Guard case C-25 sends a
  cookie canary on every case, and a lint test inside the probe re-runs the
  cookie grep. A new cookie reader makes the probe fail until this row
  becomes `P`.
- **k** — a multipart part, a query or a path segment is request input to its
  own route. It is not carried into outbound requests, DLQ or notifications
  except as a stored value, which is the I1 row.
- **l** — no `:urlencoded` body parser on `/api/v1` (§0 fact). The body is
  refused before any handler. C-26 asserts the refusal status, that S3 does
  not echo the body, and that S* shows no write. If a urlencoded parser is
  added, C-26's status assertion fails and the row must become `P`.

## 6. The case list

T-2628 builds these cases and lists them, one row each, in
`docs/security-probes/G-04.md` (`case | encoding | entry path | canary kind |
expected hits (exception ids) | test`). The entry paths are real routes or
context functions on main. The build checks each against the router before
writing it (§9). **The authority for a case's shape is this table; the test
name is the build's.**

| case | enc | entry path | kind(s) | expected excused hits |
|---|---|---|---|---|
| C-01 | I1 | tenant registration start with `admin_email` and `idp_realm_id`: `Letflow.PlatformProcesses.start_register_tenant/2` (on main; no route calls it yet), plus `POST /api/v1/tenants` and `POST /api/v1/onboarding` once the T-2704 rewiring has merged (the build checks with `git grep -n start_register_tenant lib/letflow/routers`) | email, name | E-02, B-01 (if not fixed) |
| C-02 | I1, I5, I6 | `POST /api/v1/instances` with `initial_variables` | email, name | E-02 (a plain variable is not a secret, so the `secret` kind is not planted here) |
| C-03 | I1 | `POST /api/v1/identity/users`, then `GET /users/:id` | email, name | E-01, E-03 |
| C-04 | I11 | `POST /api/v1/identity/users/import` (CSV and XLSX, a canary in a cell and in the filename) | email, name | E-01, E-03 |
| C-05 | I1 | `POST /api/signup` (unauthenticated) | email | none outside `signup_requests` (S*, via an E-01-like row the build adds with its reason if the stored request is the value's home) |
| C-10 | I7 | `POST /api/v1/webhooks/subscriptions` with a `credential_url` `target_url`; delivery to the listener | credential_url | E-10 |
| C-11 | I7, I8, I9 | service task whose endpoint template renders a `credential_url` and a configured header, against the listener answering 500 (lands in DLQ) | credential_url, header | E-10 only. **Not** S6 (the DLQ case of `step_log_secret_test.exs`, generalised to every form in §2.2) |
| C-12 | I1 | webhook delivery of an instance event whose variables hold the canary | email, name | E-04 |
| C-13 | I1 | webhook signing secret (`Letflow.Webhooks` → `Secrets.put`) used on a delivery | secret | none. The signature header is an HMAC of the body (not computable by the probe), and the secret itself must not appear anywhere, including S7 |
| C-14 | I8 | `Notifications.deliver_to_address/6` with a template rendering `{{var}}` = canary, and a canary recipient | email, name | E-05 |
| C-15 | I8, I1 | `Notifications.deliver_to_file/5` (notification file bytes) | name | E-05 |
| C-16 | I2, I3 | outbound destination `POST /api/v1/outbound-destinations` with a percent- and double-encoded canary in the host/path, refused or stored | credential_url | none |
| C-20 | I1, I11 | `POST /api/v1/data-export` after C-03 (xlsx via the zip step) | email, name | E-06 |
| C-21 | I2, I12q | list routes with `?q=`/filter params holding the canary (instances, identity users) | email | none (a list answer may hold the C-03 record. Its hit is E-01 only when the case reads with an authorised caller; otherwise it fails) |
| C-22 | I13, I2, I3 | `GET /api/v1/instances/<canary>` and `GET /api/v1/identity/users/<canary>` (malformed and well-formed-unknown ids) | name | none. 404/422 must not echo the id |
| C-23 | I4 | a cursor that is the base64 of the canary; a bearer token whose payload segment is the base64 of the canary | token, name | none |
| C-24 | I9 | every request of the file sends `User-Agent`, `X-Request-Id`, `traceparent`, `Idempotency-Key` canaries. A problem report is filed (`problem_reports`) | header | E-08 |
| C-25 | I10 | `Cookie:` canary on every case that sends headers, plus the cookie-reader grep guard | header | none |
| C-26 | I12 | a urlencoded body with the canary to `POST /api/v1/instances` | name | none. Refusal status asserted |
| C-27 | I9 | an invalid `Authorization: Bearer <canary>` to a protected route and to an unmatched path under a mount | token | none. 401 and logs clean |
| C-28 | I1, I8 | a real raise under `/api/v1` with a canary in the request body and the path, forced the way `test/letflow/error_capture_test.exs` EC-2 does it (drop the tenant's `groups` table, then `POST /api/v1/identity/groups/<canary>/members`). Error capture enabled, `Buffer.flush/0` before collecting | name | none in S3/S4/S12 |
| C-30 | I2 | UAT runner, mail-wait step, trap unreachable (L1). Python fake, `scripts/uat/tests/test_g04_canary.py` | email | none |
| C-31 | I7 | UAT runner with a mail trap URL and API base URL carrying userinfo (L2) | credential_url | none |
| C-32 | I1, I8 | UAT runner, a create step with a canary name, a token env var and a fake API error answer that echoes the request | name, token | E-07 (name only) |
| C-33 | I7, I9 | every tracked shell script that invokes `curl` (derived, below), run with a PATH stub `curl` that exits 22, and env base URL/token canaries (L3) | credential_url, token | none |

C-33's list of scripts is **derived from the leak's shape, not from a
directory or a variable-name suffix**: every tracked `*.sh` that invokes
`curl`, anywhere in the tree
(`git ls-files '*.sh' | xargs grep -lE '(^|[^A-Za-z_])curl[[:space:]]'`; today
28 files across `scripts/`, `scripts/lib/`, `scripts/e2e/`, `scripts/demo/`
and `deploy/`, re-derived by the build). Each derived script needs an
invocation row in `test/fixtures/security_probes/g04/shell_invocations.txt`
(`script | function or argv | env names`), or an explicit "not runnable"
row with a reason (e.g. it needs a live stack); a derived script with neither
fails the probe as "unclassified", and a row whose script is gone fails as
stale. A script that only *sources* a leaking helper is derived through its
own `curl` calls or, when it has none, is listed by name. The case table
names these explicitly, with an invocation row each, whatever env names the
fixed scripts use: `scripts/lib/seed_outbound_open.sh` (when T-2724/T-2730
merge; before that the row is absent and its absence is not a failure),
`scripts/lib/seed_service_task_base.sh` (it reads
`SERVICE_TASK_MOCK_BASE_URL` and echoes the resolved base; it has no `curl`,
so it is a by-name row), its four sourcing scripts
`scripts/seed_swiftroute_definition.sh`,
`scripts/seed_swiftroute_incident_definition.sh`,
`scripts/seed_meridian_definition.sh` and `scripts/seed_vortex_definition.sh`
(each echoes `SERVICE_TASK_EFFECTIVE_BASE_URL`; the planted canary is a
`credential_url` form in that variable), and `scripts/lib/seed_persona_actors_base.sh`
(echoes `${QA_URL}`). Env canaries cover every `*_URL`/`*_TOKEN`/`*_BASE_URL`
name a derived script reads (derived by grep, not listed by hand). The
build states which scripts it found.

The Python side (C-30..C-32, the seeded S8 case) runs as follows. The ExUnit
file writes `cases.json` (case id → canary values, from the Elixir generator,
so there is one generator), then runs
`python3 -I -B -m unittest discover -s scripts/uat/tests -p test_g04_canary.py`
with `G04_CASES` and `G04_OUT` set, and asserts exit 0 and one run directory
per case. The Elixir detector then scans `G04_OUT`. The Python test plants
and writes; it never detects. When `G04_CASES` is unset (the plain UAT suite
run by `test/scripts/uat_tooling_test.exs`), it uses built-in canaries and
asserts only that the run directories exist.

## 7. Files the build creates, and how it runs in the checks step

| file | content | tags | budget |
|---|---|---|---|
| `test/support/g04_canary.ex` | `Letflow.SecurityProbe.G04Canary`: `new/2` (case id, kind → canary), `needles/1`, `normalise/1`, `scan/2`, `collect/2` (all collectors), `verdict/2` (hits vs exceptions), `seed_leak/2`, `LogSink` handler, exceptions and invocations loaders. Pure except the collectors | — | — |
| `test/letflow/security_probe/g04_canary_detector_test.exs` | §2: every needle form hit, the near-misses not hit, the normalisation steps, the zip and PDF steps, the loader refusing a `legit` row for `secret`/`token`, stale-baseline failure. No database | `:security_probe`, `:unit`, `probe_cost_s: 2` | ≤ 2 s |
| `test/letflow/security_probe/g04_http_surfaces_test.exs` | C-01..C-05, C-20..C-28, the seeded leaks of S1–S5, S10–S13, S*. One committed tenant (`setup_all`), dropped `on_exit` | `:security_probe`, `probe_cost_s: 10` | ≤ 10 s |
| `test/letflow/security_probe/g04_outbound_surfaces_test.exs` | C-10..C-16, the seeded leaks of S6, S7, S9 | `:security_probe`, `probe_cost_s: 10` | ≤ 10 s |
| `test/letflow/security_probe/g04_artifact_surfaces_test.exs` | C-30..C-33, the seeded leaks of S8 and S14 | `:security_probe`, `:unit`, `probe_cost_s: 8` | ≤ 8 s |
| `scripts/uat/tests/test_g04_canary.py` | the Python fake runs (plant and write only) | — | inside the 8 s above |
| `test/fixtures/security_probes/g04/exceptions.txt` | §3 | — | — |
| `test/fixtures/security_probes/g04/shell_invocations.txt` | §6 C-33 | — | — |
| `docs/security-probes/G-04.md` | the case table, the non-vacuity run, the mutation run, the measured costs, the baseline rows found, residual limits | — | — |

The DB-backed files are `async: false` (one global log handler, a committed
tenant). The tag set is the one in the table above, per file: `@moduletag :security_probe`
plus `@moduletag probe_cost_s: N` (and `:unit` where the table says so; `:unit`
is an established tag on main). The donor for layout and for the committed-tenant
setup is `test/letflow/security_probe/g05_audit_row_schema_test.exs`, but its tags
(`probe_cost_s: 20`) are NOT copied: 20 exceeds the 12 s share.

**Checks step.** `project/scripts/lf.sh` (team repository) runs
`mix test --only security_probe` for every backend change, in its own
partition. Each probe file gets a share of the 300 s budget equal to
`LF_PROBE_BUDGET_S / number of tagged files`. With 20 tagged files on main
today and these 4 added, the share is 300/24 = 12 s. Every G-04 file is
designed to stay at or under 10 s, so all four run in checks, adding about
**30 s (half a minute)** to the probe set.

**Coverage move (stated, not a side effect).** Four more tagged files take the
count from 20 to 24, so the share falls from 300/20 = 15 s to 300/24 = 12 s.
`lf.sh` defers a probe whose declared cost is above the share to CI and the
nightly job. Three probes declare exactly 15 s today:
`g07_cursor_traversal_probe_test.exs`, `g08_uat_safety_equivalence_test.exs` and
`g09_migration_impact_test.exs`. They would leave the local checks step. The
build re-measures each (`Finished in`) and re-declares the measured cost; any
that truly measures above 12 s stays deferred, and the build records that move
as a finding in `G-04.md`. The build does not raise `PROBE_BUDGET_S`. If a file measures over its share
on the build host, the build splits it by surface (for example S7 apart from
S9). It does not raise `probe_cost_s` above the share, because lf.sh would
then move the file to CI and nightly only. The build quotes the measured time
of each file (`mix test <file>` with `MIX_TEST_PARTITION` set, the `Finished
in` line) in `G-04.md`.

**CI.** The build adds the four test files to `STANDARD_SECURITY_PROBE_TESTS`
in `scripts/ci_select_tests.py` (with that list's pin test, if any), so every
bounded CI run executes them, as G-06 did.

**Determinism.** Cores come from case ids (§1.1). Listener ports are bound to
`:0` and read back. No `Process.sleep`: an async delivery (webhook, notifier
task, DLQ retry) is awaited by its own completion message or by a bounded poll
on the row. A probe that fails once and passes on a rerun is a defect of the
probe (lf.sh never retries a probe).

## 8. Residual limits (stated, not hidden)

- A value the system **transforms by meaning** (a translated text, a value
  turned into a number or an id) is not traced. The harness traces bytes, not
  information flow.
- Keyed hashes and encryption (HMAC with a pepper, `Letflow.Secrets`
  ciphertext) cannot be detected by design. That is correct: they are not
  leaks.
- PDF text drawn with subset fonts and glyph ids may not be recoverable from
  the inflated streams. For document prints, the build also scans the value
  map handed to the renderer (the S11 collector reads it through the print
  module's public build function where one exists). It lists any print whose
  text it cannot recover.
- Logs from processes that run outside the test window (a poller tick after
  `on_exit`) are not captured. Cases await their own async work before
  collecting.
- The QA/prod log pipeline (journald, the JSON formatter's sink) is not run.
  The probe uses the same formatter (`Letflow.Obs.Logger.format/2`) on the same
  events, which is the code that decides the bytes.
- Real Mailpit, real Keycloak and the real UAT tenant are not used. The Python
  fakes stand in for them, as in `test_wait_mail.py`.

## 9. What the build checks before relying on this design

1. Each §0 fact, by its command: the Logger level line in `config/runtime.exs`;
   `git grep -n "log:" config/ lib/letflow/repo.ex`; the cookie grep; the
   `Plug.Parsers` list; the notifier double in `config/test.exs`.
2. Each §6 entry path, against the router (`lib/letflow/plugs/api_pipeline.ex`
   forwards and the router module's `authz_*` lines) or the context function's
   arity. A path that has moved is replaced by its current form, and the change
   is named in `G-04.md`. A path that is gone drops its case and records the
   reason.
3. Whether the L4 fix has landed (B-01 is added only if it has not), and
   whether `scripts/lib/seed_outbound_open.sh` is on main (C-33's derived
   list).
4. The tagged-file count for the share (`git grep -l "@moduletag
   :security_probe" test | wc -l`).

None of these is a design question: each has a stated default above.
