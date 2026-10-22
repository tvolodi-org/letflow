defmodule Letflow.Identity.RoleBackfillTest do
  @moduledoc """
  Tests for `Letflow.Identity.RoleBackfill` (ISS-0886) — see
  `docs/issues/ISS-0886.yaml` for the full root-cause writeup and
  `lib/letflow/design/iss0886-role-backfill-preexisting-tenants.md` §4 for
  the acceptance-criteria-to-test-case mapping this file implements.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database
  anywhere in this file. Provisions real tenant schemas via
  `Letflow.TenantFixture.provisioned_tenant!/1` (ISS-0112/GH#366's current
  convention — every explicit `Repo` call below carries its own `prefix:`,
  matching that fixture's established usage across the codebase, e.g.
  `test/letflow/engine_dlq_landing_test.exs`, `test/letflow/audit_test.exs`).
  This is a deliberate, non-behavioral deviation from the design doc's own
  §4 sketch, which mirrors the OLDER, more verbose `SET search_path`-based
  fixture `test/letflow/role_registry_test.exs` still carries (predates
  `Letflow.TenantFixture`'s introduction) — the design's own moduledoc calls
  that older shape out as one of "39 copy-paste fixture sites" earmarked for
  eventual migration to `TenantFixture`, not the pattern a brand-new test
  file should adopt today.

  `async: false`: `Letflow.TenantFixture.provisioned_tenant!/1` runs
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` (real, committed
  Postgres state, not a rolled-back sandbox transaction) — matches every
  other test file in this codebase that provisions a real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleBackfill
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  # ---------------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------------

  # Provisions a fresh tenant schema and seeds ONLY PLATFORM_ADMIN into it,
  # simulating a tenant provisioned before ISS-0778 shipped (design §4's
  # `platform_admin_only_tenant_fixture!/0`).
  defp platform_admin_only_tenant_fixture!(slug_prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "ISS-0886 PLATFORM_ADMIN-only fixture"
      )

    {:ok, %Group{id: group_id}} =
      RoleRegistry.get_or_create_group_by_name("PLATFORM_ADMIN", prefix: schema_name)

    insert_legacy_platform_admin_role!(group_id, schema_name)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  # REQ-447 PR 2: RoleRegistry.upsert_role/4 refuses a PLATFORM_ADMIN binding outside the platform
  # tenant, so the LEGACY row (a pre-REQ-447 deployment's data, which this file's subject is
  # backfilling around) is inserted raw.
  defp insert_legacy_platform_admin_role!(group_id, schema_name) do
    %TenantRole{}
    |> TenantRole.changeset(%{name: "PLATFORM_ADMIN", kind: :platform_role, group_id: group_id})
    |> Repo.insert!(prefix: schema_name)
  end

  defp insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "iss0886-user-#{System.unique_integer([:positive, :monotonic])}",
      display_name: "ISS-0886 Test User",
      email: "iss0886-#{System.unique_integer([:positive, :monotonic])}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # Binds a user to the Group backing a given platform-role name within a given
  # tenant schema (design §4's `bind_user_to_platform_role!/3`). Assumes the
  # role's Group already exists (i.e. is called post-backfill).
  defp bind_user_to_platform_role!(user, role_name, schema_name) do
    %TenantRole{group_id: group_id} =
      Repo.get_by(TenantRole, [name: role_name], prefix: schema_name)

    {:ok, _} = Identity.add_group_member(group_id, user.id, prefix: schema_name)
    :ok
  end

  defp platform_role_names(schema_name) do
    TenantRole
    |> Ecto.Query.where(kind: :platform_role)
    |> Repo.all(prefix: schema_name)
    |> Enum.map(& &1.name)
  end

  # ---------------------------------------------------------------------------------
  # AC1 (issue fail-first)
  # ---------------------------------------------------------------------------------

  describe "pre-backfill fail-first (AC1)" do
    test "a TASK_WORKER/CANDIDATE-claimed token resolves ZERO effective roles on a PLATFORM_ADMIN-only tenant, before any backfill runs" do
      %{schema_name: schema_name} = platform_admin_only_tenant_fixture!("iss0886-ac1")
      user = insert_user!(schema_name)

      # No TASK_WORKER group/role exists on this tenant yet (only PLATFORM_ADMIN
      # was seeded) -- there is nothing for a claimed TASK_WORKER/CANDIDATE role
      # to bind this user to, so list_effective_role_names/2 reads back empty,
      # reproducing the issue's own "roles: []" symptom for a non-admin user.
      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == []

      # Confirms this genuinely is the pre-ISS-0778-shaped tenant the fixture
      # claims: exactly one platform-role binding exists (PLATFORM_ADMIN), not
      # all six.
      assert platform_role_names(schema_name) == ["PLATFORM_ADMIN"]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2: run/0 seeds the five missing platform roles
  # ---------------------------------------------------------------------------------

  describe "run/0 seeds the five missing platform roles for a PLATFORM_ADMIN-only tenant (AC2)" do
    test "converges the tenant to the legacy PLATFORM_ADMIN row (kept, REQ-447) plus the seedable platform-role rows (REQ-448: seven, eight in all), and the tenant_id appears under :seeded" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        platform_admin_only_tenant_fixture!("iss0886-ac2")

      assert {:ok, %{seeded: seeded, unchanged: _unchanged}} = RoleBackfill.run()

      assert tenant_id in seeded

      expected_names = Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)
      assert Enum.sort(platform_role_names(schema_name)) == Enum.sort(expected_names)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3: post-backfill effective-role resolution (the issue's core regression assertion)
  # ---------------------------------------------------------------------------------

  describe "post-backfill: a user bound to the newly-seeded TASK_WORKER group resolves non-empty effective roles (AC3)" do
    test "list_effective_role_names/2 returns [\"TASK_WORKER\"] for a user bound after the backfill runs" do
      %{schema_name: schema_name} = platform_admin_only_tenant_fixture!("iss0886-ac3")
      user = insert_user!(schema_name)

      assert {:ok, _} = RoleBackfill.run()

      bind_user_to_platform_role!(user, "TASK_WORKER", schema_name)

      assert Identity.list_effective_role_names(user.id, prefix: schema_name) == ["TASK_WORKER"]
    end
  end

  # ---------------------------------------------------------------------------------
  # Idempotency
  # ---------------------------------------------------------------------------------

  describe "run/0 is idempotent" do
    test "a second call reports the same tenant under :unchanged and writes no duplicate rows" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        platform_admin_only_tenant_fixture!("iss0886-idem")

      assert {:ok, %{seeded: seeded_first}} = RoleBackfill.run()
      assert tenant_id in seeded_first

      assert {:ok, %{seeded: seeded_second, unchanged: unchanged_second}} = RoleBackfill.run()

      refute tenant_id in seeded_second
      assert tenant_id in unchanged_second

      # REQ-447: the fixture's pre-existing legacy PLATFORM_ADMIN group+binding is KEPT (the
      # backfill never deletes it; the migration does) plus the seedable roles (derived below).
      # (REQ-448: the count is derived from seedable_role_names/1, never re-literalled.)
      expected = 1 + length(RoleRegistry.seedable_role_names(schema_name))
      assert Repo.aggregate(Group, :count, prefix: schema_name) == expected
      assert Repo.aggregate(TenantRole, :count, prefix: schema_name) == expected
    end
  end

  # ---------------------------------------------------------------------------------
  # Already-fully-seeded tenant is a no-op
  # ---------------------------------------------------------------------------------

  describe "run/0 against an already-fully-seeded tenant (normal onboarding path)" do
    test "reports the tenant under :unchanged, with zero writes" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0886-fullyseeded",
          display_name: "ISS-0886 fully-seeded fixture"
        )

      # Mirrors TenantOnboarding.provision_and_migrate/1's own onboarding-time
      # call (ISS-0778) -- unchanged, reused as-is.
      assert {:ok, roles} = RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)
      expected = length(RoleRegistry.seedable_role_names(schema_name))
      assert length(roles) == expected

      assert {:ok, %{seeded: seeded, unchanged: unchanged}} = RoleBackfill.run()

      refute tenant_id in seeded
      assert tenant_id in unchanged

      assert Repo.aggregate(Group, :count, prefix: schema_name) == expected
      assert Repo.aggregate(TenantRole, :count, prefix: schema_name) == expected
    end
  end

  # ---------------------------------------------------------------------------------
  # Multi-tenant isolation
  # ---------------------------------------------------------------------------------

  describe "run/0 processes every tenant independently" do
    test "backfilling tenant A does not affect tenant B's own tenant_role rows" do
      %{tenant_id: tenant_id_a, schema_name: schema_a} =
        platform_admin_only_tenant_fixture!("iss0886-multi-a")

      %{tenant_id: tenant_id_b, schema_name: schema_b} =
        platform_admin_only_tenant_fixture!("iss0886-multi-b")

      assert {:ok, %{seeded: seeded}} = RoleBackfill.run()

      assert tenant_id_a in seeded
      assert tenant_id_b in seeded

      expected_names = Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1)
      assert Enum.sort(platform_role_names(schema_a)) == Enum.sort(expected_names)
      assert Enum.sort(platform_role_names(schema_b)) == Enum.sort(expected_names)

      # Tenant A's six Group ids are distinct from tenant B's six Group ids --
      # proves the sweep created independent bindings per tenant schema, not
      # one shared set accidentally reused across both.
      group_ids_a = Repo.all(Group, prefix: schema_a) |> Enum.map(& &1.id) |> MapSet.new()
      group_ids_b = Repo.all(Group, prefix: schema_b) |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.disjoint?(group_ids_a, group_ids_b)
    end
  end

  # ---------------------------------------------------------------------------------
  # Hard-failure propagation
  # ---------------------------------------------------------------------------------

  describe "run/0 halts on a hard per-tenant failure" do
    test "a tenant whose physical schema vanished mid-sweep halts the sweep with {:error, {:backfill_failed, tenant_id, reason}}, not a crash" do
      %{tenant_id: vanished_tenant_id, schema_name: vanished_schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0886-vanished",
          display_name: "ISS-0886 vanished-schema fixture",
          teardown: false
        )

      # Registered BEFORE the schema drop below, and BEFORE either assertion,
      # so this tenant's Registration/Tenant rows are reliably cleaned up even
      # if an assertion below fails -- teardown: false above means
      # TenantFixture's own on_exit does not run this cleanup for us (its
      # normal DROP SCHEMA path would be a no-op here anyway, since the schema
      # is deliberately dropped by this test itself first). Guarding against
      # this test leaving a permanently "vanished-schema" Registration row
      # behind to poison every later RoleBackfill.run() call in this suite
      # (a real failure mode hit once already during this file's own
      # development -- see docs/anti-patterns.md-worthy lesson: a manual
      # cleanup statement placed AFTER an assertion never runs if that
      # assertion fails).
      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

        Repo.delete_all(
          from(r in TenantProvisioning.Registration, where: r.tenant_id == ^vanished_tenant_id)
        )

        Repo.delete_all(from(t in Letflow.Identity.Tenant, where: t.id == ^vanished_tenant_id))
      end)

      # Drop the physical schema WITHOUT deleting the Registration row --
      # exactly the "Registration present, schema absent" window
      # test/letflow/tenant_provisioning/backfill_test.exs's own ISS-0343
      # regression test constructs the identical way.
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{vanished_schema_name}" CASCADE))

      assert {:error, {:backfill_failed, ^vanished_tenant_id, _reason}} = RoleBackfill.run()

      # Direct, tenant_id-scoped confirmation that this test genuinely
      # exercised the vanished-schema window (not some other failure mode):
      # the Registration row is still present, only the physical schema is
      # gone.
      assert %TenantProvisioning.Registration{} =
               Repo.get_by(TenantProvisioning.Registration, tenant_id: vanished_tenant_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # GH 2572: a failed marker reset must not leave a seeded-but-unreset tenant behind
  # ---------------------------------------------------------------------------------

  # Injected failure (same shape as gh2547_ta_audit_paths_test.exs T-19): a trigger on this
  # tenant's audit_entries that raises on the marker reset's audit row only.
  defp create_reset_fault_trigger!(schema_name) do
    Repo.query!(
      ~s|CREATE FUNCTION "#{schema_name}".gh2572_fail_reset() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN IF NEW.action = 'role_claims_sync.reset' THEN RAISE EXCEPTION 'injected fault (GH 2572 test)'; END IF; | <>
        ~s|RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER gh2572_fail_reset BEFORE INSERT ON "#{schema_name}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema_name}".gh2572_fail_reset()|
    )
  end

  defp drop_reset_fault_trigger!(schema_name) do
    Repo.query!(~s|DROP TRIGGER IF EXISTS gh2572_fail_reset ON "#{schema_name}".audit_entries|)
    Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema_name}".gh2572_fail_reset()|)
  end

  describe "run/0 completes a tenant whose marker reset failed on an earlier run (GH 2572)" do
    test "the failed reset rolls the tenant's seed back; the re-run seeds it, resets its markers and reports it, and a fully seeded tenant stays unchanged" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

      %{tenant_id: failing_tenant_id, schema_name: failing_schema} =
        platform_admin_only_tenant_fixture!("gh2572-failing")

      failing_user = insert_user!(failing_schema)
      stamp_role_claims_synced_at!(failing_user, failing_schema, past)

      %{tenant_id: intact_tenant_id, schema_name: intact_schema} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "gh2572-intact",
          display_name: "GH 2572 fully seeded fixture"
        )

      {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: intact_schema)
      intact_user = insert_user!(intact_schema)
      stamp_role_claims_synced_at!(intact_user, intact_schema, past)

      create_reset_fault_trigger!(failing_schema)

      try do
        assert {:error, {:backfill_failed, ^failing_tenant_id, _reason}} = RoleBackfill.run()

        # The seed and the reset are one unit: the failed reset took the seed with it, so the
        # tenant is exactly as it was before the run.
        refute "TENANT_ADMIN" in platform_role_names(failing_schema)

        assert reload_user!(failing_user, failing_schema).role_claims_synced_at ==
                 past
      after
        drop_reset_fault_trigger!(failing_schema)
      end

      # The re-run classifies the failing tenant from the same starting point as a first run:
      # :seeded, markers reset, reported. The intact tenant is :unchanged and keeps its marker.
      assert {:ok, %{seeded: seeded, unchanged: unchanged}} = RoleBackfill.run()
      assert failing_tenant_id in seeded
      assert intact_tenant_id in unchanged

      assert reload_user!(failing_user, failing_schema).role_claims_synced_at == nil
      assert reload_user!(intact_user, intact_schema).role_claims_synced_at == past
      assert "TENANT_ADMIN" in platform_role_names(failing_schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0910: role_claims_synced_at reset on the seeded/:unchanged split
  # ---------------------------------------------------------------------------------
  #
  # See lib/letflow/design/iss0910-role-backfill-resync-marker-reset.md. run/0
  # iterates EVERY tenant registered via TenantProvisioning.list_registrations/0,
  # so each test below provisions its own fresh tenant(s) and relies on
  # TenantFixture.provisioned_tenant!/1's default `teardown: true` (DROP SCHEMA +
  # Registration cleanup via on_exit) to keep prior tests' tenants out of a later
  # test's run/0 call -- without that, the returned counts below (AC4) would be
  # contaminated by whatever other tenants happen to still be registered.

  defp stamp_role_claims_synced_at!(user, schema_name, %DateTime{} = value) do
    user
    |> Ecto.Changeset.change(%{role_claims_synced_at: value})
    |> Repo.update!(prefix: schema_name)
  end

  defp reload_user!(user, schema_name) do
    Repo.get!(User, user.id, prefix: schema_name)
  end

  @a_past_timestamp DateTime.utc_now()
                    |> DateTime.add(-3600, :second)
                    |> DateTime.truncate(:microsecond)

  describe "run/0 resets role_claims_synced_at for a :seeded tenant's users (ISS-0910 AC1)" do
    test "a user with a previously-set marker has it reset to nil after run/0" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        platform_admin_only_tenant_fixture!("iss0910-seeded")

      user = insert_user!(schema_name)
      stamp_role_claims_synced_at!(user, schema_name, @a_past_timestamp)

      assert {:ok, %{seeded: seeded}} = RoleBackfill.run()
      assert tenant_id in seeded

      assert %User{role_claims_synced_at: nil} = reload_user!(user, schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0910 AC2: an :unchanged tenant is never touched
  # ---------------------------------------------------------------------------------

  describe "run/0 leaves an :unchanged tenant's role_claims_synced_at markers untouched (ISS-0910 AC2)" do
    test "a user's existing non-nil marker survives run/0 unchanged when the tenant is already fully seeded" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0910-unchanged",
          display_name: "ISS-0910 already-fully-seeded fixture"
        )

      assert {:ok, roles} = RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)
      assert length(roles) == length(RoleRegistry.seedable_role_names(schema_name))

      user = insert_user!(schema_name)
      original_marker = @a_past_timestamp
      stamp_role_claims_synced_at!(user, schema_name, original_marker)

      assert {:ok, %{seeded: seeded, unchanged: unchanged}} = RoleBackfill.run()
      refute tenant_id in seeded
      assert tenant_id in unchanged

      assert %User{role_claims_synced_at: ^original_marker} = reload_user!(user, schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0910 AC3: idempotency across two successive run/0 calls
  # ---------------------------------------------------------------------------------

  describe "run/0's marker reset is idempotent across two successive calls (ISS-0910 AC3)" do
    test "the second run classifies the now-fully-seeded tenant :unchanged and does not re-touch a marker re-synced after the first run" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        platform_admin_only_tenant_fixture!("iss0910-idem")

      user = insert_user!(schema_name)
      stamp_role_claims_synced_at!(user, schema_name, @a_past_timestamp)

      # First run: tenant is :seeded, marker is reset to nil.
      assert {:ok, %{seeded: seeded_first}} = RoleBackfill.run()
      assert tenant_id in seeded_first
      assert %User{role_claims_synced_at: nil} = reload_user!(user, schema_name)

      # Simulate the user's next login re-syncing their claims (the exact
      # follow-up this reset is meant to provoke) before the second run.
      resynced_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      user = reload_user!(user, schema_name)
      stamp_role_claims_synced_at!(user, schema_name, resynced_at)

      # Second run: tenant now holds all six platform roles, so it is
      # :unchanged -- the already-re-synced marker must NOT be reset back to
      # nil a second time.
      assert {:ok, %{seeded: seeded_second, unchanged: unchanged_second}} = RoleBackfill.run()
      refute tenant_id in seeded_second
      assert tenant_id in unchanged_second

      assert %User{role_claims_synced_at: ^resynced_at} = reload_user!(user, schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0910 AC4: the returned role_claims_markers_reset count is exact
  # ---------------------------------------------------------------------------------

  describe "run/0 returns an accurate role_claims_markers_reset count (ISS-0910 AC4)" do
    test "the returned count equals the exact number of users whose marker was reset, across seeded and unchanged tenants" do
      %{tenant_id: seeded_tenant_id, schema_name: seeded_schema} =
        platform_admin_only_tenant_fixture!("iss0910-count-seeded")

      seeded_users =
        for _ <- 1..3 do
          u = insert_user!(seeded_schema)
          stamp_role_claims_synced_at!(u, seeded_schema, @a_past_timestamp)
          u
        end

      # A user with an ALREADY-nil marker on the same seeded tenant still
      # counts: update_all's return value is "rows matched", not "rows whose
      # value actually changed" -- design §3's "naturally idempotent at the
      # SQL level" note. insert_user!/1 leaves role_claims_synced_at nil by
      # default (no value passed to the changeset), so this user contributes
      # to the row count without contributing a "was non-nil" fact.
      _already_nil_user = insert_user!(seeded_schema)

      %{tenant_id: unchanged_tenant_id, schema_name: unchanged_schema} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0910-count-unchanged",
          display_name: "ISS-0910 AC4 unchanged fixture"
        )

      assert {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: unchanged_schema)
      unchanged_user = insert_user!(unchanged_schema)
      unchanged_original_marker = @a_past_timestamp
      stamp_role_claims_synced_at!(unchanged_user, unchanged_schema, unchanged_original_marker)

      assert {:ok,
              %{
                seeded: seeded,
                unchanged: unchanged,
                role_claims_markers_reset: role_claims_markers_reset
              }} = RoleBackfill.run()

      assert seeded_tenant_id in seeded
      assert unchanged_tenant_id in unchanged

      # Exactly the 4 users on the seeded tenant (3 stamped + 1 already-nil) --
      # NOT the unchanged tenant's 1 user, which must never be touched.
      assert role_claims_markers_reset == 4

      for u <- seeded_users do
        assert %User{role_claims_synced_at: nil} = reload_user!(u, seeded_schema)
      end

      # The unchanged tenant's user keeps its marker -- confirms the count
      # above is not an approximation that happens to add up by coincidence.
      assert %User{role_claims_synced_at: ^unchanged_original_marker} =
               reload_user!(unchanged_user, unchanged_schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-447 PR 1 (design 3.9): the backfill is seven-role aware
  # ---------------------------------------------------------------------------------

  describe "REQ-447: run/0 classifies by seedable_role_names/1, not a hard-coded six" do
    defp seed_pre_req447_six_roles!(schema_name) do
      # The six roles a deployment held BEFORE REQ-447: the five old operational roles and
      # CANDIDATE, plus PLATFORM_ADMIN, i.e. every role except TENANT_ADMIN.
      for name <-
            ~w(PLATFORM_ADMIN PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER AGENT_RUNNER CANDIDATE) do
        {:ok, %Group{id: group_id}} =
          RoleRegistry.get_or_create_group_by_name(name, prefix: schema_name)

        if name == "PLATFORM_ADMIN" do
          insert_legacy_platform_admin_role!(group_id, schema_name)
        else
          {:ok, _} =
            RoleRegistry.upsert_role(name, :platform_role, group_id, prefix: schema_name)
        end
      end
    end

    test "an ordinary tenant holding the six pre-REQ-447 roles is :seeded (it lacks TENANT_ADMIN); the legacy PLATFORM_ADMIN binding is NOT deleted" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req447-bf-legacy")

      seed_pre_req447_six_roles!(schema_name)
      refute "TENANT_ADMIN" in platform_role_names(schema_name)

      assert {:ok, %{seeded: seeded}} = RoleBackfill.run()
      assert tenant_id in seeded

      names = platform_role_names(schema_name)
      assert "TENANT_ADMIN" in names
      # Not deleting the legacy binding is the migration's job (design 3.9 / 3.8 step 4).
      assert "PLATFORM_ADMIN" in names
      assert length(names) == 1 + length(RoleRegistry.seedable_role_names(schema_name))
    end

    test "an ordinary tenant with nothing seeded gets the seedable roles (REQ-448: seven) including TENANT_ADMIN and NO PLATFORM_ADMIN" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req447-bf-empty")

      assert {:ok, %{seeded: seeded}} = RoleBackfill.run()
      assert tenant_id in seeded

      names = platform_role_names(schema_name)
      assert "TENANT_ADMIN" in names
      refute "PLATFORM_ADMIN" in names
      assert length(names) == length(RoleRegistry.seedable_role_names(schema_name))
    end

    test "the pinned platform tenant is seeded every role of roles/0, so an existing platform tenant obtains its TENANT_ADMIN binding" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req447-bf-platform")

      Letflow.Support.PlatformTenantFixture.pin!(tenant_id)
      seed_pre_req447_six_roles!(schema_name)

      assert {:ok, %{seeded: seeded}} = RoleBackfill.run()
      assert tenant_id in seeded

      names = platform_role_names(schema_name)

      assert Enum.sort(names) ==
               Enum.sort(Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1))
    end

    test "a tenant that already holds exactly its seedable set is :unchanged on a second run (ordinary: roles/0 minus PLATFORM_ADMIN, platform: all of roles/0)" do
      %{tenant_id: ordinary_id, schema_name: ordinary_schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req447-bf-idem-o")

      %{tenant_id: platform_id, schema_name: platform_schema} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req447-bf-idem-p")

      Letflow.Support.PlatformTenantFixture.pin!(platform_id)

      assert {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: ordinary_schema)
      assert {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: platform_schema)

      assert {:ok, %{seeded: seeded, unchanged: unchanged}} = RoleBackfill.run()
      refute ordinary_id in seeded
      refute platform_id in seeded
      assert ordinary_id in unchanged
      assert platform_id in unchanged
    end
  end
end
