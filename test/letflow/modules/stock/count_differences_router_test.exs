Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountDifferencesRouterTest do
  @moduledoc """
  REQ-717 / GH #3764 criteria 6 and 7 (T1, X1..X3): the five signing and differences routes of module
  `stock` through the full `Letflow.Router` with real OIDC bearer tokens on committed tenants in Sandbox
  `:auto` mode. `async: false`. Scoped callers run with scope enforcement not `on`, as
  `count_sheet_router_test.exs` does.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CountsFixture, as: F
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Stock.Counts
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

  # A counted count of the tenant, driven through the routes. Returns the id.
  defp counted!(x) do
    stock!(x)
    id = ordered!(x, x.chair_tok)
    status!(call(:post, "/counts/#{id}/open", x.chair_tok, %{}), 200)

    for n <- 1..2 do
      status!(
        call(:put, "/counts/#{id}/lines/#{n}/count", x.member_tok, %{"counted_quantity" => "3"}),
        200
      )
    end

    assert status!(call(:post, "/counts/#{id}/close", x.chair_tok, %{}), 200)["status"] ==
             "counted"

    id
  end

  defp signers(x), do: [x.w.chair | x.w.members]

  describe "T1 the five routes" do
    test "sheet signing, differences, differences signing, reads", ctx do
      x = world!(ctx, :a)
      id = counted!(x)
      ids = signers(x)

      assert reason!(call(:get, "/counts/#{id}/differences", x.chair_tok), 422) ==
               "differences_not_issued"

      assert reason!(call(:post, "/counts/#{id}/differences", x.chair_tok, %{}), 422) ==
               "sheet_not_signed"

      sign = &call(:post, "/counts/#{id}/sheet-signatures", &1, &2)
      assert reason!(sign.(x.member_tok, %{"signer_employee_ids" => ids}), 422) == "not_chair"
      assert reason!(sign.(x.chair_tok, %{}), 422) == "field_invalid"

      assert reason!(sign.(x.chair_tok, %{"signer_employee_ids" => ids, "x" => 1}), 422) ==
               "field_not_allowed"

      assert reason!(sign.(x.chair_tok, %{"signer_employee_ids" => tl(ids)}), 422) ==
               "signers_incomplete"

      assert reason!(sign.(x.chair_tok, %{"signer_employee_ids" => "no"}), 422) == "field_invalid"

      signed = status!(sign.(x.chair_tok, %{"signer_employee_ids" => ids}), 200)
      assert signed["status"] == "counted" and is_binary(signed["sheet_signed_at"])

      assert reason!(sign.(x.chair_tok, %{"signer_employee_ids" => ids}), 422) ==
               "sheet_already_signed"

      assert reason!(call(:post, "/counts/#{id}/differences", x.chair_tok, %{"x" => 1}), 422) ==
               "field_not_allowed"

      issued = status!(call(:post, "/counts/#{id}/differences", x.chair_tok, %{}), 200)
      assert issued["differences_number"] =~ ~r/\ACD-\d{4}-0001\z/

      diff = status!(call(:get, "/counts/#{id}/differences", x.member_tok), 200)
      assert Enum.sort(Map.keys(diff)) == ~w(content_hash issued_at lines number version_no)
      assert length(diff["lines"]) == 2

      assert Enum.all?(
               diff["lines"],
               &(is_binary(&1["difference"]) and &1["direction"] in ~w(surplus shortage))
             )

      dsign = &call(:post, "/counts/#{id}/differences-signatures", &1, &2)

      assert reason!(dsign.(x.chair_tok, %{"signer_employee_ids" => tl(ids)}), 422) ==
               "signers_incomplete"

      done = status!(dsign.(x.chair_tok, %{"signer_employee_ids" => ids}), 200)
      assert done["status"] == "signed" and is_binary(done["differences_signed_at"])

      assert reason!(dsign.(x.chair_tok, %{"signer_employee_ids" => ids}), 422) ==
               "count_state_invalid"

      %{"rows" => rows} = status!(call(:get, "/counts/#{id}/signatures", x.member_tok), 200)
      assert length(rows) == 2 * length(ids)
      assert Enum.map(rows, & &1["marked_at"]) == Enum.sort(Enum.map(rows, & &1["marked_at"]))
      assert Enum.take(rows, length(ids)) |> Enum.all?(&(&1["document_kind"] == "sheet"))
    end
  end

  @routes [
    {:post, "/sheet-signatures", %{"signer_employee_ids" => []}},
    {:post, "/differences", %{}},
    {:post, "/differences-signatures", %{"signer_employee_ids" => []}},
    {:get, "/differences", nil},
    {:get, "/signatures", nil}
  ]

  describe "X1 another tenant's count" do
    test "a plain 404 identical to an unknown id on all five routes", ctx do
      _a = world!(ctx, :a)
      b = world!(ctx, :b)

      {:ok, order} =
        Counts.create(b.s, F.input(b.w, window()), %{actor_id: Ecto.UUID.generate(), scope: :all})

      unknown = Ecto.UUID.generate()

      for {m, p, body} <- @routes do
        got = call(m, "/counts/#{order["id"]}#{p}", ctx.tok_a, body)
        want = call(m, "/counts/#{unknown}#{p}", ctx.tok_a, body)
        assert got.status == 404, "#{m} #{p}"
        assert strip(got) == strip(want)
      end
    end
  end

  describe "X2 scoped callers" do
    test "a unit-scoped admin gets 404 on another unit's count", ctx do
      t = S.tenant!("cdf-s", Map.fetch!(ctx.names, :s))
      s = t.schema_name
      wx = F.world!(s)
      wy = F.world!(s)
      opts = %{actor_id: Ecto.UUID.generate(), scope: :all}
      {:ok, oy} = Counts.create(s, F.input(wy, window()), opts)

      tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-cdf")
      status!(call(:get, "/counts", tok), 200)
      user = Repo.one!(from(u in User, where: u.username == "scoped-cdf"), prefix: s)
      group = RSG.group_of!(s, "TENANT_ADMIN")
      _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
      :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)
      unknown = Ecto.UUID.generate()

      for {m, p, body} <- @routes do
        got = call(m, "/counts/#{oy["id"]}#{p}", tok, body)
        want = call(m, "/counts/#{unknown}#{p}", tok, body)
        assert got.status == 404, "#{m} #{p}"
        assert strip(got) == strip(want)
      end
    end
  end

  describe "X3 permissions" do
    test "a role without the permission is forbidden on every route", ctx do
      x = world!(ctx, :a)

      {:ok, o} =
        Counts.create(x.s, F.input(x.w, window()), %{actor_id: Ecto.UUID.generate(), scope: :all})

      tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-cdf")

      for {m, p, body} <- @routes do
        assert call(m, "/counts/#{o["id"]}#{p}", tok, body).status == 403, "#{m} #{p}"
      end
    end
  end
end
