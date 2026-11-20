defmodule Letflow.Modules.Stock.Documents.Legs do
  @moduledoc """
  REQ-903 / GH #4819 (decision 0073 D6, L7 part 2c): the ONE legs comparison of the stock module. Pure: no
  database access, no query building, no documents context, no clock. Both consumers call it, so they cannot disagree:

    * the read-side `posting_check` of `Letflow.Modules.Stock.Documents.Posting` and of
      `Letflow.Modules.Stock.CountPosting` (the legs the ledger holds against the legs the issued content
      gives), and
    * the handler `post_document` of `Letflow.Modules.Stock.Handlers` (the legs the posting variable
      gives against the legs the issued content gives), run before the master checks of REQ-832.

  The normal form is the multiset (a sorted list) of `{sku, location, org_unit, responsible, lot, unit,
  signed quantity}` (`leg_key/7`; an absent responsible or lot is `""`, a quantity is a normalised decimal
  text). A `to` side is a `+q` leg, a `from` side a `-q` leg; the cause `opening_negative` carries the
  magnitude and the ledger negates it, so the posting side negates it here too (`from_posting/1`).
  """

  alias Letflow.Modules.KeyHelpers
  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Modules.Stock.Documents.OpeningPosting
  alias Letflow.Modules.Stock.Documents.QuickCountPosting

  @doc "The normal form of ONE leg."
  @spec leg_key(term(), term(), term(), term(), term(), term(), term()) :: tuple()
  def leg_key(sku, location, org_unit, responsible, lot, unit, quantity) do
    {sku, location, org_unit, blank(responsible), blank(lot), unit, decimal_text(quantity)}
  end

  @doc """
  The legs the issued `content` of a document of kind `spec` (a `Kinds` entry) gives, sorted. A two-sided
  kind gives per line a `-q` leg at the from side and a `+q` leg at the to side (`Kinds.sides/2`).
  """
  @spec expected(map(), map()) :: [tuple()]
  def expected(spec, content), do: expected(spec, content, false)

  @doc false
  @spec expected(map(), map(), boolean()) :: [tuple()]
  def expected(%{kind: "opening"}, content, _record_zero),
    do: content |> OpeningPosting.expected_legs(&leg_key/7) |> Enum.sort()

  def expected(%{kind: "quick_count"}, content, record_zero),
    do: content |> QuickCountPosting.expected_legs(&leg_key/7, record_zero) |> Enum.sort()

  def expected(spec, content, _record_zero) do
    {from, to} = Kinds.sides(spec, Map.get(content, "header", %{}))

    Enum.flat_map(Map.get(content, "lines", []), fn line ->
      quantity = Map.get(line, "quantity")
      leg = &line_leg(line, &1, &2)

      cond do
        from && to -> [leg.(from, negate(quantity)), leg.(to, quantity)]
        from -> [leg.(from, negate(quantity))]
        true -> [leg.(to, quantity)]
      end
    end)
    |> Enum.sort()
  end

  @doc """
  The legs the ledger entry `receipt` (read side: a map with `legs`, each with `k`, `unit_ref`, `quantity`)
  holds, against `expected` (sorted, or `:none` when the issued content is gone, which never matches).
  """
  @spec ledger_match?(map(), [tuple()] | :none) :: boolean()
  def ledger_match?(_receipt, :none), do: false

  def ledger_match?(receipt, expected) do
    actual =
      receipt.legs
      |> Enum.map(fn leg ->
        [sku, location, org_unit, responsible, lot] = KeyHelpers.pad(Map.get(leg, :k, []))
        leg_key(sku, location, org_unit, responsible, lot, leg.unit_ref, leg.quantity)
      end)
      |> Enum.sort()

    actual == expected
  end

  @doc """
  The legs a string-keyed posting (`lines` with `sku`, `lot`, `unit`, `quantity`, `from`, `to`) gives,
  sorted, or `:invalid` when a line is not shaped like a posting line.
  """
  @spec from_posting(map()) :: [tuple()] | :invalid
  def from_posting(%{"lines" => lines} = posting) when is_list(lines) do
    negative? = Map.get(posting, "cause") == "opening_negative"

    lines
    |> Enum.reduce_while([], fn line, acc ->
      case posting_line(line, negative?) do
        :invalid -> {:halt, :invalid}
        legs -> {:cont, legs ++ acc}
      end
    end)
    |> case do
      :invalid -> :invalid
      legs -> Enum.sort(legs)
    end
  end

  def from_posting(_posting), do: :invalid

  defp posting_line(%{} = line, negative?) do
    quantity = Map.get(line, "quantity")
    from = Map.get(line, "from")
    to = Map.get(line, "to")

    leg = fn side, q ->
      leg_key(
        Map.get(line, "sku"),
        Map.get(side, "location"),
        Map.get(side, "org_unit"),
        Map.get(side, "responsible"),
        Map.get(line, "lot"),
        Map.get(line, "unit"),
        q
      )
    end

    to_q = if negative?, do: negate(quantity), else: quantity

    cond do
      is_map(from) and is_map(to) -> [leg.(from, negate(quantity)), leg.(to, to_q)]
      is_map(from) -> [leg.(from, negate(quantity))]
      is_map(to) -> [leg.(to, to_q)]
      true -> :invalid
    end
  end

  defp posting_line(_line, _negative?), do: :invalid

  defp line_leg(line, side, quantity) do
    leg_key(
      Map.get(line, "catalog_item_id"),
      side.location,
      side.org_unit,
      side.responsible,
      Map.get(line, "catalog_lot_id"),
      Map.get(line, "catalog_uom_id"),
      quantity
    )
  end

  defp negate(quantity) do
    case Decimal.parse(to_string(quantity)) do
      {%Decimal{} = d, ""} -> d |> Decimal.negate() |> Decimal.to_string(:normal)
      _bad -> "invalid"
    end
  end

  defp blank(nil), do: ""
  defp blank(value), do: value

  defp decimal_text(quantity) do
    case Decimal.parse(to_string(quantity)) do
      {%Decimal{} = d, ""} -> d |> Decimal.normalize() |> Decimal.to_string(:normal)
      _bad -> "invalid"
    end
  end
end
