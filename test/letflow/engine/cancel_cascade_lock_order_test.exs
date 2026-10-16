defmodule Letflow.Engine.CancelCascadeLockOrderTest do
  @moduledoc """
  GH #2695 (design `lib/letflow/design/gh2695-cancel-cascade-lock-order.md`, section 5): a parent
  `cancel_instance/3` against the completion of its sub-process child, in both orders, on the
  HUMAN path (H, `complete_task/3`) and the HTTP service path (S,
  `advance_after_service_task_outcome/4`).

  Determinism without sleep-coupled timing: a third connection `Z` holds ONE
  `instance_sequence` row (a barrier), the two workers run on their own pinned connections
  (`Repo.checkout/1`, each reporting `pg_backend_pid()`), and the test polls (bounded, 10 ms
  steps, 500 steps) until the number of DISTINCT blocked backends among the workers' pids reaches
  the expected count. Only then is `Z` released. Order is therefore forced by lock state.

  A deadlock victim of the service path is silently re-applied by the engine, so the test also
  attaches a telemetry handler on the Repo query event and fails on any `deadlock_detected`
  (`40P01`) query error from any process, retried or not.

  Sandbox `:auto` mode (real commits, real connections), hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Engine
  alias Letflow.Engine.SubProcess
  alias Letflow.Engine.TokenRecord
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  @poll_steps 500
  @poll_ms 10
  @await_ms 15_000

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    base = Fx.committed_tenant_case!("gh2695-lock")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)

    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        &__MODULE__.handle_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{base: base}
  end

  @doc false
  def handle_query(_event, _measurements, %{result: {:error, error}}, test_pid) do
    if match?(%Postgrex.Error{postgres: %{code: :deadlock_detected}}, error),
      do: send(test_pid, {:deadlock_detected, error})

    :ok
  end

  def handle_query(_event, _measurements, _metadata, _test_pid), do: :ok

  # ---- fixtures ---------------------------------------------------------------------------------

  defp child_graph(:human), do: Fx.graph([])

  # START -> HUMAN "ct" -> SERVICE_TASK "svc" (HTTP) -> END. The human task comes first because a
  # child created by a SUB_PROCESS node arms no dispatch row for a SERVICE_TASK directly after
  # START; completing "ct" (done in `scenario/2`, before any race) arms it.
  defp child_graph(:service) do
    svc = Fx.service_graph([])["nodes"] |> Enum.find(&(&1["id"] == "svc"))

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ct", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        svc,
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ct"},
        %{"id" => "e2", "source" => "ct", "target" => "svc"},
        %{"id" => "e3", "source" => "svc", "target" => "end"}
      ]
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
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "end"}
      ]
    }
  end

  # Parent `start -> sp -> end`, its running child (HUMAN or HTTP SERVICE node), and the two
  # closures: `complete` (the child's completion, D) and `cancel` (the parent's cancel, C).
  defp scenario(base, path) do
    child_def = Fx.activate!(base.schema, base.user, child_graph(path))
    parent_def = Fx.activate!(base.schema, base.user, parent_graph(child_def.name))

    {:ok, %{instance_id: parent_id}} =
      Engine.create(
        %{
          definition_id: parent_def.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("cc-start")
        },
        prefix: base.schema
      )

    child =
      Repo.one!(from(p in InstanceProjection, where: p.parent_instance_id == ^parent_id),
        prefix: base.schema
      )

    complete =
      case path do
        :human ->
          task = Fx.pending_task!(base.schema, child.instance_id)

          fn ->
            Engine.complete_task(
              task.id,
              %{
                output_variables: %{},
                actor_id: base.user.id,
                idempotency_key: Fx.unique("cc-complete")
              },
              prefix: base.schema
            )
          end

        :service ->
          ct = Fx.pending_task!(base.schema, child.instance_id)

          assert {:ok, _} =
                   Engine.complete_task(
                     ct.id,
                     %{
                       output_variables: %{},
                       actor_id: base.user.id,
                       idempotency_key: Fx.unique("cc-ct")
                     },
                     prefix: base.schema
                   )

          dispatch =
            from(d in Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch,
              where: d.instance_id == ^child.instance_id
            )
            |> Repo.one!(prefix: base.schema)
            |> Ecto.Changeset.change(%{status: "advanced"})
            |> Repo.update!(prefix: base.schema)

          fn ->
            Engine.advance_after_service_task_outcome(
              dispatch.id,
              {:advance, %{}},
              Repo,
              base.schema
            )
          end
      end

    cancel = fn ->
      Engine.cancel_instance(
        parent_id,
        %{actor_id: base.user.id, idempotency_key: Fx.unique("cc-cancel")},
        prefix: base.schema
      )
    end

    %{parent_id: parent_id, child_id: child.instance_id, complete: complete, cancel: cancel}
  end

  # ---- barrier and workers ----------------------------------------------------------------------

  defp hold_sequence_row(schema, instance_id) do
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            ~s(SELECT 1 FROM "#{schema}"."instance_sequence" WHERE instance_id = $1 FOR UPDATE),
            [Ecto.UUID.dump!(instance_id)]
          )

          send(test_pid, :held)

          receive do
            :release -> :ok
          after
            @await_ms -> :ok
          end
        end)
      end)

    on_exit(fn -> send(holder.pid, :release) end)
    assert_receive :held, 10_000
    holder
  end

  # A worker on its own pinned connection; returns `{task, backend_pid}`.
  defp start_worker(fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, self(), pid})
          fun.()
        end)
      end)

    task_pid = task.pid
    assert_receive {:backend, ^task_pid, backend_pid}, 10_000
    {task, backend_pid}
  end

  # Waits until `n` DISTINCT workers are blocked on a lock; bounded.
  defp wait_for_blocked(pids, n) do
    sql = """
    SELECT count(DISTINCT a.pid)
    FROM pg_stat_activity a
    JOIN pg_locks l ON l.pid = a.pid AND NOT l.granted
    WHERE a.pid = ANY($1) AND a.wait_event_type = 'Lock'
    """

    blocked =
      Enum.reduce_while(1..@poll_steps, 0, fn _step, _last ->
        %{rows: [[count]]} = Repo.query!(sql, [pids])

        if count >= n do
          {:halt, count}
        else
          Process.sleep(@poll_ms)
          {:cont, count}
        end
      end)

    assert blocked >= n,
           "expected #{n} distinct blocked worker backend(s) within the poll bound, saw #{blocked}"
  end

  # first/second are :complete or :cancel; the barrier row is held until both are parked.
  defp run(base, path, barrier, order) do
    s = scenario(base, path)

    barrier_instance =
      case barrier do
        :child -> s.child_id
        :parent -> s.parent_id
      end

    holder = hold_sequence_row(base.schema, barrier_instance)

    {first, second} =
      case order do
        :complete_first -> {s.complete, s.cancel}
        :cancel_first -> {s.cancel, s.complete}
      end

    {t1, pid1} = start_worker(first)
    wait_for_blocked([pid1], 1)
    {t2, pid2} = start_worker(second)
    wait_for_blocked([pid1, pid2], 2)

    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, @await_ms)

    {r1, r2} = {Task.await(t1, @await_ms), Task.await(t2, @await_ms)}

    results =
      case order do
        :complete_first -> %{complete: r1, cancel: r2}
        :cancel_first -> %{complete: r2, cancel: r1}
      end

    refute_receive {:deadlock_detected, _error}, 0
    refute inspect(results) =~ "40P01"
    refute inspect(results) =~ "deadlock"
    Map.merge(s, %{results: results})
  end

  # ---- shared end-state assertions ---------------------------------------------------------------

  defp token_statuses(schema, instance_id) do
    TokenRecord
    |> where([t], t.instance_id == ^instance_id)
    |> select([t], t.status)
    |> Repo.all(prefix: schema)
  end

  defp assert_invariants(base, s, expected_cancel_audits) do
    schema = base.schema

    assert Fx.projection!(schema, s.child_id).status == :completed
    assert Fx.dlq_entries(schema) == []
    assert Fx.instance_events(schema, s.parent_id, "EXECUTION_ERROR") == []

    assert length(Fx.audit_rows(schema, "instance.cancel")) == expected_cancel_audits
    assert {:ok, :valid} = Audit.verify_chain(schema)
  end

  defp assert_cancel_won(base, s) do
    schema = base.schema
    assert {:ok, _} = s.results.cancel
    assert {:ok, _} = s.results.complete
    assert Fx.projection!(schema, s.parent_id).status == :cancelled
    assert token_statuses(schema, s.parent_id) == [:cancelled]
    assert Fx.instance_events(schema, s.parent_id, "SUB_PROCESS_COMPLETED") == []
    assert_invariants(base, s, 1)
  end

  defp assert_cascade_won(base, s) do
    schema = base.schema
    assert {:ok, _} = s.results.complete
    assert {:error, {:instance_already_terminal, :completed}} = s.results.cancel
    assert Fx.projection!(schema, s.parent_id).status == :completed
    assert [_one] = Fx.instance_events(schema, s.parent_id, "SUB_PROCESS_COMPLETED")
    assert_invariants(base, s, 0)
  end

  # ---- the four interleavings --------------------------------------------------------------------

  describe "HUMAN child completion (H)" do
    test "T1: completion first, cancel second, barrier on the child's sequence row", %{base: base} do
      s = run(base, :human, :child, :complete_first)
      assert_cascade_won(base, s)
    end

    test "T2: cancel first, completion second, barrier on the parent's sequence row", %{
      base: base
    } do
      s = run(base, :human, :parent, :cancel_first)
      assert_cancel_won(base, s)
    end
  end

  describe "HTTP service child completion (S)" do
    test "T3: completion first, cancel second, barrier on the parent's sequence row", %{
      base: base
    } do
      s = run(base, :service, :parent, :complete_first)
      assert_cascade_won(base, s)
    end

    test "T4: cancel first, completion second, barrier on the parent's sequence row", %{
      base: base
    } do
      s = run(base, :service, :parent, :cancel_first)
      assert_cancel_won(base, s)
    end
  end

  describe "statement order of an uncontended child completion (GH #2695, AC 1)" do
    # The parent projection `FOR UPDATE` comes before the waiting-token `FOR UPDATE`, which comes
    # before the audit chain row (HUMAN: the early `:lock_ancestors` step; service: the cascade's
    # own lookup). Deterministic: no concurrency, the statement log of one completion.
    for path <- [:human, :service] do
      test "#{path}: parent projection, then waiting token, then the audit chain row", %{
        base: base
      } do
        s = scenario(base, unquote(path))

        {result, queries} = PlatformTenantFixture.capture_repo_queries(s.complete)
        assert {:ok, _} = result

        locks =
          for %{query: sql} = q <- queries, sql =~ "FOR UPDATE" do
            param = q |> Map.get(:params, []) |> List.first() |> normalize()

            cond do
              sql =~ "instance_projections" and param == s.parent_id -> :parent_projection
              sql =~ "tokens" and sql =~ "waiting_child_instance_id" -> :waiting_token
              sql =~ "audit_chain_locks" -> :audit_chain
              true -> :other
            end
          end

        index = fn kind -> Enum.find_index(locks, &(&1 == kind)) end

        assert is_integer(index.(:parent_projection)),
               "the parent projection is locked FOR UPDATE"

        assert is_integer(index.(:waiting_token))
        assert index.(:parent_projection) < index.(:waiting_token)

        if unquote(path) == :human do
          assert is_integer(index.(:audit_chain))
          assert index.(:waiting_token) < index.(:audit_chain)
        end
      end
    end

    defp normalize(param) when is_binary(param) and byte_size(param) == 16,
      do: Ecto.UUID.load!(param)

    defp normalize(param), do: param
  end

  describe "SubProcess.lock_waiting_parent/3 and lock_waiting_parent_chain/3" do
    test "nil for a non-child, the token for a waiting parent, nil once cancelled", %{base: base} do
      s = scenario(base, :human)
      schema = base.schema

      {:ok, result} =
        Repo.transaction(fn ->
          {:ok, none} = SubProcess.lock_waiting_parent(Repo, Ecto.UUID.generate(), schema)
          {:ok, orphan} = SubProcess.lock_waiting_parent(Repo, s.parent_id, schema)
          {:ok, token} = SubProcess.lock_waiting_parent(Repo, s.child_id, schema)
          {:ok, delegate} = SubProcess.find_waiting_parent_token(Repo, s.child_id, schema)
          {none, orphan, token, delegate}
        end)

      assert {nil, nil, %TokenRecord{} = token, %TokenRecord{id: same_id}} = result
      assert token.id == same_id
      assert token.instance_id == s.parent_id
      assert token.status == :waiting

      assert {:ok, _} = s.cancel.()

      assert {:ok, nil} =
               Repo.transaction(fn ->
                 {:ok, t} = SubProcess.lock_waiting_parent(Repo, s.child_id, schema)
                 t
               end)
    end

    test "chain: a three-level fixture returns the two tokens, nearest first", %{base: base} do
      schema = base.schema
      leaf = Fx.activate!(schema, base.user, Fx.graph([]))

      # START -> HUMAN "mt" -> SUB_PROCESS(leaf) -> END: a child's own initial hop chain spawns
      # no grandchild, so the leaf is created when "mt" completes.
      middle_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "mt", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
          %{
            "id" => "sp",
            "node_type" => "SUB_PROCESS",
            "attributes" => %{"definition_name" => leaf.name}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "mt"},
          %{"id" => "e2", "source" => "mt", "target" => "sp"},
          %{"id" => "e3", "source" => "sp", "target" => "end"}
        ]
      }

      middle = Fx.activate!(schema, base.user, middle_graph)
      top = Fx.activate!(schema, base.user, parent_graph(middle.name))

      {:ok, %{instance_id: top_id}} =
        Engine.create(
          %{
            definition_id: top.id,
            initial_variables: %{},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("cc-chain")
          },
          prefix: schema
        )

      middle_id =
        Repo.one!(
          from(p in InstanceProjection,
            where: p.parent_instance_id == ^top_id,
            select: p.instance_id
          ),
          prefix: schema
        )

      mt = Fx.pending_task!(schema, middle_id)

      assert {:ok, _} =
               Engine.complete_task(
                 mt.id,
                 %{
                   output_variables: %{},
                   actor_id: base.user.id,
                   idempotency_key: Fx.unique("cc-mt")
                 },
                 prefix: schema
               )

      leaf_id =
        Repo.one!(
          from(p in InstanceProjection,
            where: p.parent_instance_id == ^middle_id,
            select: p.instance_id
          ),
          prefix: schema
        )

      assert {:ok, {:ok, tokens}} =
               Repo.transaction(fn ->
                 SubProcess.lock_waiting_parent_chain(Repo, leaf_id, schema)
               end)

      assert Enum.map(tokens, & &1.instance_id) == [middle_id, top_id]
    end
  end
end
