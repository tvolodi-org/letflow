defmodule Letflow.EngineTest do
  @moduledoc """
  Tests for REQ-045's `Letflow.Engine.create/2` (EE-01 — instance start). See
  `test/specs/REQ-045.md` for the full test-case rationale, including the
  WF-02 Step 3 scope-test verdict.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. `create/2`'s entire
  algorithm is I/O (resolves a real `process_definitions` row, calls
  `SnapshotStore.create/3`, runs a real `Ecto.Multi` against
  `instance_projections`/`tokens`/`events`), so there is no meaningful pure-layer
  split the way `lib/letflow/engine/transition.ex` had.

  Mirrors `test/letflow/definitions/store_test.exs`'s and
  `test/letflow/definitions/snapshot_store_test.exs`'s established
  `provisioned_tenant/1` + Sandbox `:auto` + `async: false` pattern exactly --
  `Ecto.Migrator` needs a second real DB connection the sandbox can't hand out.

  Every fixture definition is created via `Definitions.create/2` +
  `Definitions.activate/2` (REQ-030), never a raw `Repo.insert!/2` -- so each test
  exercises `create/2` against a definition that genuinely passed REQ-028/029's
  structural/attribute validation, matching `store_test.exs`'s own discipline.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Engine.PinResolver
  alias Letflow.Engine.PinResolver.Lookup
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task
  alias Letflow.Engine.TokenRecord

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  # Adopts the shared `Letflow.TenantFixture` (ISS-0109/GH#358, ISS-0116/GH#370) in
  # place of this file's own hand-rolled `insert_tenant!/0` + `drop_schema!/1` +
  # `provisioned_tenant/0` copies -- same rationale as promotion_test.exs's own
  # adoption. Behaviour-preserving: `replay_migrations/1` is still called with the
  # real default manifest (no caller-supplied one), which is load-bearing here --
  # it is what triggers `TenantProvisioning.maybe_seed_platform_event_types/2` to
  # seed the "INSTANCE_STARTED" `event_type_registry` row `create/2`'s own
  # event-append step (M3) depends on (design doc §9 OQ-3a); `TenantFixture`'s own
  # `replay!/1` calls `TenantProvisioning.replay_migrations/1` the same way. This
  # module was named alongside rollback_test.exs (ISS-0116's carried finding,
  # WF03-ISS0119-20260821/TEST-RUNNER) as a further un-instrumented site that
  # reproduced the same 3F000 signature from its own copy-pasted fixture.
  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      Letflow.TenantFixture.provisioned_tenant!(
        slug_prefix: "req045",
        display_name: "REQ-045 Test Tenant"
      )

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req045-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> END directly. First non-START node is :END (design §9 OQ-1a's
  # second success case).
  defp graph_start_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  # START -> HUMAN_TASK("role": "approver") -> END. First non-START node is
  # :HUMAN_TASK.
  defp graph_start_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # START -> EXCLUSIVE_GATEWAY -> END. First non-START node is
  # :EXCLUSIVE_GATEWAY -- now auto-advances via REQ-050's dispatch and
  # activate/3's own hop loop (design §9 OQ-1a, superseded).
  # is_default: true on the gateway's one outgoing edge so CHK-13/CHK-16 (which
  # would otherwise require a condition on a non-default gateway edge) don't
  # reject this fixture at Definitions.create/2 time -- this graph must itself
  # be structurally valid; the point under test is create/2's own dispatch
  # failure, not a REQ-029 validation failure.
  defp graph_start_gateway_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gw"},
        %{"id" => "e2", "source" => "gw", "target" => "end", "is_default" => true}
      ]
    }
  end

  # START -> PARALLEL_GATEWAY(split) -> PARALLEL_GATEWAY(join, direct edges) -> END.
  # Mirrors test/letflow/engine/parallel_gateway_test.exs's own split/join fixture
  # shape exactly (direct split->join edges, no intermediate node) -- the simplest
  # graph shape that exercises a genuine split producing 2 tokens *and* the matching
  # join firing, all within create/2's own single synchronous call, since neither
  # branch has a HUMAN_TASK stop in the way (WF02-REQ045-20260818 addendum).
  defp graph_start_parallel_split_join_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "join"},
        %{"id" => "e3", "source" => "split", "target" => "join"},
        %{"id" => "e4", "source" => "join", "target" => "end"}
      ]
    }
  end

  # START -> PARALLEL_GATEWAY(split into 2 branches) -> HUMAN_TASK(a) / HUMAN_TASK(b),
  # each branch's own single-outgoing-edge chain continuing on to a shared join -> END.
  # Both branches genuinely stop at their own HUMAN_TASK (no automatic outgoing
  # traversal, transition.ex's dispatch_human_task/3 contract) -- create/2's own
  # activation loop cannot reach the join within one call, and that's deliberate
  # (WF02-REQ045-20260818 task step 2b): the join/END portion of this graph exists
  # ONLY so dispatch_parallel_split/4's own find_matching_join/2 call succeeds
  # structurally (a split with no matching join is REQ-051's own
  # {:no_matching_join_found, node_id} error, not what this fixture is testing) -- it
  # is never actually reached by any test using this fixture.
  defp graph_start_parallel_split_human_tasks do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "task_a",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_a"}
        },
        %{
          "id" => "task_b",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_b"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "end"}
      ]
    }
  end

  # START -> gw1 <-> gw2 forever. A cycle through 2 EXCLUSIVE_GATEWAY nodes is
  # explicitly CHK-06-permitted (graph.ex: "a cycle is permitted iff at least one
  # endpoint of the closing back-edge is a gateway node"). gw1's one non-default edge
  # (to :END) carries a condition referencing a variable that's never set
  # ("variables.does_not_exist == 1"), which Expr.evaluate_condition/2 folds to
  # `false` (transition.ex's own catch-false rule) -- so gw1 always falls through to
  # its default edge into gw2, and gw2's own single (default) edge always routes
  # straight back to gw1. This drives the real advance_until_stable/4 loop forever,
  # hitting its length(graph.nodes) * 4 + 10 == 4 * 4 + 10 == 26 hop bound for real --
  # not a fabricated unit-level stand-in. A 1-node self-loop does NOT work here:
  # tokens_needing_dispatch/3 treats a token landing back on the *same* node_id as
  # "stayed put" (matching :HUMAN_TASK's own genuine-stop rule) and never re-queues
  # it -- two distinct gateway node_ids are required for the loop to keep advancing.
  defp graph_start_gateway_cycle_never_exits do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gw1", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "gw2", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gw1"},
        %{
          "id" => "e2",
          "source" => "gw1",
          "target" => "end",
          "condition" => "variables.does_not_exist == 1"
        },
        %{"id" => "e3", "source" => "gw1", "target" => "gw2", "is_default" => true},
        %{"id" => "e4", "source" => "gw2", "target" => "gw1", "is_default" => true}
      ]
    }
  end

  defp create_definition_attrs(graph, overrides) do
    Map.merge(
      %{
        name: unique_name(),
        version: "1.0.0",
        graph: graph,
        created_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp active_definition!(schema_name, graph, overrides \\ %{}) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph, overrides), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp draft_definition!(schema_name, graph, overrides \\ %{}) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph, overrides), prefix: schema_name)

    definition
  end

  defp deprecated_definition!(schema_name, graph, overrides \\ %{}) do
    definition = active_definition!(schema_name, graph, overrides)
    assert {:ok, deprecated} = Definitions.deprecate(definition.id, prefix: schema_name)
    deprecated
  end

  defp archived_definition!(schema_name, graph, overrides \\ %{}) do
    definition = deprecated_definition!(schema_name, graph, overrides)
    assert {:ok, archived} = Definitions.archive(definition.id, prefix: schema_name)
    archived
  end

  defp base_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: "req045-#{System.unique_integer([:positive, :monotonic])}"
      },
      overrides
    )
  end

  defp projection_count(schema_name) do
    Repo.aggregate(InstanceProjection, :count, prefix: schema_name)
  end

  defp snapshot_count(schema_name) do
    Repo.aggregate(InstanceDefinitionSnapshot, :count, prefix: schema_name)
  end

  defp token_count(schema_name) do
    Repo.aggregate(TokenRecord, :count, prefix: schema_name)
  end

  defp event_count(schema_name) do
    %{rows: [[count]]} =
      Repo.query!(~s[SELECT COUNT(*) FROM "#{schema_name}"."events"], [])

    count
  end

  # req047 -- task-row counter, mirrors token_count/1's own shape.
  defp task_count(schema_name) do
    Repo.aggregate(Task, :count, prefix: schema_name)
  end

  # req047 (AC4) -- a HUMAN_TASK whose assignee_ref names a group with no
  # members (nothing in this schema backs a group/membership concept at all,
  # so "no members" is simply "never validated against anything" -- design
  # §4.3's own "zero group-membership resolution" statement). assignee_type
  # is set to "GROUP" so the fixture concretely exercises both attrs this
  # requirement's insert_attrs/4 reads.
  defp graph_start_human_task_group_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "empty-group", "assignee_type" => "GROUP"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC1) -- ACTIVE definition, HUMAN_TASK first node" do
    test "inserts instance_projections, tokens, and instance_definition_snapshots rows with the right shape" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition, %{initial_variables: %{"amount" => 42}})

      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)

      assert result.definition_id == definition.id
      assert result.status == :active
      assert result.current_nodes == ["task"]
      assert result.variables == %{"amount" => 42}
      assert %DateTime{} = result.started_at

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.status == :active
      assert projection.definition_id == definition.id
      assert projection.current_nodes == ["task"]
      assert projection.variables == %{"amount" => 42}

      assert token_count(schema_name) == 1
      [token] = Repo.all(TokenRecord, prefix: schema_name)
      assert token.instance_id == result.instance_id
      assert token.node_id == "task"
      assert token.branch_id == result.instance_id

      assert {:ok, snapshot} =
               Letflow.Definitions.SnapshotStore.get_by_instance_id(result.instance_id,
                 prefix: schema_name
               )

      assert snapshot.definition_id == definition.id
      assert snapshot_count(schema_name) == 1
    end

    test "the snapshot is written strictly before the INSTANCE_STARTED event -- a Multi failure leaves the snapshot as a surviving orphan, zero rows elsewhere" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      # A missing actor_id fails EventStore.append/2's own required-field guard
      # (M3 of this module's own Multi), forcing the whole Multi to roll back
      # while leaving the already-committed snapshot (a separate, earlier
      # transaction, design §5/§9 OQ-4) in place.
      attrs = base_attrs(definition) |> Map.delete(:actor_id)

      assert {:error, {:event_append_failed, :missing_actor_id}} =
               Engine.create(attrs, prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert token_count(schema_name) == 0
      assert event_count(schema_name) == 0
      assert snapshot_count(schema_name) == 1
    end

    test "a definition whose first non-START node is :END completes in the same call" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_end())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert result.current_nodes == []

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.status == :completed
      assert projection.current_nodes == []

      # REQ-044's own :END dispatch removes the token before this module's
      # persist/7 even builds the tokens insert -- no tokens row for this
      # instance at all, not a token stranded at "end".
      assert token_count(schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC2) -- non-ACTIVE definitions rejected, zero rows" do
    test "a DRAFT definition returns {:error, :definition_not_active} and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = draft_definition!(schema_name, graph_start_human_task_end())

      assert {:error, :definition_not_active} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
      assert event_count(schema_name) == 0
    end

    test "a DEPRECATED definition returns {:error, :definition_not_active} and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = deprecated_definition!(schema_name, graph_start_human_task_end())

      assert {:error, :definition_not_active} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
      assert event_count(schema_name) == 0
    end

    test "an ARCHIVED definition returns {:error, :definition_not_active} and writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = archived_definition!(schema_name, graph_start_human_task_end())

      assert {:error, :definition_not_active} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
      assert event_count(schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3 -- three explicit tests
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC3) -- initial_variables: nil / list rejected, %{} accepted" do
    test "initial_variables: nil is rejected with {:error, :invalid_initial_variables}, writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition, %{initial_variables: nil})

      assert {:error, :invalid_initial_variables} = Engine.create(attrs, prefix: schema_name)
      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
    end

    test "initial_variables set to a list is rejected with {:error, :invalid_initial_variables}, writes zero rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition, %{initial_variables: ["not", "a", "map"]})

      assert {:error, :invalid_initial_variables} = Engine.create(attrs, prefix: schema_name)
      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
    end

    test "initial_variables: %{} (empty map) is accepted" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition, %{initial_variables: %{}})

      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)
      assert result.variables == %{}

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.variables == %{}
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4
  # ---------------------------------------------------------------------------------

  describe "create/2 (AC4) -- duplicate correlation_key rejected, nil correlation_key unconstrained" do
    test "a second create/2 with the same (definition_id, correlation_key) returns {:error, :duplicate_correlation_key} and writes no second row" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      correlation_key = "corr-#{System.unique_integer([:positive, :monotonic])}"

      attrs1 = base_attrs(definition, %{correlation_key: correlation_key})
      assert {:ok, _first} = Engine.create(attrs1, prefix: schema_name)
      assert projection_count(schema_name) == 1

      attrs2 = base_attrs(definition, %{correlation_key: correlation_key})

      assert {:error, :duplicate_correlation_key} = Engine.create(attrs2, prefix: schema_name)

      # No partial row from the rejected second call -- still exactly 1.
      assert projection_count(schema_name) == 1
      assert token_count(schema_name) == 1
    end

    test "two create/2 calls with correlation_key: nil both succeed" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      assert {:ok, first} =
               Engine.create(base_attrs(definition, %{correlation_key: nil}),
                 prefix: schema_name
               )

      assert {:ok, second} =
               Engine.create(base_attrs(definition, %{correlation_key: nil}),
                 prefix: schema_name
               )

      refute first.instance_id == second.instance_id
      assert projection_count(schema_name) == 2
    end
  end

  # ---------------------------------------------------------------------------------
  # Design §9 OQ-1a (superseded by REQ-050/051) -- gateways now auto-advance;
  # activate/3 loops to a stable resting state instead of assuming a fixed hop
  # count. See test/specs/REQ-045.md for the updated rationale.
  # ---------------------------------------------------------------------------------

  describe "design §9 OQ-1a (superseded) -- a definition whose first non-START node is a gateway now completes via the activation loop" do
    test "a definition whose first non-START node is :EXCLUSIVE_GATEWAY (default edge -> END) completes in the same call" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_gateway_end())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert result.status == :completed
      assert result.current_nodes == []

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.status == :completed
      assert projection.current_nodes == []

      # REQ-044's own :END dispatch removes the token before persist/7 builds
      # the tokens insert -- no tokens row for this instance at all, matching
      # the START->END fixture's own assertion above.
      assert token_count(schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-215 (lib/letflow/design/req215-service-task-engine-wiring.md) gave
  # :SERVICE_TASK a real dispatch clause -- this describe block used to
  # assert the old {:node_type_not_yet_implemented, :SERVICE_TASK, _} stub
  # error; :SERVICE_TASK is no longer part of that disclosed limitation
  # (only genuinely-unrecognized node_type atoms are, which this file does
  # not otherwise construct a fixture for). Full AC-level SERVICE_TASK
  # dispatch/end-to-end coverage is TEST-DESIGNER's own job for REQ-215 --
  # this test is narrowed to lock in, at this file's own create/2 level,
  # that a valid inline_url SERVICE_TASK node now parks the instance
  # :active (awaiting REQ-214's poller) with one service_task_dispatches
  # row inserted, rather than failing activation.
  # ---------------------------------------------------------------------------------

  describe "create/2 -- a definition whose first non-START node is :SERVICE_TASK (REQ-215)" do
    test "a valid inline_url SERVICE_TASK node parks the instance :active with one service_task_dispatches row inserted" do
      %{schema_name: schema_name} = provisioned_tenant()

      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "svc",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"endpoint" => "https://example.test/svc", "timeout_ms" => 5000}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "svc"},
          %{"id" => "e2", "source" => "svc", "target" => "end"}
        ]
      }

      definition = active_definition!(schema_name, graph)

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert result.status == :active
      assert result.current_nodes == ["svc"]

      assert projection_count(schema_name) == 1
      assert token_count(schema_name) == 1
      assert event_count(schema_name) == 1
      assert snapshot_count(schema_name) == 1

      dispatch_rows =
        Repo.all(Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch, prefix: schema_name)

      assert [%{node_id: "svc", status: :pending, attempt_index: 0}] = dispatch_rows
    end
  end

  # ---------------------------------------------------------------------------------
  # REVIEWER-flagged coverage gap (Step 2d re-review, WF02-REQ045-20260818): the
  # worklist-based advance_until_stable/4 rework has zero PARALLEL_GATEWAY split/join
  # coverage in this file -- the exact multi-token-in-flight scenario the rework
  # exists for. See test/specs/REQ-045.md for the full rationale.
  # ---------------------------------------------------------------------------------

  describe "create/2 -- :PARALLEL_GATEWAY split/join (REVIEWER-flagged gap, WF02-REQ045-20260818)" do
    test "a split whose 2 branches both lead directly to the matching join completes create/2 in the same call" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_parallel_split_join_end())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert result.status == :completed
      assert result.current_nodes == []

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.status == :completed
      assert projection.current_nodes == []

      # Both split-derived tokens and the join's own merged token are all
      # consumed by :END's own dispatch within the same create/2 call -- no
      # tokens row survives, matching graph_start_end/0's and
      # graph_start_gateway_end/0's own "same-call :END completion" shape.
      assert token_count(schema_name) == 0
    end

    test "a split whose 2 branches each stop at their own HUMAN_TASK leaves 2 live tokens, one per branch" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_parallel_split_human_tasks())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert result.status == :active
      assert Enum.sort(result.current_nodes) == ["task_a", "task_b"]

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.status == :active
      assert Enum.sort(projection.current_nodes) == ["task_a", "task_b"]

      assert token_count(schema_name) == 2
      tokens = Repo.all(TokenRecord, prefix: schema_name)
      assert Enum.sort(Enum.map(tokens, & &1.node_id)) == ["task_a", "task_b"]
      assert Enum.all?(tokens, &(&1.instance_id == result.instance_id))

      # Each branch's own derived branch_id (dispatch_parallel_split/4's
      # `token.token_id <> "/" <> index` convention) is distinct per token --
      # confirms the split genuinely produced 2 independent tokens, not one
      # token duplicated.
      assert tokens |> Enum.map(& &1.branch_id) |> Enum.uniq() |> length() == 2
    end
  end

  # REVIEWER-flagged gap (WF02-REQ045-20260818): a CHK-06-permitted gateway cycle that
  # never exits must return {:error, {:activation_failed, {:hop_limit_exceeded, _}}},
  # writing zero rows except the benign snapshot orphan. Names kept short (ISS-0052) --
  # was 10 chars from ExUnit's 255-char SystemLimitError ceiling.
  describe "create/2 -- hop-limit-exceeded gateway cycle" do
    test "returns activation_failed/hop_limit_exceeded, writes zero rows except the snapshot" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_gateway_cycle_never_exits())

      assert {:error, {:activation_failed, {:hop_limit_exceeded, token_id}}} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert is_binary(token_id)
      assert projection_count(schema_name) == 0
      assert token_count(schema_name) == 0
      assert event_count(schema_name) == 0
      assert snapshot_count(schema_name) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # OQ-3b / INV-8 -- actor_id/idempotency_key missing-value behavior
  # ---------------------------------------------------------------------------------

  describe "actor_id/idempotency_key missing-value behavior (OQ-3b, INV-8)" do
    test "missing :actor_id returns {:error, {:event_append_failed, :missing_actor_id}}, never raises" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition) |> Map.delete(:actor_id)

      assert {:error, {:event_append_failed, :missing_actor_id}} =
               Engine.create(attrs, prefix: schema_name)
    end

    test "missing :idempotency_key returns {:error, {:event_append_failed, :missing_idempotency_key}}, never raises" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition) |> Map.delete(:idempotency_key)

      assert {:error, {:event_append_failed, :missing_idempotency_key}} =
               Engine.create(attrs, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criteria 5, 6, 7 -- moduledoc content assertions
  # ---------------------------------------------------------------------------------

  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  describe "AC5 -- moduledoc states which module is superseded vs. generalized, and TransitionEvent's disposition" do
    test "states process_instance.ex is superseded, not extended, and points to REQ-046 for its actual removal" do
      doc = normalized_moduledoc(Engine)

      assert doc =~ "process_instance.ex` is **superseded, not extended**"
      assert doc =~ "REQ-046 owns physically removing it"
    end

    test "states instance_supervisor.ex is generalized, not superseded, and untouched by this requirement" do
      doc = normalized_moduledoc(Engine)

      assert doc =~ "instance_supervisor.ex` is **generalized, not superseded**"
      assert doc =~ "`Letflow.Engine` does not modify `instance_supervisor.ex` at all"
    end

    test "states TransitionEvent is deliberately kept, not retired by this requirement" do
      doc = normalized_moduledoc(Engine)

      assert doc =~
               "TransitionEvent` (and its migration) is **deliberately kept in place, not retired by this requirement.**"
    end
  end

  # AC6: moduledoc names the process-vs-row open question, cites the stage doc,
  # leaves later engine subsystems to their own decision.
  describe "AC6 -- moduledoc names the process-vs-row open question" do
    # Names the question as this stage's largest open design question and cites
    # stage-3-instance-engine.md's second Early finding.
    test "cites stage doc as source of the open design question" do
      doc = normalized_moduledoc(Engine)

      assert doc =~
               "was this stage's largest open design question"

      assert doc =~ "stage-3-instance-engine.md`'s second Early"
    end

    test "states this module resolves it for EE-01's own scope only, and does not pre-empt REQ-056/REQ-057's own decision" do
      doc = normalized_moduledoc(Engine)

      assert doc =~ "resolves it for EE-01's own scope only"
      assert doc =~ "does not pre-empt those requirements' own decisions"
    end
  end

  describe "AC7 -- moduledoc states POST /api/v1/instances is S4 scope, this module builds a context-module function only" do
    test "states the HTTP route belongs to S4 and this module returns tagged tuples only" do
      doc = normalized_moduledoc(Engine)

      assert doc =~ "POST /api/v1/instances` and every other HTTP route belong to S4"
      assert doc =~ "this module builds a context-module function only"
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-047 (EE-03) -- task-activation persistence. See test/specs/REQ-047.md for the
  # full test-case rationale and AC traceability; pure-layer coverage of
  # Letflow.Engine.TaskActivation itself lives in
  # test/letflow/engine/task_activation_test.exs, not here.
  # ---------------------------------------------------------------------------------

  describe "create/2 (REQ-047 AC1) -- HUMAN_TASK entry produces exactly one PENDING tasks row" do
    test "the tasks row carries instance_id, node_id, node_name, assignee_type, assignee_ref, status PENDING" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert task_count(schema_name) == 1
      [task] = Repo.all(Task, prefix: schema_name)
      assert task.instance_id == result.instance_id
      assert task.node_id == "task"
      assert task.node_name == "task"
      # ISS-0905: assignee_type is derived as "ROLE" when the node carries
      # only a role attribute (no explicit assignee_type) -- see
      # Letflow.Engine.TaskActivation.resolve_assignee/1.
      assert task.assignee_type == "ROLE"
      assert task.assignee_ref == "approver"
      assert task.status == :pending

      # Same-transaction visibility: the task row's own token_id resolves to
      # the exact tokens row create/2 also committed for this instance.
      [token_record] = Repo.all(TokenRecord, prefix: schema_name)
      assert task.token_id == token_record.id
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-047 AC2 -- forced event-append failure leaves zero rows in tasks,
  # instance_projections, AND tokens. Reuses the exact missing-:actor_id forced-failure
  # technique this file's own REQ-045 atomicity test (AC1's second test, above) already
  # established, against a HUMAN_TASK-first graph so a tasks row would otherwise have
  # been committed.
  # ---------------------------------------------------------------------------------

  describe "create/2 (REQ-047 AC2) -- forced :event Multi-step failure rolls back the tasks insert too" do
    test "missing :actor_id fails the event append and leaves zero tasks/instance_projections/tokens rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      attrs = base_attrs(definition) |> Map.delete(:actor_id)

      assert {:error, {:event_append_failed, :missing_actor_id}} =
               Engine.create(attrs, prefix: schema_name)

      assert task_count(schema_name) == 0
      assert projection_count(schema_name) == 0
      assert token_count(schema_name) == 0
      assert event_count(schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-047 AC3 -- START/END/EXCLUSIVE_GATEWAY/PARALLEL_GATEWAY entries create zero
  # tasks rows, each its own explicit test (the DB-level companion to
  # task_activation_test.exs's pure per-node-type diff tests).
  # ---------------------------------------------------------------------------------

  describe "create/2 (REQ-047 AC3) -- START entry creates zero tasks rows" do
    test "a definition whose only nodes are START and END creates zero tasks rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_end())

      assert {:ok, _result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert task_count(schema_name) == 0
    end
  end

  describe "create/2 (REQ-047 AC3) -- END entry creates zero tasks rows" do
    test "a definition whose first non-START node is :END creates zero tasks rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_end())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert result.status == :completed
      assert task_count(schema_name) == 0
    end
  end

  describe "create/2 (REQ-047 AC3) -- EXCLUSIVE_GATEWAY entry creates zero tasks rows" do
    test "a definition whose first non-START node is :EXCLUSIVE_GATEWAY creates zero tasks rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_gateway_end())

      assert {:ok, _result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert task_count(schema_name) == 0
    end
  end

  describe "create/2 (REQ-047 AC3) -- PARALLEL_GATEWAY entry creates zero tasks rows" do
    test "a split whose branches lead directly to the matching join creates zero tasks rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_parallel_split_join_end())

      assert {:ok, _result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert task_count(schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-047 AC4 -- a HUMAN_TASK whose assignee_ref names a group with no members still
  # produces a PENDING task, not an activation error.
  # ---------------------------------------------------------------------------------

  describe "create/2 (REQ-047 AC4) -- assignee_ref naming a group with no members still creates a PENDING task" do
    test "create/2 succeeds and the tasks row carries the group's assignee_type/assignee_ref unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_group_end())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)
      assert result.status == :active

      assert task_count(schema_name) == 1
      [task] = Repo.all(Task, prefix: schema_name)
      assert task.status == :pending
      assert task.assignee_type == "GROUP"
      assert task.assignee_ref == "empty-group"
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-047 AC5 -- a token entering END sets the instance COMPLETED, creates no task,
  # and the named SCH-03/S6 hook is documented (checked directly on TaskActivation's
  # own @doc in task_activation_test.exs; this test only proves the COMPLETED +
  # no-task half of AC5 end to end).
  # ---------------------------------------------------------------------------------

  describe "create/2 (REQ-047 AC5) -- END entry sets the instance COMPLETED with no task row" do
    test "instance_projections.status becomes :completed and zero tasks rows are created" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_end())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      projection = Repo.get!(InstanceProjection, result.instance_id, prefix: schema_name)
      assert projection.status == :completed
      assert task_count(schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-273 -- tasks.form_schema is populated at activation from
  # node.attributes["form_schema"], shape-validated via
  # Letflow.Definitions.JsonSchemaShape.check/1, and pinned to the definition
  # version the instance was created against. See
  # lib/letflow/design/req273-form-schema-activation.md for the full design;
  # pure-layer coverage (resolve_form_schema/1, insert_attrs/4's own
  # {:ok, _}/{:error, _} shapes) lives in
  # test/letflow/engine/task_activation_test.exs, not here. This block covers
  # the DB-level acceptance criteria that require a real Ecto.Multi/Repo round
  # trip: persisted-and-read-back-from-the-DB (AC1), absent-attribute-stays-nil
  # (AC2), malformed-schema-rolls-back-the-whole-transaction (AC3), and
  # version-pinning across a later promotion (AC4).
  # ---------------------------------------------------------------------------------

  defp graph_start_human_task_end_with_form_schema(form_schema) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver", "form_schema" => form_schema}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  describe "create/2 (REQ-273 AC1) -- form_schema is populated from node.attributes[\"form_schema\"]" do
    test "the persisted tasks row's form_schema equals the node attribute, read back from the DB" do
      %{schema_name: schema_name} = provisioned_tenant()

      schema = %{"type" => "object", "properties" => %{"comment" => %{"type" => "string"}}}

      definition =
        active_definition!(schema_name, graph_start_human_task_end_with_form_schema(schema))

      assert {:ok, _result} = Engine.create(base_attrs(definition), prefix: schema_name)

      # Read back from the DB via a fresh query, not the in-memory struct
      # any earlier call returned.
      [task] = Repo.all(Task, prefix: schema_name)
      reloaded = Repo.get!(Task, task.id, prefix: schema_name)
      assert reloaded.form_schema == schema
    end
  end

  describe "create/2 (REQ-273 AC2) -- absent form_schema attribute stays nil, never an invented default" do
    test "a HUMAN_TASK node with no form_schema attribute produces a task row whose form_schema is nil" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      assert {:ok, _result} = Engine.create(base_attrs(definition), prefix: schema_name)

      [task] = Repo.all(Task, prefix: schema_name)
      reloaded = Repo.get!(Task, task.id, prefix: schema_name)
      assert reloaded.form_schema == nil
      refute reloaded.form_schema == %{}
    end
  end

  describe "create/2 (REQ-273 AC3) -- a malformed form_schema is rejected at activation, no tasks row written" do
    test "a JSON-array form_schema aborts create/2 with a typed error and zero tasks rows" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(schema_name, graph_start_human_task_end_with_form_schema([1, 2, 3]))

      assert {:error, {:invalid_form_schema, "task", {:not_well_formed, []}}} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert task_count(schema_name) == 0
      assert projection_count(schema_name) == 0
      assert token_count(schema_name) == 0
    end

    test "a bare-string form_schema aborts create/2 with a typed error and zero tasks rows" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(
          schema_name,
          graph_start_human_task_end_with_form_schema("not-a-schema")
        )

      assert {:error, {:invalid_form_schema, "task", {:not_well_formed, []}}} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert task_count(schema_name) == 0
    end

    test "a form_schema whose \"properties\" value is not an object aborts create/2 with a typed error" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(
          schema_name,
          graph_start_human_task_end_with_form_schema(%{"properties" => "not-an-object"})
        )

      assert {:error, {:invalid_form_schema, "task", {:not_well_formed, ["properties"]}}} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert task_count(schema_name) == 0
    end
  end

  describe "create/2 (ISS-0784) -- a task-activation rejection is recorded as an audit entry after rollback" do
    test "a JSON-array form_schema rejection produces exactly one task_activation.rejected audit entry, readable after rollback" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(schema_name, graph_start_human_task_end_with_form_schema([1, 2, 3]))

      attrs = base_attrs(definition)

      assert {:error, {:invalid_form_schema, "task", {:not_well_formed, []}}} =
               Engine.create(attrs, prefix: schema_name)

      # INV-ISS0784-2 -- the rolled-back Multi's own rows never reappear, but
      # the audit row itself is independently committed.
      assert task_count(schema_name) == 0
      assert projection_count(schema_name) == 0

      assert [entry] =
               Enum.filter(
                 Repo.all(Audit.Entry, prefix: schema_name),
                 &(&1.action == "task_activation.rejected")
               )

      assert entry.resource_type == "instance"
      # INV-ISS0784-1 -- resource_id is the instance's own id; create/2
      # generates it internally and never returns it on the error path, so
      # this only asserts it's a well-formed UUID (the specific value has no
      # caller-observable oracle here).
      assert {:ok, _} = Ecto.UUID.cast(entry.resource_id)
      assert entry.actor_id == attrs.actor_id
      assert entry.before_state == nil
      assert entry.after_state["node_id"] == "task"
      assert entry.after_state["reason"] == %{"code" => "not_well_formed", "path" => []}
    end

    test "a \"properties\" shape rejection encodes the offending path in after_state" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(
          schema_name,
          graph_start_human_task_end_with_form_schema(%{"properties" => "not-an-object"})
        )

      assert {:error, {:invalid_form_schema, "task", {:not_well_formed, ["properties"]}}} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert [entry] =
               Enum.filter(
                 Repo.all(Audit.Entry, prefix: schema_name),
                 &(&1.action == "task_activation.rejected")
               )

      assert entry.after_state["reason"] == %{
               "code" => "not_well_formed",
               "path" => ["properties"]
             }
    end
  end

  describe "ISS-0969: record_task_activation_rejection_audit/5 is rescue-hardened, never raises" do
    test "a genuine Postgres-level audit-insert failure is logged and swallowed, returns :ok" do
      %{schema_name: schema_name} = provisioned_tenant()

      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      instance_id = Ecto.UUID.generate()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Engine.record_task_activation_rejection_audit(
                     instance_id,
                     "task",
                     {:not_well_formed, []},
                     Letflow.EventStore.platform_actor_id(),
                     schema_name
                   )
        end)

      assert log =~ "task_activation.rejected"
      assert log =~ "#{instance_id}"
      assert log =~ "Postgrex.Error"
    end
  end

  describe "create/2 (REQ-273 AC4) -- form_schema is pinned to the version the task was created against" do
    test "promoting a new definition version with a different form_schema does not change the already-created task's form_schema" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_name = unique_name("req273-form-pin")

      schema_a = %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}
      schema_b = %{"type" => "object", "properties" => %{"b" => %{"type" => "string"}}}

      v1 =
        active_definition!(
          schema_name,
          graph_start_human_task_end_with_form_schema(schema_a),
          %{name: process_name, version: "1.0.0"}
        )

      assert {:ok, _result} = Engine.create(base_attrs(v1), prefix: schema_name)
      [task] = Repo.all(Task, prefix: schema_name)
      assert Repo.get!(Task, task.id, prefix: schema_name).form_schema == schema_a

      # Promote a NEW version, same process name, with a different
      # form_schema on the same node -- Definitions.activate/2 atomically
      # deprecates v1 in the same transaction (PD-03).
      _v2 =
        active_definition!(
          schema_name,
          graph_start_human_task_end_with_form_schema(schema_b),
          %{name: process_name, version: "2.0.0"}
        )

      # The task created against v1 must still carry schema_a -- a fresh DB
      # read, not the in-memory struct from the first insert.
      reloaded = Repo.get!(Task, task.id, prefix: schema_name)
      assert reloaded.form_schema == schema_a
      refute reloaded.form_schema == schema_b
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-059 (PIN-01..PIN-04) -- pin resolution, recording, and inheritance,
  # integration-level: real Postgres, real Engine.create/2, real
  # INSTANCE_STARTED event payloads. See test/specs/REQ-059.md for the full
  # rationale; the pure-function-level coverage (resolve/4's ordering,
  # validate_initial_variables/2, merge_effective_pins/2, apply_inheritance/2,
  # pin_for/3, the moduledoc, and the AC5 inspection-based no-fallback check)
  # lives in test/letflow/engine/pin_resolver_test.exs instead.
  # ---------------------------------------------------------------------------------

  # START -> SERVICE_TASK(service_id: given) -> END. Structurally valid (CHK-10/
  # CHK-11 satisfied by endpoint/timeout_ms), reached immediately off START so
  # its dispatch would fail today (no :SERVICE_TASK dispatch clause exists yet,
  # engine_test.exs:580's own finding) -- but that dispatch is never reached in
  # any REQ-059 test below, since pin resolution (which halts on an unresolved
  # service_id under PinResolver.default_lookup/0) runs BEFORE create_snapshot/3
  # and BEFORE activate/3 in the new start_instance/5 ordering (design doc §3).
  defp graph_start_service_task_end(service_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "endpoint" => "https://example.test/svc",
            "timeout_ms" => 5000,
            "service_id" => service_id
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "end"}
      ]
    }
  end

  defp default_variable_schema_lookup(_tenant_id, _process_key),
    do: {:ok, %{version: "unversioned", json_schema: nil}}

  defp const_pin_lookup(catalog_result, module_result) do
    %Lookup{
      catalog_lookup: fn _ref -> catalog_result end,
      module_lookup: fn _ref -> module_result end,
      variable_schema_lookup: &default_variable_schema_lookup/2
    }
  end

  defp variable_schema_pin_lookup(json_schema) do
    %Lookup{
      catalog_lookup: fn _ref -> {:error, :not_found} end,
      module_lookup: fn _ref -> {:error, :not_found} end,
      variable_schema_lookup: fn _tenant_id, _process_key ->
        {:ok, %{version: "1.0.0", json_schema: json_schema}}
      end
    }
  end

  describe "create/2 (REQ-059 AC2) -- failed pin resolution writes zero rows" do
    test "an unresolvable service_id (default lookup) returns {:error, {:unresolved_catalog_ref, ref}} and writes zero projection/snapshot/token/event rows" do
      %{schema_name: schema_name} = provisioned_tenant()

      definition =
        active_definition!(schema_name, graph_start_service_task_end("unregistered-svc"))

      assert {:error, {:unresolved_catalog_ref, "unregistered-svc"}} =
               Engine.create(base_attrs(definition), prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
      assert token_count(schema_name) == 0
      assert event_count(schema_name) == 0
    end

    # No "unresolvable module_ref" counterpart test exists at THIS (real
    # Definitions/Engine pipeline) level: `Letflow.Definitions.Graph`'s own
    # `@node_type_map` (graph.ex:203-211) does not include "SUB_PROCESS" at
    # all yet -- a "SUB_PROCESS" node built via `Definitions.create/2`'s real
    # JSON-graph path silently becomes `:unknown_node_type`, not `:SUB_PROCESS`,
    # so `PinResolver.collect_refs/3`'s `node.node_type == :SUB_PROCESS` filter
    # (pin_resolver.ex's `resolve/4`) can never match a node built this way --
    # the module_ref path is confirmed dead code through the real pipeline
    # today, a Graph-level gap one layer beneath REQ-059's own SCOPE GAP
    # (service_catalog/PLC-01 not existing), not something this requirement
    # introduces or is responsible for fixing. `resolve/4`'s own module_ref
    # halt-on-unresolved behavior is still fully covered at the pure-function
    # level against a hand-built `%Node{node_type: :SUB_PROCESS}` struct -- see
    # test/letflow/engine/pin_resolver_test.exs's "an unresolvable module ref
    # returns {:error, {:unresolved_module_ref, ref}}" test.
    test "a resolvable service_id proceeds past resolution -- later activation failure, snapshot-orphan reappears" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_service_task_end("known-svc"))

      attrs =
        base_attrs(definition, %{
          pin_lookup:
            const_pin_lookup({:ok, %{resolved_id: "sid", version: "1.0.0"}}, {:error, :not_found})
        })

      # This fixture's own graph_start_service_task_end/1 sets BOTH "endpoint"
      # and "service_id", so ServiceTask.parse_config_from_node_attributes/1
      # resolves route_kind: :catalog_service (service_id takes precedence).
      # ISS-0917: a catalog node is now resolved at activation from the
      # instance's own pin. The const pin_lookup above pins resolved_id "sid"
      # (not a UUID, and no such catalog row exists), so resolution fails
      # with the typed, non-disclosing :version_not_found -- never the old
      # :service_task_url_rendered_empty, and never a fall-back to the live
      # catalog row.
      assert {:error,
              {:activation_failed, {:service_task_catalog_unresolved, "svc", :version_not_found}}} =
               Engine.create(attrs, prefix: schema_name)

      assert projection_count(schema_name) == 0
      assert event_count(schema_name) == 0
      # unlike the AC2 unresolved-ref cases above, pin resolution itself
      # SUCCEEDED here, so create_snapshot/3 ran before activate/3's own
      # (pre-existing, REQ-059-independent) dispatch failure -- same benign
      # orphan engine_test.exs:580's own test documents.
      assert snapshot_count(schema_name) == 1
    end
  end

  describe "create/2 (REQ-059 AC3) -- variables violating the resolved variable_schema are rejected" do
    test "violating variables return {:error, {:variable_schema_violation, failures}} listing every failing field, zero rows written" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      schema = %{
        "type" => "object",
        "required" => ["approver", "amount"],
        "properties" => %{"amount" => %{"type" => "number", "minimum" => 0}}
      }

      attrs =
        base_attrs(definition, %{
          initial_variables: %{"amount" => -5},
          pin_lookup: variable_schema_pin_lookup(schema)
        })

      assert {:error, {:variable_schema_violation, failures}} =
               Engine.create(attrs, prefix: schema_name)

      assert length(failures) == 2
      assert Enum.any?(failures, &(&1.field_path == "/approver" and &1.constraint == "required"))
      assert Enum.any?(failures, &(&1.field_path == "/amount" and &1.constraint == "minimum"))

      assert projection_count(schema_name) == 0
      assert snapshot_count(schema_name) == 0
      assert event_count(schema_name) == 0
    end

    test "initial_variables conforming to the resolved schema are accepted" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      schema = %{"type" => "object", "required" => ["approver"]}

      attrs =
        base_attrs(definition, %{
          initial_variables: %{"approver" => "alice"},
          pin_lookup: variable_schema_pin_lookup(schema)
        })

      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)
      assert result.variables == %{"approver" => "alice"}
    end
  end

  describe "create/2 (REQ-059 AC4) -- INSTANCE_STARTED payload carries pinned_versions, no separate pin table" do
    test "zero catalog/module references still records exactly one variable_schema pinned_versions entry" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert {:ok, events} = Reconstruction.read_full_log(result.instance_id, schema_name, 1)
      started = Enum.find(events, &(&1.event_type == "INSTANCE_STARTED"))

      assert [%{"kind" => "variable_schema"}] = started.payload["pinned_versions"]
      refute Map.has_key?(started.payload, "pin_conflicts")
    end

    test "no priv/repo/migrations file creates a separate pin table -- the event log is the only record of a pin" do
      migrations_dir = Path.join([File.cwd!(), "priv", "repo", "migrations"])

      pin_table_migrations =
        migrations_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.filter(fn filename ->
          contents = File.read!(Path.join(migrations_dir, filename))
          contents =~ ~r/create\s+table\([:"]?[a-z_]*pin/i
        end)

      assert pin_table_migrations == [],
             "found migration(s) creating a pin-shaped table, contradicting PIN-02 AC3's " <>
               "\"event log is the record of record\": #{inspect(pin_table_migrations)}"
    end
  end

  describe "create/2 (REQ-059 AC6) -- child pin inheritance and conflict recording" do
    test "a child with a differing pin than its parent inherits the PARENT's version, records the conflict" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      parent_attrs =
        base_attrs(definition, %{
          pin_lookup: variable_schema_pin_lookup(nil),
          pin_overrides: [
            %{
              kind: :variable_schema,
              ref: definition.name,
              version: "1.0.0"
            }
          ]
        })

      assert {:ok, parent} = Engine.create(parent_attrs, prefix: schema_name)

      assert {:ok, parent_events} =
               Reconstruction.read_full_log(parent.instance_id, schema_name, 1)

      parent_started = Enum.find(parent_events, &(&1.event_type == "INSTANCE_STARTED"))

      assert [%{"version" => "1.0.0", "source" => "override"}] =
               parent_started.payload["pinned_versions"]

      refute Map.has_key?(parent_started.payload, "pin_conflicts")

      child_attrs =
        base_attrs(definition, %{parent_instance_id: parent.instance_id})

      assert {:ok, child} = Engine.create(child_attrs, prefix: schema_name)

      assert {:ok, child_events} = Reconstruction.read_full_log(child.instance_id, schema_name, 1)
      child_started = Enum.find(child_events, &(&1.event_type == "INSTANCE_STARTED"))

      assert [%{"version" => "1.0.0", "source" => "inherited"}] =
               child_started.payload["pinned_versions"]

      expected_ref = definition.name

      assert [
               %{
                 "kind" => "variable_schema",
                 "ref" => ^expected_ref,
                 "child_resolved_version" => "unversioned",
                 "inherited_version" => "1.0.0"
               }
             ] = child_started.payload["pin_conflicts"]
    end

    test "a child agreeing with its parent's pin has zero conflicts, but pin_conflicts: [] is still present (vs. root's omitted key)" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      parent_attrs =
        base_attrs(definition, %{
          pin_overrides: [
            %{
              kind: :variable_schema,
              ref: definition.name,
              version: "unversioned"
            }
          ]
        })

      assert {:ok, parent} = Engine.create(parent_attrs, prefix: schema_name)

      child_attrs = base_attrs(definition, %{parent_instance_id: parent.instance_id})
      assert {:ok, child} = Engine.create(child_attrs, prefix: schema_name)

      assert {:ok, child_events} = Reconstruction.read_full_log(child.instance_id, schema_name, 1)
      child_started = Enum.find(child_events, &(&1.event_type == "INSTANCE_STARTED"))

      assert child_started.payload["pin_conflicts"] == []
    end
  end

  describe "create/2 (REQ-059 AC7) -- replay derives pins from events only, zero catalog/module reads" do
    test "reconstruct_effective_pins/2, called after a call-counted create/2, never increments that counter (no Lookup param to reach it)" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      counting_lookup = %Lookup{
        catalog_lookup: fn ref ->
          Agent.update(counter, &(&1 + 1))
          {:ok, %{resolved_id: ref, version: "1.0.0"}}
        end,
        module_lookup: fn ref ->
          Agent.update(counter, &(&1 + 1))
          {:ok, %{resolved_id: ref, version: "1.0.0"}}
        end,
        variable_schema_lookup: fn tenant_id, process_key ->
          Agent.update(counter, &(&1 + 1))
          default_variable_schema_lookup(tenant_id, process_key)
        end
      }

      attrs = base_attrs(definition, %{pin_lookup: counting_lookup})
      assert {:ok, result} = Engine.create(attrs, prefix: schema_name)

      count_after_create = Agent.get(counter, & &1)

      assert count_after_create == 1,
             "expected exactly the one variable_schema lookup call create/2 itself makes"

      assert {:ok, effective_pins} =
               PinResolver.reconstruct_effective_pins(result.instance_id, prefix: schema_name)

      assert [%{kind: :variable_schema, version: "unversioned"}] = effective_pins

      assert Agent.get(counter, & &1) == count_after_create,
             "reconstruct_effective_pins/2 must issue zero catalog/module/variable_schema lookup calls -- " <>
               "the counter changed after replay"

      Agent.stop(counter)
    end

    test "reconstruct_effective_pins/2 on an instance with no events returns {:error, :instance_not_found}" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:error, :instance_not_found} =
               PinResolver.reconstruct_effective_pins(Ecto.UUID.generate(), prefix: schema_name)
    end
  end
end
