# Runbook: onboarding a real company as a tenant (production and QA dress rehearsal)

T-2220. The one procedure from an empty host to a walked tenant, for a company such as Smart Security
Systems (`sss`, `sss.ai-letflow.com`, D-158). It replaces the idea of a provisioner-made production
tenant: `Letflow.TenantProvisioner.create/1` is the demo provisioner (derived slug and realm, no realm,
no clients, no users, tier demo with an expiry) and is not used here.

## Scope and status

Production is not approved (D-086, D-019 item 9). This page is the procedure for the go and for QA dress
rehearsals; the QA walk was done for `qoimeks-qa2`. Run it on QA first, always: the create in step 4 is the
point of no return for the slug and the realm id. A tenant made by `POST /api/v1/tenants` has no
`tenant_lifecycles` row and `Letflow.TenantPurge` refuses it (and refuses every production tenant), so the
only way back is deactivate, and the slug stays taken for good. Nothing here touches production by itself.

## Who does what

| Actor | Does |
|---|---|
| infra | host, DNS, TLS, nginx, Keycloak (realm, clients, accounts), environment settings and restarts, database backups, `bin/letflow eval` |
| platform operator | holds the platform tenant's PLATFORM_ADMIN login (in practice infra's script mints the token in-process; who holds it in production is the owner's to name) |
| setup administrator | an operator-held TENANT_ADMIN account `<slug>-setup` in the company realm, from first sign-in until handover |
| company administrator | the customer's own TENANT_ADMIN |
| Qoimeks team | write freeze and extract, migration only |
| owner | the go decisions, see "Owner decisions this procedure needs" |

Steps marked **infra only** need host, Keycloak-admin or database access that no Letflow role has; Letflow
cannot do them through any route.

## Values for sss

| Value | Production | QA rehearsal |
|---|---|---|
| slug and realm | `sss` | a free QA slug, for example `sss-qa` |
| display name | `Smart Security Systems` | same |
| company host `<host>` | `sss.ai-letflow.com` | `<slug>.qa.ai-letflow.com` |
| `tenant_type` | `production` | `test` |
| app host `<app-host>` | `app.ai-letflow.com` | `qa.bizdala.com` |
| Keycloak host | `auth.ai-letflow.com` | `auth.qa.bizdala.com` |
| PWA `<pwa-uri>` | `https://pwa.ai-letflow.com` | `https://pwa.letflow.qa.bizdala.com` |

Default modules, in install order: `org`, `locations`, `catalog_items`, `codes`, `stock`.

`assets` only if the company keeps the asset register; it goes last (it depends on stock). The install route
installs one module and no dependency: `codes` is installed by hand before `stock`, a missing one is answered
422 `missing dependency: <id>`.

## Steps

Placeholders are in angle brackets. Tokens are read from a mode-600 file and never typed into a command line
or printed: `$PLATFORM_TOKEN` and `$SETUP_TOKEN` stand for a header line in such a file, used as
`--header @"$F"`.

### Step 0. Host ready

**Who:** infra only.

**Do:** the app at `<build-sha>`, Postgres, Keycloak, the PWA host, backups (`docs/runbooks/backup-restore.md`),
DNS and TLS for `<host>`, nginx sending `<host>` (SPA, `/api/`, `/qoimeks/`) to the app. Settings:
`LETFLOW_PLATFORM_TENANT_ID` set; `LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES` = `ai-letflow.com` (QA: the QA
suffixes); `LETFLOW_PROVISIONER_CREDENTIAL_SHA256` and the readonly hash UNSET in production;
`LETFLOW_REALM_USERS_ENABLED` unset; `LETFLOW_SHARED_STOCK_ACCESS_TENANTS` left alone until step 9.

**Check:** `curl -s https://<app-host>/health` shows `"sha":"<build-sha>"`; `/ready` answers 200;
`curl -s -o /dev/null -w '%{http_code}' https://<app-host>/admin/v1/tenants` is 404 in production; the platform
realm carries the nine roles (`python3 -I scripts/check_realm_roles.py <export>`).

**Rollback:** none needed.

### Step 1. Preflight and backup

**Who:** infra only.

**Do:** `GET https://<app-host>/api/v1/tenants/<slug>` with `$PLATFORM_TOKEN` (expect 404);
`GET https://<app-host>/api/tenant-config?host=<host>` (expect the default realm); confirm the Keycloak realm
`<slug>` does not exist; take a database dump and a Keycloak realm export and verify both. From step 4 on the
slug cannot be freed.

**Check:** 404, default realm, no realm `<slug>`, both backups restorable.

