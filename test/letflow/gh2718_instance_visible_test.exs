defmodule Letflow.GH2718InstanceVisibleTest do
  @moduledoc """
  GH #2718, design section 6 A15 and A16: `Letflow.Instances.instance_visible?/2`.

  True only for a projection row of the caller's tenant schema that is NOT registered in
  `entity_type_instances`; status is irrelevant; a DB error raises and is never folded into
  `false`. All tests are red on main because the function does not exist (A15 / A16 are
  killed by M5, M6, M9, M10, M11).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Letflow.TestSupport.InstanceFixture, only: [real_instance!: 1]

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Instances
  alias Letflow.TenantFixture

  defp tenant!(prefix),
    do:
      TenantFixture.provisioned_tenant!(
        slug_prefix: prefix,
        display_name: "GH2718 visible tenant"
      )

  describe "A15 instance_visible?/2" do
    test "true for a real active instance and for a real cancelled instance" do
      tenant = tenant!("gh2718-vis-real")
      active = real_instance!(tenant)
      cancelled = real_instance!(tenant)

      {1, _} =
        Repo.update_all(
          from(p in InstanceProjection, where: p.instance_id == ^cancelled),
          [set: [status: :cancelled]],
          prefix: tenant.schema_name
        )

      assert Instances.instance_visible?(active, prefix: tenant.schema_name) == true
      assert Instances.instance_visible?(cancelled, prefix: tenant.schema_name) == true
    end

    test "false for an unknown id, a synthetic id and the platform sentinel id" do
      tenant = tenant!("gh2718-vis-hidden")
      {:ok, synthetic} = EntityTypeInstance.get_or_create("widget", tenant.schema_name)

      assert Instances.instance_visible?(Ecto.UUID.generate(), prefix: tenant.schema_name) ==
               false

      assert Instances.instance_visible?(synthetic, prefix: tenant.schema_name) == false

      assert Instances.instance_visible?(EventStore.platform_instance_id(),
               prefix: tenant.schema_name
             ) == false
    end

    test "tenant isolation: an id real in tenant A is not visible in tenant B" do
      tenant_a = tenant!("gh2718-vis-a")
      tenant_b = tenant!("gh2718-vis-b")
      id = real_instance!(tenant_a)

      assert Instances.instance_visible?(id, prefix: tenant_a.schema_name) == true
      assert Instances.instance_visible?(id, prefix: tenant_b.schema_name) == false
    end

    test "a missing :prefix is a programmer error (KeyError), not false" do
      assert_raise KeyError, fn -> Instances.instance_visible?(Ecto.UUID.generate(), []) end
    end
  end

  describe "A16 instance_visible?/2 propagates a DB error" do
    test "a nonexistent schema prefix raises Postgrex.Error, never returns false" do
      assert_raise Postgrex.Error, fn ->
        Instances.instance_visible?(Ecto.UUID.generate(), prefix: "gh2718_no_such_schema")
      end
    end
  end
end
