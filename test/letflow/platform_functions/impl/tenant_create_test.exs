defmodule Letflow.PlatformFunctions.Impl.TenantCreateTest do
  @moduledoc """
  The body of `tenant.create` (T-2590, pilot gap G1b of the "Register a
  tenant" pilot).

  What the tests prove:

    * the body is REGISTERED: the closed registry has a body for the
      catalogue's name;
    * the body is IDEMPOTENT: a second run of the same call changes nothing
      and answers the same tenant id -- the same call, not a second tenant;
    * the body ADOPTS a tenant that already carries the slug and the name
      (it answers that tenant's id and writes nothing), and it refuses a
      slug that belongs to ANOTHER tenant;
    * the body refuses a tenant that was PURGED (REQ-580): a purge is final,
      so no step hands out a tenant that no longer exists;
    * the body refuses a value over its byte cap before anything is written
      (SF-01);
    * the ROUTE's answer does not change: the create the routes call still
      answers a duplicate slug with the duplicate, so the 409 stays.

  The tenant row lives in the GLOBAL tenant registry, inside the test's own
  sandbox transaction: the row is rolled back with the test.
  """

  use Letflow.DataCase, async: true

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.PlatformFunctions.Impl.TenantCreate
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.TenantProvisioner.Lifecycle

  @slug "t2590-create"
  @name "T-2590 Create Ltd"

  defp inputs(overrides) do
    Map.merge(%{"slug" => @slug, "name" => @name}, overrides)
  end

  defp run(overrides \\ %{}) do
    TenantCreate.run(%{inputs: inputs(overrides)})
  end

  defp tenants do
    Repo.all(from(t in Tenant, where: t.slug == ^@slug))
  end

  test "C1 the body is registered and the catalogue declares it" do
    assert {:ok, {TenantCreate, :run, 1}} = Registry.fetch("tenant.create")

    assert {:ok, entry} = Letflow.PlatformFunctions.Catalog.fetch("tenant.create")
    assert entry.permission == :TenantsManage
    assert entry.platform_tenant_only
  end

  test "C2 the first run creates the tenant and answers its id" do
    assert {:ok, %{"tenant_id" => tenant_id}} = run()
    assert is_binary(tenant_id)

    assert [%Tenant{id: ^tenant_id, display_name: @name, slug: @slug}] = tenants()
  end

  test "C3 a second run changes NOTHING and answers the same id" do
    assert {:ok, %{"tenant_id" => tenant_id}} = run()

    assert {:ok, %{"tenant_id" => ^tenant_id}} = run()

    # One row, one tenant: the repeat did not create a second one.
    assert [%Tenant{id: ^tenant_id}] = tenants()
  end

  test "C4 a slug that belongs to another tenant is refused" do
    assert {:ok, _outputs} = run()

    # The same slug with a DIFFERENT name is a different registration: the
    # step refuses it instead of adopting the tenant that holds the slug.
    assert {:error, :platform_call_duplicate_slug} = run(%{"name" => "Another Ltd"})

    assert [%Tenant{display_name: @name}] = tenants()
  end

  test "C5 a value over the byte cap is refused before anything is written" do
    assert {:error, :platform_call_arg_invalid} =
             run(%{"slug" => String.duplicate("a", 256)})

    assert {:error, :platform_call_arg_invalid} =
             run(%{"name" => String.duplicate("b", 256)})

    assert tenants() == []
  end

  test "C6 the route's create still answers a duplicate slug" do
    assert {:ok, %Tenant{}} =
             TenantCreate.create_tenant(%{"slug" => @slug, "display_name" => @name})

    # The route maps this answer to 409 "slug already exists"; the step's own
    # replay rule must not change it.
    assert {:error, :duplicate_slug} =
             TenantCreate.create_tenant(%{"slug" => @slug, "display_name" => @name})
  end

  test "C7 a repeat ADOPTS a tenant that existed before the step and writes nothing" do
    # A tenant that exists BEFORE the step runs: the operator created it.
    assert {:ok, %Tenant{id: tenant_id}} =
             TenantCreate.create_tenant(%{"slug" => @slug, "display_name" => @name})

    assert {:ok, %{"tenant_id" => ^tenant_id}} = run()

    # The step adopted it: the same id, and the row carries the name the
    # operator gave it -- the step wrote nothing.
    assert [%Tenant{id: ^tenant_id, display_name: @name}] = tenants()
  end

  test "C8 a tenant that was PURGED is refused instead of adopted" do
    assert {:ok, %{"tenant_id" => tenant_id}} = run()

    # The marker the purge writes and never clears: the lifecycle row
    # carries `purged_at`.
    Repo.insert!(%Lifecycle{
      tenant_id: tenant_id,
      lifecycle: "deleted",
      tier: "demo",
      language: "en",
      expires_at: nil,
      deletion_requested_at: nil,
      purged_at: DateTime.utc_now()
    })

    # A purge is final: the step hands out no tenant that no longer exists.
    assert {:error, :platform_call_tenant_purged} = run()

    assert [%Tenant{id: ^tenant_id}] = tenants()
  end
end
