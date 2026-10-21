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

  ## SERVICE_TASK origin (GH #2587 PR C2; design `gh2587-req499-pr-c-service-task-writes.md`)

  `ctx.origin` is `{:task, id}` (HUMAN, or the legacy `ctx.task_id`) or `{:dispatch, id}` (a
  SERVICE_TASK apply). The dispatch origin differs in three ways only: `source.dispatch_id` and
  the `sys:step:<dispatch_id>:<i>` key (through `StepSource`), the write-side restriction subject
  is `ctx.subject_id` (the activator; the event actor is the platform sentinel), and values are
  capped at `service_size_caps/0` (64 KiB per value, 256 KiB per line, JSON encoding; refusal
  `:validation_failed` with no field name). `ctx.guard_budget_ms` can only tighten the 10 s guard: the engine passes `min(10 s, remaining deadline - 8 s)`, where 8 s is the pre-guard bound of an attempt (`prepare/2` <= 4 s plus the dispatch/CAS-row and projection lock waits <= 4 s; the guard clock starts after both, at `:entity_writes_started`).

  ## TypeAccess (GH #2808)

  `check_type_access/2` runs just before the field-restriction check of every declarative line
  and of every handler write, for the same restriction subject. A type denied to the subject
  refuses the line as a type that is not writable by process (`write_not_permitted`, detail
  `:not_writable`), and activation validation (`validate_lines/2`, ctx key `:activator_user_id`)
  reports such a type as `:entity_type_not_found`: denied and absent are one answer.

  ## `module_writes` (GH #2590 / REQ-501 R4b; design 4.5, 6.1)

  `prepare/2` and `multi/3` also take the node's `module_writes` lines from the context
  (`ctx.module_writes`). `prepare/2` adds the registered targets of the verified handlers to the
  same sorted pass (`HandlerWrites.prepare_targets/2`); `multi/3` takes one ascending
  `{:type_lock, type}` step per type of the declarative-plus-handler union right after
  `:entity_writes_started`, builds the declarative lines exactly as before, then each handler
  call (`HandlerWrites.build_call/4`, behind its own `{:line, k0, :deadline}` guard), and ends
  with `:entity_writes`. The 20-line cap is on the COMBINED count. A node without `module_writes`
  builds exactly the steps it always did. `interpret_failure/2` maps a handler-range step key
  (`20 + line_index * 50 + ordinal`) back to the DECLARED line index. GH #2590 R5: the SERVICE
  origin composes handler calls the same way; the handler context gets `ctx.subject_id` (the
  activator) as its field-restriction subject, `{:dispatch, id}` as its origin, and the byte caps
  above apply to a handler write's values too (`check_service_sizes/2`).

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
  alias Letflow.Entities.HandlerWrites
  alias Letflow.Entities.ProcessWritable
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Entities.StepSource
  alias Letflow.Entities.TypeAccess
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
  def prepare(lines, %{prefix: prefix} = ctx) when is_list(lines) and is_binary(prefix) do
    module_lines = Map.get(ctx, :module_writes, [])

    cond do
      lines == [] and module_lines == [] ->
        :ok

      Repo.in_transaction?() ->
        {:error, :prepare_inside_transaction}

      true ->
        types =
          lines
          |> Enum.flat_map(fn
            %{"entity_type" => type} when is_binary(type) -> [type]
            _ -> []
          end)
          |> Enum.uniq()
          |> Enum.sort()

        # GH #2590 R4b: the registered targets of verified `module_writes` lines join the same
        # sorted list and the same short transaction (design 4.5, F-7).
        handler_types = HandlerWrites.prepare_targets(module_lines, prefix)

        run_prepare(types, handler_types, prefix)
    end
  end

  defp run_prepare([], [], _prefix), do: :ok

  defp run_prepare(types, handler_types, prefix) do
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

          # One ascending pass over the union, so declarative and handler instances are created
          # in one global order (0054 D3).
          for type <- Enum.sort(Enum.uniq(types ++ handler_types)) do
            if type in types, do: ensure_instance(type, prefix)
            if type in handler_types, do: ensure_handler_instance(type, prefix)
          end

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

  # A handler's registered target (already filtered to a type its module manages, F-7): no
  # process-writable filter, a managed type can never carry the flag (F-R7).
  defp ensure_handler_instance(type, prefix) do
    case EntityTypeInstance.get_or_create(type, prefix) do
      {:ok, _instance_id} -> :ok
      {:error, _} -> Repo.rollback({:entity_type_prepare_failed, type})
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
            semantic_codes(line, prefix, Map.get(ctx, :activator_user_id))

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
  #
  # GH #2808: with an activator id, TypeAccess is read for every well-formed line whether or
  # not the type exists; a type denied to the activator (or a failed read) gets exactly the
  # list an absent type gets, so the codes are no existence oracle for a hidden type.
  defp semantic_codes(%{"entity_type" => type} = line, prefix, activator_user_id)
       when is_binary(type) do
    if Regex.match?(@entity_type_pattern, type) do
      access = activator_access(activator_user_id, type, prefix)
      definition = Definitions.get_active_definition_by_name(type, prefix)

      case {access, definition} do
        {:allowed, {:ok, %EntityDefinition{} = row}} ->
          type_codes(row) ++ field_name_codes(row, line)

        _absent_or_denied ->
          [:entity_type_not_found]
      end
    else
      []
    end
  end

  defp semantic_codes(_line, _prefix, _activator_user_id), do: []

  defp activator_access(user_id, type, prefix) when is_binary(user_id) do
    case TypeAccess.authorized?(user_id, type, prefix) do
      {:ok, :allowed} -> :allowed
      _denied_or_failed -> :denied
    end
  end

  defp activator_access(_no_activator, _type, _prefix), do: :allowed

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

  # GH #2587 PR C2 (design D-C.7, OQ-C4): run-time size caps on values that come from a service
  # response or a script output, applied to the {:dispatch, _} origin ONLY (the HUMAN path is not
  # widened). Measured on the JSON encoding. A change is a reviewed diff: the numbers are pinned
  # by a unit test. The follow-up is an entity-side per-record cap that replaces both.
  @service_value_max_bytes 65_536
  @service_line_max_bytes 262_144

  @doc false
  @spec service_size_caps() :: %{value_max_bytes: pos_integer(), line_max_bytes: pos_integer()}
  def service_size_caps,
    do: %{value_max_bytes: @service_value_max_bytes, line_max_bytes: @service_line_max_bytes}

  @doc """
  Appends the per-line write steps and the closing `:entity_writes` step to `multi`. With no
  lines and no `module_writes` it is the identity. See the moduledoc.

  GH #2590 R4b (design 6.1): when `ctx` carries `module_writes` the order is `:entity_writes_started`,
  one `{:type_lock, type}` per type in the ASCENDING union of the declarative line types and the
  handlers' registered targets (`HandlerWrites.lock_types/3`), the declarative lines (sorted by
  `(entity_type, index)`, unchanged), then each handler call in declared order
  (`HandlerWrites.build_call/4`, each behind its own `{:line, k0, :deadline}` guard), then
  `:entity_writes`. A node without `module_writes` builds exactly the steps it always did.
  """
  @spec multi(Ecto.Multi.t(), [EntityPort.line()], EntityPort.multi_ctx()) :: Ecto.Multi.t()
  def multi(%Multi{} = multi, lines, ctx) when is_list(lines) and is_map(ctx) do
    module_lines = Map.get(ctx, :module_writes, [])

    cond do
      lines == [] and module_lines == [] ->
        multi

      # I-B6: the COMBINED cap is re-enforced here as defence in depth (the engine's plan
      # refuses first, and runs before any Multi is built). NOTE: key 20 is also
      # `StepSource.call_key(0)` of a handler call; they never coexist because of this cap.
      length(lines) + length(module_lines) > @max_lines ->
        Multi.error(multi, {:line, @max_lines, :build}, :line_malformed)

      true ->
        Multi.merge(multi, fn changes ->
          if ctx.skip?.(changes) do
            Multi.run(Multi.new(), :entity_writes, fn _repo, _changes -> {:ok, :skipped} end)
          else
            build_lines(lines, module_lines, ctx, ctx.variables.(changes))
          end
        end)
    end
  end

  defp build_lines(lines, module_lines, ctx, variables) do
    now_fun = Map.get(ctx, :now_fun, fn -> System.monotonic_time(:millisecond) end)

    indexed =
      lines
      |> Enum.with_index()
      |> Enum.sort_by(fn {line, index} -> {sort_type(line), index} end)

    started =
      Multi.run(Multi.new(), :entity_writes_started, fn _repo, _changes ->
        {:ok, now_fun.()}
      end)

    # PR C2 (D-C.9): the service origin passes `guard_budget_ms` = min(10 s, remaining deadline);
    # the guard can only ever be tightened, never widened past 10 s.
    guard_budget = min(Map.get(ctx, :guard_budget_ms, @guard_budget_ms), @guard_budget_ms)

    guard = fn _repo, changes ->
      if now_fun.() - Map.fetch!(changes, :entity_writes_started) > guard_budget,
        do: {:error, :deadline_exceeded},
        else: {:ok, :within_budget}
    end

    locked = lock_types(started, lines, module_lines, ctx.prefix)

    indexed
    |> Enum.reduce_while({:ok, locked}, fn {line, index}, {:ok, acc} ->
      case build_line(line, index, ctx, variables) do
        {:ok, line_multi} ->
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
        acc
        |> append_handler_calls(lines, module_lines, ctx, variables, guard)
        |> Multi.run(:entity_writes, fn _repo, changes ->
          {:ok, assemble_result(indexed, lines, module_lines, changes)}
        end)

      {:error, index, reason} ->
        # Build-time errors are RETURNED by command_multi/3 (nothing ran): surface the first as
        # a failing step so the whole transaction rolls back (design F-10).
        Multi.error(Multi.new(), {:line, index, :build}, reason)
    end
  end

  # Type locks (0054 D3 rule 4) for a node with `module_writes` only: the ascending union of
  # the declarative line types and the handlers' registered targets, taken BEFORE any write
  # step so a handler can neither reorder nor skip them. A type without a synthetic instance
  # (not process-writable, no active definition, a target whose row another module manages) is
  # not locked: nothing can be written to it, and its own line step refuses with the same
  # per-line result a node without `module_writes` gives.
  defp lock_types(multi, _lines, [], _prefix), do: multi

  defp lock_types(multi, lines, module_lines, prefix),
    do: lock_union(multi, lines, module_lines, prefix, :type_lock)

  @doc """
  GH #2704 (decision 0061, the entity-port callback `lock_types/4`): the same ascending union of
  line types and handler target types as the in-`multi/3` locks, as `{:pre_type_lock, type}` steps
  (a different key tag, because `build_lines/4` emits `{:type_lock, type}` later in the same
  Multi and Ecto.Multi rejects duplicate names; those later steps become no-op re-locks). Unlike
  the private clause above it also covers a node WITHOUT `module_writes`. Lock-only: no read of
  record data, no authorization step, no write.
  """
  @spec lock_planned_types(
          Multi.t(),
          [EntityPort.line()],
          [EntityPort.module_write_line()],
          %{required(:prefix) => String.t()}
        ) :: Multi.t()
  def lock_planned_types(%Multi{} = multi, lines, module_lines, %{prefix: prefix})
      when is_list(lines) and is_list(module_lines) and is_binary(prefix),
      do: lock_union(multi, lines, module_lines, prefix, :pre_type_lock)

  defp lock_union(multi, lines, module_lines, prefix, tag) do
    declarative =
      for %{"entity_type" => type} <- lines, is_binary(type), do: type

    types =
      (declarative ++ HandlerWrites.registered_targets(module_lines))
      |> Enum.uniq()
      |> Enum.filter(&match?({:ok, _id}, EntityTypeInstance.fetch_instance_id(&1, prefix)))

    HandlerWrites.lock_types(multi, types, prefix, tag)
  end

  # Handler calls, in declared order, after every declarative line. Call `j` has
  # `line_index = length(lines) + j`; its call-level key is `StepSource.call_key/1`.
  defp append_handler_calls(multi, _lines, [], _ctx, _variables, _guard), do: multi

  defp append_handler_calls(multi, lines, module_lines, ctx, variables, guard) do
    base = %{
      prefix: ctx.prefix,
      instance_id: ctx.instance_id,
      origin: origin(ctx),
      node_id: ctx.node_id,
      definition_id: ctx.definition_id,
      definition_version: ctx.definition_version,
      actor_id: ctx.actor_id,
      # GH #2590 R5 (T-10): the field-restriction subject. The completer on the human origin; the
      # ACTIVATOR on the service origin, where the event actor is the platform sentinel.
      subject_id: subject_id(ctx),
      activator_id: ctx.activator_id,
      manifest_hash: owner_manifest_hash(ctx)
    }

    module_lines
    |> Enum.with_index(length(lines))
    |> Enum.reduce(multi, fn {line, line_index}, acc ->
      acc
      |> Multi.run({:line, StepSource.call_key(line_index), :deadline}, guard)
      |> HandlerWrites.build_call(Map.put(base, :line_index, line_index), line, variables)
    end)
  end

  defp owner_manifest_hash(%{owner: %{manifest_hash: hash}}) when is_binary(hash), do: hash
  defp owner_manifest_hash(_ctx), do: nil

  defp sort_type(%{"entity_type" => type}) when is_binary(type), do: type
  defp sort_type(_line), do: ""

  # One line: run-time re-normalization of the pinned line, authorization, field
  # restrictions, then the A2 command. PR C2: the origin is `{:task, id}` (HUMAN, the legacy
  # `ctx.task_id`) or `{:dispatch, id}` (SERVICE_TASK); the restriction subject is
  # `ctx.subject_id` (the activator on the service origin, the completer on the human one).
  defp build_line(line, index, ctx, variables) do
    origin = origin(ctx)

    with {:ok, normalized} <- run_time_line(line),
         :ok <- check_authorized(normalized.entity_type, ctx.authorized),
         :ok <- check_type_access(normalized.entity_type, ctx),
         :ok <- check_restrictions(normalized.fields, normalized.entity_type, ctx),
         values = resolve_values(normalized.fields, variables),
         :ok <- check_service_sizes(values, origin),
         {:ok, source} <-
           StepSource.new(
             Map.merge(origin_attrs(origin), %{
               instance_id: ctx.instance_id,
               node_id: ctx.node_id,
               definition_id: ctx.definition_id,
               definition_version: ctx.definition_version,
               line_index: index,
               activator_id: ctx.activator_id
             })
           ) do
      command = %{
        kind: :create,
        entity_type: normalized.entity_type,
        field_values: values,
        actor_id: ctx.actor_id,
        source: source
      }

      # The authority is the LITERAL :tenant (A2 D-A2.9).
      Records.command_multi(command, ctx.prefix, :tenant)
    end
  end

  defp origin(%{origin: {tag, id} = origin}) when tag in [:task, :dispatch] and is_binary(id),
    do: origin

  defp origin(%{task_id: task_id}), do: {:task, task_id}

  defp origin_attrs({:task, id}), do: %{task_id: id}
  defp origin_attrs({:dispatch, id}), do: %{dispatch_id: id}

  # D-C.7: per-value and per-line byte caps on the JSON encoding, service origin only. The
  # refusal names no field (INV-2): `:value_too_large` -> `validation_failed`.
  @doc false
  @spec check_service_sizes(map(), {:task | :dispatch, Ecto.UUID.t()}) ::
          :ok | {:error, :value_too_large | :line_malformed}
  def check_service_sizes(_values, {:task, _id}), do: :ok

  def check_service_sizes(values, {:dispatch, _id}) do
    with {:ok, line_json} <- Jason.encode(values),
         {:ok, encoded} <- encode_values(values) do
      if byte_size(line_json) > @service_line_max_bytes or
           Enum.any?(encoded, &(byte_size(&1) > @service_value_max_bytes)),
         do: {:error, :value_too_large},
         else: :ok
    else
      {:error, _not_encodable} -> {:error, :line_malformed}
    end
  end

  defp encode_values(values) do
    Enum.reduce_while(values, {:ok, []}, fn {_name, value}, {:ok, acc} ->
      case Jason.encode(value) do
        {:ok, json} -> {:cont, {:ok, [json | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
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

  # D4c: the restriction subject. The completer on the human path; the ACTIVATOR on the service
  # origin, where no human completes and the event actor is the platform sentinel.
  defp subject_id(%{subject_id: subject_id}) when is_binary(subject_id), do: subject_id
  defp subject_id(%{actor_id: actor_id}), do: actor_id

  @doc false
  # GH #2808: TypeAccess for the restriction subject (the same subject FieldGrants uses). A
  # denied type or a failed read refuses the line; `interpret_line/4` maps it to the refusal of
  # a type that is not writable by process, so denied and absent are one answer.
  @spec check_type_access(String.t(), map()) :: :ok | {:error, :type_denied}
  def check_type_access(entity_type, ctx) do
    case TypeAccess.authorized?(subject_id(ctx), entity_type, ctx.prefix) do
      {:ok, :allowed} -> :ok
      _denied_or_failed -> {:error, :type_denied}
    end
  end

  defp check_restrictions(fields, entity_type, ctx) do
    case FieldGrants.load_restrictions(subject_id(ctx), entity_type, ctx.prefix) do
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

  defp assemble_result(indexed, lines, module_lines, changes) do
    declarative_applied =
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

    applied = declarative_applied ++ handler_applied(lines, module_lines, changes)

    sys_values =
      applied
      |> Enum.filter(&is_binary(&1.output_var))
      |> Enum.reduce(%{}, fn %{output_var: var, record_id: id, event_global_seq: seq}, acc ->
        acc |> Map.put(var, id) |> Map.put(var <> ".seq", seq)
      end)

    %{
      applied: applied,
      lines_hash: lines_hash(hash_input(lines, module_lines)),
      sys_values: sys_values
    }
  end

  # `lines_hash` of a node WITHOUT `module_writes` stays the hash of the declarative list
  # (byte-identical); with it, the hash covers both attributes (design 4.7).
  defp hash_input(lines, []), do: lines

  defp hash_input(lines, module_lines),
    do: %{"entity_writes" => lines, "module_writes" => module_lines}

  # One applied entry per handler `create/3`, found by its namespace key (>= 20): ids and
  # sequences only (INV-2), plus the handler's module id, name and write ordinal. In declared
  # order (call, then ordinal).
  defp handler_applied(_lines, [], _changes), do: []

  defp handler_applied(lines, module_lines, changes) do
    for {{:line, key, :insert_event}, %{global_seq: seq}} <- changes,
        key >= StepSource.call_key(0) do
      line_index = StepSource.declared_line_index(key)

      %Latest{record_id: record_id, entity_type: entity_type} =
        Map.fetch!(changes, {:line, key, :upsert_record_latest})

      line = Enum.at(module_lines, line_index - length(lines))

      %{
        line_index: line_index,
        entity_type: entity_type,
        record_id: record_id,
        event_global_seq: seq,
        output_var: nil,
        handler_module: Map.get(line, "module"),
        handler: Map.get(line, "handler"),
        write_ordinal: key - StepSource.call_key(line_index)
      }
    end
    |> Enum.sort_by(&{&1.line_index, &1.write_ordinal})
  end

  @doc """
  Canonical SHA-256 (lowercase hex) of the declared `lines`: key-sorted JSON, so it is a
  function of the line content alone.
  """
  @spec lines_hash([EntityPort.line()] | map()) :: String.t()
  def lines_hash(lines) when is_list(lines) or is_map(lines) do
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
  def interpret_failure({:line, key, step} = name, reason)
      when is_integer(key) and is_atom(step) do
    interpret_line(public_index(key, reason), name, step, reason)
  end

  # A type-lock step (GH #2590 R4b) can only fail on a database error: an internal fault, never
  # a client refusal (a type without an instance is not locked at all).
  def interpret_failure({:type_lock, type}, _reason) when is_binary(type),
    do: {:failed, 0, :type_lock}

  # GH #2704: the service apply's pre-lock (`{:pre_type_lock, type}`) fails the same way and is
  # the same internal fault, so the service classification (`interpret_service_step_failure/2`)
  # lands it like a failed `{:type_lock, type}`.
  def interpret_failure({:pre_type_lock, type}, _reason) when is_binary(type),
    do: {:failed, 0, :type_lock}

  def interpret_failure(_step, _reason), do: :not_a_line_failure

  # The DECLARED line index of a step key: a declarative key is its own index; a handler-range
  # key (`20 + line_index * 50 + ordinal`) maps back to the call's declared index. The overflow
  # failure `{:line, 20, :build}, :line_malformed` of `multi/3` (a 21st combined line) keeps its
  # historical public index 20; a handler call at declared index 0 also has key 20 but can never
  # fail with `:line_malformed` (its build reasons are the `:handler_*` atoms), and the two never
  # coexist (the combined cap precedes any Multi).
  defp public_index(key, :line_malformed) when key == @max_lines, do: key

  defp public_index(key, _reason) do
    case StepSource.declared_line_index(key) do
      :declarative -> key
      line_index -> line_index
    end
  end

  defp interpret_line(i, _name, :deadline, _reason),
    do: {:refused, i, :entity_write_contention, :deadline}

  # Handler call: the install row or a hash changed between the pre-transaction authorization
  # and this step (TOCTOU), checked again with no lock.
  defp interpret_line(i, _name, :owner_recheck, :hash_mismatch),
    do: {:refused, i, :write_not_permitted, :hash_mismatch}

  defp interpret_line(i, _name, :owner_recheck, _reason), do: {:failed, i, :owner_recheck}

  defp interpret_line(i, _name, :build, reason) do
    case reason do
      :line_malformed -> {:refused, i, :validation_failed, :malformed}
      :op_unsupported -> {:refused, i, :entity_append_only, :op_unsupported}
      :line_not_authorized -> {:refused, i, :write_not_permitted, :not_authorized}
      :field_restricted -> {:refused, i, :write_not_permitted, :field_restricted}
      # PR C2 (D-C.7): a service-origin value over the byte cap. No field name (INV-2).
      :value_too_large -> {:refused, i, :validation_failed, :value_too_large}
      :entity_type_managed -> {:refused, i, :write_not_permitted, :managed}
      # GH #2808: a type TypeAccess hides from the subject answers as a non-writable type.
      :type_denied -> {:refused, i, :write_not_permitted, :not_writable}
      # GH #2590 R4b, handler call build failures (design 8): a handler that is no longer
      # registered or said "not permitted" is the uniform 403; bad arguments are a 422; a
      # contract violation or a raise is an internal failure (the body carries no detail).
      :handler_unknown -> {:refused, i, :write_not_permitted, :handler_unknown}
      :handler_not_permitted -> {:refused, i, :write_not_permitted, :handler_not_permitted}
      :handler_invalid_arguments -> {:refused, i, :validation_failed, :handler_invalid_arguments}
      shape when shape in [:handler_shape, :handler_raised] -> {:failed, i, :handler}
      # `prepare/2` skips a type that is not process-writable, so it has no synthetic
      # instance: the same refusal as the `:process_policy` check (uniform body, INV-5).
      {:entity_type_instance_missing, _type} -> {:refused, i, :write_not_permitted, :not_writable}
      other -> classify(i, :build, other)
    end
  end

  defp interpret_line(i, _name, :process_policy, reason) do
    case reason do
      :not_writable_by_process -> {:refused, i, :write_not_permitted, :not_writable}
      :not_append_only -> {:refused, i, :write_not_permitted, :not_append_only}
      :scoped_type -> {:refused, i, :write_not_permitted, :scoped}
      _other -> {:failed, i, :process_policy}
    end
  end

  # `HandlerWrites`' per-write policy step (managed-by assertion F-7, scope ceiling INV-6).
  defp interpret_line(i, _name, :policy, reason) do
    case reason do
      :target_not_managed_by_module ->
        {:refused, i, :write_not_permitted, :target_not_managed_by_module}

      :scoped_type ->
        {:refused, i, :write_not_permitted, :scoped}

      _other ->
        {:failed, i, :policy}
    end
  end

  defp interpret_line(i, {:line, key, _} = name, _step, reason) do
    if reason == :entity_type_managed do
      {:refused, i, :write_not_permitted, :managed}
    else
      case Records.interpret_in_multi({:error, name, reason, %{}}) do
        {:entity_write_refused, ^key, code} -> {:refused, i, code, :step}
        {:entity_write_failed, ^key, failed_step} -> {:failed, i, failed_step}
        :not_a_line_failure -> :not_a_line_failure
      end
    end
  end

  defp classify(i, step, reason) do
    case Records.classify_step_error(reason) do
      {:refused, code} -> {:refused, i, code, :build}
      :internal -> {:failed, i, step}
    end
  end
end
