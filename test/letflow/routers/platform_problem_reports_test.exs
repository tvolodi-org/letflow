defmodule Letflow.Routers.PlatformProblemReportsTest do
  @moduledoc "T-1949 R1-R6 P1-P3 M1-M5: real tokens through the complete router."
  use Letflow.DataCase, async: false

  import Ecto.Query
  alias Letflow.Repo
  alias Letflow.ProblemReports.{Inbox, Report}
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @path "/api/v1/platform-problem-reports"
  @mine "/api/v1/me/problem-reports"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    owner = Fixture.mint_token!(tenants.p, ["PLATFORM_ADMIN"])
    caller = Fixture.mint_token!(tenants.a, ["TASK_WORKER"])

    user_id =
      Repo.one!(from(u in Letflow.Identity.User, select: u.id), prefix: tenants.a.schema_name)

    {:ok, Map.merge(tenants, %{owner: owner, caller: caller, user_id: user_id})}
  end

  defp request(fx, token, method, path, body \\ nil),
    do: method |> Fixture.api_conn(path, token, fx.tenant.slug, body) |> Fixture.dispatch_api()

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp report!(a, token) do
    conn =
      request(a, token, :post, @mine, %{
        "consent" => true,
        "text" => "The purchase date is not retained after commissioning",
        "context" => %{"route" => "/assets"}
      })

    assert conn.status == 201, conn.resp_body
    json(conn)
  end

  test "R1 R2 R3 captured context, exact allowlists, filters and paging", ctx do
    one = report!(ctx.a, ctx.caller)
    two = report!(ctx.a, ctx.caller)
    conn = request(ctx.p, ctx.owner, :get, @path <> "?limit=1")
    assert conn.status == 200, conn.resp_body
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    assert [summary] = json(conn)["reports"]
    assert summary["id"] == two["id"]

    assert Enum.sort(Map.keys(summary)) ==
             ~w(class decided_at id last_action number received_at reporter status text_preview)

    before = json(conn)["next_before"]
    page = json(request(ctx.p, ctx.owner, :get, @path <> "?before=#{before}&limit=1"))
    assert [%{"id" => id}] = page["reports"]
    assert id == one["id"]
    detail = json(request(ctx.p, ctx.owner, :get, @path <> "/" <> id))
    assert detail["context"] == %{"route" => "/assets"}
    assert detail["reporter"]["tenant_name"] == ctx.a.tenant.display_name

    assert Enum.sort(Map.keys(detail)) ==
             ~w(class context decided_at decided_by_user_id dev_summary id last_action number received_at reply_text reporter server_version status text trace_id)

    assert Enum.sort(Map.keys(detail["reporter"])) ==
             ~w(name permissions roles tenant_id tenant_name user_id)

    assert {:ok, _} = Inbox.decide(id, %{"action" => "fixed"}, Ecto.UUID.generate())

    assert [%{"id" => ^id}] =
             json(request(ctx.p, ctx.owner, :get, @path <> "?status=closed"))["reports"]

    assert length(json(request(ctx.p, ctx.owner, :get, @path <> "?status=all"))["reports"]) == 2
    assert length(json(request(ctx.p, ctx.owner, :get, @path))["reports"]) == 1
  end

  test "R4 R6 bad filters and decisions, INV-5 identical missing lookups", ctx do
    report = report!(ctx.a, ctx.caller)
    path = @path <> "/" <> report["id"]

    for query <- ["status=no", "limit=0", "limit=101", "before=-1", "before=x", "limit[]=2"] do
      assert request(ctx.p, ctx.owner, :get, @path <> "?" <> query).status == 400
    end

    for body <- [
          %{},
          %{"action" => "ai"},
          %{"action" => "answer"},
          %{"action" => "answer", "text" => 1},
          %{
            "action" => "develop",
            "text" => "The purchase date is not retained after commissioning"
          }
        ] do
      assert request(ctx.p, ctx.owner, :post, path <> "/decision", body).status == 422
    end

    bad = request(ctx.p, ctx.owner, :get, @path <> "/bad")
    absent = request(ctx.p, ctx.owner, :get, @path <> "/" <> Ecto.UUID.generate())
    assert bad.status == 404
    assert absent.status == 404
    assert Map.delete(json(bad), "trace_id") == Map.delete(json(absent), "trace_id")
  end

  test "R5 one click answers, repeated closed decision is 409", ctx do
    report = report!(ctx.a, ctx.caller)
    path = @path <> "/" <> report["id"] <> "/decision"
    body = %{"action" => "answer", "text" => "Use the date picker"}
    conn = request(ctx.p, ctx.owner, :post, path, body)
    assert conn.status == 200, conn.resp_body
    assert json(conn)["status"] == "answered"
    assert request(ctx.p, ctx.owner, :post, path, body).status == 409
  end

  @tag timeout: 30_000
  test "P1 P2 P3 owner-only permission refuses tenant administrators and foreign platform admins",
       ctx do
    report = report!(ctx.a, ctx.caller)

    for {fx, roles} <- [
          {ctx.p, ["TENANT_ADMIN"]},
          {ctx.a, ["TENANT_ADMIN"]},
          {ctx.a, ["PLATFORM_ADMIN"]}
        ] do
      token = Fixture.mint_token!(fx, roles)

      for {method, suffix, body} <- [
            {:get, "", nil},
            {:get, "/" <> report["id"], nil},
            {:post, "/" <> report["id"] <> "/decision", %{"action" => "fixed"}},
            {:get, "/unknown/path/more", nil}
          ] do
        conn = request(fx, token, method, @path <> suffix, body)
        assert conn.status == 403, conn.resp_body
      end
    end

    assert Repo.get!(Report, report["id"], prefix: ctx.p.schema_name).status == "received"
  end

  test "M1 M4 own list shows each status/question and never private owner fields", ctx do
    initial = report!(ctx.a, ctx.caller)
    assert [received] = json(request(ctx.a, ctx.caller, :get, @mine))["reports"]
    assert received["status"] == "received"
    assert received["question"] == false

    for {action, status, question, reply} <- [
          {"ask", "in_work", true, "Please provide details"},
          {"develop", "in_work", false, nil},
          {"answer", "answered", false, "Please provide details"},
          {"fixed", "fixed", false, "Please provide details"},
          {"reject", "not_done", false, "Please provide details"}
        ] do
      report = if action == "ask", do: initial, else: report!(ctx.a, ctx.caller)

      text =
        if action == "develop", do: "Investigate date persistence", else: "Please provide details"

      assert {:ok, _} =
               Inbox.decide(
                 report["id"],
                 %{"action" => action, "text" => text},
                 Ecto.UUID.generate()
               )

      row =
        json(request(ctx.a, ctx.caller, :get, @mine))["reports"]
        |> Enum.find(&(&1["id"] == report["id"]))

      assert row["status"] == status
      assert row["question"] == question
      assert row["reply_text"] == reply

      assert Enum.sort(Map.keys(row)) ==
               ~w(decided_at id number question received_at reply_text status text)
    end
  end

  test "M2 M3 M5 filter by both tenant AND user; cap is honest", ctx do
    report = report!(ctx.a, ctx.caller)
    stored = Repo.get!(Report, report["id"], prefix: ctx.p.schema_name)
    # Same user id in a different company must not be visible to A's caller.
    Repo.insert!(
      %{stored | id: Ecto.UUID.generate(), seq: nil, reporter_tenant_id: ctx.b.tenant_id},
      prefix: ctx.p.schema_name
    )

    other = Fixture.mint_token!(ctx.a, ["TASK_WORKER"])
    b_token = Fixture.mint_token!(ctx.b, ["TASK_WORKER"])
    assert json(request(ctx.a, other, :get, @mine)) == %{"reports" => [], "has_more" => false}
    assert json(request(ctx.b, b_token, :get, @mine)) == %{"reports" => [], "has_more" => false}

    assert [%{"id" => id}] =
             json(request(ctx.a, ctx.caller, :get, @mine <> "?tenant_id=" <> ctx.b.tenant_id))[
               "reports"
             ]

    assert id == report["id"]

    for _ <- 1..50 do
      Repo.insert!(%{stored | id: Ecto.UUID.generate(), seq: nil}, prefix: ctx.p.schema_name)
    end

    mine = json(request(ctx.a, ctx.caller, :get, @mine))
    assert length(mine["reports"]) == 50
    assert mine["has_more"] == true
  end

  test "M6 own list is unavailable when the platform pin is absent", ctx do
    Fixture.unpin!()
    assert request(ctx.a, ctx.caller, :get, @mine).status == 503
  end
end
