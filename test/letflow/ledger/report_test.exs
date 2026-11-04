defmodule Letflow.Ledger.ReportTest do
  @moduledoc """
  REQ-637 / GH #3559 part B, criteria 5 and 6 and the read half of 9: what a report states, its
  allowlisted rows, `entries/3`, the CS-01 identity, read-only statements and tenant separation
  (T-RP-1..5, T-EN-1..4, T-TN-1). Sandbox `:auto`, committed tenants, `async: false`.
  """

  use Letflow.DataCase, async: false
  use ExUnitProperties

  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Repo

  @report_keys ~w(as_of basis cutoff_seq filters ledger_id ledger_seq next_cursor rows timezone)a
  @row_keys ~w(k last_posting_seq quantity unit_ref)a
  @entry_keys ~w(cause correlation_id document_id document_type entry_id event_time ledger_id legs posting_seq posting_time reason_code related_document_id reverses_entry_id)a
  @leg_keys ~w(document_line_id k leg_no quantity unit_ref)a

  setup do
    Fx.setup_auto_mode!()
    Fx.put_registry!()
    fx = Fx.tenant_fixture!()
    %{fx: fx, schema: fx.schema_name, auth: Fx.authorized!(fx)}
  end

  defp post!(schema, cause, legs, opts \\ []),
    do: Fx.post!(Fx.capability(schema, cause, legs, opts))

  defp receipt!(schema, key, qty, opts \\ []),
    do: post!(schema, "receipt", [Fx.leg(key, qty)], opts)

  defp sorted(list), do: Enum.sort(list)

  test "T-RP-1 the report has exactly the nine keys and allowlisted plain rows", %{
    schema: s,
    auth: a
  } do
    receipt!(s, ["a", "l"], 5)
    receipt!(s, ["b"], "1.5")

    assert {:ok, r} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{})
    assert sorted(Map.keys(r)) == sorted(@report_keys)
    assert r.ledger_id == Fx.ledger_id()
    assert r.as_of == nil
    assert r.filters == %{}

    for row <- r.rows do
      refute is_struct(row)
      assert sorted(Map.keys(row)) == sorted(@row_keys)
      assert length(row.k) == 8 and Enum.all?(row.k, &is_binary/1)
      assert is_binary(row.quantity) and row.quantity =~ ~r/\A-?\d+\.\d{9}\z/
    end

    assert Enum.find(r.rows, &(hd(&1.k) == "b")).k == ["b", "", "", "", "", "", "", ""]
    assert Enum.find(r.rows, &(hd(&1.k) == "b")).quantity == "1.500000000"
    refute inspect(r) =~ "actor_id"
    refute inspect(r) =~ "subject_id"
    refute inspect(r) =~ "bpm_"
  end

  test "T-RP-1b the timezone: the default, a tenant value, a malformed value", %{
    fx: fx,
    auth: a
  } do
    zone = fn ->
      {:ok, r} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{})
      r.timezone
    end

    assert zone.() == "Asia/Almaty"
    Fx.put_tenant_settings!(fx, %{"timezone" => "America/New_York"})
    assert zone.() == "America/New_York"
    Fx.put_tenant_settings!(fx, %{"timezone" => "bad zone; drop"})
    assert zone.() == "Asia/Almaty"
    Fx.put_tenant_settings!(fx, %{"timezone" => 5})
    assert zone.() == "Asia/Almaty"
  end

  test "T-RP-4 zero balances are returned; empty rows and keys past the cutoff are not", %{
    schema: s,
    auth: a
  } do
    receipt!(s, ["a", "l"], 5)
    post!(s, "issue", [Fx.leg(["a", "l"], -5)])
    :ok = Fx.insert_balance!(s, ["empty", "l"], "u1", 10)
    receipt!(s, ["late", "l"], 2)

    assert {:ok, r} = Ledger.balances(a, {:posting_seq, 2}, %{}, %{})
    assert Enum.map(r.rows, &{hd(&1.k), &1.quantity}) == [{"a", "0.000000000"}]
    assert hd(r.rows).last_posting_seq == 2

    assert {:ok, now} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{})
    assert Enum.map(now.rows, &hd(&1.k)) == ["a", "late"]
    assert {:ok, evt} = Ledger.balances(a, {:event_time, DateTime.utc_now(), :latest}, %{}, %{})
    assert Enum.map(evt.rows, &hd(&1.k)) == ["a", "late"]
  end

  test "T-RP-5 only SELECT statements, no lock, and an open poster does not block a report", %{
    schema: s,
    auth: a
  } do
    receipt!(s, ["a", "l"], 5)

    {_, statements} =
      Fx.record(fn ->
        {:ok, _} = Ledger.balances(a, {:posting_seq, :latest}, %{}, %{})
        {:ok, _} = Ledger.balances(a, {:posting_seq, 1}, %{}, %{})
        {:ok, _} = Ledger.balances(a, {:event_time, DateTime.utc_now(), 1}, %{}, %{})
        {:ok, _} = Ledger.entries(a, %{}, %{})
      end)

    refute statements == []

    for {sql, _} <- statements do
      assert sql =~ ~r/\ASELECT/i
      refute sql =~ ~r/FOR (UPDATE|SHARE|NO KEY)|INSERT|UPDATE|DELETE|LOCK/
    end

    parent = self()

    poster =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, _} = Ledger.post(Fx.capability(s, "receipt", [Fx.leg(["a", "l"], 1)]))
          send(parent, :posted)

          receive do
            :go -> :ok
          after
            20_000 -> :timeout
          end
        end)
      end)

    assert_receive :posted, 20_000

    reader = Task.async(fn -> Ledger.balances(a, {:posting_seq, :latest}, %{}, %{}) end)
    assert {:ok, {:ok, r}} = Task.yield(reader, 10_000)
    assert r.ledger_seq == 1
    send(poster.pid, :go)
    assert {:ok, _} = Task.await(poster, 20_000)
  end

  property "T-RP-3 CS-01: opening + movements in (N0, N1] == closing, both bases", %{} do
    check all(
            ops <-
              StreamData.list_of(
                StreamData.tuple({
                  StreamData.member_of([:in, :out, :undo]),
                  StreamData.integer(0..2),
                  StreamData.integer(1..9)
                }),
                min_length: 50,
                max_length: 56
              ),
            max_runs: 2
          ) do
      fx = Fx.tenant_fixture!()
      s = fx.schema_name
      auth = Fx.authorized!(fx)
      keys = ["k0", "k1", "k2"]

      # log: [{seq, key_index, delta}] of every leg posted; a reversal is its own negated leg
      {log, _model, _last} =
        Enum.reduce(ops, {[], %{0 => 0, 1 => 0, 2 => 0}, nil}, fn {kind, ki, q},
                                                                  {log, model, last} ->
          {ki, delta} = movement(kind, ki, q, model, last)
          posted = post!(s, "adjust", [Fx.leg([Enum.at(keys, ki)], delta)])

          {[{posted.posting_seq, ki, delta} | log], Map.update!(model, ki, &(&1 + delta)),
           {ki, delta}}
        end)

      log = Enum.reverse(log)
      n1 = length(log)
      n0 = div(n1, 2)
      t = DateTime.add(DateTime.utc_now(), 60)

      closing = fn basis ->
        {:ok, r} = Ledger.balances(auth, basis, %{}, %{})
        Map.new(r.rows, &{hd(&1.k), Decimal.new(&1.quantity)})
      end

      for {open_basis, close_basis} <- [
            {{:posting_seq, n0}, {:posting_seq, n1}},
            {{:event_time, t, n0}, {:event_time, t, n1}}
          ] do
        opening = closing.(open_basis)
        closed = closing.(close_basis)

        for {key, ki} <- Enum.with_index(keys) do
          moved =
            for {seq, ^ki, d} <- log, seq > n0 and seq <= n1, reduce: Decimal.new(0) do
              acc -> Decimal.add(acc, d)
            end

          before = Map.get(opening, key, Decimal.new(0))
          after_ = Map.get(closed, key, Decimal.new(0))
          assert Decimal.equal?(Decimal.add(before, moved), after_)
        end
      end
    end
  end

  # an out that the key cannot cover becomes an in; an undo negates the previous movement when
  # the key can pay for it (reversal is modelled as its own negated leg, P12 not merged)
  defp movement(:in, ki, q, _model, _last), do: {ki, q}
  defp movement(:out, ki, q, model, _last), do: if(model[ki] >= q, do: {ki, -q}, else: {ki, q})
  defp movement(:undo, ki, q, _model, nil), do: {ki, q}

  defp movement(:undo, _ki, q, model, {lki, ldelta}),
    do: if(model[lki] - ldelta >= 0 and ldelta != 0, do: {lki, -ldelta}, else: {lki, q})

  describe "entries/3" do
    test "T-EN-1 ascending order, exact key sets, no excluded column", %{schema: s, auth: a} do
      receipt!(s, ["a", "l"], 5,
        posting: %{document_type: "doc", document_id: "d1", reason_code: "r1"}
      )

      post!(s, "transfer", [Fx.leg(["a", "l"], -2), Fx.leg(["a", "m"], 2)])

      assert {:ok, %{rows: rows, next_cursor: nil}} = Ledger.entries(a, %{}, %{})
      assert Enum.map(rows, & &1.posting_seq) == [1, 2]

      for row <- rows do
        assert sorted(Map.keys(row)) == sorted(@entry_keys)
        assert match?(%DateTime{}, row.event_time) and match?(%DateTime{}, row.posting_time)
        assert row.reverses_entry_id == nil
        assert {:ok, _} = Ecto.UUID.cast(row.entry_id)

        refute Enum.any?(
                 Map.keys(row),
                 &(Atom.to_string(&1) =~ ~r/actor|subject|bpm_|origin|hash|digest|device|client/)
               )

        for leg <- row.legs do
          assert sorted(Map.keys(leg)) == sorted(@leg_keys)
          assert leg.quantity =~ ~r/\A-?\d+\.\d{9}\z/
        end
      end

      assert [
               %{document_type: "doc", document_id: "d1", reason_code: "r1", cause: "receipt"},
               second
             ] = rows

      assert Enum.map(second.legs, & &1.leg_no) == [1, 2]
      assert Enum.map(second.legs, & &1.quantity) == ["-2.000000000", "2.000000000"]
    end

    test "T-EN-2 filters, an empty valid range and the refusals", %{schema: s, auth: a} do
      receipt!(s, ["a", "l"], 5, posting: %{document_type: "doc", document_id: "d1"})
      receipt!(s, ["a", "l"], 5, posting: %{document_type: "doc", document_id: "d2"})
      post!(s, "issue", [Fx.leg(["a", "l"], -1)], posting: %{document_type: "other"})

      seqs = fn filters ->
        {:ok, %{rows: rows}} = Ledger.entries(a, filters, %{})
        Enum.map(rows, & &1.posting_seq)
      end

      assert seqs.(%{"cause" => "receipt"}) == [1, 2]
      assert seqs.(%{cause: "issue"}) == [3]
      assert seqs.(%{"document_type" => "doc", "document_id" => "d2"}) == [2]
      assert seqs.(%{"from_seq" => 2, "to_seq" => 2}) == [2]
      assert seqs.(%{"from_seq" => 3}) == [3]
      assert seqs.(%{"to_seq" => 1}) == [1]
      assert seqs.(%{"cause" => "adjust"}) == []

      assert {:ok, %{rows: [], next_cursor: nil}} =
               Ledger.entries(a, %{"from_seq" => 50, "to_seq" => 60}, %{})

      correlation =
        Repo.query!(~s|SELECT correlation_id FROM "#{s}".ledger_entry WHERE posting_seq = 1|).rows
        |> hd()
        |> hd()

      assert seqs.(%{"correlation_id" => correlation}) == [1]

      bad = [
        %{"nope" => "x"},
        %{"cause" => 1},
        %{"cause" => ""},
        %{"from_seq" => -1},
        %{"from_seq" => "1"},
        %{"from_seq" => 5, "to_seq" => 4},
        %{"prefix" => "tenant_x"},
        %{"ledger_id" => "other"},
        "not a map"
      ]

      {results, statements} = Fx.record(fn -> for f <- bad, do: Ledger.entries(a, f, %{}) end)
      assert Enum.all?(results, &(&1 == {:error, :invalid_filter}))
      assert statements == []

      for page <- [%{limit: 0}, %{cursor: -1}, %{cursor: "1"}, %{z: 1}],
          do: assert({:error, :invalid_filter} = Ledger.entries(a, %{}, page))
    end

    test "T-EN-3 paging: each entry once, the cursor is the last seq, postings landing between",
         %{
           schema: s,
           auth: a
         } do
      for i <- 1..5, do: receipt!(s, ["a#{i}"], 1)

      assert {:ok, %{rows: p1, next_cursor: 2}} = Ledger.entries(a, %{}, %{limit: 2})
      receipt!(s, ["z"], 1)
      assert {:ok, %{rows: p2, next_cursor: 4}} = Ledger.entries(a, %{}, %{limit: 2, cursor: 2})
      assert {:ok, %{rows: p3, next_cursor: nil}} = Ledger.entries(a, %{}, %{limit: 2, cursor: 4})

      seqs = Enum.map(p1 ++ p2 ++ p3, & &1.posting_seq)
      assert seqs == [1, 2, 3, 4, 5, 6]
      assert {:ok, %{rows: capped}} = Ledger.entries(a, %{}, %{limit: 10_000})
      assert length(capped) == 6
    end

    test "T-EN-4 a reversal row carries reverses_entry_id, its target no marker", %{
      schema: s,
      auth: a
    } do
      receipt!(s, ["a", "l"], 5)

      # `post/1` refuses the cause `reversal` until P12 (REQ-637 part A) merges, so a reversal
      # entry is inserted raw here; the read side only has to report the stored column.
      %{rows: [[target]]} =
        Repo.query!(~s|SELECT id FROM "#{s}".ledger_entry WHERE posting_seq = 1|)

      Repo.query!(~s|ALTER TABLE "#{s}".ledger_entry DISABLE TRIGGER USER|)

      Repo.query!(
        ~s|INSERT INTO "#{s}".ledger_entry (id, ledger_id, posting_seq, cause, sign_rule, reverses_entry_id, actor_id, subject_id, correlation_id, event_time, posting_time, client_op_id, origin_key, payload_hash, entry_digest, chain_hash, registration_hash, leg_count) SELECT gen_random_uuid(), ledger_id, 2, 'reversal', 'reversal', id, actor_id, subject_id, correlation_id, event_time, posting_time, 'rev-op', 'rev-origin', payload_hash, entry_digest, chain_hash, registration_hash, leg_count FROM "#{s}".ledger_entry WHERE posting_seq = 1|
      )

      assert {:ok, %{rows: [first, second]}} = Ledger.entries(a, %{}, %{})
      assert first.reverses_entry_id == nil
      assert second.reverses_entry_id == Ecto.UUID.load!(target)
      assert {:ok, %{rows: [only]}} = Ledger.entries(a, %{"cause" => "reversal"}, %{})
      assert only.posting_seq == 2
    end
  end
end
