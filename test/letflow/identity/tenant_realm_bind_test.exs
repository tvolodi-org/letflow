defmodule Letflow.Identity.TenantRealmBindTest do
  @moduledoc """
  ISS-1030 PR 1 -- `Letflow.Identity.bind_tenant_realm/3` (bind-once, row-locked)
  and `Letflow.Identity.Tenant.realm_bind_changeset/2`. Design:
  `lib/letflow/design/iss1030-onboarding-administrator.md` sections 3.2, 7a, 10.1.

  Real Postgres, real tenant schemas (`Letflow.TenantFixture`). The tenant chain
  is the fixture tenant's own schema; the platform chain is a second fixture
  tenant's schema. `async: false`: `TenantFixture` flips the sandbox to `:auto`.

  Status: WRITTEN, NOT YET RUN (park of Q-1012; see test/specs/ISS-1030-PR1.md).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-bind")
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-bind-plat")
    %{tenant: tenant, platform: platform, actor_id: Ecto.UUID.generate()}
  end

  defp opts(ctx),
    do: [actor_id: ctx.actor_id, platform_prefix: ctx.platform.schema_name, trace_id: "t-1"]

  defp realm, do: Letflow.TenantSlugFixture.unique_realm("iss1030")

  defp entries(schema, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema)

  defp stored_realm(tenant_id), do: Repo.get!(Tenant, tenant_id).idp_realm_id

  test "bind_tenant_realm sets idp_realm_id only while it is NULL", ctx do
    first = realm()
    assert stored_realm(ctx.tenant.tenant_id) == nil

    assert {:ok, %Tenant{idp_realm_id: ^first}} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, first, opts(ctx))

    assert stored_realm(ctx.tenant.tenant_id) == first

    # Same realm again: idempotent, no second audit entry in either chain.
    assert {:ok, %Tenant{idp_realm_id: ^first}} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, first, opts(ctx))

    assert length(entries(ctx.tenant.schema_name, "tenant.idp_realm.bound")) == 1
    assert length(entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound")) == 1

    # A different realm is refused and the tenant is unchanged.
    assert {:error, :realm_already_bound} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, realm(), opts(ctx))

    assert stored_realm(ctx.tenant.tenant_id) == first
    assert length(entries(ctx.tenant.schema_name, "tenant.idp_realm.bound")) == 1
  end

  test "bind_tenant_realm audits a NIL actor in the tenant chain and the operator in the platform chain",
       ctx do
    bound = realm()
    assert {:ok, _tenant} = Identity.bind_tenant_realm(ctx.tenant.tenant_id, bound, opts(ctx))

    assert [tenant_entry] = entries(ctx.tenant.schema_name, "tenant.idp_realm.bound")
    assert tenant_entry.actor_id == nil

    assert tenant_entry.after_state == %{
             "idp_realm_id" => bound,
             "actor_class" => "platform_operator"
           }

    refute inspect(tenant_entry) =~ ctx.actor_id

    assert [platform_entry] = entries(ctx.platform.schema_name, "platform.tenant_idp_realm.bound")
    assert platform_entry.actor_id == ctx.actor_id
    assert platform_entry.after_state["tenant_id"] == ctx.tenant.tenant_id
    assert platform_entry.after_state["idp_realm_id"] == bound
  end

  test "bind_tenant_realm refuses a non-active tenant, an unknown tenant and a realm held elsewhere",
       ctx do
    for status <- [:migrating, :inactive] do
      other = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-bind-status")
      {:ok, _} = other.tenant |> Tenant.status_changeset(%{status: status}) |> Repo.update()

      assert {:error, :tenant_not_active} =
               Identity.bind_tenant_realm(other.tenant_id, realm(), opts(ctx))

      assert stored_realm(other.tenant_id) == nil
      assert entries(other.schema_name, "tenant.idp_realm.bound") == []
    end

    assert {:error, :not_found} =
             Identity.bind_tenant_realm(Ecto.UUID.generate(), realm(), opts(ctx))

    held = realm()
    TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-bind-held", idp_realm_id: held)

    assert {:error, :duplicate_realm} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, held, opts(ctx))

    assert stored_realm(ctx.tenant.tenant_id) == nil
  end

  test "bind_tenant_realm without actor_id or platform_prefix writes nothing", ctx do
    assert {:error, :audit_failed} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, realm(), platform_prefix: "x")

    assert {:error, :audit_failed} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, realm(), actor_id: ctx.actor_id)

    assert stored_realm(ctx.tenant.tenant_id) == nil
  end

  test "realm bound: a forced failure of the platform write leaves idp_realm_id NULL and no tenant entry",
       ctx do
    # A platform prefix naming a schema that does not exist makes the second
    # audit write fail AFTER the tenant row and the tenant entry were written.
    bad = [
      actor_id: ctx.actor_id,
      platform_prefix: "tenant_00000000000000000000000000000000",
      trace_id: "t-2"
    ]

    assert {:error, :audit_failed} =
             Identity.bind_tenant_realm(ctx.tenant.tenant_id, realm(), bad)

    assert stored_realm(ctx.tenant.tenant_id) == nil
    assert entries(ctx.tenant.schema_name, "tenant.idp_realm.bound") == []
  end

  test "realm_bind_changeset casts nothing but idp_realm_id and rejects a malformed value", ctx do
    tenant = ctx.tenant.tenant

    cs =
      Tenant.realm_bind_changeset(tenant, %{
        "idp_realm_id" => "ok-realm",
        "slug" => "hijack",
        "status" => "inactive",
        "display_name" => "x"
      })

    assert cs.valid?
    assert Map.keys(cs.changes) == [:idp_realm_id]

    for bad <- ["", "a.b", "..", "a/b", "-x", "_x", "master", "Master", String.duplicate("a", 65)] do
      refute Tenant.realm_bind_changeset(tenant, %{"idp_realm_id" => bad}).valid?, bad
    end

    refute Tenant.realm_bind_changeset(tenant, %{}).valid?
  end

  test "no other changeset casts idp_realm_id on an existing tenant (structural)", ctx do
    tenant = ctx.tenant.tenant
    attrs = %{"idp_realm_id" => "smuggled", "idp_realm_id_" => "x"}

    changeset_funs =
      for {name, 2} <- Tenant.__info__(:functions),
          String.ends_with?(Atom.to_string(name), "_changeset"),
          name != :realm_bind_changeset,
          do: name

    assert changeset_funs != []

    for name <- changeset_funs do
      cs = apply(Tenant, name, [tenant, attrs])
      refute Map.has_key?(cs.changes, :idp_realm_id), "#{name} casts idp_realm_id"
    end

    # The bind-once changeset has exactly one production caller.
    callers =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "realm_bind_changeset("))
      |> Enum.sort()

    assert callers == ["lib/letflow/identity.ex", "lib/letflow/identity/tenant.ex"]
  end
end
