defmodule Letflow.Engine.CompleteTaskFormHookLocksTest do
  @moduledoc """
  REQ-605 / GH #3409 (decision 0067 D9, decision 0061 items 3 to 8, slice F-3 part B), tests
  L1..L3 of the T-0829 design. Sandbox `:auto` mode (real commits, real parallel connections),
  hence `async: false`.

    * L1 (criterion 7): while the script runs, the transaction holds the `tasks` row and the
      instance projection row, and none of the ancestor, entity-type sequence, own sequence, token
      or audit chain rows. A probe on its own connection (`FOR UPDATE NOWAIT`) runs from inside the
      runner stub.
    * L2 (criterion 8): after a busy answer the locks are free BEFORE the backoff and the next
      attempt starts only after it (at least the fixed 25 ms).
    * L3 (criterion 10a): a stub that runs for `FormValidation.max_timeout_ms/0` and a second
      completion of the same task on a second connection; wait time and outcome are printed as a
      `LOCKWAIT_MS=` line for the PR.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine.Contention
  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Scripts.FormValidation
  alias Letflow.Scripts.HmacSecret
  alias Letflow.Support.ScriptTaskFixture, as: F
  alias Letflow.Test.SandboxAutoMode

  defmodule StubRunner do
    @moduledoc false
    # The behaviour is a 0-arity-per-call function kept in the application env: `fun.(call_no, opts)`.
    def start, do: Agent.start_link(fn -> 0 end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def calls, do: Agent.get(__MODULE__, & &1)

    def run(_source, _input, opts) do
      n = Agent.get_and_update(__MODULE__, &{&1 + 1, &1 + 1})
      Application.fetch_env!(:letflow, :f3b_stub_fun).(n, opts)
    end
  end

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    base = Fx.committed_tenant_case!("f3b-lk")
    tenant_id = base.tenant.tenant_id
    :ok = HmacSecret.ensure(%{id: tenant_id})

    on_exit(fn ->
      Repo.delete_all(from(s in Letflow.Secrets.Secret, where: s.tenant_id == ^tenant_id))
      Fx.drop_committed_tenant!(tenant_id)
    end)

    set_env(:form_validation_hook_enabled, true)
    {:ok, _pid} = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:form_validation_script_runner, StubRunner)

    rule =
      F.published!(base.schema, "fv_f3b_lk", "return { ok = true }", manifest(),
        hook_kind: "form_validation"
      )

    Fx.define_type!(base.schema, "stock_move", %{})
    %{base: base, rule: rule}
  end

  defp set_env(key, value) do
    previous = Application.fetch_env(:letflow, key)
    Application.put_env(:letflow, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, key, old)
        :error -> Application.delete_env(:letflow, key)
      end
    end)
  end

  defp manifest do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "integer"}}
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{
          "ok" => %{"type" => "boolean"},
          "code" => %{"type" => "string"},
          "fields" => %{"type" => "array"}
        },
        "additionalProperties" => false
      },
      "fail_codes" => [],
      "refusal_codes" => ["too_small"],
      "fields" => ["amount"],
      "limits" => %{"timeout_ms" => 50}
    }
  end

  defp accept,
    do:
      {:ok,
       %{
         output: %{"ok" => true},
         stats: %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9}
       }}

  defp busy, do: {:error, :script_busy, %{}}

  # START -> ht (hook + one entity-write line on `stock_move`) -> END. The line makes the later
  # `maybe_entity_writes` step lock the type rows, so a granted probe on them is not vacuous.
  defp hook_graph(rule) do
    graph = Fx.graph([Fx.line("stock_move", %{"label" => %{"const" => "x"}})])

    update_in(graph, ["nodes"], fn nodes ->
      Enum.map(nodes, fn
        %{"id" => "ht"} = node ->
          update_in(node, ["attributes"], fn attrs ->
            Map.merge(attrs, %{
              "validation_script_key" => rule.key,
              "validation_script_version" => rule.version
            })
          end)

        node ->
          node
      end)
    end)
  end

  defp start_case!(base, rule, graph \\ nil) do
    definition = Fx.activate!(base.schema, base.user, graph || hook_graph(rule))
    {instance_id, task} = Fx.start!(base.schema, definition)
    %{instance_id: instance_id, task: task}
  end

  defp complete(base, task, output \\ %{"amount" => 5}) do
    Engine.complete_task(
      task.id,
      %{
        output_variables: output,
        actor_id: base.user.id,
        idempotency_key: Fx.unique("f3b-complete")
      },
      prefix: base.schema
    )
  end

  # One probe on its own connection (autocommit): granted or refused, never waiting.
  defp nowait(schema, sql_tail, params) do
    Task.async(fn ->
      case Repo.query(~s(SELECT 1 FROM "#{schema}".#{sql_tail} FOR UPDATE NOWAIT), params) do
        {:ok, %{num_rows: n}} -> {:granted, n}
        {:error, %{postgres: %{code: code}}} -> {:refused, code}
      end
    end)
    |> Task.await(10_000)
  end

  defp probe_tasks_row(schema, task_id),
    do: nowait(schema, ~s("tasks" WHERE id = $1), [Ecto.UUID.dump!(task_id)])

  defp probe_projection(schema, instance_id),
    do:
      nowait(schema, ~s("instance_projections" WHERE instance_id = $1), [
        Ecto.UUID.dump!(instance_id)
      ])

  describe "criterion 7: lock set while the script runs" do
    test "L1 only the tasks row and the projection row are held; ancestors, type, own sequence, tokens, audit chain are free",
         %{base: base, rule: rule} do
      schema = base.schema

      # A SUB_PROCESS parent whose child is the hook node's instance.
      child_def = Fx.activate!(schema, base.user, hook_graph(rule))

      parent_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "sp",
            "node_type" => "SUB_PROCESS",
            "attributes" => %{"definition_name" => child_def.name}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "p1", "source" => "start", "target" => "sp"},
          %{"id" => "p2", "source" => "sp", "target" => "end"}
        ]
      }

      parent_def = Fx.activate!(schema, base.user, parent_graph)

      {:ok, %{instance_id: parent_id}} =
        Engine.create(
          %{
            definition_id: parent_def.id,
            initial_variables: %{},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("f3b-parent")
          },
          prefix: schema
        )

      child_id =
        Repo.one!(
          from(p in Letflow.EventStore.InstanceProjection,
            where: p.parent_instance_id == ^parent_id and p.definition_id == ^child_def.id,
            select: p.instance_id
          ),
          prefix: schema
        )

      # Warm-up: one completion of a plain instance of the same definition writes a record, so the
      # entity type's synthetic instance and its sequence row exist before the probed completion.
      Application.put_env(:letflow, :f3b_stub_fun, fn _n, _opts -> accept() end)
      {_warm_id, warm_task} = Fx.start!(schema, child_def)
      assert {:ok, _} = complete(base, warm_task)

      task = Fx.pending_task!(schema, child_id)
      test_pid = self()

      Application.put_env(:letflow, :f3b_stub_fun, fn _n, _opts ->
        # The entity type's synthetic instance (registry row); its sequence row exists after the
        # warm-up completion above wrote a record.
        type_ids =
          Repo.query!(~s|SELECT instance_id FROM "#{schema}"."entity_type_instances"|).rows
          |> Enum.map(fn [id] -> id end)

        result = %{
          task: probe_tasks_row(schema, task.id),
          child_projection: probe_projection(schema, child_id),
          parent_projection: probe_projection(schema, parent_id),
          parent_token:
            nowait(schema, ~s("tokens" WHERE waiting_child_instance_id = $1), [
              Ecto.UUID.dump!(child_id)
            ]),
          own_tokens:
            nowait(schema, ~s("tokens" WHERE instance_id = $1), [Ecto.UUID.dump!(child_id)]),
          own_sequence:
            nowait(schema, ~s("instance_sequence" WHERE instance_id = $1), [
              Ecto.UUID.dump!(child_id)
            ]),
          type_sequences:
            Enum.map(
              type_ids,
              &nowait(schema, ~s("instance_sequence" WHERE instance_id = $1), [&1])
            ),
          audit_chain: nowait(schema, ~s("audit_chain_locks"), [])
        }

        send(test_pid, {:probes, result})
        accept()
      end)

      on_exit(fn -> Application.delete_env(:letflow, :f3b_stub_fun) end)

      assert {:ok, _} = complete(base, task)
      assert_receive {:probes, probes}

      assert {:refused, _} = probes.task
      assert {:refused, _} = probes.child_projection
      assert {:granted, 1} = probes.parent_projection
      assert {:granted, 1} = probes.parent_token
      assert {:granted, n} = probes.own_tokens
      assert n >= 1
      assert {:granted, 1} = probes.own_sequence
      assert probes.type_sequences != [], "the entity type must have a sequence row to probe"
      assert Enum.all?(probes.type_sequences, &match?({:granted, 1}, &1))
      assert {:granted, 1} = probes.audit_chain
    end
  end

  describe "criterion 8: release before the backoff" do
    test "L2 the tasks row is free before attempt 2 starts, and the backoff separates them",
         %{base: base, rule: rule} do
      %{task: task} = start_case!(base, rule)
      schema = base.schema
      test_pid = self()
      {:ok, log} = Agent.start_link(fn -> %{} end)

      Application.put_env(:letflow, :f3b_stub_fun, fn n, _opts ->
        now = System.monotonic_time(:millisecond)

        case n do
          1 ->
            # The transaction is open: the probe is refused until the rollback, then granted.
            Agent.update(log, &Map.put(&1, :first_probe, probe_tasks_row(schema, task.id)))

            spawn_link(fn ->
              t_free = wait_until_granted(schema, task.id)
              send(test_pid, {:t_free, t_free})
            end)

            Agent.update(log, &Map.put(&1, :t_call1_end, System.monotonic_time(:millisecond)))

          2 ->
            Agent.update(log, &Map.put(&1, :t_start2, now))

          _ ->
            :ok
        end

        busy()
      end)

      on_exit(fn -> Application.delete_env(:letflow, :f3b_stub_fun) end)

      assert {:error, {:form_hook_failed, :script_busy}} = complete(base, task)
      assert StubRunner.calls() == 3
      assert_receive {:t_free, t_free}, 5_000

      log = Agent.get(log, & &1)
      assert {:refused, _} = log.first_probe
      assert t_free <= log.t_start2
      assert log.t_start2 - log.t_call1_end >= 25

      assert {:granted, 1} = probe_tasks_row(schema, task.id)
      assert Repo.get!(Engine.Task, task.id, prefix: schema).status == :pending
    end
  end

  defp wait_until_granted(schema, task_id) do
    case probe_tasks_row(schema, task_id) do
      {:granted, _} ->
        System.monotonic_time(:millisecond)

      {:refused, _} ->
        Process.sleep(2)
        wait_until_granted(schema, task_id)
    end
  end

  describe "criterion 10a: lock wait of a second completion" do
    test "L3 a second completion waits for the first one's script run; wait and outcome printed",
         %{base: base, rule: rule} do
      %{task: task} = start_case!(base, rule)
      test_pid = self()

      Application.put_env(:letflow, :f3b_stub_fun, fn _n, _opts ->
        send(test_pid, :in_hook)
        Process.sleep(FormValidation.max_timeout_ms())
        accept()
      end)

      on_exit(fn -> Application.delete_env(:letflow, :f3b_stub_fun) end)

      first = Task.async(fn -> complete(base, task) end)
      assert_receive :in_hook, 10_000

      started = System.monotonic_time(:millisecond)
      second = Task.async(fn -> complete(base, task) end)
      second_result = Task.await(second, 30_000)
      waited = System.monotonic_time(:millisecond) - started
      first_result = Task.await(first, 30_000)

      IO.puts(
        "LOCKWAIT_MS=#{waited} OUTCOME=#{inspect(second_result)} " <>
          "HOOK_MS=#{FormValidation.max_timeout_ms()} LOCK_TIMEOUT_MS=#{Contention.lock_timeout_ms()}"
      )

      assert {:ok, _} = first_result
      assert {:error, _} = second_result
      assert StubRunner.calls() == 1
      assert waited < Contention.lock_timeout_ms()
    end
  end
end
