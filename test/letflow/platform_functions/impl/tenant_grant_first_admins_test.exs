defmodule Letflow.PlatformFunctions.Impl.TenantGrantFirstAdminsTest do
  @moduledoc """
  The body of `tenant.grant_first_admins` (T-2590, pilot gap G1b of the
  "Register a tenant" pilot).

  What the tests prove:

    * the body is REGISTERED: the closed registry has a body for the
      catalogue's name;
    * the body is IDEMPOTENT: a second run of the same call stores nothing a
      second time -- the tenant's schema holds ONE pending grant;
    * the body refuses an address that is not an address, and one over its
      byte cap, before anything is written (SF-01);
    * the body refuses a tenant that is not provisioned: the grant lives in
      the tenant's own schema, so an unprovisioned tenant has nowhere to put
      it;
    * the body's grant is audited as a SYSTEM write: no actor in either
      chain, the explicit `created_via` marker, and no address in the entry
      (INV-4).

  `async: false`: the platform tenant pin is application configuration, which
  is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.PlatformFunctions.Impl.TenantGrantFirstAdmins
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx
  alias Letflow.TenantFixture

  @email "admin@t2590.example"

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "t2590-plat")
    PlatformFx.pin!(platform.tenant_id)

    %{platform: platform, tenant: TenantFixture.provisioned_tenant!(slug_prefix: "t2590-grant")}
  end

  defp run(tenant_id, email) do
    TenantGrantFirstAdmins.run(%{inputs: %{"tenant_id" => tenant_id, "admin_email" => email}})
  end

  defp grants(prefix) do
    from(g in "pending_tenant_admin_grants", select: g.id) |> Repo.all(prefix: prefix)
  end

  # Every audit entry of one action in one schema: the actor and the state
  # the entry carries.
  defp audit_entries(schema_name, action) do
    Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema_name)
  end

  test "G1 the body is registered and the catalogue declares it" do
    assert {:ok, {TenantGrantFirstAdmins, :run, 1}} = Registry.fetch("tenant.grant_first_admins")

    assert {:ok, entry} = Letflow.PlatformFunctions.Catalog.fetch("tenant.grant_first_admins")
    assert entry.permission == :TenantsManage
    assert entry.platform_tenant_only
  end

  test "G2 the first run stores the pending grant in the tenant's own schema", %{tenant: tenant} do
    assert {:ok, %{}} = run(tenant.tenant_id, @email)
    assert length(grants(tenant.schema_name)) == 1
  end

  test "G3 a second run changes NOTHING", %{tenant: tenant} do
    assert {:ok, %{}} = run(tenant.tenant_id, @email)

    grants_before = grants(tenant.schema_name)
    assert length(grants_before) == 1

    assert {:ok, %{}} = run(tenant.tenant_id, @email)

    # One grant, one row: the repeat stored nothing a second time.
    assert grants(tenant.schema_name) == grants_before
  end

  test "G4 an address that is not an address is refused", %{tenant: tenant} do
    assert {:error, :platform_call_invalid_email} = run(tenant.tenant_id, "not-an-address")
    assert grants(tenant.schema_name) == []
  end

  test "G5 an address over the byte cap is refused before anything is written", %{tenant: tenant} do
    long = String.duplicate("a", 250) <> "@t2590.example"

    assert {:error, :platform_call_invalid_email} = run(tenant.tenant_id, long)
    assert grants(tenant.schema_name) == []
  end

  test "G6 a tenant that is not provisioned is refused" do
    assert {:error, :platform_call_tenant_not_found} = run(Ecto.UUID.generate(), @email)
  end

  test "G7 a value that is not a UUID is refused before the database sees it" do
    assert {:error, :platform_call_arg_invalid} = run("not-a-uuid", @email)
  end

  test "G8 the step's grant is audited as a SYSTEM write and carries no address",
       %{platform: platform, tenant: tenant} do
    assert {:ok, %{}} = run(tenant.tenant_id, @email)

    # The tenant chain: no actor (a step runs outside any person's request)
    # and the explicit marker of who wrote it.
    assert [tenant_entry] = audit_entries(tenant.schema_name, "tenant.admin_grant.created")
    assert tenant_entry.actor_id == nil
    assert tenant_entry.after_state["created_via"] == "provisioning"

    # The platform chain: no actor either, and the same marker.
    assert [platform_entry] =
             audit_entries(platform.schema_name, "platform.tenant_admin_grant.created")

    assert platform_entry.actor_id == nil
    assert platform_entry.after_state["created_via"] == "provisioning"

    # The address is never written to an audit entry (INV-4).
    refute inspect(tenant_entry) =~ @email
    refute inspect(platform_entry) =~ @email
  end
end
