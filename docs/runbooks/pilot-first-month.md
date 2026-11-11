# Pilot company: first month (plan, not started)

## Status

- No pilot company has been named by the owner. Qoimeks Client 1 waits (`docs/uat/ba-decisions/T-1600.md`, section 1, row d).
- Production is not approved (D-086). This plan is a document only.
- `docs/runbooks/qoimeks-rehearsal.md` stays prepared and is not started by this plan.
- The plan creates no tenant, account, server or DNS name, spends no money and contacts no one outside the team. The owner or the portfolio manager speaks to the company.

## Before week 1

Two things are done before week 1; their steps are not repeated here:

- the tenant has a realm and a first administrator: `docs/runbooks/onboarding-new-tenant-realm.md`, section "Ordered steps";
- the modules the pilot uses are switched on: `docs/guides/tenant-admin/en.md`, section 4 (Modules).

## Week 1

The company administrator signs in, creates the people and loads the lists the other weeks depend on.

| Who | Does | Module | Where | Source |
|---|---|---|---|---|
| company administrator | First sign-in | none | the sign-in page | `docs/guides/tenant-admin/en.md`, section 1 |
| company administrator | Adds the users one by one | none | Admin > Users | `docs/guides/tenant-admin/en.md`, section 2 |
| company administrator | Puts users into groups and gives roles: `TENANT_ADMIN` for the administrator, `STOREKEEPER` for the storekeeper, `TENANT_AUDITOR` only if the owner confirms it for the accountant (see Open owner questions) | none | Admin > Users | `docs/guides/tenant-admin/en.md`, section 3; `docs/roles.md` |
| company administrator | Imports locations, dry_run first | `locations` | Admin > Import data | `docs/runbooks/qoimeks-rehearsal.md`, step 3; `docs/guides/tenant-admin/en.md`, section 5 |
| company administrator | Imports units of measure, dry_run first | `catalog_items` | Admin > Import data | `docs/runbooks/qoimeks-rehearsal.md`, step 3 |
| company administrator | Imports catalog items, dry_run first | `catalog_items` | Admin > Import data | `docs/runbooks/qoimeks-rehearsal.md`, step 3 |

Import order is locations, units of measure, catalog items, each with a dry_run before the real run, as in the rehearsal runbook.

Users import: the xlsx users import is available, server and screen (REQ-791: template download, dry run, up to 200 rows per import; the screen is at `admin/users/import`, for a user who may manage users, groups and roles). It may be used instead of adding users one by one. It creates the users only: an imported user has no identity-provider login yet, so being imported does not mean being able to sign in. How such a user gets a way to sign in is not decided (see "What the pilot administrator must not rely on yet" below and Open owner questions).

## What the pilot administrator must not rely on yet

| Do not rely on | State today | What to do instead |
|---|---|---|
| The "Send password reset instructions" button on the user page (REQ-789) | The reset route (REQ-788) and the button (REQ-789) are built; the button is hidden for users the route refuses, with a hint in plain words. The route refuses a user who has no identity-provider login, which includes every user made by the Users screen or by the xlsx import | Do not expect the button to work for these users; ask the owner, and do not promise them a self-service reset |
| Imported or hand-added users being able to sign in | Not settled: such users are created without a password and without an identity-provider login | Use the interim path below ("Interim sign-in path for created users"). It is option (a) of `docs/design/REQ-801-sign-in-for-created-users.md`; observe each pilot user signing in once (M5) and report any who cannot to the owner before week 1 ends |
| The platform operator's screen for module rollouts | The screen is built (`/admin/module-rollouts`) and is for the platform operator only; the pilot administrator does not see it | Ask the owner to arrange any module update; the pilot administrator has no action here |

Second caveat on M5: a user who has been seen signing in may still be a duplicate. If a person's identity-provider account has the same e-mail as a user made by the Users screen or the import but a different username, the first sign-in creates a second user row and the first row keeps the roles. If the usernames are equal, the sign-in is refused with HTTP 403 `username_in_use` and the message "This username already belongs to another account in this company. Ask your administrator." Either way, after the sign-in, check on the Users screen that the person appears once and has the expected roles, and report any other result to the owner (`docs/design/REQ-801-sign-in-for-created-users.md`, section "What happens at first sign-in to an existing row").

