# GH #2654 -- `:decimal` entity fields accept and return exact decimal strings and enforce `decimal_scale`

Run: WF-02, branch `feat/GH-2654-decimal-exact` off origin/main (9a8aa7ca). Source: WMS decision 0057 D4
(`docs/migration/decisions/0057-wms-customer-draft-reconciliation.md:16,24`), consumer WMS draft REQ-504. Backend only
(`lib/letflow/`, `docs/`). No migration, no DDL change, no event-type change. Prior art for "decimal as string":
decision 0056 (versioned documents, line 84). Line numbers are at 9a8aa7ca. Design only: nothing here was run
(read-only pass); the reproduction (AC1) is the implementer's first step.

## 1. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Write**: a `:decimal` field accepts a decimal STRING (canonical grammar, section 3). A JSON number (integer or float) stays accepted for back-compat. No opt-in refusal flag in this PR (OQ1). | The SPA sends `parseFloat` numbers for decimal filters and number inputs for forms (`web/src/pages/entities/EntityListBrowserPage.tsx:69`, `web/src/utils/entityFieldToFormField.ts:66`). Refusing numbers would break them and every existing tenant. |
| D2 | **Storage**: after validation the value is rewritten to its canonical scale-padded STRING, and that string is what is stored in `field_values` (JSONB), put in the event payload, and echoed in the create response. Never a float. | `->>` of a JSON string is the exact text, so `(?->>?)::numeric` (compiler.ex:531) is exact. No Decimal-to-JSON-number encoder exists (Jason encodes `Decimal` as a string), so a string is the only exact JSON form. |
| D3 | **Read**: reads return a STRING for every decimal field, always. No flag. Legacy rows that store a JSON number are converted at render time (section 6). | Least-breaking: existing tenants' stored data and events are untouched; the visible change is number -> string on read, which the SPA displays unchanged (it only renders, section 9). A per-field/per-tenant flag would leave two wire shapes forever and defeat D4 of 0057. |
| D4 | **Scale enforcement**: refuse (422, field path), never round. Value-based: a value is accepted iff it is exactly representable with `decimal_scale` fractional digits (so `"2.500"` is accepted for scale 2 and stored `"2.50"`; `"2.505"` is refused). | The issue allows refuse-or-round; silent rounding of a quantity is the wrong default for a ledger. Postgres `numeric(p,s)` rounds silently (promoted column), which today diverges from the JSONB value (section 2.3). |
| D5 | **Precision**: refused when integer digits exceed `decimal_precision - decimal_scale`. | Mirrors `numeric(p,s)`; today overflow reaches Postgres (22003) only on a promoted column. |
| D6 | **Bounds** (`min`/`max`/`non_negative`) are compared with `Decimal.compare/2` only. A decimal-field bound may be a JSON number OR a decimal string. | Exact comparison (AC5). JSON-Schema `minimum`/`maximum` (json_schema.ex:102) compares Elixir numbers, which cannot hold a string. |
| D7 | The decimal check is a pre-pass in `Record.Validator`, not a JSON-Schema keyword. The derived JSON schema for a decimal field becomes `{"type":"string"}` with no range keys (the pre-pass has already turned number inputs into strings and enforced bounds). | JsonSchema has no scale concept; keeping it generic. |
| D8 | Per-unit-of-measure scale is NOT a core concern: field scale = the maximum scale; narrowing per UoM is the consumer's/handler's job (section 8). | The scale is a property of the field (issue text). |
| D9 | No event schema version bump. | `field_values` is `{"type":"object"}` in the envelope (event_types.ex:54-64); only the inner value type of a decimal changes number -> string for new events. Old events replay unchanged (section 7). |
| D10 | Decision record: NEW `docs/migration/decisions/0060-decimal-entity-fields-exact-strings.md` (next free number; 0059 exists), plus a one-line "Amended by 0060" note under 0057 D4. | The wire shape of an existing field type changes (reads). |

## 2. Where `:decimal` is handled today (evidence) and the change at each place

