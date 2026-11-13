# Owner gate review, November 2026

Written 2026-11-13 by the business analyst (task T-1845, PM decision D-128 part 2). This page is for the
portfolio manager (PM). The PM walks the owner through it. Nothing here was sent to the owner, and nothing was
changed on QA, production, the demo, secrets, DNS, the public repo or money.

It replaces the snapshot `docs/status/owner-questions-2026-11.md` (2026-11-11) for the walk. That page stays as it
is. Every row of it was checked again against main and the owner decisions D-097 to D-130. Rows the owner has
already answered are in section 9 ("Already answered"). They are not asked again.

How to read the tables:
- **Look at** = something to open and check. **Answer** = a question for the owner.
- **Our recommendation** = what the team suggests. The owner may choose otherwise.
- **Time** = owner minutes. All times are guesses.
- **V** = verified today by reading the file or commit on main (`687f4242b`) or the decision text.
  **G** = guess, or a fact not checked today.
- Where a role is needed, the page says what the person does. The tenant configures who that is.

## 1. Short version

- About **2 h 40 min** of owner time in total (guess). Two sittings work best (section 10).
- **Must answer before the next build step:** the six role choices (item N1), the voice key line (D2), and the
  production questions (F1), if production is the next step.
- **Only looking, no answer:** gates C, D and E. They need a QA walk.
- Everything else is a quick yes/no on our recommendations, or can wait.

## 2. Gate A (done)

| # | What it is | Status | V/G |
|---|---|---|---|
| A | Shared master data: org tree, locations, employees, codes, units, items, lots, xlsx import | Passed. Tasks T-1047 and T-1128 are closed. Nothing to do. | V |

## 3. Gate B (done)

| # | What it is | Status | V/G |
|---|---|---|---|
| B | Stock register, stock documents and counts | Passed on 2026-11-05 (D-101), after one rework wave (D-098). Task T-1053 is closed. Nothing is open. The five screen wishes of D-105 were marked "not urgent". They do not block anything. | V |

## 4. Gate C (held): asset register

Gate task T-1058. The phase has been built. Only the owner's walk is missing.

