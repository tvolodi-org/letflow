# First closed-feature candidates (note for the owner, for later)

Task T-1851 (PM D-131, corrected by D-132, 2026-11-13). Under D-126 the product is an open core with a few closed features behind
sockets (`docs/design/open-core-sockets.md`). This note lists the first candidates in plain words so the owner can choose later. It
builds nothing: no code, no private repository, no package. Nothing here is decided except candidate 1, which the owner decided in
D-132 (decision record `docs/migration/decisions/0088-permission-only-access-tenant-defined-roles.md`, D10).

Marks: **V** = verified by reading the file on origin/main (`abdcaee89`, 2026-11-13); **G** = guess (all sizes are guesses).
Sizes: S = a few days, M = one to two weeks, L = several weeks, for one developer with reviews (G).

## The candidates

| # | Candidate | What it is | Why it fits closed | Open socket it needs (small) | Size (G) | What the open build keeps |
|---|---|---|---|---|---|---|
| 1 | **Role editor** (decided, D-132) | The tenant admin creates roles from the permissions the modules declare, copies a ready-made role, edits, replaces or retires roles | A company-scale need (own job titles, separation of duties); the open build works fully without it | The role editor socket: one mount point, one capability field for the screen, writes only through the core role write path (`open-core-sockets.md` section 1.3) | M to L for the package; S to M for the socket | The ready-made roles as read-only rows, assigning users to them, the storekeeper asset switch, the same access checks (V for today's facts: `open-core-sockets.md` 1.1) |
| 2 | **Audit export and retention** | Scheduled export of the audit trail to the company's own store, long retention periods, retention rules per kind of record, an export of the audit chain with its proof | Asked for by regulated, larger customers; the base audit is enough to run the product | An export target interface called by the core after its own audit write; the open default writes nothing | M | The audit trail with its hash chain (`Letflow.Audit`, `lib/letflow/audit/chain_lock.ex`, V); the CSV export of the audit list, capped at 10 000 rows (`lib/letflow/routers/audit.ex`, `audit_export_cap`, T-1557, V); event archiving with per-event-type retention rows (`EventStore` archive, `lib/letflow/event_store.ex`, V); document retention (`Letflow.Documents.Retention`, decision 0063, V) |
| 3 | **Several sign-in realms** | Each customer company signs in through its own identity realm, created and removed by a provisioner | A company-scale feature; T-1521 section 4 point 4 already places it in the corporate edition | An identity-provider interface in the core: the open default is one realm configured by the operator | M to L, with a security review for tenant isolation | Sign-in through one operator-configured identity provider. Note: the realm-per-tenant provisioner is in the open code today (`Letflow.TenantProvisioner`, `lib/letflow/tenant_provisioner.ex`, decision 0072, QA only, V); moving it behind the socket is moving open code to closed, which section 2.1 of `open-core-sockets.md` says needs the PM. The repository is not public yet (no `LICENSE` file, V), so the move is still possible |
| 4 | **Print template designer** | A visual designer for printed forms (drag and drop fields, tables, logos) on top of today's layout format | A convenience for companies with many forms; the open build can already change a print layout | A screen slot on the print templates page; the designer saves through the same open save route and the same layout format | M (G: depends on how rich the designer is) | Per-tenant print-template overrides (decision 0068) with the declarative layout, the JSON layout editor with live preview (`web/src/components/admin/PrintLayoutEditor.tsx`, `web/src/pages/admin/PrintTemplatesPage.tsx`, REQ-614, V) |
| 5 | **Advanced reports** | Report builder across modules, pivot tables, scheduled reports sent by e-mail, saved report packs | Management reporting is sold value; day-to-day lists work without it | A report definition interface that reads through the same permission-checked query path as saved views; the open default offers no extra report kinds | M to L (G) | Saved list views with aggregates and chart type (`/entity-views`, `lib/letflow/routers/entity_views.ex`, decision 0066, V); the saved stock balance report (decision 0086, status proposed, V) |

## Preconditions that are not features

| Item | Why it comes first | Size (G) |
|---|---|---|
| Licence and feature-flag check | Every closed feature asks "is this licensed for this tenant"; the role editor's `enabled?/1` does. What happens when a licence ends is an owner question for that design (T-1521 Q9). | S to M |
| Per-edition test pins | A closed package must not break the open CI (`open-core-sockets.md` section 2.3). | M, test-only |
| Module loader and signed packages | Needed when a closed package is shipped outside the source tree (T-1521 section 4 point 1). | M to L |

## Verified vs guess

* V: every file, route and decision named in the "What the open build keeps" column (opened or grepped on origin/main); candidate 1's
  status (0088 D10, from the D-132 text in the task).
* G: the content of candidates 2 to 5 beyond what exists today, the shape of each socket, all sizes, the order.
* Not read: the portfolio record D-126 and any customer request for these features (not reachable from the worktree).

Commands: `ls lib/letflow/audit lib/letflow/documents`; `grep -n export lib/letflow/routers/audit.ex`; `grep -n retention lib/letflow/event_store.ex`;
`sed -n 1,15p lib/letflow/tenant_provisioner.ex`; `grep -rln print_override web/src`; `sed -n 1,12p lib/letflow/routers/entity_views.ex`;
`head -3 docs/migration/decisions/0086-saved-stock-balance-report.md`; `ls LICENSE*`.

One new business choice for the owner, later (recommendation): pick candidate 2 (audit export and retention) as the second closed
feature, because the base audit it builds on is already complete in the open code.
