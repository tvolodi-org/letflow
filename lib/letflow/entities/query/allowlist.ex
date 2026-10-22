defmodule Letflow.Entities.Query.Allowlist do
  @moduledoc """
  `allowlist.zig`-equivalent (REQ-230 §3) -- builds a per-tenant,
  per-entity-type field allowlist from REQ-225's entity definition, and
  resolves a caller-supplied field name against it. See
  `lib/letflow/design/req230-entity-query-dsl-compiler.md` §3 for the full
  design this module implements.

  This is layer 2 of the three-layer SQL-injection defence: a field name
  absent from the loaded allowlist is rejected by `resolve_field/2` before
  it ever reaches `Letflow.Entities.Query.Compiler` (AC2).

  ## Shadowing precedence rule (AC3, design §3.4)

  **A field name backed by a real typed column on `entity_record_latest`
  always takes precedence over the same name found only as a JSONB key
  inside `field_values`.** A caller writing `field: "deleted"` always
  resolves to the typed `entity_record_latest.deleted` boolean column,
  never to a same-named key an entity definition happens to declare inside
  its `field_values` JSON, even if that entity type's definition includes a
  `queried: true` field literally named `"deleted"`. This is because the
  typed columns are structural to every entity record regardless of entity
  type, are indexed/typed at the Postgres level, and a comparison against
  them is cheaper and more precise than a JSONB text-cast comparison
  against a same-named key would be -- there is no scenario where
  resolving to the JSONB key instead would be more correct, only ambiguous
  (design §3.4).
  """

  alias Letflow.Entities.Definition
  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Record.Decimals
  alias Letflow.TenantProvisioning

  @typedoc "Where an allowlisted field's data actually lives (design §3.2)."
  @type field_source :: :typed_column | :json_field

  @typedoc "One resolved, allowlisted field (design §3.2)."
  @type allowlisted_field :: %{
          required(:name) => String.t(),
          required(:source) => field_source(),
          required(:type) => Definition.field_type(),
          required(:enum_values) => [String.t()] | nil,
          # GH #2654: a strict decimal field carries its scale; nil/false for any other field.
          optional(:decimal_scale) => non_neg_integer() | nil,
          optional(:decimal_strict) => boolean()
        }

  @typedoc """
  The full per-entity-type allowlist (design §3.2) -- keyed by the field
  name a caller writes in a `filter_clause()`/`sort_clause()`, already
  shadow-resolved: a name can never map to two entries.
  """
  @type allowlist :: %{String.t() => allowlisted_field()}

  @typedoc "`resolve_field/2`'s field-not-allowed error (design §3.5, AC2)."
  @type field_not_allowed_error :: {:error, {:field_not_allowed, String.t()}}

  @typedoc """
  Enough of `Definition.field_def()` for `DDL.promoted_columns/1` and this
  module's own type lookup (design §1.4). Private -- feeds
  `DDL.promoted_columns/1` only, never returned to any caller.
  """
  @type decoded_field_def :: %{
          name: String.t(),
          type: Definition.field_type(),
          queried: boolean(),
          enum_values: [String.t()] | nil,
          locales: [String.t()] | nil,
          search_strategy: :plain | :fulltext | nil
        }

  @typedoc """
  Enough of `Definition.fk_def()` for `DDL.promoted_columns/1`'s
  `fk_field_names` computation (design §1.4). Private.
  """
  @type decoded_fk_def :: %{field: String.t()}

  @typedoc "The `DDL.promoted_columns/1`-compatible decoded shape (design §1.4)."
  @type definition_document :: %{
          required(:fields) => [decoded_field_def()],
          required(:foreign_keys) => [decoded_fk_def()]
        }

  @doc """
  The fixed typed-column table (design §3.3 step 4's first pass, §3.4) --
  every entry present on **every** entity type's allowlist, since these
  columns exist on `entity_record_latest` regardless of entity type.
  Exposed for `Letflow.Entities.Query.Compiler.build_filter_dynamic/2`'s
  typed-column dispatch (design §5.3).
  """
  @spec typed_columns() :: %{String.t() => {atom(), Definition.field_type()}}
  def typed_columns do
    %{
      "entity_type" => {:entity_type, :string},
      "record_id" => {:record_id, :string},
      "deleted" => {:deleted, :boolean},
      "entity_def_version" => {:entity_def_version, :string},
      "last_event_global_seq" => {:last_event_global_seq, :integer},
      "inserted_at" => {:inserted_at, :datetime},
      "updated_at" => {:updated_at, :datetime}
    }
  end

  @doc """
  The per-entity-type typed-column table (design §1.2, AC1): the union of
  `typed_columns/0`'s fixed 7 structural columns and every attribute
  `Letflow.Entities.Definition.DDL.promoted_columns/1` reports as promoted
  for `entity_type`'s current active definition in the tenant schema named
  by `prefix`. Name -> `Definition.field_type()` only, deliberately with no
  column atom (design §5.3) -- nothing in this module's scope fabricates a
  column reference for a promoted attribute; that remains
  `typed_columns/0`'s exclusive, unchanged responsibility. **Additive and
  currently uncalled by `load/2`** (design §1.5, REWORK ITERATION 1) --
  wiring this into `load/2`'s output is REQ-300's job, not this
  requirement's.

  ## `:localized_text` locale columns (REQ-301)

  A `:localized_text` field's promoted locale columns (e.g. `"stem_kk"`,
  `"stem_ru"` for a field named `"stem"`) appear in this result under their
  own composed names, typed `:string` always -- never `:localized_text` and
  never a `tsvector`-flavored variant, since both the plain-text and
  `tsvector` column shapes hold textual content this layer treats as
  string-like (the ranked/`@@`-operator query semantics `:fulltext` needs
  are a `Compiler`-layer concern REQ-300 owns). The original field name
  (`"stem"`) never appears in this result at all -- only its locale
  derivatives are ever promoted columns
  (`Letflow.Entities.Definition.DDL.promoted_columns/1`'s own output for a
  `:localized_text` field never includes an entry named after the field
  itself).

    1. Validate `prefix` resolves to a provisioned tenant schema --
       `{:error, :invalid_schema_name}` before any query.
    2. `Letflow.Entities.Definitions.get_active_definition_by_name/2` --
       `{:error, :not_found}` remapped to `{:error, :entity_type_not_found}`.
    3. Decode into `DDL.promoted_columns/1`'s expected shape
       (`definition_document/1`) and compute the union
       (`entity_type_typed_columns/1`).
  """
  @spec typed_columns(entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, %{String.t() => Definition.field_type()}}
          | {:error, :invalid_schema_name}
          | {:error, :entity_type_not_found}
  def typed_columns(entity_type, prefix) when is_binary(entity_type) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, entity_definition} <- fetch_active_definition(entity_type, prefix) do
      {:ok, entity_type_typed_columns(definition_document(entity_definition))}
    end
  end

  @doc """
  Builds the field allowlist for one entity type, scoped to the tenant
  schema named by `prefix` (design §3.3). Step order:

    1. Validate `prefix` resolves to a provisioned tenant schema --
       `{:error, :invalid_schema_name}` before any query.
    2. `Letflow.Entities.Definitions.get_active_definition_by_name/2` --
       `{:error, :not_found}` from that call is remapped to
       `{:error, :entity_type_not_found}` here, this module's own error
       atom.
    3. Decode `definition_json` into a `Letflow.Entities.Definition.t()`
       (already-validated JSON by construction -- no re-validation here).
    4. Build the typed-column entries first (§3.4's fixed table, **plus**
       REQ-300's per-entity-type promoted set -- see the note below), then
       the JSON-field entries: only fields with `queried: true` are ever
       allowlisted from the JSONB side. `:json`-typed fields are
       structurally excluded without a special case, since
       `Definition.Validator`'s Rule 3 already forbids `queried: true` on a
       `:json` field at definition-creation time. `:localized_text`-typed
       fields (REQ-301) ARE excluded by an explicit second filter condition
       here -- unlike `:json`, a `:localized_text` field CAN be `queried:
       true` (REQ-301 AC3), but its value is a JSON object keyed by locale,
       not a scalar `Letflow.Entities.Query.Compiler.json_cast_dynamic/2`
       has any clause for; allowlisting it under its own bare name would
       crash that function's `:json_field` dispatch with
       `FunctionClauseError` the moment such a field is resolved. Only its
       derived per-locale generated columns are ever exposed, and only via
       `typed_columns/2` (§5) -- neither this function nor `Compiler`/
       `Cursor` resolve them yet (REQ-300's job).
    5. Merge: a JSON-field entry whose name collides with a typed-column
       entry is discarded -- the typed-column entry wins (AC3, the
       shadowing-precedence rule stated in this module's own moduledoc
       above).

  ## REQ-300 AC8 -- promoted columns resolve `source: :typed_column`, gated
  ## on the SPECIFIC column actually existing (rework cycle 3: per-column,
  ## not just per-table)

  `typed_columns/2`'s promoted set is purely definition-derived (decoded
  straight off the active `Definition.t()` document, same as
  `fk_defs/2` -- see that function's own moduledoc note): it reports a
  field as promoted the moment a definition declares it `queried: true` or
  as an `fk_def().field`, **regardless of whether any `ColumnPromotion` has
  ever actually run** for that attribute (0023's promotion rule marks
  *eligibility*; `Letflow.TenantProvisioning.run_column_promotion/1` is the
  separate, explicit step that lands the physical column). Naively
  repointing `load/2` at `typed_columns/2`'s full result unconditionally
  would therefore mark a merely-*eligible*, never-promoted field (e.g. this
  test suite's own "customer" fixture, whose `queried: true` fields have
  never been through a real `ColumnPromotion`) `source: :typed_column` too
  -- and `Letflow.Entities.Query.Compiler.build_filter_dynamic/2`'s
  `:typed_column` clause would then try to resolve it as a real physical
  column on a table that was never created, corrupting every ordinary,
  never-promoted-entity-type query this module's own AC3 tests (and
  `Letflow.Entities.QueryTest`'s whole "customer" fixture) already rely on.

  Checking only whether `entity_type`'s per-entity-type table **exists**
  (rework cycle 2's fix) is table-granularity and is not enough on its
  own: 0023's additive-declare-then-promote rule allows a definition to
  declare a *second* `queried: true` field (or `fk_def`) after the table
  already exists from an earlier, unrelated field's promotion, with no
  `ColumnPromotion` ever registered/run for that second attribute. Gating
  on table existence alone would then classify that never-promoted field
  `source: :typed_column` too, and
  `Letflow.Entities.Query.Compiler.build_filter_dynamic/3`/`build_order_by/3`
  would build a `fragment("?", literal(^field_name))` reference to a
  column that does not physically exist, surfacing as an unhandled
  `Postgrex.Error` (`undefined_column`) straight out of `Repo.all/2` for an
  ordinary, non-join filter/sort request -- SECURITY-REVIEWER's reproduced
  regression this rework cycle fixes, the exact table-vs-column gap
  `Letflow.Entities.Query.Compiler.relation_column_exists?/3` already
  closed for the join path's declaring side (design §4.0.2), now closed
  here too so every consumer of this function's output (filter, sort, and
  any future one) gets the fix in one place.

  So `load/2` includes a **non-structural** promoted name (anything
  `typed_columns/2` reports beyond the fixed 7) as `source: :typed_column`
  only when BOTH `entity_type`'s per-entity-type table **and that specific
  column** physically exist right now
  (`TenantProvisioning.entity_table_exists?/2` then, per surviving
  candidate name, `TenantProvisioning.entity_column_exists?/3` -- the same
  shared primitive `Letflow.Entities.Query.Compiler.relation_column_exists?/3`
  delegates to for the join path, so there is exactly one
  `information_schema.columns` query implementation, not two) --
  otherwise that name is left to resolve via the ordinary `:json_field`
  path below, exactly as it did before this requirement and exactly as it
  did before any column on this entity type was ever promoted. This keeps
  every existing, never-promoted-entity-type request byte-for-byte
  unchanged (REQ-300's own hard non-regression requirement), keeps a
  declared-but-not-yet-promoted field on an *already-promoted* entity type
  working via the always-safe JSONB path silently and correctly (no new
  error needed for what used to just work), and still gives a
  genuinely-promoted attribute (this requirement's own AC8 scenario, and a
  join's declaring side) the real `:typed_column` resolution
  `Letflow.Entities.Query.Compiler`'s two-path column-reference split
  (design §3.4) needs.
  """
  @spec load(entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, allowlist()}
          | {:error, :invalid_schema_name}
          | {:error, :entity_type_not_found}
  def load(entity_type, prefix) when is_binary(entity_type) and is_binary(prefix) do
    with {:ok, allowlist, _strict_specs} <- load(entity_type, prefix, :with_specs),
         do: {:ok, allowlist}
  end

  @doc """
  `load/2` plus the strict decimal specs (`Decimals.specs()`) of the SAME active definition row,
  as `{:ok, allowlist, strict_specs}` (GH #2773). A read response renders a strict field that is
  not `queried` too, so the specs come from the definition, not from the allowlist entries; this
  hands them to the router without a second definition read. Same errors as `load/2`.
  """
  @spec load(entity_type :: String.t(), prefix :: String.t(), :with_specs) ::
          {:ok, allowlist(), Decimals.specs()}
          | {:error, :invalid_schema_name}
          | {:error, :entity_type_not_found}
  def load(entity_type, prefix, :with_specs) when is_binary(entity_type) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, entity_definition} <- fetch_active_definition(entity_type, prefix) do
      structural_names = MapSet.new(Map.keys(typed_columns()))
      decimal_info = decimal_info(entity_definition.definition_json)

      promoted_typed_column_names =
        case entity_table_name_if_exists(entity_type, prefix) do
          {:ok, table_name} ->
            entity_definition
            |> definition_document()
            |> entity_type_typed_columns()
            |> Map.drop(MapSet.to_list(structural_names))
            |> Enum.filter(fn {name, _type} ->
              TenantProvisioning.entity_column_exists?(prefix, table_name, name)
            end)
            |> Map.new()

          :error ->
            %{}
        end

      typed_column_entries =
        Map.new(typed_columns(), fn {name, {_atom, type}} ->
          {name,
           %{
             name: name,
             source: :typed_column,
             type: type,
             enum_values: nil,
             decimal_scale: nil,
             decimal_strict: false
           }}
        end)

      promoted_typed_column_entries =
        Map.new(promoted_typed_column_names, fn {name, type} ->
          {name,
           Map.merge(
             %{name: name, source: :typed_column, type: type, enum_values: nil},
             decimal_keys(decimal_info, name)
           )}
        end)

      json_field_entries =
        entity_definition.definition_json
        |> Map.get("fields", [])
        |> Enum.map(&field_document/1)
        |> Enum.filter(&(&1.queried == true and &1.type != :localized_text))
        |> Map.new(fn field ->
          {field.name,
           Map.merge(
             %{
               name: field.name,
               source: :json_field,
               type: field.type,
               enum_values: field.enum_values
             },
             decimal_keys(decimal_info, field.name)
           )}
        end)

      # AC3: typed-column entries win on name collision -- merge with the
      # typed-column maps as the *second*/*third* arguments so their values
      # overwrite any same-named json_field entry. promoted_typed_column_entries
      # is merged last so a promoted name always resolves :typed_column once
      # its table exists, even if (impossibly, per 0023's own rule -- see
      # this function's moduledoc note) it collided with a json_field name.
      allowlist =
        json_field_entries
        |> Map.merge(typed_column_entries)
        |> Map.merge(promoted_typed_column_entries)

      {:ok, allowlist, Decimals.specs_from_definition_json(entity_definition.definition_json)}
    end
  end

  @doc """
  The per-entity-type set of `fk_def()`s declared by `entity_type`'s active
  definition (REQ-300 design §2) -- the full shape (`name`, `field`,
  `references_entity`, `references_field`), not `typed_columns/2`'s
  internal `field`-only `decoded_fk_def()`. Mirrors `typed_columns/2`'s own
  three-step shape and reuses the same active-definition fetch
  (`fetch_active_definition/2`) -- no second lookup path.

  Returns `[]` (not an error) for an entity type with no `foreign_keys` --
  same "absence is the common case, not an error" convention
  `Letflow.Entities.Query.FieldGrants.load_restrictions/3` already uses for
  zero restricted fields.

  Purely definition-JSON-derived, like `typed_columns/2` -- does **not**
  consult `ColumnPromotion`/`entity_table_exists?/2` at all. It is
  `Letflow.Entities.Query.Compiler`'s own job (via
  `Compiler.resolve_binding_source/2` and `Compiler.relation_column_exists?/3`)
  to check whether a relation this function reports is actually usable
  against real Postgres state before building a join on it.
  """
  @spec fk_defs(entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, [Definition.fk_def()]}
          | {:error, :invalid_schema_name}
          | {:error, :entity_type_not_found}
  def fk_defs(entity_type, prefix) when is_binary(entity_type) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, entity_definition} <- fetch_active_definition(entity_type, prefix) do
      fk_defs =
        entity_definition.definition_json
        |> Map.get("foreign_keys", [])
        |> Enum.map(&full_fk_def_document/1)

      {:ok, fk_defs}
    end
  end

  # `{:ok, table_name}` when entity_type's per-entity-type table physically
  # exists (so its name is available for the per-column check above too);
  # `:error` otherwise -- an invalid entity type name and "no table yet"
  # both collapse to the same "nothing is promoted" outcome load/2 already
  # treated identically before this rework cycle.
  defp entity_table_name_if_exists(entity_type, prefix) do
    case TenantProvisioning.table_name_for_entity_type(entity_type) do
      {:ok, table_name} ->
        if TenantProvisioning.entity_table_exists?(prefix, table_name) do
          {:ok, table_name}
        else
          :error
        end

      {:error, :invalid_entity_type} ->
        :error
    end
  end

  # Full fk_def() decode (name/field/references_entity/references_field) --
  # a second, separate private decoder from definition_document/1's own
  # internal decoded_fk_def() (field-only), which entity_type_typed_columns/1
  # still exclusively consumes, unchanged.
  defp full_fk_def_document(fk) do
    %{
      name: Map.fetch!(fk, "name"),
      field: Map.fetch!(fk, "field"),
      references_entity: Map.fetch!(fk, "references_entity"),
      references_field: Map.get(fk, "references_field")
    }
  end

  @doc """
  Resolves one caller-supplied field name against an already-loaded
  `allowlist()` (design §3.5). A single `Map.fetch/2`, remapped to
  `{:error, {:field_not_allowed, field_name}}` on miss -- AC2's rejection
  point, called once per `filter_clause()`/`sort_clause()` field by
  `Letflow.Entities.Query.Compiler`.
  """
  @spec resolve_field(allowlist(), field_name :: String.t()) ::
          {:ok, allowlisted_field()} | field_not_allowed_error()
  def resolve_field(allowlist, field_name) when is_map(allowlist) and is_binary(field_name) do
    case Map.fetch(allowlist, field_name) do
      {:ok, field} -> {:ok, field}
      :error -> {:error, {:field_not_allowed, field_name}}
    end
  end

  defp fetch_active_definition(entity_type, prefix) do
    case Definitions.get_active_definition_by_name(entity_type, prefix) do
      {:ok, entity_definition} -> {:ok, entity_definition}
      {:error, :not_found} -> {:error, :entity_type_not_found}
      {:error, :invalid_schema_name} = error -> error
    end
  end

  # `definition_json` is always string-keyed once round-tripped through the
  # `entity_definitions.definition_json` JSONB column -- same conversion
  # `Letflow.Entities.Records`'s own private `definition_document/1`/
  # `field_document/1` already performs (see that module's moduledoc for why
  # `String.to_existing_atom/1` on `"type"`'s value is safe: the full closed
  # set of `Letflow.Entities.Definition.field_type()` atoms is already
  # compiled into this codebase). `"queried"` defaults to `false` when
  # absent, matching `Letflow.Entities.Definition.field_def()`'s own
  # `optional(:queried)`.
  defp field_document(field) do
    %{
      name: Map.fetch!(field, "name"),
      type: String.to_existing_atom(Map.fetch!(field, "type")),
      queried: Map.get(field, "queried", false),
      enum_values: Map.get(field, "enum_values"),
      locales: Map.get(field, "locales"),
      search_strategy: field |> Map.get("search_strategy") |> search_strategy_atom()
    }
  end

  # GH #2654: the strict decimal fields of the active definition, name -> scale. Only a
  # field with `decimal_strict: true` (and a valid precision/scale) appears.
  defp decimal_info(definition_json) do
    definition_json
    |> Decimals.specs_from_definition_json()
    |> Map.new(fn {name, %{scale: scale}} -> {name, scale} end)
  end

  defp decimal_keys(decimal_info, name) do
    case Map.fetch(decimal_info, name) do
      {:ok, scale} -> %{decimal_scale: scale, decimal_strict: true}
      :error -> %{decimal_scale: nil, decimal_strict: false}
    end
  end

  # REQ-301: same decode `Letflow.TenantProvisioning.field_from_persisted/1`
  # applies -- both atoms are already compiled into this codebase (Validator
  # Rule 11, DDL's own dispatch), so `String.to_existing_atom/1` is safe.
  defp search_strategy_atom(nil), do: nil
  defp search_strategy_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  # Decodes `entity_definition.definition_json` into the shape
  # `DDL.promoted_columns/1` expects (design §1.4) -- `field_document/1`'s
  # per-field decode, reused, plus `"foreign_keys"` -> `decoded_fk_def()`,
  # which neither `field_document/1` nor `Records.definition_document/1`
  # decode today. Defaults to `[]` when `"foreign_keys"` is absent (an
  # entity type with no relationships). Feeds `typed_columns/2` only --
  # `load/2` does not call this (design §1.5, REWORK ITERATION 1).
  @spec definition_document(entity_definition :: struct()) :: definition_document()
  defp definition_document(entity_definition) do
    fields =
      entity_definition.definition_json
      |> Map.get("fields", [])
      |> Enum.map(&field_document/1)

    foreign_keys =
      entity_definition.definition_json
      |> Map.get("foreign_keys", [])
      |> Enum.map(fn fk -> %{field: Map.fetch!(fk, "field")} end)

    %{fields: fields, foreign_keys: foreign_keys}
  end

  # Structural 7 (from `typed_columns/0`, type half only) union the promoted
  # set `DDL.promoted_columns/1` reports for `document` (design §1.3, INV-B).
  # Structural entries win on any name collision -- consistent with, not a
  # change to, the existing shadowing-precedence rule. Feeds `typed_columns/2`
  # only -- `load/2` does not call this (design §1.5, REWORK ITERATION 1).
  @spec entity_type_typed_columns(definition_document()) :: %{
          String.t() => Definition.field_type()
        }
  defp entity_type_typed_columns(document) do
    structural = Map.new(typed_columns(), fn {name, {_atom, type}} -> {name, type} end)

    fields_by_name = Map.new(document.fields, &{&1.name, &1})

    promoted =
      document
      |> DDL.promoted_columns()
      |> Map.new(fn column ->
        # REQ-301: a locale-derived generated column's own name
        # ("stem_kk") never matches a `fields_by_name` key -- its
        # originating field's name ("stem") is carried separately in
        # `:source_field`. `nil` for every ordinary promoted column
        # (its own name already equals its originating field's name), so
        # this falls back to `column.name`, identical to before REQ-301.
        field = Map.fetch!(fields_by_name, Map.get(column, :source_field) || column.name)
        type = if Map.get(column, :source_field), do: :string, else: field.type
        {column.name, type}
      end)

    Map.merge(promoted, structural)
  end
end
