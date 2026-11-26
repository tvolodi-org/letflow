# Designer: one editor instead of two (T-2814, finding D4)

Status: PROPOSED, waits for the PM's answer. This note is Part 1 (docs only). Part 2, the
change in `web/`, is not started and must not start before the PM has read this note.

## The problem

The definition page (`web/src/pages/definitions/DefinitionEditorPage.tsx`) has a view switch
(`DefinitionViewSwitch`: Diagram | Versions | Edit diagram | Editor). Two of them edit a
process, and they are two different components with two different save paths:

- **Edit diagram** (`view = 'edit'`, `DiagramEditPane` and `DiagramEditor`, T-1563, T-2599).
- **Editor** (`view = 'editor'`, `ProcessCanvas`, `NodePalette`, `PropertyPanel`, REQ-431).

A user can open the Editor, which cannot build the pilot's process (platform function steps,
notification steps), and does not learn that the other tab can.

## What each tab can do today (from the code)

| Capability | Edit diagram | Editor | Evidence |
|---|---|---|---|
| Add step types: start, end, human task, service task, exclusive gateway, parallel gateway, timer, sub-process | yes (add-step select, all `NODE_TYPES`) | yes (palette, same 8 types) | `diagramConfig.ts` `NODE_TYPES`; `NodePalette.tsx` item list |
| Platform function picker and typed var/const mapping (`platform_call`) | yes | **no** | `NodeEditPanel.tsx` (T-2599); `grep platform_call PropertyPanel.tsx` finds 0 |
| Notification step (`notify`) | yes | **no** | `NodeEditPanel.tsx`, `notifyStep`; `grep notify PropertyPanel.tsx` finds 0 |
| Service-task attributes `endpoint`, `service_id`, `script_key`, `module_writes` | yes (`diagramConfig.ts` SERVICE_TASK list) | partial (PropertyPanel) | `diagramConfig.ts:36` |
| Connect with the server's rules (`connectionRefusal`), delete, undo and redo | yes | canvas based | `EditToolbar.tsx`, `graphEdit.ts` |
| Live check with the server validator, blocks Save on a violation | yes (`useValidateDraft`) | yes (validation summary bar) | `DiagramEditPane.tsx`; `ValidationSummaryBar.tsx` |
| Declared variables panel | yes (`VariablesPanel`) | no | `DiagramEditPane.tsx` |
| Save | "Save draft": PATCH for a DRAFT, POST next version otherwise | "Save" (DRAFT only) | `DiagramEditPane.tsx`; page `btn-save-definition` |
| Release | "Publish saved version" (`btn-publish-diagram`) | "Submit for Release" (`btn-submit-for-release`) | page lines ~843 and ~933 |
| **Show Raw JSON** | no | yes | page `btn-show-raw-json` |
| **Re-layout** (Dagre) | no (positions come from `withLayoutPositions` on open) | yes | page `btn-auto-layout` |
| Works on a non-DRAFT definition | yes (saves a new version) | no (read only) | page `isReadOnly` |

Both release buttons call the same function, `handleSubmitForRelease`. Only the label and
the place differ, so merging them loses no behaviour.

What the Guide says (T-2804/T-2805): the designer UAT list (`project/designer-uat-2026-11-25.md`,
D11) records that the screens have no Guide entry yet and that both tasks are queued. I found
no Guide text to keep in step. When the Guide lands it must describe the one surviving editor
only; this note is the reason to write it that way.

## Decision (proposed)

**Edit diagram stays; the Editor is removed from the switch.** The label becomes
"Edit" (en/ru/kk) so no one reads two "edit" tabs any more.

Reason:
1. It is the only one that can build the pilot's process (function picker, typed mapping,
   notification step, declared variables).
2. It works on every status (saves a next version), which the Editor cannot.
3. It already reuses the server's validator and `graphEdit` rules; the Editor keeps a second
   copy of the graph logic.

## What moves, and what is lost

| Item | Decision |
|---|---|
| Gateways and timers | Already in the surviving editor's add-step select; Part 2 adds a test that adds each of the 8 types. Nothing to move. |
| Raw JSON view | Moves to Edit as a read-only "Show JSON" toggle (a copy of the draft's graph). Editing raw JSON is dropped: it bypasses the connect rules. If the PM wants raw editing, say so; it is a separate task. |
| Re-layout | Moves to the Edit toolbar (call `withLayoutPositions` on the draft; undoable). |
| Submit for Release vs Publish | One button, the "Publish saved version" wording and gating (needs a saved draft with no open problem). `btn-submit-for-release` is removed. |
| Editor's `Save` (DRAFT only) | Replaced by "Save draft". |
| `?view=editor` links | Kept as an alias that opens Edit, so old bookmarks and the e2e specs work. |

## Part 2 plan (after the PM answers)

- `DefinitionViewSwitch`: drop the Editor button and the `editorLocked` rule; `view = 'editor'`
  maps to `'edit'`. Remove the "Editor has unsaved changes" lock banner and the two-state
  divergence code in the page.
- Delete (or leave unreferenced for one release) `ProcessCanvas`, `NodePalette`,
  `PropertyPanel` once nothing else imports them; first `git grep` each for other users.
- Add Show JSON and Re-layout to `EditToolbar`.
- Tests: mount `DiagramEditPane` with the shipped platform definition (the seeded v2
  register-tenant definition) and assert the function picker, the notification step, each of
  the 8 add-step types, Show JSON and Re-layout; rewrite the tests of the removed tab
  (`DefinitionEditorPage.diagram.test.tsx`, `...versions.test.tsx`, `processDesignerNote.test.ts`
  hits for `definition-view-editor`).
- PM 22:50 note: a new designer e2e spec must be added to `.github/workflows/designer-e2e.yml`
  in the same PR (the workflow runs only the pilot spec today). The Part 2 PR text says so.
- Screen change: the screenshot matrix and state table per the design-system skill.

## For the PM

Answer one thing: is "Edit diagram stays, raw JSON becomes read-only" the decision? Any other
answer changes the Part 2 plan. The task parks at this note.
