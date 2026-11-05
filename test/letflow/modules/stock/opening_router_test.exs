Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.OpeningRouterTest do
  @moduledoc """
  REQ-725 / GH #3775 criteria 3, 4 and 7: save, replace and discard of an opening draft, the exact
  read key sets, the list filter, and the tenancy rules of the opening routes including the new
  `check` route, through the full `Letflow.Router` with real OIDC bearer tokens on committed tenants
  (Sandbox `:auto`, `async: false`). Tests: O-SAVE-1..6, O-READ-1..2, O-TEN-1..4.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture

  setup do
    ctx = P.setup!([:a, :b, :s, :c])
    Map.merge(ctx, P.tenant_b!(ctx))
  end

  defp strip(body), do: Map.delete(body, "trace_id")

  defp refused(ctx, body, status, reason, extras \\ %{}) do
    before = O.counts(ctx.schema)
    json = D.request(:post, "/documents", ctx.tok_a, body) |> P.status!(status)
    assert json["reason"] == reason, inspect(json)
    for {k, v} <- extras, do: assert(json[k] == v)
    assert O.counts(ctx.schema) == before
  end

  describe "save, replace, discard" do
    test "O-SAVE-1 a saved opening reads back field by field", ctx do
      doc = O.save!(ctx)
      assert doc["kind"] == "opening" and doc["state"] == "draft" and doc["number"] == nil
      assert doc["org_unit_id"] == ctx.ma.unit and doc["note"] == "migration stock"
      assert [one, two] = doc["lines"]
      assert one["line_no"] == 1 and one["quantity"] == "10.500000000"
      assert one["location_id"] == ctx.ma.location and one["responsible_id"] == ctx.ma.employee
      assert one["received_on"] == O.back(400) and one["catalog_lot_id"] == nil
      assert two["catalog_lot_id"] == ctx.ma.lot and two["unit_price"] == "3.500000000"
      assert two["line_value"] == "7.000000000" and two["received_on"] == O.back(30)
    end

    test "O-SAVE-2 PUT replaces the whole draft, a line left out is deleted", ctx do
      doc = O.save!(ctx)
      m = ctx.ma
      new = O.body(m, %{"note" => "again", "lines" => [O.line(m, %{"quantity" => "5"})]})
      put = D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, new) |> P.status!(200)
      assert put["note"] == "again" and length(put["lines"]) == 1
      assert hd(put["lines"])["quantity"] == "5.000000000"
      assert hd(put["lines"])["line_id"] == hd(doc["lines"])["line_id"]
      # another org unit is refused
      other = D.unit!(ctx.schema)

      conn =
        D.request(
          :put,
          "/documents/#{doc["id"]}",
          ctx.tok_a,
          O.body(m, %{"org_unit_id" => other})
        )

      assert conn.status == 422
      # the receipt kind cannot replace an opening
      assert D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, D.body(m)).status == 422
    end

    test "O-SAVE-3 DELETE discards the draft and soft-deletes its records", ctx do
      doc = O.save!(ctx)
      assert D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_a).status == 204
      assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a).status == 404

      live =
        Repo.aggregate(
          from(r in Letflow.Entities.Record.Latest,
            where: r.entity_type in ["stock_opening", "stock_opening_line"] and not r.deleted
          ),
          :count,
          prefix: ctx.schema
        )

      assert live == 0
    end

    test "O-SAVE-4 each shape reason is a 422 and nothing is written", ctx do
      m = ctx.ma

      refused(
        ctx,
        O.body(m, %{"event_time" => "2026-01-01T00:00:00Z"}),
        422,
        "field_not_allowed",
        %{"field" => "event_time"}
      )

      refused(ctx, O.body(m, %{"location_id" => m.location}), 422, "field_not_allowed", %{
        "field" => "location_id"
      })

      refused(ctx, O.body(m, %{"responsible_id" => m.employee}), 422, "field_not_allowed", %{
        "field" => "responsible_id"
      })

      refused(ctx, Map.delete(O.body(m), "org_unit_id"), 422, "field_required", %{
        "field" => "org_unit_id"
      })

      refused(ctx, O.body(m, %{"lines" => []}), 422, "lines_count")
      refused(ctx, O.body(m, %{"lines" => List.duplicate(O.line(m), 101)}), 422, "lines_count")

      refused(
        ctx,
        O.body(m, %{"lines" => [O.line(m, %{"quantity" => "0"})]}),
        422,
        "quantity_invalid",
        %{"line_no" => 1}
      )

      refused(
        ctx,
        O.body(m, %{"lines" => [O.line(m, %{"unit_price" => "-1"})]}),
        422,
        "price_invalid",
        %{"field" => "unit_price"}
      )

      refused(
        ctx,
        O.body(m, %{"lines" => [O.line(m, %{"received_on" => "x"})]}),
        422,
        "field_invalid",
        %{"field" => "received_on", "line_no" => 1}
      )

      refused(ctx, O.body(m, %{"external_ref_system" => "erp"}), 422, "external_ref_pair")
      zero = O.body(m, %{"lines" => [O.line(m, %{"unit_price" => "0"})]})
      assert D.request(:post, "/documents", ctx.tok_a, zero).status == 201
    end

    test "O-SAVE-5 the external pair is held by one live opening; free after discard; per tenant",
         ctx do
      m = ctx.ma
      ref = %{"external_ref_system" => "erp", "external_ref_id" => "OB-1"}
      first = O.save!(ctx, O.body(m, ref))
      refused(ctx, O.body(m, ref), 409, "external_ref_taken")
      # another id is fine; the own pair on replace is fine
      assert D.request(
               :post,
               "/documents",
               ctx.tok_a,
               O.body(m, %{ref | "external_ref_id" => "OB-2"})
             ).status == 201

      assert D.request(:put, "/documents/#{first["id"]}", ctx.tok_a, O.body(m, ref)).status == 200
      # a replace to a pair held by another document is refused
      second = O.save!(ctx, O.body(m, %{ref | "external_ref_id" => "OB-3"}))
      before = O.counts(ctx.schema)
      conn = D.request(:put, "/documents/#{second["id"]}", ctx.tok_a, O.body(m, ref))
      assert conn.status == 409 and S.json(conn)["reason"] == "external_ref_taken"
      assert O.counts(ctx.schema) == before
      # discard frees the pair
      assert D.request(:delete, "/documents/#{first["id"]}", ctx.tok_a).status == 204
      assert D.request(:post, "/documents", ctx.tok_a, O.body(m, ref)).status == 201
      # tenant B accepts A's pair
      b = D.request(:post, "/documents", ctx.tok_b, O.body(ctx.mb, ref))
      assert b.status == 201, b.resp_body
    end

    test "O-SAVE-6 an issued opening cannot be replaced or discarded", ctx do
      doc = O.issue!(ctx)
      assert D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, O.body(ctx.ma)).status == 409
      assert D.request(:delete, "/documents/#{doc["id"]}", ctx.tok_a).status == 409
    end
  end

  describe "reads" do
    test "O-READ-1 the exact key sets of the document and of a line", ctx do
      doc = O.save!(ctx)
      read = D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> P.status!(200)

      assert read |> Map.keys() |> Enum.sort() ==
               ~w(entry_id external_ref_id external_ref_system header_id id issued_at kind lines note number org_unit_id posted_at posted_by posted_by_label posting_check reversed_at reversed_by reversed_by_label state)

      for line <- read["lines"] do
        assert line |> Map.keys() |> Enum.sort() ==
                 ~w(catalog_item_id catalog_lot_id catalog_uom_id external_ref_id external_ref_system line_id line_no line_value location_id quantity received_on responsible_id unit_price)
      end

      assert Enum.map(read["lines"], & &1["line_no"]) == [1, 2]
    end

    test "O-READ-2 the list filters by kind and keeps the receipt row key set", ctx do
      op = O.save!(ctx)
      rc = P.save!(ctx)
      all = D.request(:get, "/documents", ctx.tok_a) |> P.status!(200)
      assert all["rows"] |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort([op["id"], rc["id"]])

      only = fn kind ->
        D.request(:get, "/documents?kind=#{kind}", ctx.tok_a) |> P.status!(200) |> Map.get("rows")
      end

      assert [%{"id" => id, "kind" => "opening", "event_time" => nil} = row] = only.("opening")
      assert id == op["id"]
      assert [%{"id" => rid, "kind" => "receipt"} = rrow] = only.("receipt")
      assert rid == rc["id"]
      assert Enum.sort(Map.keys(row)) == Enum.sort(Map.keys(rrow))
      assert D.request(:get, "/documents?kind=bogus", ctx.tok_a).status == 422
    end
  end

  describe "tenancy" do
    test "O-TEN-1 an API token and a scoped admin get the no-module 404 on opening routes", ctx do
      doc = O.save!(ctx)
      S.tenant!("stk-oref", ctx.names.c, install: false)
      ref_tok = S.token(ctx, :c, ["TENANT_ADMIN"], sub: "ref-admin")
      reference = D.request(:get, "/documents", ref_tok) |> P.status!(404) |> strip()

      user = TokenMintFixture.role_holder!(ctx.a.schema_name, ["TENANT_ADMIN"])

      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: ctx.a.schema_name
        )

      slug = Repo.get!(Letflow.Identity.Tenant, ctx.a.tenant_id).slug
      s = S.tenant!("stk-os", ctx.names.s)
      scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-writer")
      D.request(:get, "/documents", scoped) |> P.status!(200)

      scoped_user =
        Repo.one!(from(u in User, where: u.username == "scoped-writer"), prefix: s.schema_name)

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
        {:post, "/documents", O.body(ctx.ma)},
        {:put, "/documents/#{id}", O.body(ctx.ma)},
        {:post, "/documents/#{id}/check", nil},
        {:post, "/documents/#{id}/issue", nil},
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

      assert D.request(:get, "/documents/#{id}", ctx.tok_a) |> P.status!(200) |> Map.get("state") ==
               "draft"
    end

    test "O-TEN-2 a TASK_WORKER is forbidden on the opening routes and nothing is written", ctx do
      doc = O.save!(ctx)
      before = O.counts(ctx.schema)
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")
      id = doc["id"]

      for {method, path, body} <- [
            {:post, "/documents", O.body(ctx.ma)},
            {:put, "/documents/#{id}", O.body(ctx.ma)},
            {:post, "/documents/#{id}/check", nil},
            {:post, "/documents/#{id}/issue", nil}
          ] do
        res = D.request(method, path, tok, body) |> P.status!(403)
        assert res["detail"] == "insufficient permissions"
      end

      assert O.counts(ctx.schema) == before
    end

    test "O-TEN-3 a malformed, unknown or other tenant's id gives one 404 body on check", ctx do
      doc = O.save!(ctx)

      other =
        D.request(:get, "/documents/#{Ecto.UUID.generate()}", ctx.tok_a)
        |> P.status!(404)
        |> strip()

      for id <- ["not-a-uuid", "123", Ecto.UUID.generate()] do
        assert D.request(:post, "/documents/#{id}/check", ctx.tok_a) |> P.status!(404) |> strip() ==
                 other
      end

      # tenant B's admin checks A's opening id: same 404
      assert D.request(:post, "/documents/#{doc["id"]}/check", ctx.tok_b)
             |> P.status!(404)
             |> strip() == other
    end

    test "O-TEN-4 tenant B cannot check, replace, issue or discard A's opening; A is unchanged",
         ctx do
      doc = O.save!(ctx)
      id = doc["id"]
      before = O.counts(ctx.schema)

      for {method, path, body} <- [
            {:put, "/documents/#{id}", O.body(ctx.mb)},
            {:delete, "/documents/#{id}", nil},
            {:post, "/documents/#{id}/check", nil},
            {:post, "/documents/#{id}/issue", nil},
            {:post, "/documents/#{id}/post", nil},
            {:post, "/documents/#{id}/cancel", %{"reason" => "x"}}
          ] do
        assert D.request(method, path, ctx.tok_b, body).status == 404, "#{method} #{path}"
      end

      assert O.counts(ctx.schema) == before

      assert D.request(:get, "/documents/#{id}", ctx.tok_a) |> P.status!(200) |> Map.get("state") ==
               "draft"
    end
  end

  defp send_with_slug(method, path, token, body, slug) do
    import Plug.Conn

    conn =
      case body do
        nil -> Plug.Test.conn(method, "/api/v1/modules/stock" <> path)
        body -> Plug.Test.conn(method, "/api/v1/modules/stock" <> path, Jason.encode!(body))
      end

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-tenant-slug", slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end
end
