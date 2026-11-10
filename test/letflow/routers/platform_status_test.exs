defmodule Letflow.Routers.PlatformStatusTest do
  @moduledoc """
  T-1607: `GET /api/v1/platform-status/backup` through the full `Letflow.Router` with real bearer
  tokens (B3, B4). The platform tenant's PLATFORM_ADMIN reads it; every other caller gets the same
  fixed 403; no token is 401.
  """

  use Letflow.DataCase, async: false

  import Plug.Test

  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @path "/api/v1/platform-status/backup"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    old = Application.get_env(:letflow, :backup_status_dir)

    on_exit(fn ->
      if old,
        do: Application.put_env(:letflow, :backup_status_dir, old),
        else: Application.delete_env(:letflow, :backup_status_dir)
    end)

    {:ok, tenants}
  end

  defp get_as(token, slug),
    do: Fixture.api_conn(:get, @path, token, slug, nil) |> Fixture.dispatch_api()

  @tag :tmp_dir
  test "B3 the platform operator reads the line over real HTTP; no detail, path or env", ctx do
    dir = ctx.tmp_dir
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    File.write!(
      Path.join(dir, "dump.json"),
      Jason.encode!(%{
        job: "dump",
        env: "qa-env-name",
        ts: ts,
        exit: 0,
        ok: true,
        detail: "sets=2 /opt/backups/qa"
      })
    )

    File.write!(Path.join(dir, "prune.json"), String.duplicate("x", 5000))
    Application.put_env(:letflow, :backup_status_dir, dir)

    token = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])
    resp = get_as(token, ctx.p.tenant.slug)
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["configured"] == true
    jobs = Map.new(body["jobs"], &{&1["job"], &1["state"]})

    assert jobs == %{
             "dump" => "ok",
             "base" => "missing",
             "prune" => "unreadable",
             "restore_test" => "missing"
           }

    refute resp.resp_body =~ "qa-env-name"
    refute resp.resp_body =~ "/opt/backups"
    refute resp.resp_body =~ "detail"
    refute resp.resp_body =~ dir
  end

  test "B2 over HTTP: not configured", ctx do
    Application.delete_env(:letflow, :backup_status_dir)
    token = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])
    resp = get_as(token, ctx.p.tenant.slug)
    assert resp.status == 200
    assert Jason.decode!(resp.resp_body) == %{"configured" => false, "jobs" => []}
  end

  test "B4 a tenant admin and another tenant's admin get the same fixed 403; no token is 401",
       ctx do
    tenant_admin = Fixture.mint_token!(ctx.a, ["TENANT_ADMIN"])
    other_admin = Fixture.mint_token!(ctx.a, ["PROCESS_DESIGNER"])

    r1 = get_as(tenant_admin, ctx.a.tenant.slug)
    r2 = get_as(other_admin, ctx.a.tenant.slug)
    assert r1.status == 403
    assert r2.status == 403

    assert Map.delete(Jason.decode!(r1.resp_body), "trace_id") ==
             Map.delete(Jason.decode!(r2.resp_body), "trace_id")

    refute r1.resp_body =~ "configured"

    anon =
      conn(:get, @path)
      |> Plug.Conn.put_req_header("x-tenant-slug", ctx.a.tenant.slug)
      |> Fixture.dispatch_api()

    assert anon.status == 401
  end
end
