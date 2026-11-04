defmodule Letflow.Ledger.ReversalTest do
  @moduledoc """
  REQ-637 / GH #3559 part A, criteria 1, 2 and 11: R1..R7, A1..A6, P1..P5, S1..S2. The reversal
  posting, its refusals, the concurrency and guard cases, and the reversal of a two-posting
  document. Sandbox `:auto` with real commits on fresh tenants, hence `async: false`.

  A5 (the unique-index backstop): a second session cannot insert a competing reversal between the
  step 8 re-read and the entry insert, because the competitor would have to take the ledger
  counter row that this transaction already holds and the triggers tie the entry to the counter;
  so A5 tests the public `@doc false` mapping function with a `Postgrex.Error` struct instead.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo

  @not_found {:error,
              {:ledger_refused, :validation_failed, "validation_failed",
               %{reason: "movement_not_found"}}}

  setup do
    Fx.setup_auto_mode!()
    :ok = H.attach_error_handler(__MODULE__)
    %{schema: Fx.tenant!()}
  end

  defp receipt(schema, key, qty, opts \\ []),
    do: Fx.capability(schema, "receipt", [Fx.leg(key, qty)], opts)

  defp refused(result, code) do
    assert {:error, {:ledger_refused, ^code, wire, details}} = result
    assert wire == Atom.to_string(code)
    details
  end

  defp tables(schema),
    do:
      for(t <- ~w(ledger_entry ledger_leg ledger_counter ledger_balance), do: Fx.count(schema, t))

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

  @doc_posting %{document_type: "doc_t", document_id: "doc-1"}

  # A committed two-posting document: ledger_a and ledger_b, one subject, one client_op_id.
  defp post_pair!(schema, qty \\ 5) do
    a = receipt(schema, ["a1", "l"], qty, ledger_id: "ledger_a", posting: @doc_posting)

    b =
      receipt(schema, ["b1", "l"], qty,
        ledger_id: "ledger_b",
        posting: @doc_posting,
        subject_id: a.subject_id,
        command: %{client_op_id: a.command.client_op_id}
      )

    {:ok, [pa, pb]} = plan_tx([a, b])
    {pa, pb}
  end

  describe "the reversal posting (criterion 1)" do
    test "R1 a new posting with the negated legs; balances equal those before the target", %{
      schema: schema
    } do
      key = ["a", "l"]
      Fx.seed_on_hand!(schema, key, 3)
      before = Fx.total_on_hand(schema)

      legs = [Fx.leg(key, "5.5", "u1", %{attrs: %{"x" => 1}}), Fx.leg(["b", "l"], 2)]
      target = Fx.post!(Fx.capability(schema, "receipt", legs))
      assert Decimal.eq?(Fx.balance(schema, key).on_hand, "8.5")

      assert {:ok, %{duplicate: false} = rev} =
               Fx.post_tx(Fx.reversal_capability(schema, target.entry_id))

      assert rev.entry_id != target.entry_id
      assert rev.ledger_id == target.ledger_id
      assert rev.posting_seq == target.posting_seq + 1

      row = Fx.entry_row(schema, rev.entry_id)
      assert %{cause: "reversal", sign_rule: "reversal", reason_code: "r1"} = row
      assert row.reverses_entry_id == target.entry_id

      assert [{1, k1, q1, "u1", %{"x" => 1}}, {2, k2, q2, "u1", nil}] =
               Fx.leg_rows(schema, rev.entry_id)

      assert k1 == ["a", "l", "", "", "", "", "", ""]
      assert k2 == ["b", "l", "", "", "", "", "", ""]
      assert Decimal.eq?(q1, "-5.5") and Decimal.eq?(q2, -2)

      assert Decimal.eq?(Fx.total_on_hand(schema), before)
      assert Decimal.eq?(Fx.balance(schema, key).on_hand, 3)
    end

    test "R1b reversal_not_available is no longer returned", %{schema: schema} do
      target = Fx.post!(receipt(schema, ["a", "l"], 1))
      result = Fx.post_tx(Fx.reversal_capability(schema, target.entry_id))
      assert {:ok, _} = result
      refute inspect(result) =~ "reversal_not_available"
    end

    test "R2 a reversal without reason_code is refused, nothing written", %{schema: schema} do
      target = Fx.post!(receipt(schema, ["a", "l"], 1))
      before = tables(schema)
      seq = Fx.last_seq(schema)

      for reason <- [nil, ""] do
        cap = Fx.reversal_capability(schema, target.entry_id, reason: reason)

        assert %{leg_no: nil, reason: :reason_required} =
                 refused(Fx.post_tx(cap), :invalid_posting)
      end

      assert tables(schema) == before
      assert Fx.last_seq(schema) == seq
    end

    test "R2b shape: legs supplied, or a target with another cause, is posting_shape", %{
      schema: schema
    } do
      target = Fx.post!(receipt(schema, ["a", "l"], 1))

      with_legs =
        Fx.reversal_capability(schema, target.entry_id, posting: %{legs: [Fx.leg(["a"], -1)]})

      assert %{reason: :posting_shape} = refused(Fx.post_tx(with_legs), :invalid_posting)

      other_cause =
        receipt(schema, ["a", "l"], 1, posting: %{reverses_entry_id: target.entry_id})

      assert %{reason: :posting_shape} = refused(Fx.post_tx(other_cause), :invalid_posting)

      no_target =
        Fx.capability(schema, "reversal", [], posting: %{reason_code: "r1"})

      assert %{reason: :posting_shape} = refused(Fx.post_tx(no_target), :invalid_posting)
    end

    test "R3 document ref and correlation default to the target's; given values are kept", %{
      schema: schema
    } do
      target =
        Fx.post!(
          receipt(schema, ["a", "l"], 4,
            posting: %{document_type: "dt", document_id: "d-9", correlation_id: "corr-9"}
          )
        )

      assert {:ok, rev} = Fx.post_tx(Fx.reversal_capability(schema, target.entry_id))
      row = Fx.entry_row(schema, rev.entry_id)
      assert {row.document_type, row.document_id, row.correlation_id} == {"dt", "d-9", "corr-9"}

      other = Fx.post!(receipt(schema, ["b", "l"], 4))

      given =
        Fx.reversal_capability(schema, other.entry_id,
          posting: %{document_type: "dx", document_id: "d-x", correlation_id: "corr-x"}
        )

      assert {:ok, rev2} = Fx.post_tx(given)
      row2 = Fx.entry_row(schema, rev2.entry_id)

      assert {row2.document_type, row2.document_id, row2.correlation_id} ==
               {"dx", "d-x", "corr-x"}
    end

    test "R4 unknown, malformed, other-ledger and other-tenant targets: one identical refusal",
         %{schema: schema} do
      target = Fx.post!(receipt(schema, ["a", "l"], 4))
      other_ledger = Fx.post!(receipt(schema, ["a", "l"], 4, ledger_id: "ledger_z"))

      other_schema = Fx.tenant!()
      foreign = Fx.post!(receipt(other_schema, ["a", "l"], 4))
      before = tables(schema)

      results =
        for id <- [
              Ecto.UUID.generate(),
              "not-a-uuid",
              42,
              other_ledger.entry_id,
              foreign.entry_id
            ] do
          Fx.post_tx(Fx.reversal_capability(schema, id))
        end

      assert Enum.all?(results, &(&1 == @not_found))
      assert tables(schema) == before
      assert Fx.last_seq(schema) == target.posting_seq
      # the other tenant's entry is untouched
      assert Fx.count(other_schema, "ledger_entry") == 1
    end

    test "R5 a reversal of a reversal is posting_is_reversal naming the supplied id", %{
      schema: schema
    } do
      target = Fx.post!(receipt(schema, ["a", "l"], 4))
      {:ok, rev} = Fx.post_tx(Fx.reversal_capability(schema, target.entry_id))
      seq = Fx.last_seq(schema)

      assert %{entry_id: id} =
               refused(
                 Fx.post_tx(Fx.reversal_capability(schema, rev.entry_id)),
                 :posting_is_reversal
               )

      assert id == rev.entry_id
      assert Fx.last_seq(schema) == seq
    end

    test "R6 target, another posting and the reversal chain through the entry digests", %{
      schema: schema
    } do
      target = Fx.post!(receipt(schema, ["a", "l"], 4))
      Fx.post!(receipt(schema, ["b", "l"], 1))
      Fx.post!(Fx.reversal_capability(schema, target.entry_id))

      %{rows: rows} =
        Repo.query!(
          ~s|SELECT posting_seq, entry_digest, chain_hash, reverses_entry_id FROM "#{schema}".ledger_entry ORDER BY posting_seq|
        )

      assert [1, 2, 3] == Enum.map(rows, &hd/1)
      assert [nil, nil, rev_target] = Enum.map(rows, &Enum.at(&1, 3))
      assert Ecto.UUID.load!(rev_target) == target.entry_id

      Enum.reduce(rows, "", fn [_s, digest, chain, _r], previous ->
        assert chain == Letflow.Ledger.Digest.chain_hash(previous, digest)
        chain
      end)
    end

    test "R7 the event time rules apply to a reversal", %{schema: schema} do
      target = Fx.post!(receipt(schema, ["a", "l"], 4))
      seq = Fx.last_seq(schema)
      future = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601()

      cap =
        Fx.reversal_capability(schema, target.entry_id,
          command: %{device_id: "dev-r", client_seq: 1, client_event_time: future}
        )

      assert %{} == refused(Fx.post_tx(cap), :event_time_in_future)
      assert Fx.last_seq(schema) == seq
      assert Fx.count(schema, "ledger_entry") == 1
    end
  end

  describe "reversal under concurrency and the guard (criterion 2)" do
    test "A1 reversing an entry that already has a reversal writes nothing", %{schema: schema} do
      target = Fx.post!(receipt(schema, ["a", "l"], 4))
      Fx.post!(Fx.reversal_capability(schema, target.entry_id))
      before = tables(schema)
      seq = Fx.last_seq(schema)

      assert %{entry_id: id} =
               refused(
                 Fx.post_tx(Fx.reversal_capability(schema, target.entry_id)),
                 :posting_already_reversed
               )

      assert id == target.entry_id
      assert tables(schema) == before
      assert Fx.last_seq(schema) == seq
    end

    test "A2 two concurrent reversals: one posts, the loser sends no counter statement", %{
      schema: schema
    } do
      key = ["a", "l"]
      target = Fx.post!(receipt(schema, key, 4))
      seq = Fx.last_seq(schema)

      worker = fn ->
        Fx.record(fn -> Fx.post_tx(Fx.reversal_capability(schema, target.entry_id)) end)
      end

      %{first: r1, second: r2} =
        H.forced_overlap(schema, {:ledger_balance, Fx.ledger_id(), key}, worker, worker)

      results = [r1, r2]
      assert [{{:ok, %{duplicate: false}}, _}] = Enum.filter(results, &match?({{:ok, _}, _}, &1))

      assert [{loser, statements}] = Enum.filter(results, &match?({{:error, _}, _}, &1))
      assert %{entry_id: _} = refused(loser, :posting_already_reversed)

      assert Enum.any?(statements, fn {sql, _} ->
               sql =~ "ledger_balance" and sql =~ "FOR UPDATE"
             end)

      refute Enum.any?(statements, fn {sql, _} -> sql =~ "ledger_counter" end)
      assert Fx.last_seq(schema) == seq + 1
      assert Fx.count(schema, "ledger_entry") == 2
    end

    test "A4 a partly issued receipt: insufficient_balance with leg_nos and count only", %{
      schema: schema
    } do
      key = ["a", "l"]
      target = Fx.post!(receipt(schema, key, 6))
      Fx.post!(Fx.capability(schema, "issue", [Fx.leg(key, -4)]))
      seq = Fx.last_seq(schema)

      details =
        refused(
          Fx.post_tx(Fx.reversal_capability(schema, target.entry_id)),
          :insufficient_balance
        )

      assert details == %{leg_nos: [1], count: 1}
      assert Fx.last_seq(schema) == seq
    end

    test "A4b reversing an issue above a pinned max_on_hand is balance_bound_exceeded", %{
      schema: schema
    } do
      key = ["a", "l", "cap"]
      reg = Fx.registration(key_bounds: [%{when_slot_nonempty: "k_third", max_on_hand: "10"}])
      Fx.post!(receipt(schema, key, 10, registration: reg))

      issue =
        Fx.post!(Fx.capability(schema, "issue", [Fx.leg(key, -4)], registration: reg))

      Fx.post!(receipt(schema, key, 4, registration: reg))
      seq = Fx.last_seq(schema)

      cap = Fx.reversal_capability(schema, issue.entry_id, registration: reg)
      assert %{legs: [%{leg_no: 1}]} = refused(Fx.post_tx(cap), :balance_bound_exceeded)
      assert Fx.last_seq(schema) == seq
    end

    test "A5 a unique violation on the reversal index maps to posting_already_reversed" do
      id = Ecto.UUID.generate()
      row = %{reverses_entry_id: Ecto.UUID.dump!(id)}

      for constraint <- [
            "ledger_entry_reverses_unique_index",
            "ledger_entry_reverses_unique_index_p1",
            "generated_name"
          ] do
        error = %Postgrex.Error{
          postgres: %{
            code: :unique_violation,
            constraint: constraint,
            message: "duplicate key value violates unique constraint secret-name",
            detail: "Key (ledger_id, reverses_entry_id)=(test_ledger, #{id}) already exists."
          }
        }

        result = Ledger.reversal_unique_violation_refusal(error, row)

        assert {:error,
                {:ledger_refused, :posting_already_reversed, "posting_already_reversed",
                 %{entry_id: ^id}}} = result

        refute inspect(result) =~ "unique"
        refute inspect(result) =~ "secret-name"
      end

      other = %Postgrex.Error{
        postgres: %{
          code: :unique_violation,
          constraint: "ledger_entry_subject_op_key",
          detail: "x"
        }
      }

      assert Ledger.reversal_unique_violation_refusal(other, row) == :unknown
      assert Ledger.reversal_unique_violation_refusal(:nope, row) == :unknown
    end

    test "A6 a reversal is not tied to the original subject; the result holds ids only", %{
      schema: schema
    } do
      target = Fx.post!(receipt(schema, ["a", "l"], 4, subject_id: Ecto.UUID.generate()))

      assert {:ok, rev} =
               Fx.post_tx(
                 Fx.reversal_capability(schema, target.entry_id, subject_id: Ecto.UUID.generate())
               )

      assert Enum.sort(Map.keys(rev)) ==
               [:chain_hash, :duplicate, :entry_id, :ledger_id, :posting_seq]
    end
  end

  describe "reversal of a two-posting document (criterion 11)" do
    test "P1 a paired entry on its own is refused, both counters unchanged", %{schema: schema} do
      {pa, pb} = post_pair!(schema)
      before = tables(schema)

      for p <- [pa, pb] do
        cap = Fx.reversal_capability(schema, p.entry_id, ledger_id: p.ledger_id)
        assert %{entry_id: id} = refused(Fx.post_tx(cap), :posting_is_paired)
        assert id == p.entry_id
      end

      assert tables(schema) == before
      assert Fx.last_seq(schema, "ledger_a") == 1
      assert Fx.last_seq(schema, "ledger_b") == 1
    end

    test "P2 two reversals commit both, each with its own seq, chain step and counter", %{
      schema: schema
    } do
      {pa, pb} = post_pair!(schema)

      ra = Fx.reversal_capability(schema, pa.entry_id, ledger_id: "ledger_a")

      rb =
        Fx.reversal_capability(schema, pb.entry_id,
          ledger_id: "ledger_b",
          subject_id: ra.subject_id,
          command: %{client_op_id: ra.command.client_op_id}
        )

      assert {:ok, [xa, xb]} = plan_tx([ra, rb])

      assert {xa.ledger_id, xa.posting_seq, xb.ledger_id, xb.posting_seq} ==
               {"ledger_a", 2, "ledger_b", 2}

      assert xa.chain_hash != pa.chain_hash and xb.chain_hash != pb.chain_hash
      assert Fx.last_seq(schema, "ledger_a") == 2 and Fx.last_seq(schema, "ledger_b") == 2
      assert Decimal.eq?(Fx.total_on_hand(schema, "ledger_a"), 0)
      assert Decimal.eq?(Fx.total_on_hand(schema, "ledger_b"), 0)
      assert Fx.entry_row(schema, xa.entry_id).reverses_entry_id == pa.entry_id
      assert Fx.entry_row(schema, xb.entry_id).reverses_entry_id == pb.entry_id
    end

    defp reversal_pair(schema, pa, pb) do
      ra = Fx.reversal_capability(schema, pa.entry_id, ledger_id: "ledger_a")

      rb =
        Fx.reversal_capability(schema, pb.entry_id,
          ledger_id: "ledger_b",
          subject_id: ra.subject_id,
          command: %{client_op_id: ra.command.client_op_id}
        )

      [ra, rb]
    end

    test "P3 a refused second reversal leaves neither written and neither counter moved", %{
      schema: schema
    } do
      {pa, pb} = post_pair!(schema)
      # take the stock of ledger_b's receipt away, so its reversal is insufficient_balance
      Fx.post!(Fx.capability(schema, "issue", [Fx.leg(["b1", "l"], -5)], ledger_id: "ledger_b"))
      before = tables(schema)

      assert {:error, {:ledger_refused, :insufficient_balance, _, details}} =
               plan_tx(reversal_pair(schema, pa, pb))

      assert details == %{leg_nos: [1], count: 1}
      assert tables(schema) == before
      assert Fx.last_seq(schema, "ledger_a") == 1
      assert Fx.last_seq(schema, "ledger_b") == 2
    end

    test "P3b a pair whose target is already reversed writes nothing", %{schema: schema} do
      {pa, pb} = post_pair!(schema)
      assert {:ok, _} = plan_tx(reversal_pair(schema, pa, pb))
      before = tables(schema)

      assert {:error, {:ledger_refused, :posting_already_reversed, _, %{entry_id: id}}} =
               plan_tx(reversal_pair(schema, pa, pb))

      assert id == pa.entry_id
      assert tables(schema) == before
    end

    test "P4 two unpaired targets of one document id are ledger_document_mismatch", %{
      schema: schema
    } do
      a = Fx.post!(receipt(schema, ["a1", "l"], 5, ledger_id: "ledger_a", posting: @doc_posting))
      b = Fx.post!(receipt(schema, ["b1", "l"], 5, ledger_id: "ledger_b", posting: @doc_posting))
      before = tables(schema)

      assert {:error, {:ledger_contract, :ledger_document_mismatch}} =
               plan_tx(reversal_pair(schema, a, b))

      assert tables(schema) == before
      assert Fx.last_seq(schema, "ledger_a") == 1 and Fx.last_seq(schema, "ledger_b") == 1
    end

    test "P5 an entry with no sibling is reversed alone", %{schema: schema} do
      lone = Fx.post!(receipt(schema, ["a", "l"], 5, posting: @doc_posting))
      assert {:ok, _} = Fx.post_tx(Fx.reversal_capability(schema, lone.entry_id))
    end
  end

  describe "tenancy and source" do
    test "S1 the same ledger id and keys in two tenants: the other tenant's id is not found", %{
      schema: schema
    } do
      other = Fx.tenant!()
      mine = Fx.post!(receipt(schema, ["a", "l"], 4))
      theirs = Fx.post!(receipt(other, ["a", "l"], 4))

      assert Fx.post_tx(Fx.reversal_capability(schema, theirs.entry_id)) == @not_found
      assert Fx.post_tx(Fx.reversal_capability(other, mine.entry_id)) == @not_found
      assert {:ok, _} = Fx.post_tx(Fx.reversal_capability(schema, mine.entry_id))
      assert Fx.count(other, "ledger_entry") == 1
    end

    test "S2 the ledger sources run no Repo.query with runtime text and no interpolated SQL" do
      source = File.read!("lib/letflow/ledger.ex")
      assert length(Regex.scan(~r/Repo\.query!?\(/, source)) == 2
      refute source =~ ~r/Repo\.query!?\("[^"]*#\{/
    end
  end
end
