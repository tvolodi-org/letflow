# Function catalog seed (reviewable)

Task T-2675, owner decision D-192. A **feature** is a group of business **functions**; a function is named for what it does and is linked to every business process that uses it (many-to-many). Cross-cutting features come first (F-01..F-14), then the domain features of each application (F-20..). System functions, scripts and rules only support a function; they appear as evidence.

Machine file: `catalog-seed.json` (same rows). Evidence = the first task route, form or system function of the process that matches the function.

## Measures

- functions: 69
- shared_functions: 60
- shared_percent: 87.0
- max_sharing: 41
- max_sharing_function: FN-010 Claim a task from the work list
- process_specific: 6
- processes_total: 224
- processes_covered: 224
- uncovered processes: 0

Not a row: *Send to printer* and *Send by e-mail* (document output): no process in the map has a task that does either, so none is invented (a function with no process is a FAIL).

## F-01 Document output feature (print, preview, save, send) (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-001 Preview a document on screen | shared | 22: BP-ASSETS-03, BP-ASSETS-04, BP-ASSETS-05, BP-ASSETS-06, BP-ASSETS-07, BP-ASSETS-08 ... | BP-ASSETS-03: documents/:id -> DocumentPage; BP-ASSETS-04: documents/:id -> DocumentPage |
| FN-002 Generate a printable document from a form template | shared | 5: BP-DESIGNER-21, BP-EXAM-06, BP-EXAM-07, BP-PLATFORM-23, BP-STOCK-15 | BP-DESIGNER-21: GET /api/v1/documents/print-overrides; BP-EXAM-06: POST /api/v1/modules/exam/exam-sessions/:id/certificate |
| FN-003 Save a document or report as a file | shared | 15: BP-DESIGNER-03, BP-DESIGNER-05, BP-DESIGNER-08, BP-DESIGNER-21, BP-EXAM-06, BP-EXAM-07 ... | BP-DESIGNER-03: GET /api/v1/definitions/:id/export; BP-DESIGNER-05: POST /api/v1/solution-packs/export |

## F-02 Scanning, codes and recognition feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-004 Assign and print a code or label for an item | single-process | 1: BP-MASTER-10 | BP-MASTER-10: POST /api/v1/modules/codes/labels |
| FN-005 Resolve an item by a scanned code | shared | 9: BP-ASSETS-03, BP-ASSETS-04, BP-ASSETS-05, BP-ASSETS-06, BP-MASTER-08, BP-MASTER-09 ... | BP-ASSETS-03: Letflow.Modules.Assets.Documents.Checks.card_lookup; BP-ASSETS-04: Letflow.Modules.Assets.Documents.Checks.card_lookup |
| FN-006 Recognise an item or quantity by voice | shared | 6: BP-STOCK-17, BP-STOCK-23, BP-STOCK-24, BP-STOCK-25, BP-STOCK-30, BP-STOCK-36 | BP-STOCK-17: POST /api/v1/modules/stock/voice/draft; BP-STOCK-23: POST /api/v1/modules/stock/voice/draft |

## F-03 Notification feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-007 Show and read my notifications | single-process | 1: BP-TENANT-ADMIN-24 | BP-TENANT-ADMIN-24: GET /api/v1/me/notifications |
| FN-008 Define and deliver a notification by e-mail or another channel | single-process | 1: BP-TENANT-ADMIN-26 | BP-TENANT-ADMIN-26: GET /api/v1/notification-templates |
| FN-009 Call an outside system when something happens (webhook) | shared | 5: BP-DESIGNER-18, BP-DESIGNER-19, BP-DESIGNER-24, BP-DESIGNER-25, BP-DESIGNER-30 | BP-DESIGNER-18: GET /api/v1/webhooks/subscriptions; BP-DESIGNER-19: POST /api/v1/integration-mappings |

