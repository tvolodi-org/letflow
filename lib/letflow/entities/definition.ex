defmodule Letflow.Entities.Definition do
  @moduledoc """
  The `entity_definition()` document shape and its nested
  `field_def()`/`index_def()`/`fk_def()`/`constraint_def()` shapes (REQ-225).
  See `lib/letflow/design/req225-entity-definition-schema-validation.md` §2
  for the full design this module implements.

  This is a **document shape**, not an `Ecto.Schema` -- REQ-226 owns the
  persisted `entity_definitions` table; this module only describes the
  shape of the JSON blob that becomes that table's `definition_json`
  column. No persistence, no CRUD, no migration lives here (REQ-226's job).

  ## Entity-type ownership model: tenant-scoped (design §1)

  An `entity_definition()` belongs to exactly one tenant. This module itself
  takes no `tenant_id` and performs no cross-definition/cross-tenant
  lookups -- tenant scoping is enforced by REQ-226's context module, the
  same division of responsibility `Letflow.Repository.Canonicaliser` already
  has relative to `Letflow.Repository`.

  ## `append_only` (GH #2529)

  Optional top-level boolean, never defaulted or inserted by any layer
  (absent means mutable, and keeps the stored JSON and its hashes unchanged).
  When the entity type's **current** active definition carries `true`,
  `Letflow.Entities.Records.update_record/2` and `delete_record/2` refuse with
  `{:error, {:entity_append_only, entity_type}}` right after resolving the
  definition and before any record lookup; creating records is unaffected.
  A present non-boolean value (including `nil`) is `:malformed` at
  `[:append_only]`. The key is part of the logical shape, so adopting it is a
  new version to activate. It is a reversible tenant policy: activating a
  version without it lifts it, and it applies to commands that start after
  the activation. Ledgers that must be tamper-proof use `managed_by`
  (decision 0050 D7).

  ## `writable_by_process` (GH #2587, decision 0054 D4a.2)

  Optional top-level boolean, never defaulted or inserted by any layer.
  Absent (or `false`) means a process step may NOT write records of this type;
  `true` declares that it may. A present non-boolean value is `:malformed` at
  `[:writable_by_process]`. The key is part of the logical shape, so adopting
  it is a new version to activate, exactly like `append_only`.

  Only a principal holding `:EntitiesDefinitionsWrite` can set it (through
  `POST /entities/definitions` and `POST /entities/definitions/:name/activate`).
  `Letflow.Entities.Definitions.create_definition/3` refuses `true` on a
  module-managed type and on a type whose name matches the interim denied list
  (`Letflow.Entities.ProcessWritable`; the list is documented in
  `docs/guides/adding-an-application-module.md`), and a solution pack never
  carries it. The process-step write path (PR B) re-reads the flag from the
  CURRENT active definition at run time; nothing caches it.

  ## Numeric ranges (GH #2532)

  `:integer` and `:decimal` fields take three optional keys, never defaulted
  or inserted by any layer (absent means unbounded, and keeps the stored JSON,
  the record subschema and the shape hashes unchanged): `min` and `max`
  (inclusive bounds; an integer on `:integer`, any number on `:decimal`) and
  `non_negative` (boolean; `true` means an effective minimum of
  `max(min, 0)`). `non_negative: true` is stored as written, never rewritten
  to `min: 0`, so the two hash differently and are distinct logical shapes.
  `Letflow.Entities.Definition.Validator` Rule 12 (`:invalid_range`) rejects
  the keys on any other type, a non-number/non-integer bound, `min > max`,
  a negative bound alongside `non_negative: true`, and a non-boolean
  `non_negative`. `Letflow.Entities.Record.Validator` turns them into JSON
  Schema `"minimum"`/`"maximum"`, enforced on every record create and update.

  A JSON `null` bound is treated as **absent** when a definition is submitted
  over HTTP (the router drops `nil` field keys), but is **rejected** with
  `:invalid_range` when it arrives in a solution pack (the pack installer
  carries `null` through as `nil`, which Rule 12 sees as a present,
  non-number bound).
  """

  @typedoc "Top-level entity definition document. See moduledoc for the tenant-scoping decision."
  @type t :: %{
          required(:name) => String.t(),
          required(:display_name) => String.t(),
          optional(:description) => String.t(),
          required(:fields) => [field_def()],
          optional(:indexes) => [index_def()],
          optional(:foreign_keys) => [fk_def()],
          optional(:constraints) => [constraint_def()],
          optional(:append_only) => boolean(),
          optional(:writable_by_process) => boolean()
        }

  @typedoc "One field in an entity definition's `fields` list."
  @type field_def :: %{
          required(:name) => String.t(),
          required(:type) => field_type(),
          optional(:required) => boolean(),
          optional(:queried) => boolean(),
          optional(:enum_values) => [String.t()],
          optional(:decimal_precision) => pos_integer(),
          optional(:decimal_scale) => non_neg_integer(),
          optional(:default) => term(),
          optional(:locales) => [String.t(), ...],
          optional(:search_strategy) => :plain | :fulltext,
          optional(:min) => number(),
          optional(:max) => number(),
          optional(:non_negative) => boolean()
        }

  @typedoc """
  The closed set of field types this slice supports. `:json` is the one type
  that Rule 3 (`Letflow.Entities.Definition.Validator`) treats specially: a
  `:json` field may never also be `queried: true`. `:localized_text`
  (REQ-301) is the other type Rule 3's carve-out matters for: unlike `:json`,
  a `:localized_text` field CAN be `queried: true` -- see
  `Letflow.Entities.Definition.Validator`'s moduledoc and Rule 3's own
  comment for why this is achieved by `:localized_text` being a distinct
  atom, not by weakening Rule 3 itself.
  """
  @type field_type ::
          :string
          | :integer
          | :decimal
          | :boolean
          | :date
          | :datetime
          | :enum
          | :json
          | :localized_text

  @typedoc "One entry in an entity definition's `indexes` list."
  @type index_def :: %{
          required(:name) => String.t(),
          required(:fields) => [String.t(), ...],
          optional(:unique) => boolean()
        }

  @typedoc "One entry in an entity definition's `foreign_keys` list."
  @type fk_def :: %{
          required(:name) => String.t(),
          required(:field) => String.t(),
          required(:references_entity) => String.t(),
          optional(:references_field) => String.t()
        }

  @typedoc "One entry in an entity definition's `constraints` list."
  @type constraint_def :: %{
          required(:name) => String.t(),
          required(:type) => :unique,
          required(:fields) => [String.t(), ...]
        }
end
