defmodule Letflow.Entities.Query.Compiler do
  @moduledoc """
  `compiler.zig`-equivalent (REQ-230 §5) -- compiles an allowlisted
  filter/sort request into a parameterised `Ecto.Query.t()`. See
  `lib/letflow/design/req230-entity-query-dsl-compiler.md` §5 for the full
  design this module implements.

  This is layer 3 of the three-layer SQL-injection defence: by the time a
  clause reaches `build_filter_dynamic/3`/`build_order_by/3`, its `field`
  has already been resolved against `Letflow.Entities.Query.Allowlist`
  (layer 2) and its `op` has already been parsed against
  `Letflow.Entities.Query.Types`'s closed enum (layer 1) -- this module's
  own job is exclusively to ensure every remaining caller-supplied VALUE is
  bound as a genuine positional Ecto/Postgres parameter, never
  string-interpolated or concatenated into any SQL text (AC4, INV-7).

  ## The fragment-literal discipline (design §5.2, AC4's core mechanism)

  `fragment/1`'s first argument must be a compile-time-literal binary --
  Ecto's own compiler rejects any attempt to build that literal at runtime
  (`Ecto.Query.CompileError`, confirmed by `docs/anti-patterns.md`'s
  "Duplicating an `Ecto.Query.fragment/1` SQL literal" entry). This module
  never attempts to build a fragment literal at runtime: `build_filter_dynamic/3`
  is a pattern-matched function with one clause per `{source, op, field_type}`
  combination that needs JSONB access, each clause containing its own
  distinct `fragment/1` call whose literal string is fixed at compile time,
  chosen by which clause matches at runtime -- the same technique
  `lib/letflow/definitions.ex`'s `select_with_rank/3`/`order_by_rank/3` use
  for their shared `@rank_case_sql` literal.

  Both the JSONB **key name** (`^field_name`, already proven to be one of
  the finite names `Allowlist.load/2` enumerated for this entity type) and
  the comparison **value** (`^value`) are bound as separate `^`-bound Ecto
  parameters -- never spliced into the fragment text. This is strictly
  stronger than AC4's own wording requires (AC4 names the comparison value
  only) -- parameterising the key name too closes a second, related
  injection surface for free.

  `compile/2` never calls `Repo.*` to *execute* the query it returns -- it
  returns a **not-yet-executed** `Ecto.Query.t()`; the caller executes it
  (e.g. `Repo.all(query, prefix: prefix)`), matching every other
  tenant-scoped query in this subsystem. As of REQ-300, `compile/2`'s own
  *compilation* step does perform two narrow, genuine `information_schema`
  introspection reads (`resolve_binding_source/2`'s and
  `relation_column_exists?/3`'s, both delegating to
  `Letflow.TenantProvisioning`'s `entity_table_exists?/2` and
  `entity_column_exists?/3` respectively, rather than touching `Repo`
  directly in this module -- REQ-300 rework cycle 3 moved the column-level
  query there so `Letflow.Entities.Query.Allowlist.load/2` could reuse the
  exact same primitive) -- see the REQ-300 design doc §3.2/§4.0.2 for why
  this is a deliberate, narrow exception to (not a violation of) the
  "never executes the query it builds" invariant, which is about the
  *returned* query, not every step of building it.

  ## REQ-300 -- joins over promoted FK columns

  See `lib/letflow/design/req300-query-joins.md` for the full design this
  section implements: a query request can additionally carry a `:join`
  list (`Letflow.Entities.Query.Types.join_clause/0`), each entry
  expressing a read across one `fk_def()` relationship (direct, or
  many-to-many via `through`). Two invariants this design's own rework
  history exists to protect, restated here for anyone touching this module
  again:

    1. A **plain** (non-join) request against an entity type that has
       never had a column promoted is **completely unchanged** --
       `resolve_binding_source/2` resolves such a primary to `:latest`, and
       the base query stays the exact `Latest |> where(entity_type) |>
       where(combined) |> apply_order_bys(...)` construction this module
       has always produced (`compile_plain/6`'s `:latest` branch, byte for
       byte).
    2. A join's **declaring side** (whichever entity type owns the
       `fk_def`) is checked at **two levels**, not one, before its `on:`
       condition is ever built: does its per-type **table** exist
       (`resolve_binding_source/2`), and does the specific **column** this
       relation names physically exist on that table
       (`relation_column_exists?/3`)? A definition can declare an `fk_def`
       additively, ahead of that column ever being promoted -- the second
       check is what turns that gap into a named `{:relation_column_not_found,
       entity_type, column}` error instead of a raw Postgres error surfacing
       only once the returned query is executed.
  """

  import Ecto.Query

  alias Letflow.Entities.Definition
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.Record.Latest
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type compile_error ::
          {:error, :invalid_schema_name}
          | {:error, :entity_type_not_found}
          | {:error, {:unknown_operator, String.t()}}
          | {:error, {:unknown_sort_dir, String.t()}}
          | {:error, {:field_not_allowed, String.t()}}
          | {:error, {:value_arity_mismatch, Types.filter_op()}}
          | {:error, {:invalid_in_value, String.t()}}
          | {:error, {:operator_not_valid_for_type, Types.filter_op(), Definition.field_type()}}
          | {:error, :entity_table_not_found}
          | {:error, {:too_many_joins, non_neg_integer()}}
          | {:error, :join_depth_exceeded}
          | {:error, {:no_through_relation, through :: String.t(), primary :: String.t()}}
          | {:error, {:ambiguous_through_relation, through :: String.t()}}
          | {:error, {:duplicate_join_target, entity_type :: String.t()}}
          | {:error,
             {:relation_column_not_found, entity_type :: String.t(), column :: String.t()}}

  @typedoc """
  One fk hop of a resolved join relation: the entity that DECLARES the fk
  (`owner_entity_type`) and the fk column on it (`fk_field`). GH #2697: the
  request-side restricted-field guard governs each hop by the declaring
  entity's own restriction set.
  """
  @type join_hop :: %{owner_entity_type: String.t(), fk_field: String.t()}

  @typedoc """
  One join clause's resolved relation: a direct join has exactly one hop, a
  `through` join exactly two (`[near_hop, far_hop]`).
  """
  @type join_relation :: %{exposed_key: String.t(), hops: [join_hop()]}

  @typedoc "Error union of `join_relations/3` (all members of `compile_error()`)."
  @type join_relations_error ::
          {:error, {:too_many_joins, non_neg_integer()}}
          | {:error, :join_depth_exceeded}
          | {:error, {:duplicate_join_target, String.t()}}
          | {:error, {:field_not_allowed, String.t()}}
          | {:error, {:no_through_relation, String.t(), String.t()}}
          | {:error, {:ambiguous_through_relation, String.t()}}
          | {:error, :entity_type_not_found}
          | {:error, :invalid_schema_name}

  @typedoc """
  Which physical table a binding (the primary, or one side of a join)
  reads from (REQ-300 design §3.2). `:latest` is the shared
  `entity_record_latest` table, scoped by an `entity_type` where-clause;
  `{:per_type_table, table_name}` is that entity type's own promoted-column
  table (REQ-296/297/298).
  """
  @type binding_source :: {:per_type_table, table_name :: String.t()} | :latest

  @typedoc "One structurally-uniform entity row (REQ-300 design §4.1)."
  @type entity_row :: %{
          record_id: String.t(),
          field_values: map(),
          deleted: boolean(),
          entity_def_version: binary() | nil,
          last_event_global_seq: integer(),
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  @typedoc """
  One joined result row (REQ-300 design §4.1): the primary entity under
  `:primary`, plus one entry per `join_clause()`, keyed by that clause's own
  `entity_type` string.
  """
  @type joined_row :: %{
          required(:primary) => entity_row(),
          optional(String.t()) => entity_row()
        }

  @join_alias_pool [:join_0, :join_1, :join_2, :join_3]
  @through_alias_pool [:through_0, :through_1, :through_2, :through_3]
  @max_joins 4

  @doc """
  Compiles `request` (already allowlisted per its `entity_type`) into a
  parameterised `Ecto.Query.t()`, scoped to the tenant schema named by
  `prefix` (design §5.1, extended by REQ-300 design §3.3 for the optional
  `:join` field). Never calls `Repo.*` to execute the returned query -- see
  this module's own moduledoc for the two narrow, genuine `Repo.*` reads
  REQ-300 adds during *compilation* itself.
  """
  @spec compile(Types.query_request(), prefix :: String.t()) ::
          {:ok, Ecto.Query.t()} | compile_error()
  def compile(%{entity_type: entity_type} = request, prefix)
      when is_binary(entity_type) and is_binary(prefix) do
    filters = Map.get(request, :filters, [])
    sorts = Map.get(request, :sort, [])
    joins = Map.get(request, :join, [])

    with :ok <- check_join_shape(joins),
         {:ok, allowlist} <- Allowlist.load(entity_type, prefix),
         {:ok, primary_source0} <- resolve_binding_source(entity_type, prefix),
         {:ok, prepared_joins, primary_source} <-
           resolve_joins(joins, entity_type, primary_source0, prefix) do
      if prepared_joins == [] do
        compile_plain(entity_type, allowlist, primary_source, filters, sorts)
      else
        compile_joined(entity_type, allowlist, primary_source, prepared_joins, filters, sorts)
      end
    end
  end

  @doc """
  Resolves, from entity DEFINITIONS only (no query built, no
  `information_schema` read), the fk hops a `join` list would use (GH #2697).
  Runs `check_join_shape/1` first, exactly as `compile/2` does, so an
  over-wide request does no definition reads and returns the same error
  `compile/2` would. An empty `joins` list returns `{:ok, []}` with no I/O.
  Reuses `resolve_all_raw_relations/3`, so there is no second copy of the
  fk-ownership rules.
  """
  @spec join_relations(
          joins :: [Types.join_clause()],
          primary_entity_type :: String.t(),
          prefix :: String.t()
        ) :: {:ok, [join_relation()]} | join_relations_error()
  def join_relations(joins, primary_entity_type, prefix)
      when is_list(joins) and is_binary(primary_entity_type) and is_binary(prefix) do
    with :ok <- check_join_shape(joins),
         :ok <- ensure_primary_exists(joins, primary_entity_type, prefix),
         {:ok, raw} <-
           resolve_all_raw_relations(Enum.with_index(joins), primary_entity_type, prefix) do
      {:ok, Enum.map(raw, &raw_to_join_relation/1)}
    end
  end

  # INV-5 (GH #2697 sec rework B1): compile/2 loads the primary first, so a
  # missing primary type is `:entity_type_not_found` before any join-specific
  # error. Establish the same precedence here (a `through` join on a missing
  # primary would otherwise surface `:no_through_relation`). No I/O for [].
  defp ensure_primary_exists([], _primary, _prefix), do: :ok

  defp ensure_primary_exists(_joins, primary, prefix) do
    # MUTANT M11: the primary-existence check is removed
    _ = {primary, prefix}
    :ok
  end

  defp raw_to_join_relation(%{kind: :direct, exposed_key: key, rel: rel}),
    do: %{exposed_key: key, hops: [hop_of(rel)]}

  defp raw_to_join_relation(%{kind: :through, exposed_key: key, near_rel: near, far_rel: far}),
    do: %{exposed_key: key, hops: [hop_of(near), hop_of(far)]}

  defp hop_of(rel), do: %{owner_entity_type: rel.owner_entity_type, fk_field: rel.fk_field}

  # ---------------------------------------------------------------------------------
  # REQ-300 design §3.2 -- resolve_binding_source/2 and §4.0.2 --
  # relation_column_exists?/3. The two genuine `information_schema` reads
  # this module performs during compilation (both delegating to
  # `TenantProvisioning`, rework cycle 3).
  # ---------------------------------------------------------------------------------

  @doc """
  Resolves which physical table `entity_type` reads from, scoped to the
  tenant schema named by `prefix` (design §3.2): `{:per_type_table,
  table_name}` if that entity type's per-entity-type table currently
  exists, `:latest` otherwise. A **query-time existence check**, not a
  promotion-state cache -- it reflects whatever
  `TenantProvisioning.entity_table_exists?/2` reports at the moment this
  runs.
  """
  @spec resolve_binding_source(entity_type :: String.t(), prefix :: String.t()) ::
          {:ok, binding_source()} | {:error, :invalid_entity_type}
  def resolve_binding_source(entity_type, prefix) do
    with {:ok, table_name} <- TenantProvisioning.table_name_for_entity_type(entity_type) do
      if TenantProvisioning.entity_table_exists?(prefix, table_name) do
        {:ok, {:per_type_table, table_name}}
      else
        {:ok, :latest}
      end
    end
  end

  @doc """
  Whether `column_name` physically exists on `table_name` in the tenant
  schema named by `schema_name` (design §4.0.2). REQ-300 rework cycle 3:
  this is now a thin delegate to
  `TenantProvisioning.entity_column_exists?/3`, the single shared
  implementation of this check -- `Letflow.Entities.Query.Allowlist.load/2`
  needed the exact same column-granularity check (SECURITY-REVIEWER-found
  regression: the ordinary, non-join filter/sort path had the same
  table-vs-column existence gap this join-path check was already built
  for), and duplicating the `information_schema.columns` query in two
  places risked them drifting. Kept as a public function here (not
  inlined at its one call site below) since it is still this module's own
  named primitive per the design doc.
  """
  @spec relation_column_exists?(
          schema_name :: String.t(),
          table_name :: String.t(),
          column_name :: String.t()
        ) :: boolean()
  def relation_column_exists?(schema_name, table_name, column_name) do
    TenantProvisioning.entity_column_exists?(schema_name, table_name, column_name)
  end

  # ---------------------------------------------------------------------------------
  # §4.2 -- value-arity / :in-value-shape checks (pure, no allowlist needed).
  # ---------------------------------------------------------------------------------

  @doc """
  Checks that `value_present?` matches what `op` requires (design §4.2):
  `:is_null`/`:is_not_null` require no value; every other operator requires
  exactly one.
  """
  @spec check_value_arity(Types.filter_op(), value_present? :: boolean()) ::
          :ok | {:error, {:value_arity_mismatch, Types.filter_op()}}
  def check_value_arity(op, value_present?) when op in [:is_null, :is_not_null] do
    if value_present?, do: {:error, {:value_arity_mismatch, op}}, else: :ok
  end

  def check_value_arity(op, value_present?) do
    if value_present?, do: :ok, else: {:error, {:value_arity_mismatch, op}}
  end

  # ---------------------------------------------------------------------------------
  # §4.3 -- operator/field-type compatibility (needs the resolved field's type).
  # ---------------------------------------------------------------------------------

  @doc """
  Checks that `op` is meaningful for `field_type` per
  `Letflow.Entities.Query.Types.valid_field_types_for/1`'s table (design
  §4.3, §2.1).
  """
  @spec check_operator_field_type(Types.filter_op(), Definition.field_type()) ::
          :ok
          | {:error, {:operator_not_valid_for_type, Types.filter_op(), Definition.field_type()}}
  def check_operator_field_type(op, field_type) do
    case Types.valid_field_types_for(op) do
      nil ->
        :ok

      valid_types ->
        if field_type in valid_types do
          :ok
        else
          {:error, {:operator_not_valid_for_type, op, field_type}}
        end
    end
  end

  # ---------------------------------------------------------------------------------
  # §5.4 -- build_filter_dynamic/3: source x op x type dispatch, no fallback clause.
  #
  # REQ-300 design §3.4 -- the two-path column-reference split, gated on the
  # PRIMARY binding's own `binding_source`, carried via `ctx`
  # (`%{source: binding_source(), entity_type: String.t()}`). For a
  # `:latest`-bound primary (the ordinary, never-promoted case, and every
  # existing REQ-230 test), dispatch is byte-for-byte what it always was:
  # `"entity_type"` and every other fixed-7 name resolve via the fixed atom
  # path below; a `:typed_column`-sourced non-fixed-7 name cannot occur for
  # a `:latest`-bound entity type in the first place (Allowlist.load/2 only
  # marks a promoted name `:typed_column` once its own per-type table
  # exists -- see that module's own moduledoc note). Only for a
  # `{:per_type_table, _}`-bound primary do the `"entity_type"`
  # constant-fold special case and the promoted-name fragment path ever
  # trigger.
  # ---------------------------------------------------------------------------------

  @doc """
  Builds one `Ecto.Query.dynamic_expr()` for one already-resolved filter
  clause (design §5.4, extended by REQ-300 design §3.4). Dispatches first
  on `allowlisted_field().source`, then on `{op, field_type}` -- every
  combination this design considered is enumerated explicitly; there is no
  catch-all clause that could silently assemble an unvetted shape for a
  combination this design did not think through.
  """
  @spec build_filter_dynamic(Types.filter_clause(), Allowlist.allowlisted_field(), binding_ctx()) ::
          {:ok, Ecto.Query.dynamic_expr()}
          | {:error, {:value_arity_mismatch, Types.filter_op()}}
          | {:error, {:invalid_in_value, String.t()}}
          | {:error, {:operator_not_valid_for_type, Types.filter_op(), Definition.field_type()}}
  def build_filter_dynamic(
        %{field: "entity_type", op: op} = clause,
        %{source: :typed_column},
        %{source: {:per_type_table, _}, entity_type: bound_entity_type}
      ) do
    value = Map.get(clause, :value)

    with :ok <- check_in_value_shape(op, value, "entity_type") do
      {:ok, entity_type_constant_dynamic(op, bound_entity_type, value)}
    end
  end

  def build_filter_dynamic(%{field: field_name, op: op} = clause, %{source: :typed_column}, _ctx) do
    value = Map.get(clause, :value)

    with :ok <- check_in_value_shape(op, value, field_name) do
      {:ok, typed_column_dynamic_dispatch(op, field_name, value)}
    end
  end

  def build_filter_dynamic(%{op: op} = clause, %{source: :json_field, type: type} = af, _ctx) do
    value = Map.get(clause, :value)
    field_name = af.name

    with :ok <- check_in_value_shape(op, value, field_name) do
      {:ok, json_field_dynamic(op, type, field_name, value)}
    end
  end

  defp check_in_value_shape(op, value, field_name) when op in [:in, :not_in] do
    if is_list(value) do
      :ok
    else
      {:error, {:invalid_in_value, field_name}}
    end
  end

  defp check_in_value_shape(_op, _value, _field_name), do: :ok

  # Dispatch: a name present on Allowlist.typed_columns/0's fixed 7-entry
  # map resolves via the unchanged fixed atom path; any other name (only
  # ever reachable for a per-type-table-bound primary, per Allowlist.load/2's
  # own gating) resolves via the new promoted-name fragment path.
  defp typed_column_dynamic_dispatch(op, field_name, value) do
    case Map.fetch(Allowlist.typed_columns(), field_name) do
      {:ok, {column_atom, _type}} -> typed_column_dynamic(op, column_atom, value)
      :error -> promoted_column_dynamic(op, field_name, value)
    end
  end

  # -- typed-column dynamics (design §5.3) -- `field(r, ^column_atom)`,
  # `column_atom` sourced only from `Allowlist.typed_columns/0`'s own fixed,
  # closed table -- never `String.to_atom/1` on caller input.

  defp typed_column_dynamic(:eq, col, value), do: dynamic([r], field(r, ^col) == ^value)
  defp typed_column_dynamic(:neq, col, value), do: dynamic([r], field(r, ^col) != ^value)
  defp typed_column_dynamic(:gt, col, value), do: dynamic([r], field(r, ^col) > ^value)
  defp typed_column_dynamic(:gte, col, value), do: dynamic([r], field(r, ^col) >= ^value)
  defp typed_column_dynamic(:lt, col, value), do: dynamic([r], field(r, ^col) < ^value)
  defp typed_column_dynamic(:lte, col, value), do: dynamic([r], field(r, ^col) <= ^value)
  defp typed_column_dynamic(:in, col, value), do: dynamic([r], field(r, ^col) in ^value)
  defp typed_column_dynamic(:not_in, col, value), do: dynamic([r], field(r, ^col) not in ^value)

  defp typed_column_dynamic(:contains, col, value) do
    pattern = "%" <> value <> "%"
    dynamic([r], ilike(field(r, ^col), ^pattern))
  end

  defp typed_column_dynamic(:starts_with, col, value) do
    pattern = value <> "%"
    dynamic([r], ilike(field(r, ^col), ^pattern))
  end

  defp typed_column_dynamic(:is_null, col, _value), do: dynamic([r], is_nil(field(r, ^col)))

  defp typed_column_dynamic(:is_not_null, col, _value),
    do: dynamic([r], not is_nil(field(r, ^col)))

  # -- promoted-column dynamics (REQ-300 design §3.4, new) -- referenced via
  # `fragment("?", literal(^field_name))`, Ecto's own `literal/1` fragment
  # helper, which emits a properly quoted SQL identifier from a runtime
  # string WITHOUT ever producing an Elixir atom. `field_name` reaching this
  # branch has already passed `Allowlist.resolve_field/2` (this entity
  # type's own allowlist), so it is provably one of that entity type's own
  # real, promoted column names -- never an arbitrary caller string. Only
  # ever reached for a per-type-table-bound field (see
  # `Allowlist.load/2`'s own gating), where the primary is the query's only
  # binding, so an unqualified identifier reference is unambiguous.

  defp promoted_column_dynamic(:eq, field_name, value),
    do: dynamic([r], fragment("?", literal(^field_name)) == ^value)

  defp promoted_column_dynamic(:neq, field_name, value),
    do: dynamic([r], fragment("?", literal(^field_name)) != ^value)

  defp promoted_column_dynamic(:gt, field_name, value),
    do: dynamic([r], fragment("?", literal(^field_name)) > ^value)

  defp promoted_column_dynamic(:gte, field_name, value),
    do: dynamic([r], fragment("?", literal(^field_name)) >= ^value)

  defp promoted_column_dynamic(:lt, field_name, value),
    do: dynamic([r], fragment("?", literal(^field_name)) < ^value)

  defp promoted_column_dynamic(:lte, field_name, value),
    do: dynamic([r], fragment("?", literal(^field_name)) <= ^value)

  defp promoted_column_dynamic(:in, field_name, value),
    do: dynamic([r], fragment("?", literal(^field_name)) in ^value)

  defp promoted_column_dynamic(:not_in, field_name, value),
    do: dynamic([r], fragment("?", literal(^field_name)) not in ^value)

  defp promoted_column_dynamic(:contains, field_name, value) do
    pattern = "%" <> value <> "%"
    dynamic([r], ilike(fragment("?", literal(^field_name)), ^pattern))
  end

  defp promoted_column_dynamic(:starts_with, field_name, value) do
    pattern = value <> "%"
    dynamic([r], ilike(fragment("?", literal(^field_name)), ^pattern))
  end

  defp promoted_column_dynamic(:is_null, field_name, _value),
    do: dynamic([r], is_nil(fragment("?", literal(^field_name))))

  defp promoted_column_dynamic(:is_not_null, field_name, _value),
    do: dynamic([r], not is_nil(fragment("?", literal(^field_name))))

  # -- "entity_type" constant-fold (REQ-300 design §3.4, new, per-type-table
  # only) -- the entity type is already statically known, so this evaluates
  # entirely in Elixir and folds to a constant `dynamic(true)`/`dynamic(false)`,
  # never a SQL comparison against a column that does not physically exist
  # on a per-type table.

  defp entity_type_constant_dynamic(op, bound_entity_type, value) do
    if entity_type_constant_result(op, bound_entity_type, value) do
      dynamic(true)
    else
      dynamic(false)
    end
  end

  defp entity_type_constant_result(:eq, bound, value), do: bound == value
  defp entity_type_constant_result(:neq, bound, value), do: bound != value
  defp entity_type_constant_result(:in, bound, values), do: bound in values
  defp entity_type_constant_result(:not_in, bound, values), do: bound not in values
  defp entity_type_constant_result(:contains, bound, value), do: String.contains?(bound, value)

  defp entity_type_constant_result(:starts_with, bound, value),
    do: String.starts_with?(bound, value)

  defp entity_type_constant_result(:is_null, _bound, _value), do: false
  defp entity_type_constant_result(:is_not_null, _bound, _value), do: true

  # -- JSONB-field dynamics (design §5.2) -- one compile-time-fixed
  # fragment literal per field_type(), selected by pattern match, never
  # assembled at runtime. `r.field_values` and `^field_name` are the two
  # `fragment/1` placeholders; `^value` (or `^values` for :in/:not_in) is a
  # further, separate bound parameter appended after the cast.

  @string_fragment "?->>?"
  @integer_fragment "(?->>?)::bigint"
  @decimal_fragment "(?->>?)::numeric"
  @boolean_fragment "(?->>?)::boolean"
  @date_fragment "(?->>?)::date"
  @datetime_fragment "(?->>?)::timestamp"

  # Each clause below has its own distinct, compile-time-literal first
  # `fragment/1` argument (a `@module_attribute`, never a variable holding
  # one) -- the technique this module's moduledoc states.
  defp json_cast_dynamic(:string, field_name),
    do: dynamic([r], fragment(@string_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:enum, field_name),
    do: dynamic([r], fragment(@string_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:integer, field_name),
    do: dynamic([r], fragment(@integer_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:decimal, field_name),
    do: dynamic([r], fragment(@decimal_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:boolean, field_name),
    do: dynamic([r], fragment(@boolean_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:date, field_name),
    do: dynamic([r], fragment(@date_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:datetime, field_name),
    do: dynamic([r], fragment(@datetime_fragment, r.field_values, ^field_name))

  defp json_field_dynamic(:eq, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast == ^value)
  end

  defp json_field_dynamic(:neq, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast != ^value)
  end

  defp json_field_dynamic(:gt, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast > ^value)
  end

  defp json_field_dynamic(:gte, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast >= ^value)
  end

  defp json_field_dynamic(:lt, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast < ^value)
  end

  defp json_field_dynamic(:lte, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast <= ^value)
  end

  defp json_field_dynamic(:in, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast in ^value)
  end

  defp json_field_dynamic(:not_in, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast not in ^value)
  end

  defp json_field_dynamic(:contains, _type, field_name, value) do
    cast = json_cast_dynamic(:string, field_name)
    pattern = "%" <> value <> "%"
    dynamic([r], ilike(^cast, ^pattern))
  end

  defp json_field_dynamic(:starts_with, _type, field_name, value) do
    cast = json_cast_dynamic(:string, field_name)
    pattern = value <> "%"
    dynamic([r], ilike(^cast, ^pattern))
  end

  defp json_field_dynamic(:is_null, type, field_name, _value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], is_nil(^cast))
  end

  defp json_field_dynamic(:is_not_null, type, field_name, _value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], not is_nil(^cast))
  end

  # ---------------------------------------------------------------------------------
  # §5.5 -- build_order_by/3.
  # ---------------------------------------------------------------------------------

  @doc """
  Builds one `{sort_dir(), Ecto.Query.dynamic_expr()}` order-by term for one
  already-resolved sort clause (design §5.5, extended by REQ-300 design
  §3.4), or `:drop` for a per-type-table-bound `"entity_type"` sort (every
  row shares the same value; ordering by it contributes nothing).
  """
  @spec build_order_by(Types.sort_clause(), Allowlist.allowlisted_field(), binding_ctx()) ::
          {Types.sort_dir(), Ecto.Query.dynamic_expr()} | :drop
  def build_order_by(
        %{},
        %{source: :typed_column, name: "entity_type"},
        %{source: {:per_type_table, _}}
      ) do
    :drop
  end

  def build_order_by(%{dir: dir}, %{source: :typed_column, name: field_name}, _ctx) do
    case Map.fetch(Allowlist.typed_columns(), field_name) do
      {:ok, {column_atom, _type}} ->
        {dir, dynamic([r], field(r, ^column_atom))}

      :error ->
        {dir, dynamic([r], fragment("?", literal(^field_name)))}
    end
  end

  def build_order_by(%{dir: dir}, %{source: :json_field, type: type, name: field_name}, _ctx) do
    {dir, json_cast_dynamic(type, field_name)}
  end

  # ═══════════════════════════════════════════════════════════════════════
  # REQ-315 -- compile_aggregate/2, per
  # lib/letflow/design/req312-query-aggregation.md §1/§2/§4. A NEW function
  # alongside compile/2, not a fourth branch of it -- compile/2 itself and
  # its two existing private helpers (compile_plain/5, compile_joined/6)
  # above this line are byte-for-byte unchanged by this section.
  #
  # Reuses check_join_shape/1, Allowlist.load/2, resolve_binding_source/2,
  # resolve_joins/4, build_all_filter_dynamics/3, binding_ctx/2, combine_filters/1
  # and add_all_hops/2 UNMODIFIED -- every one of them is defined above this
  # section, none is touched. Adds exactly two new resolution steps
  # (resolve_group_by_specs/2, resolve_aggregate_specs/2) and a
  # group_by/select-building step in place of apply_order_bys/2 -- design §2.
  # ═══════════════════════════════════════════════════════════════════════

  @typedoc "The closed enum of supported aggregate functions (design §1)."
  @type aggregate_fn :: :count | :sum | :avg | :min | :max

  @typedoc """
  One aggregate target in an `aggregate_request()` (design §1). `field` is
  required for `:sum`/`:avg`/`:min`/`:max`, forbidden for `:count`.
  """
  @type aggregate_target :: %{
          required(:fn) => aggregate_fn(),
          optional(:field) => String.t()
        }

  @typedoc "One group-by target in an `aggregate_request()` (design §1)."
  @type group_by_clause :: %{required(:field) => String.t()}

  @typedoc """
  The full aggregate request shape (design §1) -- additive, not a mutation
  of `Types.query_request()`. `aggregates` is required and non-empty
  (enforced by the caller, e.g. `Letflow.Routers.Entities`'s own request
  parser, before this request map is ever built).
  """
  @type aggregate_request :: %{
          required(:entity_type) => String.t(),
          required(:aggregates) => [aggregate_target(), ...],
          optional(:group_by) => [group_by_clause()],
          optional(:filters) => [Types.filter_clause()],
          optional(:join) => [Types.join_clause()]
        }

  @typedoc "compile_aggregate/2's error union (design §2) -- compile_error() plus three aggregate-specific members with no row-query analogue."
  @type aggregate_compile_error ::
          compile_error()
          | {:error, {:aggregate_field_required, aggregate_fn()}}
          | {:error, {:aggregate_field_not_allowed, aggregate_fn()}}
          | {:error, {:aggregate_type_not_valid, aggregate_fn(), Definition.field_type()}}

  @doc """
  Compiles `request` into a parameterised, not-yet-executed `Ecto.Query.t()`
  producing one row per distinct `group_by` combination (or exactly one row
  absent `group_by`), scoped to the tenant schema named by `prefix` (design
  §1/§2). The caller is responsible for the §4 INV-2 field-restriction check
  (every `aggregates`/`group_by`/`filters` field against
  `Letflow.Entities.Query.FieldGrants.load_restrictions/3`) BEFORE calling
  this function -- this function itself performs no such check, mirroring
  `compile/2`'s own "resolution only, no grant-awareness" scope.
  """
  @spec compile_aggregate(aggregate_request(), prefix :: String.t()) ::
          {:ok, Ecto.Query.t()} | aggregate_compile_error()
  def compile_aggregate(%{entity_type: entity_type, aggregates: aggregates} = request, prefix)
      when is_binary(entity_type) and is_binary(prefix) and is_list(aggregates) do
    filters = Map.get(request, :filters, [])
    group_by = Map.get(request, :group_by, [])
    joins = Map.get(request, :join, [])

    with :ok <- check_join_shape(joins),
         {:ok, allowlist} <- Allowlist.load(entity_type, prefix),
         {:ok, primary_source0} <- resolve_binding_source(entity_type, prefix),
         {:ok, prepared_joins, primary_source} <-
           resolve_joins(joins, entity_type, primary_source0, prefix) do
      ctx = binding_ctx(primary_source, entity_type)

      with {:ok, filter_dynamics} <- build_all_filter_dynamics(filters, allowlist, ctx),
           {:ok, group_by_specs} <- resolve_group_by_specs(group_by, allowlist),
           {:ok, aggregate_specs} <- resolve_aggregate_specs(aggregates, allowlist) do
        combined = combine_filters(filter_dynamics)

        base =
          if prepared_joins == [] do
            aggregate_base_plain(entity_type, primary_source, combined)
          else
            aggregate_base_joined(entity_type, primary_source, prepared_joins, combined)
          end

        query =
          base
          |> apply_group_by(group_by_specs)
          |> apply_aggregate_select(group_by_specs, aggregate_specs)

        {:ok, query}
      end
    end
  end

  @doc """
  Compiles `request` per `compile_aggregate/2` and executes it, scoped to the
  tenant schema named by `prefix` -- the one place in this module that calls
  `Repo.*` to *execute* a query it built (design §4: an aggregate result has
  no `Cursor`-shaped execution wrapper, unlike `compile/2`'s row-query path).
  Added so `Letflow.Routers.Entities` -- whose own moduledoc states "router
  composes existing context/query-module calls, never executes its own SQL"
  -- has a context-module call to compose here too, instead of calling
  `Repo.all/2` itself (SECURITY-REVIEWER structural finding, REQ-315).
  """
  @spec run_aggregate(aggregate_request(), prefix :: String.t()) ::
          {:ok, [map()]} | aggregate_compile_error()
  def run_aggregate(request, prefix) do
    with {:ok, query} <- compile_aggregate(request, prefix) do
      {:ok, Repo.all(query, prefix: prefix)}
    end
  end

  defp aggregate_base_plain(entity_type, primary_source, combined) do
    case primary_source do
      :latest ->
        Latest
        |> where([r], r.entity_type == ^entity_type)
        |> where([r], ^combined)

      {:per_type_table, table_name} ->
        table_name
        |> from()
        |> where([r], ^combined)
    end
  end

  defp aggregate_base_joined(entity_type, primary_source, prepared_joins, combined) do
    base =
      case primary_source do
        :latest -> from(r in Latest, as: :primary) |> where([r], r.entity_type == ^entity_type)
        {:per_type_table, table_name} -> from(r in table_name, as: :primary)
      end

    base
    |> where([r], ^combined)
    |> add_all_hops(prepared_joins)
  end

  # -- group_by resolution (design §1: Allowlist.resolve_field/2, the SAME
  # call build_one_filter_dynamic/3 already makes for a filter_clause().field).

  # ⛔ `group_dyn` (raw field reference, used ONLY in the group_by/3 clause)
  # and `dyn` (the SAME field reference wrapped in `max/1`, used ONLY in the
  # select map built below) are DELIBERATELY two independently-parameterised
  # copies, not one dynamic reused twice. Postgres's GROUP BY functional-
  # dependency check compares the SELECT list's expressions against the
  # GROUP BY list's expressions SYNTACTICALLY, on the parse tree, BEFORE any
  # bound parameter is substituted -- two `^field_name`-parameterised copies
  # of the identical Elixir string bind to two DIFFERENT positional
  # placeholders ($1 vs $3, say) once spliced into two separate query-macro
  # calls (`group_by/3` here, `select/3`/`select_merge/3` in
  # `apply_aggregate_select/3`), so Postgres cannot see them as "the same
  # expression" and rejects a bare (non-aggregated) repeat of the GROUP BY
  # key in SELECT with `ERROR 42803 grouping_error`. Wrapping the SELECT
  # copy in `max/1` (reused from the exact `Ecto.Query.API.max/1` this
  # module already applies to the `:max` aggregate target above) sidesteps
  # the check entirely -- any aggregate-wrapped expression is always valid
  # in SELECT regardless of GROUP BY, and every row within one group shares
  # the same value for its own grouping key by definition, so `max/1` here
  # is a no-op pass-through, not a real reduction.
  defp resolve_group_by_specs(group_by, allowlist) do
    Enum.reduce_while(group_by, {:ok, []}, fn clause, {:ok, acc} ->
      case Allowlist.resolve_field(allowlist, clause.field) do
        {:ok, allowlisted_field} ->
          spec = %{
            key: "group__" <> clause.field,
            group_dyn: field_value_dynamic(allowlisted_field),
            dyn: dynamic([r], max(^field_value_dynamic(allowlisted_field)))
          }

          {:cont, {:ok, [spec | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      {:error, _reason} = error -> error
    end
  end

  # -- aggregate-target resolution (design §1/§2's arity + field-type checks,
  # then Allowlist.resolve_field/2 for a field-carrying target).

  defp resolve_aggregate_specs(aggregates, allowlist) do
    Enum.reduce_while(aggregates, {:ok, []}, fn target, {:ok, acc} ->
      case build_aggregate_spec(target, allowlist) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      {:error, _reason} = error -> error
    end
  end

  defp build_aggregate_spec(%{fn: :count} = target, _allowlist) do
    if Map.has_key?(target, :field) do
      {:error, {:aggregate_field_not_allowed, :count}}
    else
      {:ok, %{key: "agg__count_none", dyn: dynamic([r], count(field(r, :record_id)))}}
    end
  end

  defp build_aggregate_spec(%{fn: fn_} = target, allowlist)
       when fn_ in [:sum, :avg, :min, :max] do
    case Map.fetch(target, :field) do
      :error ->
        {:error, {:aggregate_field_required, fn_}}

      {:ok, field_name} ->
        with {:ok, allowlisted_field} <- Allowlist.resolve_field(allowlist, field_name),
             :ok <- check_aggregate_field_type(fn_, allowlisted_field.type) do
          value_dyn = field_value_dynamic(allowlisted_field)
          {:ok, %{key: "agg__#{fn_}_#{field_name}", dyn: aggregate_fn_dynamic(fn_, value_dyn)}}
        end
    end
  end

  defp check_aggregate_field_type(fn_, type) when fn_ in [:sum, :avg] do
    if type in [:integer, :decimal] do
      :ok
    else
      {:error, {:aggregate_type_not_valid, fn_, type}}
    end
  end

  defp check_aggregate_field_type(fn_, type) when fn_ in [:min, :max] do
    if type in [:string, :integer, :decimal, :date, :datetime] do
      :ok
    else
      {:error, {:aggregate_type_not_valid, fn_, type}}
    end
  end

  defp aggregate_fn_dynamic(:sum, value_dyn), do: dynamic([r], sum(^value_dyn))
  defp aggregate_fn_dynamic(:avg, value_dyn), do: dynamic([r], avg(^value_dyn))
  defp aggregate_fn_dynamic(:min, value_dyn), do: dynamic([r], min(^value_dyn))
  defp aggregate_fn_dynamic(:max, value_dyn), do: dynamic([r], max(^value_dyn))

  # -- the SAME two existing field-reference idioms compile/2's own
  # filter/sort building already uses (design §4's INV-7 section): a fixed-7
  # typed column via `field(r, ^column_atom)` (`column_atom` sourced only
  # from `Allowlist.typed_columns/0`'s closed table), a promoted/non-fixed-7
  # typed column via `fragment("?", literal(^field_name))`
  # (`promoted_column_dynamic/3`'s own idiom), and -- for a JSON field -- the
  # existing typed `json_cast_dynamic/2`, the same cast `build_filter_dynamic/3`'s
  # `:json_field` clause already applies. No new fragment-building primitive.
  defp field_value_dynamic(%{source: :typed_column, name: field_name}) do
    case Map.fetch(Allowlist.typed_columns(), field_name) do
      {:ok, {column_atom, _type}} -> dynamic([r], field(r, ^column_atom))
      :error -> dynamic([r], fragment("?", literal(^field_name)))
    end
  end

  defp field_value_dynamic(%{source: :json_field, type: type, name: field_name}) do
    json_cast_dynamic(type, field_name)
  end

  # -- group_by clause (Ecto.Query.group_by/3, the same `^list-of-dynamics`
  # idiom apply_order_bys/2 already uses for order_by/3).

  defp apply_group_by(query, []), do: query

  defp apply_group_by(query, group_by_specs) do
    group_by(query, [r], ^Enum.map(group_by_specs, & &1.group_dyn))
  end

  # -- select clause (design §5): a FLAT map, one key per group_by/aggregate
  # target, prefixed "group__"/"agg__" so the two namespaces can never
  # collide -- reshaped into the {"group": _, "values": _} response shape by
  # the caller (Letflow.Routers.Entities), never by this module (design §5
  # states the response envelope is the router's job, not Compiler's). Built
  # via select/3 then one select_merge/3 per remaining spec -- the same
  # "one select, then select_merge in a loop" idiom add_join_selects/2
  # already uses, each call's own map literal carrying exactly one
  # `^`-interpolated key (design's own ⛔ note on dynamic-expression
  # interpolation: only ever ONE fully-built dynamic per select/select_merge
  # call, never several spliced into one bare map literal).
  defp apply_aggregate_select(query, group_by_specs, aggregate_specs) do
    case group_by_specs ++ aggregate_specs do
      [first | rest] ->
        query
        |> select([r], ^one_key_select_dynamic(first))
        |> then(fn q ->
          Enum.reduce(rest, q, fn spec, acc ->
            select_merge(acc, [r], ^one_key_select_dynamic(spec))
          end)
        end)
    end
  end

  defp one_key_select_dynamic(%{key: key, dyn: value_dyn}) do
    dynamic([r], %{^key => ^value_dyn})
  end

  # ---------------------------------------------------------------------------------
  # Private: per-clause pipeline + fold/assemble (design §5.1 steps 2-5).
  # ---------------------------------------------------------------------------------

  @typep binding_ctx :: %{source: binding_source(), entity_type: String.t()}

  defp binding_ctx(primary_source, entity_type),
    do: %{source: primary_source, entity_type: entity_type}

  defp build_all_filter_dynamics(filters, allowlist, ctx) do
    Enum.reduce_while(filters, {:ok, []}, fn clause, {:ok, acc} ->
      case build_one_filter_dynamic(clause, allowlist, ctx) do
        {:ok, dyn} -> {:cont, {:ok, [dyn | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, dyns} -> {:ok, Enum.reverse(dyns)}
      {:error, _reason} = error -> error
    end
  end

  defp build_one_filter_dynamic(%{field: field_name, op: op} = clause, allowlist, ctx) do
    value_present? = Map.has_key?(clause, :value)

    with :ok <- check_value_arity(op, value_present?),
         {:ok, allowlisted_field} <- Allowlist.resolve_field(allowlist, field_name),
         :ok <- check_operator_field_type(op, allowlisted_field.type) do
      build_filter_dynamic(clause, allowlisted_field, ctx)
    end
  end

  defp build_all_order_bys(sorts, allowlist, ctx) do
    Enum.reduce_while(sorts, {:ok, []}, fn clause, {:ok, acc} ->
      case Allowlist.resolve_field(allowlist, clause.field) do
        {:ok, allowlisted_field} ->
          {:cont, {:ok, [build_order_by(clause, allowlisted_field, ctx) | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, terms |> Enum.reverse() |> Enum.reject(&(&1 == :drop))}
      {:error, _reason} = error -> error
    end
  end

  # Design §5.1 step 3: starting from a `true` identity value, fold every
  # clause's dynamic left-to-right, ANDing each successive fragment onto the
  # accumulator -- implicit AND across all filter clauses.
  defp combine_filters(dynamics) do
    Enum.reduce(dynamics, dynamic(true), fn clause_dynamic, acc ->
      dynamic(^acc and ^clause_dynamic)
    end)
  end

  defp apply_order_bys(query, []), do: query

  defp apply_order_bys(query, order_bys) do
    order_by(query, [r], ^Enum.map(order_bys, fn {dir, dyn} -> {dir, dyn} end))
  end

  # ---------------------------------------------------------------------------------
  # REQ-300 design §3.3 -- the plain (non-join) compile path. The `:latest`
  # branch is the CURRENT compile/2 body, unchanged, byte for byte -- this
  # is the hard non-regression requirement rework cycle 1 exists to protect.
  # ---------------------------------------------------------------------------------

  defp compile_plain(entity_type, allowlist, primary_source, filters, sorts) do
    ctx = binding_ctx(primary_source, entity_type)

    with {:ok, filter_dynamics} <- build_all_filter_dynamics(filters, allowlist, ctx),
         {:ok, order_bys} <- build_all_order_bys(sorts, allowlist, ctx) do
      combined = combine_filters(filter_dynamics)

      query =
        case primary_source do
          :latest ->
            Latest
            |> where([r], r.entity_type == ^entity_type)
            |> where([r], ^combined)
            |> apply_order_bys(order_bys)

          {:per_type_table, table_name} ->
            table_name
            |> from()
            |> where([r], ^combined)
            |> apply_order_bys(order_bys)
            |> select_entity_row()
        end

      {:ok, query}
    end
  end

  # `record_id` is wrapped in `type/2` because this query runs against a
  # SCHEMALESS `from(table_name)` binding (a per-type promoted table) --
  # with no `Ecto.Schema` field declaration to tell Ecto the column is a
  # uuid, the raw Postgrex driver value (a 16-byte binary) would otherwise
  # come back unloaded, contradicting this module's own `entity_row()`
  # type (`record_id: String.t()`). `type(field(r, :record_id), Ecto.UUID)`
  # tells Ecto the column's real type so it loads/casts it exactly the way
  # a real `field(:record_id, Ecto.UUID)` schema declaration would --
  # matching what `entity_record_latest`'s `Latest` schema gets for free.
  defp select_entity_row(query) do
    select(query, [r], %{
      record_id: type(field(r, :record_id), Ecto.UUID),
      field_values: field(r, :field_values),
      deleted: field(r, :deleted),
      entity_def_version: field(r, :entity_def_version),
      last_event_global_seq: field(r, :last_event_global_seq),
      inserted_at: field(r, :inserted_at),
      updated_at: field(r, :updated_at)
    })
  end

  # ---------------------------------------------------------------------------------
  # REQ-300 design §3-5 -- the joined compile path.
  # ---------------------------------------------------------------------------------

  defp compile_joined(entity_type, allowlist, primary_source, prepared_joins, filters, sorts) do
    ctx = binding_ctx(primary_source, entity_type)

    with {:ok, filter_dynamics} <- build_all_filter_dynamics(filters, allowlist, ctx),
         {:ok, order_bys} <- build_all_order_bys(sorts, allowlist, ctx) do
      combined = combine_filters(filter_dynamics)

      base =
        case primary_source do
          :latest ->
            from(r in Latest, as: :primary) |> where([r], r.entity_type == ^entity_type)

          {:per_type_table, table_name} ->
            from(r in table_name, as: :primary)
        end

      query =
        base
        |> where([r], ^combined)
        |> apply_order_bys(order_bys)
        |> add_all_hops(prepared_joins)
        |> apply_joined_select(prepared_joins)

      {:ok, query}
    end
  end

  defp add_all_hops(query, prepared_joins) do
    Enum.reduce(prepared_joins, query, fn pj, acc ->
      Enum.reduce(pj.hops, acc, fn hop, acc2 -> add_hop_join(acc2, hop, pj.join_type) end)
    end)
  end

  defp add_hop_join(query, hop, join_type) do
    on_dyn = hop_on_dynamic(hop)

    case hop.to_source do
      :latest ->
        join(query, join_type, [], t in Latest, as: ^hop.to_alias, on: ^on_dyn)

      {:per_type_table, table_name} ->
        join(query, join_type, [], t in ^{table_name, nil}, as: ^hop.to_alias, on: ^on_dyn)
    end
  end

  # Both sides referenced exclusively via `as(^alias)` -- position-independent,
  # so hops can be added in a loop without tracking binding indices. The
  # fk-column side is always the promoted-name fragment path (design §4,
  # "ON condition: joined table's <fk column> (promoted-name path, §3.4)")
  # -- an fk_def().field is never one of the fixed 7 in any of this
  # requirement's worked examples.
  #
  # REQ-324 (S10 gap 14, open question 4): the fk-column side used to be
  # `fragment("?", literal(^fk_field))` -- Ecto's `literal/1` fragment
  # helper, which quotes a runtime string as a SQL identifier but never
  # qualifies it with a table/binding prefix. That was unambiguous for
  # every non-self join this design was originally built against (each
  # hop's two sides are always two DIFFERENT physical tables, so Postgres
  # resolves the bare column name with no qualifier needed), but a
  # self-referential fk_def joins the SAME physical table to itself under
  # two different Ecto bindings (`:primary` and a `@join_alias_pool`
  # alias) -- both bindings carry a column of that name, and the
  # unqualified fragment raised Postgres `ambiguous_column` (confirmed
  # empirically against a self-join before this fix: see
  # `test/letflow/entities/query_self_join_test.exs`).
  #
  # Fixed by using `field(as(^alias), ^fk_field)` instead of the bare
  # fragment. Ecto's `field/2` accepts a runtime STRING (not just an
  # atom) as its column-name argument when the source is a named binding
  # (`as(^alias)`) -- `Ecto.Query.Builder.atom_or_string!/2` (the runtime
  # check Ecto's own macro expansion compiles `field(as(^b), ^x)` down to)
  # returns a binary unchanged, never converting it to an atom. This is
  # exactly this module's own existing invariant restated elsewhere in this
  # file ("`column_atom` sourced only from `Allowlist.typed_columns/0`'s
  # own fixed, closed table -- never `String.to_atom/1` on caller input");
  # `field/2`'s string form gets us a properly alias-qualified,
  # injection-safe reference (the SQL adapter quotes it the same way
  # `literal/1` did) with zero new atoms created and zero reliance on
  # guessing Ecto's internally-generated positional alias text (`e0`,
  # `e1`, ...), which is NOT the same string as the `as:` binding name and
  # cannot be reproduced from outside Ecto's own query-compilation step.
  defp hop_on_dynamic(%{
         from_alias: from_alias,
         from_source: from_source,
         from_entity_type: from_entity_type,
         to_alias: to_alias,
         to_source: to_source,
         to_entity_type: to_entity_type,
         from_owns_fk: from_owns_fk,
         fk_field: fk_field
       }) do
    eq =
      if from_owns_fk do
        dynamic([], field(as(^from_alias), ^fk_field) == field(as(^to_alias), :record_id))
      else
        dynamic([], field(as(^from_alias), :record_id) == field(as(^to_alias), ^fk_field))
      end

    eq
    |> scope_to_entity_type(from_source, from_alias, from_entity_type)
    |> scope_to_entity_type(to_source, to_alias, to_entity_type)
  end

  defp scope_to_entity_type(dyn, :latest, alias_atom, entity_type) do
    dynamic([], ^dyn and field(as(^alias_atom), :entity_type) == ^entity_type)
  end

  defp scope_to_entity_type(dyn, {:per_type_table, _}, _alias_atom, _entity_type), do: dyn

  # A `^dynamic()`-built expression can only be interpolated at the TOP
  # LEVEL of `select`/`select_merge` -- not nested as one value inside a
  # plain map literal (Ecto: "dynamic expressions can only be interpolated
  # at the top level of ... select ..."). So each select/select_merge below
  # interpolates exactly ONE fully-built dynamic map, rather than a plain
  # map literal containing a nested `^dynamic(...)` per key.
  defp apply_joined_select(query, prepared_joins) do
    query
    |> select([], ^primary_entity_row_select_dynamic())
    |> add_join_selects(prepared_joins)
  end

  defp add_join_selects(query, prepared_joins) do
    Enum.reduce(prepared_joins, query, fn pj, acc ->
      alias_atom = pj.hops |> List.last() |> Map.fetch!(:to_alias)
      exposed_key = pj.exposed_key

      select_merge(acc, [], ^joined_entity_row_select_dynamic(exposed_key, alias_atom))
    end)
  end

  # Same `type/2` reasoning as `select_entity_row/1` above -- a joined
  # binding can equally be a schemaless per-type-table source, so
  # `record_id` is always wrapped regardless of which physical table this
  # particular binding turns out to read from.
  defp primary_entity_row_select_dynamic do
    dynamic([], %{
      primary: %{
        record_id: type(field(as(:primary), :record_id), Ecto.UUID),
        field_values: field(as(:primary), :field_values),
        deleted: field(as(:primary), :deleted),
        entity_def_version: field(as(:primary), :entity_def_version),
        last_event_global_seq: field(as(:primary), :last_event_global_seq),
        inserted_at: field(as(:primary), :inserted_at),
        updated_at: field(as(:primary), :updated_at)
      }
    })
  end

  defp joined_entity_row_select_dynamic(exposed_key, alias_atom) do
    dynamic([], %{
      ^exposed_key => %{
        record_id: type(field(as(^alias_atom), :record_id), Ecto.UUID),
        field_values: field(as(^alias_atom), :field_values),
        deleted: field(as(^alias_atom), :deleted),
        entity_def_version: field(as(^alias_atom), :entity_def_version),
        last_event_global_seq: field(as(^alias_atom), :last_event_global_seq),
        inserted_at: field(as(^alias_atom), :inserted_at),
        updated_at: field(as(^alias_atom), :updated_at)
      }
    })
  end

  # ---------------------------------------------------------------------------------
  # REQ-300 design §5 -- width/depth bounds, checked before any relation is
  # resolved (fail fast, no database touched for an over-wide/over-deep
  # request).
  # ---------------------------------------------------------------------------------

  defp check_join_shape(joins) do
    cond do
      length(joins) > @max_joins ->
        {:error, {:too_many_joins, length(joins)}}

      Enum.any?(joins, &Map.has_key?(&1, :join)) ->
        {:error, :join_depth_exceeded}

      true ->
        entity_types = Enum.map(joins, &Map.fetch!(&1, :entity_type))

        case entity_types -- Enum.uniq(entity_types) do
          [dup | _] -> {:error, {:duplicate_join_target, dup}}
          [] -> :ok
        end
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-300 design §4 -- join resolution. Two passes: (1) resolve every
  # relation (fk_defs-based, purely definition-derived, no DB touched yet),
  # from which we learn whether the primary itself is any resolved
  # relation's declaring side (forcing primary_source to a per-type table
  # for the WHOLE query, design §4.0.1); (2) finalize every hop against
  # that single, consistent primary_source -- each hop independently
  # asserting/checking its own declaring side's table+column existence
  # (design §4.0.1/§4.0.2).
  # ---------------------------------------------------------------------------------

  defp resolve_joins([], _primary_entity_type, primary_source0, _prefix),
    do: {:ok, [], primary_source0}

  defp resolve_joins(joins, primary_entity_type, primary_source0, prefix) do
    indexed = Enum.with_index(joins)

    with {:ok, raw} <- resolve_all_raw_relations(indexed, primary_entity_type, prefix),
         {:ok, final_primary_source} <-
           resolve_final_primary_source(raw, primary_entity_type, primary_source0, prefix),
         {:ok, prepared} <-
           finalize_all_hops(raw, primary_entity_type, final_primary_source, prefix) do
      {:ok, prepared, final_primary_source}
    end
  end

  defp resolve_all_raw_relations(indexed, primary_entity_type, prefix) do
    Enum.reduce_while(indexed, {:ok, []}, fn {join_clause, idx}, {:ok, acc} ->
      case resolve_raw_one(join_clause, idx, primary_entity_type, prefix) do
        {:ok, raw} -> {:cont, {:ok, [raw | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_raw_one(
         %{through: through, entity_type: far_entity_type} = jc,
         idx,
         primary_entity_type,
         prefix
       )
       when is_binary(through) do
    fk_name = Map.fetch!(jc, :fk)
    join_type = Map.get(jc, :type, :inner)
    join_alias = Enum.at(@join_alias_pool, idx)
    through_alias = Enum.at(@through_alias_pool, idx)

    with {:ok, near_rel} <- resolve_through_near_hop(through, primary_entity_type, prefix),
         {:ok, far_rel} <- resolve_named_relation(through, far_entity_type, fk_name, prefix) do
      {:ok,
       %{
         kind: :through,
         exposed_key: far_entity_type,
         join_type: join_type,
         through_entity_type: through,
         through_alias: through_alias,
         far_entity_type: far_entity_type,
         join_alias: join_alias,
         near_rel: near_rel,
         far_rel: far_rel
       }}
    end
  end

  defp resolve_raw_one(%{entity_type: target_entity_type} = jc, idx, primary_entity_type, prefix) do
    fk_name = Map.fetch!(jc, :fk)
    join_type = Map.get(jc, :type, :inner)
    join_alias = Enum.at(@join_alias_pool, idx)

    with {:ok, rel} <-
           resolve_named_relation(primary_entity_type, target_entity_type, fk_name, prefix) do
      {:ok,
       %{
         kind: :direct,
         exposed_key: target_entity_type,
         join_type: join_type,
         target_entity_type: target_entity_type,
         join_alias: join_alias,
         rel: rel
       }}
    end
  end

  # REQ-300 design §4 -- the single primitive resolving which side owns the
  # fk_def for a relation between entity_a/entity_b, named by fk_name.
  # Reused for a direct join and for a through join's far hop.
  defp resolve_named_relation(entity_a, entity_b, fk_name, prefix) do
    with {:ok, fk_defs_a} <- Allowlist.fk_defs(entity_a, prefix) do
      case Enum.find(fk_defs_a, &(&1.name == fk_name and &1.references_entity == entity_b)) do
        %{} = fk ->
          {:ok, %{owner_entity_type: entity_a, other_entity_type: entity_b, fk_field: fk.field}}

        nil ->
          with {:ok, fk_defs_b} <- Allowlist.fk_defs(entity_b, prefix) do
            case Enum.find(fk_defs_b, &(&1.name == fk_name and &1.references_entity == entity_a)) do
              %{} = fk ->
                {:ok,
                 %{owner_entity_type: entity_b, other_entity_type: entity_a, fk_field: fk.field}}

              nil ->
                {:error, {:field_not_allowed, fk_name}}
            end
          end
      end
    end
  end

  # REQ-300 design §4 -- the through join's near hop: the join entity is
  # expected to own exactly one fk_def referencing the primary; found
  # without the caller having to name it.
  defp resolve_through_near_hop(through, primary_entity_type, prefix) do
    with {:ok, fk_defs} <- Allowlist.fk_defs(through, prefix) do
      case Enum.filter(fk_defs, &(&1.references_entity == primary_entity_type)) do
        [fk] ->
          {:ok,
           %{
             owner_entity_type: through,
             other_entity_type: primary_entity_type,
             fk_field: fk.field
           }}

        [] ->
          {:error, {:no_through_relation, through, primary_entity_type}}

        [_ | _] ->
          {:error, {:ambiguous_through_relation, through}}
      end
    end
  end

  defp resolve_final_primary_source(raw, primary_entity_type, primary_source0, prefix) do
    forces_primary? =
      Enum.any?(raw, fn
        %{kind: :direct, rel: rel} ->
          rel.owner_entity_type == primary_entity_type

        %{kind: :through, near_rel: near, far_rel: far} ->
          near.owner_entity_type == primary_entity_type or
            far.owner_entity_type == primary_entity_type
      end)

    if forces_primary? do
      assert_per_type_table(resolve_binding_source(primary_entity_type, prefix))
    else
      {:ok, primary_source0}
    end
  end

  defp assert_per_type_table({:ok, {:per_type_table, _} = ts}), do: {:ok, ts}
  defp assert_per_type_table({:ok, :latest}), do: {:error, :entity_table_not_found}
  defp assert_per_type_table({:error, _reason} = error), do: error

  defp finalize_all_hops(raw, primary_entity_type, final_primary_source, prefix) do
    Enum.reduce_while(raw, {:ok, []}, fn r, {:ok, acc} ->
      case finalize_raw(r, primary_entity_type, final_primary_source, prefix) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp finalize_raw(%{kind: :direct} = r, primary_entity_type, final_primary_source, prefix) do
    with {:ok, hop} <-
           finalize_hop(
             r.rel,
             primary_entity_type,
             :primary,
             r.target_entity_type,
             r.join_alias,
             primary_entity_type,
             final_primary_source,
             prefix
           ) do
      {:ok, %{exposed_key: r.exposed_key, join_type: r.join_type, hops: [hop]}}
    end
  end

  defp finalize_raw(%{kind: :through} = r, primary_entity_type, final_primary_source, prefix) do
    with {:ok, near_hop} <-
           finalize_hop(
             r.near_rel,
             primary_entity_type,
             :primary,
             r.through_entity_type,
             r.through_alias,
             primary_entity_type,
             final_primary_source,
             prefix
           ),
         {:ok, far_hop} <-
           finalize_hop(
             r.far_rel,
             r.through_entity_type,
             r.through_alias,
             r.far_entity_type,
             r.join_alias,
             primary_entity_type,
             final_primary_source,
             prefix
           ) do
      {:ok, %{exposed_key: r.exposed_key, join_type: r.join_type, hops: [near_hop, far_hop]}}
    end
  end

  # REQ-300 design §4.0.1/§4.0.2 -- the per-relation binding-source rule
  # plus the per-column existence check, applied uniformly whether this hop
  # is a direct join, a through near hop, or a through far hop: whichever
  # side owns the fk_def MUST be sourced from its own per-type table (a
  # table-level check), and that side's specific fk column MUST physically
  # exist on that table (a column-level check) -- both before this hop's ON
  # condition is ever built.
  defp finalize_hop(
         rel,
         from_entity_type,
         from_alias,
         to_entity_type,
         to_alias,
         primary_entity_type,
         final_primary_source,
         prefix
       ) do
    from_owns_fk = rel.owner_entity_type == from_entity_type
    declaring_entity_type = rel.owner_entity_type
    fk_field = rel.fk_field

    with {:ok, _declaring_table} <-
           assert_declaring_table(
             declaring_entity_type,
             primary_entity_type,
             final_primary_source,
             prefix,
             fk_field
           ),
         {:ok, from_source} <-
           binding_source_for(from_entity_type, primary_entity_type, final_primary_source, prefix),
         {:ok, to_source} <-
           binding_source_for(to_entity_type, primary_entity_type, final_primary_source, prefix) do
      {:ok,
       %{
         from_alias: from_alias,
         from_source: from_source,
         from_entity_type: from_entity_type,
         to_alias: to_alias,
         to_source: to_source,
         to_entity_type: to_entity_type,
         from_owns_fk: from_owns_fk,
         fk_field: fk_field
       }}
    end
  end

  defp assert_declaring_table(
         entity_type,
         primary_entity_type,
         final_primary_source,
         prefix,
         fk_field
       ) do
    with {:ok, {:per_type_table, table_name}} <-
           assert_per_type_table(
             binding_source_for(entity_type, primary_entity_type, final_primary_source, prefix)
           ) do
      if relation_column_exists?(prefix, table_name, fk_field) do
        {:ok, table_name}
      else
        {:error, {:relation_column_not_found, entity_type, fk_field}}
      end
    end
  end

  defp binding_source_for(entity_type, primary_entity_type, final_primary_source, _prefix)
       when entity_type == primary_entity_type do
    {:ok, final_primary_source}
  end

  defp binding_source_for(entity_type, _primary_entity_type, _final_primary_source, prefix) do
    resolve_binding_source(entity_type, prefix)
  end
end
