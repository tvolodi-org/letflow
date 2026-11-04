defmodule Letflow.Ledger.GapFreeTest do
  @moduledoc """
  REQ-621 / GH #3469 part B, criteria 4 and 5: T-GF-1a..d, T-GF-2a..c, T-GF-3a/b, T-GF-4.
  The gap-free counter (insert-if-absent, then `FOR UPDATE`), the isolation assertion, the
  digest golden vector and the chain, and the literal-SQL source scan. Sandbox `:auto` with real
  commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.Ledger.Digest
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo

  setup do
    Fx.setup_auto_mode!()
    :ok = H.attach_error_handler(__MODULE__)
    %{schema: Fx.tenant!()}
  end

  defp receipt(schema, key, opts \\ []),
    do: Fx.capability(schema, "receipt", [Fx.leg(key, 1)], opts)

  describe "counter" do
    test "T-GF-1a two postings in forced overlap get n and n+1", %{schema: schema} do
      Fx.seed_on_hand!(schema, ["seed", "l"], 1)
      worker_a = fn -> Fx.post_tx(receipt(schema, ["a", "l"])) end
      worker_b = fn -> Fx.post_tx(receipt(schema, ["b", "l"])) end

      %{first: r1, second: r2} =
        H.forced_overlap(schema, {:ledger_counter, Fx.ledger_id()}, worker_a, worker_b)

      assert {:ok, %{posting_seq: s1}} = r1
      assert {:ok, %{posting_seq: s2}} = r2
      assert Enum.sort([s1, s2]) == [2, 3]
      assert Fx.last_seq(schema) == 3
    end

    test "T-GF-1b two first posters of a fresh ledger id: one counter row, 1 and 2", %{
      schema: schema
    } do
      ledger = "fresh_1b"

      results =
        for key <- [["a", "l"], ["b", "l"]] do
          Task.async(fn -> Fx.post_tx(receipt(schema, key, ledger_id: ledger)) end)
        end
        |> Task.await_many(30_000)

      assert [{:ok, %{posting_seq: a}}, {:ok, %{posting_seq: b}}] = results
      assert Enum.sort([a, b]) == [1, 2]
      assert Fx.count(schema, "ledger_counter") == 1
      assert Fx.last_seq(schema, ledger) == 2
    end

    test "T-GF-2a a poster that rolls back leaves no gap", %{schema: schema} do
      Fx.seed_on_hand!(schema, ["seed", "l"], 1)

      undone = fn ->
        Repo.transaction(fn ->
          {:ok, _posted} = Ledger.post(receipt(schema, ["a", "l"]))
          Repo.rollback(:undone)
        end)
      end

      kept = fn -> Fx.post_tx(receipt(schema, ["b", "l"])) end

      %{first: r1, second: r2} =
        H.forced_overlap(schema, {:ledger_counter, Fx.ledger_id()}, undone, kept)

      assert [{:ok, %{posting_seq: 2}}] = Enum.filter([r1, r2], &match?({:ok, _}, &1))
      assert [{:error, :undone}] = Enum.filter([r1, r2], &match?({:error, :undone}, &1))
      assert Fx.count(schema, "ledger_entry") == 2
      assert Fx.last_seq(schema) == 2

      assert %{rows: [[2]]} =
               Repo.query!(~s|SELECT max(posting_seq) FROM "#{schema}".ledger_entry|)
    end

    test "T-GF-2b a first poster of a fresh ledger id that rolls back leaves no counter row", %{
      schema: schema
    } do
      ledger = "fresh_2b"

      assert {:error, :undone} =
               Repo.transaction(fn ->
                 {:ok, _} = Ledger.post(receipt(schema, ["a", "l"], ledger_id: ledger))
                 Repo.rollback(:undone)
               end)

      assert Fx.count(schema, "ledger_counter") == 0
      assert {:ok, %{posting_seq: 1}} = Fx.post_tx(receipt(schema, ["a", "l"], ledger_id: ledger))
    end

    test "T-GF-2c 100 postings at concurrency 4 number exactly 1..100", %{schema: schema} do
      seqs =
        1..100
        |> Task.async_stream(
          fn i ->
            {:ok, %{posting_seq: seq}} = Fx.post_tx(receipt(schema, ["k#{i}", "l"]))
            seq
          end,
          max_concurrency: 4,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, seq} -> seq end)

      assert Enum.sort(seqs) == Enum.to_list(1..100)
      assert Fx.last_seq(schema) == 100
    end
  end

  describe "isolation" do
    test "T-GF-3a the default transaction is read committed" do
      assert {:ok, %{rows: [["read committed"]]}} =
               Repo.transaction(fn ->
                 Repo.query!("SELECT current_setting('transaction_isolation')")
               end)
    end

    test "T-GF-3b a repeatable-read transaction is refused before any read or lock", %{
      schema: schema
    } do
      cap = receipt(schema, ["a", "l"])

      {result, statements} =
        Fx.record(fn ->
          Repo.transaction(fn ->
            Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
            Ledger.post(cap)
          end)
        end)

      assert {:ok, {:error, {:ledger_contract, :isolation_not_read_committed}}} = result

      posting_statements =
        statements
        |> Enum.map(&elem(&1, 0))
        |> Enum.reject(&(&1 =~ ~r/\A(begin|commit|rollback|SET TRANSACTION)/i))

      assert posting_statements == ["SELECT current_setting('transaction_isolation')"]
      assert Fx.count(schema, "ledger_entry") == 0
      assert Fx.count(schema, "ledger_counter") == 0
      assert Fx.count(schema, "ledger_balance") == 0
    end
  end

  describe "digest" do
    @golden_digest "21b198f6397ca44f0da5e245204dcc009d6994212edafcb2fbd136652b7aca00"
    @golden_chain_first "7a9dd44a1bec22b2754db9d40fe0b37f016bb30133e36fc99979db7ca9978912"
    @golden_chain_second "529945e4bf6e4b6d739d1ddffc4fd71a4aa994ceb827e8456ab1ce9aab351477"

    defp golden_header do
      time = ~U[2026-01-02 03:04:05.123456Z]

      %{
        id: "11111111-1111-1111-1111-111111111111",
        ledger_id: "test_ledger",
        posting_seq: 1,
        cause: "receipt",
        sign_rule: "positive",
        actor_id: "22222222-2222-2222-2222-222222222222",
        subject_id: "33333333-3333-3333-3333-333333333333",
        correlation_id: "op-1",
        event_time: time,
        posting_time: time,
        client_op_id: "op-1",
        origin_key: "origin-1",
        payload_hash: String.duplicate("ab", 32),
        registration_hash: String.duplicate("cd", 32),
        leg_count: 2
      }
    end

    defp golden_legs do
      base = %{
        k1: "a",
        k2: "l",
        k3: "",
        k4: "",
        k5: "",
        k6: "",
        k7: "",
        k8: "",
        unit_ref: "u1"
      }

      [
        Map.merge(base, %{leg_no: 1, quantity: Decimal.new("10.5"), quantity_scale: 1}),
        Map.merge(base, %{
          leg_no: 2,
          quantity: Decimal.new("-3"),
          quantity_scale: 0,
          attrs: %{"b" => 1, "a" => [2]}
        })
      ]
    end

    test "T-GF-1c golden vector (recomputed independently in python3, golden.py in the task)" do
      assert Digest.entry_digest(golden_header(), golden_legs()) == @golden_digest
      assert Digest.chain_hash("", @golden_digest) == @golden_chain_first
      assert Digest.chain_hash(@golden_chain_first, @golden_digest) == @golden_chain_second
    end

    test "T-GF-1c every column class changes the digest; attrs key order does not" do
      base = Digest.entry_digest(golden_header(), golden_legs())
      [leg1, leg2] = golden_legs()

      changed = [
        Digest.entry_digest(%{golden_header() | cause: "issue"}, golden_legs()),
        Digest.entry_digest(
          %{golden_header() | posting_time: ~U[2026-01-02 03:04:05.123457Z]},
          golden_legs()
        ),
        Digest.entry_digest(golden_header(), [%{leg1 | k3: "x"}, leg2]),
        Digest.entry_digest(golden_header(), [%{leg1 | quantity: Decimal.new("10.6")}, leg2])
      ]

      assert length(Enum.uniq([base | changed])) == 5

      reordered = %{leg2 | attrs: %{"a" => [2], "b" => 1}}
      assert Digest.entry_digest(golden_header(), [leg1, reordered]) == base
    end

    test "T-GF-1d three consecutive postings chain through chain_hash/2", %{schema: schema} do
      for key <- [["a", "l"], ["b", "l"], ["c", "l"]], do: Fx.post!(receipt(schema, key))

      %{rows: rows} =
        Repo.query!(
          ~s|SELECT posting_seq, entry_digest, chain_hash FROM "#{schema}".ledger_entry ORDER BY posting_seq|
        )

      assert [1, 2, 3] == Enum.map(rows, &hd/1)

      Enum.reduce(rows, "", fn [_seq, entry_digest, chain_hash], previous ->
        assert chain_hash == Digest.chain_hash(previous, entry_digest)
        chain_hash
      end)

      last_chain = rows |> List.last() |> Enum.at(2)

      assert %{rows: [[^last_chain]]} =
               Repo.query!(~s|SELECT last_chain_hash FROM "#{schema}".ledger_counter|)
    end
  end

  describe "source scan" do
    @files ["lib/letflow/ledger.ex" | Path.wildcard("lib/letflow/ledger/*.ex")]

    # Returns {violations, query_literals} for one source text. Docs are skipped.
    defp scan(source) do
      ast =
        source
        |> Code.string_to_quoted!()
        |> Macro.prewalk(fn
          {:@, _, [{attr, _, _}]} when attr in [:moduledoc, :doc] -> nil
          node -> node
        end)

      {_, acc} =
        Macro.prewalk(ast, {[], []}, fn node, {bad, lits} = state ->
          case node do
            text when is_binary(text) ->
              if text =~ ~r/nextval|\bmax\s*\(/i,
                do: {node, {["forbidden text: #{text}" | bad], lits}},
                else: {node, state}

            {{:., _, [{:__aliases__, _, [:Repo]}, fun]}, _, [first | _]}
            when fun in [:query, :query!] ->
              if is_binary(first),
                do: {node, {bad, [first | lits]}},
                else: {node, {["non-literal Repo.#{fun} argument" | bad], lits}}

            {:fragment, _, [first | _]} ->
              if is_binary(first),
                do: {node, state},
                else: {node, {["non-literal fragment" | bad], lits}}

            {:lock, value} ->
              if value == "FOR UPDATE",
                do: {node, state},
                else: {node, {["lock other than FOR UPDATE" | bad], lits}}

            _ ->
              {node, state}
          end
        end)

      acc
    end

    test "T-GF-4 the ledger sources hold exactly the literal SQL statements" do
      results = Enum.map(@files, &scan(File.read!(&1)))
      assert Enum.flat_map(results, &elem(&1, 0)) == []

      assert results |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort() ==
               Enum.sort([
                 "SELECT current_setting('transaction_isolation')",
                 "SELECT clock_timestamp()",
                 # REQ-637 part C (reconcile/2): a reviewed addition, four literal statements
                 "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY",
                 "SELECT set_config('statement_timeout', $1, true)",
                 "SELECT pg_try_advisory_xact_lock(hashtext($1), hashtext($2))"
               ])
    end

    test "T-GF-4 the scan bites on an interpolated query and a sequence" do
      source = ~S"""
      defmodule Bad do
        def a(t), do: Repo.query!("SELECT nextval('#{t}')")
        def b(t), do: Repo.query!("SELECT 1 FROM #{t}")
        def c, do: from(c in "ledger_counter", lock: "FOR SHARE")
      end
      """

      {bad, _} = scan(source)
      assert length(bad) >= 3
    end
  end
end