### 2.1 Definition validation (`lib/letflow/entities/definition/validator.ex`)
- 463-503 Rule 7: precision and scale required together, `scale <= precision`, absent on other types. **No change.** Add nothing about a precision cap (OQ2).
- 505-578 Rule 12 (#2532): `valid_bound?(:decimal, b)` is `is_number(b)` (578); `min > max` (544-ish), `min < 0`, `max < 0` compare raw terms. **Change**: for `:decimal`, `valid_bound?` also accepts a binary matching the canonical grammar (section 3, without scale/precision counting, length-capped); the three comparisons go through a private `compare_bounds/2` (Decimal.compare after `Decimals.to_decimal/1`), so number-vs-string bounds compare exactly. Messages stay fixed strings and never echo the value. Update the message at 557/560 to "a number or decimal string for :decimal fields".
- `Definition` typedoc (definition.ex:55-58, 95-96): `min`/`max` on `:decimal` become `number() | String.t()`.
- Carriers of the bound keys (ISS-0624 key-drop risk): `Records.field_document/1` (records.ex:1511-1526) copies `min`/`max` verbatim via `put_present`: strings pass through unchanged, **no change**. `routers/entities.ex:585-586` HTTP builder: `maybe_put_optional` for `min`/`max` passes any term: **no change**, but a test must POST a definition with `"min": "0.001"` and prove it round-trips.

### 2.2 DDL (`ddl.ex:581-588`)
`decimal_pg_type/1` -> `numeric(p, s)` or bare `numeric`. **No change.** Only a promoted (queried/column-promoted) field gets a typed column; the JSONB `field_values` has no type constraint at all. Promoted values are cast by `TenantProvisioning.cast_promoted_value/2` (tenant_provisioning.ex:2803-2817): `numeric` and `numeric(...)` already accept `Decimal`, number (via `Decimal.new(to_string(v))`) and binary (`Decimal.new(v)`), so a canonical string is bound as an exact `Decimal`. **No change**, but add a test that a promoted `numeric(10,2)` column holds `2.50` from `"2.50"`. Note `Decimal.new/1` raises on garbage: safe only because section 3 validation runs first (every write passes `validate_field_values`, section 2.4).

### 2.3 Current behaviour (the AC1 reproduction target; from code reading, to be confirmed by running)
- Create `{"qty":"2.50"}`: `field_subschema(%{type: :decimal})` is `{"type":"number"}` (record/validator.ex:108); `matches_type?(value,"number")` is `is_number/1` (json_schema.ex:83) -> violation `{field_path:"/qty", constraint:"type"}` -> `{:record_payload_invalid, violations}` (records.ex:1451-1455) -> HTTP 422 `record_payload_invalid` with violation `{"code":"type","path":"/qty","message":"/qty violates type"}` (`violation_map/1`, routers/entities.ex:2694 region, drops `actual`).
- Create `{"qty":2.5}`: passes; `Jason.encode!(field_values)` (records.ex:1000, and the event payload) stores `2.5`; response and later reads return the JSON number `2.5` (Ecto `:map` -> Jason decodes JSONB number to a float, latest.ex:30). `2.50` and `2.5` are indistinguishable. A 17+ significant-digit number loses digits in the request-body decode (Plug.Parsers/Jason float), before any code of ours runs.
- Scale is unchecked: `2.505` into scale 2 passes validation; JSONB keeps `2.505`; a promoted `numeric(10,2)` column silently rounds to `2.51` (divergence); an out-of-range value on a promoted column raises a Postgres numeric overflow (likely 500).

### 2.4 Write side -- single choke point
Every write goes through `Records.validate_field_values/2` (records.ex:1451): `create_record` (338), `update_record` (419), step/handler `command_multi/3` (551, which `HandlerWrites.create/3` and process `entity_writes` both use via `Records.command_multi`), and bulk import (via `create_record/2`, routers/entities.ex:1340-1350). **Change** at this one place (D2, D7):
1. `validate_field_values` first calls `Decimals.normalize_field_values(definition_doc, field_values)`.
2. On `{:ok, normalised}` the NORMALISED map must be what flows into `ctx.field_values` (events, JSONB insert at records.ex:1000, fingerprint at 1226, `to_append_attrs`). Today the three call sites ignore the function's value and use the original map; each of the three sites (338-345, 419-424, 551-557) must be changed to take the normalised map. This is the main trap: validating but storing the raw input would defeat D2.
3. Idempotency/fingerprint: because normalisation happens before `fingerprint_field_values/1` and the event encode, a retry that sends `2.5` after an original `"2.50"` compares equal (`json_equal?`, records.ex:1292-1330 sees string vs string). Do not touch `json_equal?`.
4. `step_writes.ex` size caps (value 65_536 B, line 262_144 B, lines 514-520/725) are measured on the JSON encoding; a canonical string is not larger than the number it replaces by more than the scale padding. No change. The decimal input cap (section 3) is far below them.
5. Process-variable mapping: variables are JSON terms (expr.ex numbers are floats/integers); a variable holding `"2.50"` now maps cleanly, a numeric variable still maps (legacy path). No engine change. Note for REQ-504: put decimals in variables as strings.

### 2.5 Record validator (`record/validator.ex`)
- Add public `Letflow.Entities.Record.Decimals` (new file `lib/letflow/entities/record/decimals.ex`), section 4.
- `field_subschema(%{type: :decimal})` (108): returns exactly `%{"type" => "string"}`; `put_range` is no longer applied to decimal (still applied to integer). Update the moduledoc (58-63) and the #2532 tests that assert `"minimum"`/`"maximum"` on a decimal subschema.
- `validate_record_payload/2` stays the public entry for the JSON-schema part and keeps its signature; add `normalize_record_payload(definition, field_values) :: {:ok, field_values()} | {:error, violations()}` = decimals pre-pass, then `validate_record_payload` on the normalised map; violations from both passes are concatenated (a failed pre-pass for a field replaces that field's value with a placeholder string `""` ONLY inside the schema check input so the schema pass does not emit a second violation for it).

### 2.6 Reads and serialisation
All record JSON reads are `record.field_values` passthrough: `record_map` (routers/entities.ex:2845), `entity_row_map` (2596-2599, 2808), export (2591), query items (2787), plus record history (decision 0059 field policy) and joined rows. Aggregate results already serialise `Decimal` as strings (Jason), see 2.8.
**Change (D3)**: a pure `Decimals.render_field_values(field_values, decimal_specs)` where `decimal_specs :: %{String.t() => scale :: non_neg_integer()}` converts, for each decimal field present, a stored JSON number or string to the canonical scale-padded string (`Decimal.from_float` for floats; a stored value that is not parseable, or a `nil`, is passed through unchanged -- reads never raise, INV-8). Call it at the six render sites above. Where the definition is not already at hand, `Query.Allowlist` fields (allowlist.ex:63, 273-291, 415) gain `decimal_scale` (nil for non-decimal) so the router does not re-load the definition per row; `Allowlist` and `Records.definition_document/1` already hold `decimal_scale` source data (`records.ex:1516`). Redaction (`FieldGrants`, field_grants.ex:32) keeps the key and replaces the value; render BEFORE redaction so a redacted value is not parsed, and skip nil/redaction placeholders (a non-parseable value is left as is).
Legacy-number read rule: `Decimal.from_float(2.5)` is shortest round-trip (`"2.5"`), padded to scale -> `"2.50"`. If the legacy value has MORE fractional digits than the scale, do not truncate: return its plain `Decimal.to_string(:normal)` form.

### 2.7 Query: filters, sort, cursor
- Filter values reach the compiler raw (`routers/entities.ex:2079-2080`, `build_one_filter_dynamic`, compiler.ex:980-988); `^value` is bound next to `(?->>?)::numeric`. A string value for a decimal field is a Postgrex encode error today (expected to surface as a 500; confirm in the reproduction), and a float goes through Postgrex numeric encoding.
- **Change**: in `build_one_filter_dynamic` (before `build_filter_dynamic`), for an allowlisted field of type `:decimal` and ops `eq neq gt gte lt lte in not_in`, coerce `value` (and each element for `in`/`not_in`) with `Decimals.filter_value/1` -> `%Decimal{}`; accepts a canonical-grammar string, an integer, a float (legacy, via `from_float`). Anything else -> `{:error, {:invalid_decimal_value, field}}`, rendered as 422 beside `{:invalid_in_value, field}` (routers/entities.ex:2710-2711). Scale is NOT enforced on filter literals (`> 2.5555` is a legitimate predicate); only the length cap and grammar apply. The coerced `Decimal` is a bound parameter; the fragment literal stays the compile-time `@decimal_fragment`.
- `script_reads.ex:224-225` `coerce(:decimal, ...)` accepts integer/float only: add a binary clause (canonical grammar via `Decimals.filter_value/1`; invalid -> the existing type-mismatch `placeholder(:decimal)` constant-false).
- Sort/group: `json_cast_dynamic(:decimal, ...)` casts the stored text, exact for both string and legacy-number storage. **No change.** Mixed storage forms (`"2.5"` vs `"2.50"` vs legacy `2.5`) all cast to equal numerics.
- Cursor (cursor.ex:353-355, 496): `decode_component(:decimal, v)` uses `Decimal.new(to_string(v))`, which RAISES `Decimal.Error` on a malformed string. Replace by `Decimal.parse/1` (strict: `{d, ""}` else `:error`) so a tampered cursor yields the existing cursor error and never a crash; `encode_component(%Decimal{})` already emits a string. `read_sort_value` (477-491) returns the raw stored value (string or float): both decode through the same clause. No other change.

### 2.8 Aggregates (`compiler.ex:870-905`)
`sum/avg/min/max(("?->>?")::numeric)` run in Postgres `numeric`; results are `%Decimal{}` -> Jason strings; `aggregate_result_map` (routers/entities.ex:2309) passes them through. So with exact stored text the aggregate is already float-free; the float step today is only the INPUT (request body number -> float -> JSONB text) which D2 removes. **No compiler SQL change.** Presentation: Postgres `sum` scale equals the max input scale, so `sum` of ten `"0.1"` is `"1.0"` (exactly the AC expectation). For `sum/min/max` of a decimal field and for a decimal `group_by` key, pad the rendered string to the field's scale in `aggregate_result_map` (uses the same `decimal_scale` from the allowlist); `avg` is left as Postgres returns it (its scale is not the field's). If padding makes the AC test awkward the test may assert `Decimal.equal?` on the parsed result; the padded string form `"1.00"` for a scale-2 field is the specified output.

### 2.9 Events, audit, history, projection
- Record events carry `field_values` as JSON; new events carry decimal strings (D2, D9). Jason encodes strings losslessly; no float step remains on the write path.
- Projector rebuild (`Record.Projector`) re-upserts the payload's `field_values` without re-validating, so replay of OLD events puts legacy JSON numbers back into `entity_record_latest`; D3's render-time conversion covers them. A replay of new events reproduces strings byte-identically. No projector change.
- `Audit` (audit.ex:627) leaves `Decimal` structs as-is; record writes do not put Decimal structs in audit entries. No change.
- Event-schema bump policy: the project bumps `schema_version` in `event_types.ex:80` only when the envelope schema changes; it does not here (D9). If the supervisor wants decimal-typed event payload checking later, that is a separate versioned schema (out of scope).

### 2.10 Export / import
Export returns `field_values` through `export_record_map` (2591/2599): rendered via D3 (strings). Import (`handle_import_records`, 1340-1350 -> `create_record/2`) is covered by 2.4: strings and numbers both accepted, errors surface per entry as `record_payload_invalid` (`import_reason_json`, 1393). No CSV path exists for records (grep found none); nothing to change.

### 2.11 OpenAPI/docs
Update `docs/guides/backend_developer_guide.md` (entity field types section) and the decision records (D10). `docs/frontend/` and `docs/mobile/` mention no decimal wire shape; no change there.

## 3. Input grammar and limits (single definition, used by writes, bounds, filters)

`Decimals.parse/1` accepts exactly:
- a **binary** matching `^-?(0|[1-9][0-9]*)(\.[0-9]+)?$` and `byte_size <= 1100` (the cap is checked BEFORE the regex or any `Decimal` call; Postgres numeric max is 1000 digits; DoS bound);
- an **integer** (any size up to the same digit cap after `Integer.to_string`);
- a **float** (legacy), finite by construction (JSON has no NaN/Infinity; Jason never yields them), converted with `Decimal.from_float/1`, then rendered in plain notation (`Decimal.to_string(d, :normal)`), never exponent form.
Refused with constraint `"type"`: leading `+`, any whitespace, leading/trailing `.` (`".5"`, `"5."`), exponent (`"1e3"`), thousands/locale commas (`"1,5"`), `"NaN"`, `"Infinity"`, empty string, leading zeros (`"007"`), boolean, null (a `nil` for a non-required field follows the existing null handling: unchanged), map, list.
Normalisation: negative zero (`"-0"`, `"-0.00"`) becomes `"0.00"` (sign dropped when all digits are zero); output is `Decimal.to_string(d, :normal)` after rescaling to exactly `decimal_scale` fractional digits (`"2.5"` -> `"2.50"`, `"3"` -> `"3.00"`, scale 0 -> no dot).
Order of checks per field: type/grammar -> scale (value-based, D4) -> precision (D5) -> `minimum`/`maximum` (exact). One violation per field per pass, first failing check wins (consistent with Rule 7/12 one-per-field style).

New `ValidationFailure.constraint` strings (document them in validation_failure.ex's moduledoc closed list): `"scale"`, `"precision"`; `"type"`, `"minimum"`, `"maximum"` are reused. `actual` carries the raw submitted term in memory only; `violation_map/1` already drops it from the response (INV-2). 422 body example: `{"code":"scale","path":"/qty","message":"/qty violates scale"}`.

## 4. Public interfaces (signatures only)

New module `Letflow.Entities.Record.Decimals` (pure, no DB, no process):
- `parse(term(), precision :: pos_integer() | nil, scale :: non_neg_integer() | nil) :: {:ok, Decimal.t()} | {:error, :type | :scale | :precision}` -- `nil` precision/scale skips those checks (bounds, filters).
- `to_canonical(Decimal.t(), scale :: non_neg_integer()) :: String.t()` -- scale-padded, plain notation, no negative zero.
- `normalize_field_values(Definition.t(), field_values :: map()) :: {:ok, map()} | {:error, [ValidationFailure.t()]}` -- touches only `:decimal` fields present in the map; other keys are returned unchanged; unknown keys are left to the schema pass (`additionalProperties`).
- `filter_value(term()) :: {:ok, Decimal.t()} | :error` -- grammar and length cap only (no scale/precision).
- `bound(term()) :: {:ok, Decimal.t()} | :error` -- for definition bounds (number or canonical string).
- `render_field_values(map(), %{String.t() => non_neg_integer()}) :: map()` -- never raises.
- `render_value(term(), scale :: non_neg_integer()) :: term()` -- single-value form (aggregates, group keys).

Changed signatures: none public except `Record.Validator.normalize_record_payload/2` (new) and the extra `decimal_scale` key on `Allowlist.allowlisted_field()` (new optional key, nil default). New compile error `{:invalid_decimal_value, field :: String.t()}` added to `Compiler`'s error union (types in compiler.ex ~line 90-100) and to `render_query_error/2` (-> 422). No new route, no new permission, no new DB object.

## 5. Acceptance-criteria map

| AC | Element |
|---|---|
| Reproduce first (`"2.50"` and `2.5`) | Section 2.3 gives the code-derived expectation: `"2.50"` -> 422 `type` at `/qty`; `2.5` -> 201, `field_values.qty == 2.5` (float). The implementer runs it on main BEFORE editing, quotes both responses in the PR, and corrects 2.3 if reality differs. |
| Accepts exact decimal string; numbers stay accepted; effect on tenants stated | D1, section 3, section 9 migration story |
| Stored and read back exactly, string on read | D2, D3, 2.4, 2.6 (test: store `"12345678901234567890.12"` into a (30,2) field, read back byte-identical via GET, query, export, record history) |
| `decimal_scale` enforced, 422 with path, a test per behaviour | D4/D5, section 3; tests T4-T7 |
| min/max/non_negative exact on strings | D6; tests T8 |
| Compiler aggregates without float; sum 0.1 x10 == exactly 1.0 | 2.8; test T11 |
| Decision record/amendment, back-compat unless stated | D10; section 9 |

## 6. Invariants

I1 No `Float`/`:erlang.float` arithmetic or comparison on a decimal path (Decimal only; `Decimal.from_float` only for legacy-number input conversion). I2 After a successful write, every decimal field in the stored/event/response `field_values` is a canonical scale-padded string. I3 A write that passes validation can never raise in `cast_promoted_value` or the numeric cast. I4 Reads, cursors and renderers never raise on a malformed stored value (pass through / `:error`). I5 Values never reach SQL text: only bound parameters; fragment literals stay compile-time constants.

## 7. Compatibility and replay

Existing rows/events keep JSON numbers; no backfill. They read as strings (D3), filter/sort/aggregate identically (text cast is shape-independent), and replay without change. A legacy record updated later is rewritten with strings. Mixed shapes inside one tenant are expected and harmless. An optional one-time backfill is explicitly out of scope.

## 8. Per-unit-of-measure scale (D8)

Core guarantees: stored value has exactly `decimal_scale` fractional digits, never more. A UoM with a smaller scale (kg 3, pcs 0, same quantity field with scale 3) is enforced by the module/write handler: it knows the UoM from the sibling field and checks `Decimals.parse(value, precision, uom_scale)` (public function, usable by handlers via `HandlerWrites`), refusing in its own handler error. Out of scope: any definition-level "scale depends on field X" feature, conversion factors, rounding rules per item (0057 D4 says half-up per item: that is posting logic, the WMS module's).

## 9. Migration story, SPA and mobile

- Existing tenants: writes unchanged for numbers (apart from the NEW scale/precision refusals: a client that today stores `2.505` into a scale-2 field now gets 422. This is the one behavioural tightening; it is what the AC asks for and it removes the promoted-column rounding divergence). Reads change number -> string for decimal fields only.
- SPA: decimal columns render the value as text (EntityListBrowserPage cell rendering is generic); filters send `parseFloat` numbers (still accepted); form inputs submit numbers (still accepted). One implementer check: grep `web/src` for arithmetic on a record's decimal value (`+`, `Number(`, `toFixed`) in entity pages and fix if found. A follow-up frontend ticket (out of scope) should send strings and use a decimal-safe input.
- Mobile (`apps/mobile`): `EntityFieldType.decimal` exists (list.dart:28,43); check the renderer does not cast the value with `as num`; if it does, that is a bug to file (OQ6), not fixed here.
- Rollback: reverting the PR leaves strings in `field_values`; the old validator would 422 them on the next full-replacement update, so rollback needs the D3 render change only if mixed data matters. State this in decision 0060.

## 10. Test plan (ExUnit; reproduction test first and committed separately)

T0 (reproduction, run on main): create `"2.50"` and `2.5` on a (10,2) field; record statuses/bodies in the PR. T1 string accepted, stored `"2.50"` in JSONB (`field_values->>'qty'`) and event payload. T2 number `2.5` accepted, stored `"2.50"`. T3 `"3"` -> `"3.00"`; scale 0 field `"3"` -> `"3"`, `"3.0"` accepted -> `"3"`, `"3.1"` refused. T4 `"2.505"` scale 2 -> 422 `scale` path `/qty`; `"2.500"` accepted -> `"2.50"`. T5 precision overflow `"123456789.12"` in (10,2) -> 422 `precision`; `(2,2)` accepts `"0.99"`, refuses `"1.00"`. T6 grammar table (each refused with `type`): `"+1"`, `" 1"`, `"1 "`, `".5"`, `"5."`, `"1e3"`, `"1,5"`, `"NaN"`, `"Infinity"`, `""`, `"007"`, true, `%{}`; and `"-0.00"` -> `"0.00"`; a 2000-byte string -> 422 `type` without parsing. T7 float `0.1+0.2` as JSON `0.30000000000000004` into scale 2 -> 422 `scale` (proves no silent rounding). T8 bounds: field `min:"0.10"`, `max:"99.99"`: `"0.10"` ok, `"0.09"` -> `minimum`, `"99.99"` ok, `"100.00"` -> `maximum`; `non_negative` refuses `"-0.01"`, accepts `"-0"`; definition create with `min:"1", max:"0.5"` -> `invalid_range`; number bound and string bound mixed compare. T9 idempotent retry with `2.5` after `"2.50"` -> duplicate, no second event. T10 update (full replacement) and step/handler `command_multi` writes normalise too; bulk import per-entry error. T11 aggregate: 10 records `"0.1"`, `sum` equals `Decimal.new("1.0")` exactly (assert `Decimal.equal?` and the rendered string `"1.00"` for scale 2); min/max/avg/group_by on a decimal field; legacy-number rows sum identically. T12 filters: `eq "2.50"`, `gt "2.4999"`, `in ["1.00","2.50"]`, legacy float `2.5`, invalid `"abc"` -> 422 `invalid_decimal_value`; sort order with mixed storage forms; keyset cursor over `"2.50"/"10.00"` (numeric not lexicographic order) and a tampered decimal cursor -> cursor error, no raise. T13 legacy: seed a row with a JSON number via direct insert, GET/query/export/history return the padded string; unparseable stored value passes through without raising. T14 promoted `numeric(10,2)` column receives the exact value and equals JSONB. T15 `script_reads` decimal match with a string. T16 existing #2532 tests updated for D7 subschema. T17 security: a filter value `"1; DROP TABLE x"` is 422 (grammar), never reaches SQL; redacted decimal field stays redacted on read.

## 11. Security and limits notes

No new tenant-data path, route or permission; SECURITY-REVIEWER not required by the routing note, but INV-2 (no value echo: `violation_map` drops `actual`; definition-rule messages are fixed strings) and INV-8 (no crash on stored/corrupt data: sections 2.6, 2.7) are explicit above. Injection: values are bound parameters (`^value`, `^field_name`); strings are grammar-validated before `Decimal` is called. Resource limits: 1100-byte pre-check before regex/parse; `Decimal` arithmetic on at most ~1100 digits per value; existing body-size caps unchanged.

## 12. Files touched (expected, ~9 production)

`entities/record/decimals.ex` (new), `entities/record/validator.ex`, `entities/records.ex` (3 call sites + render), `entities/definition/validator.ex`, `entities/definition.ex` (typedoc), `entities/query/compiler.ex` (filter coercion + error type), `entities/query/cursor.ex` (parse), `entities/query/allowlist.ex` (+`decimal_scale`), `entities/script_reads.ex`, `routers/entities.ex` (render sites, error clause, aggregate padding), `event_store/registry/validation_failure.ex` (doc), docs (decision 0060, 0057 note, developer guide). If this exceeds the split rule (~6 production files), split: PR-A normalisation+validation+storage (D1-D7, 2.1, 2.4, 2.5, 2.7 filters, 2.8) and PR-B read rendering (D3, 2.6, 2.10, 2.7 cursor); but PR-A alone returns numbers on read for legacy rows and strings for new ones, so ship both before WMS consumes it.

## 13. Open questions (for the supervisor)

OQ1 Opt-in `decimal_strict` field flag that refuses JSON numbers (the issue offers it)? Design says NO for now (cost: one more definition key through the 4 carrier places; benefit: guaranteed no float step for WMS). Float inputs with 16+ significant digits cannot be detected as lossy. OQ2 Cap `decimal_precision` in Rule 7 (today any `pos_integer()`; Postgres max 1000)? Recommend max 1000 to match the 1100-byte input cap; changes validation of existing definitions only if one exceeds it. OQ3 Confirm new `ValidationFailure.constraint` names `"scale"` and `"precision"` (vs reusing `"type"`). OQ4 Value-based scale rule (`"2.500"` accepted at scale 2) vs literal digit-count rule (refused): chosen value-based. OQ5 Aggregate result padding to field scale (2.8) vs leaving Postgres' scale: chosen pad for sum/min/max/group. OQ6 Mobile renderer behaviour with a string decimal -- unverified (read only the enum). OQ7 Wanted: one-time backfill of legacy numbers to strings? Chosen no (render-time conversion).
