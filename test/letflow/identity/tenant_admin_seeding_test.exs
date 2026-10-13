defmodule Letflow.Identity.TenantAdminSeedingTest do
  @moduledoc """
  REQ-447 PR 1, AC3 and AC7 (`lib/letflow/design/req447-tenant-admin-role.md` sections 3.2, 3.3,
  3.7, 3.10 and 11; spec `test/specs/REQ-447-PR1.md`).

    * AC3: a tenant provisioned through the real `Letflow.TenantOnboarding.provision_and_migrate/1`
      has a `TENANT_ADMIN` group and binding; it has NO `PLATFORM_ADMIN` binding unless it is the
      pinned platform tenant, which has both. With no pin configured, no tenant gets
      `PLATFORM_ADMIN`.
    * `RoleRegistry.seedable_role_names/1` and `PlatformTenant.platform_prefix?/1` fail closed.
    * The name-collision guard: a `:process_routing_role` row named `TENANT_ADMIN` makes the seed
      return the error before any write.
    * AC7 (realm file additions): `bpm-default.json` has the `TENANT_ADMIN` realm role and a
      `tenant-admin-user`, and `TENANT_ADMIN` is in no default role, default group or composite.
      (`authorization_role_realm_test.exs` is NOT edited and must pass unmodified.)

  `async: false`: the platform tenant pin is VM-global application config.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantRole
  alias Letflow.PlatformTenant
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantOnboarding
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # Derived (REQ-448): never re-literalled to the next role count.
  @all_names Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)
  @non_platform_names List.delete(@all_names, "PLATFORM_ADMIN")

  # A tenant in the `migrating` state exactly as `POST /onboarding` creates it; the cleanup mirrors
  # `test/letflow/tenant_onboarding_test.exs`.
  defp new_migrating_tenant! do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug("req447-seed"),
          display_name: "REQ-447 seeding tenant",
          status: "migrating"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} ->
          Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))

        {:error, :invalid_tenant_id} ->
          :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    tenant
  end

  defp role_rows(schema_name),
    do: Repo.all(from(t in TenantRole, order_by: [asc: t.name]), prefix: schema_name)

  defp role_names(schema_name), do: schema_name |> role_rows() |> Enum.map(& &1.name)

  defp group_names(schema_name),
    do: Repo.all(from(g in Group, select: g.name), prefix: schema_name) |> Enum.sort()

  describe "AC3: provision_and_migrate/1 seeds by tenant kind" do
    test "an ordinary tenant (a different tenant is pinned) gets a TENANT_ADMIN group and binding and NO PLATFORM_ADMIN group or binding" do
      other = TenantFixture.provisioned_tenant!(slug_prefix: "req447-seed-pin")
      Fixture.pin!(other.tenant_id)

      tenant = new_migrating_tenant!()

      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      refute PlatformTenant.platform_tenant?(tenant.id)

      assert Enum.sort(role_names(schema_name)) == Enum.sort(@non_platform_names)
      assert "TENANT_ADMIN" in role_names(schema_name)
      refute "PLATFORM_ADMIN" in role_names(schema_name)
      refute "PLATFORM_ADMIN" in group_names(schema_name)
      assert Enum.all?(role_rows(schema_name), &(&1.kind == :platform_role))

      # The binding points at a real group named TENANT_ADMIN.
      binding = Enum.find(role_rows(schema_name), &(&1.name == "TENANT_ADMIN"))
      assert %Group{name: "TENANT_ADMIN"} = Repo.get(Group, binding.group_id, prefix: schema_name)
    end

    test "the pinned platform tenant gets BOTH the TENANT_ADMIN and the PLATFORM_ADMIN bindings (every role of roles/0)" do
      tenant = new_migrating_tenant!()
      Fixture.pin!(tenant.id)

      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      assert Enum.sort(role_names(schema_name)) == Enum.sort(@all_names)
      assert "PLATFORM_ADMIN" in group_names(schema_name)
      assert "TENANT_ADMIN" in group_names(schema_name)
    end

    test "with NO pin configured, no tenant is seeded PLATFORM_ADMIN (it would be an ordinary tenant)" do
      Fixture.unpin!()
      tenant = new_migrating_tenant!()

      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      assert Enum.sort(role_names(schema_name)) == Enum.sort(@non_platform_names)
      refute "PLATFORM_ADMIN" in role_names(schema_name)
    end

    test "re-seeding is idempotent: a second call yields the same bindings and no extra rows (ordinary and platform)" do
      ordinary = TenantFixture.provisioned_tenant!(slug_prefix: "req447-seed-idem-o")
      platform = TenantFixture.provisioned_tenant!(slug_prefix: "req447-seed-idem-p")
      Fixture.pin!(platform.tenant_id)

      for schema <- [ordinary.schema_name, platform.schema_name] do
        assert {:ok, first} = RoleRegistry.seed_default_platform_role_groups(prefix: schema)
        assert {:ok, second} = RoleRegistry.seed_default_platform_role_groups(prefix: schema)

        assert Enum.map(first, &{&1.name, &1.group_id}) ==
                 Enum.map(second, &{&1.name, &1.group_id})

        assert Repo.aggregate(TenantRole, :count, prefix: schema) == length(first)
        assert Repo.aggregate(Group, :count, prefix: schema) == length(first)
      end

      assert length(role_names(ordinary.schema_name)) == length(@non_platform_names)
      assert length(role_names(platform.schema_name)) == length(@all_names)
    end
  end

  describe "seedable_role_names/1 and platform_prefix?/1 fail closed" do
    setup do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req447-prefix")

      {:ok, tenant_id: tenant_id, schema_name: schema_name}
    end

    test "pin unset: no schema is a platform prefix and PLATFORM_ADMIN is never seedable", ctx do
      Fixture.unpin!()

      refute PlatformTenant.platform_prefix?(ctx.schema_name)
      assert RoleRegistry.seedable_role_names(ctx.schema_name) == @non_platform_names
    end

    test "pin set: exactly the pinned tenant's schema is a platform prefix and gets every name of roles/0 in order",
         ctx do
      Fixture.pin!(ctx.tenant_id)

      assert PlatformTenant.platform_prefix?(ctx.schema_name)
      assert RoleRegistry.seedable_role_names(ctx.schema_name) == @all_names

      other = TenantFixture.provisioned_tenant!(slug_prefix: "req447-prefix-o")
      refute PlatformTenant.platform_prefix?(other.schema_name)
      assert RoleRegistry.seedable_role_names(other.schema_name) == @non_platform_names
    end

    test "a pin given in upper case still matches the lower-case schema encoding", ctx do
      Fixture.pin!(String.upcase(ctx.tenant_id))
      assert PlatformTenant.platform_prefix?(ctx.schema_name)
    end

    test "a malformed or non-binary prefix fails closed even with the pin set", ctx do
      Fixture.pin!(ctx.tenant_id)

      for bad <- [
            "public",
            "",
            "tenant_",
            "tenant_zzzz",
            "tenant_" <> String.upcase(String.replace(ctx.tenant_id, "-", "")),
            "tenant_" <> String.replace(ctx.tenant_id, "-", "") <> "x",
            ~s(tenant_#{String.replace(ctx.tenant_id, "-", "")}"; DROP SCHEMA x;--),
            nil,
            :tenant,
            123,
            %{},
            ["tenant_" <> String.replace(ctx.tenant_id, "-", "")]
          ] do
        refute PlatformTenant.platform_prefix?(bad), "platform_prefix?(#{inspect(bad)})"

        assert RoleRegistry.seedable_role_names(bad) == @non_platform_names,
               "seedable_role_names(#{inspect(bad)})"
      end
    end
  end

  describe "name-collision guard (design F12)" do
    test "a :process_routing_role row named TENANT_ADMIN makes the seed return the error before any write; the row is unchanged" do
      %{schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req447-collide")

      {:ok, %Group{id: group_id}} =
        RoleRegistry.get_or_create_group_by_name("tenant-admin-routing-group",
          prefix: schema_name
        )

      assert {:ok, %TenantRole{kind: :process_routing_role}} =
               RoleRegistry.upsert_role("TENANT_ADMIN", :process_routing_role, group_id,
                 prefix: schema_name
               )

      groups_before = group_names(schema_name)
      roles_before = role_rows(schema_name)
      assert [%TenantRole{name: "TENANT_ADMIN", kind: :process_routing_role}] = roles_before

      assert {:error, {:role_name_taken_by_routing_role, "TENANT_ADMIN"}} =
               RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)

      # Nothing written: no group, no other binding, and the routing binding keeps its kind and group.
      assert group_names(schema_name) == groups_before

      assert [after_row] = role_rows(schema_name)
      assert after_row.name == "TENANT_ADMIN"
      assert after_row.kind == :process_routing_role
      assert after_row.group_id == group_id
      assert after_row.id == hd(roles_before).id
    end

    test "provision_and_migrate/1 reports the collision as role_seeding_failed and leaves the tenant :migrating" do
      Fixture.unpin!()
      tenant = new_migrating_tenant!()

      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      assert {:ok, _applied} = TenantProvisioning.replay_migrations(tenant.id)

      {:ok, %Group{id: group_id}} =
        RoleRegistry.get_or_create_group_by_name("routing-g", prefix: schema_name)

      assert {:ok, _} =
               RoleRegistry.upsert_role("TENANT_ADMIN", :process_routing_role, group_id,
                 prefix: schema_name
               )

      assert {:error, {:role_seeding_failed, {:role_name_taken_by_routing_role, "TENANT_ADMIN"}}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      assert %Tenant{status: :migrating} = Repo.get(Tenant, tenant.id)
      assert role_names(schema_name) == ["TENANT_ADMIN"]
    end

    test "a pre-existing :platform_role TENANT_ADMIN binding is NOT a collision: seeding keeps its group and succeeds" do
      %{schema_name: schema_name} = TenantFixture.provisioned_tenant!(slug_prefix: "req447-keep")

      {:ok, %Group{id: group_id}} =
        RoleRegistry.get_or_create_group_by_name("TENANT_ADMIN", prefix: schema_name)

      assert {:ok, _} =
               RoleRegistry.upsert_role("TENANT_ADMIN", :platform_role, group_id,
                 prefix: schema_name
               )

      assert {:ok, roles} = RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)
      assert Enum.find(roles, &(&1.name == "TENANT_ADMIN")).group_id == group_id
    end
  end

  describe "AC7: the realm file (priv/keycloak/realms/bpm-default.json)" do
    @realm_path "priv/keycloak/realms/bpm-default.json"

    defp realm, do: @realm_path |> File.read!() |> Jason.decode!()

    # Every JSON path at which the string "TENANT_ADMIN" appears as a value or as the value of a "name".
    defp paths_mentioning(json, needle), do: do_paths(json, needle, [])

    defp do_paths(value, needle, path) when is_binary(value),
      do: if(value == needle, do: [Enum.reverse(path)], else: [])

    defp do_paths(value, needle, path) when is_map(value),
      do: Enum.flat_map(value, fn {k, v} -> do_paths(v, needle, [k | path]) end)

    defp do_paths(value, needle, path) when is_list(value),
      do:
        value
        |> Enum.with_index()
        |> Enum.flat_map(fn {v, i} -> do_paths(v, needle, [i | path]) end)

    defp do_paths(_other, _needle, _path), do: []

    test "TENANT_ADMIN is a realm role and the realm role list equals roles/0" do
      names = realm() |> get_in(["roles", "realm"]) |> Enum.map(& &1["name"])

      assert "TENANT_ADMIN" in names
      assert length(names) == length(Letflow.Api.Authorization.roles())
      assert "TENANT_AUDITOR" in names
      assert List.last(names) == "TENANT_AUDITOR"
    end

    test "tenant-admin-user exists with exactly [TENANT_ADMIN]; admin-user is still PLATFORM_ADMIN only; no other user holds TENANT_ADMIN" do
      users = realm()["users"]
      by_name = Map.new(users, &{&1["username"], &1})

      assert %{"realmRoles" => ["TENANT_ADMIN"], "enabled" => true} = by_name["tenant-admin-user"]
      assert by_name["admin-user"]["realmRoles"] == ["PLATFORM_ADMIN"]

      holders = for u <- users, "TENANT_ADMIN" in (u["realmRoles"] || []), do: u["username"]
      assert holders == ["tenant-admin-user"]
    end

    test "TENANT_ADMIN appears ONLY as the realm role definition and on tenant-admin-user: not a default role, default group, composite or client role" do
      json = realm()

      user_index =
        Enum.find_index(json["users"], &(&1["username"] == "tenant-admin-user"))

      role_index =
        Enum.find_index(get_in(json, ["roles", "realm"]), &(&1["name"] == "TENANT_ADMIN"))

      assert Enum.sort(paths_mentioning(json, "TENANT_ADMIN")) ==
               Enum.sort([
                 ["roles", "realm", role_index, "name"],
                 ["users", user_index, "realmRoles", 0]
               ])

      # The keys under which Keycloak keeps default roles / default groups are absent.
      for key <- ["defaultRoles", "defaultRole", "defaultGroups", "groups"] do
        refute Map.has_key?(json, key), "unexpected top-level key #{key}"
      end

      # No realm role is composite (a composite of PLATFORM_ADMIN or another role could grant it).
      for role <- get_in(json, ["roles", "realm"]) do
        refute Map.get(role, "composite") in [true, "true"], "composite role #{role["name"]}"
        refute Map.has_key?(role, "composites"), "composites on #{role["name"]}"
      end
    end
  end
end
