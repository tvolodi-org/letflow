defmodule Letflow.Proof.MesP1.LedgerTest do
  @moduledoc """
  MES PROOF P1 (T-1829), REMOVABLE: L1..L11 of the design. Posts through the COPY of the stock policy and registration
  on a committed test tenant (Sandbox `:auto`), and checks the ledger invariants (append-only, no negative stock,
  reversal, reconcile, mixed era) and the lot hold rule of the proof guard. Nothing real is changed.
  `git rm -r test/support/mes_p1 test/letflow/proof/mes_p1` removes the proof.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.LedgerFixture
  alias Letflow.Proof.MesP1.LotStatus
  alias Letflow.Proof.MesP1.StockCopy
  alias Letflow.Repo

  setup do
    LedgerFixture.setup_auto_mode!()
    schema = LedgerFixture.tenant!()
    :ok = LotStatus.ensure_table!(schema)
    %{schema: schema, ou: Ecto.UUID.generate(), loc: Ecto.UUID.generate()}
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────

  defp id, do: Ecto.UUID.generate()

  defp side(ctx, location \\ nil),
    do: %{org_unit: ctx.ou, location: location || ctx.loc, responsible: nil}

  defp line(sku, lot, quantity, extra),
    do: Map.merge(%{line_id: id(), sku: sku, lot: lot, unit: "kg", quantity: quantity}, extra)

  defp command(cause, lines, extra \\ %{}),
    do: Map.merge(%{cause: cause, lines: lines, document_type: "proof", document_id: id()}, extra)

  defp receipt(ctx, sku, lot, qty, opts \\ []) do
    unit = Keyword.get(opts, :unit, "kg")
    cmd = command("receipt", [line(sku, lot, qty, %{to: side(ctx), unit: unit})])
    StockCopy.post(ctx.schema, cmd, era: Keyword.get(opts, :era, :copy))
  end

  defp consume(ctx, sku, lot, qty, batch),
    do:
      StockCopy.post(
        ctx.schema,
        command("consume", [line(sku, lot, qty, %{from: side(ctx)})], %{batch_id: batch})
      )

  defp produce(ctx, sku, lot, qty, batch),
    do:
      StockCopy.post(
        ctx.schema,
        command("produce", [line(sku, lot, qty, %{to: side(ctx)})], %{batch_id: batch})
      )

  defp on_hand(schema, sku, loc, ou, lot) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT on_hand FROM "#{schema}".ledger_balance WHERE ledger_id = 'stock' AND k1 = $1 AND k2 = $2 AND k3 = $3 AND k4 = '' AND k5 = $4|,
        [sku, loc, ou, lot]
      )

    case rows do
      [[n]] -> n |> Decimal.normalize() |> Decimal.to_string(:normal)
      [] -> nil
    end
  end

  defp entry_count(schema), do: LedgerFixture.count(schema, "ledger_entry")

  defp entry_column(schema, entry_id, column)
       when column in ~w(related_document_id registration_hash cause) do
    %{rows: [[value]]} =
      Repo.query!(
        ~s|SELECT #{column} FROM "#{schema}".ledger_entry WHERE id = $1|,
        [Ecto.UUID.dump!(entry_id)]
      )

    value
  end

  defp reversal(ctx, entry_id),
    do:
      StockCopy.post(ctx.schema, %{
        cause: "reversal",
        reverses_entry_id: entry_id,
        reason_code: "proof",
        reverses: entry_id,
        reason: "proof"
      })

  # ── the proof of the posting path ─────────────────────────────────────────────────────

  describe "consume and produce on the ledger" do
    test "L1 receipt, consume into a batch, produce from the batch", ctx do
      {material, finished, batch, lot_m, lot_f} = {id(), id(), id(), id(), id()}

      assert {:ok, %{entry_id: r}} = receipt(ctx, material, lot_m, "10", era: :real)
      assert {:ok, %{entry_id: c}} = consume(ctx, material, lot_m, "4", batch)
      assert {:ok, %{entry_id: p}} = produce(ctx, finished, lot_f, "3", batch)

      assert on_hand(ctx.schema, material, ctx.loc, ctx.ou, lot_m) == "6"
      assert on_hand(ctx.schema, finished, ctx.loc, ctx.ou, lot_f) == "3"
      assert entry_column(ctx.schema, c, "related_document_id") == batch
      assert entry_column(ctx.schema, p, "related_document_id") == batch
      assert entry_column(ctx.schema, r, "related_document_id") == nil
      assert entry_column(ctx.schema, c, "cause") == "consume"
    end

    test "L2 consume of more than is on hand is refused and nothing is written", ctx do
      {sku, lot} = {id(), id()}
      assert {:ok, _} = receipt(ctx, sku, lot, "2")
      before = entry_count(ctx.schema)

      assert {:error, {:ledger_refused, :insufficient_balance, _, _}} =
               consume(ctx, sku, lot, "3", id())

      assert entry_count(ctx.schema) == before
      assert on_hand(ctx.schema, sku, ctx.loc, ctx.ou, lot) == "2"
    end

    test "L3 the entry and leg tables are append-only", ctx do
      {sku, lot} = {id(), id()}
      assert {:ok, %{entry_id: entry}} = receipt(ctx, sku, lot, "2")
      dumped = Ecto.UUID.dump!(entry)

      for sql <- [
            ~s|UPDATE "#{ctx.schema}".ledger_entry SET reason_code = 'x' WHERE id = $1|,
            ~s|DELETE FROM "#{ctx.schema}".ledger_entry WHERE id = $1|,
            ~s|UPDATE "#{ctx.schema}".ledger_leg SET unit_ref = 'x' WHERE entry_id = $1|,
            ~s|DELETE FROM "#{ctx.schema}".ledger_leg WHERE entry_id = $1|
          ] do
        assert_raise Postgrex.Error, fn -> Repo.query!(sql, [dumped]) end
      end
    end

    test "L4 reversal restores a consume; a produce can be reversed only while the lot is there",
         ctx do
      {material, finished, batch, lot_m, lot_f} = {id(), id(), id(), id(), id()}
      assert {:ok, _} = receipt(ctx, material, lot_m, "10")
      assert {:ok, %{entry_id: c}} = consume(ctx, material, lot_m, "4", batch)
      assert {:ok, %{entry_id: p}} = produce(ctx, finished, lot_f, "3", batch)

      assert {:ok, _} = reversal(ctx, c)
      assert on_hand(ctx.schema, material, ctx.loc, ctx.ou, lot_m) == "10"

      # the produced lot is then used up: its reversal would go below zero
      assert {:ok, _} =
               StockCopy.post(
                 ctx.schema,
                 command("issue", [line(finished, lot_f, "3", %{from: side(ctx)})])
               )

      before = entry_count(ctx.schema)
      assert {:error, {:ledger_refused, :insufficient_balance, _, _}} = reversal(ctx, p)
      assert entry_count(ctx.schema) == before
    end

    test "L4b a produce is reversed when the lot is still there", ctx do
      {finished, lot_f} = {id(), id()}
      assert {:ok, %{entry_id: p}} = produce(ctx, finished, lot_f, "3", id())
      assert {:ok, _} = reversal(ctx, p)
      assert on_hand(ctx.schema, finished, ctx.loc, ctx.ou, lot_f) == "0"
    end

    test "L5 L6 reconcile is clean, also with entries of both registrations in one ledger", ctx do
      {material, finished, batch, lot_m, lot_f} = {id(), id(), id(), id(), id()}
      assert {:ok, %{entry_id: old}} = receipt(ctx, material, lot_m, "10", era: :real)
      assert {:ok, %{entry_id: new}} = consume(ctx, material, lot_m, "4", batch)
      assert {:ok, %{entry_id: p}} = produce(ctx, finished, lot_f, "3", batch)
      assert {:ok, _} = reversal(ctx, p)

      assert {:ok, %{mismatches: []}} =
               LedgerFixture.reconcile_all(StockCopy.authorized(ctx.schema))

      old_hash = entry_column(ctx.schema, old, "registration_hash")
      new_hash = entry_column(ctx.schema, new, "registration_hash")
      assert old_hash != new_hash
    end

    test "L11 kg and litres on different items post; two units on one key are refused", ctx do
      {tank, bag, lot} = {id(), id(), id()}
      assert {:ok, _} = receipt(ctx, tank, lot, "100", unit: "l")
      assert {:ok, _} = receipt(ctx, bag, lot, "20", unit: "kg")

      result = receipt(ctx, tank, lot, "5", unit: "kg")
      assert {:error, {:ledger_refused, :unit_mismatch, _, _}} = result
    end
  end

  # ── the hold rule ─────────────────────────────────────────────────────────────────────

  @held ~w(issue hand_over consume kind_change_out customer_transfer)
  @allowed ~w(receipt produce write_off count_difference plant_transfer return reversal)

  defp try_cause(ctx, "issue", sku, lot, _target),
    do: StockCopy.post(ctx.schema, command("issue", [line(sku, lot, "1", %{from: side(ctx)})]))

  defp try_cause(ctx, "hand_over", sku, lot, _target) do
    to = side(ctx, id())

    StockCopy.post(
      ctx.schema,
      command("hand_over", [line(sku, lot, "1", %{from: side(ctx), to: to})])
    )
  end

  defp try_cause(ctx, "consume", sku, lot, _target), do: consume(ctx, sku, lot, "1", id())

  defp try_cause(ctx, "kind_change_out", sku, lot, _target),
    do:
      StockCopy.post(
        ctx.schema,
        command("kind_change_out", [line(sku, lot, "1", %{from: side(ctx)})])
      )

  defp try_cause(ctx, "customer_transfer", sku, lot, _target) do
    customer = id()
    :ok = LotStatus.mark_customer_location!(ctx.schema, customer)
    cmd = command("transfer", [line(sku, lot, "1", %{from: side(ctx), to: side(ctx, customer)})])
    StockCopy.post(ctx.schema, cmd)
  end

  defp try_cause(ctx, "receipt", sku, lot, _target), do: receipt(ctx, sku, lot, "1")
  defp try_cause(ctx, "produce", sku, lot, _target), do: produce(ctx, sku, lot, "1", id())

  defp try_cause(ctx, "write_off", sku, lot, _target),
    do:
      StockCopy.post(
        ctx.schema,
        command("write_off", [line(sku, lot, "1", %{from: side(ctx)})], %{reason_code: "lost"})
      )

  defp try_cause(ctx, "count_difference", sku, lot, _target),
    do:
      StockCopy.post(
        ctx.schema,
        command("count_difference", [line(sku, lot, "1", %{from: side(ctx)})], %{
          reason_code: "count"
        })
      )

  defp try_cause(ctx, "plant_transfer", sku, lot, _target) do
    cmd = command("transfer", [line(sku, lot, "1", %{from: side(ctx), to: side(ctx, id())})])
    StockCopy.post(ctx.schema, cmd)
  end

  defp try_cause(ctx, "return", sku, lot, _target) do
    cmd = command("return", [line(sku, lot, "1", %{from: side(ctx), to: side(ctx, id())})])
    StockCopy.post(ctx.schema, cmd)
  end

  defp try_cause(ctx, "reversal", _sku, _lot, target), do: reversal(ctx, target)

  describe "L7 the hold matrix: a lot status against every cause" do
    for status <- [nil, "released", "quarantine", "rejected"] do
      @tag timeout: 120_000
      test "L7 lot status #{inspect(status)}", ctx do
        status = unquote(status)
        {sku, lot} = {id(), id()}
        assert {:ok, _} = receipt(ctx, sku, lot, "100")
        assert {:ok, %{entry_id: target}} = receipt(ctx, sku, lot, "1")
        if status, do: :ok = LotStatus.set!(ctx.schema, lot, status)

        blocked? = status in ["quarantine", "rejected"]

        for cause <- @held do
          before = entry_count(ctx.schema)
          result = try_cause(ctx, cause, sku, lot, target)

          if blocked? do
            assert result == {:error, {:held, "lot-" <> status}}, "#{cause}: #{inspect(result)}"
            assert entry_count(ctx.schema) == before, "#{cause} wrote an entry"
          else
            assert {:ok, _} = result, "#{cause}: #{inspect(result)}"
          end
        end

        for cause <- @allowed do
          assert {:ok, _} = try_cause(ctx, cause, sku, lot, target), "#{cause} was refused"
        end
      end
    end

    test "L8 a quarantined lot is released, then it can be issued; rejected is terminal", ctx do
      {sku, lot, bad} = {id(), id(), id()}
      assert {:ok, _} = receipt(ctx, sku, lot, "10")
      :ok = LotStatus.set!(ctx.schema, lot, "quarantine")
      assert {:error, {:held, "lot-quarantine"}} = try_cause(ctx, "issue", sku, lot, nil)

      :ok = LotStatus.set!(ctx.schema, lot, "released")
      assert {:ok, _} = try_cause(ctx, "issue", sku, lot, nil)

      :ok = LotStatus.set!(ctx.schema, bad, "quarantine")
      :ok = LotStatus.set!(ctx.schema, bad, "rejected")
      assert {:error, :transition_not_allowed} = LotStatus.set!(ctx.schema, bad, "released")
      assert LotStatus.get(ctx.schema, bad) == "rejected"
    end
  end

  describe "tenant isolation and locking" do
    test "L9 the status of tenant A does not hold the same lot id in tenant B; a missing table fails closed",
         ctx do
      {sku, lot} = {id(), id()}
      assert {:ok, _} = receipt(ctx, sku, lot, "10")
      :ok = LotStatus.set!(ctx.schema, lot, "quarantine")
      assert {:error, {:held, "lot-quarantine"}} = try_cause(ctx, "issue", sku, lot, nil)

      schema_b = LedgerFixture.tenant!()
      b = %{ctx | schema: schema_b}
      assert {:ok, _} = receipt(b, sku, lot, "10")

      # tenant B has no proof table yet: the guard cannot read, so the posting raises (fail closed)
      assert_raise Postgrex.Error, fn -> try_cause(b, "issue", sku, lot, nil) end
      assert on_hand(schema_b, sku, ctx.loc, ctx.ou, lot) == "10"

      :ok = LotStatus.ensure_table!(schema_b)
      assert {:ok, _} = try_cause(b, "issue", sku, lot, nil)
      assert {:error, {:held, "lot-quarantine"}} = try_cause(ctx, "issue", sku, lot, nil)
      assert LotStatus.get(schema_b, lot) == nil
    end

    test "L10 a status change holds the posting until it commits", ctx do
      {sku, lot} = {id(), id()}
      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Ledger.hold_exclusive!(ctx.schema, "stock")
            send(parent, :locked)

            receive do
              :go -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)

      assert_receive :locked, 10_000
      poster = Task.async(fn -> receipt(ctx, sku, lot, "1") end)
      assert Task.yield(poster, 500) == nil

      send(holder.pid, :go)
      assert {:ok, {:ok, :ok}} = Task.yield(holder, 10_000)
      assert {:ok, {:ok, _}} = Task.yield(poster, 10_000)
    end
  end
end
