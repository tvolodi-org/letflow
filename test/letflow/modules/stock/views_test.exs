defmodule Letflow.Modules.Stock.ViewsTest do
  @moduledoc "REQ-687 / GH #3707 T-VW-1: the views are allowlists. Pure."

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Stock.Views

  test "T-VW-1: an extra key never reaches the output; empty slots are nil" do
    row = %{
      k: ["s", "l", "o", "", ""],
      unit_ref: "pcs",
      quantity: "3",
      last_posting_seq: 2,
      secret: 1
    }

    assert Views.stock_balance(row) == %{
             sku: "s",
             location: "l",
             org_unit: "o",
             responsible: nil,
             lot: nil,
             unit_ref: "pcs",
             quantity: "3",
             last_posting_seq: 2
           }

    leg = %{
      leg_no: 1,
      k: ["s", "l", "o", "r", "x"],
      quantity: "-1",
      unit_ref: "pcs",
      document_line_id: "d",
      actor_id: "a"
    }

    assert Map.keys(Views.stock_movement_leg(leg)) |> Enum.sort() ==
             ~w(document_line_id leg_no location lot org_unit quantity responsible sku unit_ref)a

    entry = %{
      entry_id: "e",
      posting_seq: 1,
      cause: "receipt",
      reverses_entry_id: nil,
      reason_code: nil,
      document_type: nil,
      document_id: nil,
      related_document_id: nil,
      correlation_id: nil,
      event_time: nil,
      posting_time: nil,
      ledger_id: "stock",
      chain_hash: "h",
      legs: [leg]
    }

    assert Map.keys(Views.stock_movement(entry)) |> Enum.sort() ==
             ~w(cause correlation_id document_id document_type entry_id event_time legs posting_seq posting_time reason_code related_document_id reverses_entry_id)a
  end

  test "padding of a short reconcile key" do
    assert Views.mismatch(%{key: ["s", "l", "o"], balance: nil, ledger_sum: "1", x: 1}) == %{
             sku: "s",
             location: "l",
             org_unit: "o",
             responsible: nil,
             lot: nil,
             balance: nil,
             ledger_sum: "1"
           }
  end

  test "T-VW-2: a masked leg keeps only leg_no, quantity, unit_ref and masked" do
    leg = %{leg_no: 2, quantity: "3", unit_ref: "pcs", masked: true}

    assert Views.stock_movement_leg(leg) == leg
  end
end
