defmodule Letflow.Definitions.ModuleWrites do
  @moduledoc """
  GH #2590 / REQ-501 PR R3 (decision 0054 D6; design
  `lib/letflow/design/gh2590-req501-module-write-handlers.md` 5.1, 5.2, D-R.6, D-R.16): the
  ACTIVATION-time validation of a HUMAN_TASK node's `module_writes` attribute, shared by the
  three activation paths (`Definitions.activate/2`, version rollback, promotion apply) through
  `Letflow.Definitions.check_entity_writes/3`.

  ## Declaration (a node attribute of its own, not a line kind of `entity_writes`)

      attributes["module_writes"] :: [ %{"module" => id, "handler" => name, "args" => %{name => src}} ]
      src :: %{"var" => String.t()} | %{"const" => json}

  Closed keys per line; only `var` and `const` argument sources exist (no `_sys` source: a
  `var` naming a reserved engine key is refused).

  ## What activation proves

  A definition may call a module's handler only when ALL hold, evaluated against the row being
  activated and the tenant's CURRENT state (reads only, no lock):

    1. the row carries the ownership stamp an install put on it (`OwnerStamp.from_row/1`) and
       the line names the stamp's module;
    2. the module is installed in this tenant and its installed manifest hash equals the
       stamp's `owner_manifest_hash` AND, strictly, the manifest hash of the module compiled
       into this build (decision OQ-R3: no drift tolerance);
    3. the handler resolves in the compiled `Letflow.Modules.Catalog` now;
    4. the graph still hashes to the stamp's `owner_body_hash`;
    5. the arguments match the registration (names declared, required ones present, one
       well-formed source each).

  The activator-authority check (`:EntitiesRecordsWrite` + an active user, OQ-R6) is the
  caller's `activator_codes/2`, reported at index 0 of the node. A tenant-created, edited,
  imported, promoted or rolled-back copy of a stamped version has NO stamp, so its handler
  lines are refused with `:module_write_stamp_missing`.

  ## Hashes

  The stamp and installed hashes are compared here and never returned: a violation carries a
  code only.
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Engine.VariableMerge
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs

  # The combined cap of declarative and handler lines on one node (design 4.7).
  @max_lines 20

  @line_keys ["module", "handler", "args"]

  @typedoc "One violation inside a node: the declared line index and a stable code."
  @type violation :: %{index: non_neg_integer(), code: atom()}

  @doc """
  The non-empty `module_writes` of the graph's nodes as `{node, raw_writes}`, in graph order
  (`nil` and `[]` mean "none declared"; anything else, a malformed value included, is declared
  and reported by `violations/6`).
  """
  @spec declared_nodes([Graph.Node.t()]) :: [{Graph.Node.t(), term()}]
  def declared_nodes(nodes) when is_list(nodes) do
    for %Graph.Node{attributes: %{"module_writes" => writes}} = node <- nodes,
        writes not in [nil, []],
        do: {node, writes}
  end

  @doc """
  The sorted, de-duplicated `"<module>/<handler>"` names the declared lines call (well-formed
  lines only), for the `activated_by` document.
  """
  @spec handler_names([{Graph.Node.t(), term()}]) :: [String.t()]
  def handler_names(declared) do
    names =
      for {_node, writes} <- declared,
          is_list(writes),
          %{"module" => module, "handler" => handler} <- writes,
          is_binary(module),
          is_binary(handler),
          uniq: true,
          do: module <> "/" <> handler

    Enum.sort(names)
  end

  @doc """
  The violations of one node's `module_writes`. `definition` is the row (or a plain map) being
  activated, `entity_write_count` the length of the same node's declarative `entity_writes`,
  `activator_codes` the already-evaluated activator refusals (index 0), `prefix` the tenant
  schema.
  """
  @spec violations(
          Graph.Node.t(),
          term(),
          map(),
          non_neg_integer(),
          [atom()],
          String.t()
        ) :: [violation()]
  def violations(
        %Graph.Node{node_type: node_type},
        writes,
        definition,
        entity_write_count,
        activator_codes,
        prefix
      ) do
    node_codes =
      cond do
        not is_list(writes) -> [:module_writes_not_a_list]
        node_type != :HUMAN_TASK -> [:module_writes_node_type_not_supported]
        true -> []
      end

    activator_node_codes = if is_list(writes), do: activator_codes, else: []

    {line_violations, cap_violations} =
      if is_list(writes) and node_type == :HUMAN_TASK do
        stamp_state = stamp_state(definition, prefix)

        {writes
         |> Enum.with_index()
         |> Enum.flat_map(fn {line, index} ->
           for code <- line_codes(line, stamp_state), do: %{index: index, code: code}
         end), cap_violations(writes, entity_write_count)}
      else
        {[], []}
      end

    Enum.map(node_codes ++ activator_node_codes, &%{index: 0, code: &1}) ++
      cap_violations ++ line_violations
  end

  # Entity lines alone above the cap are reported by the entity validator already; this adds
  # the COMBINED overflow (design 4.7, 5.1) once, at index 20.
  defp cap_violations(writes, entity_write_count) do
    if entity_write_count <= @max_lines and entity_write_count + length(writes) > @max_lines,
      do: [%{index: @max_lines, code: :entity_writes_too_many_lines}],
      else: []
  end

  # ── stamp-level state, resolved ONCE per node ────────────────────────────────────────────

  # {:ok, stamp, stamp_codes} | {:error, :module_write_stamp_missing}
  #
  # `stamp_codes` are the line-independent refusals (not installed, hash mismatch, body
  # changed), computed once; the handler-dependent ones are evaluated per line.
  defp stamp_state(definition, prefix) do
    case OwnerStamp.from_row(definition) do
      :none ->
        {:error, :module_write_stamp_missing}

      {:ok, stamp} ->
        {:ok, stamp, stamp_codes(stamp, definition, prefix)}
    end
  end

  defp stamp_codes(stamp, definition, prefix) do
    install_codes =
      case Installs.installed_manifest_hash(stamp.module_id, prefix: prefix) do
        {:error, :not_installed} ->
          [:module_write_module_not_installed]

        {:error, :no_installed_hash} ->
          [:module_write_hash_mismatch]

        {:ok, installed} ->
          cond do
            installed != stamp.manifest_hash -> [:module_write_hash_mismatch]
            compiled_differs?(stamp.module_id, installed) -> [:module_write_hash_mismatch]
            true -> []
          end
      end

    body_codes =
      case definition do
        %{graph: graph} when is_map(graph) ->
          if OwnerStamp.graph_hash(graph) == stamp.body_hash,
            do: [],
            else: [:module_write_body_changed]

        _no_graph ->
          [:module_write_body_changed]
      end

    install_codes ++ body_codes
  end

  # Strict equality with the module compiled into THIS build. A module that is not compiled
  # in is reported by the per-line handler lookup instead, so it is not a hash difference.
  defp compiled_differs?(module_id, installed_hash) do
    case Catalog.manifest_hash(module_id) do
      {:ok, compiled} -> compiled != installed_hash
      {:error, :not_found} -> false
    end
  end

  # ── per-line codes ───────────────────────────────────────────────────────────────────────

  defp line_codes(line, _stamp_state) when not is_map(line) or is_struct(line),
    do: [:module_write_line_malformed]

  defp line_codes(line, stamp_state) do
    cond do
      not Enum.all?(Map.keys(line), &is_binary/1) ->
        [:module_write_line_malformed]

      Enum.any?(Map.keys(line), &(&1 not in @line_keys)) ->
        [:module_write_unknown_key]

      true ->
        identity_codes(line) ++ resolved_codes(line, stamp_state)
    end
  end

  defp identity_codes(line) do
    for {key, code} <- [
          {"module", :module_write_module_missing},
          {"handler", :module_write_handler_missing}
        ],
        not nonblank?(Map.get(line, key)),
        do: code
  end

  # Everything that needs a well-formed `module` and `handler`.
  defp resolved_codes(line, stamp_state) do
    module = Map.get(line, "module")
    handler = Map.get(line, "handler")

    if nonblank?(module) and nonblank?(handler) do
      case stamp_state do
        {:error, code} ->
          [code]

        {:ok, %{module_id: stamp_module}, _stamp_codes} when stamp_module != module ->
          [:module_write_stamp_mismatch]

        {:ok, _stamp, stamp_codes} ->
          stamp_codes ++ handler_codes(module, handler, line)
      end
    else
      []
    end
  end

  defp handler_codes(module, handler, line) do
    case Catalog.write_handler(module, handler) do
      {:error, :not_found} -> [:module_write_handler_unknown]
      {:ok, registered} -> arg_codes(Map.get(line, "args", %{}), registered.args)
    end
  end

  defp arg_codes(args, declared) when is_map(args) and not is_struct(args) do
    unknown =
      for {name, _src} <- args,
          not (is_binary(name) and Map.has_key?(declared, name)),
          do: :module_write_arg_unknown

    missing =
      for {name, %{required: true}} <- declared,
          not Map.has_key?(args, name),
          do: :module_write_arg_missing

    source =
      Enum.flat_map(args, fn {_name, src} -> source_codes(src) end)

    unknown ++ missing ++ source
  end

  defp arg_codes(_args, _declared), do: [:module_write_line_malformed]

  defp source_codes(%{"var" => var} = src) when map_size(src) == 1 do
    cond do
      not nonblank?(var) -> [:module_write_arg_source_invalid]
      VariableMerge.reserved_key?(var) -> [:module_write_arg_sys_reference]
      true -> []
    end
  end

  defp source_codes(%{"const" => _json} = src) when map_size(src) == 1, do: []
  defp source_codes(_other), do: [:module_write_arg_source_invalid]

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
