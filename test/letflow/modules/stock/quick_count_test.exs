Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.QuickCountTest do
  @moduledoc """
  REQ-854 / GH #4564 (Qoimeks parity G5 part 2): the quick count through the real routes. Committed
  tenants, real OIDC tokens, Sandbox `:auto`, `async: false`. Test ids QC-1..QC-12 follow the acceptance
  criteria of the entry (criterion n is QC-n); QC-13.. are the extra rules (guard, shape, state).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Modules.Stock.FreezeGuard
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P

  @moduletag timeout: 240_000

  setup tags do
    ctx = P.setup!([:a, :b])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))

    ctx =
      Map.merge(ctx, %{
        tok_k: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "counter-1"),
        tok_u2: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "second-admin"),
        tok_kb: S.token(ctx, :b, ["TENANT_ADMIN"], sub: "counter-b"),
        tok_sk: S.token(ctx, :a, ["STOREKEEPER"], sub: "keeper-1")
      })

    # StockQuickCount is held by TENANT_ADMIN and PLATFORM_ADMIN only: a role_grants widening of an
    # existing role (STOREKEEPER) is refused by the permission matrix check until per-tenant grant
    # snapshots exist (decision 0081 D2). The counter is a second TENANT_ADMIN user; a TENANT_ADMIN
    # issues the first quick count of the tenant (it activates the module's process definition), on
    # masters of its own so the tests' keys stay clean (QCT number 1).
    first = D.masters!(ctx.schema)
    body = qc_body(first, %{"counted_quantity" => "0"})

    unless tags[:missing_quick_count_type] do
      assert D.request(:post, "/quick-counts", ctx.tok_a, body).status == 201
    end

    ctx
  end

  # -- helpers ------------------------------------------------------------------------------------

  defp api(method, path, token, body) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, "/api/v1" <> path)
        body -> Plug.Test.conn(method, "/api/v1" <> path, Jason.encode!(body))
      end

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp qc_body(m, extra \\ %{}) do
    Map.merge(
      %{
        "org_unit_id" => m.unit,
        "location_id" => m.location,
        "responsible_id" => m.employee,
        "catalog_item_id" => m.item,
        "catalog_uom_id" => m.uom,
        "counted_quantity" => "7",
        "reason_code" => "recount"
      },
      extra
    )
  end

  defp count(ctx, body, token \\ nil),
    do: D.request(:post, "/quick-counts", token || ctx.tok_k, body)

  defp count!(ctx, body, token \\ nil), do: count(ctx, body, token) |> P.status!(201)

  # A posted receipt of `qty` of the plain item (the key of `qc_body/1`).
  defp receipt!(ctx, qty) do
    m = ctx.ma

    body =
      D.body(m, nil, %{
        "lines" => [%{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => qty}]
      })

    doc = P.issue!(ctx, body)
    P.post_and_complete!(ctx, doc["id"])
  end

  defp balance(ctx, m \\ nil, token \\ nil) do
    m = m || ctx.ma
    path = "/balances?sku=#{m.item}&location=#{m.location}&org_unit=#{m.unit}"
    rows = S.get(path, token || ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")
    Enum.reduce(rows, Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
  end

  defp stored(ctx) do
    alias Letflow.Entities.Record.Latest

    records =
      Repo.aggregate(
        from(r in Latest,
          where: r.entity_type in ["stock_quick_count", "stock_quick_count_line"]
        ),
        :count,
        prefix: ctx.schema
      )

    docs =
      Repo.aggregate(
        from(d in Letflow.Documents.Document, where: d.type_key == "stock_quick_count"),
        :count,
        :id,
        prefix: ctx.schema
      )

    {records, docs}
  end

  defp task(ctx, id, node, status), do: O.task(ctx, id, node, status)

  defp complete_route(task, token), do: api(:post, "/tasks/#{task.id}/complete", token, %{})

  defp approve_as(ctx, id, token) do
    complete_route(task(ctx, id, "approve", :pending) || flunk("no pending approve"), token)
  end

  defp reason(conn) do
    body = Jason.decode!(conn.resp_body)
    get_in(body, ["extensions", "reason"]) || body["reason"] || body
  end

  defp refused!(conn, status, reason) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    assert reason(conn) == reason, "got #{conn.resp_body}"
    conn
  end

  defp audit(schema, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema)

  defp switch(token, four_eyes) do
    api(:put, "/approval-rules/stock_quick_count/approve", token, %{
      "four_eyes" => four_eyes,
      "reason" => "one-person company"
    })
  end

  # -- criteria -----------------------------------------------------------------------------------

  test "QC-1 a counter counts 7 on a balance of 10: issued QCT document with book, counted, difference",
       ctx do
    receipt!(ctx, "10")
    doc = count!(ctx, qc_body(ctx.ma))

    assert doc["kind"] == "quick_count" and doc["state"] == "issued"
    assert doc["number"] =~ "QCT"
    assert [line] = doc["lines"]

    assert {line["book_quantity"], line["counted_quantity"], line["difference"]} ==
             {"10.000000000", "7.000000000", "-3.000000000"}

    assert doc["reason_code"] == "recount" and doc["org_unit_id"] == ctx.ma.unit
    assert line["location_id"] == ctx.ma.location and line["catalog_item_id"] == ctx.ma.item

    read = P.get!(ctx, doc["id"])
    assert read["lines"] == doc["lines"] and read["state"] == "issued"
    assert task(ctx, doc["id"], "submit", :completed)
    assert task(ctx, doc["id"], "approve", :pending)
  end

  test "QC-2 four eyes ON: the counter is refused, a second user posts; balance 7, one count_set entry",
       ctx do
    receipt!(ctx, "10")
    # the counter is a TENANT_ADMIN here: the approve task role is TENANT_ADMIN (like every stock
    # posting task), so the refusal under test is the separation of duties and not the role check
    doc = count!(ctx, qc_body(ctx.ma), ctx.tok_a)

    conn = approve_as(ctx, doc["id"], ctx.tok_a)
    reference = Letflow.Api.Response.separation_of_duties(Plug.Test.conn(:get, "/"))
    assert conn.status == 403 and conn.resp_body == reference.resp_body
    assert Decimal.eq?(balance(ctx), 10)

    approve_as(ctx, doc["id"], ctx.tok_u2) |> P.status!(200)
    assert Decimal.eq?(balance(ctx), 7)

    assert [entry] = P.movements(ctx, doc["id"])
    assert entry["cause"] == "count_set" and entry["reason_code"] == "recount"
    assert entry["document_type"] == "stock_quick_count"
    assert [leg] = entry["legs"]
    assert Decimal.eq?(Decimal.new(leg["quantity"]), -3)

    read = P.get!(ctx, doc["id"])
    assert read["state"] == "posted" and read["posting_check"] == "ok"
    assert P.counts(ctx, doc["id"]) == %{entries: %{"count_set" => 1}, marks: 1}
  end

  test "QC-3 approval rule switched OFF: the counter approves alone, one self_approved audit",
       ctx do
    receipt!(ctx, "10")
    doc = count!(ctx, qc_body(ctx.ma), ctx.tok_a)
    switch(ctx.tok_a, false) |> P.status!(200)

    approve_as(ctx, doc["id"], ctx.tok_a) |> P.status!(200)
    assert Decimal.eq?(balance(ctx), 7)
    assert [self] = audit(ctx.schema, "task.self_approved")
    assert self.after_state["definition_name"] == "stock_quick_count"
    assert self.after_state["node_id"] == "approve"
    assert P.get!(ctx, doc["id"])["state"] == "posted"
  end

  test "QC-4a counted 0 on a balance of 4 posts -4 and the balance reads 0", ctx do
    receipt!(ctx, "4")
    doc = count!(ctx, qc_body(ctx.ma, %{"counted_quantity" => "0"}))
    assert [%{"counted_quantity" => "0.000000000", "difference" => "-4.000000000"}] = doc["lines"]

    approve_as(ctx, doc["id"], ctx.tok_u2) |> P.status!(200)
    assert Decimal.eq?(balance(ctx), 0)
  end

  defp zero_bodies(m) do
    now = DateTime.to_iso8601(DateTime.utc_now())
    line = %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => "0"}

    two_side = %{
      "org_unit_id" => m.unit,
      "event_time" => now,
      "from_location_id" => m.location,
      "from_responsible_id" => m.employee,
      "to_org_unit_id" => m.unit,
      "to_location_id" => m.location,
      "to_responsible_id" => m.employee,
      "lines" => [line]
    }

    one_side = %{
      "org_unit_id" => m.unit,
      "location_id" => m.location,
      "responsible_id" => m.employee,
      "event_time" => now,
      "lines" => [line]
    }

    [
      {"receipt", Map.put(one_side, "kind", "receipt")},
      {"issue", Map.put(one_side, "kind", "issue")},
      {"write_off", Map.merge(one_side, %{"kind" => "write_off", "reason_code" => "lost"})},
      {"transfer", Map.put(two_side, "kind", "transfer")},
      {"hand_over", Map.put(two_side, "kind", "hand_over")},
      {"return",
       two_side
       |> Map.drop(["to_org_unit_id", "to_location_id", "to_responsible_id"])
       |> Map.merge(%{
         "kind" => "return",
         "from_org_unit_id" => m.unit,
         "to_location_id" => m.location,
         "to_responsible_id" => m.employee
       })},
      {"opening",
       %{
         "kind" => "opening",
         "org_unit_id" => m.unit,
         "lines" => [
           %{
             "location_id" => m.location,
             "responsible_id" => m.employee,
             "catalog_item_id" => m.item,
             "catalog_uom_id" => m.uom,
             "quantity" => "0",
             "received_on" => O.back(5)
           }
         ]
       }}
    ]
  end

  for kind <- ~w(receipt issue write_off transfer hand_over return opening) do
    test "QC-4b quantity 0 stays quantity_invalid with its line_no for kind #{kind}", ctx do
      body = ctx.ma |> zero_bodies() |> List.keyfind!(unquote(kind), 0) |> elem(1)
      before_docs = {D.counts(ctx.schema), O.counts(ctx.schema)}

      conn = D.request(:post, "/documents", ctx.tok_a, body)
      refused!(conn, 422, "quantity_invalid")
      assert Jason.decode!(conn.resp_body)["line_no"] == 1
      assert {D.counts(ctx.schema), O.counts(ctx.schema)} == before_docs
    end
  end

  test "QC-5 stale: a receipt posted after the count: approve is 409 quick_count_stale, then cancel",
       ctx do
    receipt!(ctx, "10")
    doc = count!(ctx, qc_body(ctx.ma))
    receipt!(ctx, "2")
    assert Decimal.eq?(balance(ctx), 12)

    conn = approve_as(ctx, doc["id"], ctx.tok_u2)
    refused!(conn, 409, "quick_count_stale")
    assert task(ctx, doc["id"], "approve", :pending)
    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert Decimal.eq?(balance(ctx), 12)

    P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "counted again"}) |> P.status!(200)
    assert P.get!(ctx, doc["id"])["state"] == "cancelled"
  end

  test "QC-6 counted equal to book: issued, difference 0, no instance, no entry, state confirmed",
       ctx do
    receipt!(ctx, "10")
    doc = count!(ctx, qc_body(ctx.ma, %{"counted_quantity" => "10"}))
    assert [%{"difference" => "0.000000000"}] = doc["lines"]
    assert doc["state"] == "confirmed" and doc["number"] =~ "QCT"

    count =
      Repo.aggregate(
        from(p in InstanceProjection,
          where: fragment("?->>'document_id' = ?", p.variables, ^doc["id"])
        ),
        :count,
        prefix: ctx.schema
      )

    assert count == 0
    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert P.get!(ctx, doc["id"])["state"] == "confirmed"
    assert Decimal.eq?(balance(ctx), 10)
    # a confirmed document has nothing to post
    P.req(ctx, :post, doc["id"], "post") |> refused!(409, "document_posted")
  end

  test "QC-6b an item with no balance row counts against 0", ctx do
    doc = count!(ctx, qc_body(ctx.ma, %{"counted_quantity" => "5"}))
    assert [%{"book_quantity" => "0.000000000", "difference" => "5.000000000"}] = doc["lines"]
    approve_as(ctx, doc["id"], ctx.tok_u2) |> P.status!(200)
    assert Decimal.eq?(balance(ctx), 5)
  end

  @tag :missing_quick_count_type
  test "QC-4719 missing document type is a clear conflict with no writes", ctx do
    # Simulate a tenant installed before the quick-count document type existed.
    Repo.query!(~s|ALTER TABLE "#{ctx.schema}".document_types DISABLE TRIGGER USER|)

    try do
      Repo.delete_all(
        from(t in Letflow.Documents.DocumentType, where: t.key == "stock_quick_count"),
        prefix: ctx.schema
      )
    after
      Repo.query!(~s|ALTER TABLE "#{ctx.schema}".document_types ENABLE TRIGGER USER|)
    end

    before = {stored(ctx), O.counts(ctx.schema)}
    body = qc_body(ctx.ma, %{"counted_quantity" => "97.5"}) |> Map.delete("responsible_id")
    count(ctx, body) |> refused!(409, "definition_not_active")
    assert {stored(ctx), O.counts(ctx.schema)} == before
  end

  test "QC-4719 unassigned count alongside employee stock creates its own key", ctx do
    receipt!(ctx, "96.5")
    body = qc_body(ctx.ma, %{"counted_quantity" => "97.5"}) |> Map.delete("responsible_id")
    doc = count!(ctx, body)
    assert [%{"book_quantity" => "0.000000000", "difference" => "97.500000000"}] = doc["lines"]
    approve_as(ctx, doc["id"], ctx.tok_u2) |> P.status!(200)

    rows =
      S.get(
        "/balances?sku=#{ctx.ma.item}&location=#{ctx.ma.location}&org_unit=#{ctx.ma.unit}",
        ctx.tok_a
      )
      |> P.status!(200)
      |> Map.fetch!("rows")

    assert Enum.any?(
             rows,
             &(&1["responsible"] == ctx.ma.employee and
                 Decimal.eq?(Decimal.new(&1["quantity"]), "96.5"))
           )

    assert Enum.any?(
             rows,
             &(&1["responsible"] in [nil, ""] and Decimal.eq?(Decimal.new(&1["quantity"]), "97.5"))
           )
  end

  # -- the formal count rule (criteria 7 and 8) ---------------------------------------------------

  defp count_order!(ctx, m, status, extra \\ %{}) do
    alias Letflow.Entities.{ManagedTypes, Records}
    owner = ManagedTypes.owner_for!(Letflow.Modules.Stock)

    base = %{
      "org_unit_id" => m.unit,
      "status" => status,
      "kind" => "full",
      "planned_start" => "2026-11-01T08:00:00Z",
      "planned_end" => "2026-11-02T08:00:00Z",
      "chair_employee_id" => m.employee,
      "number" => "CO-T-#{System.unique_integer([:positive])}"
    }

    opts = %{
      entity_type: "count_order",
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: test fixture writing a count order header directly (own tenant schema)
    {:ok, %{record: order}} =
      Records.create_record(
        Map.put(opts, :field_values, Map.merge(base, extra)),
        ctx.schema,
        owner
      )

    scope = %{
      entity_type: "count_order_scope",
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      field_values: %{
        "count_order_id" => order.record_id,
        "location_id" => m.location,
        "org_unit_id" => m.unit
      }
    }

    # scope-all: test fixture
    {:ok, _} = Records.create_record(scope, ctx.schema, owner)
    {order.record_id, base["number"]}
  end

  defp set_status(ctx, order_id, status) do
    alias Letflow.Entities.{ManagedTypes, Records}
    owner = ManagedTypes.owner_for!(Letflow.Modules.Stock)

    fv =
      Repo.one(
        from(r in Letflow.Entities.Record.Latest,
          where: r.entity_type == "count_order" and r.record_id == ^order_id,
          select: r.field_values
        ),
        prefix: ctx.schema
      )

    attrs = %{
      entity_type: "count_order",
      record_id: order_id,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      field_values: Map.put(fv, "status", status)
    }

    # scope-all: test fixture
    {:ok, _} = Records.update_record(attrs, ctx.schema, owner)
  end

  test "QC-7 an opened count of the same org unit holds the quick count; pair rule; released after post",
       ctx do
    receipt!(ctx, "10")
    before_open = count!(ctx, qc_body(ctx.ma))
    # a reversible quick count posted before the order opens
    approve_as(ctx, before_open["id"], ctx.tok_u2) |> P.status!(200)
    second = count!(ctx, qc_body(ctx.ma, %{"counted_quantity" => "5"}))

    {order_id, number} = count_order!(ctx, ctx.ma, "counting")
    stored_before = stored(ctx)

    conn = count(ctx, qc_body(ctx.ma))
    refused!(conn, 422, "count_in_progress")
    assert Jason.decode!(conn.resp_body)["held_by"] == number
    assert stored(ctx) == stored_before

    # the quick count issued before the open is refused at approval: location_frozen with held_by
    conn = approve_as(ctx, second["id"], ctx.tok_u2)
    refused!(conn, 409, "location_frozen")
    assert conn.resp_body =~ number
    assert task(ctx, second["id"], "approve", :pending)

    # the reversal of a quick count posted before the open is held too
    rev = P.req(ctx, :post, before_open["id"], "reverse", %{"reason_code" => "wrong_quantity"})
    P.status!(rev, 200)
    rev_task = P.pending_task(ctx, before_open["id"], "reverse")

    assert {:error, {:entity_write_refused_detailed, _index, _code, "location_frozen", details}} =
             P.complete(ctx, rev_task)

    assert (Map.get(details, :held_by) || Map.get(details, "held_by")) == number
    assert P.get!(ctx, before_open["id"])["state"] == "posted"

    # the SAME place under another org unit is not held (the pair rule)
    unit2 = D.unit!(ctx.schema)
    opts = %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

    {:ok, _} =
      Letflow.Modules.Locations.link_unit_location(ctx.schema, unit2, ctx.ma.location, opts)

    other_doc = count!(ctx, qc_body(%{ctx.ma | unit: unit2}, %{"counted_quantity" => "1"}))
    assert other_doc["state"] == "issued"

    # after the order is posted or cancelled the quick count is accepted again
    set_status(ctx, order_id, "cancelled")
    assert count!(ctx, qc_body(ctx.ma, %{"counted_quantity" => "6"}))["state"] == "issued"
    {order2, _} = count_order!(ctx, ctx.ma, "signed")
    refused!(count(ctx, qc_body(ctx.ma)), 422, "count_in_progress")
    set_status(ctx, order2, "posted")
    assert count!(ctx, qc_body(ctx.ma, %{"counted_quantity" => "6"}))["state"] == "issued"
  end

  test "QC-7b a count order that is only ordered (not opened) does not hold", ctx do
    count_order!(ctx, ctx.ma, "ordered")
    assert count!(ctx, qc_body(ctx.ma))["state"] == "issued"
  end

  test "QC-8 REQ-765 unchanged: a no-freeze open count holds no receipt, issue or receipt reversal",
       ctx do
    count_order!(ctx, ctx.ma, "counting")

    summary = fn type, cause ->
      %{
        ledger_id: "stock",
        cause: cause,
        document_type: type,
        document_id: Ecto.UUID.generate(),
        keys: [%{"org_unit" => ctx.ma.unit, "location" => ctx.ma.location}]
      }
    end

    assert FreezeGuard.check(ctx.schema, summary.("stock_receipt", "receipt")) == :ok
    assert FreezeGuard.check(ctx.schema, summary.("stock_issue", "issue")) == :ok
    assert FreezeGuard.check(ctx.schema, summary.("stock_receipt", "reversal")) == :ok
    assert {:held, _} = FreezeGuard.check(ctx.schema, summary.("stock_quick_count", "count_set"))
    assert {:held, _} = FreezeGuard.check(ctx.schema, summary.("stock_quick_count", "reversal"))

    # a receipt really posts under the open count
    receipt!(ctx, "3")
    assert Decimal.eq?(balance(ctx), 3)
  end

  # -- refusals (criterion 9) ---------------------------------------------------------------------

  test "QC-9 input refusals store nothing and take no number", ctx do
    before = {stored(ctx), D.counts(ctx.schema)}
    m = ctx.ma

    cases = [
      {%{"counted_quantity" => "-1"}, 422, "quantity_invalid"},
      {%{"counted_quantity" => "1.0000000001"}, 422, "quantity_invalid"},
      {%{"counted_quantity" => 7}, 422, "quantity_invalid"},
      {%{"reason_code" => "bogus"}, 422, "reason_invalid"},
      {%{"reason_code" => "other"}, 422, "reason_invalid"},
      {%{"reason_code" => "other", "reason_text" => "  "}, 422, "reason_invalid"},
      {%{"reason_text" => String.duplicate("x", 501)}, 422, "reason_invalid"},
      {%{"catalog_item_id" => m.lot_item}, 422, "lot_required"},
      {%{"catalog_lot_id" => m.lot}, 422, "lot_not_allowed"},
      {%{"kind" => "quick_count"}, 422, "field_not_allowed"},
      {%{"difference" => "1"}, 422, "field_not_allowed"},
      {%{"location_id" => "nope"}, 422, "field_invalid"}
    ]

    for {extra, status, reason} <- cases do
      conn = count(ctx, qc_body(m, extra))

      assert conn.status == status and reason(conn) == reason,
             "#{inspect(extra)}: #{conn.resp_body}"
    end

    missing = Map.delete(qc_body(m), "reason_code")
    refused!(count(ctx, missing), 422, "reason_invalid")
    refused!(count(ctx, Map.delete(qc_body(m), "counted_quantity")), 422, "field_required")

    # POST /documents with kind quick_count is unknown_kind
    body = Map.put(qc_body(m), "kind", "quick_count")
    D.request(:post, "/documents", ctx.tok_a, body) |> refused!(422, "unknown_kind")

    D.request(:post, "/documents", ctx.tok_a, Map.put(body, "lines", []))
    |> refused!(422, "unknown_kind")

    assert {stored(ctx), D.counts(ctx.schema)} == before
    # the next quick count is number 2 (1 is the tenant's activating count): none was taken
    doc = count!(ctx, qc_body(m))
    assert doc["number"] =~ "000002"
  end

  test "QC-9d a multipart one-grapheme reason_text over the byte cap is refused, nothing stored",
       ctx do
    before = {stored(ctx), D.counts(ctx.schema)}
    m = ctx.ma
    text = "a" <> String.duplicate(<<0x301::utf8, 0x316::utf8>>, 100_000)

    fields =
      qc_body(m, %{"reason_code" => "other", "reason_text" => text}) |> Enum.to_list()

    boundary = "qc9dboundary7f3a"

    parts =
      for {k, v} <- fields do
        [
          "--",
          boundary,
          "\r\nContent-Disposition: form-data; name=\"",
          k,
          "\"\r\n\r\n",
          v,
          "\r\n"
        ]
      end

    body = IO.iodata_to_binary([parts, "--", boundary, "--\r\n"])

    conn =
      Plug.Test.conn(:post, S.base() <> "/quick-counts", body)
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.tok_k)
      |> Plug.Conn.put_req_header("content-type", "multipart/form-data; boundary=" <> boundary)
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

    assert conn.status == 422 and reason(conn) == "reason_invalid"
    assert {stored(ctx), D.counts(ctx.schema)} == before
  end

  test "QC-9b a lot-tracked item counts with its lot; the balance key includes the lot", ctx do
    m = ctx.ma
    body = qc_body(m, %{"catalog_item_id" => m.lot_item, "catalog_lot_id" => m.lot})
    doc = count!(ctx, body)
    assert [%{"catalog_lot_id" => lot}] = doc["lines"]
    assert lot == m.lot
    approve_as(ctx, doc["id"], ctx.tok_u2) |> P.status!(200)
  end

  test "QC-9c a serial-tracked item is refused tracking_policy_not_supported", ctx do
    m = ctx.ma

    serial =
      Letflow.CatalogItemsFixture.item!(
        ctx.schema,
        "SER#{System.unique_integer([:positive])}",
        m.uom,
        %{"tracking_policy" => "serial"}
      )

    conn = count(ctx, qc_body(m, %{"catalog_item_id" => serial.record_id}))
    refused!(conn, 422, "tracking_policy_not_supported")
  end

  # -- access (criteria 10 and 11) ----------------------------------------------------------------

  test "QC-10 permission: STOREKEEPER and other roles are 403, the matrix lists two roles",
       ctx do
    token = S.token(ctx, :a, ["AUDITOR"], sub: "auditor-1")
    assert count(ctx, qc_body(ctx.ma), token).status == 403
    assert count(ctx, qc_body(ctx.ma), ctx.tok_sk).status == 403
    assert count(ctx, qc_body(ctx.ma), ctx.tok_a).status == 201
    assert count(ctx, qc_body(ctx.ma), ctx.tok_k).status == 201

    golden = File.read!("priv/permission_matrix/effective.golden")

    allowed =
      for line <- String.split(golden, "\n"),
          [role, "StockQuickCount", "true" | _] <- [String.split(line, " ")],
          do: role

    assert Enum.sort(allowed) == ["PLATFORM_ADMIN", "TENANT_ADMIN"]
  end

  test "QC-10b an API token gets the 404 of a tenant without the module and nothing is stored",
       ctx do
    user = Letflow.Support.TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

    {:ok, %{plaintext: plaintext}} =
      Letflow.Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: ctx.schema
      )

    slug = Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug
    before = stored(ctx)

    conn =
      Plug.Test.conn(:post, S.base() <> "/quick-counts", Jason.encode!(qc_body(ctx.ma)))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> plaintext)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-tenant-slug", slug)
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

    assert conn.status == 404, conn.resp_body
    assert stored(ctx) == before
  end

  test "QC-10c a caller without the tenant-wide stock read gets the unknown-document 404 first",
       ctx do
    sc_admin = scoped_token!(ctx, "TENANT_ADMIN", "scoped-admin")
    before = stored(ctx)

    # a good body and a body whose masters do not link: both 404, never the 422 of the master checks
    bad = qc_body(ctx.ma, %{"location_id" => Ecto.UUID.generate()})

    for tok <- [sc_admin], body <- [qc_body(ctx.ma), bad] do
      conn = count(ctx, body, tok)
      assert conn.status == 404, conn.resp_body
    end

    assert stored(ctx) == before
  end

  test "QC-10d no read authority is the 404 before any master check (context level)", ctx do
    before = stored(ctx)
    bad = qc_body(ctx.ma, %{"location_id" => Ecto.UUID.generate()})

    for body <- [bad, qc_body(ctx.ma)] do
      assert {:error, :not_found} =
               Letflow.Modules.Stock.Documents.quick_count(ctx.schema, body, Ecto.UUID.generate(),
                 authorized: nil
               )
    end

    assert stored(ctx) == before
  end

  # A user of tenant A whose only role row is scoped to the unit of `ctx.ma` (not tenant-wide).
  defp scoped_token!(ctx, role, sub) do
    tok = S.token(ctx, :a, [role], sub: sub)
    assert D.request(:get, "/documents", tok).status in [200, 403, 404]

    user =
      Repo.one!(from(u in Letflow.Identity.User, where: u.username == ^sub), prefix: ctx.schema)

    group = Letflow.Support.RoleScopeGrantsFixture.group_of!(ctx.schema, role)
    _ = Letflow.Support.RoleScopeGrantsFixture.raw_delete_rows!(ctx.schema, group, role)

    :ok =
      Letflow.Support.RoleScopeGrantsFixture.raw_user_row!(ctx.schema, user.id, role, ctx.ma.unit)

    tok
  end

  test "QC-11 cross-tenant: tenant B naming tenant A's masters is refused with nothing written",
       ctx do
    before_a = stored(ctx)
    before_b = stored(%{schema: ctx.b.schema_name})

    conn = count(ctx, qc_body(ctx.ma), ctx.tok_kb)
    assert conn.status == 422, conn.resp_body
    assert reason(conn) in ["not_linked", "unit_not_valid", "org_unit_invalid"]
    assert stored(ctx) == before_a
    assert stored(%{schema: ctx.b.schema_name}) == before_b

    doc = count!(ctx, qc_body(ctx.ma))

    D.request(:get, "/documents/#{doc["id"]}", ctx.tok_kb)
    |> Map.fetch!(:status)
    |> then(&assert(&1 == 404))
  end

  # -- reversal (criterion 12) --------------------------------------------------------------------

  test "QC-12 reverse of a posted quick count restores the book; a second reverse is refused",
       ctx do
    receipt!(ctx, "10")
    doc = count!(ctx, qc_body(ctx.ma))
    approve_as(ctx, doc["id"], ctx.tok_u2) |> P.status!(200)
    assert Decimal.eq?(balance(ctx), 7)

    P.req(ctx, :post, doc["id"], "reverse", %{"reason_code" => "wrong_quantity"})
    |> P.status!(200)

    task = P.pending_task(ctx, doc["id"], "reverse") || flunk("no reverse task")
    assert {:ok, _} = P.complete(ctx, task)

    assert Decimal.eq?(balance(ctx), 10)
    read = P.get!(ctx, doc["id"])
    assert read["state"] == "reversed" and read["posting_check"] == "ok"

    P.req(ctx, :post, doc["id"], "reverse", %{"reason_code" => "wrong_quantity"})
    |> refused!(409, "document_reversed")
  end

  # -- more ---------------------------------------------------------------------------------------

  test "QC-14 PUT /documents/:id of a quick count is refused, and the document has no draft",
       ctx do
    doc = count!(ctx, qc_body(ctx.ma))

    conn = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, qc_body(ctx.ma))
    assert conn.status in [409, 422]

    D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_a)
    |> refused!(409, "document_not_draft")
  end

  test "QC-15 the list shows quick counts and filters by kind", ctx do
    doc = count!(ctx, qc_body(ctx.ma))
    rows = S.get("/documents?kind=quick_count", ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")
    assert Enum.any?(rows, &(&1["id"] == doc["id"] and &1["kind"] == "quick_count"))
  end

  test "QC-16 the approve task has the stock approve role and the pack definition is the opening shape" do
    defs =
      File.read!("priv/modules/stock/pack.json") |> Jason.decode!() |> Map.fetch!("definitions")

    graph = Enum.find(defs, &(&1["process_key"] == "stock_quick_count"))["graph"]
    assert Enum.map(graph["nodes"], & &1["id"]) == ~w(start submit approve end)
    approve = Enum.find(graph["nodes"], &(&1["id"] == "approve"))
    assert approve["attributes"]["distinct_from"] == ["submit"]
    assert [%{"handler" => "post_document"}] = approve["attributes"]["module_writes"]
    assert approve["attributes"]["role"] == "TENANT_ADMIN"
  end

  test "QC-17 the unit of the key must match the balance row", ctx do
    receipt!(ctx, "10")

    other_uom =
      Letflow.CatalogItemsFixture.uom!(ctx.schema, "BOX#{System.unique_integer([:positive])}")

    conn = count(ctx, qc_body(ctx.ma, %{"catalog_uom_id" => other_uom.record_id}))
    assert conn.status == 422
    assert reason(conn) in ["unit_not_valid"]
  end
end
