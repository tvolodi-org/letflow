# Process designer — slice 1: the read view

Status: delivered with T-1520 (D-114 item 2). Slice 2 (editing in the same picture) is delivered with T-1563, see the section "Slice 2: editing in the diagram". Slice 3A (versions list and read-only diff) is delivered with T-1588, see the last section.

The definition format stays the **single source of truth**. Agents and the editor write the definition; the picture
is always drawn from it and never saved. This slice adds a read-only diagram on the Definitions screen
(`definitions/:id`, "Diagram | Editor" switch) and on the instance detail (Graph tab, with the live path).

## Library choice

| option | licence | bundle | verdict |
|---|---|---|---|
| React Flow `@xyflow/react` 12 + `@dagrejs/dagre` 3 | MIT / MIT | no change: both already ship with the editor; the diagram chunk is lazy-loaded (`React.lazy`) | **chosen**: zoom, pan, minimap and node focus built in; `onlyRenderVisibleElements` for big graphs |
| elkjs | EPL-2.0 | about 1.5 MB | rejected: licence is outside MIT/Apache |
| own SVG | n/a | small | rejected: it would re-implement pan, zoom, focus and minimap; revisit only if React Flow blocks slice 2 |

`web/package.json` also lists a stale `reactflow` 11 that nothing imports; it is left alone here.

## What the definition holds

A definition graph is `nodes[] {id, node_type, label, attributes (JSON string)}` and
`edges[] {id, source, target, condition?, is_default?}` (`web/src/types/api.ts`, checks in
`lib/letflow/definitions/graph.ex`). Node types: START, END, HUMAN_TASK, SERVICE_TASK, EXCLUSIVE_GATEWAY,
PARALLEL_GATEWAY, TIMER, SUB_PROCESS. What the picture does with each piece:

| where | key / field | decision |
|---|---|---|
| node | `node_type`, `label` (null shows the type name) | SHOWN: shape and text |
| node | `id` | SUMMARISED: details panel, mono |
| node | `position` (editor only) | IGNORED: the layout is computed |
| HUMAN_TASK | `role`, `assignee_type`, `assignee_ref` | SHOWN: sub-line (role, else assignee_ref); listed in details |
| HUMAN_TASK | `form_schema` | SUMMARISED: "Form: N fields", keys and titles (at most 12); schema bodies and `x-ui` expressions are never rendered |
| HUMAN_TASK | `validation_script_key` | SUMMARISED: key only |
| HUMAN_TASK | `distinct_from` (four-eyes rule) | SUMMARISED: "Must differ from: <step labels>" |
| HUMAN_TASK / SERVICE_TASK | `module_writes` | SUMMARISED: handler names only (`post_document`, ...); `args` are never shown |
| SERVICE_TASK | `service_id` | SUMMARISED: "Service: <id>" |
| SERVICE_TASK | `endpoint` | SUMMARISED: scheme and host only (a path or query may carry a token); a malformed URL shows "endpoint set" |
| SERVICE_TASK | `script_key`, `script_version`, `timeout_ms` | SHOWN: `script_key` as the sub-line; version and timeout in details |
| TIMER | `duration_iso8601` | SHOWN: sub-line, raw (for example `PT15M`) |
| SUB_PROCESS | `definition_name` (child definition, `Letflow.Engine.SubProcess`), `interface` | SHOWN: double border, `definition_name` in details; `interface` DOCUMENTED only |
| edge | `condition` | SHOWN: edge label (cut; full text in the tooltip and the step list) |
| edge | `is_default` | SHOWN: label "default" |
| any other key | | DOCUMENTED: counted as "n other attributes", values never shown |

Values are plain text (no HTML, no links). The keys the code knows are `FORMAT_KEYS` in
`web/src/components/diagram/diagramConfig.ts`; a test checks that every key there and every attribute key of the
shipped packs (`priv/modules/*/pack.json`) is named in this table.

**From the definition alone** the picture shows type, label, role or assignee, timer duration, script key, edge
conditions, the default edge and the sub-process marker. **Status and path need instance data.**

## Instance path

