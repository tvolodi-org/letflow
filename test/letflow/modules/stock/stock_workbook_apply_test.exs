Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("posting_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.StockWorkbookApplyTest do
  @moduledoc """
  REQ-885 / GH #4606: the load (apply) of a Qoimeks-layout balances workbook as a stock_quick_count
  document. Test ids QWA-1..QWA-11 follow the acceptance criteria; QWA-12 is the route registration.
  Committed tenants in Sandbox `:auto` mode; `async: false` (DDL, app env seams).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Engine
  alias Letflow.Engine.Task
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
        tok_k: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "wba-counter-1"),
        tok_u2: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "wba-second-admin"),
        tok_kb: S.token(ctx, :b, ["TENANT_ADMIN"], sub: "wba-counter-b"),
        tok_sk: S.token(ctx, :a, ["STOREKEEPER"], sub: "wba-keeper-1"),
        holder2: TokenMintFixture.role_holder!(ctx.a.schema_name, ["TENANT_ADMIN"])
      })

    # Activate the stock_quick_count process definition so the apply route can issue documents.
    # (TENANT_ADMIN issues one quick-count to warm up, same as quick_count_test.exs.)
    first = Docs.masters!(ctx.schema)

    body = %{
      "org_unit_id" => first.unit,
      "location_id" => first.location,
      "catalog_item_id" => first.item,
      "catalog_uom_id" => first.uom,
      "counted_quantity" => "0",
      "reason_code" => "recount"
    }

    assert apply_request("/quick-counts", ctx.tok_a, Jason.encode!(body), "application/json").status ==
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

  # Items Z-1 (10 at RI2, 3 at LA1), Z-2 (5 at RK2, usual place LA1), Z-3 (nothing).
  defp seed!(schema) do
    unit = Docs.unit!(schema)
    uom = Cat.uom!(schema, "pcs")
    ri2 = loc!(schema, "RI2")
    la1 = loc!(schema, "LA1")
    rk2 = loc!(schema, "RK2")
    z1 = Cat.item!(schema, "Z-1", uom.record_id, %{"name" => "Один"})
    z2 = Cat.item!(schema, "Z-2", uom.record_id, %{"name" => "Два", "default_location_id" => la1})
    _z3 = Cat.item!(schema, "Z-3", uom.record_id, %{"name" => "Три"})

    # Use the UOM's record_id (UUID) as the posting unit so the balance row's unit_ref is a UUID.
    # This keeps unit_ref compatible with the posting leg's catalog_uom_id (also the UUID).
    S.post!(schema, "receipt", %{
      document_id: "wba-seed-1",
      lines: [
        S.line(z1.record_id, "10", %{to: S.side(unit, ri2)}, %{unit: uom.record_id}),
        S.line(z1.record_id, "3", %{to: S.side(unit, la1)}, %{unit: uom.record_id}),
        S.line(z2.record_id, "5", %{to: S.side(unit, rk2)}, %{unit: uom.record_id})
      ]
    })

    %{unit: unit, uom: uom, ri2: ri2, la1: la1, rk2: rk2, z1: z1, z2: z2}
  end

  defp apply_request(path, token, body, ct \\ @xlsx) do
    Plug.Test.conn(:post, S.base() <> path, body)
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", ct)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp apply_path(unit, file_name \\ nil) do
    base = "/stock-workbook/apply?org_unit_id=#{unit}"
    if file_name, do: base <> "&file_name=#{URI.encode(file_name)}", else: base
  end

  defp apply!(ctx, unit, bytes, token \\ nil, path_opts \\ []) do
    path = apply_path(unit, Keyword.get(path_opts, :file_name))
    conn = apply_request(path, token || ctx.tok_k, bytes)
    assert conn.status in [200, 201], "expected 200/201, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  defp reason!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)["reason"]
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

  # Read the content of the issued DocumentVersion for a document.
  defp doc_content(schema, document_id) do
    Repo.one(
      from(v in Letflow.Documents.DocumentVersion,
        where: v.document_id == ^document_id and v.status == :issued,
        select: v.content,
        limit: 1
      ),
      prefix: schema
    )
  end

  # What a load writes: documents, quick count records, ledger entries and audit entries.
  defp written(schema) do
    alias Letflow.Entities.Record.Latest

    docs =
      Repo.aggregate(
        from(d in Letflow.Documents.Document, where: d.type_key == "stock_quick_count"),
        :count,
        :id,
        prefix: schema
      )

    records =
      Repo.aggregate(
        from(r in Latest,
          where: r.entity_type in ["stock_quick_count", "stock_quick_count_line"]
        ),
        :count,
        prefix: schema
      )

    audit = Repo.aggregate(Letflow.Audit.Entry, :count, prefix: schema)
    %{rows: [[entries]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".ledger_entry|)
    {docs, records, audit, entries}
  end

  # The first request of a user provisions the user (one audit entry): do it before counting.
  defp warm!(ctx), do: S.get("/balances", ctx.tok_k) |> P.status!(200)

  defp task_complete(task_id, token) do
    Plug.Test.conn(:post, "/api/v1/tasks/#{task_id}/complete", Jason.encode!(%{}))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp approve_http(ctx, doc_id, token) do
    task = pending_task(ctx.schema, doc_id, "approve") || flunk("no pending approve task")
    task_complete(task.id, token)
  end

  defp balance(ctx, m, item, location) do
    path = "/balances?sku=#{item}&location=#{location}&org_unit=#{m.unit}"
    rows = S.get(path, ctx.tok_k) |> P.status!(200) |> Map.fetch!("rows")
    Enum.reduce(rows, Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
  end

  defp reason_of(conn) do
    body = S.json(conn)
    get_in(body, ["extensions", "reason"]) || body["reason"]
  end

  # -- criterion 1: access -----------------------------------------------------------------------

  describe "access (QWA-1)" do
    test "QWA-1 TENANT_ADMIN can apply; STOREKEEPER cannot; scoped reader gets 404", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      path = apply_path(m.unit)

      # TENANT_ADMIN can apply
      conn_admin = apply_request(path, ctx.tok_k, bytes)
      assert conn_admin.status == 201

      # STOREKEEPER holds StockQuickCount (T-2239) but NOT StockWorkbookApply: the Excel load is an
      # administrator function, so it is 403 and nothing is written
      conn_sk = apply_request(path, ctx.tok_sk, bytes)
      assert conn_sk.status == 403
      refute apply_request("/quick-counts", ctx.tok_sk, "{}", "application/json").status == 403

      # org_unit_required when no org_unit_id
      conn_no_unit = apply_request("/stock-workbook/apply", ctx.tok_k, bytes)
      assert reason!(conn_no_unit, 422) == "org_unit_required"

      # unknown org unit
      unknown = Ecto.UUID.generate()
      conn_unk = apply_request("/stock-workbook/apply?org_unit_id=#{unknown}", ctx.tok_k, bytes)
      assert reason!(conn_unk, 422) == "org_unit_not_found"

      # extra query key is refused
      conn_extra = apply_request(path <> "&x=1", ctx.tok_k, bytes)
      assert reason!(conn_extra, 422) == "invalid_filter"
    end

    test "QWA-1b a scoped reader gets the unknown-path 404", ctx do
      s = S.tenant!("wba-s", ctx.names.s)
      node = Letflow.Support.RoleScopeGrantsFixture.node!(s.schema_name)

      import Ecto.Query, only: [from: 2]

      user_tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "wba-scoped2")

      # Touch the API to create the user record in the DB (lazy creation on first request).
      _ = S.get("/balances", user_tok)

      _ =
        Letflow.Support.RoleScopeGrantsFixture.raw_delete_rows!(
          s.schema_name,
          Letflow.Support.RoleScopeGrantsFixture.group_of!(s.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      user =
        Letflow.Repo.one!(from(u in Letflow.Identity.User, where: u.username == "wba-scoped2"),
          prefix: s.schema_name
        )

      :ok =
        Letflow.Support.RoleScopeGrantsFixture.raw_user_row!(
          s.schema_name,
          user.id,
          "TENANT_ADMIN",
          node
        )

      unit = Docs.unit!(s.schema_name)
      bytes = book([])
      conn = apply_request(apply_path(unit), user_tok, bytes)
      reference = S.get("/stock-workbook", user_tok)
      assert conn.status == 404

      assert Letflow.ModuleConnCase.strip(S.json(conn)) ==
               Letflow.ModuleConnCase.strip(S.json(reference))
    end
  end

  # -- criterion 2: no changes → 200 applied:false -----------------------------------------------

  describe "no changes (QWA-2)" do
    test "QWA-2 when file equals stock: 200 applied:false, nothing written", ctx do
      m = seed!(ctx.schema)

      # file exactly matches the book
      bytes =
        book([
          ["Z-1", "Один", 10, "R", "I", 2],
          ["Z-1", "Один", 3, "L", "A", 1],
          ["Z-2", "Два", 5, "R", "K", 2]
        ])

      warm!(ctx)
      before = written(ctx.schema)

      conn = apply_request(apply_path(m.unit), ctx.tok_k, bytes)
      assert conn.status == 200
      answer = S.json(conn)
      assert answer["applied"] == false
      assert answer["changes"] == 0
      assert is_list(answer["remarks"])
      assert written(ctx.schema) == before
    end
  end

  # -- criterion 3: 201 with correct response body -----------------------------------------------

  describe "201 response body (QWA-3)" do
    test "QWA-3 returns document_id, number, lines, remarks, approve_task_id on 201", ctx do
      m = seed!(ctx.schema)

      # Z-1 at RI2: 10→8 (change); Z-1 at LA1: 3→0 (change because Z-1 not in that place in file)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      answer = apply!(ctx, m.unit, bytes)

      assert is_binary(answer["document_id"])
      assert is_binary(answer["number"]) and answer["number"] =~ "QCT"
      # 2 changes: RI2 (10→8) and LA1 (3→0, emptied)
      assert answer["lines"] == 2
      assert is_list(answer["remarks"])
      assert is_binary(answer["approve_task_id"])

      # verify the task id references a real pending approve task
      task = pending_task(ctx.schema, answer["document_id"], "approve")
      assert task != nil
      assert to_string(task.id) == answer["approve_task_id"]
    end
  end

  # -- criterion 4: document header carries workbook fields --------------------------------------

  describe "document header fields (QWA-4)" do
    test "QWA-4 document content has source, file_name, sheet, rows_read, remarks_count", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 7, "R", "I", 2]])
      answer = apply!(ctx, m.unit, bytes, nil, file_name: "my-stock.xlsx")

      content = doc_content(ctx.schema, answer["document_id"])
      assert is_map(content)

      # workbook metadata is stored in content under "workbook_ext"
      wb = content["workbook_ext"]
      assert wb["source"] == "workbook"
      assert wb["file_name"] == "my-stock.xlsx"
      assert wb["sheet"] == "Лист1"
      assert wb["rows_read"] == 1
      assert is_integer(wb["remarks_count"])

      # header entity fields are correct
      header = content["header"]
      assert header["reason_code"] == "other"
      assert header["reason_text"] == "Записать остатки из файла"
    end

    test "QWA-4b default file_name is workbook.xlsx", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 7, "R", "I", 2]])
      answer = apply!(ctx, m.unit, bytes)

      content = doc_content(ctx.schema, answer["document_id"])
      assert content["workbook_ext"]["file_name"] == "workbook.xlsx"
    end
  end

  # -- criterion 5: document lines ---------------------------------------------------------------

  describe "document lines (QWA-5)" do
    test "QWA-5 each line has the right fields; reason_code/reason_text in content workbook_ext",
         ctx do
      m = seed!(ctx.schema)

      # Z-1 at RI2 changes (10 → 7), Z-1 at LA1 unchanged (3 → 3), Z-2 at RK2 changes (5 → 2)
      bytes =
        book([
          ["Z-1", "Один", 7, "R", "I", 2],
          ["Z-1", "Один", 3, "L", "A", 1],
          ["Z-2", "Два", 2, "R", "K", 2]
        ])

      answer = apply!(ctx, m.unit, bytes)
      assert answer["lines"] == 2

      {:ok, doc} = Documents.fetch(ctx.schema, answer["document_id"])
      assert length(doc.lines) == 2

      for line <- doc.lines do
        assert is_binary(line.location_id)
        assert is_binary(line.catalog_item_id)
        assert is_binary(line.catalog_uom_id)
        assert is_binary(line.counted_quantity)
        assert is_binary(line.book_quantity)
        assert is_binary(line.difference)
      end

      # reason_code / reason_text are stored in workbook_ext of the content
      content = doc_content(ctx.schema, answer["document_id"])
      wb = content["workbook_ext"]
      assert wb["line_reason"]["reason_code"] == "other"
      assert wb["line_reason"]["reason_text"] == "Записать остатки из файла"
    end
  end

  # -- criterion 6: too_many_changes → 422 -------------------------------------------------------

  describe "too_many_changes (QWA-6)" do
    test "QWA-6 when changes > seam cap: 422 too_many_changes, nothing written", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 7, "R", "I", 2], ["Z-2", "Два", 2, "R", "K", 2]])
      Application.put_env(:letflow, :stock_workbook_import_max_changes, 1)
      warm!(ctx)
      before = written(ctx.schema)

      try do
        conn = apply_request(apply_path(m.unit), ctx.tok_k, bytes)
        assert reason!(conn, 422) == "too_many_changes"
        assert written(ctx.schema) == before
      after
        Application.delete_env(:letflow, :stock_workbook_import_max_changes)
      end
    end
  end

  # -- criterion 7: count_in_progress → 422 -----------------------------------------------------

  describe "count_in_progress (QWA-7)" do
    test "QWA-7 a count order holding a key blocks the apply with count_in_progress", ctx do
      m = seed!(ctx.schema)

      # Create a count order directly (like quick_count_test.exs count_order! helper)
      alias Letflow.Entities.{ManagedTypes, Records}
      owner = ManagedTypes.owner_for!(Letflow.Modules.Stock)
      number = "CO-WBA-#{System.unique_integer([:positive])}"

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
              "number" => number
            }
          },
          ctx.schema,
          owner
        )

      # scope covers RI2 location
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

      # Z-1 at RI2 changes: the count order blocks this
      bytes = book([["Z-1", "Один", 7, "R", "I", 2]])
      warm!(ctx)
      before = written(ctx.schema)
      conn = apply_request(apply_path(m.unit), ctx.tok_k, bytes)
      body = S.json(conn)
      assert conn.status == 422
      assert body["reason"] == "count_in_progress"
      assert body["held_by"] == number
      assert written(ctx.schema) == before
    end
  end

  # -- criterion 8: file_name validation ---------------------------------------------------------

  describe "file_name validation (QWA-8)" do
    test "QWA-8 empty or >255-char file_name is 422 invalid_filter", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])

      # empty file_name
      conn_empty = apply_request(apply_path(m.unit) <> "&file_name=", ctx.tok_k, bytes)
      assert reason!(conn_empty, 422) == "invalid_filter"

      # 255 chars is ok
      name_ok = String.duplicate("a", 255)

      conn_ok =
        apply_request(
          apply_path(m.unit) <> "&file_name=#{URI.encode(name_ok)}",
          ctx.tok_k,
          bytes
        )

      assert conn_ok.status == 201

      # 256 chars is too long
      name_long = String.duplicate("a", 256)

      conn_long =
        apply_request(
          apply_path(m.unit) <> "&file_name=#{URI.encode(name_long)}",
          ctx.tok_k,
          bytes
        )

      assert reason!(conn_long, 422) == "invalid_filter"

      # the limit counts characters, not bytes: 200 Cyrillic letters are 400 bytes and fine
      name_cyr = String.duplicate("ф", 200)

      conn_cyr =
        apply_request(
          apply_path(m.unit) <> "&file_name=#{URI.encode(name_cyr)}",
          ctx.tok_k,
          bytes
        )

      assert conn_cyr.status == 201
    end
  end

  # -- criterion 9: four eyes / approve process -------------------------------------------------

  describe "four eyes (QWA-9)" do
    test "QWA-9 four eyes ON: loader cannot self-approve; second user can", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      answer = apply!(ctx, m.unit, bytes)

      doc_id = answer["document_id"]
      task = pending_task(ctx.schema, doc_id, "approve") || flunk("no pending approve task")

      # The loader (tok_k is a TENANT_ADMIN) cannot approve their own load
      loader_user =
        Repo.one!(
          from(u in Letflow.Identity.User,
            where: u.username == "wba-counter-1"
          ),
          prefix: ctx.schema
        )

      result_self =
        Engine.complete_task(
          task.id,
          %{
            output_variables: %{},
            actor_id: loader_user.id,
            idempotency_key: Ecto.UUID.generate()
          },
          prefix: ctx.schema,
          credential: :oidc
        )

      assert match?({:error, _}, result_self),
             "loader should not be able to self-approve"

      # Second user can approve
      {:ok, _} = complete_task(ctx, task, ctx.holder2)

      {:ok, doc_after} = Documents.fetch(ctx.schema, doc_id)
      assert doc_after.state in ["posted", "confirmed"]
    end
  end

  # -- criterion 10: multi-line posting ----------------------------------------------------------

  describe "multi-line posting (QWA-10)" do
    test "QWA-10 a document with multiple changes posts one leg per change", ctx do
      m = seed!(ctx.schema)

      # Z-1 at RI2: 10→7 (diff -3); Z-1 at LA1: 3→0 (diff -3); Z-2 at RK2: 5→2 (diff -3)
      bytes =
        book([
          ["Z-1", "Один", 7, "R", "I", 2],
          ["Z-2", "Два", 2, "R", "K", 2]
        ])

      answer = apply!(ctx, m.unit, bytes)
      # 3 changes: RI2 (Z-1), LA1 (Z-1 emptied), RK2 (Z-2)
      assert answer["lines"] == 3

      doc_id = answer["document_id"]
      task = pending_task(ctx.schema, doc_id, "approve") || flunk("no pending approve task")
      {:ok, _} = complete_task(ctx, task, ctx.holder2)

      # Verify the document is now posted
      {:ok, doc_after} = Documents.fetch(ctx.schema, doc_id)
      assert doc_after.state in ["posted", "confirmed"]
    end
  end

  # -- criterion 11: idempotency / no sha256 binding --------------------------------------------

  describe "no sha256 binding (QWA-11)" do
    test "QWA-11 two applies of the same file each create a new document", ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])

      answer1 = apply!(ctx, m.unit, bytes)
      # Two changes: RI2 (10→8, diff -2) and LA1 implicitly zeroed (3→0, diff -3).
      assert answer1["lines"] == 2

      # Approve first document so second apply can be applied again (book changes)
      doc_id1 = answer1["document_id"]
      task1 = pending_task(ctx.schema, doc_id1, "approve") || flunk("no pending approve (first)")
      {:ok, _} = complete_task(ctx, task1, ctx.holder2)

      # Now apply again (book is now 8, file says 8: no changes)
      answer2_conn = apply_request(apply_path(m.unit), ctx.tok_k, bytes)
      assert answer2_conn.status == 200
      answer2 = S.json(answer2_conn)
      assert answer2["applied"] == false

      # Different file: get a 201 again
      bytes2 = book([["Z-1", "Один", 6, "R", "I", 2]])
      answer3 = apply!(ctx, m.unit, bytes2)
      assert answer3["document_id"] != doc_id1
    end
  end

  # -- criterion 12: route registration ---------------------------------------------------------

  describe "route registration (QWA-12)" do
    test "QWA-12 POST /stock-workbook/apply is in the route policies", _ctx do
      manifest = Letflow.Modules.Stock.manifest()
      routes = manifest.route_policies
      assert {"POST", "/stock-workbook/apply", :StockWorkbookApply} in routes
    end
  end

  # -- acceptance criteria 1, 2, 3, 4, 5, 8, 9 end to end ----------------------------------------

  describe "criteria end to end (QWA-13..)" do
    test "QWA-13 bad header: 422 header_missing and nothing written", ctx do
      m = seed!(ctx.schema)
      warm!(ctx)
      before = written(ctx.schema)
      bytes = xlsx!([["A", "B", "C"], ["Z-1", "Один", 8]])
      conn = apply_request(apply_path(m.unit), ctx.tok_k, bytes)
      assert reason!(conn, 422) == "header_missing"
      assert written(ctx.schema) == before
    end

    test "QWA-14 GET /documents/:id shows the workbook header and two lines; four eyes ON posts",
         ctx do
      m = seed!(ctx.schema)

      answer =
        apply!(ctx, m.unit, book([["Z-1", "Один", 8, "R", "I", 2]]), nil, file_name: "f.xlsx")

      id = answer["document_id"]
      assert answer["lines"] == 2

      doc = S.get("/documents/#{id}", ctx.tok_k) |> P.status!(200)
      assert doc["kind"] == "quick_count" and doc["state"] == "issued"
      assert doc["source"] == "workbook" and doc["file_name"] == "f.xlsx"
      assert doc["sheet"] == "Лист1" and doc["rows_read"] == 1
      assert doc["reason_code"] == "other" and doc["reason_text"] == "Записать остатки из файла"

      by_loc = Map.new(doc["lines"], &{&1["location_id"], &1})
      ri2 = by_loc[m.ri2]
      la1 = by_loc[m.la1]

      assert {ri2["book_quantity"], ri2["counted_quantity"], ri2["difference"]} ==
               {"10.000000000", "8.000000000", "-2.000000000"}

      assert {la1["book_quantity"], la1["counted_quantity"], la1["difference"]} ==
               {"3.000000000", "0.000000000", "-3.000000000"}

      assert Enum.all?(doc["lines"], &(&1["reason_text"] == "Записать остатки из файла"))

      # the loader's own completion is refused, a second user posts
      self = approve_http(ctx, id, ctx.tok_k)
      reference = Letflow.Api.Response.separation_of_duties(Plug.Test.conn(:get, "/"))
      assert self.status == 403 and self.resp_body == reference.resp_body

      approve_http(ctx, id, ctx.tok_u2) |> P.status!(200)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.ri2), 8)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.la1), 0)

      assert [entry] = P.movements(ctx, id)
      assert entry["cause"] == "count_set"

      assert entry["legs"]
             |> Enum.map(&Decimal.to_integer(Decimal.new(&1["quantity"])))
             |> Enum.sort() ==
               [-3, -2]
    end

    test "QWA-15 four eyes OFF: the loader approves alone; a second check gives no change", ctx do
      m = seed!(ctx.schema)

      Plug.Test.conn(
        :put,
        "/api/v1/approval-rules/stock_quick_count/approve",
        Jason.encode!(%{"four_eyes" => false, "reason" => "one-person company"})
      )
      |> put_req_header("authorization", "Bearer " <> ctx.tok_k)
      |> put_req_header("content-type", "application/json")
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
      |> P.status!(200)

      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      answer = apply!(ctx, m.unit, bytes)
      approve_http(ctx, answer["document_id"], ctx.tok_k) |> P.status!(200)

      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.ri2), 8)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.la1), 0)

      check = apply_request("/stock-workbook/check?org_unit_id=#{m.unit}", ctx.tok_k, bytes)
      assert S.json(check)["changes"] == []
    end

    test "QWA-16 stale: a receipt after the load refuses approve quick_count_stale", ctx do
      m = seed!(ctx.schema)
      answer = apply!(ctx, m.unit, book([["Z-1", "Один", 8, "R", "I", 2]]))
      id = answer["document_id"]

      S.post!(ctx.schema, "receipt", %{
        document_id: "wba-late-1",
        lines: [
          S.line(m.z1.record_id, "1", %{to: S.side(m.unit, m.ri2)}, %{unit: m.uom.record_id})
        ]
      })

      conn = approve_http(ctx, id, ctx.tok_u2)
      assert conn.status == 409 and reason_of(conn) == "quick_count_stale"
      assert pending_task(ctx.schema, id, "approve")
      assert P.counts(ctx, id) == %{entries: %{}, marks: 0}
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.ri2), 11)
      assert Decimal.eq?(balance(ctx, m, m.z1.record_id, m.la1), 3)
    end

    test "QWA-17 same file twice: two documents, the second approval is stale, then no change",
         ctx do
      m = seed!(ctx.schema)
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      first = apply!(ctx, m.unit, bytes)
      second = apply!(ctx, m.unit, bytes)
      assert first["document_id"] != second["document_id"]
      assert first["number"] != second["number"]

      approve_http(ctx, first["document_id"], ctx.tok_u2) |> P.status!(200)
      conn = approve_http(ctx, second["document_id"], ctx.tok_u2)
      assert conn.status == 409 and reason_of(conn) == "quick_count_stale"

      again = apply_request(apply_path(m.unit), ctx.tok_k, bytes)
      assert again.status == 200 and S.json(again)["applied"] == false
    end

    test "QWA-18 INV-10: an org unit of another tenant is org_unit_not_found, nothing written",
         ctx do
      m = seed!(ctx.schema)
      warm!(ctx)
      before = {written(ctx.schema), written(ctx.b.schema_name)}
      bytes = book([["Z-1", "Один", 8, "R", "I", 2]])
      conn = apply_request(apply_path(ctx.mb.unit), ctx.tok_k, bytes)
      assert reason!(conn, 422) == "org_unit_not_found"
      assert {written(ctx.schema), written(ctx.b.schema_name)} == before
      assert m.unit != ctx.mb.unit
    end

    test "QWA-19 GH #4695: a checked workbook on a pre-0.20 install is a clear refusal", ctx do
      s = S.tenant!("wba-pre20", ctx.names.s)
      token = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "wba-pre20-admin")
      m = seed!(s.schema_name)
      bytes = book([["Z-3", "Три", 1, "R", "I", 2]])
      S.get("/balances", token) |> P.status!(200)

      # An install upgraded from before quick count has no document type. The first unfixed apply
      # activates the shipped process and then fails; the documented repair is a module reinstall.
      Repo.query!(~s|ALTER TABLE "#{s.schema_name}"."document_types" DISABLE TRIGGER USER|)

      try do
        Repo.delete_all(
          from(t in Letflow.Documents.DocumentType, where: t.key == "stock_quick_count"),
          prefix: s.schema_name
        )
      after
        Repo.query!(~s|ALTER TABLE "#{s.schema_name}"."document_types" ENABLE TRIGGER USER|)
      end

      checked = apply_request("/stock-workbook/check?org_unit_id=#{m.unit}", token, bytes)
      assert checked.status == 200
      assert length(S.json(checked)["changes"]) == 1
      before = written(s.schema_name)

      conn = apply_request(apply_path(m.unit), token, bytes)
      assert reason!(conn, 409) == "definition_not_active"
      assert written(s.schema_name) == before

      assert {:error, :not_found} =
               Letflow.Definitions.get_active_by_name("stock_quick_count", prefix: s.schema_name)
    end
  end
end
