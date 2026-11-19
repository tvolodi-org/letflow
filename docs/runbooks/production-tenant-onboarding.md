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
and four-eyes are information, not readiness gates.

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
`https://<host>/qoimeks/<slug>/catalog` answers 401 without the value and 200 with it; scope enforcement is off.

**Rollback:** `DELETE /api/v1/identity/shared-stock-access`, and remove the slug from the setting.

### Step 10. Data load for a migration

**Who:** setup administrator, Qoimeks team, infra.

**Do:** follow `docs/runbooks/qoimeks-rehearsal.md` with the setup token (write freeze first, then its steps), with
its "Minimum master data by API" first. The two OIDC-only switches (negative opening balances, four eyes for a
one-person company) are set on the Ledger settings and Approval rules screens; the four-eyes choice is the
company's and the owner's. Production only after the same extract passed on the QA rehearsal tenant.

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
- Four eyes for the company (step 10).
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
