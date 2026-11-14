# List and document screens: where title, primary actions and filters sit (T-1953)

Inventory at `a378c3fba` (T-1946 merged), re-checked against the source in this task. Rule: `page-header-actions.md`.
Commands that produced it:

```
grep -rln "<ListDetail\b\|<DocLayout\b\|PageLayout\|PageHeader" web/src          # which screens
grep -rn "<Plus\b"  web/src --include=*.tsx | grep -v __tests__                  # create controls
grep -rln "lf-doc__tools\|lf-reg__tools\|lf-reg__listhead" web/src --include=*.tsx | grep -v __tests__   # list panes
```

Before the fix, only the two document screens put a create control in the list pane. Every other screen already had it
in the header's right side.

| Screen (source) | Shell | Title | Primary / creation | Filters | Differed? |
|---|---|---|---|---|---|
| Asset documents (`modules/assets/documents/DocumentsWorkspace.tsx`) | PageHeader + DocLayout | header | was: 6 "New" buttons in the list pane. Now: one `NewMenu` (6 kinds) in the header | list pane `lf-doc__tools` | **yes, fixed** |
| Stock documents (`modules/stock/documents/DocumentsWorkspace.tsx`) | PageHeader + DocLayout | header | was: one "New document" in the list pane, kind chosen in the form. Now: one `NewMenu` (7 kinds) in the header; the empty-state button stays (R2) | list pane `lf-doc__tools` | **yes, fixed** |
| Asset cards (`modules/assets/AssetCardsPage.tsx`) | AssetsShell(PageHeader) + ListDetail | header | header right: help, "Change of kind", "Create" | ListDetail `tools` | no |
| Asset balances, movements (`modules/assets/register/*`) | PageHeader + ListDetail / journal | header | none (read only) | FilterBar in the list pane | no |
| Stock balances, movements (`modules/stock/register/*`) | PageHeader + ListDetail / journal | header | none | FilterBar | no |
| Stock counts (`modules/stock/counts/CountsPage.tsx`) | PageHeader + ListDetail | header | header right "New count" | `tools` | no |
| Catalog items (`modules/catalog_items/items/ItemsPage.tsx`) | PageHeader + RegistryList | header | none yet (create wiring pending); reset layout in the header | RegistryList tools | no |
| Lots (`modules/catalog_items/LotsPage.tsx`) | PageHeader + ListDetail | header | header right `createAction` | `tools` | no |
| Codes (`modules/codes/CodesPage.tsx`) | PageHeader + ListDetail | header | header right "Receive codes" | `tools` | no |
| Locations (`modules/locations/LocationTreePage.tsx`) | LocationsShell + ListDetail tree | header | header right "Create"; "add child" in the detail panel (R2 exception) | `tools` | no |
| Org, five screens (`modules/org/OrgScreen.tsx`) | PageHeader + ListDetail tree | header | header right `org-create`; units "add child" in the detail panel | `tools` | no |
| Task inbox (`pages/tasks/TaskInboxPage.tsx`) | PageHeader + ListDetail | header | none | `tools` | no |
| Module rollouts (`pages/admin/module-rollouts/ModuleRolloutsPage.tsx`) | PageHeader + ListDetail | header | help only; start/resume are record actions | list | no |
| DLQ (`pages/dlq/DlqPage.tsx`) | PageLayout | header | none | `FilterBar` under the header | no |
| Webhooks (`pages/dlq/WebhooksPage.tsx`) | PageLayout + ListDetail | header | header right "+ New Subscription" (English-only label: follow-up) | none | no |
| Definitions (`pages/definitions/DefinitionListPage.tsx`) | PageLayout | header | header right import + create | FilterBar under the header | no |
| Entities CRUD (`pages/entities/EntityCrudPage.tsx`) | PageLayout | header | header right create (`entities.crud.list.createAction`) | under the header | no |
| Entity browser, reports (`pages/entities/*`) | PageLayout | header | none / builder actions | under the header | no |
| Exam question bank, builder list (`modules/exam/*`) | PageLayout | header | header right New / Create | search under the header | no |
| Currencies (`pages/admin/currencies/CurrenciesPage.tsx`) | PageHeader | header | none (seeded list) | search row directly under the header | no |
| Print templates (`pages/admin/PrintTemplatesPage.tsx`) | PageLayout | header | the editor is the create form | none | no |
| Users, Groups, Tokens, Audit (`pages/admin/*.tsx`), Tenants (`pages/admin/tenants/TenantsPage.tsx`) | own `<h2>`/`<h1>` row | own row | right side (`marginLeft: auto`) | under the row | placement no; markup legacy, follow-up |
| Instances board (`pages/instances/InstanceBoardPage.tsx`) | own `<h2>` row | own row | right side: "Start instance" (primary) | under the row | placement no; markup legacy, follow-up |

## Follow-ups (not in this task)

- Users, Groups, Tokens, Audit, Tenants, Instances board: move the hand-made header rows to `PageHeader` and the
  English-only labels (`+ New Group`, `+ Issue token`, `+ New Subscription`) to the catalogs.
- `AssetCardActionsMenu`, `AssetFormMenu`, `OfficialFormMenu`, `LanguageSwitcher` each copy the open/close/arrow-key
  logic of `NewMenu`; a shared menu hook would remove four copies.
- The design repo has no dropdown component yet (`platform/NOTES.md` section 7); `NewMenu` reuses the in-product
  `lf-lang`/`lf-formmenu` markup.
