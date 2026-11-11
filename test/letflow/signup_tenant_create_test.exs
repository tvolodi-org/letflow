defmodule Letflow.SignupTenantCreateTest do
  @moduledoc """
  T-1679 (decision 0085 D9, slice 1a): the in-process Letflow tenant create after the credential mail.
  Committed-tenant tests (the provisioner flips the sandbox to `:auto`), `async: false`. Every tenant a
  test may create is dropped in `on_exit` registered at the row's insert. IDs C1..C15 follow the design.
  """

  use Letflow.DataCase, async: false
  @moduletag :unit

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Letflow.Test.SignupHelpers

  alias Letflow.Audit.Entry
  alias Letflow.Identity.{OnboardingRecord, Tenant}
  alias Letflow.Repo
  alias Letflow.Signup.{Provisioning, RealmProvisioner, Request}
  alias Letflow.TenantProvisioner
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.Test.ProvisionerStub, as: Stub

  @token "tok-SECRET-caller-token"
  @password "Tmp-Pa55-ONE-time"

  setup do
    System.put_env(RealmProvisioner.token_env(), @token)
    on_exit(fn -> System.delete_env(RealmProvisioner.token_env()) end)
    {:ok, _} = Application.ensure_all_started(:inets)
    %{platform: tenant_create_env!()}
  end

  defp configure!(stub, overrides \\ []) do
    enable!(
      Keyword.merge(
        [
          provisioner_url: stub.url,
          hostname_domain: "qa.example.test",
          retry_delays_ms: [0, 0],
          http_timeout_ms: 2_000
        ],
        overrides
      )
    )
  end

  defp row!(attrs \\ []) do
    tenant_id = Keyword.get(attrs, :tenant_id) || Ecto.UUID.generate()
    track_tenant(tenant_id)

    Repo.insert!(
      struct!(
        %Request{
          tenant_id: tenant_id,
          email: "owner-#{System.unique_integer([:positive])}@example.test",
          company_name: "Acme Ltd",
          language: "ru",
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

  # A row whose credential mail already went out (the state a failed create resumes from).
  defp sent_row!(attrs \\ []) do
    id = Keyword.get(attrs, :tenant_id) || Ecto.UUID.generate()

    row!(
      Keyword.merge(
        [
          tenant_id: id,
          state: "provisioning",
          step: "credential_sent",
          idp_realm_id: RealmProvisioner.label(id),
          credential_sent_at: DateTime.utc_now()
        ],
        attrs
      )
    )
  end

  defp stub_for(id), do: Stub.start!([{201, Stub.created(id, %{"password" => @password})}])
  defp row(id), do: Repo.get!(Request, id)

  defp mails do
    receive do
      {:deliver_message, m} -> [m | mails()]
    after
      50 -> []
    end
  end

  defp counts do
    %{
      tenants: Repo.aggregate(Tenant, :count),
      lifecycles: Repo.aggregate(Lifecycle, :count),
      onboarding: Repo.aggregate(OnboardingRecord, :count),
      audit: audit_count()
    }
  end

  defp audit_count do
    Repo.aggregate(Entry, :count, prefix: Letflow.PlatformTenant.platform_prefix() |> elem(1))
  end

  defp put_prov(extra) do
    current = Application.get_env(:letflow, Letflow.TenantProvisioner, [])
    Application.put_env(:letflow, Letflow.TenantProvisioner, Keyword.merge(current, extra))
  end

  describe "create after the credential mail" do
    test "C1 C2 the saga creates the demo tenant with the row's tenant_id; no credential used" do
      r = row!()
      stub = stub_for(r.tenant_id)
      configure!(stub)

      assert Provisioning.run(r.tenant_id) == :ok

      row = row(r.tenant_id)
      assert {row.state, row.step} == {"provisioning", "tenant_created"}
      assert %Tenant{} = tenant = Repo.get!(Tenant, r.tenant_id)
      assert tenant.slug =~ ~r/\At-/
      lifecycle = Repo.get!(Lifecycle, r.tenant_id)
      assert {lifecycle.tier, lifecycle.language} == {"demo", "ru"}

      onboarding = Repo.get_by!(OnboardingRecord, tenant_id: r.tenant_id)
      assert onboarding.hostname == RealmProvisioner.label(r.tenant_id) <> ".qa.example.test"

      # one mail only: the credential (the welcome mail is slice 1b)
      assert [credential] = mails()
      assert credential.body =~ @password

      # no provisioner (admin API) credential configured, yet the create worked
      assert Application.get_env(:letflow, Letflow.Plugs.ProvisionerAuth) in [nil, []]

      source =
        "lib/letflow/signup/provisioning.ex"
        |> File.read!()
        |> String.replace(~r/"""[\s\S]*?"""/, "")
        |> String.replace(~r/#[^\n]*/, "")

      refute source =~ "auth_context"
      refute source =~ "ProvisionerAuth"
    end

    test "C3 a replay changes nothing" do
      r = sent_row!()
      configure!(Stub.start!([]))
      assert Provisioning.run(r.tenant_id) == :ok
      before = counts()

      Repo.update_all(from(x in Request, where: x.tenant_id == ^r.tenant_id),
        set: [state: "provisioning", step: "credential_sent", step_attempts: 0]
      )

      assert Provisioning.run(r.tenant_id) == :ok
      assert counts() == before
      assert row(r.tenant_id).step == "tenant_created"
      assert mails() == []
    end

    test "C3 a tenant created earlier with the same id is left as it is" do
      r = sent_row!()
      configure!(Stub.start!([]))
      host = RealmProvisioner.label(r.tenant_id) <> ".qa.example.test"

      {:ok, request} =
        TenantProvisioner.Request.parse(%{
          "tenant_id" => r.tenant_id,
          "name" => "Acme Ltd",
          "language" => "ru",
          "tier" => "demo",
          "owner_email" => r.email,
          "hostname" => host,
          "idp_realm_id" => r.idp_realm_id
        })

      assert {:ok, :created, _} = TenantProvisioner.create(request)
      before = counts()
      assert Provisioning.run(r.tenant_id) == :ok
      assert counts() == before
    end
  end

  describe "failure and resume" do
    test "C4 C5 a failed create keeps the row retryable; resume does not mail again" do
      r = sent_row!()
      configure!(Stub.start!([]))
      base = Application.get_env(:letflow, :provisioner_public_base_url)
      Application.delete_env(:letflow, :provisioner_public_base_url)

      log =
        capture_log(fn ->
          assert Provisioning.run(r.tenant_id) == {:failed, "tenant_internal"}
        end)

      refute log =~ r.email
      refute log =~ "Acme"

      failed = row(r.tenant_id)

      assert {failed.state, failed.step, failed.last_error} ==
               {"failed", "provisioning_failed", "tenant_internal"}

      refute Repo.get(Tenant, r.tenant_id)

      Application.put_env(:letflow, :provisioner_public_base_url, base)
      assert Provisioning.resume(tenant_id: r.tenant_id) == [{r.tenant_id, :ok}]
      assert row(r.tenant_id).step == "tenant_created"
      assert Repo.get!(Tenant, r.tenant_id)
      assert mails() == []
    end

    test "C5 resume picks the restart step by what is recorded" do
      stub = Stub.start!(List.duplicate({500, %{}}, 12))
      configure!(stub)
      Application.delete_env(:letflow, :provisioner_public_base_url)
      failed = [state: "failed", step: "provisioning_failed"]

      sent = sent_row!(failed ++ [last_error: "tenant_internal"])
      id2 = Ecto.UUID.generate()

      realm =
        row!(
          failed ++
            [tenant_id: id2, last_error: "internal", idp_realm_id: RealmProvisioner.label(id2)]
        )

      bare = row!(failed ++ [last_error: "unavailable"])

      capture_log(fn -> Provisioning.resume() end)

      # mail already sent: only the tenant step runs, no mail, no realm POST
      assert row(sent.tenant_id).last_error == "tenant_internal"
      sent_email = sent.email
      sent_mails = mails() |> Enum.filter(&(&1.to == sent_email))
      assert sent_mails == []
      # realm exists: restarts at the mail (the hint), then the tenant step fails
      assert row(realm.tenant_id).last_error == "tenant_internal"
      # nothing recorded: restarts at the realm POST
      assert Enum.any?(Stub.posts(stub), &(&1.body["tenant_id"] == bare.tenant_id))

      refute Enum.any?(
               Stub.posts(stub),
               &(&1.body["tenant_id"] in [sent.tenant_id, realm.tenant_id])
             )
    end

    test "C6 a row stuck at credential_sent by part a is resumed and gets its tenant" do
      r = sent_row!(state: "verified")
      configure!(Stub.start!([]))
      assert [{id, :ok}] = Provisioning.resume(tenant_id: r.tenant_id)
      assert id == r.tenant_id
      assert Repo.get!(Tenant, r.tenant_id)
      assert row(r.tenant_id).step == "tenant_created"
    end
  end

  describe "limits and mapping" do
    test "C7 demo cap: permanent, no tenant, forced resume only" do
      r = sent_row!()
      configure!(Stub.start!([]))
      put_prov(demo_cap: Repo.aggregate(from(l in Lifecycle, where: l.tier == "demo"), :count))

      capture_log(fn -> assert Provisioning.run(r.tenant_id) == {:failed, "demo_cap_reached"} end)
      refute Repo.get(Tenant, r.tenant_id)
      assert Provisioning.resume(tenant_id: r.tenant_id) == []
    end

    test "C7 source budget: the second sign-up of one source is refused" do
      key = :crypto.hash(:sha256, "one-source-#{System.unique_integer([:positive])}")
      put_prov(source_daily_budget: 1, email_domain_daily_budget: 0)
      configure!(Stub.start!([]))

      first = sent_row!(ip_key: key)
      second = sent_row!(ip_key: key)
      assert Provisioning.run(first.tenant_id) == :ok

      capture_log(fn ->
        assert Provisioning.run(second.tenant_id) == {:failed, "source_budget"}
      end)

      refute Repo.get(Tenant, second.tenant_id)
    end

    test "C7 e-mail domain budget" do
      domain = "d#{System.unique_integer([:positive])}.example"
      put_prov(source_daily_budget: 0, email_domain_daily_budget: 1)
      configure!(Stub.start!([]))

      first = sent_row!(email: "a@" <> domain)
      second = sent_row!(email: "b@" <> domain)
      assert Provisioning.run(first.tenant_id) == :ok

      capture_log(fn ->
        assert Provisioning.run(second.tenant_id) == {:failed, "email_domain_budget"}
      end)
    end

    test "C8 the default modules install runs on this path" do
      put_prov(default_modules: TenantProvisioner.Config.default_modules())
      r = sent_row!()
      configure!(Stub.start!([]))
      assert Provisioning.run(r.tenant_id) == :ok
      assert Repo.get!(Lifecycle, r.tenant_id).default_modules_state == "done"
    end

    test "C9 C11 a hostname domain outside the allowed suffixes is invalid_tenant, nothing leaks" do
      r = sent_row!()
      configure!(Stub.start!([]), hostname_domain: "evil.example.org")

      log =
        capture_log(fn -> assert Provisioning.run(r.tenant_id) == {:failed, "invalid_tenant"} end)

      refute Repo.get(Tenant, r.tenant_id)
      refute log =~ r.email
      refute log =~ "Acme"
      refute log =~ @token
      refute log =~ @password
      refute inspect(row(r.tenant_id)) =~ @password
      refute inspect(row(r.tenant_id)) =~ @token
    end

    test "C10 a suspended tenant with the same id is a conflict" do
      r = sent_row!()
      configure!(Stub.start!([]))
      assert Provisioning.run(r.tenant_id) == :ok

      Repo.update_all(from(l in Lifecycle, where: l.tenant_id == ^r.tenant_id),
        set: [lifecycle: "suspended"]
      )

      Repo.update_all(from(x in Request, where: x.tenant_id == ^r.tenant_id),
        set: [state: "provisioning", step: "credential_sent", step_attempts: 0]
      )

      capture_log(fn -> assert Provisioning.run(r.tenant_id) == {:failed, "tenant_conflict"} end)
    end
  end

  describe "flag and scope" do
    test "C12 flag off: no run, no tenant" do
      r = sent_row!(state: "verified")
      configure!(Stub.start!([]), enabled: false)
      assert Provisioning.run(r.tenant_id) == :noop
      refute Repo.get(Tenant, r.tenant_id)
    end

    test "C13 the in-process create has exactly two executable callers" do
      callers =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(fn file ->
          code =
            file
            |> File.read!()
            |> String.replace(~r/"""[\s\S]*?"""/, "")
            |> String.replace(~r/#[^\n]*/, "")

          code =~ "TenantProvisioner.create("
        end)
        |> Enum.map(&Path.relative_to(&1, "lib/letflow"))
        |> Enum.sort()

      assert callers == ["routers/admin_v1.ex", "signup/provisioning.ex"]
    end

    test "C15 the mix task reports tenant_created" do
      r = sent_row!(state: "verified")
      configure!(Stub.start!([]))
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.Letflow.Signup.Resume.run(["--tenant-id", r.tenant_id])
      assert_received {:mix_shell, :info, [line]}
      assert line == "#{r.tenant_id}: tenant_created"
    end
  end
end
