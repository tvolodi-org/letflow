defmodule Letflow.Modules.RuntimeDemo.RouterTest do
  @moduledoc """
  T-1641: the runtime-update gates driven through the real router with real tokens, on the QA-only demo
  module: a rollback that succeeds, `module_version_ahead`, the `min_data_version` gate and
  `rollback_below_min_data_version`. Committed tenants, Sandbox `:auto`, `async: false`; the release is
  changed at run time exactly as the QA operator changes `LETFLOW_RUNTIME_DEMO_RELEASE`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EventTypes
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @why "T-1641 test: runtime demo"
  @ping "/api/v1/modules/runtime_demo/ping"

  setup do
    old = Application.get_env(:letflow, :runtime_demo_release)
    Application.put_env(:letflow, :runtime_demo_release, "0.1.0")

    on_exit(fn ->
      if old,
        do: Application.put_env(:letflow, :runtime_demo_release, old),
        else: Application.delete_env(:letflow, :runtime_demo_release)
    end)

    a = tenant!("t1641a")
    b = tenant!("t1641b")

    %{
      a: a,
      admin: user!(a, "TENANT_ADMIN"),
      worker: user!(a, "TASK_WORKER"),
      b_admin: user!(b, "TENANT_ADMIN")
    }
  end

  defp release(v), do: Application.put_env(:letflow, :runtime_demo_release, v)

  defp tenant!(prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _} = EventTypes.seed!(tenant.schema_name)

    %{
      tenant_id: tenant.tenant_id,
      schema: tenant.schema_name,
      slug: Repo.get!(Letflow.Identity.Tenant, tenant.tenant_id).slug
    }
  end

  defp user!(ctx, role) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "t1641-#{Ecto.UUID.generate()}",
        display_name: "Runtime Demo Test User",
        email: "t1641-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: [role], expires_at: nil}, prefix: ctx.schema)

    %{plaintext: plaintext, slug: ctx.slug}
  end

  defp call(method, path, user, body \\ nil) do
    conn(method, path, body && Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> user.plaintext)
    |> put_req_header("x-tenant-slug", user.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp install!(user) do
    conn =
      call(:post, "/api/v1/tenant/modules", user, %{
        "module_id" => "runtime_demo",
        "rationale" => @why
      })

    assert conn.status == 201, conn.resp_body
  end

  defp upgrade!(user) do
    plan = call(:post, "/api/v1/tenant/modules/runtime_demo/upgrade/plan", user, %{})
    assert plan.status == 200, plan.resp_body
    hash = json(plan)["plan_hash"]

    conn =
      call(:post, "/api/v1/tenant/modules/runtime_demo/upgrade", user, %{
        "plan_hash" => hash,
        "rationale" => @why
      })

    assert conn.status == 200, conn.resp_body
  end

  defp rollback(user, target) do
    call(:post, "/api/v1/tenant/modules/runtime_demo/rollback", user, %{
      "target_version" => target,
      "rationale" => @why
    })
  end

  defp stored(ctx),
    do: Repo.get_by!(TenantModule, [module_id: "runtime_demo"], prefix: ctx.schema).version

  test "install at 0.1.0: the ping route answers 200 for a tenant admin", ctx do
    install!(ctx.admin)
    assert stored(ctx.a) == "0.1.0"
    conn = call(:get, @ping, ctx.admin)
    assert conn.status == 200
    assert json(conn) == %{"runtime_demo" => true, "release" => "0.1.0"}
  end

  test "access: a task worker is refused, and another tenant without the module gets the unknown-module 404",
       ctx do
    install!(ctx.admin)
    assert call(:get, @ping, ctx.worker).status == 403
    other = call(:get, @ping, ctx.b_admin)
    assert other.status == 404

    unknown = call(:get, "/api/v1/modules/no_such_module/ping", ctx.b_admin)
    assert unknown.status == 404
    assert Map.delete(json(other), "trace_id") == Map.delete(json(unknown), "trace_id")
  end

  test "rollback succeeds: upgrade 0.1.0 -> 0.2.0, then back to 0.1.0", ctx do
    install!(ctx.admin)
    release("0.2.0")
    upgrade!(ctx.admin)
    assert stored(ctx.a) == "0.2.0"

    conn = rollback(ctx.admin, "0.1.0")
    assert conn.status == 200, conn.resp_body
    assert stored(ctx.a) == "0.1.0"
  end

  test "ahead: data at 0.2.0 under a 0.1.0 build is module_version_ahead on the route and on rollback",
       ctx do
    install!(ctx.admin)
    release("0.2.0")
    upgrade!(ctx.admin)
    release("0.1.0")

    ping = call(:get, @ping, ctx.admin)
    assert ping.status == 503
    assert ping.resp_body =~ "module_version_ahead"

    rb = rollback(ctx.admin, "0.1.0")
    assert rb.status == 409
    assert rb.resp_body =~ "module_version_ahead"
    assert stored(ctx.a) == "0.2.0"
  end

  test "below min: 0.3.0 raises min_data_version; the gate answers, the upgrade clears it, rollback is refused",
       ctx do
    install!(ctx.admin)
    release("0.2.0")
    upgrade!(ctx.admin)
    release("0.3.0")

    gate = call(:get, @ping, ctx.admin)
    assert gate.status == 503
    assert gate.resp_body =~ "module_upgrade_required"

    upgrade!(ctx.admin)
    assert stored(ctx.a) == "0.3.0"
    assert call(:get, @ping, ctx.admin).status == 200

    rb = rollback(ctx.admin, "0.2.0")
    assert rb.status == 409
    assert rb.resp_body =~ "rollback_below_min_data_version"
    assert stored(ctx.a) == "0.3.0"
  end
end
