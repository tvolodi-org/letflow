defmodule Letflow.ISS0974JoinDispatchIdMapTest do
  @moduledoc """
  Regression coverage for ISS-0974 -- a `PARALLEL_GATEWAY` join firing within
  the same hop chain and leading directly into a `:SERVICE_TASK` (or a
  `:TIMER`-start node) minted a dispatch/timer row with the join's own
  synthetic, non-UUID `token_id` (`Transition.fire_join/5`'s
  `"<origin>/<join_node>/joined"` string), instead of the real, persisted
  `TokenRecord` id. See `docs/issues/ISS-0974.yaml` and the gate-approved
  design, `lib/letflow/design/iss0974-join-dispatch-id-map-fix.md`.

  Root cause (confirmed by direct reading, design doc §0/§2): unlike
  `build_task_activation_and_reconciliation_multi/4` (ISS-0408's fix, which
  already threads the real `id_map` `insert_hop_chain_new_token_records/5`
  produces into the task-activation/reconciliation Multi steps), the two
  SIBLING `Multi.merge/2` blocks immediately after it -- one for
  `prepared_timers`/`build_timer_arms_multi/4`, one for
  `prepared_service_task_dispatches`/`build_service_task_dispatch_multi/5` --
  each independently built their own id_map as a pure IDENTITY map
  (`Map.new(prepared, fn t -> {t, t} end)`), on the stale assumption that
  every token_id reaching them is already a real, persisted `TokenRecord`
  id. That assumption breaks exactly when a `PARALLEL_GATEWAY` join fires
  same-hop-chain and its own outgoing edge leads directly to a
  `:SERVICE_TASK` or `:TIMER` node -- the join-merged token's id is still
  the synthetic string at that point, and `Ecto.UUID.cast/1` (via
  `ServiceTaskDispatch.arm_changeset/2` / `Letflow.Scheduler.Timer`'s own
  changeset) rejects it.

  THE FIX (`lib/letflow/engine.ex`, 4 call sites, 8 `Multi.merge/2`
  callbacks total): each sibling merge now reads the real id_map back out
  of the transaction's accumulated `changes` (already computed earlier in
  the same pipe by `insert_hop_chain_new_token_records/5`, keyed
  `{:hop_chain_token_records, <instance_id>}`) and falls back to identity
  only for token_ids that map doesn't cover (design doc §2.1's sparse-map
  argument) -- `build_timer_arms_multi/4` and
  `build_service_task_dispatch_multi/5` themselves are unchanged, they were
  always handed a wrong `id_map`.

  Originally this file covered site 1 only
  (`build_complete_task_tail_multi/6`, reached via `complete_task/3` --
  the design doc's own §2.2 confirms all 4 sites share the identical
  expression-level fix, so this was not 4x redundant coverage, just the one
  call site a real `complete_task/3` hop chain can reach without also
  needing a TIMER-fired/escalation-timer-fired/SERVICE_TASK-outcome
  re-entry scaffold).

  ## ISS-0976 follow-up (sites 2-4)

  RELEASE-VALIDATOR's own mutation test on ISS-0974's closure (filed as
  `docs/issues/ISS-0976.yaml`) found that reverting sites 2
  (`persist_timer_fired_advance/7`), 3 (`persist_escalation_timer_fired_advance/7`),
  and 4 (`do_persist_service_task_advance/10`) back to their pre-fix
  identity-id_map code -- while leaving site 1 fixed -- still passed the
  full regression suite: those 3 sites had zero independent coverage. The
  3 describe blocks below close that gap, each reaching its own site via
  that site's own distinct re-entry path (not site 1's `complete_task/3`):

    - "join -> SERVICE_TASK via Scheduler.poll_and_fire/1 (TIMER branch,
      same hop chain)" reaches site 2 (`persist_timer_fired_advance/7`) by
      firing an ordinary (non-escalation) due `:TIMER` branch of a
      `PARALLEL_GATEWAY` split whose sibling `:HUMAN_TASK` branch is
      already completed, so the timer-fire call is the one that fires the
      join.
    - "join -> SERVICE_TASK via an escalation timer firing (same hop
      chain)" reaches site 3 (`persist_escalation_timer_fired_advance/7`)
      the same way, but the join-satisfying branch is a `:HUMAN_TASK` whose
      *escalation* timer fires (routing along the task's own outgoing edge
      into the join) rather than being completed normally.
    - "join -> SERVICE_TASK via ServiceTaskDispatcher.poll_and_dispatch/1
      (SERVICE_TASK branch, same hop chain)" reaches site 4
      (`do_persist_service_task_advance/10`) by letting a real dispatched
      `:SERVICE_TASK` branch resolve to `:advance` through the real poller,
      which is the join-satisfying event.

  Each of these 3 new tests was confirmed, for this run, to FAIL against a
  hand-reverted copy of its own specific site only (the other 3 sites left
  fixed) with the same real `Ecto.Changeset` `:token_id` cast error
  (`{"is invalid", [type: Ecto.UUID, validation: :cast]}`) ISS-0974's own
  site-1 tests failed with pre-fix, and to PASS again once that site's fix
  was restored. See this run's own final report for the verbatim command
  output and the specific hand-revert applied per site.

  Fail-then-pass proof (WF-02 Step 2a, site 1's own original tests): both
  describe blocks below were run against the pre-fix commit (`git stash` of
  this branch's own `lib/letflow/engine.ex` changes, confirmed identical to
  `origin/main` at the branch point) and failed with a real
  `Ecto.Changeset` cast error on `:token_id` (`{"is invalid", [type:
  Ecto.UUID, validation: :cast]}`); then run again with the fix restored
  and confirmed to pass. See this run's own final report for the verbatim
  command output.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked
  database. `async: false`, matching every other tenant-fixture-using file
  in this codebase. Self-contained: fixtures are duplicated here rather
  than shared with `test/letflow/iss0408_join_token_record_test.exs` (this
  file's own direct structural model) or
  `test/letflow/engine/service_task_wiring_test.exs`/`timer_wiring_test.exs`,
  per this codebase's established "each test file provisions its own
  fixtures" discipline.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture
  alias Letflow.WebhookTestServer

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "ISS-0974 Join Dispatch Id Map Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp enable_ssrf_bypass do
    Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
    on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)
  end

  # START -> PARALLEL_GATEWAY(split) -> HUMAN_TASK(a) / HUMAN_TASK(b) ->
  # PARALLEL_GATEWAY(join) -> SERVICE_TASK(svc) -> END.
  # Distinguishing feature vs. iss0408_join_token_record_test.exs's own
  # `graph_join_then_human_task/0`: the join's own outgoing edge leads
  # directly to a dispatch-needing :SERVICE_TASK node, not another
  # :HUMAN_TASK (which already goes through the already-fixed
  # task-activation/reconciliation path, not build_service_task_dispatch_multi/5).
  defp graph_join_then_service_task(endpoint) do
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
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => endpoint, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "svc"},
        %{"id" => "e7", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # Same split/join shape, but the join's outgoing edge leads directly to a
  # :TIMER node instead -- the structurally-identical generalized-bug-class
  # case the design doc (and ISS-0974's own acceptance criteria) calls out
  # explicitly: build_timer_arms_multi/4 has the exact same
  # Map.fetch!(id_map, token_id) shape as build_service_task_dispatch_multi/5.
  defp graph_join_then_timer(duration) do
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
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "tmr"},
        %{"id" => "e7", "source" => "tmr", "target" => "end"}
      ]
    }
  end

  defp create_definition_attrs(graph) do
    %{
      name: unique_name("iss0974-def"),
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

  defp start_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("iss0974-start")
      },
      overrides
    )
  end

  defp complete_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_name("iss0974-complete")
      },
      overrides
    )
  end

  defp task_by_node_id(schema_name, node_id) do
    schema_name
    |> tasks_for()
    |> Enum.find(&(&1.node_id == node_id))
  end

  defp tasks_for(schema_name) do
    Repo.all(EngineTask, prefix: schema_name)
  end

  defp dispatches_for(schema_name, instance_id) do
    ServiceTaskDispatch
    |> where([d], d.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
  end

  defp timers_for(schema_name, instance_id) do
    Timer
    |> where([t], t.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # Case 1 -- join -> SERVICE_TASK (build_service_task_dispatch_multi/5 sibling)
  # ---------------------------------------------------------------------------------

  describe "join -> SERVICE_TASK via complete_task/3 (same hop chain)" do
    test "the second complete_task/3 call fires the join and creates a real service_task_dispatches row, not a 422/cast error" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant("iss0974-svc")
      definition = active_definition!(schema_name, graph_join_then_service_task(server_url))

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_id = created.instance_id
      assert Enum.sort(created.current_nodes) == ["task_a", "task_b"]

      task_a = task_by_node_id(schema_name, "task_a")
      task_b = task_by_node_id(schema_name, "task_b")

      # First branch: join does not fire yet -- succeeded pre-fix and
      # post-fix alike.
      assert {:ok, after_a} =
               Engine.complete_task(task_a.id, complete_attrs(), prefix: schema_name)

      assert after_a.instance_status == :active

      # Second branch: fires the join, whose own outgoing edge leads
      # directly to the SERVICE_TASK node "svc" -- the exact ISS-0974
      # scenario. Pre-fix: {:error, %Ecto.Changeset{}} with a :token_id
      # cast error (Ecto.UUID rejecting the join's synthetic string id).
      # Post-fix: succeeds, a real dispatch row is created.
      result = Engine.complete_task(task_b.id, complete_attrs(), prefix: schema_name)

      assert {:ok, after_b} = result
      assert after_b.instance_status == :active
      assert after_b.current_nodes == ["svc"]

      # Exactly one new service_task_dispatches row exists for "svc", whose
      # token_id is a real UUID backed by a real, persisted TokenRecord row
      # (not the join's own synthetic "<origin>/join/joined" string).
      assert [dispatch] = dispatches_for(schema_name, instance_id)
      assert dispatch.node_id == "svc"
      assert dispatch.status == :pending
      assert {:ok, _} = Ecto.UUID.cast(dispatch.token_id)

      token_records = Repo.all(TokenRecord, prefix: schema_name)
      assert [joined_record] = Enum.filter(token_records, &(&1.node_id == "svc"))
      assert joined_record.id == dispatch.token_id
      assert joined_record.branch_id == nil
      assert joined_record.status == :active

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # Case 2 -- join -> TIMER (build_timer_arms_multi/4 sibling) -- the
  # generalized bug class ISS-0974's own acceptance criteria name explicitly.
  # ---------------------------------------------------------------------------------

  describe "join -> TIMER via complete_task/3 (same hop chain)" do
    test "the second complete_task/3 call fires the join and arms a real timers row, not a 422/cast error" do
      %{schema_name: schema_name} = provisioned_tenant("iss0974-tmr")
      definition = active_definition!(schema_name, graph_join_then_timer("P1D"))

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_id = created.instance_id
      assert Enum.sort(created.current_nodes) == ["task_a", "task_b"]

      task_a = task_by_node_id(schema_name, "task_a")
      task_b = task_by_node_id(schema_name, "task_b")

      assert {:ok, after_a} =
               Engine.complete_task(task_a.id, complete_attrs(), prefix: schema_name)

      assert after_a.instance_status == :active

      # Fires the join, whose own outgoing edge leads directly to the
      # :TIMER node "tmr". Pre-fix: the same {:error, %Ecto.Changeset{}}
      # :token_id cast-error class as case 1, surfaced instead from
      # Letflow.Scheduler.Timer's own changeset (build_timer_arms_multi/4).
      # Post-fix: succeeds, a real timers row is armed.
      result = Engine.complete_task(task_b.id, complete_attrs(), prefix: schema_name)

      assert {:ok, after_b} = result
      assert after_b.instance_status == :active
      assert after_b.current_nodes == ["tmr"]

      assert [timer] = timers_for(schema_name, instance_id)
      assert timer.node_id == "tmr"
      assert {:ok, _} = Ecto.UUID.cast(timer.token_id)

      token_records = Repo.all(TokenRecord, prefix: schema_name)
      assert [joined_record] = Enum.filter(token_records, &(&1.node_id == "tmr"))
      assert joined_record.id == timer.token_id
      assert joined_record.branch_id == nil
      assert joined_record.status == :active

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0976 follow-up fixtures/helpers -- sites 2-4.
  # ---------------------------------------------------------------------------------

  # START -> PARALLEL_GATEWAY(split) -> TIMER(tmr, non-escalation, due
  # immediately) / HUMAN_TASK(task_b) -> PARALLEL_GATEWAY(join) ->
  # SERVICE_TASK(svc) -> END. Distinguishing feature vs.
  # graph_join_then_service_task/1: the join-satisfying event is a plain
  # TIMER firing (reaches site 2, persist_timer_fired_advance/7), not a
  # complete_task/3 call.
  defp graph_split_timer_then_join_service_task(endpoint) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "tmr", "node_type" => "TIMER", "attributes" => %{"duration_iso8601" => "P0D"}},
        %{
          "id" => "task_b",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_b"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => endpoint, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "tmr"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "tmr", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "svc"},
        %{"id" => "e7", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # START -> PARALLEL_GATEWAY(split) -> HUMAN_TASK(task_a, escalation
  # P0D/role-escalation) / HUMAN_TASK(task_b, plain) -> PARALLEL_GATEWAY(join)
  # -> SERVICE_TASK(svc) -> END. task_a's own single outgoing edge goes
  # straight to "join" -- its escalation timer firing (not a normal
  # complete_task/3 call) is what carries its token onto that edge. The
  # join-satisfying event is therefore the escalation timer fire (reaches
  # site 3, persist_escalation_timer_fired_advance/7).
  defp graph_split_escalation_then_join_service_task(endpoint) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "task_a",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{
            "role" => "approver_a",
            "escalation_timer_duration" => "P0D",
            "escalation_role" => "role-escalation"
          }
        },
        %{
          "id" => "task_b",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_b"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => endpoint, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "task_a"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "task_a", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "svc"},
        %{"id" => "e7", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # START -> PARALLEL_GATEWAY(split) -> SERVICE_TASK(svc_a) /
  # HUMAN_TASK(task_b) -> PARALLEL_GATEWAY(join) -> SERVICE_TASK(svc_c) ->
  # END. The join-satisfying event is svc_a's own dispatch resolving to
  # :advance through the real poller (reaches site 4,
  # do_persist_service_task_advance/10), not a complete_task/3 call or a
  # timer fire.
  defp graph_split_service_task_then_join_service_task(endpoint_a, endpoint_c) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "svc_a",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => endpoint_a, "timeout_ms" => 5_000}
        },
        %{
          "id" => "task_b",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver_b"}
        },
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{
          "id" => "svc_c",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => endpoint_c, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "svc_a"},
        %{"id" => "e3", "source" => "split", "target" => "task_b"},
        %{"id" => "e4", "source" => "svc_a", "target" => "join"},
        %{"id" => "e5", "source" => "task_b", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "svc_c"},
        %{"id" => "e7", "source" => "svc_c", "target" => "end"}
      ]
    }
  end

  defp escalation_timer_for_node(schema_name, instance_id, node_id) do
    schema_name
    |> timers_for(instance_id)
    |> Enum.find(&(&1.timer_type == "escalation" and &1.node_id == node_id))
  end

  # ---------------------------------------------------------------------------------
  # ISS-0976 site 2 -- join -> SERVICE_TASK via Scheduler.poll_and_fire/1
  # (persist_timer_fired_advance/7)
  # ---------------------------------------------------------------------------------

  describe "ISS-0976 site 2: join -> SERVICE_TASK via TIMER fire (Scheduler.poll_and_fire/1)" do
    test "firing the due TIMER branch fires the join and creates a real service_task_dispatches row, not a cast error" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant("iss0976-s2")

      definition =
        active_definition!(schema_name, graph_split_timer_then_join_service_task(server_url))

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_id = created.instance_id
      assert Enum.sort(created.current_nodes) == ["task_b", "tmr"]

      task_b = task_by_node_id(schema_name, "task_b")

      # First branch: complete task_b normally. The join does not fire yet
      # -- the "tmr" branch is still outstanding. Succeeds identically
      # pre-fix and post-fix (this call never reaches any of the 4 buggy
      # sites -- its own hop chain terminates with nothing left to dispatch).
      assert {:ok, after_b} =
               Engine.complete_task(task_b.id, complete_attrs(), prefix: schema_name)

      assert after_b.instance_status == :active

      [timer] = timers_for(schema_name, instance_id)

      # Second branch: the due TIMER fires via Letflow.Scheduler.fire_timer/2
      # (the same direct per-timer entry point timer_wiring_test.exs and
      # human_task_escalation_test.exs use) -> Letflow.Engine.advance_after_timer_fired/3
      # -> persist_timer_fired_advance/7, site 2. This fires the join,
      # whose own outgoing edge leads directly to the SERVICE_TASK node
      # "svc". Pre-fix (site 2 reverted to identity id_map): {:error,
      # %Ecto.Changeset{}} with a :token_id cast error, surfaced here as
      # fire_timer/2's own {:error, reason}. Post-fix: {:ok, :fired}, a
      # real dispatch row is created.
      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema_name)

      reloaded_timer = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded_timer.status == "fired"

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
      assert projection.current_nodes == ["svc"]

      # Exactly one new service_task_dispatches row exists for "svc", whose
      # token_id is a real UUID backed by a real, persisted TokenRecord row
      # (not the join's own synthetic "<origin>/join/joined" string).
      assert [dispatch] = dispatches_for(schema_name, instance_id)
      assert dispatch.node_id == "svc"
      assert dispatch.status == :pending
      assert {:ok, _} = Ecto.UUID.cast(dispatch.token_id)

      token_records = Repo.all(TokenRecord, prefix: schema_name)
      assert [joined_record] = Enum.filter(token_records, &(&1.node_id == "svc"))
      assert joined_record.id == dispatch.token_id
      assert joined_record.branch_id == nil
      assert joined_record.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0976 site 3 -- join -> SERVICE_TASK via an escalation timer firing
  # (persist_escalation_timer_fired_advance/7)
  # ---------------------------------------------------------------------------------

  describe "ISS-0976 site 3: join -> SERVICE_TASK via escalation timer fire" do
    test "firing task_a's escalation timer fires the join and creates a real service_task_dispatches row, not a cast error" do
      enable_ssrf_bypass()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant("iss0976-s3")

      definition =
        active_definition!(schema_name, graph_split_escalation_then_join_service_task(server_url))

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_id = created.instance_id
      assert Enum.sort(created.current_nodes) == ["task_a", "task_b"]

      task_b = task_by_node_id(schema_name, "task_b")

      # First branch: complete task_b normally. The join does not fire yet
      # -- task_a's own branch is still outstanding (never completed; it
      # will be escalated instead).
      assert {:ok, after_b} =
               Engine.complete_task(task_b.id, complete_attrs(), prefix: schema_name)

      assert after_b.instance_status == :active

      escl_timer = escalation_timer_for_node(schema_name, instance_id, "task_a")
      assert %Timer{status: "pending"} = escl_timer

      # Second branch: task_a's escalation timer fires via the real
      # Letflow.Scheduler.fire_timer/2 entry point, which routes "escalation"
      # timer_type to Letflow.Engine.advance_after_escalation_timer_fired/3
      # -> persist_escalation_timer_fired_advance/7, site 3. This cancels
      # the original task_a row and follows task_a's own single outgoing
      # edge directly into "join", which fires (task_b's branch already
      # satisfied) and whose own outgoing edge leads directly to the
      # SERVICE_TASK node "svc". Pre-fix (site 3 reverted to identity
      # id_map): {:error, %Ecto.Changeset{}} with a :token_id cast error.
      # Post-fix: succeeds, a real dispatch row is created.
      assert {:ok, :fired} = Scheduler.fire_timer(escl_timer.id, schema_name)

      task_a = task_by_node_id(schema_name, "task_a")
      assert task_a.status == :cancelled

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
      assert projection.current_nodes == ["svc"]

      assert [dispatch] = dispatches_for(schema_name, instance_id)
      assert dispatch.node_id == "svc"
      assert dispatch.status == :pending
      assert {:ok, _} = Ecto.UUID.cast(dispatch.token_id)

      token_records = Repo.all(TokenRecord, prefix: schema_name)
      assert [joined_record] = Enum.filter(token_records, &(&1.node_id == "svc"))
      assert joined_record.id == dispatch.token_id
      assert joined_record.branch_id == nil
      assert joined_record.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0976 site 4 -- join -> SERVICE_TASK via ServiceTaskDispatcher.poll_and_dispatch/1
  # (do_persist_service_task_advance/10)
  # ---------------------------------------------------------------------------------

  describe "ISS-0976 site 4: join -> SERVICE_TASK via SERVICE_TASK advance (poll_and_dispatch/1)" do
    test "svc_a's dispatch resolving via the real poller fires the join and arms svc_c, not a cast error" do
      enable_ssrf_bypass()
      %{url: url_a} = WebhookTestServer.start(200, ~s({"ok":true}))
      %{url: url_c} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant("iss0976-s4")

      definition =
        active_definition!(
          schema_name,
          graph_split_service_task_then_join_service_task(url_a, url_c)
        )

      assert {:ok, created} = Engine.create(start_attrs(definition), prefix: schema_name)
      instance_id = created.instance_id
      assert Enum.sort(created.current_nodes) == ["svc_a", "task_b"]

      task_b = task_by_node_id(schema_name, "task_b")

      # First branch: complete task_b normally. The join does not fire yet
      # -- svc_a's own dispatch is still pending.
      assert {:ok, after_b} =
               Engine.complete_task(task_b.id, complete_attrs(), prefix: schema_name)

      assert after_b.instance_status == :active

      assert [svc_a_dispatch] = dispatches_for(schema_name, instance_id)
      assert svc_a_dispatch.node_id == "svc_a"
      assert svc_a_dispatch.status == :pending

      # Second branch, phase 1: svc_a's own HTTP round trip resolves via the
      # real transport call (REQ-214, already-shipped), same as AC1's own
      # two-phase pattern in service_task_wiring_test.exs.
      assert {:ok, {:advance, decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(svc_a_dispatch.id, schema_name)

      reloaded_svc_a_dispatch =
        Repo.get!(ServiceTaskDispatch, svc_a_dispatch.id, prefix: schema_name)

      assert reloaded_svc_a_dispatch.status == :advanced

      # Second branch, phase 2: Letflow.Engine.advance_after_service_task_outcome/4
      # (the exact call ServiceTaskDispatcher.poll_and_dispatch/1's own reduce
      # loop makes) -> persist_service_task_advance/10 ->
      # do_persist_service_task_advance/10, site 4. This fires the join
      # (task_b's branch already satisfied), whose own outgoing edge leads
      # directly to the SERVICE_TASK node "svc_c". Pre-fix (site 4 reverted
      # to identity id_map): {:error, %Ecto.Changeset{}} with a :token_id
      # cast error. Post-fix: {:ok, :advanced}, a real second dispatch row
      # is created.
      assert {:ok, :advanced} =
               Engine.advance_after_service_task_outcome(
                 svc_a_dispatch.id,
                 {:advance, decoded_body},
                 Repo,
                 schema_name
               )

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :active
      assert projection.current_nodes == ["svc_c"]

      dispatches = dispatches_for(schema_name, instance_id)
      assert [svc_c_dispatch] = Enum.filter(dispatches, &(&1.node_id == "svc_c"))
      assert svc_c_dispatch.status == :pending
      assert {:ok, _} = Ecto.UUID.cast(svc_c_dispatch.token_id)

      token_records = Repo.all(TokenRecord, prefix: schema_name)
      assert [joined_record] = Enum.filter(token_records, &(&1.node_id == "svc_c"))
      assert joined_record.id == svc_c_dispatch.token_id
      assert joined_record.branch_id == nil
      assert joined_record.status == :active
    end
  end
end
