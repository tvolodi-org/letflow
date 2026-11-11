# Owner answer sheet, November 2026

Written 2026-11-11 (owner ill; D-086, D-118, D-119; task T-1721, item 1 of `docs/uat/ba-decisions/T-1707.md`).

This page only lists. It decides nothing, adds no question of its own and changes no source text. Each row says where its text lives; a row whose source could not be found was left out. "Options" are copied in short from the source; where the source writes none, the cell says so. "Recommendation" is the analyst's own recommendation as written in the source, not a decision. Everything here stays unanswered until the owner (or, where named, infra) answers it.

Sources read: `docs/uat/ba-decisions/T-1677.md`, `T-1695.md`, `T-1706.md`, `T-1567.md`, `T-1651.md`, `T-1665.md`, `docs/migration/decisions/0072-*.md` section 8b, `docs/runbooks/pilot-first-month.md` (section "Open owner questions" and the "Question list for the pilot's 30 users"). Rows marked "via T-1677" take the option text from the note that `T-1677.md` cites (`T-1567.md`, `docs/design/REQ-801-sign-in-for-created-users.md`).

## A. Pilot (runbook `docs/runbooks/pilot-first-month.md`)

| # | Question | Options written down | What it blocks | Where the text is |
|---|---|---|---|---|
| A1 | Which company is the pilot, and what is the start date? | None written. | Week 1 of the pilot; every other pilot row. | Runbook, "Open owner questions" 1; `T-1677.md`, "Owner questions" |
| A2 | What is the accountant's role? | `TENANT_AUDITOR` is a candidate (UAT assumption, to be confirmed). `docs/roles.md` has no accountant role. | Role grants for the three named people. | Runbook, "Open owner questions" 2 and the roles line; `T-1677.md` |
| A3 | Who trains the three people, and in which language? | None written. | Training before week 1. | Runbook, "Open owner questions" 3 |
| A4 | What are the exit thresholds (numbers for the Exit criteria)? | None written. | Judging the end of the pilot. | Runbook, "Open owner questions" 4 |
| A5 | How long does the pilot run after month one? | None written. | Plan beyond month one. | Runbook, "Open owner questions" 5 |
| A6 | What does the company give before week 1 (xlsx of locations, items, balances; names and e-mails of users)? | None written. | Data load and user creation. | Runbook, "Open owner questions" 6 |
| A7 | How does a user made by the Users screen or the xlsx import get a way to sign in? | (a) a Keycloak operator creates each account by hand; (b) a provisioner call from Letflow; (c) invitation mail with self-registration; (d) first-login binding by verified e-mail (needs (a), (b) or (c) first). Interim answer D-118 (1): option (a), QA and pilot only. **Recorded answer for QA: option (b)**, specified in `docs/migration/decisions/0072-*.md` section 8b (addendum T-1703, owner chose (b), D-118 item 1). Still open: infra delivering items (i) to (v) of 8b, and whether (c) or (d) are wanted later (8b "Not decided here": the e-mail set-password link, production, rows that never get a sign-in). | The reset button for users without a login; "has signed in" being a plain observation (M5); runbook "not yet" rows; the Letflow client call (REQ-807 to REQ-809, planned) until infra publishes the call. | Runbook, "Open owner questions" 7 and "Interim sign-in path for created users"; `docs/migration/decisions/0072-*.md` section 8b; `docs/design/REQ-801-sign-in-for-created-users.md`, "Options" and "Owner and infra questions"; `T-1677.md`, items 6 and 7 |
| A8 | Who hands out the temporary passwords to the pilot users, and through which channel does the operator give them to the company administrator? (Pilot question 5 asks the responsibility part; runbook open question 8 asks the channel.) | None written. | Interim path step 4. | Runbook, "Open owner questions" 8 and question list 5 |

### A-bis. Question list for the pilot's 30 users (runbook, "Question list for the pilot's 30 users")

The runbook says: answer before week 1; none is answered there. Items 3 and 5 repeat A2 and A8 (A8 now carries both the responsibility and the channel).

