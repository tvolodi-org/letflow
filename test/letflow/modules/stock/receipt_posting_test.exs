Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.ReceiptPostingTest do
  @moduledoc """
  REQ-714 / GH #3747 criterion 3: price and value live on the document only. A priced receipt is issued,
  posted and reversed through the real routes; the movements and balances answers keep their pinned key
  sets, and the ledger tables hold neither value nor a price-like column. Committed tenant, Sandbox
  `:auto`, `async: false`. Tests: PL-4..8.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  @entry ~w(cause correlation_id document_id document_type entry_id event_time legs posting_seq posting_time reason_code related_document_id reverses_entry_id)
  @leg ~w(document_line_id leg_no location lot org_unit quantity responsible sku unit_ref)
  @balance ~w(last_posting_seq location lot org_unit quantity responsible sku unit_ref)
  @price "123.456000000"
  @value "987.654000000"

  setup do
    P.setup!()
  end

  defp priced(ctx) do
    body =
      D.body(ctx.ma, nil, %{"supplier_document_ref" => "INV-9", "received_on" => "2026-01-01"})

    lines =
      Enum.map(body["lines"], &Map.merge(&1, %{"unit_price" => @price, "line_value" => @value}))

    %{body | "lines" => lines}
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp assert_key_sets(ctx, id) do
    [entry] = P.movements(ctx, id)
    assert keys(entry) == @entry
    for leg <- entry["legs"], do: assert(keys(leg) == @leg)

    rows = S.get("/balances", ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")
    assert rows != []
    for row <- rows, do: assert(keys(row) == @balance)

    text = Jason.encode!(%{entry: entry, rows: rows})
    refute text =~ @price or text =~ @value or text =~ "123.456" or text =~ "987.654"
    refute text =~ ~r/price|value|amount/i
  end

  test "PL-4 a priced receipt posts without price or value on the entry, legs or balances", ctx do
    doc = P.issue!(ctx, priced(ctx))
    P.post_and_complete!(ctx, doc["id"])
    assert_key_sets(ctx, doc["id"])

    for table <- ~w(ledger_entry ledger_leg ledger_balance) do
      %{rows: cols} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2",
          [ctx.schema, table]
        )

      assert cols != []
      refute Enum.any?(cols, fn [c] -> c =~ ~r/price|value|amount/i end)

      %{rows: [[hit]]} =
        Repo.query!(
          ~s|SELECT count(*) FROM "#{ctx.schema}"."#{table}" t WHERE t::text LIKE $1 OR t::text LIKE $2|,
          [
            "%123.456%",
            "%987.654%"
          ]
        )

      assert hit == 0
    end
  end

  test "PL-5 the issued content holds the new keys and the posting check stays ok", ctx do
    doc = P.issue!(ctx, priced(ctx))
    content = Letflow.Modules.Stock.Documents.Posting.issued(ctx.schema, doc["id"]).content
    assert content["header"]["supplier_document_ref"] == "INV-9"
    assert content["header"]["received_on"] == "2026-01-01"

    assert Enum.all?(
             content["lines"],
             &(&1["unit_price"] == @price and &1["line_value"] == @value)
           )

    assert P.post_and_complete!(ctx, doc["id"])["posting_check"] == "ok"
  end

  test "PL-6 a priced receipt reverses; balances return to zero", ctx do
    doc = P.issue!(ctx, priced(ctx))
    P.post_and_complete!(ctx, doc["id"])

    P.req(ctx, :post, doc["id"], "reverse", %{"reason_code" => "wrong_document"})
    |> P.status!(200)

    task = P.pending_task(ctx, doc["id"], "reverse")
    assert {:ok, _} = P.complete(ctx, task)

    rows = S.get("/balances", ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")
    assert Enum.all?(rows, &Decimal.equal?(Decimal.new(&1["quantity"]), 0))
    assert P.get!(ctx, doc["id"])["posting_check"] == "ok"
  end

  test "PL-7 no ledger slot, cause or source file outside the document code names a price" do
    ledger = Letflow.Modules.Stock.manifest().ledger["stock"]
    refute inspect(ledger) =~ ~r/price|value|amount/i

    allowed = ~w(documents.ex shape.ex checks.ex stock.ex opening_shape.ex)

    hits =
      "lib/letflow/modules/stock/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn p ->
        text = File.read!(p)
        text =~ "unit_price" or text =~ "line_value"
      end)
      |> Enum.map(&Path.basename/1)
      |> Enum.reject(&(&1 in allowed))

    assert hits == []
    refute File.read!("lib/letflow/modules/stock/ledger_policy/declare.ex") =~ "unit_price"
  end

  test "PL-8 an unpriced receipt answers the same key sets", ctx do
    doc = P.issue!(ctx)
    P.post_and_complete!(ctx, doc["id"])
    assert_key_sets(ctx, doc["id"])
  end
end
