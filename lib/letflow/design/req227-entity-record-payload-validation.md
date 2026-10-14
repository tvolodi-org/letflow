# Design: REQ-227 — Entity record-payload validation against a definition's derived schema

**Requirement:** REQ-227 (stage S6, queue task 462, ISS-0438 slice 3)
**Owner (implementer of this design's output):** ELIXIR-DEV
**Run:** `WF02-REQ227-20260906`, WF-02 Step 1
**Depends on:** REQ-225 (`Letflow.Entities.Definition`, done), REQ-024 (`Letflow.EventStore.Registry.JsonSchema`, done)
**This document produces:** the `buildRecordSchema`/`validateRecordPayload` module design, the
resolution of the named cross-namespace open design question, and full acceptance-criteria
traceability. **Design only — no implementation code.**

---

## 0. Sources read for this design

- This run's handoff (`handoffs/WF02-REQ227-20260906/step-00-git-setup.json`) and REQ-227's full
  `docs/requirements.yaml` entry (description, `acceptance_criteria`, `depends_on`).
- `lib/letflow/entities/definition.ex` — REQ-225's `entity_definition()`/`field_def()` document
  shape (the exact input this requirement translates).
- `lib/letflow/entities/definition/validator.ex` and `lib/letflow/entities/definition/shape.ex` —
  REQ-225's sibling modules, read for this codebase's naming/structuring precedent
  (`Letflow.Entities.Definition.*`, one rule-set per leaf module, pure functions only).
- `lib/letflow/event_store/registry/json_schema.ex` (`Letflow.EventStore.Registry.JsonSchema`,
  REQ-024) — confirmed its public API is exactly one function, `validate/2`, and its keyword
  support (`type`, `minimum`/`maximum`, `minLength`/`maxLength`, `enum`, `required`,
  `properties`, `items`, `additionalProperties` — literal `false` form only).
- `lib/letflow/event_store/registry/validation_failure.ex` — the `%ValidationFailure{field_path,
  constraint, actual}` struct `JsonSchema.validate/2` returns violations as. REQ-227's own
  acceptance criteria require reusing this exact shape.
- `lib/letflow/event_store/registry.ex` — `validate_payload/3`, read specifically for the outer
  event-envelope vs. inner record-payload distinction this design's §3 draws.
- `lib/letflow/repository/attachments.ex` (`Letflow.Repository.Attachments`) — the cross-reach
  precedent REQ-227's own text names for the namespace open question.
- `lib/letflow/definitions/json_schema_shape.ex` (`Letflow.Definitions.JsonSchemaShape`) — an
  **existing** cross-namespace reference: its own moduledoc names
  `Letflow.EventStore.Registry.JsonSchema.validate/2` as the exact consumer its output shape is
  built for, i.e. another subsystem (`Letflow.Definitions`) already treats `JsonSchema` as a
  shared, cross-namespace utility today. This is the strongest precedent found for §5's decision.
- `lib/letflow/design/req237-zig-provenance-marking-convention.md` §2 — the
  `PROVENANCE (historical, not current decision authority):` marker convention, applied below
  wherever R-Co material is cited.
- `docs/anti-patterns.md` — checked; no entry bears on this design.

---

## 1. Scope (from REQ-227's own text)

**In scope:**

1. `buildRecordSchema`-equivalent — a pure function translating one REQ-225
   `Letflow.Entities.Definition.t()` document's `fields` list into a JSON-Schema-shaped
   constraint map that `Letflow.EventStore.Registry.JsonSchema.validate/2` can consume directly.
2. `validateRecordPayload`-equivalent — a pure function validating a record's `field_values` map
   against that derived schema, returning **every** violation (not just the first) as
   `%Letflow.EventStore.Registry.ValidationFailure{field_path, constraint, actual}` structs — the
   same struct `JsonSchema.validate/2` already returns, not a new shape.
3. Resolving, explicitly, which namespace this new module calls
   `Letflow.EventStore.Registry.JsonSchema` from (§5 below).

**Out of scope (explicit boundary, confirmed §8):**

- No route, no controller, no Plug module.
- No event registration or command functions (`ENTITY_RECORD_CREATED`/`UPDATED`/`DELETED`,
  create/update/delete commands, idempotency-key handling, `entity_type_instances`) — all
  REQ-228.
- No outer event-envelope validation — that is `Letflow.EventStore.Registry.validate_payload/3`,
  a separate, pre-existing concern (§3 below).
- No second JSON-Schema-shaped constraint engine — `Letflow.EventStore.Registry.JsonSchema` is
  reused as-is (§5).

---

## 2. Input/output shapes

### 2.1 Input: a REQ-225 definition (unchanged, cited not redefined)

This design takes `Letflow.Entities.Definition.t()` and its `field_def()` exactly as REQ-225
defined them (`lib/letflow/entities/definition.ex`) — no new definition-shape type is introduced.
For reference, the fields of `field_def()` this design actually reads:

| `field_def()` key | Type | Read by this design for |
|---|---|---|
| `:name` | `String.t()` | JSON Schema property key, and `required` list membership |
| `:type` | `field_type()` (`:string \| :integer \| :decimal \| :boolean \| :date \| :datetime \| :enum \| :json`) | §4's type-mapping table |
| `:required` | `boolean()`, optional | whether `:name` is added to the derived schema's top-level `"required"` list |
| `:enum_values` | `[String.t()]`, optional | the derived per-field subschema's `"enum"` keyword, only when `:type` is `:enum` |
| `:queried`, `:decimal_precision`, `:decimal_scale`, `:default` | — | **not read by this design** — see §4's explicit note on why `decimal_precision`/`decimal_scale` do not produce `minimum`/`maximum`/`maxLength` keywords |
| `:min`, `:max`, `:non_negative` (GH #2532) | `number()`, `number()`, `boolean()`, optional, `:integer`/`:decimal` only | the derived subschema's `"minimum"` (`max(min, 0)` under `non_negative: true`) and `"maximum"` — added by GH #2532, see `gh2532-field-min-max-non-negative.md` §4 |

### 2.2 Input: a record payload

```
@type field_values :: %{required(String.t()) => term()}
```

The already-decoded (not JSON-string) map of field name → value a record submission carries. Per
REQ-225's own field-name rule (`Definition.Validator`'s Rule 1, `^[a-z][a-z0-9_]{0,63}$`), keys
are plain strings, not atoms — this matches `JsonSchema.validate/2`'s own map-with-string-keys
expectation (it pattern-matches `is_map/1` generically and reads schema keys as raw JSON keys
like `"type"`/`"properties"`, never atoms).

### 2.3 Output: the derived schema

```
@type record_schema :: map()
```

A plain map, JSON-Schema-shaped exactly the way `Letflow.EventStore.Registry.JsonSchema.validate/2`
expects its second argument (`schema`) — i.e. built entirely out of the same string-keyed
vocabulary `EventType.json_schema` columns already use (`"type"`, `"properties"`, `"required"`,
`"additionalProperties"`, `"enum"`, `"minimum"`, `"maximum"`, `"maxLength"`). No new schema
dialect, no atom keys.

### 2.4 Output: violations

```
@type violations :: [Letflow.EventStore.Registry.ValidationFailure.t()]
```

Reused verbatim from REQ-024 (`lib/letflow/event_store/registry/validation_failure.ex`) — see §5
for why this is a direct `alias`, not a redefinition. `field_path` is the RFC 6901 JSON Pointer
`JsonSchema.validate/2` already produces (`"/field_name"` for a top-level field violation);
`constraint` is the keyword-name string that fired (`"type"`, `"required"`, `"enum"`,
`"additionalProperties"`, etc.); `actual` is the raw, already-decoded offending value (or `nil`
for a `"required"` violation, matching `JsonSchema`'s own convention).

---

## 3. The two validations this design must NOT conflate (AC4 analysis)

REQ-227's own description flags this explicitly, so it is stated here in full rather than left
implicit, per that description's own instruction to read this section before drafting.

There are two structurally similar but functionally distinct validation passes in play once
REQ-228 exists:

| | **This requirement (REQ-227)** | **REQ-228's outer envelope validation** |
|---|---|---|
| Validates | A record's `field_values` map | The full event payload about to be appended (`entity_type`, `entity_def_version`, `record_id`, `field_values`, and every other envelope key) |
| Schema source | Derived fresh, per call, from a REQ-225 `Definition.t()` document via `buildRecordSchema/1` (this design, §4) | A `json_schema` column value registered once, ahead of time, via `Letflow.EventStore.Registry.register_type/2` (REQ-228's own seed step) |
| Entry point | The new module this design specifies (§5), called directly by a command function | `Letflow.EventStore.Registry.validate_payload/3` (already exists, REQ-024) |
| Engine used underneath | `Letflow.EventStore.Registry.JsonSchema.validate/2` | Also `Letflow.EventStore.Registry.JsonSchema.validate/2` — **the same engine, called from two different call sites for two different schemas** |
| Payload shape checked | Just the field-level business data (`{"customer_name" => "Acme", "balance" => 12}`) | The structural envelope wrapping that data (does `field_values` exist, is it an object, are `entity_type`/`record_id` present and correctly typed) |
| Relationship | **Inner** — one field of the outer envelope (`field_values`) is itself opaque to the outer schema (the outer envelope schema does not know about any individual entity type's specific fields; only this design's derived schema does) | **Outer** — wraps and pre-dates the inner check |

Concretely: REQ-228's create/update/delete commands are expected to call **both** —
`validate_record_payload/2` (this design) against the incoming `field_values` using the specific
entity definition's derived schema, **and separately** rely on
`Letflow.EventStore.Registry.validate_payload/3` at event-append time against the registered
envelope schema. Neither validation subsumes the other: the outer schema cannot express
per-entity-type field constraints (enum values, per-field required-ness) because one single
registered event type (`ENTITY_RECORD_CREATED`) must accept records from every entity type in a
tenant; only the per-definition derived schema this design builds can express that. This design
implements the inner check only — the outer envelope registration and its call site are entirely
REQ-228's scope.

---

## 4. `buildRecordSchema/1` — the definition → JSON-Schema-shaped map translation

**Signature:**

```
@spec build_record_schema(definition :: Letflow.Entities.Definition.t()) :: record_schema()
```

**Behavior (pure, total over the malformed-shape precondition REQ-225's `Validator` already
guarantees — see the precondition note below):** builds one JSON-Schema-shaped map:

```
%{
  "type" => "object",
  "properties" => %{ <field name string> => <per-field subschema map>, ... },
  "required" => [ <field name string>, ... ],   # only fields with required: true
  "additionalProperties" => false
}
```

**Precondition (not re-checked by this function):** `definition` has already passed
`Letflow.Entities.Definition.Validator.validate/1` (returned `:ok`) — same divide of
responsibility REQ-225's own `Shape` module already documents ("callers are expected to have
already called `Validator.validate/1`"). `build_record_schema/1` does not re-run the 11
structural rules and does not handle a malformed definition specially; a caller skipping
validation first is a caller error, not a case this function defends against.

### 4.1 Per-field type mapping (`field_type()` → JSON Schema `"type"` + extra keywords)

| REQ-225 `field_def().type` | Derived `"type"` | Extra keywords on this field's subschema | Notes |
|---|---|---|---|
| `:string` | `"string"` | none | |
| `:integer` | `"integer"` | none; since GH #2532 `"minimum"`/`"maximum"` from `min`/`max`/`non_negative` when present | Superseded in part by GH #2532 (`gh2532-field-min-max-non-negative.md` §4). |
| `:decimal` | `"number"` | none; since GH #2532 `"minimum"`/`"maximum"` from `min`/`max`/`non_negative` when present | See note below — `decimal_precision`/`decimal_scale` are **not** translated into `"minimum"`/`"maximum"`/`"maxLength"`. Range keys: superseded in part by GH #2532. |
| `:boolean` | `"boolean"` | none | |
| `:date` | `"string"` | none | No `"format"` keyword is emitted — `JsonSchema.validate/2`'s own moduledoc documents `format` as a keyword it silently ignores ("permitted and inert"), so emitting it would be a no-op; date-shape validation is not this requirement's scope. |
| `:datetime` | `"string"` | none | Same rationale as `:date`. |
| `:enum` | `"string"` | `"enum" => enum_values` (copied verbatim from the field's `enum_values` list) | REQ-225's Rule 6 already guarantees `enum_values` is a non-empty list of strings whenever `type == :enum` — no re-validation needed here. |
| `:json` | *(key omitted entirely)* | none | Omitting `"type"` for this field's subschema means `JsonSchema.validate/2`'s `type_violation/3` short-circuits to `:ok` (its `nil` clause) for this field — any JSON value (object, array, string, number, boolean, null) is accepted, matching a `:json` field's own definition-level meaning (an opaque JSON blob, not a further-constrained shape). |

> **Superseded by GH #2532** (`lib/letflow/design/gh2532-field-min-max-non-negative.md`):
> `field_def()` now has explicit `min`/`max`/`non_negative` keys on `:integer`/`:decimal`
> fields, and `build_record_schema/1` emits `"minimum"`/`"maximum"` from them when present.
> The finding below still holds for `"maxLength"` and for `decimal_precision`/`decimal_scale`,
> which are still never translated into any keyword.

**Explicit, non-silent finding on `minimum`/`maximum`/`maxLength` (do not invent constraint
kinds REQ-225 doesn't have):** REQ-227's own requirement text frames the derived schema's keyword
set as "type, properties, required, additionalProperties: false, enum, maxLength, minimum,
maximum" and calls this "a strict superset" of what `JsonSchema.validate/2` supports — meaning
the requirement is asserting an upper bound on what a derived schema *could* need, not a
promise that `buildRecordSchema/1` must emit all of those keywords for every definition.
Checked against the actual `field_def()` shape (`lib/letflow/entities/definition.ex`, §2.1
above): **no field of `field_def()` carries a string-length bound or a numeric range bound** —
`decimal_precision`/`decimal_scale` bound how many *digits* a decimal value may have (REQ-225
Rule 7, enforced once, at definition-authoring time, against the field's own declared precision/
scale numbers — not against any individual record's value), not the numeric *value* a record
instance may take, and there is no length-bound field at all. Translating
`decimal_precision`/`decimal_scale` into `"maximum"`/`"minLength"`/`"maxLength"` would be
inventing a constraint kind REQ-225 does not define (a precision-derived value ceiling is not
the same check as "this field's decimal digit count is ≤ N", and `JsonSchema` has no
digit-count keyword at all). **Therefore `build_record_schema/1` never emits `"minimum"`,
`"maximum"`, or `"maxLength"` for any field today** — those three keywords remain available in
`JsonSchema.validate/2` (confirming no keyword gap, satisfying REQ-227's "strict superset,
confirmed" framing) but are simply unused by this translation until/unless a future requirement
extends `field_def()` with an explicit range or length constraint. This is deliberate, not an
oversight — flagged again as OQ-1 (§8) so it is not silently rediscovered later as "a missing
feature."

### 4.2 Worked example

Given a definition with fields `[%{name: "customer_name", type: :string, required: true},
%{name: "status", type: :enum, enum_values: ["open", "closed"], required: false}, %{name:
"notes", type: :json}]`, `build_record_schema/1` produces (shown as the literal map shape, not
executable code):

```
"type"                 => "object"
"properties"           => {
  "customer_name" => {"type" => "string"},
  "status"        => {"type" => "string", "enum" => ["open", "closed"]},
  "notes"         => {}
}
"required"             => ["customer_name"]
"additionalProperties" => false
```

---

## 5. `validateRecordPayload/2` and the namespace open design question

**Signature:**

```
@spec validate_record_payload(
        definition :: Letflow.Entities.Definition.t(),
        field_values :: field_values()
      ) :: violations()
```

**Behavior:** calls `build_record_schema/1` on `definition`, then calls
`Letflow.EventStore.Registry.JsonSchema.validate/2` with `(field_values, <derived schema>)`,
returning its result list unchanged. Zero violations means `field_values` conforms. Every
violation `JsonSchema.validate/2` finds is returned — since `JsonSchema.validate/2` itself
already collects (not short-circuits on the first failure; see its own moduledoc, "ES-05
requires reporting EVERY failure"), `validate_record_payload/2` inherits that all-violations
guarantee for free by delegating rather than re-implementing traversal.

### 5.1 THE NAMED OPEN DESIGN QUESTION — resolved here, explicitly

**Question (from REQ-227's own text):** should this new module call
`Letflow.EventStore.Registry.JsonSchema` (a) as-is, accepting the cross-namespace reach (the
`Letflow.EventStore.Registry` namespace, from a module that is not part of that subsystem), or
(b) should a shared top-level `Letflow.JsonSchema` module be extracted first?

**Decision: (a) — call `Letflow.EventStore.Registry.JsonSchema.validate/2` as-is, with a direct
`alias`, accepting the cross-namespace reach. No extraction.**

**Rationale:**

1. **A cross-namespace reference to this exact module already exists in the codebase.**
   `Letflow.Definitions.JsonSchemaShape` (`lib/letflow/definitions/json_schema_shape.ex`) — a
   module that is not part of `Letflow.EventStore.Registry` either — names
   `Letflow.EventStore.Registry.JsonSchema.validate/2` directly in its own moduledoc as "exactly
   the shape" its own output is built to be consumed by. `Letflow.Definitions` and (with this
   design) `Letflow.Entities` would then be the second and third subsystems treating
   `JsonSchema` as a shared, cross-namespace utility — the namespace boundary is already
   informally crossed in practice, this design just makes a second concrete caller of it.
2. **`JsonSchema` is already a pure, dependency-free leaf module** — no `Repo`, no I/O, no
   process state (confirmed by reading it directly, §0). Its home namespace
   (`Letflow.EventStore.Registry.*`) reflects *where it was first needed*, not a structural
   dependency it imposes on callers — calling it from `Letflow.Entities` creates no coupling
   beyond a plain function call to a pure function, the same shape
   `Letflow.Repository.Attachments` already accepts when it calls
   `Letflow.Repository.upsert_content/6` directly rather than wrapping it.
3. **Extraction now buys nothing concrete and costs a real migration.** Moving `JsonSchema` to a
   new top-level `Letflow.JsonSchema` module would require either (a) physically relocating the
   module — which touches `Letflow.EventStore.Registry`'s own call site and every existing test
   for it, none of which is in this requirement's scope — or (b) leaving the original in place
   and adding a thin delegating module, which adds an indirection layer with zero behavior
   change, purely to rename an already-correct dependency edge. REQ-227's own scope explicitly
   excludes "no route or controller" and does not authorize a `Letflow.EventStore.Registry`
   refactor.
4. **Rule of three, not pre-emptive extraction.** Two callers of a pure, already-shared utility
   is not yet the point where a home-namespace mismatch becomes a real ownership problem. If a
   third, unrelated subsystem needs this same engine later, extracting a top-level
   `Letflow.JsonSchema` at that point is a reasonable, low-risk follow-up (a rename plus two
   call-site updates) — flagged as OQ-2 (§8) for REVIEWER, not resolved as a "never" here.

**What this means concretely for the new module:** it `alias`es
`Letflow.EventStore.Registry.JsonSchema` and `Letflow.EventStore.Registry.ValidationFailure`
directly, the same way `Letflow.Definitions.JsonSchemaShape`'s sibling call sites already treat
`JsonSchema` as an importable dependency of an unrelated subsystem, and calls
`JsonSchema.validate/2` with no wrapper, no re-shaping, no adapter module in between.

---

## 6. Module naming and placement

**New module: `Letflow.Entities.Record.Validator`**, at `lib/letflow/entities/record/validator.ex`.

**Justification against REQ-225/226's established naming precedent:**

- REQ-225 established `Letflow.Entities.Definition` (the document shape) with sibling leaf
  modules `Letflow.Entities.Definition.Validator` (structural rules) and
  `Letflow.Entities.Definition.Shape` (canonicalisation/hashing) — one parent noun
  (`Definition`), multiple single-purpose child modules under it.
- This requirement validates a different noun — a **record**, not a **definition** — against a
  definition's derived schema. `Letflow.Entities.Record.Validator` mirrors that exact pattern:
  the parent noun this module's functions are about (`Record`), with `.Validator` naming its one
  responsibility, exactly parallel to `Definition.Validator`'s own naming.
- **No `lib/letflow/entities/record.ex` (a `Letflow.Entities.Record` document-shape module) is
  created by this requirement.** REQ-227's scope is the two functions in §4/§5 only; a full
  persisted/document `record()` shape (id, entity_type, entity_def_version, field_values,
  timestamps) is REQ-228's to define, alongside its create/update/delete commands. This design
  deliberately introduces the `Letflow.Entities.Record` namespace one level early (via its
  `.Validator` child) rather than inventing an unrelated flat name (e.g.
  `Letflow.Entities.RecordPayloadValidator`), so REQ-228 has an obvious, already-precedented slot
  (`lib/letflow/entities/record.ex`) to fill in later without a rename. Flagged as OQ-3 (§8) so
  REQ-228's own CODE-DESIGNER pass is aware this namespace is already partially claimed.
- `field_values()` and `record_schema()`/`violations()` (§2) are typedocs living inside
  `Letflow.Entities.Record.Validator` itself (not a separate shape module), since REQ-227's scope
  is exactly these two functions and their immediate input/output types — no third leaf module is
  justified for two type aliases this small, matching `Letflow.Definitions.JsonSchemaShape`'s own
  precedent of a single-purpose leaf module carrying its own tiny local types rather than
  spinning up a dedicated shape module for them.

**Full function surface of `Letflow.Entities.Record.Validator`:**

| Function | Spec | Section |
|---|---|---|
| `build_record_schema/1` | `@spec build_record_schema(Letflow.Entities.Definition.t()) :: record_schema()` | §4 |
| `validate_record_payload/2` | `@spec validate_record_payload(Letflow.Entities.Definition.t(), field_values()) :: violations()` | §5 |

No other public function is added. No `GenServer`, no `Ecto.Schema`, no migration — this module
is pure, exactly like `Letflow.Entities.Definition.Validator` and `Letflow.Definitions.JsonSchemaShape`.

---

## 7. Confirmations against REQ-227's explicit scope-boundary acceptance criteria

- **No route or controller is added or modified.** This design specifies exactly one new file,
  `lib/letflow/entities/record/validator.ex`, and no changes to `lib/letflow/router.ex`, any
  `lib/letflow/routers/*.ex`, or any Plug/controller module. `git diff --stat` for this
  requirement's implementation commit(s) is expected to show only the new module file (and its
  test file, TEST-DESIGNER's job) — verifiable directly.
- **No new general-purpose JSON-Schema-shaped validator module is added.** `validate_record_payload/2`
  delegates its entire constraint-checking logic to the existing
  `Letflow.EventStore.Registry.JsonSchema.validate/2` (§5) — `Letflow.Entities.Record.Validator`
  contains no recursive schema-walking logic of its own, only (a) the definition→schema
  translation (§4, pure data reshaping, not constraint evaluation) and (b) a direct delegating
  call to the existing engine. `git diff --stat` is expected to show zero new files under any
  path resembling a second JSON Schema engine (no new `*/json_schema*.ex` outside the existing
  `lib/letflow/event_store/registry/json_schema.ex` and `lib/letflow/definitions/json_schema_shape.ex`,
  both pre-existing).

---

## 8. Open questions — explicitly listed, not silently resolved

**OQ-1 (MINOR).** *Superseded by GH #2532 for `minimum`/`maximum`*: `field_def()` gained
`min`/`max`/`non_negative` and `build_record_schema/1` now emits both keywords from them (see
`gh2532-field-min-max-non-negative.md`); `maxLength` remains unused. Original text: §4.1 finds that `minimum`/`maximum`/`maxLength` are never emitted by
`build_record_schema/1` today, because `field_def()` (REQ-225) carries no length- or
range-constraint attribute to translate. If a future requirement adds such an attribute to
`field_def()` (e.g. a `max_length` or `min_value`/`max_value` key), `build_record_schema/1` must
be extended at that point — this design does not attempt to guess that shape in advance. Flagged
for REVIEWER to confirm "confirmed superset, currently unused" is the right reading of REQ-227's
"strict superset of keywords" framing, rather than a promise that all three keywords must appear
in every derived schema today.

**OQ-2 (MINOR).** §5.1 resolves the namespace question as "call as-is, no extraction," but notes
a hypothetical third caller as the trigger for reconsidering a shared top-level
`Letflow.JsonSchema` module. Flagged for REVIEWER to weigh at this slice's own gate, per REQ-227's
own text ("REVIEWER weighs it at that slice's own gate").

**OQ-3 (MINOR).** §6 introduces the `Letflow.Entities.Record` namespace via its `.Validator`
child only, without creating a `Letflow.Entities.Record` parent document-shape module (that is
REQ-228's job). Flagged so REQ-228's own CODE-DESIGNER pass treats `lib/letflow/entities/record.ex`
as an already-anticipated (not yet claimed) file path, and confirms whether REQ-228's record
document shape should live there or elsewhere.

**OQ-4 (MINOR).** `:date`/`:datetime` fields are translated to plain `"type" => "string"` with no
format constraint (§4.1) — a syntactically arbitrary string currently passes `validate_record_payload/2`
for a `:date`/`:datetime` field as long as it is a string at all. This matches
`JsonSchema.validate/2`'s own documented `"format"`-is-inert stance, so it is not a gap this
design introduces, but it means date/time value *shape* checking (e.g. "is this actually
ISO-8601") is not enforced anywhere in this requirement's scope. Flagged for REVIEWER to confirm
this is an acceptable, already-platform-wide limitation rather than a REQ-227-specific omission.

---

## 9. Acceptance-criteria traceability

| REQ-227 acceptance criterion | Concrete design element |
|---|---|
| "a record payload whose field_values conform to every field constraint in a REQ-225 definition passes validation with zero violations" | §5 (`validate_record_payload/2` delegates to `JsonSchema.validate/2`, which returns `[]` when conformant); §4.2 worked example |
| "a record payload violating multiple independent field constraints in one submission returns ALL violations in one call, not only the first" | §5 ("Every violation `JsonSchema.validate/2` finds is returned... inherits that all-violations guarantee for free by delegating rather than re-implementing traversal") |
| "each returned violation carries a (field_path, constraint, actual) triple identifying exactly which field and which constraint failed" | §2.4 (`violations()` reuses `%ValidationFailure{field_path, constraint, actual}` verbatim) |
| "the validation engine used is Letflow.EventStore.Registry.JsonSchema (REQ-024), not a newly hand-rolled constraint engine" | §5 (direct delegation, no re-implementation); §7 (explicit `git diff --stat` confirmation) |
| "the design artefact for this requirement explicitly states which of the two named namespace options...was chosen and why" | §5.1 (decision (a), four numbered rationale points) |
| "no route or controller file is added or modified" | §7 (first bullet) |
| "mix test and mix compile --warnings-as-errors both pass with real output quoted" | Not a design-time concern — ELIXIR-DEV's implementation turn must run and quote both, per `docs/agents/instructions/core-directives.md`'s no-speculation rule; this design does not (and cannot) satisfy this criterion itself |
