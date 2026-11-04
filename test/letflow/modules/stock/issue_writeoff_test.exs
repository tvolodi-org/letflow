Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.IssueWriteoffTest do
  @moduledoc """
  REQ-715 / GH #3746: the issue and write-off documents through the real routes. Registration of the
  new types, numbering, per-kind master and lot checks, posting with negative legs, the
  `insufficient_stock` refusal at the post task, reversal and cancel, and tenant isolation. Committed
  tenants, Sandbox `:auto`, `async: false`. Tests: R1..R4, D1..D3, P1..P3, V1..V2, T1..T2, G1.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  setup do
    ctx = P.setup!([:a, :b])
    Map.merge(ctx, P.tenant_b!(ctx))
  end

  defp line(m, qty),
    do: %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => qty}

  defp receipt_body(ctx, qty),
    do: D.body(ctx.ma, nil, %{"lines" => [line(ctx.ma, qty)]})

  # An issue or write-off body: the receipt body without the counterparty, other kind, one line.
  defp body(ctx, kind, qty, extra \\ %{}) do
    ctx.ma
    |> D.body(nil, %{"kind" => kind, "lines" => [line(ctx.ma, qty)]})
    |> Map.delete("counterparty_id")
    |> Map.merge(extra)
  end

  defp writeoff(ctx, qty, extra \\ %{}),
    do: body(ctx, "write_off", qty, Map.merge(%{"reason_code" => "damaged"}, extra))

  defp receive!(ctx, qty) do
    doc = P.issue!(ctx, receipt_body(ctx, qty))
    P.post_and_complete!(ctx, doc["id"])
  end

  defp balance(ctx) do
    rows = S.get("/balances", ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")

    rows
    |> Enum.filter(&(&1["sku"] == ctx.ma.item))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
  end

  defp reason(conn, status), do: conn |> P.status!(status) |> Map.fetch!("reason")

  defp entry_rows(ctx, id) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT e.cause, e.reason_code, l.quantity::text FROM "#{ctx.schema}".ledger_entry e JOIN "#{ctx.schema}".ledger_leg l ON l.entry_id = e.id WHERE e.document_id = $1|,
        [id]
      )

    rows
  end

  # -- registration (criterion 1) -----------------------------------------------------------------

  test "R2 after install the ISS and WOF document types exist", ctx do
    for {key, prefix} <- [{"stock_issue", "ISS"}, {"stock_writeoff", "WOF"}] do
      type = Repo.get!(Letflow.Documents.DocumentType, key, prefix: ctx.schema)
      assert type.number_prefix == prefix
      assert type.numbering_scope == :year
      assert type.number_pad == 6
      assert type.legal_entity_required == false
      assert type.owner_module == "stock"
    end
  end

  test "R3 the field sets of the four new definitions", ctx do
    fields = fn name ->
      %{rows: rows} =
        Repo.query!(
          ~s|SELECT definition_json FROM "#{ctx.schema}".entity_definitions WHERE name = $1 AND status = 'active'|,
          [name]
        )

      [[json]] = rows
      json |> Map.fetch!("fields") |> Map.new(&{&1["name"], {&1["type"], &1["required"] == true}})
    end

    common = %{
      "document_id" => {"string", true},
      "event_time" => {"datetime", true},
      "org_unit_id" => {"string", true},
      "location_id" => {"string", true},
      "responsible_id" => {"string", true},
      "note" => {"string", false},
      "reason_text" => {"string", false}
    }

    assert fields.("stock_issue") == common
    assert fields.("stock_writeoff") == Map.put(common, "reason_code", {"enum", true})

    line_fields = %{
      "header_id" => {"string", true},
      "org_unit_id" => {"string", true},
      "line_no" => {"integer", true},
      "catalog_item_id" => {"string", true},
      "catalog_uom_id" => {"string", true},
      "catalog_lot_id" => {"string", false},
      "quantity" => {"decimal", true}
    }

    assert fields.("stock_issue_line") == line_fields
    assert fields.("stock_writeoff_line") == line_fields
  end

  test "R4 the pack has the two process definitions with one post task each" do
    pack = "priv/modules/stock/pack.json" |> File.read!() |> Jason.decode!()

    for name <- ["stock_issue", "stock_writeoff"] do
      definition = Enum.find(pack["definitions"], &(&1["process_key"] == name))
      nodes = definition["graph"]["nodes"]
      assert [task] = Enum.filter(nodes, &(&1["node_type"] == "HUMAN_TASK"))
      assert task["id"] == "post"

      assert [%{"module" => "stock", "handler" => "post_document"}] =
               task["attributes"]["module_writes"]
    end
  end

  test "G1 no route and no permission was added" do
    m = Letflow.Modules.Stock.manifest()
    assert length(m.route_policies) == 26

    assert m.permissions == [
             :StockPost,
             :StockReverse,
             :StockRead,
             :StockReconcile,
             :StockCountOrder,
             :StockCountRecord
           ]
  end

  # -- documents (criterion 2) --------------------------------------------------------------------

  test "D1 save, replace, read, list and discard an issue and a write-off", ctx do
    issue = P.save!(ctx, body(ctx, "issue", "3", %{"reason_text" => "to the kitchen"}))
    assert issue["kind"] == "issue" and issue["state"] == "draft"
    assert issue["reason_text"] == "to the kitchen" and issue["reason_code"] == nil
    assert issue["counterparty_id"] == nil

    off = P.save!(ctx, writeoff(ctx, "1"))
    assert off["kind"] == "write_off" and off["reason_code"] == "damaged"

    replaced =
      D.request(
        :put,
        "/documents/#{off["id"]}",
        ctx.tok_a,
        writeoff(ctx, "2", %{"reason_code" => "lost"})
      )
      |> P.status!(200)

    assert replaced["reason_code"] == "lost"
    assert [%{"quantity" => "2.000000000"}] = replaced["lines"]
    assert Enum.all?(replaced["lines"], &(&1["unit_price"] == nil and &1["line_value"] == nil))

    ids = fn q ->
      D.request(:get, "/documents" <> q, ctx.tok_a)
      |> P.status!(200)
      |> Map.fetch!("rows")
      |> Enum.map(&{&1["id"], &1["kind"]})
      |> Enum.sort()
    end

    assert ids.("?kind=issue") == [{issue["id"], "issue"}]
    assert ids.("?kind=write_off") == [{off["id"], "write_off"}]
    assert ids.("") == Enum.sort([{issue["id"], "issue"}, {off["id"], "write_off"}])
    assert ids.("?kind=receipt") == []

    D.request(:delete, "/documents/#{off["id"]}", ctx.tok_a) |> P.status!(204)
    D.request(:get, "/documents/#{off["id"]}", ctx.tok_a) |> P.status!(404)

    remaining =
      Repo.aggregate(
        from(r in Letflow.Entities.Record.Latest,
          where: r.entity_type in ["stock_writeoff", "stock_writeoff_line"] and not r.deleted
        ),
        :count,
        prefix: ctx.schema
      )

    assert remaining == 0
  end

  test "D2 router refusals of the new kinds", ctx do
    before = D.counts(ctx.schema)
    price = [Map.put(line(ctx.ma, "1"), "unit_price", "1")]
    value = [Map.put(line(ctx.ma, "1"), "line_value", "1")]
    long = String.duplicate("x", 501)

    cases = [
      {"reason_invalid", writeoff(ctx, "1", %{"reason_code" => "stolen"})},
      {"reason_invalid", writeoff(ctx, "1", %{"reason_code" => "other"})},
      {"reason_invalid", writeoff(ctx, "1", %{"reason_code" => "other", "reason_text" => "  "})},
      {"reason_invalid", writeoff(ctx, "1", %{"reason_text" => long})},
      {"field_required", Map.delete(writeoff(ctx, "1"), "reason_code")},
      {"field_invalid", body(ctx, "issue", "1", %{"reason_text" => long})},
      {"field_not_allowed", writeoff(ctx, "1", %{"lines" => price})},
      {"field_not_allowed", body(ctx, "issue", "1", %{"lines" => value})},
      {"field_not_allowed", body(ctx, "issue", "1", %{"counterparty_id" => ctx.ma.supplier})},
      {"field_not_allowed", body(ctx, "issue", "1", %{"received_on" => "2026-01-01"})},
      {"field_not_allowed", body(ctx, "issue", "1", %{"reason_code" => "lost"})}
    ]

    for {expected, body} <- cases do
      assert reason(D.request(:post, "/documents", ctx.tok_a, body), 422) == expected,
             inspect(body)
    end

    assert D.counts(ctx.schema) == before

    ok = P.save!(ctx, writeoff(ctx, "1", %{"reason_code" => "other", "reason_text" => "flood"}))
    assert ok["reason_text"] == "flood"
  end

  test "D3 the issue step numbers per kind and runs the checks", ctx do
    first = P.issue!(ctx, body(ctx, "issue", "1"))
    off = P.issue!(ctx, writeoff(ctx, "1"))
    year = Integer.to_string(DateTime.utc_now().year)
    assert first["number"] == "ISS-#{year}-000001"
    assert off["number"] == "WOF-#{year}-000001"
    assert first["state"] == "issued" and off["state"] == "issued"

    # a post task exists for each kind (its own process definition is active)
    assert P.pending_task(ctx, first["id"], "post")
    assert P.pending_task(ctx, off["id"], "post")

    refuse = fn kind, extra, expected ->
      base = if kind == "write_off", do: %{"reason_code" => "lost"}, else: %{}
      doc = P.save!(ctx, body(ctx, kind, "1", Map.merge(base, extra)))
      conn = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)
      assert reason(conn, 422) == expected
      read = P.get!(ctx, doc["id"])
      assert read["state"] == "draft" and read["number"] == nil
    end

    refuse.("issue", %{"location_id" => Ecto.UUID.generate()}, "not_linked")
    refuse.("issue", %{"responsible_id" => Ecto.UUID.generate()}, "employee_not_active")
    refuse.("issue", %{"event_time" => "2020-01-01T00:00:00Z"}, "event_time_too_old")

    future = DateTime.utc_now() |> DateTime.add(86_400 * 3) |> DateTime.to_iso8601()
    refuse.("issue", %{"event_time" => future}, "event_time_in_future")

    lot_item = ctx.ma.lot_item
    lot_line = %{"catalog_item_id" => lot_item, "catalog_uom_id" => ctx.ma.uom, "quantity" => "1"}
    refuse.("issue", %{"lines" => [lot_line]}, "lot_required")

    serial =
      Cat.item!(ctx.schema, "SER#{System.unique_integer([:positive])}", ctx.ma.uom, %{
        "tracking_policy" => "serial"
      })

    refuse.(
      "write_off",
      %{"lines" => [%{lot_line | "catalog_item_id" => serial.record_id}]},
      "tracking_policy_not_supported"
    )

    bad_uom = Cat.uom!(ctx.schema, "BU#{System.unique_integer([:positive])}")

    refuse.(
      "issue",
      %{
        "lines" => [
          %{lot_line | "catalog_item_id" => ctx.ma.item, "catalog_uom_id" => bad_uom.record_id}
        ]
      },
      "unit_not_valid"
    )
  end

  # -- posting (criterion 3) ----------------------------------------------------------------------

  test "P1 an issue posts one negative leg per line and the check is ok", ctx do
    receive!(ctx, "10")
    doc = P.issue!(ctx, body(ctx, "issue", "7"))
    posted = P.post_and_complete!(ctx, doc["id"])

    assert posted["state"] == "posted" and posted["posting_check"] == "ok"
    assert posted["entry_id"]
    assert [["issue", nil, qty]] = entry_rows(ctx, doc["id"])
    assert Decimal.equal?(Decimal.new(qty), -7)
    assert P.counts(ctx, doc["id"]) == %{entries: %{"issue" => 1}, marks: 1}
    assert Decimal.equal?(balance(ctx), 3)

    [entry] = P.movements(ctx, doc["id"])
    assert entry["cause"] == "issue" and entry["document_type"] == "stock_issue"
    [leg] = entry["legs"]
    assert leg["sku"] == ctx.ma.item and leg["location"] == ctx.ma.location
    assert leg["org_unit"] == ctx.ma.unit and leg["responsible"] == ctx.ma.employee
    assert leg["unit_ref"] == ctx.ma.uom
  end

  test "P2 a write-off posts with the header reason code", ctx do
    receive!(ctx, "10")
    doc = P.issue!(ctx, writeoff(ctx, "4", %{"reason_code" => "used_up"}))
    posted = P.post_and_complete!(ctx, doc["id"])

    assert posted["posting_check"] == "ok" and posted["state"] == "posted"
    assert [["write_off", "used_up", qty]] = entry_rows(ctx, doc["id"])
    assert Decimal.equal?(Decimal.new(qty), -4)
    assert Decimal.equal?(balance(ctx), 6)
  end

  test "P3 receive 5, issue 7: the post task is refused, nothing is written", ctx do
    receive!(ctx, "5")
    doc = P.issue!(ctx, body(ctx, "issue", "7"))
    task = P.pending_task(ctx, doc["id"], "post")

    assert {:error, refusal} = P.complete(ctx, task)
    assert inspect(refusal) =~ "insufficient"

    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert P.pending_task(ctx, doc["id"], "post").id == task.id
    assert P.get!(ctx, doc["id"])["state"] == "issued"
    assert Decimal.equal?(balance(ctx), 5)

    again = P.issue!(ctx, body(ctx, "issue", "5"))
    assert P.post_and_complete!(ctx, again["id"])["state"] == "posted"
    assert Decimal.equal?(balance(ctx), 0)
  end

  # -- reversal and cancel (criterion 4) ----------------------------------------------------------

  for kind <- ["issue", "write_off"] do
    test "V1 #{kind}: post, reverse, cancel; balance returns", ctx do
      receive!(ctx, "10")
      kind = unquote(kind)
      payload = if kind == "issue", do: body(ctx, kind, "6"), else: writeoff(ctx, "6")
      doc = P.issue!(ctx, payload)
      P.post_and_complete!(ctx, doc["id"])
      assert Decimal.equal?(balance(ctx), 4)

      P.req(ctx, :post, doc["id"], "reverse", %{"reason_code" => "wrong_document"})
      |> P.status!(200)

      assert {:ok, _} = P.complete(ctx, P.pending_task(ctx, doc["id"], "reverse"))

      reversed = P.get!(ctx, doc["id"])
      assert reversed["state"] == "reversed" and reversed["posting_check"] == "ok"
      assert Decimal.equal?(balance(ctx), 10)

      cancelled =
        P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "mistake"}) |> P.status!(200)

      assert cancelled["state"] == "cancelled"
    end
  end

  test "V2 an issued issue and write-off whose posting never started can be cancelled", ctx do
    Application.put_env(:letflow, :stock_post_start_fail?, true)

    for payload <- [body(ctx, "issue", "1"), writeoff(ctx, "1")] do
      doc = P.issue!(ctx, payload)
      assert doc["state"] == "issued"
      assert P.pending_task(ctx, doc["id"], "post") == nil

      cancelled = P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "x"}) |> P.status!(200)
      assert cancelled["state"] == "cancelled"
    end
  end

  # -- tenancy (criterion 5) ----------------------------------------------------------------------

  test "T1 a task worker is refused and an API token sees no module on the new kinds", ctx do
    worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-t1")
    D.request(:post, "/documents", worker, body(ctx, "issue", "1")) |> P.status!(403)
    D.request(:post, "/documents", worker, writeoff(ctx, "1")) |> P.status!(403)
    assert D.counts(ctx.schema) == {0, 0}
  end

  test "T2 tenant B cannot reach tenant A's issue or write-off", ctx do
    receive!(ctx, "10")
    issue = P.issue!(ctx, body(ctx, "issue", "2"))
    off = P.issue!(ctx, writeoff(ctx, "2"))
    P.post_and_complete!(ctx, issue["id"])
    before = {Decimal.to_string(balance(ctx)), P.counts(ctx, issue["id"])}

    for id <- [issue["id"], off["id"]],
        {method, suffix, payload} <- [
          {:get, "", nil},
          {:put, "", writeoff(ctx, "1")},
          {:delete, "", nil},
          {:post, "/issue", nil},
          {:post, "/post", nil},
          {:post, "/reverse", %{"reason_code" => "wrong_document"}},
          {:post, "/cancel", %{"reason" => "x"}}
        ] do
      conn = D.request(method, "/documents/#{id}" <> suffix, ctx.tok_b, payload)
      assert conn.status == 404, "#{method} #{id}#{suffix}: #{conn.status}"
    end

    assert D.request(:get, "/documents", ctx.tok_b) |> P.status!(200) |> Map.fetch!("rows") == []
    assert before == {Decimal.to_string(balance(ctx)), P.counts(ctx, issue["id"])}
    assert P.get!(ctx, off["id"])["state"] == "issued"
  end
end
