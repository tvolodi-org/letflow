Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountsRouterTest do
  @moduledoc """
  REQ-700 / GH #3737 criteria 7 and 8 (R-ROUTES, T-TENANT-A, T-SCOPE-B, T-PERM-C, O-RACE): the seven count
  routes of module `stock` through the full `Letflow.Router` with real OIDC bearer tokens on committed
  tenants in Sandbox `:auto` mode. `async: false`. T-SCOPE-B runs with scope enforcement not `on`,
  as T-R-SC of `router_test.exs` does (with `on` a scoped caller is refused 403 at the route, which is stricter).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CountsFixture, as: F
  alias Letflow.Identity.User
  alias Letflow.Modules.Stock.Counts
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    Map.put(ctx, :tok_a, S.token(ctx, :a, ["TENANT_ADMIN"]))
  end

  defp tenant_world!(ctx, name) do
    t = S.tenant!("stk-#{name}", Map.fetch!(ctx.names, name))
    {t, F.world!(t.schema_name)}
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

  defp strip(conn), do: conn |> S.json() |> Map.delete("trace_id")

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  defp reason!(conn, status), do: status!(conn, status)["reason"]

  describe "R-ROUTES" do
    test "the whole life of an order through the seven routes", ctx do
      {t, w} = tenant_world!(ctx, :a)
      s = t.schema_name
      chair_tok = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "chair-1")
      status!(call(:get, "/counts", chair_tok), 200)
      user = Repo.one!(from(u in User, where: u.username == "chair-1"), prefix: s)
      chair = F.employee!(s, w.unit, user: user.id)

      body = F.input(w, %{"chair_employee_id" => chair})
      created = status!(call(:post, "/counts", ctx.tok_a, body), 201)
      id = created["id"]
      assert created["status"] == "draft" and created["location_ids"] == [w.a]

      assert status!(call(:get, "/counts/#{id}", ctx.tok_a), 200) == created
      upd = Map.put(body, "note", "changed")
      assert status!(call(:put, "/counts/#{id}", ctx.tok_a, upd), 200)["note"] == "changed"

      listed = status!(call(:get, "/counts?status=draft&limit=1", ctx.tok_a), 200)
      assert [%{"id" => ^id}] = listed["rows"]
      assert listed["next_cursor"] == nil

      assert status!(call(:get, "/counts/#{id}/document", ctx.tok_a), 404)

      issued = status!(call(:post, "/counts/#{id}/issue", ctx.tok_a, %{}), 200)
      assert issued["status"] == "ordered" and issued["number"] =~ ~r/\ACO-\d{4}-0001\z/

      doc = status!(call(:get, "/counts/#{id}/document", ctx.tok_a), 200)
      assert doc["number_label"] == issued["number"]

      assert Map.keys(doc) |> Enum.sort() ==
               ~w(content_hash document_id issued_at number_label version_no)

      assert reason!(call(:post, "/counts/#{id}/cancel", ctx.tok_a, %{}), 422) == "not_chair"
      cancelled = status!(call(:post, "/counts/#{id}/cancel", chair_tok, %{}), 200)
      assert cancelled["status"] == "cancelled"
    end

    test "refusals carry their reason; bad ids are 404; bodies and query keys are closed", ctx do
      {_t, w} = tenant_world!(ctx, :a)
      tok = ctx.tok_a
      post = &call(:post, "/counts", tok, &1)

      assert reason!(post.(Map.put(F.input(w), "bogus", 1)), 422) == "field_not_allowed"
      assert reason!(post.(F.input(w, %{"kind" => "x"})), 422) == "field_invalid"

      assert reason!(post.(F.input(w, %{"org_unit_id" => Ecto.UUID.generate()})), 422) ==
               "org_unit_inactive"

      id = status!(post.(F.input(w)), 201)["id"]
      full = F.input(w, %{"kind" => "full"})
      assert status!(call(:put, "/counts/#{id}", tok, full), 200)

      assert reason!(call(:post, "/counts/#{id}/issue", tok, %{}), 422) ==
               "count_scope_incomplete"

      assert reason!(call(:post, "/counts/#{id}/issue", tok, %{"x" => 1}), 422) ==
               "field_not_allowed"

      assert reason!(call(:post, "/counts/#{id}/cancel", tok, %{"x" => 1}), 422) ==
               "field_not_allowed"

      ok = F.input(w, %{"planned_end" => "2026-12-30T09:00:00Z"})
      assert status!(call(:put, "/counts/#{id}", tok, ok), 200)
      assert reason!(call(:post, "/counts/#{id}/issue", tok, %{}), 422) == "count_too_long"

      assert status!(call(:put, "/counts/#{id}", tok, F.input(w)), 200)
      assert status!(call(:post, "/counts/#{id}/issue", tok, %{}), 200)
      assert reason!(call(:post, "/counts/#{id}/issue", tok, %{}), 422) == "count_state_invalid"
      assert reason!(call(:put, "/counts/#{id}", tok, F.input(w)), 422) == "count_state_invalid"

      unknown = status!(call(:get, "/counts/#{Ecto.UUID.generate()}", tok), 404)

      for {m, p} <- [get: "nope", put: "nope", get: "nope/document"] do
        conn = call(m, "/counts/#{p}", tok, if(m == :put, do: F.input(w)))
        assert conn.status == 404
        assert strip(conn) == Map.delete(unknown, "trace_id")
      end

      assert reason!(call(:get, "/counts?bogus=1", tok), 422) == "field_not_allowed"
      assert reason!(call(:get, "/counts?limit=0", tok), 422) == "field_invalid"
    end

    test "list pages with a cursor", ctx do
      {_t, w} = tenant_world!(ctx, :a)

      for d <- ["01", "02", "03"] do
        input =
          F.input(w, %{
            "planned_start" => "2026-11-#{d}T09:00:00Z",
            "planned_end" => "2026-11-#{d}T18:00:00Z"
          })

        status!(call(:post, "/counts", ctx.tok_a, input), 201)
      end

      p1 = status!(call(:get, "/counts?limit=2", ctx.tok_a), 200)
      assert length(p1["rows"]) == 2 and is_binary(p1["next_cursor"])
      p2 = status!(call(:get, "/counts?limit=2&cursor=#{p1["next_cursor"]}", ctx.tok_a), 200)
      assert length(p2["rows"]) == 1 and p2["next_cursor"] == nil
      starts = Enum.map(p1["rows"] ++ p2["rows"], & &1["planned_start"])
      assert starts == Enum.sort(starts, :desc)
    end
  end

  describe "T-TENANT-A" do
    test "another tenant's order is a plain 404", ctx do
      {_ta, _wa} = tenant_world!(ctx, :a)
      {tb, wb} = tenant_world!(ctx, :b)
      {:ok, order} = Counts.create(tb.schema_name, F.input(wb), F.opts())
      tok_b = S.token(ctx, :b, ["TENANT_ADMIN"])
      assert status!(call(:get, "/counts/#{order["id"]}", tok_b), 200)

      unknown = strip(call(:get, "/counts/#{Ecto.UUID.generate()}", ctx.tok_a))

      for {m, p, b} <- [
            {:get, "", nil},
            {:put, "", F.input(wb)},
            {:post, "/issue", %{}},
            {:post, "/cancel", %{}},
            {:get, "/document", nil}
          ] do
        conn = call(m, "/counts/#{order["id"]}#{p}", ctx.tok_a, b)
        assert conn.status == 404, "#{m} #{p}"
        assert strip(conn) == unknown
      end

      assert status!(call(:get, "/counts", ctx.tok_a), 200)["rows"] == []
    end
  end

  describe "T-SCOPE-B" do
    test "a TENANT_ADMIN scoped to one unit sees only that unit's orders", ctx do
      {t, wx} = tenant_world!(ctx, :s)
      s = t.schema_name
      wy = F.world!(s)
      {:ok, ox} = Counts.create(s, F.input(wx), F.opts())
      {:ok, oy} = Counts.create(s, F.input(wy), F.opts())

      tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-counter")
      status!(call(:get, "/counts", tok), 200)
      user = Repo.one!(from(u in User, where: u.username == "scoped-counter"), prefix: s)
      group = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)

      assert status!(call(:get, "/counts/#{ox["id"]}", tok), 200)
      assert [%{"id" => id}] = status!(call(:get, "/counts", tok), 200)["rows"]
      assert id == ox["id"]

      unknown = strip(call(:get, "/counts/#{Ecto.UUID.generate()}", tok))

      for {m, p, b} <- [
            {:get, "", nil},
            {:put, "", F.input(wy)},
            {:post, "/issue", %{}},
            {:post, "/cancel", %{}},
            {:get, "/document", nil}
          ] do
        conn = call(m, "/counts/#{oy["id"]}#{p}", tok, b)
        assert conn.status == 404, "#{m} #{p}"
        assert strip(conn) == unknown
      end

      assert call(:post, "/counts", tok, F.input(wy)).status == 404
      assert call(:post, "/counts", tok, F.input(wx)).status == 201
    end
  end

  describe "T-PERM-C" do
    test "a role without the permission is forbidden on every route", ctx do
      {t, w} = tenant_world!(ctx, :a)
      {:ok, o} = Counts.create(t.schema_name, F.input(w), F.opts())
      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")
      id = o["id"]

      for {m, p, b} <- [
            {:post, "/counts", F.input(w)},
            {:put, "/counts/#{id}", F.input(w)},
            {:post, "/counts/#{id}/issue", %{}},
            {:post, "/counts/#{id}/cancel", %{}},
            {:get, "/counts", nil},
            {:get, "/counts/#{id}", nil},
            {:get, "/counts/#{id}/document", nil}
          ] do
        assert call(m, p, tok, b).status == 403, "#{m} #{p}"
      end
    end
  end

  describe "O-RACE" do
    test "two overlapping orders issued at once: exactly one wins", ctx do
      {t, w} = tenant_world!(ctx, :a)
      s = t.schema_name
      {:ok, o1} = Counts.create(s, F.input(w, %{"location_ids" => [w.a]}), F.opts())
      {:ok, o2} = Counts.create(s, F.input(w, %{"location_ids" => [w.a1]}), F.opts())

      results =
        [o1, o2]
        |> Enum.map(fn o -> Task.async(fn -> Counts.issue(s, o["id"], F.opts()) end) end)
        |> Task.await_many(30_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :count_scope_overlaps})) == 1
    end
  end
end
