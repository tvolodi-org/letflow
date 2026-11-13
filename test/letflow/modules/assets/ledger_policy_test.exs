defmodule Letflow.Modules.Assets.LedgerPolicyTest do
  @moduledoc """
  REQ-749 / GH #3893 criterion 2 (A8-POL-*): the pure `declare/2` of module assets. No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Assets.LedgerPolicy

  @asset "11111111-1111-4111-8111-111111111111"
  @unit_a "44444444-4444-4444-8444-444444444444"
  @unit_b "46464646-4646-4646-8646-464646464646"
  @loc "33333333-3333-4333-8333-333333333333"
  @loc_b "35353535-3535-4535-8535-353535353535"
  @resp "55555555-5555-4555-8555-555555555555"
  @resp_b "56565656-5656-4656-8656-565656565656"
  @user "57575757-5757-4757-8757-575757575757"
  @line "66666666-6666-4666-8666-666666666666"
  @target "77777777-7777-4777-8777-777777777777"

  defp side(extra \\ %{}),
    do: Map.merge(%{org_unit: @unit_a, location: @loc, material_responsible: @resp}, extra)

  defp line(from, to, extra \\ %{}) do
    Map.merge(%{line_id: @line, asset: @asset, quantity: "1", from: from, to: to}, extra)
  end

  defp cmd(cause, lines, extra \\ %{}),
    do: Map.merge(%{cause: cause, lines: lines, document_type: "doc", document_id: "d1"}, extra)

  defp declare(command), do: LedgerPolicy.declare(command, %{})

  defp refused(command, n) do
    assert declare(command) == {:error, {:invalid_posting, %{leg_no: n}}}
  end

  defp k(unit, location, resp, user), do: [@asset, unit, location, resp, user]

  test "A8-POL-1 commission: one positive leg at to, absent location and user are empty text" do
    to = %{org_unit: @unit_a, material_responsible: @resp}
    assert {:ok, posting} = declare(cmd("commission", [line(nil, to)]))

    assert posting == %{
             ledger_id: "assets",
             cause: "commission",
             document_type: "doc",
             document_id: "d1",
             legs: [
               %{
                 k: k(@unit_a, "", @resp, ""),
                 quantity: Decimal.new("1"),
                 unit_ref: "pcs",
                 document_line_id: @line
               }
             ]
           }

    assert {:ok, %{legs: [leg]}} =
             declare(cmd("commission", [line(nil, side(%{actual_user: @user}))]))

    assert leg.k == k(@unit_a, @loc, @resp, @user)
  end

  test "A8-POL-2 writeoff: one negative leg at from and a reason" do
    assert {:ok, %{cause: "writeoff", reason_code: "lost", legs: [leg]}} =
             declare(cmd("writeoff", [line(side(), nil)], %{reason_code: "lost"}))

    assert leg.k == k(@unit_a, @loc, @resp, "")
    assert Decimal.equal?(leg.quantity, -1)
    assert leg.unit_ref == "pcs"
  end

  test "A8-POL-3 change and handover: -q at from, +q at to, same asset and quantity, pcs" do
    change = line(side(), side(%{material_responsible: @resp_b}), %{quantity: "200"})
    assert {:ok, %{legs: [out, into]}} = declare(cmd("change", [change]))
    assert out.k == k(@unit_a, @loc, @resp, "")
    assert into.k == k(@unit_a, @loc, @resp_b, "")
    assert Decimal.equal?(out.quantity, -200) and Decimal.equal?(into.quantity, 200)
    assert out.unit_ref == "pcs" and into.unit_ref == "pcs"
    assert out.document_line_id == @line and into.document_line_id == @line

    hand = line(side(), side(%{org_unit: @unit_b}))
    assert {:ok, %{cause: "handover", legs: [out, into]}} = declare(cmd("handover", [hand]))
    assert out.k == k(@unit_a, @loc, @resp, "") and into.k == k(@unit_b, @loc, @resp, "")

    # a change of the actual user alone, and a handover to another location of the same unit
    assert {:ok, _} = declare(cmd("change", [line(side(), side(%{actual_user: @user}))]))
    assert {:ok, _} = declare(cmd("handover", [line(side(), side(%{location: @loc_b}))]))
  end

  test "LP-OPEN-1 opening: one positive leg at to, cause opening" do
    to = %{org_unit: @unit_a, location: @loc, material_responsible: @resp, actual_user: @user}
    assert {:ok, posting} = declare(cmd("opening", [line(nil, to)]))
    assert posting.cause == "opening"
    assert [%{k: key, quantity: q}] = posting.legs
    assert key == k(@unit_a, @loc, @resp, @user)
    assert Decimal.equal?(q, 1)
  end

  test "LP-OPEN-2 opening refuses every client time key and a from side" do
    to = side()

    for key <- [:event_time, :client_event_time, :device_id, :client_seq] do
      refused(cmd("opening", [line(nil, to)], %{key => "x"}), 1)
    end

    refused(cmd("opening", [line(side(), to)]), 1)
  end

  test "A8-POL-4 an unknown cause is refused at leg 1" do
    for cause <- ["receipt", "other", nil, 1] do
      refused(cmd(cause, [line(nil, side())]), 1)
    end

    refused("nope", 1)
    refused(cmd("commission", []), 1)
    refused(cmd("commission", nil), 1)
  end

  test "A8-POL-5 the quantity: a decimal text above zero with no fractional part" do
    to = side()
    assert {:ok, _} = declare(cmd("commission", [line(nil, to, %{quantity: "200"})]))

    for bad <- ["2.5", "0", "2.0", "-1", "", "abc", nil, 2] do
      refused(cmd("commission", [line(nil, to, %{quantity: bad})]), 1)
    end

    # the second line is bad: leg 2 for a one-leg cause, leg 3 for a two-leg cause
    ok = line(nil, to)
    refused(cmd("commission", [ok, line(nil, to, %{quantity: "0"})]), 2)

    ok2 = line(side(), side(%{material_responsible: @resp_b}))
    bad2 = line(side(), side(%{material_responsible: @resp_b}), %{quantity: "2.5"})
    refused(cmd("change", [ok2, bad2]), 3)
  end

  test "A8-POL-6 a missing asset, org_unit, material_responsible or line_id is refused" do
    refused(cmd("commission", [line(nil, side(), %{asset: nil})]), 1)
    refused(cmd("commission", [line(nil, side(), %{asset: "x"})]), 1)
    refused(cmd("commission", [line(nil, side(%{org_unit: nil}))]), 1)
    refused(cmd("commission", [line(nil, side(%{material_responsible: nil}))]), 1)
    refused(cmd("commission", [line(nil, side(%{location: "not-a-uuid"}))]), 1)
    refused(cmd("commission", [line(nil, side(%{actual_user: "not-a-uuid"}))]), 1)
    refused(cmd("commission", [Map.delete(line(nil, side()), :line_id)]), 1)
    refused(cmd("commission", [line(nil, nil)]), 1)
    refused(cmd("commission", ["not a map"]), 1)
    refused("not a map", 1)
  end

  test "A8-POL-7 more than 100 lines: the first leg of line 101" do
    one = for _ <- 1..101, do: line(nil, side())
    refused(cmd("commission", one), 101)
    assert {:ok, %{legs: legs}} = declare(cmd("commission", Enum.take(one, 100)))
    assert length(legs) == 100

    two = for _ <- 1..101, do: line(side(), side(%{material_responsible: @resp_b}))
    refused(cmd("change", two), 201)
  end

  test "A8-POL-8 change: a different org_unit or location, or nothing different, is refused" do
    refused(cmd("change", [line(side(), side(%{org_unit: @unit_b, actual_user: @user}))]), 1)
    refused(cmd("change", [line(side(), side(%{location: @loc_b, actual_user: @user}))]), 1)
    refused(cmd("change", [line(side(), side())]), 1)
    refused(cmd("change", [line(side(), nil)]), 1)
    refused(cmd("change", [line(nil, side())]), 1)
  end

  test "A8-POL-9 handover: the same org_unit and location is refused" do
    refused(cmd("handover", [line(side(), side())]), 1)
    refused(cmd("handover", [line(side(), side(%{material_responsible: @resp_b}))]), 1)
    refused(cmd("handover", [line(side(), nil)]), 1)
  end

  test "A8-POL-10 writeoff without reason_code, and a to side, are refused" do
    refused(cmd("writeoff", [line(side(), nil)]), 1)
    refused(cmd("writeoff", [line(side(), nil)], %{reason_code: 5}), 1)
    refused(cmd("writeoff", [line(side(), side())], %{reason_code: "lost"}), 1)
    refused(cmd("commission", [line(side(), side())]), 1)
  end

  test "A8-POL-11 reversal: no lines, a target and a reason; with lines it is refused" do
    assert {:ok, posting} =
             declare(%{cause: "reversal", reverses_entry_id: @target, reason_code: "typo"})

    assert posting.legs == [] and posting.ledger_id == "assets"
    assert posting.reverses_entry_id == @target and posting.reason_code == "typo"

    refused(
      %{
        cause: "reversal",
        lines: [line(nil, side())],
        reverses_entry_id: @target,
        reason_code: "typo"
      },
      1
    )

    refused(%{cause: "reversal", reverses_entry_id: @target}, 1)
    refused(%{cause: "reversal", reverses_entry_id: "x", reason_code: "typo"}, 1)
  end

  test "A8-POL-12 a refusal carries no detail beyond leg_no" do
    {:error, {:invalid_posting, detail}} =
      declare(cmd("commission", [line(nil, side(), %{asset: "secret-value"})]))

    assert detail == %{leg_no: 1}
  end
end
