defmodule Letflow.Routers.ModulesVersionGateTest do
  @moduledoc """
  T-1548 / RU-S3 (decision 0055 D5): the deploy-skew gate of `Letflow.Routers.Modules`, through the
  real HTTP router (`Letflow.Router.call/2` with a bearer token and `X-Tenant-Slug`).
  `async: false`: `TenantFixture.provisioned_tenant!/1` switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantFixture

  @path "/api/v1/modules/fixture/items/42"

  defp request(ctx, path \\ @path, trace_id \\ nil) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(fn c -> if trace_id, do: put_req_header(c, "x-trace-id", trace_id), else: c end)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp tenant_ctx(prefix, role \\ :TASK_WORKER) do
    t = TenantFixture.provisioned_tenant!(slug_prefix: prefix, display_name: "T-1548 gate")

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "t1548-#{Ecto.UUID.generate()}",
        display_name: "T-1548 user",
        email: "t1548-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: t.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: [Atom.to_string(role)], expires_at: nil},
        prefix: t.schema_name
      )

    %{schema_name: t.schema_name, slug: t.tenant.slug, plaintext: plaintext}
  end

  defp install!(ctx) do
    {:ok, _} =
      Installs.install("fixture", Ecto.UUID.generate(),
        prefix: ctx.schema_name,
        rationale: "test: gate"
      )

    ctx
  end

  defp set_version!(ctx, version) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "fixture"),
        [set: [version: version]],
        prefix: ctx.schema_name
      )

    ctx
  end

  defp ungranted_role do
    Enum.find(Letflow.Api.Authorization.roles(), fn role ->
      role not in [:PLATFORM_ADMIN, :TENANT_ADMIN] and
        role not in Map.keys(Letflow.Modules.Fixture.manifest().role_grants)
    end)
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["code"]

  defp count_queries(fun) do
    ref = make_ref()
    me = self()
    id = "t1548-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:letflow, :repo, :query],
      fn _e, _m, meta, _c ->
        if meta.source == "tenant_modules", do: send(me, {ref, :q})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)
    {result, drain(ref, 0)}
  end

  defp drain(ref, n) do
    receive do
      {^ref, :q} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  test "G1 below min_data_version -> 503 module_upgrade_required, no versions in body" do
    ctx = "t1548-g1" |> tenant_ctx() |> install!() |> set_version!("0.0.9")
    conn = request(ctx)
    assert conn.status == 503
    assert code(conn) == "module_upgrade_required"
    refute conn.resp_body =~ "0.0.9"
    refute conn.resp_body =~ "0.1.0"
  end

  test "G2 at the minimum is served" do
    ctx = "t1548-g2" |> tenant_ctx() |> install!()
    conn = request(ctx)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"fixture" => true, "id" => "42"}
  end

  test "G3 tenant data ahead of the build -> 503 module_version_ahead" do
    ctx = "t1548-g3" |> tenant_ctx() |> install!() |> set_version!("9.9.9")
    conn = request(ctx)
    assert conn.status == 503
    assert code(conn) == "module_version_ahead"
  end

  test "G4 never-installed and uninstalled stay byte-identical 404" do
    ctx = tenant_ctx("t1548-g4")
    never = request(ctx, @path, "trace-g4")
    unknown = request(ctx, "/api/v1/modules/nope/items/42", "trace-g4")
    assert never.status == 404
    assert never.resp_body == unknown.resp_body
  end

  test "G5 exactly one tenant_modules query for 200, 503 and 404" do
    ok = "t1548-g5" |> tenant_ctx() |> install!()
    {c, n} = count_queries(fn -> request(ok) end)
    assert {c.status, n} == {200, 1}

    set_version!(ok, "0.0.9")
    {c, n} = count_queries(fn -> request(ok) end)
    assert {c.status, n} == {503, 1}

    set_version!(ok, "9.9.9")
    {c, n} = count_queries(fn -> request(ok) end)
    assert {c.status, n} == {503, 1}

    none = tenant_ctx("t1548-g5b")
    {c, n} = count_queries(fn -> request(none) end)
    assert {c.status, n} == {404, 1}
  end

  test "G6 refusal precedes the module's permission check" do
    ctx =
      "t1548-g6"
      |> tenant_ctx(ungranted_role())
      |> install!()

    # An ungranted-role token is not granted FixtureRead: 403 when in range, 503 when out of range.
    in_range = request(ctx)
    assert in_range.status == 403
    set_version!(ctx, "0.0.9")
    assert request(ctx).status == 503
  end

  test "G7 cross-tenant: tenant A refused does not affect tenant B" do
    a = "t1548-g7a" |> tenant_ctx() |> install!() |> set_version!("0.0.9")
    b = "t1548-g7b" |> tenant_ctx() |> install!()
    assert request(a).status == 503
    assert request(b).status == 200
    # A's token with B's slug is refused by auth, no gate answer leaks.
    crossed = request(%{a | slug: b.slug})
    assert crossed.status in [401, 403, 404]
    refute code(crossed) in ["module_upgrade_required", "module_version_ahead"]
  end

  test "G8 a changed manifest hash with an in-range version is served (409 is not this gate)" do
    ctx = "t1548-g8" |> tenant_ctx() |> install!()

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "fixture"),
        [set: [manifest_hash: String.duplicate("0", 64)]],
        prefix: ctx.schema_name
      )

    assert request(ctx).status == 200
  end
end
