defmodule Letflow.TenantSchemaReaperTest do
  @moduledoc """
  Regression test for ISS-0064 ("orphaned `tenant_schemas` rows from the
  direct-provisioning + on_exit-only test pattern (no reaper)"). See
  `test/specs/ISS-0064.md` for the full test-case rationale and the fail-then-pass
  proof required by WF-03 Step 4.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. Exercises
  `Letflow.TenantSchemaReaper.sweep_orphans/2` directly against real, hand-inserted
  `tenant_schemas`/`tenants` rows and a real Postgres schema created via
  `CREATE SCHEMA`, mirroring `test/letflow/tenant_provisioning_test.exs`'s own
  `async: false` + `Sandbox.mode(Letflow.Repo, :auto)` + manual `on_exit/1` pattern --
  the module under test itself switches `Letflow.Repo` to `:auto` mode internally
  (`sweep_orphans/2`'s own first step, per the design doc §3.2 step 1), so this file's
  fixtures must commit for real (not inside a rolled-back sandbox transaction) for the
  sweep to be able to see them at all.

  `async: false` for the whole module -- ExUnit's `async` setting is module-wide, and
  this file, like `tenant_provisioning_test.exs`/`identity_migration_test.exs`, forces
  `Letflow.Repo` into `:auto` mode for real-commit work.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantSchemaReaper
  alias Letflow.Test.FakeInvocationConnection

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  # oidc_mode: :disabled avoids Tenant.create_changeset/3's idp_realm_id requirement --
  # irrelevant to anything this file tests, matching tenant_provisioning_test.exs's
  # own use of :disabled wherever the OIDC realm-binding fields don't matter.
  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("iss064"),
        display_name: "ISS-0064 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  # Matches Letflow.TenantProvisioning.schema_name_for_tenant/1's own derivation
  # ("tenant_" <> 32 lowercase hex chars) -- the same format
  # Letflow.TenantSchemaReaper's @schema_name_format validates against.
  defp valid_schema_name do
    "tenant_" <> (Ecto.UUID.generate() |> String.replace("-", ""))
  end

  defp schema_exists?(schema_name) do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM information_schema.schemata WHERE schema_name = $1", [
        schema_name
      ])

    rows != []
  end

  defp tenant_schemas_row_exists?(id) do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM tenant_schemas WHERE id = $1", [Ecto.UUID.dump!(id)])

    rows != []
  end

  defp tenants_row_exists?(id) do
    %{rows: rows} = Repo.query!("SELECT 1 FROM tenants WHERE id = $1", [Ecto.UUID.dump!(id)])
    rows != []
  end

  # Inserts a real tenant_schemas row directly via SQL (bypassing
  # Registration.create_changeset/2, exactly like ISSUE-FIXER's diagnosis names as
  # this issue's own leak-producing pattern -- "a raw Repo.insert into
  # tenant_schemas") with an explicit provisioned_at, so age-threshold behavior can
  # be controlled precisely instead of depending on wall-clock timing between insert
  # and assertion. Returns the row's id (already an Ecto.UUID binary, matching what
  # sweep_orphans/2's own bulk SELECT returns for the `id`/`tenant_id` columns).
  defp insert_tenant_schemas_row!(tenant_id, schema_name, provisioned_at) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO tenant_schemas (id, tenant_id, schema_name, provisioned_at) " <>
          "VALUES (gen_random_uuid(), $1, $2, $3) RETURNING id",
        [Ecto.UUID.dump!(tenant_id), schema_name, provisioned_at]
      )

    Ecto.UUID.cast!(id)
  end

  # Real (non-sandboxed) schema, matching what Letflow.TenantProvisioning.
  # provision_tenant_schema/1 creates in production -- sweep_orphans/2 must be able
  # to DROP a genuine Postgres schema, not just delete rows.
  defp create_schema!(schema_name) do
    Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{schema_name}"))
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp naive_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------------
  # Criterion 1 -- an old, well-formed orphaned row is reclaimed: schema dropped,
  # tenant_schemas row deleted, tenants row deleted.
  # ---------------------------------------------------------------------------------

  describe "sweep_orphans/2 reclaims an old, well-formed orphaned row" do
    test "drops the real schema and deletes both rows" do
      tenant = insert_tenant!()
      schema_name = valid_schema_name()
      create_schema!(schema_name)

      old_provisioned_at =
        naive_now() |> NaiveDateTime.add(-10_000, :second)

      row_id = insert_tenant_schemas_row!(tenant.id, schema_name, old_provisioned_at)

      on_exit(fn ->
        # Best-effort cleanup in case an assertion fails before the sweep runs --
        # mirrors the "swallow-its-own-failure" idiom this project already uses for
        # real-commit test cleanup (tenant_provisioning_test.exs's drop_schema!/1).
        drop_schema!(schema_name)
      end)

      assert schema_exists?(schema_name)
      assert tenant_schemas_row_exists?(row_id)
      assert tenants_row_exists?(tenant.id)

      # min_age_seconds: 1 -- comfortably below the 10_000s age above, and avoids an
      # artificial sleep (the design doc's own rationale for exposing this as a
      # parameter, §3.1).
      assert {:ok, %{reclaimed: reclaimed, skipped_invalid_format: skipped}} =
               TenantSchemaReaper.sweep_orphans(Repo, 1)

      # sweep_orphans/2 restores Letflow.Repo to Sandbox :manual mode in its own
      # `after` clause (design doc §3.2 step 4/§4 INV-R-6) -- switch back to :auto
      # so this test's own remaining assertions can keep issuing real queries.
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert reclaimed >= 1
      assert is_integer(skipped) and skipped >= 0

      refute schema_exists?(schema_name)
      refute tenant_schemas_row_exists?(row_id)
      refute tenants_row_exists?(tenant.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # Criterion 2 -- age-threshold guard (design doc §2.3/§4 INV-R-5): a row younger
  # than min_age_seconds is left untouched, proving the concurrent-invocation race
  # mitigation actually works.
  # ---------------------------------------------------------------------------------

  describe "sweep_orphans/2 age-threshold guard" do
    test "does not touch a row younger than min_age_seconds" do
      tenant = insert_tenant!()
      schema_name = valid_schema_name()
      create_schema!(schema_name)

      # Provisioned "now" -- well within any min_age_seconds worth testing.
      recent_provisioned_at = naive_now()

      row_id = insert_tenant_schemas_row!(tenant.id, schema_name, recent_provisioned_at)

      on_exit(fn ->
        drop_schema!(schema_name)
        Repo.query!("DELETE FROM tenant_schemas WHERE id = $1", [Ecto.UUID.dump!(row_id)])
        Repo.query!("DELETE FROM tenants WHERE id = $1", [Ecto.UUID.dump!(tenant.id)])
      end)

      # min_age_seconds: 300 (the design's own default) -- a row provisioned moments
      # ago is nowhere near old enough to qualify.
      assert {:ok, %{reclaimed: _reclaimed, skipped_invalid_format: _skipped}} =
               TenantSchemaReaper.sweep_orphans(Repo, 300)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      # The row and its schema must survive untouched -- this is the concurrent-
      # invocation safety mitigation (design doc §2.3/§4 INV-R-5): a row this recent
      # might belong to a still-in-progress test in this or another concurrently
      # running mix test invocation, so the sweep must fail closed and leave it alone.
      assert schema_exists?(schema_name)
      assert tenant_schemas_row_exists?(row_id)
      assert tenants_row_exists?(tenant.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # Criterion 3 -- regex-validation guard (design doc §3.2 step 3a / §4 INV-R-1): an
  # old row with a malformed schema_name is skipped, not dropped, and does not crash
  # the sweep.
  # ---------------------------------------------------------------------------------

  describe "sweep_orphans/2 schema_name format guard" do
    test "skips an old row with a malformed schema_name instead of attempting a drop" do
      tenant = insert_tenant!()
      # Deliberately does NOT match ^tenant_[0-9a-f]{32}$ -- e.g. wrong prefix and a
      # SQL-metacharacter-laden suffix. No real schema is created for this row: if
      # sweep_orphans/2 ever tried to interpolate this value into a DROP SCHEMA
      # statement, that would be exactly the SQL-injection-shaped hazard the design's
      # INV-R-1 exists to prevent, so this test also does not give it a schema to
      # legitimately drop. Suffixed with a fresh UUID (not a fixed literal) so re-runs
      # never collide against `tenant_schemas_schema_name_index`'s unique constraint,
      # including a re-run after a prior failed/interrupted run of this same test left
      # its own row behind.
      malformed_schema_name =
        "not_a_valid_schema_name; DROP TABLE tenants;--" <> Ecto.UUID.generate()

      old_provisioned_at = naive_now() |> NaiveDateTime.add(-10_000, :second)

      row_id =
        insert_tenant_schemas_row!(tenant.id, malformed_schema_name, old_provisioned_at)

      on_exit(fn ->
        Repo.query!("DELETE FROM tenant_schemas WHERE id = $1", [Ecto.UUID.dump!(row_id)])
        Repo.query!("DELETE FROM tenants WHERE id = $1", [Ecto.UUID.dump!(tenant.id)])
      end)

      assert {:ok, %{reclaimed: _reclaimed, skipped_invalid_format: skipped}} =
               TenantSchemaReaper.sweep_orphans(Repo, 1)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      # Not asserting `reclaimed == 0` here: sweep_orphans/2 sweeps the whole
      # tenant_schemas table, not just this test's own row, so an unrelated
      # well-formed orphan left over from a different test/run could also be
      # reclaimed in the same call without that being a failure of THIS guard. What
      # this test cares about -- and asserts below -- is that THIS row, specifically,
      # was skipped rather than dropped.
      assert skipped >= 1

      # Row is left alone (skip, not delete) -- the design's fail-closed contract for
      # a malformed schema_name.
      assert tenant_schemas_row_exists?(row_id)
      assert tenants_row_exists?(tenant.id)
    end
  end

  # ---------------------------------------------------------------------------------
  # Criterion 4 -- outer return-shape contract: sweep_orphans/2 reliably returns
  # {:ok, %{reclaimed: _, skipped_invalid_format: _}}, including on a call that finds
  # nothing to do (the everyday case for both real call sites in test_helper.exs).
  # A forced DB-level outer failure is not exercised here -- see test/specs/ISS-0064.md
  # for why that was judged impractical for this file and left uncovered.
  # ---------------------------------------------------------------------------------

  # ---------------------------------------------------------------------------------
  # Criterion 5 (ISS-0110) -- concurrent-invocation liveness guard: an old row is
  # spared while ANOTHER "mix test invocation" (a real, separate Postgres connection
  # tagged with a distinct letflow_mixtest_* application_name) is connected, and
  # reclaimed once that connection closes -- proving both directions of the fix
  # without needing to spawn a second OS process.
  # ---------------------------------------------------------------------------------

  describe "sweep_orphans/2 concurrent-invocation liveness guard (ISS-0110)" do
    test "spares an old row while another invocation's connection is open, reclaims it once that connection closes" do
      tenant = insert_tenant!()
      schema_name = valid_schema_name()
      create_schema!(schema_name)

      old_provisioned_at = naive_now() |> NaiveDateTime.add(-10_000, :second)
      row_id = insert_tenant_schemas_row!(tenant.id, schema_name, old_provisioned_at)

      on_exit(fn -> drop_schema!(schema_name) end)

      # A real, separate Postgres connection tagged as a DIFFERENT mix test
      # invocation -- exactly what config/test.exs's own connections carry, just
      # with a fake pid suffix a real invocation could never coincidentally share.
      fake_tag = "letflow_mixtest_fake#{System.unique_integer([:positive])}"
      # Starts the fake-tagged connection with explicit queue options and blocks until
      # it is really visible in pg_stat_activity under its tag (the sanity check) --
      # otherwise this test could pass for the wrong reason (Q-1037 / GH #2364).
      other_conn = FakeInvocationConnection.start!(fake_tag)

      # ISS-1083 / GH #2441 (diagnostic, not a root-cause fix): start!/2 proved visibility
      # once, at setup time. assert_visible!/3 re-checks it through the sweeper's session
      # type right before the sweep, which narrows the window in which the backend could be
      # between disconnect and reconnect. It does not close the window: the sweep's own
      # guard read is a separate read after this one. Sandbox :auto is needed so the
      # re-check is not served from the transaction's cached snapshot.
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
      :ok = FakeInvocationConnection.assert_visible!(other_conn, fake_tag)

      result = TenantSchemaReaper.sweep_orphans(Repo, 1)

      case result do
        {:ok, %{reclaimed: 0, skipped_invalid_format: _}} ->
          :ok

        other ->
          # the sweep's after-block restored :manual; set :auto so the failure-time listing
          # is fresh, not a cached snapshot
          Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

          flunk(
            "sweep_orphans/2 did not defer while another invocation was open: #{inspect(other)}\n" <>
              FakeInvocationConnection.capture(other_conn, fake_tag)
          )
      end

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      # Deferred, not reclaimed -- the row and its real schema both survive despite
      # being 10_000s old and comfortably past min_age_seconds: 1.
      assert schema_exists?(schema_name)
      assert tenant_schemas_row_exists?(row_id)
      assert tenants_row_exists?(tenant.id)

      # Close the "other invocation" -- its connection, and therefore its tag,
      # disappears from pg_stat_activity exactly as a genuinely dead invocation's
      # would (TCP-level, unconditional).
      # Q-1037 / GH #2364: stopping the client closes its socket, but the server-side
      # backend leaves pg_stat_activity a moment LATER (it notices the closed socket
      # on its next read). A sweep issued in that window still sees the tag and
      # defers (reclaimed: 0). With a faster database (durability off in CI) that
      # window is hit, so stop_and_wait_gone!/3 waits, bounded, until the tag is
      # really gone before the second sweep -- the guard under test is unchanged.
      FakeInvocationConnection.stop_and_wait_gone!(other_conn, fake_tag)

      assert {:ok, %{reclaimed: reclaimed, skipped_invalid_format: _}} =
               TenantSchemaReaper.sweep_orphans(Repo, 1)

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      assert reclaimed >= 1
      refute schema_exists?(schema_name)
      refute tenant_schemas_row_exists?(row_id)
      refute tenants_row_exists?(tenant.id)
    end
  end

  describe "sweep_orphans/2 guard-read diagnostics (GH #2441)" do
    import ExUnit.CaptureLog

    test "logs the guard read with the database-side transaction state" do
      # The test process holds its DataCase sandbox checkout, so the guard read runs inside
      # a DB-level transaction that Repo.in_transaction?/0 cannot see.
      log =
        capture_log([level: :warning], fn ->
          assert {:ok, _} = TenantSchemaReaper.sweep_orphans(Repo, 1)
        end)

      assert log =~ "TenantSchemaReaper guard read (GH #2441)"
      assert log =~ "in_transaction=true"
    end
  end

  describe "sweep_orphans/2 return-shape contract" do
    test "returns {:ok, %{reclaimed: _, skipped_invalid_format: _}} with no orphans present" do
      assert {:ok, %{reclaimed: reclaimed, skipped_invalid_format: skipped}} =
               TenantSchemaReaper.sweep_orphans(Repo, 300)

      assert is_integer(reclaimed) and reclaimed >= 0
      assert is_integer(skipped) and skipped >= 0
    end

    test "returns the same shape when called with the two-argument defaults" do
      assert {:ok, %{reclaimed: reclaimed, skipped_invalid_format: skipped}} =
               TenantSchemaReaper.sweep_orphans()

      assert is_integer(reclaimed) and reclaimed >= 0
      assert is_integer(skipped) and skipped >= 0
    end
  end
end
