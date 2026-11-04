defmodule Letflow.Ledger.TwoPostingTest do
  @moduledoc """
  REQ-685 criteria 6 and 7 (decision 0073 A2, A3): two postings in one transaction (the run-time
  plan check) and the ONE lock step placed after every handler call of the node. Build-time
  plan refusals are released after authority as contract refusals, and nothing of the transaction
  is committed. The lock-order probes record the statements of a real completion
  (`Engine.complete_task/3`), so they fail if the lines stop being reduced into one merge.
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  alias Letflow.Ledger.HandlerPost
  alias Letflow.LedgerFixture, as: LF
  alias Letflow.LedgerPostFixture, as: Fx

  defp alpha(doc \\ "d1", extra \\ %{}),
    do:
      Fx.post_line(
        "post_alpha",
        Fx.posting("receipt", "a", "5", Map.put(extra, "document_id", doc))
      )

  defp beta(doc \\ "d1", extra \\ %{}),
    do:
      Fx.post_line(
        "post_beta",
        Fx.posting("receipt", "b", "7", Map.put(extra, "document_id", doc))
      )

  defp reason({:error, {:line, _, :ledger_post}, reason, _changes}), do: reason
  defp reason({:error, _step, reason, _changes}), do: reason

  test "TP-1 a third posting is refused ledger_too_many_postings, nothing committed" do
    ctx = Fx.case!("req685-tp1", [alpha(), beta()])

    assert {:ledger_contract, :ledger_too_many_postings} ==
             reason(Fx.run_lines(ctx, [alpha(), beta(), alpha()]))

    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "TP-2 the same ledger id twice is ledger_duplicate_ledger_in_transaction" do
    ctx = Fx.case!("req685-tp2", [alpha()])

    assert {:ledger_contract, :ledger_duplicate_ledger_in_transaction} ==
             reason(Fx.run_lines(ctx, [alpha(), alpha()]))

    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "TP-3 a different or empty document is ledger_document_mismatch" do
    ctx = Fx.case!("req685-tp3", [alpha()])

    for second <- [beta("d2"), beta(""), beta("d1", %{"document_type" => "other"})] do
      assert {:ledger_contract, :ledger_document_mismatch} ==
               reason(Fx.run_lines(ctx, [alpha(), second]))
    end

    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "TP-4 two ledgers, one document: both commit, each with its own posting_seq" do
    ctx = Fx.case!("req685-tp4", [alpha(), beta()])
    assert {:ok, changes} = Fx.run_lines(ctx, [alpha(), beta()])

    assert %{
             "fixture_ledger_post" => %{posting_seq: 1, duplicate: false},
             "fixture_ledger_post:beta" => %{posting_seq: 1, duplicate: false}
           } = changes[{:ledger_write, :all}]

    assert {2, 2, 2, 2} = Fx.ledger_counts(ctx.schema)
  end

  test "TP-5 a refused second posting commits neither" do
    ctx = Fx.case!("req685-tp5", [alpha()])

    issue =
      Fx.post_line(
        "post_beta",
        Fx.posting("issue", "b", "-3", %{"document_id" => "d1"})
      )

    assert {:error, {:ledger_lock, :all}, {:ledger_refused, :insufficient_balance, _, _}, _} =
             Fx.run_lines(ctx, [alpha(), issue])

    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "TP-6 a duplicate retry plans again, writes nothing new and raises no error" do
    ctx = Fx.case!("req685-tp6", [alpha(), beta()])
    one = alpha("d1", %{"client_op_id" => "op-a"})
    two = beta("d1", %{"client_op_id" => "op-b"})

    assert {:ok, _} = Fx.run_lines(ctx, [one, two])
    assert {2, 2, 2, 2} = Fx.ledger_counts(ctx.schema)

    assert {:ok, changes} = Fx.run_lines(ctx, [one, two])
    assert %{"fixture_ledger_post" => %{duplicate: true}} = changes[{:ledger_write, :all}]
    assert {2, 2, 2, 2} = Fx.ledger_counts(ctx.schema)
  end

  test "TP-7 a completion that retries with the same idempotency key does not post twice" do
    ctx =
      Fx.case!("req685-tp7", [
        Fx.line("post_alpha", %{"posting" => Fx.posting("receipt", "a", "5")})
      ])

    assert {:ok, _} = Fx.complete(ctx, idempotency_key: "req685-tp7-key")
    assert {1, 1, 1, 1} = Fx.ledger_counts(ctx.schema)
    _ = Fx.complete(ctx, idempotency_key: "req685-tp7-key")
    assert {1, 1, 1, 1} = Fx.ledger_counts(ctx.schema)
  end

  # --- lock step probes -------------------------------------------------------------------

  defp complete_recorded(ctx) do
    {result, statements} = LF.record(fn -> Fx.complete(ctx) end)
    assert {:ok, _} = result
    Enum.map(statements, &elem(&1, 0))
  end

  defp index_of(statements, regex), do: Enum.find_index(statements, &Regex.match?(regex, &1))

  defp last_index_of(statements, regex),
    do:
      statements
      |> Enum.map(&Regex.match?(regex, &1))
      |> Enum.with_index()
      |> Enum.filter(&elem(&1, 0))
      |> List.last()
      |> elem(1)

  @ledger_stmt ~r/"ledger_(balance|counter)"/
  @entity_insert ~r/INSERT INTO "[^"]+"\."entity_record_latest"/

  defp ledger_lines(order) do
    for h <- order do
      note = Fx.line(h, %{"posting" => Fx.posting("receipt", "a", "5", %{"document_id" => "d1"})})
      note
    end
  end

  test "LK-1 no ledger balance or counter statement before the last handler call is built" do
    ctx = Fx.case!("req685-lk1", ledger_lines(["post_alpha", "post_beta"]))
    statements = complete_recorded(ctx)

    first_ledger = index_of(statements, @ledger_stmt)
    last_record_write = last_index_of(statements, @entity_insert)
    assert first_ledger, "the completion sent no ledger statement"
    assert last_record_write < first_ledger
  end

  defp lock_sequence(statements) do
    for sql <- statements, sql =~ @ledger_stmt do
      cond do
        sql =~ ~r/INSERT INTO "[^"]+"\."ledger_balance"/ -> :insert_balance
        sql =~ ~r/FROM "[^"]+"\."ledger_balance".*FOR UPDATE/s -> :lock_balance
        sql =~ ~r/INSERT INTO "[^"]+"\."ledger_counter"/ -> :insert_counter
        sql =~ ~r/FROM "[^"]+"\."ledger_counter".*FOR UPDATE/s -> :lock_counter
        sql =~ ~r/UPDATE "[^"]+"\."ledger_counter"/ -> :update_counter
        true -> :other
      end
    end
  end

  test "LK-2 and LK-3 both line orders take the same lock statements, and no posting_seq is allocated before they end" do
    sequences =
      for {slug, order} <- [
            {"req685-lk2", ["post_alpha", "post_beta"]},
            {"req685-lk3", ["post_beta", "post_alpha"]}
          ] do
        ctx = Fx.case!(slug, ledger_lines_by(order))
        sequence = lock_sequence(complete_recorded(ctx))

        last_lock = Enum.find_index(Enum.reverse(sequence), &(&1 == :lock_counter))
        last_lock = length(sequence) - 1 - last_lock
        first_update = Enum.find_index(sequence, &(&1 == :update_counter))
        assert first_update > last_lock
        assert Enum.take(sequence, 2) == [:insert_balance, :insert_balance]
        sequence
      end

    assert Enum.at(sequences, 0) == Enum.at(sequences, 1)
  end

  defp ledger_lines_by(order) do
    for {h, doc} <- Enum.zip(order, ["d1", "d1"]) do
      ledger = if h == "post_alpha", do: "a", else: "b"
      Fx.line(h, %{"posting" => Fx.posting("receipt", ledger, "5", %{"document_id" => doc})})
    end
  end

  test "LK-5 a numbered bookkeeping type takes its counter row (5a) before the first ledger statement (5b)" do
    ctx = Fx.case!("req685-lk5", ledger_lines(["post_alpha", "post_beta"]))

    # `create_definition/2` refuses a module-managed type, so the binding row is written raw.
    Repo.insert!(
      %Letflow.NumberSequences.Definition{
        tenant_id: ctx.tenant.tenant_id,
        key: "note_no",
        entity_type: "fxlp_note",
        prefix: "N",
        padding: 4,
        period: "none"
      },
      prefix: ctx.schema
    )

    statements = complete_recorded(ctx)

    counter_lock =
      index_of(statements, ~r/FROM "[^"]+"\."number_sequence_counter[^"]*".*FOR UPDATE/s)

    first_ledger = index_of(statements, @ledger_stmt)
    first_audit = index_of(statements, ~r/INSERT INTO "[^"]+"\."audit_chain_locks"/)

    assert counter_lock, "the numbered type's counter row was never locked"
    assert counter_lock < first_ledger
    assert first_ledger < first_audit
  end

  test "LK-4 a node without a posting line gets no lock step; one with it gets exactly one merge" do
    plain_lines = [Fx.line("plain"), Fx.line("plain")]
    post_lines = [Fx.line("post_alpha", %{"posting" => Fx.posting("receipt", "a", "5")})]
    ctx = Fx.case!("req685-lk4", post_lines)

    plain = Fx.build_lines(ctx, plain_lines)
    assert HandlerPost.lock_steps(plain, plain_lines) == plain

    posting = Fx.build_lines(ctx, post_lines)
    names = fn multi -> multi |> Ecto.Multi.to_list() |> Enum.map(&elem(&1, 0)) end
    assert names.(HandlerPost.lock_steps(posting, post_lines)) == names.(posting) ++ [:merge]
  end
end
