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

Users import: the xlsx users import is available (REQ-791: template download, dry run, up to 200 rows per import; the server part merged in #4138). It may be used instead of adding users one by one. Sign-in of imported users depends on REQ-788/789 (task T-1632, in review); that part stays pending until it is merged.

Roles: no pilot user gets `PLATFORM_ADMIN`; platform authority belongs to the platform tenant only (`docs/roles.md`). `docs/roles.md` has no accountant role, so the accountant's role is an open owner question.

## Week 2

Opening balances are loaded and checked against the company's own lists.

| Who | Does | Module | Where | Source |
|---|---|---|---|---|
| storekeeper | Loads stock opening lines, dry_run first | `stock` | Admin > Import data | `docs/roles.md` (STOREKEEPER: registered import function, opening lines) |
| company administrator | Loads asset cards, dry_run first (only if assets are installed) | `assets` | Admin > Import data | `docs/assets/asset-xlsx.md`, section 1 |
| company administrator | Loads asset opening lines, dry_run first, after the cards | `assets` | Admin > Import data | `docs/assets/asset-xlsx.md`, section 5a |
| accountant | Checks the loaded stock totals against the company's own lists | `stock` | admin/stock/balances | this file, What to measure (M2) |
| accountant | Checks asset balances against the company's own list (only if assets are installed) | `assets` | Assets balances | `docs/assets/asset-xlsx.md`, section 7 |

## Week 3

The storekeeper starts the daily work and the first count.

| Who | Does | Module | Where | Source |
|---|---|---|---|---|
| storekeeper | Enters the daily stock documents | `stock` | admin/stock/documents | stock help topic `documents` |
| storekeeper | Runs the first stock count | `stock` | admin/stock/counts | stock help topic `counts` |
| storekeeper | Prints the forms of documents and counts | `stock` | admin/stock/documents, admin/stock/counts | stock help topics `documents`, `counts` |
| company administrator | Reads the audit log | none | Admin > Audit | `docs/guides/tenant-admin/en.md`, section 6 |

## Week 4

The storekeeper repeats the count; the three people review the month.

| Who | Does | Module | Where | Source |
|---|---|---|---|---|
| storekeeper | Runs the second stock count | `stock` | admin/stock/counts | stock help topic `counts` |
| accountant | Takes the measures of What to measure | none | see What to measure | this file, What to measure |
| company administrator | Takes the measures of What to measure | none | see What to measure | this file, What to measure |
| storekeeper, accountant, company administrator | Exit review together | none | this file, Exit criteria | this file, Exit criteria |

## Training

Texts are not copied here; each person reads the existing page in the language they prefer.

- Company administrator: `docs/guides/tenant-admin/ru.md`, `docs/guides/tenant-admin/kk.md`, `docs/guides/tenant-admin/en.md`.
- Storekeeper and accountant: the stock help pages, opened from the Help link (`web/src/components/help/HelpLink.tsx`, `web/src/modules/stock/help/StockHelpPage.tsx`). Topics: documents, balances, movements, counts.
- Who trains and when is an open owner question.

## Support questions

| Question | Read first |
|---|---|
| An import row is refused | `docs/guides/tenant-admin/en.md`, section 5 |
| A document cannot be posted | stock help topic `documents` |
| A count is frozen | stock help topic `counts` |
| A balance is hidden | stock help topic `balances`; `docs/guides/tenant-admin/en.md`, section 3 |
| Sign-in fails (about 5 wrong attempts lock the account for a few minutes, up to 15) | `docs/guides/tenant-admin/en.md`, section 8 |
| A printed form looks wrong | stock help topics `documents`, `counts` |
| A user does not see a menu item | `docs/guides/tenant-admin/en.md`, section 8 |

A question that these pages do not answer goes to the owner. Per D-116 (`docs/uat/ba-decisions/T-1605.md`, section 3) nobody is on call and there is no night service for a non-paying pilot.

## What to measure

No targets are set here; each measure is read where it already exists.

| Measure | Where it is read | Who reads it | When |
|---|---|---|---|
| M1 Rows imported and refused per import | Import report of Admin > Import data | company administrator | weeks 1 and 2 |
| M2 Opening balances loaded versus the company's lists | admin/stock/balances | accountant | week 2 |
| M3 Count result: differences found, posted or explained | admin/stock/counts | storekeeper, accountant | weeks 3 and 4 |
| M4 Documents entered without team help | admin/stock/documents | storekeeper | weeks 3 and 4 |
| M5 Users who signed in | Audit log (Admin > Audit) | company administrator | weeks 1 to 4 |
| M6 System health | Metrics page (`docs/guides/tenant-admin/en.md`, section 7) | company administrator | weeks 1 to 4 |

## Exit criteria

Yes/no list. Any number added later is a proposal, to be confirmed by the owner. The owner decides with the portfolio manager (D-063).

- [ ] Opening balances are loaded and the accountant confirmed the totals (M1, M2).
- [ ] A stock count was completed and the differences were posted or explained (M3).
- [ ] The storekeeper worked a week of documents without team help (M4).
- [ ] All pilot users can sign in (M5).
- [ ] No unresolved health problem on the Metrics page (M6).

## Open owner questions

1. Which company is the pilot, and what is the start date (Client 1, `docs/uat/ba-decisions/T-1600.md`)?
2. What is the accountant's role? `TENANT_AUDITOR` is a candidate, a UAT assumption, to be confirmed by the process owner; `docs/roles.md` has no accountant role.
3. Who trains the three people, and in which language?
4. What are the exit thresholds (numbers for the Exit criteria)?
5. How long does the pilot run after month one?
6. What does the company give before week 1 (xlsx files of locations, items and balances; names and e-mail addresses of users)?
7. Does the pilot wait for REQ-788/789 (T-1632, in review) before imported users sign in?