**Rollback:** none needed.

### Step 2. Realm and clients

**Who:** infra only.

**Do:** build the realm from `priv/keycloak/provisioner/v3/tenant-realm.json`: `__REALM_ID__` = `<slug>`,
`__TENANT_HOST__` = `<host>`, `__TENANT_SLUG__` = `<slug>`, `__PWA_URI__` = `<pwa-uri>`, `__PWA_ORIGIN__`, and the
`smtpServer` block. Product rule for the clients `letflow-web` and `letflow-mobile`: exact redirect URIs, no
path wildcard, and "Direct access grants" OFF (the v3 template has both). Infra's `realm` mode must follow this;
a copy of `bpm-default`'s `letflow-web` (password grant on, redirect `*`) is not acceptable for production.

**Check:** `python3 -I scripts/check_realm_roles.py <filled file>` passes; an authorize probe with
`redirect_uri=https://<host>/auth/callback` is accepted and one with a foreign URI gets Keycloak's
invalid-redirect page; the realm checklist of `docs/runbooks/onboarding-new-tenant-realm.md` is filled; admin
events are on.

**Rollback:** delete the realm (only before step 4).

### Step 3. Setup and first administrator accounts

**Who:** infra only.

**Do:** create `<slug>-setup` and the company administrator, each with a verified e-mail and the realm role
TENANT_ADMIN (`POST /api/v1/tenants` writes no pending admin grant). The company administrator's temporary
password goes by the channel the owner names (`docs/design/production-staff-accounts.md`, O-015). Never
PLATFORM_ADMIN. On QA infra's `users` mode makes persona accounts; for production it must not set permanent
passwords.

**Check:** both users enabled, role mapping exactly TENANT_ADMIN, no change to the default roles.

**Rollback:** disable or delete the users.

### Step 4. Tenant

**Who:** platform operator.

**Do:** `POST https://<app-host>/api/v1/tenants` with body
`{"slug":"<slug>","display_name":"<display name>","idp_realm_id":"<slug>","tenant_type":"production"}`
(QA: `"test"`).

**Check:** 201, `status` `active`, `tenant_type` as sent, `idp_realm_id` = `<slug>`. A 409 `slug already
exists`: stop, never retry with another slug. A 500: the tenant row may exist as `migrating`; follow "If the
tenant stays migrating" in `docs/runbooks/onboarding-new-tenant-realm.md`.

**Rollback:** `POST https://<app-host>/api/v1/tenants/<slug>/deactivate` only; slug and realm id stay reserved.

### Step 5. Host

**Who:** platform operator.

**Do:** `PUT https://<app-host>/api/v1/tenants/<slug>/hostname` with `{"hostname":"<host>"}`. Do not use infra's
SQL `registry` mode: it writes no audit entry and skips the suffix and reserved-name checks.

**Check:** 200 with `changed: true` (a replay answers `false`);
`GET /api/tenant-config?host=<host>` and `?realm=<slug>` give an `oidc_authority` ending in `/realms/<slug>`;
`GET /api/mobile/tenant-config?slug=<slug>` gives a `realm_url` ending in `/realms/<slug>`.

**Rollback:** `DELETE https://<app-host>/api/v1/tenants/<slug>/hostname`.

### Step 6. First sign-in and setup token

**Who:** setup administrator.

**Do:** sign in at `https://<host>` in a browser; on Admin, API tokens, mint a token for `<slug>-setup` itself with
role TENANT_ADMIN and `expires_at` at most one day ahead; the plaintext goes straight into a mode-600 file and is
shown only once. Calls with it send `Authorization: Bearer $SETUP_TOKEN` and `X-Tenant-Slug: <slug>`. The v3
realm refuses a password grant, so no script may get a token that way.

**Check:** `GET /api/v1/me/access` shows TENANT_ADMIN and `platform_tenant` false; `GET /api/v1/tenants` is 403.

**Rollback:** revoke the token (the screen, or `DELETE /api/v1/identity/tokens/<id>`).

### Step 7. Modules

**Who:** setup administrator, with `$SETUP_TOKEN`.

**Do:** one `POST https://<host>/api/v1/tenant/modules` with `{"module_id":"<id>","rationale":"<slug> onboarding"}`
per module, in the order of "Values for sss".

**Check:** each answers 201 with `version` equal to the build's own
(`git show <build-sha>:lib/letflow/modules/<id>/<id>.ex | grep 'version: "'`); 409 `module already installed`
on a replay counts as done; 422 `missing dependency` means the order was wrong: stop.
`GET /api/v1/entities/definitions/active/stock_quick_count` and `.../stock_opening` answer 200.

