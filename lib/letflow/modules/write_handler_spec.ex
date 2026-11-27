defmodule Letflow.Modules.WriteHandlerSpec do
  @moduledoc """
  One write-handler registration a module declares in its manifest (GH #2651 /
  REQ-501 follow-up of R1 #2590): `name`, `function: {Mod, :fun}`, `targets` and
  `args`. It replaces the bare map the manifest used to carry; the shape rules
  are unchanged (see `t:Letflow.Modules.Module.write_handler_spec/0`).

  `new/1` is the validating constructor and returns `{:ok, spec}` or
  `{:error, reason}`; it checks the SHAPE of one entry only. The rules that
  need the rest of the manifest or the loaded code (targets within the module's
  managed types, handler module namespace, exported function) stay in
  `Letflow.Modules.Catalog` rule 10. The struct literal is accepted in a
  manifest too, so `Catalog` re-validates every entry through `valid?/1`.

  Errors, first one returned: `{:not_a_spec, value}` (neither a map nor a
  keyword list), `{:unknown_keys, keys}`, `{:missing_keys, keys}`,
  `{:invalid_field, key}`.

  `posts_ledger` (REQ-684, decision 0073) is the one optional key: the name of a registration of the
  same manifest's `:ledger` map, or `nil` (default). A handler that carries it is a posting handler;
  `Letflow.Modules.Catalog` rule 10 checks the name exists. It is not in `@enforce_keys`.

  `updates` (G2, decision 0054 R-update) is the other optional key: `%{entity_type => [field, ...]}`, the
  fields of a target type the handler may change through `Letflow.Entities.HandlerWrites.update/3`
  (default `%{}`: the handler updates nothing). `Catalog` rule 10 checks every key is one of the
  handler's `targets`. It is covered by the manifest hash only when non-empty.

  `reads` (REQ-829, decision 0073 D6, OQ-R4) is the last optional key: a list of entity type names the
  handler may read one record of by id through `Letflow.Entities.HandlerWrites.read/3` and `active?/3`
  (default `[]`: the handler reads nothing). `Catalog` rule 10 checks every type is managed by the
  handler's own module or by a module named in its `depends_on`. It is covered by the manifest hash
  only when non-empty.

  `reads_documents` (REQ-902, decision 0073 D6, L7 part 2b) is a boolean (default `false`): the handler
  may read one version of one document of its OWN module through
  `Letflow.Entities.HandlerWrites.read_document_version/3`. It is covered by the manifest hash only
  when `true`, so no existing manifest hash changes.

  ## The four catalogue fields (D-204, the module-process conversion, section 1.2)

  A write handler that opts into the MODULE FAMILY of the compiled platform function catalogue
  declares four more fields. They are the handler's half of a catalogue entry; the entry itself is
  DERIVED from them (`Letflow.PlatformFunctions.ModuleFamily`), never written by hand:

    * `permission` -- the permission atom the activator and the starter must hold. A handler
      WITHOUT it stays on the old owner-stamp path (`module_writes`) and is no catalogue entry.
      The atom must be one the module declares in its own `:permissions`;
    * `outputs` -- the typed names the call returns, as `[%{name: String.t(), type: atom()}]`
      (default `[]`);
    * `idempotency_inputs` -- the argument names that make a repeat the same call, as
      `[String.t()]` (default `[]`). Every one must be a REQUIRED argument of the handler, and a
      write-like handler must declare at least one;
    * `side_effect_classes` -- the classes of the call's side effects, as a list of atoms out of
      `[:read, :write_module_record, :ledger_post]` (default `[]`).

  The record (design `docs/design-module-process-conversion.md` 1.2) names the last field
  `side_effect_class` in the singular; the field carries a LIST here, because the record's own
  worked example (1.3, `stock.post_document`) puts TWO classes on one entry: `:write_module_record`
  and `:ledger_post`.

  The four fields are covered by the manifest hash only when present, so no existing manifest hash
  changes.
  """

  @enforce_keys [:name, :function, :targets, :args]
  defstruct [
    :name,
    :function,
    :targets,
    :args,
    posts_ledger: nil,
    updates: %{},
    reads: [],
    reads_documents: false,
    permission: nil,
    outputs: [],
    idempotency_inputs: [],
    side_effect_classes: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          function: {module(), atom()},
          targets: [String.t()],
          args: %{String.t() => %{required: boolean()}},
          posts_ledger: String.t() | nil,
          updates: %{optional(String.t()) => [String.t()]},
          reads: [String.t()],
          reads_documents: boolean(),
          permission: atom() | nil,
          outputs: [%{name: String.t(), type: atom()}],
          idempotency_inputs: [String.t()],
          side_effect_classes: [atom()]
        }

  @required_keys [:name, :function, :targets, :args]
  @optional_keys [
    :posts_ledger,
    :updates,
    :reads,
    :reads_documents,
    :permission,
    :outputs,
    :idempotency_inputs,
    :side_effect_classes
  ]
  @keys @required_keys ++ @optional_keys

  @doc "Builds a spec from a map or keyword list, rejecting missing, unknown or ill-typed fields."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, {atom(), term()}}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: {:error, {:not_a_spec, attrs}}
  end

  def new(attrs) when is_map(attrs) do
    attrs = if is_struct(attrs), do: Map.from_struct(attrs), else: attrs

    with :ok <- check_keys(attrs),
         :ok <- check_fields(attrs) do
      {:ok, struct!(__MODULE__, Map.take(attrs, @keys))}
    end
  end

  def new(other), do: {:error, {:not_a_spec, other}}

  @doc "True when `value` is a `#{inspect(__MODULE__)}` whose fields all pass `new/1`."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = spec), do: match?({:ok, _}, new(spec))
  def valid?(_other), do: false

  defp check_keys(attrs) do
    keys = Map.keys(attrs)

    cond do
      (unknown = keys -- @keys) != [] -> {:error, {:unknown_keys, unknown}}
      (missing = @required_keys -- keys) != [] -> {:error, {:missing_keys, missing}}
      true -> :ok
    end
  end

  defp check_fields(attrs) do
    present = Enum.filter(@keys, &Map.has_key?(attrs, &1))

    case Enum.find(present, fn key -> not valid_field?(key, Map.fetch!(attrs, key)) end) do
      nil -> :ok
      key -> {:error, {:invalid_field, key}}
    end
  end

  defp valid_field?(:name, name),
    do: is_binary(name) and Letflow.Entities.ManagedTypes.managed_name?(name)

  defp valid_field?(:posts_ledger, value), do: is_nil(value) or is_binary(value)

  # D-204: the permission atom the activator and the starter must hold. A
  # handler without one is no catalogue entry (it stays on the owner-stamp
  # path), so `nil` is the "not in the module family" marker.
  defp valid_field?(:permission, value), do: is_nil(value) or is_atom(value)

  defp valid_field?(:outputs, outputs) when is_list(outputs) do
    Enum.all?(outputs, fn output ->
      is_map(output) and not is_struct(output) and map_size(output) == 2 and
        Map.has_key?(output, :name) and Map.has_key?(output, :type) and
        is_binary(Map.get(output, :name)) and Map.get(output, :name) != "" and
        is_atom(Map.get(output, :type))
    end)
  end

  defp valid_field?(:outputs, _other), do: false

  defp valid_field?(:idempotency_inputs, inputs),
    do: is_list(inputs) and Enum.all?(inputs, &is_binary/1) and Enum.uniq(inputs) == inputs

  defp valid_field?(:side_effect_classes, classes),
    do: is_list(classes) and Enum.all?(classes, &is_atom/1) and Enum.uniq(classes) == classes

  defp valid_field?(:updates, updates) when is_map(updates) and not is_struct(updates) do
    Enum.all?(updates, fn {type, fields} ->
      is_binary(type) and is_list(fields) and fields != [] and Enum.all?(fields, &is_binary/1) and
        Enum.uniq(fields) == fields
    end)
  end

  defp valid_field?(:updates, _other), do: false

  defp valid_field?(:reads, reads),
    do: is_list(reads) and Enum.all?(reads, &is_binary/1) and Enum.uniq(reads) == reads

  defp valid_field?(:reads_documents, value), do: is_boolean(value)

  defp valid_field?(:function, {module, fun}), do: is_atom(module) and is_atom(fun)
  defp valid_field?(:function, _other), do: false

  defp valid_field?(:targets, targets),
    do: is_list(targets) and Enum.all?(targets, &is_binary/1) and Enum.uniq(targets) == targets

  defp valid_field?(:args, args) when is_map(args) and not is_struct(args) do
    Enum.all?(args, fn
      {name, %{required: required} = spec} ->
        is_binary(name) and is_boolean(required) and map_size(spec) == 1

      _ ->
        false
    end)
  end

  defp valid_field?(:args, _other), do: false
end
