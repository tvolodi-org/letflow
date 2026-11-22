defmodule Letflow.Definitions.NotifyCalls do
  @moduledoc """
  The NOTIFICATION STEP of a process definition (T-2592, pilot gap G4 -- the
  "Register a tenant" pilot): a SERVICE_TASK node that carries a `notify`
  attribute instead of an HTTP endpoint, a catalogue service, a Lua script or a
  platform call.

  A notification is CONFIGURATION, never a script: the step says WHICH registered
  template to send, WHERE to send it (an address read from a variable) and WHAT
  to put in it (the declared values). There is no code in the step and there is
  nothing to review but a template key and a set of variable names.

  ## The declaration

      attributes["notify"] :: %{
        "template_key" => "tenant_registered",
        "recipient" => %{"var" => "admin_email"},
        "values" => %{
          "tenant_name" => %{"var" => "tenant_name"},
          "tenant_slug" => %{"const" => "acme"}
        }
      }

  ## The rules

    1. the node carries a `notify` attribute and NOTHING else that routes it:
       no `endpoint`, no `service_id`, no `script_key`, no `platform_call`. The
       step kinds are exclusive, so a node that carries two of them would run
       one of them and be exempt from the rules of the other;
    2. the `template_key` names a REGISTERED template
       (`Letflow.NotificationTemplates.Registry`). A tenant may override the
       text of a key; it may not invent one;
    3. the RECIPIENT is a VARIABLE, never a constant. A constant address would
       sit in the stored definition of the tenant, and the address of a person
       is personal data that the platform does not store (INV-4). The address is
       read from the instance variables at dispatch time and is not written
       anywhere: not in the definition, not in the delivery log;
    4. every value names a placeholder of the template's allow-list. A value
       the template does not know is refused rather than silently dropped;
    5. a value or a recipient may not name a variable that a person may write
       (the T-2430 rule): the address of the recipient and the text of the
       message are decided by the person who started the process, not by the
       person who completes a task in it.

  ## Pure and total

  `parse/1` is the ONE parse of the attribute: the activation rule and the
  dispatcher both read the declaration through it, so a step that passed
  activation cannot be read differently at dispatch time. It never queries,
  never raises and never logs the attribute it was given.
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Engine.VariableMerge
  alias Letflow.NotificationTemplates.Registry

  @attribute "notify"
  @call_keys ["template_key", "recipient", "values"]
  @conflicting_route_attributes ["endpoint", "service_id", "script_key", "platform_call"]

  @node_types [:SERVICE_TASK]

  # The byte caps of the declaration's own strings. They come out of the stored
  # definition, so they are bounded before anything else looks at them (SF-01).
  @max_template_key_bytes 64
  @max_var_name_bytes 255
  @max_const_bytes 4096

  @typedoc "One source of a value: a variable of the instance or a constant."
  @type source :: {:var, String.t()} | {:const, String.t()}

  @typedoc "The parsed declaration of a notification step."
  @type declaration :: %{
          template_key: String.t(),
          recipient_var: String.t(),
          values: %{String.t() => source()}
        }

  @typedoc "One violation inside a node: a stable code."
  @type violation :: %{index: non_neg_integer(), code: atom()}

  @doc """
  The nodes of `nodes` that declare a `notify` attribute, as `{node, raw}`, in
  graph order. A node whose attribute is present but malformed is DECLARED (and
  refused), never skipped.
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
  The ONE parse of a `notify` attribute.

  `{:ok, declaration}` or `{:error, code}`. The codes are stable:

    * `:notify_malformed` -- the attribute is not a map, or a key is missing;
    * `:notify_unknown_key` -- the attribute carries a key that is not part of
      the declaration;
    * `:notify_template_unknown` -- the template key is not a registered one;
    * `:notify_recipient_invalid` -- the recipient is not a well-formed variable
      source (a constant address is refused with this code too: the address
      must not sit in the stored definition, INV-4);
    * `:notify_value_unknown` -- a value names a placeholder the template does
      not allow;
    * `:notify_value_source_invalid` -- a value's source is malformed;
    * `:notify_value_missing` -- a required value is not declared.

  The parse is pure: it never raises and never logs the attribute.
  """
  @spec parse(term()) :: {:ok, declaration()} | {:error, atom()}
  def parse(raw) when is_map(raw) and not is_struct(raw) do
    with :ok <- closed_keys(raw),
         {:ok, template_key} <- template_key(raw),
         {:ok, recipient_var} <- recipient(raw),
         {:ok, values} <- values(raw, template_key) do
      {:ok,
       %{
         template_key: template_key,
         recipient_var: recipient_var,
         values: values
       }}
    end
  end

  def parse(_raw), do: {:error, :notify_malformed}

  @doc """
  The violations of one node's `notify` declaration, in the order they are
  checked. `nodes` is the whole graph's node list (the human tasks of the same
  graph decide which variables a person may write).

  The node type must be SERVICE_TASK, and the node may not carry another route
  beside the `notify` attribute.
  """
  @spec violations(Graph.Node.t(), [Graph.Node.t()]) :: [violation()]
  def violations(%Graph.Node{node_type: node_type, attributes: attributes}, nodes)
      when is_list(nodes) do
    raw = if is_map(attributes), do: Map.get(attributes, @attribute), else: nil

    if is_nil(raw) do
      []
    else
      cond do
        conflicting_route?(attributes) ->
          [%{index: 0, code: :notify_conflicting_route}]

        node_type not in @node_types ->
          [%{index: 0, code: :notify_node_type_not_supported}]

        true ->
          case parse(raw) do
            {:ok, declaration} ->
              person_writable_violations(declaration, nodes)

            {:error, code} ->
              [%{index: 0, code: code}]
          end
      end
    end
  end

  def violations(_node, _nodes), do: []

  @doc """
  The variable names the declared steps READ: the recipient's variable and the
  variables of the values. The engine refuses these keys in a task completion
  body (the T-2430 rule, carried to the notification step).
  """
  @spec read_keys([Graph.Node.t()]) :: [String.t()]
  def read_keys(nodes) when is_list(nodes) do
    nodes
    |> declared_nodes()
    |> Enum.flat_map(fn {_node, raw} ->
      case parse(raw) do
        {:ok, declaration} ->
          [declaration.recipient_var] ++
            Enum.map(declaration.values, fn {_name, source} -> source_var(source) end)

        {:error, _code} ->
          []
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ── the shape of the attribute ───────────────────────────────────────────────────────────

  defp closed_keys(raw) do
    cond do
      not Map.has_key?(raw, "template_key") -> {:error, :notify_malformed}
      not Map.has_key?(raw, "recipient") -> {:error, :notify_malformed}
      not Map.has_key?(raw, "values") -> {:error, :notify_malformed}
      Enum.any?(Map.keys(raw), &(&1 not in @call_keys)) -> {:error, :notify_unknown_key}
      true -> :ok
    end
  end

  defp template_key(raw) do
    case Map.get(raw, "template_key") do
      key when is_binary(key) and byte_size(key) <= @max_template_key_bytes ->
        case Registry.fetch(key) do
          {:ok, _entry} -> {:ok, key}
          :error -> {:error, :notify_template_unknown}
        end

      _other ->
        {:error, :notify_template_unknown}
    end
  end

  # The recipient is a VARIABLE. A constant address would sit in the stored
  # definition of the tenant (INV-4), so it is refused with the same code as a
  # malformed one: the answer must not tell the author which mistake it was.
  defp recipient(raw) do
    case Map.get(raw, "recipient") do
      %{"var" => var} = source when map_size(source) == 1 ->
        if valid_var_name?(var) do
          {:ok, var}
        else
          {:error, :notify_recipient_invalid}
        end

      _other ->
        {:error, :notify_recipient_invalid}
    end
  end

  defp values(raw, template_key) do
    case Map.get(raw, "values") do
      values when is_map(values) and not is_struct(values) ->
        allowed = Registry.placeholders(template_key)

        parsed =
          Enum.reduce_while(values, {:ok, %{}}, fn {name, source}, {:ok, acc} ->
            cond do
              not (is_binary(name) and name != "") ->
                {:halt, {:error, :notify_value_unknown}}

              name not in allowed ->
                {:halt, {:error, :notify_value_unknown}}

              true ->
                case source(source) do
                  {:ok, parsed_source} -> {:cont, {:ok, Map.put(acc, name, parsed_source)}}
                  {:error, code} -> {:halt, {:error, code}}
                end
            end
          end)

        parsed

      _other ->
        {:error, :notify_malformed}
    end
  end

  defp source(%{"var" => var} = src) when map_size(src) == 1 do
    if valid_var_name?(var) do
      {:ok, {:var, var}}
    else
      {:error, :notify_value_source_invalid}
    end
  end

  defp source(%{"const" => const} = src) when map_size(src) == 1 do
    if is_binary(const) and byte_size(const) <= @max_const_bytes do
      {:ok, {:const, const}}
    else
      {:error, :notify_value_source_invalid}
    end
  end

  defp source(_other), do: {:error, :notify_value_source_invalid}

  # A variable name is a plain top-level key of the instance variables: not
  # empty, not dotted (the instance variables are one flat namespace) and not a
  # reserved engine key.
  defp valid_var_name?(var) when is_binary(var) do
    byte_size(var) > 0 and byte_size(var) <= @max_var_name_bytes and
      not String.contains?(var, ".") and not VariableMerge.reserved_key?(var)
  end

  defp valid_var_name?(_var), do: false

  # ── the person may not decide the address or the text ───────────────────────────────────

  # The T-2430 rule: a person who completes a task in the same graph may write
  # the variables the node lists as its inputs. Such a variable would let that
  # person decide where the message goes and what it says. The engine refuses
  # those keys in a completion body; the activation rule refuses the step.
  defp person_writable_violations(declaration, nodes) do
    writable = completer_writable_keys(nodes)

    read =
      [declaration.recipient_var] ++
        Enum.map(declaration.values, fn {_name, source} -> source_var(source) end)

    if Enum.any?(read, &(&1 in writable)) do
      [%{index: 0, code: :notify_input_source_refused}]
    else
      []
    end
  end

  defp completer_writable_keys(nodes) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    |> Enum.flat_map(&Letflow.Engine.WriteTargets.completer_inputs/1)
    |> MapSet.new()
  end

  defp source_var({:var, var}), do: var
  defp source_var({:const, _const}), do: nil

  defp conflicting_route?(attributes) when is_map(attributes) do
    Enum.any?(@conflicting_route_attributes, &(Map.get(attributes, &1) != nil))
  end

  defp conflicting_route?(_attributes), do: false
end
