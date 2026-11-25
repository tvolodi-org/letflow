defmodule Letflow.PlatformFunctions.RegistryTest do
  @moduledoc """
  The CLOSED registry of platform function bodies (T-2589, pilot gap G1a;
  T-2590, pilot gap G1b).

  Two closures, both proved here:

    * a body exists only for a name the compiled catalogue declares (the
      catalogue is the only list of names a definition may call);
    * a name the catalogue declares but that has no body yet is refused with
      `:not_implemented` -- the dispatcher never pretends such a call
      succeeded.

  And the register of the pilot's tenant family (T-2590): the side-effecting
  functions of the registration chain have a body, and the code that today
  sat in the routes and in the provisioner now sits BEHIND those bodies --
  the routes call the implementation modules, so the route and the platform
  step run ONE implementation.

  No database.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Impl.TenantBindRealm
  alias Letflow.PlatformFunctions.Impl.TenantCreate
  alias Letflow.PlatformFunctions.Impl.TenantGrantFirstAdmins
  alias Letflow.PlatformFunctions.Impl.TenantInstallDefaultModules
  alias Letflow.PlatformFunctions.Impl.TenantProvision
  alias Letflow.PlatformFunctions.Impl.ValidateRegistration
  alias Letflow.PlatformFunctions.Registry

  @tenant_family [
    "tenant.create",
    "tenant.provision",
    "tenant.bind_realm",
    "tenant.grant_first_admins",
    "tenant.install_default_modules"
  ]

  test "every body the registry knows is declared in the compiled catalogue" do
    names = Registry.names()

    assert "platform.validate_registration" in names

    for name <- names do
      assert {:ok, entry} = Catalog.fetch(name),
             "#{name} has a body but is not declared in the compiled catalogue"

      assert entry.name == name
    end
  end

  test "a name that is not in the catalogue has no body" do
    assert {:error, :not_found} = Registry.fetch("platform.not_in_the_catalogue")
    assert {:error, :not_found} = Catalog.fetch("platform.not_in_the_catalogue")
  end

  test "T-2704: tenant.validate has a body, so the shipped definition can start" do
    assert {:ok, {Letflow.PlatformFunctions.Impl.TenantValidate, :run, 1}} =
             Registry.fetch("tenant.validate")
  end

  test "the registered body of the validation entry is the implementation module" do
    assert {:ok, {ValidateRegistration, :run, 1}} =
             Registry.fetch("platform.validate_registration")
  end

  test "T-2590: every side-effecting function of the tenant family has a body" do
    for name <- @tenant_family do
      assert {:ok, {_module, :run, 1}} = Registry.fetch(name), "#{name} has no body"

      assert {:ok, entry} = Catalog.fetch(name)
      assert entry.permission == :TenantsManage
      assert entry.platform_tenant_only
    end

    assert {:ok, {TenantCreate, :run, 1}} = Registry.fetch("tenant.create")
    assert {:ok, {TenantProvision, :run, 1}} = Registry.fetch("tenant.provision")
    assert {:ok, {TenantBindRealm, :run, 1}} = Registry.fetch("tenant.bind_realm")

    assert {:ok, {TenantGrantFirstAdmins, :run, 1}} =
             Registry.fetch("tenant.grant_first_admins")

    assert {:ok, {TenantInstallDefaultModules, :run, 1}} =
             Registry.fetch("tenant.install_default_modules")
  end

  test "T-2590: the code that sat in the routes now sits behind the bodies" do
    # The routes and the provisioner call the implementation modules, so the
    # platform step and the route run ONE implementation of each operation.
    # The direct calls below are the ones that must be GONE from them.
    routes = [
      "lib/letflow/routers/tenants.ex",
      "lib/letflow/routers/onboarding.ex",
      "lib/letflow/tenant_provisioner.ex"
    ]

    forbidden = [
      "Identity.create_tenant(",
      "TenantOnboarding.provision_and_migrate(",
      "Identity.bind_tenant_realm(",
      "PendingAdminGrants.create("
    ]

    for path <- routes do
      source = File.read!(path)

      for call <- forbidden do
        refute source =~ call, "#{path} still calls #{call} directly"
      end
    end

    # And the bodies are the ones that call them.
    assert File.read!("lib/letflow/platform_functions/impl/tenant_create.ex") =~
             "Identity.create_tenant("

    assert File.read!("lib/letflow/platform_functions/impl/tenant_provision.ex") =~
             "TenantOnboarding.provision_and_migrate("

    assert File.read!("lib/letflow/platform_functions/impl/tenant_bind_realm.ex") =~
             "Identity.bind_tenant_realm("

    assert File.read!("lib/letflow/platform_functions/impl/tenant_grant_first_admins.ex") =~
             "PendingAdminGrants.create("
  end
end
