defmodule Letflow.Entities.Definition.DDL do
  @moduledoc """
  Generates the `CREATE TABLE` DDL text for one entity type's per-tenant
  table, as a pure function of `Letflow.Entities.Definition.t()` (REQ-296).
  See `lib/letflow/design/req296-entity-table-ddl-generator.md` for the full
  design this module implements.

  ## Pure function -- no I/O, no tenant/schema awareness

  This module never calls `Letflow.Repo`, never opens a database
  connection, and never knows which tenant or schema a table belongs to.
  It only turns a `Letflow.Entities.Definition.t()` (plus a caller-supplied
  `table_name`) into raw SQL text. Deciding the physical `table_name` from
  an `entity_type`, executing the returned SQL against a real schema, and
  wiring promoted columns into any write path are all REQ-297/298's job,
  not this module's (see `docs/migration/decisions/0023-entity-storage-hybrid.md`
  and `docs/migration/decisions/0024-entity-promotion-ddl-execution.md`).

  ## Precondition: the definition has already passed `Validator.validate/1`

  Callers must have already run `Letflow.Entities.Definition.Validator.validate/1`
  on `definition` and received `:ok` before calling `generate_table_ddl/2` --
  this module does not re-run structural validation (FK coverage, the
  `:json`/`queried` conflict, name-format checks). It leans on those
  already-enforced invariants. The one exception is `valid_identifier?/1`
  (see below), which this module checks itself anyway, as a defence-in-depth
  measure independent of the Validator's own name-format rule, because a
  SQL-injection-shaped defect is exactly the kind of failure that should not
  depend solely on an upstream precondition silently continuing to hold.

  ## Output form: raw SQL text, not an `Ecto.Migration` AST

  `generate_table_ddl/2` returns `{:ok, sql}` where `sql` is a complete
  `CREATE TABLE` statement as a `String.t()` -- not an `Ecto.Migration`
  macro call list. This matches REQ-295/297's own `ALTER TABLE ... ADD
  COLUMN` half of table DDL, which already executes raw SQL text directly
  (the same way `Letflow.TenantProvisioning.provision_tenant_schema/1`
  already executes `CREATE SCHEMA IF NOT EXISTS ...` directly rather than
  through the migrator) -- one representation used consistently across both
  halves of table DDL, not two.

  ## REQ-301 -- generated-column-per-locale for `:localized_text`

  `promoted_columns/1`'s per-field dispatch (via `field_type_to_pg_type/1`
  and `promotion_trigger/2`) is a closed case dispatch over
  `Definition.field_type()`. A `:localized_text` field (REQ-301) dispatches
  instead to `localized_text_column_specs/1`, which emits one generated
  column per configured locale -- either a plain `text` column or a
  `tsvector` column, selected per-field by the field's `search_strategy`
  attribute (`:plain`, the default, or `:fulltext`). This per-field choice
  is `docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md`
  "Sub-question 2"'s decision, implemented here verbatim -- see that record
  for the reasoning; it is not re-derived in this module. See
  `lib/letflow/design/req301-localized-text-field-type.md` for the full
  design this section implements.

  ## ON DELETE policy for promoted FK columns (REQ-298)

  Every promoted-FK-column `REFERENCES` constraint this module emits carries
  a fixed, unconditional `ON DELETE RESTRICT` clause (Ecto:
  `on_delete: :restrict`), per
  `docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md`,
  "Decision" section, "Sub-question 1 -- `ON DELETE RESTRICT`": *"Every
  promoted-FK-column `REFERENCES` constraint uses **`ON DELETE RESTRICT`**
  (Ecto: `on_delete: :restrict`)."* This module does not re-derive or
  second-guess that record's reconciliation of `ON DELETE RESTRICT` against
  `Letflow.Entities.Records.delete_record/2`'s soft-delete semantics -- 0025
  already did that reasoning; this module only implements its answer.
  """

  alias Letflow.Entities.Definition

  @typedoc """
  One column in a generated `CREATE TABLE` statement. `:generated_as` and
  `:source_field` (REQ-301) are `nil`/absent for every structural or
  ordinary promoted column -- non-`nil` only for a locale-derived generated
  column (see `localized_text_column_specs/1`).
  """
  @type column_spec :: %{
          required(:name) => String.t(),
          required(:pg_type) => String.t(),
          required(:nullable) => boolean(),
          optional(:references_entity) => String.t() | nil,
          optional(:generated_as) => String.t() | nil,
          optional(:source_field) => String.t() | nil
        }

  @typedoc "Failure reason for `generate_table_ddl/3`."
  @type ddl_error ::
          {:invalid_identifier,
           field:
             :table_name
             | :attribute
             | :constraint_name
             | :constraint_field
             | :index_name
             | :index_field,
           value: String.t()}
          | {:missing_fk_target_table, entity_type: String.t()}

  @typedoc "Failure reason for `index_create_statements/2` (ISS-0623)."
  @type index_ddl_error ::
          ddl_error()
          | {:unsupported_index_field_type,
             index_name: String.t(), field: String.t(), type: Definition.field_type()}

  # GH #2635: end-anchor with \z, not $ -- in PCRE `$` also matches just before a
  # final newline, so a name with a trailing newline would pass.
  @identifier_format_regex ~r/^[a-z][a-z0-9_]{0,63}\z/

  # REQ-301 defence-in-depth: the exact two SQL-expression shapes
  # `localized_text_generated_expression/3` below ever emits, with `name`/
  # `locale` constrained to the same formats Validator Rules 1/10 already
  # enforce (`^[a-z][a-z0-9_]{0,63}$` / `^[a-z]{2,8}$`). See
  # `valid_generated_as_expression?/1`. End-anchored with \z (GH #2635), not $:
  # `$` would accept a trailing newline; the emitted expressions never have one.
  @localized_text_generated_as_regex ~r/^(?:field_values->'[a-z][a-z0-9_]{0,63}'->>'[a-z]{2,8}'|to_tsvector\('simple', coalesce\(field_values->'[a-z][a-z0-9_]{0,63}'->>'[a-z]{2,8}', ''\)\))\z/

  @doc """
  Generates the full `CREATE TABLE` DDL text for `definition`'s per-entity-type
  table, named `table_name`.

  `table_name` is supplied by the caller (REQ-297/provisioning's job to
  derive a physical table name from `entity_type`) -- this module does not
  invent a table-naming convention; it validates whatever name it is given
  and uses it verbatim in the emitted `CREATE TABLE "<table_name>" (...)`.

  `fk_target_tables` (REQ-298) maps every `references_entity` value named by
  `definition.foreign_keys` to its already-resolved physical table name.
  This module never resolves an `entity_type -> table_name` mapping itself
  (per its own "pure function, no I/O, no tenant/schema awareness"
  invariant) -- that is the caller's job
  (`Letflow.TenantProvisioning.table_name_for_entity_type/1`), same as
  `table_name` (the entity type's own physical name) already is today.
  Defaults to `%{}`, so every existing 2-arity call site (a definition with
  no `foreign_keys`) keeps compiling and behaving identically. If
  `definition.foreign_keys` names a `references_entity` absent from
  `fk_target_tables`, this function returns
  `{:error, {:missing_fk_target_table, entity_type: that_entity_type}}`
  rather than silently omitting the `REFERENCES` clause or guessing a table
  name.

  Returns `{:error, ddl_error()}` for a defence-in-depth identifier-shape
  failure (`table_name`, a promoted column name, or a `constraint_def`'s
  name/fields not matching the safe identifier format), or for a missing FK
  target table -- never for a structurally-invalid `Definition.t()`, which
  is the Validator's job and is assumed already passed per the precondition
  stated in the moduledoc.
  """
  @spec generate_table_ddl(
          Definition.t(),
          table_name :: String.t(),
          fk_target_tables :: %{optional(String.t()) => String.t()}
        ) :: {:ok, String.t()} | {:error, ddl_error()}
  def generate_table_ddl(definition, table_name, fk_target_tables \\ %{}) do
    promoted = promoted_columns(definition)
    columns = structural_columns() ++ promoted

    with :ok <- check_identifier(:table_name, table_name),
         :ok <- check_column_identifiers(columns),
         {:ok, unique_constraint_lines} <- unique_constraint_clauses(definition),
         {:ok, column_lines} <- build_column_lines(columns, fk_target_tables) do
      enum_checks = enum_check_constraints(definition, promoted)

      {:ok,
       build_create_table_sql(table_name, column_lines, enum_checks, unique_constraint_lines)}
    end
  end

  @doc """
  The fixed, definition-independent list of structural columns every
  per-entity-type table carries. A constant-shaped function (no
  `Definition.t()` input) so REQ-297/provisioning can also introspect the
  structural set independently of generating full DDL (e.g. to confirm a
  promoted attribute name never collides with a structural column name).

  `entity_type` is deliberately absent here -- `entity_record_latest`
  (the shared table this per-type table splits apart) carries it because
  that table holds every entity type in a tenant's schema; a per-entity-type
  table is, by construction, all one type, so the column would be a
  redundant constant on every row.
  """
  @spec structural_columns() :: [column_spec()]
  def structural_columns do
    [
      %{name: "id", pg_type: "uuid", nullable: false, references_entity: nil},
      %{name: "record_id", pg_type: "uuid", nullable: false, references_entity: nil},
      %{name: "field_values", pg_type: "jsonb", nullable: false, references_entity: nil},
      %{name: "deleted", pg_type: "boolean", nullable: false, references_entity: nil},
      %{name: "entity_def_version", pg_type: "bytea", nullable: true, references_entity: nil},
      %{
        name: "last_event_global_seq",
        pg_type: "bigint",
        nullable: false,
        references_entity: nil
      },
      %{
        name: "inserted_at",
        pg_type: "timestamp(6) without time zone",
        nullable: false,
        references_entity: nil
      },
      %{
        name: "updated_at",
        pg_type: "timestamp(6) without time zone",
        nullable: false,
        references_entity: nil
      }
    ]
  end

  @doc """
  Applies the promotion rule to `definition.fields`, using
  `definition.foreign_keys` to determine trigger 1 (foreign key). Returns
  zero or more `column_spec()`s per promoted attribute, in
  `definition.fields`'s original order (stable, deterministic output) --
  exactly one for every ordinary promoted type, and one per locale (REQ-301)
  for a promoted `:localized_text` field.

  A non-`:localized_text` field is filtered on `field_type_to_pg_type/1`
  returning `{:ok, _}`, not merely on `promotion_trigger/2`'s result -- this
  is the defence-in-depth that keeps a `:json`-typed field excluded even if
  it is somehow marked `queried: true` (Validator's Rule 3 bypassed, or
  relaxed by a future change) or somehow appears as an `fk_def().field`.
  A `:localized_text` field dispatches to `localized_text_column_specs/1`
  instead, which always returns `length(field.locales)` entries (never
  zero, since Rule 10 already guarantees a non-empty `:locales` for any
  `:localized_text` field that reaches this function).
  """
  @spec promoted_columns(Definition.t()) :: [column_spec()]
  def promoted_columns(definition) do
    foreign_keys = Map.get(definition, :foreign_keys, [])
    fk_field_names = MapSet.new(foreign_keys, &Map.get(&1, :field))

    references_entity_by_field =
      Map.new(foreign_keys, fn fk -> {Map.get(fk, :field), Map.get(fk, :references_entity)} end)

    definition
    |> Map.get(:fields, [])
    |> Enum.filter(fn field -> promotion_trigger(field, fk_field_names) != :not_promoted end)
    |> Enum.flat_map(fn field ->
      if Map.get(field, :type) == :localized_text do
        localized_text_column_specs(field)
      else
        trigger = promotion_trigger(field, fk_field_names)

        case field_type_to_pg_type(field) do
          :never_promoted ->
            []

          {:ok, mapped_pg_type} ->
            name = Map.get(field, :name)
            references_entity = Map.get(references_entity_by_field, name)

            [
              %{
                name: name,
                pg_type: fk_column_pg_type(trigger, mapped_pg_type),
                nullable: true,
                references_entity: references_entity,
                generated_as: nil,
                source_field: nil
              }
            ]
        end
      end
    end)
  end

  # REQ-298 correction, flagged for REVIEWER (found empirically while
  # implementing this requirement, not named by the req298 design doc's
  # literal text): a `:fk`-triggered column's physical Postgres type MUST be
  # `uuid`, never `field_type_to_pg_type/1`'s ordinary `:string -> "text"`
  # mapping. `fk_def.field` is, per 0023's own characterization, "an
  # ordinary `:string`-typed field ... holding a record_id-shaped UUID
  # string" -- but the *target* of every `REFERENCES` clause this module
  # emits is always `record_id`, a `uuid`-typed structural column
  # (`structural_columns/0`). Postgres's `ADD CONSTRAINT`/`ADD COLUMN
  # ... REFERENCES` check requires the referencing and referenced columns
  # to share a compatible equality operator; `text` and `uuid` do not have
  # one by default, so a `text`-typed FK column can never actually get a
  # real `REFERENCES` constraint at all -- confirmed empirically against a
  # real Postgres instance while building this requirement's own tests
  # (`ERROR 42804: foreign key constraint ... cannot be implemented ...
  # incompatible types: text and uuid`). Since every `fk_def.field` in this
  # codebase's own worked examples is `:string`-typed (0023 §"Many-to-many
  # is not a special case"), applying this module's ordinary mapping
  # unconditionally would make AC2 -- a real, Postgres-enforced FK --
  # unsatisfiable for the only field shape that ever triggers it. This
  # override is narrowly scoped to the `:fk` trigger only; a `:queried`
  # -triggered `:string` field (no FK) still gets `"text"`, unchanged.
  defp fk_column_pg_type(:fk, _mapped_pg_type), do: "uuid"
  defp fk_column_pg_type(_trigger, mapped_pg_type), do: mapped_pg_type

  @doc """
  The type-mapping table as a function. Takes the full `field_def()` (not
  just its `field_type()`) because `:decimal`'s Postgres type depends on
  the field's optional `decimal_precision`/`decimal_scale`, and `:enum`'s
  depends on its `enum_values`.

  Returns `:never_promoted` for `:json` and `:localized_text` -- the
  defence-in-depth measure described in `promoted_columns/1`'s doc.
  `:localized_text` always promotes via the N-column
  `localized_text_column_specs/1` path instead (dispatched in
  `promoted_columns/1` before this function is ever called for such a
  field) -- this clause exists purely so this function stays exhaustive and
  never raises. Never raises on any of the 9 `field_type()` values.

  Exposed publicly so REQ-297's own `column_spec` construction for a single
  later promotion (its own, separate `ALTER TABLE ADD COLUMN`) reuses the
  same mapping rather than re-deriving it.
  """
  @spec field_type_to_pg_type(Definition.field_def()) :: {:ok, String.t()} | :never_promoted
  def field_type_to_pg_type(field) do
    case Map.get(field, :type) do
      :string -> {:ok, "text"}
      :integer -> {:ok, "bigint"}
      :decimal -> {:ok, decimal_pg_type(field)}
      :boolean -> {:ok, "boolean"}
      :date -> {:ok, "date"}
      :datetime -> {:ok, "timestamp(6) without time zone"}
      :enum -> {:ok, "text"}
      :json -> :never_promoted
      :localized_text -> :never_promoted
    end
  end

  @doc """
  Given a `:localized_text` `field_def()` that has already passed
  `Letflow.Entities.Definition.Validator.validate/1` (so `:locales` is a
  non-empty, deduplicated, `^[a-z]{2,8}$`-validated list, and
  `:search_strategy` is `:plain`, `:fulltext`, or absent-meaning-`:plain`),
  returns one `column_spec()` per locale, in `:locales`'s declared order.

  Per `docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md`
  Sub-question 2: a `:plain` field (the default) promotes to one plain
  `text` column per locale, extracted from the `field_values` blob with a
  JSONB path-then-text-extract expression; a `:fulltext` field promotes to
  one `tsvector` column per locale instead, built via
  `to_tsvector('simple', ...)` (Postgres's always-available,
  language-neutral text-search configuration -- no per-locale
  dictionary/stemming policy is decided here or by `0025`).
  """
  @spec localized_text_column_specs(Definition.field_def()) :: [column_spec()]
  def localized_text_column_specs(field) do
    name = Map.get(field, :name)
    search_strategy = Map.get(field, :search_strategy) || :plain

    field
    |> Map.get(:locales, [])
    |> Enum.map(fn locale ->
      %{
        name: "#{name}_#{locale}",
        pg_type: localized_text_pg_type(search_strategy),
        nullable: true,
        generated_as: localized_text_generated_expression(search_strategy, name, locale),
        source_field: name
      }
    end)
  end

  defp localized_text_pg_type(:plain), do: "text"
  defp localized_text_pg_type(:fulltext), do: "tsvector"

  defp localized_text_generated_expression(:plain, name, locale) do
    ~s{field_values->'#{name}'->>'#{locale}'}
  end

  defp localized_text_generated_expression(:fulltext, name, locale) do
    ~s{to_tsvector('simple', coalesce(field_values->'#{name}'->>'#{locale}', ''))}
  end

  @doc """
  Determines which promotion trigger, if any, fires for `field`.

  - `:fk` -- `field`'s `:name` is a member of `fk_field_names` (every
    `fk_def().field` value from `definition.foreign_keys`), regardless of
    `field`'s `:queried` value.
  - `:queried` -- not `:fk`, and `field`'s `:queried` is `true`.
  - `:not_promoted` -- neither trigger fires.

  A bare decision function (no DDL concerns) so the promotion *rule* is
  independently testable from the DDL *text* it produces.
  """
  @spec promotion_trigger(Definition.field_def(), fk_field_names :: MapSet.t(String.t())) ::
          :fk | :queried | :not_promoted
  def promotion_trigger(field, fk_field_names) do
    cond do
      MapSet.member?(fk_field_names, Map.get(field, :name)) -> :fk
      Map.get(field, :queried) == true -> :queried
      true -> :not_promoted
    end
  end

  @doc """
  Whether `value` is a safe SQL identifier -- matches the same format
  `Letflow.Entities.Definition.Validator` already enforces on names
  (`~r/^[a-z][a-z0-9_]{0,63}$/`). This module does not import or call the
  Validator's private regex; it defines its own equivalent public check, so
  this module's safety property does not depend on the Validator's private
  implementation detail staying accessible or unchanged.
  """
  @spec valid_identifier?(String.t()) :: boolean()
  def valid_identifier?(value) when is_binary(value) do
    Regex.match?(@identifier_format_regex, value)
  end

  def valid_identifier?(_value), do: false

  @doc """
  Builds the `CONSTRAINT "<name>" UNIQUE (...)` clause text for every entry
  in `definition.constraints` (`constraint_def()`, REQ-298) -- always a
  **named** constraint, never a bare `UNIQUE (...)`, because
  `Letflow.TenantProvisioning.run_constraint_activation/1`'s own retrofit
  `ADD CONSTRAINT` step (the many-fields-promoted-independently case a
  single-column `ADD COLUMN` cannot express) must reference the same name
  for its own idempotent-skip check against
  `information_schema.table_constraints`.

  Public so both the fresh-`CREATE TABLE` path (this module's own
  `generate_table_ddl/3`) and the retrofit path
  (`Letflow.TenantProvisioning.run_constraint_activation/1`) build the
  identical clause text from one shared function -- never two independently
  hand-written SQL strings.

  Validates `constraint_def.name` and every entry of `constraint_def.fields`
  via `valid_identifier?/1` (defence in depth, same posture as
  `check_column_identifiers/1`) -- returns `{:error, ddl_error()}` on the
  first invalid identifier found, never silently drops or truncates a
  malformed constraint.
  """
  @spec unique_constraint_clauses(Definition.t()) ::
          {:ok, [String.t()]} | {:error, ddl_error()}
  def unique_constraint_clauses(definition) do
    definition
    |> Map.get(:constraints, [])
    |> Enum.reduce_while({:ok, []}, fn constraint, {:ok, acc} ->
      case unique_constraint_clause(constraint) do
        {:ok, clause} -> {:cont, {:ok, [clause | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, clauses} -> {:ok, Enum.reverse(clauses)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Builds one complete, standalone `CREATE INDEX "<name>" ON "<table_name>"
  (<fields>)` statement (or `CREATE UNIQUE INDEX` when `index_def.unique` is
  `true`) per entry in `definition.indexes`, in `definition.indexes`'s
  declared order, over **unqualified** `table_name` -- schema-qualification
  is the caller's job, same convention `generate_table_ddl/3` already uses
  (`Letflow.TenantProvisioning.qualify_index_create_sql/3`). Returns
  `{:ok, []}` when `definition.indexes` is absent or `[]`.

  `CREATE INDEX` cannot be inlined into `CREATE TABLE (...)`'s column/
  constraint list the way `UNIQUE (...)`/`CHECK (...)` can -- Postgres
  syntax requires a separate statement -- so this is a sibling function,
  independent of `generate_table_ddl/3`'s own return value, never folded
  into it (ISS-0623 design §1: this keeps `generate_table_ddl/3`'s
  `@spec`/behavior/tests completely unchanged).

  Validates every `index_def.name` and every entry of `index_def.fields` via
  `valid_identifier?/1` (defence in depth, same posture as
  `unique_constraint_clause/1`'s own checks), returning
  `{:error, {:invalid_identifier, field: :index_name | :index_field, value:
  ...}}` on the first invalid identifier found.

  Also defensively rejects an `index_def` naming a `:localized_text`-typed
  field (ISS-0623 design §5): such a field never promotes to a single column
  named `field.name` (it promotes to one generated column per locale, see
  `localized_text_column_specs/1`), so a naive `CREATE INDEX` referencing
  `field.name` directly would reference a column that does not exist.
  Returns `{:error, {:unsupported_index_field_type, index_name: ...,
  field: ..., type: :localized_text}}` instead of emitting broken SQL.

  Field order within each statement is `index_def.fields`'s declared order
  -- never reordered or deduplicated (index column order is semantically
  meaningful for a Postgres index's usefulness on range/prefix queries).

  No de-duplication against `definition.constraints` is performed -- an
  `index_def{unique: true}` whose fields overlap a `constraint_def`'s fields
  is emitted verbatim regardless (ISS-0623 design §3: these are two
  independent, author-controlled declarations).
  """
  @spec index_create_statements(Definition.t(), table_name :: String.t()) ::
          {:ok, [String.t()]} | {:error, index_ddl_error()}
  def index_create_statements(definition, table_name) do
    localized_text_field_names =
      definition
      |> Map.get(:fields, [])
      |> Enum.filter(fn field -> Map.get(field, :type) == :localized_text end)
      |> MapSet.new(&Map.get(&1, :name))

    definition
    |> Map.get(:indexes, [])
    |> Enum.reduce_while({:ok, []}, fn index_def, {:ok, acc} ->
      case index_create_statement(index_def, table_name, localized_text_field_names) do
        {:ok, statement} -> {:cont, {:ok, [statement | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, statements} -> {:ok, Enum.reverse(statements)}
      {:error, _reason} = error -> error
    end
  end

  defp index_create_statement(
         %{name: name, fields: fields} = index_def,
         table_name,
         localized_text_field_names
       ) do
    with :ok <- check_index_name_identifier(name),
         :ok <- check_index_field_identifiers(fields),
         :ok <- check_index_field_types(name, fields, localized_text_field_names) do
      field_list = Enum.map_join(fields, ", ", &~s("#{&1}"))

      keyword =
        if Map.get(index_def, :unique) == true, do: "CREATE UNIQUE INDEX", else: "CREATE INDEX"

      {:ok, ~s|#{keyword} "#{name}" ON "#{table_name}" (#{field_list})|}
    end
  end

  defp check_index_name_identifier(name) do
    if valid_identifier?(name) do
      :ok
    else
      {:error, {:invalid_identifier, field: :index_name, value: name}}
    end
  end

  defp check_index_field_identifiers(fields) do
    fields
    |> Enum.find(fn field -> not valid_identifier?(field) end)
    |> case do
      nil -> :ok
      field -> {:error, {:invalid_identifier, field: :index_field, value: field}}
    end
  end

  defp check_index_field_types(index_name, fields, localized_text_field_names) do
    fields
    |> Enum.find(fn field -> MapSet.member?(localized_text_field_names, field) end)
    |> case do
      nil ->
        :ok

      field ->
        {:error,
         {:unsupported_index_field_type,
          index_name: index_name, field: field, type: :localized_text}}
    end
  end

  @doc """
  Whether `value` matches one of the two known SQL-expression shapes
  `localized_text_column_specs/1` ever emits into a `generated_as` field
  (REQ-301) -- the `:plain` JSONB-extract form or the `:fulltext`
  `to_tsvector(...)` form, each with `name`/`locale` constrained to the same
  formats `Letflow.Entities.Definition.Validator` Rules 1/10 already
  enforce.

  This is `valid_identifier?/1`'s counterpart for a SQL *expression* rather
  than a bare identifier: `Letflow.TenantProvisioning.execute_add_column/3`
  calls this to re-validate a `ColumnPromotion` row's `generated_as` text
  immediately before splicing it into `ALTER TABLE ... ADD COLUMN`, the same
  defence-in-depth posture that function already applies to
  `table_name`/`column_name`/`pg_type` -- closing the one interpolated value
  that re-validation set previously left uncovered.
  """
  @spec valid_generated_as_expression?(String.t()) :: boolean()
  def valid_generated_as_expression?(value) when is_binary(value) do
    Regex.match?(@localized_text_generated_as_regex, value)
  end

  def valid_generated_as_expression?(_value), do: false

  # --- internal ---------------------------------------------------------------

  defp decimal_pg_type(field) do
    case {Map.get(field, :decimal_precision), Map.get(field, :decimal_scale)} do
      {precision, scale} when is_integer(precision) and is_integer(scale) ->
        "numeric(#{precision}, #{scale})"

      _other ->
        "numeric"
    end
  end

  defp check_identifier(_field, value) when is_binary(value) do
    if valid_identifier?(value) do
      :ok
    else
      {:error, {:invalid_identifier, field: :table_name, value: value}}
    end
  end

  defp check_column_identifiers(columns) do
    columns
    |> Enum.find(fn column -> not valid_identifier?(column.name) end)
    |> case do
      nil -> :ok
      column -> {:error, {:invalid_identifier, field: :attribute, value: column.name}}
    end
  end

  defp enum_check_constraints(definition, promoted_columns) do
    promoted_names = MapSet.new(promoted_columns, & &1.name)

    definition
    |> Map.get(:fields, [])
    |> Enum.filter(fn field ->
      Map.get(field, :type) == :enum and MapSet.member?(promoted_names, Map.get(field, :name))
    end)
    |> Enum.map(fn field ->
      name = Map.get(field, :name)
      values = Map.get(field, :enum_values, [])
      value_list = Enum.map_join(values, ", ", &enum_literal/1)

      "CHECK (\"#{name}\" IN (#{value_list}))"
    end)
  end

  defp enum_literal(value) do
    escaped = String.replace(value, "'", "''")
    "'#{escaped}'"
  end

  defp build_create_table_sql(table_name, column_lines, enum_checks, unique_constraint_lines) do
    constraint_lines =
      ["PRIMARY KEY (\"id\")", "UNIQUE (\"record_id\")"] ++
        enum_checks ++ unique_constraint_lines

    lines = column_lines ++ constraint_lines

    """
    CREATE TABLE "#{table_name}" (
      #{Enum.join(lines, ",\n  ")}
    )\
    """
  end

  defp build_column_lines(columns, fk_target_tables) do
    columns
    |> Enum.reduce_while({:ok, []}, fn column, {:ok, acc} ->
      case column_sql_line(column, fk_target_tables) do
        {:ok, line} -> {:cont, {:ok, [line | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      {:error, _reason} = error -> error
    end
  end

  defp column_sql_line(
         %{name: name, pg_type: pg_type, nullable: nullable} = column,
         fk_target_tables
       ) do
    case Map.get(column, :generated_as) do
      nil ->
        null_clause = if nullable, do: "", else: " NOT NULL"
        default_clause = default_clause_for(column)
        base = ~s("#{name}" #{pg_type}#{null_clause}#{default_clause})

        case Map.get(column, :references_entity) do
          nil ->
            {:ok, base}

          entity_type ->
            case Map.fetch(fk_target_tables, entity_type) do
              {:ok, target_table} ->
                {:ok, base <> ~s| REFERENCES "#{target_table}"("record_id") ON DELETE RESTRICT|}

              :error ->
                {:error, {:missing_fk_target_table, entity_type: entity_type}}
            end
        end

      generated_as ->
        {:ok, ~s{"#{name}" #{pg_type} GENERATED ALWAYS AS (#{generated_as}) STORED}}
    end
  end

  defp default_clause_for(%{name: "field_values"}), do: " DEFAULT '{}'::jsonb"
  defp default_clause_for(%{name: "deleted"}), do: " DEFAULT false"
  defp default_clause_for(_column), do: ""

  defp unique_constraint_clause(%{name: name, fields: fields}) do
    with :ok <- check_constraint_name_identifier(name),
         :ok <- check_constraint_field_identifiers(fields) do
      field_list = Enum.map_join(fields, ", ", &~s("#{&1}"))
      {:ok, ~s|CONSTRAINT "#{name}" UNIQUE (#{field_list})|}
    end
  end

  defp check_constraint_name_identifier(name) do
    if valid_identifier?(name) do
      :ok
    else
      {:error, {:invalid_identifier, field: :constraint_name, value: name}}
    end
  end

  defp check_constraint_field_identifiers(fields) do
    fields
    |> Enum.find(fn field -> not valid_identifier?(field) end)
    |> case do
      nil -> :ok
      field -> {:error, {:invalid_identifier, field: :constraint_field, value: field}}
    end
  end
end
