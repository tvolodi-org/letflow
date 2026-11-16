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

  test "M2 another company never reads the reporter’s rows", %{a: a, b: b} do
    {token_a, _} = caller!(a)
    {token_b, _} = caller!(b)
    resp = json(post(a, token_a, body()))

    get = :get |> Fixture.api_conn(@path, token_b, b.tenant.slug, nil) |> Fixture.dispatch_api()

    # The self-service read is filtered by tenant AND user.
    assert get.status == 200
    assert json(get) == %{"reports" => [], "has_more" => false}
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

  test "REQ-872 a STOREKEEPER-only caller reports and lists its own report; a colleague sees none",
       %{a: a} do
    {token, _} = caller!(a, ["STOREKEEPER"])
    resp = post(a, token, body())
    assert resp.status == 201
    number = json(resp)["number"]

    get = :get |> Fixture.api_conn(@path, token, a.tenant.slug, nil) |> Fixture.dispatch_api()
    assert get.status == 200
    assert %{"reports" => [mine], "has_more" => false} = json(get)
    assert mine["number"] == number
    assert mine["status"] == "received"

    {other, _} = caller!(a, ["STOREKEEPER"])

    other_get =
      :get |> Fixture.api_conn(@path, other, a.tenant.slug, nil) |> Fixture.dispatch_api()

    assert other_get.status == 200
    assert json(other_get) == %{"reports" => [], "has_more" => false}
  end

  # ── T-2015 image tests (IM1-IM5) ───────────────────────────────────────

  alias Letflow.ProblemReports.ReportImage
  alias Letflow.Support.OwnerListFixture, as: F

  defp images(fx),
    do: Repo.all(from(i in ReportImage, order_by: i.position), prefix: fx.schema_name)

  defp image_body(images_list) do
    body(%{
      "images" =>
        Enum.map(images_list, fn {bytes, ct} ->
          %{"data_base64" => Base.encode64(bytes), "content_type" => ct}
        end)
    })
  end

  test "IM1 valid PNG stored under the platform prefix with correct fields", %{p: p, a: a} do
    {token, _} = caller!(a)
    conn = post(a, token, image_body([{F.png(), "image/png"}]))
    assert conn.status == 201, conn.resp_body

    assert [row] = reports(p)
    assert [img] = images(p)
    assert img.report_id == row.id
    assert img.content_type == "image/png"
    assert img.bytes == F.png()
    assert img.position == 1
    assert img.size == byte_size(F.png())
    # Images land only in the platform schema (INV-1)
    assert images(a) == []
  end

  test "IM2 valid JPEG stored; PNG and JPEG together (2 images)", %{p: p, a: a} do
    {token, _} = caller!(a)
    conn = post(a, token, image_body([{F.png(), "image/png"}, {F.jpeg(), "image/jpeg"}]))
    assert conn.status == 201, conn.resp_body
    assert [img1, img2] = images(p)
    assert img1.content_type == "image/png"
    assert img2.content_type == "image/jpeg"
    assert img1.position == 1
    assert img2.position == 2
  end

  test "IM3 more than 3 images answers 422 (invalid images field)", %{p: p, a: a} do
    {token, _} = caller!(a)
    four = List.duplicate({F.png(), "image/png"}, 4)
    conn = post(a, token, image_body(four))
    assert conn.status == 422, conn.resp_body
    assert reports(p) == []
  end

  test "IM4 type mismatch (PNG bytes declared as JPEG) answers 422", %{p: p, a: a} do
    {token, _} = caller!(a)
    conn = post(a, token, image_body([{F.png(), "image/jpeg"}]))
    assert conn.status == 422, conn.resp_body
    assert reports(p) == []
  end

  # IM5 (oversize > 5 MiB) cannot be tested through the router: the 2 MiB body cap is hit first
  # (the base64 of a 5 MiB image is ~6.7 MiB). The cap is validated in Capture.parse_images;
  # see test/letflow/problem_reports/capture_test.exs for the unit-level proof.
end
