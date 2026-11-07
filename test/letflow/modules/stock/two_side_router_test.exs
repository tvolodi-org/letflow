Code.require_file("two_side_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.TwoSideRouterTest do
  @moduledoc """
  REQ-721 / GH #3770 criteria 2 and 7: save, replace, discard and the shape refusals of transfer,
  hand over and return through the full `Letflow.Router`, the filing unit, and the tenancy and role
  refusals on the document routes. Committed tenants, Sandbox `:auto`, `async: false`.
  Tests: SAV-1..10, SCP-1, SCP-2, TEN-1..4.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  @types ~w(stock_transfer stock_transfer_line stock_handover stock_handover_line stock_return stock_return_line)
  @transfer_keys ~w(from_location_id from_responsible_id to_location_id to_org_unit_id to_responsible_id)
  @return_keys ~w(from_location_id from_org_unit_id from_responsible_id to_location_id to_responsible_id)

  setup do
    ctx = P.setup!([:a, :b, :s, :c])
    b = S.tenant!("stk-2sb", ctx.names.b)

    Map.merge(ctx, %{
      mb: D.masters!(b.schema_name),
      b: b,
      tok_b: S.token(ctx, :b, ["TENANT_ADMIN"]),
      m2: T.b2!(ctx)
    })
  end

  defp strip(body), do: Map.delete(body, "trace_id")

  defp counts(ctx) do
    records =
      Letflow.Repo.aggregate(from(r in Latest, where: r.entity_type in ^@types), :count,
        prefix: ctx.schema
      )

    {records, Letflow.Repo.aggregate(Letflow.Documents.Document, :count, :id, prefix: ctx.schema)}
  end

  defp body(ctx, kind, extra \\ %{}), do: T.body(kind, ctx.ma, ctx.ma, ctx.m2, extra)

  defp create(ctx, body), do: D.request(:post, "/documents", ctx.tok_a, body)

  defp reason(conn, status), do: conn |> P.status!(status) |> Map.fetch!("reason")

  describe "save, replace, discard" do
    test "SAV-1..3 per kind: create 201 with the exact key set, replace, discard", ctx do
      for kind <- T.kinds() do
        doc = create(ctx, body(ctx, kind)) |> P.status!(201)
        sides = if kind == "return", do: @return_keys, else: @transfer_keys

        assert doc |> Map.keys() |> Enum.sort() ==
                 Enum.sort(
                   ~w(id kind state number issued_at header_id org_unit_id event_time note lines) ++
                     sides ++
                     ~w(posted_at posted_by posted_by_label entry_id reversed_at reversed_by reversed_by_label posting_check)
                 )

        assert doc["kind"] == kind and doc["state"] == "draft" and doc["number"] == nil
        assert length(doc["lines"]) == 2

        # replace: a line out, the note removed
        replaced =
          D.request(
            :put,
            "/documents/#{doc["id"]}",
            ctx.tok_a,
            body(ctx, kind, %{"lines" => [hd(T.lines(ctx.ma, "9"))]}) |> Map.delete("note")
          )
          |> P.status!(200)

        assert [%{"quantity" => "9.000000000"}] = replaced["lines"]
        assert replaced["note"] == nil

        D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_a) |> P.status!(204)
        D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> P.status!(404)
      end
    end

    test "SAV-4..6 equal sides: 422 sides_equal and nothing written", ctx do
      before = counts(ctx)
      m = ctx.ma

      for kind <- T.kinds() do
        assert create(ctx, T.body(kind, m, m, m)) |> reason(422) == "sides_equal"
      end

      # a replace to equal sides is refused too, the draft is unchanged
      doc = create(ctx, body(ctx, "transfer")) |> P.status!(201)
      mid = counts(ctx)

      assert D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, T.body("transfer", m, m, m))
             |> reason(422) == "sides_equal"

      assert counts(ctx) == mid and mid != before
      assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> P.status!(200) == doc
    end

    test "SAV-7 sides that differ in one key only are accepted", ctx do
      m = ctx.ma
      # same unit and location, another employee (hand over between two people)
      other = %{m | employee: ctx.m2.employee}
      assert create(ctx, T.body("hand_over", m, m, other)) |> P.status!(201)
      # same employee and unit, another location
      other = %{m | location: ctx.m2.location}
      assert create(ctx, T.body("transfer", m, m, other)) |> P.status!(201)
      # same location and employee, another unit
      other = %{m | unit: ctx.m2.unit}
      assert create(ctx, T.body("transfer", m, m, other)) |> P.status!(201)
    end

    test "SAV-8..10 keys of another kind: 422 field_not_allowed with the field", ctx do
      for kind <- T.kinds(),
          field <- ~w(unit_price line_value reason_code counterparty_id received_on) do
        conn = create(ctx, body(ctx, kind, %{field => "x"}))
        assert %{"reason" => "field_not_allowed", "field" => ^field} = P.status!(conn, 422)
      end

      for kind <- ["transfer", "hand_over"] do
        conn = create(ctx, body(ctx, kind, %{"location_id" => ctx.ma.location}))
        assert %{"reason" => "field_not_allowed", "field" => "location_id"} = P.status!(conn, 422)
      end

      assert create(ctx, body(ctx, "return") |> Map.delete("from_org_unit_id"))
             |> reason(422) == "field_required"

      assert create(ctx, body(ctx, "transfer", %{"to_location_id" => "nope"})) |> reason(422) ==
               "field_invalid"
    end
  end

  describe "scope and tenancy" do
    test "SCP-1 SCP-2 lines carry the filing unit and the other unit sees nothing", ctx do
      for kind <- T.kinds() do
        doc = create(ctx, body(ctx, kind)) |> P.status!(201)

        # transfer, hand over: filed under the from unit (ma); return: under the unit it goes back to
        # (the `to` side of the body, ctx.m2)
        expected = if kind == "return", do: ctx.m2.unit, else: ctx.ma.unit
        expected = if kind == "return", do: ctx.m2.unit, else: expected
        assert doc["org_unit_id"] == expected
        spec = Letflow.Modules.Stock.Documents.Kinds.get(kind)

        records =
          Letflow.Repo.all(
            from(r in Latest,
              where: r.entity_type in [^spec.type_key, ^spec.line_type] and not r.deleted,
              select: {r.entity_type, fragment("?->>'org_unit_id'", r.field_values)}
            ),
            prefix: ctx.schema
          )

        assert length(records) == 3
        assert Enum.all?(records, fn {_type, unit} -> unit == expected end)

        other = if expected == ctx.ma.unit, do: ctx.m2.unit, else: ctx.ma.unit

        rows =
          D.request(:get, "/documents?kind=#{kind}&org_unit_id=#{other}", ctx.tok_a)
          |> P.status!(200)
          |> Map.fetch!("rows")

        assert rows == []

        rows =
          D.request(:get, "/documents?kind=#{kind}&org_unit_id=#{expected}", ctx.tok_a)
          |> P.status!(200)
          |> Map.fetch!("rows")

        assert [%{"id" => id, "kind" => ^kind}] = rows
        assert id == doc["id"]
      end

      all = D.request(:get, "/documents", ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")
      assert all |> Enum.map(& &1["kind"]) |> Enum.sort() == ["hand_over", "return", "transfer"]

      assert D.request(:get, "/documents?kind=loan", ctx.tok_a) |> reason(422) ==
               "invalid_filter"
    end

    test "TEN-1 an API token and a scoped admin get the no-module 404 on every route", ctx do
      doc = create(ctx, body(ctx, "transfer")) |> P.status!(201)
      S.tenant!("stk-2sref", ctx.names.c, install: false)
      ref_tok = S.token(ctx, :c, ["TENANT_ADMIN"], sub: "ref-admin")
      reference = D.request(:get, "/documents", ref_tok) |> P.status!(404) |> strip()

      user = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: ctx.schema
        )

      slug = Letflow.Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug
      s = S.tenant!("stk-2ss", ctx.names.s)
      scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-writer")
      D.request(:get, "/documents", scoped) |> P.status!(200)

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

      for {method, path, req_body} <- routes(ctx, id) do
        conn = with_slug(method, path, plaintext, req_body, slug)
        assert conn.status == 404, "token #{method} #{path}: #{conn.status}"
        assert strip(S.json(conn)) == reference

        conn = D.request(method, path, scoped, req_body)
        assert conn.status == 404, "scoped #{method} #{path}: #{conn.status}"
        assert strip(S.json(conn)) == reference
      end

      assert D.request(:get, "/documents/#{id}", ctx.tok_a) |> P.status!(200) |> Map.get("state") ==
               "draft"
    end

    test "TEN-2 a TASK_WORKER is forbidden on every route and nothing is written", ctx do
      doc = create(ctx, body(ctx, "return")) |> P.status!(201)
      before = counts(ctx)
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")

      for {method, path, req_body} <- routes(ctx, doc["id"]) do
        res = D.request(method, path, tok, req_body) |> P.status!(403)
        assert res["title"] == "Forbidden" and res["detail"] == "insufficient permissions"
      end

      assert counts(ctx) == before
    end

    test "TEN-3 B cannot read, change, discard, issue or post A's transfer; B's list is empty",
         ctx do
      doc = create(ctx, body(ctx, "transfer")) |> P.status!(201)
      before = D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> P.status!(200)
      other = D.request(:get, "/documents/#{Ecto.UUID.generate()}", ctx.tok_a) |> P.status!(404)

      for {method, path, req_body} <- routes(ctx, doc["id"]),
          path != "/documents" do
        conn = D.request(method, path, ctx.tok_b, req_body)
        assert conn.status == 404, "#{method} #{path}: #{conn.status}"
        assert strip(S.json(conn)) == strip(other)
      end

      assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> P.status!(200) == before
      assert (D.request(:get, "/documents", ctx.tok_b) |> P.status!(200))["rows"] == []

      assert (D.request(:get, "/documents?kind=transfer", ctx.tok_b) |> P.status!(200))["rows"] ==
               []
    end

    test "TEN-4 a to side naming tenant B's unit and location is not_linked, side to", ctx do
      mb = ctx.mb
      doc = create(ctx, T.body("transfer", ctx.ma, ctx.ma, mb)) |> P.status!(201)
      conn = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)
      assert %{"reason" => "not_linked", "side" => "to"} = P.status!(conn, 422)

      assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a)
             |> P.status!(200)
             |> Map.get("state") == "draft"
    end
  end

  defp routes(ctx, id) do
    [
      {:post, "/documents", body(ctx, "transfer")},
      {:put, "/documents/#{id}", body(ctx, "transfer")},
      {:delete, "/documents/#{id}", nil},
      {:post, "/documents/#{id}/issue", nil},
      {:post, "/documents/#{id}/post", nil},
      {:post, "/documents/#{id}/reverse", %{"reason_code" => "wrong_document"}},
      {:post, "/documents/#{id}/cancel", %{"reason" => "x"}},
      {:get, "/documents", nil},
      {:get, "/documents/#{id}", nil}
    ]
  end

  defp with_slug(method, path, token, body, slug) do
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
end
