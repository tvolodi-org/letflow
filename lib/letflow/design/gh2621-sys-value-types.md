# GH #2621: narrow `_sys` value types per key shape; close the `INSTANCE_SYS_VARIABLES_SET` values check

Author: CODE-DESIGNER, 2026-10-15. Branch `design/GH-2621-2623`, from `origin/main` `10e6688f`.
Parent: #2587 / REQ-499 (decision 0054 D1/D1a). Depends on #2620 (PR A1, merged `ad91d48a`).
Targets PR B's prerequisites: must land BEFORE PR B writes `_sys` values in a production path.
Design only: signatures, shapes, test briefs. No function bodies.

## Changelog

* Revision 0 (2026-10-15): first design. Supervisor ruling of 2026-10-15 on the issue is the
  source of the requirement; section 5 lists what still needs a ruling.

* Revision 1 (2026-10-15): CDV FAIL (one blocker) and supervisor rulings applied. F1: replay
  tests of malformed or wide stored events use a raw-insert helper, because the existing
  `append!/4` goes through the new guard (section 4). F2: corrected the layering premise (OQ-1,
  now closed). F3: purity build constraint for the new functions (section 5). OQ-1..OQ-5 are
  closed by supervisor rulings (section 7). The dotted-`output_record_id_var` rule is a hard PR B
  constraint (section 9).

* Revision 2 (2026-10-15): CDV re-check amendments (ELIXIR-DEV). F-A: the raw-insert helper is
  specified by an explicit column list (section 4). F-B: the cap counts top-level keys, exactly
  40 accepted; more than 40 reports only the count failure; the `{:values, :too_many_keys}` to
  `sys_values_count` mapping is in D-9; a raw-inserted 41-key v1 event is pinned in the replay
  test. The `Registry -> VariableMerge` edge was checked: `mix letflow.check_boundaries` passes.

## 0. Sources and verification (all on `origin/main` `10e6688f`)

| Fact | Where |
|---|---|
| `sys_key?/1`: binary, `<= 160` bytes, `"_sys." <> name`, name `~r/\A[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*\z/`; bare `"_sys"` false | `lib/letflow/engine/variable_merge.ex:225-226, 339-344` |
| `sys_value?/1`: ANY binary, or a non-negative integer | `variable_merge.ex:350-353` |
| `put_sys/3` returns the map, and RAISES `FunctionClauseError` on a bad key/value | `variable_merge.ex:369-375` |
| types `sys_key()` (any string) / `sys_value()` (`String.t() \| non_neg_integer()`) | `variable_merge.ex:184, 187` |
| replay pre-checks every pair with `sys_key?/1` and `sys_value?/1`, then calls `put_sys/3` per pair (sorted); a bad pair is `{:error, {:invalid_sys_variables_event, event_id}}` | `lib/letflow/engine/reconstruction.ex:806-830` |
| the event's seed schema types `values` as `%{"type" => "object"}`, `schema_version` 1 | `lib/letflow/tenant_provisioning.ex:1388-1403` |
| the seed loop treats `{:error, :duplicate_event_type_version}` as success, so an EDITED v1 seed schema never reaches an existing tenant | `tenant_provisioning.ex:1443-1451`; `lib/letflow/event_store/registry.ex:101, 261-283` |
| the registry validates every append against the HIGHEST registered `schema_version` (`ORDER BY schema_version DESC LIMIT 1`), never an exact version | `registry.ex:144-163, 175-190` |
| the registry's JSON Schema subset ignores `patternProperties` and `pattern` ("permitted and inert"), and `additionalProperties: false` only compares against the literal `properties` key list | `lib/letflow/event_store/registry/json_schema.ex:5-18, 176-193`; pinned by `test/letflow/event_store/registry/json_schema_test.exs:496` |
| three append entry points all call `Registry.validate_payload/3` before the Multi | `lib/letflow/event_store.ex:250, 359, 415` |
| replay never re-validates a stored payload against the registry (it reads events and folds them) | `reconstruction.ex` fold; no `Registry` call in that file |
| seed-count pins: 22 rows, and 19 after deleting 3 | `test/letflow/tenant_provisioning_event_seed_test.exs:283, 346` (and the "does NOT duplicate any of the 22 rows" comment near `:426`) |
| static allow-lists: R1 `put_sys` only in variable_merge.ex + reconstruction.ex; R2 the two event literals only in 4 files; R3 a `"_sys"`-prefixed literal only in variable_merge.ex | `test/letflow/engine/put_sys_callers_test.exs:41-47, 167` |
| known key shapes: output var `_sys.<name>` (a minted record id) and `_sys.<name>.seq` (the `event_global_seq` of the create) | decision 0054 D1 (lines 54), D1a.4, D5 |
| ids are minted by `Ecto.UUID.generate/0`-style UUIDs (`records.ex:239` per 0054) | decision 0054 D1 |