## F-04 Task routing and approval feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-010 Claim a task from the work list | shared | 41: BP-ASSETS-03, BP-ASSETS-04, BP-ASSETS-05, BP-ASSETS-06, BP-ASSETS-07, BP-ASSETS-08 ... | BP-ASSETS-03: POST /api/v1/tasks/:id/claim; BP-ASSETS-04: POST /api/v1/tasks/:id/claim |
| FN-011 Complete a task with an outcome | shared | 37: BP-ASSETS-03, BP-ASSETS-04, BP-ASSETS-05, BP-ASSETS-06, BP-ASSETS-07, BP-ASSETS-08 ... | BP-ASSETS-03: POST /api/v1/tasks/:id/complete; BP-ASSETS-04: POST /api/v1/tasks/:id/complete |
| FN-012 Set who approves a step (approval rules) | shared | 15: BP-ASSETS-15, BP-STOCK-15, BP-STOCK-21, BP-STOCK-26, BP-STOCK-27, BP-STOCK-35 ... | BP-ASSETS-15: GET /api/v1/modules/assets/approval-access; BP-STOCK-15: GET /api/v1/modules/stock/approval-access |
| FN-013 Record a decision on a request | shared | 15: BP-PROCUREMENT-02, BP-PROCUREMENT-06, BP-PROCUREMENT-07, BP-PROCUREMENT-08, BP-PROCUREMENT-09, BP-PROCUREMENT-11 ... | BP-PROCUREMENT-02: POST /api/v1/modules/procurement/purchase-requests/:id/decisions; BP-PROCUREMENT-06: POST /api/v1/modules/procurement/purchase-requests/:id/decisions |
| FN-014 Start a process instance | shared | 8: BP-ASSETS-17, BP-DESIGNER-14, BP-DESIGNER-15, BP-DESIGNER-27, BP-DESIGNER-29, BP-STOCK-19 ... | BP-ASSETS-17: POST /api/v1/instances; BP-DESIGNER-14: POST /api/v1/instances |

## F-05 Accounting and ledger posting feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-015 Post a document to the ledger | shared | 26: BP-ASSETS-03, BP-ASSETS-04, BP-ASSETS-05, BP-ASSETS-06, BP-ASSETS-07, BP-ASSETS-08 ... | BP-ASSETS-03: assets.post_document; BP-ASSETS-04: assets.post_document |
| FN-016 Reverse a posted document | shared | 12: BP-ASSETS-09, BP-ASSETS-14, BP-ASSETS-15, BP-STOCK-12, BP-STOCK-16, BP-STOCK-20 ... | BP-ASSETS-09: POST /api/v1/modules/assets/documents/:id/reverse; BP-ASSETS-14: POST /api/v1/modules/assets/documents/:id/reverse |
| FN-017 Show balances and movements | shared | 17: BP-ASSETS-03, BP-ASSETS-04, BP-ASSETS-05, BP-ASSETS-06, BP-ASSETS-13, BP-STOCK-15 ... | BP-ASSETS-03: GET /api/v1/modules/assets/balances; BP-ASSETS-04: GET /api/v1/modules/assets/balances |
| FN-018 Reconcile the ledger with the records | shared | 4: BP-ASSETS-13, BP-ASSETS-15, BP-STOCK-15, BP-STOCK-21 | BP-ASSETS-13: GET /api/v1/modules/assets/reconcile; BP-ASSETS-15: GET /api/v1/modules/assets/reconcile |
| FN-019 Set ledger and posting rules | shared | 9: BP-STOCK-02, BP-STOCK-09, BP-STOCK-15, BP-STOCK-40, BP-STOCK-41, BP-TENANT-ADMIN-22 ... | BP-STOCK-02: Letflow.Modules.Stock.PostingRules.negative_allowed?; BP-STOCK-09: GET /api/v1/modules/stock/frozen-locations |

