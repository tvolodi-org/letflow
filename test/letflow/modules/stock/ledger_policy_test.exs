defmodule Letflow.Modules.Stock.LedgerPolicyTest do
  @moduledoc """
  REQ-687 / GH #3707 criterion 3 (T-LP-1..9): the pure `declare/2` of module stock. No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Stock.LedgerPolicy

  @sku "11111111-1111-4111-8111-111111111111"
  @lot "22222222-2222-4222-8222-222222222222"
  @loc "33333333-3333-4333-8333-333333333333"
  @unit_a "44444444-4444-4444-8444-444444444444"
  @resp "55555555-5555-4555-8555-555555555555"
  @line "66666666-6666-4666-8666-666666666666"

  defp side(extra \\ %{}), do: Map.merge(%{org_unit: @unit_a, location: @loc}, extra)

  defp other, do: side(%{location: "88888888-8888-4888-8888-888888888888"})

  defp line(from, to, extra \\ %{}) do
    Map.merge(
      %{line_id: @line, sku: @sku, lot: @lot, unit: "pcs", quantity: "2.5", from: from, to: to},
      extra
    )
  end

  defp cmd(cause, lines, extra \\ %{}),
    do: Map.merge(%{cause: cause, lines: lines, document_type: "doc", document_id: "d1"}, extra)

  defp declare(command), do: LedgerPolicy.declare(command, %{})
  defp refused(command), do: declare(command)

  defp k(location, unit, resp, lot), do: [@sku, location, unit, resp, lot]

  test "T-LP-1: receipt gives one positive leg at to" do
    assert {:ok, posting} = declare(cmd("receipt", [line(nil, side(%{responsible: @resp}))]))

    assert posting == %{
             ledger_id: "stock",
             cause: "receipt",
             document_type: "doc",
             document_id: "d1",
             legs: [
               %{
                 k: k(@loc, @unit_a, @resp, @lot),
                 quantity: Decimal.new("2.5"),
                 unit_ref: "pcs",
                 document_line_id: @line
               }
             ]
           }
  end

  for cause <- ["issue", "write_off"] do
    test "T-LP-2 #{cause}: one negative leg at from" do
      assert {:ok, %{cause: cause, legs: [leg]}} =
               declare(cmd(unquote(cause), [line(side(), nil, %{lot: nil})]))

      assert cause == unquote(cause)
      assert leg.k == k(@loc, @unit_a, "", "")
      assert leg.quantity == Decimal.new("-2.5")
    end
  end

  for cause <- ["transfer", "hand_over", "return"] do
    test "T-LP-3 #{cause}: two legs from the same sku, lot, unit and quantity" do
      assert {:ok, %{legs: [out, into]}} =
               declare(cmd(unquote(cause), [line(side(), other())]))

      assert out.quantity == Decimal.new("-2.5")
      assert into.quantity == Decimal.new("2.5")
      assert out.unit_ref == into.unit_ref
      assert hd(out.k) == hd(into.k) and List.last(out.k) == List.last(into.k)
      assert out.k != into.k
      assert out.document_line_id == @line
    end
  end

  test "T-LP-4: lines keep their order, legs of several lines" do
    second = "77777777-7777-4777-8777-777777777777"

    assert {:ok, %{legs: legs}} =
             declare(
               cmd("transfer", [line(side(), other()), line(side(), other(), %{line_id: second})])
             )

    assert Enum.map(legs, & &1.document_line_id) == [@line, @line, second, second]
  end

  test "T-LP-5: upper-case ids come back lower-case" do
    upper = String.upcase(@sku)
    assert {:ok, %{legs: [leg]}} = declare(cmd("receipt", [line(nil, side(), %{sku: upper})]))
    assert hd(leg.k) == @sku
  end

  test "T-LP-7: whole-command refusals" do
    ok_line = line(nil, side())

    for cause <- ["reversal", "nope", nil, 5],
        do: assert(refused(cmd(cause, [ok_line])) == bad(1))

    assert refused(cmd("receipt", [])) == bad(1)
    assert refused(cmd("receipt", :nope)) == bad(1)
    assert refused(:nope) == bad(1)
    assert refused(cmd("receipt", List.duplicate(ok_line, 101))) == bad(101)
    assert refused(cmd("transfer", List.duplicate(line(side(), side()), 101))) == bad(201)
    assert {:ok, _} = declare(cmd("receipt", List.duplicate(ok_line, 100)))
  end

  test "T-LP-7: line refusals carry the number of the first leg of the bad line" do
    good = line(nil, side())
    bad_line = fn changes -> Map.merge(good, changes) end

    for changes <- [
          %{line_id: nil},
          %{line_id: "x"},
          %{sku: "x"},
          %{sku: nil},
          %{lot: "x"},
          %{lot: ""},
          %{unit: "BAD UNIT"},
          %{quantity: "0"},
          %{quantity: "-1"},
          %{quantity: "abc"},
          %{quantity: "1.0000000001"},
          %{quantity: 1.5},
          %{quantity: 3},
          %{to: nil},
          %{to: "x"},
          %{to: side(%{org_unit: "x"})},
          %{to: side(%{location: nil})},
          %{to: side(%{responsible: ""})},
          %{from: side()}
        ] do
      assert refused(cmd("receipt", [bad_line.(changes)])) == bad(1), inspect(changes)
    end

    assert refused(cmd("receipt", [good, "not a map"])) == bad(2)
    assert refused(cmd("issue", [line(side(), side())])) == bad(1)
    assert refused(cmd("issue", [line(nil, nil)])) == bad(1)
    assert refused(cmd("transfer", [line(side(), nil)])) == bad(1)
    assert refused(cmd("transfer", [line(nil, side())])) == bad(1)
    assert refused(cmd("transfer", [line(side(), side())])) == bad(1)

    assert refused(
             cmd("return", [line(side(%{responsible: @resp}), side(%{responsible: @resp}))])
           ) == bad(1)

    assert {:ok, _} = declare(cmd("transfer", [line(side(), side(%{responsible: @resp}))]))

    assert refused(
             cmd("transfer", [line(side(), other()), line(side(), other()), line(side(), "x")])
           ) == bad(5)

    assert refused(cmd("transfer", [line(side(), other()), line(side(), 5)])) == bad(3)
  end

  test "T-LP-8: details carry the leg number only; event_time and unknown keys change nothing" do
    {:error, {:invalid_posting, details}} =
      refused(cmd("receipt", [line(nil, side(), %{sku: "x"})]))

    assert Map.keys(details) == [:leg_no]

    plain = declare(cmd("receipt", [line(nil, side())]))

    noisy =
      declare(
        cmd("receipt", [line(nil, side(), %{extra: 1})], %{
          event_time: DateTime.utc_now(),
          client_op_id: "op",
          junk: 1
        })
      )

    assert plain == noisy
  end

  test "T-LP-9: the policy scan passes on the real tree" do
    paths = Mix.Tasks.Letflow.CheckBoundaries.policy_paths()
    assert "lib/letflow/modules/stock/ledger_policy/declare.ex" in paths

    assert Path.wildcard("lib/letflow/modules/stock/ledger_policy/**/*.ex") ==
             ["lib/letflow/modules/stock/ledger_policy/declare.ex"]

    files = for path <- paths, String.contains?(path, "/stock/"), do: {path, File.read!(path)}
    assert Mix.Tasks.Letflow.CheckBoundaries.policy_violations(files) == []
  end

  defp bad(n), do: {:error, {:invalid_posting, %{leg_no: n}}}
end
