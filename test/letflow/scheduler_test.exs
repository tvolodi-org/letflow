defmodule Letflow.SchedulerTest do
  @moduledoc """
  Tests for REQ-186 -- `Letflow.Scheduler` (context module) and
  `Letflow.Scheduler.Timer` (schema): the `timers` table's migration-level
  constraints, and the arm/claim/fire/retry/exhaustion machinery. See
  `test/specs/REQ-186.md` for the full acceptance-criterion -> test-case
  mapping and rationale. Design authority:
  `lib/letflow/design/req186-scheduler-core.md`. Implementation authority:
  `lib/letflow/scheduler.ex`/`lib/letflow/scheduler/timer.ex`/
  `priv/repo/migrations/20260829020001_create_timers.exs`, which already
  passed SECURITY-REVIEWER and REVIEWER
  (`handoffs/WF02-REQ186-20260829/step-02c-security-reviewer.json`,
  `step-02d-reviewer.json`).

  `test/letflow/scheduler/poller_test.exs` covers the `Letflow.Scheduler.Poller`
  `GenServer` ticker itself (started explicitly, per
  `handoffs/WF02-REQ186-20260829/step-03-test-designer.json`'s own instruction
  -- `config/test.exs` sets `start_scheduler: false`, so the Poller is never
  running under the ordinary test supervision tree) -- not duplicated here.
  This file exercises `Letflow.Scheduler.poll_and_fire/1`,
  `claim_due_timer_ids/2`, `fire_timer/2`, `attempt_fire/2`, and `create/2`
  directly, matching this codebase's own established "context module tested
  without its process wrapper" precedent (`test/letflow/dlq_test.exs`).

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  Each test that needs real rows provisions a real tenant schema via
  `Letflow.TenantFixture.provisioned_tenant!/1`. `Letflow.EventStore.append/2`'s
  own `active_instance_guard` step requires a real, non-terminal
  `instance_projections` row for `attrs[:instance_id]` (verified directly in
  `event_store.ex`'s `active_instance_guard/3` -- `{:error, :instance_not_started}`
  for any instance_id with no such row) -- every timer expected to actually
  *fire* successfully in these tests is therefore armed against a real,
  started `Letflow.Engine` instance (`start_instance!/1`, mirroring
  `test/letflow/engine_dlq_landing_test.exs`'s own fixture), while a timer
  deliberately armed against a bare `Ecto.UUID.generate()` instance id (no
  matching `instance_projections` row) is this design's own natural,
  organic "fire attempt fails" fixture for AC6/AC7 -- no mocking library
  exists in this codebase (`mix.exs` has no `mox`/`meck` dependency) and none
  is introduced here.

  `async: false` for the same reason every other tenant-fixture-using test
  file in this codebase sets it (real schema creation/teardown against one
  shared Postgres instance).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.Event
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req186-scheduler") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-186 Scheduler Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp create_definition_attrs(graph) do
    %{
      name: unique_name("req186-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  # START -> task(TIMER) -> END -- reaches a real, :active instance_projections
  # row with a real live token parked on a real :TIMER node (REQ-187: firing
  # a timer now re-enters Letflow.Engine to advance the token off the
  # :TIMER node it's found sitting on via the timer's own token_id, so a
  # timer this file expects to actually *fire* successfully must be armed
  # with `token_id: live_token_id!(schema_name, instance_id)`, matching this
  # graph's own real live token -- `node_id` on the Timer row itself stays
  # free-form/informational (only used for the TIMER_FIRED event payload),
  # not cross-checked against the live token's own real node_id anywhere).
  # `duration_iso8601` is set far in the future (`P1D`) so `start_instance!/1`'s
  # own automatic REQ-187 timer-arm (armed by Letflow.Engine.create/2 itself,
  # the moment the root token lands on this node) never becomes due during
  # any test in this file -- this file's own manually-`arm_timer!`-ed rows
  # are always the ones that end up claimed.
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P1D"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # The real, live TokenRecord.id (stringified) for `instance_id`'s one
  # live token -- the id Letflow.Scheduler.create/2's own `:token_id`
  # attribute must carry for Letflow.Engine.advance_after_timer_fired/3 to
  # find it (REQ-187 design doc §8.2 -- a direct match against the live
  # token set's own token_id, not a node_id search).
  defp live_token_id!(schema_name, instance_id) do
    TokenRecord
    |> where([t], t.instance_id == ^instance_id and t.status == :active)
    |> select([t], t.id)
    |> Repo.one!(prefix: schema_name)
    |> to_string()
  end

  defp active_definition!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph_human_task_end()),
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp start_instance!(schema_name) do
    definition = active_definition!(schema_name)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_name("req186-start")
               },
               prefix: schema_name
             )

    result.instance_id
  end

  defp past_fire_at(seconds_ago \\ 60) do
    DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:microsecond)
  end

  defp future_fire_at(seconds_ahead \\ 3600) do
    DateTime.utc_now() |> DateTime.add(seconds_ahead, :second) |> DateTime.truncate(:microsecond)
  end

  defp arm_timer!(schema_name, instance_id, overrides) do
    attrs =
      Map.merge(
        %{
          instance_id: instance_id,
          timer_type: "deadline",
          node_id: "timer-node",
          fire_at: past_fire_at()
        },
        overrides
      )

    assert {:ok, timer} = Scheduler.create(Letflow.Repo, attrs, prefix: schema_name)
    timer
  end

  defp fired_events_for(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "TIMER_FIRED")
    |> Repo.all(prefix: schema_name)
  end

  defp dlq_timer_entries_for(schema_name, timer_id) do
    Dlq.Entry
    |> where([d], d.entry_type == "timer" and d.reference_id == ^timer_id)
    |> Repo.all(prefix: schema_name)
  end

  defp put_scheduler_config(overrides) do
    original = Application.get_env(:letflow, :scheduler)
    Application.put_env(:letflow, :scheduler, overrides)

    ExUnit.Callbacks.on_exit(fn ->
      case original do
        nil -> Application.delete_env(:letflow, :scheduler)
        val -> Application.put_env(:letflow, :scheduler, val)
      end
    end)
  end

  # Raw-insert helper for AC2/AC3 (DB-level CHECK constraint tests) --
  # deliberately bypasses `Letflow.Scheduler.Timer`'s own changesets, which
  # never cast `status` at all (design §1's own "status is always forced to
  # pending" discipline) and have no recurrence-shape validation of their
  # own -- only a real INSERT proves the DB constraint itself is what stops
  # an invalid row, not some application-layer guard this schema doesn't
  # even have.
  defp raw_insert_timer(schema_name, overrides) do
    base = %{
      id: Ecto.UUID.generate(),
      tenant_id: Ecto.UUID.generate(),
      instance_id: Ecto.UUID.generate(),
      timer_type: "deadline",
      node_id: "raw-node",
      fire_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      status: "pending",
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    attrs = Map.merge(base, overrides)
    columns = Map.keys(attrs)
    col_list = Enum.map_join(columns, ", ", &to_string/1)
    placeholders = columns |> Enum.with_index(1) |> Enum.map_join(", ", fn {_c, i} -> "$#{i}" end)
    params = Enum.map(columns, fn c -> dump_param(Map.fetch!(attrs, c)) end)

    Repo.query(
      "INSERT INTO \"#{schema_name}\".timers (#{col_list}) VALUES (#{placeholders})",
      params
    )
  end

  # binary_id/uuid columns need Postgrex's raw 16-byte form via a plain
  # `Repo.query/3` (no Ecto type layer in between); `:utc_datetime_usec`
  # columns are stored as plain (timezone-less) `timestamp` -- Postgrex
  # expects `NaiveDateTime` for that column type, not `DateTime` directly.
  # Same idiom as `test/letflow/identity_migration_test.exs`'s own
  # `Ecto.UUID.dump!/1` usage for raw-SQL fixture inserts.
  defp dump_param(%DateTime{} = dt), do: DateTime.to_naive(dt)

  defp dump_param(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> binary
      :error -> value
    end
  end

  defp dump_param(value), do: value

  # ---------------------------------------------------------------------------------
  # AC1 -- timers migration: tenant-scoped, tenant_id retained, partial index
  # ---------------------------------------------------------------------------------

  describe "AC1: timers migration -- schema-per-tenant with tenant_id retained and the partial index" do
    test "the table exists in the tenant's own schema with a tenant_id column, and is absent from public" do
      %{schema_name: schema_name} = provisioned_tenant()

      %{rows: tenant_columns} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'timers'",
          [schema_name]
        )

      column_names = Enum.map(tenant_columns, fn [name] -> name end)
      assert "tenant_id" in column_names
      assert "id" in column_names
      assert "status" in column_names
      assert "fire_at" in column_names

      %{rows: public_rows} =
        Repo.query!(
          "SELECT 1 FROM information_schema.tables " <>
            "WHERE table_schema = 'public' AND table_name = 'timers'"
        )

      assert public_rows == []
    end

    test "carries the partial index idx_timers_pending_fire_at on (fire_at) WHERE status = 'pending'" do
      %{schema_name: schema_name} = provisioned_tenant()

      %{rows: [[indexdef]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes " <>
            "WHERE schemaname = $1 AND tablename = 'timers' AND indexname = 'idx_timers_pending_fire_at'",
          [schema_name]
        )

      assert indexdef =~ "fire_at"
      assert indexdef =~ ~r/status\)?::text\s*=\s*'pending'/
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- status CHECK constraint, DB-level
  # ---------------------------------------------------------------------------------

  describe "AC2: chk_timers_status rejects an out-of-domain status at the database level" do
    test "an insert with status 'expired' is rejected with a check_violation, not merely a changeset error" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               raw_insert_timer(schema_name, %{status: "expired"})

      %{rows: rows} = Repo.query!(~s(SELECT id FROM "#{schema_name}".timers), [])
      assert rows == []
    end

    test "each of the four admitted values inserts successfully" do
      %{schema_name: schema_name} = provisioned_tenant()

      for status <- ["pending", "fired", "cancelled", "failed"] do
        assert {:ok, %Postgrex.Result{num_rows: 1}} =
                 raw_insert_timer(schema_name, %{id: Ecto.UUID.generate(), status: status})
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- recurrence CHECK constraint, all-or-nothing
  # ---------------------------------------------------------------------------------

  describe "AC3: chk_timers_recurrence_shape is all-or-nothing" do
    test "repeat_expression alone (without repeat_interval_us) is rejected at the database level" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               raw_insert_timer(schema_name, %{repeat_expression: "R3/PT1H"})
    end

    test "all four recurrence columns populated consistently succeeds" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, %Postgrex.Result{num_rows: 1}} =
               raw_insert_timer(schema_name, %{
                 repeat_expression: "R3/PT1H",
                 repeat_interval_us: 3_600_000_000,
                 repeat_total: 3,
                 fired_count: 0
               })
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- past fire_at fires with fired_late: true; future fire_at does not
  # ---------------------------------------------------------------------------------

  describe "AC4: a past fire_at timer is fired by the first poll, marked fired_late" do
    test "the timer transitions to fired and the TIMER_FIRED event carries fired_late: true plus both timestamps" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      timer =
        arm_timer!(schema_name, instance_id, %{
          fire_at: past_fire_at(120),
          token_id: live_token_id!(schema_name, instance_id)
        })

      result = Scheduler.poll_and_fire(schema_name)

      assert result.claimed == 1
      assert result.fired == 1
      assert result.errored == 0
      assert result.exhausted == 0

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "fired"
      assert %DateTime{} = reloaded.fired_at

      assert [event] = fired_events_for(schema_name, instance_id)
      assert event.payload["fired_late"] == true
      assert is_binary(event.payload["scheduled_fire_at"])
      assert is_binary(event.payload["actual_fired_at"])
      assert event.payload["timer_id"] == timer.id
    end
  end

  describe "AC4: a future fire_at timer is NOT fired by that same poll" do
    test "the timer stays pending and no TIMER_FIRED event is appended" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)
      timer = arm_timer!(schema_name, instance_id, %{fire_at: future_fire_at()})

      result = Scheduler.poll_and_fire(schema_name)

      assert result.claimed == 0
      assert result.fired == 0

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "pending"
      assert reloaded.fired_at == nil

      assert fired_events_for(schema_name, instance_id) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- double-poll idempotency
  # ---------------------------------------------------------------------------------

  describe "AC5: polling twice over the same due timer fires it exactly once" do
    test "the second poll appends no second event and fired_at is unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      timer =
        arm_timer!(schema_name, instance_id, %{
          token_id: live_token_id!(schema_name, instance_id)
        })

      first = Scheduler.poll_and_fire(schema_name)
      assert first.fired == 1

      after_first = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert after_first.status == "fired"
      first_fired_at = after_first.fired_at

      second = Scheduler.poll_and_fire(schema_name)
      assert second.claimed == 0
      assert second.fired == 0

      after_second = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert after_second.status == "fired"
      assert DateTime.compare(after_second.fired_at, first_fired_at) == :eq

      assert length(fired_events_for(schema_name, instance_id)) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- a failing fire attempt increments fire_error_count, stays pending,
  # and does not stop the remaining due timers in the same cycle
  # ---------------------------------------------------------------------------------

  describe "AC6: a fire attempt that fails increments fire_error_count, stays pending, and the cycle continues" do
    test "the first of two due timers fails (no active instance to append its event against); the second still fires" do
      %{schema_name: schema_name} = provisioned_tenant()

      # No instance_projections row exists for this instance_id at all, so
      # fire_timer/2's lock prelude (Letflow.Engine.lock_for_timer_fire/3, GH #2707)
      # finds no projection row to lock and returns `{:error, :instance_not_found}`
      # before the timer row is even locked (formerly EventStore.append/2's own
      # active_instance_guard `{:error, :instance_not_started}`). fire_timer/2's
      # `Repo.rollback/1` surfaces it as a normal {:error, _} return from
      # `Repo.transaction/1` -- still a COUNTED failure, exactly the class
      # attempt_fire/2's `{:error, _reason} ->` branch exists to handle (design §2.5
      # step 3), the same branch a genuine raised exception is converted into by
      # attempt_fire/2's own outer try/rescue before reaching it. A projection that
      # EXISTS but is not :active is a different case: its timers are settled, not
      # counted (test/letflow/scheduler_dead_instance_timer_test.exs). See "AC6: a
      # raise inside fire_timer/2 itself never escapes attempt_fire/2" below for the
      # raise-specific half of this acceptance criterion.
      failing_instance_id = Ecto.UUID.generate()

      failing_timer =
        arm_timer!(schema_name, failing_instance_id, %{
          fire_at: past_fire_at(120),
          node_id: "fails"
        })

      ok_instance_id = start_instance!(schema_name)

      ok_timer =
        arm_timer!(schema_name, ok_instance_id, %{
          fire_at: past_fire_at(60),
          node_id: "ok",
          token_id: live_token_id!(schema_name, ok_instance_id)
        })

      result = Scheduler.poll_and_fire(schema_name)

      assert result.claimed == 2
      assert result.fired == 1
      assert result.errored == 1

      reloaded_failing = Repo.get!(Timer, failing_timer.id, prefix: schema_name)
      assert reloaded_failing.status == "pending"
      assert reloaded_failing.fire_error_count == 1

      reloaded_ok = Repo.get!(Timer, ok_timer.id, prefix: schema_name)
      assert reloaded_ok.status == "fired"
      assert length(fired_events_for(schema_name, ok_instance_id)) == 1
    end

    test "a raise inside fire_timer/2 itself never escapes attempt_fire/2" do
      %{schema_name: schema_name} = provisioned_tenant()

      # A syntactically invalid UUID for a :binary_id-typed column raises
      # Ecto.Query.CastError from inside fetch_and_lock_timer/2's own query
      # execution -- a genuine exception, not a returned {:error, _} tuple --
      # which propagates out of fire_timer/2's own Repo.transaction/1 call
      # (Ecto's own documented "an unhandled raise inside a transaction fun
      # rolls back and re-raises" behavior, cited by the design doc §2.4).
      # attempt_fire/2's outer try/rescue must catch it and return a normal
      # atom, never letting the exception propagate to this test process.
      assert Scheduler.attempt_fire("not-a-real-uuid", schema_name) == :errored
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- exhausting max fire retries lands exactly one dlq_entries row and
  # the timer is never attempted again
  # ---------------------------------------------------------------------------------

  describe "AC7: exhausting max_fire_retries transitions to failed with exactly one DLQ entry" do
    test "after max_fire_retries failed attempts the timer is failed, DLQ-landed once, and never reattempted" do
      put_scheduler_config(max_fire_retries: 2)

      %{schema_name: schema_name} = provisioned_tenant()
      failing_instance_id = Ecto.UUID.generate()
      timer = arm_timer!(schema_name, failing_instance_id, %{fire_at: past_fire_at(120)})

      first = Scheduler.poll_and_fire(schema_name)
      assert first.errored == 1
      assert first.exhausted == 0

      after_first = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert after_first.status == "pending"
      assert after_first.fire_error_count == 1

      second = Scheduler.poll_and_fire(schema_name)
      assert second.exhausted == 1
      assert second.errored == 0

      after_second = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert after_second.status == "failed"
      assert after_second.fire_error_count == 2
      assert %DateTime{} = after_second.failed_at

      assert [entry] = dlq_timer_entries_for(schema_name, timer.id)
      assert entry.entry_type == "timer"
      assert entry.instance_id == failing_instance_id

      third = Scheduler.poll_and_fire(schema_name)
      assert third.claimed == 0

      after_third = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert after_third.status == "failed"
      assert after_third.fire_error_count == 2

      assert length(dlq_timer_entries_for(schema_name, timer.id)) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- config defaults and override
  # ---------------------------------------------------------------------------------

  describe "AC8: scheduler config accessors -- documented defaults, and an override taking effect" do
    test "poll_interval_ms/jitter_ms/max_timers_per_cycle/max_fire_retries fall back to the documented defaults when unset" do
      assert Application.get_env(:letflow, :scheduler) == nil

      assert Scheduler.poll_interval_ms() == 5_000
      assert Scheduler.jitter_ms() == 0
      assert Scheduler.max_timers_per_cycle() == 64
      assert Scheduler.max_fire_retries() == 3
    end

    test "overriding :poll_interval_ms in application config is what poll_interval_ms/0 returns" do
      put_scheduler_config(poll_interval_ms: 1_234)

      assert Scheduler.poll_interval_ms() == 1_234
      # unrelated keys still fall back to their own defaults
      assert Scheduler.jitter_ms() == 0
      assert Scheduler.max_timers_per_cycle() == 64
      assert Scheduler.max_fire_retries() == 3
    end

    test "max_timers_per_cycle/0 is what claim_due_timer_ids/2 actually uses as its LIMIT" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      for n <- 1..3 do
        arm_timer!(schema_name, instance_id, %{fire_at: past_fire_at(120), node_id: "node-#{n}"})
      end

      assert length(Scheduler.claim_due_timer_ids(schema_name, 3)) == 3
      assert length(Scheduler.claim_due_timer_ids(schema_name, 2)) == 2
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0444 -- claim_due_timer_ids/2's/poll_and_fire/1's/run_retention_sweep/1's
  # own contracts against a tenant schema that is genuinely absent (a
  # `"tenant_" <> 32-hex-chars` string that passes
  # `TenantProvisioning.tenant_id_for_schema_name/1`'s format regex but has NO
  # physical `CREATE SCHEMA` ever run for it -- distinct from a present schema
  # missing only one table). See
  # `lib/letflow/design/iss0444-poller-schema-availability.md` §1/§4/§6. No
  # `provisioned_tenant/0` fixture involved -- these tests deliberately never
  # provision anything for `schema_name`.
  # ---------------------------------------------------------------------------------

  defp never_provisioned_schema_name do
    "tenant_" <> (Ecto.UUID.generate() |> String.replace("-", ""))
  end

  describe "ISS-0444: claim_due_timer_ids/2 against a genuinely-absent tenant schema" do
    test "returns [] instead of raising a Postgrex.Error, and logs a warning naming the schema" do
      schema_name = never_provisioned_schema_name()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Scheduler.claim_due_timer_ids(schema_name, 10) == []
        end)

      assert log =~ "tenant schema unavailable"
      assert log =~ schema_name
    end
  end

  describe "ISS-0444: poll_and_fire/1's own 'never raises' contract now holds for a genuinely-absent schema" do
    test "returns an all-zero poll_result() instead of raising, and logs a warning" do
      schema_name = never_provisioned_schema_name()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Scheduler.poll_and_fire(schema_name) == %{
                   tenant_schema: schema_name,
                   claimed: 0,
                   fired: 0,
                   errored: 0,
                   exhausted: 0
                 }
        end)

      assert log =~ "tenant schema unavailable"
    end
  end

  describe "ISS-0444: run_retention_sweep/1 against a genuinely-absent tenant schema" do
    test "returns {:error, {:schema_unavailable, _}} instead of raising, and logs a warning" do
      schema_name = never_provisioned_schema_name()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Scheduler.run_retention_sweep(schema_name) ==
                   {:error, {:schema_unavailable, schema_name}}
        end)

      assert log =~ "tenant schema unavailable"
      assert log =~ "retention sweep"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC9 -- no route or controller file added or modified (structural, no git
  # history dependency -- see test/letflow/dlq_test.exs's own AC6 comment for
  # why a hardcoded-commit-SHA git check is this project's own documented
  # anti-pattern)
  # ---------------------------------------------------------------------------------

  describe "AC9: REQ-186 added no route or controller construct" do
    test "neither Letflow.Scheduler nor Letflow.Scheduler.Timer references Plug/Router-shaped constructs" do
      for path <- ["lib/letflow/scheduler.ex", "lib/letflow/scheduler/timer.ex"] do
        source = File.read!(Path.join(File.cwd!(), path))
        refute source =~ ~r/use\s+Plug\.Router/, "#{path} unexpectedly uses Plug.Router"
        refute source =~ ~r/use\s+\w*Web,\s*:controller/, "#{path} unexpectedly is a controller"
        refute source =~ ~r/\bget\s+"\//, "#{path} unexpectedly defines a route"
      end
    end

    # SUPERSEDED by ISS-0389 (2026-09-05): at REQ-186 time no route exposed
    # the scheduler at all, so "no lib/letflow/api|routers file references
    # Letflow.Scheduler/timers" was a true and useful guard against a
    # premature route. ISS-0389 (design
    # `lib/letflow/design/iss0389-advance-timer-endpoint.md`) deliberately
    # adds the first such route -- `POST /instances/:id/advance-timer` in
    # `lib/letflow/routers/instances.ex`, calling
    # `Letflow.Scheduler.resolve_advance_target/3` and
    # `Letflow.Scheduler.fire_timer/2` -- reviewed and approved with that
    # reference in place, so the original blanket assertion is no longer
    # accurate and would flag intended, reviewed work as a regression. The
    # narrower guard above (no Plug.Router/controller/route construct
    # *inside* the scheduler modules themselves) still holds and is kept.
  end

  # ---------------------------------------------------------------------------------
  # ISS-0389 -- Letflow.Scheduler.resolve_advance_target/3 (design §3)
  #
  # Pure targeting-resolution query, no mutation and no engine re-entry (that
  # happens separately, in the caller's own follow-up `fire_timer/2` call --
  # see `lib/letflow/routers/instances.ex`'s `handle_advance_timer/2`). Every
  # branch below is exercised directly against `timers` rows, with no need
  # for a real started instance/live token (`resolve_advance_target/3` never
  # joins `instance_projections` or `tokens` -- confirmed by reading its own
  # `Timer |> where(...)` implementation, `lib/letflow/scheduler.ex`), so
  # these use bare `Ecto.UUID.generate()` instance ids, matching this file's
  # own documented "organic fire attempt fails" precedent in the moduledoc
  # above for tests that don't need a real engine-started instance.
  # ---------------------------------------------------------------------------------

  describe "ISS-0389: resolve_advance_target/3 -- timer_id absent (0/1/2+ pending)" do
    test "zero pending timers for the instance -> {:error, :no_pending_timer}" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      assert Scheduler.resolve_advance_target(instance_id, nil, schema_name) ==
               {:error, :no_pending_timer}
    end

    test "exactly one pending timer -> {:ok, timer}" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      timer = arm_timer!(schema_name, instance_id, %{})

      assert {:ok, resolved} = Scheduler.resolve_advance_target(instance_id, nil, schema_name)
      assert resolved.id == timer.id
    end

    test "a pending timer belonging to a DIFFERENT instance is not counted -- still 0 for this instance" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      other_instance_id = Ecto.UUID.generate()
      arm_timer!(schema_name, other_instance_id, %{})

      assert Scheduler.resolve_advance_target(instance_id, nil, schema_name) ==
               {:error, :no_pending_timer}
    end

    test "a non-pending (already fired) timer for the instance is not counted -- still 0" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      timer = arm_timer!(schema_name, instance_id, %{})

      assert {:ok, _} =
               timer
               |> Timer.fire_changeset(%{
                 status: "fired",
                 fired_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
               })
               |> Repo.update(prefix: schema_name)

      assert Scheduler.resolve_advance_target(instance_id, nil, schema_name) ==
               {:error, :no_pending_timer}
    end

    test "two or more pending timers -> {:error, :ambiguous_pending_timers}" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      arm_timer!(schema_name, instance_id, %{node_id: "timer-a"})
      arm_timer!(schema_name, instance_id, %{node_id: "timer-b"})

      assert Scheduler.resolve_advance_target(instance_id, nil, schema_name) ==
               {:error, :ambiguous_pending_timers}
    end
  end

  describe "ISS-0389: resolve_advance_target/3 -- timer_id present (same-404 fold)" do
    test "matches a real, pending timer on the same instance -> {:ok, timer}" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      timer = arm_timer!(schema_name, instance_id, %{})

      assert {:ok, resolved} =
               Scheduler.resolve_advance_target(instance_id, timer.id, schema_name)

      assert resolved.id == timer.id
    end

    test "timer_id does not exist at all -> {:error, :no_pending_timer}" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      assert Scheduler.resolve_advance_target(instance_id, Ecto.UUID.generate(), schema_name) ==
               {:error, :no_pending_timer}
    end

    test "timer_id exists but is not pending (already fired) -> {:error, :no_pending_timer}" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      timer = arm_timer!(schema_name, instance_id, %{})

      assert {:ok, _} =
               timer
               |> Timer.fire_changeset(%{
                 status: "fired",
                 fired_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
               })
               |> Repo.update(prefix: schema_name)

      assert Scheduler.resolve_advance_target(instance_id, timer.id, schema_name) ==
               {:error, :no_pending_timer}
    end

    test "timer_id exists, is pending, but belongs to a DIFFERENT instance -> {:error, :no_pending_timer} (cross-instance guard)" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_a = Ecto.UUID.generate()
      instance_b = Ecto.UUID.generate()
      timer = arm_timer!(schema_name, instance_a, %{})

      assert Scheduler.resolve_advance_target(instance_b, timer.id, schema_name) ==
               {:error, :no_pending_timer}
    end
  end
end
