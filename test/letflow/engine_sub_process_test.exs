defmodule Letflow.EngineSubProcessTest do
  @moduledoc """
  DB-integration tests for REQ-062's SPC-01 sub-process runtime half -- real child
  instance creation via `Letflow.Engine.create/2`'s activation loop, completion
  propagation via `Letflow.Engine.complete_task/3`'s hop chain, and the four SPC-01
  failure modes, all driven through the real public `Letflow.Engine`/`Letflow.Definitions`
  surface (never a direct `Letflow.Engine.SubProcess` call) so these tests exercise the
  exact transaction shape a real caller would trigger. See
  `lib/letflow/design/req062-sub-process-runtime.md` and `test/specs/REQ-062.md` for the
  full design/AC-to-test-case mapping. Pure-layer coverage (input/output filtering,
  `Transition`'s new `:SUB_PROCESS` dispatch clauses, the AC5 GH-428 struct-update
  regression) lives in `test/letflow/engine/sub_process_test.exs`.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. Mirrors
  `test/letflow/engine_complete_task_test.exs`'s own `provisioned_tenant/0` + Sandbox
  `:auto` + `async: false` pattern, registering the extra event types this module's own
  new code appends (`SUB_PROCESS_COMPLETED`) alongside the pre-existing
  `TASK_COMPLETED`/`EXECUTION_ERROR` every failure-mode/completion test needs.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.Engine.VariableSchema
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  #
  # INSTANCE_STARTED, TASK_COMPLETED, EXECUTION_ERROR, SUB_PROCESS_COMPLETED, and
  # INSTANCE_CANCELLED are all auto-seeded by replay_migrations/2's default manifest
  # (REQ-045 §9 OQ-3a, extended by ISS-0072/GH#257) -- this fixture used to
  # self-register the latter four against a permissive `%{"type" => "object"}` schema
  # (ISS-0073/GH#267: that duplicate registration now collides with provisioning's own
  # seed and hard-fails). Removed rather than reconciled: this file's actual event
  # payloads are produced by the same production writers (Engine.complete_task/3,
  # ExecutionError.append_execution_error_event/2, the SUB_PROCESS_COMPLETED and
  # cancel_instance/3 paths) that provisioning's own stricter schema was written to
  # validate, so relying on the real seed here isn't a coverage loss.
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req062",
      display_name: "REQ-062 Test Tenant"
    )
  end

  defp unique_name(prefix \\ "req062-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp create_definition_attrs(graph) do
    %{
      name: unique_name(),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # A 2-step child: START -> HUMAN_TASK("work") -> END. Deliberately does NOT complete
  # synchronously at creation time -- every test needs to observe the parent's
  # waiting_child_instance_id/:waiting state, and independently drive the child's own
  # completion via a real Engine.complete_task/3 call.
  defp graph_child_two_step do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "work", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "worker"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "work"},
        %{"id" => "e2", "source" => "work", "target" => "end"}
      ]
    }
  end

  # START -> SUB_PROCESS("sp") -> END. sp's own attributes (definition_name, optionally
  # interface) are injected by each test via `sp_attributes`.
  defp graph_parent_subprocess_root(child_definition_name, interface \\ nil) do
    sp_attributes =
      case interface do
        nil -> %{"definition_name" => child_definition_name}
        iface -> %{"definition_name" => child_definition_name, "interface" => iface}
      end

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "sp", "node_type" => "SUB_PROCESS", "attributes" => sp_attributes},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "end"}
      ]
    }
  end

  # START -> SUB_PROCESS("sp") -> HUMAN_TASK("after") -> END -- used by AC5's set/clear
  # test, which needs a surviving parent token row to inspect post-completion (the
  # 2-node root-SUB_PROCESS graph above removes the token outright on :END).
  defp graph_parent_subprocess_then_task(child_definition_name, interface \\ nil) do
    sp_attributes =
      case interface do
        nil -> %{"definition_name" => child_definition_name}
        iface -> %{"definition_name" => child_definition_name, "interface" => iface}
      end

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "sp", "node_type" => "SUB_PROCESS", "attributes" => sp_attributes},
        %{"id" => "after", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "closer"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "after"},
        %{"id" => "e3", "source" => "after", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK("gate") -> SUB_PROCESS("sp") -> END -- used by the two
  # activation-time (input) failure-mode tests, which need the SUB_PROCESS node to be
  # reached via a task-completion hop chain (Engine.complete_task/3), not create/2's own
  # root-node path, so the failure has an already-persisted parent instance to route into
  # ExecutionError against (AC8) -- create/2's own root-SUB_PROCESS path has no persisted
  # parent yet for a failure there to attach to (design doc §3.3).
  defp graph_parent_task_then_subprocess(child_definition_name, interface) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gate", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "gater"}},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_definition_name, "interface" => interface}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gate"},
        %{"id" => "e2", "source" => "gate", "target" => "sp"},
        %{"id" => "e3", "source" => "sp", "target" => "end"}
      ]
    }
  end

  # ISS-0067: START -> HUMAN_TASK("gate") -> PARALLEL_GATEWAY("split") ->
  # {SUB_PROCESS("sp1"), SUB_PROCESS("sp2")} -> PARALLEL_GATEWAY("join") -> END.
  # Completing "gate" mints two derived split-branch token_ids
  # ("#{gate_token.id}/0", "#{gate_token.id}/1") purely in-memory
  # (Transition.dispatch_parallel_split/4) that land directly on sp1/sp2
  # within the SAME hop chain, before either branch ever gets its own
  # persisted `tokens` row -- exactly the "parent token_id is a derived
  # split/join branch id, not a persisted one" scenario
  # resolve_parent_token_record_id/2 must reject. sp1/sp2's own edges both
  # converge on "join" (single-hop, so find_matching_join/2's
  # walk_to_gateway/3 accepts this as a legal block-structured split) so the
  # split itself dispatches successfully -- the rejection happens one hop
  # later, when advance_until_stable/4 dispatches sp1/sp2 themselves.
  defp graph_parent_split_then_subprocess(child_definition_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gate", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "gater"}},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "sp1",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_definition_name}
        },
        %{
          "id" => "sp2",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_definition_name}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gate"},
        %{"id" => "e2", "source" => "gate", "target" => "split"},
        %{"id" => "e3", "source" => "split", "target" => "sp1"},
        %{"id" => "e4", "source" => "split", "target" => "sp2"},
        %{"id" => "e5", "source" => "sp1", "target" => "join"},
        %{"id" => "e6", "source" => "sp2", "target" => "join"},
        %{"id" => "e7", "source" => "join", "target" => "end"}
      ]
    }
  end

  # ISS-0067's positive counterpart to graph_parent_split_then_subprocess/1
  # above: START -> HUMAN_TASK("gate") -> SUB_PROCESS("sp") -> END, no
  # split/join anywhere on the graph, so the token reaching "sp" is exactly
  # "gate"'s own genuinely persisted `tokens.id`. Deliberately not
  # graph_parent_task_then_subprocess/2 (already in use by the AC3 interface-
  # violation tests, which fail at SubProcess.prepare_child_activation/4,
  # AFTER resolve_parent_token_record_id/2 already accepted the id) -- this
  # helper's whole point is a hop chain that also succeeds, so the accept
  # branch is asserted at the public Engine.complete_task/3 boundary, not
  # just implied by a later, unrelated failure.
  defp graph_parent_task_then_subprocess_no_split(child_definition_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gate", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "gater"}},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_definition_name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gate"},
        %{"id" => "e2", "source" => "gate", "target" => "sp"},
        %{"id" => "e3", "source" => "sp", "target" => "end"}
      ]
    }
  end

  # ISS-0392: a synchronously-completing child -- START -> END, no intervening task at
  # all. Deliberately the ONLY graph in this file with no HUMAN_TASK node: every other
  # child helper (graph_child_two_step/0 above) exists precisely so its own completion
  # must be independently driven, but ISS-0392's collision only fires when
  # prepare_child_activation/4 drives the child to InstanceState.status == :completed
  # synchronously, inside the SAME transaction as the parent hop chain that spawned it
  # (design doc iss0392-multi-task-records-collision-fix.md §5, point 2) -- a graph with
  # any pending task in it would leave the child :active instead, never exercising the
  # collision this test proves fixed.
  defp graph_child_immediate do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "end"}
      ]
    }
  end

  # ISS-0396: START -> PARALLEL_GATEWAY("split") -> {SUB_PROCESS("sp1"),
  # SUB_PROCESS("sp2")} -> PARALLEL_GATEWAY("join") -> END. Same edge/node JSON
  # shape as graph_parent_split_then_subprocess/1 above, but with "start"
  # feeding directly into "split" -- no intervening HUMAN_TASK("gate") --
  # because this scenario is exercised via Engine.create/2's own root
  # activation (design doc iss0396-task-records-multi-sibling-fix.md §1), not
  # via a completing task: unlike graph_parent_split_then_subprocess/1's
  # sp1/sp2 (whose parent token_ids are derived split-branch ids, rejected by
  # resolve_parent_token_record_id/2 per ISS-0067), sp1/sp2 here are reached
  # directly by Engine.create/2's own activate/3 path, which has no such
  # "already persisted" membership check at all (§1).
  defp graph_root_split_into_two_subprocesses(child_definition_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "sp1",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_definition_name}
        },
        %{
          "id" => "sp2",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_definition_name}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "sp1"},
        %{"id" => "e3", "source" => "split", "target" => "sp2"},
        %{"id" => "e4", "source" => "sp1", "target" => "join"},
        %{"id" => "e5", "source" => "sp2", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "end"}
      ]
    }
  end

  defp start_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("start")
      },
      overrides
    )
  end

  defp complete_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("complete")
      },
      overrides
    )
  end

  defp child_projection!(schema_name, parent_instance_id) do
    InstanceProjection
    |> where([p], p.parent_instance_id == ^parent_instance_id)
    |> Repo.one!(prefix: schema_name)
  end

  defp child_projections(schema_name, parent_instance_id) do
    InstanceProjection
    |> where([p], p.parent_instance_id == ^parent_instance_id)
    |> Repo.all(prefix: schema_name)
  end

  defp instance_projection_count(schema_name) do
    Repo.aggregate(InstanceProjection, :count, :instance_id, prefix: schema_name)
  end

  defp pending_task_for_instance!(schema_name, instance_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id and t.status == :pending)
    |> Repo.one!(prefix: schema_name)
  end

  # ISS-0392: ALL task rows for an instance, any status -- not just :pending. The
  # collision-fix's own "no orphan row" claim (design doc §5 point 6) is about a task row
  # that should never have been INSERTed at all (call (1)'s now-skipped step), not about
  # a pending-vs-completed status distinction, so this deliberately doesn't filter by
  # status the way pending_task_for_instance!/2 does.
  defp all_tasks_for_instance(schema_name, instance_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
  end

  defp sub_process_completed_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "SUB_PROCESS_COMPLETED")
    |> Repo.all(prefix: schema_name)
  end

  defp execution_error_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "EXECUTION_ERROR")
    |> Repo.all(prefix: schema_name)
  end

  # OQ-2 (req062-sub-process-runtime.md §9, GH#329)/REQ-109 precedent
  # (test/letflow/engine_variable_schema_merge_test.exs's own seed_schema_row!/4):
  # REQ-109 builds no registration/INSERT path (REQ-078/REQ-082 own it), so rows are
  # seeded directly against the provisioned tenant schema.
  defp seed_schema_row!(schema_name, definition_id, variable_key, json_schema) do
    %VariableSchema{}
    |> VariableSchema.changeset(%{
      definition_id: definition_id,
      variable_key: variable_key,
      json_schema: json_schema
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- filtered input, only the declared inputs reach the child
  # ---------------------------------------------------------------------------------

  describe "AC1 -- a declared interface filters the child's initial variables to ONLY the named inputs" do
    test "a parent variable not named in inputs is demonstrably absent from the child" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "inputs" => [%{"name" => "amount", "json_schema" => %{"type" => "number"}}]
      }

      parent_def =
        active_definition!(schema_name, graph_parent_subprocess_root(child_def.name, interface))

      attrs = start_attrs(parent_def, %{initial_variables: %{"amount" => 5, "secret" => "x"}})
      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)

      child = child_projection!(schema_name, result.instance_id)
      assert child.variables == %{"amount" => 5}
      refute Map.has_key?(child.variables, "secret")
      assert child.parent_instance_id == result.instance_id

      # ISS-0071: exact composition check for derive_idempotency_key/3's call site 1
      # (append_instance_started_event_for_child/8) -- proves the private helper still
      # emits `base::sub_process_start::child_instance_id` byte-for-byte, not merely
      # that INSTANCE_STARTED got appended at all. derive_idempotency_key/3 is `defp`
      # and unreachable from outside Letflow.Engine.SubProcess, so this is the closest
      # available direct assertion on its exact join format.
      child_started_event =
        Event
        |> where(
          [e],
          e.instance_id == ^child.instance_id and e.event_type == "INSTANCE_STARTED"
        )
        |> Repo.one!(prefix: schema_name)

      assert child_started_event.idempotency_key ==
               "#{attrs.idempotency_key}::sub_process_start::#{child.instance_id}"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- no declared interface -> full parent variable map copied (EXT-05)
  # ---------------------------------------------------------------------------------

  describe "AC2 -- a SUB_PROCESS node with no declared interface copies the full parent variable map" do
    test "the child's initial variables equal the parent's full initial_variables map" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())
      parent_def = active_definition!(schema_name, graph_parent_subprocess_root(child_def.name))

      initial_variables = %{"amount" => 5, "secret" => "x", "nested" => %{"a" => 1}}
      attrs = start_attrs(parent_def, %{initial_variables: initial_variables})
      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)

      child = child_projection!(schema_name, result.instance_id)
      assert child.variables == initial_variables
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- the two activation-time failure modes: ZERO child instances created, routed
  # through ExecutionError against the already-persisted parent (AC8), gate task stays
  # pending (no partial completion).
  # ---------------------------------------------------------------------------------

  describe "AC3/AC8 -- SUB_PROCESS_MISSING_REQUIRED_INPUT: zero children created, routed into set_instance_error" do
    test "the gate task's own completion is rejected: parent flips to :error, zero child instance rows, gate task stays pending" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "inputs" => [
          %{"name" => "amount", "required" => true, "json_schema" => %{"type" => "number"}}
        ]
      }

      parent_def =
        active_definition!(
          schema_name,
          graph_parent_task_then_subprocess(child_def.name, interface)
        )

      assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)
      gate_task = pending_task_for_instance!(schema_name, created.instance_id)

      before_count = instance_projection_count(schema_name)

      # complete_task/3 itself returns {:error, {:instance_execution_error, ...}} directly
      # -- the same, single conversion every EE-10-routed complete_task/3 call goes
      # through (interpret_complete_result/1's leading clause, engine.ex:1916-1918;
      # mirrors AC4a's own shape/style, engine_execution_error_test.exs:410). There is no
      # code path that returns {:ok, %{instance_status: :error, ...}} -- complete_result()'s
      # own @spec restricts instance_status to :active | :completed, never :error.
      assert {:error,
              {:instance_execution_error, :subprocess_interface_violation, {:field, "amount"}}} =
               Engine.complete_task(gate_task.id, complete_attrs(), prefix: schema_name)

      projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert projection.status == :error
      assert projection.error_detail["error_type"] == "subprocess_interface_violation"
      assert projection.error_detail["details"]["code"] == "SUB_PROCESS_MISSING_REQUIRED_INPUT"

      # Zero child instances created -- structural, not a rollback (AC's own wording).
      assert instance_projection_count(schema_name) == before_count
      assert child_projections(schema_name, created.instance_id) == []

      # The gate task itself never completed -- "no partial merge" extends to "no
      # partial task completion" here too.
      still_pending = Repo.get!(EngineTask, gate_task.id, prefix: schema_name)
      assert still_pending.status == :pending

      assert [event] = execution_error_events(schema_name, created.instance_id)
      assert event.payload["error_type"] == "subprocess_interface_violation"
    end
  end

  describe "AC3/AC8 -- SUB_PROCESS_INPUT_SCHEMA_VIOLATION: zero children created, routed into set_instance_error" do
    test "a present input failing its own json_schema behaves identically to the missing-required case" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "inputs" => [%{"name" => "amount", "json_schema" => %{"type" => "number"}}]
      }

      parent_def =
        active_definition!(
          schema_name,
          graph_parent_task_then_subprocess(child_def.name, interface)
        )

      assert {:ok, created} =
               Engine.create(
                 start_attrs(parent_def, %{initial_variables: %{"amount" => "not-a-number"}}),
                 prefix: schema_name
               )

      gate_task = pending_task_for_instance!(schema_name, created.instance_id)

      # complete_task/3 itself returns {:error, {:instance_execution_error, ...}} directly
      # -- same shape/rationale as the SUB_PROCESS_MISSING_REQUIRED_INPUT case above
      # (mirrors AC4a's own shape/style, engine_execution_error_test.exs:410).
      assert {:error,
              {:instance_execution_error, :subprocess_interface_violation, {:field, "amount"}}} =
               Engine.complete_task(gate_task.id, complete_attrs(), prefix: schema_name)

      projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert projection.status == :error
      assert projection.error_detail["error_type"] == "subprocess_interface_violation"
      assert projection.error_detail["details"]["code"] == "SUB_PROCESS_INPUT_SCHEMA_VIOLATION"
      assert child_projections(schema_name, created.instance_id) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3/AC4/AC8 -- the two completion-time failure modes: the child already exists and
  # completes normally, but the parent's merge is rejected -- parent's own variable map
  # is left unmodified (no partial merge), routed into set_instance_error.
  # ---------------------------------------------------------------------------------

  describe "AC3/AC8 -- SUB_PROCESS_MISSING_REQUIRED_OUTPUT: parent's variables unmodified, routed into set_instance_error" do
    test "the child completes normally but the parent's own merge never applies" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "outputs" => [
          %{"name" => "result", "required" => true, "json_schema" => %{"type" => "boolean"}}
        ]
      }

      parent_def =
        active_definition!(
          schema_name,
          graph_parent_subprocess_root(child_def.name, interface)
        )

      parent_initial_variables = %{"seed" => 1}

      assert {:ok, created} =
               Engine.create(
                 start_attrs(parent_def, %{initial_variables: parent_initial_variables}),
                 prefix: schema_name
               )

      child = child_projection!(schema_name, created.instance_id)
      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      # "result" deliberately omitted from the child's own output_variables.
      child_complete_attrs = complete_attrs()

      assert {:ok, child_result} =
               Engine.complete_task(child_task.id, child_complete_attrs, prefix: schema_name)

      # The child itself completes successfully -- only the PARENT's own merge is
      # rejected; the two are not the same transaction's success/failure verdict.
      assert child_result.instance_status == :completed

      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :error
      assert parent_projection.variables == parent_initial_variables

      assert parent_projection.error_detail["details"]["code"] ==
               "SUB_PROCESS_MISSING_REQUIRED_OUTPUT"

      assert [event] = execution_error_events(schema_name, created.instance_id)
      assert event.payload["error_type"] == "subprocess_interface_violation"

      # ISS-0071: exact composition check for derive_idempotency_key/3's call site 2
      # (append_completion_multi/4's error_idempotency_key) -- proves the private
      # helper still emits `base::sub_process_completion_error::parent_id::child_id`
      # byte-for-byte at the one call site whose derived value is otherwise never
      # observed by any assertion. derive_idempotency_key/3 is `defp` and unreachable
      # from outside Letflow.Engine.SubProcess, so this is the closest available
      # direct assertion on its exact join format.
      assert event.idempotency_key ==
               "#{child_complete_attrs.idempotency_key}::sub_process_completion_error::#{created.instance_id}::#{child.instance_id}"

      # No SUB_PROCESS_COMPLETED event on the parent's own stream -- the completion
      # event is only appended on the success path (design doc §3.4 point 4).
      assert sub_process_completed_events(schema_name, created.instance_id) == []
    end
  end

  describe "AC3/AC8 -- SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION: parent's variables unmodified, routed into set_instance_error" do
    test "a present output failing its own json_schema behaves identically to the missing-required-output case" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "outputs" => [%{"name" => "result", "json_schema" => %{"type" => "boolean"}}]
      }

      parent_def =
        active_definition!(
          schema_name,
          graph_parent_subprocess_root(child_def.name, interface)
        )

      parent_initial_variables = %{"seed" => 1}

      assert {:ok, created} =
               Engine.create(
                 start_attrs(parent_def, %{initial_variables: parent_initial_variables}),
                 prefix: schema_name
               )

      child = child_projection!(schema_name, created.instance_id)
      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      output_attrs = complete_attrs(%{output_variables: %{"result" => "not-a-boolean"}})

      assert {:ok, child_result} =
               Engine.complete_task(child_task.id, output_attrs, prefix: schema_name)

      assert child_result.instance_status == :completed

      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :error
      assert parent_projection.variables == parent_initial_variables

      assert parent_projection.error_detail["details"]["code"] ==
               "SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- successful completion: only the named outputs merge into the parent
  # ---------------------------------------------------------------------------------

  describe "AC4 -- on child completion, only the named outputs merge into the parent" do
    test "a child variable not named in outputs is demonstrably absent from the parent afterwards" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "outputs" => [%{"name" => "result", "json_schema" => %{"type" => "boolean"}}]
      }

      parent_def =
        active_definition!(schema_name, graph_parent_subprocess_root(child_def.name, interface))

      assert {:ok, created} =
               Engine.create(
                 start_attrs(parent_def, %{initial_variables: %{"seed" => 1}}),
                 prefix: schema_name
               )

      child = child_projection!(schema_name, created.instance_id)
      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      output_attrs =
        complete_attrs(%{output_variables: %{"result" => true, "junk" => "never merged"}})

      assert {:ok, _child_result} =
               Engine.complete_task(child_task.id, output_attrs, prefix: schema_name)

      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :completed
      assert parent_projection.variables == %{"seed" => 1, "result" => true}
      refute Map.has_key?(parent_projection.variables, "junk")

      assert [event] = sub_process_completed_events(schema_name, created.instance_id)
      assert event.payload["child_instance_id"] == child.instance_id
      # Pilot gap G6: the event names the PARENT's own node (the SUB_PROCESS
      # node of the parent's graph), so a reader of the parent's history --
      # the instance step log -- can close the parent's visit with it.
      assert event.payload["node_id"] == "sp"
      assert event.payload["output_variables"] == %{"result" => true}
      refute Map.has_key?(event.payload["output_variables"], "junk")

      # ISS-0071: exact composition check for derive_idempotency_key/3's call site 3
      # (append_sub_process_completed_event/8) -- proves the private helper still
      # emits `base::sub_process_completed::parent_id::child_id` byte-for-byte.
      # derive_idempotency_key/3 is `defp` and unreachable from outside
      # Letflow.Engine.SubProcess, so this is the closest available direct
      # assertion on its exact join format.
      assert event.idempotency_key ==
               "#{output_attrs.idempotency_key}::sub_process_completed::#{created.instance_id}::#{child.instance_id}"
    end
  end

  # ---------------------------------------------------------------------------------
  # OQ-2 (req062-sub-process-runtime.md §9, GH#329) -- verified against R-Co
  # (instance.zig's mergeVariables call at the sub-process completion site uses the
  # exact same variable_schemas lookup, keyed only on definition_id, as every other
  # merge call site): the parent's own registered variable-type schemas DO apply to a
  # sub-process output merge, on top of (not instead of) the interface's own
  # per-output json_schema (SPC-01). "result" below passes the interface's own
  # {"type" => "boolean"} output check but still gets rejected by a stricter registry
  # schema for the same key -- proving the registry lookup actually ran, not just that
  # the interface's own check did.
  # ---------------------------------------------------------------------------------

  describe "OQ-2/GH#329 -- a registered variable_schemas row also applies to a sub-process output merge" do
    test "an output that passes the interface's own schema but violates the registry's is rejected, parent lands in ERROR" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      interface = %{
        "outputs" => [%{"name" => "result", "json_schema" => %{"type" => "boolean"}}]
      }

      parent_def =
        active_definition!(schema_name, graph_parent_subprocess_root(child_def.name, interface))

      # Stricter than the interface's own output schema -- "result" must be an
      # OVERWRITE candidate (REQ-109 AC5) for this row to be consulted at all, so
      # the parent's own initial_variables seeds a placeholder value for it.
      seed_schema_row!(schema_name, parent_def.id, "result", %{"type" => "string"})

      parent_initial_variables = %{"seed" => 1, "result" => "placeholder"}

      assert {:ok, created} =
               Engine.create(
                 start_attrs(parent_def, %{initial_variables: parent_initial_variables}),
                 prefix: schema_name
               )

      child = child_projection!(schema_name, created.instance_id)
      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      # true is a valid boolean per the interface's own output json_schema (SPC-01
      # accepts it, so no SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION fires) but is not a
      # string, so the registry's own row must be what rejects it.
      output_attrs = complete_attrs(%{output_variables: %{"result" => true}})

      assert {:ok, child_result} =
               Engine.complete_task(child_task.id, output_attrs, prefix: schema_name)

      assert child_result.instance_status == :completed

      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :error
      # Unmerged -- the placeholder value survives untouched (REQ-109 AC3 precedent).
      assert parent_projection.variables == parent_initial_variables

      assert [event] = execution_error_events(schema_name, created.instance_id)
      assert event.payload["error_type"] == "variable_schema_rejected"
      assert event.payload["affected"] == %{"kind" => "field", "key" => "result"}
      assert event.payload["reason"] =~ "result"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- waiting_child_instance_id set while the child runs, cleared on completion
  # ---------------------------------------------------------------------------------

  describe "AC5 -- the parent token's waiting_child_instance_id is set while the child runs and cleared on completion" do
    test "set at child-creation time, cleared once the child completes, token survives at its next node" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      parent_def =
        active_definition!(schema_name, graph_parent_subprocess_then_task(child_def.name))

      assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)

      parent_token_while_running =
        TokenRecord
        |> where([t], t.instance_id == ^created.instance_id and t.status == :waiting)
        |> Repo.one!(prefix: schema_name)

      child = child_projection!(schema_name, created.instance_id)
      assert parent_token_while_running.waiting_child_instance_id == child.instance_id
      assert parent_token_while_running.node_id == "sp"

      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      assert {:ok, _result} =
               Engine.complete_task(child_task.id, complete_attrs(), prefix: schema_name)

      parent_token_after =
        Repo.get!(TokenRecord, parent_token_while_running.id, prefix: schema_name)

      assert parent_token_after.waiting_child_instance_id == nil
      assert parent_token_after.status == :active
      assert parent_token_after.node_id == "after"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- child creation is not reachable through create/2's own public create_attrs()
  # shape (inspection: create_attrs() has no parent_instance_id key at all -- see
  # lib/letflow/engine.ex's @type create_attrs; functional half below).
  # ---------------------------------------------------------------------------------

  describe "AC6 -- child instance creation is not reachable through create/2's public path" do
    test "a caller-supplied parent_instance_id in attrs is silently ignored -- the created instance is never a child" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition = active_definition!(schema_name, graph_child_two_step())

      # REQ-059 (merged into this branch after this test was originally
      # written) reads attrs[:parent_instance_id] for pin-inheritance lookup
      # (Letflow.Engine.PinResolver.reconstruct_effective_pins/2, design doc
      # §8/§9 OQ-4's own admittedly-speculative seam) -- a value that does not
      # resolve to a real instance now fails create/2 outright with
      # {:parent_pin_lookup_failed, :instance_not_found} before ever reaching
      # instance_projections insertion, which is a different failure mode
      # than the one this test exercises. Using a real (but otherwise
      # unrelated) instance's id keeps this test's actual invariant intact --
      # create/2's own insert_instance_projection/8 never reads
      # attrs[:parent_instance_id] to populate the parent_instance_id/
      # parent_token_id columns, regardless of whether pin resolution itself
      # consults that key for an unrelated purpose.
      unrelated_definition = active_definition!(schema_name, graph_child_two_step())

      assert {:ok, unrelated} =
               Engine.create(start_attrs(unrelated_definition), prefix: schema_name)

      forged_parent_id = unrelated.instance_id

      attrs =
        start_attrs(definition)
        |> Map.put(:parent_instance_id, forged_parent_id)
        |> Map.put("parent_instance_id", forged_parent_id)

      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.parent_instance_id == nil
      assert projection.parent_token_id == nil
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- cancelling a parent does not cancel its running child (EE-08)
  # ---------------------------------------------------------------------------------

  describe "AC7 -- cancelling a parent instance does not cancel its running child" do
    test "the child's own projection/task/token rows are completely unaffected by the parent's cancellation" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())
      parent_def = active_definition!(schema_name, graph_parent_subprocess_root(child_def.name))

      assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)
      child = child_projection!(schema_name, created.instance_id)
      child_task = pending_task_for_instance!(schema_name, child.instance_id)

      cancel_attrs = %{
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("cancel")
      }

      assert {:ok, cancel_result} =
               Engine.cancel_instance(created.instance_id, cancel_attrs, prefix: schema_name)

      assert cancel_result.status == :cancelled

      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :cancelled

      # The child is entirely untouched: still active, its own task still pending.
      child_projection_after =
        Repo.get!(InstanceProjection, child.instance_id, prefix: schema_name)

      assert child_projection_after.status == :active

      child_task_after = Repo.get!(EngineTask, child_task.id, prefix: schema_name)
      assert child_task_after.status == :pending

      child_token =
        TokenRecord
        |> where([t], t.instance_id == ^child.instance_id)
        |> Repo.one!(prefix: schema_name)

      assert child_token.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0067 -- resolve_parent_token_record_id/2's own correctness property
  # (GH#228): a genuinely persisted parent token_id is accepted, a derived
  # split/join branch token_id reaching a SUB_PROCESS node within the SAME hop
  # chain is rejected. Confirmed by ISSUE-FIXER: before this pair, zero tests
  # anywhere in the suite referenced resolve_parent_token_record_id (nor its
  # pre-fix name cast_parent_token_record_id) or the
  # {:sub_process_after_split_join_not_supported, _} tuple by name -- every
  # other SUB_PROCESS test either never reaches this classification at all
  # (create/2's root-SUB_PROCESS path uses a different function,
  # prepare_sub_process_children/5) or reaches it only to have it *accept*
  # incidentally, on the way to an unrelated interface-validation failure
  # (the AC3 tests above). See lib/letflow/design/iss067-token-id-persisted-check.md.
  # ---------------------------------------------------------------------------------

  describe "ISS-0067 -- resolve_parent_token_record_id/2 rejects a derived split/join branch token_id" do
    test "a SUB_PROCESS node off a PARALLEL_GATEWAY split, within the completing hop chain, is rejected -- zero children created, transaction rolled back" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      parent_def =
        active_definition!(schema_name, graph_parent_split_then_subprocess(child_def.name))

      assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)
      gate_task = pending_task_for_instance!(schema_name, created.instance_id)

      gate_token =
        TokenRecord
        |> where([t], t.instance_id == ^created.instance_id and t.node_id == "gate")
        |> Repo.one!(prefix: schema_name)

      before_count = instance_projection_count(schema_name)

      # dispatch_parallel_split/4's own Enum.with_index order
      # (transition.ex:656-658) mints "#{gate_token.id}/0" for the first
      # declared outgoing edge (e3, "split" -> "sp1") -- the first
      # {:sub_process_start, ...} pending event Enum.reduce_while/3 in
      # prepare_sub_process_children_for_completion/8 hits, so this is the
      # exact token_id the rejection must carry. Neither branch id was ever
      # written to a `tokens` row before this check runs.
      expected_rejected_token_id = "#{gate_token.id}/0"

      assert {:error, {:sub_process_after_split_join_not_supported, ^expected_rejected_token_id}} =
               Engine.complete_task(gate_task.id, complete_attrs(), prefix: schema_name)

      # Whole transaction rolled back -- unlike the SUB_PROCESS_MISSING_REQUIRED_INPUT
      # family above (routed through set_instance_error, a *committed* ERROR
      # state), {:sub_process_after_split_join_not_supported, _} is returned
      # as a bare {:error, reason} from the "transition" Multi.run/3 step
      # (engine.ex's prepare_sub_process_children_for_completion/8's own
      # `else` clause halts with {:error, reason}, not an :execution_error
      # tuple), which Ecto.Multi aborts wholesale: the gate task is still
      # pending, the instance is still :active (never :error), and zero
      # child instances exist.
      still_pending = Repo.get!(EngineTask, gate_task.id, prefix: schema_name)
      assert still_pending.status == :pending

      projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert projection.status == :active

      assert instance_projection_count(schema_name) == before_count
      assert child_projections(schema_name, created.instance_id) == []
    end
  end

  describe "ISS-0067 -- resolve_parent_token_record_id/2 accepts a genuinely persisted parent token_id" do
    test "a SUB_PROCESS node reached via a normal (non-split) task-completion hop chain succeeds -- child instance created" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_def = active_definition!(schema_name, graph_child_two_step())

      parent_def =
        active_definition!(
          schema_name,
          graph_parent_task_then_subprocess_no_split(child_def.name)
        )

      assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)
      gate_task = pending_task_for_instance!(schema_name, created.instance_id)

      gate_token =
        TokenRecord
        |> where([t], t.instance_id == ^created.instance_id and t.node_id == "gate")
        |> Repo.one!(prefix: schema_name)

      # gate_token.id is a real, already-persisted tokens.id -- no split/join
      # anywhere on this graph to derive a branch id from it.
      assert {:ok, result} =
               Engine.complete_task(gate_task.id, complete_attrs(), prefix: schema_name)

      assert result.instance_status == :active
      assert result.current_nodes == ["sp"]

      child = child_projection!(schema_name, created.instance_id)
      assert child.parent_instance_id == created.instance_id

      parent_token_after = Repo.get!(TokenRecord, gate_token.id, prefix: schema_name)
      assert parent_token_after.status == :waiting
      assert parent_token_after.waiting_child_instance_id == child.instance_id
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0392 -- Ecto.Multi :task_records key collision when a SUB_PROCESS child
  # completes synchronously in the same hop-chain transaction as the parent task that
  # spawned it. See lib/letflow/design/iss0392-multi-task-records-collision-fix.md §5
  # for the exact scenario this reproduces, and test/specs/ISS-0392.md for why each
  # assertion below exists. This closes engine_sub_process_test.exs's own documented gap
  # (graph_child_two_step/0's comment at the top of this file, "Deliberately does NOT
  # complete synchronously") -- every other test in this file drives a child that stays
  # :active pending its own task; this is the first test in the file whose child
  # completes inside the SAME transaction as the parent's hop chain.
  # ---------------------------------------------------------------------------------

  describe "ISS-0392 -- a synchronously-completing SUB_PROCESS child no longer collides on {:task_records, parent_instance_id}" do
    test "single-level: gate completion cascades through synchronous child completion, no raise, no orphan task row" do
      %{schema_name: schema_name} = provisioned_tenant()

      # START -> END, no intervening task -- prepare_child_activation/4 drives this
      # child to InstanceState.status == :completed synchronously, before any Multi
      # step for it exists (design doc §5 point 2).
      child_def = active_definition!(schema_name, graph_child_immediate())

      # START -> HUMAN_TASK("gate") -> SUB_PROCESS("sp") -> END. "end" is a terminal
      # node with nothing after "sp" -- deliberately, so the collision-fix's dominance
      # argument (design doc §2.3/§5 point 6) is observable as "no orphan task row"
      # rather than needing a positive-content assertion about a node that doesn't
      # exist in this graph.
      parent_def =
        active_definition!(
          schema_name,
          graph_parent_task_then_subprocess_no_split(child_def.name)
        )

      assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)
      gate_task = pending_task_for_instance!(schema_name, created.instance_id)

      before_task_count = length(all_tasks_for_instance(schema_name, created.instance_id))

      # Pre-fix: this call raised RuntimeError "cannot merge Multi; ... task_records: "
      # (ISS-0392's own filed repro). Post-fix: {:ok, _}, no raise.
      assert {:ok, result} =
               Engine.complete_task(gate_task.id, complete_attrs(), prefix: schema_name)

      # complete_task/3's own returned instance_status reflects final_instance_state --
      # the PRE-cascade snapshot from call (1)'s own transition (engine.ex
      # interpret_complete_result/1, :advanced clause), evaluated before the child's
      # synchronous completion cascades back into the parent. It is therefore still
      # :active here regardless of the fix -- this is not itself a collision symptom,
      # so it is asserted (not skipped) precisely to document that the persisted
      # PROJECTION below, not this return value, is where the fix's dominance argument
      # (design doc §2.3) becomes observable.
      assert result.instance_status == :active

      # The gate task's own hop chain reaches SUB_PROCESS("sp"), spawns the child, the
      # child completes synchronously inside the same transaction, and that completion
      # chains back into the parent (sub_process_completed) -- which itself advances
      # the parent straight to END (design doc §2.3's dominance argument: call (2)'s
      # diff, evaluated AFTER the child's completion, strictly dominates call (1)'s).
      # This IS observable on the persisted projection, which reconcile_projection/4
      # writes from the further-advanced state produced by the cascade, not from
      # final_instance_state alone.
      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :completed

      # child.status itself is NOT asserted :completed here: insert_child_instance_
      # projection/8 (sub_process.ex:520-544) hardcodes status: :active at insert time
      # regardless of child_initial_state.status, and no later step in this hop chain
      # updates the child's own projection row afterwards -- this is pre-existing
      # behavior, orthogonal to ISS-0392's own scope (the collision and its fix are
      # both about the PARENT's {:task_records, parent_instance_id} Multi step, not
      # the child's projection row) and not something design doc §5 asks this test to
      # assert. child_final_state.status == :completed (verified indirectly below via
      # the SUB_PROCESS_COMPLETED event, which only fires on that status) is what
      # actually drives the collision and the parent's own advance to :completed.
      child = child_projection!(schema_name, created.instance_id)
      assert child.parent_instance_id == created.instance_id

      # No orphan/duplicate task row: call (1)'s {:task_records, parent_instance_id}
      # step is never built when this scenario's predicate is true (design doc §2.2),
      # so there is no earlier-snapshot pending_task_nodes row for it to have inserted
      # in the first place -- this is a structural guarantee, not a race outcome, per
      # §5 point 6's own closing note. The gate task itself is the only row that ever
      # existed for this instance; completing it does not insert a second row.
      after_tasks = all_tasks_for_instance(schema_name, created.instance_id)
      assert length(after_tasks) == before_task_count
      assert Enum.map(after_tasks, & &1.id) == [gate_task.id]

      assert [sp_event] = sub_process_completed_events(schema_name, created.instance_id)
      assert sp_event.payload["child_instance_id"] == child.instance_id
    end

    test "multi-level cascade: two synchronous SUB_PROCESS completions in one transaction, distinct instance_ids never collide" do
      %{schema_name: schema_name} = provisioned_tenant()

      # Level 0 (innermost) child: START -> END, synchronous.
      innermost_child_def = active_definition!(schema_name, graph_child_immediate())

      # Level 1 (middle): START -> HUMAN_TASK("gate") -> SUB_PROCESS("sp") -> END. This
      # is itself the "child" of the outer grandparent below -- when spawned as a
      # child, it has no pending HUMAN_TASK reached yet by its OWN activation (its
      # first node is "start", not "gate"), so it does not complete synchronously on
      # spawn; it becomes the outer SUB_PROCESS's :active, waiting child. What DOES
      # cascade synchronously is this middle instance's own eventual completion, once
      # ITS "gate" task is completed independently -- see the outer flow below.
      middle_def =
        active_definition!(
          schema_name,
          graph_parent_task_then_subprocess_no_split(innermost_child_def.name)
        )

      # Level 2 (outer/grandparent): START -> HUMAN_TASK("outer_gate") ->
      # SUB_PROCESS("outer_sp") -> END, "outer_sp" pointing at the middle definition.
      outer_def =
        active_definition!(
          schema_name,
          graph_parent_task_then_subprocess_no_split(middle_def.name)
        )

      assert {:ok, outer_created} = Engine.create(start_attrs(outer_def), prefix: schema_name)
      outer_gate_task = pending_task_for_instance!(schema_name, outer_created.instance_id)

      # Completing "outer_gate" spawns the middle instance as outer_sp's child. The
      # middle instance's own first node is "start" -> "gate" (a HUMAN_TASK), so it
      # does NOT complete synchronously here -- it is left :active, waiting on its own
      # "gate" task. This single hop chain therefore does NOT yet exercise the
      # collision (only one instance_id, outer_created.instance_id, is a candidate for
      # the predicate, and the middle child's own prepared_children entry has
      # child_initial_state.status == :active, not :completed) -- confirms the
      # baseline (pre-existing, already-passing) async/queued path is unaffected.
      assert {:ok, outer_after_spawn} =
               Engine.complete_task(outer_gate_task.id, complete_attrs(), prefix: schema_name)

      assert outer_after_spawn.instance_status == :active

      middle_instance = child_projection!(schema_name, outer_created.instance_id)
      assert middle_instance.status == :active

      middle_gate_task = pending_task_for_instance!(schema_name, middle_instance.instance_id)

      before_outer_tasks = length(all_tasks_for_instance(schema_name, outer_created.instance_id))

      before_middle_tasks =
        length(all_tasks_for_instance(schema_name, middle_instance.instance_id))

      # Completing the middle instance's own "gate" task is the hop chain that
      # actually cascades: it spawns the innermost child (synchronous completion,
      # collides on {:task_records, middle_instance.instance_id} -- this IS §2's
      # first-level predicate firing, for the middle instance), which chains the
      # middle instance to :completed, which in turn fires
      # maybe_cascade_to_grandparent/6's :completed clause and chains the OUTER
      # (grandparent) instance to :completed too, appending a SECOND, independently-
      # keyed {:task_records, outer_created.instance_id} step. Per design doc §3.2,
      # these two instance_ids are distinct by construction, so the second append
      # never collides with anything regardless of the fix -- this variant is expected
      # to pass post-fix purely because distinct keys never collide (§5 point 7).
      assert {:ok, middle_result} =
               Engine.complete_task(middle_gate_task.id, complete_attrs(), prefix: schema_name)

      # Same pre-cascade-snapshot caveat as the single-level test above:
      # middle_result.instance_status reflects the middle instance's own
      # final_instance_state from call (1) (gate -> sp, :active/waiting), evaluated
      # before the innermost child's synchronous completion cascades. The persisted
      # projections below are where both cascaded completions actually show up.
      assert middle_result.instance_status == :active

      middle_projection =
        Repo.get!(InstanceProjection, middle_instance.instance_id, prefix: schema_name)

      assert middle_projection.status == :completed

      outer_projection =
        Repo.get!(InstanceProjection, outer_created.instance_id, prefix: schema_name)

      assert outer_projection.status == :completed

      # Same pre-existing-behavior caveat as the single-level test: the innermost
      # child's own projection row is hardcoded status: :active at insert time
      # (sub_process.ex:520-544's insert_child_instance_projection/8), not updated
      # afterwards -- orthogonal to ISS-0392's scope. Only its parent linkage is
      # asserted here; both cascaded completions are observed on the middle/outer
      # projections above.
      innermost_child = child_projection!(schema_name, middle_instance.instance_id)
      assert innermost_child.parent_instance_id == middle_instance.instance_id

      # No orphan task row at either cascading level -- same structural guarantee as
      # the single-level test, now confirmed at two distinct instance_ids in the same
      # transaction.
      after_outer_tasks = all_tasks_for_instance(schema_name, outer_created.instance_id)
      assert length(after_outer_tasks) == before_outer_tasks
      assert Enum.map(after_outer_tasks, & &1.id) == [outer_gate_task.id]

      after_middle_tasks = all_tasks_for_instance(schema_name, middle_instance.instance_id)
      assert length(after_middle_tasks) == before_middle_tasks
      assert Enum.map(after_middle_tasks, & &1.id) == [middle_gate_task.id]

      assert [_outer_sp_event] =
               sub_process_completed_events(schema_name, outer_created.instance_id)

      assert [_middle_sp_event] =
               sub_process_completed_events(schema_name, middle_instance.instance_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0396 -- Ecto.Multi :task_records key collision when 2+ SIBLING SUB_PROCESS
  # children of the SAME parent instance each complete synchronously within the SAME
  # transaction. ISS-0392 above fixed only the call(1)-vs-call(2) collision (one
  # instance's own :task_records step vs. its synchronously-completing child's); this
  # is the call(2)-vs-call(2) case ISS-0392 left open. See
  # lib/letflow/design/iss0396-task-records-multi-sibling-fix.md for the full
  # re-derivation of the defect mechanism and why the trigger below (Engine.create/2's
  # own root activation, not a complete_task/3 hop chain -- ISS-0067's guard forecloses
  # that path today, design doc §1) is the one that is actually reachable.
  # ---------------------------------------------------------------------------------

  describe "ISS-0396 -- 2+ sibling SUB_PROCESS children no longer collide on {:task_records, instance_id}" do
    test "two sync-completing sibling SUB_PROCESS children: no Multi crash, task_records independently persisted" do
      %{schema_name: schema_name} = provisioned_tenant()

      # Shared child definition for both branches -- START -> END, synchronous, same
      # graph_child_immediate/0 ISS-0392 already uses. Deliberately shared: ISS-0396 is
      # about the Multi key, keyed on the PARENT's instance_id/parent_token.id, not on
      # which child definition is used.
      child_def = active_definition!(schema_name, graph_child_immediate())

      parent_def =
        active_definition!(
          schema_name,
          graph_root_split_into_two_subprocesses(child_def.name)
        )

      # Pre-fix, this raised RuntimeError "cannot merge Multi; ... [task_records:
      # \"<parent_instance_id>\"]" at build_sub_process_children_multi/6, since sp1's
      # and sp2's own synchronous-completion cascades both appended the identical
      # {:task_records, parent_instance_id} key onto the same Multi. Post-fix: {:ok,
      # _}, no raise -- each sibling's step is keyed {:task_records, instance_id,
      # parent_token.id}, and distinct siblings have distinct parent_token.id values
      # (design doc §2, uniqueness proof).
      assert {:ok, created} = Engine.create(start_attrs(parent_def), prefix: schema_name)

      # Both branches complete synchronously and the join immediately admits both,
      # advancing the root instance straight through "join" to "end" within this same
      # create/2 transaction -- no external complete_task/3 call needed, unlike the
      # ISS-0392 single-level test, since nothing here is gated behind a HUMAN_TASK.
      parent_projection = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent_projection.status == :completed

      # Both sp1's and sp2's own children-creation multi step ran -- proves neither
      # sibling's step was silently dropped/skipped by the fix (the assertion that
      # would fail under a "just skip the second sibling" style fix the Step-1
      # diagnosis explicitly rejected in favor of key disambiguation).
      children = child_projections(schema_name, created.instance_id)
      assert length(children) == 2

      for child <- children do
        assert child.parent_instance_id == created.instance_id
        assert child.definition_id == child_def.id
      end

      # One SUB_PROCESS_COMPLETED event per sibling -- proves both siblings' own
      # event_key step (sub_process.ex:961) ran to completion, not just one.
      assert sub_process_completed_events(schema_name, created.instance_id) |> length() == 2

      # This graph has no HUMAN_TASK node anywhere, so the root instance itself should
      # have inserted zero `tasks` rows across the whole hop chain -- the direct "both
      # sibling {:task_records, instance_id, parent_token.id} steps ran, inserted
      # nothing extra, and did not orphan/duplicate any row" assertion (the
      # :task_records step's own newly_pending == [] short-circuit case,
      # task_activation.ex).
      assert all_tasks_for_instance(schema_name, created.instance_id) == []

      # Secondary assertion (ISS-0397 cross-reference, design doc §5 point 10): the
      # root instance's own join_counters column is written sequentially by each
      # sibling's own projection_key step (reconcile_parent_projection/5) before the
      # join admits the second sibling. Once both branches have joined, the fired
      # join's own counter entry is deleted (mirroring
      # test/letflow/iss0397_join_counters_test.exs's own "fired join -> no entry"
      # precedent) -- asserted here since it's exercised "for free" by this same
      # scenario, not because this fix changes that column's behavior.
      assert parent_projection.join_counters == %{}
    end
  end
end
