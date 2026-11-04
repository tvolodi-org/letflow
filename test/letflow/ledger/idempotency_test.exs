defmodule Letflow.Ledger.IdempotencyTest do
  @moduledoc """
  REQ-621 / GH #3469 part B, criterion 6: T-AC6-a..i. `client_op_id` idempotency with the payload
  hash, the duplicate answer, `idempotency_key_reuse`, the `sys:` refusal and the unique-violation
  backstop. REQ-692 / GH #3726 criterion 2: IDM-1..3 and the rewritten (2), the lookups per ledger
  id. Sandbox `:auto` with real commits, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.Ledger.Digest
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H

  @reuse {:ledger_refused, :idempotency_key_reuse, "idempotency_key_reuse", %{}}

  setup do
    Fx.setup_auto_mode!()
    :ok = H.attach_error_handler(__MODULE__)
    %{schema: Fx.tenant!()}
  end

  defp receipt(schema, key, qty, opts \\ []),
    do: Fx.capability(schema, "receipt", [Fx.leg(key, qty)], opts)

  test "T-AC6-a the same key and payload twice: one entry, the second is the duplicate", %{
    schema: schema
  } do
    cap = receipt(schema, ["a", "l"], 5)
    assert {:ok, %{duplicate: false} = first} = Fx.post_tx(cap)
    assert {:ok, %{duplicate: true} = second} = Fx.post_tx(cap)

    assert second.entry_id == first.entry_id
    assert second.posting_seq == first.posting_seq
    assert second.chain_hash == first.chain_hash
    assert Fx.count(schema, "ledger_entry") == 1
    assert Fx.last_seq(schema) == 1
    assert Decimal.eq?(Fx.balance(schema, ["a", "l"]).on_hand, 5)
  end

  test "T-AC6-b the same key with another payload is idempotency_key_reuse", %{schema: schema} do
    cap = receipt(schema, ["a", "l"], 5)
    assert {:ok, _} = Fx.post_tx(cap)

    changed = %{cap | command: Map.put(cap.command, :note, "x")}
    assert {:error, @reuse} = Fx.post_tx(changed)
    assert Fx.count(schema, "ledger_entry") == 1

    other_posting = %{cap | posting: %{cap.posting | legs: [Fx.leg(["b", "l"], 9)]}}

    assert Digest.payload_hash(cap.command, cap.subject_id) ==
             Digest.payload_hash(other_posting.command, other_posting.subject_id)
  end

  test "T-AC6-c a sys: client_op_id is refused before any write", %{schema: schema} do
    cap = receipt(schema, ["a", "l"], 5, command: %{client_op_id: "sys:x"})

    assert {:error,
            {:ledger_refused, :invalid_posting, "invalid_posting",
             %{reason: :client_op_id_invalid}}} = Fx.post_tx(cap)

    assert Fx.count(schema, "ledger_entry") == 0
    assert Fx.count(schema, "ledger_counter") == 0
  end

  test "T-AC6-d another subject with the same client_op_id posts a new entry", %{schema: schema} do
    first = receipt(schema, ["a", "l"], 5)
    {:ok, p1} = Fx.post_tx(first)

    second = receipt(schema, ["a", "l"], 5, command: %{client_op_id: first.command.client_op_id})
    assert {:ok, %{duplicate: false} = p2} = Fx.post_tx(second)
    assert p2.entry_id != p1.entry_id
    assert Fx.count(schema, "ledger_entry") == 2
  end

  test "T-AC6-e a client_op_id and an origin_key of two entries, or a reused origin", %{
    schema: schema
  } do
    subject = Ecto.UUID.generate()
    a = receipt(schema, ["a", "l"], 1, subject_id: subject, origin_key: "origin-A")
    b = receipt(schema, ["b", "l"], 1, subject_id: subject, origin_key: "origin-B")
    assert {:ok, _} = Fx.post_tx(a)
    assert {:ok, _} = Fx.post_tx(b)

    mixed = %{a | origin_key: "origin-B"}
    assert {:error, @reuse} = Fx.post_tx(mixed)

    reused_origin = receipt(schema, ["c", "l"], 1, subject_id: subject, origin_key: "origin-A")
    assert {:error, @reuse} = Fx.post_tx(reused_origin)
    assert Fx.count(schema, "ledger_entry") == 2
  end

  test "T-AC6-f tight stock: the retry is the duplicate, never insufficient_balance", %{
    schema: schema
  } do
    key = ["a", "l"]
    Fx.seed_on_hand!(schema, key, 6)
    cap = Fx.capability(schema, "issue", [Fx.leg(key, -6)])
    worker = fn -> Fx.post_tx(cap) end

    %{first: r1, second: r2} =
      H.forced_overlap(schema, {:ledger_balance, Fx.ledger_id(), key}, worker, worker)

    assert [{:ok, %{duplicate: false}}, {:ok, %{duplicate: true}}] =
             Enum.sort_by([r1, r2], fn {:ok, p} -> p.duplicate end)

    assert Decimal.eq?(Fx.balance(schema, key).on_hand, 0)
    assert Fx.count(schema, "ledger_entry") == 2
  end

  test "T-AC6-rev a concurrent identical reversal retry is the duplicate, never already_reversed",
       %{schema: schema} do
    key = ["a", "l"]
    target = Fx.post!(receipt(schema, key, 6))
    cap = Fx.reversal_capability(schema, target.entry_id)
    worker = fn -> Fx.post_tx(cap) end

    %{first: r1, second: r2} =
      H.forced_overlap(schema, {:ledger_balance, Fx.ledger_id(), key}, worker, worker)

    assert [{:ok, %{duplicate: false} = first}, {:ok, %{duplicate: true} = dup}] =
             Enum.sort_by([r1, r2], fn {:ok, p} -> p.duplicate end)

    assert dup.entry_id == first.entry_id and dup.posting_seq == first.posting_seq
    assert Fx.count(schema, "ledger_entry") == 2
    assert Fx.last_seq(schema) == 2
  end

  test "T-AC6-g a retry on another balance key set is the duplicate at the counter lock", %{
    schema: schema
  } do
    Fx.seed_on_hand!(schema, ["seed", "l"], 1)
    cap_a = receipt(schema, ["a", "l"], 5)
    cap_b = %{cap_a | posting: %{cap_a.posting | legs: [Fx.leg(["b", "l"], 5)]}}

    %{first: r1, second: r2} =
      H.forced_overlap(
        schema,
        {:ledger_counter, Fx.ledger_id()},
        fn -> Fx.record(fn -> Fx.post_tx(cap_a) end) end,
        fn -> Fx.record(fn -> Fx.post_tx(cap_b) end) end
      )

    results = [r1, r2]

    assert [{{:ok, %{duplicate: false}}, _}] =
             Enum.filter(results, &match?({{:ok, %{duplicate: false}}, _}, &1))

    assert [{{:ok, %{duplicate: true}}, statements}] =
             Enum.filter(results, &match?({{:ok, %{duplicate: true}}, _}, &1))

    refute Enum.any?(statements, fn {sql, _} -> sql =~ ~r/UPDATE .*ledger_counter/ end)
    assert Fx.last_seq(schema) == 2
    assert Fx.count(schema, "ledger_entry") == 2
  end

  test "T-AC6-h (race-only) two identical posts on a fresh ledger id: one entry", %{
    schema: schema
  } do
    cap = receipt(schema, ["a", "l"], 5, ledger_id: "fresh_h")

    results =
      [Task.async(fn -> Fx.post_tx(cap) end), Task.async(fn -> Fx.post_tx(cap) end)]
      |> Task.await_many(30_000)

    assert [{:ok, p1}, {:ok, p2}] = results
    assert p1.entry_id == p2.entry_id
    assert Enum.sort([p1.duplicate, p2.duplicate]) == [false, true]
    assert Fx.count(schema, "ledger_entry") == 1
  end

  describe "T-AC6-i unique-violation backstop" do
    defp violation(constraint),
      do: %Postgrex.Error{
        postgres: %{
          code: :unique_violation,
          constraint: constraint,
          message: "duplicate key value violates unique constraint \"#{constraint}\""
        }
      }

    test "(1) the mapper hides message and constraint" do
      for c <- ["ledger_entry_subject_op_key", "ledger_entry_origin_key_key"] do
        assert Ledger.unique_violation_refusal(violation(c)) == {:error, @reuse}
      end

      assert {:error, {:ledger_refused, :client_seq_conflict, "client_seq_conflict", %{}} = r} =
               Ledger.unique_violation_refusal(violation("ledger_entry_device_seq_unique_index"))

      refute inspect(r) =~ "ledger_entry"
      assert Ledger.unique_violation_refusal(violation("some_other_key")) == :unknown
      assert Ledger.unique_violation_refusal(%RuntimeError{message: "x"}) == :unknown
    end

    test "(2) the same op on two ledger ids: two entries, posting_seq 1 in each counter", %{
      schema: schema
    } do
      {cap_1, cap_2} = two_ledgers(schema)

      assert {:ok, %{duplicate: false, posting_seq: 1} = first} = Fx.post_tx(cap_1)
      assert {:ok, %{duplicate: false, posting_seq: 1} = second} = Fx.post_tx(cap_2)

      assert first.entry_id != second.entry_id
      assert Fx.count(schema, "ledger_entry") == 2
      assert Fx.last_seq(schema, "ledger_a") == 1
      assert Fx.last_seq(schema, "ledger_b") == 1
    end

    test "IDM-1 a replay of the B command returns the B entry, never the A entry", %{
      schema: schema
    } do
      {cap_1, cap_2} = two_ledgers(schema)
      assert {:ok, a} = Fx.post_tx(cap_1)
      assert {:ok, b} = Fx.post_tx(cap_2)

      assert {:ok, %{duplicate: true} = replay} = Fx.post_tx(cap_2)
      assert replay.entry_id == b.entry_id
      assert replay.ledger_id == "ledger_b"
      assert replay.entry_id != a.entry_id
      assert Fx.count(schema, "ledger_entry") == 2
    end

    test "IDM-2 the same origin_key on A and on B posts twice; on one ledger id it is a reuse", %{
      schema: schema
    } do
      a = receipt(schema, ["a", "l"], 1, ledger_id: "ledger_a", origin_key: "origin-shared")
      b = receipt(schema, ["a", "l"], 1, ledger_id: "ledger_b", origin_key: "origin-shared")
      assert {:ok, _} = Fx.post_tx(a)
      assert {:ok, %{duplicate: false}} = Fx.post_tx(b)
      assert Fx.count(schema, "ledger_entry") == 2

      again = receipt(schema, ["a", "l"], 1, ledger_id: "ledger_a", origin_key: "origin-shared")
      assert {:error, @reuse} = Fx.post_tx(again)
      assert Fx.count(schema, "ledger_entry") == 2
    end

    test "IDM-3 the same (subject, device, client_seq) on A and B posts twice; on one id it conflicts",
         %{schema: schema} do
      subject = Ecto.UUID.generate()
      cmd = %{device_id: "dev-1", client_seq: 3}

      mk = fn ledger_id ->
        receipt(schema, ["a", "l"], 1, ledger_id: ledger_id, subject_id: subject, command: cmd)
      end

      assert {:ok, _} = Fx.post_tx(mk.("ledger_a"))
      assert {:ok, %{duplicate: false}} = Fx.post_tx(mk.("ledger_b"))
      assert Fx.count(schema, "ledger_entry") == 2

      assert {:error, {:ledger_refused, :client_seq_conflict, "client_seq_conflict", %{}}} =
               Fx.post_tx(mk.("ledger_a"))

      assert Fx.count(schema, "ledger_entry") == 2
    end

    defp two_ledgers(schema) do
      cap_1 = receipt(schema, ["a", "l"], 1, ledger_id: "ledger_a", origin_key: "origin-i1")

      cap_2 =
        receipt(schema, ["a", "l"], 1,
          ledger_id: "ledger_b",
          origin_key: "origin-i2",
          subject_id: cap_1.subject_id,
          command: %{client_op_id: cap_1.command.client_op_id}
        )

      {cap_1, cap_2}
    end
  end
end
