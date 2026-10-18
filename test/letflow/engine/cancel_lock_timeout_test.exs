defmodule Letflow.Engine.CancelLockTimeoutTest do
  @moduledoc """
  GH #2706 / PR-2 (design `lib/letflow/design/gh2706-cancel-snapshot-and-lock-timeouts.md`
  sections 3 and 6; decision 0061): `cancel_instance/3` bounds every lock wait with a
  transaction-local `lock_timeout` and maps a lock timeout (55P03) or deadlock victim (40P01) to
  `{:error, :cancel_contention}` (HTTP 503).

    * T1: a REAL 55P03 against a real holder of the instance projection (the worker lowers the
      timeout to 300 ms through the process-local override, test-seam builds only): the typed
      error, nothing committed, and the retry succeeds once the holder is gone;
    * T1b: the leftover path with a real, permanent holder of the straggler task: the first
      attempt aborts (leftover), the second waits on the holder and times out (55P03), exactly
      two attempts, nothing committed;
    * T3: a deterministic deadlock victim (40P01) maps to the same typed error;
    * T4: nested in the caller's transaction the timeout is NOT set (no leak into the caller);
    * T5: not nested, the setting is transaction-local (the pinned connection is back to its
      default afterwards);
    * T6: statement trace: the bound `set_config` form is the first statement after BEGIN and no
      timeout value appears in any SQL text (INV-7);
    * H2: the route maps a real timeout to 503 with the constant body.

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
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  @override_ms 300
  # T1b: the first attempt also waits on A while the test arranges the straggler, so its budget
  # must outlast that setup (the 300 ms of the other tests would time out on A itself)
  @leftover_override_ms 1_500

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)

    base = Fx.committed_tenant_case!("gh2706-pr2")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    %{base: base}
  end

  # ---- fixtures ---------------------------------------------------------------------------------

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp human(id),
    do: %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}}

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

  defp started!(base, ids) do
    definition = Fx.activate!(base.schema, base.user, seq_graph(ids))
    Fx.start!(base.schema, definition)
  end

  defp cancel_fn(base, instance_id) do
    fn ->
      Engine.cancel_instance(
        instance_id,
        %{actor_id: base.user.id, idempotency_key: Fx.unique("gh2706-pr2-cancel")},
        prefix: base.schema
      )
    end
  end

  # Runs in the worker's own process: lowers the lock timeout to 300 ms (test-seam builds only).
  defp with_override(fun, ms \\ @override_ms) do
    fn ->
      Process.put(:contention_lock_timeout_ms_override, ms)
      fun.()
    end
  end

  defp traced(fun), do: fn -> PlatformTenantFixture.capture_repo_queries(fun) end

  defp pending_ids(schema, instance_id),
    do:
      Repo.all(
        from(t in EngineTask,
          where: t.instance_id == ^instance_id and t.status == :pending,
          select: t.id
        ),
        prefix: schema
      )

  # A worker that does not finish within `ms` is a failure (on code without the lock timeout it
  # waits for the holder), never a hang.
  defp await_within!(task, ms) do
    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      other -> flunk("the worker did not finish within #{ms} ms (#{inspect(other)})")
    end
  end

  defp assert_nothing_committed!(base, x, task_ids) do
    assert Fx.projection!(base.schema, x).status == :active
    assert Enum.sort(pending_ids(base.schema, x)) == Enum.sort(task_ids)
    assert Fx.instance_events(base.schema, x, "INSTANCE_CANCELLED") == []
  end

  # Task B (and its token at node "b") inserted straight into the tables, as the committed
  # result of a completer of A that the cancel's class-1 snapshot never saw.
  defp insert_straggler!(schema, instance_id, task_a) do
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

  defp assert_55p03_reported! do
    assert_receive {:deadlock_detected, %Postgrex.Error{postgres: %{code: :lock_not_available}}},
                   1_000
  end

  # ---- T1 ---------------------------------------------------------------------------------------

  describe "T1: a real lock timeout" do
    test "returns :cancel_contention within the lowered timeout, commits nothing, succeeds after",
         %{base: base} do
      {x, task_a} = started!(base, ["a", "b"])
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      started_at = System.monotonic_time(:millisecond)
      {worker, pid} = H.start_worker(with_override(cancel_fn(base, x)))
      H.wait_for_blocked([pid], 1)

      {result, done_at} = await_within!(worker, 3_000)
      assert result == {:error, :cancel_contention}
      assert done_at - started_at >= @override_ms - 50

      # a genuine 55P03 from Postgres, not a stub
      assert_55p03_reported!()

      assert_nothing_committed!(base, x, [task_a.id])

      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, H.await_ms())
      assert {:ok, %{cancelled_task_ids: [id]}} = cancel_fn(base, x).()
      assert id == task_a.id
      assert Fx.projection!(base.schema, x).status == :cancelled
    end
  end

  # ---- T1b --------------------------------------------------------------------------------------

  describe "T1b: the leftover path against a real, permanent holder" do
    test "attempt 1 aborts on the leftover, attempt 2 times out on the holder: typed error",
         %{base: base} do
      schema = base.schema
      {x, task_a} = started!(base, ["a", "b"])

      {holder_a, _} = H.hold_row(schema, {:task, task_a.id})

      {worker, pid} =
        H.start_worker(with_override(traced(cancel_fn(base, x)), @leftover_override_ms))

      H.wait_for_blocked([pid], 1)

      task_b = insert_straggler!(schema, x, task_a)
      {holder_b, _} = H.hold_row(schema, {:task, task_b.id})

      send(holder_a.pid, :release)
      assert {:ok, _} = Task.await(holder_a, H.await_ms())

      {{result, queries}, _done_at} = await_within!(worker, 8_000)
      assert result == {:error, :cancel_contention}
      assert_55p03_reported!()

      # exactly two attempts: two waiting class-1 tasks reads (the second is the one that timed out)
      class1 =
        Enum.count(queries, fn q ->
          q.query =~ ~s(FROM "#{schema}"."tasks") and q.query =~ "FOR UPDATE" and
            not (q.query =~ "SKIP LOCKED")
        end)

      assert class1 == 2
      assert Enum.count(queries, &(&1.query =~ "set_config")) == 2

      assert_nothing_committed!(base, x, [task_a.id, task_b.id])

      send(holder_b.pid, :release)
      assert {:ok, _} = Task.await(holder_b, H.await_ms())
      assert {:ok, %{cancelled_task_ids: ids}} = cancel_fn(base, x).()
      assert Enum.sort(ids) == Enum.sort([task_a.id, task_b.id])
    end
  end

  # ---- T3 ---------------------------------------------------------------------------------------

  describe "T3: a deadlock victim" do
    test "40P01 raised inside the cancel maps to :cancel_contention", %{base: base} do
      schema = base.schema
      {x, task_a} = started!(base, ["a", "b"])
      test_pid = self()

      # Z holds P_x, then (on :go) asks for task A, which the cancel already holds (class 1) while
      # it queues at P_x. The cancel is the FIRST waiter, so its deadlock_timeout expires first
      # and it is the detector, hence the victim.
      z =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              ~s(SELECT 1 FROM "#{schema}"."instance_projections" WHERE instance_id = $1 FOR UPDATE),
              [Ecto.UUID.dump!(x)]
            )

            send(test_pid, :z_holds_projection)

            receive do
              :go -> :ok
            after
              H.await_ms() -> :timeout
            end

            Repo.query!(~s(SELECT 1 FROM "#{schema}"."tasks" WHERE id = $1 FOR UPDATE), [
              Ecto.UUID.dump!(task_a.id)
            ])
          end)
        end)

      on_exit(fn -> send(z.pid, :go) end)
      assert_receive :z_holds_projection, 10_000

      {worker, pid} = H.start_worker(cancel_fn(base, x))
      H.wait_for_blocked([pid], 1)
      send(z.pid, :go)

      {result, _done_at} = await_within!(worker, 8_000)
      assert result == {:error, :cancel_contention}

      assert_receive {:deadlock_detected, %Postgrex.Error{postgres: %{code: :deadlock_detected}}},
                     1_000

      assert {:ok, _} = Task.await(z, H.await_ms())
      assert_nothing_committed!(base, x, [task_a.id])
    end
  end

  # ---- T4 / T5 / T6 -----------------------------------------------------------------------------

  defp show_lock_timeout do
    %{rows: [[value]]} = Repo.query!("SHOW lock_timeout")
    value
  end

  describe "T4: nested in the caller's transaction" do
    test "the timeout is not set and does not leak into the caller", %{base: base} do
      {x, _task_a} = started!(base, ["a", "b"])

      assert {:ok, {result, queries, before, after_call}} =
               Repo.transaction(fn ->
                 before = show_lock_timeout()
                 {call, queries} = PlatformTenantFixture.capture_repo_queries(cancel_fn(base, x))
                 {call, queries, before, show_lock_timeout()}
               end)

      assert {:ok, _} = result
      assert after_call == before
      refute after_call == "5s"
      refute Enum.any?(queries, &(&1.query =~ "set_config"))
    end
  end

  describe "T5: not nested" do
    test "the setting is transaction-local: the pinned connection returns to its default",
         %{base: base} do
      {x, _task_a} = started!(base, ["a", "b"])

      Repo.checkout(fn ->
        refute Repo.in_transaction?()
        before = show_lock_timeout()
        assert {:ok, _} = cancel_fn(base, x).()
        assert show_lock_timeout() == before
        refute show_lock_timeout() == "5s"
      end)
    end
  end

  describe "T6: statement order and the bound parameter" do
    test "set_config is the first statement after BEGIN, one bound parameter, no value in SQL",
         %{base: base} do
      {x, _task_a} = started!(base, ["a", "b"])

      {result, queries} = PlatformTenantFixture.capture_repo_queries(cancel_fn(base, x))
      assert {:ok, _} = result

      stmts = Enum.map(queries, & &1.query)
      begin_at = Enum.find_index(stmts, &(&1 == "begin"))
      assert is_integer(begin_at)

      first = Enum.at(queries, begin_at + 1)
      assert first.query == "SELECT set_config('lock_timeout', $1, true)"
      assert first.params == ["5000ms"]

      # no timeout value is spliced into any SQL text of the transaction
      refute Enum.any?(stmts, &(&1 =~ "5000" or &1 =~ "5s"))
      assert Enum.count(stmts, &(&1 =~ "set_config")) == 1
    end

    test "the process-local override is what is bound (test-seam builds)", %{base: base} do
      {x, _task_a} = started!(base, ["a", "b"])
      Process.put(:contention_lock_timeout_ms_override, @override_ms)

      {result, queries} = PlatformTenantFixture.capture_repo_queries(cancel_fn(base, x))
      assert {:ok, _} = result

      assert %{params: ["300ms"]} = Enum.find(queries, &(&1.query =~ "set_config"))
    end
  end

  # ---- H2 ---------------------------------------------------------------------------------------

  describe "H2: the route maps a real timeout to 503" do
    test "constant body, instance unchanged", %{base: base} do
      {x, task_a} = started!(base, ["a", "b"])
      {holder, _} = H.hold_row(base.schema, {:projection, x})

      route = fn ->
        conn("POST", "/#{x}/cancel")
        |> assign(:auth_context, %{
          user_id: base.user.id,
          tenant_id: base.tenant.tenant_id,
          roles: ["PROCESS_OPERATOR"]
        })
        |> assign(:trace_id, "fixed-test-trace-id")
        |> Letflow.Routers.Instances.call(Letflow.Routers.Instances.init([]))
      end

      {worker, pid} = H.start_worker(with_override(route))
      H.wait_for_blocked([pid], 1)

      {conn, _done_at} = await_within!(worker, 3_000)
      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 503
      assert body["detail"] == "the instance is being modified concurrently; retry"
      refute conn.resp_body =~ "Postgrex"
      assert_55p03_reported!()

      assert_nothing_committed!(base, x, [task_a.id])
      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, H.await_ms())
    end
  end
end
