defmodule Letflow.ModuleUpgrade.CapabilityTest do
  @moduledoc """
  REQ-683 criterion 5 (C1, C2): `Capability.new/4` reads the tenant's registration row.

  `async: false`: tenant provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.ModuleUpgrade.Capability
  alias Letflow.TenantFixture

  test "C1: an unknown tenant id is :tenant_not_provisioned" do
    assert {:error, :tenant_not_provisioned} =
             Capability.new(Ecto.UUID.generate(), "up-1", "plan-1", Ecto.UUID.generate())
  end

  test "C2: a provisioned tenant yields its schema name as the prefix" do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: "cap683")

    actor = Ecto.UUID.generate()

    assert {:ok, capability} = Capability.new(tenant_id, "up-1", "plan-1", actor)

    assert %Capability{
             tenant_id: ^tenant_id,
             prefix: ^schema_name,
             upgrade_id: "up-1",
             plan_hash: "plan-1",
             actor_id: ^actor
           } = capability
  end
end
