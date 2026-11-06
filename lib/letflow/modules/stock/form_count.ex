defmodule Letflow.Modules.Stock.FormCount do
  @moduledoc """
  T-1418 (phase E, E5d): the small helpers the official count forms share (`FormCountInv18` and
  `FormCountInv10`; `FormZ2` uses `date/1`). Pure: they read the output of
  `CountPaperworkSource.read_form/4` and invent nothing; what Letflow does not hold stays absent
  from the data map and prints as a blank line.
  """

  alias Letflow.Modules.Stock.CountPaperwork

  @doc "The text of any stored value (`nil` is the empty text)."
  @spec text(term()) :: String.t()
  def text(v), do: CountPaperwork.text(v)

  # `2026-11-05T12:00:00+06:00` -> `05.11.2026`; a text that is not that shape is kept as it is.
  @doc "The date part of a `CountPaperwork.time/3` text, printed `DD.MM.YYYY`."
  @spec date(String.t()) :: String.t()
  def date(text) when is_binary(text) do
    case Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})/, text) do
      [_, y, m, d] -> "#{d}.#{m}.#{y}"
      _ -> text
    end
  end

  @doc "The date of an instant in the tenant zone (the offset named by `key`), or the empty text."
  @spec date_of(term(), map(), atom()) :: String.t()
  def date_of(value, names, key), do: value |> CountPaperwork.time(names, key) |> date()

  @doc """
  `{position, full_name}` of an employee id. An employee the caller's scope hides (or an unknown
  id) is `{"", ""}`: neither name nor position is shown (INV-2).
  """
  @spec person(map(), term()) :: {String.t(), String.t()}
  def person(names, id) when is_binary(id) do
    case names |> Map.get(:employees, %{}) |> Map.get(id) do
      %{} = e -> {text(names |> Map.get(:positions, %{}) |> Map.get(id)), text(e[:full_name])}
      _ -> {"", ""}
    end
  end

  def person(_names, _id), do: {"", ""}

  @doc "Several people as two texts joined by `; `: `{positions, names}`; empty entries are skipped."
  @spec people(map(), [term()]) :: {String.t(), String.t()}
  def people(names, ids) do
    persons = ids |> Enum.map(&person(names, &1)) |> Enum.reject(&(&1 == {"", ""}))

    joined = fn pick ->
      persons |> Enum.map(pick) |> Enum.reject(&(&1 == "")) |> Enum.join("; ")
    end

    {joined.(&elem(&1, 0)), joined.(&elem(&1, 1))}
  end

  @doc "The data of a signature block `key`: `key` is the name, `key_position` the position."
  @spec signature(String.t(), {String.t(), String.t()}) :: %{String.t() => String.t()}
  def signature(key, {position, name}), do: %{key => name, (key <> "_position") => position}

  @doc "The organisation name and BIN of the count's org unit (blank when not found)."
  @spec org(map(), map(), map()) :: %{String.t() => String.t()}
  def org(content, order_content, names) do
    unit_id = content["org_unit_id"] || order_content["org_unit_id"]
    entity = names |> Map.get(:legal_entities, %{}) |> Map.get(unit_id) |> map()
    %{"org_name" => text(entity[:name]), "org_bin" => text(entity[:bin])}
  end

  @doc "The quantity text of a decimal as it is stored; `nil` when it is not a decimal."
  @spec decimal(term()) :: Decimal.t() | nil
  def decimal(v) when is_binary(v) do
    case Decimal.parse(v) do
      {%Decimal{} = d, ""} -> d
      _ -> nil
    end
  end

  def decimal(_), do: nil

  @doc "Absolute value of a decimal text as `:normal` text, `\"\"` for zero or not a decimal."
  @spec abs_text(term()) :: String.t()
  def abs_text(v) do
    case decimal(v) do
      %Decimal{} = d ->
        if Decimal.eq?(d, 0), do: "", else: d |> Decimal.abs() |> Decimal.to_string(:normal)

      nil ->
        ""
    end
  end

  @doc "The sum of decimal texts, `\"\"` when the list is empty or one value is not a decimal."
  @spec sum_text([term()]) :: String.t()
  def sum_text([]), do: ""

  def sum_text(values) do
    decimals = Enum.map(values, &decimal/1)

    if Enum.any?(decimals, &is_nil/1),
      do: "",
      else: decimals |> Enum.reduce(Decimal.new(0), &Decimal.add/2) |> Decimal.to_string(:normal)
  end

  @doc "The lines of an issued document in line order."
  @spec lines(map()) :: [map()]
  def lines(content), do: CountPaperwork.lines_of(:differences, content)

  @doc "Item name and code, unit text for a line."
  @spec line_cells(map(), map()) :: %{String.t() => String.t()}
  def line_cells(line, names) do
    item = names |> Map.get(:items, %{}) |> Map.get(line["catalog_item_id"]) |> map()
    unit = names |> Map.get(:units, %{}) |> Map.get(line["unit_ref"])

    %{
      "no" => text(line["line_no"]),
      "name" => text(item[:name]),
      "nom" => text(item[:code]),
      "unit" => unit_name(unit, line["unit_ref"])
    }
  end

  # The unit's name (its code when it has none); the raw reference only when the record is not found.
  defp unit_name(%{} = unit, ref), do: text(unit[:name] || unit[:code] || ref)
  defp unit_name(_, ref), do: text(ref)

  @doc "The order's number label and date for the order fields."
  @spec order(map()) :: {String.t(), String.t()}
  def order(names) do
    summary = Map.get(names, :order) || %{}
    {text(summary[:number_label]), date_of(summary[:issued_at], names, :order_issued_at)}
  end

  defp map(%{} = m), do: m
  defp map(_), do: %{}
end
