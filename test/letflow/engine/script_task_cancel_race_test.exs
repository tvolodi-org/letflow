defmodule Letflow.Engine.ScriptTaskCancelRaceTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC18a (SEC S6; design `lib/letflow/design/gh2534-7c-script-handler.md` 5.6,
  residual R9): apply vs `cancel_instance/3`. Both take the dispatch row lock before the
  projection lock, so they serialise. Driven through the REAL code paths with the pause seams
  (honoured only under `:scripts_test_hooks`): two processes, real commits.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    %{t: F.tenant!("gh2534-7c-race")}
  end

  defp pause_fn(test_pid, tag) do
    fn _point ->
      send(test_pid, {tag, self()})

      receive do
        :go -> :ok
      after
        15_000 -> :ok
      end
    end
  end

  defp cancel_async(test_pid, schema, instance_id) do
    spawn(fn ->
      result =
        Engine.cancel_instance(
          instance_id,
          %{actor_id: Ecto.UUID.generate(), idempotency_key: "race-#{instance_id}"},
          prefix: schema
        )

      send(test_pid, {:cancel_done, result})
    end)
  end

  test "apply first: the cancel waits on the dispatch row, then cancels the advanced instance",
       %{t: t} do
    k2 = "k2#{System.unique_integer([:positive])}"
    rule2 = F.published!(t.schema_name, k2, F.doubling_source(), F.closed_manifest())

    b =
      F.bound_graph!(
        t,
        F.doubling_source(),
        F.closed_manifest(),
        %{"amount" => 2},
        fn k1, v1 -> F.two_script_graph(k1, v1, k2, rule2.version) end,
        []
      )

    test_pid = self()
    F.put_env!(:script_task_apply_pause, pause_fn(test_pid, :apply_paused))
    {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)

    applier =
      spawn(fn ->
        send(test_pid, {:apply_done, ScriptTaskDispatcher.run_claimed(row, t.schema_name)})
      end)

    assert_receive {:apply_paused, ^applier}, 10_000

    canceller = cancel_async(test_pid, t.schema_name, b.instance_id)
    # the cancel is blocked on the dispatch row the paused apply holds
    refute_receive {:cancel_done, _}, 700
    assert Process.alive?(canceller)

    send(applier, :go)
    assert_receive {:apply_done, {:ok, :applied}}, 10_000
    assert_receive {:cancel_done, {:ok, _}}, 10_000

    projection = F.projection(t.schema_name, b.instance_id)
    assert projection.status == :cancelled
    # the instance advanced (svc1's output merged) before it was cancelled
    assert projection.variables["total"] == 4
    assert F.reload(t.schema_name, row).status == :applied

    # R9: svc2's row, armed by the apply that committed while the cancel waited, may be left
    # `pending` on the cancelled instance. It is inert: the claim requires an active instance.
    leftover = Enum.reject(F.rows(t.schema_name, b.instance_id), &(&1.id == row.id))
    assert [%{node_id: "svc2"} = svc2] = leftover
    assert svc2.status in [:pending, :cancelled]
    if svc2.status == :pending, do: F.make_due!(t.schema_name, svc2)
    assert ScriptTaskDispatcher.claim_next(t.schema_name) == :none
    assert F.reload(t.schema_name, svc2).status != :running
  end

  test "cancel first: the apply waits, then is stale and writes nothing", %{t: t} do
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 2})
    test_pid = self()
    {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
    F.put_env!(:script_task_cancel_pause, pause_fn(test_pid, :cancel_paused))

    canceller = cancel_async(test_pid, t.schema_name, b.instance_id)
    assert_receive {:cancel_paused, ^canceller}, 10_000

    applier =
      spawn(fn ->
        send(test_pid, {:apply_done, ScriptTaskDispatcher.run_claimed(row, t.schema_name)})
      end)

    # the script runs (no lock held); its apply then blocks on the cancelled-but-uncommitted row
    refute_receive {:apply_done, _}, 1_500
    assert Process.alive?(applier)

    send(canceller, :go)
    assert_receive {:cancel_done, {:ok, _}}, 10_000
    assert_receive {:apply_done, {:ok, :stale}}, 10_000

    assert F.projection(t.schema_name, b.instance_id).status == :cancelled
    refute Map.has_key?(F.projection(t.schema_name, b.instance_id).variables, "total")
    assert F.reload(t.schema_name, row).status == :cancelled

    types = F.event_types(t.schema_name, b.instance_id)
    refute "SCRIPT_TASK_COMPLETED" in types
    refute "SCRIPT_RUN_RECORDED" in types
    refute "EXECUTION_ERROR" in types
  end
end
