defmodule Letflow.Engine.ExecutionErrorLockOrderTest do
  @moduledoc """
  GH #2709 / PR-2 of the lock-order family (design `lib/letflow/design/gh2704-lock-order-family.md`
  section 4.2 and 10; decision 0061): an ExecutionError landing on a sub-process CHILD takes the
  ancestor group (parent projection, then the parent's waiting token, `FOR KEY SHARE`) before the
  landing writes anything, because the final UPDATE of the child's projection row takes
  foreign-key locks on the parent token and the parent projection.

  MECHANISM (measured by X0, it was "unconfirmed" in the design): the foreign-key check on an
  UPDATE of a referencing row is skipped while no key column changed, EXCEPT when the old row
  version was written by the SAME transaction. The landing UPDATEs the child's projection row twice
  (the event append bumps `last_event_seq`, then the projection goes to `:error`), so the second
  UPDATE queues the FK checks: `KEY SHARE` on the parent token and the parent projection, in an
  order fixed per tenant schema by the constraint-trigger names. Where the token comes first, a
  parent cancel (`P_p` then `T_p`) and the landing (`T_p` then `P_p`) form an AB-BA.

    * X0: the mechanism probe (first UPDATE: no lock; second UPDATE: both parent rows refused);
    * X1: statement order of `set_instance_error/2` on a child (group before the event insert and
      the projection UPDATE), and no group lock for an ineligible or a top-level landing;
    * X2: forced AB-BA against `cancel_instance(parent)` in a schema whose FK order is token first
      (the test re-creates the two foreign keys in that order and asserts the order as a
      precondition): RED on the unmodified landing (40P01 through the telemetry handler);
    * X3: the same overlap in a schema whose FK order is projection first (unreachable cycle);
    * X4: the same overlap through the HUMAN execution-error tail of `complete_task/3` and the
      service no-matching-edge landing (the callers that run in a child of their own transaction).

  Forced-overlap method: `Letflow.LockOrderHelpers` (a barrier row held by a third connection plus
  lock-queue FIFO; deadlocks and lock timeouts are reported through the Repo telemetry event, so a
  retried victim cannot hide). Sandbox `:auto` mode (real commits), hence `async: false`.

  The caller at the cascade error branch (`engine.ex` cascade; the instance is the parent and the
  chain is already locked `FOR UPDATE` by the completing child) is a documented no-op re-lock and is
  NOT tested by a separate case. The 2 s `lock_timeout` margin asserted in `overlap!/2` is only a
  yardstick shared with the PR-1 files: these paths set no `lock_timeout` of their own.

  S1 covers the limit of the guarantee: the group is found through `tokens.waiting_child_instance_id
  = child AND status = :waiting`, so it is held for a WAITING parent only. A child whose parent was
  already cancelled lands without any group lock; nothing holds the parent rows then, so the FK
  check does not queue.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
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
    :ok
  end

  defp tenant(_context) do
    base = Fx.committed_tenant_case!("gh2709-xe")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)
    %{base: base}
  end

  # ---- graphs -----------------------------------------------------------------------------------

  defp human(id),
    do: %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}}

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp start_node, do: %{"id" => "start", "node_type" => "START"}
  defp end_node, do: %{"id" => "end", "node_type" => "END"}

  # an exclusive gateway whose only outgoing edge has a condition the test makes false
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

  # START -> ct -> svc -> xg -(approved == true)-> END: the service result has no approved = true
  defp service_error_child do
    svc = Fx.service_graph([])["nodes"] |> Enum.find(&(&1["id"] == "svc"))

    %{
      "nodes" => [start_node(), human("ct"), svc, gateway(), end_node()],
      "edges" => [
        edge("e1", "start", "ct"),
        edge("e2", "ct", "svc"),
        edge("e3", "svc", "xg"),
        guarded_edge()
      ]
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

  defp activate!(base, graph), do: Fx.legacy_activate!(base.schema, base.user, graph, [])

  defp start_instance!(base, definition) do
    {:ok, %{instance_id: id}} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("xe-start")
        },
        prefix: base.schema
      )

    id
  end

  defp pair!(base, child_graph) do
    c_def = activate!(base, child_graph)
    parent = activate!(base, parent_graph(c_def))
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

  # ---- FK order control (Letflow.LockOrderHelpers.set_fk_order!/2) ----------------------------------

  defp token_first(_context) do
    %{base: base} = tenant(%{})
    H.set_fk_order!(base.schema, "tokens")
    %{base: base}
  end

  defp projection_first(_context) do
    %{base: base} = tenant(%{})
    H.set_fk_order!(base.schema, "instance_projections")
    %{base: base}
  end

  # ---- workers ----------------------------------------------------------------------------------

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
          idempotency_key: Fx.unique("xe-set")
        },
        prefix: base.schema
      )
    end
  end

  defp cancel_parent_fn(base, parent_id) do
    fn ->
      Engine.cancel_instance(
        parent_id,
        %{actor_id: base.user.id, idempotency_key: Fx.unique("xe-cancel")},
        prefix: base.schema
      )
    end
  end

  # {parent_id, child_id, landing closure, matcher for the landing's result}
  defp landing_case(base, :set_error) do
    {parent_id, child_id} = pair!(base, plain_child())
    {parent_id, child_id, set_error_fn(base, child_id), &match?({:ok, _}, &1)}
  end

  defp landing_case(base, :human_tail) do
    {parent_id, child_id} = pair!(base, human_error_child())
    task = pending_task(base, child_id, "h1")

    landing = fn ->
      Engine.complete_task(
        task.id,
        %{
          output_variables: %{"approved" => false},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("xe-complete")
        },
        prefix: base.schema
      )
    end

    {parent_id, child_id, landing,
     &match?({:error, {:instance_execution_error, _type, _affected}}, &1)}
  end

  defp landing_case(base, :service) do
    {parent_id, child_id} = pair!(base, service_error_child())
    ct = pending_task(base, child_id, "ct")

    assert {:ok, _} =
             Engine.complete_task(
               ct.id,
               %{
                 output_variables: %{},
                 actor_id: base.user.id,
                 idempotency_key: Fx.unique("xe-ct")
               },
               prefix: base.schema
             )

    dispatch =
      from(d in ServiceTaskDispatch, where: d.instance_id == ^child_id)
      |> Repo.one!(prefix: base.schema)
      |> Ecto.Changeset.change(%{status: :advanced})
      |> Repo.update!(prefix: base.schema)

    landing = fn ->
      Engine.advance_after_service_task_outcome(
        dispatch.id,
        {:advance, %{"approved" => false}},
        Repo,
        base.schema
      )
    end

    {parent_id, child_id, landing, &match?({:ok, :error_set}, &1)}
  end

  # `Z` holds the parent projection, `cancel_instance(parent)` parks first on it, the landing
  # arrives second, `Z` is released.
  defp overlap!(base, kind) do
    {parent_id, child_id, landing, landing_ok?} = landing_case(base, kind)

    overlap =
      H.forced_overlap(
        base.schema,
        {:projection, parent_id},
        cancel_parent_fn(base, parent_id),
        landing
      )

    assert {:ok, _} = overlap.first
    assert landing_ok?.(overlap.second), inspect(overlap.second)

    assert Fx.projection!(base.schema, parent_id).status == :cancelled
    assert Fx.projection!(base.schema, child_id).status == :error
    assert [_one] = Fx.instance_events(base.schema, child_id, "EXECUTION_ERROR")
    assert [_one] = Fx.dlq_entries(base.schema)

    # the 2 s lock_timeout yardstick of the PR-1 files (these paths set no lock_timeout, the figure
    # shows how far inside it the green waits stay)
    margin = H.margin_ms(overlap.timing)

    assert margin >= 500,
           "#{kind}: lock_timeout margin #{margin} ms is under 500 ms (#{inspect(overlap.timing)})"

    overlap
  end

  # ---- X0 ---------------------------------------------------------------------------------------

  # Runs the `updates` (SET fragments) in ONE transaction on a holder connection, then tries
  # FOR UPDATE NOWAIT on the child's own row (positive control), the parent's waiting token and
  # the parent projection from another connection (autocommit, so a refusal aborts nothing).
  defp probe!(base, parent_id, child_id, updates) do
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          for set <- updates do
            Repo.query!(
              ~s(UPDATE "#{base.schema}"."instance_projections" SET #{set} WHERE instance_id = $1),
              [Ecto.UUID.dump!(child_id)]
            )
          end

          send(test_pid, :updated)

          receive do
            :release -> :ok
          after
            H.await_ms() -> :ok
          end
        end)
      end)

    on_exit(fn -> send(holder.pid, :release) end)
    assert_receive :updated, 10_000

    nowait = fn table, column, id ->
      case Repo.query(
             ~s(SELECT 1 FROM "#{base.schema}"."#{table}" WHERE #{column} = $1 FOR UPDATE NOWAIT),
             [Ecto.UUID.dump!(id)]
           ) do
        {:ok, %{num_rows: n}} -> {:granted, n}
        {:error, %{postgres: %{code: code}}} -> {:refused, code}
      end
    end

    result = %{
      control: nowait.("instance_projections", "instance_id", child_id),
      token: nowait.("tokens", "waiting_child_instance_id", child_id),
      parent_projection: nowait.("instance_projections", "instance_id", parent_id)
    }

    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, H.await_ms())
    result
  end

  describe "X0: mechanism probe (when does an UPDATE of a child's projection row lock the parent?)" do
    setup :tenant

    test "the first UPDATE of the row takes no FK lock, the second of the same transaction does",
         %{base: base} do
      {parent_id, child_id} = pair!(base, plain_child())

      first = "status = 'active', last_event_seq = last_event_seq + 1"
      second = "status = 'error', error_detail = '{}'::jsonb"

      one = probe!(base, parent_id, child_id, [first])
      two = probe!(base, parent_id, child_id, [first, second])

      # the probe sees locks at all
      assert one.control == {:refused, :lock_not_available}
      assert two.control == {:refused, :lock_not_available}

      # one UPDATE: the old row version was written by an earlier transaction and no key column
      # changed, so Postgres skips the FK checks
      assert one.token == {:granted, 1}, inspect({one, two})
      assert one.parent_projection == {:granted, 1}, inspect({one, two})

      # two UPDATEs: the old version of the second was written by this transaction, so the FK
      # checks run and take KEY SHARE on both parent rows. This is what the landing does.
      assert two.token == {:refused, :lock_not_available}, inspect({one, two})
      assert two.parent_projection == {:refused, :lock_not_available}, inspect({one, two})
    end
  end

  # ---- X1 ---------------------------------------------------------------------------------------

  defp params(q), do: q |> Map.get(:params, []) |> Enum.map(&H.normalize/1)

  describe "X1: statement order of a landing" do
    setup :tenant

    test "the parent projection and the waiting token are locked before any write", %{base: base} do
      {parent_id, child_id} = pair!(base, plain_child())

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(set_error_fn(base, child_id))

      assert {:ok, _} = result

      parent_projection =
        Enum.find_index(queries, fn q ->
          q.query =~ "instance_projections" and q.query =~ "FOR KEY SHARE" and
            parent_id in params(q)
        end)

      waiting_token =
        Enum.find_index(queries, fn q ->
          q.query =~ "tokens" and q.query =~ "FOR KEY SHARE" and q.query =~ "waiting_child"
        end)

      event_insert = Enum.find_index(queries, &(&1.query =~ ~r/INSERT INTO "[^"]+"\."events"/))

      projection_update =
        Enum.find_index(queries, &(&1.query =~ ~r/UPDATE "[^"]+"\."instance_projections"/))

      positions = [parent_projection, waiting_token, event_insert, projection_update]

      assert Enum.all?(positions, &is_integer/1),
             inspect(Enum.map(queries, & &1.query), limit: :infinity)

      assert parent_projection < waiting_token
      assert waiting_token < event_insert
      assert waiting_token < projection_update
    end

    test "an ineligible landing and a top-level landing take no group lock", %{base: base} do
      {_parent_id, child_id} = pair!(base, plain_child())
      assert {:ok, _} = set_error_fn(base, child_id).()

      # the child is now in :error: the second landing is refused by the eligibility step
      {second, queries} =
        PlatformTenantFixture.capture_repo_queries(set_error_fn(base, child_id))

      assert {:error, {:instance_already_error, _detail}} = second
      refute Enum.any?(queries, &(&1.query =~ "FOR KEY SHARE"))

      # a top-level instance has no waiting parent: a token read, no row lock on a parent
      top = activate!(base, plain_child())
      top_id = start_instance!(base, top)

      {third, queries} = PlatformTenantFixture.capture_repo_queries(set_error_fn(base, top_id))
      assert {:ok, _} = third
      refute Enum.any?(queries, &(&1.query =~ "FOR KEY SHARE"))
    end
  end

  # ---- X2 / X3 / X4: forced AB-BA against cancel(parent) ----------------------------------------

  describe "X2/X4: FK order token first (cancel's P_p then T_p inverts the landing's FK locks)" do
    setup :token_first

    test "X2: set_instance_error/2 against cancel_instance(parent)", %{base: base} do
      overlap!(base, :set_error)
    end

    test "X4a: the HUMAN execution-error tail against cancel_instance(parent)", %{base: base} do
      overlap!(base, :human_tail)
    end

    test "X4b: the service no-matching-edge landing against cancel_instance(parent)", %{
      base: base
    } do
      overlap!(base, :service)
    end
  end

  describe "X3: FK order projection first (the cycle is unreachable, green before and after)" do
    setup :projection_first

    test "set_instance_error/2 against cancel_instance(parent)", %{base: base} do
      overlap!(base, :set_error)
    end
  end

  describe "S1: a child whose parent is no longer waiting" do
    setup :tenant

    test "a landing on a child of an already cancelled parent neither blocks nor deadlocks", %{
      base: base
    } do
      {parent_id, child_id} = pair!(base, plain_child())
      assert {:ok, _} = cancel_parent_fn(base, parent_id).()
      assert Fx.projection!(base.schema, parent_id).status == :cancelled

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(set_error_fn(base, child_id))

      assert {:ok, _} = result
      assert Fx.projection!(base.schema, child_id).status == :error
      refute_receive {:deadlock_detected, _error}, 0

      # the parent token is no longer :waiting, so the step finds no group and locks nothing
      refute Enum.any?(queries, &(&1.query =~ "FOR KEY SHARE"))
    end
  end
end
