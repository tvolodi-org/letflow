defmodule Letflow.TenantOnboardingTest do
  @moduledoc """
  Tests for `Letflow.TenantOnboarding` (REQ-076 AC9 — SCOPE EXTENSION, run
  `WF02-REQ076-20260822`, ISS-0230). See `test/specs/REQ-076.md`'s AC9 section for the
  full rationale, and `lib/letflow/design/req076-identity-tokens-roles-onboarding.md`
  §11 for the design.

  Uses `Letflow.DataCase` (real Postgres) but, like
  `test/letflow/tenant_provisioning_test.exs` (which this file follows directly as its
  style precedent), switches `Letflow.Repo` to Sandbox `:auto` mode for the one describe
  block that calls `Ecto.Migrator.run/4` (via `TenantProvisioning.replay_migrations/2`
  and `TenantOnboarding.recover_provisioning/1`) — `Ecto.Migrator` genuinely needs a
  second, independent database connection that DataCase's single-connection sandboxed
  transaction cannot supply (empirically confirmed in `tenant_provisioning_test.exs`'s
  own moduledoc). Real Postgres state is created and is cleaned up explicitly in
  `on_exit/1` rather than relying on transaction rollback.

  `async: false` for the whole module, same reasoning as `tenant_provisioning_test.exs`:
  ExUnit fully drains all `async: true` modules before running any `async: false` module,
  and runs `async: false` modules strictly one at a time — there is no other test's
  sandboxed connection to disturb at the moment this file's `:auto`-mode switch runs.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantRole
  alias Letflow.TenantOnboarding
  alias Letflow.TenantOnboarding.BrokenMigrationFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # oidc_mode: :disabled -- irrelevant to this file, matches
  # tenant_provisioning_test.exs's own insert_tenant!/0 convention.
  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req076-ac9"),
        display_name: "REQ-076 AC9 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp registration_count(tenant_id) do
    Registration |> where([r], r.tenant_id == ^tenant_id) |> Repo.aggregate(:count)
  end

  defp table_exists_in_schema?(schema_name, table_name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)",
        [schema_name, table_name]
      )

    exists?
  end

  # NOTE(ISS-0030): describe/test names kept short -- ExUnit's combined
  # "test " <> describe <> " " <> test_name atom is capped at 255 chars (BEAM
  # SystemLimitError). Full rationale lives in test/specs/REQ-076.md's AC9 section.
  describe "AC9: recover_provisioning/1 (ISS-0230)" do
    setup do
      # Ecto.Migrator.run/4 (invoked both by the deliberately-broken replay below and
      # by recover_provisioning/1's own real-manifest replay) needs a second, genuinely
      # independent connection beyond this process's single sandboxed one -- see this
      # file's moduledoc and tenant_provisioning_test.exs's own identical setup for the
      # full empirical justification. Switching to :auto mode here means every Repo call
      # in this describe block is a real, committing call, cleaned up manually below.
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      tenant = insert_tenant!()

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

      %{tenant: tenant}
    end

    test "recovers a half-provisioned tenant and is idempotent on a second call",
         %{tenant: tenant} do
      # 1. Provision the schema for real, then force replay_migrations/2 to fail via
      #    the broken fixture (same forced-failure mechanism
      #    tenant_provisioning_test.exs's own AC3 describe block established: a
      #    migration_source override, never the default manifest).
      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      assert {:error, {:migration_failed, _exception}} =
               TenantProvisioning.replay_migrations(tenant.id, [{1, BrokenMigrationFixture}])

      # 2. Survival: no rollback -- the tenants row is intact, exactly one
      #    tenant_schemas row exists, and migrations_applied_at is still nil. This is
      #    the exact state WF03-ISS0230-20260822 measured against real Postgres.
      assert %Tenant{} = Repo.get(Tenant, tenant.id)

      assert %Registration{migrations_applied_at: nil} =
               Repo.get_by(Registration, tenant_id: tenant.id)

      assert registration_count(tenant.id) == 1

      # 3. Invoke the AC9 recovery entry point -- real (default) migration manifest,
      #    never the broken fixture (recover_provisioning/1 always converges onto the
      #    real shipped manifest, design §11.2.1 step 2).
      assert {:ok, %Registration{migrations_applied_at: %NaiveDateTime{}}} =
               TenantOnboarding.recover_provisioning(tenant.id)

      # 4. Full convergence: the schema is genuinely migrated (spot-checked via a real
      #    tenant-scoped production table, "users", under the tenant's own schema --
      #    not merely a returned :ok), still exactly one tenant_schemas row, and the
      #    tenant's status flipped to :active (AC10's status-flip step, exercised here
      #    via AC9's own recovery path).
      assert table_exists_in_schema?(schema_name, "users")
      assert registration_count(tenant.id) == 1
      assert %Tenant{status: :active} = Repo.get(Tenant, tenant.id)

      # 5. Invoke the SAME entry point a SECOND time, against the now-healthy tenant --
      #    mandatory per AC9's own wording, not optional. Success with unchanged
      #    cardinality (no duplicate schema, no duplicate tenant_schemas row) is what
      #    demonstrates idempotence.
      assert {:ok, %Registration{migrations_applied_at: %NaiveDateTime{}}} =
               TenantOnboarding.recover_provisioning(tenant.id)

      assert registration_count(tenant.id) == 1
      assert %Tenant{status: :active} = Repo.get(Tenant, tenant.id)
      assert table_exists_in_schema?(schema_name, "users")
    end
  end

  # ISS-0778 T3 (design §3.3/§5): provision_and_migrate/1 gains a THIRD step
  # (RoleRegistry.seed_default_platform_role_groups/1) between migration replay and
  # activation. This describe block proves that step is genuinely exercised by the
  # real onboarding-orchestration sequence -- not merely that the seeding function
  # itself works in isolation (that is T1, test/letflow/role_registry_test.exs) --
  # and proves design §3.3's explicit ordering claim: a role-seeding failure blocks
  # activation (tenant stays :migrating, not :active) and is recoverable once the
  # underlying failure clears, the same way any other partial-provisioning failure
  # already is (AC9, the describe block above).
  describe "ISS-0778 T3: provision_and_migrate/1 seeds platform roles as part of real provisioning" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      # Mirrors Letflow.Routers.Onboarding.handle_create/1's own real behavior
      # (design §3's AC10 status lifecycle: "status" => "migrating" at creation) --
      # not insert_tenant!/0's bare default (:active), so the failure test below can
      # actually observe "activation was blocked" rather than "an already-active
      # tenant stayed active".
      tenant =
        %Tenant{}
        |> Tenant.create_changeset(
          %{
            slug: Letflow.TenantSlugFixture.unique_slug("iss0778-t3"),
            display_name: "ISS-0778 T3 Test Tenant",
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

      %{tenant: tenant}
    end

    defp tenant_role_rows(schema_name) do
      Repo.all(from(t in TenantRole, order_by: [asc: t.name]), prefix: schema_name)
    end

    # ISS-0778 T3 failure-path fixture: installs a real, deterministic Postgres
    # AFTER INSERT trigger on <schema>.groups that deletes the just-inserted row
    # whenever its name matches `role_name`, synchronously, inside the SAME
    # transaction as the INSERT itself -- not a race, not a sleep, not unseeded
    # randomness (test_developer_guide.md principle 3 / DIRECTIVE T-1: real Postgres,
    # no mocked database).
    #
    # This exploits RoleRegistry.get_or_create_group_by_name/2's OWN EXISTING
    # defensive post-insert verification (lib/letflow/identity/role_registry.ex's
    # insert_group/2, written for the "on_conflict :nothing raced against a
    # concurrent insert" case: `if Repo.get(Group, id, prefix: prefix) do ... else
    # fetch_group_by_name(...) end`) -- the trigger makes that check genuinely
    # observe a vanished row every single time, deterministically, so
    # get_or_create_group_by_name/2 falls through to fetch_group_by_name/2, finds
    # nothing either, and returns {:error, :group_not_found} for real. No
    # modification to any lib/ code.
    #
    # Why this specific mechanism, not a simpler one (documented, not just chosen
    # by default): every one of RoleRegistry's OWN explicit validation branches
    # (name format, the closed platform-role-name-literal check) is structurally
    # unreachable for a name that already IS one of
    # Letflow.Api.Authorization.roles/0's own six literals by construction --
    # seed_default_platform_role_groups/1 never passes it anything else. The
    # genuinely reachable failure modes are (a) a real concurrent-delete race
    # against Repo.get(Group, group_id) inside do_upsert_role/4's own transaction
    # (non-deterministic, rejected -- would be exactly the "unseeded randomness"
    # this project's test guide forbids), or (b) infrastructure-level corruption
    # (e.g. a dropped unique index), which Ecto does NOT convert into a graceful
    # {:error, _} -- Repo.insert/Repo.get raise an uncaught Postgrex.Error for that
    # class of failure instead, which would crash provision_and_migrate/1 rather
    # than exercising its documented {:error, {:role_seeding_failed, _}} tagged-error
    # branch. This trigger-based sabotage is the one mechanism that is BOTH fully
    # deterministic AND produces the exact graceful failure shape the design (§3.3)
    # documents.
    # Plain double-quoted Elixir strings below, NOT the ~s(...) sigil -- Elixir's
    # sigil reader treats a bare "$" specially even inside ~s(...) (confirmed
    # empirically: `~s($$)` raises `SyntaxError: unexpected token: "$"` at compile
    # time, while a plain `"$$"` string does not), and Postgres's dollar-quoted
    # function-body syntax (`AS $$ ... $$`) needs a literal, unescaped `$$`.
    defp install_group_insert_sabotage!(schema_name, role_name) do
      Repo.query!("
        CREATE FUNCTION \"#{schema_name}\".iss0778_sabotage_group_insert() RETURNS trigger AS $$
        BEGIN
          DELETE FROM \"#{schema_name}\".groups WHERE id = NEW.id;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
      ")

      Repo.query!("
        CREATE TRIGGER iss0778_sabotage_trigger
        AFTER INSERT ON \"#{schema_name}\".groups
        FOR EACH ROW
        WHEN (NEW.name = '#{role_name}')
        EXECUTE FUNCTION \"#{schema_name}\".iss0778_sabotage_group_insert();
      ")
    end

    defp drop_group_insert_sabotage!(schema_name) do
      Repo.query!("DROP TRIGGER IF EXISTS iss0778_sabotage_trigger ON \"#{schema_name}\".groups")

      Repo.query!("DROP FUNCTION IF EXISTS \"#{schema_name}\".iss0778_sabotage_group_insert()")
    end

    test "a freshly-provisioned ordinary tenant has its tenant_role rows (every role but PLATFORM_ADMIN; REQ-447/448)",
         %{tenant: tenant} do
      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      rows = tenant_role_rows(schema_name)
      # REQ-447: an ordinary tenant is seeded every role but PLATFORM_ADMIN.
      expected_names =
        Letflow.Api.Authorization.roles()
        |> Enum.map(&Atom.to_string/1)
        |> Enum.reject(&(&1 == "PLATFORM_ADMIN"))

      assert length(rows) == length(expected_names)
      assert Enum.map(rows, & &1.name) |> Enum.sort() == Enum.sort(expected_names)
      assert "TENANT_ADMIN" in Enum.map(rows, & &1.name)
      assert Enum.all?(rows, &(&1.kind == :platform_role))

      # AC10's status-flip step also ran -- the tenant genuinely reached :active,
      # not merely that seeding succeeded in isolation.
      assert %Tenant{status: :active} = Repo.get(Tenant, tenant.id)
    end

    test "seeding failure blocks activation (tenant stays :migrating) and is recoverable once the failure clears",
         %{tenant: tenant} do
      # Provision + migrate directly first -- real Postgres schema, groups/
      # tenant_role tables exist with their normal DDL -- so this test can install
      # its own sabotage trigger against a clean, already-migrated schema BEFORE
      # calling TenantOnboarding.provision_and_migrate/1 for real. Both primitives
      # are idempotent (design §2.4/§11), so provision_and_migrate/1 re-running them
      # below is a genuine no-op, not a second real provisioning -- the ONLY new
      # work that call performs is the role-seeding step under test.
      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

      # REQ-447: PLATFORM_ADMIN is not seeded in an ordinary tenant, so the first role the
      # seeder reaches is PROCESS_DESIGNER (Authorization.roles/0's order without PLATFORM_ADMIN).
      install_group_insert_sabotage!(schema_name, "PROCESS_DESIGNER")

      assert {:error, {:role_seeding_failed, :group_not_found}} =
               TenantOnboarding.provision_and_migrate(tenant.id)

      # Activation was blocked -- design §3.3's load-bearing claim: letting a tenant
      # reach :active with its role bindings unseeded would reproduce ISS-0778 under
      # a different trigger (a role-seed DB error instead of "nobody ever wrote the
      # seeding code").
      assert %Tenant{status: :migrating} = Repo.get(Tenant, tenant.id)

      # No partial platform-role bindings survived either -- seeding halted on the
      # FIRST seeded role name in Authorization.roles/0's own declared order
      # ("PROCESS_DESIGNER" here), before any of the others were even attempted.
      assert tenant_role_rows(schema_name) == []

      drop_group_insert_sabotage!(schema_name)

      # Recoverable (design §3.3's other half, same mechanism as AC9 above): the
      # SAME recovery entry point, re-invoked once the underlying failure clears,
      # converges correctly.
      assert {:ok, %Registration{schema_name: ^schema_name}} =
               TenantOnboarding.recover_provisioning(tenant.id)

      rows = tenant_role_rows(schema_name)

      expected_names =
        Letflow.Api.Authorization.roles()
        |> Enum.map(&Atom.to_string/1)
        |> Enum.reject(&(&1 == "PLATFORM_ADMIN"))

      assert length(rows) == length(expected_names)
      assert Enum.map(rows, & &1.name) |> Enum.sort() == Enum.sort(expected_names)

      assert %Tenant{status: :active} = Repo.get(Tenant, tenant.id)
    end
  end
end
