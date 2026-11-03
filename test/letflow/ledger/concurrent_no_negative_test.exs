defmodule Letflow.Ledger.ConcurrentNoNegativeTest do
  @moduledoc """
  REQ-621 / GH #3469 part A, criterion 2: T-AC2. Two concurrent issues of 6 against on_hand 10
  (forced overlap behind a barrier holding the balance row) leave exactly one posted.
  Sandbox `:auto` with real commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H

  setup do
    Fx.setup_auto_mode!()
    :ok = H.attach_error_handler(__MODULE__)
    %{schema: Fx.tenant!()}
  end

  test "T-AC2 two concurrent issues of 6 against 10: one posted, one refused", %{schema: schema} do
    key = ["a", "l"]
    Fx.seed_on_hand!(schema, key, 10)
    assert Fx.last_seq(schema) == 1

    worker = fn -> Fx.post_tx(Fx.capability(schema, "issue", [Fx.leg(key, -6)])) end

    %{first: r1, second: r2} =
      H.forced_overlap(schema, {:ledger_balance, Fx.ledger_id(), key}, worker, worker)

    results = [r1, r2]
    assert [{:ok, %{posting_seq: 2}}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, {:ledger_refused, :insufficient_balance, "insufficient_balance", details}}] =
             Enum.filter(results, &match?({:error, _}, &1))

    assert [%{leg_no: 1, k: ["a", "l", ""], requested: "6.000000000"} = leg] = details.legs
    refute Map.has_key?(leg, :available)
    refute Map.has_key?(details, :available)

    assert Decimal.eq?(Fx.balance(schema, key).on_hand, 4)
    assert Fx.last_seq(schema) == 2
    assert Fx.count(schema, "ledger_entry") == 2
  end
end
