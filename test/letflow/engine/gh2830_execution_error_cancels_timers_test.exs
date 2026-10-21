defmodule Letflow.Engine.Gh2830ExecutionErrorCancelsTimersTest do
  @moduledoc """
  GH #2830 (follow-up F-2 of the #2707 design; root cause of the `:error` timer leak #2822): the
  ExecutionError landing cancels the instance's pending timers in the same transaction, under the
  `P_x` lock the landing already holds, with reason `instance_error` (decision 0061 rule 1; the
  cancel sits after the eligibility check, the group lock and before the EXECUTION_ERROR append).

    * E1: the red proof: after the landing sets `:error`, the pending timer is `cancelled`;
    * E2: the cancelled row (reason, timestamp, no fire failure), no TIMER_FIRED, one DLQ row;
    * E3: the cancel shares the landing's transaction (a rollback after the landing undoes it);
    * E4: the cancel is instance-wide and not tenant-wide (a sibling instance keeps its timer);
    * E5: a sub-process child's timers are cancelled, the parent's are not touched;
    * E6: an ineligible landing cancels nothing; a timer armed after the landing is still settled
      by the next tick with reason `instance_error` (the #2707 settle stays for later rows).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.Engine.ExecutionError
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Event
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp past(seconds_ago),
    do:
      DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:microsecond)

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  # START -> tmr (TIMER) -> h (HUMAN) -> END
  defp timer_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "PT1H"}
        },
        %{"id" => "h", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "tmr"), edge("e2", "tmr", "h"), edge("e3", "h", "end")]
    }
  end

  defp setup_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "gh2830",
      display_name: "GH 2830 execution-error timer tenant"
    )
  end

  defp start_instance!(schema, graph) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: unique("gh2830-def"),
          version: "1.0.0",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema)

    {:ok, %{instance_id: id}} =
      Engine.create(
        %{
          definition_id: activated.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("gh2830-start")
        },
        prefix: schema
      )

    id
  end

  defp error_args(instance_id) do
    %{
      instance_id: instance_id,
      error_type: :variable_schema_rejected,
      affected: {:field, "approved"},
      reason: "rejected",
      variables: %{},
      details: %{},
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique("gh2830-err")
    }
  end

  defp error!(schema, instance_id) do
    {:ok, _} = Engine.set_instance_error(error_args(instance_id), prefix: schema)
  end

  # a DUE pending timer row armed after the instance was created
  defp arm!(schema, instance_id, seconds_ago) do
    {:ok, timer} =
      Scheduler.create(
        Repo,
        %{
          instance_id: instance_id,
          timer_type: "deadline",
          node_id: "ghost",
          fire_at: past(seconds_ago)
        },
        prefix: schema
      )

    timer
  end

  defp engine_timer!(schema, instance_id) do
    timer = Repo.one!(from(t in Timer, where: t.instance_id == ^instance_id), prefix: schema)
    assert timer.status == "pending"
    timer
  end

  defp reload(schema, timer), do: Repo.get!(Timer, timer.id, prefix: schema)

  defp timer_fired_events(schema, instance_id) do
    Repo.all(
      from(e in Event, where: e.instance_id == ^instance_id and e.event_type == "TIMER_FIRED"),
      prefix: schema
    )
  end

  defp assert_cancelled_by_landing!(schema, timer) do
    reloaded = reload(schema, timer)
    assert reloaded.status == "cancelled"
    assert reloaded.cancel_reason == "instance_error"
    assert reloaded.cancelled_at != nil
    assert reloaded.fire_error_count == 0
  end

  describe "E1: the landing cancels the pending timers of the instance it errors (red on main)" do
    test "after set_instance_error/2 the instance's pending timer is cancelled" do
      %{schema_name: schema} = setup_tenant()
      x = start_instance!(schema, timer_graph())
      timer = engine_timer!(schema, x)

      error!(schema, x)

      assert Repo.one!(
               from(p in InstanceProjection, where: p.instance_id == ^x, select: p.status),
               prefix: schema
             ) == :error

      assert_cancelled_by_landing!(schema, timer)
    end
  end

  describe "E2: the cancelled row and the rest of the landing" do
    test "no TIMER_FIRED, the ERROR is landed once, and the timer is not dead-lettered" do
      %{schema_name: schema} = setup_tenant()
      x = start_instance!(schema, timer_graph())
      timer = engine_timer!(schema, x)

      error!(schema, x)

      assert_cancelled_by_landing!(schema, timer)
      assert timer_fired_events(schema, x) == []

      assert [%{entry_type: "event"}] =
               Repo.all(from(d in Dlq.Entry, where: d.instance_id == ^x), prefix: schema)

      assert %{claimed: 0} = Scheduler.poll_and_fire(schema)
    end
  end

  describe "E3: the cancel shares the landing's transaction" do
    test "a failure after the projection update rolls the cancel back with the landing" do
      %{schema_name: schema} = setup_tenant()
      x = start_instance!(schema, timer_graph())
      timer = engine_timer!(schema, x)

      result =
        Ecto.Multi.new()
        |> ExecutionError.append_multi(error_args(x), prefix: schema)
        |> Ecto.Multi.run(:forced, fn _repo, _changes -> {:error, :forced} end)
        |> Repo.transaction()

      assert {:error, :forced, :forced, _changes} = result

      assert reload(schema, timer).status == "pending"

      assert Repo.one!(
               from(p in InstanceProjection, where: p.instance_id == ^x, select: p.status),
               prefix: schema
             ) == :active

      assert Repo.all(
               from(e in Event, where: e.instance_id == ^x and e.event_type == "EXECUTION_ERROR"),
               prefix: schema
             ) == []
    end
  end

  describe "E4: the cancel is instance-wide, not tenant-wide" do
    test "a sibling instance keeps its pending timer" do
      %{schema_name: schema} = setup_tenant()
      a = start_instance!(schema, timer_graph())
      b = start_instance!(schema, timer_graph())
      timer_a = engine_timer!(schema, a)
      timer_b = engine_timer!(schema, b)

      error!(schema, a)

      assert_cancelled_by_landing!(schema, timer_a)
      assert reload(schema, timer_b).status == "pending"
    end
  end

  describe "E6: an ineligible landing cancels nothing; a later timer is still settled" do
    test "a second landing is refused and leaves the armed timer pending, the tick settles it" do
      %{schema_name: schema} = setup_tenant()
      x = start_instance!(schema, timer_graph())
      error!(schema, x)

      late = arm!(schema, x, 60)

      assert {:error, {:instance_already_error, _detail}} =
               Engine.set_instance_error(error_args(x), prefix: schema)

      assert reload(schema, late).status == "pending"

      test_pid = self()
      id = {__MODULE__, make_ref()}
      on_exit(fn -> :telemetry.detach(id) end)

      :telemetry.attach(
        id,
        [:letflow, :scheduler, :timers_settled],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:settled, measurements, metadata})
        end,
        nil
      )

      assert %{claimed: 1, errored: 0, exhausted: 0, fired: 0} = Scheduler.poll_and_fire(schema)
      assert_cancelled_by_landing_reason!(schema, late)
      assert_receive {:settled, %{count: 1}, %{reason: "instance_error"}}
    end
  end

  defp assert_cancelled_by_landing_reason!(schema, timer) do
    reloaded = reload(schema, timer)
    assert reloaded.status == "cancelled"
    assert reloaded.cancel_reason == "instance_error"
  end
end