**What is on main (V):** module `assets` version 0.16.0 (`lib/letflow/modules/assets/assets.ex`). It has:
- asset cards for fixed assets, low-value items and intangible assets;
- the commission, change of responsible, hand over, write off, change of kind and asset opening documents;
- reversal, balances as of a date, movements, and xlsx import and export;
- depreciation shown on the card (#4080);
- search and paging of the card list on the server (#4320).

New since the walk text was written (V): the tenant administrator can switch on "the storekeeper reads and posts
assets" for the tenant. The switch is on the Groups page (`/admin/groups`), built in #4108 / T-1570. A tenant that
already existed starts with the switch **off**. A tenant that installs the module from now on starts with it on.

New spec, not built (V): the fixed asset count (official form Inv-8). The spec is `docs/assets/asset-count.md`,
requirements REQ-816 to REQ-822. The owner closed question A2 with D-128. Nothing needs answering. The owner looks at
it after it is built.

| # | What it is | Look at or answer | Our recommendation | Time | Blocked until done | V/G |
|---|---|---|---|---|---|---|
| C1 | The asset walk on QA | **Look at:** QA app `https://qa.bizdala.com/login?realm=gate-b5`. Sign in as the tenant administrator. Follow "GATE C" steps 1 to 8 of `project/walkthrough-gates-cde.md` (team repo). The menu has Asset cards, Asset documents, Asset balances and Asset movements (`/admin/assets/cards`, `/documents`, `/balances`, `/movements`). | Walk it. One change to step 7: the storekeeper now sees no assets **until the administrator switches it on** on `/admin/groups`. Switch it on and check that the storekeeper can read and post assets but cannot reverse or write cards. | 30 | Closing gate C (T-1058). | V (paths, switch). G: whether gate-b5 still is the live tenant and has `assets` 0.16.0. The walk text says 0.9.0 was installed on 2026-11-08. |
| C2 | Prepare the tenant (for the PM, not the owner) | Before the walk, the operator checks that gate-b5 runs the newest module versions. A tenant on an old version refuses writes until it is upgraded. | Operator task, done before the owner sits down. | 0 | C1 | G |
| C3 | Fixed asset count (Inv-8) | Nothing now. | Look at it when slices K1 onward are built and on QA. | 0 | - | V |

## 5. Gate D (held): phone and voice

Gate task T-1062.

**What is on main (V):**
- voice service and routes (`lib/letflow/voice/`, `lib/letflow/modules/stock/voice_*.ex`);
- the 20-phrase regression check (`docs/runbooks/stock-voice-regression.md`);
- phone count screens and movement drafts in the app (`apps/mobile/lib/features/stock/`);
- camera scan of codes;
- the PWA build of the same app: sign-in, offline queue, scanner and voice on Safari, HTTPS packaging (M1 to M5);
- the client test kit (`docs/runbooks/pwa-client-test/`).

Voice is **off** on QA until the speech and model keys are set (`docs/runbooks/stock-voice.md`). While it is off,
the voice draft answers "speech off". Typing and scanning still work.

| # | What it is | Look at or answer | Our recommendation | Time | Blocked until done | V/G |
|---|---|---|---|---|---|---|
| D1 | The phone walk | **Look at:** an Android phone with the app, or the PWA in a phone browser. Follow "GATE D" steps 1 to 3 of `project/walkthrough-gates-cde.md`: count screens (list, scan, typed quantity, surplus line, close) and movement drafts (receipt, issue, write off, transfer, hand over, return). | Walk it on the phone you have. Pass if you can make a draft of each kind. If voice is off, the microphone button should say so in plain words. | 25 | Closing gate D (T-1062). | V (screens, steps). G: whether infra already serves the PWA on QA, and at which address. |
| D2 | Voice keys for QA | **Answer:** should voice be on for QA now? Infra may copy the Qoimeks speech keys to Letflow QA only after **your own line in the infra session**. This was decided in D-111 item 6 and D-092. Infra's handoff still says "key handoff pending the owner's own line". | Give the line now, QA only, if you want to hear voice during the walk. If not, pass gate D on typing and scanning, and add voice later. | 2 | Voice in D1 and in the nightly check with a real provider. | V (decision, infra handoff note) |

## 6. Gate E (held): paperwork, reports, labels, languages

Gate task T-1067. The owner postponed the printout check on 2026-11-08 (D-111 item 5).

**What is on main (V):**
- count paperwork as PDF in ru, kk and en, plus the Inv-* forms;
- printed hand-over documents with print buttons;
- the asset list as a saved report, created when the module is installed (`docs/assets/government-lists.md`, "Built (plan key E2b)");
- barcode and QR label printing (`lib/letflow/modules/codes/labels.ex`, screen `/admin/codes`);
- a ru and kk sweep of the web screens (#4285) and ru and kk default texts for the e-mails (#4341);
- a check of every printout against real paper, with 6 layout defects fixed (`docs/status/print-check-20261109.md`).

| # | What it is | Look at or answer | Our recommendation | Time | Blocked until done | V/G |
|---|---|---|---|---|---|---|
| E1 | The paperwork walk | **Look at:** same tenant as C1. Follow "GATE E" steps 1 to 5 of `project/walkthrough-gates-cde.md`. Steps: count order print and download (`/admin/stock/counts`, open an order); a transfer or hand-over document; the asset list report (`/entities/assets_card/reports`); label printing (`/admin/codes`); switch RU, then KK. | Do it in the same sitting as C1. The screens and tenant are the same. Take one label sheet and try it with a phone camera. | 25 | Closing gate E (T-1067). | V (paths, built parts). G: whether the codes and stock versions on gate-b5 are current (see C2). |
| E2 | Kazakh wording | **Answer:** who reads the Kazakh texts as a native speaker, and when? The team cannot judge them. Machine drafts are used until then. This is a UAT assumption (`docs/uat/ba-decisions/T-1706.md`). | One native speaker reads the asset and stock screens, Users, and the printouts in one sitting before the pilot starts. You choose the person. | 2 to answer. The check itself takes someone else about 1 to 2 h (G). | Calling the Kazakh text final. | V (source). G: the check's length. |

## 7. Gate F (held): production and the first customer

Gate task T-1070. Only specifications and runbooks are on main: `docs/runbooks/production-readiness.md`,
`docs/runbooks/pilot-rollout.md` and `docs/runbooks/pilot-first-month.md`. Nothing has been built for production yet.
The build task "sign-in per company" (T-1359) is held. The owner already answered the production host, the wildcard
name, data in Germany, simple backups and no night service (D-115 item 2, D-116 items 3 and 4). That is not asked
again.

| # | What it is | Look at or answer | Our recommendation | Time | Blocked until done | V/G |
|---|---|---|---|---|---|---|
| F1 | Five production questions (`production-readiness.md`, "Open owner questions" 2 to 6. Question 1 is answered by D-116: loss up to the last backup) | **Answer:** (a) How long may a restore take? (b) How long are backups kept, given that a deleted company's data stays in old backups until they expire? (c) Where does the production sign-in server run, and who holds its admin access? (d) Is a production provisioner approved, or are realms made by hand? (e) May the first administrator of a production company manage users in the sign-in server directly? | Our suggestions, not from a source (G): (a) one working day while no company pays; (b) 30 days, the same as the demo data period; (c) on the same production server, run by the infra agent, admin access for you only; (d) by hand until the first paying company, then decide; (e) no, as for demo tenants. Users are created through Letflow's "Create sign-in" button. | 10 | Production setup (infra) and the F1a build task. | V (questions). G (recommendations). |
| F2 | The pilot company | **Answer:** which company, which dealer, and which start date? Does the dealer get its own tenant, and what may it see? (`pilot-rollout.md` 1 and 2; `pilot-first-month.md` 1) | No recommendation. This is your business choice. | 5 | Every other pilot question (F3) and the F2a task. | V |
| F3 | Pilot details, asked together with the company | **Answer, with the company:** training (who, which language); exit numbers; length after month one; the data they give before week 1 (locations, items, balances, users); support hours; how they report a problem; data volumes; which printed forms come first. Sources: `pilot-first-month.md` 3 to 6; `pilot-rollout.md` 3 to 7. | Hold one call with the company and answer all of them there. Nothing is needed from you before the company is named. | 0 now (about 30 with the company, G) | The pilot plan of week 1. | V |
| F4 | Sign-in for the pilot's 30 users | **Answer, after F2:** do all 30 sign in from the start, or only three in week 1? Who passes on the one-time passwords, and by which channel? (`pilot-first-month.md`, list items 4 and 5; open question 8) | The administrator of the company creates each sign-in with the "Create sign-in" button and hands out the one-time password in person. This button is option (b): built in REQ-807 to REQ-809, behind a switch that is off, and waiting for infra's provisioner call. Three people in week 1, the rest in week 2. Most other questions on the 30-user list (hand-made accounts, username form, the second-row problem) fall away with option (b). | 3 | Week 1 of the pilot. | V (what is built). G: when infra delivers its part. |
| F5 | Sign-in per company (T-1359) | **Answer:** is one sign-in link per company (today: one sign-in server realm per company, D-016) enough for the pilot? | Yes, for the pilot. Build T-1359 (company look on the sign-in page, several legal entities) when a second company is live. D-126 already names it as a candidate for a closed extra. | 2 | T-1359 stays held. | V (facts). G (recommendation). |

## 8. Not tied to a gate

| # | What it is | Look at or answer | Our recommendation | Time | Blocked until done | V/G |
|---|---|---|---|---|---|---|
| N1 | Roles as tenant data: six choices from the architect's verdict (`docs/design/roles-architect-verdict.md`, "Owner choices that remain"; D-129: you wait for this verdict) | **Answer:** (1) Existing companies keep their ready-made roles as normal roles they may edit, or the roles are removed? (2) A new company starts with only its administrator, or with starter roles? (3) When a module update brings a new permission, do the company's own roles get it automatically? (4) May the company administrator let someone else manage users and roles? (5) Is "create your own roles" free or paid? (6) Any limit on roles per company? | (1) keep them; (2) only the administrator, starter roles copied from a list; (3) never automatically; (4) not now; (5) free; (6) no number now, needed before stage 3. All are the architect's recommendations, except (6), which the architect leaves to you. | 10 | Decision record T-1849 and every stage after stage 0 of the roles change. | V |
| N2 | Three product calls from the security follow-up (`docs/uat/ba-decisions/T-1695.md`, "Must wait") | **Answer:** (a) May the platform operator force a security update on a company, even inside the company's chosen upgrade window? (b) When the sign-up limit for a mail domain is reached, does the person see "limit reached", or the same neutral "check your mail" as always? (c) On the rollouts page, should Escape inside the module field close the whole detail? | Our suggestions, no source wrote one (G): (a) yes, after a notice to the company; (b) the neutral answer, so nobody can probe which domains exist; (c) no, Escape inside a field only leaves the field. | 5 | Fixes F4-2, F4-3 and one accessibility row. | V (questions). G (recommendations). |
| N3 | Paid CI capacity (`docs/status/ci-minutes-after-batch4.md`, "Owner decisions") | **Answer:** pay for bigger runners or more parallel jobs? | No, not now. The saving has not been measured, and the free cuts have been applied first. | 2 | Nothing urgent. | V |
| N4 | Public repo clean-up, the rest of the plan (`docs/uat/ba-decisions/T-1599.md` section 12. Q1 to Q4 and Q6 are answered by D-116 and D-118) | **Answer:** Q5: is it fine that the issues and PRs of the old repo become private with it? Q7: do the team template and lab stay private (the engine maybe published later)? Q8: rotate any live secret the audit finds, before stage 1? Q9: go for the last stage only after the trial period? | Yes to all four, as written in the plan. As decided in D-118, you are still told before the new public repo is created, before files are deleted, and before any force-push. | 3 | Stages 1 and 7 of the clean-up. | V |
| N5 | Offline install package signing (`docs/design/offline-package-signing.md`, section 9) | **Answer:** keep the written defaults until the first customer? These are: we hold the key; one release owner signs after green checks; the customer confirms the package by a phone read-out of its fingerprint; upgrade from the previous version only; a checked backup is required before install. | Yes. D-121 already says the real key place is decided at the first real customer. | 2 | Nothing now. The signature step is built later. | V |
| N6 | Rolling deploy (`docs/design/rolling-deploy.md`, section 9) | **Answer:** is "no downtime" a promise for production, or for QA and the demo only? And the four smaller rules: the migration check blocks the merge; no removal release before every company is upgraded; a short period of doubled rate limits during a roll is fine on QA; the operator and infra run the two-server test off hours. | QA first. Production after the two-server test. Yes to the four rules. | 3 | Slices R1 to R5 of that note. | V |
| N7 | Sign-up from the front door, QA only (`docs/status/owner-questions-2026-11.md` rows B1 to B12, item L-01) | **Answer only if you want public sign-up opened soon.** There are 12 questions: invitation code or open form, plans and prices, captcha, the company address form, terms text, the mail sender, erasure, mail language, default modules. | Can wait. If answered now, accept the three recommendations already written: (a) sign-up by invitation code, the limit of 30 demo tenants stays; (b) shared address with the company in the link; (c) new demo companies get assets, locations, codes and catalog items. Leave the others for when sign-up opens. | 0 (5 if answered now) | Opening the form to the public. | V (questions and the three recommendations). G: D-118 "accept all" may already cover them, but its list of eight does not name them, so they are treated as open. |
| N8 | MES | Nothing to answer now. A.1, A.2, A.4, A.6 and the phase 1 go are answered (D-124). The later items (recipe tolerance, keeping the "big bags" quantity, legal e-signature, rework, trace index) come up during phase 1 or from the plants' answers (`docs/design/mes/13-phase1-plan.md`, section 13). Sending the questionnaires is your own step (D-124). | - | 0 | - | V |
| N9 | On-premise delivery (`docs/design/on-premise-delivery.md`) | Nothing to answer now. The licence (MIT, D-127) and the key place (D-121) are settled. Section 6 has 16 questions for a plant's IT, in English and Russian. You hand them to a plant when one is in view. | - | 0 | Only the install for a plant. | V |
| N10 | Engine clean-up after Copilot (T-1459) | Nothing to answer. D-107 settled it. The operator releases the task when Copilot is used up. | - | 0 | - | V |

## 9. Already answered: do not ask again

| Item | Answer on record |
|---|---|
| Who signs the asset count, and the "accountant" question A2 | A configured role in the tenant's own setup. Nothing is fixed in code (D-128). |
| Sign-in for people created in Letflow (A7, A18) | Option (b) for QA; mail link later; the admin hands out a temporary password (D-118 item 1). Letflow side built behind a switch that is off (REQ-807 to REQ-809). Infra's part is still due (decision 0072 section 8b). |
| PWA stays signed in | 30 days with a PIN or device unlock (D-118 item 2). Built behind a switch that is off (REQ-811). |
| Android app or PWA | Keep both. Decide after real use (D-111 item 1). iPhone test by your clients (D-112). |
| Mail digest and notification settings | No digest until real mail sending is on (D-118 item 4). |
| Review step for asset documents | None in the pilot (D-118 item 3). |
| Storekeeper and assets | Reads and posts assets, switchable per tenant (D-097, D-115). Built (#4108). |
| Inventory number and currency | Unique per tenant; one currency per tenant, KZT by default (D-097). |
| Old assets | Come in through the asset opening document (D-111 item 2). |
| Government form layouts | Use the 2026 drafts now (D-104). |
| Document layouts and numbering | Prepared layouts (D-100); numbering postponed (D-099). |
| Licence and open core | MIT (D-116, D-127); a few closed extras behind sockets (D-126); access by permissions only (D-129). |
| Public repo clean-up, main choices | Classification, companion repo, new squashed public repo, `git-filter-repo` (D-118 item 6). |
| Production basics | New small server, wildcard name, data in Germany, simple backups, no night service (D-115 item 2, D-116). |
| Qoimeks cut-over | Client 1 moves only when the Letflow applications are ready (D-115 item 2). |
| MES | A.1 backfill, A.2 customer marker, A.4 decision record first, A.6 units and density, phase 1 go, MES open under MIT (D-122, D-124). |
| Signing key place | Any place for now; decide at the first customer (D-121). |
| Voice test phrases | Synthetic first (D-092, D-097). |

## 10. Total time and suggested order

| Order | Item | Owner minutes (G) |
|---|---|---|
| 1 | N1 roles (blocks the next roles build steps) | 10 |
| 2 | D2 voice key line (so voice can be tried in the walk) | 2 |
| 3 | Sitting 1 on QA: C1 assets walk, then E1 paperwork walk | 55 |
| 4 | E2 who checks Kazakh | 2 |
| 5 | Sitting 2: D1 phone walk | 25 |
| 6 | F1 production questions, F2 pilot company, F4, F5 | 20 |
| 7 | Quick yes/no list: N2, N3, N4, N5, N6 | 15 |
| 8 | Later: F3 with the company, N7 when sign-up opens | 0 now |
| | **Total** | **about 129 min**, plus about 30 min of slack for questions during the walks: **about 2 h 40 min** |

## 11. Sources

Opened today (V):
- In this repo: `docs/status/owner-questions-2026-11.md`; `docs/runbooks/production-readiness.md` and
  `pilot-rollout.md` ("Open owner questions", "Sign-in per company"); `docs/runbooks/stock-voice.md`,
  `mobile-web-pwa-hosting.md`, `mobile-web-pwa-ready-check.md`, `mobile-web-pwa-signin.md`;
  `docs/design/roles-architect-verdict.md` (verdict and owner table); `docs/design/tenant-defined-roles.md` section 10;
  `docs/design/open-core-sockets.md` sections 1.6 and 7; `docs/design/on-premise-delivery.md` sections 5 to 7;
  `docs/design/offline-package-signing.md` section 9; `docs/design/rolling-deploy.md` sections 9 and 10;
  `docs/design/mes/12-core-decisions-for-owner.md`; `docs/design/mes/13-phase1-plan.md` sections 2 and 13;
  `docs/assets/asset-count.md` (head, sections 8 and 9); `docs/assets/government-lists.md` (status lines);
  `docs/status/print-check-20261109.md` (head); `docs/status/ci-minutes-after-batch4.md` ("Owner decisions");
  `docs/uat/ba-decisions/T-1599.md` section 12, `T-1695.md`, `T-1809.md`, `T-1814.md` ("Must wait");
  `docs/uat/uat-sweep-2026-11-11.md`, `-11b.md`, `-12.md` (grep for owner items: none found);
  `lib/letflow/modules/assets/assets.ex` (version, storekeeper switch, settings); web routes in
  `web/src/modules/assets/assetsRoutes.tsx`, `web/src/modules/stock/stockRoutes.tsx`, `web/src/modules/codes/codesRoutes.tsx`,
  `web/src/router.tsx`, `web/src/pages/admin/GroupsPage.tsx`; `git log origin/main` for the commits named above.
- Outside this repo. The gate cannot open these, so the facts used are quoted in section 12: the team repo files
  `project/walkthrough-gates-cde.md`, `project/gate-c-walkthrough.md`, `project/phase-cdef-plan.md`,
  `project/gate-b-rework-findings.md`, `project/LINKS.md`; the task records T-1047, T-1053, T-1058, T-1062, T-1067,
  T-1070, T-1128, T-1359, T-1459, T-1599, T-1842, T-1844 (engine task list); the portfolio `DECISIONS.md` entries D-097 to
  D-130; the infra `HANDOFF.md`, line on D-092. Copies are in the task folder `state/tasks/T-1845/src/`.

Not re-read today (G where used): `docs/runbooks/pilot-first-month.md` (its rows are taken from the 11-11 sheet,
which quotes it); `docs/uat/ba-decisions/T-1677.md`, `T-1567.md`, `T-1651.md`, `T-1665.md`, `T-1706.md` (taken from the
11-11 sheet); `docs/migration/decisions/0072-*.md` section 8b; `docs/uat/gap-sidecar-audit.md`; the gate-b walk files
other than the rework findings; `docs/design/mes/` files 01 to 11; the QA server itself (no call was made, so the
tenant's module versions and the PWA address are not known).

Left out on purpose:
- The GAP sidecar groups (row D9 of the 11-11 sheet). Each needs an infra or roster step first. No owner answer is
  needed now.
- The dependency-audit items (`docs/status/dependency-audit-2026-11.md`). These are team tasks with a security review,
  not owner questions.
- The questions for a plant's IT (N9). They go to a plant, not to the owner.

## 12. Quoted outside sources (short, for the gate)

- Gate tasks (engine task list): T-1047 and T-1053 state `done`; T-1058, T-1062, T-1067 and T-1070 state `ready`,
  each "Manual step (D-063). All work stops. Close ... only when the owner says the phase is accepted." T-1128
  `done`. T-1359 "phase F F1b: Sign-in per company", `ready`, held by the operator. T-1459 "Engine cleanup: nothing calls
  Copilot", held "release when Copilot is drained".
- T-1849 (engine task, its branch only, not on main): commit 60105ace4 "Decision record (proposed): custom roles as
  tenant data supersede the closed role set (0013, 0046 D10, 0081 D1, 0084); plus the stage 0 slice list"; it adds
  `docs/migration/decisions/0088-permission-only-access-tenant-defined-roles.md` (planned, not yet on main).
- `project/walkthrough-gates-cde.md` (2026-11-08): "Tenant: **gate-b5** (the only live QA tenant). Login:
  https://qa.bizdala.com/login?realm=gate-b5"; "module **assets 0.9.0 installed** on gate-b5"; gate C about 25
  minutes, steps 1 to 8; gate D "about 10 minutes on the web, the rest needs the phone app"; gate E about 25 minutes,
  steps 1 to 5. Gate C step 7: "Expect: no asset entries in the menu ... (The owner decision D-097 ... is still waiting
  for a platform feature; this is expected.)"
- `project/LINKS.md`: "Sign in (the only live tenant) | https://qa.bizdala.com/login?realm=gate-b5".
- D-101: "Owner: 'QA is pass for now' = GATE B passed".
- D-111: "(1) Mobile client: option A = keep the Android app and add a PWA build ... (2) Existing fixed assets enter
  through a dedicated asset opening document ... (5) Gate E printout check postponed by the owner. (6) Audio: Letflow
  uses the same API keys as the Qoimeks project (owner); infra copies them without printing; needs the owner's own line
  in the infra session".
- Infra `HANDOFF.md`: "D-092: Letflow voice tests will use the Qoimeks ElevenLabs account; key handoff pending the
  owner's own line".
- D-115: "Production: a new small Hetzner VPS ...; wildcard `*.letflow.ai-dala.com` accepted; data in Germany accepted
  for now ...; Qoimeks Client 1 moves only when the Letflow applications are ready ... Storekeeper grant D-097 approved,
  configurable per tenant."
- D-116: "(1) ... MIT licence ... (3) Backups: simple for now ...; accepted loss = up to the time since the last
  backup. (4) Night-hour service for non-paying clients: none".
- D-118: "(1) created users get an e-mail set-password link, the admin hands out a temporary password until the mail
  relay exists; (2) the PWA keeps users signed in 30 days with a PIN or biometric unlock; (3) no review step ...; (4) no
  e-mail digest until real mail sending is on; ... (6) T-1599: classification approved, private companion repo ...
  approved, NEW squashed public repo ..., `git-filter-repo` ... approved".
- D-121: "any solution and any convenient place may be used for now; the real key place is decided at the first real
  customer case."
- D-124: "A.1 backfill old lots as released ...; A.2 customer-location marker; A.4 posting-kernel decision record
  first; A.6 unit per item plus physical attributes incl. density ... (2) 'Go on with the phase 1' ... the owner sends
  them himself".
- D-126: "First closed feature: custom roles management ... Candidates later: audit export/retention, per-company
  sign-in (several realms), print template designer, advanced reports."
- D-128: "'Who signs' = whoever is assigned the role `accountant` (or the role the tenant maps to that step) ...
  (closes owner question A2 ...). Owner dislikes questions about who a role is: ask him only about the business effect.
  After it, the owner goes through ALL items waiting for his answer or review, gate by gate."
- D-129: "access is checked against PERMISSIONS, never against role names ... The question goes to the architect agent;
  the owner waits for his verdict."
