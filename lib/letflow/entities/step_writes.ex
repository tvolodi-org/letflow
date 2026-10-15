defmodule Letflow.Entities.StepWrites do
  @moduledoc """
  GH 2587 / REQ-499 PR A3 (decision 0054 D2/D3): the write half of the engine's entity port,
  reached through `Letflow.Entities.EntityPortImpl`. Design
  `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md` section 4.3.

  `prepare/2` is real (PR A3) and `validate_lines/2` is real (PR B1). `multi/3` still FAILS
  CLOSED on any non-empty line list so nothing can reach a write before PR B2 replaces its
  body; nothing in the engine calls it yet.

  ## `validate_lines/2` (PR B1; design `gh2587-req499-pr-b-human-task-writes.md` section 6)

  Activation-time validation of one node's declared lines. It reports EVERY violation as
  `%{index, code}` with a stable atom code (no field value, no field name), sorted by
  `{index, code}`, so the same input always yields the same list. It reads definitions by name
  (no lock, no write). Per line, structural checks are pure (`line_codes/1`); semantic checks
  read the type's CURRENT active definition. `validate_lines/2` is the guard for a missing or
  non-string `entity_type` (GH #2633): `prepare/2` stays lenient and silently SKIPS such a line,
  so it assumes validated lines and must never be relied on as the guard.

  A B1-only gate (`execution_enabled?/0`, default OFF, never set in `config/*.exs`) appends
  `:entity_writes_execution_not_enabled` for every line once every real check passed, because
  no write path exists until PR B2; B2 deletes the gate. It is a seam for the named B1 tests,
  not a feature flag.

  ## Scope-predicate seam (design D-B.18, F-7)

  No scoped-type or scope-column declaration exists on a definition document today.
  `scoped_type?/1` and `scope_column_field?/2` read the closed key list
  `Application.get_env(:letflow, :entity_writes_scope_keys, [])` (default empty, so both are
  false): a definition-level key of that list with a truthy value makes the TYPE scoped; a
  field named by a key of the list, or whose entry carries such a key with a truthy value, is a
  scope column. Decision 0051 `scope_node` replaces the seam.

  ## `prepare/2` (0054 D3 step 0)

  Runs ONE short transaction, BEFORE the completion transaction, creating the synthetic
  per-type instance (`EntityTypeInstance.get_or_create/2`) of every distinct line type that has
  an ACTIVE definition, in ascending byte order of the type name. The first two statements are
  the constant `SET LOCAL lock_timeout`/`statement_timeout` (2 s each), so a contended wait is
  bounded; exactly the contention exceptions (lock not available, query canceled, deadlock,
  connection error) map to `{:error, :entity_write_contention}`; any other exception is
  re-raised. It refuses to run inside a caller's transaction, because a `SET LOCAL` there would
  leak into the rest of it.
  """

  alias Letflow.Engine.EntityPort
  alias Letflow.Engine.VariableMerge
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.ProcessWritable
  alias Letflow.Repo

  @max_lines 20
  @entity_type_pattern ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @line_keys ~w(op entity_type fields output_record_id_var record expected)

  @prepare_lock_timeout "2s"
  @prepare_statement_timeout "2s"

  # Built at compile time from the two constants above: no runtime interpolation (INV-7).
  @set_lock_timeout "SET LOCAL lock_timeout = '#{@prepare_lock_timeout}'"
  @set_statement_timeout "SET LOCAL statement_timeout = '#{@prepare_statement_timeout}'"

  # Postgres condition codes (as Postgrex names them) that mean "waited too long / lost a race".
  @contention_codes [:lock_not_available, :query_canceled, :deadlock_detected]

  @spec prepare([EntityPort.line()], EntityPort.prepare_ctx()) ::
          :ok
          | {:error, :entity_write_contention}
          | {:error, :prepare_inside_transaction}
          | {:error, {:entity_type_prepare_failed, String.t()}}
  def prepare([], %{prefix: prefix}) when is_binary(prefix), do: :ok

  def prepare(lines, %{prefix: prefix}) when is_list(lines) and is_binary(prefix) do
    if Repo.in_transaction?() do
      {:error, :prepare_inside_transaction}
    else
      types =
        lines
        |> Enum.flat_map(fn
          %{"entity_type" => type} when is_binary(type) -> [type]
          _ -> []
        end)
        |> Enum.uniq()
        |> Enum.sort()

      run_prepare(types, prefix)
    end
  end

  defp run_prepare([], _prefix), do: :ok

  defp run_prepare(types, prefix) do
    result =
      try do
        Repo.transaction(fn ->
          Repo.query!(@set_lock_timeout)
          Repo.query!(@set_statement_timeout)
          Enum.each(types, &ensure_instance(&1, prefix))
        end)
      rescue
        e in Postgrex.Error ->
          if match?(%{postgres: %{code: code}} when code in @contention_codes, e),
            do: {:error, :entity_write_contention},
            else: reraise(e, __STACKTRACE__)

        _e in DBConnection.ConnectionError ->
          {:error, :entity_write_contention}
      end

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_instance(type, prefix) do
    case Definitions.get_active_definition_by_name(type, prefix) do
      {:ok, _definition} ->
        case EntityTypeInstance.get_or_create(type, prefix) do
          {:ok, _instance_id} -> :ok
          {:error, _} -> Repo.rollback({:entity_type_prepare_failed, type})
        end

      # No active definition: skip (D-A3.2); `command_multi/3` refuses the line later.
      {:error, _not_found} ->
        :ok
    end
  end

  @typedoc "One normalized line (PR B1): sources tagged so a constant map is never a reference."
  @type normalized_line :: %{
          entity_type: String.t(),
          fields: %{optional(String.t()) => {:var, String.t()} | {:const, term()}},
          output_var: String.t() | nil
        }

  @doc """
  Validates one node's declared `lines` against the tenant's current definitions (design
  section 6). `ctx` carries `:prefix` and optionally `:graph_output_vars`, the
  `output_record_id_var` names declared by other nodes of the graph. `:ok` or
  `{:error, violations}` with every violation, sorted by `{index, code}`.
  """
  @spec validate_lines([EntityPort.line()], EntityPort.definition_ctx()) ::
          :ok | {:error, [EntityPort.line_violation()]}
  def validate_lines([], _ctx), do: :ok

  def validate_lines(lines, %{prefix: prefix} = ctx) when is_list(lines) and is_binary(prefix) do
    other_vars = MapSet.new(Map.get(ctx, :graph_output_vars, []))

    indexed = Enum.with_index(lines)
    checked = Enum.take(indexed, @max_lines)

    cap =
      if length(lines) > @max_lines,
        do: [%{index: @max_lines, code: :entity_writes_too_many_lines}],
        else: []

    {per_line, _seen} =
      Enum.flat_map_reduce(checked, MapSet.new(), fn {line, index}, seen ->
        output_var = declared_output_var(line)

        duplicate? =
          is_binary(output_var) and
            (MapSet.member?(seen, output_var) or MapSet.member?(other_vars, output_var))

        codes =
          line_codes(line) ++
            if(duplicate?, do: [:entity_write_output_var_duplicate], else: []) ++
            semantic_codes(line, prefix)

        seen = if is_binary(output_var), do: MapSet.put(seen, output_var), else: seen
        {Enum.map(Enum.uniq(codes), &%{index: index, code: &1}), seen}
      end)

    real = cap ++ per_line

    violations =
      cond do
        real != [] ->
          real

        execution_enabled?() ->
          []

        true ->
          Enum.map(checked, fn {_line, index} ->
            %{index: index, code: :entity_writes_execution_not_enabled}
          end)
      end

    case Enum.sort_by(violations, &{&1.index, &1.code}) do
      [] -> :ok
      sorted -> {:error, sorted}
    end
  end

  @doc """
  The B1 execution gate: `false` unless `config :letflow, :entity_writes_execution_enabled`
  is `true`. Default OFF in every environment (never set in `config/*.exs`); named B1 tests
  set it in `setup` and restore it in `on_exit`. PR B2 deletes this function and the key.
  """
  @spec execution_enabled?() :: boolean()
  def execution_enabled? do
    Application.get_env(:letflow, :entity_writes_execution_enabled, false) == true
  end

  @doc """
  Pure structural normalization of one declared line, shared by activation validation and
  (PR B2) the run-time re-check of a pinned snapshot. `{:ok, normalized}` or `{:error, code}`
  with the first (sorted) structural code of the line.
  """
  @spec normalize_line(term()) :: {:ok, normalized_line()} | {:error, atom()}
  def normalize_line(line) do
    case line_codes(line) do
      [] ->
        fields =
          line
          |> Map.get("fields")
          |> Kernel.||(%{})
          |> Map.new(fn
            {name, %{"var" => var}} -> {name, {:var, var}}
            {name, %{"const" => value}} -> {name, {:const, value}}
          end)

        {:ok,
         %{
           entity_type: Map.fetch!(line, "entity_type"),
           fields: fields,
           output_var: declared_output_var(line)
         }}

      [code | _] ->
        {:error, code}
    end
  end

  @doc "The declared `output_record_id_var` of `line` when it is a binary; `nil` otherwise."
  @spec declared_output_var(term()) :: String.t() | nil
  def declared_output_var(%{"output_record_id_var" => var}) when is_binary(var), do: var
  def declared_output_var(_line), do: nil

  # Structural (pure) violation codes of one line, sorted, de-duplicated. Total: any term.
  @spec line_codes(term()) :: [atom()]
  defp line_codes(line) when is_map(line) and not is_struct(line) do
    if Enum.all?(Map.keys(line), &is_binary/1) do
      codes =
        unknown_key_codes(line) ++
          entity_type_codes(line) ++
          op_codes(line) ++
          forbidden_key_codes(line) ++
          field_codes(line) ++
          output_var_codes(line)

      codes |> Enum.uniq() |> Enum.sort()
    else
      [:entity_write_line_malformed]
    end
  end

  defp line_codes(_line), do: [:entity_write_line_malformed]

  defp unknown_key_codes(line) do
    if Enum.any?(Map.keys(line), &(&1 not in @line_keys)),
      do: [:entity_write_unknown_key],
      else: []
  end

  defp entity_type_codes(%{"entity_type" => type}) when is_binary(type) do
    cond do
      String.trim(type) == "" -> [:entity_type_missing]
      Regex.match?(@entity_type_pattern, type) -> []
      true -> [:entity_type_name_invalid]
    end
  end

  defp entity_type_codes(_line), do: [:entity_type_missing]

  defp op_codes(%{"op" => "create"}), do: []
  defp op_codes(_line), do: [:entity_write_op_unsupported]

  defp forbidden_key_codes(line) do
    if(Map.has_key?(line, "record"), do: [:entity_write_record_not_allowed], else: []) ++
      if(Map.has_key?(line, "expected"), do: [:entity_write_expected_not_allowed], else: [])
  end

  defp field_codes(line) do
    case Map.get(line, "fields") do
      nil ->
        []

      fields when is_map(fields) and not is_struct(fields) ->
        Enum.flat_map(fields, &source_codes/1)

      _not_a_map ->
        [:entity_write_field_source_invalid]
    end
  end

  defp source_codes({name, %{"var" => var} = source})
       when is_binary(name) and map_size(source) == 1 do
    cond do
      not is_binary(var) or String.trim(var) == "" -> [:entity_write_field_source_invalid]
      VariableMerge.reserved_key?(var) -> [:entity_write_sys_reference]
      true -> []
    end
  end

  defp source_codes({name, %{"const" => _value} = source})
       when is_binary(name) and map_size(source) == 1,
       do: []

  defp source_codes(_entry), do: [:entity_write_field_source_invalid]

  # `output_record_id_var`: exactly `_sys.<one [A-Za-z0-9_]+ segment>`, the id key and the
  # derived `.seq` key each at most 160 bytes (the strict classifier of GH #2621). A dotted
  # name is refused.
  defp output_var_codes(%{"output_record_id_var" => var}) when not is_nil(var) do
    if is_binary(var) and VariableMerge.sys_key_kind(var) == :id and
         VariableMerge.sys_key_kind(var <> ".seq") == :seq,
       do: [],
       else: [:entity_write_output_var_shape]
  end

  defp output_var_codes(_line), do: []

  # Semantic (database-reading) codes: only for a line whose type name is well formed.
  defp semantic_codes(%{"entity_type" => type} = line, prefix) when is_binary(type) do
    if Regex.match?(@entity_type_pattern, type) do
      case Definitions.get_active_definition_by_name(type, prefix) do
        {:ok, %EntityDefinition{} = row} -> type_codes(row) ++ field_name_codes(row, line)
        {:error, _not_found} -> [:entity_type_not_found]
      end
    else
      []
    end
  end

  defp semantic_codes(_line, _prefix), do: []

  defp type_codes(%EntityDefinition{} = row) do
    managed = if is_nil(row.managed_by), do: [], else: [:entity_type_managed]

    writable =
      if is_nil(row.managed_by) and not ProcessWritable.writable?(row),
        do: [:entity_type_not_writable_by_process],
        else: []

    append_only =
      if is_map(row.definition_json) and Map.get(row.definition_json, "append_only") == true,
        do: [],
        else: [:entity_type_not_append_only]

    scoped = if scoped_type?(row), do: [:entity_type_scoped], else: []
    managed ++ writable ++ append_only ++ scoped
  end

  defp field_name_codes(%EntityDefinition{} = row, line) do
    case Map.get(line, "fields") do
      fields when is_map(fields) and not is_struct(fields) ->
        known = definition_field_names(row)

        fields
        |> Map.keys()
        |> Enum.filter(&is_binary/1)
        |> Enum.flat_map(fn name ->
          cond do
            not MapSet.member?(known, name) -> [:entity_write_field_unknown]
            scope_column_field?(row, name) -> [:entity_write_field_scope_column]
            true -> []
          end
        end)

      _no_fields ->
        []
    end
  end

  defp definition_field_names(%EntityDefinition{definition_json: %{"fields" => fields}})
       when is_list(fields) do
    for %{"name" => name} when is_binary(name) <- fields, into: MapSet.new(), do: name
  end

  defp definition_field_names(_row), do: MapSet.new()

  @doc """
  Seam (design D-B.18): whether the definition ROW declares a scoped type, per the closed key
  list `:entity_writes_scope_keys` (default empty, so `false`). A top-level key of the list
  with a truthy value in `definition_json` makes the type scoped.
  """
  @spec scoped_type?(EntityDefinition.t()) :: boolean()
  def scoped_type?(%EntityDefinition{definition_json: json}) when is_map(json) do
    Enum.any?(scope_keys(), &truthy?(Map.get(json, &1)))
  end

  def scoped_type?(_row), do: false

  @doc """
  Seam (design D-B.18): whether `field` is a scope column of the definition ROW, per the
  closed key list `:entity_writes_scope_keys` (default empty, so `false`): the field is named
  by a key of the list, or its definition entry carries such a key with a truthy value.
  """
  @spec scope_column_field?(EntityDefinition.t(), String.t()) :: boolean()
  def scope_column_field?(%EntityDefinition{definition_json: json}, field)
      when is_map(json) and is_binary(field) do
    keys = scope_keys()

    field in keys or
      case Map.get(json, "fields") do
        entries when is_list(entries) ->
          Enum.any?(entries, fn
            %{"name" => ^field} = entry -> Enum.any?(keys, &truthy?(Map.get(entry, &1)))
            _other -> false
          end)

        _no_fields ->
          false
      end
  end

  def scope_column_field?(_row, _field), do: false

  defp scope_keys do
    case Application.get_env(:letflow, :entity_writes_scope_keys, []) do
      keys when is_list(keys) -> Enum.filter(keys, &is_binary/1)
      _other -> []
    end
  end

  defp truthy?(value), do: value not in [nil, false]

  @spec multi(Ecto.Multi.t(), [EntityPort.line()], EntityPort.multi_ctx()) :: Ecto.Multi.t()
  def multi(%Ecto.Multi{} = multi, [], _ctx), do: multi

  def multi(%Ecto.Multi{} = multi, lines, _ctx) when is_list(lines) do
    Ecto.Multi.error(multi, {:line, 0, :build}, :entity_writes_not_enabled)
  end
end