## F-06 Audit trail and user records feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-020 Read the audit trail | shared | 5: BP-STOCK-27, BP-TENANT-ADMIN-23, BP-TENANT-ADMIN-33, BP-TENANT-ADMIN-39, BP-TENANT-ADMIN-44 | BP-STOCK-27: GET /api/v1/audit; BP-TENANT-ADMIN-23: GET /api/v1/audit |
| FN-021 Keep and retire old events (retention) | shared | 2: BP-PLATFORM-09, BP-PLATFORM-16 | BP-PLATFORM-09: GET /api/v1/event-retention/summary; BP-PLATFORM-16: GET /api/v1/event-retention/summary |

## F-07 Excel import and export feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-022 Import records from an Excel or CSV file | shared | 14: BP-DESIGNER-03, BP-DESIGNER-08, BP-DESIGNER-29, BP-MAINTENANCE-13, BP-MAINTENANCE-20, BP-MASTER-06 ... | BP-DESIGNER-03: POST /api/v1/definitions/import; BP-DESIGNER-08: POST /api/v1/entities/records/:entity_type/import |
| FN-023 Export records or a workbook to Excel | shared | 10: BP-MAINTENANCE-12, BP-MAINTENANCE-13, BP-MAINTENANCE-20, BP-STOCK-13, BP-STOCK-20, BP-STOCK-21 ... | BP-MAINTENANCE-12: Letflow.Plugs.ReportExportAuth; BP-MAINTENANCE-13: Letflow.Plugs.ReportExportAuth |

## F-08 Attachments and photos feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-024 Attach a file or a photo to a record | shared | 15: BP-ASSETS-02, BP-ASSETS-16, BP-DESIGNER-07, BP-DESIGNER-15, BP-DESIGNER-29, BP-MAINTENANCE-02 ... | BP-ASSETS-02: POST /api/v1/modules/assets/cards/:id/photos; BP-ASSETS-16: POST /api/v1/modules/assets/cards/:id/photos |

## F-09 Search and lookup feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-025 Search and filter records | shared | 3: BP-DESIGNER-01, BP-DESIGNER-07, BP-DESIGNER-09 | BP-DESIGNER-01: GET /api/v1/definitions/search; BP-DESIGNER-07: POST /api/v1/entities/query |
| FN-026 Look up a master record by name | shared | 2: BP-DESIGNER-06, BP-DESIGNER-13 | BP-DESIGNER-06: GET /api/v1/entities/definitions/by-name/:name; BP-DESIGNER-13: GET /api/v1/script-policy/readable-masters |

## F-10 Sign-in and access feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-027 Sign in and find my tenant | shared | 8: BP-PLATFORM-13, BP-PLATFORM-19, BP-PLATFORM-22, BP-PLATFORM-23, BP-TENANT-ADMIN-01, BP-TENANT-ADMIN-17 ... | BP-PLATFORM-13: GET /api/signup/config; BP-PLATFORM-19: POST /api/signup/verify |
| FN-028 Manage users and their status | shared | 13: BP-TENANT-ADMIN-03, BP-TENANT-ADMIN-04, BP-TENANT-ADMIN-05, BP-TENANT-ADMIN-06, BP-TENANT-ADMIN-07, BP-TENANT-ADMIN-13 ... | BP-TENANT-ADMIN-03: GET /api/v1/identity/users; BP-TENANT-ADMIN-04: GET /api/v1/identity/users/import-template |
| FN-029 Give roles, groups and scope to users | shared | 9: BP-TENANT-ADMIN-08, BP-TENANT-ADMIN-09, BP-TENANT-ADMIN-10, BP-TENANT-ADMIN-11, BP-TENANT-ADMIN-12, BP-TENANT-ADMIN-34 ... | BP-TENANT-ADMIN-08: POST /api/v1/identity/groups; BP-TENANT-ADMIN-09: GET /api/v1/identity/roles |
| FN-030 Issue and revoke an access token | shared | 9: BP-DESIGNER-22, BP-DESIGNER-26, BP-DESIGNER-30, BP-PLATFORM-23, BP-TENANT-ADMIN-14, BP-TENANT-ADMIN-34 ... | BP-DESIGNER-22: POST /api/v1/public-read-handles; BP-DESIGNER-26: GET /api/public/:kind/:handle |
| FN-031 Share stock access with another tenant | shared | 13: BP-STOCK-28, BP-STOCK-29, BP-STOCK-30, BP-STOCK-31, BP-STOCK-32, BP-STOCK-33 ... | BP-STOCK-28: GET /api/v1/identity/shared-stock-access; BP-STOCK-29: GET /api/v1/identity/shared-stock-access |
| FN-032 Manage my own account and preferences | shared | 7: BP-TENANT-ADMIN-01, BP-TENANT-ADMIN-02, BP-TENANT-ADMIN-24, BP-TENANT-ADMIN-25, BP-TENANT-ADMIN-37, BP-TENANT-ADMIN-43 ... | BP-TENANT-ADMIN-01: GET /api/v1/me; BP-TENANT-ADMIN-02: GET /api/v1/me/access |

