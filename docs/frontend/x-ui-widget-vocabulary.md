# x-ui.widget vocabulary — closed set

**Requirement:** REQ-284 (forms half of decision
[`0020-frontend-architecture.md`](../migration/decisions/0020-frontend-architecture.md)
step 6). **Stage:** S8. **Owner:** `FRONTEND-DEV`.

## The vocabulary is closed

A tenant selects `x-ui.widget` from the set below. A tenant cannot introduce
a new widget name; an unrecognised name degrades to the built-in renderer
for the field's JSON Schema type (§4). Extending this vocabulary is a
platform change — a new renderer registered in `fieldRegistry`, reviewed and
tested like any other platform code — going through the normal gate chain
(CODE-DESIGNER → CODE-DESIGN-VALIDATOR → FRONTEND-DEV → REVIEWER →
TEST-DESIGNER → TEST-DESIGN-VALIDATOR), never a tenant-side extension point.
This cites decision 0020's clause D1 ("tenant customisation is data, never
code") and clause D3 ("custom widgets register in `fieldRegistry` as
platform code, keyed by an `x-ui.widget` name a tenant's schema may
reference — the tenant names a widget, the platform decides what that
widget is").

## Relationship to the DynamicForm mapping

[`docs/design-system/principles.md` "DynamicForm"](../design-system/principles.md) is the
**default** mapping from a JSON-Schema `type`/`format` to an input.
`x-ui.widget` is an optional override applied on top of that mapping for the
same field: the field's JSON-Schema `type` still determines what value
shape is produced (a string, a number); the widget only changes *which
control* produces it. A field with no `x-ui.widget` (or an unrecognised
one) always renders exactly per §7.6. This document does not duplicate
§7.6's table.

## §1. The five widgets

Deliberately small: five names, each covering an interaction §7.6's
type-mapping structurally cannot express, each reachable without any
backend dependency (no upload/storage endpoint, no server-side search), and
each excluded from scripting/logic by construction (no expression
evaluation, no visibility rules — see §6, deferred to a separate track). A
file-upload or autocomplete-with-remote-search widget was deliberately
**not** included: both would need a backend endpoint this requirement's
scope fence forbids touching (REQ-273's "populate the column" work is the
backend prerequisite, not yet landed).

### 1.1 `rich-text-lite`

- **Valid JSON-Schema types:** `string`.
- **Renders:** a multi-line text editor (a `<textarea>`) with a small fixed
  toolbar of three toggle buttons — Bold, Italic, Bullet list. Each button
  inserts/removes a constrained markdown-lite token pair (`**`/`**`,
  `*`/`*`, `- ` line prefix) around the current selection or at the cursor;
  the field's value is always the plain string containing those literal
  tokens. There is **no live HTML preview and no HTML rendering of the
  value at all** — the platform never interprets the tokens as markup
  client-side. A future renderer (server-side or a dedicated preview
  surface) is what would ever turn the tokens into HTML, and is out of this
  requirement's scope.
- **Accessibility contract:** the editing surface is a real `<textarea>`
  (native `role="textbox"`/`aria-multiline="true"`, no explicit attributes
  needed) carrying the full `requiredAriaAttributes` set (`aria-required`,
  `aria-describedby`, `aria-invalid`, `aria-errormessage`). Each toolbar
  button is a real `<button type="button">` with a visible label and
  `aria-label` ("Bold" / "Italic" / "Bullet list") and `aria-pressed`
  reflecting whether the token is present around the current selection.

### 1.2 `masked-input`

- **Valid JSON-Schema types:** `string`.
- **Renders:** a single-line text input that formats keystrokes against one
  mask, named by a companion closed enum `x-ui.mask`
  (`"phone-us"` | `"postal-us"` | `"currency-usd"`) that this widget alone
  consumes — the mask is a platform-chosen format, never a tenant-supplied
  pattern or regex. Formatting is applied on each keystroke by
  inserting/removing literal separator characters (parens, dash, `$`,
  comma) at fixed positions for the selected mask; the submitted value is
  always the plain string the user has entered including those separators.
- **Accessibility contract:** the input carries the full
  `requiredAriaAttributes` set plus `inputMode` appropriate to the mask
  (`"tel"` for `phone-us`, `"numeric"` for `postal-us`/`currency-usd`) and
  `aria-describedby` extended (space-joined) to also reference a
  mask-format hint node (e.g. "Format: (555) 555-5555") rendered alongside
  the field's own description hint.

### 1.3 `searchable-select`

- **Valid JSON-Schema types:** `string` with a non-empty `enum` (the same
  precondition §7.6 already requires for its own `<select>` default).
- **Renders:** a combobox — a text input that filters the field's own
  `enum` list client-side as the user types, plus a listbox of matching
  options the user can navigate and select. No network request is ever
  made; the option universe is exactly the schema's own `enum`.
