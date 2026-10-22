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
  """

  @enforce_keys [:name, :function, :targets, :args]
  defstruct [:name, :function, :targets, :args]

  @type t :: %__MODULE__{
          name: String.t(),
          function: {module(), atom()},
          targets: [String.t()],
          args: %{String.t() => %{required: boolean()}}
        }

  @keys [:name, :function, :targets, :args]

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
      (missing = @keys -- keys) != [] -> {:error, {:missing_keys, missing}}
      true -> :ok
    end
  end

  defp check_fields(attrs) do
    case Enum.find(@keys, fn key -> not valid_field?(key, Map.fetch!(attrs, key)) end) do
      nil -> :ok
      key -> {:error, {:invalid_field, key}}
    end
  end

  defp valid_field?(:name, name),
    do: is_binary(name) and Letflow.Entities.ManagedTypes.managed_name?(name)

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