## F-11 Master data and reference lists feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-033 Maintain places, sites and locations | shared | 9: BP-MASTER-01, BP-MASTER-04, BP-MASTER-05, BP-MASTER-07, BP-MASTER-11, BP-MASTER-12 ... | BP-MASTER-01: POST /api/v1/modules/org/sites; BP-MASTER-04: POST /api/v1/modules/locations/nodes |
| FN-034 Maintain the organisation (units, employees, positions) | shared | 8: BP-MASTER-01, BP-MASTER-02, BP-MASTER-03, BP-MASTER-07, BP-MASTER-11, BP-MASTER-12 ... | BP-MASTER-01: POST /api/v1/modules/org/legal-entities; BP-MASTER-02: POST /api/v1/modules/org/units |
| FN-035 Maintain items, currencies and number sequences | shared | 8: BP-MASTER-06, BP-MASTER-08, BP-MASTER-11, BP-MASTER-15, BP-TENANT-ADMIN-27, BP-TENANT-ADMIN-29 ... | BP-MASTER-06: ItemsPage; BP-MASTER-08: POST /api/v1/modules/catalog_items/lots |
| FN-036 Define a record type and its fields | shared | 6: BP-DESIGNER-06, BP-DESIGNER-07, BP-DESIGNER-09, BP-DESIGNER-24, BP-DESIGNER-25, BP-DESIGNER-33 | BP-DESIGNER-06: POST /api/v1/entities/definitions; BP-DESIGNER-07: entities/:entityType |
| FN-037 Create and change records of a defined type | shared | 6: BP-DESIGNER-07, BP-DESIGNER-08, BP-DESIGNER-29, BP-MASTER-06, BP-MASTER-07, BP-MASTER-15 | BP-DESIGNER-07: POST /api/v1/entities/records/:entity_type; BP-DESIGNER-08: POST /api/v1/entities/records/:entity_type/export |

## F-12 Tenant and module configuration feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-038 Install, upgrade or remove a module for a tenant | shared | 7: BP-MES-01, BP-MES-02, BP-MES-03, BP-PLATFORM-07, BP-PLATFORM-16, BP-TENANT-ADMIN-19 ... | BP-MES-01: POST /api/v1/tenant/modules; BP-MES-02: POST /api/v1/tenant/modules |
| FN-039 Set tenant settings, logo and hostname | shared | 9: BP-TENANT-ADMIN-01, BP-TENANT-ADMIN-16, BP-TENANT-ADMIN-17, BP-TENANT-ADMIN-33, BP-TENANT-ADMIN-34, BP-TENANT-ADMIN-37 ... | BP-TENANT-ADMIN-01: GET /api/tenant-config/logo; BP-TENANT-ADMIN-16: GET /api/v1/tenant/settings |
| FN-040 Export and import a tenant configuration | shared | 6: BP-DESIGNER-05, BP-TENANT-ADMIN-18, BP-TENANT-ADMIN-19, BP-TENANT-ADMIN-34, BP-TENANT-ADMIN-38, BP-TENANT-ADMIN-41 | BP-DESIGNER-05: POST /api/v1/solution-packs/export; BP-TENANT-ADMIN-18: GET /api/v1/tenant/config-bundle |
| FN-041 Promote a configuration from one tenant to another | shared | 3: BP-DESIGNER-04, BP-DESIGNER-24, BP-DESIGNER-25 | BP-DESIGNER-04: POST /api/v1/promotions/plan; BP-DESIGNER-24: POST /api/v1/promotions |
| FN-069 Override screen wording (labels) | process-specific | 1: BP-TENANT-ADMIN-28 | BP-TENANT-ADMIN-28: GET /api/v1/labels |