Inputs, all from responses the page already reads: `status`, `current_nodes`, `error_detail.affected.node_id`
(the error attribution source; an `affected` of kind "field" or none is shown as a banner, no step is marked error)
and the full timeline. The timeline is read page by page (page size 200) until `next_cursor` is null, at most 25
pages; while the instance is ACTIVE all pages are re-read every 2 s (5 s beyond 3 pages), and once more when it
ends. Completion evidence is only `TASK_COMPLETED`, `SERVICE_TASK_COMPLETED`, `SCRIPT_TASK_COMPLETED` and
`TIMER_FIRED` (the events with a top-level `node_id`); `EXECUTION_ERROR` and `SUB_PROCESS_COMPLETED` carry none.
From REQ-793 the engine records a `NODE_ENTERED` event (`node_id`, `node_type`, `via_edge_id`) for every node a
token enters, for moves committed after that deploy; instances that moved earlier have none, so gateways,
sub-processes and END are still inferred for them (the screen requirement owns reading the new event).

The rule (`web/src/utils/canvas/instancePath.ts`, "segment attribution") asserts only what holds in every run that
agrees with the evidence; anything else is shown **Not certain** (dashed), never as a taken path:

- A completed step has certainly been left (the engine moves the token on in the same transaction). START has been
  left once the instance started.
- A *segment* is a way between two such facts through steps with no events of their own. Each segment gets a count
  of how often the token went along it; the counts must add up to the completions and entries of the steps at both
  ends. Where the counts force a segment, it is proven: the steps every path of it passes are **Done** and the
  connections it must use are **taken**. Example: with `G → A → C` and a direct `G → C`, A completed and C active,
  the direct connection is shown not taken.
- A parallel join has no event and its waiting state is not exposed by any API; when the last branch arrives it
  fires and moves on in the same transaction (`lib/letflow/design/req051-parallel-gateway-split-join.md` §4). So
  **a parallel join is shown done once anything after it has certainly run**. Example: both branches completed and
  the step after the join active: the join is done and its outgoing connection is taken.
- **Skipped** needs proof: a done decision with one branch taken, and the step reachable only through an untaken
  branch that no live token can reach again. Unreached parallel branches stay "Not reached".
- When pages are missing ("history incomplete", with Retry) or the counts contradict the graph ("history could not
  be reconciled"), every inferred step and connection becomes Not certain; evidence and current steps stay.

## Accessibility

Nodes are focusable (Tab), with an accessible name "label, type, state"; Enter opens the details panel, Escape
closes it. Status is a word and a glyph, never colour alone. The **Steps** view (a button next to Diagram) lists
every step in reading order with its type, state and outgoing connections, and doubles as the screen-reader view.
Edges are never animated (dashes are reserved for "Not certain"). Light and dark come from the design tokens.

## Large definitions

Starting values in `diagramConfig`: above 150 nodes the minimap is off and only visible elements are rendered;
above 400 nodes only the step list is shown, with a banner. Below 640 px of width the step list replaces the canvas;
from 900 px the details panel sits beside the canvas and a plain chain is laid out left to right (any other graph
takes the direction that shows more of it at a readable scale).

## Readability and routing

The first view never shrinks the drawing below 0.9 (`diagramConfig.readableZoom`), so canvas text stays legible; a
larger drawing starts at its beginning and is panned (the "fit view" control still shows it whole). An instance view
starts with its active or failed step in view. Task boxes are sized so a label up to the edge-label length fits at
1:1 (two lines at most). A compact shape's box includes its caption, edge labels get their own space in the dagre
layout, and edges follow the dagre route as a smooth curve, so no label covers a caption and an edge that skips ranks
bends around the steps between its ends. React Flow's screen-reader texts (`ariaLabelConfig`) come from the catalog
in en/ru/kk and are worded for a read-only view.

## Slice 2 hooks

The editor (`ProcessCanvas`) stays as it is and stays mounted while the diagram is shown, so unsaved edits are safe
(the diagram then shows "Preview of unsaved changes"). Editing in the diagram itself, saving layout, export and a
version diff are out of this slice. A node-entered event in the backend would let the path stop inferring gateways;
it is not part of this slice.

## Slice 2: editing in the diagram (T-1563)

Status: delivered with T-1563. The picture is still the definition: the edit model is the `DefinitionGraph` itself
(`web/src/utils/canvas/graphEdit.ts`, immutable functions; `editHistory.ts`, a bounded undo/redo stack of snapshots).
There is no second canvas model. Keys the diagram does not edit (`form_schema`, `module_writes`, `interface`,
`distinct_from`, `endpoint`, unknown keys) are carried through unchanged. A node's `attributes` is an object on the wire
(the server does not decode strings); the legacy JSON-string form is only read, never written. A node's position is
`attributes.position {x, y}`; steps without one get the automatic left-to-right layout when editing starts.

- **Where.** A third switch state "Edit diagram" (Diagram | Edit diagram | Editor) on the Definitions page, shown to
  callers who may design definitions. `DiagramEditPane` seeds a draft, runs the live check and saves.
- **Edit.** Add a step (any type except a second START), drag, connect handle to handle (handles show only in edit
  mode), delete, edit the label and the flat properties of the type: role and assignee (human task), script key and
  version as ONE unit (service task; a service binding is replaced only by the explicit "Use script instead"), duration
  (timer), definition name (sub-process), a connection's condition and default flag. Illegal edits (self-loop, duplicate
  or reversed connection, deleting START) are refused with a spoken message.
