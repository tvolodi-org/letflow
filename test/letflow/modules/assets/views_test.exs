defmodule Letflow.Modules.Assets.ViewsTest do
  @moduledoc """
  REQ-749 / GH #3893 criterion 3 (A8-VIEW-*): the pure view maps of module assets. No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Assets.Views
  alias Letflow.Modules.Stock.Views, as: StockViews

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  test "A8-VIEW-1 asset_balance: exact keys, empty location and user are nil, unknown key absent" do
    row = %{
      k: ["a", "u", "", "r", ""],
      unit_ref: "pcs",
      quantity: Decimal.new(3),
      last_posting_seq: 7,
      extra: "leak"
    }

    view = Views.asset_balance(row)

    assert keys(view) ==
             Enum.sort(
               ~w(asset org_unit location material_responsible actual_user unit_ref quantity last_posting_seq)a
             )

    assert view.asset == "a" and view.org_unit == "u" and view.material_responsible == "r"
    assert view.location == nil and view.actual_user == nil

    full = Views.asset_balance(%{row | k: ["a", "u", "l", "r", "x"]})
    assert full.location == "l" and full.actual_user == "x"
  end

  defp entry do
    %{
      entry_id: "e",
      posting_seq: 1,
      cause: "commission",
      reverses_entry_id: nil,
      reason_code: nil,
      document_type: "d",
      document_id: "i",
      related_document_id: nil,
      correlation_id: nil,
      event_time: "t",
      posting_time: "t",
      secret: "leak",
      legs: [
        %{
          leg_no: 1,
          k: ["a", "u", "", "r", ""],
          quantity: Decimal.new(1),
          unit_ref: "pcs",
          document_line_id: "l",
          leaked: 1
        }
      ]
    }
  end

  test "A8-VIEW-2 asset_movement: the key list of the stock movement, legs with asset slot names" do
    view = Views.asset_movement(entry())
    stock = StockViews.stock_movement(put_in(entry(), [:legs], []))
    assert keys(view) == keys(stock)
    refute Map.has_key?(view, :secret)

    [leg] = view.legs

    assert keys(leg) ==
             Enum.sort(
               ~w(leg_no asset org_unit location material_responsible actual_user quantity unit_ref document_line_id)a
             )

    assert leg.location == nil and leg.actual_user == nil
  end

  test "A8-VIEW-3 a masked leg keeps exactly leg_no, quantity, unit_ref and masked" do
    leg =
      Views.asset_movement_leg(%{masked: true, leg_no: 2, quantity: 1, unit_ref: "pcs", k: [1]})

    assert keys(leg) == [:leg_no, :masked, :quantity, :unit_ref]
    assert leg.masked == true
  end

  test "A8-VIEW-4 mismatch: five slots (a short key padded) plus balance and ledger_sum" do
    view = Views.mismatch(%{key: ["a", "u"], balance: 1, ledger_sum: 2, extra: 1})

    assert keys(view) ==
             Enum.sort(
               ~w(asset org_unit location material_responsible actual_user balance ledger_sum)a
             )

    assert view.location == nil and view.material_responsible == nil
  end
end
