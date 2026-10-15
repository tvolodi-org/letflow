defmodule Letflow.Entities.StepWrites do
  @moduledoc """
  GH 2587 / REQ-499 PR A3 (decision 0054 D2/D3): the write half of the engine's entity port,
  reached through `Letflow.Entities.EntityPortImpl`. Design
  `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md` section 4.3.

  `prepare/2` is real (PR A3), `validate_lines/2` is real (PR B1) and `multi/3` is real (PR B2):
  the engine's HUMAN_TASK completion composes the lines into its own transaction through it.

  ## `multi/3` (PR B2; design `gh2587-req499-pr-b-human-task-writes.md` sections 5.2, 7.4)

  Lines are built lazily, in one `Multi.merge/2`, after the engine's `:transition` step (so a
  form output can feed a field, and an execution error skips every write). Execution order
  is `(entity_type, declared index)`. Per line: a 10 s wall-clock guard, the run-time
  re-normalization of the PINNED line, the recorded `(entity_type, "create")` authorization,
  the write-side field restrictions of the completer, `Records.command_multi/3` with the
  LITERAL authority `:tenant` and server-built `source` metadata, then a `:process_policy`
  step re-reading the type's row under its sequence lock (writable-by-process flag,
  append-only, scoped). The multi ends with the named step `:entity_writes`.

  A stale `expected` is UNREACHABLE in this create-only MVP (OQ-B5): a `create` line carries
  no `expected` and no `record`, and a pinned line that does is refused as
  `:validation_failed` before anything is written. The `:record_version_conflict` mapping
  stays covered by `Records.interpret_in_multi/1`'s own tests.

  A replayed `_sys.<name>` value may hold a non-UUID string or any non-negative integer (the
  stored, wide tier): a reader must apply `Letflow.Engine.VariableMerge.check_sys_entry/2`
  and treat a failure as a refusal, never assume a UUID or an int64 (CO-7). PR B has no
  reader: update and delete lines are refused.

  Until decision 0051 `scope_node` exists the scoped-type and scope-column predicates are
  vacuous (OQ-B6): a pilot limit, not a guarantee.

  ## `validate_lines/2` (PR B1; design `gh2587-req499-pr-b-human-task-writes.md` section 6)

  Activation-time validation of one node's declared lines. It reports EVERY violation as
  `%{index, code}` with a stable atom code (no field value, no field name), sorted by
  `{index, code}`, so the same input always yields the same list. It reads definitions by name
  (no lock, no write). Per line, structural checks are pure (`line_codes/1`); semantic checks
  read the type's CURRENT active definition. `validate_lines/2` is the guard for a missing or
  non-string `entity_type` (GH #2633): `prepare/2` stays lenient and silently SKIPS such a line,
  so it assumes validated lines and must never be relied on as the guard.

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
  an ACTIVE, process-writable definition (`ProcessWritable.writable?/1`, so a type without
  the flag, or a managed one, gets no synthetic instance), in ascending byte order of the
  type name. The first two statements are
  the constant `SET LOCAL lock_timeout`/`statement_timeout` (2 s each), so a contended wait is
  bounded; exactly the contention exceptions (lock not available, query canceled, deadlock,
  connection error) map to `{:error, :entity_write_contention}`; any other exception is
  re-raised. It refuses to run inside a caller's transaction, because a `SET LOCAL` there would
  leak into the rest of it. Under the SQL sandbox (a savepoint, not a real transaction) the
  previous session values are restored before the transaction ends (CO-4).
  """

  alias Ecto.Multi
  alias Letflow.Engine.EntityPort
  alias Letflow.Engine.VariableMerge
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.ProcessWritable
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Entities.StepSource
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
          # CO-4: under a SQL-sandbox savepoint a `SET LOCAL` survives RELEASE until the
          # sandbox's outer transaction ends, so the session's previous values are read
          # first and put back (parameterized `set_config(.., true)`, no interpolation) once
          # the instances exist. In a real top-level transaction the restore is a no-op.
          %{rows: [[previous_lock, previous_statement]]} =
            Repo.query!(
              "SELECT current_setting('lock_timeout'), current_setting('statement_timeout')"
            )

          Repo.query!(@set_lock_timeout)
          Repo.query!(@set_statement_timeout)
          Enum.each(types, &ensure_instance(&1, prefix))
          Repo.query!("SELECT set_config('lock_timeout', $1, true)", [previous_lock])
          Repo.query!("SELECT set_config('statement_timeout', $1, true)", [previous_statement])
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
      {:ok, %EntityDefinition{} = definition} ->
        # CO-3 / SEC F7: only a process-writable type gets a synthetic instance.
        if ProcessWritable.writable?(definition) do
          case EntityTypeInstance.get_or_create(type, prefix) do
            {:ok, _instance_id} -> :ok
            {:error, _} -> Repo.rollback({:entity_type_prepare_failed, type})
          end
        else
          :ok
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

    violations = real

    case Enum.sort_by(violations, &{&1.index, &1.code}) do
      [] -> :ok
      sorted -> {:error, sorted}
    end
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

  # ---------------------------------------------------------------------
  # multi/3 (PR B2)
  # ---------------------------------------------------------------------

  @guard_budget_ms 10_000

  @doc """
  Appends the per-line write steps and the closing `:entity_writes` step to `multi`. With no
  lines it is the identity. See the moduledoc.
  """
  @spec multi(Ecto.Multi.t(), [EntityPort.line()], EntityPort.multi_ctx()) :: Ecto.Multi.t()
  def multi(%Multi{} = multi, [], _ctx), do: multi

  # I-B6: the cap is re-enforced here as defence in depth (the engine's plan refuses first).
  def multi(%Multi{} = multi, lines, _ctx) when is_list(lines) and length(lines) > @max_lines,
    do: Multi.error(multi, {:line, @max_lines, :build}, :line_malformed)

  def multi(%Multi{} = multi, lines, ctx) when is_list(lines) and is_map(ctx) do
    Multi.merge(multi, fn changes ->
      if ctx.skip?.(changes) do
        Multi.run(Multi.new(), :entity_writes, fn _repo, _changes -> {:ok, :skipped} end)
      else
        build_lines(lines, ctx, ctx.variables.(changes))
      end
    end)
  end

  defp build_lines(lines, ctx, variables) do
    now_fun = Map.get(ctx, :now_fun, fn -> System.monotonic_time(:millisecond) end)

    indexed =
      lines
      |> Enum.with_index()
      |> Enum.sort_by(fn {line, index} -> {sort_type(line), index} end)

    started =
      Multi.run(Multi.new(), :entity_writes_started, fn _repo, _changes ->
        {:ok, now_fun.()}
      end)

    indexed
    |> Enum.reduce_while({:ok, started}, fn {line, index}, {:ok, acc} ->
      case build_line(line, index, ctx, variables) do
        {:ok, line_multi} ->
          guard = fn _repo, changes ->
            if now_fun.() - Map.fetch!(changes, :entity_writes_started) > @guard_budget_ms,
              do: {:error, :deadline_exceeded},
              else: {:ok, :within_budget}
          end

          acc =
            acc
            |> Multi.run({:line, index, :deadline}, guard)
            |> Multi.append(line_multi)
            |> Multi.run({:line, index, :process_policy}, fn _repo, changes ->
              process_policy(Map.fetch!(changes, {:line, index, :recheck_definition}))
            end)

          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, index, reason}}
      end
    end)
    |> case do
      {:ok, acc} ->
        Multi.run(acc, :entity_writes, fn _repo, changes ->
          {:ok, assemble_result(indexed, lines, changes)}
        end)

      {:error, index, reason} ->
        # Build-time errors are RETURNED by command_multi/3 (nothing ran): surface the first as
        # a failing step so the whole transaction rolls back (design F-10).
        Multi.error(Multi.new(), {:line, index, :build}, reason)
    end
  end

  defp sort_type(%{"entity_type" => type}) when is_binary(type), do: type
  defp sort_type(_line), do: ""

  # One line: run-time re-normalization of the pinned line, authorization, field
  # restrictions, then the A2 command.
  defp build_line(line, index, ctx, variables) do
    with {:ok, normalized} <- run_time_line(line),
         :ok <- check_authorized(normalized.entity_type, ctx.authorized),
         :ok <- check_restrictions(normalized.fields, normalized.entity_type, ctx),
         {:ok, source} <-
           StepSource.new(%{
             instance_id: ctx.instance_id,
             task_id: ctx.task_id,
             node_id: ctx.node_id,
             definition_id: ctx.definition_id,
             definition_version: ctx.definition_version,
             line_index: index,
             activator_id: ctx.activator_id
           }) do
      command = %{
        kind: :create,
        entity_type: normalized.entity_type,
        field_values: resolve_values(normalized.fields, variables),
        actor_id: ctx.actor_id,
        source: source
      }

      # The authority is the LITERAL :tenant (A2 D-A2.9).
      Records.command_multi(command, ctx.prefix, :tenant)
    end
  end

  # A pinned line is re-checked at run time (a hand-edited snapshot): `expected`/`record`
  # present is a validation failure BEFORE any op check; an op other than "create" is
  # append-only (D7/D8).
  defp run_time_line(line) when is_map(line) and not is_struct(line) do
    cond do
      Map.has_key?(line, "expected") or Map.has_key?(line, "record") ->
        {:error, :line_malformed}

      is_binary(Map.get(line, "op")) and Map.get(line, "op") != "create" ->
        {:error, :op_unsupported}

      true ->
        case normalize_line(line) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, _code} -> {:error, :line_malformed}
        end
    end
  end

  defp run_time_line(_line), do: {:error, :line_malformed}

  defp check_authorized(entity_type, authorized) when is_list(authorized) do
    if {entity_type, "create"} in authorized, do: :ok, else: {:error, :line_not_authorized}
  end

  defp check_authorized(_entity_type, _authorized), do: {:error, :line_not_authorized}

  # `var` from the merged variables (absent or reserved -> omitted, so the type's own
  # validation refuses a missing required field); `const` as is. Never `_sys`.
  defp resolve_values(fields, variables) do
    Enum.reduce(fields, %{}, fn
      {name, {:const, value}}, acc ->
        Map.put(acc, name, value)

      {name, {:var, var}}, acc ->
        if VariableMerge.reserved_key?(var) do
          acc
        else
          case Map.fetch(variables, var) do
            {:ok, value} -> Map.put(acc, name, value)
            :error -> acc
          end
        end
    end)
  end

  defp check_restrictions(fields, entity_type, ctx) do
    case FieldGrants.load_restrictions(ctx.actor_id, entity_type, ctx.prefix) do
      {:ok, restricted} ->
        if Enum.any?(Map.keys(fields), &MapSet.member?(restricted, &1)),
          do: {:error, :field_restricted},
          else: :ok

      {:error, _reason} ->
        {:error, :field_restricted}
    end
  end

  # Reads the row `:recheck_definition` returned under the type's sequence lock.
  defp process_policy(%EntityDefinition{} = row) do
    append_only? =
      is_map(row.definition_json) and Map.get(row.definition_json, "append_only") == true

    cond do
      not ProcessWritable.writable?(row) -> {:error, :not_writable_by_process}
      not append_only? -> {:error, :not_append_only}
      scoped_type?(row) -> {:error, :scoped_type}
      true -> {:ok, :allowed}
    end
  end

  defp process_policy(_other), do: {:error, :not_writable_by_process}

  defp assemble_result(indexed, lines, changes) do
    applied =
      indexed
      |> Enum.map(fn {line, index} ->
        %Latest{record_id: record_id} = Map.fetch!(changes, {:line, index, :upsert_record_latest})
        %{global_seq: seq} = Map.fetch!(changes, {:line, index, :insert_event})

        %{
          line_index: index,
          entity_type: Map.fetch!(line, "entity_type"),
          record_id: record_id,
          event_global_seq: seq,
          output_var: declared_output_var(line)
        }
      end)
      |> Enum.sort_by(& &1.line_index)

    sys_values =
      applied
      |> Enum.filter(&is_binary(&1.output_var))
      |> Enum.reduce(%{}, fn %{output_var: var, record_id: id, event_global_seq: seq}, acc ->
        acc |> Map.put(var, id) |> Map.put(var <> ".seq", seq)
      end)

    %{applied: applied, lines_hash: lines_hash(lines), sys_values: sys_values}
  end

  @doc """
  Canonical SHA-256 (lowercase hex) of the declared `lines`: key-sorted JSON, so it is a
  function of the line content alone.
  """
  @spec lines_hash([EntityPort.line()]) :: String.t()
  def lines_hash(lines) when is_list(lines) do
    :sha256 |> :crypto.hash(canonical(lines)) |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map) and not is_struct(map) do
    body =
      map
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join(",", fn {k, v} -> Jason.encode!(to_string(k)) <> ":" <> canonical(v) end)

    "{" <> body <> "}"
  end

  defp canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"

  defp canonical(other), do: Jason.encode!(other)

  # ---------------------------------------------------------------------
  # interpret_failure/2 (design D-B.8)
  # ---------------------------------------------------------------------

  @doc """
  Maps a failed Multi step of this module's lines to the engine's outcome. Only `{:line, i,
  step}` names are line failures; anything else is `:not_a_line_failure`. The `detail` atom
  is a closed class for the tenant audit entry only (INV-5): the public body never carries it.
  """
  @spec interpret_failure(term(), term()) :: EntityPort.failure()
  def interpret_failure({:line, i, :deadline}, _reason) when is_integer(i),
    do: {:refused, i, :entity_write_contention, :deadline}

  def interpret_failure({:line, i, :build}, reason) when is_integer(i) do
    case reason do
      :line_malformed -> {:refused, i, :validation_failed, :malformed}
      :op_unsupported -> {:refused, i, :entity_append_only, :op_unsupported}
      :line_not_authorized -> {:refused, i, :write_not_permitted, :not_authorized}
      :field_restricted -> {:refused, i, :write_not_permitted, :field_restricted}
      :entity_type_managed -> {:refused, i, :write_not_permitted, :managed}
      # `prepare/2` skips a type that is not process-writable, so it has no synthetic
      # instance: the same refusal as the `:process_policy` check (uniform body, INV-5).
      {:entity_type_instance_missing, _type} -> {:refused, i, :write_not_permitted, :not_writable}
      other -> classify(i, :build, other)
    end
  end

  def interpret_failure({:line, i, :process_policy}, reason) when is_integer(i) do
    case reason do
      :not_writable_by_process -> {:refused, i, :write_not_permitted, :not_writable}
      :not_append_only -> {:refused, i, :write_not_permitted, :not_append_only}
      :scoped_type -> {:refused, i, :write_not_permitted, :scoped}
      _other -> {:failed, i, :process_policy}
    end
  end

  def interpret_failure({:line, i, step} = name, reason) when is_integer(i) and is_atom(step) do
    if reason == :entity_type_managed do
      {:refused, i, :write_not_permitted, :managed}
    else
      case Records.interpret_in_multi({:error, name, reason, %{}}) do
        {:entity_write_refused, ^i, code} -> {:refused, i, code, :step}
        {:entity_write_failed, ^i, failed_step} -> {:failed, i, failed_step}
        :not_a_line_failure -> :not_a_line_failure
      end
    end
  end

  def interpret_failure(_step, _reason), do: :not_a_line_failure

  defp classify(i, step, reason) do
    case Records.classify_step_error(reason) do
      {:refused, code} -> {:refused, i, code, :build}
      :internal -> {:failed, i, step}
    end
  end
end
