defmodule Letflow.Entities.Record.Decimals do
  @moduledoc """
  Exact decimal-string handling for `:decimal` entity fields that opt in with
  `decimal_strict: true` (GH #2654, decision
  `docs/migration/decisions/0060-decimal-strict-exact-string-fields.md`, design
  `lib/letflow/design/gh2654-decimal-exact-strings.md`). Pure: no database, no
  process.

  ## Opt-in, structurally

  A field without `decimal_strict: true` is invisible to this module:
  `strict_specs/1` returns `%{}` for a definition with no strict field and
  `normalize_field_values/2` / `prepass/2` then return their input untouched
  (design I6). Nothing here changes how a non-strict decimal field is
  validated, stored or read.

  ## Write grammar (strict fields only)

  A strict field accepts a **canonical decimal string** (`^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$`,
  at most 1100 bytes, checked before the regex or any `Decimal` call) or a **JSON
  integer** (magnitude pre-checked without building a power of ten beyond the
  field's precision). Every JSON float is refused (`type`): the body decoder has
  already turned it into a lossy float, so no float can be proven exact.

  The value is then checked, in this order, and at most one violation is
  reported per field per write: grammar/type (`"type"`), scale (`"scale"`: more
  fractional digits than `decimal_scale` after trailing zeros are dropped, never
  rounded), precision (`"precision"`: more integer digits than
  `decimal_precision - decimal_scale`), then `min`/`max`/`non_negative`
  (`"minimum"`/`"maximum"`), all compared with `Decimal.compare/2` (exact).
  The accepted value is rewritten to its canonical scale-padded string
  (`"2.5"` -> `"2.50"`, `3` -> `"3.00"`, `"-0.00"` -> `"0.00"`), which is what is
  stored, put in the event payload, fingerprinted and echoed.

  Violations carry `actual: nil` on purpose: the submitted value is never echoed
  (INV-2), including into `EXECUTION_ERROR` payloads that encode the struct.
  """

  alias Letflow.EventStore.Registry.ValidationFailure

  @max_string_bytes 1100
  @max_integer_bytes 425
  # Decimal.parse/1 has its own default digit limit; the 1100-byte cap above is ours.
  @parse_limits [max_digits: :infinity, max_exponent: :infinity]

  @typedoc "One strict field's write limits. `min`/`max` already fold `non_negative`."
  @type spec :: %{
          precision: pos_integer(),
          scale: non_neg_integer(),
          min: Decimal.t() | nil,
          max: Decimal.t() | nil
        }

  @type specs :: %{optional(String.t()) => spec()}

  @doc """
  The strict decimal fields of a definition document (atom-keyed `fields`, as
  `Letflow.Entities.Records` builds it): only a `:decimal` field with
  `decimal_strict == true` and an integer precision/scale. `%{}` otherwise.
  A non-parseable stored bound is ignored (INV-8), never raised on.
  """
  @spec strict_specs(map()) :: specs()
  def strict_specs(definition) when is_map(definition) do
    definition
    |> Map.get(:fields, [])
    |> Enum.reduce(%{}, fn field, acc ->
      case strict_spec(field) do
        {name, spec} -> Map.put(acc, name, spec)
        nil -> acc
      end
    end)
  end

  defp strict_spec(
         %{
           type: :decimal,
           decimal_strict: true,
           decimal_precision: precision,
           decimal_scale: scale
         } =
           field
       )
       when is_integer(precision) and is_integer(scale) and precision >= 1 and scale >= 0 do
    min = field |> Map.get(:min) |> bound_or_nil()
    max = field |> Map.get(:max) |> bound_or_nil()

    {Map.fetch!(field, :name),
     %{
       precision: precision,
       scale: scale,
       min: fold_non_negative(min, Map.get(field, :non_negative)),
       max: max
     }}
  end

  defp strict_spec(_field), do: nil

  defp bound_or_nil(value) do
    case bound(value) do
      {:ok, decimal} -> decimal
      :error -> nil
    end
  end

  # The effective minimum under `non_negative: true` is max(min, 0).
  defp fold_non_negative(min, true) do
    zero = Decimal.new(0)

    case min do
      nil -> zero
      %Decimal{} -> if Decimal.compare(min, zero) == :lt, do: zero, else: min
    end
  end

  defp fold_non_negative(min, _non_negative), do: min

  # The one grammar of a strict value (inline sigil: a compiled regex must not
  # live in a module attribute).
  defp canonical_grammar?(value),
    do: Regex.match?(~r/\A-?(0|[1-9][0-9]*)(\.[0-9]+)?\z/, value)

  @doc """
  Parses a strict write value against `precision`/`scale`. `{:ok, decimal}` is
  the exact value (not yet padded); the errors are the constraint names
  `:type`, `:scale`, `:precision`.
  """
  @spec parse(term(), pos_integer(), non_neg_integer()) ::
          {:ok, Decimal.t()} | {:error, :type | :scale | :precision}
  def parse(value, precision, scale) when is_binary(value) do
    with true <- byte_size(value) <= @max_string_bytes,
         true <- canonical_grammar?(value),
         {%Decimal{} = parsed, ""} <- Decimal.parse(value, @parse_limits) do
      check_digits(parsed, precision, scale)
    else
      _ -> {:error, :type}
    end
  end

  def parse(value, precision, scale) when is_integer(value) do
    cond do
      byte_size(:binary.encode_unsigned(abs(value))) > @max_integer_bytes -> {:error, :precision}
      abs(value) >= Integer.pow(10, precision - scale) -> {:error, :precision}
      true -> {:ok, normalise_zero(Decimal.new(value))}
    end
  end

  def parse(_value, _precision, _scale), do: {:error, :type}

  # Value-based digit counting on the reduced form: "2.500" at scale 2 is fine,
  # "2.505" is not; numeric(2,2) takes "0.99" and refuses "1.00".
  defp check_digits(%Decimal{} = parsed, precision, scale) do
    %Decimal{coef: coef, exp: exp} = reduced = reduce(parsed)
    fractional = max(-exp, 0)
    integer = if coef == 0, do: 0, else: max(digit_count(coef) + exp, 0)

    cond do
      fractional > scale -> {:error, :scale}
      integer > precision - scale -> {:error, :precision}
      true -> {:ok, normalise_zero(reduced)}
    end
  end

  # Strips trailing coefficient zeros (exact integer arithmetic; `Decimal.normalize/1`
  # applies the arithmetic context's 28-digit precision and must not be used here).
  defp reduce(%Decimal{coef: 0} = decimal), do: %Decimal{decimal | exp: 0}

  defp reduce(%Decimal{coef: coef, exp: exp} = decimal) when rem(coef, 10) == 0,
    do: reduce(%Decimal{decimal | coef: div(coef, 10), exp: exp + 1})

  defp reduce(%Decimal{} = decimal), do: decimal

  defp digit_count(coef), do: coef |> Integer.to_string() |> byte_size()

  # "-0" / "-0.00" -> unsigned zero.
  defp normalise_zero(%Decimal{coef: 0} = decimal), do: %Decimal{decimal | sign: 1}
  defp normalise_zero(%Decimal{} = decimal), do: decimal

  @doc """
  The plain-notation string of `decimal` with exactly `scale` fractional digits
  (scale 0: no dot). Integer arithmetic only. Precondition: `decimal` has at most
  `scale` fractional digits (what `parse/3` guarantees).
  """
  @spec to_canonical(Decimal.t(), non_neg_integer()) :: String.t()
  def to_canonical(%Decimal{} = decimal, scale) when is_integer(scale) and scale >= 0 do
    %Decimal{sign: sign, coef: coef, exp: exp} = reduce(decimal)
    shift = exp + scale

    scaled =
      if shift >= 0, do: coef * Integer.pow(10, shift), else: div(coef, Integer.pow(10, -shift))

    digits = Integer.to_string(scaled)
    sign_prefix = if sign == -1 and scaled != 0, do: "-", else: ""

    if scale == 0 do
      sign_prefix <> digits
    else
      {int_part, frac_part} =
        digits |> String.pad_leading(scale + 1, "0") |> String.split_at(-scale)

      sign_prefix <> int_part <> "." <> frac_part
    end
  end

  @doc """
  A `min`/`max` bound as a `Decimal`: an integer, a float, or a string of the
  strict grammar (same size cap). Anything else is `:error`.
  """
  @spec bound(term()) :: {:ok, Decimal.t()} | :error
  def bound(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  def bound(value) when is_float(value), do: {:ok, Decimal.from_float(value)}

  def bound(value) when is_binary(value) do
    with true <- byte_size(value) <= @max_string_bytes,
         true <- canonical_grammar?(value),
         {%Decimal{} = parsed, ""} <- Decimal.parse(value, @parse_limits) do
      {:ok, parsed}
    else
      _ -> :error
    end
  end

  def bound(_value), do: :error

  @doc """
  Validates and rewrites the strict fields of `field_values`. `{:ok, map}` holds
  every strict value as its canonical string; `{:error, failures}` lists one
  `ValidationFailure` per refused field. A definition with no strict field returns
  `{:ok, field_values}` untouched.
  """
  @spec normalize_field_values(map(), term()) :: {:ok, term()} | {:error, [ValidationFailure.t()]}
  def normalize_field_values(definition, field_values) do
    case prepass(definition, field_values) do
      {normalised, []} -> {:ok, normalised}
      {_schema_input, failures} -> {:error, failures}
    end
  end

  @doc """
  Like `normalize_field_values/2` but always returns a map: strict values that
  passed are canonical strings, a refused strict value is replaced by `""` (so
  the schema pass that follows reports nothing further about it), and the
  failures are returned beside it. `{field_values, []}` untouched when the
  definition has no strict field or `field_values` is not a map.
  """
  @spec prepass(map(), term()) :: {term(), [ValidationFailure.t()]}
  def prepass(definition, field_values) do
    specs = strict_specs(definition)

    if specs == %{} or not is_map(field_values) or is_struct(field_values) do
      {field_values, []}
    else
      Enum.reduce(specs, {field_values, []}, fn {name, spec}, {values, failures} ->
        case Map.fetch(values, name) do
          {:ok, value} when not is_nil(value) ->
            normalise_one(values, failures, name, value, spec)

          _absent_or_null ->
            {values, failures}
        end
      end)
    end
  end

  defp normalise_one(values, failures, name, value, spec) do
    with {:ok, parsed} <- parse(value, spec.precision, spec.scale),
         :ok <- check_bounds(parsed, spec) do
      {Map.put(values, name, to_canonical(parsed, spec.scale)), failures}
    else
      {:error, constraint} ->
        {Map.put(values, name, ""), failures ++ [failure(name, constraint)]}
    end
  end

  defp check_bounds(parsed, spec) do
    cond do
      spec.min != nil and Decimal.compare(parsed, spec.min) == :lt -> {:error, :minimum}
      spec.max != nil and Decimal.compare(parsed, spec.max) == :gt -> {:error, :maximum}
      true -> :ok
    end
  end

  defp failure(name, constraint) do
    %ValidationFailure{
      field_path: "/" <> String.replace(String.replace(name, "~", "~0"), "/", "~1"),
      constraint: Atom.to_string(constraint),
      actual: nil
    }
  end
end
