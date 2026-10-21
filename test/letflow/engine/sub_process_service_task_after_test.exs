defmodule Letflow.Engine.SubProcessServiceTaskAfterTest do
  @moduledoc """
  ISS-0929 / Q-929 engine regression (E1-E6 of
  `lib/letflow/design/q929-vortex-8d-corrective-action-subprocess.md` section 8.2).

  When a child instance completes, `Letflow.Engine.SubProcess` advances the parent past the
  SUB_PROCESS node. Pre-fix it discarded the hop chain's pending events, so a SERVICE_TASK /
  TIMER / escalation HUMAN_TASK reached right after the SUB_PROCESS never got its
  `service_task_dispatches` / `timers` rows and the parent hung `:active` forever.

    * E1 -- SUB_PROCESS -> SERVICE_TASK -> END: exactly one pending dispatch row after the child
      completes; after the stubbed outcome the parent is COMPLETED.
    * E2 -- SUB_PROCESS -> TIMER: one pending timer row for the parent token.
    * E3 -- SUB_PROCESS -> HUMAN_TASK with escalation: the task AND one pending escalation timer.
    * E4 -- SUB_PROCESS -> HUMAN_TASK -> END unchanged.
    * E5 -- SERVICE_TASK after the SUB_PROCESS whose endpoint renders empty: the failure is routed
      to an ERROR (EXECUTION_ERROR event) instead of a crash or silent hang.
    * E6 -- the REAL Vortex fixtures end to end (critical severity -> 8D child -> close-deviation
      -> COMPLETED).

  No HTTP: the dispatcher is not run; the test performs the poller's re-entry (`mark advanced` +
  `advance_after_service_task_outcome/4`) itself, as `regulatory_review_timer_path_test.exs` does.
  Real Postgres, `async: false`. See `test/specs/ISS-0929.md`.

  ## E7 / E8 -- ISS-0975 (`lib/letflow/design/iss0975-subprocess-join-reentry-id-map.md`)

  A `PARALLEL_GATEWAY` join positioned in the PARENT's own graph, straddling a `SUB_PROCESS`
  branch and a plain `HUMAN_TASK` branch, can fire INSIDE
  `Letflow.Engine.SubProcess.build_completion_write_steps/13`'s own hop chain -- the parent's
  own advance past its `SUB_PROCESS` node, triggered by the child completing -- when the
  sibling `HUMAN_TASK` branch already arrived at the join in an earlier, unrelated hop chain.
  The join mints a synthetic, not-yet-persisted token id that is then handed straight to
  `Letflow.Engine.append_pending_event_arms_multi/7`'s own identity id_map (the ISS-0974 bug's
  5th, un-ported sibling) to arm the following SERVICE_TASK/TIMER.

  Graph shape (`parent_graph_split_sub_and_task/2`):

  ```
  START -> PARALLEL_GATEWAY(split) -> SUB_PROCESS(child) / HUMAN_TASK(task_a)
         -> PARALLEL_GATEWAY(join) -> SERVICE_TASK|TIMER -> END
  child:  START -> HUMAN_TASK(child-task) -> END
  ```

  Fail-then-pass proof (WF-02 Step 2a) -- EMPIRICALLY CONFIRMED, not assumed:
  `git stash push -- lib/letflow/engine.ex lib/letflow/engine/sub_process.ex` (restoring both to
  `origin/main`, pre-ISS-0975) and running both E7 and E8 showed the pre-fix failure mode is
  **NOT** `{:error, {:new_token_during_resume_not_supported, token_id}}` -- this design doc's own
  §0 diagnosis, predicting `reconcile_parent_tokens/5`'s guard fires first, does **not** hold for
  this graph shape. REVIEWER's own re-trace (WF-02 Step 2d gate, 2026-10-03) found this
  moduledoc's own earlier explanation for *why* ("the token is never a member of
  `final_instance_state.tokens`") was itself wrong -- `Transition.fire_join/5` places the
  join-merged token into `.tokens` identically regardless of the outgoing edge's node type
  (confirmed by instrumenting the pre-fix call path directly), so that is not the reason. The
  real mechanism: the pre-fix identity id_map hands the still-synthetic token_id straight to
  `ServiceTaskDispatch.arm_changeset/2`/`Scheduler.create/3`, building an already-cast-invalid
  changeset *at Multi-build time*; `Ecto.Multi.__apply__/4`'s own pre-flight validity scan
  (`check_operations_valid/1`) rejects that invalid changeset before executing **any**
  `Multi.run/3` callback in the whole composed Multi, so `reconcile_parent_tokens/5`'s own
  `Multi.run` step (declared earlier) never even runs to reject anything -- see
  `lib/letflow/design/q929-vortex-8d-corrective-action-subprocess.md`'s own §3.1 "SECOND
  CORRECTION" for the full trace. The ACTUAL pre-fix failure itself, verbatim from both E7 and
  E8's own runs, is the raw `Ecto.Changeset` cast error ISS-0975 originally assumed before this
  design doc's own "corrected" diagnosis -- that symptom was always accurately reported here;
  only the explanation of its mechanism was wrong and is now fixed:

  ```
  {:error, %Ecto.Changeset{errors: [token_id: {"is invalid", [type: Ecto.UUID, validation: :cast]}], ...}}
  ```

  (`Letflow.Scheduler.Timer`'s changeset for E8, `ServiceTaskDispatcher.ServiceTaskDispatch`'s for
  E7) -- i.e. Part B's bug (`append_pending_event_arms_multi/7`'s identity id_map) is the one
  actually reachable for this test's own graph shape; Part A's insert step is still structurally
  required regardless (it is what creates the real `TokenRecord` row the dispatch/timer's own
  `token_id` FK references, and what populates the `id_map` Part B reads back), but
  `reconcile_parent_tokens/5`'s own rejection guard specifically never fires on this path. Both
  tests were re-run with the fix restored and now pass: the child's own task completion
  succeeds, a real dispatch/timer row is armed keyed to a real, newly-inserted `TokenRecord.id`,
  and both the child and parent instances reach `:completed`. See this run's own final report
  for the verbatim command output.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  @parent_fixture Path.expand(
                    "../../fixtures/qa/vortex_supplier_quality_deviation_process_definition.json",
                    __DIR__
                  )
  @child_fixture Path.expand(
                   "../../fixtures/qa/vortex_8d_corrective_action_definition.json",
                   __DIR__
                 )

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # Helpers (no optional-argument defaults -- anti-patterns.md ISS-0069)
  # ---------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp provision!, do: TenantFixture.provisioned_tenant!(slug_prefix: "iss0929").schema_name

  defp create_active!(schema, name, version, graph) do
    assert {:ok, definition} =
             Definitions.create(
               %{name: name, version: version, graph: graph, created_by: Ecto.UUID.generate()},
               prefix: schema
             )

    assert {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)
    active
  end

  # REQ-462: a fixture whose HUMAN_TASKs declare required_outputs is only activatable with the
  # definition's own variable_schemas registered (check 2), as the seed scripts do.
  defp create_active_with_schemas!(schema, doc) do
    entries =
      Enum.map(doc["variable_schemas"], fn e ->
        %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
      end)

    assert {:ok, definition} =
             Definitions.create_with_variable_schemas(
               %{
                 name: doc["name"],
                 version: doc["version"],
                 graph: doc["graph"],
                 created_by: Ecto.UUID.generate()
               },
               entries,
               prefix: schema
             )

    assert {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)
    active
  end

  defp start!(schema, definition, variables) do
    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: variables,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss0929-start")
               },
               prefix: schema
             )

    result.instance_id
  end

  defp child_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "child-task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "role-x"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "c0", "source" => "start", "target" => "child-task"},
        %{"id" => "c1", "source" => "child-task", "target" => "end"}
      ]
    }
  end

  # START -> SUB_PROCESS(child_name) -> <after_node> -> END
  defp parent_graph(child_name, after_node) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        after_node,
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "sub"},
        %{"id" => "p1", "source" => "sub", "target" => after_node["id"]},
        %{"id" => "p2", "source" => after_node["id"], "target" => "end"}
      ]
    }
  end

  defp service_node(endpoint) do
    %{
      "id" => "after",
      "node_type" => "SERVICE_TASK",
      "attributes" => %{"endpoint" => endpoint, "method" => "POST", "timeout_ms" => 300_000}
    }
  end

  # Provision a tenant, activate child + parent, start the parent, return the child's pending
  # task and the ids. The child task is NOT yet completed.
  defp parent_with_child!(after_node) do
    schema = provision!()
    child_name = unique("iss0929-child")
    create_active!(schema, child_name, "1.0", child_graph())

    parent =
      create_active!(
        schema,
        unique("iss0929-parent"),
        "1.0",
        parent_graph(child_name, after_node)
      )

    parent_id = start!(schema, parent, %{"deviation_id" => "dev-1"})
    child_task = child_task!(schema, parent_id, "child-task")
    {schema, parent_id, child_task}
  end

  defp child_task!(schema, parent_instance_id, node_id) do
    child_ids =
      InstanceProjection
      |> where([p], p.parent_instance_id == ^parent_instance_id)
      |> select([p], p.instance_id)
      |> Repo.all(prefix: schema)

    assert [child_id] = child_ids
    pending_task!(schema, child_id, node_id)
  end

  defp pending_task!(schema, instance_id, node_id) do
    tasks =
      EngineTask
      |> where([t], t.instance_id == ^instance_id and t.node_id == ^node_id)
      |> Repo.all(prefix: schema)

    assert [task] = tasks
    task
  end

  defp complete!(schema, task, output) do
    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: output,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss0929-complete")
               },
               prefix: schema
             )
  end

  defp projection(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema)

  defp dispatches(schema, instance_id) do
    ServiceTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> order_by([d], asc: d.created_at)
    |> Repo.all(prefix: schema)
  end

  defp timers(schema, instance_id) do
    Timer |> where([t], t.instance_id == ^instance_id) |> Repo.all(prefix: schema)
  end

  defp event_types(schema, instance_id) do
    assert {:ok, events} = Reconstruction.read_full_log(instance_id, schema, 1)
    Enum.map(events, & &1.event_type)
  end

  # Reproduce attempt_dispatch/2's precondition (status "advanced") -- no HTTP.
  defp mark_advanced!(schema, row) do
    row |> Ecto.Changeset.change(%{status: :advanced}) |> Repo.update!(prefix: schema)
  end

  defp stub_advance!(schema, row) do
    assert {:ok, :advanced} =
             Engine.advance_after_service_task_outcome(
               mark_advanced!(schema, row).id,
               {:advance, %{}},
               Repo,
               schema
             )
  end

  # ---------------------------------------------------------------------------------
  # E1 -- the engine regression
  # ---------------------------------------------------------------------------------

  test "E1 SUB_PROCESS -> SERVICE_TASK: child completion creates exactly one pending dispatch; stub outcome completes parent" do
    {schema, parent_id, child_task} =
      parent_with_child!(service_node("https://example.test/close/{{variables.deviation_id}}"))

    complete!(schema, child_task, %{})

    proj = projection(schema, parent_id)
    assert proj.status == :active
    assert proj.current_nodes == ["after"]

    assert [row] = dispatches(schema, parent_id)
    assert row.node_id == "after"
    assert row.status == :pending
    assert row.config_snapshot["rendered_url"] == "https://example.test/close/dev-1"

    stub_advance!(schema, row)

    assert projection(schema, parent_id).status == :completed
    assert Enum.all?(dispatches(schema, parent_id), &(&1.status != :pending))

    types = event_types(schema, parent_id)
    assert "SUB_PROCESS_COMPLETED" in types
    refute "EXECUTION_ERROR" in types
  end

  # ---------------------------------------------------------------------------------
  # E2 / E3 -- timer halves of the fix
  # ---------------------------------------------------------------------------------

  test "E2 SUB_PROCESS -> TIMER: child completion arms exactly one pending timer for the parent token" do
    timer_node = %{
      "id" => "after",
      "node_type" => "TIMER",
      "attributes" => %{"duration_iso8601" => "PT1H"}
    }

    {schema, parent_id, child_task} = parent_with_child!(timer_node)
    complete!(schema, child_task, %{})

    assert projection(schema, parent_id).status == :active
    assert [%Timer{} = timer] = timers(schema, parent_id)
    assert timer.node_id == "after"
    assert timer.status == "pending"
    assert timer.token_id != nil
  end

  test "E3 SUB_PROCESS -> HUMAN_TASK with escalation: the task is created AND one pending escalation timer is armed" do
    human_node = %{
      "id" => "after",
      "node_type" => "HUMAN_TASK",
      "attributes" => %{
        "role" => "role-y",
        "escalation_timer_duration" => "PT2H",
        "escalation_role" => "role-z"
      }
    }

    {schema, parent_id, child_task} = parent_with_child!(human_node)
    complete!(schema, child_task, %{})

    assert projection(schema, parent_id).current_nodes == ["after"]
    assert %EngineTask{status: :pending} = pending_task!(schema, parent_id, "after")

    assert [%Timer{} = timer] = timers(schema, parent_id)
    assert timer.timer_type == "escalation"
    assert timer.node_id == "after"
    assert timer.status == "pending"
  end

  # ---------------------------------------------------------------------------------
  # E4 -- unchanged path
  # ---------------------------------------------------------------------------------

  test "E4 SUB_PROCESS -> plain HUMAN_TASK -> END still works: task pending, no dispatch, no timer" do
    human_node = %{
      "id" => "after",
      "node_type" => "HUMAN_TASK",
      "attributes" => %{"role" => "role-y"}
    }

    {schema, parent_id, child_task} = parent_with_child!(human_node)
    complete!(schema, child_task, %{})

    assert projection(schema, parent_id).status == :active
    after_task = pending_task!(schema, parent_id, "after")
    assert after_task.status == :pending
    assert dispatches(schema, parent_id) == []
    assert timers(schema, parent_id) == []

    complete!(schema, after_task, %{})
    assert projection(schema, parent_id).status == :completed
  end

  # ---------------------------------------------------------------------------------
  # E5 -- error channel
  # ---------------------------------------------------------------------------------

  test "E5 SERVICE_TASK after SUB_PROCESS with an empty rendered endpoint is routed to an ERROR, not a hang or crash" do
    {schema, parent_id, child_task} = parent_with_child!(service_node("{{variables.missing}}"))

    # Whatever the exact return shape of the failed completion, the observable contract is:
    # no pending dispatch row, parent flipped to :error, EXECUTION_ERROR recorded.
    _ =
      Engine.complete_task(
        child_task.id,
        %{
          output_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("iss0929-complete")
        },
        prefix: schema
      )

    assert Enum.all?(dispatches(schema, parent_id), &(&1.status != :pending))
    assert projection(schema, parent_id).status == :error
    assert "EXECUTION_ERROR" in event_types(schema, parent_id)
  end

  # ---------------------------------------------------------------------------------
  # E6 -- the real Vortex fixtures end to end
  # ---------------------------------------------------------------------------------

  test "E6 real Vortex fixtures: critical deviation -> 8D child -> close-deviation dispatch -> COMPLETED" do
    schema = provision!()
    parent_doc = @parent_fixture |> File.read!() |> Jason.decode!()
    child_doc = @child_fixture |> File.read!() |> Jason.decode!()

    create_active!(schema, child_doc["name"], child_doc["version"], child_doc["graph"])

    parent = create_active_with_schemas!(schema, parent_doc)

    parent_id = start!(schema, parent, %{"batch_ref" => "b-1", "deviation_id" => "dev-9"})

    # quarantine-batch dispatch, stub-advanced.
    assert [quarantine] = dispatches(schema, parent_id)
    assert quarantine.node_id == "quarantine-batch"
    stub_advance!(schema, quarantine)

    complete!(
      schema,
      pending_task!(schema, parent_id, "severity-classification"),
      %{"severity" => "critical", "false_positive" => false}
    )

    # Parent parked at the sub-process; the 8D child task belongs to the child instance.
    proj = projection(schema, parent_id)
    assert proj.status == :active
    assert proj.current_nodes == ["corrective-action-subprocess"]

    child_task = child_task!(schema, parent_id, "corrective-action-8d")
    assert child_task.status == :pending
    complete!(schema, child_task, %{})

    # The ISS-0929 fix: close-deviation dispatch exists (pre-fix: parent hung with none).
    assert projection(schema, parent_id).current_nodes == ["close-deviation"]
    pending = Enum.filter(dispatches(schema, parent_id), &(&1.status == :pending))
    assert [close] = pending
    assert close.node_id == "close-deviation"

    assert close.config_snapshot["rendered_url"] ==
             "https://httpbin.org/anything/quality/deviations/dev-9/close"

    stub_advance!(schema, close)

    assert projection(schema, parent_id).status == :completed
    types = event_types(schema, parent_id)
    assert "SUB_PROCESS_COMPLETED" in types
    refute "EXECUTION_ERROR" in types
  end

  # ---------------------------------------------------------------------------------
  # E7 / E8 -- ISS-0975: a join straddling a SUB_PROCESS branch and a plain
  # HUMAN_TASK branch, firing inside build_completion_write_steps/13's own
  # hop chain.
  # ---------------------------------------------------------------------------------

  # START -> PARALLEL_GATEWAY(split) -> SUB_PROCESS(child_name) / HUMAN_TASK(task_a)
  #        -> PARALLEL_GATEWAY(join) -> after_node -> END
  defp parent_graph_split_sub_and_task(child_name, after_node) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        %{
          "id" => "task_a",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "role-join-a"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        after_node,
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "q0", "source" => "start", "target" => "split"},
        %{"id" => "q1", "source" => "split", "target" => "sub"},
        %{"id" => "q2", "source" => "split", "target" => "task_a"},
        %{"id" => "q3", "source" => "sub", "target" => "join"},
        %{"id" => "q4", "source" => "task_a", "target" => "join"},
        %{"id" => "q5", "source" => "join", "target" => after_node["id"]},
        %{"id" => "q6", "source" => after_node["id"], "target" => "end"}
      ]
    }
  end

  defp timer_node_after do
    %{
      "id" => "after",
      "node_type" => "TIMER",
      "attributes" => %{"duration_iso8601" => "PT1H"}
    }
  end

  # Provisions a tenant, activates child + parent, starts the parent (which fires the
  # initial split immediately: the SUB_PROCESS branch spawns the child, the task_a branch
  # dispatches a pending HUMAN_TASK), and returns the schema, parent id, task_a's own pending
  # task, and the child's own pending task. Neither is completed yet.
  defp parent_with_split_child!(after_node) do
    schema = provision!()
    child_name = unique("iss0975-child")
    create_active!(schema, child_name, "1.0", child_graph())

    parent =
      create_active!(
        schema,
        unique("iss0975-parent"),
        "1.0",
        parent_graph_split_sub_and_task(child_name, after_node)
      )

    parent_id = start!(schema, parent, %{"deviation_id" => "dev-1"})
    task_a = pending_task!(schema, parent_id, "task_a")
    child_task = child_task!(schema, parent_id, "child-task")
    {schema, parent_id, task_a, child_task}
  end

  defp token_records(schema, instance_id) do
    TokenRecord |> where([t], t.instance_id == ^instance_id) |> Repo.all(prefix: schema)
  end

  test "E7 join straddling SUB_PROCESS + HUMAN_TASK branches -> SERVICE_TASK: child completion fires the join inside build_completion_write_steps/13, real dispatch row created" do
    {schema, parent_id, task_a, child_task} =
      parent_with_split_child!(
        service_node("https://example.test/after/{{variables.deviation_id}}")
      )

    # Branch task_a completes first -- arrives at the join, which does not fire
    # yet (the SUB_PROCESS branch hasn't arrived). Parent stays :active. This is
    # a plain complete_task/3 hop chain on the parent instance, unrelated to
    # Letflow.Engine.SubProcess.
    complete!(schema, task_a, %{})
    assert projection(schema, parent_id).status == :active

    # Completing the child's own task is what satisfies the join's last missing
    # branch -- the join fires INSIDE Letflow.Engine.SubProcess.build_completion_write_steps/13's
    # own hop chain (the parent's advance past its SUB_PROCESS node), not via
    # complete_task/3's own plain tail (ISS-0974's already-fixed path, exercised
    # by task_a's own completion above and left untouched by this design).
    assert {:ok, after_child} =
             Engine.complete_task(
               child_task.id,
               %{
                 output_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss0975-complete")
               },
               prefix: schema
             )

    assert after_child.instance_status == :completed

    # Post-fix: the parent advanced past the join onto "after", with a real
    # dispatch row keyed to a real, newly-inserted TokenRecord id -- not the
    # join's own synthetic "<origin>/join/joined" string.
    assert [dispatch] = dispatches(schema, parent_id)
    assert dispatch.node_id == "after"
    assert dispatch.status == :pending
    assert {:ok, _} = Ecto.UUID.cast(dispatch.token_id)

    records = token_records(schema, parent_id)
    assert [joined_record] = Enum.filter(records, &(&1.node_id == "after"))
    assert joined_record.id == dispatch.token_id
    assert joined_record.status == :active

    stub_advance!(schema, dispatch)

    assert projection(schema, parent_id).status == :completed
  end

  test "E8 join straddling SUB_PROCESS + HUMAN_TASK branches -> TIMER: child completion fires the join inside build_completion_write_steps/13, real timer row created" do
    {schema, parent_id, task_a, child_task} = parent_with_split_child!(timer_node_after())

    complete!(schema, task_a, %{})
    assert projection(schema, parent_id).status == :active

    assert {:ok, after_child} =
             Engine.complete_task(
               child_task.id,
               %{
                 output_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss0975-complete")
               },
               prefix: schema
             )

    assert after_child.instance_status == :completed

    assert [%Timer{} = timer] = timers(schema, parent_id)
    assert timer.node_id == "after"
    assert timer.status == "pending"
    assert {:ok, _} = Ecto.UUID.cast(timer.token_id)

    records = token_records(schema, parent_id)
    assert [joined_record] = Enum.filter(records, &(&1.node_id == "after"))
    assert joined_record.id == timer.token_id
    assert joined_record.status == :active
  end
end
