defmodule Letflow.Identity.TenantAuditorSeedingTest do
  @moduledoc """
  REQ-448 AC (`lib/letflow/design/req448-tenant-auditor-role.md` sections 4, 5 and 8; spec
  `test/specs/REQ-448.md`): seeding, backfill, the widened name-collision guard and the realm file
  for the `TENANT_AUDITOR` role. Model: `tenant_admin_seeding_test.exs`.

    * New tenants: an ordinary tenant provisioned through the real
      `Letflow.TenantOnboarding.provision_and_migrate/1` has a `TENANT_AUDITOR` group and a
      `:platform_role` binding; the pinned platform tenant has it too (and `PLATFORM_ADMIN`).
    * Existing tenants: `Letflow.Identity.RoleBackfill.run/0` seeds the binding on a tenant that
      lacks it (`:seeded`); a second run lists the tenant under `:unchanged` and writes no row,
      resets no `role_claims_synced_at` marker and touches no `group_members` row.
    * Collision guard: a `:process_routing_role` row named `TENANT_AUDITOR` makes the seed return
      `{:error, {:role_name_taken_by_routing_role, "TENANT_AUDITOR"}}` with the row untouched.
    * Realm file: `priv/keycloak/realms/bpm-default.json` has the `TENANT_AUDITOR` realm role and
      an `auditor-user` holding exactly `["TENANT_AUDITOR"]`.

  `async: false`: the platform tenant pin is VM-global application config.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Api.Authorization
  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleBackfill
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantOnboarding
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # A tenant in the `migrating` state exactly as `POST /onboarding` creates it; cleanup as in
  # `tenant_admin_seeding_test.exs`.
  defp new_migrating_tenant! do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug("req448-seed"),
          display_name: "REQ-448 seeding tenant",
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

  defp insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req448-user-#{System.unique_integer([:positive, :monotonic])}",
      display_name: "REQ-448 Test User",
      email: "req448-#{System.unique_integer([:positive, :monotonic])}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  describe "new tenants: provision_and_migrate/1 seeds TENANT_AUDITOR" do
    test "an ordinary tenant has the TENANT_AUDITOR group and a :platform_role binding to it, seedable_role_names/1 ends with it, and PLATFORM_ADMIN is absent" do
      other = TenantFixture.provisioned_tenant!(slug_prefix: "req448-seed-pin")
      Fixture.pin!(other.tenant_id)

      tenant = new_migrating_tenant!()

      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      seedable = RoleRegistry.seedable_role_names(schema_name)
      assert List.last(seedable) == "TENANT_AUDITOR"
      refute "PLATFORM_ADMIN" in seedable

      assert Enum.sort(role_names(schema_name)) == Enum.sort(seedable)
      assert "TENANT_AUDITOR" in group_names(schema_name)
      refute "PLATFORM_ADMIN" in role_names(schema_name)

      binding = Enum.find(role_rows(schema_name), &(&1.name == "TENANT_AUDITOR"))
      assert binding.kind == :platform_role

      assert %Group{name: "TENANT_AUDITOR"} =
               Repo.get(Group, binding.group_id, prefix: schema_name)
    end

    test "the pinned platform tenant has every role of roles/0, TENANT_AUDITOR last" do
      tenant = new_migrating_tenant!()
      Fixture.pin!(tenant.id)

      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      all_names = Enum.map(Authorization.roles(), &Atom.to_string/1)

      assert RoleRegistry.seedable_role_names(schema_name) == all_names
      assert List.last(all_names) == "TENANT_AUDITOR"
      assert Enum.sort(role_names(schema_name)) == Enum.sort(all_names)
      assert "TENANT_AUDITOR" in group_names(schema_name)
      assert "PLATFORM_ADMIN" in group_names(schema_name)
    end

    test "re-seeding is idempotent for TENANT_AUDITOR: same group id, no extra rows" do
      ordinary = TenantFixture.provisioned_tenant!(slug_prefix: "req448-seed-idem")
      schema = ordinary.schema_name

      assert {:ok, first} = RoleRegistry.seed_default_platform_role_groups(prefix: schema)
      assert {:ok, second} = RoleRegistry.seed_default_platform_role_groups(prefix: schema)

      assert Enum.find(first, &(&1.name == "TENANT_AUDITOR")).group_id ==
               Enum.find(second, &(&1.name == "TENANT_AUDITOR")).group_id

      assert Repo.aggregate(TenantRole, :count, prefix: schema) == length(first)
      assert Enum.count(group_names(schema), &(&1 == "TENANT_AUDITOR")) == 1
    end
  end

  describe "existing tenants: RoleBackfill.run/0 adds the binding, then is a no-op" do
    # A tenant exactly as it stood before REQ-448: every ordinary seedable name EXCEPT
    # TENANT_AUDITOR is bound, and one user is a member of the TASK_WORKER group with a
    # role_claims_synced_at marker.
    defp pre_req448_tenant!(slug_prefix) do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

      assert {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)

      %TenantRole{} =
        binding = Repo.get_by!(TenantRole, [name: "TENANT_AUDITOR"], prefix: schema_name)

      Repo.delete!(binding, prefix: schema_name)
      Repo.delete!(Repo.get!(Group, binding.group_id, prefix: schema_name), prefix: schema_name)
      refute "TENANT_AUDITOR" in role_names(schema_name)

      user = insert_user!(schema_name)
      worker = Repo.get_by!(TenantRole, [name: "TASK_WORKER"], prefix: schema_name)
      {:ok, _} = Identity.add_group_member(worker.group_id, user.id, prefix: schema_name)

      %{tenant_id: tenant_id, schema_name: schema_name, user: user}
    end

    defp mark_synced!(schema_name) do
      marker = DateTime.utc_now()
      Repo.update_all(User, [set: [role_claims_synced_at: marker]], prefix: schema_name)
      marker
    end

    defp counts(schema_name) do
      %{
        groups: Repo.aggregate(Group, :count, prefix: schema_name),
        tenant_roles: Repo.aggregate(TenantRole, :count, prefix: schema_name),
        group_members: Repo.aggregate(GroupMember, :count, prefix: schema_name),
        markers:
          from(u in User, order_by: u.id, select: {u.id, u.role_claims_synced_at})
          |> Repo.all(prefix: schema_name)
      }
    end

    test "first run: the tenant is :seeded and gains TENANT_AUDITOR; second run: :unchanged with groups, tenant_role, group_members and every marker unchanged" do
      %{tenant_id: tenant_id, schema_name: schema_name, user: user} =
        pre_req448_tenant!("req448-bf")

      _ = mark_synced!(schema_name)
      before_first = counts(schema_name)

      assert {:ok, %{seeded: seeded, unchanged: unchanged_first}} = RoleBackfill.run()
      assert tenant_id in seeded
      refute tenant_id in unchanged_first

      binding = Repo.get_by!(TenantRole, [name: "TENANT_AUDITOR"], prefix: schema_name)
      assert binding.kind == :platform_role

      assert %Group{name: "TENANT_AUDITOR"} =
               Repo.get!(Group, binding.group_id, prefix: schema_name)

      after_first = counts(schema_name)
      assert after_first.tenant_roles == before_first.tenant_roles + 1
      assert after_first.groups == before_first.groups + 1
      # The backfill never writes group_members: nobody is auto-granted the new role.
      assert after_first.group_members == before_first.group_members

      assert Repo.aggregate(
               from(m in GroupMember, where: m.group_id == ^binding.group_id),
               :count,
               prefix: schema_name
             ) == 0

      # ISS-0910 (documented): a :seeded tenant's markers are reset once so the claim sync reruns.
      assert [{_id, nil}] = after_first.markers

      # Second run: put a marker back, then prove the run neither writes nor resets anything.
      restored = mark_synced!(schema_name)
      before_second = counts(schema_name)

      assert {:ok, %{seeded: seeded_2, unchanged: unchanged_2}} = RoleBackfill.run()
      refute tenant_id in seeded_2
      assert tenant_id in unchanged_2

      after_second = counts(schema_name)
      assert after_second == before_second
      assert [{user_id, ^restored}] = after_second.markers
      assert user_id == user.id

      assert Repo.get_by!(TenantRole, [name: "TENANT_AUDITOR"], prefix: schema_name).id ==
               binding.id
    end

    test "after the backfill the tenant holds exactly its seedable set, TENANT_AUDITOR included" do
      %{schema_name: schema_name} = pre_req448_tenant!("req448-bf-set")

      assert {:ok, _} = RoleBackfill.run()

      assert Enum.sort(role_names(schema_name)) ==
               Enum.sort(RoleRegistry.seedable_role_names(schema_name))

      assert "TENANT_AUDITOR" in role_names(schema_name)
    end
  end

  describe "name-collision guard: :process_routing_role named TENANT_AUDITOR" do
    test "the seed returns the error before any write; the routing row keeps its kind, group and id" do
      %{schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req448-collide")

      {:ok, %Group{id: group_id}} =
        RoleRegistry.get_or_create_group_by_name("auditor-routing-group", prefix: schema_name)

      assert {:ok, %TenantRole{kind: :process_routing_role}} =
               RoleRegistry.upsert_role("TENANT_AUDITOR", :process_routing_role, group_id,
                 prefix: schema_name
               )

      groups_before = group_names(schema_name)
      roles_before = role_rows(schema_name)
      assert [%TenantRole{name: "TENANT_AUDITOR", kind: :process_routing_role}] = roles_before

      assert {:error, {:role_name_taken_by_routing_role, "TENANT_AUDITOR"}} =
               RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)

      assert group_names(schema_name) == groups_before
      assert [after_row] = role_rows(schema_name)
      assert after_row.name == "TENANT_AUDITOR"
      assert after_row.kind == :process_routing_role
      assert after_row.group_id == group_id
      assert after_row.id == hd(roles_before).id
    end

    test "RoleBackfill.run/0 halts with {:backfill_failed, tenant_id, the collision} and leaves the row unchanged" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req448-collide-bf")

      {:ok, %Group{id: group_id}} =
        RoleRegistry.get_or_create_group_by_name("auditor-routing-group", prefix: schema_name)

      assert {:ok, _} =
               RoleRegistry.upsert_role("TENANT_AUDITOR", :process_routing_role, group_id,
                 prefix: schema_name
               )

      assert {:error,
              {:backfill_failed, ^tenant_id, {:role_name_taken_by_routing_role, "TENANT_AUDITOR"}}} =
               RoleBackfill.run()

      assert [row] = role_rows(schema_name)
      assert row.kind == :process_routing_role
      assert row.group_id == group_id
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
               RoleRegistry.upsert_role("TENANT_AUDITOR", :process_routing_role, group_id,
                 prefix: schema_name
               )

      assert {:error,
              {:role_seeding_failed, {:role_name_taken_by_routing_role, "TENANT_AUDITOR"}}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      assert %Tenant{status: :migrating} = Repo.get(Tenant, tenant.id)
      assert role_names(schema_name) == ["TENANT_AUDITOR"]
    end

    test "a pre-existing :platform_role TENANT_AUDITOR binding is NOT a collision: seeding keeps its group and succeeds" do
      %{schema_name: schema_name} = TenantFixture.provisioned_tenant!(slug_prefix: "req448-keep")

      {:ok, %Group{id: group_id}} =
        RoleRegistry.get_or_create_group_by_name("TENANT_AUDITOR", prefix: schema_name)

      assert {:ok, _} =
               RoleRegistry.upsert_role("TENANT_AUDITOR", :platform_role, group_id,
                 prefix: schema_name
               )

      assert {:ok, roles} = RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)
      assert Enum.find(roles, &(&1.name == "TENANT_AUDITOR")).group_id == group_id
    end

    test "the guard is not TENANT_AUDITOR-only: a routing row named TENANT_ADMIN is still refused with its own name" do
      %{schema_name: schema_name} = TenantFixture.provisioned_tenant!(slug_prefix: "req448-admin")

      {:ok, %Group{id: group_id}} =
        RoleRegistry.get_or_create_group_by_name("admin-routing-group", prefix: schema_name)

      assert {:ok, _} =
               RoleRegistry.upsert_role("TENANT_ADMIN", :process_routing_role, group_id,
                 prefix: schema_name
               )

      assert {:error, {:role_name_taken_by_routing_role, "TENANT_ADMIN"}} =
               RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)
    end
  end

  describe "the realm file (priv/keycloak/realms/bpm-default.json)" do
    @realm_path "priv/keycloak/realms/bpm-default.json"

    defp realm, do: @realm_path |> File.read!() |> Jason.decode!()

    # Every JSON path at which `needle` appears as a string value.
    defp paths_mentioning(value, needle, path \\ [])

    defp paths_mentioning(value, needle, path) when is_binary(value),
      do: if(value == needle, do: [Enum.reverse(path)], else: [])

    defp paths_mentioning(value, needle, path) when is_map(value),
      do: Enum.flat_map(value, fn {k, v} -> paths_mentioning(v, needle, [k | path]) end)

    defp paths_mentioning(value, needle, path) when is_list(value),
      do:
        value
        |> Enum.with_index()
        |> Enum.flat_map(fn {v, i} -> paths_mentioning(v, needle, [i | path]) end)

    defp paths_mentioning(_other, _needle, _path), do: []

    test "TENANT_AUDITOR is a realm role and the realm role list equals roles/0 (set and order)" do
      names = realm() |> get_in(["roles", "realm"]) |> Enum.map(& &1["name"])

      assert "TENANT_AUDITOR" in names
      assert names == Enum.map(Authorization.roles(), &Atom.to_string/1)
    end

    test "auditor-user holds exactly [TENANT_AUDITOR]; admin-user and tenant-admin-user are unchanged; no other user holds TENANT_AUDITOR" do
      users = realm()["users"]
      by_name = Map.new(users, &{&1["username"], &1})

      assert %{"realmRoles" => ["TENANT_AUDITOR"], "enabled" => true} = by_name["auditor-user"]
      assert by_name["admin-user"]["realmRoles"] == ["PLATFORM_ADMIN"]
      assert by_name["tenant-admin-user"]["realmRoles"] == ["TENANT_ADMIN"]

      holders = for u <- users, "TENANT_AUDITOR" in (u["realmRoles"] || []), do: u["username"]
      assert holders == ["auditor-user"]
    end

    test "TENANT_AUDITOR appears ONLY as the realm role definition and on auditor-user: not a default role, default group, composite or client role" do
      json = realm()
      user_index = Enum.find_index(json["users"], &(&1["username"] == "auditor-user"))

      role_index =
        Enum.find_index(get_in(json, ["roles", "realm"]), &(&1["name"] == "TENANT_AUDITOR"))

      assert Enum.sort(paths_mentioning(json, "TENANT_AUDITOR")) ==
               Enum.sort([
                 ["roles", "realm", role_index, "name"],
                 ["users", user_index, "realmRoles", 0]
               ])

      for role <- get_in(json, ["roles", "realm"]) do
        refute Map.get(role, "composite") in [true, "true"], "composite role #{role["name"]}"
        refute Map.has_key?(role, "composites"), "composites on #{role["name"]}"
      end
    end
  end
end
