defmodule Letflow.Identity.StorekeeperSeedingTest do
  @moduledoc """
  T-1317 / decision 0081 (T-10): the `STOREKEEPER` built-in role is seeded like every other platform role.
  A tenant that lacks it gains the group and binding from `RoleRegistry.seed_default_platform_role_groups/1`
  (what `RoleBackfill.run/0` calls for an existing tenant), and a routing role of the same name is refused.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.TenantFixture

  test "T-10a a tenant seeded without the role gains the STOREKEEPER group and binding" do
    %{schema_name: schema_name} = TenantFixture.provisioned_tenant!(slug_prefix: "sk-seed")

    assert {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)
    assert "STOREKEEPER" in RoleRegistry.seedable_role_names(schema_name)

    names = RoleRegistry.list_roles(prefix: schema_name) |> Enum.map(& &1.name)
    assert "STOREKEEPER" in names
  end

  test "T-10b a routing role named STOREKEEPER makes the seed return the collision error" do
    %{schema_name: schema_name} = TenantFixture.provisioned_tenant!(slug_prefix: "sk-collide")

    {:ok, %Group{id: group_id}} =
      RoleRegistry.get_or_create_group_by_name("sk-routing-group", prefix: schema_name)

    assert {:ok, _} =
             RoleRegistry.upsert_role("STOREKEEPER", :process_routing_role, group_id,
               prefix: schema_name
             )

    assert {:error, {:role_name_taken_by_routing_role, "STOREKEEPER"}} =
             RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)
  end
end
