defmodule Letflow.Modules.Procurement.PurchaseRequest do
  @moduledoc """
  Pure validation and exact totals of a purchase request (GH #3162, REQ-544 criteria 1, 2, 3).
  No database: the two reference reads are injected as `lookups`, so the rules are unit-testable.

  `build/3` takes the string-keyed client params, the authenticated actor and
  `%{unit: fun, department: fun}`; each fun takes the client's id and answers
  `{:ok, canonical_id} | :unknown | :retired`. It returns `{:ok, content}` (string keys, no floats,
  decimals as normalized strings, ready for `Letflow.Documents`) or
  `{:error, {:validation, errors}}`.

  `errors` is every problem at once, `[%{field: "lines[2].quantity", code: "invalid"}]`, sorted by
  field then code. Codes: `required`, `invalid`, `unknown`, `retired`, `mismatch`. A value the client
  sent is never echoed. Unknown keys are ignored and never copied: the content is built from the
  field whitelist only. A client `total` or `line_total` is accepted only when it equals the
  calculated value (`mismatch` otherwise); the stored value is always the calculated one.

  Decimals: the accepted lexical form is `^[0-9]+(\\.[0-9]+)?$` (or a non-negative integer), checked
  before `Decimal.new/1`, so exponent, sign, NaN and spaces are `invalid`. The caps below keep every
  product and the sum of all lines within the default 28-digit `Decimal` context, so no rounding can
  happen and the totals are exact. No float is used anywhere.
  """

  @priorities ~w(low normal high urgent)
  @kinds ~w(material work service)
  @decimal_re ~r/\A[0-9]+(\.[0-9]+)?\z/

  # Assumed closed lists and caps (REQ-544 leaves them as open questions for the process owner).
  # Quantity < 1e6 and cost < 1e9 with 4 decimals keep every product and the 200-line sum inside
  # the default 28-digit Decimal context.
  @max_lines 200
  @max_fraction 4
  @justification_max 4000
  @description_max 500
  @long_text_max 2000
  @quantity_max Decimal.new(1_000_000)
  @cost_max Decimal.new(1_000_000_000)

  @type error :: %{field: String.t(), code: String.t()}
  @type lookup_result :: {:ok, String.t()} | :unknown | :retired
  @type lookups :: %{unit: (term() -> lookup_result()), department: (term() -> lookup_result())}

  @doc "The accepted priorities."
  def priorities, do: @priorities

  @doc "The accepted line kinds."
  def kinds, do: @kinds

  @spec build(term(), term(), lookups()) :: {:ok, map()} | {:error, {:validation, [error()]}}
  def build(params, actor_id, lookups)

  def build(params, actor_id, lookups) when is_map(params) and not is_struct(params) do
    if Enum.all?(Map.keys(params), &is_binary/1) do
      do_build(params, actor_id, lookups)
    else
      {:error, {:validation, [err("params", "invalid")]}}
    end
  end

  def build(_params, _actor_id, _lookups), do: {:error, {:validation, [err("params", "invalid")]}}

  defp do_build(params, actor_id, lookups) do
    {content, errors} =
      {%{}, []}
      |> requester(params, actor_id)
      |> reference("department_id", params, lookups.department)
      |> put("justification", text(params["justification"], @justification_max))
      |> put("required_date", date(params["required_date"]))
      |> put("priority", enum(params["priority"], @priorities))

    {lines, line_errors} = lines(params["lines"], lookups)

    {content, errors} = {Map.put(content, "lines", lines), errors ++ line_errors}

    {content, errors} =
      if line_errors == [] and lines != [] do
        totals(content, lines, params["total"], errors)
      else
        {content, errors}
      end

    case errors do
      [] ->
        {:ok, content}

      errors ->
        {:error, {:validation, errors |> Enum.uniq() |> Enum.sort_by(&{&1.field, &1.code})}}
    end
  end

  # -- top level ---------------------------------------------------------------------------

  defp requester({content, errors}, params, actor_id) do
    case actor_id do
      id when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} ->
            case params["requester"] do
              nil -> {Map.put(content, "requester", uuid), errors}
              ^uuid -> {Map.put(content, "requester", uuid), errors}
              _other -> {content, [err("requester", "mismatch") | errors]}
            end

          :error ->
            {content, [err("requester", "required") | errors]}
        end

      _other ->
        {content, [err("requester", "required") | errors]}
    end
  end

  defp reference({content, errors}, key, params, fun) do
    case reference_value(params[key], fun) do
      {:ok, id} -> {Map.put(content, key, id), errors}
      {:error, code} -> {content, [err(key, code) | errors]}
    end
  end

  defp reference_value(value, fun) do
    case blank_or_type(value) do
      {:error, _code} = error ->
        error

      :ok ->
        case fun.(value) do
          {:ok, id} -> {:ok, id}
          :retired -> {:error, "retired"}
          _unknown -> {:error, "unknown"}
        end
    end
  end

  defp blank_or_type(nil), do: {:error, "required"}

  defp blank_or_type(value) when is_binary(value),
    do: if(String.trim(value) == "", do: {:error, "required"}, else: :ok)

  defp blank_or_type(_value), do: {:error, "invalid"}

  defp put({content, errors}, key, {:ok, value}), do: {Map.put(content, key, value), errors}
  defp put({content, errors}, key, {:error, code}), do: {content, [err(key, code) | errors]}

  # -- lines -------------------------------------------------------------------------------

  defp lines(nil, _lookups), do: {[], [err("lines", "required")]}
  defp lines([], _lookups), do: {[], [err("lines", "required")]}

  defp lines(list, lookups) when is_list(list) do
    if length(list) > @max_lines do
      {[], [err("lines", "invalid")]}
    else
      cache = distinct_units(list, lookups.unit)

      {lines, errors} =
        list
        |> Enum.with_index(1)
        |> Enum.map(fn {line, n} -> line(line, n, cache) end)
        |> Enum.unzip()

      {Enum.reject(lines, &is_nil/1), List.flatten(errors)}
    end
  end

  defp lines(_other, _lookups), do: {[], [err("lines", "invalid")]}

  # One read per distinct unit id.
  defp distinct_units(list, fun) do
    list
    |> Enum.flat_map(fn
      %{"unit_id" => id} when is_binary(id) -> if String.trim(id) == "", do: [], else: [id]
      _other -> []
    end)
    |> Enum.uniq()
    |> Map.new(fn id -> {id, fun.(id)} end)
  end

  defp line(line, n, cache) when is_map(line) and not is_struct(line) do
    prefix = "lines[#{n}]."
    kind = enum(line["kind"], @kinds)

    {content, errors} =
      {%{"line_no" => n}, []}
      |> put("kind", kind)
      |> put("description", text(line["description"], @description_max))
      |> put("quantity", decimal(line["quantity"], @quantity_max, :positive))
      |> unit(line["unit_id"], cache)
      |> put(
        "estimated_unit_cost",
        decimal(line["estimated_unit_cost"], @cost_max, :non_negative)
      )

    {content, errors} =
      case kind do
        {:ok, k} when k in ["work", "service"] ->
          {content, errors}
          |> put("scope", text(line["scope"], @long_text_max))
          |> put("deliverables", text(line["deliverables"], @long_text_max))
          |> put("completion_date", date(line["completion_date"]))

        _other ->
          {content, errors}
      end

    {content, errors} = line_total(content, errors, line["line_total"])

    errors = Enum.map(errors, fn e -> %{e | field: prefix <> e.field} end)

    if errors == [], do: {content, []}, else: {nil, errors}
  end

  defp line(_other, n, _cache), do: {nil, [err("lines[#{n}]", "invalid")]}

  defp unit({content, errors}, value, cache) do
    case blank_or_type(value) do
      {:error, code} ->
        {content, [err("unit_id", code) | errors]}

      :ok ->
        case Map.fetch!(cache, value) do
          {:ok, id} -> {Map.put(content, "unit_id", id), errors}
          :retired -> {content, [err("unit_id", "retired") | errors]}
          _unknown -> {content, [err("unit_id", "unknown") | errors]}
        end
    end
  end

  defp line_total(content, errors, client) do
    with %{"quantity" => q, "estimated_unit_cost" => c} <- content do
      total = Decimal.mult(Decimal.new(q), Decimal.new(c))
      content = Map.put(content, "line_total", normalize(total))
      {content, client_total(errors, "line_total", client, total)}
    else
      _incomplete -> {content, errors}
    end
  end

  # -- totals ------------------------------------------------------------------------------

  defp totals(content, lines, client, errors) do
    total =
      Enum.reduce(lines, Decimal.new(0), fn l, acc ->
        Decimal.add(acc, Decimal.new(l["line_total"]))
      end)

    errors = client_total(errors, "total", client, total)
    {Map.put(content, "total", normalize(total)), errors}
  end

  defp client_total(errors, _field, nil, _calculated), do: errors

  defp client_total(errors, field, client, calculated) do
    case parse_decimal(client) do
      {:ok, d} ->
        if Decimal.equal?(d, calculated), do: errors, else: [err(field, "mismatch") | errors]

      :error ->
        [err(field, "invalid") | errors]
    end
  end

  # -- field parsers -----------------------------------------------------------------------

  defp text(value, max) do
    case blank_or_type(value) do
      :ok ->
        trimmed = String.trim(value)
        if String.length(trimmed) > max, do: {:error, "invalid"}, else: {:ok, trimmed}

      error ->
        error
    end
  end

  defp enum(value, allowed) do
    case blank_or_type(value) do
      :ok -> if value in allowed, do: {:ok, value}, else: {:error, "invalid"}
      error -> error
    end
  end

  defp date(value) do
    case blank_or_type(value) do
      :ok ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, Date.to_iso8601(date)}
          _bad -> {:error, "invalid"}
        end

      error ->
        error
    end
  end

  # A field value: a non-negative integer or a decimal string; `max` is the exclusive upper bound.
  defp decimal(nil, _max, _min), do: {:error, "required"}

  defp decimal(value, max, min) do
    case parse_decimal(value) do
      {:ok, d} ->
        if Decimal.compare(d, max) == :lt and above_min?(d, min) and
             fraction_digits(value) <= @max_fraction,
           do: {:ok, normalize(d)},
           else: {:error, "invalid"}

      :error ->
        case blank_or_type(value) do
          {:error, "required"} -> {:error, "required"}
          _other -> {:error, "invalid"}
        end
    end
  end

  defp above_min?(d, :positive), do: Decimal.gt?(d, 0)
  defp above_min?(_d, :non_negative), do: true

  defp parse_decimal(value) when is_integer(value) and value >= 0, do: {:ok, Decimal.new(value)}

  defp parse_decimal(value) when is_binary(value) and byte_size(value) <= 40 do
    if Regex.match?(@decimal_re, value), do: {:ok, Decimal.new(value)}, else: :error
  end

  defp parse_decimal(_other), do: :error

  defp fraction_digits(value) when is_binary(value) do
    case String.split(value, ".") do
      [_int, frac] -> String.length(frac)
      _none -> 0
    end
  end

  defp fraction_digits(_integer), do: 0

  defp normalize(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp err(field, code), do: %{field: field, code: code}
end