## F-13 Process definition and automation feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-042 Design, validate and publish a process definition | shared | 12: BP-DESIGNER-01, BP-DESIGNER-02, BP-DESIGNER-03, BP-DESIGNER-04, BP-DESIGNER-06, BP-DESIGNER-24 ... | BP-DESIGNER-01: POST /api/v1/definitions; BP-DESIGNER-02: POST /api/v1/definitions/:id/activate |
| FN-043 Write and publish a business rule script | shared | 3: BP-DESIGNER-12, BP-DESIGNER-24, BP-DESIGNER-31 | BP-DESIGNER-12: GET /api/v1/script-rules; BP-DESIGNER-24: POST /api/v1/script-rules/:key/versions |
| FN-044 Control what scripts may do (script policy) | shared | 5: BP-DESIGNER-13, BP-DESIGNER-24, BP-DESIGNER-31, BP-DESIGNER-32, BP-PLATFORM-04 | BP-DESIGNER-13: GET /api/v1/script-policy; BP-DESIGNER-24: PUT /api/v1/script-policy/kill-switch |
| FN-045 Run a job on a schedule or on a record change | shared | 6: BP-DESIGNER-10, BP-DESIGNER-11, BP-DESIGNER-14, BP-DESIGNER-20, BP-DESIGNER-25, BP-STOCK-37 | BP-DESIGNER-10: GET /api/v1/entity-type-hooks; BP-DESIGNER-11: GET /api/v1/record-trigger-bindings |

## F-14 Platform operation feature (platform)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-046 Create, suspend, resume, expire and delete a tenant | shared | 16: BP-PLATFORM-01, BP-PLATFORM-02, BP-PLATFORM-03, BP-PLATFORM-04, BP-PLATFORM-05, BP-PLATFORM-06 ... | BP-PLATFORM-01: GET /api/v1/tenants; BP-PLATFORM-02: POST /api/v1/tenants/:slug/deactivate |
| FN-047 Roll a platform migration or module out to tenants | shared | 3: BP-PLATFORM-07, BP-PLATFORM-08, BP-PLATFORM-16 | BP-PLATFORM-07: POST /api/v1/platform-module-rollouts; BP-PLATFORM-08: POST /api/v1/platform-migrations/rollouts |
| FN-048 Watch the health, backups and failed messages | shared | 11: BP-DESIGNER-17, BP-DESIGNER-23, BP-DESIGNER-24, BP-MAINTENANCE-12, BP-MAINTENANCE-20, BP-PLATFORM-01 ... | BP-DESIGNER-17: GET /api/v1/dlq; BP-DESIGNER-23: GET /api/v1/services |
| FN-049 Receive and decide a problem report | shared | 5: BP-MAINTENANCE-12, BP-MAINTENANCE-20, BP-PLATFORM-12, BP-PLATFORM-16, BP-TENANT-ADMIN-25 | BP-MAINTENANCE-12: GET /maintenance/v1/problem-reports; BP-MAINTENANCE-20: GET /maintenance/v1/problem-reports |
| FN-068 Prove a module's runtime is alive (runtime demo ping) | process-specific | 1: BP-PLATFORM-15 | BP-PLATFORM-15: GET /api/v1/modules/runtime_demo/ping |

