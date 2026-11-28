defmodule Letflow.SignupProvisioningProcessTest do
  @moduledoc """
  T-3154 (owner item 11 / D-195, slice G2): route 4 (the sign-up saga) goes THROUGH the
  `platform.register_tenant` process. The saga no longer asks the provisioner and sends no credential
  mail: the process step `tenant.provision_realm_and_invite` does both, the saga sends only its welcome
  mail. Real router-free saga (`Provisioning.run/1`), the seeded v3 definition, the platform step runner,
  and the provisioner stub (Bandit on loopback, real `:httpc`).

  S1 one POST, one credential mail, then the welcome; S2 the password is nowhere but the mail; S3 the
  chosen slug is the host the realm registers; S4 a row an earlier build left with a realm binds it and
  the provisioner is not asked; S5 the saga module has no direct caller of the realm client.
  """

  use Letflow.DataCase, async: false
  @moduletag :unit

  import ExUnit.CaptureLog
  import Letflow.Test.SignupHelpers

  alias Letflow.Engine.PlatformStepRunner
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Signup.{Provisioning, RealmProvisioner, Request}
  alias Letflow.Support.RegisterTenantProcessFixture
  alias Letflow.Test.ProvisionerStub, as: Stub

  @token "tok-SECRET-caller-token"
  @password "Tmp-Pa55-ONE-time"

  setup do
    System.put_env(RealmProvisioner.token_env(), @token)
    on_exit(fn -> System.delete_env(RealmProvisioner.token_env()) end)
    {:ok, _} = Application.ensure_all_started(:inets)

    platform = tenant_create_env!()
    RegisterTenantProcessFixture.seed!(platform.schema_name)

    previous_prov = Application.get_env(:letflow, Letflow.TenantProvisioner)
    previous_runner = Application.get_env(:letflow, :start_platform_step_runner)

    Application.put_env(:letflow, Letflow.TenantProvisioner,
      allowed_hostname_suffixes: ["qa.example.test"],
      demo_lifetime_days: 14,
      default_modules: [],
      create_via_process: true,
      create_wait_seconds: 0
    )

    Application.put_env(:letflow, :start_platform_step_runner, true)

    on_exit(fn ->
      restore_env(Letflow.TenantProvisioner, previous_prov)
      restore_env(:start_platform_step_runner, previous_runner)
    end)

    %{platform: platform}
  end

  defp restore_env(key, nil), do: Application.delete_env(:letflow, key)
  defp restore_env(key, value), do: Application.put_env(:letflow, key, value)

  defp configure!(stub) do
    # ONE attempt per run: the process is asynchronous, a run that finds it unfinished is a retry of the
    # sweep (`resume/0` here), and the test runs the steps in between.
    enable!(
      provisioner_url: stub.url,
      hostname_domain: "qa.example.test",
      retry_delays_ms: [],
      http_timeout_ms: 2_000
    )
  end

  defp ready_row(attrs \\ []) do
    tenant_id = Keyword.get(attrs, :tenant_id) || Ecto.UUID.generate()
    track_tenant(tenant_id)

    Repo.insert!(
      struct!(
        %Request{
          tenant_id: tenant_id,
          email: "owner@example.test",
          company_name: "Acme Ltd",
          language: "en",
          state: "verified",
          step: "ready_for_provisioning",
          ip_key: :crypto.hash(:sha256, tenant_id),
          terms_version: "t",
          terms_accepted_at: DateTime.utc_now(),
          verified_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp row(tenant_id), do: Repo.get!(Request, tenant_id)

  defp run_steps(ctx),
    do: Enum.each(1..16, fn _ -> PlatformStepRunner.run_due(ctx.platform.schema_name) end)

  defp mails do
    receive do
      {:deliver_message, m} -> [m | mails()]
    after
      50 -> []
    end
  end

  test "S1 route 4 through the process: one POST, one credential mail, then the welcome", ctx do
    r = ready_row()
    stub = Stub.start!([{201, Stub.created(r.tenant_id)}])
    configure!(stub)

    # the saga starts the process and does not wait: a retryable code, nothing asked of the provisioner
    capture_log(fn -> assert Provisioning.run(r.tenant_id) == {:failed, "tenant_pending"} end)
    assert Stub.posts(stub) == []
    assert mails() == []
    assert {row(r.tenant_id).state, row(r.tenant_id).last_error} == {"failed", "tenant_pending"}

    run_steps(ctx)

    # the PROCESS asked the provisioner, once, keyed by the tenant id, and mailed the credential, once
    assert [post] = Stub.posts(stub)
    assert post.auth == "Bearer " <> @token
    assert post.body["tenant_id"] == r.tenant_id
    assert post.body["owner_email"] == "owner@example.test"
    assert [%{to: "owner@example.test", body: credential}] = mails()
    assert credential =~ @password

    # the sweep resumes the row: the create is the process's replay, the saga sends only the welcome
    assert [{tenant_id, :ok}] = Provisioning.resume()
    assert tenant_id == r.tenant_id
    assert {row(tenant_id).state, row(tenant_id).step} == {"completed", "completed"}
    assert [%{to: "owner@example.test", body: welcome}] = mails()
    refute welcome =~ @password

    label = RealmProvisioner.label(r.tenant_id)
    assert %Tenant{idp_realm_id: ^label} = Repo.get!(Tenant, r.tenant_id)
    assert length(Stub.posts(stub)) == 1
  end

  test "S2 the temporary password is in the mail only: not the row, a log line or an instance",
       ctx do
    r = ready_row()
    stub = Stub.start!([{201, Stub.created(r.tenant_id)}])
    configure!(stub)

    log =
      capture_log([level: :debug], fn ->
        Provisioning.run(r.tenant_id)
        run_steps(ctx)
        Provisioning.resume()
      end)

    refute log =~ @password
    refute log =~ @token
    refute inspect(Map.from_struct(row(r.tenant_id))) =~ @password

    prefix = ctx.platform.schema_name

    stored = [
      Repo.all(Letflow.PlatformFunctions.Dispatcher.StepDispatch, prefix: prefix),
      Repo.all(Letflow.EventStore.InstanceProjection, prefix: prefix),
      Repo.all(Letflow.EventStore.Event, prefix: prefix),
      Repo.all(Letflow.Audit.Entry, prefix: prefix)
    ]

    refute inspect(stored, limit: :infinity, printable_limit: :infinity) =~ @password
  end

  test "S3 the chosen slug is the host the realm registers", ctx do
    r = ready_row(slug: "my-co")
    stub = Stub.start!([{201, Stub.created(r.tenant_id)}])
    configure!(stub)

    capture_log(fn -> Provisioning.run(r.tenant_id) end)
    run_steps(ctx)

    assert [post] = Stub.posts(stub)
    assert post.body["hostname"] == "my-co.qa.example.test"
  end

  test "S4 a row an earlier build left with a realm binds it; the provisioner is not asked",
       ctx do
    id = Ecto.UUID.generate()

    r =
      ready_row(
        tenant_id: id,
        step: "credential_sent",
        state: "provisioning",
        idp_realm_id: RealmProvisioner.label(id)
      )

    stub = Stub.start!([{201, Stub.created(id)}])
    configure!(stub)

    capture_log(fn -> Provisioning.run(r.tenant_id) end)
    run_steps(ctx)
    Provisioning.resume()

    assert Stub.posts(stub) == []
    assert row(id).step == "completed"
    label = RealmProvisioner.label(id)
    assert %Tenant{idp_realm_id: ^label} = Repo.get!(Tenant, id)
  end

  test "S5 the saga module has no direct caller of the realm client" do
    source = File.read!("lib/letflow/signup/provisioning.ex")
    refute source =~ "RealmProvisioner.create_realm"
    refute source =~ "create_realm_step"
  end
end
