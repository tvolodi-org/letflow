defmodule Letflow.Definitions.PlatformCalls do
  @moduledoc """
  The ACTIVATION-time validation of a SERVICE_TASK node's `platform_call`
  attribute -- the authority rule of gap G2 (T-2588; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (b)).

  ## The declaration

      attributes["platform_call"] :: %{
        "function" => name,
        "args" => %{arg_name => src},
        "reads" => %{var_name => type_name},
        "writes" => %{var_name => type_name}
      }
      src :: %{"var" => String.t()} | %{"const" => json}

  A `platform_call` step is a SERVICE_TASK bound to a platform function of the
  compiled catalogue (`Letflow.PlatformFunctions.Catalog`) instead of an HTTP
  endpoint or a Lua script. The step library (gap G1) owns the dispatcher that
  runs it; this module owns the RULE that decides who may switch such a step
  on, and where it may run.

  ## The typed mapping of the step (gap G13)

  `reads` and `writes` are the step's TYPED MAPPING: the variables it reads
  and the variables it writes, each with its type. They are checked against
  the definition's own `variable_schemas` by
  `Letflow.Definitions.StepMapping`, at activation and in the designer. The
  dispatcher writes only the outputs the step declares.

  The two keys are REQUIRED: a step that declares none of them maps nothing
  and is refused. This module owns the SHAPE of the declaration (the closed
  key set above); the rules the declaration must satisfy live in
  `Letflow.Definitions.StepMapping`, so a notification step (gap G4) will use
  the same rules.

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
       `Letflow.Engine.WriteTargets` refuses such a key at run time;
    6. the node declares ONLY the platform-call route: no `endpoint`,
       `service_id` or `script_key` beside it. The step kinds are exclusive, so
       a closed catalogue call cannot dispatch as an outbound or script step.

  ## The foreign source, and the notification step beside it

  Rule 5 has a second half, one step further: a write-like entry also reads no
  variable a node OUTSIDE the graph's own trusted inputs may write. An inline
  HTTP service task, a script-bound one and a sub-process all merge their own
  output into the same instance variables, so they could overwrite the value
  the catalogue call reads -- a source the human-task comparison cannot see.
  A graph that carries a write-like catalogue call therefore carries no
  foreign source at all (code `:platform_call_foreign_source_refused`).

  A NOTIFICATION step (gap G4) is NOT a foreign source (T-2595, gap G9): it
  reads variables of the instance and writes NONE of them -- the notification
  leaves the process, it changes no variable. A node that merges nothing
  cannot overwrite anything, so the rule does not touch it. The exemption
  holds only for a node that routes itself by the `notify` attribute ALONE: a
  node that carries `notify` beside `endpoint`, `service_id` or `script_key` is
  refused by the notify fence (`:notify_conflicting_route`) and keeps the
  foreign-source rule, so the rule cannot be dodged by hanging a `notify`
  attribute on a node that really does call something.

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
  alias Letflow.Definitions.NotifyCalls
  alias Letflow.Engine.VariableMerge
  alias Letflow.Engine.WriteTargets
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformTenant

  @attribute "platform_call"
  @notify_attribute "notify"
  @call_keys ["function", "args", "reads", "writes"]
  @conflicting_route_attributes ["endpoint", "service_id", "script_key"]
  # `entity_writes` / `module_writes` on a platform_call node count as a second route: the
  # platform route plans no lines, so such a node would run its function and then be refused
  # when the result is applied. Refused at activation and at dispatch instead (T-2703). Kept
  # apart from the route list above: they route nothing by themselves, so they are not a
  # foreign source beside a call and do not cost a `notify` node its exemption.
  @platform_call_line_attributes ["entity_writes", "module_writes"]

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
  The platform call a node of `nodes` declares, as
  `{:ok, %{"function" => name, "args" => args, "reads" => ..., "writes" => ...}}`
  (the typed mapping of the step is part of the call, gap G13), or an error:

    * `:platform_call_node_missing` -- the graph carries no node of that id;
    * `:platform_call_node_not_declared` -- the node carries no well-formed
      `platform_call` attribute.

  This is the READ side of the binding between a dispatch row and the
  definition's graph: the step library's dispatcher (gap G1) re-derives the
  node's call from the STORED graph before it runs anything, so a row that
  names a function or arguments the definition does not declare is refused
  before the body runs.
  """
  @spec node_call_binding(Graph.t() | [Graph.Node.t()] | term(), term()) ::
          {:ok, map()} | {:error, atom()}
  def node_call_binding(nodes, node_id) when is_binary(node_id) do
    case Enum.find(node_list(nodes), &(&1.id == node_id)) do
      nil -> {:error, :platform_call_node_missing}
      node -> node_call(node)
    end
  end

  def node_call_binding(_nodes, _node_id), do: {:error, :platform_call_node_missing}

  defp node_list(%Graph{nodes: nodes}) when is_list(nodes), do: nodes
  defp node_list(nodes) when is_list(nodes), do: nodes
  defp node_list(_other), do: []

  # The node's call, in FULL: the function, the arguments and the typed
  # mapping (`reads` / `writes`). The binding the dispatcher reads is the
  # two-key projection below, so the shape it sees does not change with the
  # mapping; the mapping itself is read out of the same map by the
  # dispatcher's own `declared_writes/1`.
  defp node_call(%Graph.Node{attributes: attributes}) when is_map(attributes) do
    case Map.get(attributes, @attribute) do
      %{"function" => function, "args" => args} = call
      when is_binary(function) and function != "" and is_map(args) ->
        {:ok, call}

      _no_call ->
        {:error, :platform_call_node_not_declared}
    end
  end

  defp node_call(_node), do: {:error, :platform_call_node_not_declared}

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
  True when the graph carries a node that declares a `platform_call` and also
  carries an HTTP, catalogue-service or script route. Such a node is never a
  trusted platform step: the runtime would otherwise dispatch the other route
  while the source rules exempted the node as a closed catalogue call.
  """
  @spec conflicting_route_graph?(Graph.t() | [Graph.Node.t()] | term()) :: boolean()
  def conflicting_route_graph?(%Graph{nodes: nodes}) when is_list(nodes),
    do: Enum.any?(nodes, &conflicting_route?/1)

  def conflicting_route_graph?(nodes) when is_list(nodes),
    do: Enum.any?(nodes, &conflicting_route?/1)

  def conflicting_route_graph?(_other), do: false

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
        call_violations(call, node_type, attributes, nodes, activator)
      else
        # One fixed code for a company tenant: the answer must not tell whether
        # the function exists (INV-5).
        [%{index: 0, code: :platform_call_not_allowed}]
      end
    end
  end

  def violations(_node, _nodes, _prefix, _activator), do: []

  # ── the platform tenant ────────────────────────────────────────────────────────────────

  defp call_violations(call, node_type, attributes, nodes, activator) do
    cond do
      platform_call_conflict?(attributes) ->
        [%{index: 0, code: :conflicting_platform_call_routes}]

      node_type not in @node_types ->
        [%{index: 0, code: :platform_call_node_type_not_supported}]

      not is_map(call) or is_struct(call) ->
        [%{index: 0, code: :platform_call_malformed}]

      true ->
        case shape_violations(call) do
          [] ->
            case entry(call) do
              {:error, :not_found} ->
                [%{index: 0, code: :platform_call_function_unknown}]

              {:ok, entry} ->
                authority_violations(entry, call, nodes, activator) ++
                  argument_violations(entry, call)
            end

          violations ->
            violations
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
  # variables from outside its own trusted inputs. A PURE `platform_call` step
  # is exempt; a node that also carries an HTTP, catalogue-service or script
  # route is not, because that other route can merge its own output.
  #
  # A NOTIFICATION step is exempt too (T-2595, gap G9): it READS variables of
  # the instance and WRITES none of them -- the notification leaves the
  # process, it changes no variable (`Letflow.Definitions.NotifyCalls.mappings/1`
  # derives an empty write set for it, and the dispatcher never merges
  # anything). A node that merges nothing cannot overwrite the value a
  # catalogue call reads, so it is not the source the rule is about.
  #
  # The exemption holds only for a node that routes itself by the `notify`
  # attribute ALONE: a node that carries `notify` and another route
  # (`endpoint`, `service_id`, `script_key`) is refused by the notify fence
  # itself (`Letflow.Definitions.NotifyCalls`, code `:notify_conflicting_route`)
  # and keeps the foreign-source rule, so the rule cannot be dodged by hanging
  # a `notify` attribute on a node that really does call something.
  defp foreign_source?(nodes) do
    Enum.any?(nodes, fn node ->
      node.node_type in @foreign_source_types and
        (not declares_platform_call?(node) or conflicting_route?(node)) and
        not declares_notify?(node)
    end)
  end

  # The node declares a WELL-FORMED `notify` attribute and NOTHING else that
  # routes it. The declaration is parsed through the ONE parse the notify
  # fence uses (`Letflow.Definitions.NotifyCalls.parse/1`), so only a
  # declaration the notify fence itself accepts is exempt: a malformed one
  # keeps the foreign-source rule, and so does a node that routes itself by
  # something else as well.
  defp declares_notify?(%Graph.Node{attributes: attributes}) when is_map(attributes) do
    case Map.get(attributes, @notify_attribute) do
      raw when is_map(raw) and not is_struct(raw) ->
        match?({:ok, _declaration}, NotifyCalls.parse(raw)) and
          not conflicting_route_attributes?(attributes)

      _other ->
        false
    end
  end

  defp declares_notify?(_other), do: false

  defp conflicting_route?(%Graph.Node{attributes: attributes} = node) do
    declares_platform_call?(node) and platform_call_conflict?(attributes)
  end

  defp conflicting_route?(_node), do: false

  # Every caller already holds a map (both sit behind an `is_map/1` guard),
  # so there is no fallback clause: the compiler reports one as unreachable.
  defp conflicting_route_attributes?(attributes) when is_map(attributes) do
    Enum.any?(@conflicting_route_attributes, &(Map.get(attributes, &1) != nil))
  end

  defp platform_call_conflict?(attributes) when is_map(attributes) do
    conflicting_route_attributes?(attributes) or
      Enum.any?(@platform_call_line_attributes, &(Map.get(attributes, &1) != nil))
  end

  defp platform_call_conflict?(_attributes), do: false

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

      String.contains?(var, ".") ->
        # Instance variables are one flat namespace. Refusing a dotted name here
        # keeps G1's dispatcher from turning it into a path that would bypass
        # the exact top-level-key comparison of the person-writable source rule.
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

  @doc """
  The catalogue entry a call names, or `{:error, :not_found}`.

  The one lookup of the compiled catalogue for a call: the activation fence
  reads the entry's permission and its typed inputs and outputs from it, and
  the typed step mapping (gap G13) reads the entry's contract types from it.
  """
  @spec entry(map() | term()) :: {:ok, Entry.t()} | {:error, :not_found}
  def entry(call) when is_map(call) do
    case function_name(call) do
      nil -> {:error, :not_found}
      name -> Catalog.fetch(name)
    end
  end

  def entry(_call), do: {:error, :not_found}

  @doc """
  The TYPED MAPPING FACTS of every `platform_call` step of `nodes`, as
  `Letflow.Definitions.StepMapping` wants them: the declared reads and writes
  (or `:missing` when the step declares none), the variables the step really
  reads, the variables the entry lets it write, and the types the entry
  declares for them.

  A step whose function is not in the compiled catalogue still gets a mapping:
  its reads and writes are declared, but it has no contract, so nothing is
  written and the catalogue itself refuses the call with
  `:platform_call_function_unknown`.
  """
  @spec mappings([Graph.Node.t()]) :: [map()]
  def mappings(nodes) when is_list(nodes) do
    nodes
    |> declared_nodes()
    |> Enum.map(fn {node, call} -> mapping(node, call) end)
  end

  defp mapping(node, call) do
    {read_types, write_types, write_names} = contract(call)

    %{
      node_id: node.id,
      reads: declared_side(call, "reads"),
      writes: declared_side(call, "writes"),
      read_names: read_var_names(call),
      write_names: write_names,
      read_types: read_types,
      write_types: write_types
    }
  end

  # The contract of the call: the entry's typed inputs (the reads it may
  # name) and its typed outputs (the writes it may make).
  defp contract(call) do
    case entry(call) do
      {:ok, entry} ->
        read_types = Map.new(entry.inputs, &{&1.name, &1.type})
        write_types = Map.new(entry.outputs, &{&1.name, &1.type})

        {read_types, write_types, Map.keys(write_types)}

      {:error, :not_found} ->
        {%{}, %{}, []}
    end
  end

  defp declared_side(call, key) when is_map(call) do
    case Map.fetch(call, key) do
      {:ok, declared} -> declared
      :error -> :missing
    end
  end

  defp declared_side(_call, _key), do: :missing

  @doc """
  The variables a call READS: the names its `var` arguments name. Every one
  of them is read out of the instance variables when the call runs, so every
  one of them must be among the step's declared reads.
  """
  @spec read_var_names(map() | term()) :: [String.t()]
  def read_var_names(call) when is_map(call) do
    call
    |> Map.get("args", %{})
    |> Map.values()
    |> Enum.flat_map(fn
      %{"var" => var} when is_binary(var) -> [var]
      _other -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def read_var_names(_call), do: []

  @doc """
  The variable names a call DECLARES it writes, sorted. An empty list when the
  call declares no `writes` mapping: a step that declares no write writes
  nothing.
  """
  @spec declared_write_names(map() | term()) :: [String.t()]
  def declared_write_names(call) when is_map(call) do
    case Map.get(call, "writes") do
      declared when is_map(declared) -> declared |> Map.keys() |> Enum.sort()
      _absent_or_malformed -> []
    end
  end

  def declared_write_names(_call), do: []

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
