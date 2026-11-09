defmodule Letflow.Modules.StepSpec do
  @moduledoc """
  The closed vocabulary of a declarative module migration step (REQ-773, decision 0055 D3).

  A `Letflow.Modules.Step` with `kind: :declarative` carries `up` as a map with atom keys:

      %{op: :set_default, type: "t", field: "f", value: scalar}
      %{op: :backfill_from_constant, type: "t", field: "f", value: scalar}
      %{op: :copy_field, type: "t", from: "a", to: "b", transform: :identity | :to_decimal | :trim | :upcase}

  `:rename_field` and `:settings_map` are named by the vocabulary but are not executed by the
  one-transaction apply: they validate as a map with that op and the apply refuses them
  (`upgrade_needs_runner`). Manifest steps are trusted module code, not tenant input; the checks
  here are still total (`validate/2` never raises on an arbitrary term, INV-8) and the type and
  field names must be identifiers, so the query layer can treat them as bound parameters only.

  The plan hash binds what a step does through `spec_hash/1`. Pure; no I/O.
  """

  alias Letflow.Entities.Definition.DDL

  @ops [:set_default, :backfill_from_constant, :copy_field, :rename_field, :settings_map]
  @executable [:set_default, :backfill_from_constant, :copy_field]
  @transforms [:identity, :to_decimal, :trim, :upcase]

  @doc "Every op name of the vocabulary."
  @spec ops() :: [atom()]
  def ops, do: @ops

  @doc "The ops the one-transaction apply executes."
  @spec executable_ops() :: [atom()]
  def executable_ops, do: @executable

  @doc "The closed list of `copy_field` transforms."
  @spec transforms() :: [atom()]
  def transforms, do: @transforms

  @doc """
  Whether `step.up` is a spec map this vocabulary governs (a map carrying an `:op` key). A
  declarative step whose `up` is anything else is an opaque legacy value: it is stored as before
  and the apply refuses it as needing a runner.
  """
  @spec spec?(term()) :: boolean()
  def spec?(%Letflow.Modules.Step{up: %{op: _op}}), do: true
  def spec?(_other), do: false

  @doc """
  `:ok` when `step` is a well-formed vocabulary step of `manifest` (a managed type, identifier
  names, no `x_` field, a scalar value, a transform of the closed list), else `:error`.
  """
  @spec validate(term(), map()) :: :ok | :error
  def validate(%Letflow.Modules.Step{up: %{op: op} = up}, manifest) when is_map(manifest) do
    managed = Map.get(manifest, :manages_entity_types, [])

    if op in @ops and valid_type?(up, managed) and valid_body?(op, up), do: :ok, else: :error
  end

  def validate(_step, _manifest), do: :error

  defp valid_type?(%{type: type}, managed) when is_binary(type) and is_list(managed),
    do: DDL.valid_identifier?(type) and type in managed

  defp valid_type?(_up, _managed), do: false

  defp valid_body?(op, %{field: field, value: value} = up)
       when op in [:set_default, :backfill_from_constant],
       do: map_size(up) == 4 and field_name?(field) and scalar?(value)

  defp valid_body?(:copy_field, %{from: from, to: to, transform: transform} = up),
    do:
      map_size(up) == 5 and field_name?(from) and field_name?(to) and from != to and
        transform in @transforms

  # Vocabulary names whose shape is owned by a later slice: an identifier-typed pair is enough.
  defp valid_body?(:rename_field, %{from: from, to: to} = up),
    do: map_size(up) == 4 and field_name?(from) and field_name?(to) and from != to

  defp valid_body?(:settings_map, up), do: map_size(up) >= 2
  defp valid_body?(_op, _up), do: false

  defp field_name?(name),
    do: is_binary(name) and DDL.valid_identifier?(name) and not String.starts_with?(name, "x_")

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  @doc "The op name for the plan report: a vocabulary op, `\"code\"`, or `\"other\"`."
  @spec op_name(Letflow.Modules.Step.t()) :: String.t()
  def op_name(%Letflow.Modules.Step{kind: :code}), do: "code"
  def op_name(%Letflow.Modules.Step{up: %{op: op}}) when op in @ops, do: Atom.to_string(op)
  def op_name(_step), do: "other"

  @doc "Whether the one-transaction apply can run this step (a validated executable op)."
  @spec executable?(Letflow.Modules.Step.t()) :: boolean()
  def executable?(%Letflow.Modules.Step{kind: :declarative, up: %{op: op}}),
    do: op in @executable

  def executable?(_step), do: false

  @doc """
  Applies a named transform to a value. `:identity` returns the value; `:trim` and `:upcase`
  accept binaries only; `:to_decimal` accepts a number or a numeric string and returns the
  canonical decimal string (parsed with `Decimal`, no float round trip). Anything else is `:error`.
  """
  @spec transform(atom(), term()) :: {:ok, term()} | :error
  def transform(:identity, value), do: {:ok, value}
  def transform(:trim, value) when is_binary(value), do: {:ok, String.trim(value)}
  def transform(:upcase, value) when is_binary(value), do: {:ok, String.upcase(value)}

  def transform(:to_decimal, value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {%Decimal{} = decimal, ""} -> finite(decimal)
      _other -> :error
    end
  end

  def transform(:to_decimal, value) when is_integer(value),
    do: finite(Decimal.new(value))

  def transform(:to_decimal, value) when is_float(value),
    do: finite(Decimal.from_float(value))

  def transform(_name, _value), do: :error

  defp finite(%Decimal{} = decimal) do
    if Decimal.inf?(decimal) or Decimal.nan?(decimal),
      do: :error,
      else: {:ok, Decimal.to_string(decimal, :normal)}
  end

  @doc "A stable SHA-256 hex of the step's `up` map (atoms stringified); binds the plan hash."
  @spec spec_hash(Letflow.Modules.Step.t()) :: String.t()
  def spec_hash(%Letflow.Modules.Step{up: up}) do
    up |> stringify() |> Letflow.Definitions.OwnerStamp.graph_hash()
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp stringify(other), do: other
end