## F-20 Stock posting document feature (receive, issue, transfer) (wms)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-050 Create a draft stock document | shared | 27: BP-ASSETS-03, BP-ASSETS-04, BP-ASSETS-05, BP-ASSETS-06, BP-ASSETS-07, BP-ASSETS-08 ... | BP-ASSETS-03: documents/new -> DocumentNewPage; BP-ASSETS-04: documents/new -> DocumentNewPage |
| FN-051 Issue a stock document (fix it and start its posting task) | shared | 26: BP-ASSETS-03, BP-ASSETS-04, BP-ASSETS-05, BP-ASSETS-06, BP-ASSETS-07, BP-ASSETS-08 ... | BP-ASSETS-03: documents/:id -> DocumentPage; BP-ASSETS-04: documents/:id -> DocumentPage |
| FN-052 Cancel a document or count before it is posted | shared | 13: BP-ASSETS-11, BP-DESIGNER-14, BP-PROCUREMENT-04, BP-PROCUREMENT-06, BP-PROCUREMENT-11, BP-PROCUREMENT-12 ... | BP-ASSETS-11: POST /api/v1/modules/assets/counts/:id/cancel; BP-DESIGNER-14: POST /api/v1/instances/:id/cancel |

## F-21 Stock counting document feature (wms)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-053 Plan and open a stock count | shared | 14: BP-STOCK-08, BP-STOCK-09, BP-STOCK-10, BP-STOCK-11, BP-STOCK-12, BP-STOCK-13 ... | BP-STOCK-08: POST /api/v1/modules/stock/quick-counts; BP-STOCK-09: POST /api/v1/modules/stock/counts |
| FN-054 Approve count differences and post them | shared | 8: BP-STOCK-07, BP-STOCK-08, BP-STOCK-13, BP-STOCK-26, BP-STOCK-33, BP-STOCK-34 ... | BP-STOCK-07: stock_opening/approve; BP-STOCK-08: stock_quick_count/approve |

## F-22 Fixed-asset document and card feature (assets)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-055 Create and issue an asset document | shared | 12: BP-ASSETS-01, BP-ASSETS-03, BP-ASSETS-04, BP-ASSETS-05, BP-ASSETS-06, BP-ASSETS-07 ... | BP-ASSETS-01: Letflow.Modules.Assets.Documents.Checks.held?; BP-ASSETS-03: POST /api/v1/modules/assets/documents |
| FN-056 Keep an asset card | shared | 5: BP-ASSETS-01, BP-ASSETS-02, BP-ASSETS-14, BP-ASSETS-15, BP-ASSETS-16 | BP-ASSETS-01: POST /api/v1/modules/assets/cards; BP-ASSETS-02: POST /api/v1/modules/assets/cards/:id/photos |
| FN-057 Count assets | shared | 4: BP-ASSETS-11, BP-ASSETS-12, BP-ASSETS-14, BP-ASSETS-15 | BP-ASSETS-11: POST /api/v1/modules/assets/counts; BP-ASSETS-12: GET /api/v1/modules/assets/counts/:id/result |

## F-23 Maintenance feature (maintenance)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-058 Raise a maintenance request | shared | 7: BP-MAINTENANCE-01, BP-MAINTENANCE-02, BP-MAINTENANCE-03, BP-MAINTENANCE-15, BP-MAINTENANCE-16, BP-MAINTENANCE-17 ... | BP-MAINTENANCE-01: POST /api/v1/modules/maintenance/requests; BP-MAINTENANCE-02: POST /api/v1/modules/maintenance/requests/:id/photos |
| FN-059 Plan, assign and carry out a work order | shared | 11: BP-MAINTENANCE-04, BP-MAINTENANCE-05, BP-MAINTENANCE-06, BP-MAINTENANCE-07, BP-MAINTENANCE-08, BP-MAINTENANCE-14 ... | BP-MAINTENANCE-04: POST /api/v1/modules/maintenance/orders; BP-MAINTENANCE-05: POST /api/v1/modules/maintenance/orders/:id/assign |
| FN-064 Web screens for work requests | process-specific | 1: BP-MAINTENANCE-09 | BP-MAINTENANCE-09: process title: Web screens for work requests |
| FN-065 Web screens for work orders and My work orders | process-specific | 1: BP-MAINTENANCE-10 | BP-MAINTENANCE-10: process title: Web screens for work orders and My work orders |
| FN-066 My work orders on the phone app and PWA | process-specific | 1: BP-MAINTENANCE-11 | BP-MAINTENANCE-11: process title: My work orders on the phone app and PWA |

