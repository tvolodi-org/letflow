defmodule Letflow.EventStoreColdAppendLockOrderTest do
  @moduledoc """
  GH #2707 / PR-2 (design `lib/letflow/design/gh2707-timer-fire-and-cold-appenders-lock-order.md`
  sections 7 and 8.3; decision 0061 "Amended (GH #2707, PR-2)", invariant I-S):
  `Letflow.EventStore.append/2` locks the instance's projection row `P_x` (`FOR NO KEY UPDATE`)
  in its first step, BEFORE the sequence row `S_x`, so the cold appenders (attachment events, a
  Lua `emit_event`) take the same order as every engine writer.

    * A0: statement order of `append/2`; `append_multi/3` keeps its unlocked guard;
    * A1 (C7): a cold append against `set_instance_error/2`, barrier on `S_x` (the deadlock cycle);
    * A3: semantics (terminal, missing, duplicate key) are unchanged;
    * R1: a cold append racing a cancel gets `{:instance_terminated, :cancelled}` and never
      writes after the terminal event;
    * S1: an entity-type synthetic instance is NEVER locked by `append/2` (rule 5);
    * L1: the `:lock_timeout_ms` option (bound parameter, default off, `{:error, :contention}`);
    * L2: the attachment-event caller swallows the bounded wait (existing log-and-swallow path);
    * L3: a Lua `emit_event` (a Task process, another connection) against a held `P_x` either
      succeeds or fails with a script-visible error within the bound; it never hangs.

  The census of every `append/2` caller flow (A2) is `event_store_append_census_test.exs`.
  Forced-overlap method: `Letflow.LockOrderHelpers`. Sandbox `:auto` mode, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Engine.Contention
  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Repository.Attachments
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)

    base = Fx.committed_tenant_case!("gh2707-cold")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    %{base: base}
  end

  # ---- fixtures ---------------------------------------------------------------------------------

  defp human_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "h", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "h"},
        %{"id" => "e2", "source" => "h", "target" => "end"}
      ]
    }
  end

  defp instance!(base) do
    definition = Fx.legacy_activate!(base.schema, base.user, human_graph(), [])

    {:ok, %{instance_id: id}} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("cold-start")
        },
        prefix: base.schema
      )

    id
  end

  defp attach_attrs(base, instance_id, key \\ nil) do
    %{
      instance_id: instance_id,
      event_type: "ATTACHMENT_ATTACHED",
      payload:
        Jason.encode!(%{
          attachment_id: Ecto.UUID.generate(),
          file_name: "a.txt",
          content_type: "text/plain",
          byte_size: 1
        }),
      actor_id: base.user.id,
      idempotency_key: key || Fx.unique("cold-attach")
    }
  end

  defp cold_append_fn(base, instance_id, opts \\ []) do
    fn -> EventStore.append(attach_attrs(base, instance_id), [prefix: base.schema] ++ opts) end
  end

  defp set_error_fn(base, instance_id) do
    fn ->
      Engine.set_instance_error(
        %{
          instance_id: instance_id,
          error_type: :variable_schema_rejected,
          affected: {:field, "approved"},
          reason: "rejected",
          variables: %{},
          details: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("cold-set")
        },
        prefix: base.schema
      )
    end
  end

  defp cancel_fn(base, instance_id) do
    fn ->
      Engine.cancel_instance(
        instance_id,
        %{actor_id: base.user.id, idempotency_key: Fx.unique("cold-cancel")},
        prefix: base.schema
      )
    end
  end

  defp event_types(base, instance_id) do
    Repo.all(
      from(e in Event,
        where: e.instance_id == ^instance_id,
        order_by: e.sequence_number,
        select: e.event_type
      ),
      prefix: base.schema
    )
  end

  defp projection_seq(base, instance_id),
    do: Fx.projection!(base.schema, instance_id).last_event_seq

  defp index_of(queries, pred), do: Enum.find_index(queries, pred)

  defp release!(holder) do
    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, H.await_ms())
  end

  # `NOWAIT` probe of a projection row from the test connection: `:locked` when another
  # transaction holds the row in a mode that conflicts with FOR UPDATE.
  defp probe_projection(base, instance_id) do
    sql =
      ~s(SELECT 1 FROM "#{base.schema}"."instance_projections" WHERE instance_id = $1 ) <>
        "FOR UPDATE NOWAIT"

    case Repo.query(sql, [Ecto.UUID.dump!(instance_id)]) do
      {:ok, _} -> :free
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> :locked
    end
  end

  # wait (bounded) until `pid` is blocked on a lock
  defp await_blocked(pid), do: H.wait_for_blocked([pid], 1)

  # wait (bounded) until some OTHER backend is blocked by the barrier backend (the emit Task or any
  # worker whose pid the test does not know), then return its pid
  defp await_blocked_by(barrier_pid) do
    deadline = System.monotonic_time(:millisecond) + 3_000

    Stream.repeatedly(fn ->
      %{rows: rows} =
        Repo.query!(
          "SELECT pid FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
          [barrier_pid]
        )

      if rows == [] and System.monotonic_time(:millisecond) < deadline, do: Process.sleep(10)
      rows
    end)
    |> Enum.find(fn rows -> rows != [] or System.monotonic_time(:millisecond) >= deadline end)
    |> case do
      [[pid] | _] -> pid
      _ -> flunk("no backend became blocked by the barrier holder")
    end
  end

  # BEFORE UPDATE trigger on the tenant's projections raising the given SQLSTATE: a deterministic
  # stand-in for a lock timeout / deadlock victim on the append's last statement
  defp inject_projection_error!(base, sqlstate) do
    schema = base.schema

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".gh2707_boom() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN RAISE EXCEPTION 'injected' USING ERRCODE = '#{sqlstate}'; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER gh2707_boom BEFORE UPDATE ON "#{schema}".instance_projections | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".gh2707_boom()|
    )
  end

  defp flush_contention_reports do
    receive do
      {:deadlock_detected, _} -> flush_contention_reports()
    after
      0 -> :ok
    end
  end

  # ---- A0 ---------------------------------------------------------------------------------------

  describe "A0: statement order" do
    test "append/2 locks the projection FOR NO KEY UPDATE before the sequence row", %{base: base} do
      x = instance!(base)

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(cold_append_fn(base, x))

      assert {:ok, %{is_duplicate: false}} = result

      guard =
        index_of(queries, fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR NO KEY UPDATE" and
            q.query =~ "SELECT"
        end)

      sequence = index_of(queries, &(&1.query =~ ~r/"instance_sequence"/))
      projection_update = index_of(queries, &(&1.query =~ ~r/\AUPDATE .*"instance_projections"/))

      assert is_integer(guard), inspect(Enum.map(queries, & &1.query), limit: :infinity)
      assert guard < sequence, "P_x must be locked BEFORE the sequence row"
      assert sequence < projection_update

      refute Enum.any?(
               queries,
               &(&1.query =~ ~r/FOR UPDATE/ and &1.query =~ "instance_projections")
             ),
             "the cold guard must be FOR NO KEY UPDATE, never an upgrade to FOR UPDATE"

      assert Enum.at(queries, guard).query =~ "FOR NO KEY UPDATE"
    end

    test "append_multi/3 keeps the UNLOCKED guard (rule 5 for entity-type streams)", %{base: base} do
      x = instance!(base)

      {:ok, multi} =
        EventStore.append_multi(Ecto.Multi.new(), attach_attrs(base, x), prefix: base.schema)

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> Repo.transaction(multi) end)

      assert {:ok, _} = result

      guard =
        index_of(queries, fn q ->
          q.query =~ ~r/FROM "[^"]+"\."instance_projections"/ and q.query =~ "SELECT"
        end)

      assert is_integer(guard)
      refute Enum.at(queries, guard).query =~ ~r/FOR (NO KEY )?UPDATE/
    end
  end

  # ---- A1 (C7) ----------------------------------------------------------------------------------

  describe "A1 (C7): the cold appender against a completer-style writer" do
    test "append parks at the barrier on S_x holding P_x; set_instance_error queues behind it; no cycle",
         %{base: base} do
      x = instance!(base)

      overlap =
        H.forced_overlap(
          base.schema,
          {:sequence, x},
          cold_append_fn(base, x),
          set_error_fn(base, x)
        )

      assert {:ok, %{is_duplicate: false}} = overlap.first
      assert {:ok, _} = overlap.second
      types = event_types(base, x)
      assert "ATTACHMENT_ATTACHED" in types
      assert "EXECUTION_ERROR" in types
      assert H.margin_ms(overlap.timing) >= 500
    end
  end

  # ---- A3 ---------------------------------------------------------------------------------------

  describe "A3: semantics unchanged" do
    test "terminal, missing and duplicate", %{base: base} do
      x = instance!(base)

      first = cold_append_fn(base, x).()
      assert {:ok, %{is_duplicate: false, sequence_number: seq}} = first
      {:ok, %{event: original}} = first

      key = original.idempotency_key
      before = {event_types(base, x), projection_seq(base, x)}

      assert {:ok, %{is_duplicate: true, sequence_number: ^seq}} =
               EventStore.append(attach_attrs(base, x, key), prefix: base.schema)

      assert before == {event_types(base, x), projection_seq(base, x)}

      assert {:error, :instance_not_started} =
               EventStore.append(attach_attrs(base, Ecto.UUID.generate()), prefix: base.schema)

      assert {:ok, _} = cancel_fn(base, x).()
      after_cancel = {event_types(base, x), projection_seq(base, x)}

      assert {:error, {:instance_terminated, :cancelled}} = cold_append_fn(base, x).()
      assert after_cancel == {event_types(base, x), projection_seq(base, x)}
    end
  end

  # ---- R1 ---------------------------------------------------------------------------------------

  describe "R1: a cold append racing a cancel" do
    test "the append sees the terminal status on the locked row and writes nothing", %{base: base} do
      x = instance!(base)

      # barrier on P_x: the cancel parks first, the cold append second; the cancel gets P_x first
      overlap =
        H.forced_overlap(
          base.schema,
          {:projection, x},
          cancel_fn(base, x),
          cold_append_fn(base, x)
        )

      assert {:ok, _} = overlap.first
      assert {:error, {:instance_terminated, :cancelled}} = overlap.second

      types = event_types(base, x)
      assert List.last(types) == "INSTANCE_CANCELLED", "no event after the terminal event"
      refute "ATTACHMENT_ATTACHED" in types
    end
  end

  # ---- S1 ---------------------------------------------------------------------------------------

  describe "S1: entity-type synthetic instances are never locked by append/2" do
    test "the projection of a synthetic instance is not held while append/2 waits on its S_s",
         %{base: base} do
      {:ok, synthetic} = EntityTypeInstance.get_or_create("widget", base.schema)
      # the sequence row must exist for the barrier
      assert {:ok, _} = cold_append_fn(base, synthetic).()
      x = instance!(base)

      # control: a workflow instance IS held (FOR NO KEY UPDATE) while its append waits on S_x
      {holder_x, _} = H.hold_row(base.schema, {:sequence, x})
      {task_x, pid_x} = H.start_worker(cold_append_fn(base, x))
      await_blocked(pid_x)
      assert probe_projection(base, x) == :locked
      release!(holder_x)
      assert {{:ok, _}, _} = Task.await(task_x, H.await_ms())

      # the synthetic stream: append/2 waits on S_s but does NOT hold P_s (the row exists, so a
      # :free probe is not vacuous)
      assert Fx.projection!(base.schema, synthetic).instance_id == synthetic
      {holder_s, _} = H.hold_row(base.schema, {:sequence, synthetic})
      {task_s, pid_s} = H.start_worker(cold_append_fn(base, synthetic))
      await_blocked(pid_s)
      assert probe_projection(base, synthetic) == :free
      release!(holder_s)
      assert {{:ok, _}, _} = Task.await(task_s, H.await_ms())
      flush_contention_reports()
    end

    test "append/2 on a synthetic instance still appends (guard falls back to the plain read)",
         %{base: base} do
      {:ok, synthetic} = EntityTypeInstance.get_or_create("gadget", base.schema)

      assert {:ok, %{is_duplicate: false}} = cold_append_fn(base, synthetic).()
      assert event_types(base, synthetic) == ["ATTACHMENT_ATTACHED"]
    end
  end

  # ---- L1 ---------------------------------------------------------------------------------------

  describe "L1: the :lock_timeout_ms option" do
    test "statement trace: set_config first, one bound parameter, nothing without the option",
         %{base: base} do
      x = instance!(base)

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(cold_append_fn(base, x, lock_timeout_ms: 300))

      assert {:ok, _} = result
      statements = Enum.map(queries, & &1.query)
      begin = Enum.find_index(statements, &(&1 == "begin"))
      assert is_integer(begin)
      assert Enum.at(statements, begin + 1) == "SELECT set_config('lock_timeout', $1, true)"
      assert %{params: ["300ms"]} = Enum.at(queries, begin + 1)
      refute Enum.any?(statements, &(&1 =~ "300"))
      assert Enum.at(statements, begin + 2) =~ "FOR NO KEY UPDATE"

      {_, plain} = PlatformTenantFixture.capture_repo_queries(cold_append_fn(base, x))
      refute Enum.any?(plain, &(&1.query =~ "set_config"))
    end

    test "a wait beyond the bound returns {:error, :contention}, within the bound, writing nothing",
         %{base: base} do
      x = instance!(base)
      before = {event_types(base, x), projection_seq(base, x)}
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      append = cold_append_fn(base, x, lock_timeout_ms: 300)

      {task, _pid} =
        H.start_worker(fn ->
          started = System.monotonic_time(:millisecond)
          result = append.()
          {result, System.monotonic_time(:millisecond) - started}
        end)

      {{result, elapsed}, _finished} = Task.await(task, 5_000)

      assert result == {:error, :contention}

      assert elapsed >= 250,
             "the append waited for the bound (#{elapsed} ms), it did not fail early"

      assert elapsed < 1_500,
             "the wait is bounded by the option, not by the holder (#{elapsed} ms)"

      release!(holder)
      flush_contention_reports()
      assert before == {event_types(base, x), projection_seq(base, x)}
    end

    test "without the option the same append waits for the holder (other callers unchanged)",
         %{base: base} do
      x = instance!(base)
      {holder, _} = H.hold_row(base.schema, {:projection, x})
      {task, pid} = H.start_worker(cold_append_fn(base, x))
      await_blocked(pid)
      # still parked well past the bound the option would have used
      Process.sleep(400)
      assert Task.yield(task, 0) == nil
      release!(holder)
      assert {{:ok, %{is_duplicate: false}}, _} = Task.await(task, H.await_ms())
    end

    test "an invalid value is a programmer error", %{base: base} do
      x = instance!(base)

      for bad <- [0, -1, "300", 1.5] do
        assert_raise ArgumentError, ~r/lock_timeout_ms/, fn ->
          EventStore.append(attach_attrs(base, x), prefix: base.schema, lock_timeout_ms: bad)
        end
      end
    end

    test "nested in a caller's transaction the option is a no-op (no set-config, outer setting kept)",
         %{base: base} do
      x = instance!(base)

      {{outer_before, result, outer_after}, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Repo.transaction(fn ->
            before = Repo.query!("SHOW lock_timeout").rows
            appended = cold_append_fn(base, x, lock_timeout_ms: 300).()
            {before, appended, Repo.query!("SHOW lock_timeout").rows}
          end)
          |> elem(1)
        end)

      assert {:ok, %{is_duplicate: false}} = result
      assert outer_before == outer_after
      refute outer_after == [["300ms"]]
      refute Enum.any?(queries, &(&1.query =~ "set_config"))
    end

    test "a 40P01 under the option makes the cold append the victim: {:error, :contention}, nothing written",
         %{base: base} do
      x = instance!(base)
      before = {event_types(base, x), projection_seq(base, x)}
      inject_projection_error!(base, "40P01")

      assert {:error, :contention} = cold_append_fn(base, x, lock_timeout_ms: 300).()
      flush_contention_reports()
      assert before == {event_types(base, x), projection_seq(base, x)}

      assert Contention.contention_code(%Postgrex.Error{postgres: %{code: :deadlock_detected}}) ==
               {:ok, :deadlock_detected}
    end

    test "without the option the same deadlock still raises", %{base: base} do
      x = instance!(base)
      inject_projection_error!(base, "40P01")

      assert_raise Postgrex.Error, ~r/injected/, cold_append_fn(base, x)
      flush_contention_reports()
    end

    test "a non-contention database error still raises under the option", %{base: base} do
      x = instance!(base)
      inject_projection_error!(base, "22012")

      assert_raise Postgrex.Error, ~r/injected/, cold_append_fn(base, x, lock_timeout_ms: 300)
    end
  end

  # ---- L2 ---------------------------------------------------------------------------------------

  describe "L2: the attachment-event caller" do
    test "a bounded wait on P_x is logged and swallowed; upload/2 still returns {:ok, _}",
         %{base: base} do
      x = instance!(base)
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      log =
        capture_log(fn ->
          {task, _pid} =
            H.start_worker(fn ->
              Process.put(:cold_append_lock_timeout_ms_override, 300)

              Attachments.upload(
                %{
                  instance_id: x,
                  raw_bytes: "hello",
                  file_name: "n.txt",
                  content_type: "text/plain",
                  uploaded_by: base.user.id,
                  description: nil
                },
                prefix: base.schema
              )
            end)

          {result, _} = Task.await(task, 5_000)
          assert {:ok, _attachment} = result
        end)

      release!(holder)
      flush_contention_reports()
      assert log =~ "attachment history event not recorded: ATTACHMENT_ATTACHED"
      refute "ATTACHMENT_ATTACHED" in event_types(base, x)
    end
  end

  describe "L2b: Attachments.delete/3" do
    test "a bounded wait on P_x is logged and swallowed; delete/3 still returns {:ok, _}",
         %{base: base} do
      x = instance!(base)

      assert {:ok, attachment} =
               Attachments.upload(
                 %{
                   instance_id: x,
                   raw_bytes: "hello",
                   file_name: "n.txt",
                   content_type: "text/plain",
                   uploaded_by: base.user.id,
                   description: nil
                 },
                 prefix: base.schema
               )

      {holder, _} = H.hold_row(base.schema, {:projection, x})

      log =
        capture_log(fn ->
          {task, _pid} =
            H.start_worker(fn ->
              Process.put(:cold_append_lock_timeout_ms_override, 300)
              Attachments.delete(attachment.id, base.user.id, prefix: base.schema)
            end)

          {result, _} = Task.await(task, 5_000)
          assert {:ok, _deleted} = result
        end)

      release!(holder)
      flush_contention_reports()
      assert log =~ "attachment history event not recorded: ATTACHMENT_REMOVED"
      refute "ATTACHMENT_REMOVED" in event_types(base, x)
    end
  end

  # ---- L3 ---------------------------------------------------------------------------------------

  describe "L3: Lua emit_event against a held P_x" do
    # The nearest REAL flow: no production route installs a granted execution context (the
    # executor's script body is `Sandbox.new/1` with no grants), so the script is run the way the
    # executor runs it, in a process of the Lua Task.Supervisor on its own connection, with
    # `Platform.install/3` granting `event:emit`; the barrier on `P_x` plays the dispatcher / any
    # writer holding the instance row.
    defp run_script_task(base, x, timeout_override_ms) do
      script = """
      local ok, err = platform.emit_event('ATTACHMENT_ATTACHED', {attachment_id = 'a1', file_name = 'f', content_type = 't', byte_size = 1}, 'lua-key')
      if ok then return true end
      return nil, err.reason
      """

      Task.Supervisor.async_nolink(Letflow.Engine.Lua.TaskSupervisor, fn ->
        started = System.monotonic_time(:millisecond)
        Process.put(:cold_append_lock_timeout_ms_override, timeout_override_ms)

        lua =
          Platform.install(
            Sandbox.new(),
            Capabilities.new(["event:emit"]),
            Map.merge(Platform.empty_execution_context(), %{
              instance_id: x,
              prefix: base.schema,
              actor_id: base.user.id
            })
          )

        {values, _lua} = Lua.eval!(lua, script)
        {values, System.monotonic_time(:millisecond) - started}
      end)
    end

    test "held beyond the bound: a script-visible error within the bound, nothing written",
         %{base: base} do
      x = instance!(base)
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      task = run_script_task(base, x, 300)

      {result, elapsed} =
        case Task.yield(task, 3_000) do
          {:ok, {values, elapsed}} ->
            {values, elapsed}

          nil ->
            Task.shutdown(task, :brutal_kill)
            flunk("emit_event hung past the bound")
        end

      release!(holder)
      flush_contention_reports()

      assert result == [nil, "contention"]
      assert elapsed >= 250, "the emit waited for the bound (#{elapsed} ms)"
      assert elapsed < 1_500, "bounded by the option (#{elapsed} ms)"
      refute "ATTACHMENT_ATTACHED" in event_types(base, x)
    end

    test "released within the bound: the emit succeeds", %{base: base} do
      x = instance!(base)
      {holder, barrier_pid} = H.hold_row(base.schema, {:projection, x})
      task = run_script_task(base, x, 5_000)

      # release only once the emit is really parked on the barrier
      await_blocked_by(barrier_pid)
      release!(holder)

      assert {:ok, {[true], _elapsed}} =
               Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)

      assert "ATTACHMENT_ATTACHED" in event_types(base, x)
      flush_contention_reports()
    end
  end
end
