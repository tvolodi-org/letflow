defmodule Letflow.Ledger.LockOrderTest do
  @moduledoc """
  REQ-621 / GH #3469 part A, criterion 2: T-LK-1a (AB-BA overlap raises no deadlock) and T-LK-1b
  (the statements a posting sends: missing rows inserted ascending, then locked ascending one key at
  a time, the counter last; a refused posting never touches the counter) and, from part C (criterion 9), T-LK-3 (a lock
  timeout on the counter row propagates unrescued, nothing is committed, a retry posts). The counter-order
  assertions are statement-order recordings, not lock probes.
  Sandbox `:auto` with real commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Ledger
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo

  setup do
    Fx.setup_auto_mode!()
    :ok = H.attach_error_handler(__MODULE__)
    %{schema: Fx.tenant!()}
  end

  # classify a recorded statement; the key is read from the bound parameters
  defp classify({sql, params}) do
    key = Enum.find(params, &(&1 in ["a1", "b1"]))

    cond do
      sql =~ ~r/INSERT INTO "[^"]+"\."ledger_balance"/ -> {:insert_balance, key}
      sql =~ ~r/FROM "[^"]+"\."ledger_balance".*FOR UPDATE/s -> {:lock_balance, key}
      sql =~ ~r/INSERT INTO "[^"]+"\."ledger_counter"/ -> :insert_counter
      sql =~ ~r/FROM "[^"]+"\."ledger_counter".*FOR UPDATE/s -> :lock_counter
      sql =~ "ledger_counter" -> :counter
      true -> nil
    end
  end

  defp classified(statements), do: statements |> Enum.map(&classify/1) |> Enum.reject(&is_nil/1)

  test "T-LK-1a legs (A,B) and (B,A) in forced overlap: both commit, no deadlock", %{
    schema: schema
  } do
    a = ["a1"]
    b = ["b1"]
    Fx.seed_on_hand!(schema, a, 1)
    Fx.seed_on_hand!(schema, b, 1)

    one = fn -> Fx.post_tx(Fx.capability(schema, "adjust", [Fx.leg(a, 1), Fx.leg(b, 1)])) end
    two = fn -> Fx.post_tx(Fx.capability(schema, "adjust", [Fx.leg(b, 1), Fx.leg(a, 1)])) end

    %{first: r1, second: r2} =
      H.forced_overlap(schema, {:ledger_balance, Fx.ledger_id(), a}, one, two)

    assert {:ok, _} = r1
    assert {:ok, _} = r2
    assert Decimal.eq?(Fx.balance(schema, a).on_hand, 3)
    assert Decimal.eq?(Fx.balance(schema, b).on_hand, 3)
    assert Fx.last_seq(schema) == 4
  end

  test "T-LK-1b statement order: inserts ascending, locks ascending, counter last", %{
    schema: schema
  } do
    legs = [Fx.leg(["b1"], 2), Fx.leg(["a1"], 2)]
    {result, statements} = Fx.record(fn -> Fx.post_tx(Fx.capability(schema, "receipt", legs)) end)
    assert {:ok, _} = result

    order = classified(statements)

    assert Enum.take(order, 5) == [
             {:insert_balance, "a1"},
             {:insert_balance, "b1"},
             {:lock_balance, "a1"},
             {:lock_balance, "b1"},
             :insert_counter
           ]

    assert Enum.at(order, 5) == :lock_counter
  end

  test "T-LK-1c a refused posting records the key locks and no counter statement", %{
    schema: schema
  } do
    Fx.seed_on_hand!(schema, ["a1"], 1)
    legs = [Fx.leg(["b1"], -1), Fx.leg(["a1"], -3)]
    {result, statements} = Fx.record(fn -> Fx.post_tx(Fx.capability(schema, "issue", legs)) end)

    assert {:error, {:ledger_refused, :insufficient_balance, _, _}} = result

    order = classified(statements)
    assert {:lock_balance, "a1"} in order and {:lock_balance, "b1"} in order
    refute Enum.any?(order, &(&1 in [:insert_counter, :lock_counter, :counter]))
    assert Fx.last_seq(schema) == 1
  end

  test "T-LK-3 a lock timeout (55P03) on the counter propagates, nothing is written, retry posts",
       %{schema: schema} do
    Fx.seed_on_hand!(schema, ["a1"], 1)
    entries = Fx.count(schema, "ledger_entry")
    legs = Fx.count(schema, "ledger_leg")
    assert Fx.last_seq(schema) == 1

    {holder, _backend} = H.hold_row(schema, {:ledger_counter, Fx.ledger_id()})
    cap = Fx.capability(schema, "receipt", [Fx.leg(["a1"], 2)])

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '200ms'")
          Ledger.post(cap)
        end)
      end

    assert error.postgres.code == :lock_not_available
    assert error.postgres.pg_code == "55P03"
    assert_receive {:deadlock_detected, _}, 5_000

    # the holder is still open: nothing was committed by the timed-out posting
    assert Fx.last_seq(schema) == 1
    assert Fx.count(schema, "ledger_entry") == entries
    assert Fx.count(schema, "ledger_leg") == legs
    assert Decimal.eq?(Fx.balance(schema, ["a1"]).on_hand, 1)

    send(holder.pid, :release)
    Task.await(holder, H.await_ms())

    assert {:ok, %{posting_seq: 2, duplicate: false}} = Fx.post_tx(cap)
    assert Decimal.eq?(Fx.balance(schema, ["a1"]).on_hand, 3)
  end
end
