defmodule Letflow.Engine.Gh2830ExecutionErrorCancelsTimersOrderTest do
  @moduledoc """
  GH #2830: the statement order of the ExecutionError landing with its timer cancel, under
  decision 0061 rule 1 (the group and `P_x` locks first, then the timer class, then the instance's
  own event append). Run in sandbox auto mode (real commits), as the #2709 lock-order tests are.

    * E5: a sub-process child's pending timer is cancelled by its landing; the parent's is not;
    * E7: on a child landing the timer UPDATE sits after the waiting-token lock and before the
      EXECUTION_ERROR insert and the projection UPDATE;
    * E8: the HUMAN execution-error tail (a `complete_task/3` caller that composes the landing into
      a larger transaction): the timer UPDATE comes after the instance's `P_x` lock and before the
      first events INSERT of that transaction (the EXECUTION_ERROR append).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    :ok
  end

  defp tenant(_context) do
    base = Fx.committed_tenant_case!("gh2830-ord")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    %{base: base}
  end

  # ---- graphs (as in execution_error_lock_order_test.exs) ---------------------------------------

  defp human(id),
    do: %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}}

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp start_node, do: %{"id" => "start", "node_type" => "START"}
  defp end_node, do: %{"id" => "end", "node_type" => "END"}
  defp gateway, do: %{"id" => "xg", "node_type" => "EXCLUSIVE_GATEWAY"}

  defp guarded_edge,
    do: Map.put(edge("eg", "xg", "end"), "condition", "variables.approved == true")

  # START -> h1 -> END
  defp plain_child do
    %{
      "nodes" => [start_node(), human("h1"), end_node()],
      "edges" => [edge("e1", "start", "h1"), edge("e2", "h1", "end")]
    }
  end

  # START -> h1 -> xg -(approved == true)-> END: completing h1 with approved = false has no edge
  defp human_error_child do
    %{
      "nodes" => [start_node(), human("h1"), gateway(), end_node()],
      "edges" => [edge("e1", "start", "h1"), edge("e2", "h1", "xg"), guarded_edge()]
    }
  end

  defp parent_graph(child_def) do
    %{
      "nodes" => [
        start_node(),
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_def.name}
        },
        end_node()
      ],
      "edges" => [edge("p1", "start", "sp"), edge("p2", "sp", "end")]
    }
  end

  # START -> sp (child) -> xg -(approved == true)-> END: the parent's gateway reads the child's output
  defp parent_gate_graph(child_def) do
    %{
      "nodes" => [
        start_node(),
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_def.name}
        },
        gateway(),
        end_node()
      ],
      "edges" => [edge("p1", "start", "sp"), edge("p2", "sp", "xg"), guarded_edge()]
    }
  end

  defp activate!(base, graph), do: Fx.legacy_activate!(base.schema, base.user, graph, [])

  defp start_instance!(base, definition) do
    {:ok, %{instance_id: id}} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("gh2830-start")
        },
        prefix: base.schema
      )

    id
  end

  defp pair!(base, child_graph, parent_fun \\ &parent_graph/1) do
    c_def = activate!(base, child_graph)
    parent = activate!(base, parent_fun.(c_def))
    parent_id = start_instance!(base, parent)

    child_id =
      Repo.one!(
        from(p in InstanceProjection,
          where: p.parent_instance_id == ^parent_id and p.definition_id == ^c_def.id,
          select: p.instance_id
        ),
        prefix: base.schema
      )

    {parent_id, child_id}
  end

  defp pending_task(base, instance_id, node_id) do
    Repo.one!(
      from(t in Letflow.Engine.Task,
        where: t.instance_id == ^instance_id and t.node_id == ^node_id and t.status == :pending
      ),
      prefix: base.schema
    )
  end

  # a DUE pending timer row, armed as the engine arms one
  defp arm!(base, instance_id, node_id) do
    {:ok, timer} =
      Scheduler.create(
        Repo,
        %{
          instance_id: instance_id,
          timer_type: "deadline",
          node_id: node_id,
          fire_at:
            DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)
        },
        prefix: base.schema
      )

    timer
  end

  defp reload(base, timer), do: Repo.get!(Timer, timer.id, prefix: base.schema)

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
          idempotency_key: Fx.unique("gh2830-set")
        },
        prefix: base.schema
      )
    end
  end

  defp params(q), do: q |> Map.get(:params, []) |> Enum.map(&Letflow.LockOrderHelpers.normalize/1)

  describe "E5: a child landing cancels the child's timers only" do
    setup :tenant

    test "the child's pending timer is cancelled, the parent's pending timer is untouched", %{
      base: base
    } do
      {parent_id, child_id} = pair!(base, plain_child())
      child_timer = arm!(base, child_id, "child-tmr")
      parent_timer = arm!(base, parent_id, "parent-tmr")

      assert {:ok, _} = set_error_fn(base, child_id).()

      child = reload(base, child_timer)
      assert child.status == "cancelled"
      assert child.cancel_reason == "instance_error"
      assert reload(base, parent_timer).status == "pending"

      assert Repo.one!(
               from(p in InstanceProjection,
                 where: p.instance_id == ^parent_id,
                 select: p.status
               ),
               prefix: base.schema
             ) == :active
    end
  end

  describe "E7: statement order of a child landing with the timer cancel" do
    setup :tenant

    test "the timer UPDATE follows the waiting-token lock and precedes the EXECUTION_ERROR insert",
         %{base: base} do
      {_parent_id, child_id} = pair!(base, plain_child())
      _timer = arm!(base, child_id, "child-tmr")

      {result, queries} = PlatformTenantFixture.capture_repo_queries(set_error_fn(base, child_id))
      assert {:ok, _} = result

      waiting_token =
        Enum.find_index(queries, fn q ->
          q.query =~ "tokens" and q.query =~ "FOR KEY SHARE" and q.query =~ "waiting_child"
        end)

      timer_update =
        Enum.find_index(queries, &(&1.query =~ ~r/UPDATE "[^"]+"\."timers"/))

      event_insert = Enum.find_index(queries, &(&1.query =~ ~r/INSERT INTO "[^"]+"\."events"/))

      projection_update =
        Enum.find_index(queries, &(&1.query =~ ~r/UPDATE "[^"]+"\."instance_projections"/))

      positions = [waiting_token, timer_update, event_insert, projection_update]

      assert Enum.all?(positions, &is_integer/1),
             inspect(Enum.map(queries, & &1.query), limit: :infinity)

      assert waiting_token < timer_update
      assert timer_update < event_insert
      assert timer_update < projection_update
    end
  end

  describe "E8: the HUMAN execution-error tail (class B) cancels before its EXECUTION_ERROR append" do
    setup :tenant

    test "the timer UPDATE is inside the tail's transaction, before the first events INSERT",
         %{base: base} do
      {_parent_id, child_id} = pair!(base, human_error_child())
      task = pending_task(base, child_id, "h1")
      timer = arm!(base, child_id, "child-tmr")

      landing = fn ->
        Engine.complete_task(
          task.id,
          %{
            output_variables: %{"approved" => false},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("gh2830-complete")
          },
          prefix: base.schema
        )
      end

      {result, queries} = PlatformTenantFixture.capture_repo_queries(landing)

      assert {:error, {:instance_execution_error, _type, _affected}} = result

      projection_lock =
        Enum.find_index(queries, fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR UPDATE" and
            child_id in params(q)
        end)

      timer_update = Enum.find_index(queries, &(&1.query =~ ~r/UPDATE "[^"]+"\."timers"/))
      event_insert = Enum.find_index(queries, &(&1.query =~ ~r/INSERT INTO "[^"]+"\."events"/))

      assert Enum.all?([projection_lock, timer_update, event_insert], &is_integer/1),
             inspect(Enum.map(queries, & &1.query), limit: :infinity)

      assert projection_lock < timer_update
      assert timer_update < event_insert

      # the first events INSERT of the tail is the EXECUTION_ERROR append (no S_x before the cancel)
      first_insert = Enum.find(queries, &(&1.query =~ ~r/INSERT INTO "[^"]+"\."events"/))
      assert "EXECUTION_ERROR" in params(first_insert)

      cancelled = reload(base, timer)
      assert cancelled.status == "cancelled"
      assert cancelled.cancel_reason == "instance_error"
    end
  end

  describe "E9: the cascade error branch (class G1) takes the timer class after the parent group" do
    setup :tenant

    test "the parent's timers are cancelled after its P_p lock and before its EXECUTION_ERROR insert",
         %{base: base} do
      {parent_id, child_id} = pair!(base, plain_child(), &parent_gate_graph/1)
      task = pending_task(base, child_id, "h1")
      parent_timer = arm!(base, parent_id, "parent-tmr")

      completion = fn ->
        Engine.complete_task(
          task.id,
          %{
            output_variables: %{"approved" => false},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("gh2830-cascade")
          },
          prefix: base.schema
        )
      end

      {_result, queries} = PlatformTenantFixture.capture_repo_queries(completion)

      # the cascade reached the parent's gateway, which had no matching edge: the parent is in :error
      assert Repo.one!(
               from(p in InstanceProjection,
                 where: p.instance_id == ^parent_id,
                 select: p.status
               ),
               prefix: base.schema
             ) == :error

      parent_lock =
        Enum.find_index(queries, fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR UPDATE" and
            parent_id in params(q)
        end)

      timer_update = Enum.find_index(queries, &(&1.query =~ ~r/UPDATE "[^"]+"\."timers"/))

      parent_error_insert =
        Enum.find_index(queries, fn q ->
          q.query =~ ~r/INSERT INTO "[^"]+"\."events"/ and "EXECUTION_ERROR" in params(q) and
            parent_id in params(q)
        end)

      assert Enum.all?([parent_lock, timer_update, parent_error_insert], &is_integer/1),
             inspect(Enum.map(queries, & &1.query), limit: :infinity)

      assert parent_lock < timer_update
      assert timer_update < parent_error_insert

      cancelled = reload(base, parent_timer)
      assert cancelled.status == "cancelled"
      assert cancelled.cancel_reason == "instance_error"
    end
  end
end
