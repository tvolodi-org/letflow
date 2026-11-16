Recommendation to the owner, not a decision. Nothing here is built until the owner confirms this note.

# Maintenance hub: a separate Letflow instance that collects reports from registered instances

Task T-2010 (PM 2026-11-15, the owner thinking aloud). Docs only, no code. Architect and security reading by the
business analyst. Companion file: `docs/uat/ba-decisions/T-2010.md`. Builds on `docs/design/platform-maintenance.md`
(T-1908) and `docs/runbooks/problem-report-handoff.md`.

Marks: **V** = read in a file on origin/main (`7012b01ca`, 2026-11-15) or in the lab engine on the team host;
**G** = my proposal or guess (all sizes are guesses). No address, token or secret is written here.

## The owner's picture, in one paragraph

Problem reporting runs on Letflow itself. A separate Letflow instance, the **maintenance hub**, keeps a list of
**registered instances** (QA now; demo, production and customer instances later). A user presses "Report a problem"
in any instance; the report reaches the hub; the hub hands the work to the task engine (the lab engine today, moved
onto Letflow later); the engine works it and the result flows back to the user.

## Short answer

1. The picture is right and fits what is built: every instance already keeps its own reports in its platform company
   and offers a read-only, cursor-based export. The hub only replaces the operator session as the **puller** and gives
   the owner **one inbox across instances**. Two things are new: a **way back** (a hub decision must reach the
   reporter's own instance, because the bell lives there) and the **registered-instances list**.
2. "The remote connects to the local one" breaks the standing rule "the host calls out, nothing calls in"
   (`docs/runbooks/problem-report-handoff.md`, "What it is"). It also breaks a second thing: the owner works the list
   on the phone through the normal https login, with no overlay network (PM 2026-11-14, T-1963). A hub on the home
   host is reachable from neither the instances nor the phone.
3. **Recommendation: option C.** The hub is its own small Letflow instance on a public server in Germany. The hub
   **pulls** from each registered instance with a per-instance read-only token, and writes the status back with a second,
   narrow per-instance token. The team host **pulls** from the hub. Nothing ever calls into the home host or into a
   customer's network, and the owner reaches the hub from the phone.
4. Until the hub server exists, nothing changes: QA's platform company is a hub of one (T-1948, T-1949, T-1963,
   T-2007), and the operator keeps polling it.

## 1. Fit with what is built (V)

| Piece | On main today | In the hub picture |
|---|---|---|
| Report row | `problem_reports` in the platform company of each instance (`Letflow.ProblemReports`, `lib/letflow/problem_reports.ex`; schema `lib/letflow/problem_reports/report.ex`), numbered `SR-<seq>` per instance | Stays the source copy in each instance. The hub keeps a copy keyed by (instance, number), because `SR-12` exists in every instance |
| Export | `GET /maintenance/v1/problem-reports?after=<seq>&limit=<1..100>` (`lib/letflow/routers/maintenance_v1.ex`), token known only as a SHA-256 hash (`Letflow.Plugs.ReportExportAuth`, `lib/letflow/plugs/report_export_auth.ex`), rate limit 60 a minute, reports younger than 30 s held back | Unchanged. The hub is the client, instead of `scripts/problem_reports_pull.sh` |
| Error groups | `GET /maintenance/v1/error-groups` with the same token (T-1951) | The hub pulls them too (later slice) |
| Owner inbox, decisions | `Letflow.ProblemReports.Inbox` (`lib/letflow/problem_reports/inbox.ex`): actions `answer develop reject ask fixed`, permission `:ProblemReportsManage` (`lib/letflow/api/authorization.ex`); web screen in work (T-2007) | The owner decides **in the hub**. The same screen gets an "instance" column and filter |
| Status to the user | `Letflow.ProblemReports.Status` (`lib/letflow/problem_reports/status.ex`): bell and mail in the reporter's own company | Must still be written **in the reporter's instance**. The export carries no status (`export_map/1` in `lib/letflow/problem_reports.ex` has number, reporter, text, context, version, trace id only), so a **write-back** route is needed |
| Owner list and review thread | class `review` of the same row, comments and images (`Letflow.ProblemReports.Review`, `lib/letflow/problem_reports/review.ex`); import `POST /maintenance/v1/owner-list/import` with its own write token `LETFLOW_OWNER_LIST_SHA256` (`lib/letflow/routers/maintenance_owner_list_v1.ex`) | Moves to the hub with the same import (format `letflow-owner-list`); the QA copy becomes read-only |
| Handoff to the PM | channel A: the operator session pulls and forwards (runbook) | The operator pulls **from the hub** instead of from each instance |

