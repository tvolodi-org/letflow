defmodule Letflow.PlatformFunctions.Impl.TenantProvisionTest do
  @moduledoc """
  The body of `tenant.provision` (T-2590, pilot gap G1b of the "Register a
  tenant" pilot).

  What the tests prove:

    * the body is REGISTERED: the closed registry has a body for the
      catalogue's name;
    * the body is IDEMPOTENT: a second run of the same call changes nothing
      -- the same schema, no new migration, the same roles, the same status
      -- so the step may be retried after a crash;
    * the body refuses a tenant that does not exist, and a value that is not
      a UUID (the id is checked before it reaches the database, INV-8).

  `async: false`: the fixture provisions a real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.PlatformFunctions.Impl.TenantProvision
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.TenantFixture

  setup do
    %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "t2590-prov")}
  end

  defp run(tenant_id) do
    TenantProvision.run(%{inputs: %{"tenant_id" => tenant_id}})
  end

  # The applied migrations of the tenant's own schema: the number of them is
  # what a second provisioning run must not grow.
  defp applied_migrations(prefix) do
    from(m in "schema_migrations", select: m.version) |> Repo.all(prefix: prefix)
  end

  test "P1 the body is registered and the catalogue declares it" do
    assert {:ok, {TenantProvision, :run, 1}} = Registry.fetch("tenant.provision")

    assert {:ok, entry} = Letflow.PlatformFunctions.Catalog.fetch("tenant.provision")
    assert entry.permission == :TenantsManage
    assert entry.platform_tenant_only
  end

  test "P2 the body answers the tenant's own schema", %{tenant: tenant} do
    assert {:ok, %{"schema_name" => schema_name}} = run(tenant.tenant_id)
    assert schema_name == tenant.schema_name
  end

  test "P3 a second run changes NOTHING", %{tenant: tenant} do
    assert {:ok, %{"schema_name" => schema_name}} = run(tenant.tenant_id)

    applied_before = applied_migrations(schema_name)
    roles_before = role_count(schema_name)

    assert {:ok, %{"schema_name" => ^schema_name}} = run(tenant.tenant_id)

    # The same schema, the same applied migrations, the same seeded roles:
    # a repeat provisions nothing a second time.
    assert applied_migrations(schema_name) == applied_before
    assert role_count(schema_name) == roles_before
  end

  test "P4 a tenant that does not exist is refused" do
    assert {:error, :platform_call_tenant_not_found} = run(Ecto.UUID.generate())
  end

  test "P5 a value that is not a UUID is refused before the database sees it" do
    assert {:error, :platform_call_arg_invalid} = run("not-a-uuid")
  end

  defp role_count(prefix) do
    Repo.aggregate(from(r in "tenant_role", select: count(r.id)), :count, prefix: prefix)
  end
end
