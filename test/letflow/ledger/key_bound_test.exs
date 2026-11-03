defmodule Letflow.Ledger.KeyBoundTest do
  @moduledoc """
  REQ-621 / GH #3469 part A, criterion 3: T-KB-1a..f. key_bounds, the first-touch pin of
  `max_on_hand` and `unit_ref`, and the balance invariant I-BAL.
  The bound is per BALANCE KEY (k1 .. k8 together, OQ-23): the same third-slot value at another
  second slot is another key and is not bounded by the first.
  Sandbox `:auto` with real commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false
  use ExUnitProperties

  alias Letflow.Repo
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H

  setup do
    Fx.setup_auto_mode!()
    :ok = H.attach_error_handler(__MODULE__)
    %{schema: Fx.tenant!()}
  end

  defp bounded(max),
    do: Fx.registration(key_bounds: [%{when_slot_nonempty: "k_third", max_on_hand: max}])

  defp receipt(schema, k, q, reg, unit \\ "u1"),
    do: Fx.capability(schema, "receipt", [Fx.leg(k, q, unit)], registration: reg)

  test "T-KB-1a first receipt pins max_on_hand 1; a second is refused; another key posts", %{
    schema: schema
  } do
    reg = bounded("1")
    key = ["a", "loc1", "s1"]

    assert {:ok, _} = Fx.post_tx(receipt(schema, key, 1, reg))
    assert Decimal.eq?(Fx.balance(schema, key).max_on_hand, 1)

    assert {:error, {:ledger_refused, :balance_bound_exceeded, _, %{legs: [%{leg_no: 1}]}}} =
             Fx.post_tx(receipt(schema, key, 1, reg))

    # same third-slot value at a DIFFERENT second slot: a different balance key (OQ-23)
    assert {:ok, _} = Fx.post_tx(receipt(schema, ["a", "loc2", "s1"], 1, reg))
    # an empty third slot matches no bound
    assert {:ok, _} = Fx.post_tx(receipt(schema, ["a", "loc1"], 5, reg))
    assert Fx.balance(schema, ["a", "loc1"]).max_on_hand == nil
  end

  test "T-KB-1b the minimum of matching bounds is pinned and the pin survives a new registration",
       %{schema: schema} do
    reg =
      Fx.registration(
        key_bounds: [
          %{when_slot_nonempty: "k_third", max_on_hand: "5"},
          %{when_slot_nonempty: "k_second", max_on_hand: "2"}
        ]
      )

    key = ["a", "loc", "s"]
    assert {:ok, _} = Fx.post_tx(receipt(schema, key, 1, reg))
    assert Decimal.eq?(Fx.balance(schema, key).max_on_hand, 2)

    wider = bounded("9")
    assert {:ok, _} = Fx.post_tx(receipt(schema, key, 1, wider))

    assert {:error, {:ledger_refused, :balance_bound_exceeded, _, _}} =
             Fx.post_tx(receipt(schema, key, 1, wider))

    assert Decimal.eq?(Fx.balance(schema, key).max_on_hand, 2)
    assert Decimal.eq?(Fx.balance(schema, key).on_hand, 2)
  end

  test "T-KB-1c two concurrent receipts of one bounded key: exactly one posted", %{schema: schema} do
    key = ["a", "loc", "s"]
    Fx.insert_balance!(schema, key, "u1", "1")
    worker = fn -> Fx.post_tx(receipt(schema, key, 1, bounded("1"))) end

    %{first: r1, second: r2} =
      H.forced_overlap(schema, {:ledger_balance, Fx.ledger_id(), key}, worker, worker)

    assert [{:ok, _}] = Enum.filter([r1, r2], &match?({:ok, _}, &1))

    assert [{:error, {:ledger_refused, :balance_bound_exceeded, _, _}}] =
             Enum.filter([r1, r2], &match?({:error, _}, &1))

    assert Decimal.eq?(Fx.balance(schema, key).on_hand, 1)
  end

  test "T-KB-1d the first receipt pins the unit; another unit is unit_mismatch", %{schema: schema} do
    key = ["a"]
    assert {:ok, _} = Fx.post_tx(receipt(schema, key, 2, Fx.registration()))
    assert Fx.balance(schema, key).unit_ref == "u1"
    seq = Fx.last_seq(schema)

    assert {:error, {:ledger_refused, :unit_mismatch, _, %{leg_no: 1}}} =
             Fx.post_tx(receipt(schema, key, 1, Fx.registration(), "u2"))

    assert Fx.last_seq(schema) == seq
    assert {:ok, _} = Fx.post_tx(receipt(schema, key, 1, Fx.registration(), "u1"))

    # two legs of one key with two units in one posting
    legs = [Fx.leg(["c"], 1, "u1"), Fx.leg(["c"], 1, "u2")]

    assert {:error, {:ledger_refused, :unit_mismatch, _, %{leg_no: 2}}} =
             Fx.post_tx(Fx.capability(schema, "receipt", legs))

    # a unit outside the allowlist creates no balance row
    reg = Fx.registration(units: ["u1"])

    assert {:error, {:ledger_refused, :invalid_posting, _, %{reason: :unit_not_allowed}}} =
             Fx.post_tx(receipt(schema, ["d"], 1, reg, "zz"))

    assert Fx.balance(schema, ["d"]) == nil
  end

  test "T-KB-1e a new key's row starts at 0/0 and ends at last_posting_seq == posting_seq", %{
    schema: schema
  } do
    {result, statements} =
      Fx.record(fn -> Fx.post_tx(receipt(schema, ["a"], 3, Fx.registration())) end)

    assert {:ok, %{posting_seq: 1}} = result

    {_sql, params} =
      Enum.find(statements, fn {sql, _} -> sql =~ ~r/INSERT INTO "[^"]+"\."ledger_balance"/ end)

    assert Enum.count(params, &match?(%Decimal{}, &1)) >= 1 and
             Enum.all?(params, &(not is_integer(&1) or &1 == 0))

    row = Fx.balance(schema, ["a"])
    assert Decimal.eq?(row.on_hand, 3)
    assert row.last_posting_seq == 1
  end

  test "T-KB-1f on_hand equals the sum of the legs up to the counter (I-BAL)", %{
    schema: schema
  } do
    check all(
            ops <-
              list_of(
                {member_of(["k1", "k2", "k3"]), member_of(["receipt", "issue"]), integer(1..5)},
                min_length: 50,
                max_length: 60
              ),
            max_runs: 2,
            max_shrinking_steps: 0
          ) do
      ledger = "prop_#{System.unique_integer([:positive])}"

      for {key, cause, n} <- ops do
        q = if cause == "issue", do: -n, else: n
        Fx.post_tx(Fx.capability(schema, cause, [Fx.leg([key], q)], ledger_id: ledger))

        %{rows: rows} =
          Repo.query!(
            """
            SELECT b.k1, b.on_hand = COALESCE((SELECT SUM(l.quantity) FROM "#{schema}".ledger_leg l
                     WHERE l.ledger_id = b.ledger_id AND l.k1 = b.k1
                       AND l.posting_seq <= (SELECT last_seq FROM "#{schema}".ledger_counter WHERE ledger_id = b.ledger_id)), 0)
            FROM "#{schema}".ledger_balance b WHERE b.ledger_id = $1
            """,
            [ledger]
          )

        assert Enum.all?(rows, fn [_k, equal] -> equal end)
      end
    end
  end
end