Roles: no pilot user gets `PLATFORM_ADMIN`; platform authority belongs to the platform tenant only (`docs/roles.md`). `docs/roles.md` has no accountant role, so the accountant's role is an open owner question.

## Interim sign-in path for created users

Decided: the portfolio decision D-118 (1), taken under D-086 on the owner's answer "Accept all recommendations" and recorded in the portfolio `DECISIONS.md` (not in this repository), picks option (a) of `docs/design/REQ-801-sign-in-for-created-users.md` as the interim path. It stays until option (b) is built; nothing in Letflow changes for it. Option (b), Letflow side, is decided (`docs/migration/decisions/0072-tenant-provisioner-realm-per-tenant-on-qa.md`, section 8b, settings `LETFLOW_REALM_USERS_*`) but no code for it is on main yet, and it needs a provisioner call from infra. It covers QA and the pilot only; production is not approved (D-086). Anything inside the realm is done by a Keycloak operator (infra), never by Letflow (`docs/migration/decisions/0072-tenant-provisioner-realm-per-tenant-on-qa.md` D1).

Why it is needed: a user made by the Users screen or the xlsx import has no identity-provider login, and no code path creates one (the design note, section "Today").

Steps, per pilot user:

1. The company administrator adds the user in Admin > Users (or by the xlsx import) with the person's real e-mail address. The e-mail is what the sign-in page uses to find the company (login directory, written when the user is created).
2. The company administrator sends the operator the list: name, e-mail, language. The administrator sends no password and no role through this list.
3. A Keycloak operator creates the account in the company's realm by hand, as in step R2 of `docs/runbooks/onboarding-new-tenant-realm.md`: the e-mail is set and marked VERIFIED, and a temporary password is set (the required action `UPDATE_PASSWORD` makes the person choose their own at first sign-in). The username is the e-mail address unless the operator is told otherwise (see "Collision" below). The operator does not map `PLATFORM_ADMIN` or any Letflow role in the realm for a pilot user; roles are given in Letflow (step 6).
4. The operator tells the company administrator the temporary password through the channel the owner approves (open question 8); the administrator hands it to the person, face to face or by phone, not by a mail that also names the user. A temporary password is never written in a ticket, chat log, runbook or git.
5. The person signs in once while the administrator watches (M5) and sets their own password.
6. The administrator opens Admin > Users and checks that the person appears once and has the expected groups and roles. Case (ii) of the design note applies: when the realm username differs from the username of the row the administrator made, the first sign-in creates a second row and the first row keeps the roles, so the roles must be given to the row that the sign-in made, and the first row is retired. When the usernames are equal the sign-in is refused with HTTP 403 `username_in_use` and a message that tells the person to ask their administrator (case (i)); do not retry, give the person a realm username that differs from the existing row, or resolve the duplicate on the Users screen, and report it to the owner if it persists.

Collision: nothing here changes the first-sign-in rules (`docs/design/REQ-801-sign-in-for-created-users.md`, "What happens at first sign-in to an existing row"). The equal-username refusal is already in plain words (403 `username_in_use`, `Letflow.Plugs.AuthPipeline`).

Limits of the interim path:

- One manual operator step per person; 30 people means 30 steps. Group them in one operator session.
- A forgotten password: the "Send password reset instructions" button (REQ-789) is hidden for these users until they have an identity-provider login. After their first sign-in they are `:oidc` users and the reset link on the sign-in page works (`docs/guides/tenant-admin/en.md`, section 8). Before it, the operator sets a new temporary password.
- Leaving the company: the administrator retires the user in Letflow; removing the realm account is the operator's step. Tell the operator.
- Nobody is on call (D-116); ask the operator for batches, not for same-hour service.

### The created-user sign-in flag (option b) stays OFF

