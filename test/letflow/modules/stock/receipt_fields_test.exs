Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.ReceiptFieldsTest do
  @moduledoc """
  REQ-714 / GH #3747 criteria 1, 2 and 5: the receipt-only fields (`supplier_document_ref`, `received_on`,
  `unit_price`, `line_value`), their shape reasons, the `received_on` check at issue and that
  `received_on` never fills `event_time`. Committed tenant, Sandbox `:auto`, `async: false`.
  Tests: RF-1..10, PR-1..7.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Stock
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockPostingFixture, as: P

  setup do
    on_exit(fn -> Application.delete_env(:letflow, :stock_documents_clock) end)
    P.setup!()
  end

  defp names(type) do
    ["priv", "modules", "stock", "entity_definitions", type <> ".json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("fields")
  end

  defp post(ctx, body), do: D.request(:post, "/documents", ctx.tok_a, body)

  defp reason(conn) do
    Jason.decode!(conn.resp_body)
  end

  defp line(ctx, extra \\ %{}) do
    Map.merge(
      %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => ctx.ma.uom, "quantity" => "1"},
      extra
    )
  end

  defp with_line(ctx, extra), do: D.body(ctx.ma, nil, %{"lines" => [line(ctx), line(ctx, extra)]})

  test "RF-1 version and the field sets of both types" do
    m = Stock.manifest()
    assert m.version == "0.7.0"
    assert Catalog.validate(m) == :ok

    header = names("stock_receipt")

    assert Enum.sort(Enum.map(header, & &1["name"])) ==
             ~w(counterparty_id document_id event_time location_id note org_unit_id received_on responsible_id supplier_document_ref)

    by = Map.new(header, &{&1["name"], &1})
    assert by["received_on"]["type"] == "date" and by["supplier_document_ref"]["type"] == "string"

    lines = names("stock_receipt_line")

    for f <- ~w(unit_price line_value) do
      d = Enum.find(lines, &(&1["name"] == f))
      assert d["type"] == "decimal" and d["decimal_strict"] == true
      assert d["decimal_scale"] == 9 and d["decimal_precision"] == 24
      refute d["required"]
    end
  end

  test "RF-2 the active definitions of a fresh tenant carry the new fields", ctx do
    %{rows: rows} =
      Letflow.Repo.query!(
        ~s|SELECT name FROM "#{ctx.schema}".entity_definitions WHERE name IN ('stock_receipt','stock_receipt_line') AND status = 'active'|
      )

    assert length(rows) >= 2
    doc = post(ctx, with_line(ctx, %{"unit_price" => "1.5"}))
    assert doc.status == 201, doc.resp_body
  end

  test "RF-3 supplier_document_ref bounds", ctx do
    ok = post(ctx, D.body(ctx.ma, nil, %{"supplier_document_ref" => String.duplicate("ш", 200)}))
    assert ok.status == 201, ok.resp_body

    for bad <- [String.duplicate("ш", 201), "", 5, nil] do
      conn = post(ctx, D.body(ctx.ma, nil, %{"supplier_document_ref" => bad}))
      assert conn.status == 422
      assert reason(conn)["reason"] == "field_invalid"
    end
  end

  test "RF-4 the docs name received_on" do
    text = File.read!("docs/assets/stock-workflow-documents.md")
    assert text =~ "`received_on`" and text =~ "0078 D7"
  end

  test "RF-5 received_on forms", ctx do
    assert post(ctx, D.body(ctx.ma, nil, %{"received_on" => "2026-11-04"})).status == 201
    before = D.counts(ctx.schema)

    for bad <- ["2026-02-30", "2026-11-4", "2026-11-04T10:00:00Z", 20_261_104, nil] do
      conn = post(ctx, D.body(ctx.ma, nil, %{"received_on" => bad}))
      assert conn.status == 422
      assert reason(conn)["reason"] == "field_invalid"
      assert reason(conn)["field"] == "received_on"
    end

    assert D.counts(ctx.schema) == before
  end

  defp issue_with(ctx, received_on, time) do
    Application.put_env(:letflow, :stock_documents_clock, fn ->
      elem(DateTime.from_iso8601(time), 1)
    end)

    doc = post(ctx, D.body(ctx.ma, time, %{"received_on" => received_on})) |> P.status!(201)
    {doc, D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)}
  end

  test "RF-6 received_on after the Almaty event day is refused and takes no number", ctx do
    time = "2026-11-04T20:30:00Z"
    {ok, conn} = issue_with(ctx, "2026-11-05", time)
    assert conn.status == 200, conn.resp_body
    assert Jason.decode!(conn.resp_body)["number"] =~ "000001"
    assert ok["id"]

    {late, conn} = issue_with(ctx, "2026-11-06", time)
    assert conn.status == 422
    assert reason(conn)["reason"] == "received_on_after_event"
    read = P.get!(ctx, late["id"])
    assert read["state"] == "draft" and read["number"] == nil

    {_next, conn} = issue_with(ctx, "2026-11-05", time)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["number"] =~ "000002"
  end

  test "RF-7 the UTC day before the Almaty day is accepted", ctx do
    {_doc, conn} = issue_with(ctx, "2026-11-04", "2026-11-04T20:30:00Z")
    assert conn.status == 200, conn.resp_body
  end

  test "RF-8 received_on 400 days back issues, event_time unchanged", ctx do
    time = DateTime.utc_now() |> DateTime.add(-48 * 3600) |> DateTime.truncate(:second)
    back = Date.utc_today() |> Date.add(-400) |> Date.to_iso8601()

    doc =
      post(ctx, D.body(ctx.ma, DateTime.to_iso8601(time), %{"received_on" => back}))
      |> P.status!(201)

    conn = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)
    assert conn.status == 200, conn.resp_body
    read = Jason.decode!(conn.resp_body)
    assert read["event_time"] == DateTime.to_iso8601(time) and read["received_on"] == back
  end

  test "RF-9 the posted entry carries the header event_time, not received_on", ctx do
    time = DateTime.utc_now() |> DateTime.add(-48 * 3600) |> DateTime.truncate(:second)
    back = Date.utc_today() |> Date.add(-400) |> Date.to_iso8601()
    doc = P.issue!(ctx, D.body(ctx.ma, DateTime.to_iso8601(time), %{"received_on" => back}))
    read = P.post_and_complete!(ctx, doc["id"])

    [entry] = P.movements(ctx, doc["id"])
    {:ok, at, _} = DateTime.from_iso8601(entry["event_time"])
    assert abs(DateTime.diff(at, time)) <= 1
    assert read["received_on"] == back and read["event_time"] == DateTime.to_iso8601(time)
    refute String.starts_with?(entry["event_time"], back)
  end

  test "RF-10 received_on is read only by shape, checks and documents" do
    hits =
      "lib/letflow/modules/stock/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "received_on"))
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert hits ==
             ~w(checks.ex documents.ex kinds.ex opening_checks.ex opening_shape.ex shape.ex stock.ex)

    checks = File.read!("lib/letflow/modules/stock/documents/checks.ex")
    assert length(Regex.scan(~r/@receipt_timezone\s/, checks)) == 2
  end

  describe "receipt prices" do
    test "PR-1 bad forms are price_invalid with field and line_no", ctx do
      before = D.counts(ctx.schema)

      for key <- ~w(unit_price line_value),
          bad <- ["1e3", " 1", "-0", "", 1.5, nil, "1.1234567891", "-1"] do
        conn = post(ctx, with_line(ctx, %{key => bad}))
        assert conn.status == 422
        json = reason(conn)
        assert json["reason"] == "price_invalid"
        assert json["field"] == key and json["line_no"] == 2
      end

      assert D.counts(ctx.schema) == before
    end

    test "PR-2 and PR-3 zero accepted; value need not equal quantity times price", ctx do
      doc =
        post(ctx, with_line(ctx, %{"unit_price" => "0", "line_value" => "0.000000000"}))
        |> P.status!(201)

      assert Enum.at(doc["lines"], 1)["unit_price"] == "0.000000000"

      body = with_line(ctx, %{"unit_price" => "2.5", "line_value" => "999"})
      saved = post(ctx, body) |> P.status!(201)
      issued = D.request(:post, "/documents/#{saved["id"]}/issue", ctx.tok_a) |> P.status!(200)
      l2 = Enum.at(issued["lines"], 1)
      assert l2["unit_price"] == "2.500000000" and l2["line_value"] == "999.000000000"

      content = Letflow.Modules.Stock.Documents.Posting.issued(ctx.schema, saved["id"]).content
      assert Enum.at(content["lines"], 1)["unit_price"] == "2.500000000"
    end

    test "PR-4 receipt-only keys are field_not_allowed elsewhere", ctx do
      c1 = post(ctx, D.body(ctx.ma, nil, %{"unit_price" => "1"}))
      assert c1.status == 422 and reason(c1)["reason"] == "field_not_allowed"
      c2 = post(ctx, with_line(ctx, %{"supplier_document_ref" => "x"}))
      assert c2.status == 422 and reason(c2)["reason"] == "field_not_allowed"
    end

    test "PR-5 the read shows the values; PR-7 a PUT replaces the whole document", ctx do
      body = with_line(ctx, %{"unit_price" => "3", "line_value" => "6"})
      body = Map.merge(body, %{"supplier_document_ref" => "INV-1", "received_on" => "2026-11-01"})
      doc = post(ctx, body) |> P.status!(201)
      read = P.get!(ctx, doc["id"])
      assert read["supplier_document_ref"] == "INV-1" and read["received_on"] == "2026-11-01"
      assert Enum.at(read["lines"], 1)["line_value"] == "6.000000000"

      kept = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, body) |> P.status!(200)
      assert kept["supplier_document_ref"] == "INV-1"

      bare =
        D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, D.body(ctx.ma)) |> P.status!(200)

      assert bare["supplier_document_ref"] == nil and bare["received_on"] == nil
      assert Enum.all?(bare["lines"], &(&1["unit_price"] == nil and &1["line_value"] == nil))
    end
  end
end
