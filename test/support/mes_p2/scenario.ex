defmodule Letflow.Proof.MesP2.Scenario do
  @moduledoc """
  MES PROOF P2 (T-1830), REMOVABLE: shared test helpers and the fixed scenario of section 5 of the design
  (items A, B, F in kg; recipe R v1; raw lots LA1, LA2, LB1; batches 1 and 2).
  """

  import ExUnit.Assertions

  alias Letflow.LedgerFixture
  alias Letflow.Proof.MesP1.LotStatus
  alias Letflow.Proof.MesP1.StockCopy
  alias Letflow.Proof.MesP2.BatchStore
  alias Letflow.Repo

  def id, do: Ecto.UUID.generate()

  @doc "A fresh committed test tenant with the proof tables, and one org unit and location."
  def new_ctx do
    LedgerFixture.setup_auto_mode!()
    another_ctx()
  end

  @doc "A second tenant in the same test (auto mode is already set up)."
  def another_ctx do
    schema = LedgerFixture.tenant!()
    :ok = BatchStore.ensure_tables!(schema)
    %{schema: schema, ou: id(), loc: id()}
  end

  def side(ctx, location \\ nil),
    do: %{org_unit: ctx.ou, location: location || ctx.loc, responsible: nil}

  def receipt(ctx, sku, lot, qty, opts \\ []) do
    cmd = %{
      cause: "receipt",
      lines: [
        %{
          line_id: id(),
          sku: sku,
          lot: lot,
          unit: Keyword.get(opts, :unit, "kg"),
          quantity: qty,
          to: side(ctx, Keyword.get(opts, :location))
        }
      ],
      document_type: "proof_receipt",
      document_id: Keyword.get(opts, :doc, id())
    }

    StockCopy.post(ctx.schema, cmd)
  end

  def issue(ctx, sku, lot, qty, opts \\ []) do
    cmd = %{
      cause: "issue",
      lines: [
        %{
          line_id: id(),
          sku: sku,
          lot: lot,
          unit: Keyword.get(opts, :unit, "kg"),
          quantity: qty,
          from: side(ctx)
        }
      ],
      document_type: "proof_issue",
      document_id: id()
    }

    StockCopy.post(ctx.schema, cmd)
  end

  def customer_transfer(ctx, sku, lot, qty, customer) do
    :ok = LotStatus.mark_customer_location!(ctx.schema, customer)

    cmd = %{
      cause: "transfer",
      lines: [
        %{
          line_id: id(),
          sku: sku,
          lot: lot,
          unit: "kg",
          quantity: qty,
          from: side(ctx),
          to: side(ctx, customer)
        }
      ],
      document_type: "proof_transfer",
      document_id: id()
    }

    StockCopy.post(ctx.schema, cmd)
  end

  def reversal(ctx, entry_id) do
    StockCopy.post(ctx.schema, %{
      cause: "reversal",
      reverses_entry_id: entry_id,
      reason_code: "proof",
      reverses: entry_id,
      reason: "proof"
    })
  end

  def c_line(ctx, sku, lot, qty, unit \\ "kg"),
    do: %{sku: sku, lot: lot, unit: unit, quantity: qty, from: side(ctx)}

  def p_line(ctx, sku, lot, qty, unit \\ "kg"),
    do: %{sku: sku, lot: lot, unit: unit, quantity: qty, to: side(ctx)}

  def on_hand(ctx, sku, lot, location \\ nil) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT on_hand FROM "#{ctx.schema}".ledger_balance WHERE ledger_id = 'stock' AND k1 = $1 AND k2 = $2 AND k3 = $3 AND k4 = '' AND k5 = $4|,
        [sku, location || ctx.loc, ctx.ou, lot]
      )

    case rows do
      [[n]] -> n |> Decimal.normalize() |> Decimal.to_string(:normal)
      [] -> nil
    end
  end

  def entry_count(ctx), do: LedgerFixture.count(ctx.schema, "ledger_entry")

  def entry_column(ctx, entry_id, column) when column in ~w(related_document_id cause) do
    %{rows: [[value]]} =
      Repo.query!(~s|SELECT #{column} FROM "#{ctx.schema}".ledger_entry WHERE id = $1|, [
        Ecto.UUID.dump!(entry_id)
      ])

    value
  end

  def dec(s), do: Decimal.new(s)

  def assert_dec(actual, expected),
    do: assert(Decimal.equal?(actual, dec(expected)), "#{inspect(actual)} != #{expected}")

  @doc """
  Section 5 of the design: recipe R v1 approved, receipts LA1=100 A, LA2=100 A, LB1=100 B, batch 1 (LA1 50 + LB1 30 -> LF1 80),
  batch 2 (LA2 20 + LB1 20 -> LF2 40). Both finished lots stay in `quarantine`. Returns a map of all ids.
  """
  def scenario(ctx) do
    [a, b, f] = [id(), id(), id()]
    [la1, la2, lb1, lf1, lf2] = [id(), id(), id(), id(), id()]
    [ra1, ra2, rb1] = [id(), id(), id()]

    v =
      BatchStore.create_recipe(ctx.schema, "R", 1, [
        %{role: "input", sku: a, unit: "kg", quantity: "60"},
        %{role: "input", sku: b, unit: "kg", quantity: "40"},
        %{role: "output", sku: f, unit: "kg", quantity: "100"}
      ])

    :ok = BatchStore.approve(ctx.schema, v)

    {:ok, _} = receipt(ctx, a, la1, "100", doc: ra1)
    {:ok, _} = receipt(ctx, a, la2, "100", doc: ra2)
    {:ok, _} = receipt(ctx, b, lb1, "100", doc: rb1)

    {:ok, b1} = BatchStore.create_batch(ctx.schema, "B-1", v)
    {:ok, b2} = BatchStore.create_batch(ctx.schema, "B-2", v)

    {:ok, %{entry_id: c1}} =
      BatchStore.consume(ctx.schema, b1, [c_line(ctx, a, la1, "50"), c_line(ctx, b, lb1, "30")])

    {:ok, _} = BatchStore.produce(ctx.schema, b1, p_line(ctx, f, lf1, "80"))

    {:ok, %{entry_id: c2}} =
      BatchStore.consume(ctx.schema, b2, [c_line(ctx, a, la2, "20"), c_line(ctx, b, lb1, "20")])

    {:ok, _} = BatchStore.produce(ctx.schema, b2, p_line(ctx, f, lf2, "40"))

    %{
      a: a,
      b: b,
      f: f,
      la1: la1,
      la2: la2,
      lb1: lb1,
      lf1: lf1,
      lf2: lf2,
      ra1: ra1,
      ra2: ra2,
      rb1: rb1,
      version: v,
      b1: b1,
      b2: b2,
      c1: c1,
      c2: c2
    }
  end
end