**Rollback:** none (a failed install rolls itself back; uninstall is off by default).

The stock process drafts activate on first use without an administrator step: test a shared-token
receipt, then an issue, and a STOREKEEPER receipt on a fresh tenant. Each creates its document and
reaches posting; check the `definition.activate` audit entry and that retrying creates no second
activation entry. Tenant-created or changed definitions must remain untouched and return 409
`definition_not_active`. See `stock-counts.md`, "Stock process activation".

### Step 8. Product check

**Who:** infra only (release console).

**Do:**
`bin/letflow eval 'Letflow.Release.tenant_onboarding_check("<slug>", host: "<host>", tenant_type: "production")'`
(QA: `tenant_type: "test"`; add `modules: ~w(org locations catalog_items codes stock assets)` when assets is
installed). For a readiness script, append `format: :json`: stdout is then one JSON object with the same header,
checks and `status` (`ready` or `red`). Both forms are read-only.

The report covers the tenant, realm, host row, modules at the build's versions, all ten stock process definitions
(ACTIVE and not needing reactivation), platform role groups including STOREKEEPER, active STOREKEEPER users and
their employee links, every stock document type and entity table, place-to-org-unit links, org units' legal entity
name and BIN, exactly one active employee and its active user link, `app_name`, shared stock access and scope
enforcement. Shared access is information; when it is enabled, scope enforcement must be `off`. Negative balances
and four-eyes are information, not readiness gates: the count rule is set at step 20, after this report runs, and
its value is read from the `four-eyes` line there.

Document types: `stock_receipt`, `stock_opening`, `stock_quick_count`, `stock_issue`, `stock_writeoff`,
`stock_transfer`, `stock_handover`, `stock_return`, `count.order`, `count.sheet`, `count.differences`,
`count.posting`.

Entity tables: `entity_stock_receipt`, `entity_stock_receipt_line`, `entity_stock_issue`,
`entity_stock_issue_line`, `entity_stock_writeoff`, `entity_stock_writeoff_line`, `entity_stock_transfer`,
`entity_stock_transfer_line`, `entity_stock_handover`, `entity_stock_handover_line`, `entity_stock_return`,
`entity_stock_return_line`, `entity_count_order`, `entity_count_order_scope`, `entity_count_commission_member`,
`entity_count_sheet_line`, `entity_count_entry`, `entity_count_signature`, `entity_count_freeze_location`,
`entity_stock_posting_mark`, `entity_stock_opening`, `entity_stock_opening_line`, `entity_stock_quick_count`,
`entity_stock_quick_count_line`.

A stock process is ready when it is `active` and needs no reactivation, or when it is still an untouched
module-owned draft that the first use activates (`active=false auto_activation=ready`). A missing,
tenant-created, changed, deprecated or archived process is `process_not_active`: stop and review the tenant's
definitions; never replace them by hand.

**Check:** the header names tenant slug, build SHA and date; each check is one `OK`, `RED` or `INFO` line with a
count or name and no personal data. The last line is `READY`, or `RED` followed by every failed check name. A
failing token means:

| Token | What to do |
|---|---|
| `module_missing` | step 7 |
| `module_version_differs` | the module upgrade route, never by hand |
| `process_not_active` | activate the shipped definition through its normal first-use path; do not edit rows |
| `reactivation_required` | reactivate the definition through the normal definition path |
| `document_type_missing`, `document_type_not_stock`, `table_missing` | stop and report; never create by hand |
| `role_groups_missing` | run the platform role-group check/backfill, then repeat this report |
| `storekeeper_missing`, `storekeeper_link_missing` | give the storekeeper the STOREKEEPER group and an active employee link |
| `place_link_missing`, `legal_entity_incomplete` | complete the named place/org-unit master data |
| `active_employee_count`, `employee_user_link_missing` | leave exactly one active employee, linked to an active user |
| `app_name_missing` | set the tenant's application name in tenant settings |
| `scope_enforcement_active` | when shared access is enabled, follow the scope-off procedure; never edit the row |
| `host_missing`, `host_differs`, `host_multiple` | step 5 |
| `realm_differs`, `tenant_type_differs` | stop and escalate: the realm cannot be changed after the create |
| `tenant_not_found`, `tenant_not_active`, `schema_not_registered`, `read_failed` | stop and report |

**Rollback:** none needed (read-only).

### Step 9. Shared stock access (only if the company's phones keep the old Qoimeks app)

**Who:** infra only for the settings and the Keycloak window; setup administrator for the call. Needs the owner's go.

