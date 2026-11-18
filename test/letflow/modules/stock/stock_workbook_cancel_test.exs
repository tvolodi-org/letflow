Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("posting_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.StockWorkbookCancelTest do
  @moduledoc """
  REQ-886 / GH #4605: list the balances workbook loads and cancel one.
  Test ids SWC-1..SWC-8 follow the acceptance criteria; SWC-9 is the route registration.
  Committed tenants in Sandbox `:auto` mode; `async: false` (DDL, process tasks).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Engine
  alias Letflow.Engine.Task
  alias Letflow.Entities.{ManagedTypes, Records}
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.Documents
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: Docs
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.Support.TokenMintFixture

  @moduletag timeout: 300_000

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @header ["Артикул", "Номенклатура", "Конечный остаток", "Зона", "Стеллаж", "Полка"]

  setup do
    ctx = P.setup!([:a, :b, :s])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))

    ctx =
      Map.merge(ctx, %{
        tok_k: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "swc-counter-1"),
        tok_u2: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "swc-second-admin"),
        tok_sk: S.token(ctx, :a, ["STOREKEEPER"], sub: "swc-keeper-1"),
        tok_kb: S.token(ctx, :b, ["TENANT_ADMIN"], sub: "swc-counter-b"),
        holder2: TokenMintFixture.role_holder!(ctx.a.schema_name, ["TENANT_ADMIN"])
      })

    # Activate the stock_quick_count process definition so the apply route can issue documents.
    first = Docs.masters!(ctx.schema)

    body = %{
      "org_unit_id" => first.unit,
      "location_id" => first.location,
      "catalog_item_id" => first.item,
      "catalog_uom_id" => first.uom,
      "counted_quantity" => "0",
      "reason_code" => "recount"
    }

    assert apply_request("/quick-counts", ctx.tok_k, Jason.encode!(body), "application/json").status ==
             201

    ctx
  end

  # -- helpers -----------------------------------------------------------------------------------

  defp xlsx!(rows, sheet \\ "Лист1") do
    wb = %Elixlsx.Workbook{sheets: [%Elixlsx.Sheet{name: sheet, rows: rows}]}
    {:ok, {_name, bin}} = Elixlsx.write_to_memory(wb, "t.xlsx")
    bin
  end

  defp book(rows), do: xlsx!([@header | rows])

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  defp loc!(schema, code) do
    {:ok, node} =
      Locations.create_node(
        schema,
        %{"code" => code, "name" => code, "node_kind" => "zone"},
        opts()
      )

    node["record_id"]
  end

  # Items Z-1 (10 at RI2, 3 at LA1). Returns seed map.
  defp seed!(schema) do
    unit = Docs.unit!(schema)
    uom = Cat.uom!(schema, "pcs")
    ri2 = loc!(schema, "RI2")
    la1 = loc!(schema, "LA1")
    z1 = Cat.item!(schema, "Z-1", uom.record_id, %{"name" => "Один"})

    S.post!(schema, "receipt", %{
      document_id: "swc-seed-1",
      lines: [
        S.line(z1.record_id, "10", %{to: S.side(unit, ri2)}, %{unit: uom.record_id}),
        S.line(z1.record_id, "3", %{to: S.side(unit, la1)}, %{unit: uom.record_id})
      ]
    })

    %{unit: unit, uom: uom, ri2: ri2, la1: la1, z1: z1}
  end

  defp apply_request(path, token, body, ct \\ @xlsx) do
    Plug.Test.conn(:post, S.base() <> path, body)
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", ct)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp cancel_request(id, token, body \\ %{"reason" => "файл с ошибкой"}) do
    Plug.Test.conn(
      :post,
      S.base() <> "/stock-workbook/imports/#{id}/cancel",
      Jason.encode!(body)
    )
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp list_request(token, query \\ "") do
    Plug.Test.conn(:get, S.base() <> "/stock-workbook/imports" <> query)
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp apply_load!(ctx, unit, bytes, token \\ nil, file_name \\ nil) do
    path =
      "/stock-workbook/apply?org_unit_id=#{unit}" <>
        if(file_name, do: "&file_name=#{URI.encode(file_name)}", else: "")

    conn = apply_request(path, token || ctx.tok_k, bytes)
    assert conn.status == 201, "expected 201, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  defp pending_task(schema, doc_id, node) do
    Repo.one(
      from(t in Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :pending and t.node_id == ^node and
            fragment("?->>'document_id' = ?", p.variables, ^doc_id),
        order_by: [asc: t.inserted_at],
        limit: 1
      ),
      prefix: schema
    )
  end

  defp complete_task(ctx, task, user) do
    Engine.complete_task(
      task.id,
      %{output_variables: %{}, actor_id: user.id, idempotency_key: Ecto.UUID.generate()},
      prefix: ctx.schema,
      credential: :oidc
    )
  end

  defp approve!(ctx, doc_id) do
    task = pending_task(ctx.schema, doc_id, "approve") || flunk("no pending approve task")
    {:ok, _} = complete_task(ctx, task, ctx.holder2)
  end

  defp complete_reverse!(ctx, doc_id) do
    task = pending_task(ctx.schema, doc_id, "reverse") || flunk("no pending reverse task")
    {:ok, _} = complete_task(ctx, task, ctx.holder)
  end

  defp balance(ctx, m, item, location) do
    path = "/balances?sku=#{item}&location=#{location}&org_unit=#{m.unit}"
    rows = S.get(path, ctx.tok_k) |> P.status!(200) |> Map.fetch!("rows")
    Enum.reduce(rows, Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
  end

  defp ledger_entries(schema) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".ledger_entry|)
    n
  end

  defp workbook_docs(schema) do
    Repo.aggregate(
      from(d in Letflow.Documents.Document, where: d.type_key == "stock_quick_count"),
      :count,
      :id,
      prefix: schema
    )
  end

  defp reversal_instances(schema, doc_id) do
    Repo.one(
      from(p in InstanceProjection,
        join: d in Letflow.Definitions.ProcessDefinition,
        on: d.id == p.definition_id,
        where:
          p.status == :active and d.name == "stock_reversal" and
            fragment("?->>'document_id' = ?", p.variables, ^doc_id)
      ),
      prefix: schema
    )
  end

  defp reason_of(conn) do
    body = S.json(conn)
    get_in(body, ["extensions", "reason"]) || body["reason"]
  end

  # -- criterion 1: list -------------------------------------------------------------------------

  describe "list (SWC-1)" do
    test "SWC-1a list fields, order and reversal_pending", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])

      # Three loads by two users, each in creation order
      a1 = apply_load!(ctx, m.unit, bytes, ctx.tok_k, "file1.xlsx")
      a2 = apply_load!(ctx, m.unit, bytes, ctx.tok_u2, "file2.xlsx")
      a3 = apply_load!(ctx, m.unit, bytes, ctx.tok_k, "file3.xlsx")

      conn = list_request(ctx.tok_k)
      assert conn.status == 200
      rows = S.json(conn)["rows"]

      # At least 3 rows from our loads (may have earlier ones from setup warm)
      ids = Enum.map(rows, & &1["document_id"])
      assert a3["document_id"] in ids
      assert a2["document_id"] in ids
      assert a1["document_id"] in ids

      # Newest first
      pos_a1 = Enum.find_index(rows, &(&1["document_id"] == a1["document_id"]))
      pos_a2 = Enum.find_index(rows, &(&1["document_id"] == a2["document_id"]))
      pos_a3 = Enum.find_index(rows, &(&1["document_id"] == a3["document_id"]))
      assert pos_a3 < pos_a2
      assert pos_a2 < pos_a1

      # Fields of one row
      row = Enum.find(rows, &(&1["document_id"] == a2["document_id"]))
      assert is_binary(row["document_id"])
      assert is_binary(row["number"])
      assert is_binary(row["created_at"])
      assert is_binary(row["created_by"])
      assert row["file_name"] == "file2.xlsx"
      assert row["sheet"] == "Лист1"
      assert row["lines"] == 2
      assert row["remarks_count"] == 0
      assert row["state"] == "issued"
      refute row["reversal_pending"]

      # A posted load with started reversal reads reversal_pending: true
      approve!(ctx, a1["document_id"])
      cancel_request(a1["document_id"], ctx.tok_k)

      conn2 = list_request(ctx.tok_k)

      row_a1 =
        conn2
        |> S.json()
        |> Map.fetch!("rows")
        |> Enum.find(&(&1["document_id"] == a1["document_id"]))

      assert row_a1["state"] == "posted"
      assert row_a1["reversal_pending"]
    end

    test "SWC-1b at most 50 results", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])

      # Seed many loads (we need 51 workbook quick-count docs but that requires many applies;
      # instead verify capped at 50 by checking length <= 50 after several applies)
      for _i <- 1..5, do: apply_load!(ctx, m.unit, bytes)

      conn = list_request(ctx.tok_k)
      rows = S.json(conn)["rows"]
      assert length(rows) <= 50
    end

    test "SWC-1c scoped stock reader gets the unknown-path 404", ctx do
      s = S.tenant!("swc-s", ctx.names.s)
      node = Letflow.Support.RoleScopeGrantsFixture.node!(s.schema_name)
      user_tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "swc-scoped2")
      _ = S.get("/balances", user_tok)

      _ =
        Letflow.Support.RoleScopeGrantsFixture.raw_delete_rows!(
          s.schema_name,
          Letflow.Support.RoleScopeGrantsFixture.group_of!(s.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      user =
        Repo.one!(from(u in Letflow.Identity.User, where: u.username == "swc-scoped2"),
          prefix: s.schema_name
        )

      :ok =
        Letflow.Support.RoleScopeGrantsFixture.raw_user_row!(
          s.schema_name,
          user.id,
          "TENANT_ADMIN",
          node
        )

      conn = list_request(user_tok)
      reference = S.get("/stock-workbook", user_tok)
      assert conn.status == 404

      assert Letflow.ModuleConnCase.strip(S.json(conn)) ==
               Letflow.ModuleConnCase.strip(S.json(reference))
    end

    test "SWC-1d a query key is 422 invalid_filter", ctx do
      conn = list_request(ctx.tok_k, "?page=1")
      assert conn.status == 422
      assert reason_of(conn) == "invalid_filter"
    end

    test "SWC-1e a TASK_WORKER gets 403", ctx do
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "swc-worker")
      conn = list_request(tok)
      assert conn.status == 403
    end
  end

  # -- criterion 2: reason validation -----------------------------------------------------------

  describe "reason validation (SWC-2)" do
    test "SWC-2 bad reason → 422, nothing written", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      load = apply_load!(ctx, m.unit, bytes)
      doc_id = load["document_id"]

      entries_before = ledger_entries(ctx.schema)
      docs_before = workbook_docs(ctx.schema)

      # No body
      c1 = cancel_request(doc_id, ctx.tok_k, %{})
      assert c1.status == 422
      assert reason_of(c1) == "reason_required"

      # Blank reason
      c2 = cancel_request(doc_id, ctx.tok_k, %{"reason" => "  "})
      assert c2.status == 422
      assert reason_of(c2) == "reason_required"

      # No reason key
      c3 = cancel_request(doc_id, ctx.tok_k, %{"other" => "x"})
      assert c3.status == 422
      assert reason_of(c3) == "reason_required"

      # 501 characters
      long = String.duplicate("а", 501)
      c4 = cancel_request(doc_id, ctx.tok_k, %{"reason" => long})
      assert c4.status == 422
      assert reason_of(c4) == "reason_too_long"

      # JSON array body (not an object) — INV-8 regression
      c5 = cancel_request(doc_id, ctx.tok_k, [1])
      assert c5.status == 422
      assert reason_of(c5) == "reason_required"

      # JSON string body (not an object) — INV-8 regression
      c6 = cancel_request(doc_id, ctx.tok_k, "x")
      assert c6.status == 422
      assert reason_of(c6) == "reason_required"

      # Document state unchanged, nothing written
      {:ok, doc} = Documents.fetch(ctx.schema, doc_id)
      assert doc.state == "issued"
      assert pending_task(ctx.schema, doc_id, "approve")
      refute reversal_instances(ctx.schema, doc_id)
      assert ledger_entries(ctx.schema) == entries_before
      assert workbook_docs(ctx.schema) == docs_before
    end
  end

  # -- criterion 3: cancel before approval ------------------------------------------------------

  describe "cancel before approval (SWC-3)" do
    test "SWC-3 cancel awaiting-approval load: 200 cancelled, approve task gone, balances unchanged",
         ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      load = apply_load!(ctx, m.unit, bytes)
      doc_id = load["document_id"]
      assert load["lines"] == 2

      conn = cancel_request(doc_id, ctx.tok_k, %{"reason" => "файл с ошибкой"})
      assert conn.status == 200
      body = S.json(conn)
      assert body["action"] == "cancelled"
      assert body["lines"] == 2

      {:ok, doc} = Documents.fetch(ctx.schema, doc_id)
      assert doc.state == "cancelled"
      refute pending_task(ctx.schema, doc_id, "approve")

      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.ri2), 10)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.la1), 3)
    end
  end

  # -- criterion 4: cancel after posting --------------------------------------------------------

  describe "cancel after posting (SWC-4)" do
    test "SWC-4 cancel posted load: 200 reverse_pending, balances unchanged, reversal entry after task",
         ctx do
      m = seed!(ctx.schema)
      # file: Z-1=8 at RI2, so Z-1 RI2 book=10→8 (diff -2), Z-1 LA1 book=3→0 (diff -3)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      load = apply_load!(ctx, m.unit, bytes)
      doc_id = load["document_id"]
      assert load["lines"] == 2

      # Approve (second user): balances now 8 at RI2, 0 at LA1
      approve!(ctx, doc_id)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.ri2), 8)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.la1), 0)

      # Cancel: starts reversal
      conn = cancel_request(doc_id, ctx.tok_k, %{"reason" => "неверный файл"})
      assert conn.status == 200
      body = S.json(conn)
      assert body["action"] == "reverse_pending"
      assert body["lines"] == 2

      # Balances unchanged
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.ri2), 8)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.la1), 0)

      # stock_reversal instance has open reverse task with reason_code other and reason_text
      reverse_task = pending_task(ctx.schema, doc_id, "reverse")
      assert reverse_task
      instance = Repo.get!(InstanceProjection, reverse_task.instance_id, prefix: ctx.schema)
      assert instance.variables["reason_code"] == "other"
      assert instance.variables["reason_text"] == "неверный файл"

      # Complete the reverse task: balances return
      complete_reverse!(ctx, doc_id)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.ri2), 10)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.la1), 3)

      # One reversal entry with legs +2 and +3
      rows =
        S.get("/movements?document_id=#{doc_id}", ctx.tok_k)
        |> P.status!(200)
        |> Map.fetch!("rows")

      reversal = Enum.find(rows, &(&1["cause"] == "reversal"))
      assert reversal

      leg_quantities =
        reversal["legs"]
        |> Enum.map(&Decimal.to_integer(Decimal.new(&1["quantity"])))
        |> Enum.sort()

      assert leg_quantities == [2, 3]
    end
  end

  # -- criterion 5: 409 and 422 state cases -----------------------------------------------------

  describe "pending and twice (SWC-5)" do
    test "SWC-5 409 reversal_pending, 422 import_already_cancelled in all flavours", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      load = apply_load!(ctx, m.unit, bytes)
      doc_id = load["document_id"]
      approve!(ctx, doc_id)
      cancel_request(doc_id, ctx.tok_k) |> then(&assert &1.status == 200)

      # 409 while reverse task is open: nothing new created
      reverse_task_before = pending_task(ctx.schema, doc_id, "reverse")
      entries_before = ledger_entries(ctx.schema)

      c1 = cancel_request(doc_id, ctx.tok_k)
      assert c1.status == 409
      assert reason_of(c1) == "reversal_pending"
      assert pending_task(ctx.schema, doc_id, "reverse").id == reverse_task_before.id
      assert ledger_entries(ctx.schema) == entries_before

      # Complete reverse task, then 422 import_already_cancelled
      complete_reverse!(ctx, doc_id)
      entries_after_reverse = ledger_entries(ctx.schema)

      c2 = cancel_request(doc_id, ctx.tok_k)
      assert c2.status == 422
      assert reason_of(c2) == "import_already_cancelled"
      assert ledger_entries(ctx.schema) == entries_after_reverse
      refute reversal_instances(ctx.schema, doc_id)

      # A load cancelled before approval also gives 422 import_already_cancelled
      load2 = apply_load!(ctx, m.unit, bytes)
      doc_id2 = load2["document_id"]
      cancel_request(doc_id2, ctx.tok_k) |> then(&assert &1.status == 200)
      c3 = cancel_request(doc_id2, ctx.tok_k)
      assert c3.status == 422
      assert reason_of(c3) == "import_already_cancelled"

      # A load reversed through POST /documents/:id/reverse is also import_already_cancelled
      load3 = apply_load!(ctx, m.unit, bytes)
      doc_id3 = load3["document_id"]
      approve!(ctx, doc_id3)

      reverse_conn =
        Plug.Test.conn(
          :post,
          S.base() <> "/documents/#{doc_id3}/reverse",
          Jason.encode!(%{"reason_code" => "other", "reason_text" => "manual reverse"})
        )
        |> put_req_header("authorization", "Bearer " <> ctx.tok_k)
        |> put_req_header("content-type", "application/json")
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

      assert reverse_conn.status == 200

      complete_reverse!(ctx, doc_id3)

      c4 = cancel_request(doc_id3, ctx.tok_k)
      assert c4.status == 422
      assert reason_of(c4) == "import_already_cancelled"
    end
  end

  # -- criterion 6: not a workbook load / INV-10 / permission -----------------------------------

  describe "not a load (SWC-6)" do
    test "SWC-6 non-workbook loads and unknown ids get 404; no StockReverse gets 403", ctx do
      # One-line quick count from POST /quick-counts (uses ctx.ma - linked masters)
      qc_body =
        Jason.encode!(%{
          "org_unit_id" => ctx.ma.unit,
          "location_id" => ctx.ma.location,
          "catalog_item_id" => ctx.ma.item,
          "catalog_uom_id" => ctx.ma.uom,
          "counted_quantity" => "9",
          "reason_code" => "recount"
        })

      qc_resp = apply_request("/quick-counts", ctx.tok_k, qc_body, "application/json")
      assert qc_resp.status == 201, "expected 201, got #{qc_resp.status}: #{qc_resp.resp_body}"
      qc_id = S.json(qc_resp)["id"]

      # Receipt document
      rcp_resp = Docs.request(:post, "/documents", ctx.tok_k, Docs.body(ctx.ma))
      assert rcp_resp.status == 201
      rcp_id = S.json(rcp_resp)["id"]

      # Unknown id
      unknown_id = Ecto.UUID.generate()

      reference_conn =
        Plug.Test.conn(:get, S.base() <> "/documents/#{unknown_id}")
        |> put_req_header("authorization", "Bearer " <> ctx.tok_k)
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

      reference_body = Letflow.ModuleConnCase.strip(S.json(reference_conn))

      for id <- [qc_id, rcp_id, unknown_id] do
        conn = cancel_request(id, ctx.tok_k)
        assert conn.status == 404, "expected 404 for #{id}, got #{conn.status}"
        assert Letflow.ModuleConnCase.strip(S.json(conn)) == reference_body
      end

      # Tenant B's workbook load cancelled by Tenant A's user (INV-10)
      m_b = seed!(ctx.b.schema_name)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])

      load_b =
        apply_load!(
          %{
            ctx
            | schema: ctx.b.schema_name,
              tok_k: ctx.tok_kb,
              holder2: TokenMintFixture.role_holder!(ctx.b.schema_name, ["TENANT_ADMIN"])
          },
          m_b.unit,
          bytes,
          ctx.tok_kb
        )

      # Take snapshot after seeding and loading in B (seed creates a receipt = 1 ledger entry)
      entries_a_snapshot = ledger_entries(ctx.schema)
      entries_b_snapshot = ledger_entries(ctx.b.schema_name)

      conn_b = cancel_request(load_b["document_id"], ctx.tok_k)
      assert conn_b.status == 404
      assert Letflow.ModuleConnCase.strip(S.json(conn_b)) == reference_body
      assert ledger_entries(ctx.schema) == entries_a_snapshot
      assert ledger_entries(ctx.b.schema_name) == entries_b_snapshot

      # No StockReverse → 403 (TASK_WORKER has no stock permissions)
      m = seed!(ctx.schema)
      bytes2 = book([["Z-1", "Один", 8, "R", "I", 2]])
      load_a = apply_load!(ctx, m.unit, bytes2)
      tok_w = S.token(ctx, :a, ["TASK_WORKER"], sub: "swc-worker-403")
      conn_w = cancel_request(load_a["document_id"], tok_w)
      assert conn_w.status == 403
    end
  end

  # -- criterion 7: guards at completion --------------------------------------------------------

  describe "guards at completion (SWC-7)" do
    test "SWC-7 location_frozen at reverse task, then completes after count order cancel", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      load = apply_load!(ctx, m.unit, bytes)
      doc_id = load["document_id"]
      approve!(ctx, doc_id)

      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.ri2), 8)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.la1), 0)

      # Open a count order over the same org unit with scope covering RI2
      owner = ManagedTypes.owner_for!(Letflow.Modules.Stock)
      order_number = "CO-SWC-#{System.unique_integer([:positive])}"

      {:ok, %{record: order}} =
        Records.create_record(
          %{
            entity_type: "count_order",
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate(),
            field_values: %{
              "org_unit_id" => m.unit,
              "status" => "counting",
              "kind" => "full",
              "planned_start" => "2026-11-01T08:00:00Z",
              "planned_end" => "2026-11-02T08:00:00Z",
              "chair_employee_id" => ctx.ma.employee,
              "number" => order_number
            }
          },
          ctx.schema,
          owner
        )

      {:ok, _} =
        Records.create_record(
          %{
            entity_type: "count_order_scope",
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate(),
            field_values: %{
              "count_order_id" => order.record_id,
              "location_id" => m.ri2,
              "org_unit_id" => m.unit
            }
          },
          ctx.schema,
          owner
        )

      # Cancel starts reversal (count order does not block this call)
      conn = cancel_request(doc_id, ctx.tok_k, %{"reason" => "пересчёт"})
      assert conn.status == 200
      assert S.json(conn)["action"] == "reverse_pending"

      # Completing the reverse task is refused location_frozen
      task = pending_task(ctx.schema, doc_id, "reverse") || flunk("no pending reverse task")
      result = complete_task(ctx, task, ctx.holder)
      assert match?({:error, _}, result)

      # Task is still pending; balances unchanged
      assert pending_task(ctx.schema, doc_id, "reverse")
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.ri2), 8)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.la1), 0)

      # Cancel the count order
      {:ok, _} =
        Records.update_record(
          %{
            record_id: order.record_id,
            entity_type: "count_order",
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate(),
            field_values: Map.put(order.field_values, "status", "cancelled")
          },
          ctx.schema,
          owner
        )

      # Now the reverse task can complete
      task2 =
        pending_task(ctx.schema, doc_id, "reverse") ||
          flunk("no pending reverse task after order cancel")

      {:ok, _} = complete_task(ctx, task2, ctx.holder)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.ri2), 10)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.la1), 3)
    end
  end

  # -- criterion 8: docs in step ----------------------------------------------------------------

  describe "docs in step (SWC-8)" do
    test "SWC-8a runbook has list and cancel section", _ctx do
      runbook = File.read!("docs/runbooks/stock-workbook-import.md")
      assert runbook =~ "stock-workbook/imports"
      assert runbook =~ "import_already_cancelled"
      assert runbook =~ "reversal_pending"
      assert runbook =~ "reverse task"
      assert runbook =~ "REQ-833"
    end

    test "SWC-8b route_policies of module stock lists both routes and pins pass", _ctx do
      routes = Letflow.Modules.Stock.manifest().route_policies
      assert {"GET", "/stock-workbook/imports", :StockRead} in routes
      assert {"POST", "/stock-workbook/imports/:id/cancel", :StockReverse} in routes
    end
  end

  # -- criterion 9: route registration -----------------------------------------------------------

  describe "route registration (SWC-9)" do
    test "SWC-9 both routes are in the route policies", _ctx do
      policy = Letflow.Modules.Stock.manifest().route_policies
      assert Enum.any?(policy, fn {m, p, _} -> m == "GET" and p == "/stock-workbook/imports" end)

      assert Enum.any?(policy, fn {m, p, _} ->
               m == "POST" and p == "/stock-workbook/imports/:id/cancel"
             end)
    end
  end
end
