# Principles kept from the old frontend design-system text

The old `docs/frontend/design-system.md` (palette, typography, spacing, per-domain badge colour tables) is gone:
values come from the design repo (`letflow-design`, `platform/NOTES.md`) through the generated token file, see
[README.md](README.md). What follows is the part of that text that is behaviour, not value. Section
numbers cited in older documents (`design-system.md §7.3` and so on) map to the headings below.

## Destructive actions (was §1, §7.3)

Cancel, delete, discard and revoke never fire on one click. They use `ConfirmDialog`
(`web/src/components/ui/ConfirmDialog.tsx`), never `window.confirm`. Props: `open`, `onConfirm`, `onCancel`,
`title`, `body`, `confirmText`, `cancelText` (default "Cancel"), `confirmVariant="danger"`, `isLoading` (disables
both buttons while true).

## Status is always visible (was §1, §5)

Process, task and instance status is shown as a `StatusPill`: a word and a glyph, never colour alone. Each module
keeps its own map from status to tone and glyph.

## PaginationControls (was §7.8)

- Summary text shows the visible range and the total ("1-25 of 130"); when `totalItems` is `null` (cursor mode) it
  shows the range only.
- `page` is 1-indexed; `pageSize` is one of 25, 50, 100; `onPageSizeChange` is optional and omitting it hides the
  size selector.
- In cursor mode (`totalItems === null`) "next" is enabled by `hasNextPage` (for example `next_cursor` is not null);
  with a numeric total, "next" is computed from the page and the total and `hasNextPage` is ignored.
- Previous and next are real buttons, disabled (not hidden) at the ends.

## FilterBar (was §7.7)

Layout only. It renders its children (the page owns each control and its state) in a wrapping row and holds no
filter values. The "Clear filters" action appears only when `onClear` is given and `activeCount` is above zero.

## DynamicForm (was §7.6)

`DynamicForm` renders a form from the JSON Schema of a task node's `form_schema`
(`schema`, `onSubmit`, `submitLabel`, `isSubmitting`). Default mapping:

| JSON Schema | Input |
|---|---|
| `string` | text |
| `string`, `format: date` | date |
| `string`, `format: date-time` | datetime-local |
| `string`, `enum` | select |
| `number` / `integer` | number |
| `boolean` | checkbox |
| `string`, `maxLength > 200` | textarea |

The optional `x-ui.widget` override and the closed widget set are in
[`../frontend/x-ui-widget-vocabulary.md`](../frontend/x-ui-widget-vocabulary.md): tenant customisation is data,
never code. The renderers are restyled with the shared `Field` component.

## Toast (was §7.4)

Top right, stacked, at most 4 visible. Success and info dismiss after 4 s; errors stay until closed. Success uses
`aria-live="polite"`, errors `aria-live="assertive"`. API: `useToast()` with `success`, `error`, `warning`.

## Process canvas (was §6)

Node sizes (width x min height): START and END 48 circle (END double border); HUMAN_TASK and SERVICE_TASK 180 x 72;
EXCLUSIVE_GATEWAY and PARALLEL_GATEWAY 56 diamond (parallel with +); TIMER 56 circle with clock; SUB_PROCESS 200 x 80
dashed border.

Runtime states: default is a card with a neutral border; active (holds a token) uses the `current` border and the
ember ring; completed uses `success-tint`; error uses the `danger` border and an icon in the corner; read-only has
default cursor and no hover. Edges: solid with arrow; a CEL condition edge carries a label bubble (expression cut at
30 characters); a gateway default edge is dashed with a `D` bubble; a cancelled branch is grey with reduced opacity.
Colours are tokens, never literals.

## Breakpoints (was §9)

640 / 900 / 1100 px (see NOTES.md section 5). The sidebar collapses to a drawer on phones; the process designer
canvas is not offered on phones (a notice links to desktop).
