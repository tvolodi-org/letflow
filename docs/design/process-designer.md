# Process designer — slice 1: the read view

Status: delivered with T-1520 (D-114 item 2). Slice 2 (editing in the same picture) is a later task.

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
There is no node-entered event, so gateways, sub-processes and END are inferred.

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
from 900 px the details panel sits beside the canvas and a plain chain is laid out left to right.

## Slice 2 hooks

The editor (`ProcessCanvas`) stays as it is and stays mounted while the diagram is shown, so unsaved edits are safe
(the diagram then shows "Preview of unsaved changes"). Editing in the diagram itself, saving layout, export and a
version diff are out of this slice. A node-entered event in the backend would let the path stop inferring gateways;
it is not part of this slice.
