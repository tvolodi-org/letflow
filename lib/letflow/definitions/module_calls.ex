defmodule Letflow.Definitions.ModuleCalls do
  @moduledoc """
  The DEFINITION-time rules of a SERVICE_TASK node's `module_call` (T-3045, D-204 task P2a of
  `docs/design-module-process-conversion.md` section 6.1): a step bound to a MODULE FAMILY entry
  of the compiled catalogue (`Letflow.PlatformFunctions.ModuleFamily`).

      attributes["module_call"] :: %{
        "function" => "<module id>.<handler>",
        "args"     => %{"<input>" => %{"var" => name} | %{"const" => json}},
        "reads"    => ..., "writes" => ...          # the typed mapping, as for a platform call
      }

  It is the twin of `Letflow.Definitions.PlatformCalls`, with three differences:

    * the entry is a MODULE entry (`Entry.module_family?/1`); a platform entry named here is the
      same `:module_call_function_unknown` as an unknown name, so the step kind cannot be used to
      reach the platform family;
    * the tenant rule is the module's (`Letflow.PlatformFunctions.ModuleTenantRule`: installed in
      THIS tenant, manifest hash accepted), not "platform tenant only"; any tenant may carry the
      step, and the module rule decides whether it may be switched on;
    * the authority is the activator's: the signed `activated_by` document records the entry's
      permission (`required_permissions/1`, `function_names/1`), exactly as for a platform call.
      The stamp-free run-time authority is task P3; this task reuses the signed document.

  ## The refusals (activation)

  One fixed, closed list of codes, all at node index 0: `:module_call_malformed`,
  `:module_call_unknown_key`, `:module_call_node_type_not_supported`,
  `:conflicting_module_call_routes`, `:module_call_function_unknown`,
  `:module_call_activator_required`, `:module_call_permission_required`,
  `:module_call_module_not_installed`, `:module_call_module_hash_mismatch`,
  `:module_call_module_upgrade_required`, `:module_call_foreign_source_refused`,
  `:module_call_input_source_refused`, `:module_call_arg_unknown`, `:module_call_arg_missing`,
  `:module_call_arg_source_invalid`, `:module_call_arg_sys_reference` and
  `:module_call_runtime_unavailable`.

  ## NOT RUNNABLE YET (P2b)

  The run time of the step (in the transaction that ENTERS the node, section 3.2) is task P2b.
  Until it lands, `runtime_violations/0` always answers and a graph whose `module_call` steps are
  otherwise valid is refused at activation with `:module_call_runtime_unavailable`, so no version
  can be switched on that the engine could not run. The engine itself also refuses such a node at
  entry (`Letflow.Engine`, `:config_parse_failed`), fail closed. P2b empties `runtime_violations/0`,
  adds the typed step mapping of the declared writes (`PlatformCalls.mappings/1` has no module
  twin yet) and removes both refusals.
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.PlatformCalls
  alias Letflow.Engine.WriteTargets
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformFunctions.ModuleTenantRule

  @attribute "module_call"
  @call_keys ["function", "args", "reads", "writes"]
  @node_types [:SERVICE_TASK]
  @conflicting_attributes [
    "endpoint",
    "service_id",
    "script_key",
    "platform_call",
    "notify",
    "entity_writes",
    "module_writes"
  ]

  @typedoc "One violation inside a node: a stable code."
  @type violation :: %{index: non_neg_integer(), code: atom()}

  @doc """
  The nodes of `nodes` that declare a `module_call`, as `{node, raw_call}`, in graph order. A
  node whose attribute is present but malformed is declared (and refused), never skipped.
  """
  @spec declared_nodes([Graph.Node.t()]) :: [{Graph.Node.t(), term()}]
  def declared_nodes(nodes) when is_list(nodes) do
    for %Graph.Node{attributes: attributes} = node <- nodes,
        is_map(attributes),
        Map.get(attributes, @attribute) != nil,
        do: {node, Map.get(attributes, @attribute)}
  end

  @doc "True when the graph declares at least one `module_call` step."
  @spec declares_call?(Graph.t() | [Graph.Node.t()] | term()) :: boolean()
  def declares_call?(%Graph{nodes: nodes}) when is_list(nodes), do: declared_nodes(nodes) != []
  def declares_call?(nodes) when is_list(nodes), do: declared_nodes(nodes) != []
  def declares_call?(_other), do: false

  @doc """
  The MODULE entry a call names, or `{:error, :not_found}`. A platform entry is not found here.
  """
  @spec entry(map() | term()) :: {:ok, Entry.t()} | {:error, :not_found}
  def entry(call) when is_map(call) do
    with name when is_binary(name) <- function_name(call),
         {:ok, entry} <- Catalog.fetch(name),
         true <- Entry.module_family?(entry) do
      {:ok, entry}
    else
      _no_module_entry -> {:error, :not_found}
    end
  end

  def entry(_call), do: {:error, :not_found}

  @doc """
  The permission atoms the declared steps require (the entries' permissions), sorted, one per
  distinct permission: what the activator must hold and what the signed document records.
  """
  @spec required_permissions([Graph.Node.t()]) :: [atom()]
  def required_permissions(nodes) when is_list(nodes) do
    nodes
    |> declared_nodes()
    |> Enum.flat_map(fn {_node, call} ->
      case entry(call) do
        {:ok, entry} -> [entry.permission]
        {:error, :not_found} -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The sorted, de-duplicated names of the module functions the declared steps call."
  @spec function_names([{Graph.Node.t(), term()}]) :: [String.t()]
  def function_names(declared) do
    declared
    |> Enum.flat_map(fn {_node, call} ->
      case entry(call) do
        {:ok, entry} -> [entry.name]
        {:error, :not_found} -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The variable names the declared steps READ that no person may write: the `var` arguments of the
  inputs whose source class is not `:person`. The engine refuses these keys in a task completion
  body (the T-2430 rule, carried over by source class; `WriteTargets.write_read_keys/1`).
  """
  @spec read_keys([Graph.Node.t()]) :: [String.t()]
  def read_keys(nodes) when is_list(nodes) do
    nodes
    |> declared_nodes()
    |> Enum.flat_map(fn {_node, call} -> trusted_vars(call) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The violations of one node's `module_call`, in the order they are checked. `nodes` is the whole
  graph's node list; `prefix` the tenant schema the definition lives in; `activator` the signed
  authority of the person switching the version on (nil when there is none).
  """
  @spec violations(Graph.Node.t(), [Graph.Node.t()], String.t(), term()) :: [violation()]
  def violations(
        %Graph.Node{node_type: node_type, attributes: attributes},
        nodes,
        prefix,
        activator
      )
      when is_binary(prefix) and is_list(nodes) do
    call = if is_map(attributes), do: Map.get(attributes, @attribute), else: nil

    cond do
      is_nil(call) ->
        []

      conflict?(attributes) ->
        [v(:conflicting_module_call_routes)]

      node_type not in @node_types ->
        [v(:module_call_node_type_not_supported)]

      not is_map(call) or is_struct(call) ->
        [v(:module_call_malformed)]

      true ->
        case shape_violations(call) do
          [] -> entry_violations(call, nodes, prefix, activator)
          shape -> shape
        end
    end
  end

  def violations(_node, _nodes, _prefix, _activator), do: []

  defp v(code), do: %{index: 0, code: code}

  defp conflict?(attributes),
    do: Enum.any?(@conflicting_attributes, &(Map.get(attributes, &1) != nil))

  defp shape_violations(call) do
    cond do
      Enum.any?(Map.keys(call), &(&1 not in @call_keys)) -> [v(:module_call_unknown_key)]
      is_nil(function_name(call)) -> [v(:module_call_malformed)]
      not is_map(Map.get(call, "args", %{})) -> [v(:module_call_malformed)]
      true -> []
    end
  end

  defp entry_violations(call, nodes, prefix, activator) do
    case entry(call) do
      {:error, :not_found} ->
        [v(:module_call_function_unknown)]

      {:ok, entry} ->
        case authority_violations(entry, activator) do
          [] -> detail_violations(entry, call, nodes, prefix)
          refused -> refused
        end
    end
  end

  # The activator's authority: the entry's permission, as the signed document will record it.
  # `catalogue_permissions` is what `Letflow.Definitions.Activator` resolved from the activator's
  # effective roles in THIS tenant, so a role dropped outside the platform tenant is not counted.
  defp authority_violations(_entry, nil), do: [v(:module_call_activator_required)]

  defp authority_violations(entry, activator) when is_map(activator) do
    held = Map.get(activator, :catalogue_permissions, [])

    if is_list(held) and Atom.to_string(entry.permission) in held,
      do: [],
      else: [v(:module_call_permission_required)]
  end

  defp authority_violations(_entry, _other), do: [v(:module_call_activator_required)]

  defp detail_violations(entry, call, nodes, prefix) do
    case tenant_violations(entry, prefix) do
      [] ->
        case source_violations(entry, call, nodes) ++ argument_violations(entry, call) do
          [] -> runtime_violations()
          refused -> refused
        end

      refused ->
        refused
    end
  end

  # P2b replaces this with `[]` when the run time of the step lands (see the moduledoc).
  defp runtime_violations do
    [v(:module_call_runtime_unavailable)]
  end

  defp tenant_violations(entry, prefix) do
    case ModuleTenantRule.check(entry, prefix) do
      :ok -> []
      {:error, :module_write_module_not_installed} -> [v(:module_call_module_not_installed)]
      {:error, :module_write_hash_mismatch} -> [v(:module_call_module_hash_mismatch)]
      {:error, :module_write_upgrade_required} -> [v(:module_call_module_upgrade_required)]
      {:error, _other} -> [v(:module_call_function_unknown)]
    end
  end

  # The T-2430 rule by source class, carried over (as `PlatformCalls.source_violations/3`): a
  # write-like entry reads no variable a human task of the graph may write, and the graph holds no
  # foreign source (an inline HTTP, script or sub-process node) that could overwrite a value the
  # entry reads. A pure `module_call` step and a well-formed notification step are not foreign.
  defp source_violations(entry, call, nodes) do
    if Entry.write_like?(entry) do
      completer_writable =
        nodes
        |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
        |> Enum.flat_map(&WriteTargets.completer_inputs/1)
        |> MapSet.new()

      cond do
        PlatformCalls.foreign_source_beside?(nodes, &pure_module_call?/1) ->
          [v(:module_call_foreign_source_refused)]

        Enum.any?(trusted_vars(call), &MapSet.member?(completer_writable, &1)) ->
          [v(:module_call_input_source_refused)]

        true ->
          []
      end
    else
      []
    end
  end

  defp pure_module_call?(%Graph.Node{attributes: attributes}) when is_map(attributes),
    do: Map.get(attributes, @attribute) != nil and not conflict?(attributes)

  defp pure_module_call?(_node), do: false

  defp argument_violations(entry, call) do
    args = Map.get(call, "args", %{})
    declared = Map.new(entry.inputs, &{&1.name, &1})

    unknown =
      for name <- Map.keys(args),
          not (is_binary(name) and Map.has_key?(declared, name)),
          do: v(:module_call_arg_unknown)

    missing =
      for {name, input} <- declared,
          input.required,
          not Map.has_key?(args, name),
          do: v(:module_call_arg_missing)

    source =
      for {_name, src} <- Map.to_list(args),
          code <- source_codes(src),
          do: v(code)

    unknown ++ missing ++ source
  end

  # The ONE parse of an argument source is the platform call's; its codes are renamed.
  defp source_codes(src), do: Enum.map(PlatformCalls.arg_source_codes(src), &rename/1)

  defp rename(:platform_call_arg_sys_reference), do: :module_call_arg_sys_reference
  defp rename(_other), do: :module_call_arg_source_invalid

  defp function_name(%{"function" => name}) when is_binary(name) do
    if String.trim(name) == "", do: nil, else: name
  end

  defp function_name(_call), do: nil

  # The `var` arguments of the inputs that may not come from a person.
  defp trusted_vars(call) when is_map(call) do
    args = Map.get(call, "args", %{})

    case entry(call) do
      {:ok, entry} when is_map(args) ->
        entry
        |> Entry.trusted_inputs()
        |> Enum.flat_map(fn input ->
          case Map.get(args, input.name) do
            %{"var" => var} when is_binary(var) -> [var]
            _other -> []
          end
        end)

      _no_entry ->
        []
    end
  end

  defp trusted_vars(_call), do: []
end
