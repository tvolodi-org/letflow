defmodule Letflow.Ledger.PostBalanceTest do
  @moduledoc """
  REQ-621 / GH #3469 part A, criteria 1 and 2 (shape and refusal cases): T-AC1a..g.
  Sandbox `:auto` with real commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.Ledger.Capability
  alias Letflow.LedgerFixture, as: Fx

  setup do
    Fx.setup_auto_mode!()
    %{schema: Fx.tenant!()}
  end

  defp refused(result, code) do
    case result do
      {:error, {:ledger_refused, ^code, _wire, details}} -> details
      other -> flunk("expected ledger_refused #{inspect(code)}, got: #{inspect(other)}")
    end
  end

  defp invalid(result, reason, leg_no \\ nil) do
    details = refused(result, :invalid_posting)
    assert details == %{leg_no: leg_no, reason: reason}
    assert Enum.sort(Map.keys(details)) == [:leg_no, :reason]
  end

  defp nothing_written(schema) do
    for t <- ~w(ledger_entry ledger_leg ledger_counter), do: assert(Fx.count(schema, t) == 0, t)
  end

  test "T-AC1a a non-capability is refused before any query", %{schema: schema} do
    full = Map.from_struct(Fx.capability(schema, "receipt", [Fx.leg(["a"], 1)]))

    {results, statements} =
      Fx.record(fn ->
        for bad <- [%{}, [prefix: "x"], nil, %URI{}, full, "text", 1] do
          Ledger.post(bad)
        end
      end)

    assert Enum.all?(results, &(&1 == {:error, {:ledger_contract, :invalid_capability}}))
    assert statements == []
  end

  test "T-AC1b the capability struct enforces its eight keys" do
    assert_raise ArgumentError, fn -> struct!(Capability, %{prefix: "x"}) end

    keys = Capability.__struct__() |> Map.keys() |> List.delete(:__struct__) |> Enum.sort()

    assert keys ==
             Enum.sort(
               ~w(prefix registration_name registration command posting subject_id actor_id origin_key)a
             )
  end

  test "T-AC1b2 outside a transaction post/1 raises and writes nothing", %{schema: schema} do
    cap = Fx.capability(schema, "receipt", [Fx.leg(["a"], 1)])
    assert_raise ArgumentError, ~r/open transaction/, fn -> Ledger.post(cap) end
    nothing_written(schema)

    bad = %{cap | prefix: "tenant_x"}
    {result, statements} = Fx.record(fn -> Ledger.post(bad) end)
    assert result == {:error, {:ledger_contract, :invalid_capability}}
    assert statements == []
  end

  test "T-AC1b3 a posting under tenant A's prefix writes only into A", %{schema: schema} do
    other = Fx.tenant!()
    Fx.seed_on_hand!(schema, ["a"], 5)
    assert Fx.count(schema, "ledger_entry") == 1

    for t <- ~w(ledger_entry ledger_leg ledger_counter ledger_balance),
        do: assert(Fx.count(other, t) == 0)
  end

  test "T-AC1c an unbalanced transfer is refused before any lock", %{schema: schema} do
    legs = [Fx.leg(["a1"], 5), Fx.leg(["b1"], -4)]

    {result, statements} =
      Fx.record(fn -> Fx.post_tx(Fx.capability(schema, "transfer", legs)) end)

    assert %{k1: ["a1", "b1"]} = refused(result, :posting_not_balanced)

    refute Enum.any?(statements, fn {sql, _} -> sql =~ "FOR UPDATE" or sql =~ "ledger_counter" end)

    assert Fx.last_seq(schema) == 0

    balanced = [Fx.leg(["a1"], 5), Fx.leg(["a1"], -5)]
    assert {:ok, %{posting_seq: 1}} = Fx.post_tx(Fx.capability(schema, "transfer", balanced))
  end

  test "T-AC1d exactly zero posts, one unit below zero is refused", %{schema: schema} do
    Fx.seed_on_hand!(schema, ["a"], 5)
    assert {:ok, _} = Fx.post_tx(Fx.capability(schema, "issue", [Fx.leg(["a"], -5)]))
    assert Decimal.eq?(Fx.balance(schema, ["a"]).on_hand, 0)

    Fx.seed_on_hand!(schema, ["b"], "0.000000001")
    result = Fx.post_tx(Fx.capability(schema, "issue", [Fx.leg(["b"], "-0.000000002")]))

    assert %{legs: [%{leg_no: 1, requested: "0.000000002"} = leg]} =
             refused(result, :insufficient_balance)

    refute Map.has_key?(leg, :available)
    assert Decimal.eq?(Fx.balance(schema, ["b"]).on_hand, "0.000000001")
  end

  test "T-AC1e a sign rule mismatch is invalid_posting with leg_no and reason only", %{
    schema: schema
  } do
    invalid(
      Fx.post_tx(Fx.capability(schema, "receipt", [Fx.leg(["a"], 1), Fx.leg(["a"], -1)])),
      :sign_mismatch,
      2
    )

    invalid(Fx.post_tx(Fx.capability(schema, "issue", [Fx.leg(["a"], 1)])), :sign_mismatch, 1)
    nothing_written(schema)
  end

  test "T-AC1f other core rules are refused invalid_posting, nothing written", %{schema: schema} do
    post = fn cause, legs, opts -> Fx.post_tx(Fx.capability(schema, cause, legs, opts)) end
    ok = Fx.leg(["a"], 1)

    invalid(post.("reversal", [ok], []), :posting_shape)
    invalid(post.("nope", [ok], []), :unknown_cause)
    invalid(post.("receipt", [], []), :no_legs)
    invalid(post.("receipt", List.duplicate(ok, 201), []), :too_many_legs)
    invalid(post.("receipt", [Fx.leg(["a"], 1.5)], []), :quantity_invalid, 1)
    invalid(post.("receipt", [Fx.leg(["a"], "0.0000000001")], []), :quantity_scale, 1)
    invalid(post.("receipt", [Fx.leg([""], 1)], []), :k1_empty, 1)

    invalid(
      post.("receipt", [Fx.leg(["a", "", ""], 1, "other")],
        registration: Fx.registration(units: ["u1"])
      ),
      :unit_not_allowed,
      1
    )

    invalid(
      post.("receipt", [Fx.leg(["a"], 1)], posting: %{device_id: "d1"}),
      :posting_shape
    )

    invalid(
      post.("receipt", [Fx.leg(["a"], 1)], posting: %{event_time: DateTime.utc_now()}),
      :posting_shape
    )

    invalid(post.("receipt", [Fx.leg(["A"], 1)], []), :slot_invalid, 1)
    invalid(post.("receipt", [Fx.leg(["a", "b", "c", "d"], 1)], []), :slot_invalid, 1)
    nothing_written(schema)
  end

  test "T-AC1g a quantity over the pinned bound is balance_bound_exceeded", %{schema: schema} do
    reg = Fx.registration(key_bounds: [%{when_slot_nonempty: "k_third", max_on_hand: "3"}])
    Fx.post!(Fx.capability(schema, "receipt", [Fx.leg(["a", "l", "s"], 3)], registration: reg))

    result =
      Fx.post_tx(
        Fx.capability(schema, "receipt", [Fx.leg(["a", "l", "s"], "0.000000001")],
          registration: reg
        )
      )

    assert %{legs: [%{leg_no: 1}]} = refused(result, :balance_bound_exceeded)
  end

  test "T-AC1h a malformed registration is refused before any query", %{schema: schema} do
    cap = %{Fx.capability(schema, "receipt", [Fx.leg(["a"], 1)]) | registration: %{slots: []}}

    {result, statements} =
      Fx.record(fn -> Letflow.Repo.transaction(fn -> Ledger.post(cap) end) end)

    assert {:ok, {:error, {:ledger_contract, :invalid_registration}}} = result
    refute Enum.any?(statements, fn {sql, _} -> sql =~ "ledger_" end)
  end
end
