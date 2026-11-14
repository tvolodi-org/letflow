defmodule Letflow.Routers.PlatformOwnerItemsTest do
  @moduledoc "T-1963 P1-P3 R1-R5 IM1-IM7: the owner list through the real router with real tokens."
  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query
  alias Letflow.Repo
  alias Letflow.ProblemReports.{Comment, Report}
  alias Letflow.Support.OwnerListFixture, as: F
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @path "/api/v1/platform-problem-reports"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    owner = Fixture.mint_token!(tenants.p, ["PLATFORM_ADMIN"])
    p_admin = Fixture.mint_token!(tenants.p, ["TENANT_ADMIN"])
    a_admin = Fixture.mint_token!(tenants.a, ["TENANT_ADMIN"])

    ids =
      F.import!([
        F.item("O-001"),
        F.item("O-002", %{"state" => "closed", "closed" => 1_763_200_000.0})
      ])

    {:ok, Map.merge(tenants, %{owner: owner, p_admin: p_admin, a_admin: a_admin, ids: ids})}
  end

  defp request(fx, token, method, path, body \\ nil),
    do: method |> Fixture.api_conn(path, token, fx.tenant.slug, body) |> Fixture.dispatch_api()

  defp multipart(fx, token, path, parts) do
    {type, body} = F.multipart(parts)

    conn(:post, path, body)
    |> put_req_header("content-type", type)
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-tenant-slug", fx.tenant.slug)
    |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp new_routes(id) do
    [
      {:post, "#{@path}/#{id}/comments", %{"text" => "x"}},
      {:post, "#{@path}/#{id}/state", %{"state" => "waiting"}},
      {:get, "#{@path}/#{id}/images/#{Ecto.UUID.generate()}", nil}
    ]
  end

  test "P1 P2 P3 only the platform owner reaches the new routes; rows stay unchanged", ctx do
    id = ctx.ids["O-001"]
    before_rows = Repo.all(from(r in Report), prefix: ctx.p.schema_name)

    for {token, fx} <- [
          {ctx.p_admin, ctx.p},
          {ctx.a_admin, ctx.a},
          {Fixture.mint_token!(ctx.a, ["PLATFORM_ADMIN"]), ctx.a}
        ],
        {method, path, body} <- new_routes(id) do
      conn = request(fx, token, method, path, body)
      assert conn.status == 403, "#{method} #{path}: #{conn.status}"
    end

    for {token, fx} <- [{ctx.p_admin, ctx.p}, {ctx.a_admin, ctx.a}] do
      assert request(fx, token, :get, @path <> "?class=review").status == 403
    end

    assert Repo.all(from(r in Report), prefix: ctx.p.schema_name) == before_rows
    assert Repo.aggregate(Comment, :count, prefix: ctx.p.schema_name) == 0
  end

  test "R1 R2 R3 review list and detail, exact keys, filters, bad class, decision is a 404",
       ctx do
    conn = request(ctx.p, ctx.owner, :get, @path <> "?class=review&status=all")
    assert conn.status == 200
    body = json(conn)
    assert Map.keys(body) |> Enum.sort() == ["next_before", "reports"]
    assert [s | _] = body["reports"]

    assert Enum.sort(Map.keys(s)) ==
             ~w(added_at class closed_at cycle due entries id kind last_entry_at number status title)

    assert Enum.map(
             json(request(ctx.p, ctx.owner, :get, @path <> "?class=review"))["reports"],
             & &1["number"]
           ) == ["O-001"]

    closed = json(request(ctx.p, ctx.owner, :get, @path <> "?class=review&status=closed"))
    assert Enum.map(closed["reports"], & &1["number"]) == ["O-002"]
    # default class stays problem and shows no review row
    assert json(request(ctx.p, ctx.owner, :get, @path <> "?status=all"))["reports"] == []
    assert request(ctx.p, ctx.owner, :get, @path <> "?class=bogus").status == 400

    detail = json(request(ctx.p, ctx.owner, :get, @path <> "/" <> ctx.ids["O-001"]))

    assert Enum.sort(Map.keys(detail)) ==
             ~w(added_at answer class closed_at cycle due entries id kind last_entry_at number recommended source status steps tasks thread title why)

    conn =
      request(ctx.p, ctx.owner, :post, "#{@path}/#{ctx.ids["O-001"]}/decision", %{
        "action" => "answer",
        "text" => "x"
      })

    assert conn.status == 404
  end

  test "R4 R5 comment and state routes, 409 on a closed item, GET still works", ctx do
    id = ctx.ids["O-001"]
    conn = request(ctx.p, ctx.owner, :post, "#{@path}/#{id}/comments", %{"text" => "Looks wrong"})
    assert conn.status == 201
    assert %{"status" => "owner_reviewed", "thread" => [%{"text" => "Looks wrong"}]} = json(conn)

    assert request(ctx.p, ctx.owner, :post, "#{@path}/#{id}/comments", %{"text" => ""}).status ==
             422

    assert request(ctx.p, ctx.owner, :post, "#{@path}/#{id}/comments", %{
             "text" => "password: hunter2abc"
           }).status == 422

    assert request(ctx.p, ctx.owner, :post, "#{@path}/#{id}/state", %{"state" => "ready"}).status ==
             422

    conn =
      request(ctx.p, ctx.owner, :post, "#{@path}/#{id}/state", %{
        "state" => "closed",
        "text" => "ok"
      })

    assert conn.status == 200 and json(conn)["status"] == "closed"

    for {path, body} <- [{"comments", %{"text" => "again"}}, {"state", %{"state" => "waiting"}}] do
      assert request(ctx.p, ctx.owner, :post, "#{@path}/#{id}/#{path}", body).status == 409
    end

    assert request(ctx.p, ctx.owner, :get, "#{@path}/#{id}").status == 200
    unknown = Ecto.UUID.generate()

    assert request(ctx.p, ctx.owner, :post, "#{@path}/#{unknown}/comments", %{"text" => "x"}).status ==
             404

    assert request(ctx.p, ctx.owner, :post, "#{@path}/not-a-uuid/state", %{"state" => "closed"}).status ==
             404
  end

  test "IM1 IM5 IM6 IM7 multipart screenshots are typed from bytes, served with safe headers",
       ctx do
    id = ctx.ids["O-001"]

    conn =
      multipart(ctx.p, ctx.owner, "#{@path}/#{id}/comments", [
        {"text", nil, nil, "See the shots"},
        {"images[]", "a.png", "image/jpeg", F.png()},
        {"images[]", "b.jpg", "image/png", F.jpeg()}
      ])

    assert conn.status == 201, conn.resp_body
    [entry] = json(conn)["thread"]
    assert [%{"content_type" => "image/png"}, %{"content_type" => "image/jpeg"}] = entry["images"]
    [%{"id" => image_id, "byte_size" => size} | _] = entry["images"]
    assert size == byte_size(F.png())

    conn = request(ctx.p, ctx.owner, :get, "#{@path}/#{id}/images/#{image_id}")
    assert conn.status == 200 and conn.resp_body == F.png()
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]

    # IM6: image of another item, unknown, non-uuid: the same 404 body
    other = ctx.ids["O-002"]
    a = request(ctx.p, ctx.owner, :get, "#{@path}/#{other}/images/#{image_id}")
    b = request(ctx.p, ctx.owner, :get, "#{@path}/#{id}/images/#{Ecto.UUID.generate()}")
    c = request(ctx.p, ctx.owner, :get, "#{@path}/#{id}/images/nope")
    assert [a.status, b.status, c.status] == [404, 404, 404]
    body = fn conn -> conn.resp_body |> Jason.decode!() |> Map.drop(["instance", "trace_id"]) end
    assert body.(a) == body.(b) and body.(b) == body.(c)

    # IM7: text only works as JSON; an image alone (no text) works as multipart
    conn =
      multipart(ctx.p, ctx.owner, "#{@path}/#{id}/comments", [
        {"images[]", "a.png", "image/png", F.png()}
      ])

    assert conn.status == 201
  end

  test "IM2 IM3 IM4 too many, wrong type and too large images write nothing", ctx do
    id = ctx.ids["O-001"]
    comments = fn -> Repo.aggregate(Comment, :count, prefix: ctx.p.schema_name) end
    url = "#{@path}/#{id}/comments"

    seven = for _ <- 1..7, do: {"images[]", "a.png", "image/png", F.png()}
    assert multipart(ctx.p, ctx.owner, url, [{"text", nil, nil, "x"} | seven]).status == 422

    assert multipart(ctx.p, ctx.owner, url, [{"images[]", "a.gif", "image/gif", "GIF89a...."}]).status ==
             422

    assert multipart(ctx.p, ctx.owner, url, [{"images[]", "a.txt", "text/plain", "hello"}]).status ==
             422

    big = F.png() <> :binary.copy(<<0>>, 5_242_881)

    assert multipart(ctx.p, ctx.owner, url, [{"images[]", "big.png", "image/png", big}]).status ==
             413

    assert multipart(ctx.p, ctx.owner, url, [{"images[]", nil, nil, "not a file"}]).status == 422
    assert comments.() == 0
  end
end