**Do:** infra adds `<slug>` to `LETFLOW_SHARED_STOCK_ACCESS_TENANTS` (back up the env file, one key line, recreate
the app, `/health` back). The create route accepts only an interactive (OIDC) token and has no screen. Preferred:
the access token of the setup administrator's own browser session. Otherwise infra opens a time-boxed window with
"Direct access grants" ON for `letflow-web` of `<slug>` only. Then `POST /api/v1/identity/shared-stock-access`
with `{}` to generate, or `{"value": ...}` read from a file to keep the old value; the value goes into a mode-600
file for the phones. Infra turns the grant OFF again and probes that a password grant is refused.

**Check:** `GET /api/v1/identity/shared-stock-access` shows `enabled: true, exists: true`;
`https://<host>/qoimeks/<slug>/catalog` (and `.../api/catalog`, the form the real old app sends) answers 401 without the value and 200 with it; scope enforcement is off.

**Rollback:** `DELETE /api/v1/identity/shared-stock-access`, and remove the slug from the setting.

### Step 10. Data load for a migration

**Who:** setup administrator, Qoimeks team, infra.

**Do:** follow `docs/runbooks/qoimeks-rehearsal.md` with the setup token (write freeze first, then its steps), with
its "Minimum master data by API" first. The two OIDC-only switches (negative opening balances, four eyes for a
one-person company) are set on the Ledger settings and Approval rules screens; the four-eyes choice is the
company's and the owner's (step 20). For sss the count rule is already decided and is OFF (owner decision
D-164, step 20). Production only after the same extract passed on the QA rehearsal tenant.

**Check:** that runbook's compares (counts, quantities, masters) exit 0.

**Rollback:** the rollback step of that runbook.

### Step 11. Staff accounts

**Who:** infra only (Keycloak operator); the company administrator gives roles in Letflow.

**Do:** `docs/design/production-staff-accounts.md`, option B, pending owner decision O-015. Roles are given in
Letflow after each person's first sign-in; do not create people in Letflow first.

**Check:** the batch checklist of that note.

**Rollback:** its row "Disable a leaver in Keycloak".

### Step 12. Walk

**Who:** setup administrator, one storekeeper, company administrator.

**Do:** in a real browser: W1 the company administrator signs in at `https://<host>` (1440 px) and sees the Stock
menu; W2 a storekeeper signs in on a phone or at 390 px through the PWA; W3 the balances screen opens (data equals
step 10's compare, or empty); W4 the quick count screen opens (QA: one quick count posted and reversed;
production: no test data); W5 sign out. One screenshot per step, kept outside the repository (customer data).

**Check:** all five done.

**Rollback:** none needed.

### Step 13. Handover

**Who:** company administrator and infra.

**Do:** revoke the setup token; the company administrator sets `<slug>-setup` inactive
(`POST /api/v1/identity/users/<id>/status`; it needs another TENANT_ADMIN, otherwise 409
`last_tenant_wide_admin`); infra disables it in Keycloak and deletes the credential files.

**Check:** the setup login is refused; the evidence list (references only) is filed with the owner's go record.

**Rollback:** none needed.

## First use and cutover (steps 14 to 23)

Follow-up of T-2220 (T-2269). These steps come after step 8 and before the walk (step 12) as far as the data
allows; the order below is the order to do them in. Steps 14 to 18 are the first-use settings of a stock
tenant, 19 to 20 the defaults and the approval choice, 21 the cutover, 22 the infra-only list, 23 the go/no-go
page. Each has a **Check**. Where a check names a screen and not a route, the screen is the supported way.

### Step 14. Stock process definitions

**Who:** nobody for a fresh tenant: the product does it. The LONG-TERM COMPANY ADMIN only for the exception below.
NEVER the `<slug>-setup` account.

**Do:** nothing for the ten stock process definitions (receipt, issue, transfer, return, handover, writeoff,
reversal, count_posting, opening, quick_count). The first use of each activates its untouched module-owned draft
through a tenant-local system activator that never expires, so the handover in step 13 does not flag it
`needs_reactivation`; the activation is audited (`definition.activate`) and runs once. The same holds after
every FIRST install; after a stock module UPGRADE the old versions stay ACTIVE beside new DRAFTs, and the first use does not activate a draft over an active one: the tenant admin activates each draft (`stock-counts.md`, "After a module upgrade", 10 drafts on qoimeks-qa2 0.21.0 -> 0.22.0). A definition the tenant created or
changed, or a deprecated one, is never touched: the post answers 409 `definition_not_active`; the company admin
reviews it and activates it by `POST /api/v1/definitions/<id>/activate`. Details: `stock-counts.md`, "Stock
process activation".