| # | Question | Options written down | What it blocks | Where the text is |
|---|---|---|---|---|
| A9 | Who is the Keycloak operator for the pilot realm, and do they accept 30 hand-made accounts? | None written. | Interim path (a). | Runbook, question list 1 |
| A10 | Real e-mail, display name and language for each of the 30; does each person have their own address? | None written. | Creating the accounts. | Runbook, question list 2 |
| A11 | Which of the 30 need which role or group; which three are administrator, storekeeper, accountant? | None written. | Role grants. | Runbook, question list 3 |
| A12 | Do all 30 sign in from the start, or only the three named roles in week 1? | Two: all 30, or three in week 1. | Size of the operator's work in week 1. | Runbook, question list 4 |
| A13 | Is it acceptable that the first sign-in makes a second user row and the administrator moves the roles, or must the collision be fixed before week 1? | Two: accept, or fix first. | Any change that links or merges user rows by e-mail (excluded from the builds, takeover risk; owner and security decision). | Runbook, question list 6; `T-1677.md`, item 3 and "Must wait for the owner" |
| A14 | Which username form in the realm: e-mail address, or the username written in Letflow? | Two, as stated. Equal usernames are refused; different ones make a second row. | Account creation by the operator. | Runbook, question list 7 |
| A15 | Is the operator's manual step acceptable beyond QA? | None written. Production is not approved. | Any use outside QA. | Runbook, question list 8 |
| A16 | How long may a person wait for the operator after being added? | None written. | Service promise in week 1. | Runbook, question list 9 |
| A17 | When option (b) is built, how are the 30 accounts moved to it? | None written. Not needed for week 1. | Move to option (b). | Runbook, question list 10 |

### A-ter. REQ-801 owner and infra questions

| # | Question | Options written down | What it blocks | Where the text is |
|---|---|---|---|---|
| A18 | Which sign-in option, or combination, is wanted for QA (the same decision as A7)? | (a) alone; (b); (c); (a) now and (b) or (c) later; with or without (d). **Recorded:** option (b) for QA, `docs/migration/decisions/0072-*.md` section 8b (D-118 item 1). Open only: whether (c) or (d) are wanted later. | Option (c)/(d) work; production (not approved). | `docs/design/REQ-801-sign-in-for-created-users.md`, "Owner and infra questions" 1; `docs/migration/decisions/0072-*.md` section 8b |
| A19 | Are internal rows made by the import kept, linked to their Keycloak account (needs (d)), or replaced? | Three, as stated. | Option (d). | Same file, question 3 |
| A20 | What does infra still owe for (b)? Recorded in `docs/migration/decisions/0072-*.md` section 8b: (i) one provisioner call that creates an enabled, e-mail-verified user with a temporary password and UPDATE_PASSWORD; (ii) its answer shapes; (iii) the provisioner's Keycloak credential re-scoped to create users only in realms it made (a change of D-018, for infra and the portfolio manager to record); (iv) a caller token for Letflow's users step; (v) audit log and rate limit; (vi) QA only. For (c), if wanted later: realm template v2 and mail relay settings. | Not alternatives: the record specifies the provisioner extension; the earlier "widen the credential or a separate service" question is answered by item (iii). | Option (b) going live; (c). Infra decision (D-016, D-018). | `docs/migration/decisions/0072-*.md` section 8b ("What infra must provide"); `docs/design/REQ-801-sign-in-for-created-users.md`, question 4 |
| A21 | May Letflow keep a "has signed in" time per person (privacy posture)? | None written. | Showing "has signed in" on the Users screen; `T-1677.md` item 7. | `T-1677.md`, item 7 and "Must wait for the owner" |

## B. Tenant sign-up (front door), all QA only

The questions Q1 to Q11 come from the note `T-1567.md`; `T-1677.md` and `T-1695.md` list which of them stay open and which slices wait.

