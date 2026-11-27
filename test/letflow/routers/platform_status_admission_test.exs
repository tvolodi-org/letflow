defmodule Letflow.Routers.PlatformStatusAdmissionTest do
  @moduledoc """
  T-3034: `GET /api/v1/platform-status/admission` through the full
  `Letflow.Router` with real bearer tokens.

  The route shows TENANT DATA (the per-tenant in-flight rows and the oldest
  in-flight admission), so it is platform-scope: the platform operator of the
  configured platform tenant reads it, every other caller gets the same fixed
  403, and no token is 401. The tenant schema names are hashed, so even the
  operator sees a pseudonym.
  """

  use Letflow.DataCase, async: false

  import Plug.Test

  alias Letflow.Admission
  alias Letflow.Admission.Observability
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @path "/api/v1/platform-status/admission"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp get_as(token, slug),
    do: Fixture.api_conn(:get, @path, token, slug, nil) |> Fixture.dispatch_api()

  test "the platform operator reads the counters over real HTTP", ctx do
    token = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])
    resp = get_as(token, ctx.p.tenant.slug)

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)

    assert body["available"] == true
    assert body["tracked_tenants"] >= 0
    assert body["in_use"] >= 0
    assert body["cap"] >= 1
    assert body["reserved_headroom"] >= 0
    assert body["pool_size"] >= 1
    assert body["rejections"]["global"] >= 0
    assert body["rejections"]["tenant"] >= 0
    assert is_list(body["tenants"])
  end

  test "the tenant rows carry hashed tenant names and the route class, never a raw name", ctx do
    schema = "tenant_" <> String.replace(Ecto.UUID.generate(), "-", "")
    {:ok, ref} = Admission.try_acquire({:tenant, schema})
    on_exit(fn -> Admission.release(ref) end)

    token = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])
    resp = get_as(token, ctx.p.tenant.slug)

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)

    row = Enum.find(body["tenants"], &(&1["tenant"] == Observability.hash_tenant(schema)))
    assert row, "the tenant of the answer is not in the rows"
    assert row["in_use"] == 1
    assert is_list(row["routes"])

    # the raw schema name is nowhere in the answer
    refute resp.resp_body =~ schema
  end

  test "a tenant admin of an ordinary tenant gets the same fixed 403", ctx do
    token = Fixture.mint_token!(ctx.a, ["TENANT_ADMIN"])
    resp = get_as(token, ctx.a.tenant.slug)

    assert resp.status == 403
    refute resp.resp_body =~ "admission"
  end

  test "no token is 401", ctx do
    resp =
      conn(:get, @path)
      |> Plug.Conn.put_req_header("x-tenant-slug", ctx.a.tenant.slug)
      |> Fixture.dispatch_api()

    assert resp.status == 401
  end
end
