defmodule Letflow.Ledger.BalanceReconcileTest do
  @moduledoc """
  REQ-637 part C (GH #3559), criteria 7 and 8: `Letflow.Ledger.reconcile/2`. Sandbox `:auto` with
  real commits on fresh tenants, hence `async: false`. Overlaps are forced by held locks.

  The owner-tamper cases disable the append-only triggers as table owner (residual D-L2a of
  decision 0073); they return early with a stated reason when the test role does not own the
  tables.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Repo

  @write ~r/\b(INSERT|UPDATE|DELETE|TRUNCATE|LOCK)\b/i
  @keys [["a"], ["a-1"], ["a.b"], ["a0"], ["a1"], ["b"]]

  setup do
    Fx.setup_auto_mode!()
    %{schema: Fx.tenant!()}
  end

  defp receipt!(schema, key, qty, extra \\ %{}),
    do: Fx.post!(Fx.capability(schema, "receipt", [Fx.leg(key, qty, "u1", extra)]))

  # Six keys (mixed case so the byte order matters), one issue, one leg with attrs.
  defp build!(schema, keys \\ @keys) do
    keys
    |> Enum.with_index(1)
    |> Enum.each(fn {key, i} ->
      extra = if i == 1, do: %{attrs: %{"s" => "x", "n" => 1, "b" => true, "f" => 1.5}}, else: %{}
      receipt!(schema, key, i * 10, extra)
    end)

    Fx.post!(Fx.capability(schema, "issue", [Fx.leg(["a"], -3)]))
    schema
  end

  defp corrupt_balance!(schema, key, on_hand) do
    [k1, k2, k3, k4, k5, k6, k7, k8] = Fx.pad(key)

    Fx.exec!(
      ~s|UPDATE "#{schema}".ledger_balance SET on_hand = $1, last_posting_seq = $2 WHERE ledger_id = $3 AND k1 = $4 AND k2 = $5 AND k3 = $6 AND k4 = $7 AND k5 = $8 AND k6 = $9 AND k7 = $10 AND k8 = $11|,
      [Decimal.new(on_hand), Fx.last_seq(schema), Fx.ledger_id(), k1, k2, k3, k4, k5, k6, k7, k8]
    )
  end

  defp edit_cursor(cursor, fun) do
    cursor
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> fun.()
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode(cursor),
    do: cursor |> Base.url_decode64!(padding: false) |> Jason.decode!()

  # Deletes the whole entry `seq` (legs first: the foreign key stays enforced).
  defp delete_entry!(schema, seq) do
    Fx.exec!(~s|DELETE FROM "#{schema}".ledger_leg WHERE posting_seq = $1|, [seq])
    Fx.exec!(~s|DELETE FROM "#{schema}".ledger_entry WHERE posting_seq = $1|, [seq])
  end

  describe "criterion 7: balance and sequence checks" do
    test "C7a a clean ledger reports nothing", %{schema: schema} do
      build!(schema)
      a = Fx.authorized(schema)
      assert {:ok, result} = Fx.reconcile_all(a)

      assert Map.keys(result) |> Enum.sort() ==
               ~w(chain_check checked_through_seq gap_check ledger_id mismatches next_cursor)a

      assert %{mismatches: [], gap_check: :ok, chain_check: :ok, next_cursor: nil} = result
      assert result.checked_through_seq == Fx.last_seq(schema)
      assert result.ledger_id == Fx.ledger_id()
    end

    test "C7a an empty ledger finishes in one call", %{schema: schema} do
      assert {:ok, result} = Ledger.reconcile(Fx.authorized(schema), %{})

      assert %{
               checked_through_seq: 0,
               mismatches: [],
               gap_check: :ok,
               chain_check: :ok,
               next_cursor: nil
             } = result
    end

    test "C7b arity 2 only, and only for a value minted for :reconcile", %{schema: schema} do
      assert function_exported?(Letflow.Ledger, :reconcile, 2)
      refute function_exported?(Letflow.Ledger, :reconcile, 3)

      assert_raise FunctionClauseError, fn ->
        Ledger.reconcile(Fx.authorized(schema, :read), %{})
      end

      assert_raise FunctionClauseError, fn -> Ledger.reconcile(%{prefix: schema}, %{}) end
    end

    test "C7c a corrupted balance is reported with its key, balance and ledger sum", %{
      schema: schema
    } do
      build!(schema)
      corrupt_balance!(schema, ["a0"], 999)

      assert {:ok, %{mismatches: [mismatch]}} = Fx.reconcile_all(Fx.authorized(schema))
      assert mismatch == %{key: ["a0"], balance: "999.000000000", ledger_sum: "40.000000000"}
    end

    test "C7d a key with legs and no balance row is reported with balance nil", %{schema: schema} do
      build!(schema)
      Fx.exec!(~s|ALTER TABLE "#{schema}".ledger_balance DISABLE TRIGGER USER|)
      Fx.exec!(~s|DELETE FROM "#{schema}".ledger_balance WHERE k1 = 'a1'|)

      assert {:ok, %{mismatches: [mismatch]}} = Fx.reconcile_all(Fx.authorized(schema))
      assert mismatch == %{key: ["a1"], balance: nil, ledger_sum: "50.000000000"}
    end

    test "C7e chunks of 2 give the union of the one-shot run, and attrs do not break the chain",
         %{
           schema: schema
         } do
      build!(schema)
      corrupt_balance!(schema, ["a"], 1)
      corrupt_balance!(schema, ["b"], 2)
      a = Fx.authorized(schema)

      {:ok, one} = Fx.reconcile_all(a)
      chunks = Fx.reconcile_chunks(a, %{chunk_size: 2})
      assert length(chunks) > 1
      {:ok, many} = Fx.reconcile_all(a, %{chunk_size: 2})

      assert Enum.sort_by(one.mismatches, & &1.key) == Enum.sort_by(many.mismatches, & &1.key)
      assert Enum.map(one.mismatches, & &1.key) |> Enum.sort() == [["a"], ["b"]]
      assert one.chain_check == :ok and many.chain_check == :ok
      assert Enum.all?(chunks, &(&1.checked_through_seq == one.checked_through_seq))
    end

    test "C7f a deleted middle entry is a gap and a broken chain", %{schema: schema} do
      Enum.each(["a", "b", "c", "d"], &receipt!(schema, [&1], 1))
      Fx.disable_guards!(schema, "ledger_entry")
      Fx.disable_guards!(schema, "ledger_leg")
      delete_entry!(schema, 2)

      assert {:ok, result} = Fx.reconcile_all(Fx.authorized(schema))
      assert result.gap_check == {:gap, [2]}
      assert result.chain_check == {:broken_at, 3}
    end

    test "C7f a deleted last entry is a gap and a broken tail", %{schema: schema} do
      Enum.each(["a", "b", "c", "d"], &receipt!(schema, [&1], 1))
      Fx.disable_guards!(schema, "ledger_entry")
      Fx.disable_guards!(schema, "ledger_leg")
      delete_entry!(schema, 4)

      assert {:ok, result} = Fx.reconcile_all(Fx.authorized(schema))
      assert result.gap_check == {:gap, [4]}
      assert result.chain_check == {:broken_at, 4}
    end

    test "C7f a surplus entry is a gap with no missing value", %{schema: schema} do
      Enum.each(["a", "b", "c", "d"], &receipt!(schema, [&1], 1))
      Fx.disable_guards!(schema, "ledger_counter")
      Fx.exec!(~s|UPDATE "#{schema}".ledger_counter SET last_seq = 3|)

      assert {:ok, %{gap_check: {:gap, []}}} = Fx.reconcile_all(Fx.authorized(schema))
    end

    test "C7g a run sends no write statement and changes nothing", %{schema: schema} do
      build!(schema)

      before =
        for t <- ~w(ledger_entry ledger_leg ledger_counter ledger_balance),
            do: Fx.count(schema, t)

      seq = Fx.last_seq(schema)

      {result, statements} = Fx.record(fn -> Fx.reconcile_all(Fx.authorized(schema)) end)

      assert {:ok, %{mismatches: []}} = result
      assert statements != []
      assert Enum.filter(statements, fn {sql, _} -> sql =~ @write end) == []

      assert before ==
               for(
                 t <- ~w(ledger_entry ledger_leg ledger_counter ledger_balance),
                 do: Fx.count(schema, t)
               )

      assert Fx.last_seq(schema) == seq
    end

    test "RP2 a posting between two chunks is never a mismatch", %{schema: schema} do
      build!(schema)
      a = Fx.authorized(schema)
      {:ok, first} = Ledger.reconcile(a, %{chunk_size: 2})
      assert first.next_cursor

      receipt!(schema, ["a"], 5)
      receipt!(schema, ["z"], 7)

      rest = Fx.reconcile_chunks(a, %{chunk_size: 2, cursor: first.next_cursor})
      assert Enum.all?(rest, &(&1.checked_through_seq == first.checked_through_seq))
      assert Enum.flat_map(rest, & &1.mismatches) == []
      assert List.last(rest).chain_check == :ok

      {:ok, second} = Fx.reconcile_all(a)
      assert second.checked_through_seq > first.checked_through_seq
      assert second.mismatches == []
    end

    test "RP2b a posting between two recheck chunks is skipped, not reported", %{schema: schema} do
      build!(schema)
      a = Fx.authorized(schema)
      {:ok, first} = Ledger.reconcile(a, %{chunk_size: 2})
      Enum.each(["a.b", "a0", "a1"], &receipt!(schema, [&1], 1))

      walk = fn walk, cursor, posted?, acc ->
        {:ok, r} = Ledger.reconcile(a, %{chunk_size: 2, cursor: cursor})
        acc = acc ++ r.mismatches

        cond do
          r.next_cursor == nil ->
            {acc, posted?}

          not posted? and decode(r.next_cursor)["ph"] == "recheck" and
              decode(r.next_cursor)["n2"] != nil ->
            receipt!(schema, ["a1"], 1)
            walk.(walk, r.next_cursor, true, acc)

          true ->
            walk.(walk, r.next_cursor, posted?, acc)
        end
      end

      assert {[], true} = walk.(walk, first.next_cursor, false, [])
    end
  end

  describe "criterion 8: chain check and concurrency cap" do
    test "C8a a tampered digest or chain hash is found at its sequence", %{schema: schema} do
      if Fx.table_owner?(schema) do
        Enum.each(["a", "b", "c", "d"], &receipt!(schema, [&1], 1))
        Fx.disable_guards!(schema, "ledger_entry")

        Fx.exec!(
          ~s|UPDATE "#{schema}".ledger_entry SET entry_digest = repeat('0', 64) WHERE posting_seq = 3|
        )

        Fx.exec!(
          ~s|UPDATE "#{schema}".ledger_entry SET entry_digest = repeat('1', 64) WHERE posting_seq = 4|
        )

        assert {:ok, %{chain_check: {:broken_at, 3}}} = Fx.reconcile_all(Fx.authorized(schema))
      else
        IO.puts("C8a skipped: the test role does not own the ledger tables (owner-tamper)")
      end
    end

    test "C8a a tampered chain hash, and a tampered counter hash", %{schema: schema} do
      if Fx.table_owner?(schema) do
        Enum.each(["a", "b", "c", "d"], &receipt!(schema, [&1], 1))
        Fx.disable_guards!(schema, "ledger_entry")

        Fx.exec!(
          ~s|UPDATE "#{schema}".ledger_entry SET chain_hash = repeat('2', 64) WHERE posting_seq = 2|
        )

        assert {:ok, %{chain_check: {:broken_at, 2}}} = Fx.reconcile_all(Fx.authorized(schema))
      else
        IO.puts("C8a skipped: the test role does not own the ledger tables (owner-tamper)")
      end
    end

    test "C8a a tampered counter hash breaks the chain at the last entry", %{schema: schema} do
      if Fx.table_owner?(schema) do
        Enum.each(["a", "b", "c"], &receipt!(schema, [&1], 1))
        Fx.disable_guards!(schema, "ledger_counter")
        Fx.exec!(~s|UPDATE "#{schema}".ledger_counter SET last_chain_hash = repeat('3', 64)|)
        assert {:ok, %{chain_check: {:broken_at, 3}}} = Fx.reconcile_all(Fx.authorized(schema))
      else
        IO.puts("C8a skipped: the test role does not own the ledger tables (owner-tamper)")
      end
    end

    test "C8b the recomputation reuses Digest" do
      source = File.read!("lib/letflow/ledger/reconcile.ex")
      assert source =~ "Digest.entry_digest("
      assert source =~ "Digest.chain_hash("
      refute source =~ ":crypto.hash"
    end

    test "C8c a held chunk lock is reconcile_busy, per ledger id and transaction scoped", %{
      schema: schema
    } do
      build!(schema)
      lid = Fx.ledger_id()
      a = Fx.authorized(schema)
      me = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Fx.exec!("SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))", [schema, lid])
            send(me, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked, 5_000
      assert {:error, :reconcile_busy} = Ledger.reconcile(a, %{})
      assert {:ok, _} = Ledger.reconcile(Fx.authorized(schema, :reconcile, "other_ledger"), %{})
      send(holder.pid, :release)
      Task.await(holder)

      assert {:ok, _} = Ledger.reconcile(a, %{})

      assert %{rows: [[0]]} =
               Fx.exec!(
                 "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND classid::bigint = (hashtext($1)::bigint & 4294967295) AND objid::bigint = (hashtext($2)::bigint & 4294967295)",
                 [schema, lid]
               )
    end

    test "C8d a statement timeout propagates as a database error", %{schema: schema} do
      build!(schema)
      me = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Fx.exec!(~s|LOCK TABLE "#{schema}".ledger_balance IN ACCESS EXCLUSIVE MODE|)
            send(me, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked, 5_000

      try do
        error =
          assert_raise Postgrex.Error, fn ->
            Ledger.reconcile(Fx.authorized(schema), %{statement_timeout_ms: 200})
          end

        assert error.postgres.code == :query_canceled
      after
        send(holder.pid, :release)
        Task.await(holder)
      end
    end
  end

  describe "tenancy, options and cursor" do
    test "C9a another tenant's corruption never appears; a cursor is bound to its ledger id", %{
      schema: schema
    } do
      other = Fx.tenant!()
      build!(schema)
      build!(other)
      corrupt_balance!(other, ["a0"], 5)

      assert {:ok, %{mismatches: []}} = Fx.reconcile_all(Fx.authorized(schema))
      assert {:ok, %{mismatches: [%{key: ["a0"]}]}} = Fx.reconcile_all(Fx.authorized(other))

      {:ok, %{next_cursor: cursor}} =
        Ledger.reconcile(Fx.authorized(schema), %{chunk_size: 2})

      assert {:error, :invalid_cursor} =
               Ledger.reconcile(Fx.authorized(schema, :reconcile, "other_ledger"), %{
                 cursor: cursor
               })
    end

    test "C9b bad options and cursors are typed refusals", %{schema: schema} do
      build!(schema)
      a = Fx.authorized(schema)

      for opts <- [
            %{chunk_size: 0},
            %{chunk_size: "x"},
            %{statement_timeout_ms: 0},
            %{statement_timeout_ms: 10_001}
          ] do
        assert {:error, :invalid_opts} = Ledger.reconcile(a, opts)
      end

      {:ok, %{next_cursor: cursor}} = Ledger.reconcile(a, %{chunk_size: 2})

      for bad <- [
            "!!not base64!!",
            Base.url_encode64("[1]", padding: false),
            String.duplicate("a", 20_000),
            123,
            edit_cursor(cursor, &Map.put(&1, "n", 10_000)),
            edit_cursor(cursor, &Map.put(&1, "after", ["a", "b"])),
            edit_cursor(cursor, &Map.put(&1, "ph", "nope")),
            edit_cursor(cursor, &Map.put(&1, "prev", "zz"))
          ] do
        assert {:error, :invalid_cursor} = Ledger.reconcile(a, %{cursor: bad})
      end

      expired = edit_cursor(cursor, &Map.put(&1, "dl", 1))
      assert {:error, :run_expired} = Ledger.reconcile(a, %{cursor: expired})

      assert {:ok, %{mismatches: [], next_cursor: nil}} =
               Fx.reconcile_all(a, %{chunk_size: 10_000})
    end

    test "C9c reconcile starts its own transaction", %{schema: schema} do
      Repo.transaction(fn ->
        assert_raise ArgumentError, fn -> Ledger.reconcile(Fx.authorized(schema), %{}) end
      end)
    end
  end
end