- **Accessibility contract:** implements the WAI-ARIA combobox pattern —
  the text input carries `role="combobox"`, `aria-expanded`,
  `aria-controls` (pointing at the listbox's id), and
  `aria-activedescendant` (updated as the user navigates filtered options
  with the keyboard); the listbox carries `role="listbox"` and each option
  `role="option"` with `aria-selected`. The input also carries the full
  `requiredAriaAttributes` set.

### 1.4 `rating`

- **Valid JSON-Schema types:** `number` or `integer`, with `minimum: 1` and
  a small `maximum` (a `maximum` absent or `> 10` is a registry-population
  authoring precondition, not a runtime tenant-input check).
- **Renders:** a fixed-size row of `maximum` selectable segments, where
  selecting segment *N* sets the field's numeric value to *N*.
- **Accessibility contract:** the row is a `role="radiogroup"` carrying the
  full `requiredAriaAttributes` set (the group, not an individual segment,
  is the field's accessible unit); each segment is a `role="radio"` with
  `aria-checked` and an `aria-label` stating its value in context (e.g.
  `"3 out of 5"`).

### 1.5 `slider`

- **Valid JSON-Schema types:** `number` or `integer`, with `minimum` and
  `maximum` both present (a registry-population precondition, same
  rationale as `rating`).
- **Renders:** a native range control spanning `[minimum, maximum]` in
  `multipleOf` steps (defaulting to `1` when `multipleOf` is absent), with
  the current numeric value displayed as text next to the control.
- **Accessibility contract:** a native `<input type="range">`, which the
  browser already exposes as `role="slider"` with
  `aria-valuemin`/`aria-valuemax`/`aria-valuenow` computed from its own
  `min`/`max`/`value` attributes — the renderer sets those three native
  attributes correctly from the field's `minimum`/`maximum`/current value
  and still applies the full `requiredAriaAttributes` set (`aria-required`,
  `aria-describedby`, `aria-invalid`, `aria-errormessage`) on the same
  `<input>`.

## §2. This is the complete vocabulary

This is the complete `x-ui.widget` vocabulary as of REQ-284. No other
`x-ui.widget` name is platform-supported; `fieldRegistry`'s key set and this
list's name set are identical and mechanically checked by
`web/tests/unit/xUiWidgetVocabulary.test.tsx`.

## §3. Registration

Each widget registers in `fieldRegistry`
(`web/src/components/forms/fieldRegistry.ts`) as platform code, via
`web/src/components/forms/widgets/index.ts`'s `registerBuiltinWidgets()`,
called once at application start
(`web/src/main.tsx`) — never as a tenant-side extension point.

## §4. Unrecognised or absent widget name

`FieldFactory`'s existing `fieldRegistry.get(fieldDef.xUiWidget)` miss →
built-in-switch fall-through (keyed by the field's own JSON-Schema type,
per §7.6) is the designed behaviour for both an absent `x-ui.widget` and an
unrecognised one. The field's JSON-Schema `type` is never affected by an
unrecognised `x-ui.widget` value, so the built-in switch always has a real
case to fall into: the field renders per §7.6's default for its type, it
does not error and does not disappear.

## §5. No code execution

No widget in this vocabulary evaluates a tenant-supplied string as code or
as an expression. None of the five renderers, `fieldRegistry.ts`, or
`FieldFactory.tsx` call `eval`, `new Function`, set
`dangerouslySetInnerHTML`, or assign to `.innerHTML` — verified by grep at
implementation time (see the REQ-284 implementation report). `rich-text-lite`
in particular stores and echoes its markdown-lite tokens as plain text —
never parsed to HTML by this widget (§1.1).

## §6. Field logic: `visible_when`, `computed`, and cross-field validation (REQ-291)

REQ-291 is the resolution of the deferral this section used to state (a
prior version of this section, titled "Field logic is deferred, not
rejected," said only that decision 0020's clause D1a *permitted* field
logic on a later track — it is not a second deferral: this section states
that logic's actual semantics, and REQ-291's implementation validates them
at definition time).

Three new keys extend the `x-ui` object (the same object REQ-284 already
established for `widget`/`mask`, nested under
`form_schema.properties.<field_name>["x-ui"]`, never a sibling top-level
key):

| Key | Shape | Semantics |
|---|---|---|
| `x-ui.visible_when` | `string` — a `Letflow.Engine.Expr`-grammar expression | Evaluates to a boolean; `false` hides the field. Absent key ⇒ field is always visible. |
| `x-ui.computed` | `string` — a `Letflow.Engine.Expr`-grammar expression | The field's value is populated by evaluating this expression; the field becomes not user-editable when present. Absent key ⇒ field is a normal user-editable field. |
| `x-ui.cross_field_validation` | `{"expression": string, "message": string}` | `expression` must evaluate to a boolean; `false` means the form does not validate and `message` is the text shown to the user. May reference any in-scope sibling field, not only its own field's value. Absent key ⇒ no cross-field rule from this field. |

**Variable scope and naming — no `"variables."` prefix, flat sibling scope
only.** A field expression is written directly against sibling field
names, e.g. `amount > 1000`, never `variables.amount > 1000` — a form
field is not a process variable, and carrying that unrelated convention's
prefix into a different namespace would suggest a shared namespace that
does not exist. The set of names a field expression may reference is
*exactly* the top-level keys of the same `form_schema`'s `"properties"`
map, addressed as single-segment bare identifiers. A multi-segment dotted
path is **always** out of scope, unconditionally — there is no nested-field
addressing model for form-field expressions.

**Absent/null input to a `computed` field's expression:** the field
evaluates to `nil`, uniformly, regardless of the specific cause. Whether
the failure is an absent (undefined) referenced field, a referenced field
holding an explicit JSON `null` that then causes a downstream
type-mismatch, or any other expression evaluation error, the outcome is
the same single value — `nil` — not a per-cause table. This is the one
statement REQ-292 (server), REQ-293 (TypeScript client) and REQ-294 (Dart
client) must all implement identically.

**Evaluation order.** `computed` fields evaluate first, in a
definition-time-proven-acyclic dependency order (a computed field may
reference another computed field; a reference cycle of any length —
self-reference, 2-node, or longer — is rejected at definition time).
`visible_when` and cross-field validation expressions evaluate after every
`computed` field has produced its value, in any order relative to each
other, and can never themselves participate in a cycle (nothing lets
another expression reference a `visible_when` or cross-field-validation
"result").

**Submit disposition: both a hidden field's value and a computed field's
value are submitted, not dropped.** Neither a `visible_when: false`-hidden
field's value nor a `computed` field's value is dropped or filtered
client-side. Quoting record 0020 D1a's constraint 3 directly: "A
client-supplied value for a `computed` or hidden field is therefore an
*input to be checked*, never a value to be stored on trust." The server
(REQ-292) is what turns "submitted" into "trusted or not" — this document
and REQ-291's validator do not implement that authority, only the
client-side disposition every client must agree on.

**Security boundary — client-side hiding is a UX affordance only, never
access control (record 0020 D1a).** A field whose visibility is
security-relevant must be **omitted from the schema entirely** on the
server side before the schema is served to any client — the server never
relies on `visible_when` to keep a security-relevant field away from a
user who should not see it. Relatedly, D1a requires that an expression may
not reference anything the client was not already given: an expression
referencing a name that is not a declared property of the same
`form_schema` is rejected at definition time, exactly like a multi-segment
path.

**Validated at definition time.** All of the above — malformed key shape,
syntactically invalid expressions, out-of-scope variable references, and
computed-field dependency cycles — is checked when a definition is
created, updated, or validated, not only discovered at render time.
`Letflow.Definitions.FormSchemaExpressions` is the validator
(`lib/letflow/definitions/form_schema_expressions.ex`), wired into
`Letflow.Definitions.Graph.validate_node_attributes/1` as CHK-20. A
violation surfaces one of four `Violation.code()` atoms:
`:form_schema_x_ui_logic_malformed`, `:form_schema_expression_invalid`,
`:form_schema_expression_out_of_scope`, and
`:form_schema_computed_field_cycle`.

## §7. Client-side validation is a UX affordance only

**Any client-side validation derived from `form_schema` (built-in or via an
`x-ui.widget`) is a UX affordance only — it improves the editing experience
but proves nothing to the server. Server-side authority for what a
submitted value must satisfy stays exclusively with `variable_schemas`
(REQ-109). A widget that appears to accept a value client-side does not
mean the server will accept it; no renderer in this vocabulary may be read
as a validation boundary.**

## §8. Scope fence

- `DynamicFormRenderer.tsx`'s compilation pipeline
  (`parseFormSchema`/`compileFormSchemaToZod`) is not changed by this
  requirement beyond `formSchemaParser.ts`'s additive `xUiWidget`/`xUiMask`
  fields — `compileFormSchemaToZod` continues to validate purely by
  JSON-Schema `type`/`format`/`enum`/etc., never by widget name, consistent
  with §7.
- `DynamicFormRenderer.tsx`'s own inlined field-rendering switch is not
  touched or reconciled with `FieldFactory` by this requirement — a known,
  pre-existing gap (`DynamicFormRenderer.tsx` does not call
  `FieldFactory`/`fieldRegistry` at all), filed as a separate finding for
  ORCH to route, not fixed here.
- No backend change: `tasks.form_schema` stays unpopulated (REQ-273's job);
  this requirement only prepares the renderer side for when real schemas
  start arriving.
- `x-ui.visible_when`/`x-ui.computed`/`x-ui.cross_field_validation`'s
  *evaluation* (client-side interactivity or server-side re-evaluation) is
  not implemented by this document's own requirement (REQ-284) or by
  REQ-291 — REQ-291 validates that the expressions exist and are
  well-formed and in-scope at definition time only; REQ-292 (server),
  REQ-293 (TypeScript client) and REQ-294 (Dart client) implement
  evaluation.
