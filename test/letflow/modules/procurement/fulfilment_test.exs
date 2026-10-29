defmodule Letflow.Modules.Procurement.FulfilmentTest do
  @moduledoc """
  GH #3188 / REQ-558 part 2, criteria 6 and 7 (design tests C6-T1, C7-T1..C7-T5): the pure derivation of
  the line status and the request status. No database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Procurement.Fulfilment

  defp d(value), do: Decimal.new(value)

  defp line(quantity, fulfilled, cancelled?),
    do: %{quantity: d(quantity), fulfilled: d(fulfilled), cancelled?: cancelled?}

  test "C6-T1: line status for quantity 10, each fulfilled value, with and without the mark" do
    table = [
      {"0", false, :open},
      {"0", true, :cancelled},
      {"0.001", false, :partial},
      {"0.001", true, :partial},
      {"9.999", false, :partial},
      {"9.999", true, :partial},
      {"10", false, :fulfilled},
      {"10", true, :fulfilled},
      {"10.5", false, :fulfilled},
      {"10.5", true, :fulfilled}
    ]

    for {fulfilled, cancelled?, expected} <- table do
      assert Fulfilment.line_status(d("10"), d(fulfilled), cancelled?) == expected,
             "fulfilled #{fulfilled} cancelled #{cancelled?}"
    end
  end

  test "C7-T1: three lines, nothing fulfilled: no fulfilment status" do
    assert Fulfilment.request_status([
             line("10", "0", false),
             line("5", "0", false),
             line("1", "0", false)
           ]) ==
             nil
  end

  test "C7-T2: one Partial line makes the request Partial" do
    assert Fulfilment.request_status([
             line("10", "0.001", false),
             line("5", "0", false),
             line("1", "0", false)
           ]) ==
             :partial
  end

  test "C7-T3: one Fulfilled plus two cancelled lines is Closed" do
    assert Fulfilment.request_status([
             line("10", "10", false),
             line("5", "0", true),
             line("1", "0", true)
           ]) ==
             :closed
  end

  test "C7-T4: all three lines cancelled is Cancelled, not Closed" do
    assert Fulfilment.request_status([
             line("10", "0", true),
             line("5", "0", true),
             line("1", "0", true)
           ]) ==
             :cancelled
  end

  test "C7-T5: no lines has no status; an open line keeps the request out of Closed" do
    assert Fulfilment.request_status([]) == nil

    assert Fulfilment.request_status([line("10", "10", false), line("5", "0", false)]) == :partial
  end
end
