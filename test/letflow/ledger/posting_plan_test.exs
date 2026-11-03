defmodule Letflow.Ledger.PostingPlanTest do
  @moduledoc """
  REQ-692 / GH #3726 criteria 3-8: PL-SH-1..4, PL-LK-1..4, PL-DUP-1..3, PL-WR-1..4, PL-SC-1.
  The posting plan of one or two postings: `lock_postings/1` (checks, the one lock step, duplicates)
  and `write_posting/2`. PL-DUP-3b (a duplicate at lookup 3) cannot be forced: a competing poster
  of the same command must take the balance locks the plan already holds, so lookup 3 is covered by
  the all-duplicate and mixed paths (PL-DUP-1, PL-DUP-2) and by PL-DUP-3c (one classification for
  all three lookups). Sandbox `:auto` with real commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.Ledger.Digest
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo

  @reuse {:ledger_refused, :idempotency_key_reuse, "idempotency_key_reuse", %{}}
  @doc_posting %{document_type: "doc_t", document_id: "doc-1"}

  setup do
    Fx.setup_auto_mode!()
    :ok = H.attach_error_handler(__MODULE__)
    %{schema: Fx.tenant!()}
  end

  # A capability on `ledger_id` receiving `qty` on the given keys (listed as given).
  defp cap(schema, ledger_id, keys, opts \\ []) do
    {qty, opts} = Keyword.pop(opts, :qty, 5)
    {cause, opts} = Keyword.pop(opts, :cause, "receipt")
    legs = Enum.map(keys, &Fx.leg(&1, qty))

    posting = Map.merge(@doc_posting, Keyword.get(opts, :posting, %{}))

    Fx.capability(
      schema,
      cause,
      legs,
      [ledger_id: ledger_id] ++ Keyword.put(opts, :posting, posting)
    )
  end

  # The pair of one document: same subject, same client_op_id, the other fields unique.
  defp pair(schema, keys_a \\ [["a1"]], keys_b \\ [["b1"]], opts \\ []) do
    a = cap(schema, "ledger_a", keys_a, opts)

    shared = [subject_id: a.subject_id, command: %{client_op_id: a.command.client_op_id}]
    b_opts = Keyword.merge(opts, shared)

    b =
      cap(schema, "ledger_b", keys_b, b_opts ++ [])
      |> then(fn b ->
        %{b | command: Map.merge(b.command, Keyword.get(opts, :b_command, %{}))}
      end)

    {a, b}
  end

  # lock_postings, then write every posting; any refusal rolls the transaction back.
  defp plan_tx(caps) do
    Repo.transaction(fn ->
      case Ledger.lock_postings(caps) do
        {:ok, plan} ->
          for c <- caps do
            {:ok, posted} = Ledger.write_posting(plan, c.posting.ledger_id)
            posted
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp contract(atom), do: {:error, {:ledger_contract, atom}}

  defp classify({sql, params}) do
    ledger = Enum.find(params, &(&1 in ["ledger_a", "ledger_b"]))
    key = Enum.find(params, &(&1 in ["a1", "a2", "b1", "b2"]))

    cond do
      sql =~ ~r/^UPDATE/ and sql =~ "ledger_balance" -> :update_balance
      sql =~ ~r/^UPDATE/ and sql =~ "ledger_counter" -> :update_counter
      sql =~ ~r/INSERT INTO "[^"]+"\."ledger_entry"/ -> :insert_entry
      sql =~ ~r/INSERT INTO "[^"]+"\."ledger_leg"/ -> :insert_leg
      sql =~ ~r/INSERT INTO "[^"]+"\."ledger_balance"/ -> {:insert_balance, ledger, key}
      sql =~ ~r/FROM "[^"]+"\."ledger_balance".*FOR UPDATE/s -> {:lock_balance, ledger, key}
      sql =~ ~r/INSERT INTO "[^"]+"\."ledger_counter"/ -> {:insert_counter, ledger}
      sql =~ ~r/FROM "[^"]+"\."ledger_counter".*FOR UPDATE/s -> {:lock_counter, ledger}
      sql =~ ~r/^SELECT .* FROM "[^"]+"\."ledger_entry"/s -> :lookup
      true -> nil
    end
  end

  defp classified(statements), do: statements |> Enum.map(&classify/1) |> Enum.reject(&is_nil/1)

  defp counts(schema),
    do:
      for(t <- ~w(ledger_entry ledger_leg ledger_counter ledger_balance), do: Fx.count(schema, t))

  # -- criterion 3: shape and checks -------------------------------------------------------------

  describe "plan shape and checks (criterion 3)" do
    test "PL-SH-1 list shape, prefixes and count are refused with zero statements", %{
      schema: schema
    } do
      good = cap(schema, "ledger_a", [["a1"]])

      other = %{
        cap(schema, "ledger_b", [["b1"]])
        | prefix: "tenant_" <> String.duplicate("0", 32)
      }

      bad_prefix = %{good | prefix: "public"}

      for input <- [[], :x, [:x], [good, :x], [good, other], [bad_prefix], [good, bad_prefix]] do
        {result, statements} = Fx.record(fn -> Ledger.lock_postings(input) end)
        assert result == contract(:invalid_capability), inspect(input)
        assert statements == [], inspect(input)
      end

      three = [good, cap(schema, "ledger_b", [["b1"]]), cap(schema, "ledger_c", [["a1"]])]
      {result, statements} = Fx.record(fn -> Ledger.lock_postings(three) end)
      assert result == contract(:ledger_too_many_postings)
      assert statements == []

      mixed = [good, other, cap(schema, "ledger_c", [["a1"]])]
      assert Ledger.lock_postings(mixed) == contract(:invalid_capability)
    end

    test "PL-SH-2 same ledger id twice and document mismatches are refused before any lock", %{
      schema: schema
    } do
      a = cap(schema, "ledger_a", [["a1"]])
      same = cap(schema, "ledger_a", [["a2"]])
      b = cap(schema, "ledger_b", [["b1"]])

      no_doc = fn ledger -> cap(schema, ledger, [["b1"]], posting: %{document_type: nil}) end

      cases = [
        {[a, same], :ledger_duplicate_ledger_in_transaction},
        {[a, cap(schema, "ledger_b", [["b1"]], posting: %{document_type: "other"})],
         :ledger_document_mismatch},
        {[a, cap(schema, "ledger_b", [["b1"]], posting: %{document_id: "doc-2"})],
         :ledger_document_mismatch},
        {[a, no_doc.("ledger_b")], :ledger_document_mismatch},
        {[no_doc.("ledger_b"), a], :ledger_document_mismatch},
        {[a, cap(schema, "ledger_b", [["b1"]], posting: %{document_id: ""})],
         :ledger_document_mismatch}
      ]

      for {caps, atom} <- cases do
        {result, statements} =
          Fx.record(fn -> Repo.transaction(fn -> Ledger.lock_postings(caps) end) end)

        assert result == {:ok, contract(atom)}, inspect(atom)

        refute Enum.any?(classified(statements), fn
                 {:insert_balance, _, _} -> true
                 {:lock_balance, _, _} -> true
                 {:insert_counter, _} -> true
                 {:lock_counter, _} -> true
                 _ -> false
               end)
      end

      # a plan of one capability has no document rule
      lone = Fx.capability(schema, "receipt", [Fx.leg(["a1"], 1)], ledger_id: "ledger_a")
      assert {:ok, %{duplicate: false}} = Fx.post_tx(lone)
      assert b.posting.ledger_id == "ledger_b"
    end

    test "PL-SH-3 outside a transaction it raises; repeatable read is refused", %{schema: schema} do
      c = cap(schema, "ledger_a", [["a1"]])

      assert_raise ArgumentError, ~r/open transaction/, fn -> Ledger.lock_postings([c]) end

      assert {:ok, {:error, {:ledger_contract, :isolation_not_read_committed}}} =
               Repo.transaction(fn ->
                 Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
                 Ledger.lock_postings([c])
               end)
    end

    test "PL-SH-4 LockedPlan is built only in lib/letflow/ledger.ex" do
      hits =
        for file <- Path.wildcard("lib/**/*.ex"),
            File.read!(file) =~ ~r/%(Letflow\.Ledger\.|Ledger\.)?LockedPlan\{/,
            do: file

      assert hits == ["lib/letflow/ledger.ex"]
    end
  end

  # -- criterion 4: the one lock step -------------------------------------------------------------

  describe "the one lock step (criterion 4)" do
    test "PL-LK-1 [A,B] and [B,A] send the identical statement sequence, and write nothing", %{
      schema: schema
    } do
      # two ledger ids, two balance keys each, given in descending order
      {a, b} = pair(schema, [["b1"], ["a1"]], [["b1"], ["a1"]])

      run = fn caps ->
        {result, statements} =
          Fx.record(fn ->
            Repo.transaction(fn ->
              {:ok, _plan} = Ledger.lock_postings(caps)
              Repo.rollback(:probe)
            end)
          end)

        assert result == {:error, :probe}
        classified(statements)
      end

      expected =
        [:lookup, :lookup] ++
          for(l <- ["ledger_a", "ledger_b"], k <- ["a1", "b1"], do: {:insert_balance, l, k}) ++
          for(l <- ["ledger_a", "ledger_b"], k <- ["a1", "b1"], do: {:lock_balance, l, k}) ++
          [:lookup, :lookup] ++
          [{:insert_counter, "ledger_a"}, {:insert_counter, "ledger_b"}] ++
          [{:lock_counter, "ledger_a"}, {:lock_counter, "ledger_b"}] ++
          [:lookup, :lookup]

      assert run.([a, b]) == expected
      assert run.([b, a]) == expected
    end

    test "PL-LK-2 a refused second posting locks both balance sets and takes no counter", %{
      schema: schema
    } do
      {a, _b} = pair(schema)
      b = cap(schema, "ledger_b", [["b1"]], cause: "issue", qty: -5, subject_id: a.subject_id)
      b = %{b | command: %{b.command | client_op_id: a.command.client_op_id}}

      {result, statements} =
        Fx.record(fn ->
          Repo.transaction(fn -> Repo.rollback(Ledger.lock_postings([a, b])) end)
        end)

      assert {:error, {:error, {:ledger_refused, :insufficient_balance, _, _}}} = result
      order = classified(statements)

      assert {:lock_balance, "ledger_a", "a1"} in order
      assert {:lock_balance, "ledger_b", "b1"} in order

      refute Enum.any?(order, &(&1 in [:insert_entry, :insert_leg, :update_balance]))
      refute Enum.any?(order, &match?({:insert_counter, _}, &1))
      refute Enum.any?(order, &match?({:lock_counter, _}, &1))
      assert counts(schema) == [0, 0, 0, 0]
    end

    test "PL-LK-3 two plans over the same two ledger ids in opposite order: no deadlock", %{
      schema: schema
    } do
      Fx.seed_on_hand!(schema, ["a1"], 1, ledger_id: "ledger_a")
      Fx.seed_on_hand!(schema, ["b1"], 1, ledger_id: "ledger_b")

      {a1, b1} = pair(schema, [["a1"]], [["b1"]], posting: %{document_id: "doc-1"})
      {a2, b2} = pair(schema, [["a1"]], [["b1"]], posting: %{document_id: "doc-2"})

      %{first: r1, second: r2} =
        H.forced_overlap(
          schema,
          {:ledger_balance, "ledger_b", ["b1"]},
          fn -> plan_tx([a1, b1]) end,
          fn -> plan_tx([b2, a2]) end
        )

      assert {:ok, [_, _]} = r1
      assert {:ok, [_, _]} = r2
      assert Fx.last_seq(schema, "ledger_a") == 3
      assert Fx.last_seq(schema, "ledger_b") == 3
    end

    test "PL-LK-4 a one-posting plan on B and a two-posting plan on A and B both commit", %{
      schema: schema
    } do
      Fx.seed_on_hand!(schema, ["a1"], 1, ledger_id: "ledger_a")
      Fx.seed_on_hand!(schema, ["b1"], 1, ledger_id: "ledger_b")

      {a, b} = pair(schema)
      single = cap(schema, "ledger_b", [["b1"]])

      %{first: r1, second: r2} =
        H.forced_overlap(
          schema,
          {:ledger_balance, "ledger_b", ["b1"]},
          fn -> Fx.post_tx(single) end,
          fn -> plan_tx([a, b]) end
        )

      assert {:ok, %{duplicate: false}} = r1
      assert {:ok, [_, _]} = r2
      assert Fx.last_seq(schema, "ledger_a") == 2
      assert Fx.last_seq(schema, "ledger_b") == 3
    end
  end

  # -- criterion 5: duplicates ----------------------------------------------------------------------

  describe "duplicates in a plan (criterion 5)" do
    test "PL-DUP-1 a committed plan replayed returns both entries and writes nothing", %{
      schema: schema
    } do
      {a, b} = pair(schema)
      assert {:ok, [first_a, first_b]} = plan_tx([a, b])

      {result, statements} = Fx.record(fn -> plan_tx([a, b]) end)
      assert {:ok, [%{duplicate: true} = dup_a, %{duplicate: true} = dup_b]} = result
      assert dup_a.entry_id == first_a.entry_id
      assert dup_b.entry_id == first_b.entry_id

      assert Fx.count(schema, "ledger_entry") == 2
      assert Fx.last_seq(schema, "ledger_a") == 1
      assert Fx.last_seq(schema, "ledger_b") == 1
      # the lock step stopped at the first lookup: no balance or counter lock at all
      assert classified(statements) == [:lookup, :lookup]
    end

    test "PL-DUP-2 a one-posting commit then a plan with the same A command is a reuse", %{
      schema: schema
    } do
      {a, b} = pair(schema)
      assert {:ok, %{duplicate: false}} = Fx.post_tx(a)

      assert plan_tx([a, b]) == {:error, @reuse}
      assert plan_tx([b, a]) == {:error, @reuse}

      assert Fx.count(schema, "ledger_entry") == 1
      assert Fx.last_seq(schema, "ledger_a") == 1
      assert Fx.last_seq(schema, "ledger_b") == 0
      assert Fx.count(schema, "ledger_counter") == 1
    end

    test "PL-DUP-3a a duplicate that appears at lookup 2 makes the plan a reuse", %{
      schema: schema
    } do
      parent = self()
      {a, b} = pair(schema)

      {t1, pid1} =
        H.start_worker(fn ->
          Repo.transaction(fn ->
            {:ok, _} = Ledger.post(a)
            send(parent, :first_posted)

            receive do
              :commit -> :ok
            after
              H.await_ms() -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive :first_posted, 10_000

      # the plan finds nothing at lookup 1, then blocks on the first sorted key (an A key) that
      # the open transaction holds; it holds nothing itself, so the poster is never blocked
      {t2, pid2} = H.start_worker(fn -> plan_tx([a, b]) end)
      H.await_blocked_by(pid2, [pid1])
      send(t1.pid, :commit)

      assert {{:ok, :ok}, _} = Task.await(t1, H.await_ms())
      assert {{:error, @reuse}, _} = Task.await(t2, H.await_ms())

      assert Fx.count(schema, "ledger_entry") == 1
      assert Fx.last_seq(schema, "ledger_a") == 1
      assert Fx.last_seq(schema, "ledger_b") == 0
    end

    test "PL-DUP-3c the three lookups call one classification function" do
      source = File.read!("lib/letflow/ledger.ex")
      assert length(Regex.scan(~r/<- lookup_all\(prefix, parts\)/, source)) == 3
      # the definition and its one call in lookup_all/2
      assert length(Regex.scan(~r/\blookup\(prefix, /, source)) == 2
    end
  end

  # -- criterion 6: writing --------------------------------------------------------------------------

  describe "writing a locked posting (criterion 6)" do
    test "PL-WR-1 a two-posting plan commits two entries, each seq 1 with its own chain", %{
      schema: schema
    } do
      {a, b} = pair(schema)

      assert {:ok, [%{posting_seq: 1, ledger_id: "ledger_a"}, %{posting_seq: 1} = pb]} =
               plan_tx([a, b])

      assert pb.ledger_id == "ledger_b"

      %{rows: rows} =
        Repo.query!(
          ~s|SELECT ledger_id, posting_seq, entry_digest, chain_hash, document_id FROM "#{schema}".ledger_entry ORDER BY ledger_id|
        )

      assert [[_, 1, d_a, c_a, "doc-1"], [_, 1, d_b, c_b, "doc-1"]] = rows
      assert c_a == Digest.chain_hash("", d_a)
      assert c_b == Digest.chain_hash("", d_b)
      assert c_a != c_b
      assert Fx.last_seq(schema, "ledger_a") == 1
      assert Fx.last_seq(schema, "ledger_b") == 1
    end

    test "PL-WR-2 a refused second posting commits nothing of either", %{schema: schema} do
      {a, _} = pair(schema)
      b = cap(schema, "ledger_b", [["b1"]], cause: "issue", qty: -5, subject_id: a.subject_id)
      b = %{b | command: %{b.command | client_op_id: a.command.client_op_id}}

      assert {:error, {:ledger_refused, :insufficient_balance, _, _}} = plan_tx([a, b])
      assert counts(schema) == [0, 0, 0, 0]
    end

    test "PL-WR-3 a ledger id outside the plan, and a second write of one ledger id", %{
      schema: schema
    } do
      {a, b} = pair(schema)

      assert {:ok, :done} =
               Repo.transaction(fn ->
                 {:ok, plan} = Ledger.lock_postings([a, b])
                 assert Ledger.write_posting(plan, "ledger_z") == contract(:not_in_plan)
                 assert {:ok, %{duplicate: false}} = Ledger.write_posting(plan, "ledger_a")
                 assert Fx.count(schema, "ledger_entry") == 1
                 assert Fx.last_seq(schema, "ledger_a") == 1

                 assert Ledger.write_posting(plan, "ledger_a") == contract(:plan_already_written)
                 assert Fx.count(schema, "ledger_entry") == 1
                 assert Fx.count(schema, "ledger_leg") == 1
                 assert Fx.last_seq(schema, "ledger_a") == 1
                 :done
               end)
    end

    test "PL-WR-4 an event-time refusal of the second posting writes nothing", %{schema: schema} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      {a, b} =
        pair(schema, [["a1"]], [["b1"]],
          b_command: %{device_id: "dev-1", client_seq: 1, client_event_time: future}
        )

      assert {:error, {:ledger_refused, :event_time_in_future, _, _}} = plan_tx([a, b])
      assert Fx.last_seq(schema, "ledger_a") == 0
      assert Fx.last_seq(schema, "ledger_b") == 0
      assert counts(schema) == [0, 0, 0, 0]
    end
  end

  # -- criterion 8 --------------------------------------------------------------------------------

  test "PL-SC-1 no caller of lock_postings or write_posting in lib outside ledger.ex" do
    callers =
      for file <- Path.wildcard("lib/**/*.ex"),
          file != "lib/letflow/ledger.ex",
          File.read!(file) =~ ~r/\b(lock_postings|write_posting)\(/,
          do: file

    assert callers == []
  end
end
