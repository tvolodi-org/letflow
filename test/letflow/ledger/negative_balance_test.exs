defmodule Letflow.Ledger.NegativeBalanceTest do
  @moduledoc """
  REQ-834 / GH #4547 (decision 0090), criteria 1 to 7: the ledger core honours the tenant's
  negative balance setting of a registration that declares `negative_balance: :tenant_setting`.
  Sandbox `:auto` with real commits on fresh tenants, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Assets

  @key ["item-1", "loc-1"]

  setup do
    Fx.setup_auto_mode!()
    %{schema: Fx.tenant!(), reg: Fx.settable_registration()}
  end

  defp post(schema, cause, qty, reg, key \\ @key) do
    Fx.post_tx(Fx.capability(schema, cause, [Fx.leg(key, qty)], registration: reg))
  end

  defp on_hand(schema, key \\ @key), do: Fx.balance(schema, key).on_hand

  defp read_quantity(schema, key \\ @key) do
    {:ok, report} =
      Ledger.balances(Fx.authorized(schema, :read), {:posting_seq, :latest}, %{}, %{})

    Enum.find_value(report.rows, &(&1.k |> Enum.take(length(key)) == key && &1.quantity))
  end

  defp tables(schema),
    do:
      for(t <- ~w(ledger_entry ledger_leg ledger_counter ledger_balance), do: Fx.count(schema, t))

  test "NB-1 no settings row: 5 to -2 is refused insufficient_balance and nothing is written", %{
    schema: schema,
    reg: reg
  } do
    assert {:ok, _} = post(schema, "receipt", 5, reg)
    before = {tables(schema), Fx.last_seq(schema), on_hand(schema)}

    assert {:error, {:ledger_refused, :insufficient_balance, "insufficient_balance", details}} =
             post(schema, "issue", -7, reg)

    assert [%{leg_no: 1, requested: "7.000000000"} = leg] = details.legs
    refute Map.has_key?(leg, :available)
    assert {tables(schema), Fx.last_seq(schema), on_hand(schema)} == before
  end

  test "NB-2 allow: -2, -5, then a receipt of 6 reads 1; reconcile finds no mismatch", %{
    schema: schema,
    reg: reg
  } do
    assert {:ok, _} = post(schema, "receipt", 5, reg)
    Fx.set_negative_balance!(schema, "test", true)

    assert {:ok, _} = post(schema, "issue", -7, reg)
    assert read_quantity(schema) == "-2.000000000"
    assert {:ok, _} = post(schema, "issue", -3, reg)
    assert read_quantity(schema) == "-5.000000000"
    assert {:ok, _} = post(schema, "receipt", 6, reg)
    assert read_quantity(schema) == "1.000000000"

    assert {:ok, %{mismatches: []}} = Fx.reconcile_all(Fx.authorized(schema))
  end

  test "NB-3 refuse after allow: a receipt into -5 is accepted, an issue of 1 is refused", %{
    schema: schema,
    reg: reg
  } do
    Fx.set_negative_balance!(schema, "test", true)
    assert {:ok, _} = post(schema, "issue", -5, reg)
    assert on_hand(schema) |> Decimal.eq?(-5)

    Fx.set_negative_balance!(schema, "test", false)
    assert {:ok, _} = post(schema, "receipt", 3, reg)
    assert on_hand(schema) |> Decimal.eq?(-2)

    assert {:error, {:ledger_refused, :insufficient_balance, _, _}} =
             post(schema, "issue", -1, reg)

    assert on_hand(schema) |> Decimal.eq?(-2)
  end

  describe "NB-4 reversal" do
    defp receipt_then_issue(schema, reg) do
      {:ok, receipt} = post(schema, "receipt", 10, reg)
      {:ok, _} = post(schema, "issue", -6, reg)
      receipt
    end

    defp reverse(schema, reg, entry_id),
      do: Fx.post_tx(Fx.reversal_capability(schema, entry_id, registration: reg))

    test "under allow the reversal reads -6; a second one and a reversal of it keep their refusals",
         %{schema: schema, reg: reg} do
      receipt = receipt_then_issue(schema, reg)
      Fx.set_negative_balance!(schema, "test", true)

      assert {:ok, reversal} = reverse(schema, reg, receipt.entry_id)
      assert on_hand(schema) |> Decimal.eq?(-6)

      assert {:error, {:ledger_refused, :posting_already_reversed, _, _}} =
               reverse(schema, reg, receipt.entry_id)

      assert {:error, {:ledger_refused, :posting_is_reversal, _, _}} =
               reverse(schema, reg, reversal.entry_id)
    end

    test "under refuse the same reversal is refused with only leg_nos and count", %{
      schema: schema,
      reg: reg
    } do
      receipt = receipt_then_issue(schema, reg)

      assert {:error, {:ledger_refused, :insufficient_balance, _, details}} =
               reverse(schema, reg, receipt.entry_id)

      assert details == %{leg_nos: [1], count: 1}
      assert on_hand(schema) |> Decimal.eq?(4)
    end
  end

  test "NB-5a a registration without the key refuses below zero even with an allow row", %{
    schema: schema
  } do
    reg = Fx.registration()
    refute Map.has_key?(reg, :negative_balance)
    Fx.set_negative_balance!(schema, "test", true)

    assert {:ok, _} = post(schema, "receipt", 5, reg)

    assert {:error, {:ledger_refused, :insufficient_balance, _, _}} =
             post(schema, "issue", -7, reg)

    refute Ledger.negative_balances_allowed?(schema, "test", reg)
    assert Ledger.negative_balances_allowed?(schema, "test", Fx.settable_registration())
  end

  test "NB-5b the assets registration does not declare the key, an allow row does not matter", %{
    schema: schema
  } do
    assets = Assets.manifest().ledger["assets"]
    refute Map.has_key?(assets, :negative_balance)
    Fx.set_negative_balance!(schema, "assets", true)
    refute Ledger.negative_balances_allowed?(schema, "assets", assets)
  end

  test "NB-5c :refuse declared explicitly behaves as refuse with an allow row", %{schema: schema} do
    reg = Map.put(Fx.registration(), :negative_balance, :refuse)
    Fx.set_negative_balance!(schema, "test", true)

    assert {:error, {:ledger_refused, :insufficient_balance, _, _}} =
             post(schema, "issue", -1, reg)
  end

  test "NB-6 lower bound: ending at -1.0E+21 is refused balance_bound_exceeded, just above is accepted",
       %{schema: schema, reg: reg} do
    Fx.set_negative_balance!(schema, "test", true)
    # a leg is below 1.0E+20, so ten postings reach -9.9E+20
    for _ <- 1..10, do: assert({:ok, _} = post(schema, "issue", "-99000000000000000000", reg))
    assert on_hand(schema) |> Decimal.eq?(Decimal.new("-990000000000000000000"))

    assert {:error, {:ledger_refused, :balance_bound_exceeded, _, %{legs: [%{leg_no: 1}]}}} =
             post(schema, "issue", "-10000000000000000000", reg)

    assert on_hand(schema) |> Decimal.eq?(Decimal.new("-990000000000000000000"))
    assert {:ok, _} = post(schema, "issue", "-9000000000000000000", reg)
    assert on_hand(schema) |> Decimal.eq?(Decimal.new("-999000000000000000000"))
  end

  test "NB-6b max_on_hand is unchanged under allow", %{schema: schema} do
    reg =
      Fx.settable_registration()
      |> Map.put(:key_bounds, [%{when_slot_nonempty: "k_third", max_on_hand: "1"}])

    Fx.set_negative_balance!(schema, "test", true)
    key = ["a", "loc1", "s1"]
    assert {:ok, _} = post(schema, "receipt", 1, reg, key)

    assert {:error, {:ledger_refused, :balance_bound_exceeded, _, _}} =
             post(schema, "receipt", 1, reg, key)
  end

  test "NB-7 tenant A allow, tenant B without a row: B is refused, A accepted", %{
    schema: a,
    reg: reg
  } do
    b = Fx.tenant!()
    Fx.set_negative_balance!(a, "test", true)

    assert {:ok, _} = post(a, "issue", -3, reg)
    assert on_hand(a) |> Decimal.eq?(-3)

    assert {:error, {:ledger_refused, :insufficient_balance, _, _}} = post(b, "issue", -3, reg)
    assert Fx.balance(b, @key) |> then(&(&1 == nil or Decimal.eq?(&1.on_hand, 0)))

    refute Ledger.negative_balances_allowed?(b, "test", reg)
    assert Ledger.negative_balances_allowed?(a, "test", reg)
  end

  test "NB-8 a key the posting does not lower is not judged under refuse", %{
    schema: schema,
    reg: reg
  } do
    Fx.set_negative_balance!(schema, "test", true)
    assert {:ok, _} = post(schema, "issue", -2, reg)
    Fx.set_negative_balance!(schema, "test", false)

    # case B of decision 0090 section 2: on-hand -2, receipt 3 reads 1
    assert {:ok, _} = post(schema, "receipt", 3, reg)
    assert on_hand(schema) |> Decimal.eq?(1)
  end
end
