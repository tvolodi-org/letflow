Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.WithdrawCancelTest do
  @moduledoc """
  T-1375 (GATE B walk P1/P2): an issued stock document whose post task is refused for insufficient
  stock can be cancelled (the pending post instance is withdrawn), and the typed refusal carries the
  standard problem keys. Everything through the real routes. Tests: W1..W9, S2.
  """

  use Letflow.DataCase, async: false

  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  setup do
    ctx = P.setup!([:a, :b])
    Map.merge(ctx, P.tenant_b!(ctx))
  end

  defp line(m, qty),
    do: %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => qty}

  defp body(ctx, kind, qty, extra \\ %{}) do
    ctx.ma
    |> D.body(nil, %{"kind" => kind, "lines" => [line(ctx.ma, qty)]})
    |> Map.delete("counterparty_id")
    |> Map.merge(extra)
  end

  defp receive!(ctx, qty) do
    doc = P.issue!(ctx, D.body(ctx.ma, nil, %{"lines" => [line(ctx.ma, qty)]}))
    P.post_and_complete!(ctx, doc["id"])
  end

  defp balance(ctx) do
    rows = S.get("/balances", ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")

    rows
    |> Enum.filter(&(&1["sku"] == ctx.ma.item))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
  end

  defp complete_route(task, token) do
    conn =
      Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/complete", "{}")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  # Receives 18, issues `qty` of `kind`, completes the post task over HTTP: refused.
  defp stuck!(ctx, kind, qty, extra \\ %{}) do
    receive!(ctx, "18")
    doc = P.issue!(ctx, body(ctx, kind, qty, extra))
    task = P.pending_task(ctx, doc["id"], "post") || flunk("no post task")
    {doc, task}
  end

  test "W1 completing the post task of issue 500 of 18 is refused with the problem shape", ctx do
    {_doc, task} = stuck!(ctx, "issue", "500")
    conn = complete_route(task, ctx.tok_a)
    resp = P.status!(conn, 409)

    assert resp["error"] == "insufficient_stock"
    assert resp["reason"] == "insufficient_stock"
    assert resp["status"] == 409
    assert is_binary(resp["type"]) and is_binary(resp["title"]) and is_binary(resp["detail"])
    assert is_integer(resp["line_index"])
    assert [leg] = resp["details"]["legs"]
    assert Decimal.equal?(Decimal.new(leg["available"]), 18)
    assert Decimal.equal?(Decimal.new(leg["requested"]), 500)
    assert {"content-type", ct} = List.keyfind(conn.resp_headers, "content-type", 0)
    assert ct =~ "application/problem+json"
  end

  for kind <- ["issue", "write_off"] do
    test "W2 #{kind}: after the refusal the document can be cancelled, balance unchanged", ctx do
      extra = if unquote(kind) == "write_off", do: %{"reason_code" => "damaged"}, else: %{}
      {doc, task} = stuck!(ctx, unquote(kind), "500", extra)
      complete_route(task, ctx.tok_a) |> P.status!(409)

      cancelled =
        P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "not enough stock"})
        |> P.status!(200)

      assert cancelled["state"] == "cancelled"
      assert P.pending_task(ctx, doc["id"], "post") == nil
      assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
      assert Decimal.equal?(balance(ctx), 18)

      # W5: the old task cannot be completed any more
      assert complete_route(task, ctx.tok_a).status in 400..499
      assert Decimal.equal?(balance(ctx), 18)
    end
  end

  test "W2b a stuck issue can be cancelled even before the refused completion", ctx do
    {doc, _task} = stuck!(ctx, "issue", "5")
    P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "changed my mind"}) |> P.status!(200)
    assert P.pending_task(ctx, doc["id"], "post") == nil
  end

  test "W4 a receipt with a pending post task still answers posting_pending", ctx do
    doc = P.issue!(ctx, D.body(ctx.ma, nil, %{"lines" => [line(ctx.ma, "3")]}))

    conn = P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "x"})
    assert P.status!(conn, 409)["reason"] == "posting_pending"
    assert P.pending_task(ctx, doc["id"], "post")
  end

  test "W6 a posted document is not cancellable", ctx do
    receive!(ctx, "10")
    doc = P.issue!(ctx, body(ctx, "issue", "2"))
    P.post_and_complete!(ctx, doc["id"])
    conn = P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "x"})
    assert P.status!(conn, 409)["reason"] == "document_posted"
  end

  test "W8 a bad cancel request leaves the post task pending", ctx do
    {doc, task} = stuck!(ctx, "issue", "500")

    for payload <- [%{}, %{"reason" => "   "}, %{"reason" => 5}, "text", nil] do
      conn = P.req(ctx, :post, doc["id"], "cancel", payload)
      assert conn.status in 400..499, "#{inspect(payload)}: #{conn.status}"
      assert P.pending_task(ctx, doc["id"], "post").id == task.id
      assert P.get!(ctx, doc["id"])["state"] == "issued"
    end

    P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "ok"}) |> P.status!(200)
  end

  test "W9 a too long reason leaves the post task pending", ctx do
    {doc, task} = stuck!(ctx, "issue", "500")
    long = String.duplicate("x", 501)
    conn = P.req(ctx, :post, doc["id"], "cancel", %{"reason" => long})
    assert P.status!(conn, 422)["reason"] == "reason_too_long"
    assert P.pending_task(ctx, doc["id"], "post").id == task.id
  end

  test "W7 tenant B cannot cancel tenant A's stuck document", ctx do
    {doc, task} = stuck!(ctx, "issue", "500")
    conn = D.request(:post, "/documents/#{doc["id"]}/cancel", ctx.tok_b, %{"reason" => "x"})
    assert conn.status == 404
    assert P.pending_task(ctx, doc["id"], "post").id == task.id
  end

  test "S2 entity_write_refused_detailed gives the problem keys for each status", ctx do
    _ = ctx

    for {code, wire, status} <- [
          {:record_version_conflict, "record_version_conflict", 409},
          {:validation_failed, "validation_failed", 422},
          {:entity_write_contention, "busy", 503},
          {:write_not_permitted, "no_way", 403}
        ] do
      conn =
        Plug.Test.conn(:post, "/x")
        |> Letflow.Api.Response.entity_write_refused_detailed(code, wire, 0, %{"a" => 1})

      body = Jason.decode!(conn.resp_body)

      assert conn.status == status
      assert body["reason"] == wire
      assert body["error"] == wire
      assert body["status"] == status
      assert body["details"] == %{"a" => 1}
      for key <- ~w(type title detail), do: assert(is_binary(body[key]))
    end
  end

  test "S1 the separation-of-duties body carries the problem keys and a reason" do
    body = Jason.decode!(Letflow.Api.Response.separation_of_duties_body())

    assert %{"reason" => "separation_of_duties", "status" => 403, "type" => _, "title" => _} =
             body

    assert body["detail"] == "separation of duties"
  end
end