### 0.1 The central finding: the issue's schema mechanism is not enforceable as written

The issue asks for `patternProperties` plus `additionalProperties: false` on `values`. On main
that is inert or wrong: `patternProperties` is ignored, and `additionalProperties: false`
with no listed `properties` would refuse EVERY key (the keys are dynamic, `_sys.<name>`).
Changing the validator to honour `patternProperties` is a platform-wide change to a documented
contract ("permitted and inert") and would start enforcing keywords in any tenant-registered
schema that already carries them. So the enforcement must live in code, at the append door
(the issue's "or an equivalent"). Section 1 D-2 and D-3 follow from this.

## 1. Decisions (one-line rationale each)

* **D-1 Compatible tightening, NO `schema_version` bump.** The registered JSON schema for
  `INSTANCE_SYS_VARIABLES_SET` stays v1 and byte-identical; the narrowing is code. Rationale:
  a v2 row's schema could not differ from v1 in the supported subset (0.1), so a bump would add
  a row to every tenant and change the seed-count pins for no enforcement; stored v1 events
  keep their version unchanged. (Alternative considered and rejected: bump to v2 carrying the
  same schema; pure noise, 23 rows, and the registry validates against highest version anyway.)
* **D-2 Enforcement point: `Registry.validate_payload/3`, after the schema passes.** One new
  private step keyed on the event type (compared with `VariableMerge.sys_event_type/0`, so no
  new literal is introduced and R2 is untouched). It covers all three append entry points
  (event_store.ex:250, 359, 415) with one change. Rationale: "an invalid new event is refused
  at append" must hold for `append/2`, `append_platform_event/2` and `append_multi/3` alike.
* **D-3 Why code and not a seed edit.** An edited v1 seed does not reach existing tenants
  (seed loop treats a duplicate version as success), so fresh and existing tenants would
  diverge. A code guard deploys with the binary: every tenant, immediately. No migration, no
  seed-path change, no existing-tenant backfill.
* **D-4 Two tiers, never one predicate.**
  STRICT tier (new appends and the engine writer): exact key shapes and value types, D-5/D-6.
  STORED tier (replay of already-stored events): today's `sys_key?/1` and `sys_value?/1`,
  unchanged in behaviour. Rationale: AC "replay of a stored v1 event with the old wider values
  gives the same state"; strictness on replay would turn old data into a replay failure.
  `sys_key?/1` and `sys_value?/1` therefore keep their current contracts and are re-documented
  as the "stored-event tier"; they are NOT narrowed.
* **D-5 Strict key shapes (closed set of two).**
  `id` key: `"_sys." <> name`, `name` = one segment `[A-Za-z0-9_]+`, total `<= 160` bytes.
  `seq` key: `"_sys." <> name <> ".seq"`, same `name`, total `<= 160` bytes.
  Anything else (a dotted name, `"_sys"`, `"_sys."`, `"_sys.x.y"`, `"_sys.x.seq.seq"`,
  trailing newline, non-binary, an atom) is refused with `:invalid_sys_key_shape`.
  Rationale: 0054 D1 defines exactly these two; `name` has no dot so `_sys.a.seq` is
  unambiguous (the seq of `a`, never the id of a variable named `a.seq`). A variable literally
  named `seq` is fine: `_sys.seq` is its id, `_sys.seq.seq` its seq.
* **D-6 Strict value types.**
  `id` key -> a canonical lowercase hyphenated UUID string, matched by an exact anchored
  pattern `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`, NOT
  `Ecto.UUID.cast/1` (which also accepts upper case and the 32-hex unhyphenated form, so a
  second spelling of one id could be stored). No version/variant nibble check (ids are minted
  by the engine; a version check would make a future v7 id a refusal for no gain).
  `seq` key -> an integer `0 <= n <= 9_223_372_036_854_775_807` (the `event_global_seq`
  bigint ceiling). A float (`7.0`), a numeric string (`"7"`), a boolean, `nil`, a map and a
  list are all `:invalid_sys_value_type`.
* **D-7 Nothing raises (INV-8).** The strict functions return tagged results. `put_sys/3`
  changes from "returns the map / raises" to a result tuple (its only caller today is
  replay, which moves to the stored-tier writer, D-8). Rationale: the issue's "errors, not
  raises"; the callers are allow-listed but a malformed value must still never crash an
  instance transaction.
* **D-8 Separate stored-tier writer.** New `put_sys_replayed/3` applies a pair after the
  STORED-tier predicates and returns a tuple (no raise either). `reconstruction.ex` calls it.
  Rationale: replay must keep writing exactly what it writes today, and the one place that may
  set a reserved key stays a named, allow-listed function (R1 gains the new identifier, D-11).
* **D-9 Guard failure shape.** A refused new event is
  `{:error, {:payload_validation_failed, [%ValidationFailure{}]}}`, the same envelope a schema
  violation uses. Per offending key: `field_path` = `"/values/" <> RFC6901-escaped key` (the
  pointer is `"/values"` when the key exceeds 160 bytes or is not a binary), `constraint` =
  `"sys_key_shape"` or `"sys_value_type"`, `actual` = `nil` (never echo a value; INV-2/INV-4
  hygiene as D-A1.2). Failures are sorted by key. The count failure that
  `check_sys_values/1` returns as `{:values, :too_many_keys}` maps to `constraint`
  `"sys_values_count"`, `field_path` `"/values"`, `actual` `nil`. A non-map `values` that
  somehow passed the schema step maps to `constraint` `"type"`, `field_path` `"/values"`. Rationale: no new error variant for callers
  of `EventStore.append*/2`.
* **D-10 Also cap key count (supervisor ruling, beyond the issue AC).** The cap counts the
  top-level keys of the decoded `values` map: exactly 40 is accepted, 41 refused. When more
  than 40 keys are present, ONLY the single count failure is reported and the per-pair pass is
  skipped. `values` with more than 40 keys is refused (`constraint` `"sys_values_count"`, `field_path` `"/values"`).
  Rationale: the A1 design section 2.3 states "at most 40 keys (20 lines x id + seq)" but main
  does not enforce it. CDV suggested dropping it as outside the issue's ACs; the supervisor
  ruled to keep it. The PR body must say it is a supervisor ruling beyond the issue AC.
* **D-11 Static test updates.** R1 of `put_sys_callers_test.exs` matches the identifier set
  `{put_sys, put_sys_replayed}` with the same allow-list (variable_merge.ex, reconstruction.ex).
  Rationale: otherwise the new name would be an unguarded writer.
* **D-12 PR B constraint recorded now.** PR B's activation validation of
  `output_record_id_var` must accept only `_sys.<one segment>` (a dotted name would be an
  unknown key shape and the engine write would be refused at append). Hard constraint, section 9.
* **D-14 The PR must state that the issue's schema wording was unenforceable** ("patternProperties
  plus additionalProperties: false" is inert or refuses every key in this validator, 0.1), and
  that the equivalent is the code guard of D-2.
* **D-13 `sys_event_type/0` and the event's schema description are unchanged.**

## 2. Interfaces (signatures and types only)

All in `Letflow.Engine.VariableMerge` (`lib/letflow/engine/variable_merge.ex`) unless stated.

```
@type sys_id_key  :: String.t()    # "_sys." <> one [A-Za-z0-9_]+ segment, <= 160 bytes
@type sys_seq_key :: String.t()    # sys_id_key <> ".seq", <= 160 bytes
@type sys_key     :: sys_id_key() | sys_seq_key()
@type sys_value   :: String.t() | non_neg_integer()      # UUID string for an id key; <= int64 for a seq key
@type sys_entry_error :: :invalid_sys_key_shape | :invalid_sys_value_type

@spec sys_key_kind(term()) :: :id | :seq | :unknown
# strict classification of a key; total, never raises; :unknown for every non-shape incl. "_sys", atoms, > 160 bytes.

@spec check_sys_entry(key :: term(), value :: term()) :: :ok | {:error, sys_entry_error()}
# strict pair check: key kind :unknown -> :invalid_sys_key_shape; kind :id needs a canonical lowercase UUID,
# kind :seq needs 0..int64 max, else :invalid_sys_value_type. Pure, total.

@spec check_sys_values(term()) :: :ok | {:error, [{key :: term(), sys_entry_error()}]} | {:error, :not_a_map}
# every pair of a `values` map through check_sys_entry/2; offending pairs sorted by key; also > 40 keys is
# {:error, [{:values, :too_many_keys}]} (D-10). Pure, total. Used ONLY by the registry guard.

@spec put_sys(map(), key :: term(), value :: term()) :: {:ok, map()} | {:error, sys_entry_error()}
# STRICT. The only writer for NEW values (PR B). Returns the map with the key set on :ok; never raises.

@spec put_sys_replayed(map(), key :: term(), value :: term()) :: {:ok, map()} | {:error, sys_entry_error()}
# STORED tier: gated by the unchanged sys_key?/1 and sys_value?/1. Reconstruction's only writer.

# unchanged contracts (re-documented as the stored tier): sys_key?/1, sys_value?/1, reserved_key?/1,
# reserved_keys/1, drop_reserved/1, sys_event_type/0, merge/3.
```

`Letflow.EventStore.Registry` (`registry.ex`): `validate_payload/3`'s spec is unchanged
(`{:error, {:payload_validation_failed, [ValidationFailure.t()]}}` already exists). Behaviour:
after `JsonSchema.validate/2` returns `[]`, if `event_type == VariableMerge.sys_event_type()`
run `check_sys_values/1` on the decoded `"values"` and map each `{key, reason}` per D-9.
Guard is skipped when the schema step already failed (no cascade).

`Letflow.Engine.Reconstruction` (`reconstruction.ex:806-830`): the pre-check stays on
`sys_key?/1` and `sys_value?/1`; the reduce calls `put_sys_replayed/3` and a (now
unreachable) `{:error, _}` maps to the existing `{:error, {:invalid_sys_variables_event, event_id}}`.
No new replay failure for any v1 event that replays today.

DB tables / columns / migrations / seed rows: NONE. `@platform_event_type_seed_attrs`
is unchanged; `schema_version` stays 1; row counts (22 / 19) unchanged.

## 3. Error table

| Condition | Where | Code / shape |
|---|---|---|
| key not one of the two shapes | `check_sys_entry/2`, `put_sys/3` | `{:error, :invalid_sys_key_shape}` |
| id key with a non-UUID, upper-case, unhyphenated or non-binary value | same | `{:error, :invalid_sys_value_type}` |
| seq key with negative, float, string, boolean, nil, map, list or `> int64` | same | `{:error, :invalid_sys_value_type}` |
| new `INSTANCE_SYS_VARIABLES_SET` with a bad pair | `Registry.validate_payload/3` -> `EventStore.append*` | `{:error, {:payload_validation_failed, [%ValidationFailure{constraint: "sys_key_shape" \| "sys_value_type", field_path: "/values/<key>", actual: nil}]}}`, nothing written |
| `values` not an object | schema step (existing) | existing `type` violation |
| `values` with `> 40` keys | guard | `constraint: "sys_values_count"`, `field_path: "/values"` |
| stored v1 event with a wide value | replay | unchanged: accepted if `sys_key?/1` and `sys_value?/1` accept (today's behaviour) |
| malformed stored event (key `"x"`, value `%{}`) | replay | unchanged `{:error, {:invalid_sys_variables_event, event_id}}` |

Never raises on any path (INV-8). No HTTP surface in this PR.

## 4. AC -> design -> test brief

| AC | Design | Test (all must FAIL on `10e6688f`) |
|---|---|---|
| closed schema per key shape; both `put_sys/3` and the event | D-5, D-6, D-2 | `test/letflow/engine/variable_merge_sys_types_test.exs` (async, pure): `check_sys_entry("_sys.r", uuid)` -> `:ok`; `("_sys.r", "not-a-uuid")`, `("_sys.r", String.upcase(uuid))`, `("_sys.r", uuid_without_hyphens)`, `("_sys.r", 7)`, `("_sys.r", %{})` -> `:invalid_sys_value_type`; `("_sys.r.seq", 0)`, `(.., 9_223_372_036_854_775_807)` -> `:ok`; `(.., -1)`, `(.., 7.0)`, `(.., "7")`, `(.., true)`, `(.., 9_223_372_036_854_775_808)` -> `:invalid_sys_value_type`; unknown shapes `"_sys"`, `"_sys."`, `"_sys.a.b"`, `"_sys.a.seq.seq"`, `"_sys.a-b"`, `:"_sys.a"`, 161-byte key, `"x"` -> `:invalid_sys_key_shape`; `"_sys.seq"` is an id key, `"_sys.seq.seq"` a seq key; `put_sys/3` returns `{:ok, map}` on a valid pair and `{:error, _}` (no raise) on each bad one, input map untouched. |
| event schema refuses extra/ill-typed keys | D-2, D-9, D-10 | `test/letflow/event_store/registry_sys_values_guard_test.exs` (DB, mirrors `registry_entity_writes_test.exs`): with a freshly provisioned tenant, `Registry.validate_payload/3` -> `:ok` for `%{"_sys.r" => uuid, "_sys.r.seq" => 7}`; `{:error, {:payload_validation_failed, [f]}}` with `f.constraint == "sys_key_shape"` for key `"extra"` and for `"_sys.a.b"`; `"sys_value_type"` for a non-UUID id, a negative seq; `f.actual == nil` for every failure; 41 keys -> `"sys_values_count"`; the same through `EventStore.append/2`, `append_platform_event/2` and `append_multi/3`: `{:error, {:payload_validation_failed, _}}` and zero `events` rows and zero `event_idempotency` rows. |
| errors, not raises | D-7 | in both files above: `assert_raise` is NOT used; each bad input is matched as a tuple; a StreamData property over arbitrary terms for key and value: `check_sys_entry/2` and `put_sys/3` never raise and return `:ok`/`{:ok, _}` iff the key is in the two shapes and the value matches its type. |
| replay of stored v1 events unchanged | D-4, D-8 | extend `test/letflow/engine/reconstruction_sys_test.exs` with a NEW raw-insert helper `insert_raw_event!(schema, instance_id, type, payload)` that inserts the `events` row directly with `Repo.insert_all(..., prefix: schema)` (a plain column write by an EXPLICIT column list: `event_id` and `created_at` (the composite
primary key), `instance_id`, `event_type`, `payload`, `actor_id`, `sequence_number` (the next
value for the instance), `idempotency_key`, `metadata`; `global_seq` is `read_after_writes`
and database-assigned; it does NOT touch `event_idempotency` or the projection; anchor:
`lib/letflow/event_store/event.ex` schema), so `EventStore.append/2`, therefore `Registry.validate_payload/3` and the new guard, are NOT traversed. The file's existing `append!/4` (`:81-95`) calls `EventStore.append/2` and cannot be used for these cases once the guard exists. Cases: a raw-inserted 41-key v1 event replays unchanged (pins "replay unaffected" by the cap);
exactly 40 keys (20 id/seq pairs) is accepted and 41 is refused with only the count failure.
Case: a stored pre-change event `%{"_sys.line_0.id" => "any string", "_sys.r.seq" => 3}` inserted raw; rebuild; `state.variables` equals the golden map the pre-change code produced (committed in the test). |
| the PR states which | D-1 | PR body: "compatible tightening, no schema_version bump; the v1 seed is unchanged". |
| static allow-list covers the new writer | D-11 | `put_sys_callers_test.exs`: R1 over `put_sys` and `put_sys_replayed`; synthetic negatives under `lib/letflow/fake.ex` for the new name; real tree set equality unchanged `[variable_merge.ex, reconstruction.ex]`. |
| existing suites (F1) | all | `reconstruction_sys_test.exs`: the four malformed-event cases at `:170-185` (`"x"`, `"_sys"`, `%{"_sys.r" => %{}}`, `%{"_sys.r.seq" => -1}`) and the wide-value case above MOVE from `sys_event!/3` (which goes through `append!/4` and so the guard; they would be refused at append and never reach replay) to the raw-insert helper; their assertions stay exactly `{:error, {:replay_failed, {:invalid_sys_variables_event, ^event_id}}}`. The valid-event cases (`:133` area, uuid + seq 7) keep `append!/4` and now also exercise the guard's accept path. `variable_merge_sys_test.exs` cases that assert `put_sys/3` returns a map or raises (`:151` area, the `FunctionClauseError` cases) are rewritten to the tuple contract; `sys_key?/sys_value?` cases (`:117-129`) stay as they are (stored tier); `tenant_provisioning_event_seed_test.exs` counts stay 22 and 19 (assert, do not edit); `platform_test.exs:2011` (Lua refusal) unchanged. |

## 5. Invariants, security, scope fence

* **INV-8** no raise on any path (D-7). **INV-2 / INV-4** a refused value is never echoed
  (`actual: nil`). **INV-1** no query added; the guard is pure and reads only the payload.
* **0054 D1a.3** `put_sys/3` and `put_sys_replayed/3` stay the only reserved-key writers,
  allow-listed; their callers must never receive request, form, HTTP, start, message or
  script data (unchanged).
* **I-1 (replay)** any v1 event that folds today folds to the same state afterwards.
* **I-2 (one registry)** no second event-type version and no seed change: existing and fresh
  tenants behave identically the moment the binary ships.
* **Purity build constraint (F3).** `variable_merge.ex` stays pure: the new functions
  (`sys_key_kind/1`, `check_sys_entry/2`, `check_sys_values/1`, `put_sys/3`,
  `put_sys_replayed/3`) call no `Registry.validate_payload/3`, `Registry.get_type/2`,
  `Registry.register_type/2`, `Repo`, `Logger`, clock, `File` or `:crypto`. The dependency
  direction is `Registry -> VariableMerge`, never the reverse. The moduledoc's awk-then-grep
  recipe (the "Purity" section of `variable_merge.ex`, which strips `"""` doc blocks) must
  still return zero matches; mentions in doc strings are stripped by it and are allowed.
* Scope fence: no `Expr` change, no `merge/3` change, no `JsonSchema` change, no migration,
  no router change, no new permission. `ServiceTask`, catalog and A1b untouched.

## 6. Files touched

`lib/letflow/engine/variable_merge.ex` (types, 4 new functions, `put_sys/3` contract, moduledoc),
`lib/letflow/engine/reconstruction.ex` (one call site + moduledoc line),
`lib/letflow/event_store/registry.ex` (guard step in `validate_payload/3`, moduledoc),
tests: `test/letflow/engine/variable_merge_sys_types_test.exs` (new),
`test/letflow/event_store/registry_sys_values_guard_test.exs` (new),
`test/letflow/engine/reconstruction_sys_test.exs`, `test/letflow/engine/variable_merge_sys_test.exs`,
`test/letflow/engine/put_sys_callers_test.exs` (edited), and one pointer line in `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md` section 15 (c).
`docs/anti-patterns.md`: one line if a reviewer finds a recurrence of "edited v1 seed never
reaches existing tenants" (not currently an entry for the seed-loop skip; confirm before adding).
Does NOT touch: `tenant_provisioning.ex`, any migration, `json_schema.ex`.

## 7. Open questions: all CLOSED by supervisor rulings (revision 1)

* **OQ-1 Layering. CLOSED: accepted.** `Registry` calls `VariableMerge`. Corrected premise (CDV
  F2): `VariableMerge` depends on `Registry.JsonSchema` and `Registry.ValidationFailure`, not on
  `Registry` itself, so `Registry -> VariableMerge` creates no module cycle. CDV confirmed
  `check_boundaries` has one layer rule only (engine -> entities), so the edge is permitted; it
  is the first code-level event_store -> engine edge, and ELIXIR-DEV must run
  `mix letflow.check_boundaries` and quote the result in the PR.
* **OQ-2 40-key cap. CLOSED: YES, kept** (supervisor ruling beyond the issue AC; D-10).
* **OQ-3 Bump vs tighten. CLOSED: no bump, code guard** at `Registry.validate_payload/3`
  (D-1..D-3); the PR states the issue's schema wording was unenforceable (D-14).
* **OQ-4 `put_sys/3` return change. CLOSED: accepted**; replay uses `put_sys_replayed/3` with
  the old wide predicates, proved by a replay test of a stored pre-change event (section 4).
* **OQ-5 Dotted `output_record_id_var`. CLOSED: PR B must refuse it** (section 9).

## 9. Hard PR B constraints (also recorded in the parent design's section 15)

1. PR B's activation validation MUST refuse an `output_record_id_var` that is not exactly
   `_sys.<one segment of [A-Za-z0-9_]+>` (no dot; the key and its derived `<name>.seq` key each
   `<= 160` bytes). Otherwise the engine's own write would be refused at append.
2. PR B writes `_sys` values ONLY through strict `put_sys/3`, and appends the event only through
   a path that traverses `Registry.validate_payload/3` (never a raw insert).
3. This PR adds one pointer line to
   `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md` section 15, carry-over (c).

## 8. Merge-order note

Independent of GH #2623 (disjoint files: this PR touches variable_merge.ex, reconstruction.ex,
registry.ex; #2623 touches service_task.ex, reserved_references.ex, entry.ex, service_catalog
and admin routes). One functional PR in CI at a time (core-directives merge discipline): either
order. Both must merge BEFORE #2587 PR B. This PR rebases onto whichever lands first; no
shared test file is edited by both.
