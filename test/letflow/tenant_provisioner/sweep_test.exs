defmodule Letflow.TenantProvisioner.SweepTest do
  @moduledoc """
  GH #3292 / REQ-572 criteria 1, 4, 8, 19 / REQ-580 criterion 7(c): `Letflow.TenantProvisioner.Sweep`
  against real Postgres and real tenant schemas, with an injected clock. Test IDs: SW1..SW9.

  `async: false`: provisioning flips the sandbox to `:auto`, and the platform-tenant pin and the
  retention setting are VM-global. `run/1` is global, so a stray eligible row left by another test
  would also be swept: counters are asserted as lower bounds, per-tenant outcomes exactly.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioner
  alias Letflow.TenantProvisioner.Config
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantProvisioner.Sweep
  alias Letflow.TenantPurge

  @day 86_400

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "gh3292-plat")
    Fixture.pin!(platform.tenant_id)
    previous = Application.get_env(:letflow, Letflow.TenantProvisioner)
    Application.put_env(:letflow, Letflow.TenantProvisioner, retention_days: 30)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, Letflow.TenantProvisioner, previous),
        else: Application.delete_env(:letflow, Letflow.TenantProvisioner)
    end)

    :ok
  end

  # --- helpers ---------------------------------------------------------------

  defp ago(days), do: DateTime.add(DateTime.utc_now(), -days * @day, :second)
  defp plus(%DateTime{} = at, seconds), do: DateTime.add(at, seconds, :second)

  # A provisioned tenant with a lifecycle row. `:status` is the tenants row status (default
  # :inactive), the rest are lifecycle columns. The row is removed in on_exit.
  defp tenant!(opts \\ []) do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: "gh3292-v")
    id = fixture.tenant_id

    Repo.update_all(from(t in Tenant, where: t.id == ^id),
      set: [status: Keyword.get(opts, :status, :inactive)]
    )

    Repo.insert!(%Lifecycle{
      tenant_id: id,
      lifecycle: Keyword.get(opts, :lifecycle, "suspended"),
      tier: Keyword.get(opts, :tier, "demo"),
      language: "en",
      expires_at: Keyword.get(opts, :expires_at),
      deletion_requested_at: Keyword.get(opts, :requested)
    })

    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^id))
    end)

    fixture
  end

  defp lifecycle!(id), do: Repo.get!(Lifecycle, id)

  defp schema_exists?(schema) do
    Repo.query!("SELECT 1 FROM information_schema.schemata WHERE schema_name = $1", [schema]).rows !=
      []
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(25) && wait_until(fun, tries - 1)
    end
  end

  # --- SW1..SW5 --------------------------------------------------------------

  describe "expire and purge with an injected clock" do
    test "SW1 an expired demo is expired by the sweep, kept inside retention, purged after it" do
      expires_at = ago(1)
      v = tenant!(lifecycle: "active", status: :active, expires_at: expires_at)
      id = v.tenant_id

      first = Sweep.run(now: plus(expires_at, 1))
      assert first.expired >= 1
      assert %Lifecycle{lifecycle: "expired", purged_at: nil} = lifecycle!(id)
      assert Repo.get!(Tenant, id).status == :inactive
      assert {:ok, %{status: "expired"}} = TenantProvisioner.get(id)
      assert schema_exists?(v.schema_name)

      Sweep.run(now: plus(expires_at, 30 * @day - 1))
      assert %Lifecycle{lifecycle: "expired", purged_at: nil} = lifecycle!(id)
      assert schema_exists?(v.schema_name)

      at = plus(expires_at, 30 * @day)
      assert Sweep.run(now: at).purged >= 1
      assert %Lifecycle{lifecycle: "deleted", purged_at: %DateTime{}} = lifecycle!(id)
      refute schema_exists?(v.schema_name)

      entry =
        Repo.one(
          from(e in Letflow.Audit.Entry,
            where: e.action == "platform.tenant.purged" and e.resource_id == ^id,
            select: e.after_state
          ),
          prefix: elem(Letflow.PlatformTenant.platform_prefix(), 1)
        )

      assert entry["trigger"] == "sweep"
    end

    test "SW2 a suspended tenant with no deletion_requested_at and no expires_at is never purged" do
      v = tenant!(lifecycle: "suspended")
      Sweep.run(now: plus(DateTime.utc_now(), 3650 * @day))
      assert %Lifecycle{lifecycle: "suspended", purged_at: nil} = lifecycle!(v.tenant_id)
      assert schema_exists?(v.schema_name)
    end

    test "SW3 an active tenant is never purged, and expires only when its expires_at has passed" do
      plain = tenant!(lifecycle: "active", status: :active)

      later =
        tenant!(
          lifecycle: "active",
          status: :active,
          expires_at: plus(DateTime.utc_now(), 5 * @day)
        )

      Sweep.run(now: DateTime.utc_now())
      Sweep.run(now: plus(DateTime.utc_now(), 4 * @day))

      assert %Lifecycle{lifecycle: "active"} = lifecycle!(plain.tenant_id)
      assert %Lifecycle{lifecycle: "active"} = lifecycle!(later.tenant_id)
      assert Repo.get!(Tenant, plain.tenant_id).status == :active
      assert schema_exists?(plain.schema_name) and schema_exists?(later.schema_name)

      # No expires_at at all: untouched even at a far-future clock by the expire step.
      Sweep.run(now: plus(DateTime.utc_now(), 3650 * @day))
      assert %Lifecycle{lifecycle: "active", purged_at: nil} = lifecycle!(plain.tenant_id)
    end

    test "SW4 a production tenant (by tier or by tenant_type) is never touched" do
      by_tier = tenant!(tier: "production", lifecycle: "expired", expires_at: ago(100))
      by_type = tenant!(lifecycle: "expired", expires_at: ago(100))

      Repo.update_all(from(t in Tenant, where: t.id == ^by_type.tenant_id),
        set: [tenant_type: "production"]
      )

      active_prod =
        tenant!(tier: "production", lifecycle: "active", status: :active, expires_at: ago(100))

      Sweep.run(now: DateTime.utc_now())

      assert %Lifecycle{lifecycle: "expired", purged_at: nil} = lifecycle!(by_tier.tenant_id)
      assert %Lifecycle{lifecycle: "expired", purged_at: nil} = lifecycle!(by_type.tenant_id)
      assert %Lifecycle{lifecycle: "active", purged_at: nil} = lifecycle!(active_prod.tenant_id)
      assert Repo.get!(Tenant, active_prod.tenant_id).status == :active

      for v <- [by_tier, by_type, active_prod], do: assert(schema_exists?(v.schema_name))
    end

    test "SW5 a suspended tenant with a deletion request is purged after retention, not inside it" do
      inside = tenant!(requested: ago(5))
      past = tenant!(requested: ago(31))

      assert Sweep.run(now: DateTime.utc_now()).purged >= 1

      assert %Lifecycle{lifecycle: "suspended", purged_at: nil} = lifecycle!(inside.tenant_id)
      assert schema_exists?(inside.schema_name)
      assert %Lifecycle{lifecycle: "deleted", purged_at: %DateTime{}} = lifecycle!(past.tenant_id)
      refute schema_exists?(past.schema_name)
    end
  end

  # --- SW6 cross-tenant ------------------------------------------------------

  test "SW6 purging tenant A leaves tenant B untouched" do
    a = tenant!(requested: ago(31))
    b = tenant!(requested: ago(5))
    before_b = {lifecycle!(b.tenant_id), Repo.get!(Tenant, b.tenant_id)}

    Sweep.run(now: DateTime.utc_now())

    assert %Lifecycle{lifecycle: "deleted"} = lifecycle!(a.tenant_id)
    assert {lifecycle!(b.tenant_id), Repo.get!(Tenant, b.tenant_id)} == before_b
    assert schema_exists?(b.schema_name)
  end

  # --- SW7 INV-8 -------------------------------------------------------------

  test "SW7 one tenant's failure is logged by id only and the sweep continues" do
    a = tenant!(requested: ago(31))
    b = tenant!(requested: ago(31))
    c = tenant!(requested: ago(31))

    purge = fn id, trigger, opts ->
      cond do
        id == a.tenant_id -> raise "boom: #{a.tenant.display_name}"
        id == b.tenant_id -> {:error, :purge_failed}
        true -> TenantPurge.purge(id, trigger, opts)
      end
    end

    log =
      capture_log(fn ->
        send(self(), {:counters, Sweep.run(now: DateTime.utc_now(), purge: purge)})
      end)

    assert_received {:counters, counters}
    assert counters.failed >= 2
    assert %Lifecycle{lifecycle: "deleted"} = lifecycle!(c.tenant_id)
    assert %Lifecycle{lifecycle: "suspended"} = lifecycle!(a.tenant_id)
    assert %Lifecycle{lifecycle: "suspended"} = lifecycle!(b.tenant_id)

    assert log =~ a.tenant_id and log =~ b.tenant_id
    refute log =~ a.tenant.display_name
    refute log =~ a.tenant.slug
    refute log =~ "boom"
  end

  # --- SW8 settings ----------------------------------------------------------

  describe "settings" do
    test "SW8 defaults, parse and rejection of the three variables" do
      Application.delete_env(:letflow, Letflow.TenantProvisioner)

      assert {Config.demo_cap(), Config.demo_alarm_threshold(), Config.sweep_interval_minutes()} ==
               {30, 25, 60}

      vars = %{
        "LETFLOW_PROVISIONER_DEMO_CAP" => "7",
        "LETFLOW_PROVISIONER_DEMO_ALARM_THRESHOLD" => "5",
        "LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES" => "15"
      }

      assert {:ok, %{provisioner: parsed}} = Config.parse(vars, :test)
      assert parsed[:demo_cap] == 7 and parsed[:demo_alarm_threshold] == 5
      assert parsed[:sweep_interval_minutes] == 15

      for {var, bad} <- [
            {"LETFLOW_PROVISIONER_DEMO_CAP", "-1"},
            {"LETFLOW_PROVISIONER_DEMO_CAP", "100001"},
            {"LETFLOW_PROVISIONER_DEMO_ALARM_THRESHOLD", "x"},
            {"LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES", "0"},
            {"LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES", "10081"}
          ] do
        assert {:error, ^var} = Config.parse(%{var => bad}, :test)
      end

      assert {:ok, %{provisioner: []}} = Config.parse(%{}, :test)
    end

    test "SW8 the retention setting is read by the sweep (retention 0 purges at once)" do
      v = tenant!(requested: ago(0))
      Application.put_env(:letflow, Letflow.TenantProvisioner, retention_days: 30)
      Sweep.run(now: plus(DateTime.utc_now(), 1))
      assert %Lifecycle{lifecycle: "suspended"} = lifecycle!(v.tenant_id)

      Application.put_env(:letflow, Letflow.TenantProvisioner, retention_days: 0)
      Sweep.run(now: plus(DateTime.utc_now(), 1))
      assert %Lifecycle{lifecycle: "deleted"} = lifecycle!(v.tenant_id)
    end

    test "SW8 runtime.exs reads each variable and the runbook lists each with its default" do
      runtime = File.read!("config/runtime.exs")
      runbook = File.read!("docs/runbooks/tenant-provisioner-credential.md")

      for {var, default} <- [
            {"LETFLOW_PROVISIONER_DEMO_CAP", "30"},
            {"LETFLOW_PROVISIONER_DEMO_ALARM_THRESHOLD", "25"},
            {"LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES", "60"}
          ] do
        assert runtime =~ var
        assert runbook =~ ~r/`#{var}`\s*\|\s*#{default}\b/
      end
    end
  end

  # --- SW9 timer -------------------------------------------------------------

  describe "timer" do
    test "SW9 the GenServer ticks on its own interval and is not started under the test config" do
      refute Application.get_env(:letflow, :start_provisioner_sweep, true)

      ids =
        Letflow.Supervisor.Pollers |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

      refute Sweep in ids

      v = tenant!(requested: ago(31))
      start_supervised!({Sweep, name: :sweep_timer_test, interval_ms: 20})

      assert wait_until(fn -> lifecycle!(v.tenant_id).lifecycle == "deleted" end)
    end

    test "SW9 the default interval is the setting in minutes" do
      Application.put_env(:letflow, Letflow.TenantProvisioner, sweep_interval_minutes: 3)
      pid = start_supervised!({Sweep, name: :sweep_interval_test})
      assert :sys.get_state(pid).interval_ms == 3 * 60_000
    end
  end
end