## F-24 Purchase request feature (wms)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-060 Create and submit a purchase request | shared | 12: BP-PROCUREMENT-01, BP-PROCUREMENT-02, BP-PROCUREMENT-03, BP-PROCUREMENT-04, BP-PROCUREMENT-05, BP-PROCUREMENT-06 ... | BP-PROCUREMENT-01: POST /api/v1/modules/procurement/purchase-requests; BP-PROCUREMENT-02: GET /api/v1/modules/procurement/purchase-requests/:id |

## F-25 Exam feature (exam)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-061 Author an exam | shared | 3: BP-EXAM-01, BP-EXAM-02, BP-EXAM-07 | BP-EXAM-01: POST /api/v1/modules/exam/authoring/:entity_type; BP-EXAM-02: POST /api/v1/modules/exam/authoring/:entity_type |
| FN-062 Run an exam session | shared | 4: BP-EXAM-03, BP-EXAM-04, BP-EXAM-06, BP-EXAM-07 | BP-EXAM-03: GET /api/v1/modules/exam/exam-sessions/available; BP-EXAM-04: GET /api/v1/modules/exam/exam-sessions/:id |
| FN-063 Grade an exam | shared | 2: BP-EXAM-05, BP-EXAM-07 | BP-EXAM-05: GET /api/v1/modules/exam/grading-queue; BP-EXAM-07: GET /api/v1/modules/exam/grading-queue |

## F-26 Production feature (mes)

| Function | Kind | Processes | Evidence |
|---|---|---|---|
| FN-067 Security: MES data paths (crafted writes, cross-company reads, token and host, uploads, webhooks, approval) -- | process-specific | 1: BP-MES-04 | BP-MES-04: process title: Security: MES data paths (crafted writes, cross-company reads, token and host, uploads, webhooks, ap |

## Validation run (BA, T-2675 rework)

All 224 BP ids exist; every function has an existing feature and at least one process; every evidence string was re-found in the cited process's task routes, forms or functions (0 mismatches); `check_catalog.py` prints PASS. Ten sampled rows, each with its quoted evidence:

- FN-018 Reconcile the ledger: BP-STOCK-21 via `GET /api/v1/modules/stock/reconcile`.
- FN-009 Call an outside system (webhook): BP-DESIGNER-30 via `POST /api/v1/webhooks/subscriptions`.
- FN-033 Maintain places and locations: BP-STOCK-09 via `GET /api/v1/modules/stock/frozen-locations`.
- FN-016 Reverse a posted document: BP-STOCK-44 via `POST /api/v1/modules/stock/documents/:id/reverse`.
- FN-064 Web screens for work requests: BP-MAINTENANCE-09, process-specific (no task route).
- FN-058 Raise a maintenance request: BP-MAINTENANCE-18 via `POST /api/v1/modules/maintenance/requests/:id/photos`.
- FN-031 Share stock access: BP-TENANT-ADMIN-45 via `GET /api/v1/identity/shared-stock-access`.
- FN-042 Design and publish a process definition: BP-STOCK-38 via `POST /api/v1/definitions`.
- FN-025 Search and filter records: BP-DESIGNER-09 via `GET /api/v1/entity-views`.
- FN-051 Issue a stock document: BP-STOCK-44 via `stock.post_document`.

Links are route/form/function matches, so a security process that exercises a route is linked to the function that route serves.
