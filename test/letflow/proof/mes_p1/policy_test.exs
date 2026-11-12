defmodule Letflow.Proof.MesP1.PolicyTest do
  @moduledoc """
  MES PROOF P1 (T-1829), REMOVABLE: E1, E2, C1..C5, T1 of the design. The copy of the stock policy against the real one
  (pure, no database). `git rm -r test/letflow/proof/mes_p1` removes it.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Stock.LedgerPolicy, as: Real
  alias Letflow.Proof.MesP1.LotStatus
  alias Letflow.Proof.MesP1.StockCopy.Policy, as: Copy

  @copy_path "test/support/mes_p1/stock_copy_policy.ex"

  defp id, do: Ecto.UUID.generate()
  defp side, do: %{org_unit: id(), location: id(), responsible: nil}

  defp line(extra \\ %{}) do
    Map.merge(%{line_id: id(), sku: id(), lot: id(), unit: "kg", quantity: "5.5"}, extra)
  end

  defp cmd(cause, lines, extra \\ %{}),
    do: Map.merge(%{cause: cause, lines: lines, document_type: "doc", document_id: id()}, extra)

  defp corpus do
    to = side()
    from = side()
    other = side()

    valid =
      [
        cmd("receipt", [line(%{to: to})]),
        cmd("opening", [line(%{to: to})]),
        cmd("issue", [line(%{from: from})]),
        cmd("write_off", [line(%{from: from})], %{reason_code: "lost"}),
        cmd("kind_change_out", [line(%{from: from})]),
        cmd("transfer", [line(%{from: from, to: other})]),
        cmd("hand_over", [line(%{from: from, to: other})]),
        cmd("return", [line(%{from: from, to: other})]),
        cmd("count_difference", [line(%{to: to})], %{reason_code: "count"}),
        cmd("count_difference", [line(%{from: from})], %{reason_code: "count"}),
        %{cause: "reversal", reverses_entry_id: id(), reason_code: "oops"}
      ]

    invalid =
      [
        cmd("scrap", [line(%{from: from})]),
        cmd("issue", []),
        cmd("issue", [line(%{from: from, to: to})]),
        cmd("receipt", [line(%{from: from})]),
        cmd("transfer", [line(%{from: from, to: from})]),
        cmd("receipt", List.duplicate(line(%{to: to}), 1001)),
        cmd("count_difference", List.duplicate(line(%{to: to}), 201)),
        cmd("reversal", [line()], %{reverses_entry_id: id(), reason_code: "x"}),
        cmd("opening", [line(%{to: to})], %{event_time: "2026-01-01T00:00:00Z"}),
        "not a map"
      ]

    valid ++ invalid
  end

  describe "E: the copy equals the real policy for every old cause" do
    test "E1 the same answer for a corpus of valid and invalid commands" do
      commands = corpus()
      assert length(commands) >= 14

      for command <- commands do
        assert Copy.declare(command, %{}) == Real.declare(command, %{}),
               "differs for #{inspect(command, limit: 4)}"
      end
    end

    test "E2 the copy source passes the policy boundary scan" do
      source = File.read!(@copy_path)
      assert Mix.Tasks.Letflow.CheckBoundaries.policy_violations([{@copy_path, source}]) == []
    end
  end

  describe "C: consume and produce" do
    test "C1 consume: one negative leg and the batch id in the header" do
      batch = id()
      from = side()
      l = line(%{from: from})
      assert {:ok, posting} = Copy.declare(cmd("consume", [l], %{batch_id: batch}), %{})
      assert posting.cause == "consume"
      assert posting.related_document_id == batch
      assert [leg] = posting.legs
      assert Decimal.negative?(leg.quantity)

      assert leg.k == [l.sku, from.location, from.org_unit, "", l.lot]
    end

    test "C2 produce: one positive leg at to; a from side is refused" do
      batch = id()
      to = side()

      assert {:ok, posting} =
               Copy.declare(cmd("produce", [line(%{to: to})], %{batch_id: batch}), %{})

      assert [leg] = posting.legs
      assert Decimal.positive?(leg.quantity)
      assert posting.related_document_id == batch

      assert {:error, {:invalid_posting, %{leg_no: 1}}} =
               Copy.declare(cmd("produce", [line(%{from: side()})], %{batch_id: batch}), %{})
    end

    test "C3 a missing or bad batch id, or both sides, is refused with the leg number only" do
      to = side()
      from = side()
      refused = {:error, {:invalid_posting, %{leg_no: 1}}}

      assert refused == Copy.declare(cmd("consume", [line(%{from: from})]), %{})
      assert refused == Copy.declare(cmd("produce", [line(%{to: to})], %{batch_id: "nope"}), %{})

      assert refused ==
               Copy.declare(cmd("consume", [line(%{from: from, to: to})], %{batch_id: id()}), %{})
    end

    test "C4 the unit is per item: kg and litres both pass" do
      to = side()
      batch = id()
      lines = [line(%{to: to, unit: "kg"}), line(%{to: to, unit: "l"})]
      assert {:ok, posting} = Copy.declare(cmd("produce", lines, %{batch_id: batch}), %{})
      assert Enum.map(posting.legs, & &1.unit_ref) == ["kg", "l"]
    end

    test "C5 the list of causes stays closed" do
      assert {:error, {:invalid_posting, %{leg_no: 1}}} =
               Copy.declare(cmd("scrap", [line(%{from: side()})], %{batch_id: id()}), %{})
    end
  end

  describe "T: lot status transitions" do
    test "T1 the nine pairs" do
      allowed = [
        {"quarantine", "released"},
        {"quarantine", "rejected"},
        {"released", "quarantine"}
      ]

      for from <- LotStatus.statuses(), to <- LotStatus.statuses() do
        assert LotStatus.allowed_transition?(from, to) == {from, to} in allowed,
               "#{from} -> #{to}"
      end
    end
  end
end
