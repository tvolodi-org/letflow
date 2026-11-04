Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.StockTwoSideFixture do
  @moduledoc """
  REQ-721 / GH #3770: bodies of the three two-sided kinds (transfer, hand over, return) on top of
  `Letflow.StockPostingFixture`. Side A is the masters of the context (`ctx.ma`: unit, location,
  employee, item, unit of measure, lot); side B is a second master set (`b2!/1`) whose unit,
  location and employee are used as the other side. A `.exs` file loaded with `Code.require_file/2`.
  """

  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockPostingFixture, as: P

  @kinds ~w(transfer hand_over return)

  def kinds, do: @kinds

  @doc "The second set of masters of the same tenant (its item and unit of measure are not used)."
  def b2!(ctx), do: D.masters!(ctx.schema)

  @doc "The lines: item with lot and without, quantities `q1` and `q2`."
  def lines(m, q1 \\ "4", q2 \\ "1") do
    [
      %{
        "catalog_item_id" => m.item,
        "catalog_uom_id" => m.uom,
        "catalog_lot_id" => m.lot,
        "quantity" => q1
      },
      %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => q2}
    ]
  end

  @doc "One line without lot (stock held without a lot) of `q` units of the context item."
  def plain(m, q),
    do: [%{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => q}]

  @doc """
  A valid body of `kind` moving stock from `from` to `to` (maps with `unit`, `location`, `employee`).
  `m` supplies items. For a return the filing unit is the `to` unit.
  """
  def body(kind, m, from, to, extra \\ %{}) do
    sides =
      case kind do
        "return" ->
          %{
            "org_unit_id" => to.unit,
            "from_org_unit_id" => from.unit,
            "from_location_id" => from.location,
            "from_responsible_id" => from.employee,
            "to_location_id" => to.location,
            "to_responsible_id" => to.employee
          }

        _transfer_or_hand_over ->
          %{
            "org_unit_id" => from.unit,
            "from_location_id" => from.location,
            "from_responsible_id" => from.employee,
            "to_org_unit_id" => to.unit,
            "to_location_id" => to.location,
            "to_responsible_id" => to.employee
          }
      end

    Map.merge(
      Map.merge(sides, %{
        "kind" => kind,
        "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
        "note" => "n",
        "lines" => lines(m)
      }),
      extra
    )
  end

  @doc "Saves `body`, returns the draft."
  def save!(ctx, body), do: P.save!(ctx, body)

  @doc "Saves and issues `body` through the routes."
  def issue!(ctx, body), do: P.issue!(ctx, body)

  @doc "Receives `qty` of the context item at side `m` (a receipt document), posted."
  def receive!(ctx, m, qty) do
    body =
      D.body(m, nil, %{
        "lines" => [
          %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => ctx.ma.uom, "quantity" => qty}
        ]
      })

    doc = P.issue!(ctx, body)
    P.post_and_complete!(ctx, doc["id"])
  end

  @doc "The quantity (as plain decimal text, `\"0\"` when absent) of the context item at `location` and (when given) `responsible`."
  def qty(ctx, location, responsible \\ :any) do
    rows =
      Letflow.StockFixture.get("/balances?sku=#{ctx.ma.item}", ctx.tok_a)
      |> P.status!(200)
      |> Map.fetch!("rows")

    rows
    |> Enum.filter(fn r ->
      r["location"] == location and (responsible == :any or r["responsible"] == responsible)
    end)
    |> Enum.reduce(Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end
end
