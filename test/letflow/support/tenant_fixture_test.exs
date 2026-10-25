defmodule Letflow.Support.TenantFixtureTest.LogCollector do
  @moduledoc """
  A minimal `:logger` handler used by the `phase=teardown` test only.

  `ExUnit.CaptureLog` installs and removes its handler around a function call made
  **inside the test body**. The fixture's teardown runs from `on_exit/1`, after the test
  process has already exited, so no `capture_log/1` wrapper written in a test body can
  ever span it. This handler is installed from an `on_exit/1` callback that is ordered
  (LIFO) to run *before* the fixture's own teardown callback, and read by a second
  callback ordered to run *after* it — which is the only way to observe that line
  without modifying `Letflow.TenantFixture` (forbidden for this run).

  Every other log assertion in the suite below uses `ExUnit.CaptureLog` directly,
  because those lines are emitted synchronously inside the test body.
  """

  @marker "LETFLOW_TENANT_FIXTURE"

  def log(%{msg: {:string, message}}, %{config: %{agent: agent}}) do
    line = IO.chardata_to_string(message)

    if String.contains?(line, @marker) do
      Agent.update(agent, &[line | &1])
    end

    :ok
  rescue
    _exception -> :ok
  end

  def log(_event, _config), do: :ok
end

defmodule Letflow.Support.TenantFixtureTest do
  @moduledoc """
  Regression tests for `Letflow.TenantFixture` (ISS-0109 / GH#358).

  Spec: `test/specs/ISS-0109.md`. Design:
  `lib/letflow/design/iss0109-provisioning-completeness-and-fixture-instrumentation.md`
  — §7's cases C1..C6 are what this module implements, one section per case.

  Real Postgres throughout (`Letflow.DataCase`, DIRECTIVE T-1) — every broken state below
  is *constructed* by real SQL against a real, really-provisioned tenant schema, never
  mocked and never waited for. ISS-0109's own occurrence is intermittent and unreproduced,
  so no test here may depend on a recurrence, on wall-clock timing, or on concurrency.

  ## Fail-first position (stated here as well as in the spec, because it is easy to fake)

  The literal WF-03 form — check out the pre-fix commit, run this file, watch it fail —
  does not apply: the fix is a *new module*, so pre-fix this file would not compile, and a
  file that does not compile is not evidence about anything. The real property is that
  **pre-fix detection was absent on identical database state**, and `test C1 replay`
  below re-derives that mechanically in one test: on the exact state of ISS-0109's
  failure 14, the old fixture's only oracle (`{:ok, _}` from `replay_migrations/1`) still
  passes, while `assert_schema_complete!/2` raises naming the missing table.

  ## Teardown discipline

  Tests that construct a broken state call `provisioned_tenant!(teardown: false)` and
  register their own cleanup, exactly as design §7 requires, so the fixture's own teardown
  cannot repair or race the damage under assertion.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.Support.TenantFixtureTest.LogCollector
  alias Letflow.Test.LoggerCollector
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @marker "LETFLOW_TENANT_FIXTURE"

  # The version/table pair from ISS-0109's failure 14, and the one CODE-DESIGN-VALIDATOR
  # measured `{:ok, []}` against at step-02b.
  @failure_14_table "promotion_assertion_runs"
  @failure_14_version 20_260_818_090_001

  # The highest entry in @tenant_scoped_migration_manifest and the table it creates.
  @highest_version 20_260_821_000_002
  @highest_version_table "variable_schemas"

  @collector_handler_id :iss0109_tenant_fixture_teardown_collector

  # ---------------------------------------------------------------------------------
  # C1 -- a dropped table whose migration version is still recorded (failure 14)
  # ---------------------------------------------------------------------------------

  describe "C1 -- a table dropped while its version stays recorded" do
    test "is reported by the capture as exactly that one table missing" do
      %{tenant_id: tenant_id, schema_name: schema_name} = broken_state_tenant!("iss0109-c1a")
      drop_table!(schema_name, @failure_14_table)

      {:ok, state} = TenantFixture.capture_schema_state(tenant_id)

      assert state.schema_present? == true
      assert state.tables_missing == [@failure_14_table]
      assert state.versions_missing == []
      assert @failure_14_version in state.applied_versions
      refute @failure_14_table in state.tables_present
    end

    test "passes replay's old oracle and still fails the completeness check" do
      %{tenant_id: tenant_id, schema_name: schema_name} = broken_state_tenant!("iss0109-c1b")
      drop_table!(schema_name, @failure_14_table)

      # The pre-fix fixture's ENTIRE oracle, run here against the broken state. Ecto's
      # migrator re-applies nothing for an already-recorded version, so this passes and
      # the table stays absent -- the same {:ok, []} CODE-DESIGN-VALIDATOR measured at
      # step-02b. This is the regression proof: same database state, old oracle green.
      assert {:ok, []} = TenantProvisioning.replay_migrations(tenant_id)
      refute table_exists?(schema_name, @failure_14_table)

      # The new oracle, on that same state, red.
      error =
        assert_raise ExUnit.AssertionError, fn ->
          TenantFixture.assert_schema_complete!(tenant_id)
        end

      assert error.message =~ @failure_14_table
      assert error.message =~ "tables_missing"
    end
  end

  # ---------------------------------------------------------------------------------
  # C2 -- a dropped schema whose registration row survives (failure 3)
  # ---------------------------------------------------------------------------------

  describe "C2 -- a schema dropped with its registration row left in place" do
    test "is captured as observed-absent with the registration still present" do
      %{tenant_id: tenant_id, schema_name: schema_name} = broken_state_tenant!("iss0109-c2a")
      drop_schema!(schema_name)

      {:ok, state} = TenantFixture.capture_schema_state(tenant_id)

      # `false`, not `nil`: the schemata query ran and observed an absence.
      assert state.schema_present? == false
      assert state.registration_present? == true
      assert state.provisioned_at != nil
      assert state.tables_present == []
      assert Enum.sort(state.tables_missing) == Enum.sort(TenantFixture.expected_tenant_tables())

      # `"<schema>".schema_migrations` is unreadable now, so applied_versions is
      # UNOBSERVED -- and an unobserved set must never be reported as an observed
      # absence, so versions_missing is [] rather than all 31 manifest versions.
      assert state.applied_versions == []
      assert state.versions_missing == []
      assert length(state.manifest_versions) > 0

      error =
        assert_raise ExUnit.AssertionError, fn ->
          TenantFixture.assert_schema_complete!(tenant_id)
        end

      assert error.message =~ "is absent from information_schema.schemata"
    end

    test "characterization only: re-provisioning returns ok and leaves it empty" do
      # NOT a regression assertion. Design §7.2 is explicit that there is no production
      # behaviour change here; this pins the DOCUMENTED idempotency of
      # provision_tenant_schema/1 so a silent change to it is visible, and then shows the
      # fixture now catches the empty schema that re-provisioning leaves behind.
      %{tenant_id: tenant_id, schema_name: schema_name} = broken_state_tenant!("iss0109-c2b")
      drop_schema!(schema_name)

      assert {:ok, %Registration{}} = TenantProvisioning.provision_tenant_schema(tenant_id)

      {:ok, state} = TenantFixture.capture_schema_state(tenant_id)
      assert state.schema_present? == true
      assert Enum.sort(state.tables_missing) == Enum.sort(TenantFixture.expected_tenant_tables())

      assert_raise ExUnit.AssertionError, fn ->
        TenantFixture.assert_schema_complete!(tenant_id)
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # C3 -- a replay that stopped short: version row deleted and its table dropped
  # ---------------------------------------------------------------------------------

  describe "C3 -- a missing migration version" do
    test "is reported alongside the table that version created" do
      %{tenant_id: tenant_id, schema_name: schema_name} = broken_state_tenant!("iss0109-c3")

      Repo.query!(
        ~s(DELETE FROM "#{schema_name}".schema_migrations WHERE version = $1),
        [@highest_version]
      )

      drop_table!(schema_name, @highest_version_table)

      {:ok, state} = TenantFixture.capture_schema_state(tenant_id)

      assert state.versions_missing == [@highest_version]
      assert state.tables_missing == [@highest_version_table]
      refute @highest_version in state.applied_versions

      error =
        assert_raise ExUnit.AssertionError, fn ->
          TenantFixture.assert_schema_complete!(tenant_id)
        end

      assert error.message =~ "versions_missing"
      assert error.message =~ @highest_version_table
    end
  end

  # ---------------------------------------------------------------------------------
  # C4 -- capture fidelity, the INV-F-4 negative case, and the §3.5 failure boundary
  # ---------------------------------------------------------------------------------

  describe "C4 -- capture_schema_state/1 on a healthy tenant" do
    test "reports every field faithfully on one clock basis" do
      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0109-c4-healthy")

      {:ok, state} = TenantFixture.capture_schema_state(tenant_id)

      assert state.schema_name == schema_name
      assert state.tenant_id == tenant_id
      assert state.registration_present? == true
      assert state.schema_present? == true
      assert state.provisioned_at != nil
      assert state.migrations_applied_at != nil
      assert state.tables_missing == []
      assert state.versions_missing == []
      assert is_integer(state.pg_backend_pid)

      # The row's age at observation is the number Step 1 had to reconstruct by hand
      # across a UTC-vs-local skew; it can never be negative on one basis.
      assert NaiveDateTime.compare(state.observed_at_utc, state.provisioned_at) in [:gt, :eq]

      # A BOUND, not equality: the two clocks are read microseconds apart. Its purpose is
      # to catch a BASIS error (local time wearing a Z), which is exactly the skew that
      # cost the ISS-0109 diagnosis five hours -- not to police jitter.
      assert abs(NaiveDateTime.diff(state.db_now, state.observed_at_utc)) < 120

      assert :ok == TenantFixture.assert_schema_complete!(tenant_id)
    end
  end

  describe "C4 -- capture_schema_state/1 failure boundary (design §3.5, INV-F-4)" do
    test "returns ok for a wholly absent tenant instead of raising" do
      # INV-F-4's negative case: no registration row, no schema, nothing at all.
      absent_tenant_id = Ecto.UUID.generate()

      assert {:ok, state} = TenantFixture.capture_schema_state(absent_tenant_id)

      # Both flags are `false` -- OBSERVED absent. Both queries ran and returned nothing.
      assert state.registration_present? == false
      assert state.schema_present? == false
      assert state.provisioned_at == nil
      assert state.tables_present == []
      # schema_migrations is unreadable, so versions are unobserved: [] not "all missing".
      assert state.versions_missing == []
    end

    test "returns capture_failed only for a failure outside the field guards" do
      # A malformed tenant_id means no schema name can be derived, so NO field can even be
      # attempted -- the one documented route to the outer safety net.
      assert {:error, {:capture_failed, exception}} =
               TenantFixture.capture_schema_state("not-a-uuid")

      # An Exception.t() naming the offending argument -- the report has to say what it
      # could not read, or it repeats ISS-0109's own unattributability.
      assert Exception.message(exception) =~ "not-a-uuid"
    end

    test "degrades a failed field to nil and never to an observed absence" do
      # THE distinction test. Inside an aborted transaction every per-field query raises,
      # so each field degrades. `nil` here means NOT-OBSERVED and must not be confused
      # with `false` (observed-absent) -- if the two were interchangeable, this healthy
      # tenant would be reported as having no schema and no registration, and
      # assert_schema_complete!/2 would turn a passing test red (INV-F-10).
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0109-c4-degraded")

      state = capture_in_aborted_transaction(tenant_id)

      assert state.registration_present? == nil
      assert state.schema_present? == nil
      refute state.registration_present? == false
      refute state.schema_present? == false

      # An unobserved set is never reported as an observed absence -- BOTH derived pairs.
      assert state.tables_present == []
      assert state.tables_missing == []
      assert state.applied_versions == []
      assert state.versions_missing == []

      # Proof the two would differ if the derivation were naive: the oracle and the
      # manifest are both non-empty, so "expected -- []" would have been 25 and 37.
      # (REQ-076 added the api_tokens table to the tenant-scoped migration manifest,
      # bumping this oracle from 20 to 21; REQ-125 added definition_sequence, bumping
      # it from 21 to 22; REQ-176 added dlq_entries, bumping it from 22 to 23; REQ-181
      # added webhook_subscriptions, bumping it from 23 to 24; REQ-186 added timers,
      # bumping it from 24 to 25; REQ-183 added webhook_delivery_attempts, bumping it
      # from 25 to 26; REQ-195 added audit_entries, bumping it from 26 to 27; REQ-202
      # added repository_artifacts and artifact_versions, bumping it from 27 to 29;
      # REQ-203 added artifact_activations, artifact_activation_history,
      # and artifact_activation_groups, bumping it from 29 to 32; REQ-201 added
      # alert_trigger_state and alert_hook_emission_state, bumping it from 32 to 34;
      # REQ-199 added correlation_cursors and effect_completions, bumping it from
      # 34 to 36; REQ-211 added instance_attachments, bumping it from 36 to 37;
      # REQ-214 added service_task_dispatches, bumping it from 37 to 38 --
      # REQ-226 added entity_definitions, bumping it from 38 to 39 -- REQ-228
      # added entity_record_latest and entity_type_instances, bumping it from
      # 39 to 41 -- REQ-231 added entity_field_restrictions and
      # user_entity_grants, bumping it from 41 to 43 -- REQ-316 added
      # entity_record_attachments, bumping it from 43 to 44 -- REQ-364 added
      # help_content, bumping it from 44 to 45 -- REQ-394 added
      # entity_type_restrictions and user_entity_type_grants, bumping it
      # from 45 to 47 -- REQ-402 added tenant_modules, bumping it from 47
      # to 48 -- ISS-0979 added audit_chain_locks, bumping it from 48 to 49 --
      # ISS-1030 added pending_tenant_admin_grants, bumping it from 49 to 50 --
      # GH 2534 7b-1 added script_rules, bumping it from 50 to 51 -- REQ-496
      # (GH #2530) added scope_node_paths, bumping it to 52 -- GH 2534 7b-2a added
      # script_policy and script_readable_masters, bumping it to 54 -- REQ-497
      # (GH #2533 PR 1a) added role_scope_grants, bumping it to 55 -- GH 2534 7c-1 added
      # script_task_dispatches, bumping it to 56 -- REQ-517 PR 2b (GH #2535) added
      # scope_shadow_counters, bumping it to 57 -- REQ-500 / GH #2588 (PR A) added
      # documents, document_types, document_versions, document_sequences and
      # document_external_registrations, bumping it to 62 -- REQ-541 / GH #3160 added number_sequence_definitions,
      # number_sequence_counters and number_sequence_numbers, bumping it to 65 -- REQ-551 / GH #3180 added label_overrides, bumping it to 66; REQ-565 / GH #3201 added integration_mappings, bumping it to 67; REQ-555 / GH #3157 added entity_views, bumping it to 68; REQ-563 / GH #3199 added notification_templates, bumping it to 69.
      # test/support/tenant_fixture.ex's own @expected_tenant_tables
      # list already carries all 69.)
      assert length(TenantFixture.expected_tenant_tables()) == 69
      assert length(state.manifest_versions) > 0
    end

    test "does not fail a passing test when the capture itself degraded" do
      # INV-F-10, the consequence of the line above: a diagnostic that cannot see must
      # abstain, not accuse.
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0109-c4-inv-f-10")

      parent = self()
      ref = make_ref()

      Repo.transaction(fn ->
        abort_transaction!()
        send(parent, {ref, TenantFixture.assert_schema_complete!(tenant_id)})
      end)

      # If the degraded capture had raised, no message would ever have been sent.
      assert_received {^ref, :ok}

      # And unambiguously: the schema really is healthy, so nothing was masked.
      assert :ok == TenantFixture.assert_schema_complete!(tenant_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # C5 -- the teardown log line, and the closed phase vocabulary
  # ---------------------------------------------------------------------------------

  describe "C5 -- teardown logging" do
    test "emits one marked teardown line naming the schema and its presence" do
      {:ok, agent} = Agent.start(fn -> [] end)

      # LIFO: registered first, so it runs LAST -- after the fixture's teardown.
      on_exit(fn -> assert_teardown_line(agent) end)

      %{tenant_id: tenant_id, schema_name: schema_name} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0109-c5")

      :persistent_term.put({__MODULE__, :expected}, {tenant_id, schema_name})

      # Registered last, so it runs FIRST -- before the fixture's teardown.
      on_exit(fn -> install_collector(agent) end)
    end

    test "logs a failure phase and never phase=teardown" do
      %{tenant_id: tenant_id, schema_name: schema_name} = broken_state_tenant!("iss0109-c5b")
      drop_table!(schema_name, @failure_14_table)

      {_, entries} =
        LoggerCollector.capture(
          fn ->
            assert_raise ExUnit.AssertionError, fn ->
              TenantFixture.assert_schema_complete!(tenant_id)
            end
          end,
          attribute_to: self()
        )

      log = LoggerCollector.text(entries)
      assert log =~ "#{@marker} phase=incomplete_schema"
      refute log =~ "phase=teardown"
      assert log =~ @failure_14_table
    end

    test "emits no teardown line while the test body is still running" do
      {_, entries} =
        LoggerCollector.capture(
          fn -> TenantFixture.provisioned_tenant!(slug_prefix: "iss0109-c5c") end,
          attribute_to: self()
        )

      refute LoggerCollector.text(entries) =~ "phase=teardown"
    end
  end

  # ---------------------------------------------------------------------------------
  # C6 -- the oracle-rot guard (design §3.3, INV-F-7)
  # ---------------------------------------------------------------------------------

  describe "C6 -- oracle-rot guard" do
    test "observed tables equal expected_tenant_tables/0 in both directions" do
      %{tenant_id: tenant_id} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0109-c6-oracle")

      # REVIEWER step-03d ruling 3: the observed set comes from the capture's
      # `tables_present`, NOT from a raw information_schema.tables read. A raw read
      # returns `schema_migrations`, which expected_tenant_tables/0 deliberately excludes,
      # and the unfiltered set equality below would then fail for the wrong reason.
      {:ok, state} = TenantFixture.capture_schema_state(tenant_id)

      # REQ-376: `provisioned_tenant!/1` above uses its default `template: :clone`,
      # whose `do_clone/2` only ever materializes what `expected_tenant_tables/0`
      # itself lists (see that function's own doc), so this particular call site
      # is not actually expected to observe any REQ-376 partition-management
      # artifact (events_default, events_archive_default, the two
      # *_pre_partition_20260922 rollback-safety-net tables, or
      # events_y<year>m<month>). This filter is a defensive no-op for the
      # :clone path today, and correctly future-proofs this same "both
      # directions" comparison for a :replay-provisioned schema (which DOES
      # carry them, exactly as `Letflow.Test.TenantTemplate`'s own
      # `template_self_check!/1` -- against a genuinely :replay-built staging
      # schema -- already needs the identical filter) should this test, or a
      # copy of it, ever switch template modes.
      observed =
        state.tables_present
        |> Enum.reject(&TenantFixture.req376_partition_management_table?/1)

      expected = TenantFixture.expected_tenant_tables()

      assert observed != []

      assert expected -- observed == [],
             "oracle lists tables absent from a freshly provisioned schema: " <>
               inspect(expected -- observed)

      assert observed -- expected == [],
             "a manifest migration created a table the oracle does not list: " <>
               inspect(observed -- expected)
    end
  end

  # ---------------------------------------------------------------------------------
  # idp_realm_id opt (ISS-0112b) --
  # lib/letflow/design/iss0112b-tenant-fixture-idp-realm-id-opt.md §7.1
  # ---------------------------------------------------------------------------------

  describe "idp_realm_id opt" do
    test "threads a caller-supplied value through to the returned tenant" do
      realm_id = "iss0112b-" <> Ecto.UUID.generate()

      %{tenant: tenant} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0112b-positive",
          oidc_mode: :enabled,
          idp_realm_id: realm_id
        )

      assert tenant.idp_realm_id == realm_id
    end

    test "defaults to nil when the opt is omitted, matching today's behaviour" do
      %{tenant: tenant} =
        TenantFixture.provisioned_tenant!(slug_prefix: "iss0112b-default")

      assert tenant.idp_realm_id == nil
    end

    test "characterization: oidc_mode: :enabled without idp_realm_id still raises, per Tenant.create_changeset/3's existing validation (design §2.2)" do
      assert_raise Ecto.InvalidChangesetError, fn ->
        TenantFixture.provisioned_tenant!(
          slug_prefix: "iss0112b-enabled-no-realm",
          oidc_mode: :enabled
        )
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------------

  # Design §7: a constructed-damage test must own its own cleanup, so the fixture's
  # teardown never repairs or races the state under assertion.
  defp broken_state_tenant!(slug_prefix) do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix, teardown: false)
    on_exit(fn -> hard_cleanup(fixture.tenant_id) end)
    fixture
  end

  defp hard_cleanup(tenant_id) do
    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
      {:error, _reason} -> :ok
    end

    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
  end

  defp drop_table!(schema_name, table) do
    Repo.query!(~s(DROP TABLE "#{schema_name}"."#{table}" CASCADE))
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA "#{schema_name}" CASCADE))
  end

  defp table_exists?(schema_name, table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2",
        [schema_name, table]
      )

    rows != []
  end

  # Aborts the current transaction, after which every further statement on this
  # connection raises until rollback -- the only way to make each per-field query fail
  # without modifying Letflow.TenantFixture (forbidden for this run).
  defp abort_transaction!, do: Repo.query("SELECT 1 FROM letflow_no_such_relation_iss0109")

  defp capture_in_aborted_transaction(tenant_id) do
    parent = self()
    ref = make_ref()

    Repo.transaction(fn ->
      abort_transaction!()
      send(parent, {ref, TenantFixture.capture_schema_state(tenant_id)})
    end)

    receive do
      {^ref, {:ok, state}} -> state
      {^ref, other} -> flunk("capture in an aborted transaction returned #{inspect(other)}")
    after
      5_000 -> flunk("capture in an aborted transaction produced no result")
    end
  end

  defp install_collector(agent) do
    :ok =
      :logger.add_handler(@collector_handler_id, LogCollector, %{
        level: :all,
        config: %{agent: agent}
      })
  end

  defp assert_teardown_line(agent) do
    {tenant_id, schema_name} = :persistent_term.get({__MODULE__, :expected})
    lines = Agent.get(agent, & &1)

    # keyed by this test's own schema: the collector is a global handler (ISS-1038)
    teardown_lines =
      Enum.filter(
        lines,
        &(String.contains?(&1, "phase=teardown") and String.contains?(&1, "schema=#{schema_name}"))
      )

    assert length(teardown_lines) == 1,
           "expected exactly one #{@marker} phase=teardown line, got: #{inspect(lines)}"

    [line] = teardown_lines

    assert String.contains?(line, @marker)
    assert String.contains?(line, "phase=teardown")
    assert String.contains?(line, "schema=#{schema_name}")
    assert String.contains?(line, "tenant_id=#{tenant_id}")
    assert String.contains?(line, "schema_present_before_drop=true")
  after
    :logger.remove_handler(@collector_handler_id)
    :persistent_term.erase({__MODULE__, :expected})
    if Process.alive?(agent), do: Agent.stop(agent)
  end
end
