defmodule Letflow.PlatformFunctions.Impl.TenantBindRealmTest do
  @moduledoc """
  The body of `tenant.bind_realm` (T-2590, pilot gap G1b of the "Register a
  tenant" pilot).

  What the tests prove:

    * the body is REGISTERED: the closed registry has a body for the
      catalogue's name;
    * the body is IDEMPOTENT: a second run of the same call binds nothing a
      second time -- the tenant keeps the realm it has, and the bind is
      audited ONCE;
    * the body refuses a DIFFERENT realm for a tenant that already has one
      (the step never replaces a realm behind the operator's back);
    * the body refuses a realm ANOTHER tenant holds (the realm is the
      identity provider's, so it belongs to one tenant only);
    * the body's bind is audited as a SYSTEM write: no actor in either
      chain, the explicit `actor_class` marker in the tenant chain, and no
      customer text in the entry;
    * the body refuses a realm over its byte cap before anything is written
      (SF-01), a tenant that does not exist, and a value that is not a UUID.

  `async: false`: the platform tenant pin is application configuration, which
  is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity.Tenant
  alias Letflow.PlatformFunctions.Impl.TenantBindRealm
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx
  alias Letflow.TenantFixture

  @realm "t2590-realm"

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "t2590-plat")
    PlatformFx.pin!(platform.tenant_id)

    %{platform: platform, tenant: TenantFixture.provisioned_tenant!(slug_prefix: "t2590-bind")}
  end

  defp run(tenant_id, realm) do
    TenantBindRealm.run(%{inputs: %{"tenant_id" => tenant_id, "realm_id" => realm}})
  end

  defp bound_realm(tenant_id) do
    Repo.get!(Tenant, tenant_id).idp_realm_id
  end

  # The platform chain's bind entries for this tenant: one bind, one entry.
  defp bind_audits(platform_prefix, tenant_id) do
    from(e in "audit_entries",
      where: e.action == "platform.tenant_idp_realm.bound" and e.resource_id == ^tenant_id,
      select: e.id
    )
    |> Repo.all(prefix: platform_prefix)
  end

  # Every audit entry of one action in one schema: the actor and the state
  # the entry carries.
  defp audit_entries(schema_name, action) do
    Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema_name)
  end

  test "B1 the body is registered and the catalogue declares it" do
    assert {:ok, {TenantBindRealm, :run, 1}} = Registry.fetch("tenant.bind_realm")

    assert {:ok, entry} = Letflow.PlatformFunctions.Catalog.fetch("tenant.bind_realm")
    assert entry.permission == :TenantsManage
    assert entry.platform_tenant_only
  end

  test "B2 the first run binds the realm", %{tenant: tenant} do
    assert {:ok, %{}} = run(tenant.tenant_id, @realm)
    assert bound_realm(tenant.tenant_id) == @realm
  end

  test "B3 a second run changes NOTHING", %{platform: platform, tenant: tenant} do
    assert {:ok, %{}} = run(tenant.tenant_id, @realm)

    audits_before = bind_audits(platform.schema_name, tenant.tenant_id)
    assert length(audits_before) == 1

    assert {:ok, %{}} = run(tenant.tenant_id, @realm)

    # The tenant keeps its realm and the bind is audited ONCE: a repeat
    # changes nothing.
    assert bound_realm(tenant.tenant_id) == @realm
    assert bind_audits(platform.schema_name, tenant.tenant_id) == audits_before
  end

  test "B4 a different realm for a bound tenant is refused", %{tenant: tenant} do
    assert {:ok, %{}} = run(tenant.tenant_id, @realm)

    assert {:error, :platform_call_realm_already_bound} = run(tenant.tenant_id, "t2590-other")
    assert bound_realm(tenant.tenant_id) == @realm
  end

  test "B5 a realm over the byte cap is refused before anything is written", %{tenant: tenant} do
    assert {:error, :platform_call_arg_invalid} =
             run(tenant.tenant_id, String.duplicate("r", 65))

    assert is_nil(bound_realm(tenant.tenant_id))
  end

  test "B6 a tenant that does not exist is refused" do
    assert {:error, :platform_call_tenant_not_found} = run(Ecto.UUID.generate(), @realm)
  end

  test "B7 a value that is not a UUID is refused before the database sees it" do
    assert {:error, :platform_call_arg_invalid} = run("not-a-uuid", @realm)
  end

  test "B8 a realm ANOTHER tenant holds is refused", %{tenant: tenant} do
    other = TenantFixture.provisioned_tenant!(slug_prefix: "t2590-bind2")

    assert {:ok, %{}} = run(tenant.tenant_id, @realm)

    # The realm belongs to the first tenant now: the second one is refused
    # and keeps no realm at all.
    assert {:error, :platform_call_duplicate_realm} = run(other.tenant_id, @realm)
    assert is_nil(bound_realm(other.tenant_id))
  end

  test "B9 the step's bind is audited as a SYSTEM write", %{platform: platform, tenant: tenant} do
    assert {:ok, %{}} = run(tenant.tenant_id, @realm)

    # The tenant chain: no actor (a step runs outside any person's request)
    # and the explicit marker of who wrote it.
    assert [tenant_entry] = audit_entries(tenant.schema_name, "tenant.idp_realm.bound")
    assert tenant_entry.actor_id == nil
    assert tenant_entry.after_state["actor_class"] == "provisioner"
    assert tenant_entry.after_state["idp_realm_id"] == @realm

    # The platform chain: no actor either.
    assert [platform_entry] =
             audit_entries(platform.schema_name, "platform.tenant_idp_realm.bound")

    assert platform_entry.actor_id == nil
    assert platform_entry.after_state["tenant_id"] == tenant.tenant_id
    assert platform_entry.after_state["idp_realm_id"] == @realm
  end
end