**Existing tenant (for example one installed before T-2253, no walk yet):** run nothing by hand either: the
first post activates the drafts. To have them active earlier, post one receipt and one issue with a
STOREKEEPER token after the dump. Verify with `GET /api/v1/definitions` (status `active`, `needs_reactivation_at`
null) and with the step 8 report (`OK process ...`). A definition that an admin activated by hand and that was
flagged `needs_reactivation` stays that way: reactivate it with `POST /api/v1/definitions/<id>/reactivate`.

**Check:** `GET /api/v1/definitions` lists the 10 stock definitions as active, and `needs_reactivation_at` is
null on each; one known-item post succeeds. `stock_opening` and `stock_quick_count` stay DRAFT until their first
use, so the four-eyes `PUT` for them answers 422 `not_a_four_eyes_step` before that first use: post one
opening and one quick count first (before step 20).

**Rollback:** none needed.

### Step 15. Storekeeper role in Keycloak

**Who:** infra only.

**Do:** map the STOREKEEPER realm role to each storekeeper BEFORE that person's first login. The role claim
sync at first login is one-time and additive: a role mapped later is not picked up by it.

**Check:** after the first login, `GET /api/v1/me/access` (the storekeeper's own token) shows STOREKEEPER.

**Rollback:** remove the role mapping in Keycloak.

### Step 16. Link each employee to the user

**Who:** company administrator.

**Do:** after each storekeeper's first login, link their EMPLOYEE record to the user (`user_id`).

**Check:** the count of employees without a user link is 0 (Employees screen, filter "no user").

**Rollback:** clear the link on the employee.

### Step 17. Master data for the forms

**Who:** company administrator.

**Do:** the legal entity WITH NAME AND BIN on the org unit (the Z-forms print blank otherwise); every place
(location) linked to the org unit; EXACTLY ONE active employee as the old-address responsible.

**Check:** legal entity name and BIN present; places not linked to the org unit = 0; active employees marked as
old-address responsible = 1 (not 0, not 2).

**Rollback:** correct the records.

### Step 18. Scope enforcement off

**Who:** company administrator.

**Do:** with the shared access of step 9 in use, scope enforcement stays OFF for the tenant.

**Check:** the shared-access call and the `/qoimeks/<slug>/...` routes do not answer 403
`scope_enforcement_active`; if they do, scope enforcement is on: switch it off.

**Rollback:** switch it on again when the shared access is removed.

### Step 19. Defaults for sss

**Who:** company administrator.

**Do:** `allow_negative` ON (Ledger settings screen, with the warning shown to the user and a reason text).
Numbering starts at 1 per year; history stays in the old Qoimeks. The unit list comes from the import
converter of the data load (step 10); there is no seed, units cannot be created by plain create. Set
`settings[app_name]` = `Smart Security Systems` for the header (tenant settings screen); the `display_name` of
`POST /api/v1/tenants` is not used for it.

**Check:** `GET /api/v1/ledger-settings` shows `allow_negative` true; the header shows `Smart Security Systems`;
the unit list is non-empty after the load; the first document of the year has number 1.

**Rollback:** switch the setting back.

### Step 20. One administrator or two (four eyes, owner item O-006)

**Who:** the owner decides; company administrator sets it.

**Do:** choose one of two ways and write the choice in the go record:

Stock approve, post and reverse tasks require `StockApprove` (stock 0.23.0, decision 0093), held by TENANT_ADMIN,
not STOREKEEPER. In a one-person company the tenant admin is the approver. Turning four eyes OFF allows that
admin to self-approve; it does not grant approval authority to a storekeeper. Routing or reassignment cannot
grant the permission. Delegation to a tenant-defined permission role is not available yet; see `docs/roles.md`,
"Delegating stock approval", for the intended owner procedure and current limitation. Never give a customer
PLATFORM_ADMIN. Existing pinned definitions keep their old checks; see `docs/runbooks/stock-counts.md`,
"Who may approve, post and reverse", before upgrading an existing tenant.

**Each document kind is its own rule and its own choice.** A rule is a four-eyes step of the shipped stock
pack; the default is ON (a second person must approve), and the tenant administrator switches one rule OFF on
the Approval rules screen (Admin > Approval rules), with a reason. The screen and the route are the same
thing: `GET /api/v1/approval-rules` lists the rules, `PUT /api/v1/approval-rules/:definition_name/:node_id`
switches one.

| Document kind | Rule | Default | Client 1 (sss) | What the staff see |
|---|---|---|---|---|
| Opening balance (`stock_opening`) | `stock_opening / approve` | ON | separate choice: ON, or OFF with its own reason | ON: the person who issued the opening cannot approve it; a second administrator approves it in My Tasks. OFF with a reason: the one administrator approves their own opening, and the audit shows "self-approved, four-eyes off". |
| Count from the phone (`stock_quick_count`) | `stock_quick_count / approve` | ON | **OFF** (D-164) | ON: the administrator who did not count must approve, so the count waits and the balance changes only after that. OFF: the count posts at once, as on the old server, and the audit shows "self-approved, four-eyes off". |
| Excel load that creates counts | `stock_quick_count / approve` (the same rule as the count) | ON | **OFF** — the same rule as the count (D-164) | The same as the count: with the rule ON the loader's own approval is refused `separation_of_duties` and the load waits for a second person; with it OFF the load posts at once. |

- Two administrators with four eyes ON: the second one approves the opening balance and the counts
  (`stock_opening` and `stock_quick_count`, the latter also for an Excel load that creates a count).
- One administrator with four eyes OFF, with the reason text (the Approval rules screen); the audit still
  records the self-approval. Use it only for a one-person company. Choose **per rule**, one row of the table
  above per rule. A rule left ON in a one-person company **cannot be confirmed alone**: the approve step is
  refused as the same person.

**For sss (Client 1) the count rule is OFF: owner decision D-164 (2026-11-20).** The storekeeper counts from
the phone at the warehouse and the company has one administrator, so the count has to post at once. Switch the
count rule OFF once, before the first count.

With the count switch OFF the storekeeper's count posts at once on the phone and on the web. The audit shows one `task.self_approved` entry with the note "self-approved, four-eyes off" for each such count. A count issued while the rule was ON stays pending until an administrator approves it in My Tasks (T-2410): turning the switch OFF later does not post it by itself.


Do it as the company administrator in the browser, on Admin > Approval rules: turn off "Require a different
person to approve" for the step `stock_quick_count / approve`, type the reason, save. The screen asks for the
reason in both directions and keeps it in the audit log with the administrator's name. The route behind the
screen is `PUT /api/v1/approval-rules/stock_quick_count/approve`, with this body:

```
{"four_eyes": false, "reason": "Client 1, storekeeper counts from the phone, one administrator, owner decision D-164"}
```

The reason is one line, exactly as it stands there: the product's reason rule refuses a line break.

**The switch is an interactive act.** The route accepts only a person signed in in the browser, so the setup
API token of step 6 is refused with 403 `insufficient permissions`; the switch is done by the company
administrator in the browser, who holds `ApprovalRulesManage` for the tenant.

The reason is required: without it, or with an empty one, the call answers 422 `invalid_reason`. Switching a
rule back ON is the same call with `"four_eyes": true` and its own reason. A rule is a step of an ACTIVE
definition, and the stock definitions activate on their first use (step 14), so issue one opening and one
quick count first; until those definitions are active the call answers 422 `not_a_four_eyes_step`.

**The opening rule stays a separate choice.** D-164 decides the count, not the opening. A one-administrator
tenant either gets a second administrator who approves the opening, or switches the opening rule OFF with its
own reason (its own `approval_rule.changed` entry). The default is ON.

**Check:** the Approval rules screen shows the chosen state; with two administrators, the opening is approved by
the second one in My Tasks. The approver's `GET /api/v1/modules/stock/approval-access` answers 200 with
`can_approve: true`; the storekeeper gets 403.

The audit log (`GET /api/v1/audit`, permission `AuditRead`) carries one `approval_rule.changed` entry for the
switch (resource type `approval_rule`, before `four_eyes: true`, after `four_eyes: false`, with the reason), and
one `task.self_approved` entry with the note "self-approved, four-eyes off" for every document the same person
then approves.

The readiness report shows the value of every rule. Run it after the first opening and the first quick
count (their definitions are active then, step 14) and after the switch:

```
bin/letflow eval 'Letflow.Release.tenant_onboarding_check("<slug>", host: "<host>", tenant_type: "production")'
```

The `four-eyes` line is the one to read. With the count rule OFF and the opening rule ON it reads:

```
INFO four-eyes on=1 off=1 steps=stock_opening.approve=on,stock_quick_count.approve=off
```

With the opening rule OFF as well it reads `INFO four-eyes on=0 off=2
steps=stock_opening.approve=off,stock_quick_count.approve=off`. In the JSON form (`format: :json`) the same
value is in the check named `four-eyes`, with `status` `info`. The line is information: the report does not
turn RED when a rule is ON, so read it by eye. Making the count rule a readiness gate (an expected value that
turns the report RED) is a small product change, not built yet; the operator queues it as a follow-up.

**Rollback:** change the rule; documents already posted stay posted.

### Step 21. Cutover rules

**Who:** company administrator, infra and the Qoimeks team (migration plan, section 6).

**Do:**

1. The phones get the NEW server address `sss.ai-letflow.com`, so old queues cannot post: the old app 0.1.3
   refuses queued entries made for another server address.
2. EMPTY the offline queue and fully restart the app BEFORE the cutover.
3. Check one known-item post on the History screen.
4. Test barcode or QR scan in training, before the go.
5. The old-address integer ids (sku, location, movement) are assigned from 1 on first use, in the order of the
   first catalog read. They are NOT the old Qoimeks ids; legacy ids are not possible (the CSV extract has none).
6. Phones refetch the catalog at every app start.

**Check:** a phone at the new address shows the catalog; its offline queue is empty; the known-item post
appears on the History screen with the expected quantity.

**Rollback:** point the phones back at the old address only while nothing was posted at the new one.

### Step 22. Infra-only items

**Who:** infra only.

**Do:** hostnames, certificates, `LETFLOW_PUBLIC_BASE_URL`, the shared-access environment setting plus the app
recreate (step 9), and the voice environment setting: one key for all tenants, not one per tenant.

**Check:** `/health` is back after each recreate; `https://<host>` answers with a valid certificate.

**Rollback:** restore the env file backup.

### Step 23. Go or no-go page

**Who:** infra (release console), owner reads.

**Do:** run the read-only check report of T-2257 and file its output with the go record. It is the go/no-go
page: it does not replace step 8 (`tenant_onboarding_check`), it adds the first-use checks of steps 14 to 19.

**Check:** the report shows no failing line; any failing line is a no-go until fixed.

**Rollback:** none needed (read-only).

## Browser setup by the company administrator

PM 2026-11-20 (T-2404). The two switches below are done in the browser: their routes
(`PUT /api/v1/approval-rules/...` and `PUT /api/v1/ledger-settings/...`) accept only a person signed in with
OIDC, so the setup token of step 6 is refused (403). They are steps 19 and 20 of this page, written as a click
path. Who signs in is decided by the PM in the go summary; the account must be a TENANT_ADMIN of the tenant (the
company administrator, or the setup administrator before handover; never PLATFORM_ADMIN). Do this after the
first opening and the first quick count (their definitions are active then, step 14). Screen labels are the
shipped ones (catalogs `approvalRulesMessages.ts` and `ledgerSettingsMessages.ts`); the Kazakh wording is a
machine draft and is not repeated here.

### 1. Sign in

Open `https://<host>` and sign in as the company administrator. The menu group "Tenant administration" /
«Администрирование организации» holds both screens.

### 2. Count rule OFF (owner decision D-164)

1. Open `/admin/approval-rules`: title "Approval rules" / «Правила утверждения».
2. In the list, columns "Document type" / «Тип документа», "Step" / «Шаг», "Different person" / «Другой человек»,
   find the row `stock_quick_count`, step `approve` ("Approval" / «Утверждение»). The pill shows "On" /
   «Включено» before the change. Click the row; the panel on the right opens.
3. Switch OFF "Require a different person to approve" / «Требовать утверждения другим человеком». The warning
   "One person will be able to issue and approve" / «Один человек сможет оформлять и утверждать» appears.
4. In the box "Reason" / «Причина» type EXACTLY, on one line (a line break is refused):

   ```
   Client 1, storekeeper counts from the phone, one administrator, owner decision D-164
   ```

   This is the exact text decided by the owner and the PM (D-164); the same text is used in step 20 and pinned by
   the runbook tests.
5. Click "Save" / «Сохранить». The toast "Approval rule saved" / «Правило утверждения сохранено» appears.

With the count switch OFF the storekeeper's count posts at once on the phone and on the web. The count shows as posted, not pending; a count issued while the rule was ON stays pending until an administrator approves it (T-2410).

**Read-back:** (a) the row shows "Off" / «Выключено»; the panel shows the rule text "The issuer may approve their
own document..." and "Last change": your name, the time, "Reason: ..." / «Причина: ...». (b) Reload the page
(F5): the row is still Off with the same reason, and `GET /api/v1/approval-rules` (the approver's own browser
session, or the screen) shows `four_eyes` false for `stock_quick_count / approve` with the reason. (c) The audit
(`GET /api/v1/audit`, `AuditRead`) has one `approval_rule.changed` entry with before `four_eyes: true`, after
`four_eyes: false` and the reason. (d) The readiness report line `INFO four-eyes on=1 off=1
steps=stock_opening.approve=on,stock_quick_count.approve=off` (step 20).

### 3. Negative balances (decision 0090, runbook step 19)

1. Open `/admin/ledger-settings`: title "Negative balances" / «Отрицательные остатки».
2. Find the row "Stock" / «Запасы». Its pill is "Refused" / «Запрещено» (the default: no row means refuse).
3. Owner's choice for Client 1: **allow** (`allow_negative` ON), as step 19 states. If the owner has not
   confirmed it for the go, leave the row "Refused" and write "owner to decide" in the go record: the default is
   safe and nothing breaks.
4. Click "Allow" / «Разрешить». The dialog "Allow negative balance: Stock" / «Разрешить отрицательный остаток:
   Запасы» shows "What changes" / «Что изменится»: issues larger than the balance will be posted and the balance
   shown below zero. Read it to the owner or the administrator.
5. Type the "Reason" / «Причина» (one line, 1 to 500 characters of plain text), for example
   `Client 1 (Smart Security Systems): negative balances allowed, owner decision`, then "Save" / «Сохранить». The
   toast "The setting was saved." / «Настройка сохранена.» appears.

**Read-back:** the pill shows "Allowed" / «Разрешено»; "Last change" shows your name and time, and "Reason" your
text; after a reload (F5) the same; `GET /api/v1/ledger-settings` shows `allow_negative` true for `stock`, with
`changed_by_name` and `reason`; the audit has the matching ledger-setting entry. Switching back is the "Refuse" /
«Запретить» button with its own reason.

### 4. Opening rule `stock_opening / approve`: owner decision pending

The opening rule is NOT decided (D-164 decides the count only). Leave the row `stock_opening` / `approve` ON
until the owner decides: with ON and one administrator the opening cannot be confirmed alone (a second
administrator approves it in My Tasks). To switch it OFF later, use the same click path as in part 2 on that row,
with its own reason; it writes its own `approval_rule.changed` entry. Record "opening rule: owner to decide" in
the go summary.

### 5. Nothing to set

| Item | Setting | What to do |
|---|---|---|
| Default location | per item, set by the item import (step 10) | Nothing to set in the browser: there is no tenant-wide default location. |
| Document numbering | the types are registered on install of the stock module; the first number is 1 per year | Nothing to set: history stays in the old Qoimeks; check that the first document of the year has number 1 (step 19). |
| Timezone | the tenant default is `Asia/Almaty` | Nothing to set: a different zone is changed only if the company asks for one. |

**Rollback:** switch each setting back in the same screen with a new reason; documents already posted stay posted.

## Rollback summary

| Step | How to undo | What cannot be undone |
|---|---|---|
| 2, 3 | delete the realm or users (before step 4) | nothing |
| 4 | deactivate the tenant | the slug and the realm id stay reserved |
| 5 | `DELETE .../hostname` | nothing |
| 6 | revoke the token | nothing |
| 7 | none | installed modules |
| 9 | `DELETE` the access, remove the slug from the setting | nothing |
| 10 | the rollback step of the rehearsal runbook | posted documents |

The last-resort whole undo (database restore from step 1 plus realm delete) is infra's and needs the owner's decision.

## Owner decisions this procedure needs

- The production go (D-086, D-019 item 9).
- O-016: production Keycloak, DNS, and who holds the platform login.
- O-015: staff accounts and the channel for temporary passwords.
- Shared stock access in production and its direct-grant window (step 9).
- Four eyes for the company: the count rule is decided (OFF, owner decision D-164, step 20); the opening rule
  is the company's own choice (step 20).
- That an operator-held setup account is used until handover (step 3).

## Notes: the demo provisioner and requested names (option C)

Decision: the provisioner keeps its derived names; no requested slug or realm for demo tenants. Reasons:

1. `sss` needs no provisioner: `POST /api/v1/tenants` already takes slug, realm and type.
2. The derived `t-<hex>` slug and realm are what make a replay of the same `tenant_id` idempotent (decision 0072 D3)
   and what the sign-in check relies on before realm users may be created.
3. A requested name on the front-door path adds squatting, collision and reserved-name handling for untrusted
   sign-up input.
4. Promoting a demo tenant to production in place is a different question (tier, expiry, purge rules) and would be
   its own design.

Revisit only if the owner wants demo-to-production promotion.
