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
| Imported or hand-added users being able to sign in | Not settled: such users are created without a password and without an identity-provider login | Observe each pilot user signing in once (M5) and report any who cannot to the owner before week 1 ends. The options are written down in `docs/design/REQ-801-sign-in-for-created-users.md`; the owner has not chosen one |
| The platform operator's screen for module rollouts | The screen is built (`/admin/module-rollouts`) and is for the platform operator only; the pilot administrator does not see it | Ask the owner to arrange any module update; the pilot administrator has no action here |

Second caveat on M5: a user who has been seen signing in may still be a duplicate. If a person's identity-provider account has the same e-mail as a user made by the Users screen or the import but a different username, the first sign-in creates a second user row and the first row keeps the roles. If the usernames are equal, the sign-in is refused with an internal error. Either way, after the sign-in, check on the Users screen that the person appears once and has the expected roles, and report any other result to the owner (`docs/design/REQ-801-sign-in-for-created-users.md`, section "What happens at first sign-in to an existing row").

Roles: no pilot user gets `PLATFORM_ADMIN`; platform authority belongs to the platform tenant only (`docs/roles.md`). `docs/roles.md` has no accountant role, so the accountant's role is an open owner question.

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
