defmodule Letflow.PlatformProcesses.ProvisionerProcessCreateTest do
  @moduledoc """
  T-2728 (pilot gap G17d): route 3 (`POST /admin/v1/tenants`) starts the `platform.register_tenant`
  process through the system-authority start when the ONE setting
  (`LETFLOW_PROVISIONER_CREATE_VIA_PROCESS`, default off) is on; route 4 (the sign-up) goes through the
  same `TenantProvisioner.create/2`, so the test of its route name is here too.

  Rows: P1 setting OFF = the old path (201, no admission, no instance); P2 ON -> 202 + poll, an
  instance exists, no tenant yet, nothing secret in the answer; P3 finished -> replay answers 200 with
  today's body keys, `GET` answers active; P4 other values -> 409; P5 demo cap and both budgets answer
  409 BEFORE any instance or admission; P6 a failing step -> instance ERROR, `GET` says failed with a
  closed reason, no canary in the answer or the debug log; P7 ON with the runner off -> the old path;
  P8 the fast finish answers the old 201 body; P9 route 4 starts an instance with the signup route name.

  `async: false`: the platform tenant pin and the provisioner settings are VM-global.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Engine.PlatformStepRunner
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.Tenant
  alias Letflow.Plugs.ProvisionerAuth.RateLimiter
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RegisterTenantProcessFixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioner
  alias Letflow.TenantProvisioner.Admission
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantProvisioner.Register
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @write_token "write-credential-for-tests-0123456789abcdef0123456789abcdef"
  @server_url "https://letflow.qa.example"

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "t2728-plat")
    Fixture.pin!(platform.tenant_id)
    RegisterTenantProcessFixture.seed!(platform.schema_name)

    previous = %{
      auth: Application.get_env(:letflow, Letflow.Plugs.ProvisionerAuth),
      prov: Application.get_env(:letflow, Letflow.TenantProvisioner),
      url: Application.get_env(:letflow, :provisioner_public_base_url),
      runner: Application.get_env(:letflow, :start_platform_step_runner)
    }

    Application.put_env(:letflow, Letflow.Plugs.ProvisionerAuth,
      write_sha256: :crypto.hash(:sha256, @write_token) |> Base.encode16(case: :lower)
    )

    put_provisioner(
      allowed_hostname_suffixes: ["qa.example"],
      demo_lifetime_days: 14,
      default_modules: [],
      create_via_process: true,
      create_wait_seconds: 0
    )

    Application.put_env(:letflow, :provisioner_public_base_url, @server_url)
    Application.put_env(:letflow, :start_platform_step_runner, true)
    RateLimiter.reset()

    on_exit(fn ->
      restore(Letflow.Plugs.ProvisionerAuth, previous.auth)
      restore(Letflow.TenantProvisioner, previous.prov)
      restore(:provisioner_public_base_url, previous.url)
      restore(:start_platform_step_runner, previous.runner)
      RateLimiter.reset()
    end)

    %{platform: platform}
  end

  defp put_provisioner(opts), do: Application.put_env(:letflow, Letflow.TenantProvisioner, opts)

  defp restore(key, nil), do: Application.delete_env(:letflow, key)
  defp restore(key, value), do: Application.put_env(:letflow, key, value)

  defp post(body) do
    conn(:post, "/admin/v1/tenants", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> @write_token)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp get(id) do
    conn(:get, "/admin/v1/tenants/#{id}")
    |> put_req_header("authorization", "Bearer " <> @write_token)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp body(overrides \\ %{}) do
    id = Ecto.UUID.generate()
    hex = String.slice(String.replace(id, "-", ""), 0, 12)

    Map.merge(
      %{
        "tenant_id" => id,
        "name" => "T-2728 Demo",
        "language" => "en",
        "tier" => "demo",
        "owner_email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "hostname" => "h#{hex}.qa.example",
        "idp_realm_id" => "t-" <> String.slice(String.replace(id, "-", ""), 0, 20)
      },
      overrides
    )
  end

  defp track(tenant_id), do: on_exit(fn -> drop_tenant!(tenant_id) end)

  defp drop_tenant!(tenant_id) do
    Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
      _invalid -> :ok
    end

    Repo.delete_all(from(a in Admission, where: a.tenant_id == ^tenant_id))
    Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^tenant_id))
    Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant_id))
    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
  end

  defp run_steps(ctx),
    do: Enum.each(1..16, fn _ -> PlatformStepRunner.run_due(ctx.platform.schema_name) end)

  defp instance_count(ctx),
    do: Repo.aggregate(InstanceProjection, :count, prefix: ctx.platform.schema_name)

  defp admission_count, do: Repo.aggregate(Admission, :count)

  defp started_events(ctx, instance_id) do
    Repo.all(
      from(e in Event,
        where: e.instance_id == ^instance_id and e.event_type == "INSTANCE_STARTED"
      ),
      prefix: ctx.platform.schema_name
    )
  end

  test "P1 setting OFF: the old synchronous path, no admission, no instance", ctx do
    put_provisioner(
      allowed_hostname_suffixes: ["qa.example"],
      demo_lifetime_days: 14,
      default_modules: []
    )

    b = body()
    track(b["tenant_id"])
    conn = post(b)

    assert conn.status == 201, conn.resp_body
    assert json(conn)["status"] == "active"
    assert admission_count() == 0
    assert instance_count(ctx) == 0
  end

  test "P2 ON: 202 + poll, an instance exists, no tenant yet, no secret in the answer", ctx do
    b = body()
    track(b["tenant_id"])
    before = instance_count(ctx)

    conn = post(b)

    assert conn.status == 202, conn.resp_body
    answer = json(conn)
    assert answer["status"] == "provisioning"
    assert answer["poll"] == "/admin/v1/tenants/" <> b["tenant_id"]
    assert Enum.sort(Map.keys(answer)) == ["poll", "status", "tenant_id"]
    refute conn.resp_body =~ b["owner_email"]
    refute conn.resp_body =~ b["idp_realm_id"]

    assert instance_count(ctx) == before + 1
    assert %Admission{instance_id: instance_id} = Repo.get(Admission, b["tenant_id"])
    assert [_event] = started_events(ctx, instance_id)
    refute Repo.get(Tenant, b["tenant_id"]), "nothing is created before the step runs"

    assert get(b["tenant_id"]) |> json() |> Map.get("status") == "provisioning"
  end

  test "P3 + P4 finished: replay answers 200 with today's keys; other values answer 409", ctx do
    b = body()
    track(b["tenant_id"])
    assert post(b).status == 202
    run_steps(ctx)

    replay = post(b)
    assert replay.status == 200, replay.resp_body
    assert Enum.sort(Map.keys(json(replay))) == ["handover", "server_url", "status", "tenant_id"]
    assert json(replay)["handover"] == %{"login_url" => "https://" <> b["hostname"]}
    assert instance_count(ctx) == 1, "the replay starts no second instance"

    got = json(get(b["tenant_id"]))
    assert got["status"] == "active"
    assert got["server_url"] == @server_url

    other = post(Map.put(b, "name", "Another name"))
    assert other.status == 409
    assert json(other)["error"] == "conflict"
    assert instance_count(ctx) == 1
  end

  test "P5 the demo cap and both budgets answer 409 before any instance or admission", ctx do
    put_provisioner(
      allowed_hostname_suffixes: ["qa.example"],
      default_modules: [],
      create_via_process: true,
      create_wait_seconds: 0,
      demo_cap: 0
    )

    capped = post(body())
    assert capped.status == 409
    assert json(capped)["limit"] == "demo_cap_reached"

    put_provisioner(
      allowed_hostname_suffixes: ["qa.example"],
      default_modules: [],
      create_via_process: true,
      create_wait_seconds: 0,
      email_domain_daily_budget: 1
    )

    first = body(%{"owner_email" => "a-#{System.unique_integer([:positive])}@budget.example"})
    track(first["tenant_id"])
    assert post(first).status == 202
    second = body(%{"owner_email" => "b-#{System.unique_integer([:positive])}@budget.example"})
    over = post(second)
    assert over.status == 409
    assert json(over)["limit"] == "email_domain_budget_reached"

    assert admission_count() == 1
    assert instance_count(ctx) == 1
    refute Repo.get(Admission, second["tenant_id"])
  end

  test "P6 a failing step ends in instance ERROR; GET says failed; no canary anywhere", ctx do
    canary = "canary-t2728-#{System.unique_integer([:positive])}"
    b = body(%{"owner_email" => "owner-#{canary}@example.com"})
    track(b["tenant_id"])
    slug = TenantProvisioner.Request.slug(b["tenant_id"])

    {conn, log} =
      with_log([level: :debug], fn ->
        conn = post(b)

        # The slug is taken between the start and the first step.
        {:ok, taken} =
          Letflow.Identity.create_tenant(%{"slug" => slug, "display_name" => "Raced"})

        on_exit(fn ->
          Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
          Repo.delete_all(from(t in Tenant, where: t.id == ^taken.id))
        end)

        run_steps(ctx)
        conn
      end)

    assert conn.status == 202
    %Admission{instance_id: instance_id} = Repo.get(Admission, b["tenant_id"])

    assert %InstanceProjection{status: :error} =
             Repo.get_by!(InstanceProjection, [instance_id: instance_id],
               prefix: ctx.platform.schema_name
             )

    got = get(b["tenant_id"]) |> json()
    assert got["status"] == "failed"
    assert got["reason"] in ["conflict", "internal"]

    replay = post(b)
    assert replay.status == 202
    assert json(replay)["status"] == "failed"

    assert log =~ "QUERY", "the capture must see debug query lines or this proves nothing"
    refute log =~ canary
    refute conn.resp_body =~ canary
    refute replay.resp_body =~ canary
    refute inspect(got) =~ canary
  end

  test "P7 ON with the platform step runner off: the old path and one warning", ctx do
    Application.put_env(:letflow, :start_platform_step_runner, false)
    b = body()
    track(b["tenant_id"])

    log = capture_log(fn -> assert post(b).status == 201 end)

    assert log =~ "create_via_process is on but the platform step runner is off"
    assert admission_count() == 0
    assert instance_count(ctx) == 0
  end

  test "P8 the fast finish answers the old 201 body (finish/4 on a completed instance)", ctx do
    b = body()
    track(b["tenant_id"])
    assert post(b).status == 202
    run_steps(ctx)
    %Admission{instance_id: instance_id} = Repo.get(Admission, b["tenant_id"])

    {:ok, request} = TenantProvisioner.Request.parse(b)

    assert {:ok, :created, answer} =
             Register.finish({:started, instance_id, :created}, request, @server_url, 0)

    assert answer == %{
             tenant_id: b["tenant_id"],
             status: "active",
             server_url: @server_url,
             handover: %{login_url: "https://" <> b["hostname"]}
           }
  end

  test "P9 route 4 (sign-up) starts the process under its own route name", ctx do
    b = body()
    track(b["tenant_id"])
    {:ok, request} = TenantProvisioner.Request.parse(b)

    assert {:ok, :accepted, %{status: "provisioning"}} =
             TenantProvisioner.create(request, route: :signup_provisioning, wait_ms: 0)

    %Admission{instance_id: instance_id} = Repo.get(Admission, b["tenant_id"])
    assert [_event] = started_events(ctx, instance_id)

    audit =
      Repo.one!(
        from(e in Letflow.Audit.Entry,
          where: e.action == "instance.create" and e.resource_id == ^instance_id
        ),
        prefix: ctx.platform.schema_name
      )

    assert audit.actor_kind == "system"
    assert audit.after_state["started_via"] == "signup_provisioning"
  end
end
