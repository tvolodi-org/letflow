defmodule Letflow.Routers.MaintenanceOwnerListV1Test do
  @moduledoc "T-1963 IMP1-IMP7: the JSON import behind the owner-list credential, through `Letflow.Router`."
  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query

  alias Letflow.Plugs.ProvisionerAuth.RateLimiter
  alias Letflow.ProblemReports.{Comment, CommentImage, Report}
  alias Letflow.Repo
  alias Letflow.Support.OwnerListFixture, as: F
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @token "owner-list-token-for-tests-0123456789abcdef0123456789abcdef"
  @export "export-token-for-tests-0123456789abcdef0123456789abcdef"
  @path "/maintenance/v1/owner-list/import"

  setup do
    %{p: p, a: a} = Fixture.three_tenants!()
    Fixture.pin!(p.tenant_id)
    previous = Application.get_env(:letflow, Letflow.Plugs.ReportExportAuth)
    limiter = Application.get_env(:letflow, Letflow.Plugs.ProvisionerAuth)

    Application.put_env(:letflow, Letflow.Plugs.ReportExportAuth,
      sha256: hash(@export),
      owner_list_sha256: hash(@token)
    )

    RateLimiter.reset()

    on_exit(fn ->
      restore(Letflow.Plugs.ReportExportAuth, previous)
      restore(Letflow.Plugs.ProvisionerAuth, limiter)
      RateLimiter.reset()
    end)

    {:ok, p: p, a: a}
  end

  defp restore(key, nil), do: Application.delete_env(:letflow, key)
  defp restore(key, value), do: Application.put_env(:letflow, key, value)
  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp post(body, token \\ @token, path \\ @path) do
    conn = conn(:post, path, if(is_binary(body), do: body, else: Jason.encode!(body)))
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp doc do
    thread = [
      %{
        "id" => 1,
        "ts" => 1_763_110_000.0,
        "author" => "owner",
        "type" => "finding",
        "text" => "first",
        "cycle" => 1,
        "images" => [%{"data_base64" => Base.encode64(F.png())}]
      },
      %{
        "id" => 2,
        "ts" => 1_763_110_100.0,
        "author" => "operator",
        "type" => "answer",
        "text" => "second",
        "cycle" => 1
      }
    ]

    F.document([
      F.item("O-001"),
      F.item("O-002", %{"state" => "closed", "closed" => 1_763_200_000.0, "kind" => "decision"}),
      F.item("O-003", %{
        "state" => "in-work",
        "thread" => thread,
        "tasks" => ["T-1", "T-2"],
        "cycle" => 2
      })
    ])
  end

  test "IMP1 IMP2 imports items with thread and image; a second run skips them", ctx do
    conn = post(doc())
    assert conn.status == 200, conn.resp_body
    assert json(conn) == %{"imported" => ["O-001", "O-002", "O-003"], "skipped" => []}

    rows = Repo.all(from(r in Report, order_by: r.owner_ref), prefix: ctx.p.schema_name)

    assert Enum.map(rows, &{&1.class, &1.status, &1.kind}) ==
             [
               {"review", "for_review", "review"},
               {"review", "closed", "decision"},
               {"review", "in_work", "review"}
             ]

    [one, two, three] = rows

    assert one.due == ~D[2026-12-01] and one.reporter_user_id == nil and
             one.text == "Check the stock count screen"

    assert DateTime.to_unix(two.closed_at) == 1_763_200_000 and one.closed_at == nil
    assert three.tasks == ["T-1", "T-2"] and three.cycle == 2
    assert DateTime.to_unix(one.consented_at) == 1_763_100_000

    thread = Repo.all(from(c in Comment, order_by: c.seq), prefix: ctx.p.schema_name)
    assert Enum.map(thread, & &1.text) == ["first", "second"]

    assert [%{content_type: "image/png", position: 1}] =
             Repo.all(CommentImage, prefix: ctx.p.schema_name)

    again = post(doc())
    assert json(again) == %{"imported" => [], "skipped" => ["O-001", "O-002", "O-003"]}
    assert Repo.aggregate(Report, :count, prefix: ctx.p.schema_name) == 3
    assert Repo.aggregate(Comment, :count, prefix: ctx.p.schema_name) == 2
  end

  test "IMP3 IMP4 one bad field writes nothing and names the item and path, never the value",
       ctx do
    bad = F.item("O-002", %{"due" => "tomorrow-maybe"})
    conn = post(F.document([F.item("O-001"), bad]))
    assert conn.status == 422
    assert %{"error" => "invalid_request", "message" => message} = json(conn)
    assert message =~ "O-002 due"
    refute message =~ "tomorrow"
    assert Repo.aggregate(Report, :count, prefix: ctx.p.schema_name) == 0

    for broken <- [
          %{"format" => "other", "version" => 1, "items" => [F.item()]},
          %{"format" => "letflow-owner-list", "version" => 2, "items" => [F.item()]},
          F.document([]),
          F.document([F.item("O-001"), F.item("O-001")]),
          F.document([F.item("O-001", %{"state" => "done"})]),
          F.document([
            F.item("O-001", %{
              "thread" => [
                %{
                  "ts" => 1.0e9,
                  "author" => "owner",
                  "type" => "finding",
                  "cycle" => 1,
                  "images" => [%{"data_base64" => Base.encode64("GIF89a")}]
                }
              ]
            })
          ]),
          F.document([
            F.item("O-001", %{
              "thread" => [
                %{"ts" => 1.0e9, "author" => "owner", "type" => "finding", "cycle" => 5}
              ]
            })
          ])
        ] do
      assert post(broken).status == 422
    end

    assert post("[1,2]").status == 422
    assert Repo.aggregate(Report, :count, prefix: ctx.p.schema_name) == 0
  end

  test "IMP5 credential errors: none, export token, bad token are 401; unset hash is a 404" do
    for token <- [nil, @export, "wrong"], do: assert(post(doc(), token).status == 401)

    Application.put_env(:letflow, Letflow.Plugs.ReportExportAuth, sha256: hash(@export))
    unmatched = post(doc(), @token, "/maintenance/v1/owner-list/nothing")
    assert post(doc()).status == 404
    # the same standard 404 as an unmatched path of the mount
    assert post(doc()).resp_body == unmatched.resp_body

    # the export token on the export mount is untouched by the new mount
    export =
      conn(:get, "/maintenance/v1/problem-reports")
      |> put_req_header("authorization", "Bearer " <> @export)

    assert Letflow.Router.call(export, Letflow.Router.init([])).status == 200
    # the owner-list token is refused on the export mount
    assert (conn(:get, "/maintenance/v1/problem-reports")
            |> put_req_header("authorization", "Bearer " <> @token)
            |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))).status == 401
  end

  test "IMP5b not JSON is 415, unknown path under the mount is 404" do
    conn =
      conn(:post, @path, "x")
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "text/plain")

    assert Letflow.Router.call(conn, Letflow.Router.init([])).status == 415
    assert post(doc(), @token, "/maintenance/v1/owner-list/other").status == 404
  end

  test "IMP6 its rate limit is a class of its own" do
    Application.put_env(:letflow, Letflow.Plugs.ProvisionerAuth, limit: 2, window_seconds: 60)
    assert post(F.document([F.item("O-011")])).status == 200
    assert post(F.document([F.item("O-011")])).status == 200
    assert post(F.document([F.item("O-011")])).status == 429

    export =
      conn(:get, "/maintenance/v1/problem-reports")
      |> put_req_header("authorization", "Bearer " <> @export)

    assert Letflow.Router.call(export, Letflow.Router.init([])).status == 200
  end

  test "IMP7 imported items appear neither in the PM export nor in My reports", ctx do
    assert post(doc()).status == 200

    Repo.update_all(Report, [set: [inserted_at: ~U[2020-01-01 00:00:00.000000Z]]],
      prefix: ctx.p.schema_name
    )

    export =
      conn(:get, "/maintenance/v1/problem-reports")
      |> put_req_header("authorization", "Bearer " <> @export)

    conn = Letflow.Router.call(export, Letflow.Router.init([]))
    assert json(conn)["reports"] == []

    token = Fixture.mint_token!(ctx.a, ["TENANT_ADMIN"])

    mine =
      Fixture.api_conn(:get, "/api/v1/me/problem-reports", token, ctx.a.tenant.slug, nil)
      |> Fixture.dispatch_api()

    assert json(mine)["reports"] == []
  end
end
