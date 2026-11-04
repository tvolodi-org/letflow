Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.DocumentsRouterTest do
  @moduledoc """
  REQ-712 / GH #3749 criteria 3, 4, 7 and 8: the six document routes of module `stock` through the full
  `Letflow.Router` with real OIDC bearer tokens, on committed tenants (Sandbox `:auto`, `async: false`).
  Tests: A-RT-1..11 (save, replace, discard, the shape reasons), A-RD-1..3 (list, cursor, key sets),
  A-IS-1..4 (issue binding), A-TEN-1..4 (tenancy and refusals), A-ET-1..3 (event time window).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Documents.DocumentVersion
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  setup do
    ctx = S.setup_oidc!([:a, :b, :s, :c])
    a = S.tenant!("stk-da", ctx.names.a)
    b = S.tenant!("stk-db", ctx.names.b)

    on_exit(fn -> Application.delete_env(:letflow, :stock_documents_clock) end)

    Map.merge(ctx, %{
      a: a,
      b: b,
      ma: D.masters!(a.schema_name),
      mb: D.masters!(b.schema_name),
      tok_a: S.token(ctx, :a, ["TENANT_ADMIN"]),
      tok_b: S.token(ctx, :b, ["TENANT_ADMIN"])
    })
  end

  defp strip(body), do: Map.delete(body, "trace_id")

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    if conn.resp_body == "", do: nil, else: S.json(conn)
  end

  defp save!(ctx, body \\ nil) do
    D.request(:post, "/documents", ctx.tok_a, body || D.body(ctx.ma)) |> status!(201)
  end

  defp reason(conn, status), do: conn |> status!(status) |> Map.fetch!("reason")

  defp fixed_clock(iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    Application.put_env(:letflow, :stock_documents_clock, fn -> at end)
    at
  end

  describe "save, replace, discard" do
    test "A-RT-1 POST creates the header, the lines and the draft", ctx do
      doc = save!(ctx)

      assert doc["kind"] == "receipt" and doc["state"] == "draft"
      assert doc["number"] == nil and doc["issued_at"] == nil
      assert doc["org_unit_id"] == ctx.ma.unit and doc["note"] == "delivery"

      assert [
               %{"line_no" => 1, "quantity" => "10.500000000"},
               %{"line_no" => 2, "catalog_lot_id" => nil}
             ] =
               doc["lines"]

      version =
        Letflow.Repo.one!(from(v in DocumentVersion, where: v.document_id == ^doc["id"]),
          prefix: ctx.a.schema_name
        )

      assert version.status == :draft
      assert version.content["header"]["location_id"] == ctx.ma.location
      assert version.content["lines"] |> Enum.map(& &1["line_no"]) == [1, 2]
      assert Enum.at(version.content["lines"], 0)["quantity"] == "10.500000000"

      assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> status!(200) == doc
    end

    test "A-RT-2 PUT replaces the whole draft: a line out, a line in, an optional key removed",
         ctx do
      doc = save!(ctx)
      line1 = Enum.at(doc["lines"], 0)

      body =
        ctx.ma
        |> D.body()
        |> Map.delete("counterparty_id")
        |> Map.put("note", "changed")
        |> Map.put("lines", [
          %{
            "catalog_item_id" => ctx.ma.item,
            "catalog_uom_id" => ctx.ma.uom,
            "quantity" => "7"
          }
        ])

      new = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, body) |> status!(200)
      assert new["note"] == "changed" and new["counterparty_id"] == nil

      assert [%{"line_no" => 1, "quantity" => "7.000000000", "catalog_lot_id" => nil} = l] =
               new["lines"]

      assert l["line_id"] == line1["line_id"]

      version =
        Letflow.Repo.one!(from(v in DocumentVersion, where: v.document_id == ^doc["id"]),
          prefix: ctx.a.schema_name
        )

      assert length(version.content["lines"]) == 1
      refute Map.has_key?(version.content["header"], "counterparty_id")

      three = Map.put(body, "lines", List.duplicate(hd(body["lines"]), 3))
      again = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, three) |> status!(200)
      assert Enum.map(again["lines"], & &1["line_no"]) == [1, 2, 3]
    end

    test "A-RT-3 DELETE discards the draft and soft-deletes header and lines", ctx do
      doc = save!(ctx)
      assert D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_a) |> status!(204) == nil
      assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> status!(404)

      live =
        Letflow.Repo.aggregate(
          from(r in Letflow.Entities.Record.Latest,
            where: r.entity_type in ["stock_receipt", "stock_receipt_line"] and not r.deleted
          ),
          :count,
          prefix: ctx.a.schema_name
        )

      assert live == 0
      assert D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_a) |> status!(404)
    end

    test "A-RT-4..10 each shape reason answers 422 and writes nothing", ctx do
      before = D.counts(ctx.a.schema_name)
      m = ctx.ma
      line = %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => "1"}

      cases = [
        {"unknown_kind", D.body(m, nil, %{"kind" => "issue"})},
        {"unknown_kind", D.body(m, nil, %{"kind" => 1})},
        {"field_required", Map.delete(D.body(m), "kind")},
        {"field_not_allowed", D.body(m, nil, %{"document_id" => Ecto.UUID.generate()})},
        {"field_not_allowed", D.body(m, nil, %{"number" => "RCP-1"})},
        {"field_not_allowed", D.body(m, nil, %{"state" => "issued"})},
        {"field_not_allowed", D.body(m, nil, %{"lines" => [Map.put(line, "line_no", 3)]})},
        {"field_required", Map.delete(D.body(m), "location_id")},
        {"field_required", D.body(m, nil, %{"lines" => [Map.delete(line, "catalog_uom_id")]})},
        {"field_invalid", D.body(m, nil, %{"location_id" => "not-a-uuid"})},
        {"field_invalid", D.body(m, nil, %{"note" => String.duplicate("x", 501)})},
        {"field_invalid", D.body(m, nil, %{"responsible_id" => 5})},
        {"event_time_invalid", D.body(m, "2026-11-04")},
        {"event_time_invalid", D.body(m, "2026-11-04T10:00:00")},
        {"event_time_invalid", D.body(m, "garbage")},
        {"lines_count", D.body(m, nil, %{"lines" => []})},
        {"lines_count", D.body(m, nil, %{"lines" => List.duplicate(line, 101)})},
        {"quantity_invalid", D.body(m, nil, %{"lines" => [%{line | "quantity" => "abc"}]})},
        {"quantity_invalid", D.body(m, nil, %{"lines" => [%{line | "quantity" => "0"}]})},
        {"quantity_invalid", D.body(m, nil, %{"lines" => [%{line | "quantity" => "-1"}]})},
        {"quantity_invalid",
         D.body(m, nil, %{"lines" => [%{line | "quantity" => "1.0000000001"}]})},
        {"quantity_invalid", D.body(m, nil, %{"lines" => [%{line | "quantity" => 1}]})},
        {"quantity_invalid", D.body(m, nil, %{"lines" => [%{line | "quantity" => 1.5}]})},
        {"org_unit_invalid", D.body(m, nil, %{"org_unit_id" => Ecto.UUID.generate()})}
      ]

      for {expected, body} <- cases do
        conn = D.request(:post, "/documents", ctx.tok_a, body)
        assert reason(conn, 422) == expected, inspect(body)
      end

      body =
        conn_body(
          D.request(
            :post,
            "/documents",
            ctx.tok_a,
            D.body(m, nil, %{"lines" => [%{line | "quantity" => "0"}, line]})
          )
        )

      assert body["line_no"] == 1

      body = conn_body(D.request(:post, "/documents", ctx.tok_a, D.body(m, nil, %{"x" => 1})))
      assert body["field"] == "x"

      assert D.counts(ctx.a.schema_name) == before
    end

    test "A-RT-4b a body that is not an object and a nine-decimal quantity", ctx do
      conn = D.request(:post, "/documents", ctx.tok_a, [1, 2])
      assert reason(conn, 422) == "field_invalid"

      ok =
        D.body(ctx.ma, nil, %{
          "lines" => [
            %{
              "catalog_item_id" => ctx.ma.item,
              "catalog_uom_id" => ctx.ma.uom,
              "quantity" => "0.000000001"
            }
          ]
        })

      assert save!(ctx, ok)["lines"] |> hd() |> Map.get("quantity") == "0.000000001"
    end

    test "A-RT-11 PUT and DELETE on an issued document are 409 and change nothing", ctx do
      doc = save!(ctx)
      issued = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> status!(200)

      other = D.body(ctx.ma, nil, %{"note" => "late edit"})

      assert reason(D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, other), 409) ==
               "document_not_draft"

      assert reason(D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_a), 409) ==
               "document_not_draft"

      assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> status!(200) == issued
    end

    test "A-RT-12 PUT cannot change the kind or the org unit", ctx do
      doc = save!(ctx)

      assert reason(
               D.request(
                 :put,
                 "/documents/#{doc["id"]}",
                 ctx.tok_a,
                 D.body(ctx.ma, nil, %{"kind" => "issue"})
               ),
               422
             ) ==
               "unknown_kind"

      body = D.body(ctx.ma, nil, %{"org_unit_id" => Ecto.UUID.generate()})

      assert reason(D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, body), 422) ==
               "field_invalid"
    end
  end

  defp conn_body(conn), do: S.json(conn)

  defp send_with_slug(method, path, token, body, slug) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, S.base() <> path)
        body -> Plug.Test.conn(method, S.base() <> path, Jason.encode!(body))
      end

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-tenant-slug", slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  describe "reads" do
    test "A-RD-1 list newest first, cursor round trip, filters", ctx do
      ids = for _ <- 1..3, do: save!(ctx)["id"]
      D.request(:post, "/documents/#{List.last(ids)}/issue", ctx.tok_a)

      all = D.request(:get, "/documents", ctx.tok_a) |> status!(200)
      assert Enum.map(all["rows"], & &1["id"]) == Enum.reverse(ids)
      assert all["next_cursor"] == nil

      p1 = D.request(:get, "/documents?limit=2", ctx.tok_a) |> status!(200)
      assert length(p1["rows"]) == 2 and is_binary(p1["next_cursor"])
      assert p1["next_cursor"] =~ ~r/\A\d+\.[0-9a-f-]{36}\z/

      p2 =
        D.request(:get, "/documents?limit=2&cursor=#{p1["next_cursor"]}", ctx.tok_a)
        |> status!(200)

      assert Enum.map(p1["rows"] ++ p2["rows"], & &1["id"]) == Enum.reverse(ids)
      assert p2["next_cursor"] == nil

      issued = D.request(:get, "/documents?state=issued", ctx.tok_a) |> status!(200)
      assert Enum.map(issued["rows"], & &1["id"]) == [List.last(ids)]
      drafts = D.request(:get, "/documents?state=draft&kind=receipt", ctx.tok_a) |> status!(200)
      assert length(drafts["rows"]) == 2

      by_unit =
        D.request(:get, "/documents?org_unit_id=#{ctx.ma.unit}", ctx.tok_a) |> status!(200)

      assert length(by_unit["rows"]) == 3

      none =
        D.request(:get, "/documents?org_unit_id=#{Ecto.UUID.generate()}", ctx.tok_a)
        |> status!(200)

      assert none["rows"] == []
    end

    test "A-RD-2 invalid filters are 422 invalid_filter", ctx do
      for q <- [
            "x=1",
            "tenant_id=#{ctx.ma.unit}",
            "limit=0",
            "limit=101",
            "limit=abc",
            "state=posted",
            "kind=issue",
            "org_unit_id=nope",
            "cursor=garbage",
            "cursor=1.not-a-uuid",
            "state[]=draft",
            "limit=1&limit=2"
          ] do
        assert reason(D.request(:get, "/documents?" <> q, ctx.tok_a), 422) == "invalid_filter", q
      end
    end

    test "A-RD-3 the exact key sets of a list row, a document and a line", ctx do
      doc = save!(ctx)
      D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)

      assert doc |> Map.keys() |> Enum.sort() ==
               ~w(counterparty_id event_time header_id id issued_at kind lines location_id note number org_unit_id responsible_id state)

      assert doc["lines"] |> hd() |> Map.keys() |> Enum.sort() ==
               ~w(catalog_item_id catalog_lot_id catalog_uom_id line_id line_no quantity)

      [row] = (D.request(:get, "/documents", ctx.tok_a) |> status!(200))["rows"]

      assert row |> Map.keys() |> Enum.sort() ==
               ~w(event_time id issued_at kind number org_unit_id state)
    end
  end

  describe "issue" do
    test "A-IS-1 issue copies the saved content, takes number 1 and answers the issued document",
         ctx do
      doc = save!(ctx)
      issued = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> status!(200)

      assert issued["state"] == "issued"
      assert issued["number"] == "RCP-#{Date.utc_today().year}-000001"
      assert is_binary(issued["issued_at"])

      assert Map.drop(issued, ["state", "number", "issued_at"]) ==
               Map.drop(doc, ["state", "number", "issued_at"])

      version =
        Letflow.Repo.one!(from(v in DocumentVersion, where: v.document_id == ^doc["id"]),
          prefix: ctx.a.schema_name
        )

      assert version.status == :issued and is_binary(version.content_hash)
      header = version.content["header"]

      for {key, value} <-
            Map.take(issued, ~w(org_unit_id location_id responsible_id counterparty_id note)) do
        assert header[key] == value, key
      end

      assert header["event_time"] == issued["event_time"]

      assert Enum.map(
               version.content["lines"],
               &Map.take(&1, ~w(line_no quantity catalog_item_id))
             ) ==
               Enum.map(issued["lines"], &Map.take(&1, ~w(line_no quantity catalog_item_id)))
    end

    test "A-IS-2 a second issue is 409 document_not_draft and unknown ids are 404", ctx do
      doc = save!(ctx)
      D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> status!(200)
      conn = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)
      assert reason(conn, 409) == "document_not_draft"

      assert D.request(:post, "/documents/#{Ecto.UUID.generate()}/issue", ctx.tok_a)
             |> status!(404)
    end

    test "A-IS-3 a busy document service answers 503 busy and the document stays a draft", ctx do
      doc = save!(ctx)
      test_pid = self()

      # A second connection holds the row lock; the issue's own lock_timeout (2 s) refuses.
      task =
        Task.async(fn ->
          Letflow.Repo.transaction(fn ->
            Letflow.Repo.query!(
              "SELECT 1 FROM #{ctx.a.schema_name}.documents WHERE id = $1 FOR UPDATE",
              [Ecto.UUID.dump!(doc["id"])]
            )

            send(test_pid, :locked)

            receive do
              :release -> :ok
            after
              15_000 -> :ok
            end
          end)
        end)

      assert_receive :locked, 5_000
      conn = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)
      send(task.pid, :release)
      Task.await(task, 20_000)

      assert reason(conn, 503) == "busy"

      assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a)
             |> status!(200)
             |> Map.get("state") == "draft"
    end
  end

  describe "event time" do
    test "A-ET-1 the window boundaries: 96 h and 5 min accepted, one second beyond refused",
         ctx do
      now = fixed_clock("2026-11-04T12:00:00Z")
      iso = fn secs -> now |> DateTime.add(secs, :second) |> DateTime.to_iso8601() end

      cases = [
        {-96 * 3600, :ok},
        {-96 * 3600 - 1, "event_time_too_old"},
        {300, :ok},
        {301, "event_time_in_future"}
      ]

      for {delta, expected} <- cases do
        doc = save!(ctx, D.body(ctx.ma, iso.(delta)))
        conn = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)

        case expected do
          :ok -> status!(conn, 200)
          reason -> assert reason(conn, 422) == reason
        end
      end
    end

    test "A-ET-2 the stored time is UTC whatever the offset", ctx do
      doc = save!(ctx, D.body(ctx.ma, "2026-11-04T17:30:15+05:00"))
      assert doc["event_time"] == "2026-11-04T12:30:15Z"
    end

    test "A-ET-3 an out-of-window draft can be corrected by PUT and then issues", ctx do
      now = fixed_clock("2026-11-04T12:00:00Z")
      doc = save!(ctx, D.body(ctx.ma, "2026-10-01T00:00:00Z"))
      conn = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)
      assert reason(conn, 422) == "event_time_too_old"

      fixed = D.body(ctx.ma, DateTime.to_iso8601(now))
      D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, fixed) |> status!(200)
      D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> status!(200)
    end
  end

  describe "tenancy and refusals" do
    test "A-TEN-1 an API token and a scoped admin get the no-module 404 on every route", ctx do
      doc = save!(ctx)
      S.tenant!("stk-dref", ctx.names.c, install: false)
      ref_tok = S.token(ctx, :c, ["TENANT_ADMIN"], sub: "ref-admin")
      reference = D.request(:get, "/documents", ref_tok) |> status!(404) |> strip()

      user = TokenMintFixture.role_holder!(ctx.a.schema_name, ["TENANT_ADMIN"])

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: ctx.a.schema_name
        )

      slug = Letflow.Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug

      s = S.tenant!("stk-ds", ctx.names.s)
      scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-writer")
      D.request(:get, "/documents", scoped) |> status!(200)

      scoped_user =
        Letflow.Repo.one!(from(u in User, where: u.username == "scoped-writer"),
          prefix: s.schema_name
        )

      _ =
        RSG.raw_delete_rows!(
          s.schema_name,
          RSG.group_of!(s.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      :ok =
        RSG.raw_user_row!(s.schema_name, scoped_user.id, "TENANT_ADMIN", RSG.node!(s.schema_name))

      id = doc["id"]

      routes = [
        {:post, "/documents", D.body(ctx.ma)},
        {:put, "/documents/#{id}", D.body(ctx.ma)},
        {:delete, "/documents/#{id}", nil},
        {:post, "/documents/#{id}/issue", nil},
        {:get, "/documents", nil},
        {:get, "/documents/#{id}", nil}
      ]

      for {method, path, body} <- routes do
        conn = send_with_slug(method, path, plaintext, body, slug)
        assert conn.status == 404, "token #{method} #{path}: #{conn.status}"
        assert strip(S.json(conn)) == reference

        conn = D.request(method, path, scoped, body)
        assert conn.status == 404, "scoped #{method} #{path}: #{conn.status}"
        assert strip(S.json(conn)) == reference
      end

      assert D.request(:get, "/documents/#{id}", ctx.tok_a) |> status!(200) |> Map.get("state") ==
               "draft"
    end

    test "A-TEN-2 a TASK_WORKER is forbidden on every route and nothing is written", ctx do
      doc = save!(ctx)
      before = D.counts(ctx.a.schema_name)
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")
      id = doc["id"]

      for {method, path, body} <- [
            {:post, "/documents", D.body(ctx.ma)},
            {:put, "/documents/#{id}", D.body(ctx.ma)},
            {:delete, "/documents/#{id}", nil},
            {:post, "/documents/#{id}/issue", nil},
            {:get, "/documents", nil},
            {:get, "/documents/#{id}", nil}
          ] do
        body = D.request(method, path, tok, body) |> status!(403)
        assert body["title"] == "Forbidden" and body["detail"] == "insufficient permissions"
      end

      assert D.counts(ctx.a.schema_name) == before
    end

    test "A-TEN-3 another tenant's id, a malformed id and an unknown id give one 404 body", ctx do
      doc = save!(ctx)

      other =
        D.request(:get, "/documents/#{Ecto.UUID.generate()}", ctx.tok_a)
        |> status!(404)
        |> strip()

      for id <- [doc["id"], "not-a-uuid", "123", Ecto.UUID.generate()],
          {method, suffix, body} <- [
            {:get, "", nil},
            {:put, "", D.body(ctx.mb)},
            {:delete, "", nil},
            {:post, "/issue", nil}
          ] do
        conn = D.request(method, "/documents/#{id}" <> suffix, ctx.tok_b, body)
        assert conn.status == 404, "#{method} #{id}#{suffix}"
        assert strip(S.json(conn)) == other
      end
    end

    test "A-TEN-4 B cannot read, change or issue A's document; B's list is empty", ctx do
      doc = save!(ctx)
      before = D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> status!(200)

      D.request(:put, "/documents/#{doc["id"]}", ctx.tok_b, D.body(ctx.mb)) |> status!(404)
      D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_b) |> status!(404)
      D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_b) |> status!(404)
      assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> status!(200) == before

      assert (D.request(:get, "/documents", ctx.tok_b) |> status!(200))["rows"] == []
      by_a = D.request(:get, "/documents?org_unit_id=#{ctx.ma.unit}", ctx.tok_b) |> status!(200)
      assert by_a["rows"] == []

      mine = D.request(:post, "/documents", ctx.tok_b, D.body(ctx.mb)) |> status!(201)
      assert mine["id"] != doc["id"]

      assert D.request(:post, "/documents", ctx.tok_b, D.body(ctx.ma)) |> reason(422) ==
               "org_unit_invalid"
    end
  end
end