Option (b) of the design note (Letflow asks infra's provisioner to create the sign-in of a user made on the Users screen) is controlled by `LETFLOW_REALM_USERS_ENABLED`. It is on only when set to exactly `true`; unset or empty means OFF, any other value stops boot, and it is OFF for the pilot (decision `docs/migration/decisions/0072-tenant-provisioner-realm-per-tenant-on-qa.md`, section 8b; QA only, production is not approved). Two more settings, `LETFLOW_REALM_USERS_PROVISIONER_URL` and `LETFLOW_REALM_USERS_PROVISIONER_TOKEN`, go with it and are set together or not at all. Turning the flag on is the owner's decision, after infra publishes the provisioner call; this runbook does not do it.

While it is OFF, an administrator who tries to create a sign-in for a user (`POST /users/:id/sign-in`) gets 409 `sign_in_creation_off`, shown as a "not available" refusal, and the user row is unchanged. It is not a fault and not to be retried. Tell the administrator to use the interim path (a) above: it stays the pilot path until the owner switches the flag on.

### Question list for the pilot's 30 users

Answer before week 1. None is answered here.

1. Who is the Keycloak operator for the pilot realm, and do they accept 30 hand-made accounts (about 30 steps)?
2. The company's list: for each of the 30 people, the real e-mail address, display name and preferred language (ru, kk, en). Does every person have their own address (shared mailboxes break the sign-in directory)?
3. Which of the 30 need which role or group (`docs/roles.md`)? Which three are the administrator, storekeeper and accountant (open question 2)?
4. Do all 30 sign in from the start, or only the three named roles in week 1 and the others later?
5. Who hands out the temporary passwords, and through which channel (open question 8)?
6. Is it acceptable that the first sign-in makes a second user row (case ii) and the administrator moves the roles to it, or does the owner want the collision fixed before week 1?
7. Which username form do we use in the realm (the e-mail address, or the username written in Letflow)? Equal usernames are refused (case i); different ones make a second row (case ii).
8. Is the operator's step acceptable beyond QA? If the pilot becomes production, the owner decides again; production is not approved.
9. How long may a person wait for the operator after the administrator adds them (a stated time, no night service)?
10. When option (b) is built, how are the 30 accounts moved to it? Not needed for week 1.

## Week 2

Opening balances are loaded and checked against the company's own lists.

| Who | Does | Module | Where | Source |
|---|---|---|---|---|
| storekeeper | Loads stock opening lines, dry_run first | `stock` | Admin > Import data | `docs/roles.md` (STOREKEEPER: registered import function, opening lines) |
| company administrator | Loads asset cards, dry_run first (only if assets are installed) | `assets` | Admin > Import data | `docs/assets/asset-xlsx.md`, section 1 |
| company administrator | Loads asset opening lines, dry_run first, after the cards | `assets` | Admin > Import data | `docs/assets/asset-xlsx.md`, section 5a |
| accountant | Checks the loaded stock totals against the company's own lists | `stock` | admin/stock/balances | `docs/guides/tenant-admin/en.md`, section 3 (balance visibility); `web/src/modules/stock/help/stockHelpMessages.ts` (topic `balances`) |
| accountant | Checks asset balances against the company's own list (only if assets are installed) | `assets` | Assets balances | `docs/assets/asset-xlsx.md`, section 7 |

## Week 3

The storekeeper starts the daily work and the first count.

| Who | Does | Module | Where | Source |
|---|---|---|---|---|
| storekeeper | Enters the daily stock documents | `stock` | admin/stock/documents | `web/src/modules/stock/help/stockHelpMessages.ts` (topic `documents`) |
| storekeeper | Runs the first stock count | `stock` | admin/stock/counts | `web/src/modules/stock/help/stockHelpMessages.ts` (topic `counts`) |
| storekeeper | Prints the forms of documents and counts | `stock` | admin/stock/documents, admin/stock/counts | `web/src/modules/stock/help/stockHelpMessages.ts` (topics `documents`, `counts`) |
| company administrator | Reads the audit log | none | Admin > Audit | `docs/guides/tenant-admin/en.md`, section 6 |

## Week 4

The storekeeper repeats the count; the three people review the month.

| Who | Does | Module | Where | Source |
|---|---|---|---|---|
| storekeeper | Runs the second stock count | `stock` | admin/stock/counts | `web/src/modules/stock/help/stockHelpMessages.ts` (topic `counts`) |
| accountant | Re-checks the stock balances for the month review (M2, M3) | none | admin/stock/balances, admin/stock/counts | `docs/guides/tenant-admin/en.md`, section 3 |
| company administrator | Reads the Metrics page and the import reports for the month review (M1, M5, M6) | none | Metrics page, Admin > Import data | `docs/guides/tenant-admin/en.md`, section 7 |
| storekeeper, accountant, company administrator | Exit review together | none | Admin > Audit, admin/stock/counts | `docs/uat/ba-decisions/T-1605.md`, section 3 (D-116, owner decides) |

## Training

Texts are not copied here; each person reads the existing page in the language they prefer.

- Company administrator: `docs/guides/tenant-admin/ru.md`, `docs/guides/tenant-admin/kk.md`, `docs/guides/tenant-admin/en.md`.
- Storekeeper and accountant: the stock help pages, opened from the Help link (`web/src/components/help/HelpLink.tsx`, `web/src/modules/stock/help/StockHelpPage.tsx`). Topics: documents, balances, movements, counts.
- Who trains and when is an open owner question.

## Support questions

| Question | Read first |
|---|---|
| An import row is refused | `docs/guides/tenant-admin/en.md`, section 5 |
| A document cannot be posted | `web/src/modules/stock/help/stockHelpMessages.ts` (topic `documents`) |
| A count is frozen | `web/src/modules/stock/help/stockHelpMessages.ts` (topic `counts`) |
| A balance is hidden | `web/src/modules/stock/help/stockHelpMessages.ts` (topic `balances`); `docs/guides/tenant-admin/en.md`, section 3 |
| Sign-in fails (about 5 wrong attempts lock the account for a few minutes, up to 15) | `docs/guides/tenant-admin/en.md`, section 8 |
| A printed form looks wrong | `web/src/modules/stock/help/stockHelpMessages.ts` (topics `documents`, `counts`) |
| A user does not see a menu item | `docs/guides/tenant-admin/en.md`, section 8 |

A question that these pages do not answer goes to the owner. Per D-116 (`docs/uat/ba-decisions/T-1605.md`, section 3) nobody is on call and there is no night service for a non-paying pilot.

## What to measure

No targets are set here; each measure is read where it already exists.

| Measure | Where it is read | Who reads it | When |
|---|---|---|---|
| M1 Rows imported and refused per import | Import report of Admin > Import data | company administrator | weeks 1 and 2 |
| M2 Opening balances loaded versus the company's lists | admin/stock/balances | accountant | week 2 |
| M3 Count result: differences found, posted or explained | admin/stock/counts | storekeeper, accountant | weeks 3 and 4 |
| M4 Documents entered in the week, and whether the storekeeper says they needed team help (the storekeeper answers yes or no) | admin/stock/documents for the count; the storekeeper's own answer for the help | storekeeper | weeks 3 and 4 |
| M5 Users who signed in: each pilot user signs in once on the sign-in page while the administrator watches, and the administrator ticks the name | Observed sign-in on the sign-in page (the audit log records user creation, not sign-in) | company administrator | weeks 1 to 4 |
| M6 System health | Metrics page (`docs/guides/tenant-admin/en.md`, section 7) | company administrator | weeks 1 to 4 |

## Exit criteria

Yes/no list. Any number added later is a proposal, to be confirmed by the owner. The owner decides with the portfolio manager (D-063).

- [ ] Opening balances are loaded and the accountant confirmed the totals (M1, M2).
- [ ] A stock count was completed and the differences were posted or explained (M3).
- [ ] The storekeeper worked a week of documents and said no help from the team was needed (M4).
- [ ] Every pilot user was observed signing in (M5).
- [ ] No unresolved health problem on the Metrics page (M6).

## Open owner questions

1. Which company is the pilot, and what is the start date (Client 1, `docs/uat/ba-decisions/T-1600.md`)?
2. What is the accountant's role? `TENANT_AUDITOR` is a candidate, a UAT assumption, to be confirmed by the process owner; `docs/roles.md` has no accountant role.
3. Who trains the three people, and in which language?
4. What are the exit thresholds (numbers for the Exit criteria)?
5. How long does the pilot run after month one?
6. What does the company give before week 1 (xlsx files of locations, items and balances; names and e-mail addresses of users)?
7. How does a user made by the Users screen or the xlsx import get a way to sign in? The reset route (REQ-788) and its button (REQ-789) are built, but the route refuses users without an identity-provider login. Does the pilot wait for the answer (`docs/uat/ba-decisions/T-1651.md`, item 1)?
   Interim answer (D-118 (1)): option (a), a Keycloak operator creates each account by hand; see "Interim sign-in path for created users". The final route (option (b) or later) is still open.
8. Through which channel does the operator give the temporary passwords to the company administrator?
