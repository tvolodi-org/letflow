Code.require_file("volume_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.DocumentVolumeTest do
  @moduledoc """
  REQ-774 criterion 8: the measured time of a stock document at volume. A receipt and a transfer of 100, 500
  and 1000 lines; per cell `@runs` runs, each on a fresh document: save, issue, completion of the post task
  (the posting), read of the document, and a list page of 50. Medians and maxima are printed as a markdown
  table. `@moduletag :stock_document_volume`: excluded by default (`test/test_helper.exs`), run on demand with
  `mix test --only stock_document_volume test/letflow/modules/stock/document_volume_test.exs`.
  Local test stack only, never QA. The test asserts nothing about the targets (criterion 9): a miss is
  recorded, it does not fail the file. `async: false`, one sequential test, no extra processes.
  """

  use Letflow.DataCase, async: false

  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T
  alias Letflow.StockVolumeFixture, as: V

  @moduletag :stock_document_volume
  @moduletag timeout: 1_800_000

  @runs 3
  @sizes [100, 500, 1000]

  defp ms(fun) do
    {micros, result} = :timer.tc(fun)
    {micros / 1000, result}
  end

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp run_once(ctx, kind, items, n) do
    lines = V.lines(ctx, Enum.take(items, n), "1")

    body =
      case kind do
        "receipt" -> D.body(ctx.ma, nil, %{"lines" => lines})
        "transfer" -> T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{"lines" => lines})
      end

    {save, doc} = ms(fn -> D.request(:post, "/documents", ctx.tok_a, body) |> P.status!(201) end)
    {issue, _} = ms(fn -> P.req(ctx, :post, doc["id"], "issue") |> P.status!(200) end)
    task = P.pending_task(ctx, doc["id"], "post")
    {post, result} = ms(fn -> P.complete(ctx, task) end)
    assert {:ok, _} = result, "#{kind} #{n} lines, completion after #{round(post)} ms"
    {fetch, got} = ms(fn -> P.get!(ctx, doc["id"]) end)
    assert got["state"] == "posted" and length(got["lines"]) == n
    {list, _} = ms(fn -> D.request(:get, "/documents?limit=50", ctx.tok_a) |> P.status!(200) end)

    IO.puts(
      "  #{kind} #{n}: save #{round(save)} issue #{round(issue)} post #{round(post)} fetch #{round(fetch)} list #{round(list)} ms"
    )

    [save, issue, post, fetch, list]
  end

  # one test per cell: a test process may hold its database connection for 120 s at most (the sandbox
  # ownership timeout), and the items of 1000 lines alone take about 35 s to create
  for kind <- ["receipt", "transfer"], n <- @sizes do
    test "M8-#{kind}-#{n} measured times of #{kind} with #{n} lines" do
      kind = unquote(kind)
      n = unquote(n)
      ctx = P.setup!()
      ctx = Map.put(ctx, :m2, T.b2!(ctx))
      Letflow.StockFixture.get("/balances", ctx.tok_a) |> P.status!(200)
      items = V.items!(ctx, n)
      ctx = Map.put(ctx, :tok_a, Letflow.StockFixture.token(ctx, :a, ["TENANT_ADMIN"]))

      # the stock for the transfer runs (untimed): 20 per item is more than all runs take
      if kind == "transfer", do: V.receive_all!(ctx, items, "20")

      runs = for _ <- 1..@runs, do: run_once(ctx, kind, items, n)

      cells =
        for i <- 0..4 do
          values = Enum.map(runs, &Enum.at(&1, i))
          "#{round(median(values))} / #{round(Enum.max(values))}"
        end

      IO.puts(
        "\nREQ-774 volume (ms, median / max of #{@runs}): | #{kind} | #{n} | " <>
          Enum.join(cells, " | ") <> " |  (save | issue | post | fetch | list page of 50)"
      )

      assert length(runs) == @runs
    end
  end
end