| # | Question | Options written down | What it blocks | Where the text is |
|---|---|---|---|---|
| B1 | Q1: how many open sign-ups may exist (cap today 30 demo tenants)? | Raise the cap with a per-source budget; keep 30 with invitation-only sign-up (a code); or a waiting list when full. Recommendation: invitation code for release 1, cap unchanged. | Opening the form to the public; SL5 number. | `T-1677.md`, "Still open from `T-1567.md`"; via T-1677: `T-1567.md` Q1 |
| B2 | Q2: plans, pricing, billing. | None written (release 1 records "demo, 14 days" only). | SL9 plan hook. | `T-1677.md` slice table (SL9) and "Must wait"; `T-1695.md`, "Must wait" |
| B3 | Q3: captcha vendor and cost, privacy, availability in Kazakhstan; who keeps the disposable-e-mail list. | None written. | Public form anti-abuse. | `T-1677.md`, "Still open"; `T-1695.md`, "Must wait" |
| B4 | Q4: tenant address. | (a) shared origin plus `?realm=<t-hex>`; (b) `?realm=<company-chosen-name>` (needs a slug rule and reserved list that do not exist); (c) per-tenant host (SL6). Recommendation: (a) for release 1, (c) second release. | SL6 host-to-tenant resolution (also an amendment of decision 0042); the welcome link form. | `T-1677.md`, slice table (SL6) and assumptions; `T-1695.md`, "Must wait" |
| B5 | Q6: terms of service and privacy text, and the retention statement (14 days demo, 30 days kept, then purged); who writes it, in which languages. | None written. A placeholder ships (0084 D6). | Real terms on the form. | `T-1677.md`, "Still open"; `T-1695.md`, "Must wait" |
| B6 | Q7: mail relay and sender domain (SPF, DKIM, DMARC), bounce handling, same relay as the realm's account mail or not. | None written. | End-to-end test of verification and welcome mail; GAP `provisioning-8`. | `T-1677.md`, "Still open" and item 5; `T-1695.md`, item 4 |
| B7 | Q8: production demo domain and whether a wildcard certificate is acceptable. | None written. | SL7 wildcard DNS and certificate (infra; DNS is outside this team's remit). | `T-1677.md`, slice table (SL7) |
| B8 | Q9: erasure on request and self-service deletion. | None written. | SL10 self-service offboarding. | `T-1677.md`, slice table (SL10) |
| B9 | Q10: language of the first release and the support contact printed in the mail. | ru, kk and en all together, or ru and en first. The support contact has no options written. | Wording of release-1 mails. | `T-1567.md`, Q10; `T-1677.md`, "Still open" |
| B10 | Q11: is production approval for this flow in scope at all? | None written. QA only until the owner approves (D-019 item 3). | SL12 production tenants; everything that touches production. | `T-1677.md`, slice table (SL12); `T-1695.md`, "Must wait" |
| B11 | Infra items SL1 (test of first-credential paths in infra's sandbox) and SL8 (sweep of orphan realms by infra's reaper). | Not an owner question: infra work. | Closing the "not tested" item of 0072 section 11; orphan realms. | `T-1677.md`, slice table; `T-1695.md`, "Must wait" |
| B12 | Q5: which modules are installed by default in a new demo tenant? | Analyst proposal: assets, locations, codes, catalog items, nothing else (exam is not a priority, D-043). The core text calls it the owner's call. | SL4 default-module install. | `T-1567.md`, Q5 and slice SL4; `T-1677.md` slice table (SL4) |

## C. Security follow-up and product calls (`T-1695.md`)

| # | Question | Options written down | What it blocks | Where the text is |
|---|---|---|---|---|
| C1 | F4-2: minimum length of a tenant's module-upgrade window, or an operator force for security updates. | The two, as stated. | Fix of F4-2; changes what a tenant is allowed. | `T-1695.md`, state-read item 2 and "Must wait for the owner" |
| C2 | F4-3: honest 429 versus neutral 202 for the domain cap. | The two, as stated. | Fix of F4-3; changes what a user is told. | Same places |
| C3 | Escape on the rollouts page also fires from the module input and closes the detail. | None written ("needs a product call"). | Accessibility row in `docs/design-system/accessibility.md`. | `T-1695.md`, state-read item 5 and "Must wait" |
| C4 | Real-browser axe run and the Kazakh wording check on the rollouts page. | Not a decision: an operator check. | Closing the second accessibility row. | `T-1695.md`, "Must wait" |

## D. Other owner-held items named in the notes

These are named in `T-1677.md` ("Still open from earlier batches") and `T-1695.md` ("not repeated"); options are copied from the earlier notes where they write any, otherwise the cell says "None written".

| # | Item | Options written down | What it blocks | Where the text is |
|---|---|---|---|---|
| D1 | Voice keys and money. | None written in the notes read. | Voice features. | `T-1677.md`, "Still open from earlier batches"; also `T-1631.md`, `T-1651.md`, `T-1665.md` (listed only) |
| D2 | The storekeeper grant and UAT account. | None written. | UAT with the storekeeper role. | Same notes |
| D3 | Qoimeks cut-over. | None written; `T-1569.md` section 5 is a proposal, no cut-over date, the pilot is not touched. | Qoimeks go-live. | `T-1600.md` row d; `T-1651.md`; `T-1569.md` section 5 |
| D4 | Digest and per-user notification preferences: mail copy, sender, time, default. | None written (default proposed off). Stays held until a third bell kind exists. | Digest and preferences work; the optional mail copy of the bell. | `T-1651.md`, item 10 and its owner column (T-1551) |
| D5 | Does an asset document get a review step (draft, submitted, returned, issued) at all, and which roles submit and review. | Two: no review step (today: draft, issued, cancelled), or a review step before issue; an issued document is never returned. The accountant role is also open (A2). | The requirement for the review step; the "document returned" bell kind. | `T-1651.md`, items 11 and point (1); REQ-800 question (a) |
| D6 | Bigger or paid CI runners, more shards or more parallel jobs. | Rank 5 of the cuts; costs money, saving not measured. | CI capacity. | `docs/status/ci-minutes-after-batch4.md`, "Owner decisions"; `T-1631.md` item 7 |
| D7 | The PWA session choice: should the PWA keep the sign-in across a closed page? | Three: tokens in memory only (today); a short-lived refresh token in browser storage; rely on the silent identity-provider session. The note states the security cost of each. | The PWA sign-in decision note and any change. | `T-1665.md`, item 7; `docs/mobile/pwa-parity.md`, gap 1; `docs/runbooks/mobile-web-pwa-signin.md`, "Behaviour to know" |
| D8 | Which build fixes the mobile gaps: Android app or PWA. | Two, as named. Not decided. | The Android draft-queue gap (held) and the other gaps. | `docs/mobile/pwa-parity.md`, "Status"; `T-1631.md` item 8; `T-1665.md` |
| D9 | GAP sidecars waiting on a roster addition, a second exam tenant, an assignment route, the exam notification switch or a mailbox. Each group is one owner or infra decision. | None written. | The sidecars of those groups. | `T-1677.md` and `T-1695.md`, "Must wait for the owner"; `docs/uat/gap-sidecar-audit.md`, "Reading notes" |
| D10 | Native check of the Kazakh drafts (batch 10 items 1 and 2: Users, Definitions, Instances, the two Users detail messages). | Machine drafts are acceptable until then (UAT assumption). | Calling the Kazakh text final. | `T-1706.md`, "Must wait for the owner" and "Assumptions"; `docs/assets/i18n-gaps.md` |
| D11 | Anything touching DNS, repositories, secrets, money, demo promotion, LICENSE, production. | Not a question: reserved to the owner by standing rule. | Those actions. | `T-1706.md`, "Must wait for the owner" |


## How to use this page

When the owner answers a row, the answer goes into the source named in the last column (and into the portfolio `DECISIONS.md` where the decision belongs there), not into this page. This page is a snapshot of 2026-11-11 and is not kept in step.
