defmodule Letflow.MaintenanceV1Test do
  @moduledoc """
  T-1948 M1-M6, X3: `GET /maintenance/v1/problem-reports`, the read-only export of the PM handoff,
  through the real `Letflow.Router`. `async: false`: the platform pin, the credential hash and the
  rate limiter are VM-global.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Plugs.ProvisionerAuth.RateLimiter
  alias Letflow.ProblemReports.Report
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @token "export-token-for-tests-0123456789abcdef0123456789abcdef"
  @path "/maintenance/v1/problem-reports"

  setup do
    %{p: p, a: a} = Fixture.three_tenants!()
    Fixture.pin!(p.tenant_id)

    previous = %{
      export: Application.get_env(:letflow, Letflow.Plugs.ReportExportAuth),
      limiter: Application.get_env(:letflow, Letflow.Plugs.ProvisionerAuth)
    }

    Application.put_env(:letflow, Letflow.Plugs.ReportExportAuth, sha256: hash(@token))
    RateLimiter.reset()

    on_exit(fn ->
      restore(Letflow.Plugs.ReportExportAuth, previous.export)
      restore(Letflow.Plugs.ProvisionerAuth, previous.limiter)
      RateLimiter.reset()
    end)

    {:ok, p: p, a: a}
  end

  defp restore(key, nil), do: Application.delete_env(:letflow, key)
  defp restore(key, value), do: Application.put_env(:letflow, key, value)
  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp call(path, token \\ @token) do
    conn = conn(:get, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp insert!(p, a, text, age_seconds) do
    now = DateTime.utc_now()

    Repo.insert!(
      %Report{
        tenant_id: p.tenant_id,
        reporter_tenant_id: a.tenant_id,
        reporter_tenant_name: "Acme",
        reporter_user_id: Ecto.UUID.generate(),
        reporter_name: "Ann",
        reporter_roles: ["TENANT_ADMIN"],
        reporter_permissions: ["MyAccessRead"],
        text: text,
        context: %{"route" => "/tasks"},
        server_version: "abc",
        trace_id: "tr",
        consented_at: now,
        inserted_at: DateTime.add(now, -age_seconds, :second)
      },
      prefix: p.schema_name
    )
  end

  test "M1 hash unset: a 404 byte-identical to an unmatched path, no header read", %{p: _p} do
    Application.delete_env(:letflow, Letflow.Plugs.ReportExportAuth)
    unmatched = Letflow.Router.call(conn(:get, "/nothing/here"), Letflow.Router.init([]))
    conn = call(@path, nil)
    assert conn.status == 404
    assert conn.resp_body == unmatched.resp_body
    assert call(@path).status == 404
  end

  test "M2 no, malformed or wrong bearer all answer the same 401" do
    bodies =
      for token <- [nil, "wrong-token"] do
        conn = call(@path, token)
        assert conn.status == 401
        conn.resp_body
      end

    malformed =
      Letflow.Router.call(
        conn(:get, @path) |> put_req_header("authorization", "Basic abc"),
        Letflow.Router.init([])
      )

    assert malformed.status == 401
    assert Enum.uniq([malformed.resp_body | bodies]) |> length() == 1

    assert json(malformed) == %{
             "error" => "unauthorized",
             "message" => "invalid or missing credential"
           }
  end

  test "M3 the right token lists reports after the cursor, in order, holding back young rows", %{
    p: p,
    a: a
  } do
    r1 = insert!(p, a, "one", 120)
    r2 = insert!(p, a, "two", 90)
    _young = insert!(p, a, "three", 1)

    conn = call(@path)
    assert conn.status == 200, conn.resp_body
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    body = json(conn)
    assert Enum.map(body["reports"], & &1["text"]) == ["one", "two"]
    assert body["next_after"] == r2.seq

    body = call(@path <> "?after=#{r1.seq}") |> json()
    assert Enum.map(body["reports"], & &1["text"]) == ["two"]

    empty = call(@path <> "?after=#{r2.seq}") |> json()
    assert empty == %{"reports" => [], "next_after" => r2.seq}

    limited = call(@path <> "?limit=1") |> json()
    assert length(limited["reports"]) == 1
    assert limited["next_after"] == r1.seq
  end

  test "M4 a bad after or limit answers 400" do
    for query <- ["?after=x", "?after=-1", "?limit=0", "?limit=101", "?limit=abc", "?after=1.5"] do
      conn = call(@path <> query)
      assert conn.status == 400, query
      assert json(conn)["error"] == "invalid_request"
    end
  end

  test "M5 the rate limit answers 429 with retry-after" do
    Application.put_env(:letflow, Letflow.Plugs.ProvisionerAuth, limit: 1)
    RateLimiter.reset()
    assert call(@path).status == 200
    conn = call(@path)
    assert conn.status == 429
    assert [retry] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry) >= 1
  end

  test "M6 the answer carries exactly the planned keys and no e-mail", %{p: p, a: a} do
    insert!(p, a, "text", 120)
    assert [report] = call(@path) |> json() |> Map.fetch!("reports")

    assert Map.keys(report) |> Enum.sort() ==
             ~w(context number received_at reporter server_version text trace_id)

    assert Map.keys(report["reporter"]) |> Enum.sort() ==
             ~w(name permissions roles tenant_id tenant_name user_id)

    refute call(@path).resp_body =~ "email"
  end

  test "M7 only GET on the one path; anything else is a 404 behind the credential" do
    assert call("/maintenance/v1/other").status == 404

    post =
      conn(:post, @path)
      |> put_req_header("authorization", "Bearer " <> @token)
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

    assert post.status == 404
  end

  test "X3 a user or platform-admin API token is not the export credential", %{p: p, a: a} do
    token_a = Fixture.mint_token!(a, ["TENANT_ADMIN"])
    token_p = Fixture.mint_token!(p, ["PLATFORM_ADMIN"])

    for token <- [token_a, token_p] do
      assert call(@path, token).status == 401
    end
  end

  test "X4 platform pin unset: the export answers 503" do
    Fixture.unpin!()
    assert call(@path).status == 503
  end
end
