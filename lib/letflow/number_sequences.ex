defmodule Letflow.NumberSequences do
  @moduledoc """
  Tenant-scoped number sequences bound to a record type (REQ-541, GH #3160).

  A definition (`create_definition/2`) gives one entity type a human number such as
  `ORD-2026-000042` (`<prefix>-<year>-<n padded>`) or `ORD-000042` (period `none`). The records
  pipeline (`Letflow.Entities.Records`) numbers a record of a bound type inside its create
  transaction, on every create path.

  ## Not the document allocator

  This is a new, small allocator. It follows the gap-free protocol of decision 0056 D2
  (insert-if-absent of the counter row, `SELECT ... FOR UPDATE`, then the increment, all in the
  caller's transaction) on its own tables. It neither reads nor writes the document sequence table and
  does not touch `lib/letflow/documents/`.

  ## Where the number lives

  Not in the record's `field_values`, the event payload or `entity_record_latest`: it is a row of
  `number_sequence_numbers` keyed by (entity type, record id), so no create or update payload can
  supply or change it. The create result carries it in the virtual field
  `Letflow.Entities.Record.Latest.record_number`; `number_for/3` and `numbers_for/3` read it.

  ## Period and zone

  `period_for/2` is the one place where the year boundary is computed, from the server clock in
  UTC (`now/0`; tests inject a clock through `:number_sequences_clock`). The project carries no
  time-zone database and decision 0056 open point 11 (the zone of a document period) is
  undecided; this follows whatever it decides, and changing the zone is a change of this one
  function. The first number after a year change is 1 (a new counter row); the previous year's
  row is not touched.

  ## Lock position (decision 0061)

  The counter row is item 5a of the lock order: it is only ever locked while the sequence row of
  its entity type (item 5) is held, and before the audit chain row (item 6). `lock_counter/3`
  takes it right after the type's sequence row in the type-lock step; `allocate/6` then increments
  the row that is already held. The step writes an empty counter row at most (insert-if-absent),
  no event, audit row or sequence number.

  ## Tenant scoping (INV-1, INV-6)

  Every Repo call carries the tenant `prefix`; `tenant_id` is derived from it and no function
  accepts a tenant identifier otherwise.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.NumberSequences.Counter
  alias Letflow.NumberSequences.Definition
  alias Letflow.NumberSequences.Number
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @definition_keys ~w(key entity_type prefix padding period)a

  @type allocation :: %{number: pos_integer(), formatted: String.t(), period: String.t()}

  @doc """
  Creates the definition binding `attrs.entity_type` to a number format.

  `attrs` keys: `key`, `entity_type`, `prefix` (1..8 letters or digits), `padding` (1..12) and
  `period` (`"year"` or `"none"`, atoms accepted). A `tenant_id` key is ignored: the tenant is the
  one of `schema_prefix`. A managed type answers `{:error, :entity_type_managed}`, an append-only
  type `{:error, {:entity_append_only, type}}`, an unknown one
  `{:error, {:entity_type_not_found, type}}`; an invalid or duplicate attribute answers
  `{:error, %Ecto.Changeset{}}`. Nothing is written on an error.
  """
  @spec create_definition(map(), schema_prefix :: String.t()) ::
          {:ok, Definition.t()} | {:error, term()}
  def create_definition(attrs, schema_prefix) when is_map(attrs) and is_binary(schema_prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(schema_prefix),
         {:ok, changeset} <- definition_changeset(attrs, tenant_id),
         :ok <- check_bindable(get_change(changeset, :entity_type), schema_prefix) do
      case Repo.insert(changeset, prefix: schema_prefix) do
        {:ok, definition} -> {:ok, definition}
        {:error, %Ecto.Changeset{} = invalid} -> {:error, invalid}
      end
    end
  end

  defp definition_changeset(attrs, tenant_id) do
    params =
      for key <- @definition_keys,
          value = fetch_attr(attrs, key),
          not is_nil(value),
          into: %{},
          do: {key, normalise(key, value)}

    changeset =
      %Definition{tenant_id: tenant_id}
      |> cast(params, @definition_keys)
      |> validate_required(@definition_keys)
      |> validate_length(:key, min: 1, max: 100)
      |> validate_format(:prefix, ~r/\A[A-Za-z0-9]{1,8}\z/)
      |> validate_number(:padding, greater_than_or_equal_to: 1, less_than_or_equal_to: 12)
      |> validate_inclusion(:period, ["year", "none"])
      |> unique_constraint(:key, name: :number_sequence_definitions_key_index)
      |> unique_constraint(:entity_type, name: :number_sequence_definitions_entity_type_index)

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp normalise(:period, value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalise(_key, value), do: value

  defp check_bindable(entity_type, schema_prefix) do
    case Definitions.get_active_definition_by_name(entity_type, schema_prefix) do
      {:ok, %EntityDefinition{managed_by: managed_by}} when not is_nil(managed_by) ->
        {:error, :entity_type_managed}

      {:ok, %EntityDefinition{definition_json: %{"append_only" => true}}} ->
        {:error, {:entity_append_only, entity_type}}

      {:ok, %EntityDefinition{}} ->
        :ok

      {:error, :not_found} ->
        {:error, {:entity_type_not_found, entity_type}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "The definition bound to `entity_type`, or `:none` (one indexed read)."
  @spec fetch_binding(String.t(), schema_prefix :: String.t(), module()) ::
          {:ok, Definition.t()} | :none
  def fetch_binding(entity_type, schema_prefix, repo \\ Repo)
      when is_binary(entity_type) and is_binary(schema_prefix) do
    case repo.one(from(d in Definition, where: d.entity_type == ^entity_type),
           prefix: schema_prefix
         ) do
      %Definition{} = definition -> {:ok, definition}
      nil -> :none
    end
  end

  @doc """
  The period key of a definition at the UTC instant `now`: `"none"` for period none, else the
  calendar year of `now` as text. The one named function of the year boundary.
  """
  @spec period_for(Definition.t(), DateTime.t()) :: String.t()
  def period_for(%Definition{period: "none"}, %DateTime{}), do: "none"
  def period_for(%Definition{period: "year"}, %DateTime{year: year}), do: Integer.to_string(year)

  @doc "`period_for/2` at the server clock."
  @spec current_period(Definition.t()) :: String.t()
  def current_period(%Definition{} = definition), do: period_for(definition, now())

  # Test-only injectable clock (`:number_sequences_clock`, zero-arity fun returning a DateTime).
  defp now do
    case Application.get_env(:letflow, :number_sequences_clock) do
      fun when is_function(fun, 0) -> fun.()
      _ -> DateTime.utc_now()
    end
  end

  @doc "The formatted number of counter value `n`."
  @spec format(Definition.t(), String.t(), pos_integer()) :: String.t()
  def format(%Definition{prefix: prefix, padding: padding, period: period}, period_key, n) do
    padded = n |> Integer.to_string() |> String.pad_leading(padding, "0")

    case period do
      "year" -> "#{prefix}-#{period_key}-#{padded}"
      "none" -> "#{prefix}-#{padded}"
    end
  end

  @doc """
  Locks the counter row of the bound type's current period (insert-if-absent plus `FOR UPDATE`,
  no increment). Returns `{:ok, {:locked, %{definition_id: id, period: period}}}` for a bound type
  and `{:ok, :unbound}` for any other. The period is computed here once; `allocate/6` takes it
  back through its `:period` option, so a year boundary between the two cannot lock one row and
  increment another. Runs in the caller's transaction, after the type's sequence row.
  """
  @spec lock_counter(module(), String.t(), schema_prefix :: String.t()) ::
          {:ok, {:locked, %{definition_id: String.t(), period: String.t()}}} | {:ok, :unbound}
  def lock_counter(repo, entity_type, schema_prefix) do
    case fetch_binding(entity_type, schema_prefix, repo) do
      :none ->
        {:ok, :unbound}

      {:ok, definition} ->
        period = current_period(definition)
        _counter = lock_row(repo, definition, period, schema_prefix)
        {:ok, {:locked, %{definition_id: definition.id, period: period}}}
    end
  end

  @doc """
  Allocates the next number of `definition` for the record `record_id`. The body of a Multi step:
  it runs inside the caller's transaction and opens none. Options: `:period` (the period
  `lock_counter/3` already locked; default the current one).

  Protocol (decision 0056 D2): insert-if-absent of the counter row, `FOR UPDATE`, increment by
  one, then the allocation-log row (its unique index is the backstop against a duplicate).
  """
  @spec allocate(
          module(),
          Definition.t(),
          String.t(),
          String.t(),
          schema_prefix :: String.t(),
          keyword()
        ) :: {:ok, allocation()} | {:error, term()}
  def allocate(
        repo,
        %Definition{} = definition,
        entity_type,
        record_id,
        schema_prefix,
        opts \\ []
      ) do
    period = Keyword.get(opts, :period) || current_period(definition)
    _locked = lock_row(repo, definition, period, schema_prefix)

    {1, [number]} =
      repo.update_all(
        from(c in Counter,
          where: c.sequence_id == ^definition.id and c.period == ^period,
          select: c.counter
        ),
        [inc: [counter: 1]],
        prefix: schema_prefix
      )

    formatted = format(definition, period, number)

    changeset =
      %Number{
        tenant_id: definition.tenant_id,
        sequence_id: definition.id,
        period: period,
        number: number,
        entity_type: entity_type,
        record_id: record_id,
        formatted: formatted
      }
      |> change()
      |> unique_constraint(:sequence_id, name: :number_sequence_numbers_seq_period_number_index)

    case repo.insert(changeset, prefix: schema_prefix) do
      {:ok, _row} -> {:ok, %{number: number, formatted: formatted, period: period}}
      {:error, %Ecto.Changeset{}} -> {:error, :number_conflict}
    end
  end

  # Insert-if-absent, then the row lock (decision 0056 D2).
  defp lock_row(repo, %Definition{} = definition, period, schema_prefix) do
    repo.insert(
      %Counter{tenant_id: definition.tenant_id, sequence_id: definition.id, period: period},
      on_conflict: :nothing,
      conflict_target: [:sequence_id, :period],
      prefix: schema_prefix
    )

    repo.one(
      from(c in Counter,
        where: c.sequence_id == ^definition.id and c.period == ^period,
        lock: "FOR UPDATE"
      ),
      prefix: schema_prefix
    )
  end

  @doc "The formatted number of one record, or nil when it has none."
  @spec number_for(String.t(), String.t(), schema_prefix :: String.t()) :: String.t() | nil
  def number_for(entity_type, record_id, schema_prefix)
      when is_binary(entity_type) and is_binary(record_id) and is_binary(schema_prefix) do
    Repo.one(
      from(n in Number,
        where: n.entity_type == ^entity_type and n.record_id == type(^record_id, Ecto.UUID),
        select: n.formatted
      ),
      prefix: schema_prefix
    )
  end

  @doc "The formatted numbers of several records of one type, keyed by record id."
  @spec numbers_for(String.t(), [String.t()], schema_prefix :: String.t()) :: %{
          String.t() => String.t()
        }
  def numbers_for(entity_type, record_ids, schema_prefix)
      when is_binary(entity_type) and is_list(record_ids) and is_binary(schema_prefix) do
    Repo.all(
      from(n in Number,
        where:
          n.entity_type == ^entity_type and
            n.record_id in type(^record_ids, {:array, Ecto.UUID}),
        select: {n.record_id, n.formatted}
      ),
      prefix: schema_prefix
    )
    |> Map.new()
  end
end
