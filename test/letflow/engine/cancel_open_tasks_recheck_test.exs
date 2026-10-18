defmodule Letflow.Engine.CancelOpenTasksRecheckTest do
  @moduledoc """
  GH #2706 / PR-1 (design `lib/letflow/design/gh2706-cancel-snapshot-and-lock-timeouts.md`
  sections 1, 2, 6; decision 0061, "Amended (GH #2706, PR-1)"): `cancel_instance/3` reads the
  instance's open tasks `FOR UPDATE` BEFORE the projection lock (class 1), so a task that a
  concurrent writer inserts while the cancel waits was never seen. The fix adds a second,
  non-waiting read (`FOR UPDATE SKIP LOCKED`) after `P_x` and the ancestor group.

    * R1: a HUMAN completion of the same instance inserts task B while the cancel is blocked on
      the completed task A (RED on main: B stays `:pending` on a cancelled instance);
    * R2: the same through a sub-process cascade (the parent's next task B);
    * P1: the INSTANCE_CANCELLED payload and the result list exactly the tasks cancelled;
    * L1 / L1b: the leftover (a straggler held by a completer queued behind the cancel at `P_x`):
      abort, roll back, retry, no deadlock; L1b where the straggler's completion ends the
      instance (the retry finds it terminal);
    * O1: statement order (the SKIP LOCKED re-read follows `P_x` and the ancestor group, no
      waiting task lock after `P_x`, an ineligible cancel issues none);
    * N1: a cancel nested in a caller's transaction returns the typed error at once (no retry)
      and the OUTER transaction is rollback-only;
    * H1: the route maps `{:error, :cancel_contention}` to HTTP 503 with a constant body. The
      route module is called directly with a hand-assigned `auth_context` (the policy enforcement
      of the `authz_post` pipeline is covered elsewhere), and the retry exhaustion is SIMULATED by
      nesting the call in an outer transaction (no retry is allowed there), not reached by real
      attempts; the cap itself is unit-tested in `cancel_attempts_loop_test.exs`.

  Forced-overlap method: `Letflow.LockOrderHelpers`. Sandbox `:auto`, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)

    base = Fx.committed_tenant_case!("gh2706-pr1")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    %{base: base}
  end

  # ---- graphs and fixtures ----------------------------------------------------------------------

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp human(id),
    do: %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}}

  # START -> ids (HUMAN, in order) -> END
  defp seq_graph(ids) do
    chain = ["start"] ++ ids ++ ["end"]

    %{
      "nodes" =>
        [%{"id" => "start", "node_type" => "START"}] ++
          Enum.map(ids, &human/1) ++
          [%{"id" => "end", "node_type" => "END"}],
      "edges" =>
        chain
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.with_index(1)
        |> Enum.map(fn {[s, t], i} -> edge("e#{i}", s, t) end)
    }
  end

  defp parent_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        human("hp"),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("p1", "start", "sp"), edge("p2", "sp", "hp"), edge("p3", "hp", "end")]
    }
  end

  defp started!(base, ids) do
    definition = Fx.activate!(base.schema, base.user, seq_graph(ids))
    {instance_id, task_a} = Fx.start!(base.schema, definition)
    {instance_id, task_a}
  end

  defp complete_fn(base, task_id) do
    fn ->
      Engine.complete_task(
        task_id,
        %{
          output_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("gh2706-complete")
        },
        prefix: base.schema
      )
    end
  end

  defp cancel_fn(base, instance_id) do
    fn ->
      Engine.cancel_instance(
        instance_id,
        %{actor_id: base.user.id, idempotency_key: Fx.unique("gh2706-cancel")},
        prefix: base.schema
      )
    end
  end

  defp tasks_of(schema, instance_id) do
    Repo.all(
      from(t in EngineTask, where: t.instance_id == ^instance_id, order_by: [asc: t.inserted_at]),
      prefix: schema
    )
  end

  defp task_at!(schema, instance_id, node_id) do
    [task] = Enum.filter(tasks_of(schema, instance_id), &(&1.node_id == node_id))
    task
  end

  defp pending_ids(schema, instance_id),
    do: for(t <- tasks_of(schema, instance_id), t.status == :pending, do: t.id)

  # The persisted INSTANCE_CANCELLED payload, the result and the rows really cancelled by this
  # cancel (same `cancelled_at`) must be the same set of task ids.
  defp assert_payload!(schema, instance_id, %{cancelled_task_ids: result_ids} = result) do
    [event] = Fx.instance_events(schema, instance_id, "INSTANCE_CANCELLED")
    payload = if is_binary(event.payload), do: Jason.decode!(event.payload), else: event.payload

    cancelled_rows =
      Repo.all(
        from(t in EngineTask,
          where:
            t.instance_id == ^instance_id and t.status == :cancelled and
              t.cancelled_at == ^result.cancelled_at,
          select: t.id
        ),
        prefix: schema
      )

    assert Enum.sort(payload["cancelled_task_ids"]) == Enum.sort(cancelled_rows)
    assert Enum.sort(result_ids) == Enum.sort(cancelled_rows)
    cancelled_rows
  end

  defp assert_margin!(overlap) do
    margin = H.margin_ms(overlap.timing)

    assert margin >= 500,
           "lock_timeout margin #{margin} ms is under 500 ms (#{inspect(overlap.timing)})"
  end

  # ---- R1 / P1 ----------------------------------------------------------------------------------

  describe "R1: same-instance HUMAN completion inserts B while the cancel waits on A" do
    test "task B is cancelled, listed in the result and in the event payload", %{base: base} do
      {x, task_a} = started!(base, ["a", "b"])

      # worker 1 completes A (holds A and P_x, inserts B, parks at S_x); worker 2 cancels (class-1
      # read blocks on A)
      overlap =
        H.forced_overlap(
          base.schema,
          {:sequence, x},
          complete_fn(base, task_a.id),
          cancel_fn(base, x)
        )

      assert {:ok, _} = overlap.first
      assert {:ok, %{cancelled_task_ids: ids} = result} = overlap.second, inspect(overlap.second)

      task_b = task_at!(base.schema, x, "b")
      assert task_b.status == :cancelled, "B left #{task_b.status} on a cancelled instance"
      assert task_b.id in ids
      assert pending_ids(base.schema, x) == []
      assert Fx.projection!(base.schema, x).status == :cancelled

      # no live token is left either
      assert Repo.aggregate(
               from(t in TokenRecord,
                 where: t.instance_id == ^x and t.status in [:active, :waiting]
               ),
               :count,
               prefix: base.schema
             ) == 0

      # P1: result == event payload == rows cancelled by this cancel, B included
      assert task_b.id in assert_payload!(base.schema, x, result)
      assert_margin!(overlap)
    end
  end

  # ---- R2 ---------------------------------------------------------------------------------------

  describe "R2: sub-process cascade inserts the parent's next task B while cancel(parent) waits" do
    test "task B is cancelled and the parent's tokens are cancelled", %{base: base} do
      child_def = Fx.activate!(base.schema, base.user, seq_graph(["h1"]))
      parent_def = Fx.activate!(base.schema, base.user, parent_graph(child_def.name))

      {:ok, %{instance_id: p}} =
        Engine.create(
          %{
            definition_id: parent_def.id,
            initial_variables: %{},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("gh2706-start")
          },
          prefix: base.schema
        )

      child =
        Repo.one!(from(i in InstanceProjection, where: i.parent_instance_id == ^p),
          prefix: base.schema
        )

      child_task = Fx.pending_task!(base.schema, child.instance_id)
      assert pending_ids(base.schema, p) == []

      # worker 1: the child's last task: holds P_c and the group, inserts the parent's task B,
      # parks at S_p; worker 2: cancel(parent) sees no task, parks at P_p
      overlap =
        H.forced_overlap(
          base.schema,
          {:sequence, p},
          complete_fn(base, child_task.id),
          cancel_fn(base, p)
        )

      assert {:ok, _} = overlap.first
      assert {:ok, %{cancelled_task_ids: ids} = result} = overlap.second, inspect(overlap.second)

      task_b = task_at!(base.schema, p, "hp")
      assert task_b.status == :cancelled, "B left #{task_b.status} on a cancelled parent"
      assert task_b.id in ids
      assert pending_ids(base.schema, p) == []
      assert Fx.projection!(base.schema, p).status == :cancelled

      assert Repo.aggregate(
               from(t in TokenRecord,
                 where: t.instance_id == ^p and t.status in [:active, :waiting]
               ),
               :count,
               prefix: base.schema
             ) == 0

      assert task_b.id in assert_payload!(base.schema, p, result)
      assert_margin!(overlap)
    end
  end

  # ---- the straggler scenarios (L1, L1b, N1, H1) ------------------------------------------------

  # Task B (and its token at node "b") inserted straight into the tables, as the committed result
  # of a completer of A that the cancel's class-1 snapshot never saw. `end_a_token?` additionally
  # finishes A's token (L1b), so that completing B ends the instance.
  defp insert_straggler!(schema, instance_id, task_a, end_a_token?) do
    token_a = Repo.get!(TokenRecord, task_a.token_id, prefix: schema)

    if end_a_token? do
      Repo.update_all(
        from(t in TokenRecord, where: t.id == ^token_a.id),
        [set: [status: :completed, completed_at: DateTime.utc_now()]],
        prefix: schema
      )
    end

    token_b =
      %TokenRecord{}
      |> TokenRecord.insert_changeset(%{
        instance_id: instance_id,
        node_id: "b",
        branch_id: "straggler-branch",
        status: :active
      })
      |> Repo.insert!(prefix: schema)

    %EngineTask{}
    |> EngineTask.insert_changeset(%{
      instance_id: instance_id,
      token_id: token_b.id,
      node_id: "b",
      node_name: "b",
      assignee_type: task_a.assignee_type,
      assignee_ref: task_a.assignee_ref,
      form_schema: task_a.form_schema
    })
    |> Repo.insert!(prefix: schema)
  end

  # Polls until `waiter` is blocked behind `blocker` (monotonic deadline).
  defp wait_blocked_by!(waiter, blocker) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_wait_blocked_by(waiter, blocker, deadline)
  end

  defp do_wait_blocked_by(waiter, blocker, deadline) do
    cond do
      blocker in H.blockers(waiter) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("backend #{waiter} never queued behind #{blocker}")

      true ->
        Process.sleep(10)
        do_wait_blocked_by(waiter, blocker, deadline)
    end
  end

  # Runs `fun` in the worker's own process and returns `{result, statements}` (the telemetry
  # handler runs in the process that issues the query, so this traces the cancel's backend).
  defp traced(fun), do: fn -> PlatformTenantFixture.capture_repo_queries(fun) end

  defp class1_task_reads(queries, schema) do
    Enum.count(queries, fn q ->
      q.query =~ ~s(FROM "#{schema}"."tasks") and q.query =~ "FOR UPDATE" and
        not (q.query =~ "SKIP LOCKED")
    end)
  end

  # The pinned order of design section 6 (L1). Returns the worker results and the ids.
  defp leftover_overlap!(base, ids, end_a_token?) do
    schema = base.schema
    {x, task_a} = started!(base, ids)

    # (1) hold task A; (2) the cancel's class-1 read blocks on A
    {holder_a, _} = H.hold_row(schema, {:task, task_a.id})
    {cancel_task, cancel_pid} = H.start_worker(traced(cancel_fn(base, x)))
    H.wait_for_blocked([cancel_pid], 1)

    # (3) the straggler B appears (P_x is free); (4) a second barrier on P_x
    task_b = insert_straggler!(schema, x, task_a, end_a_token?)
    {holder_p, barrier_p} = H.hold_row(schema, {:projection, x})

    # (5) release A: the cancel advances and queues at P_x, first in line. Its (conservative)
    # wait clock starts here: the margin is measured from this instant, not from the P_x release.
    cancel_waiting_at = System.monotonic_time(:millisecond)
    send(holder_a.pid, :release)
    assert {:ok, _} = Task.await(holder_a, H.await_ms())
    wait_blocked_by!(cancel_pid, barrier_p)

    # (6) W = complete(B): locks B, queues at P_x AFTER the cancel
    {w_task, w_pid} = H.start_worker(complete_fn(base, task_b.id))
    H.wait_for_blocked([cancel_pid, w_pid], 2)
    assert Enum.any?(H.blockers(w_pid), &(&1 in [barrier_p, cancel_pid]))

    # (7) release P_x: FIFO gives it to the cancel
    send(holder_p.pid, :release)
    assert {:ok, _} = Task.await(holder_p, H.await_ms())

    {{cancel_result, queries}, cancel_done_at} = Task.await(cancel_task, H.await_ms())
    {w_result, w_done_at} = Task.await(w_task, H.await_ms())

    refute_receive {:deadlock_detected, _error}, 0

    margin = H.lock_timeout_ms() - (max(cancel_done_at, w_done_at) - cancel_waiting_at)

    assert margin >= 500,
           "lock_timeout margin #{margin} ms is under 500 ms"

    %{
      instance: x,
      task_a: task_a,
      task_b: task_b,
      cancel: cancel_result,
      w: w_result,
      queries: queries
    }
  end

  describe "L1: the straggler is held by a completer queued behind the cancel" do
    test "abort, roll back, retry: W completes B, the retry cancels C", %{base: base} do
      s = leftover_overlap!(base, ["a", "b", "c"], false)

      assert {:ok, _} = s.w
      assert {:ok, %{cancelled_task_ids: ids} = result} = s.cancel, inspect(s.cancel)

      task_c = task_at!(base.schema, s.instance, "c")
      assert task_c.status == :cancelled
      assert task_c.id in ids
      assert Fx.task!(base.schema, s.task_b.id).status == :completed
      assert Fx.projection!(base.schema, s.instance).status == :cancelled
      assert pending_ids(base.schema, s.instance) == []
      assert task_c.id in assert_payload!(base.schema, s.instance, result)

      # exactly two attempts: two class-1 (waiting) tasks reads on the cancel's backend
      assert class1_task_reads(s.queries, base.schema) == 2
      assert Enum.count(s.queries, &(&1.query == "rollback")) == 1
    end
  end

  describe "L1b: the straggler's completion ends the instance" do
    test "the retry finds the instance terminal (409 on the route)", %{base: base} do
      s = leftover_overlap!(base, ["a", "b"], true)

      assert {:ok, _} = s.w
      assert {:error, {:instance_already_terminal, :completed}} = s.cancel

      assert Fx.task!(base.schema, s.task_b.id).status == :completed
      assert Fx.projection!(base.schema, s.instance).status == :completed
      assert class1_task_reads(s.queries, base.schema) == 2

      # A's token is synthetic here (finished by the fixture so B's completion ends the instance)
      # and A itself was only barrier-held: it stays pending on the completed instance, which is
      # why the assertions above are on B and the instance only.
      assert Fx.task!(base.schema, s.task_a.id).status == :pending
    end
  end

  # A cancel whose snapshot misses B while B is locked by a third connection (no completer, no
  # retry possible): the leftover without a queue. The worker runs `fun` after B is held.
  defp held_straggler!(base, fun) do
    schema = base.schema
    {x, task_a} = started!(base, ["a", "b"])

    {holder_a, _} = H.hold_row(schema, {:task, task_a.id})
    {worker, worker_pid} = H.start_worker(fun.(x))
    H.wait_for_blocked([worker_pid], 1)

    task_b = insert_straggler!(schema, x, task_a, false)
    {holder_b, _} = H.hold_row(schema, {:task, task_b.id})

    send(holder_a.pid, :release)
    assert {:ok, _} = Task.await(holder_a, H.await_ms())
    {result, _done_at} = Task.await(worker, H.await_ms())

    %{instance: x, task_a: task_a, task_b: task_b, result: result, holder_b: holder_b}
  end

  describe "N1: a cancel nested in the caller's transaction" do
    test "returns the typed error at once and the outer transaction is rollback-only", %{
      base: base
    } do
      parent = self()

      s =
        held_straggler!(base, fn x ->
          fn ->
            Repo.transaction(fn ->
              send(
                parent,
                {:inner, PlatformTenantFixture.capture_repo_queries(cancel_fn(base, x))}
              )

              :unreachable_commit
            end)
          end
        end)

      assert_receive {:inner, {{:error, :cancel_contention}, queries}}, 1_000
      assert s.result == {:error, :rollback}

      # "at once, no retry" proven directly: one class-1 read, one SKIP LOCKED re-read, no second
      # attempt (a retry would repeat the class-1 read)
      assert class1_task_reads(queries, base.schema) == 1
      assert Enum.count(queries, &(&1.query =~ "SKIP LOCKED")) == 1

      # nothing committed: instance active, A and B pending, no INSTANCE_CANCELLED event
      assert Fx.projection!(base.schema, s.instance).status == :active

      assert pending_ids(base.schema, s.instance) |> Enum.sort() ==
               Enum.sort([s.task_a.id, s.task_b.id])

      assert Fx.instance_events(base.schema, s.instance, "INSTANCE_CANCELLED") == []

      # and it succeeds once B is free
      send(s.holder_b.pid, :release)
      assert {:ok, _} = Task.await(s.holder_b, H.await_ms())
      assert {:ok, %{cancelled_task_ids: ids}} = cancel_fn(base, s.instance).()
      assert Enum.sort(ids) == Enum.sort([s.task_a.id, s.task_b.id])
    end
  end

  describe "H1: the route maps :cancel_contention to 503" do
    test "constant body, instance unchanged", %{base: base} do
      parent = self()

      s =
        held_straggler!(base, fn x ->
          fn ->
            Repo.transaction(fn ->
              conn =
                conn("POST", "/#{x}/cancel")
                |> assign(:auth_context, %{
                  user_id: base.user.id,
                  tenant_id: base.tenant.tenant_id,
                  roles: ["PROCESS_OPERATOR"]
                })
                |> assign(:trace_id, "fixed-test-trace-id")
                |> Letflow.Routers.Instances.call(Letflow.Routers.Instances.init([]))

              send(parent, {:conn, conn})
              :unreachable_commit
            end)
          end
        end)

      assert_receive {:conn, conn}, 1_000
      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 503
      assert body["detail"] == "the instance is being modified concurrently; retry"
      refute conn.resp_body =~ "Postgrex"
      refute conn.resp_body =~ to_string(s.task_b.id)

      assert Fx.projection!(base.schema, s.instance).status == :active
      send(s.holder_b.pid, :release)
      assert {:ok, _} = Task.await(s.holder_b, H.await_ms())
    end
  end

  # ---- O1: statement order ----------------------------------------------------------------------

  describe "O1: statement order of the open-tasks re-read" do
    test "SKIP LOCKED after P_x and the ancestor group; no waiting tasks lock after P_x", %{
      base: base
    } do
      child_def = Fx.activate!(base.schema, base.user, seq_graph(["h1"]))
      parent_def = Fx.activate!(base.schema, base.user, parent_graph(child_def.name))

      {:ok, %{instance_id: p}} =
        Engine.create(
          %{
            definition_id: parent_def.id,
            initial_variables: %{},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("gh2706-o1")
          },
          prefix: base.schema
        )

      child_id =
        Repo.one!(
          from(i in InstanceProjection, where: i.parent_instance_id == ^p, select: i.instance_id),
          prefix: base.schema
        )

      {result, queries} = PlatformTenantFixture.capture_repo_queries(cancel_fn(base, child_id))
      assert {:ok, _} = result

      stmts = Enum.map(queries, & &1.query)
      params = fn q -> q |> Map.get(:params, []) |> Enum.map(&H.normalize/1) end

      own_projection =
        Enum.find_index(queries, fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR UPDATE" and child_id in params.(q)
        end)

      group =
        Enum.find_index(queries, fn q ->
          q.query =~ "tokens" and q.query =~ "FOR KEY SHARE" and q.query =~ "waiting_child"
        end)

      tasks_locks =
        queries
        |> Enum.with_index()
        |> Enum.filter(fn {q, _} ->
          q.query =~ ~s(FROM "#{base.schema}"."tasks") and q.query =~ "FOR UPDATE"
        end)

      assert is_integer(own_projection) and is_integer(group), inspect(stmts, limit: :infinity)
      assert own_projection < group

      {skip, waiting} =
        Enum.split_with(tasks_locks, fn {q, _} -> q.query =~ "SKIP LOCKED" end)

      assert [{_, recheck_at}] = skip, inspect(stmts, limit: :infinity)
      assert recheck_at > own_projection and recheck_at > group

      # exactly one waiting tasks lock, before the projection lock
      assert [{_, class1_at}] = waiting
      assert class1_at < own_projection

      # the re-read precedes the first tasks UPDATE
      first_update = Enum.find_index(stmts, &(&1 =~ ~r/UPDATE "[^"]+"\."tasks"/))
      assert recheck_at < first_update

      # no statement against tasks after P_x takes a waiting FOR UPDATE
      refute Enum.any?(waiting, fn {_, at} -> at > own_projection end)
    end

    test "an ineligible cancel issues no re-read", %{base: base} do
      {x, _task_a} = started!(base, ["a", "b"])
      assert {:ok, _} = cancel_fn(base, x).()

      {second, queries} = PlatformTenantFixture.capture_repo_queries(cancel_fn(base, x))
      assert {:error, {:instance_already_terminal, :cancelled}} = second
      refute Enum.any?(queries, &(&1.query =~ "SKIP LOCKED"))
    end
  end
end
