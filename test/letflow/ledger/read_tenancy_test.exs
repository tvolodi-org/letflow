defmodule Letflow.Ledger.ReadTenancyTest do
  @moduledoc """
  REQ-637 / GH #3559 parts B, C and D, criterion 9 (T-TN-1..T-TN-6): the prefix of every read,
  reconciliation and reversal lookup comes only from the authorized value or the capability;
  another tenant's rows, ids and corruption never show; a refusal leaves no value in the log or
  the result; none of the reads raises on a realistic failure; no runtime-built SQL.
  """

  import ExUnit.CaptureLog

  alias Letflow.Repo

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

  defp corrupt_balance!(schema, key, on_hand) do
    [k1, k2, k3, k4, k5, k6, k7, k8] = Fx.pad(key)

    Fx.exec!(
      ~s|UPDATE "#{schema}".ledger_balance SET on_hand = $1, last_posting_seq = $2 WHERE ledger_id = $3 AND k1 = $4 AND k2 = $5 AND k3 = $6 AND k4 = $7 AND k5 = $8 AND k6 = $9 AND k7 = $10 AND k8 = $11|,
      [Decimal.new(on_hand), Fx.last_seq(schema), Fx.ledger_id(), k1, k2, k3, k4, k5, k6, k7, k8]
    )
  end

  test "T-TN-2 reconcile is bound to the authorized tenant", %{fx: fx, schema: s} do
    other = Fx.tenant_fixture!()
    receipt!(s, ["same", "l"], 5)
    receipt!(other.schema_name, ["same", "l"], 7)

    if Fx.table_owner?(other.schema_name) do
      corrupt_balance!(other.schema_name, ["same", "l"], 999)

      a = Fx.authorized!(fx, :reconcile)
      b = Fx.authorized!(other, :reconcile)

      assert {:ok, ra} = Fx.reconcile_all(a)
      assert ra.mismatches == []
      assert {:ok, %{mismatches: [mismatch]}} = Fx.reconcile_all(b)
      assert mismatch.key == ["same", "l"]
      assert mismatch.balance == "999.000000000"

      # a prefix, tenant or ledger id in the options is ignored, never obeyed
      forbidden =
        for k <- [:prefix, :tenant_id, :ledger_id, "prefix", "tenant_id", "ledger_id"],
            into: %{},
            do: {k, other.schema_name}

      {result, statements} = Fx.record(fn -> Fx.reconcile_all(a, forbidden) end)
      assert {:ok, %{mismatches: []}} = result

      table_sql = for {sql, _} <- statements, sql =~ "ledger_", do: sql
      assert table_sql != []
      assert Enum.all?(table_sql, &(&1 =~ ~s|"#{s}"|))

      refute Enum.any?(statements, fn {sql, params} ->
               sql =~ other.schema_name or Enum.member?(params, other.schema_name)
             end)

      assert Enum.any?(statements, fn {sql, params} ->
               sql =~ "pg_try_advisory_xact_lock" and params == [s, Fx.ledger_id()]
             end)
    else
      IO.puts("T-TN-2 skipped: the test role does not own the ledger tables (owner-tamper)")
    end
  end

  test "T-TN-3 a reversal target of tenant B is the refusal of an unknown id", %{schema: s} do
    other = Fx.tenant_fixture!()
    receipt!(s, ["a", "l"], 4)
    foreign = receipt!(other.schema_name, ["a", "l"], 4)
    before = {Fx.count(s, "ledger_entry"), Fx.count(other.schema_name, "ledger_entry")}

    results =
      for id <- [foreign.entry_id, Ecto.UUID.generate(), "not-a-uuid"],
          do: Fx.post_tx(Fx.reversal_capability(s, id))

    assert [
             {:error, {:ledger_refused, :validation_failed, _, %{reason: "movement_not_found"}}}
             | _
           ] =
             results

    assert results |> Enum.uniq() |> length() == 1
    assert before == {Fx.count(s, "ledger_entry"), Fx.count(other.schema_name, "ledger_entry")}
  end

  describe "T-TN-4 source scan" do
    @files Path.wildcard("lib/letflow/ledger.ex") ++ Path.wildcard("lib/letflow/ledger/*.ex")
    @pins %{"lib/letflow/ledger.ex" => 2, "lib/letflow/ledger/reconcile.ex" => 3}

    # Returns {literal query calls, offenders} for the source text.
    defp scan(source) do
      {:ok, ast} = Code.string_to_quoted(source)

      {_, acc} =
        Macro.prewalk(ast, {0, []}, fn
          {{:., _, [{:__aliases__, _, mods}, fun]}, _, [first | _]} = node, {n, bad}
          when fun in [:query, :query!] ->
            if List.last(mods) == :Repo and is_binary(first),
              do: {node, {n + 1, bad}},
              else: {node, {n, [:query_not_literal | bad]}}

          {:fragment, _, [first | _]} = node, {n, bad} when not is_binary(first) ->
            {node, {n, [:fragment_not_literal | bad]}}

          node, acc ->
            {node, acc}
        end)

      acc
    end

    test "the scan finds a synthetic offender (it is not vacuous)" do
      source = """
      defmodule X do
        def a(t), do: Repo.query!("SELECT * FROM \#{t}")
        def b(q), do: Repo.query(q)
        def c(t), do: fragment("lock \#{t}")
        def d, do: Repo.query!("SELECT 1")
      end
      """

      assert {1, bad} = scan(source)
      assert :query_not_literal in bad and :fragment_not_literal in bad
    end

    test "only literal queries, pinned per file; the read module runs none" do
      assert @files != []

      for file <- @files do
        {count, bad} = scan(File.read!(file))
        assert bad == [], "#{file}: #{inspect(bad)}"
        assert count == Map.get(@pins, file, 0), "#{file}: #{count} literal Repo.query calls"
      end
    end
  end

  test "T-TN-5 no slot value or quantity in the log from a read, reconcile or reversal refusal",
       %{fx: fx, schema: s, auth: a} do
    mk = "mk-#{System.unique_integer([:positive])}"
    receipt!(s, [mk, "l"], "7.25")
    rec = Fx.authorized!(fx, :reconcile)
    foreign = Fx.authorized(s, :reconcile, "other_ledger")
    {:ok, %{next_cursor: cursor}} = Ledger.reconcile(rec, %{chunk_size: 1})
    lid = Fx.ledger_id()
    me = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Fx.exec!("SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))", [s, lid])
          send(me, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked, 5_000

    {results, log} =
      with_log([level: :debug], fn ->
        [
          Ledger.balances(a, {:posting_seq, :latest}, %{mk => mk}, %{}),
          Ledger.balances(a, {:posting_seq, 1_000_000}, %{}, %{}),
          Ledger.balances(a, :bogus, %{}, %{}),
          Ledger.entries(a, %{mk => mk}, %{}),
          Ledger.entries(a, %{}, %{"cursor" => mk}),
          Ledger.reconcile(rec, %{mk => mk, chunk_size: mk}),
          Ledger.reconcile(foreign, %{cursor: cursor}),
          Ledger.reconcile(rec, %{}),
          Fx.post_tx(Fx.reversal_capability(s, mk)),
          Fx.post_tx(Fx.reversal_capability(s, Ecto.UUID.generate(), reason: mk))
        ]
      end)

    send(holder.pid, :release)
    Task.await(holder)

    assert Enum.all?(results, &match?({:error, _}, &1))
    refute log =~ mk
    refute log =~ "7.25"
    refute inspect(results) =~ mk
    refute inspect(results) =~ "7.25"
  end

  test "T-TN-6 realistic failures return typed values, none raises", %{fx: fx, schema: s, auth: a} do
    receipt!(s, ["a", "l"], 1)

    assert {:error, :invalid_filter} = Ledger.balances(a, {:posting_seq, :latest}, "x", %{})
    assert {:error, _} = Ledger.balances(a, {:posting_seq, 1_000_000}, %{}, %{})
    assert {:error, _} = Ledger.entries(a, %{}, %{"cursor" => "garbage"})
    assert {:error, _} = Ledger.reconcile(Fx.authorized!(fx, :reconcile), %{chunk_size: 0})

    # a read-only role cannot mint a reconcile value; the read value still reads
    ro = Fx.user!(fx, ["TENANT_AUDITOR"])
    conn = Fx.conn_for(fx, ro, ["TENANT_AUDITOR"])
    assert {:ok, _} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{})
    assert Ledger.authorize(conn, Fx.ledger_id(), :reconcile) == :error
  end
end
