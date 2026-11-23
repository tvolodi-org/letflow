defmodule Letflow.PlatformFunctions.Impl.TenantInstallDefaultModulesTest do
  @moduledoc """
  The body of `tenant.install_default_modules` (T-2590, pilot gap G1b of the
  "Register a tenant" pilot).

  What the tests prove:

    * the body is REGISTERED: the closed registry has a body for the
      catalogue's name;
    * the body is IDEMPOTENT: a second run of the same call installs NOTHING
      a second time -- the installer is asked again and answers
      `:already_installed`, which the body counts as done;
    * a failing install is a typed refusal with a CODE, never the installer's
      own text (that text names a module id and would carry a value into the
      step's failure kind, INV-4);
    * a value that is not a UUID is refused before the database sees it.

  The installer is a fake, injected through the platform's own configuration
  (the same seam the provisioner's own test uses): the real install writes
  global rows that reference the tenant, and this test is about the body's
  own logic, not about the installer.

  `async: false`: the application configuration the fake is injected into is
  VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.PlatformFunctions.Impl.TenantInstallDefaultModules
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.TenantFixture

  setup do
    previous = Application.get_env(:letflow, Letflow.TenantProvisioner)
    on_exit(fn -> restore(previous) end)

    %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "t2590-mod")}
  end

  defp restore(nil), do: Application.delete_env(:letflow, Letflow.TenantProvisioner)
  defp restore(value), do: Application.put_env(:letflow, Letflow.TenantProvisioner, value)

  # The fake installer: it answers like the real one -- installed the first
  # time, `:already_installed` after that -- and counts what it was asked.
  defp fake_installer do
    fn module_id, _actor, _opts ->
      installed = Process.get(:t2590_installed, %{})

      if Map.get(installed, module_id, 0) == 0 do
        Process.put(:t2590_installed, Map.put(installed, module_id, 1))
        {:ok, %{}}
      else
        {:error, :already_installed}
      end
    end
  end

  defp put_provisioner(extra) do
    Application.put_env(
      :letflow,
      Letflow.TenantProvisioner,
      Keyword.merge([default_modules: ["org"]], extra)
    )
  end

  defp run(tenant_id) do
    TenantInstallDefaultModules.run(%{inputs: %{"tenant_id" => tenant_id}})
  end

  test "I1 the body is registered and the catalogue declares it" do
    assert {:ok, {TenantInstallDefaultModules, :run, 1}} =
             Registry.fetch("tenant.install_default_modules")

    assert {:ok, entry} =
             Letflow.PlatformFunctions.Catalog.fetch("tenant.install_default_modules")

    assert entry.permission == :TenantsManage
    assert entry.platform_tenant_only
  end

  test "I2 the first run installs the module", %{tenant: tenant} do
    put_provisioner(default_modules_install: fake_installer())

    assert {:ok, %{}} = run(tenant.tenant_id)
    assert Process.get(:t2590_installed) == %{"org" => 1}
  end

  test "I3 a second run changes NOTHING", %{tenant: tenant} do
    put_provisioner(default_modules_install: fake_installer())

    assert {:ok, %{}} = run(tenant.tenant_id)
    installed_before = Process.get(:t2590_installed)
    assert installed_before == %{"org" => 1}

    assert {:ok, %{}} = run(tenant.tenant_id)

    # The installer is asked again and answers "already installed": the
    # module is installed once, and the repeat changes nothing.
    assert Process.get(:t2590_installed) == installed_before
  end

  test "I4 a failing install is a typed refusal, never the installer's text", %{tenant: tenant} do
    put_provisioner(default_modules_install: fn _module_id, _actor, _opts -> {:error, :boom} end)

    assert {:error, :platform_call_default_modules_failed} = run(tenant.tenant_id)
  end

  test "I5 a value that is not a UUID is refused before the database sees it" do
    assert {:error, :platform_call_arg_invalid} = run("not-a-uuid")
  end
end
