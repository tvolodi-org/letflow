defmodule Letflow.TenantProvisioningTest do
  @moduledoc """
  Tests for `Letflow.TenantProvisioning` (REQ-022): `schema_name_for_tenant/1`,
  `provision_tenant_schema/1`, `replay_migrations/2`, and
  `Letflow.TenantProvisioning.Registration.changeset/2`. See `test/specs/REQ-022.md`
  for the full test-case rationale, including why acceptance criterion 4 (moduledoc
  content) is verified by direct inspection rather than a runtime assertion (matching
  `test/specs/REQ-020.md`'s AC5 precedent), and the full Sandbox-incompatibility
  investigation behind this file's `async: false` + `Sandbox.mode(..., :auto)` pattern.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. Unlike most test files in
  this project, the `replay_migrations/2` and migration-guard-pattern describe blocks
  do NOT run inside DataCase's normal rolled-back sandbox transaction -- `Ecto.Migrator`
  genuinely cannot run under a single sandboxed connection (empirically confirmed while
  drafting this file, see test/specs/REQ-022.md), so those blocks switch
  `Letflow.Repo` to Sandbox `:auto` mode and clean up the real schema/rows they create
  in `on_exit/1` instead of relying on transaction rollback.

  `async: false` for the whole module (not just the Migrator-touching describe blocks
  -- ExUnit's `async` setting is module-wide, not per-test) -- see test/specs/REQ-022.md
  for why this makes the `:auto`-mode switch safe against other concurrently running
  test files.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.MigrationFixture
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  # oidc_mode: :disabled avoids Tenant.create_changeset/3's idp_realm_id requirement --
  # irrelevant to anything this file tests, matching identity_test.exs's own use of
  # :disabled wherever the OIDC realm-binding fields don't matter to the test at hand.
  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req022"),
        display_name: "REQ-022 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  # Must match Registration.changeset/2's @schema_name_format (ISS-0027/GH#85) --
  # "tenant_" <> 32 lowercase hex chars, the same shape schema_name_for_tenant/1
  # produces -- since these tests build changesets directly rather than going
  # through schema_name_for_tenant/1.
  defp unique_schema_name do
    "tenant_" <> (Ecto.UUID.generate() |> String.replace("-", ""))
  end

  defp schema_exists?(schema_name) do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM information_schema.schemata WHERE schema_name = $1", [
        schema_name
      ])

    rows != []
  end

  defp table_exists_in_schema?(schema_name, table_name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)",
        [schema_name, table_name]
      )

    exists?
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # --- ISS-0771 helpers (replay_all_pending/0 describe block) ---------------------

  defp tenant_table_count(schema_name) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = $1",
        [schema_name]
      )

    count
  end

  defp registration_row_count(tenant_id) do
    Registration |> where([r], r.tenant_id == ^tenant_id) |> Repo.aggregate(:count)
  end

  defp users_role_claims_synced_at_column_exists?(schema_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'users' AND column_name = 'role_claims_synced_at'",
        [schema_name]
      )

    rows != []
  end

  # REQ-378's own migration (ISS-0771's incident hinged on exactly this one) --
  # reused here deliberately, since it is the real-world case this issue exists to
  # close, not an arbitrary stand-in.
  @pending_migration_version 20_260_921_000_001

  defp mark_migration_pending!(schema_name) do
    Repo.query!(~s(ALTER TABLE "#{schema_name}".users DROP COLUMN role_claims_synced_at))

    Repo.query!(
      ~s(DELETE FROM "#{schema_name}".schema_migrations WHERE version = $1),
      [@pending_migration_version]
    )
  end

  defp migration_recorded?(schema_name) do
    %{rows: rows} =
      Repo.query!(
        ~s(SELECT 1 FROM "#{schema_name}".schema_migrations WHERE version = $1),
        [@pending_migration_version]
      )

    rows != []
  end

  # Minimal local helper mirroring Ecto's own test-helper convention (identical to the
  # one in identity_test.exs) -- avoids pulling in a full Phoenix-style ConnCase just
  # for this one assertion.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ---------------------------------------------------------------------------------
  # schema_name_for_tenant/1 -- pure function, no I/O (test_developer_guide.md's
  # "pure functions first" principle). Not itself one of REQ-022's 4 numbered
  # acceptance criteria, but the derivation both AC2 and AC3's tests below depend on,
  # and it is cheap to pin directly.
  # ---------------------------------------------------------------------------------

  describe "schema_name_for_tenant/1 (supports acceptance criteria 2 and 3)" do
    test "derives tenant_<32 lowercase hex chars, no hyphens> from a valid UUID" do
      tenant_id = Ecto.UUID.generate()

      assert {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)
      assert schema_name == "tenant_" <> String.replace(tenant_id, "-", "")
      assert String.match?(schema_name, ~r/^tenant_[0-9a-f]{32}$/)
    end

    test "returns {:error, :invalid_tenant_id} for a syntactically invalid UUID" do
      assert {:error, :invalid_tenant_id} =
               TenantProvisioning.schema_name_for_tenant("not-a-uuid")
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-064 rework (test-design-gate iteration 1): tenant_id_for_schema_name/1 is the
  # reverse of schema_name_for_tenant/1 above -- REQ-064 removed its CALL SITES (the
  # tenant_id-stamping done at write time in EventStore/Definitions/Identity context
  # modules) but not the function itself, and REQ-064's own acceptance criteria
  # require it "still exists and is still tested". Pure/total (is_binary/1 guard,
  # with/else chain, no I/O per its own moduledoc/@spec at
  # lib/letflow/tenant_provisioning.ex:100-115) -- a plain unit test, no DataCase
  # database interaction needed for either case below.
  # ---------------------------------------------------------------------------------

  describe "tenant_id_for_schema_name/1 (REQ-064: reverse of schema_name_for_tenant/1, still tested after call-site removal)" do
    test "round-trips a schema_name_for_tenant/1 output back to the same tenant_id" do
      tenant_id = Ecto.UUID.generate()

      assert {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)
      assert {:ok, ^tenant_id} = TenantProvisioning.tenant_id_for_schema_name(schema_name)
    end

    test "returns {:error, :invalid_schema_name} for a malformed schema_name" do
      assert {:error, :invalid_schema_name} =
               TenantProvisioning.tenant_id_for_schema_name("not_a_valid_schema_name")
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "priv/repo/migrations gains a tenant_schemas migration
  # (public/default schema) that applies cleanly via mix ecto.migrate, with columns
  # for at minimum tenant_id and schema_name"
  # ---------------------------------------------------------------------------------

  describe "tenant_schemas migration + Registration changeset (acceptance criterion 1)" do
    test "the migration applied cleanly: tenant_schemas exists in public with at least tenant_id and schema_name columns" do
      # Every test in this file (and every other DataCase-based test in this project)
      # already implicitly proves the migration applies cleanly -- DataCase's checkout
      # would fail outright against a database whose migrations hadn't run. This test
      # goes further and checks the specific column set directly, per this file's task
      # instruction to verify column presence via a direct query, not just trust that
      # setup succeeded.
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'tenant_schemas'",
          []
        )

      columns = List.flatten(rows)
      assert "tenant_id" in columns
      assert "schema_name" in columns
      assert "migrations_applied_at" in columns
      assert "provisioned_at" in columns
    end

    test "changeset/2 requires both tenant_id and schema_name" do
      changeset = Registration.changeset(%Registration{}, %{})

      refute changeset.valid?
      assert %{tenant_id: [_ | _], schema_name: [_ | _]} = errors_on(changeset)
    end

    # ISS-0027 (GH#85): the DDL-identifier safety argument for
    # `CREATE SCHEMA IF NOT EXISTS "#{schema_name}"` previously lived only in the
    # call graph (the only writer is schema_name_for_tenant/1's own derivation) --
    # these pin that the changeset itself now rejects anything that derivation
    # could never produce, so the guarantee holds even if a future second writer
    # bypasses schema_name_for_tenant/1.
    test "changeset/2 rejects a schema_name that doesn't match tenant_<32 lowercase hex>, even with a well-formed tenant_id" do
      tenant_id = Ecto.UUID.generate()

      for bad_name <- [
            "tenant_not-hex-at-all",
            "tenant_" <> String.duplicate("a", 31),
            "tenant_" <> String.duplicate("A", 32),
            "public",
            "tenant_" <> String.duplicate("a", 32) <> "; DROP SCHEMA public CASCADE;",
            "tenant_" <> String.duplicate("a", 32) <> " "
          ] do
        changeset =
          Registration.changeset(%Registration{}, %{tenant_id: tenant_id, schema_name: bad_name})

        refute changeset.valid?, "expected #{inspect(bad_name)} to be rejected"
        assert %{schema_name: [_ | _]} = errors_on(changeset)
      end
    end

    test "changeset/2 accepts a schema_name in exactly the shape schema_name_for_tenant/1 produces" do
      tenant_id = Ecto.UUID.generate()
      {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)

      changeset =
        Registration.changeset(%Registration{}, %{tenant_id: tenant_id, schema_name: schema_name})

      assert changeset.valid?
    end

    test "a second row for the same tenant_id violates the unique_constraint on tenant_id" do
      tenant = insert_tenant!()

      assert {:ok, _} =
               %Registration{}
               |> Registration.changeset(%{
                 tenant_id: tenant.id,
                 schema_name: unique_schema_name()
               })
               |> Repo.insert()

      assert {:error, changeset} =
               %Registration{}
               |> Registration.changeset(%{
                 tenant_id: tenant.id,
                 schema_name: unique_schema_name()
               })
               |> Repo.insert()

      assert %{tenant_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "a schema_name already used by a different tenant violates the unique_constraint on schema_name" do
      tenant_a = insert_tenant!()
      tenant_b = insert_tenant!()
      shared_schema_name = unique_schema_name()

      assert {:ok, _} =
               %Registration{}
               |> Registration.changeset(%{
                 tenant_id: tenant_a.id,
                 schema_name: shared_schema_name
               })
               |> Repo.insert()

      assert {:error, changeset} =
               %Registration{}
               |> Registration.changeset(%{
                 tenant_id: tenant_b.id,
                 schema_name: shared_schema_name
               })
               |> Repo.insert()

      assert %{schema_name: ["has already been taken"]} = errors_on(changeset)
    end

    test "a tenant_id with no matching tenants row violates the foreign_key_constraint, no row inserted" do
      orphan_tenant_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               %Registration{}
               |> Registration.changeset(%{
                 tenant_id: orphan_tenant_id,
                 schema_name: unique_schema_name()
               })
               |> Repo.insert()

      assert %{tenant_id: [_ | _]} = errors_on(changeset)
      assert Repo.get_by(Registration, tenant_id: orphan_tenant_id) == nil
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2: "a provision_tenant_schema/1-equivalent function exists
  # that issues a real CREATE SCHEMA and records the mapping in tenant_schemas,
  # demonstrated against at least one non-default tenant schema name"
  #
  # These run under DataCase's normal sandboxed (rolled-back) transaction --
  # provision_tenant_schema/1 only ever uses ONE connection (confirmed empirically,
  # see test/specs/REQ-022.md), unlike replay_migrations/2 below, so no :auto-mode
  # dance is needed here and every schema/row this describe block creates is rolled
  # back automatically at the end of each test.
  # ---------------------------------------------------------------------------------

  describe "provision_tenant_schema/1 (acceptance criterion 2)" do
    test "issues a real CREATE SCHEMA (confirmed via information_schema.schemata, not just the return value) and records the tenant_schemas row" do
      tenant = insert_tenant!()

      assert {:ok, %Registration{schema_name: schema_name, tenant_id: tenant_id}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      assert tenant_id == tenant.id
      assert schema_name == "tenant_" <> String.replace(tenant.id, "-", "")

      # Query pg_catalog/information_schema directly -- proves the physical Postgres
      # schema genuinely exists, not just that the function returned :ok.
      assert schema_exists?(schema_name)

      assert %Registration{schema_name: ^schema_name} =
               Repo.get_by(Registration, tenant_id: tenant.id)
    end

    test "calling it twice for the same tenant is idempotent: identical Registration row, schema still created only once" do
      tenant = insert_tenant!()

      assert {:ok, %Registration{id: id1, schema_name: schema_name}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      assert {:ok, %Registration{id: id2, schema_name: ^schema_name}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      assert id1 == id2
      assert schema_exists?(schema_name)

      row_count =
        Registration |> where([r], r.tenant_id == ^tenant.id) |> Repo.aggregate(:count)

      assert row_count == 1
    end

    test "a syntactically valid but unknown tenant_id returns {:error, :tenant_not_found} and leaves no orphan schema or row behind" do
      unknown_tenant_id = Ecto.UUID.generate()
      {:ok, would_be_schema_name} = TenantProvisioning.schema_name_for_tenant(unknown_tenant_id)

      # Sanity check this schema genuinely does not exist yet, so the assertion below
      # is actually exercising "rolled back", not "never existed in the first place".
      refute schema_exists?(would_be_schema_name)

      assert {:error, :tenant_not_found} =
               TenantProvisioning.provision_tenant_schema(unknown_tenant_id)

      # The atomicity invariant this test exists to prove: a tenant_not_found failure
      # rolls back the CREATE SCHEMA DDL together with the failed insert -- no orphan
      # physical schema survives a failed provisioning attempt. This is exactly the
      # property ELIXIR-DEV's own Step 2a handoff demonstrated manually once (via a
      # throwaway scratch script against a real dev DB, then deleted); a manual
      # one-time demo does not guarantee this holds on every future change, which is
      # why this needs to be an automated, always-run test.
      refute schema_exists?(would_be_schema_name)
      assert Repo.get_by(Registration, tenant_id: unknown_tenant_id) == nil
    end

    test "a syntactically invalid tenant_id returns {:error, :invalid_tenant_id} without touching the database" do
      assert {:error, :invalid_tenant_id} =
               TenantProvisioning.provision_tenant_schema("not-a-uuid")
    end
  end

  # ---------------------------------------------------------------------------------
  # replay_migrations/2, "tenant not provisioned" branch: this returns before ever
  # calling Ecto.Migrator (see tenant_provisioning.ex:161-163's `Repo.get_by ... nil ->`
  # short-circuit), so -- unlike the two describe blocks below -- it needs no :auto-mode
  # treatment and runs under DataCase's normal sandboxed transaction.
  # ---------------------------------------------------------------------------------

  describe "replay_migrations/2 -- unprovisioned tenant (part of acceptance criterion 3)" do
    test "returns {:error, :tenant_not_provisioned} for a tenant_id with no Registration row, never invoking Ecto.Migrator" do
      never_provisioned_tenant_id = Ecto.UUID.generate()

      assert {:error, :tenant_not_provisioned} =
               TenantProvisioning.replay_migrations(never_provisioned_tenant_id, [
                 {1, MigrationFixture}
               ])
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "a migration-replay function exists that re-applies
  # priv/repo/migrations/ against a specific tenant schema via Ecto's prefix: option,
  # demonstrated by confirming at least one table exists under the provisioned
  # schema's own information_schema, not just under public"
  #
  # See this file's moduledoc + test/specs/REQ-022.md for why this describe block
  # switches Letflow.Repo to Sandbox :auto mode and cleans up manually in on_exit/1
  # instead of relying on the normal DataCase rollback.
  # ---------------------------------------------------------------------------------

  describe "replay_migrations/2 -- successful replay (acceptance criterion 3)" do
    setup do
      # Ecto.Migrator.run/4 needs a second, genuinely independent database connection
      # beyond whatever this process already has checked out (confirmed directly from
      # deps/ecto_sql/lib/ecto/migrator.ex's own moduledoc, cited by the design doc's
      # SS0/SS6 "Testing environment caveat", and empirically reproduced while drafting
      # this file: calling replay_migrations/2 from inside DataCase's normal sandboxed
      # checkout raises `DBConnection.ConnectionError` -- "could not checkout the
      # connection... connection not available", reason: :queue_timeout -- because the
      # sandboxed pool only ever hands this process its single owned connection, and
      # Migrator's schema_migrations table-lock step genuinely needs a second one.
      #
      # Fix: switch to Sandbox :auto mode for this describe block only. Per
      # Ecto.Adapters.SQL.Sandbox.mode/2's own moduledoc, this checks in this test's
      # already-checked-out sandboxed connection and makes every subsequent Repo call
      # use a real, ad hoc, committing connection instead -- these specific tests are
      # NOT rolled back automatically, unlike every other test in this file. Real
      # Postgres state (a real CREATE SCHEMA, real rows) is genuinely created and must
      # be dropped explicitly, done below.
      #
      # Why this doesn't corrupt any OTHER concurrently running test's sandboxed
      # connection (the exact risk that same moduledoc warns "all existing connections
      # are checked in" could cause): confirmed directly from ExUnit's own installed
      # source (ex_unit/lib/ex_unit/runner.ex's async_loop/4) that ExUnit fully drains
      # and waits for every async: true module to finish before starting any
      # async: false (sync) module, and runs sync modules strictly one at a time, never
      # concurrently with each other or with async ones. This file is `async: false`
      # for the whole module (ExUnit's async setting is module-wide, not per-test) for
      # exactly this reason -- there is no other test's connection to disturb at the
      # moment this setup runs.
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      tenant = insert_tenant!()

      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      on_exit(fn ->
        drop_schema!(schema_name)
        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
      end)

      %{tenant: tenant, schema_name: schema_name}
    end

    test "replays test/support/req022_migration_fixture.ex into the tenant's own schema, confirmed via that schema's own information_schema, and NOT under public",
         %{tenant: tenant, schema_name: schema_name} do
      assert {:ok, [1]} = TenantProvisioning.replay_migrations(tenant.id, [{1, MigrationFixture}])

      # The core AC3 assertion: the table exists under the tenant's own schema...
      assert table_exists_in_schema?(schema_name, "req022_demo_marker")
      # ...and does NOT exist under public -- positively proves the table landed under
      # the tenant's schema because of :prefix, not because of some accidental default.
      refute table_exists_in_schema?("public", "req022_demo_marker")

      assert %Registration{migrations_applied_at: %NaiveDateTime{}} =
               Repo.get_by(Registration, tenant_id: tenant.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # Beyond REQ-022's bare 4 acceptance criteria: REVIEWER's Step 2d non-blocking note
  # (handoffs/WF02-REQ022-20260816/step-02d-reviewer.json) flagged that the guard
  # pattern every tenant-scoped migration must follow (no-op when Ecto.Migration.
  # prefix() is nil) is enforced only by design-doc/comment discipline, "not by any
  # compile-time or test-time check", and suggested "a lightweight guard test... e.g.
  # asserting each listed migration module no-ops under a nil prefix". This is not
  # itself one of REQ-022's 4 acceptance criteria (the task that dispatched this file
  # says so explicitly), but it fits naturally here since this describe block already
  # needs the same :auto-mode infrastructure as the block above, so it's added as a
  # genuine regression test rather than left purely convention-enforced.
  # ---------------------------------------------------------------------------------

  # NOTE(ISS-0030): describe/test names below are deliberately short -- ExUnit computes
  # a combined "test " <> describe <> " " <> test_name atom whose length the BEAM caps
  # at 255 chars (SystemLimitError), and the original long-sentence names totalled 292.
  # Nothing here is lost: the "(beyond REQ-022's bare acceptance criteria, REVIEWER
  # Step 2d non-blocking note)" context is already stated in the comment block just
  # above, and the "test/support/req022_migration_fixture.ex" fixture path is documented
  # in test/specs/REQ-022.md and via the MigrationFixture alias used in the test body.
  describe "tenant-scoped migration guard pattern -- nil prefix is a real no-op" do
    # A deliberately implausible version number -- avoids any chance of colliding with
    # a real timestamp-based priv/repo/migrations/ version already recorded in the
    # real public.schema_migrations table.
    @guard_probe_version 999_999_999

    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      on_exit(fn ->
        Repo.query!(~s(DELETE FROM "schema_migrations" WHERE version = $1), [
          @guard_probe_version
        ])

        # Defensive cleanup only -- a correctly-guarded migration never creates this
        # table under public in the first place (that's exactly what this test
        # proves), so this is a no-op in the passing case.
        Repo.query!(~s(DROP TABLE IF EXISTS "req022_demo_marker"))
      end)

      :ok
    end

    test "running with no :prefix option (plain mix ecto.migrate-style run) leaves public untouched" do
      # Ecto.Migrator.run/4 returns a bare [integer] list on success (not an
      # {:ok, _} tuple) -- confirmed directly from deps/ecto_sql/lib/ecto/migrator.ex's
      # own @spec, same fact the design doc's SS3.2 cites as the reason
      # replay_migrations/2 itself wraps this call to produce this project's
      # {:ok, _} | {:error, _} convention. Calling Ecto.Migrator.run/4 directly here
      # (not through replay_migrations/2) is deliberate -- this test needs to pass NO
      # :prefix option at all, which replay_migrations/2 never does.
      assert [@guard_probe_version] =
               Ecto.Migrator.run(
                 Letflow.Repo,
                 [{@guard_probe_version, MigrationFixture}],
                 :up,
                 all: true,
                 log: false
               )

      refute table_exists_in_schema?("public", "req022_demo_marker")
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0771: Letflow.TenantProvisioning.replay_all_pending/0, the boot-time-hook
  # orchestration function -- see test/specs/ISS-0771.md and
  # lib/letflow/design/iss0771-tenant-migration-replay-on-deploy.md for the full
  # rationale. Because this is a brand-new function (not a change to existing
  # behavior), the WF-03 fail-then-pass rule is satisfied only via mutation testing,
  # recorded in this run's TEST-DESIGNER handoff -- not restated here.
  #
  # Uses Letflow.TenantFixture.provisioned_tenant!/1 (test/support/tenant_fixture.ex)
  # for every provisioned tenant below -- the established fixture for this codebase,
  # not new provisioning machinery. It flips Letflow.Repo to Sandbox :auto mode itself
  # and registers its own on_exit/1 teardown (drops the schema, deletes the
  # Registration and Tenant rows), matching this file's own async: false,
  # non-transactional pattern for the two describe blocks above.
  # ---------------------------------------------------------------------------------

  describe "replay_all_pending/0 (ISS-0771)" do
    test "calling it twice against a fully migrated tenant is a safe no-op both times" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0771-idempotent")

      # Settle first -- provisioned_tenant!/1 already yields a fully migrated schema
      # (its own assert_schema_complete!/2 already checked this), but calling once
      # more up front makes the "both subsequent calls are identical" comparison below
      # exercise the true steady state rather than depend on that assumption.
      settle = TenantProvisioning.replay_all_pending()
      assert tenant_id in settle.ok
      refute Enum.any?(settle.error, fn {id, _reason} -> id == tenant_id end)

      table_count_before = tenant_table_count(schema_name)

      first = TenantProvisioning.replay_all_pending()
      second = TenantProvisioning.replay_all_pending()

      assert tenant_id in first.ok
      assert tenant_id in second.ok
      refute Enum.any?(first.error, fn {id, _reason} -> id == tenant_id end)
      refute Enum.any?(second.error, fn {id, _reason} -> id == tenant_id end)

      # No duplicate DDL: the schema's own table count is unchanged across both calls.
      assert tenant_table_count(schema_name) == table_count_before

      # No duplicate rows: still exactly one Registration row for this tenant.
      assert registration_row_count(tenant_id) == 1
    end

    test "one tenant's broken schema does not abort replay for a healthy sibling tenant" do
      healthy = TenantFixture.provisioned_tenant!(slug_prefix: "iss0771-healthy")
      broken = TenantFixture.provisioned_tenant!(slug_prefix: "iss0771-broken")

      # Simulates the design doc's own "corrupt/unreachable schema" example -- the
      # Registration row still points at a schema_name that no longer physically
      # exists, so Ecto.Migrator.run/4's prefix-scoped work has nothing to run
      # against and raises.
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{broken.schema_name}" CASCADE))

      result = TenantProvisioning.replay_all_pending()
      broken_tenant_id = broken.tenant_id

      assert healthy.tenant_id in result.ok

      assert {^broken_tenant_id, reason} =
               Enum.find(result.error, fn {id, _reason} -> id == broken_tenant_id end)

      assert match?({:migration_failed, _exception}, reason)
    end

    test "actually applies a migration that is pending against an already-provisioned tenant" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0771-pending")

      assert users_role_claims_synced_at_column_exists?(schema_name)
      assert migration_recorded?(schema_name)

      mark_migration_pending!(schema_name)

      refute users_role_claims_synced_at_column_exists?(schema_name)
      refute migration_recorded?(schema_name)

      result = TenantProvisioning.replay_all_pending()

      assert tenant_id in result.ok
      refute Enum.any?(result.error, fn {id, _reason} -> id == tenant_id end)

      assert users_role_claims_synced_at_column_exists?(schema_name)
      assert migration_recorded?(schema_name)
    end

    test "GH #2727: the stored reason code is a fixed string, never the exception text" do
      broken = TenantFixture.provisioned_tenant!(slug_prefix: "gh2727-code")
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{broken.schema_name}" CASCADE))

      TenantProvisioning.replay_all_pending()

      registration = Repo.get_by!(Registration, tenant_id: broken.tenant_id)
      assert registration.migration_replay_failure_code == "migration_failed"
      assert %NaiveDateTime{} = registration.migration_replay_failed_at

      assert [%{reason_code: "migration_failed", tenant_id: tenant_id}] =
               Enum.filter(
                 TenantProvisioning.list_replay_failures(),
                 &(&1.tenant_id == broken.tenant_id)
               )

      assert tenant_id == broken.tenant_id
    end
  end
end