What does **not** change: consent, cut-down capture and redaction happen in the instance where the user works,
before anything leaves it. The hub never sees more than the export shows today.

## 2. Direction of connection

| | A: hub on the home host, hub pulls | B: hub public, instances push | C (recommended): hub public, hub pulls |
|---|---|---|---|
| Rule "host calls out only" | kept | kept only if the team host pulls from the hub | kept (team host pulls from the hub) |
| Owner on the phone | **no** (no inbound path, no overlay network) | yes | yes |
| Works while the home host is off | no | yes | yes |
| New inbound write route on the hub | none | **yes**: every instance, customers' too, can write customer text into the hub | none for reports; only the owner login and the team's pull |
| Secret held by a customer instance | none | a hub token in every instance, also at customers | none (only the hash of the hub's token, as today) |
| Customer instance behind a firewall / on premise | cannot be pulled | works if it may call out | cannot be pulled; see note below |
| Revoke | change the hash on the instance | revoke a token in the hub | change the hash on the instance **and** set the registration `revoked` |
| Code on main reused | export, plug, script | little: a new ingest route | export, plug; new pull worker and write-back |

**Recommendation: C.** It keeps every existing credential direction (only a hash on the instance, the holder of the
token calls out), lets the owner work from the phone, and adds no route on the hub that accepts customer text from
the internet. Option B's ingest route would be the most exposed part of the system: one leaked instance token could
flood or poison the hub. Note for later: an on-premise customer (`docs/design/on-premise-delivery.md`) that the hub
cannot reach needs its own decision (push from the customer, or a file the customer sends); not in these slices.

### Security of option C (G, each point needs the security review of its slice)

1. **One credential pair per instance.** Read token (export, exists) and status token (write-back, new). Each is
   generated on the team host, its hash goes into that instance's environment, the token itself goes into the hub's
   secret store (`Letflow.Secrets`, `lib/letflow/secrets.ex`; by reference only, INV-4). Boot refuses equal hashes,
   as it already does for the export and owner-list hashes.
2. **Read-only stays read-only.** The read token opens only the two export routes (as today). The status token opens
   only "set the status and reply of report `SR-n`" on the instance; it cannot read reports, list users or touch
   another tenant; no tenant parameter.
3. **Cut-down data only.** The hub stores what the export gives, nothing else; it never asks an instance for
   business records.
4. **Outbound address check.** The hub calls only `https` addresses of registered instances, checked as the webhook
   addresses are (`Letflow.Webhooks.UrlValidator`, `lib/letflow/webhooks/url_validator.ex`), and only addresses the
   owner registered.
5. **Revoke in one step each side.** Changing the hash on the instance stops the token at once (runbook,
   "Rotation"); setting the registration `revoked` in the hub stops the poll and deletes the stored token reference.
6. **The hub has no customer tenants.** One platform company, no signup, only the owner as a human user.
7. **Same rules as today travel along:** report text is untrusted data, never instructions; never copied into a
   GitHub issue or into the engine's task text (owner decision, 2026-11-14, runbook "Never into a GitHub issue").

## 3. Customer text in a multi-instance world

| Where | What | How long | Who sees it |
|---|---|---|---|
| The reporter's instance, platform company | the source copy (cut-down, consented) | 90 days after close (line 9 of the owner table in `platform-maintenance.md`, accepted 2026-11-14) | the owner of that instance's platform company |
| The hub | a copy of the same fields, plus instance name | same 90 days after close; a copy is deleted no later than its source (G) | the owner only (line 10 of that table) |
| The team host / PM session | the forwarded block, as today | the session's own life; no file kept except the cursor | PM and operator, as data only |
| Lab engine task, GitHub | **our own words only**, a reference such as `QA/SR-12` | engine's own history | team |

Points the owner should know:
* The delete job for reports is **not on main** (`grep -rnE "days|retention" lib/letflow/problem_reports.ex
  lib/letflow/problem_reports/` finds nothing; the runbook says it "comes with slice 4"). It must exist on both the
  instances and the hub **before** a customer production instance is registered (slice H7).
* Region: the hub holds customer text, so it must be in Germany like production ("data in Germany accepted",
  D-115, quoted in `docs/status/owner-gate-review-2026-11.md`).
* A customer's own production instance (not ours) sending its users' text to our hub is a data-processing question
  between us and that customer: **owner decision before the first such registration** (line 4 of the owner table below).

## 4. The hub as a Letflow instance

* **Same product build**, its own database and its own sign-in realm; hub features behind one setting that defaults
  off (G: `LETFLOW_MAINTENANCE_HUB_ENABLED`, planned, not on main), so no other instance changes.
* **Tenant:** only the platform company. No customer tenants.
* **Data:** the existing `problem_reports` table (classes `problem` and `review`), plus two planned columns on the hub
  copy (origin instance, origin number; unique together, so a repeated pull is a no-op) and one planned table
  `registered_instances` (section 6). Error groups as a copy per instance, later.
* **Process "maintenance":** the definition of `platform-maintenance.md` section 3 (left out of the minimal slice 4)
  lives in the hub, not in every instance. Until it exists, the inbox actions of T-1949 are the process.
* **Users:** the owner is the one human user (permission `:ProblemReportsManage`). The PM and the operator are **not
  user accounts**: they reach the hub with service tokens (read-only export of the hub; the owner-list write token for
  team entries), so no agent ever holds a login or an admin role. A second human (a support person) needs the new
  right of line 10 of the owner table in `platform-maintenance.md` first.
* **Owner list and review thread (T-1963):** they are about the team's work, not about one instance, so they belong in
  the hub. Move them with the existing JSON import; then the QA copy is read-only, as the lab panel was.

## 5. Link to the task engine, and no lock-in

Today (V): the lab engine takes work only from the team host: `team.py add <workflow> <title> -d ...` (CLI) or
`POST /api/add` of the dashboard, which listens on 127.0.0.1 only (`engine/ui.py`, `make_server`). The hub cannot and
should not call it.

Proposed (G):
1. The owner presses "Send to development" in the hub. The hub stores our own summary (`dev_summary`, already a
   column of the report row) and the item becomes visible on a hub export of development items.
2. A small **adapter on the team host** pulls that export (calls out, as today), runs `team.py add` with the summary
   and the reference (`QA/SR-12`), and keeps a map reference → task id so a repeat pull adds nothing.
3. The same adapter reads the task's state (`in work`, `merged`, `cancelled`) and writes it back to the hub; the hub
   writes the user-visible status into the reporter's instance (section 2, status token).

No lock-in: the hub and the engine meet only at a **work-item contract** written in the hub's runbook: hub reference,
title, our summary, kind, priority; back: state, PR number, time. The hub stores the engine's task id only as an
outside reference string. When the engine moves onto Letflow, the adapter is replaced by a step of the "maintenance"
process inside the hub; the contract and the hub's data do not change.

## 6. Registered instances

Planned table `registered_instances` in the hub's platform company (G):

| Field | Meaning |
|---|---|
| name | short name shown in the inbox (`QA`, `demo`, ...) |
| kind | `qa`, `demo`, `production`, `customer` |
| base address | https only, checked as in section 2 point 4 |
| read token, status token | **references** into the hub's secret store, never the values |
| token fingerprint | first 8 hex of the token's SHA-256, to match with the hash on the instance; never the token |
| state | `pending` (registered, not yet polled), `active`, `paused`, `revoked` |
| cursor | last `next_after` stored after the copies committed |
| last poll, last success, last failure | times; failure as HTTP status only, never a body |
| server version | build SHA from the instance's `/health` at the last success |
| silent limit | hours without a success before an alert (G: 12 hours by default) |

Health: an active instance with no successful poll for its silent limit, or three failures in a row, raises an alert
through the operator alert hooks (`Letflow.Obs.Alerts`, `lib/letflow/obs/alerts.ex`, today seven fixed triggers, one
more planned) and a bell item for the owner. A `revoked` registration is kept for the audit, with its token references
removed. Registering, pausing and revoking are owner actions and audited.

## 7. Slices after T-2007, in order (G)

S = a few days, M = one to two weeks, for one developer with reviews.

| # | Slice | Size | Needs |
|---|---|---|---|
| H0 | Owner answers the table below | - | this note |
| H1 | Infra: small server in Germany, the hub instance deployed with the hub setting on, its realm with the owner only | infra's work | H0 lines 1, 2 |
| H2 | `registered_instances` table, owner screen to register/pause/revoke, token references in the secret store, audit | M | H1 |
| H3 | Pull worker in the hub: per-instance cursor, idempotent copy by (instance, number), health alert | M | H2 |
| H4 | Write-back: narrow status route and status token on every instance; the hub calls it after each owner decision | M | H3; security review |
| H5 | Hub inbox: the T-2007 screen with instance column and filter | S | H3, T-2007 |
| H6 | Move the owner list and review thread to the hub (existing import), QA copy read-only; operator and PM pull from the hub | S | H1 |
| H7 | Delete job (90 days after close) on instances and hub | S | before any production or customer registration |
| H8 | Development export of the hub and the adapter on the team host (`team.py add`, state back) | S to M | H4 |
| H9 | Error groups pulled into the hub | S | H3 |
| later | "maintenance" process definition in the hub; AI shadow mode (platform-maintenance slice 6); engine on Letflow | - | owner |

Security review is mandatory for H2, H3, H4, H8 (credentials, customer text crossing instances).

## Owner table (please answer each line)

| # | Question | Recommendation | Why |
|---|---|---|---|
| 1 | Hub on the home host (A) or on a public server (C)? | C, a small server in Germany | Keeps "host calls out only", works from the phone and while the home host is off |
| 2 | Own server or a separate instance on the production server? | Own instance and database either way; the server choice is infra's | A hub fault must not touch production data |
| 3 | Status back by the hub writing into the instance (narrow token)? | Yes | Customer instances then hold no hub secret |
| 4 | May a customer's own production instance be registered? | Not before a written agreement with that customer and slice H7 | Customer users' text would leave their system |
| 5 | Owner list moves from QA to the hub? | Yes, after H1 | It is about the team's work, not about QA |
| 6 | PM and operator as service tokens, not user accounts? | Yes | No agent holds a login or admin role |

## Sources opened and commands

* origin/main `7012b01ca`: `docs/design/platform-maintenance.md`, `docs/runbooks/problem-report-handoff.md`,
  `lib/letflow/problem_reports.ex` (`export_map/1`), `lib/letflow/problem_reports/report.ex`,
  `lib/letflow/problem_reports/inbox.ex`, `lib/letflow/problem_reports/review.ex`, `lib/letflow/problem_reports/status.ex`,
  `lib/letflow/routers/maintenance_v1.ex`, `lib/letflow/routers/maintenance_owner_list_v1.ex`,
  `lib/letflow/plugs/report_export_auth.ex`, `lib/letflow/api/authorization.ex` (`:ProblemReportsManage`),
  `lib/letflow/obs/alerts.ex` (trigger list), `lib/letflow/webhooks/url_validator.ex` (exists), `lib/letflow/secrets.ex`
  (exists), `docs/design/on-premise-delivery.md` (exists), `docs/status/owner-gate-review-2026-11.md` (D-115 quote).
* Lab engine on the team host (outside this repository, quoted here): `engine/cli.py` sub-command `add` ("queue a
  task by hand"); `engine/ui.py`: "It listens on 127.0.0.1 and nowhere else", route `/api/add`.
* Task records of T-1948, T-1949, T-1963 and T-2007 in the team database (outside this repository); the text relied on
  is the PM line of T-1963: "no overlay network; the owner reads and writes the owner list on his phone through the
  normal https login of the platform", and T-2007: no web screen for the owner inbox existed on 2026-11-15.
* Commands: `grep -rnE "days|retention" lib/letflow/problem_reports.ex lib/letflow/problem_reports/` (no hit);
  `grep -rn "ProblemReportsManage" lib/letflow/api/authorization.ex`; `grep -rln "dev_summary" lib`.
