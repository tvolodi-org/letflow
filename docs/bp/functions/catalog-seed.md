# Function catalog seed

Written by the business analyst (T-2675, owner decision D-192). Machine twin: `catalog-seed.json` (loader TREE-3, T-2669). A **function** is a business capability named by the BA; a **feature** is a group of functions; a function is used by one or more business processes (BP ids of `docs/bp/*.json`, many-to-many). System functions, scripts and rules only support a function and are evidence links, not rows here.

Applications: `platform` (includes the areas platform, tenant-admin, designer, master), `wms` (areas stock, procurement), `assets`, `exam`, `maintenance`, `mes`. Order of rows: stock set, assets, procurement, then platform set, then the rest.

UAT/seed status: names are a BA proposal for the owner's one-time review; a function is listed only where at least one process in the map exercises it. The owner example "document preview" is not a row: no process in the map names a preview of a document (only a notification template preview, inside the notification function), so it is left out rather than invented.

## Features

| Feature | Title | Application | Area | Functions |
|---|---|---|---|---|
| F-01 | Stock posting document feature | wms | stock | 13 |
| F-02 | Stock counting document feature | wms | stock | 4 |
| F-03 | Stock reporting and Excel exchange feature | wms | stock | 2 |
| F-04 | Old-app phone operations feature | wms | stock | 5 |
| F-05 | Asset register document feature | assets | assets | 9 |
| F-06 | Asset counting document feature | assets | assets | 2 |
| F-07 | Asset reporting feature | assets | assets | 1 |
| F-08 | Purchase request approval feature | wms | procurement | 5 |
| F-09 | Master data maintenance feature | platform | master | 7 |
| F-10 | Barcode, QR and label feature | platform | master | 1 |
| F-11 | Company administration feature | platform | tenant-admin | 7 |
| F-12 | Access control feature | platform | tenant-admin | 6 |
| F-13 | Module and configuration management feature | platform | tenant-admin | 6 |
| F-14 | Notification and message feature | platform | tenant-admin | 2 |
| F-15 | Process definition design feature | platform | designer | 5 |
| F-16 | Process execution and task work feature | platform | designer | 4 |
| F-17 | Record management feature | platform | designer | 5 |
| F-18 | Automation and integration feature | platform | designer | 5 |
| F-19 | Document printing and retention feature | platform | designer | 3 |
| F-20 | Tenant lifecycle feature | platform | platform | 7 |
| F-21 | Platform operation feature | platform | platform | 4 |
| F-22 | Problem report handling feature | platform | platform | 1 |
| F-23 | Public access feature | platform | platform | 2 |
| F-24 | Security assurance feature | platform | platform | 9 |
| F-25 | Maintenance work request and order feature | maintenance | maintenance | 6 |
| F-26 | Exam authoring and sitting feature | exam | exam | 6 |
| F-27 | Manufacturing module shell feature | mes | mes | 1 |

## Functions

