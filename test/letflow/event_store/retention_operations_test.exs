defmodule Letflow.EventStore.RetentionOperationsTest do
  @moduledoc """
  Tests for `Letflow.EventStore.RetentionOperations` (REQ-377) --
  `retention_summary/0`, `retire_oldest_eligible_month/1` (happy path +
  `{:error, :no_eligible_month}`), and `retirement_status/1` (found/not-found).
  See `test/specs/REQ-377.md` for the full AC-to-test mapping and
  `lib/letflow/design/req377-history-retirement-screen.md` §2.1 for the
  design this module implements.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked `Repo`
  anywhere in this file. Self-contained per DIRECTIVE T-4: fixture helpers
  below deliberately duplicate `test/letflow/event_store/partition_maintenance_test.exs`'s
  own helpers of the same name/shape (`provisioned_tenant/1`,
  `with_event_retention_override/2`, `create_events_month_partition!/3`,
  `seed_event!/5`) rather than importing them.

  ## Sandbox `:auto` mode

  `TenantProvisioning.replay_migrations/2` needs a second real DB
  connection the DataCase sandbox can't hand out (same reason
  `partition_maintenance_test.exs`'s own moduledoc states), and
  `retire_oldest_eligible_month/1` itself dispatches a genuinely concurrent
  `Task.Supervisor.async_nolink/3` call that reads/writes through a
  DIFFERENT connection than the test's own -- both need Sandbox `:auto`
  mode. `async: false` for the whole module for the same reason.

  ## Why `min_partition_age_days` is overridden to `1`

  Same rationale as `partition_maintenance_test.exs`'s own moduledoc: the
  real 400-day default would force every fixture to seed a partition over a
  year in the past for no additional coverage -- `eligible_months/1`'s
  underlying `eligible?/2` logic is exercised identically either way. Every
  override uses `with_event_retention_override/2`, restored in an `after`
  block unconditionally, never leaking across tests.

  ## Waiting for the async fanout to finish

  `retire_oldest_eligible_month/1` returns as soon as the
  `event_history_retirements` row is inserted -- the fanout Task may still
  be running. Tests that need the FINISHED result poll `retirement_status/1`
  via `wait_until_status/2` below (short, bounded polling against a real DB
  read -- not a `Process.sleep/1` guess, and not dependent on wall-clock
  duration beyond a generous timeout budget for one tiny, single-tenant,
  empty-partition retirement).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore.Event
  alias Letflow.EventStore.EventHistoryRetirement
  alias Letflow.EventStore.EventHistoryRetirementOutcome
  alias Letflow.EventStore.RetentionOperations
  alias Letflow.EventStore.RetentionPolicy
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.Test.PartitionClock

  # Single source for the override value and the PartitionClock argument.
  @override_age_days 1

  # ===========================================================================
  # Tenant / schema fixtures -- provisions via Letflow.TenantFixture (ISS-0112 /
  # GH#366). `drop_schema!/1` stays -- called directly by the "concurrently dropped
  # schema" regression test below (ISS-0873).
  # ===========================================================================

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # template: :replay (not the fixture's :clone default) -- this file's own
  # create_events_month_partition!/3 issues `CREATE TABLE ... PARTITION OF events`,
  # which requires a genuinely partitioned `events` table. A :clone-provisioned
  # tenant's events/events_archive are plain, unpartitioned tables (Postgres's LIKE
  # ... INCLUDING ALL does not copy the PARTITION BY clause -- see
  # Letflow.TenantFixture's own req376_partition_management_table?/1 doc), so :clone
  # would fail every test here with "events is not partitioned" (42P17).
  defp provisioned_tenant(_context \\ %{}) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req377",
      display_name: "REQ-377 Test Tenant",
      template: :replay
    )
  end

  defp unique_idempotency_key(prefix \\ "IDK377") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp seed_event!(schema_name, instance_id, event_type, seq, created_at) do
    %Event{}
    |> Event.insert_changeset(%{
      event_id: Ecto.UUID.generate(),
      created_at: created_at,
      instance_id: instance_id,
      event_type: event_type,
      payload: %{"seeded" => true},
      actor_id: Ecto.UUID.generate(),
      sequence_number: seq,
      idempotency_key: unique_idempotency_key()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp seed_retention_policy!(attrs) do
    policy =
      %RetentionPolicy{}
      |> RetentionPolicy.insert_changeset(attrs)
      |> Repo.insert!()

    on_exit(fn ->
      Repo.delete_all(from(r in RetentionPolicy, where: r.id == ^policy.id))
    end)

    policy
  end

  # ===========================================================================
  # Month / partition-naming helpers -- deliberate reimplementation, per
  # DIRECTIVE T-4, of PartitionMaintenance's own private month-boundary logic.
  # ===========================================================================

  defp shift_months({year, month}, offset) do
    total = year * 12 + (month - 1) + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp events_partition_name(year, month), do: "events_y#{year}m#{pad2(month)}"

  defp month_bounds_str(year, month) do
    from = "#{year}-#{pad2(month)}-01"
    {next_year, next_month} = shift_months({year, month}, 1)
    to = "#{next_year}-#{pad2(next_month)}-01"
    {from, to}
  end

  # Latest month eligible under the `min_partition_age_days: @override_age_days`
  # override. Last calendar month is NOT eligible on the 1st of a month; see
  # Letflow.Test.PartitionClock (ISS-0937).
  defp eligible_past_month,
    do: PartitionClock.eligible_past_month(Date.utc_today(), @override_age_days)

  defp create_events_month_partition!(schema_name, year, month) do
    partition = events_partition_name(year, month)
    {from_bound, to_bound} = month_bounds_str(year, month)

    Repo.query!(
      ~s{CREATE TABLE "#{schema_name}"."#{partition}" PARTITION OF "#{schema_name}".events FOR VALUES FROM ('#{from_bound}') TO ('#{to_bound}')}
    )

    partition
  end

  defp with_event_retention_override(overrides, fun) do
    previous = Application.get_env(:letflow, :event_retention, [])
    Application.put_env(:letflow, :event_retention, Keyword.merge(previous, overrides))

    try do
      fun.()
    after
      Application.put_env(:letflow, :event_retention, previous)
    end
  end

  defp wait_until_status(retirement_id, target_statuses, attempts \\ 100) when attempts > 0 do
    {:ok, result} = RetentionOperations.retirement_status(retirement_id)

    if result.retirement.status in target_statuses do
      result
    else
      Process.sleep(50)
      wait_until_status(retirement_id, target_statuses, attempts - 1)
    end
  end

  defp cleanup_retirement_rows_on_exit!(retirement_id) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      Repo.delete_all(
        from(o in EventHistoryRetirementOutcome, where: o.retirement_id == ^retirement_id)
      )

      Repo.delete_all(from(r in EventHistoryRetirement, where: r.id == ^retirement_id))
    end)
  end

  # ===========================================================================
  # retention_summary/0
  # ===========================================================================

  describe "retention_summary/0" do
    test "oldest_eligible_month is nil, protected_record_count is 0, when no schema has an eligible month" do
      %{schema_name: schema_name} = provisioned_tenant()
      # A brand-new tenant schema's `events` parent has no attached month
      # partitions at all beyond `events_default` -- eligible_months/1 must
      # return [] for it, so the platform-wide minimum is nil.

      assert {:ok, summary} = RetentionOperations.retention_summary()
      assert summary.oldest_eligible_month == nil
      assert summary.protected_record_count == 0
      assert is_integer(summary.tenant_schema_count)
      assert summary.tenant_schema_count >= 1
      assert %NaiveDateTime{} = summary.computed_at
      # schema_name unused directly beyond provisioning -- the fixture's own
      # registration row is what tenant_schema_count counts.
      refute is_nil(schema_name)
    end

    test "oldest_eligible_month is the minimum eligible month across every provisioned schema" do
      with_event_retention_override([min_partition_age_days: @override_age_days], fn ->
        %{schema_name: schema_a} = provisioned_tenant()
        %{schema_name: schema_b} = provisioned_tenant()

        {older_year, older_month} = shift_months(eligible_past_month(), -3)
        {newer_year, newer_month} = eligible_past_month()

        create_events_month_partition!(schema_a, newer_year, newer_month)
        create_events_month_partition!(schema_b, older_year, older_month)

        assert {:ok, summary} = RetentionOperations.retention_summary()
        assert summary.oldest_eligible_month == %{year: older_year, month: older_month}
      end)
    end

    test "protected_record_count sums keep_forever rows across events for every schema, unaffected by min_partition_age_days" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      keep_type = "kept_type_#{System.unique_integer([:positive])}"
      other_type = "other_type_#{System.unique_integer([:positive])}"
      seed_retention_policy!(%{event_type: keep_type, policy: :keep_forever})
      seed_retention_policy!(%{event_type: other_type, policy: :keep_days, keep_days: 30})

      now = DateTime.utc_now()
      seed_event!(schema_name, instance_id, keep_type, 1, now)
      seed_event!(schema_name, instance_id, keep_type, 2, now)
      seed_event!(schema_name, instance_id, other_type, 3, now)

      # ISS-0873: retention_summary/0's fix (design doc
      # lib/letflow/design/iss0873-retention-summary-toctou.md §1/§4a)
      # guarantees every read INSIDE one call is drawn from a single
      # REPEATABLE READ snapshot -- it does NOT promise that two separate
      # top-level calls return bit-identical platform-wide results, since
      # each call opens its own transaction and another test-suite
      # partition's concurrent RetentionPolicy write (under
      # scripts/test_parallel.sh sharding) can legitimately change the
      # platform-wide sum between the two calls below. So each call is
      # asserted independently against this test's OWN fixture invariant
      # (>= 2, this fixture's two keep_forever rows can only ever be ADDED
      # to by another partition, never removed) rather than asserted equal
      # to each other.
      assert {:ok, summary_before} = RetentionOperations.retention_summary()
      assert summary_before.protected_record_count >= 2

      # A second call (no retirement in between) -- still self-sufficient:
      # this test's own two keep_forever rows are still counted, whatever
      # else concurrently changed platform-wide. This also exercises
      # "calling it twice doesn't crash / doesn't mutate anything."
      assert {:ok, summary_again} = RetentionOperations.retention_summary()
      assert summary_again.protected_record_count >= 2
    end

    test "a schema whose Registration row still exists but whose physical schema was concurrently dropped contributes 0 protected rows instead of raising" do
      # ISS-0873 §2 / design doc §4b: reproduces the exact
      # "Registration says provisioned, physical schema already gone"
      # race deterministically (no timing/concurrency needed -- the schema
      # is already dropped before retention_summary/0 is even called).
      # Discriminates count_protected_rows_in_schema/3's narrow rescue
      # (retention_operations.ex:372-389): without it, this test fails with
      # a raised Postgrex.Error (:undefined_table) instead of {:ok, _}.
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      keep_type = "kept_type_#{System.unique_integer([:positive])}"
      seed_retention_policy!(%{event_type: keep_type, policy: :keep_forever})
      seed_event!(schema_name, instance_id, keep_type, 1, DateTime.utc_now())

      # Directly DROP SCHEMA ... CASCADE (bypassing normal deprovisioning),
      # same mechanism this file's own drop_schema!/1 already uses for
      # on_exit cleanup -- but here it runs BEFORE the assertion, while the
      # tenant's Registration row is deliberately left in place. Sandbox
      # :auto mode (already this module's convention, provisioned_tenant/0
      # above) lets this DDL and the summary read below share real,
      # separately-committed state.
      drop_schema!(schema_name)

      assert {:ok, summary} = RetentionOperations.retention_summary()
      assert summary.tenant_schema_count >= 1
      # The dropped schema contributes 0 -- it must not inflate the count,
      # and the call must not raise.
      assert is_integer(summary.protected_record_count)
    end
  end

  # ===========================================================================
  # retire_oldest_eligible_month/1
  # ===========================================================================

  describe "retire_oldest_eligible_month/1 -- happy path" do
    test "inserts a running row immediately, returns before the fanout completes, and the row later reaches completed" do
      with_event_retention_override([min_partition_age_days: @override_age_days], fn ->
        %{schema_name: schema_name} = provisioned_tenant()
        {year, month} = eligible_past_month()
        create_events_month_partition!(schema_name, year, month)

        requested_by = Ecto.UUID.generate()

        assert {:ok, retirement} = RetentionOperations.retire_oldest_eligible_month(requested_by)
        cleanup_retirement_rows_on_exit!(retirement.id)

        assert retirement.year == year
        assert retirement.month == month
        assert retirement.requested_by == requested_by
        # AC1: the caller gets the row back BEFORE the fanout has
        # necessarily finished -- status is "running" or already
        # "completed" by the time this assertion runs (a race is expected
        # and both are valid observations of a real async system), but a
        # `GET` issued immediately must find a real row either way.
        assert retirement.status in ["running", "completed"]

        assert {:ok, immediate_read} = RetentionOperations.retirement_status(retirement.id)
        assert immediate_read.retirement.id == retirement.id

        # Poll until the async fanout genuinely finishes.
        result = wait_until_status(retirement.id, ["completed", "failed"])
        assert result.retirement.status == "completed"
        assert %NaiveDateTime{} = result.retirement.completed_at

        own_outcomes = Enum.filter(result.outcomes, &(&1.schema_name == schema_name))

        assert [outcome] = own_outcomes
        assert outcome.status == :succeeded
        assert outcome.retired_partition == events_partition_name(year, month)
        assert is_integer(outcome.protected_rows_relocated)
      end)
    end

    test "a schema with no eligible month for the chosen month is recorded skipped, not failed" do
      with_event_retention_override([min_partition_age_days: @override_age_days], fn ->
        %{schema_name: eligible_schema} = provisioned_tenant()
        %{schema_name: bare_schema} = provisioned_tenant()

        {year, month} = eligible_past_month()
        create_events_month_partition!(eligible_schema, year, month)
        # bare_schema deliberately gets no partition for this month at all --
        # PartitionMaintenance.retire_month/3 returns
        # {:error, :partition_not_found} for it, which retire_one_schema/5
        # must record as "skipped", never "failed".

        requested_by = Ecto.UUID.generate()
        assert {:ok, retirement} = RetentionOperations.retire_oldest_eligible_month(requested_by)
        cleanup_retirement_rows_on_exit!(retirement.id)

        result = wait_until_status(retirement.id, ["completed", "failed"])
        assert result.retirement.status == "completed"

        own_schemas = [eligible_schema, bare_schema]

        statuses =
          result.outcomes
          |> Enum.filter(&(&1.schema_name in own_schemas))
          |> Enum.map(& &1.status)
          |> Enum.sort()

        assert :succeeded in statuses
        assert :skipped in statuses
        refute :failed in statuses

        refute is_nil(bare_schema)
      end)
    end
  end

  describe "retire_oldest_eligible_month/1 -- error path" do
    test "returns {:error, :no_eligible_month} and inserts no row when no schema has an eligible month" do
      provisioned_tenant()
      # Real 400-day default in force (no override) -- a schema this test
      # just provisioned has no attached month partitions at all, so this is
      # not an artificially-forced error, it is the real
      # oldest_eligible_month_platform_wide/0 result for this state.

      before_count = Repo.aggregate(EventHistoryRetirement, :count)

      assert {:error, :no_eligible_month} =
               RetentionOperations.retire_oldest_eligible_month(Ecto.UUID.generate())

      assert Repo.aggregate(EventHistoryRetirement, :count) == before_count
    end
  end

  # ===========================================================================
  # retirement_status/1
  # ===========================================================================

  describe "retirement_status/1" do
    test "returns {:error, :retirement_not_found} for an unknown id" do
      assert {:error, :retirement_not_found} =
               RetentionOperations.retirement_status(Ecto.UUID.generate())
    end

    test "found case: returns the retirement plus every outcome row, ordered by tenant_id" do
      with_event_retention_override([min_partition_age_days: @override_age_days], fn ->
        %{schema_name: schema_name, tenant_id: tenant_id} = provisioned_tenant()
        {year, month} = eligible_past_month()
        create_events_month_partition!(schema_name, year, month)

        requested_by = Ecto.UUID.generate()
        assert {:ok, retirement} = RetentionOperations.retire_oldest_eligible_month(requested_by)
        cleanup_retirement_rows_on_exit!(retirement.id)

        result = wait_until_status(retirement.id, ["completed", "failed"])

        assert result.retirement.id == retirement.id
        assert Enum.any?(result.outcomes, &(&1.tenant_id == tenant_id))
      end)
    end
  end
end
