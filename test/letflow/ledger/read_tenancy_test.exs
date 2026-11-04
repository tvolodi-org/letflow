defmodule Letflow.Ledger.ReadTenancyTest do
  @moduledoc """
  REQ-637 / GH #3559 part B, the read half of criterion 9 (T-TN-1): the prefix of every read
  comes only from the authorized value. The `reconcile/2` rows follow with part C.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx

  setup do
    Fx.setup_auto_mode!()
    Fx.put_registry!()
    fx = Fx.tenant_fixture!()
    %{fx: fx, schema: fx.schema_name, auth: Fx.authorized!(fx)}
  end

  defp receipt!(schema, key, qty),
    do: Fx.post!(Fx.capability(schema, "receipt", [Fx.leg(key, qty)]))

  test "T-TN-1 two tenants with the same ledger id and keys never see each other", %{
    schema: s,
    auth: a
  } do
    other = Fx.tenant_fixture!()
    b = Fx.authorized!(other)

    receipt!(s, ["same", "l"], 5)
    receipt!(other.schema_name, ["same", "l"], 7)
    receipt!(other.schema_name, ["only_b", "l"], 1)

    {:ok, ra} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{})
    {:ok, rb} = Ledger.balances(b, {:posting_seq, :latest}, %{}, %{})
    assert Enum.map(ra.rows, &{hd(&1.k), &1.quantity}) == [{"same", "5.000000000"}]

    assert Enum.map(rb.rows, &{hd(&1.k), &1.quantity}) == [
             {"only_b", "1.000000000"},
             {"same", "7.000000000"}
           ]

    {:ok, %{rows: ea}} = Ledger.entries(a, %{}, %{})
    {:ok, %{rows: eb}} = Ledger.entries(b, %{}, %{})
    assert length(ea) == 1 and length(eb) == 2

    # a prefix, tenant or ledger id in the caller's maps is refused, never obeyed
    for key <- ["prefix", "tenant_id", "ledger_id"] do
      assert {:error, :invalid_filter} =
               Ledger.balances(a, {:posting_seq, :latest}, %{key => other.schema_name}, %{})

      assert {:error, :invalid_filter} = Ledger.entries(a, %{key => other.schema_name}, %{})
      assert {:error, :invalid_filter} = Ledger.entries(a, %{}, %{key => other.schema_name})
    end

    {_, statements} =
      Fx.record(fn ->
        Ledger.balances(a, {:posting_seq, 1}, %{}, %{})
        Ledger.entries(a, %{}, %{})
      end)

    ledger_sql = for {sql, _} <- statements, sql =~ "ledger_", do: sql
    assert ledger_sql != []
    assert Enum.all?(ledger_sql, &(&1 =~ ~s|"#{s}"|))
    refute Enum.any?(ledger_sql, &(&1 =~ other.schema_name))
  end
end