- **Keyboard.** Tab to a step, Enter opens its panel; Alt+Arrow nudges (Shift = far); the panel's "Connect from this
  step" select and its connection rows (Edit, Delete connection) reach every edge without a pointer; Delete; Ctrl/Cmd+Z and
  Ctrl+Shift+Z / Ctrl+Y (ignored while typing); Escape closes. Actions are announced in an `aria-live` region. Under
  640 px the canvas is replaced by an editable step list.
- **Live validation.** `POST /definitions/:id/validate` takes an optional `{"graph": ...}` body and runs the same
  validators as the server's stored check, persisting nothing; the web debounces (700 ms), keeps one request in flight and
  drops answers for older drafts. Violations carry only code and message, so `violationAnchor.ts` marks the node or edge a
  message names (only an id that exists in the draft); the marker is a glyph and a word.
- **Save.** Only existing routes: a DRAFT is saved with `PATCH /definitions/:id` and the body `{graph}`; any other status
  is saved as a new draft with `POST /definitions` (next version, `copy_variable_schemas_from` keeps the declared
  variables). Create/update answer 422 for structure, attribute, edge and flow violations, so Save is off while one is
  present (`ADVISORY_CODES` = the semantic codes; everything else blocks). Updates are last write wins on the server; the
  web asks first when `updated_at` changed since editing began (best effort, a window remains). 409 cases (not a draft,
  module-owned, version exists) each have their own banner.
- **Not here.** Structured attributes (still the Editor), new unsaved definitions, autosave, a server-side revision check.
  The Editor and the diagram draft never hold two divergent unsaved states: each is locked while the other is dirty.

## Slice 3A: versions list and read-only diff (T-1588)

Web only; no backend, route or permission change. The definition page gets a fourth view, **Versions** (every saved
definition, not a new unsaved one): a table of the versions of the definition (version, status, creator, created) and a
comparison of two of them on ONE diagram. There is no restore here (the rollback page is separate).

- **Diff** (`utils/canvas/graphDiff.ts`, pure). Steps are matched by id; changed = `node_type`, `label` or an attribute
  differs (`position` is not a change, the layout is computed). Only field NAMES are reported, never values (endpoints,
  forms and script arguments may be sensitive). Connections are matched by their (source, target) endpoints, never by id
  alone: the editor reuses the lowest free `e_N`, so an id can come back with other endpoints. A moved connection is one
  removed plus one added; same endpoints are changed/unchanged by `condition` and `is_default`. The merged graph holds
  both versions; every connection in it gets a fresh diagram id (`d_<kind>_<n>`), the input ids stay in `origin`.
- **Marking.** Added = word + dot glyph + solid border; Removed = word + dash glyph + dashed border, label struck through;
  Changed = word + half glyph + double border. Steps carry a pill, connections a label chip, the step list and the details
  panel the same words; the accessible name of a step ends with the word. `ProcessDiagram` takes an optional `diff`
  (never together with `path`).
- **Versions query.** `GET /definitions?name=` is a substring match, so `definitionsApi.getVersions` follows the cursor
  (200 per page, at most 5 pages) and keeps exact name matches only; with the cap hit the pane shows a banner. The
  definition list and rollback pages read the same call and no longer see definitions with overlapping names.
- **Creator.** The API returns only the creator's id, so the table shows its first 8 characters (full id in the title)
  and the owner module when set. A creator name needs a backend field (for example `created_by_name`).
- **Not here.** Restore, three-way diff, value-level diff, a URL for the selection, position changes.
