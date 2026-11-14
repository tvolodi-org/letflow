defmodule Letflow.Routers.MeProblemReportsTest do
  @moduledoc """
  T-1948 B1-B5, X1, X2, X4: `POST /api/v1/me/problem-reports` through the real `Letflow.Router`, real
  tenant schemas and real API tokens. The platform company P is pinned; reports land in P's schema only.
  `async: false`: the platform pin is VM-global. Committed-tenant rows are removed by the fixture's own
  `on_exit` (the tenant drop cascades through the schema).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.ProblemReports.Report
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @path "/api/v1/me/problem-reports"

  setup do
    %{p: p, a: a, b: b} = Fixture.three_tenants!()
    Fixture.pin!(p.tenant_id)
    {:ok, p: p, a: a, b: b}
  end

  defp post(fx, token, body) do
    :post |> Fixture.api_conn(@path, token, fx.tenant.slug, body) |> Fixture.dispatch_api()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp reports(fx), do: Repo.all(from(r in Report, order_by: r.seq), prefix: fx.schema_name)

  defp audits(fx) do
    Repo.all(from(e in Entry, where: e.action == "problem_report.sent"), prefix: fx.schema_name)
  end

  defp caller!(fx, roles \\ ["TENANT_ADMIN"]) do
    token = Fixture.mint_token!(fx, roles)

    user_id =
      Repo.one!(
        from(t in Letflow.Identity.ApiToken,
          order_by: [desc: t.inserted_at],
          limit: 1,
          select: t.user_id
        ),
        prefix: fx.schema_name
      )

    {token, user_id}
  end

  defp body(extra \\ %{}) do
    Map.merge(
      %{
        "text" => "The commission screen froze",
        "consent" => true,
        "context" => %{
          "route" => "/admin/assets/documents",
          "ui_language" => "ru",
          "browser" => %{"user_agent" => "UA", "viewport" => "1440x900", "language" => "ru"},
          "actions" => [%{"at" => "2026-11-14T10:00:00Z", "kind" => "click", "name" => "save"}],
          "requests" => [
            %{"method" => "GET", "path" => "/api/v1/tasks", "status" => 500, "trace_id" => "tr-1"}
          ],
          "crash" => %{"name" => "TypeError", "message" => "boom"}
        }
      },
      extra
    )
  end

  test "B1 no consent (missing, string, false) answers 422 and writes nothing anywhere", %{
    p: p,
    a: a
  } do
    {token, _} = caller!(a)

    for bad <- [
          Map.delete(body(), "consent"),
          body(%{"consent" => "true"}),
          body(%{"consent" => false}),
          body(%{"consent" => 1})
        ] do
      conn = post(a, token, bad)
      assert conn.status == 422, conn.resp_body
    end

    assert reports(p) == []
    assert reports(a) == []
    assert audits(a) == []
  end

  test "B1 invalid text and context answer 422", %{p: p, a: a} do
    {token, _} = caller!(a)
    assert post(a, token, body(%{"text" => "   "})).status == 422
    assert post(a, token, body(%{"context" => "nope"})).status == 422
    assert reports(p) == []
  end

  test "B2 + B3 consent: 201 with 3 keys, row in the PLATFORM schema, audit in the reporter's", %{
    p: p,
    a: a
  } do
    {token, user_id} = caller!(a)
    conn = post(a, token, body())
    assert conn.status == 201, conn.resp_body
    resp = json(conn)
    assert Map.keys(resp) |> Enum.sort() == ~w(id number received_at)

    assert [row] = reports(p)
    assert row.id == resp["id"]
    assert resp["number"] == "SR-#{row.seq}"
    assert row.tenant_id == p.tenant_id
    assert row.reporter_tenant_id == a.tenant_id
    assert row.reporter_user_id == user_id
    assert row.reporter_name == "Scope Test Caller"
    assert row.reporter_tenant_name == a.tenant.display_name
    assert row.trace_id not in [nil, ""]
    assert row.context["route"] == "/admin/assets/documents"
    assert row.context["crash"]["name"] == "TypeError"
    assert [%{"status" => 500, "trace_id" => "tr-1"}] = row.context["requests"]

    # the same lists GET /me/access answers for the same token
    access =
      :get
      |> Fixture.api_conn("/api/v1/me/access", token, a.tenant.slug, nil)
      |> Fixture.dispatch_api()
      |> json()

    assert row.reporter_roles == access["roles"]
    assert row.reporter_permissions == access["permissions"]
    assert row.server_version == Letflow.BuildInfo.sha()

    assert reports(a) == []
    assert [entry] = audits(a)
    assert entry.resource_id == resp["number"]
    assert entry.actor_id == user_id
    refute Map.has_key?(entry.after_state, "text")
    refute inspect(entry.after_state) =~ "froze"
    assert entry.after_state["to"] == "platform_company"
  end

  test "B4 the 11th report in an hour answers 429", %{p: p, a: a} do
    {token, user_id} = caller!(a)
    now = DateTime.utc_now()

    for _ <- 1..10 do
      Repo.insert!(
        %Report{
          tenant_id: p.tenant_id,
          reporter_tenant_id: a.tenant_id,
          reporter_user_id: user_id,
          text: "old",
          consented_at: now,
          inserted_at: DateTime.add(now, -60, :second)
        },
        prefix: p.schema_name
      )
    end

    assert post(a, token, body()).status == 429
    assert length(reports(p)) == 10
  end

  test "B5 a reporter in the platform tenant itself works; row and audit in one schema", %{p: p} do
    {token, _} = caller!(p)
    assert post(p, token, body()).status == 201
    assert [_] = reports(p)
    assert [_] = audits(p)
  end

  test "X1 no route reads reports back: GET on the report path is not routed", %{a: a, b: b} do
    {token_a, _} = caller!(a)
    {token_b, _} = caller!(b)
    resp = json(post(a, token_a, body()))

    get = :get |> Fixture.api_conn(@path, token_b, b.tenant.slug, nil) |> Fixture.dispatch_api()

    # an unrouted method on an existing path is refused by the authz gate (403), never served
    assert get.status in [403, 404, 405]
    refute get.resp_body =~ resp["number"]
  end

  test "X1 B's schema stays empty and its audit never names A's number", %{p: p, a: a, b: b} do
    {token_a, _} = caller!(a)
    {token_b, _} = caller!(b)
    number_a = json(post(a, token_a, body()))["number"]
    assert post(b, token_b, body()).status == 201

    assert reports(b) == []

    assert Enum.map(reports(p), & &1.reporter_tenant_id) |> Enum.sort() ==
             Enum.sort([a.tenant_id, b.tenant_id])

    assert Enum.all?(audits(b), &(&1.resource_id != number_a))
  end

  test "X2 ids in the body are ignored (INV-10)", %{p: p, a: a, b: b} do
    {token_b, user_b} = caller!(b)

    forged =
      body(%{
        "tenant_id" => a.tenant_id,
        "user_id" => Ecto.UUID.generate(),
        "reporter_tenant_id" => a.tenant_id,
        "reporter_user_id" => Ecto.UUID.generate(),
        "context" =>
          Map.merge(body()["context"], %{
            "tenant_id" => a.tenant_id,
            "user_id" => "u",
            "roles" => ["PLATFORM_ADMIN"]
          })
      })

    assert post(b, token_b, forged).status == 201
    assert [row] = reports(p)
    assert row.reporter_tenant_id == b.tenant_id
    assert row.reporter_user_id == user_b
    refute Map.has_key?(row.context, "tenant_id")
    refute Map.has_key?(row.context, "roles")
    refute inspect(row.context) =~ a.tenant_id
  end

  test "X4 platform pin unset answers 503 and writes nothing", %{p: p, a: a} do
    Fixture.unpin!()
    {token, _} = caller!(a)
    assert post(a, token, body()).status == 503
    assert reports(p) == []
    assert reports(a) == []
    assert audits(a) == []
  end

  test "any role may report, CANDIDATE included", %{p: p, a: a} do
    {token, _} = caller!(a, ["CANDIDATE"])
    assert post(a, token, body()).status == 201
    assert length(reports(p)) == 1
  end
end
