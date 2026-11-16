# Document panels and the user's layout

The effective `ui.document_layout` returned by `GET /api/v1/me/preferences` is the user's choice,
then the tenant's `ui.document_layout_default`, then `row`. `DocLayout` reads it through
`useDocumentLayout`; loading, failed reads and unknown values fall back to Row. Explicit layout props
remain available for previews. Pane sizes are separate preferences (`ui.layout`), remembered per screen.

Row places list | document header | lines beside one another when the available work area exceeds
900 px, including a 1440 px window with the side navigation open. All three remain present while
editing. On narrower work areas, opening a document replaces the list and stacks header above lines;
Back returns to the list. Tabs keeps the list beside one panel on desktop, and switches between Header
and Lines at both widths. New documents open on Header, existing documents on Lines.

The shared `DocumentWorkspace` / `DocumentRecord` adapter gives count orders the same grid. A count
order create/edit form has only order fields, so it uses `DocumentSingle`. Asset count sheets are not
implemented yet (`AssetCountWork` currently returns null); the shipped asset count order remains a
single record panel. Its future sheet must use the shared record's `lines` slot.

Inventory (derived with `rg 'DocLayout|CountSheet|area="lines"|lf-doc__lines' web/src --glob '*.tsx'`
and the `DOC_KINDS` registries):

| Family | Routes | Lines |
|---|---|---|
| Stock documents | `/admin/stock/documents`, `/new`, `/:id` | Receipt, issue, write off, transfer, hand over, return, opening; all use `DocLayout`, including create/edit. |
| Asset documents | `/admin/assets/documents`, `/new`, `/:id` | Commission, change, handover, writeoff, kind change, opening; all use `DocLayout`, including their specialised editors. |
| Stock counts | `/admin/stock/counts`, `/:id` | Sheet, scanner, entry log, differences and posting panels are inside the shared Lines cell. |
| Asset counts | `/admin/assets/counts`, `/:id` | Order only today; no shipped lines panel. Uses the document workspace for preference and narrow-screen behavior. |

`document-panel-layout.e2e.spec.ts` measures the real screens inside AppShell at 1440 and 390 px for
every registered document layout, switches both tabs, checks overflow and asserts every panel is a
direct child of the document grid. It is a local browser test: the fixed Stock CI job does not run the
general e2e suite. Frontend unit tests also pin count-panel containment and the Row splitter count.