| Function | Title | Feature | Application | Processes (BP) |
|---|---|---|---|---|
| FN-001 | Record a goods receipt | F-01 | wms | STOCK-01 |
| FN-002 | Record a goods issue | F-01 | wms | STOCK-02, STOCK-40, STOCK-41 |
| FN-003 | Write off stock | F-01 | wms | STOCK-03 |
| FN-004 | Transfer stock between places | F-01 | wms | STOCK-04 |
| FN-005 | Hand stock over to another responsible person | F-01 | wms | STOCK-05 |
| FN-006 | Return goods | F-01 | wms | STOCK-06 |
| FN-007 | Enter opening balances | F-01 | wms | STOCK-07 |
| FN-008 | Approve and post a stock document (four-eyes Post task) | F-01 | wms | STOCK-01, STOCK-02, STOCK-03, STOCK-04, STOCK-05, STOCK-06, STOCK-07, STOCK-26, STOCK-33, STOCK-35, STOCK-37, STOCK-38, TENANT-ADMIN-20, TENANT-ADMIN-21 |
| FN-009 | Reverse a posted document or cancel an issued one | F-01 | wms | STOCK-12, STOCK-44 |
| FN-010 | Find, correct and discard a draft stock document | F-01 | wms | STOCK-14 |
| FN-011 | Draft a stock document from a voice or typed phrase | F-01 | wms | STOCK-17, STOCK-25 |
| FN-012 | Control negative balances per ledger | F-01 | wms | STOCK-40, STOCK-41, TENANT-ADMIN-22 |
| FN-013 | Move stock to an asset (change of kind, stock side) | F-01 | wms | ASSETS-07, STOCK-18 |
| FN-014 | Quick count of one item at one place | F-02 | wms | STOCK-08, STOCK-39 |
| FN-015 | Issue and close a stock count order | F-02 | wms | STOCK-09 |
| FN-016 | Sign a count sheet, review differences and post the result | F-02 | wms | STOCK-10 |
| FN-017 | Export count paperwork and official forms (Inv-10, Inv-18) | F-02 | wms | STOCK-11 |
| FN-018 | Show balances, movements and the stock card | F-03 | wms | STOCK-15 |
| FN-019 | Exchange balances through an Excel workbook (export, check, apply, cancel) | F-03 | wms | STOCK-13, STOCK-42 |
| FN-020 | Sign in the old phone app with the shared access value | F-04 | wms | STOCK-16, STOCK-24, STOCK-28, STOCK-29, STOCK-30, STOCK-31, STOCK-36, TENANT-ADMIN-15, TENANT-ADMIN-39, TENANT-ADMIN-45 |
| FN-021 | Post once per client id from the phone | F-04 | wms | STOCK-32 |
| FN-022 | Count from the phone with four-eyes on or off | F-04 | wms | STOCK-33, STOCK-34, STOCK-35 |
| FN-023 | Look up a scanned code and read stock from the phone | F-04 | wms | STOCK-16, STOCK-36 |
| FN-024 | Start a new company on stock with fresh-tenant defaults | F-04 | wms | STOCK-27 |
| FN-025 | Keep an asset card (register, correct, retire) | F-05 | assets | ASSETS-01 |
| FN-026 | Keep card photos | F-05 | assets | ASSETS-02, ASSETS-16 |
| FN-027 | Commission an asset into the register | F-05 | assets | ASSETS-03 |
| FN-028 | Change the responsible person of an asset | F-05 | assets | ASSETS-04 |
| FN-029 | Hand an asset over to another org unit | F-05 | assets | ASSETS-05 |
| FN-030 | Write off an asset | F-05 | assets | ASSETS-06 |
| FN-031 | Open the asset register from existing cards | F-05 | assets | ASSETS-08 |
| FN-032 | Reverse an asset document | F-05 | assets | ASSETS-09 |
| FN-033 | Find, correct and discard a draft asset document | F-05 | assets | ASSETS-10 |
| FN-034 | Order, sheet, scan and close an asset count | F-06 | assets | ASSETS-11 |
| FN-035 | Decide count results and sign an asset count | F-06 | assets | ASSETS-12 |
| FN-036 | Report asset balances, movements and reconcile | F-07 | assets | ASSETS-13 |
| FN-037 | Print the official asset card form (DA-2) | F-19 | platform | ASSETS-01 |
| FN-038 | Raise and submit a purchase request | F-08 | wms | PROCUREMENT-01 |
| FN-039 | Decide a purchase request (approve, reject, return) | F-08 | wms | PROCUREMENT-02 |
| FN-040 | Record handler, supplier and order of an approved line | F-08 | wms | PROCUREMENT-03 |
| FN-041 | Cancel a line and close a purchase request | F-08 | wms | PROCUREMENT-04 |
| FN-042 | Attach and download purchase request files | F-08 | wms | PROCUREMENT-05 |
| FN-043 | Identify the company from its address and sign in | F-11 | platform | TENANT-ADMIN-01, TENANT-ADMIN-42 |
| FN-044 | Show my access, modules and first screen | F-11 | platform | TENANT-ADMIN-02 |
| FN-045 | Maintain company users (create, import, deactivate) | F-11 | platform | TENANT-ADMIN-03, TENANT-ADMIN-04, TENANT-ADMIN-05, TENANT-ADMIN-06, TENANT-ADMIN-07 |
| FN-046 | Manage groups and role bindings | F-12 | platform | TENANT-ADMIN-08, TENANT-ADMIN-09 |
| FN-047 | Read and change role grants | F-12 | platform | TENANT-ADMIN-10 |
| FN-048 | Grant a role access to a part of the organisation (scope) | F-12 | platform | TENANT-ADMIN-11, TENANT-ADMIN-12 |
| FN-049 | Name the first administrator | F-12 | platform | TENANT-ADMIN-13 |
| FN-050 | Issue and revoke API tokens | F-12 | platform | TENANT-ADMIN-14 |
| FN-051 | Set company settings, appearance and logo | F-13 | platform | TENANT-ADMIN-16, TENANT-ADMIN-17 |
| FN-052 | Export and import the company configuration bundle | F-13 | platform | TENANT-ADMIN-18 |
| FN-053 | Install, upgrade and remove modules and solutions | F-13 | platform | DESIGNER-05, TENANT-ADMIN-19 |
| FN-054 | Install the manufacturing module shell | F-27 | mes | MES-01 |
| FN-055 | Switch the four-eyes rule per process step | F-12 | platform | TENANT-ADMIN-20 |
| FN-056 | Read the audit log | F-11 | platform | TENANT-ADMIN-23 |
| FN-057 | Read my notifications | F-14 | platform | TENANT-ADMIN-24 |
| FN-058 | Edit notification templates and read the delivery log | F-14 | platform | TENANT-ADMIN-26 |
| FN-059 | Switch currencies and choose the company currency | F-13 | platform | TENANT-ADMIN-27 |
| FN-060 | Override screen wording | F-13 | platform | TENANT-ADMIN-28 |
| FN-061 | Define document number sequences | F-13 | platform | TENANT-ADMIN-29 |
| FN-062 | Export company data sets | F-11 | platform | TENANT-ADMIN-30 |
| FN-063 | Read help topics and use the master-data import page | F-11 | platform | TENANT-ADMIN-31 |
| FN-064 | My settings and problem reports | F-11 | platform | TENANT-ADMIN-25 |
| FN-065 | Work my tasks in My Tasks | F-16 | platform | DESIGNER-16, TENANT-ADMIN-32 |
| FN-066 | Draft, check and change a process definition | F-15 | platform | DESIGNER-01 |
| FN-067 | Activate, retire and archive a process definition | F-15 | platform | DESIGNER-02 |
| FN-068 | Export, import and roll back a process definition | F-15 | platform | DESIGNER-03 |
| FN-069 | Promote a definition between tenants with review | F-15 | platform | DESIGNER-04, PLATFORM-14 |
| FN-070 | List services a process may call | F-15 | platform | DESIGNER-23, PLATFORM-11 |
| FN-071 | Define a record type and activate it | F-17 | platform | DESIGNER-06, DESIGNER-33 |
| FN-072 | Create, change, find and attach records | F-17 | platform | DESIGNER-07 |
| FN-073 | Import and export records | F-17 | platform | DESIGNER-08 |
| FN-074 | Save and share a list view | F-17 | platform | DESIGNER-09 |
| FN-075 | Derive field values before a record is saved | F-17 | platform | DESIGNER-10 |
| FN-076 | Run a script after a record event | F-18 | platform | DESIGNER-11 |
| FN-077 | Write, test, publish and withdraw a business rule script | F-18 | platform | DESIGNER-12, DESIGNER-13, DESIGNER-32 |
| FN-078 | Start a process and follow it | F-16 | platform | DESIGNER-14 |
| FN-079 | Attach files to a running process | F-16 | platform | DESIGNER-15 |
| FN-080 | Retry or discard failed jobs | F-16 | platform | DESIGNER-17 |
| FN-081 | Notify another system by webhook | F-18 | platform | DESIGNER-18, DESIGNER-30 |
| FN-082 | Map fields for an integration | F-18 | platform | DESIGNER-19 |
| FN-083 | Run a job on a schedule | F-18 | platform | DESIGNER-20 |
| FN-084 | Govern documents: retention, hold, print layout | F-19 | platform | DESIGNER-21 |
| FN-085 | Print code labels as PDF | F-19 | platform | MASTER-10 |
| FN-086 | Share a record read-only by public handle | F-23 | platform | DESIGNER-22 |
| FN-087 | Check a certificate by its public handle | F-23 | platform | EXAM-06, PLATFORM-23 |
| FN-088 | Register a tenant and look it up | F-20 | platform | PLATFORM-01 |
| FN-089 | Suspend, reactivate and purge a tenant | F-20 | platform | PLATFORM-02 |
| FN-090 | Give a company its own host name | F-20 | platform | PLATFORM-03 |
| FN-091 | Set a tenant script policy (kill switch) | F-20 | platform | PLATFORM-04 |
| FN-092 | Onboard a company and bind its identity realm | F-20 | platform | PLATFORM-05 |
| FN-093 | Provision a tenant through the provisioner interface | F-20 | platform | PLATFORM-06, PLATFORM-18 |
| FN-094 | Sign up a new company and find a company by e-mail | F-20 | platform | PLATFORM-13, PLATFORM-19 |
| FN-095 | Roll a module version out to the fleet | F-21 | platform | PLATFORM-07 |
| FN-096 | Run a tenant-schema migration across tenants | F-21 | platform | PLATFORM-08 |
| FN-097 | Retire the oldest month of event history | F-21 | platform | PLATFORM-09 |
| FN-098 | Watch platform health, readiness and metrics | F-21 | platform | PLATFORM-10, PLATFORM-15 |
| FN-099 | Handle problem reports from companies | F-22 | platform | MAINTENANCE-12, MAINTENANCE-13, MAINTENANCE-20, PLATFORM-12 |
| FN-100 | Maintain legal entities and sites | F-09 | platform | MASTER-01 |
| FN-101 | Maintain the org unit tree | F-09 | platform | MASTER-02 |
| FN-102 | Maintain positions and employees | F-09 | platform | MASTER-03 |
| FN-103 | Maintain the location tree | F-09 | platform | MASTER-04 |
| FN-104 | Link org units to locations | F-09 | platform | MASTER-05 |
| FN-105 | Load catalog and org data from a file | F-09 | platform | MASTER-06, MASTER-07, MASTER-15 |
| FN-106 | Maintain lots of an item | F-09 | platform | MASTER-08 |
| FN-107 | Receive, assign, release and retire a code | F-10 | platform | MASTER-09, MASTER-16 |
| FN-108 | Report a fault on an asset (work request) | F-25 | maintenance | MAINTENANCE-01, MAINTENANCE-02 |
| FN-109 | Review work requests (list, read, reject) | F-25 | maintenance | MAINTENANCE-03 |
| FN-110 | Create and assign a work order | F-25 | maintenance | MAINTENANCE-04, MAINTENANCE-05 |
| FN-111 | Report work done and close a work order | F-25 | maintenance | MAINTENANCE-06, MAINTENANCE-07 |
| FN-112 | Read and list work orders | F-25 | maintenance | MAINTENANCE-08 |
| FN-113 | Show work requests and orders on screens and phone | F-25 | maintenance | MAINTENANCE-09, MAINTENANCE-10, MAINTENANCE-11 |
| FN-114 | Keep the question bank | F-26 | exam | EXAM-01 |
| FN-115 | Build an exam | F-26 | exam | EXAM-02 |
| FN-116 | Find and start an exam | F-26 | exam | EXAM-03 |
| FN-117 | Sit an exam and submit | F-26 | exam | EXAM-04 |
| FN-118 | Grade short-text answers | F-26 | exam | EXAM-05 |
| FN-119 | See exam results and the certificate | F-26 | exam | EXAM-06 |
| FN-120 | Check the permission of the role on every route | F-24 | platform | ASSETS-15, DESIGNER-24, EXAM-07, MAINTENANCE-16, MASTER-11, MES-03, PLATFORM-16, PROCUREMENT-06, STOCK-21, TENANT-ADMIN-33, TENANT-ADMIN-44 |
| FN-121 | Refuse cross-tenant access with a uniform 404 | F-24 | platform | ASSETS-14, DESIGNER-25, DESIGNER-26, MAINTENANCE-15, MASTER-12, PLATFORM-17, PLATFORM-20, PROCUREMENT-07, STOCK-20, TENANT-ADMIN-34, TENANT-ADMIN-43, TENANT-ADMIN-46 |
| FN-122 | Refuse crafted bodies and write-target overwrites | F-24 | platform | ASSETS-17, DESIGNER-27, MAINTENANCE-14, MAINTENANCE-21, MASTER-13, MES-02, MES-04, PROCUREMENT-09, STOCK-19, TENANT-ADMIN-41 |
| FN-123 | Resolve token and host credentials safely | F-24 | platform | DESIGNER-28, MAINTENANCE-17, MASTER-14, PLATFORM-22, PROCUREMENT-11, STOCK-22, TENANT-ADMIN-37 |
| FN-124 | Validate uploads by type and size | F-24 | platform | ASSETS-16, DESIGNER-29, MAINTENANCE-18, PROCUREMENT-10, STOCK-23, TENANT-ADMIN-38 |
| FN-125 | Enforce separation of duties | F-24 | platform | DESIGNER-31, MAINTENANCE-19, PLATFORM-21, PROCUREMENT-08, STOCK-26, TENANT-ADMIN-40, TENANT-ADMIN-47 |
| FN-126 | Keep retries and concurrent decisions single-acting | F-24 | platform | PROCUREMENT-12, STOCK-43 |
| FN-127 | Guard privilege escalation and the last administrator | F-24 | platform | TENANT-ADMIN-35, TENANT-ADMIN-36 |
| FN-128 | Refuse the old address outside its rules | F-24 | platform | STOCK-24, STOCK-29, STOCK-30 |

## Coverage by area

| Area | Processes used by at least one function | of |
|---|---|---|
| assets | 17 | 17 |
| designer | 33 | 33 |
| exam | 7 | 7 |
| maintenance | 21 | 21 |
| master | 16 | 16 |
| mes | 4 | 4 |
| platform | 23 | 23 |
| procurement | 12 | 12 |
| stock | 44 | 44 |
| tenant-admin | 47 | 47 |

Every one of the 10 areas has at least one function.

Processes used by no function (named uncovered, left for the owner or a later pass): none.
