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
      a UUID (the id is checked before it reaches the database, INV-8);
    * the body refuses a PURGED tenant (REQ-580) BEFORE it writes anything:
      the purge dropped the schema, and the step must not re-create it and
      must not make a purged tenant `:active` again.

  `async: false`: the fixture provisions a real tenant schema, and the purge
  is the product's own (`Letflow.TenantPurge`), which writes into the pinned
  platform tenant.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.PlatformFunctions.Impl.TenantProvision
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantProvisioning
  alias Letflow.TenantPurge

  @day 86_400

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "t2590-plat")
    PlatformFx.pin!(platform.tenant_id)

    previous = Application.get_env(:letflow, Letflow.TenantProvisioner)
    Application.put_env(:letflow, Letflow.TenantProvisioner, retention_days: 30)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, Letflow.TenantProvisioner, previous),
        else: Application.delete_env(:letflow, Letflow.TenantProvisioner)
    end)

    %{platform: platform, tenant: TenantFixture.provisioned_tenant!(slug_prefix: "t2590-prov")}
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

  test "P6 a PURGED tenant is refused before anything is written" do
    id = purge_tenant!()

    assert {:error, :platform_call_tenant_purged} = run(id)

    # Nothing was resurrected: the status stays `:inactive`, the
    # registration row the purge dropped is not written again, and the
    # schema the purge dropped does not exist.
    assert Repo.get!(Tenant, id).status == :inactive
    assert Repo.get_by(TenantProvisioning.Registration, tenant_id: id) == nil
    refute schema_exists?(schema_name(id))
  end

  # A tenant the product's OWN purge emptied: its schema is gone, its
  # registration row is gone, its lifecycle row carries `purged_at` and its
  # status is `:inactive`.
  defp purge_tenant!() do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: "t2590-purged")
    id = fixture.tenant_id

    Repo.update_all(from(t in Tenant, where: t.id == ^id), set: [status: :inactive])

    Repo.insert!(%Lifecycle{
      tenant_id: id,
      lifecycle: "suspended",
      tier: "demo",
      language: "en",
      expires_at: nil,
      deletion_requested_at: DateTime.add(DateTime.utc_now(), -31 * @day, :second)
    })

    on_exit(fn -> Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^id)) end)

    assert {:ok, :purged} = TenantPurge.purge(id, :provisioner)
    id
  end

  defp schema_name(tenant_id) do
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)
    schema_name
  end

  defp schema_exists?(schema_name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = $1)",
        [schema_name]
      )

    exists?
  end

  defp role_count(prefix) do
    Repo.aggregate(from(r in "tenant_role", select: count(r.id)), :count, prefix: prefix)
  end
end
