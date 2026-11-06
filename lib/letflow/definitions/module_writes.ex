defmodule Letflow.Definitions.ModuleWrites do
  @moduledoc """
  GH #2590 / REQ-501 PR R3 (decision 0054 D6; design
  `lib/letflow/design/gh2590-req501-module-write-handlers.md` 5.1, 5.2, D-R.6, D-R.16): the
  ACTIVATION-time validation of a HUMAN_TASK or (R5) SERVICE_TASK node's `module_writes` attribute, shared by the
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
       the line names the stamp's module (or is a posting line the cross-module rule below allows);
    2. the module is installed in this tenant and its installed manifest hash equals the
       stamp's `owner_manifest_hash` (or the stamp is in `accepted_manifest_hashes`, REQ-769) AND, strictly, the manifest hash of the module compiled
       into this build (decision OQ-R3: no drift tolerance);
    3. the handler resolves in the compiled `Letflow.Modules.Catalog` now;
    4. the graph still hashes to the stamp's `owner_body_hash`;
    5. the arguments match the registration (names declared, required ones present, one
       well-formed source each).

  The activator-authority check (`:EntitiesRecordsWrite` + an active user, OQ-R6) is the
  caller's `activator_codes/2`, reported at index 0 of the node. A tenant-created, edited,
  imported, promoted or rolled-back copy of a stamped version has NO stamp, so its handler
  lines are refused with `:module_write_stamp_missing`.

  ## Posting lines (REQ-684, decision 0073 A2)

  A line whose handler registers `posts_ledger` is a posting line. A node with more than two of them
  is refused (`module_writes_too_many_ledger_postings`, once, at the third), a posting line whose
  ledger ids meet those of an earlier posting line is refused
  (`module_writes_duplicate_ledger_posting`), and a posting line on a `SERVICE_TASK` is refused
  (`module_writes_ledger_on_service_task`) unless the node carries `ledger_post_consent: true`
  (REQ-688). These are activation-only checks in `violations/6`.

  ## Cross-module posting lines (REQ-758, decision 0082)

  A definition stamped by module M may carry a line of ANOTHER module N only when ALL hold:

    * (a) N is in the compiled manifest `depends_on` of M (direct dependencies only);
    * (b) the line's handler in N resolves now and registers `posts_ledger`;
    * (c) the same node carries a posting line of M itself;
    * (d) N is installed in the tenant and its installed manifest hash equals N's compiled hash
      (no accepted-hash tolerance: N is not the stamp, so there is no stamp hash to compare).

  Failing (a), (b) or (c) answers `module_write_stamp_mismatch`, the code a foreign line got before, so
  nothing leaks about which condition failed; failing (d) answers the existing
  `module_write_module_not_installed` / `module_write_hash_mismatch`. The stamp checks of M (installed,
  hash, body unchanged) stay on the N line, so a tampered node cannot reach N. Any other line of
  another module keeps answering `module_write_stamp_mismatch`. The posting-line checks above (cap of
  two, one ledger id once, no SERVICE_TASK without consent) already look at posting lines of any
  module and need no change. Posting authority stays per registration: each posting is authorized at
  run time by its own registration's permission, never by the activation.

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

  # GH #2590 R5 (design D-R.18, section 13): the node types that may declare `module_writes`.
  # SERVICE_TASK joined HUMAN_TASK once its apply routes (HTTP and script-bound) composed the
  # handler calls. A script output is never a command: the module, the handler and the lines are
  # fixed by the stamped definition; a script (or an HTTP body) can only feed a declared `var`
  # argument, which the handler validates.
  @node_types [:HUMAN_TASK, :SERVICE_TASK]

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
  The violations of one node's `module_writes`. A line violation carries the line's DECLARED index, the same one the run time reports:
  `length(entity_writes) + j` for the j-th handler call (declarative lines come first); node-level
  refusals carry index 0. `definition` is the row (or a plain map) being
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
        %Graph.Node{node_type: node_type} = node,
        writes,
        definition,
        entity_write_count,
        activator_codes,
        prefix
      ) do
    node_codes =
      cond do
        not is_list(writes) -> [:module_writes_not_a_list]
        node_type not in @node_types -> [:module_writes_node_type_not_supported]
        true -> []
      end

    activator_node_codes = if is_list(writes), do: activator_codes, else: []

    {line_violations, cap_violations, ledger_violations} =
      if is_list(writes) and node_type in @node_types do
        {line_violations(writes, definition, entity_write_count, prefix),
         cap_violations(writes, entity_write_count),
         ledger_violations(node, writes, entity_write_count)}
      else
        {[], [], []}
      end

    Enum.map(node_codes ++ activator_node_codes, &%{index: 0, code: &1}) ++
      cap_violations ++ line_violations ++ ledger_violations
  end

  @doc """
  The per-line violations of a list of `module_writes` lines alone (no node-level, activator or
  cap codes), in declared order, each at `entity_write_count + position`. The shared core of
  activation (`violations/6`) and the engine's RUN-TIME authorization
  (`Letflow.Entities.HandlerWrites.authorize_module_writes/2`, GH #2590 R4b), so the two cannot
  drift. `definition` is the row (or a map with the `owner_*` columns and a `:graph`).
  """
  @spec line_violations([term()], map(), non_neg_integer(), String.t()) :: [violation()]
  def line_violations(writes, definition, entity_write_count, prefix)
      when is_list(writes) and is_integer(entity_write_count) and is_binary(prefix) do
    resolved_line_violations(writes, definition, entity_write_count, prefix, nil, :strict)
  end

  # Entity lines alone above the cap are reported by the entity validator already; this adds
  # the COMBINED overflow (design 4.7, 5.1) once, at index 20.
  defp cap_violations(writes, entity_write_count) do
    if entity_write_count <= @max_lines and entity_write_count + length(writes) > @max_lines,
      do: [%{index: @max_lines, code: :entity_writes_too_many_lines}],
      else: []
  end

  # REQ-684 (decision 0073 A2, D-L12): the activation checks for posting lines, i.e. lines whose
  # handler registers `posts_ledger`. Compiled manifests only, no database read. A line that does
  # not resolve is reported by `line_violations/4` already (unknown handler) and counts as a
  # non-posting line here. Activation only: the run-time two-posting check belongs to the posting
  # path (slice L3b), so `line_violations/4` stays shared and unchanged.
  defp ledger_violations(%Graph.Node{node_type: node_type} = node, writes, entity_write_count) do
    posting =
      writes
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, index} ->
        case posting_ledger_ids(line) do
          nil -> []
          ids -> [{entity_write_count + index, ids}]
        end
      end)

    too_many =
      case posting do
        [_first, _second, {index, _ids} | _rest] ->
          [%{index: index, code: :module_writes_too_many_ledger_postings}]

        _within_limit ->
          []
      end

    duplicates =
      posting
      |> Enum.with_index()
      |> Enum.flat_map(fn {{index, ids}, position} ->
        earlier = posting |> Enum.take(position) |> Enum.flat_map(&elem(&1, 1))

        if Enum.any?(ids, &(&1 in earlier)),
          do: [%{index: index, code: :module_writes_duplicate_ledger_posting}],
          else: []
      end)

    on_service_task =
      if node_type == :SERVICE_TASK and not ledger_consent?(node),
        do:
          for(
            {index, _ids} <- posting,
            do: %{index: index, code: :module_writes_ledger_on_service_task}
          ),
        else: []

    too_many ++ duplicates ++ on_service_task
  end

  # REQ-688 (decision 0073 D-L12): a SERVICE_TASK posting line is accepted only with the explicit
  # node attribute `ledger_post_consent` set to the boolean `true` (`"true"`, `1`, `false` and an
  # absent attribute all refuse).
  defp ledger_consent?(%Graph.Node{attributes: %{"ledger_post_consent" => true}}), do: true
  defp ledger_consent?(_node), do: false

  @doc """
  REQ-688: the sorted ids of the SERVICE_TASK nodes among `declared` (`declared_nodes/1`) that have
  a posting line AND the consent flag `ledger_post_consent == true`. Recorded in the signed
  `activated_by` document as `ledger_consent_nodes`.
  """
  @spec ledger_consent_nodes([{Graph.Node.t(), term()}]) :: [String.t()]
  def ledger_consent_nodes(declared) do
    ids =
      for {%Graph.Node{node_type: :SERVICE_TASK, id: id} = node, writes} <- declared,
          is_list(writes),
          ledger_consent?(node),
          Enum.any?(writes, &(posting_ledger_ids(&1) != nil)),
          do: id

    ids |> Enum.uniq() |> Enum.sort()
  end

  # The ledger ids of a well-formed posting line, or nil for any other line.
  defp posting_ledger_ids(%{"module" => module, "handler" => handler} = line)
       when is_binary(module) and is_binary(handler) and not is_struct(line) do
    with {:ok, %{posts_ledger: name}} when is_binary(name) <-
           Catalog.write_handler(module, handler),
         {:ok, %{ledger_ids: ids}} <- Catalog.fetch_ledger(module, name) do
      ids
    else
      _ -> nil
    end
  end

  defp posting_ledger_ids(_line), do: nil

  @doc """
  REQ-768: the violations of one node's `module_writes` as `violations/6` would report them with no
  activator codes, but judged against the GIVEN install hashes instead of the tenant's stored ones
  (`%{installed: binary, accepted: [binary]}`). Used only by `Letflow.Modules.UpgradePlan` to answer
  "does this stamp still pass after the upgrade?" from the tenant row and the compiled manifest; the
  hashes are never request-derived. Activation and run time call `violations/6` and
  `line_violations/4`, which read the database as before.
  """
  @spec node_violations_with_hashes(
          Graph.Node.t(),
          term(),
          map(),
          non_neg_integer(),
          String.t(),
          %{installed: binary(), accepted: [binary()]}
        ) :: [violation()]
  def node_violations_with_hashes(
        %Graph.Node{node_type: node_type} = node,
        writes,
        definition,
        entity_write_count,
        prefix,
        %{installed: installed, accepted: accepted} = hashes
      )
      when is_binary(installed) and is_list(accepted) do
    node_codes =
      cond do
        not is_list(writes) -> [:module_writes_not_a_list]
        node_type not in @node_types -> [:module_writes_node_type_not_supported]
        true -> []
      end

    if is_list(writes) and node_type in @node_types do
      Enum.map(node_codes, &%{index: 0, code: &1}) ++
        cap_violations(writes, entity_write_count) ++
        resolved_line_violations(writes, definition, entity_write_count, prefix, hashes, :strict) ++
        ledger_violations(node, writes, entity_write_count)
    else
      Enum.map(node_codes, &%{index: 0, code: &1})
    end
  end

  @doc """
  REQ-771: `line_violations/4` for the engine's RUN-TIME authorization. Identical, except that the
  one cause "installed hash differs from the hash compiled into this build" (the tenant's module is
  not upgraded yet) is reported as `:module_write_upgrade_required` instead of
  `:module_write_hash_mismatch`, so the caller can answer the clear 409. Activation and the upgrade
  plan keep `line_violations/4` and `node_violations_with_hashes/6`.
  """
  @spec runtime_line_violations([term()], map(), non_neg_integer(), String.t()) :: [violation()]
  def runtime_line_violations(writes, definition, entity_write_count, prefix)
      when is_list(writes) and is_integer(entity_write_count) and is_binary(prefix) do
    resolved_line_violations(writes, definition, entity_write_count, prefix, nil, :runtime)
  end

  defp resolved_line_violations(writes, definition, entity_write_count, prefix, hashes, mode) do
    stamp_state = stamp_state(definition, prefix, hashes, mode)

    writes
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      for code <- line_codes(line, stamp_state, writes, prefix),
          do: %{index: entity_write_count + index, code: code}
    end)
  end

  # ── stamp-level state, resolved ONCE per node ────────────────────────────────────────────

  # {:ok, stamp, stamp_codes} | {:error, :module_write_stamp_missing}
  #
  # `stamp_codes` are the line-independent refusals (not installed, hash mismatch, body
  # changed), computed once; the handler-dependent ones are evaluated per line.
  #
  # `hashes` is nil (read the tenant row) or the injected post-upgrade hashes (REQ-768).
  defp stamp_state(definition, prefix, hashes, mode) do
    case OwnerStamp.from_row(definition) do
      :none ->
        {:error, :module_write_stamp_missing}

      {:ok, stamp} ->
        {:ok, stamp, stamp_codes(stamp, definition, prefix, hashes, mode)}
    end
  end

  defp stamp_codes(stamp, definition, prefix, hashes, mode) do
    install_codes =
      case install_hashes_for(stamp.module_id, prefix, hashes) do
        {:error, :not_installed} ->
          [:module_write_module_not_installed]

        {:error, :no_installed_hash} ->
          [:module_write_hash_mismatch]

        {:ok, %{installed: installed, accepted: accepted}} ->
          cond do
            # REQ-769: the stamp is the installed hash or an accepted earlier one.
            stamp.manifest_hash != installed and stamp.manifest_hash not in accepted ->
              [:module_write_hash_mismatch]

            compiled_differs?(stamp.module_id, installed) ->
              if mode == :runtime,
                do: [:module_write_upgrade_required],
                else: [:module_write_hash_mismatch]

            true ->
              []
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

  defp install_hashes_for(module_id, prefix, nil),
    do: Installs.install_hashes(module_id, prefix: prefix)

  defp install_hashes_for(_module_id, _prefix, %{installed: _, accepted: _} = hashes),
    do: {:ok, hashes}

  # Strict equality with the module compiled into THIS build. A module that is not compiled
  # in is reported by the per-line handler lookup instead, so it is not a hash difference.
  defp compiled_differs?(module_id, installed_hash) do
    case Catalog.manifest_hash(module_id) do
      {:ok, compiled} -> compiled != installed_hash
      {:error, :not_found} -> false
    end
  end

  # ── per-line codes ───────────────────────────────────────────────────────────────────────

  defp line_codes(line, _stamp_state, _writes, _prefix) when not is_map(line) or is_struct(line),
    do: [:module_write_line_malformed]

  defp line_codes(line, stamp_state, writes, prefix) do
    cond do
      not Enum.all?(Map.keys(line), &is_binary/1) ->
        [:module_write_line_malformed]

      Enum.any?(Map.keys(line), &(&1 not in @line_keys)) ->
        [:module_write_unknown_key]

      true ->
        identity_codes(line) ++ resolved_codes(line, stamp_state, writes, prefix)
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
  defp resolved_codes(line, stamp_state, writes, prefix) do
    module = Map.get(line, "module")
    handler = Map.get(line, "handler")

    if nonblank?(module) and nonblank?(handler) do
      case stamp_state do
        {:error, code} ->
          [code]

        {:ok, %{module_id: stamp_module}, stamp_codes} when stamp_module != module ->
          cross_module_codes(stamp_module, stamp_codes, line, writes, prefix)

        {:ok, _stamp, stamp_codes} ->
          stamp_codes ++ handler_codes(module, handler, line)
      end
    else
      []
    end
  end

  # REQ-758 (decision 0082): a line of a module other than the stamp's. (a), (b) and (c) are
  # compiled-manifest facts; any failure is the old `module_write_stamp_mismatch`. (d) reads the
  # tenant's install row of N.
  defp cross_module_codes(stamp_module, stamp_codes, line, writes, prefix) do
    %{"module" => module, "handler" => handler} = line

    if depends_on?(stamp_module, module) and posting_ledger_ids(line) != nil and
         own_posting_line?(stamp_module, writes) do
      stamp_codes ++
        dependency_install_codes(module, prefix) ++ handler_codes(module, handler, line)
    else
      [:module_write_stamp_mismatch]
    end
  end

  defp depends_on?(stamp_module, module) do
    case Catalog.fetch(stamp_module) do
      {:ok, entry} -> module in entry.manifest().depends_on
      {:error, :not_found} -> false
    end
  end

  defp own_posting_line?(stamp_module, writes) do
    Enum.any?(writes, fn
      %{"module" => ^stamp_module} = line -> posting_ledger_ids(line) != nil
      _other -> false
    end)
  end

  defp dependency_install_codes(module, prefix) do
    case Installs.install_hashes(module, prefix: prefix) do
      {:error, :not_installed} ->
        [:module_write_module_not_installed]

      {:error, :no_installed_hash} ->
        [:module_write_hash_mismatch]

      {:ok, %{installed: installed}} ->
        if compiled_differs?(module, installed), do: [:module_write_hash_mismatch], else: []
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
