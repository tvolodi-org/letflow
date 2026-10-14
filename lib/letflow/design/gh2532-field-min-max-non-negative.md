# GH #2532 -- Field `min`/`max`/`non_negative` on `:integer`/`:decimal` entity fields

Run: WF-02, branch `feat/GH-2532-field-ranges` off origin/main f7ce96f0 (contains #2528, #2529,
#2543). Source: core brief 02, roadmap W2b. Backend only (`lib/letflow/`). No migration, no DDL,
no event-type change, no new error code. Gates: CODE-DESIGN-VALIDATOR, SECURITY-REVIEWER
(INV-1/2/5/8), REVIEWER. Line numbers are f7ce96f0; the issue's own line refs are stale
(router is 542-555, `Records.field_document/1` is 1054-1066).

## 1. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Three optional `field_def()` keys: `min`, `max` (inclusive bounds, `number()`; `integer()` on `:integer`) and `non_negative :: boolean()`. Absent = no bound. No layer defaults or inserts them. | Opt-in. Key-less definitions keep byte-identical JSON and hashes. |
| D2 | `Definition.Validator` gets new Rule 12 `:invalid_range`. It returns at most one violation per field, at path `[:fields, name]`, and its messages are fixed strings. | Same one-per-field `cond` shape as Rule 7 `:invalid_decimal` (validator.ex:461-503). |
| D3 | `Record.Validator.field_subschema/1` adds `"minimum"`/`"maximum"` only for `:integer`/`:decimal`, and only when the bound is a number. The effective minimum comes from one pure helper. | The engine already checks these keywords (json_schema.ex:102-105). A non-number bound stays inert, so a corrupt stored definition can never crash (INV-8). |
| D4 | `non_negative: true` is kept as written and never rewritten to `min: 0`. | The issue says it hashes differently from `min: 0` and gets its own `logical_shape_version`. |
| D5 | The keys are carried through all 4 places that turn JSON into a document (section 2). `Query.Allowlist` and `TenantProvisioning` are left unchanged. | Avoids the ISS-0624 key-drop failure. See section 2.5 for why those two are not touched. |
| D6 | A violation shows up as the existing 422 `record_payload_invalid` entry `{"code":"minimum"\|"maximum","path":"/qty","message":"/qty violates minimum"}`. | `violation_map/1` (routers/entities.ex:2694-2700) already drops `actual` (INV-2). |
| D7 | No DB CHECK. `Definition.Ddl` is unchanged. | Out of scope per the issue (0024 DDL design). |
| D8 | One PR. 6 production files (section 9), which is within the split rule's ~6. | A 4a-only merge would accept bounds and store them without enforcing them, which is a silent non-enforcement window. |

## 2. Plumbing: where the keys flow (string -> atom document)

1. **HTTP builder.** `definition_field_document/1` (routers/entities.ex:542-555): add three
   `maybe_put_optional/4` pipes: `:min`/"min", `:max`/"max", `:non_negative`/"non_negative".
   `maybe_put_optional/4` (entities.ex:607-612) drops only `nil`, so JSON `null` is treated as
   absent, and `false`, `"yes"` and `"a"` pass through unchanged for the Validator to reject.
   No `FieldConstraint` is added (same reasoning as the gh2529 design §2.1). Today the builder
   silently drops unknown field keys, so `"min"` in a POST body is lost. That is the behaviour
   this change fixes.
2. **Pack.** `@field_keys` (definitions/solution_pack.ex:1085-1096): add
   `"min" => :min`, `"max" => :max` and `"non_negative" => :non_negative`. `translate_keys/2`
   (solution_pack.ex:1141-1148) still rejects any other key, so `"minimum"` still gives
   `{:error, :invalid_pack_document}`. Export already ships the stored string-keyed `definition_json`
   verbatim (solution_pack.ex:910), so no export change is needed. Install goes through
   `atomize_definition_json/1` (1125) and then `create_definition/2` (1597-1599), which runs the
   Validator. A pack JSON `null` reaches the Validator as `min: nil` and is rejected
   (`:invalid_range`). `priv/modules/exam/generate_pack.exs:54-65` keeps its own mirror and is
   **not** updated, because exam types do not adopt bounds.
3. **Records read-back.** `field_document/1` (entities/records.ex:1054-1066) rebuilds
   `field_def()` from string-keyed JSONB. It gains a private helper:
   `@spec put_present(map(), atom(), map(), String.t()) :: map()`, which puts `atom_key => field[string_key]`
   only when `Map.has_key?(field, string_key)`. It is applied to "min", "max" and "non_negative".
   Values are copied verbatim, with no atom conversion and no arithmetic. The comment block at
   records.ex:1027-1053 is extended to name the three keys.
4. **Typespec.** `Definition.field_def()` (definition.ex:50-61): add
   `optional(:min) => number()`, `optional(:max) => number()` and `optional(:non_negative) => boolean()`.
   Add a moduledoc paragraph "Numeric ranges (GH #2532)" with the semantics from D1/D4.
5. **Untouched.** `Query.Allowlist.field_document/1` (query/allowlist.ex:412-421) uses only name,
   type, queried, enum_values, locales and search_strategy. It decides which fields can be
   filtered and sorted, and a range does not change that. `TenantProvisioning.field_from_persisted/1`
   (tenant_provisioning.ex:2675-2686) only feeds DDL and promotion (`Definition.Ddl`). DDL reads
   only type, name, queried, decimal_precision/scale, enum_values, locales and search_strategy
   (ddl.ex:239-618), and D7 says no CHECK. Neither module reads a bound, so adding keys there
   would be dead data. Both are partial projections by design, not full `field_def()`
   reconstructions.

## 3. `Definition.Validator` Rule 12 `:invalid_range` (entities/definition/validator.ex)

- `validate/1` (74-98): append `++ range_violations(definition)` after `decimal_violations/1`
  (line 83). Moduledoc counts: "13 structural rules"/"11 numbered rules" become 14 and 12.
- `@spec range_violations(Definition.t()) :: [violation()]` (private). Per field from
  `get_list(definition, :fields)`, a `cond` returns the **first** matching row below. Presence is
  `Map.has_key?/2`, never a truthiness test. The guards only use `is_integer/1`, `is_number/1`,
  `is_boolean/1`, `>`, `<` and `==`, and every comparison runs only after its operands have passed
  a number guard. There is no arithmetic and no conversion, so `ArithmeticError` and
  `FunctionClauseError` cannot happen. Strings ("a", "NaN", "Infinity"), `nil`, maps and lists
  fail the number guard. Bignums (10^400) compare exactly. JSON has no NaN/Infinity literal.

| # | Condition (field has `type`, `name`) | Fixed message |
|---|---|---|
| R1 | any of the 3 keys present and `type not in [:integer, :decimal]` | "min, max and non_negative are only allowed on :integer and :decimal fields" |
| R2 | `non_negative` present and not `is_boolean` | "non_negative must be a boolean" |
| R3 | `min` present and not `valid_bound?(type, min)` | "min must be an integer for :integer fields and a number for :decimal fields" |
| R4 | `max` present and not `valid_bound?(type, max)` | same text with "max" |
| R5 | both present and `min > max` | "min must not exceed max" |
| R6 | `non_negative == true` and min present and `min < 0` | "min must not be negative when non_negative is true" |
| R7 | `non_negative == true` and max present and `max < 0` | "max must not be negative when non_negative is true" |

`@spec valid_bound?(:integer | :decimal, term()) :: boolean()`: this is `is_integer/1` for
`:integer` (so `1.5` and `2.0` are rejected) and `is_number/1` for `:decimal`. Messages never
echo a value. Bound magnitude is not checked against bigint or `decimal_precision` (OQ-1). Key-less
fields never match R1-R7, so every existing fixture still returns `:ok`.

## 4. `Record.Validator` (entities/record/validator.ex)

- Clauses 92-93 become `%{type: :integer} = field -> put_range(%{"type" => "integer"}, field)`
  and the same for `:decimal`/`"number"`. Every other clause is unchanged.
- `@spec put_range(map(), Definition.field_def()) :: map()` (private): it puts `"minimum"` when
  `effective_minimum/2` is non-nil, and `"maximum"` when `Map.get(field, :max)` `is_number`. With
  no keys the result is EXACTLY `%{"type" => "integer"}` / `%{"type" => "number"}`.
- `@spec effective_minimum(min :: term(), non_negative :: term()) :: number() | nil`, a **public**
  `@doc` pure helper so it can be unit-tested directly:
  `(number m, true) -> max(m, 0)`, `(number m, _) -> m`, `(_, true) -> 0` and `(_, _) -> nil`.
  Only literal `true` turns it on. A non-number `min` is ignored. It uses only `Kernel.max/2`.
- Moduledoc lines 59-60 and the `build_record_schema/1` @doc are updated to say that
  `"minimum"`/`"maximum"` are emitted from `min`/`max`/`non_negative` and `"maxLength"` is still never emitted.
- **Decimal representation.** A `:decimal` record value is a JSON number (`"type" => "number"`,
  matched by `is_number/1`, json_schema.ex:83). A string or `%Decimal{}` fails the `type` check first,
  and `collect/3` short-circuits on a type violation (json_schema.ex:43-55). `%Decimal{}` appears only
  later, when a promoted column is bound (`TenantProvisioning.cast_promoted_value/2`,
  tenant_provisioning.ex:2582-2596), after validation. Stored bounds decode from JSONB as an
  Elixir integer or float. `numeric_violations/3` compares `value < schema["minimum"]` numerically
  (int/float mixing is exact for Erlang `<`), so `0.5` with `min: 0.1` passes. Float boundary
  equality: `0.1 < 0.1` is false, so the bound itself passes. Binary-float rounding of
  bounds like `0.1` is accepted; it is the same representation as the value.
- **Engine support (verified).** json_schema.ex:102-105 emits `"minimum"`/`"maximum"` with
  `is_number(schema[...])` guards. The keyword names match `ValidationFailure.constraint`
  (validation_failure.ex:13-19). Nothing changes in `JsonSchema`.

## 5. HTTP and INV-2

`render_record_command/3` (entities.ex:1394-1402) and `import_reason_json/1` (1286-1287) both use
`violation_map/1`. Its `ValidationFailure` clause (2694-2700) emits `code = constraint`,
`path = field_path`, and the message `"#{field_path} violates #{constraint}"`, built from the
schema-declared field name, never from `actual` (comment 2682-2684). So a record out of range
returns 422 `code == "minimum"`, and the submitted value is not in the body.
A definition `min > max` returns 422 through `render_create_definition/2` (642-650), giving
`code == "invalid_range"`, `path == ["fields","qty"]` and a fixed message. GET active returns the keys
because `definition_map/1` (2607-2612) serves `definition_json` verbatim.

## 6. Shape hashes, DDL, req227 doc

- `Definition.Shape` (shape.ex:43-64) is **not changed**. It hashes whatever document it is given,
  so a key-less document hashes as before, and `non_negative: true` vs `min: 0` differ (D4).
  TEST-DESIGNER adds a `@gh2532_keyless` fixture (one `:integer`, one `:decimal` field) to
  shape_test.exs. The digests are captured on **f7ce96f0** (pre-change), using the same procedure
  as the GH #2529 block (shape_test.exs:142-182). It also adds a refute-equal test for
  `min: 0` vs `non_negative: true`.
- DDL: there is no edit. `generate_table_ddl/3` (ddl.ex:152) ignores unknown field keys, and the only
  CHECK it emits is the enum one (ddl.ex:612-622).
- `lib/letflow/design/req227-entity-record-payload-validation.md`: update the §4.1 table rows
  `:integer`/`:decimal` (lines 188-190), the bold finding (197-217) and OQ-1 (371-377) with a
  "Superseded by GH #2532" note that points here. Line 86's table row is unchanged.

## 7. Callers that read, modify and write records

Validation runs on every `create_record/2` and `update_record/2` (records.ex:1007-1012), so an
adopting tenant's out-of-range legacy row cannot be re-saved:
- `RecordDeadlineSweep.apply_transition/3` (scheduler/record_deadline_sweep.ex:248-262) writes
  back `record.field_values`. On `record_payload_invalid` it rolls back that one record and logs
  it (lines 87-88, 209). The sweep keeps running, but that record never transitions.
- `Exam.Session` (modules/exam/session.ex:1064, 1263, 1328) and `Exam.AntiCheat` (anti_cheat.ex:258)
  write exam types whose definitions are pack-generated without bounds (generate_pack.exs is
  unchanged), so they are unaffected unless a tenant redefines those types itself.
No code change. This goes in the release note: "fix data before tightening".

## 8. Blast radius

Opt-in. No stored definition contains these keys today: the router drops them (2.1) and the pack
rejects them (2.2). Subschemas, hashes and DDL are unchanged when the keys are absent. There is no
migration and no re-activation. An adopting definition gets a new `logical_shape_version`. An older
installer rejects a pack that has bounds, which goes in the release note. The SPA type
(`web/src/types/api.ts`) and the input `min`/`max` attributes are a follow-up.

## 9. Production files (6) and split fallback

`entities/definition.ex`, `entities/definition/validator.ex`, `entities/record/validator.ex`,
`entities/records.ex`, `routers/entities.ex`, `definitions/solution_pack.ex`. The other file is
the req227 design doc, which is documentation. If REVIEWER counts more than 6: **4a** = definition.ex,
validator.ex, routers/entities.ex, solution_pack.ex (accept, validate and store). **4b** =
record/validator.ex, records.ex (enforce), merged right after 4a.

## 10. Anti-patterns (docs/anti-patterns.md)

- "An established template-substitution mechanism applied to two of three sibling code paths,
  not all three" (2306) and "A gate-approved design fixing a shared write function missed a
  sibling write path..." (2518): all 4 conversion sites are listed in section 2. The 2 that are
  deliberately not touched are justified in 2.5, and tests cover each touched site (router via
  entities_test, pack via solution_pack_test, read-back via records_test).
- "A validator that began refusing at activate broke two already-merged test files..." (4670):
  Rule 12 only fires when a key is present. Before pushing, ELIXIR-DEV runs
  `grep -rln "\bmin:\|\"min\"\|non_negative" test/` and runs every file it hits.
- "Claiming a function 'already carries' a value without reading its real parameter list"
  (2117): every carry claim above cites the real lines.

## 11. AC -> design -> named test

| AC | Design | Test (file :: name) |
|---|---|---|
| 1 Validator | §3 R1-R7 | definition/validator_test.exs :: "GH #2532 :invalid_range" -- `{integer,min 0,max 10}` ok; `min 5 max 1`; `min "a"`; `min 1.5` on integer; `min` on string field; `non_negative true, min -1`; `non_negative "yes"`; each `:invalid_range` with `path == [:fields, "qty"]`; key-less fixtures `:ok`; plus `min "NaN"`, `min nil`, `min 10^400` and `max 10^400` do not crash |
| 2 subschema | §4 | record/validator_test.exs :: "GH #2532 range keywords" -- `{1,5}` gives `"minimum"=>1,"maximum"=>5`; non_negative gives `"minimum"=>0`; key-less subschema is exactly the type map; 0 gives `"minimum"` at `/qty`, 6 gives `"maximum"`, 1 and 5 pass; decimal 0.5 with min 0.1 passes; `effective_minimum/2` table |
| 3 DB records | §2.3, §4 | records_test.exs :: "GH #2532 non_negative qty" -- create+activate; `-1` gives `{:error,{:record_payload_invalid,[_\|_]}}` and the event count is unchanged; `0` gives ok; update to -3 is refused and the row is unchanged |
| 4 Round-trip | §2.3 | records_test.exs :: "GH #2532 read-back carries each key" -- three DB definitions, min-only, max-only and non_negative-only, each refusing (each fails if its key is dropped by `field_document/1`) |
| 5 HTTP | §5 | entities_test.exs :: "GH #2532 ranges" -- 201 + GET active has keys; `min>max` gives 422 `invalid_range`; out-of-range gives 422 `minimum`, and the body does not contain the submitted value; in-range gives 201 |
| 6 Pack | §2.2 | solution_pack_test.exs :: "GH #2532 bounds round-trip" -- export, install into tenant B, keys kept; field key `"minimum"` gives `:invalid_pack_document` |
| 7 Compat | §6 | shape_test.exs :: "GH #2532 hash stability" (digests pinned from f7ce96f0); existing suites unmodified |
| 8 INV-8 | §2.3, §4 | records_test.exs :: "GH #2532 corrupt stored bound" -- a `definition_json` written directly with `"min" => "a"` and another with `"non_negative" => "yes"`: create_record accepts -1 (the key is ignored) and nothing raises |
| 9 No CHECK | §6 | ddl_test.exs :: "GH #2532 bounds add no CHECK" -- a promoted (`queried`) bounded integer gives `generate_table_ddl/3` output equal to the unbounded one |

## 12. Open questions

- **OQ-1.** Bounds outside bigint range on a promoted `:integer` field, or finer than
  `decimal_scale` on a `:decimal` field, are accepted. A record value past the bigint range already
  fails at the DB as before. Should Rule 12 reject these? This design says no (not in the ACs).
- **OQ-2.** `effective_minimum/2` is public, with `@doc`, so it can be tested in isolation. REVIEWER
  may prefer `@doc false` plus testing only through `build_record_schema/1`. Either works for AC2.
- **OQ-3.** AC4 "unit test" is met by DB-backed per-key tests, not by making
  `Records.definition_document/1` public. This keeps the API surface unchanged.
