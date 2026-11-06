Code.require_file("two_side_fixture.exs", __DIR__)

defmodule Letflow.StockVolumeFixture do
  @moduledoc """
  REQ-774: bodies of stock documents with many lines on top of `Letflow.StockTwoSideFixture`. A line of a
  big document uses its OWN catalog item, so a transfer of n lines writes 2n distinct balance keys. A
  `.exs` file loaded with `Code.require_file/2`; callers are `async: false` and run in Sandbox `:auto`.
  """

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T

  @doc "`n` active catalog items (record ids) with the unit of measure of the context masters."
  def items!(ctx, n) do
    tag = System.unique_integer([:positive])

    for i <- 1..n,
        do: Cat.item!(ctx.schema, "V#{tag}-#{i}", ctx.ma.uom).record_id
  end

  def lines(ctx, items, quantity \\ "1") do
    for item <- items,
        do: %{"catalog_item_id" => item, "catalog_uom_id" => ctx.ma.uom, "quantity" => quantity}
  end

  @doc "A receipt body of one line per item at the context masters."
  def receipt_body(ctx, items, quantity \\ "5"),
    do: D.body(ctx.ma, nil, %{"lines" => lines(ctx, items, quantity)})

  @doc "A transfer body of one line per item from the context masters to the second masters."
  def transfer_body(ctx, items, quantity \\ "1"),
    do: T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{"lines" => lines(ctx, items, quantity)})

  @doc "Receives `quantity` of every item at the context masters (one posting, one leg per item)."
  def receive_all!(ctx, items, quantity \\ "5") do
    doc = P.issue!(ctx, receipt_body(ctx, items, quantity))
    P.post_and_complete!(ctx, doc["id"])
  end

  @doc "Every balance row of the stock ledger as `{k1, k2, k3, k4, on_hand}`, sorted."
  def balances(ctx) do
    %{rows: rows} =
      Letflow.Repo.query!(
        ~s|SELECT k1, k2, k3, k4, trim_scale(on_hand)::text FROM "#{ctx.schema}".ledger_balance WHERE ledger_id = 'stock' ORDER BY 1, 2, 3, 4|
      )

    rows
  end

  @doc "The leg count of the entries of document `id`, as a list."
  def leg_counts(ctx, id) do
    %{rows: rows} =
      Letflow.Repo.query!(
        ~s|SELECT leg_count FROM "#{ctx.schema}".ledger_entry WHERE document_id = $1 ORDER BY posting_seq|,
        [id]
      )

    List.flatten(rows)
  end

  @doc """
  Rows per INSERT into `table` among recorded `statements` (`{sql, params}` of `LedgerFixture.record/1`).
  The column count is read from the column list of the statement, rows = params / columns.
  """
  def insert_rows(statements, schema, table) do
    head = ~s|INSERT INTO "#{schema}"."#{table}" (|

    for {sql, params} <- statements, String.starts_with?(sql, head) do
      [cols | _] = sql |> String.replace_prefix(head, "") |> String.split(") VALUES ", parts: 2)
      div(length(params), length(String.split(cols, ",")))
    end
  end
end
