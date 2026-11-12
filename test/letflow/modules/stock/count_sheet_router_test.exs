Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountSheetRouterTest do
  @moduledoc """
  REQ-701 / GH #3736 criteria 8 and 9 (RT1..RT8): the seven count sheet routes of module `stock`
  through the full `Letflow.Router` with real OIDC bearer tokens on committed tenants in Sandbox
  `:auto` mode. `async: false`. Scoped callers run with scope enforcement not `on`, as
  `counts_router_test.exs` does.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CountsFixture, as: F
  alias Letflow.Identity.User
  alias Letflow.Ledger
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Stock.Counts
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    Map.put(ctx, :tok_a, S.token(ctx, :a, ["TENANT_ADMIN"]))
  end

  defp call(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, S.base() <> path)
        b -> Plug.Test.conn(method, S.base() <> path, Jason.encode!(b))
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp strip(conn), do: M.strip_conn(conn)

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  defp reason!(conn, status), do: status!(conn, status)["reason"]

  defp window do
    now = DateTime.utc_now()

    %{
      "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
      "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
    }
  end

  # A tenant with a world, a chair and a member who are real users (first use of a token creates the user).
  defp world!(ctx, name) do
    t = S.tenant!("sheet", Map.fetch!(ctx.names, name))
    s = t.schema_name
    w = F.world!(s)
    chair_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "chair-#{name}")
    member_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "member-#{name}")
    status!(call(:get, "/counts", chair_tok), 200)
    status!(call(:get, "/counts", member_tok), 200)
    chair_user = Repo.one!(from(u in User, where: u.username == ^"chair-#{name}"), prefix: s)
    member_user = Repo.one!(from(u in User, where: u.username == ^"member-#{name}"), prefix: s)
    chair = F.employee!(s, w.unit, user: chair_user.id)
    member = F.employee!(s, w.unit, user: member_user.id)
    w = %{w | chair: chair, members: [member]}
    %{t: t, s: s, w: w, chair_tok: chair_tok, member_tok: member_tok}
  end

  defp stock!(x) do
    sku = S.uuid()
    S.post!(x.s, "receipt", %{lines: [S.line(sku, "10", %{to: S.side(x.w.unit, x.w.a)})]})
    S.post!(x.s, "receipt", %{lines: [S.line(S.uuid(), "4", %{to: S.side(x.w.unit, x.w.a1)})]})
    sku
  end

  defp ordered!(x, ctx_tok) do
    created = status!(call(:post, "/counts", ctx_tok, F.input(x.w, window())), 201)
    id = created["id"]
    assert status!(call(:post, "/counts/#{id}/issue", ctx_tok, %{}), 200)["status"] == "ordered"
    id
  end

  describe "RT1 RT2 the whole life through the seven routes" do
    test "open, count, surplus, entries, close, sheet document", ctx do
      x = world!(ctx, :a)
      stock!(x)
      m = D.masters!(x.s)
      id = ordered!(x, x.chair_tok)

      opened = status!(call(:post, "/counts/#{id}/open", x.chair_tok, %{}), 200)
      assert opened["status"] == "counting" and is_binary(opened["cut_off_at"])
      assert is_integer(opened["cutoff_seq"])

      page = status!(call(:get, "/counts/#{id}/lines?limit=1", x.member_tok), 200)
      assert [line] = page["rows"]
      assert is_binary(page["next_cursor"])

      assert Map.keys(line) |> Enum.sort() ==
               ~w(book_quantity catalog_item_id catalog_lot_id counted_quantity kind line_no location_id responsible_employee_id unit_ref)

      assert is_binary(line["book_quantity"]) and line["counted_quantity"] == nil

      rest =
        status!(
          call(:get, "/counts/#{id}/lines?cursor=#{page["next_cursor"]}", x.member_tok),
          200
        )

      assert length(rest["rows"]) == 1 and rest["next_cursor"] == nil

      counted =
        status!(
          call(:put, "/counts/#{id}/lines/1/count", x.member_tok, %{"counted_quantity" => "9"}),
          200
        )

      assert counted["counted_quantity"] == "9.000000000" and counted["line_no"] == 1

      status!(
        call(:put, "/counts/#{id}/lines/2/count", x.chair_tok, %{"counted_quantity" => "4"}),
        200
      )

      surplus =
        status!(
          call(:post, "/counts/#{id}/surplus-lines", x.member_tok, %{
            "location_id" => x.w.a1,
            "catalog_item_id" => m.item,
            "unit_ref" => m.uom,
            "counted_quantity" => "2"
          }),
          201
        )

      assert surplus["kind"] == "surplus" and surplus["line_no"] == 3

      e1 = status!(call(:get, "/counts/#{id}/entries?limit=2", x.chair_tok), 200)
      assert length(e1["rows"]) == 2 and e1["next_cursor"] == "2"

      assert Map.keys(hd(e1["rows"])) |> Enum.sort() ==
               ~w(entered_at entered_by entered_by_employee_id entered_by_label entry_no line_no method quantity_after quantity_before)

      # R7 A-2: a person's name next to the id (employee linked to the user: "code - full_name"), never the id
      assert Enum.all?(e1["rows"], fn r ->
               is_binary(r["entered_by_label"]) and r["entered_by_label"] =~ " - Employee " and
                 r["entered_by_label"] != r["entered_by"]
             end)

      e2 = status!(call(:get, "/counts/#{id}/entries?cursor=2", x.chair_tok), 200)
      assert length(e2["rows"]) == 1 and e2["next_cursor"] == nil

      assert reason!(call(:get, "/counts/#{id}/sheet-document", x.chair_tok), 404) == nil
      closed = status!(call(:post, "/counts/#{id}/close", x.chair_tok, %{}), 200)
      assert closed["status"] == "counted"

      doc = status!(call(:get, "/counts/#{id}/sheet-document", x.chair_tok), 200)

      assert Map.keys(doc) |> Enum.sort() ==
               ~w(content_hash document_id issued_at number_label version_no)

      assert doc["number_label"] =~ ~r/\ACS-\d{4}-0001\z/
      refute Map.has_key?(doc, "content")
    end
  end

  describe "RT1 refusals carry their reason" do
    test "reasons, 404 for a bad line path, closed bodies", ctx do
      x = world!(ctx, :a)
      stock!(x)
      id = ordered!(x, x.chair_tok)

      assert reason!(call(:post, "/counts/#{id}/open", x.member_tok, %{}), 422) == "not_chair"

      assert reason!(call(:post, "/counts/#{id}/close", x.chair_tok, %{}), 422) ==
               "count_state_invalid"

      assert reason!(
               call(:put, "/counts/#{id}/lines/1/count", x.chair_tok, %{"counted_quantity" => "1"}),
               422
             ) == "count_state_invalid"

      assert status!(call(:post, "/counts/#{id}/open", x.chair_tok, %{}), 200)

      put = &call(:put, "/counts/#{id}/lines/#{&1}/count", x.chair_tok, &2)
      assert reason!(put.(99, %{"counted_quantity" => "1"}), 422) == "line_not_found"
      assert reason!(put.("abc", %{"counted_quantity" => "1"}), 422) == "line_not_found"
      assert reason!(put.(1, %{"counted_quantity" => "-1"}), 422) == "field_invalid"
      assert reason!(put.(1, %{"counted_quantity" => 5}), 422) == "field_invalid"
      assert reason!(put.(1, %{}), 422) == "field_invalid"
      assert reason!(put.(1, %{"counted_quantity" => "1", "x" => 1}), 422) == "field_not_allowed"
      assert reason!(put.(1, [1]), 422) == "field_invalid"

      assert reason!(call(:post, "/counts/#{id}/close", x.chair_tok, %{}), 422) ==
               "lines_uncounted"

      assert reason!(call(:post, "/counts/#{id}/close", x.chair_tok, %{"x" => 1}), 422) ==
               "field_not_allowed"

      assert reason!(call(:post, "/counts/#{id}/open", x.chair_tok, %{"x" => 1}), 422) ==
               "field_not_allowed"

      assert reason!(
               call(:post, "/counts/#{id}/surplus-lines", x.chair_tok, %{"bogus" => 1}),
               422
             ) == "field_not_allowed"

      assert reason!(call(:post, "/counts/#{id}/surplus-lines", x.chair_tok, [1]), 422) ==
               "field_invalid"

      assert reason!(call(:get, "/counts/#{id}/lines?limit=0", x.chair_tok), 422) ==
               "field_invalid"

      assert reason!(call(:get, "/counts/#{id}/entries?bogus=1", x.chair_tok), 422) ==
               "field_not_allowed"
    end
  end

  describe "RT3 another tenant's count" do
    test "a plain 404 identical to an unknown id on all seven routes", ctx do
      _a = world!(ctx, :a)
      b = world!(ctx, :b)

      {:ok, order} =
        Counts.create(b.s, F.input(b.w, window()), %{actor_id: Ecto.UUID.generate(), scope: :all})

      id = order["id"]
      unknown = Ecto.UUID.generate()
      body = %{"counted_quantity" => "1"}

      for {m, p, b} <- [
            {:post, "/open", %{}},
            {:get, "/lines", nil},
            {:put, "/lines/1/count", body},
            {:post, "/surplus-lines", %{}},
            {:get, "/entries", nil},
            {:post, "/close", %{}},
            {:get, "/sheet-document", nil}
          ] do
        got = call(m, "/counts/#{id}#{p}", ctx.tok_a, b)
        want = call(m, "/counts/#{unknown}#{p}", ctx.tok_a, b)
        assert got.status == 404, "#{m} #{p}"
        assert strip(got) == strip(want)
      end
    end
  end

  describe "RT4 RT5 scoped callers" do
    test "a unit-scoped admin: 404 on another unit's count, and open is 404 on its own", ctx do
      t = S.tenant!("sheet-s", Map.fetch!(ctx.names, :s))
      s = t.schema_name
      wx = F.world!(s)
      wy = F.world!(s)
      opts = %{actor_id: Ecto.UUID.generate(), scope: :all}
      {:ok, ox} = Counts.create(s, F.input(wx, window()), opts)
      {:ok, oy} = Counts.create(s, F.input(wy, window()), opts)

      tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-sheet")
      status!(call(:get, "/counts", tok), 200)
      user = Repo.one!(from(u in User, where: u.username == "scoped-sheet"), prefix: s)
      group = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)

      unknown = Ecto.UUID.generate()
      body = %{"counted_quantity" => "1"}

      routes = [
        {:post, "/open", %{}},
        {:get, "/lines", nil},
        {:put, "/lines/1/count", body},
        {:post, "/surplus-lines", %{}},
        {:get, "/entries", nil},
        {:post, "/close", %{}},
        {:get, "/sheet-document", nil}
      ]

      for {m, p, b} <- routes do
        got = call(m, "/counts/#{oy["id"]}#{p}", tok, b)
        want = call(m, "/counts/#{unknown}#{p}", tok, b)
        assert got.status == 404, "#{m} #{p}"
        assert strip(got) == strip(want)
      end

      assert status!(call(:get, "/counts/#{ox["id"]}/lines", tok), 200) == %{
               "rows" => [],
               "next_cursor" => nil
             }

      {:ok, issued} = Counts.issue(s, ox["id"], %{actor_id: Ecto.UUID.generate(), scope: :all})
      _ = issued
      assert call(:post, "/counts/#{ox["id"]}/open", tok, %{}).status == 404
    end
  end

  describe "RT6 permissions" do
    test "a role without the permission is forbidden on every route", ctx do
      x = world!(ctx, :a)

      {:ok, o} =
        Counts.create(x.s, F.input(x.w, window()), %{actor_id: Ecto.UUID.generate(), scope: :all})

      id = o["id"]
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-sheet")

      for {m, p, b} <- [
            {:post, "/open", %{}},
            {:get, "/lines", nil},
            {:put, "/lines/1/count", %{"counted_quantity" => "1"}},
            {:post, "/surplus-lines", %{}},
            {:get, "/entries", nil},
            {:post, "/close", %{}},
            {:get, "/sheet-document", nil}
          ] do
        assert call(m, "/counts/#{id}#{p}", tok, b).status == 403, "#{m} #{p}"
      end
    end
  end

  describe "RT8 non-user principals" do
    test "an API-token principal gets no Authorized value, so open answers 404" do
      Fx.setup_auto_mode!()
      Fx.put_registry!(Letflow.Modules.Catalog.ledger_registry())
      fx = Fx.tenant_fixture!()
      user = Fx.user!(fx, ["TENANT_ADMIN"])

      assert {:ok, %Ledger.Authorized{scope: :all}} =
               Ledger.authorize(Fx.conn_for(fx, user, ["TENANT_ADMIN"]), "stock", :read)

      assert :error =
               Ledger.authorize(
                 Fx.conn_for(fx, user, ["TENANT_ADMIN"], :api_token),
                 "stock",
                 :read
               )

      assert {:error, :not_found} =
               Counts.open(fx.schema_name, Ecto.UUID.generate(), %{
                 actor_id: user.id,
                 scope: :all,
                 authorized: nil
               })
    end
  end
end
