defmodule Letflow.PlatformProcesses.TenantLifecycleSeedTest do
  @moduledoc """
  The seed of `platform.tenant_lifecycle` (T-2972, BP-PLATFORM-02 G2): the same idempotent seed
  as the registration definition, with the `definition:` option. The activation fence accepts the
  three new catalogue entries, the version runs, and a second seed writes nothing.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.PlatformProcesses.Seed
  alias Letflow.PlatformProcesses.TenantLifecycleDefinition, as: Definition
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2972-seed")
    PlatformFx.pin!(tenant.tenant_id)
    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)
    %{tenant: tenant, admin: admin}
  end

  test "S1 the lifecycle definition is created, active, and a second seed changes nothing", ctx do
    opts = [
      prefix: ctx.tenant.schema_name,
      activator_user_id: ctx.admin.id,
      definition: Definition
    ]

    assert {:ok, %{outcome: :created, definition: definition, version: "1"}} = Seed.seed(opts)
    assert definition.name == "platform.tenant_lifecycle"
    assert definition.status == :active
    assert definition.graph == Definition.graph()
    assert definition.start_permission == "TenantsManage"

    assert {:ok, %{outcome: :already_present}} = Seed.seed(opts)

    assert {:ok, active} =
             Definitions.get_active_by_name("platform.tenant_lifecycle",
               prefix: ctx.tenant.schema_name
             )

    assert active.id == definition.id
  end

  test "S2 seeding the lifecycle definition does not touch the registration one", ctx do
    assert {:ok, %{outcome: :created}} =
             Seed.seed(
               prefix: ctx.tenant.schema_name,
               activator_user_id: ctx.admin.id,
               definition: Definition
             )

    assert {:error, :not_found} =
             Definitions.get_active_by_name("platform.register_tenant",
               prefix: ctx.tenant.schema_name
             )
  end
end
