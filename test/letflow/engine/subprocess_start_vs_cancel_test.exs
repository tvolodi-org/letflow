defmodule Letflow.Engine.SubprocessStartVsCancelTest do
  @moduledoc """
  GH #2824 (design question Q7 of #2706; decision 0061): can a sub-process child be created by
  a transaction that runs concurrently with `cancel_instance(parent)` and be left behind
  (an "orphan" created by the race) under a parent that ends `:cancelled`?

  Verdict on main: no. Every child start is inside the parent's transaction and is gated by the
  parent's projection row (`P_p FOR UPDATE`, or the `FOR KEY SHARE` of the child's foreign
  keys), which conflicts with the cancel's `P_p FOR UPDATE`. Hence the two orders:

    * cancel first: the starter finds its task cancelled and returns an error; NO child row;
    * starter first: the child exists and the parent is then cancelled. The child stays `:active`
      by design (decision 0061: cancelling a parent does not go child-ward); that is not an orphan
      created by the race and is documented here, not asserted away.

  Cases (forced overlap with `Letflow.LockOrderHelpers`, sandbox `:auto`, hence `async: false`):

    * T1: the parent's HUMAN `complete_task/3` (which cascades into a SUB_PROCESS node and starts
      a child) against `cancel_instance(parent)`, both orders, barrier on the task row;
    * T2: a child's completion cascade against `cancel_instance(parent)`, both orders, barrier on
      the parent projection. The completion cascade starts NO child: the oracle is zero new child
      rows in both orders. The parent hops into a second SUB_PROCESS node on resume, and today the
      cascade drops the `{:sub_process_start, _}` event, so no second child appears. If that is
      ever fixed, the zero-child assertion in T2 turns red by design and must be revisited;
    * T4: the child-to-parent foreign keys that the argument relies on exist and are immediate.

  The timer-armed and service/script starts (T3) are not forced here: they are covered by reading
  (timers and dispatch rows are cancelled in the cancel's own transaction, `:timer_cancellations`
  and the dispatch cancellations) and share the `P_p` gate shown by T1.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)

    base = Fx.committed_tenant_case!("gh2824-sc")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    %{base: base}
  end

  # ---- graphs -----------------------------------------------------------------------------------

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp human(id),
    do: %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}}

  defp sub_process(id, def),
    do: %{
      "id" => id,
      "node_type" => "SUB_PROCESS",
      "attributes" => %{"definition_name" => def.name}
    }

  # START -> h1 (HUMAN) -> END
  defp plain_child do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        human("h1"),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "h1"), edge("e2", "h1", "end")]
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
          idempotency_key: Fx.unique("sc-start")
        },
        prefix: base.schema
      )

    id
  end

  defp cancel_fn(base, instance_id) do
    fn ->
      Engine.cancel_instance(
        instance_id,
        %{actor_id: base.user.id, idempotency_key: Fx.unique("sc-cancel")},
        prefix: base.schema
      )
    end
  end

  defp complete_fn(base, task_id) do
    fn ->
      Engine.complete_task(
        task_id,
        %{
          output_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("sc-complete")
        },
        prefix: base.schema
      )
    end
  end

  defp children(base, parent_id) do
    Repo.all(from(p in InstanceProjection, where: p.parent_instance_id == ^parent_id),
      prefix: base.schema
    )
  end

  defp children_of(base, parent_id, definition) do
    Enum.filter(children(base, parent_id), &(&1.definition_id == definition.id))
  end

  # Runs `cancel` and `starter` in the given order against `barrier`; returns {cancel_result, starter_result}.
  defp race(base, barrier, order, cancel, starter) do
    overlap =
      case order do
        :cancel_first -> H.forced_overlap(base.schema, barrier, cancel, starter)
        :starter_first -> H.forced_overlap(base.schema, barrier, starter, cancel)
      end

    margin = H.margin_ms(overlap.timing)

    assert margin >= 500,
           "lock_timeout margin #{margin} ms is under 500 ms (#{inspect(overlap.timing)})"

    case order do
      :cancel_first -> {overlap.first, overlap.second}
      :starter_first -> {overlap.second, overlap.first}
    end
  end

  # ---- T1: HUMAN completion starts a child ------------------------------------------------------

  describe "T1: complete_task(parent h0) that starts a child against cancel_instance(parent)" do
    for order <- [:cancel_first, :starter_first] do
      test "#{order}: a child exists only if the completion won", %{base: base} do
        c_def = activate!(base, plain_child())

        parent_graph = %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            human("h0"),
            sub_process("sp", c_def),
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => [edge("p1", "start", "h0"), edge("p2", "h0", "sp"), edge("p3", "sp", "end")]
        }

        parent_id = start_instance!(base, activate!(base, parent_graph))
        assert [] = children(base, parent_id)
        h0 = Fx.pending_task!(base.schema, parent_id)

        {cancel_result, starter_result} =
          race(
            base,
            {:task, h0.id},
            unquote(order),
            cancel_fn(base, parent_id),
            complete_fn(base, h0.id)
          )

        assert {:ok, _} = cancel_result
        assert Fx.projection!(base.schema, parent_id).status == :cancelled
        assert [_one] = Fx.instance_events(base.schema, parent_id, "INSTANCE_CANCELLED")

        case unquote(order) do
          :cancel_first ->
            # (i) cancel won: the starter lost and wrote no child
            assert {:error, _} = starter_result
            assert [] = children(base, parent_id)

          :starter_first ->
            # (ii) starter won: one child, active under the cancelled parent (decision 0061)
            assert {:ok, _} = starter_result
            assert [child] = children_of(base, parent_id, c_def)
            assert child.status == :active
        end

        # the invariant: a child never exists unless the starter reported success
        assert match?({:ok, _}, starter_result) == (children(base, parent_id) != [])
      end
    end
  end

  # ---- T2: child completion cascade creates no child --------------------------------------------

  describe "T2: child completion cascade against cancel_instance(parent)" do
    for order <- [:cancel_first, :starter_first] do
      test "#{order}: no new child is created", %{base: base} do
        c1_def = activate!(base, plain_child())
        c2_def = activate!(base, plain_child())

        parent_graph = %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            sub_process("sp1", c1_def),
            sub_process("sp2", c2_def),
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => [
            edge("p1", "start", "sp1"),
            edge("p2", "sp1", "sp2"),
            edge("p3", "sp2", "end")
          ]
        }

        parent_id = start_instance!(base, activate!(base, parent_graph))
        assert [c1] = children(base, parent_id)
        assert c1.definition_id == c1_def.id
        c1_task = Fx.pending_task!(base.schema, c1.instance_id)

        {cancel_result, starter_result} =
          race(
            base,
            {:projection, parent_id},
            unquote(order),
            cancel_fn(base, parent_id),
            complete_fn(base, c1_task.id)
          )

        # cancel does not touch the child, so the completion succeeds in both orders
        assert {:ok, _} = cancel_result
        assert {:ok, _} = starter_result
        assert Fx.projection!(base.schema, parent_id).status == :cancelled
        assert Fx.projection!(base.schema, c1.instance_id).status == :completed

        # the oracle: zero new children, in both orders
        assert [only] = children(base, parent_id)
        assert only.instance_id == c1.instance_id
        assert [] = children_of(base, parent_id, c2_def)
      end
    end
  end

  # ---- T4: the foreign keys the argument rests on -----------------------------------------------

  describe "T4: child-to-parent foreign keys" do
    test "parent_instance_id and parent_token_id are immediate foreign keys", %{base: base} do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT a.attname, c.condeferrable
            FROM pg_constraint c
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
           WHERE c.contype = 'f'
             AND c.conrelid = format('%I.instance_projections', $1::text)::regclass
             AND a.attname IN ('parent_instance_id', 'parent_token_id')
          """,
          [base.schema]
        )

      assert rows |> Enum.map(&hd/1) |> Enum.sort() == ["parent_instance_id", "parent_token_id"]
      assert Enum.all?(rows, fn [_name, deferrable] -> deferrable == false end)
    end
  end
end
