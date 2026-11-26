defmodule Letflow.PlatformProcesses.BootSeedTest do
  @moduledoc """
  T-2739: the platform definitions are seeded without an operator.
  `async: false`: the platform tenant pin and the setting are VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.PlatformProcesses.BootSeed
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2739-boot")
    PlatformFx.pin!(tenant.tenant_id)
    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)
    previous = Application.get_env(:letflow, :seed_platform_definitions_on_boot)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:letflow, :seed_platform_definitions_on_boot),
        else: Application.put_env(:letflow, :seed_platform_definitions_on_boot, previous)
    end)

    %{tenant: tenant}
  end

  defp rows(tenant) do
    Repo.all(
      from(d in ProcessDefinition, where: d.name == "platform.register_tenant"),
      prefix: tenant.schema_name
    )
  end

  test "setting off: skipped, nothing written, check reports missing", %{tenant: tenant} do
    Application.put_env(:letflow, :seed_platform_definitions_on_boot, false)
    assert BootSeed.run() == :skipped
    assert rows(tenant) == []
    assert BootSeed.check() == {:error, :definition_missing}
  end

  test "fresh DB: first run creates an ACTIVE definition, re-run changes nothing", %{
    tenant: tenant
  } do
    Application.put_env(:letflow, :seed_platform_definitions_on_boot, true)

    assert {:ok, :created} = BootSeed.run()
    assert [%{status: :active}] = rows(tenant)
    assert BootSeed.check() == :ok

    assert {:ok, :already_present} = BootSeed.run()
    assert length(rows(tenant)) == 1
    assert BootSeed.check() == :ok
  end

  test "force: true runs with the setting off (the deploy step)", %{tenant: tenant} do
    Application.put_env(:letflow, :seed_platform_definitions_on_boot, false)
    assert {:ok, :created} = BootSeed.run(force: true)
    assert length(rows(tenant)) == 1
  end

  test "platform tenant not configured: clear error, no write, no raise" do
    PlatformFx.unpin!()
    assert {:error, :platform_tenant_not_configured} = BootSeed.run(force: true)
    assert {:error, :platform_tenant_not_configured} = BootSeed.check()
  end

  test "the log never carries the stored version text", %{tenant: tenant} do
    assert {:ok, :created} = BootSeed.run(force: true)
    canary = "canary.person@example.invalid\nFORGED_LOG"

    Repo.update_all(
      from(d in ProcessDefinition, where: d.name == "platform.register_tenant"),
      [set: [version: canary]],
      prefix: tenant.schema_name
    )

    log = capture_log(fn -> assert {:ok, :newer_version_kept} = BootSeed.run(force: true) end)
    assert log =~ "platform definitions seed"
    refute log =~ "canary.person"
    refute log =~ "FORGED_LOG"
  end
end
