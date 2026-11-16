defmodule Letflow.Ledger.ExpectedOnHandTest do
  @moduledoc """
  REQ-853 / GH #4565 (Qoimeks parity G5 part 1): the optional `expected_on_hand` of a posting leg,
  a compare-and-set under the balance lock; refusal `balance_changed`. Criteria 1..7 (criterion 8
  is the moduledoc and decision 0073). Sandbox `:auto` with real commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H

  @key ["a", "l"]

  setup do
    Fx.setup_auto_mode!()
    :ok = H.attach_error_handler(__MODULE__)
    %{schema: Fx.tenant!()}
  end

  defp cap(schema, qty, expected, opts \\ []) do
    extra = if expected == :none, do: %{}, else: %{expected_on_hand: Fx.dec(expected)}
    command = if expected == :none, do: %{}, else: %{expected_on_hand: to_string(expected)}

    Fx.capability(
      schema,
      "receipt",
      [Fx.leg(@key, qty, "u1", extra)],
      Keyword.put(opts, :command, Map.merge(command, Keyword.get(opts, :command, %{})))
    )
  end

  defp invalid?(result, reason) do
    assert {:error, {:ledger_refused, :invalid_posting, "invalid_posting", %{reason: ^reason}}} =
             result
  end

  test "T-853-1 equal expected posts like the same posting without the key", %{schema: schema} do
    Fx.seed_on_hand!(schema, @key, 10)
    other = Fx.tenant!()
    Fx.seed_on_hand!(other, @key, 10)

    plain = Fx.post!(cap(schema, 3, :none, command: %{client_op_id: "op-1"}))
    with_key = Fx.post!(cap(other, 3, 10, command: %{client_op_id: "op-1"}))

    assert Decimal.eq?(Fx.balance(schema, @key).on_hand, 13)
    assert Decimal.eq?(Fx.balance(other, @key).on_hand, 13)
    assert plain.posting_seq == with_key.posting_seq

    a = Fx.entry_row(schema, plain.entry_id)
    b = Fx.entry_row(other, with_key.entry_id)

    differing =
      for {k, v} <- a, Map.get(b, k) != v, do: k

    allowed = [:id, :entry_digest, :chain_hash, :posting_time, :event_time]
    assert differing -- allowed == []
    # the header row map has no payload_hash column; the digest covers it and differs
    assert :entry_digest in differing
    assert Fx.leg_rows(schema, plain.entry_id) == Fx.leg_rows(other, with_key.entry_id)
  end

  test "T-853-2 a differing expected is balance_changed and writes nothing", %{schema: schema} do
    Fx.seed_on_hand!(schema, @key, 10)
    entries = Fx.count(schema, "ledger_entry")
    seq = Fx.last_seq(schema)

    assert {:error, {:ledger_refused, :balance_changed, "balance_changed", %{leg_nos: [1]}}} =
             Fx.post_tx(cap(schema, 3, 9))

    assert Fx.count(schema, "ledger_entry") == entries
    assert Fx.last_seq(schema) == seq
    assert Decimal.eq?(Fx.balance(schema, @key).on_hand, 10)
    assert Letflow.Ledger.Codes.status("balance_changed") == 409
    assert "balance_changed" in Letflow.Ledger.Codes.aliasable()
    assert "balance_changed" in Letflow.Ledger.Codes.reserved()
  end

  test "T-853-3 a first-touch key compares as 0", %{schema: schema} do
    assert {:ok, _} = Fx.post_tx(cap(schema, 3, 0))

    fresh = Fx.tenant!()

    assert {:error, {:ledger_refused, :balance_changed, _, %{leg_nos: [1]}}} =
             Fx.post_tx(cap(fresh, 3, 1))
  end

  test "T-853-4 a commit between build and lock refuses the waiting posting", %{schema: schema} do
    Fx.seed_on_hand!(schema, @key, 10)
    waiting = cap(schema, 3, 10)

    Application.put_env(:letflow, :ledger_precondition_test_hook, {:wait, self(), :validated})
    on_exit(fn -> Application.delete_env(:letflow, :ledger_precondition_test_hook) end)

    task = Task.async(fn -> Fx.post_tx(waiting) end)
    assert_receive {:ledger_precondition_hook, :validated, pid}, 10_000

    Application.delete_env(:letflow, :ledger_precondition_test_hook)
    assert {:ok, _} = Fx.post_tx(cap(schema, 1, :none))
    send(pid, :go)

    assert {:error, {:ledger_refused, :balance_changed, _, %{leg_nos: [1]}}} =
             Task.await(task, 15_000)

    assert Decimal.eq?(Fx.balance(schema, @key).on_hand, 11)
    assert Fx.count(schema, "ledger_entry") == 2
  end

  test "T-853-5 check order: unit_mismatch, then balance_changed, then insufficient", %{
    schema: schema
  } do
    Fx.seed_on_hand!(schema, @key, 2)

    both_unit =
      Fx.capability(schema, "issue", [
        Fx.leg(@key, -1, "other", %{expected_on_hand: Decimal.new(99)})
      ])

    assert {:error, {:ledger_refused, :unit_mismatch, _, _}} = Fx.post_tx(both_unit)

    both_short =
      Fx.capability(schema, "issue", [
        Fx.leg(@key, -5, "u1", %{expected_on_hand: Decimal.new(99)})
      ])

    assert {:error, {:ledger_refused, :balance_changed, _, _}} = Fx.post_tx(both_short)

    only_short =
      Fx.capability(schema, "issue", [
        Fx.leg(@key, -5, "u1", %{expected_on_hand: Decimal.new(2)})
      ])

    assert {:error, {:ledger_refused, :insufficient_balance, _, _}} = Fx.post_tx(only_short)
  end

  test "T-853-6 invalid values are invalid_posting before any lock", %{schema: schema} do
    for bad <- [Decimal.new(-1), Decimal.new("0.0000000001"), "5", 5] do
      leg = Fx.leg(["z", "l"], 1, "u1", %{expected_on_hand: bad})
      invalid?(Fx.post_tx(Fx.capability(schema, "receipt", [leg])), :expected_on_hand_invalid)
    end

    two =
      Fx.capability(schema, "receipt", [
        Fx.leg(["z", "l"], 1, "u1", %{expected_on_hand: Decimal.new(1)}),
        Fx.leg(["z", "l"], 1, "u1", %{expected_on_hand: Decimal.new(2)})
      ])

    invalid?(Fx.post_tx(two), :expected_on_hand_invalid)
    assert Fx.count(schema, "ledger_balance") == 0

    {:ok, %{entry_id: target}} = Fx.post_tx(cap(schema, 1, :none))

    rev =
      Fx.reversal_capability(schema, target, command: %{expected_on_hand: "1"})

    invalid?(Fx.post_tx(rev), :expected_on_hand_invalid)
    assert {:ok, _} = Fx.post_tx(Fx.reversal_capability(schema, target))
    _ = Ledger
  end

  test "T-853-7 idempotency covers expected_on_hand", %{schema: schema} do
    Fx.seed_on_hand!(schema, @key, 10)
    same = [subject_id: Ecto.UUID.generate(), origin_key: "origin-x"]
    first = cap(schema, 3, 10, [command: %{client_op_id: "op-x"}] ++ same)
    assert {:ok, %{duplicate: false} = one} = Fx.post_tx(first)
    assert {:ok, %{duplicate: true} = two} = Fx.post_tx(first)
    assert two.entry_id == one.entry_id

    changed = cap(schema, 3, 11, [command: %{client_op_id: "op-x"}] ++ same)

    assert {:error, {:ledger_refused, :idempotency_key_reuse, _, _}} = Fx.post_tx(changed)
  end
end
