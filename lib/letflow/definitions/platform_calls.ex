defmodule Letflow.Definitions.PlatformCalls do
  @moduledoc """
  The ACTIVATION-time validation of a SERVICE_TASK node's `platform_call`
  attribute -- the authority rule of gap G2 (T-2588; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (b)).

  ## The declaration

      attributes["platform_call"] :: %{"function" => name, "args" => %{arg_name => src}}
      src :: %{"var" => String.t()} | %{"const" => json}

  A `platform_call` step is a SERVICE_TASK bound to a platform function of the
  compiled catalogue (`Letflow.PlatformFunctions.Catalog`) instead of an HTTP
  endpoint or a Lua script. The step library (gap G1) owns the dispatcher that
  runs it; this module owns the RULE that decides who may switch such a step
  on, and where it may run.

  ## What activation proves

  A version may be activated with a `platform_call` step only when ALL hold:

    1. the definition lives in the PLATFORM tenant (`Letflow.PlatformTenant`);
    2. the function name resolves in the compiled catalogue NOW (no write
       route, no run-time registration);
    3. the ACTIVATOR holds the entry's permission (`:TenantsManage` for the
       tenant family), evaluated from the activator's effective roles in the
       platform tenant (INV-10);
    4. every argument matches the entry's declaration: a declared name, the
       required ones present, one well-formed source each, and no reserved
       engine key;
    5. a WRITE-LIKE entry (one whose side effects are more than a read) reads
       no variable that a human task of the same graph may write: the
       T-2430 rule carried over by source class, enforced the way
       `Letflow.Engine.WriteTargets` refuses such a key at run time.

  The signed `activated_by` document replaces the owner stamp for catalogue
  calls: instead of "unchanged since the module shipped it", the rule is
  "switched on by someone who holds the entry's permission, in the right
  tenant, with a signature checked at every call".

  ## The one code a company tenant ever sees

  A company-tenant definition that carries a `platform_call` step is refused
  with ONE fixed code, `:platform_call_not_allowed`, whatever the function is
  and whether or not it exists: the answer must not tell a stranger whether a
  platform function exists (INV-5). Every other refusal is reported only in
  the platform tenant.

  ## Pure and total

  No query, no clock, never raises: a malformed attribute is read as
  "declared and refused", so more is refused, never less.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Definitions.Graph
  alias Letflow.Engine.VariableMerge
  alias Letflow.Engine.WriteTargets
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformTenant

  @attribute "platform_call"
  @call_keys ["function", "args"]

  # The node types that may declare a `platform_call`: a SERVICE_TASK bound to
  # a platform function instead of an HTTP endpoint or a Lua script.
  @node_types [:SERVICE_TASK]

  # The node kinds that merge a value into the instance variables from OUTSIDE
  # the graph's own trusted inputs: an inline HTTP service task, a script-bound
  # service task, a sub-process (the child's completion output). A write-like
  # catalogue call reads its arguments from the start variables or from an
  # earlier platform step's output, so a foreign source in the same graph could
  # overwrite the value the call reads -- a source the T-2430 rule (which
  # compares the HUMAN TASK completer inputs) cannot see. The rule has the same
  # shape as the `module_writes` one (T-2444, `write_target_sources_scan_test`
  # WTS-4): "a service, script or sub-process node would add a source
  # `WriteTargets` cannot see".
  @foreign_source_types [:SERVICE_TASK, :SUB_PROCESS]

  @typedoc "One violation inside a node: a stable code."
  @type violation :: %{index: non_neg_integer(), code: atom()}

  @typedoc "One violation with the node it belongs to."
  @type node_violation :: %{node_id: String.t(), index: non_neg_integer(), code: atom()}

  @doc """
  The nodes of `nodes` that declare a `platform_call`, as `{node, raw_call}`,
  in graph order. A node whose attribute is present but malformed is declared
  (and refused), never skipped.
  """
  @spec declared_nodes([Graph.Node.t()]) :: [{Graph.Node.t(), term()}]
  def declared_nodes(nodes) when is_list(nodes) do
    for %Graph.Node{attributes: attributes} = node <- nodes,
        is_map(attributes),
        Map.has_key?(attributes, @attribute),
        Map.get(attributes, @attribute) != nil,
        do: {node, Map.get(attributes, @attribute)}
  end

  @doc """
  The violations of the graph's `platform_call` declarations for a path that has
  no activator -- the write path of a draft and the designer's validate route:
  the PLATFORM-TENANT rule only. A company tenant may not carry a platform call
  at all, so the answer is the one fixed code, whatever the function is.

  The permission of the entry is NOT checked here: only the activation path has
  the signed activator to check it against.
  """
  @spec tenant_violations([Graph.Node.t()], String.t()) :: [node_violation()]
  def tenant_violations(nodes, prefix) when is_list(nodes) and is_binary(prefix) do
    if PlatformTenant.platform_prefix?(prefix) do
      []
    else
      for node <- nodes,
          Map.has_key?(node.attributes || %{}, @attribute),
          Map.get(node.attributes, @attribute) != nil,
          do: %{node_id: node.id, index: 0, code: :platform_call_not_allowed}
    end
  end

  @doc """
  The sorted, de-duplicated names of the catalogue functions the declared steps
  call (well-formed calls only), for the `activated_by` document.
  """
  @spec function_names([{Graph.Node.t(), term()}]) :: [String.t()]
  def function_names(declared) do
    declared
    |> Enum.flat_map(fn {_node, call} ->
      case function_name(call) do
        nil -> []
        name -> [name]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The variable names the declared steps READ and that no person may write: the
  `var` arguments of the inputs whose source class is not `:person`. The
  engine refuses these keys in a task completion body (T-2430, extended to
  catalogue calls).
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
  True when the graph carries a FOREIGN SOURCE (an inline HTTP service task, a
  script-bound one or a sub-process) next to a WRITE-LIKE catalogue call.

  The dispatch-time twin of the activation refusal: the instance variables a
  running graph holds may already have been overwritten by such a node, so the
  call is refused before it runs. A read-like catalogue call is not affected --
  it reads nothing the platform writes.
  """
  @spec foreign_source_graph?(Graph.t() | [Graph.Node.t()] | term()) :: boolean()
  def foreign_source_graph?(%Graph{nodes: nodes}) when is_list(nodes),
    do: write_like_call?(nodes) and foreign_source?(nodes)

  def foreign_source_graph?(nodes) when is_list(nodes),
    do: write_like_call?(nodes) and foreign_source?(nodes)

  def foreign_source_graph?(_other), do: false

  @doc """
  True when the graph declares at least one `platform_call` step.
  """
  @spec declares_call?(Graph.t() | [Graph.Node.t()] | term()) :: boolean()
  def declares_call?(%Graph{nodes: nodes}) when is_list(nodes),
    do: declared_nodes(nodes) != []

  def declares_call?(nodes) when is_list(nodes), do: declared_nodes(nodes) != []
  def declares_call?(_other), do: false

  @doc """
  The permission atoms the declared steps require of the person who STARTS an
  instance of the definition: the entries' permissions, one atom per distinct
  permission. A definition with no `platform_call` step requires none.
  """
  @spec required_permissions([Graph.Node.t()]) :: [atom()]
  def required_permissions(nodes) when is_list(nodes) do
    nodes
    |> declared_nodes()
    |> Enum.flat_map(fn {_node, call} ->
      case entry(call) do
        {:ok, entry} -> [entry.permission]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The violations of one node's `platform_call`, in the order they are checked.
  `nodes` is the whole graph's node list (the human tasks of the same graph
  decide which variables a person may write); `prefix` is the tenant schema
  the definition lives in; `activator` is the signed authority of the person
  switching the version on (nil when there is none).
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

    if is_nil(call) do
      []
    else
      if PlatformTenant.platform_prefix?(prefix) do
        call_violations(call, node_type, nodes, activator)
      else
        # One fixed code for a company tenant: the answer must not tell whether
        # the function exists (INV-5).
        [%{index: 0, code: :platform_call_not_allowed}]
      end
    end
  end

  def violations(_node, _nodes, _prefix, _activator), do: []

  # ── the platform tenant ────────────────────────────────────────────────────────────────

  defp call_violations(call, node_type, nodes, activator) do
    cond do
      node_type not in @node_types ->
        [%{index: 0, code: :platform_call_node_type_not_supported}]

      not is_map(call) or is_struct(call) ->
        [%{index: 0, code: :platform_call_malformed}]

      true ->
        case entry(call) do
          {:error, :not_found} ->
            [%{index: 0, code: :platform_call_function_unknown}]

          {:ok, entry} ->
            shape_violations(call) ++
              authority_violations(entry, call, nodes, activator) ++
              argument_violations(entry, call)
        end
    end
  end

  # The attribute's own shape: closed keys, a non-blank function name, an args
  # map. A malformed attribute is refused, never guessed.
  defp shape_violations(call) do
    unknown_keys =
      Enum.any?(Map.keys(call), &(&1 not in @call_keys))

    cond do
      unknown_keys ->
        [%{index: 0, code: :platform_call_unknown_key}]

      is_nil(function_name(call)) ->
        [%{index: 0, code: :platform_call_malformed}]

      not is_map(Map.get(call, "args", %{})) ->
        [%{index: 0, code: :platform_call_malformed}]

      true ->
        []
    end
  end

  # ── the activator's authority ───────────────────────────────────────────────────────────

  defp authority_violations(_entry, _call, _nodes, nil),
    do: [%{index: 0, code: :platform_call_activator_required}]

  defp authority_violations(entry, call, nodes, activator) do
    if holds_permission?(activator, entry.permission) do
      source_violations(entry, call, nodes)
    else
      [%{index: 0, code: :platform_call_permission_required}]
    end
  end

  # The activator's effective roles are already resolved (PLATFORM_ADMIN is
  # dropped outside the platform tenant by `Letflow.Definitions.Activator`), so
  # the permission is evaluated from them in the platform tenant, which is the
  # only tenant a `platform_call` may live in.
  defp holds_permission?(%{user_id: user_id, roles: roles}, permission)
       when is_binary(user_id) and is_list(roles) do
    ctx = %Authorization.AccessContext{
      user_id: user_id,
      roles: Authorization.roles_from_strings(roles),
      platform_tenant?: true
    }

    Authorization.evaluate_access(ctx, permission).kind == :Allow
  end

  defp holds_permission?(_activator, _permission), do: false

  # ── the input source classes (the T-2430 rule carried over) ──────────────────────────────

  # A write-like entry reads no variable a human task of the same graph may
  # write: such a variable would let a person decide what the platform
  # function writes. The refusal is reported at activation, so the graph never
  # reaches a state where the engine has to refuse it at run time.
  #
  # The FOREIGN SOURCE rule (the same rule by source class, one step further):
  # a write-like entry also reads no variable a node outside the graph's own
  # trusted inputs may write. An inline HTTP service task, a script-bound one
  # and a sub-process all merge their own output into the same instance
  # variables, so they can overwrite the value the catalogue call reads -- a
  # source the human-task comparison above cannot see. A graph that carries a
  # write-like catalogue call therefore carries no foreign source at all.
  defp source_violations(entry, call, nodes) do
    if Entry.write_like?(entry) do
      completer_writable = completer_writable_keys(nodes)

      cond do
        foreign_source?(nodes) ->
          [%{index: 0, code: :platform_call_foreign_source_refused}]

        Enum.any?(trusted_vars(call), &(&1 in completer_writable)) ->
          [%{index: 0, code: :platform_call_input_source_refused}]

        true ->
          []
      end
    else
      []
    end
  end

  # True when the graph carries a node that merges a value into the instance
  # variables from outside its own trusted inputs. The `platform_call` step
  # itself is a SERVICE_TASK, so a node that DECLARES a platform call is not a
  # foreign source.
  defp foreign_source?(nodes) do
    Enum.any?(nodes, fn node ->
      node.node_type in @foreign_source_types and not declares_platform_call?(node)
    end)
  end

  # True when the graph declares a WRITE-LIKE catalogue call.
  defp write_like_call?(nodes) do
    nodes
    |> declared_nodes()
    |> Enum.any?(fn {_node, call} ->
      case entry(call) do
        {:ok, entry} -> Entry.write_like?(entry)
        {:error, _reason} -> false
      end
    end)
  end

  defp declares_platform_call?(%Graph.Node{attributes: attributes}) when is_map(attributes),
    do: Map.has_key?(attributes, @attribute) and Map.get(attributes, @attribute) != nil

  defp declares_platform_call?(_node), do: false

  # The variable names a human task of the graph may write: the `completer_inputs`
  # list and the `form_schema` properties of every HUMAN_TASK node.
  defp completer_writable_keys(nodes) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    |> Enum.flat_map(&WriteTargets.completer_inputs/1)
    |> MapSet.new()
  end

  # ── the arguments ──────────────────────────────────────────────────────────────────────

  defp argument_violations(entry, call) do
    args = Map.get(call, "args", %{})
    declared = Map.new(entry.inputs, &{&1.name, &1})

    unknown =
      for name <- Map.keys(args),
          not (is_binary(name) and Map.has_key?(declared, name)),
          do: %{index: 0, code: :platform_call_arg_unknown}

    missing =
      for {name, input} <- declared,
          input.required,
          not Map.has_key?(args, name),
          do: %{index: 0, code: :platform_call_arg_missing}

    source =
      for {_name, src} <- Map.to_list(args),
          code <- source_codes(src),
          do: %{index: 0, code: code}

    unknown ++ missing ++ source
  end

  defp source_codes(%{"var" => var} = src) when map_size(src) == 1 do
    cond do
      not (is_binary(var) and String.trim(var) != "") ->
        [:platform_call_arg_source_invalid]

      VariableMerge.reserved_key?(var) ->
        [:platform_call_arg_sys_reference]

      true ->
        []
    end
  end

  defp source_codes(%{"const" => _json} = src) when map_size(src) == 1, do: []
  defp source_codes(_other), do: [:platform_call_arg_source_invalid]

  # ── the catalogue ───────────────────────────────────────────────────────────────────────

  defp entry(call) when is_map(call) do
    case function_name(call) do
      nil -> {:error, :not_found}
      name -> Catalog.fetch(name)
    end
  end

  defp entry(_call), do: {:error, :not_found}

  defp function_name(%{"function" => name}) when is_binary(name) do
    if String.trim(name) == "", do: nil, else: name
  end

  defp function_name(_call), do: nil

  # The `var` arguments of the inputs that may not come from a person.
  defp trusted_vars(call) when is_map(call) do
    function_name = function_name(call)
    args = Map.get(call, "args", %{})

    if is_binary(function_name) do
      case Catalog.fetch(function_name) do
        {:ok, entry} ->
          entry
          |> Entry.trusted_inputs()
          |> Enum.flat_map(fn input ->
            case Map.get(args, input.name) do
              %{"var" => var} when is_binary(var) -> [var]
              _other -> []
            end
          end)

        {:error, :not_found} ->
          []
      end
    else
      []
    end
  end

  defp trusted_vars(_call), do: []
end
