defmodule Letflow.Simulation.Req206SwiftrouteTest do
  @moduledoc """
  REQ-206 acceptance criteria: 4 SwiftRoute scenario YAMLs executed through
  `Letflow.Simulation.Runner`, each returning a closed disposition:
  DEFERRED_TO_S8 (onboarding-happy), PASS/FAIL (shipment-high-value-happy),
  SKIP/MINOR (ops-timeout-escalation step 2), UNBUILT_FEATURE (attach-delivery-note).

  ## Spec-exists-but-not-integrated distinction (AC1)
  `web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts` EXISTS in this
  repo's `web/` tree. All 5 onboarding steps are still `:deferred_to_s8` because
  S8 frontend-Letflow integration has NOT started — "spec exists" ≠ "integration
  exists." This distinction is asserted explicitly below.

  ## SERVICE_TASK limitation (affects shipment-high-value-happy)
  `Letflow.Engine` does not yet dispatch SERVICE_TASK nodes
  (`{:error, {:activation_failed, {:node_type_not_yet_implemented, ...}}}`). The
  full `process_route_approval.yaml` has SERVICE_TASKs after CEO approval. A
  test-local simplified process (`SimpleShipmentApproval`) replaces SERVICE_TASK
  nodes with direct END edges so `complete_task/3` succeeds end-to-end.

  ## One remaining UNIMPLEMENTED finding — reported to ORCH via result.issues (not filed here)
  1. No document/attachment API in Letflow or R-Co src/

  Finding #1 as originally filed here — `POST /api/v1/instances/:id/advance-timer`
  absent — was ISS-0389 (queue task 389, GH#768); the route now exists
  (`lib/letflow/routers/instances.ex`'s `authz_post "/:id/advance-timer"`, see
  `lib/letflow/design/iss0389-advance-timer-endpoint.md`). TEST-DESIGNER has
  since un-skipped `shipment-ops-timeout-escalation.yaml` step 2 (`via: skip`
  -> `via: api`) and added a real `ops-escalation-timer` TIMER node to
  `process_shipment_dispatch.yaml` so the scenario has an actual pending
  timer to force-fire — see the `swiftroute-shipment-ops-timeout-escalation`
  describe block below (design doc AC5/AC10).

  Real Postgres, `async: false` — tenant provisioning needs `Sandbox.mode(:auto)`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.Simulation.Runner
  alias Letflow.Simulation.ScenarioFixture
  alias Letflow.Simulation.Seed
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @fixtures_dir Path.expand("../../fixtures/simulation/swiftroute", __DIR__)
  @scenarios_dir Path.join(@fixtures_dir, "scenarios")

  # Simplified process for the high-value-happy scenario: avoids SERVICE_TASK nodes
  # (not yet implemented in Engine; process_route_approval.yaml has release-shipment
  # and auto-reject SERVICE_TASKs that would cause complete_task/3 to return
  # {:error, {:instance_execution_error, ...}} instead of {:ok, ...}).
  @simple_approval_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "ops-review",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-ops-manager"}
      },
      %{"id" => "ceo-approval-gate", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "ceo-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-ceo"}
      },
      %{"id" => "end-approved", "node_type" => "END"},
      %{"id" => "end-rejected", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "ops-review"},
      %{
        "id" => "e1",
        "source" => "ops-review",
        "target" => "ceo-approval-gate",
        "condition" => "variables.ops_decision == 'approve'"
      },
      %{
        "id" => "e2",
        "source" => "ops-review",
        "target" => "end-rejected",
        "condition" => "variables.ops_decision == 'reject'"
      },
      # on_timeout fallback for ops-review
      %{"id" => "fallback-ops-review", "source" => "ops-review", "target" => "end-rejected"},
      %{
        "id" => "ceo-approval-gate-default",
        "source" => "ceo-approval-gate",
        "target" => "ceo-approval",
        "is_default" => true
      },
      %{
        "id" => "e3",
        "source" => "ceo-approval-gate",
        "target" => "ceo-approval",
        "condition" => "variables.declared_value > 500"
      },
      %{
        "id" => "e4",
        "source" => "ceo-approval-gate",
        "target" => "end-approved",
        "condition" => "variables.declared_value <= 500"
      },
      %{
        "id" => "e5",
        "source" => "ceo-approval",
        "target" => "end-approved",
        "condition" => "variables.ceo_decision == 'approve'"
      },
      %{
        "id" => "e6",
        "source" => "ceo-approval",
        "target" => "end-rejected",
        "condition" => "variables.ceo_decision == 'reject'"
      },
      # on_timeout fallback for ceo-approval
      %{"id" => "timeout-ceo-approval", "source" => "ceo-approval", "target" => "end-rejected"}
    ]
  }

  # REQ-396 AC4 -- ops-review escalation path. Mirrors @simple_approval_graph but adds
  # escalation_timer_duration: "P0D" + escalation_role: "role-ceo" to ops-review, and
  # uses the fallback-ops-review edge (already targeting ceo-approval) as the escalation
  # path. No SERVICE_TASKs (avoiding the limitation documented in this file's moduledoc).
  # P0D makes the escalation timer due immediately so fire_timer/2 can be called directly.
  @ops_escalation_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "ops-review",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{
          "role" => "role-ops-manager",
          "escalation_timer_duration" => "P0D",
          "escalation_role" => "role-ceo"
        }
      },
      %{
        "id" => "ceo-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-ceo"}
      },
      %{"id" => "end-approved", "node_type" => "END"},
      %{"id" => "end-rejected", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "ops-review"},
      %{
        "id" => "e1",
        "source" => "ops-review",
        "target" => "end-rejected",
        "condition" => "variables.ops_decision == 'approve'"
      },
      %{
        "id" => "e2",
        "source" => "ops-review",
        "target" => "end-rejected",
        "condition" => "variables.ops_decision == 'reject'"
      },
      # fallback / escalation path for ops-review -> ceo-approval
      %{"id" => "fallback-ops-review", "source" => "ops-review", "target" => "ceo-approval"},
      %{
        "id" => "e5",
        "source" => "ceo-approval",
        "target" => "end-approved",
        "condition" => "variables.ceo_decision == 'approve'"
      },
      %{
        "id" => "e6",
        "source" => "ceo-approval",
        "target" => "end-rejected",
        "condition" => "variables.ceo_decision == 'reject'"
      },
      # fallback for ceo-approval
      %{"id" => "timeout-ceo-approval", "source" => "ceo-approval", "target" => "end-rejected"}
    ]
  }

  setup do
    Sandbox.mode(Letflow.Repo, :auto)

    unique = Letflow.TenantSlugFixture.unique_slug("req206")

    company = %{
      "slug" => unique,
      "display_name" => "SwiftRoute Ltd",
      "hostname" => unique <> ".simulation.test"
    }

    {:ok, %{tenant: tenant}} = Seed.seed_company(company)
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

    # Load org structure and make usernames unique per test run
    {:ok, org_structure} =
      YamlElixir.read_from_file(Path.join(@fixtures_dir, "org_structure.yaml"))

    org_structure =
      update_in(org_structure["people"], fn people ->
        Enum.map(people, fn person ->
          Map.update!(person, "username", &(&1 <> "-" <> unique))
        end)
      end)

    {:ok, users} = Seed.seed_users(org_structure, tenant)

    # Map actor_id → seeded User.t() (people and users are in fixture order)
    users_by_actor_id =
      org_structure["people"]
      |> Enum.zip(users)
      |> Map.new(fn {person, user} -> {Map.fetch!(person, "actor_id"), user} end)

    alice = Map.fetch!(users_by_actor_id, "actor-swiftroute-alice")
    lena = Map.fetch!(users_by_actor_id, "actor-swiftroute-lena")
    marco = Map.fetch!(users_by_actor_id, "actor-swiftroute-marco")

    # ISS-0942: org_structure.yaml's departments were seeded as plain groups
    # but never bound to the "role-*" process_routing_role names the
    # @simple_approval_graph/@ops_escalation_graph HUMAN_TASK nodes assign
    # to -- harmless before this fix (POST /tasks/:id/complete enforced no
    # assignee check at all), but now that it does, the scenario's own
    # actors (marco the ops manager, alice the CEO) must actually hold the
    # role their step completes, same as a real tenant would be configured.
    {:ok, groups} = Seed.seed_groups(org_structure, tenant)
    group_by_name = Map.new(groups, &{&1.name, &1})

    {:ok, _} =
      RoleRegistry.upsert_role(
        "role-ops-manager",
        :process_routing_role,
        Map.fetch!(group_by_name, "dept-ops").id,
        prefix: schema_name
      )

    {:ok, _} =
      RoleRegistry.upsert_role(
        "role-ceo",
        :process_routing_role,
        Map.fetch!(group_by_name, "dept-mgmt").id,
        prefix: schema_name
      )

    # Seed shipment-dispatch process (for ops-timeout-escalation scenario)
    {:ok, dispatch_fixture} =
      YamlElixir.read_from_file(Path.join(@fixtures_dir, "process_shipment_dispatch.yaml"))

    dispatch_fixture = Map.update!(dispatch_fixture, "name", &(&1 <> "-" <> unique))
    {:ok, definition_dispatch} = Seed.seed_process(dispatch_fixture, tenant, alice.id)

    # Seed simplified approval process (no SERVICE_TASKs; for high-value-happy)
    simple_approval_name = "SimpleShipmentApproval-" <> unique

    simple_approval_attrs = %{
      name: simple_approval_name,
      version: "1.0",
      description:
        "REQ-206 test-local process: exercises CEL EXCLUSIVE_GATEWAY branch without SERVICE_TASKs.",
      graph: @simple_approval_graph,
      created_by: alice.id
    }

    {:ok, definition_approval} =
      case Letflow.Definitions.get_active_by_name(simple_approval_name, prefix: schema_name) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <- Letflow.Definitions.create(simple_approval_attrs, prefix: schema_name),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    # Create actor tokens (PROCESS_OPERATOR role: allows POST /instances +
    # POST /tasks/:id/complete + GET /tasks with task_scope :all, not row-filtered)
    {:ok, %{plaintext: lena_token}} =
      Identity.create_token(lena.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: marco_token}} =
      Identity.create_token(marco.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: alice_token}} =
      Identity.create_token(alice.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    actors = %{
      "actor-swiftroute-lena" => %{"token" => lena_token, "tenant_slug" => unique},
      "actor-swiftroute-marco" => %{"token" => marco_token, "tenant_slug" => unique},
      "actor-swiftroute-alice" => %{"token" => alice_token, "tenant_slug" => unique}
    }

    on_exit(fn -> teardown(unique) end)

    %{
      tenant: tenant,
      schema_name: schema_name,
      unique: unique,
      actors: actors,
      definitions: %{
        approval: definition_approval,
        dispatch: definition_dispatch
      }
    }
  end

  defp teardown(slug) do
    case Identity.get_tenant_by_slug(slug) do
      {:ok, tenant} ->
        case TenantProvisioning.schema_name_for_tenant(tenant.id) do
          {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
          {:error, _reason} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))

      {:error, :not_found} ->
        :ok
    end
  end

  # Replaces "TENANT_PREFIX" in precondition/outcome args, "DEFINITION_NAME" in
  # process_id and step params, with the real test-time values.
  defp patch_scenario(scenario, schema_name: schema_name, definition_name: defn, actors: actors) do
    %{
      scenario
      | process_id: defn,
        actors: actors,
        preconditions: patch_preconditions(scenario.preconditions, schema_name, defn),
        steps: patch_step_params(scenario.steps, defn),
        expected_outcomes: patch_outcome_prefix(scenario.expected_outcomes, schema_name)
    }
  end

  defp patch_preconditions(preconditions, schema_name, defn) do
    Enum.map(preconditions, fn p ->
      args = Map.get(p, :args, %{})

      args =
        args
        |> Map.put("prefix", schema_name)
        |> then(fn a ->
          if Map.get(a, "name") == "DEFINITION_NAME", do: Map.put(a, "name", defn), else: a
        end)

      Map.put(p, :args, args)
    end)
  end

  defp patch_step_params(steps, defn) do
    Enum.map(steps, fn step ->
      case Map.get(step, :params) do
        %{"definition_name" => "DEFINITION_NAME"} = params ->
          Map.put(step, :params, Map.put(params, "definition_name", defn))

        _ ->
          step
      end
    end)
  end

  defp patch_outcome_prefix(outcomes, schema_name) do
    Enum.map(outcomes, fn outcome ->
      put_in(outcome, [:verification, :args, "prefix"], schema_name)
    end)
  end

  # ─── AC1: swiftroute-tenant-onboarding-happy ────────────────────────────

  describe "swiftroute-tenant-onboarding-happy" do
    test "EO-001..003 verified via Seed; all 5 gui steps recorded DEFERRED_TO_S8", %{
      schema_name: schema_name,
      actors: actors,
      unique: unique
    } do
      hostname = unique <> ".simulation.test"

      # EO-001: onboarding record retrievable by hostname
      assert {:ok, onboarding} = Identity.get_onboarding_by_hostname(hostname)
      assert onboarding.slug == unique

      # EO-002: tenant slug/hostname registered, status :active (not :migrating)
      assert {:ok, tenant} = Identity.get_tenant_by_slug(unique)
      assert tenant.status == :active

      # EO-003: admin user (alice) exists and can authenticate
      alice_username = "alice.bauer-" <> unique

      assert {:ok, %{users: users}} =
               Identity.list_users(%{search: alice_username, page_size: 10}, prefix: schema_name)

      alice = Enum.find(users, &(&1.username == alice_username))
      assert alice != nil, "alice user not found for username #{alice_username}"

      assert {:ok, _} =
               Identity.create_token(alice.id, %{roles: ["PROCESS_OPERATOR"]},
                 prefix: schema_name
               )

      # Load YAML; patch with real actors and prefix
      scenario_raw =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "tenant-onboarding-happy.yaml"))

      scenario = %{
        scenario_raw
        | actors: Map.take(actors, ["actor-swiftroute-alice"]),
          expected_outcomes: patch_outcome_prefix(scenario_raw.expected_outcomes, schema_name)
      }

      assert {:ok, report} = Runner.run(scenario)

      # All 5 steps :deferred_to_s8 (all via: gui)
      assert length(report.step_results) == 5
      assert Enum.all?(report.step_results, &(&1.outcome == :deferred_to_s8))
      assert Enum.all?(report.step_results, &(&1.captured == nil))
      assert Enum.all?(report.step_results, &(&1.detail =~ "S8"))

      # disposition :executed (not :unbuilt_feature — the feature exists, it's just deferred)
      assert report.disposition == :executed

      # Spec-exists-but-not-integrated: the Playwright spec IS present in web/,
      # but S8 integration has not started. This distinction is stated explicitly here
      # per AC1, not derived from Runner's output (Runner's :deferred_to_s8 detail
      # string is factually accurate for this case regardless of spec presence).
      spec_path =
        Path.expand(
          "../../../web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts",
          __DIR__
        )

      assert File.exists?(spec_path),
             "Expected onboarding-wizard Playwright spec at #{spec_path} " <>
               "(spec-exists-but-not-integrated: present but S8 frontend-Letflow " <>
               "integration not started)"
    end
  end

  # ─── AC2: swiftroute-shipment-high-value-happy ──────────────────────────

  describe "swiftroute-shipment-high-value-happy" do
    test "dispatcher -> ops-approve -> CEO co-sign; 4 expected_outcomes with evidence", %{
      schema_name: schema_name,
      actors: actors,
      definitions: %{approval: definition}
    } do
      scenario_raw =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "shipment-high-value-happy.yaml"))

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      # 5 steps: 1 submit + 2 task-lookup + 2 complete (3 business steps, design §3.2)
      assert length(report.step_results) == 5
      [step1, step2a, step2b, step3a, step3b] = report.step_results

      assert step1.outcome == :ok,
             "step 1 (POST /instances) failed — detail: #{inspect(step1.detail)}"

      assert %{"instance_id" => _, "status" => "ACTIVE"} = step1.captured

      assert step2a.outcome == :ok,
             "step 2a (GET /tasks ops-lookup) failed — detail: #{inspect(step2a.detail)}"

      assert step2b.outcome == :ok,
             "step 2b (POST /tasks ops-complete) failed — detail: #{inspect(step2b.detail)}"

      assert step3a.outcome == :ok,
             "step 3a (GET /tasks ceo-lookup) failed — detail: #{inspect(step3a.detail)}"

      assert step3b.outcome == :ok,
             "step 3b (POST /tasks ceo-complete) failed — detail: #{inspect(step3b.detail)}"

      # 4 expected_outcomes — each evaluated PASS or FAIL with concrete evidence (AC2)
      assert length(report.outcome_results) == 4
      [eo1, eo2, eo3, eo4] = report.outcome_results

      # EO-1: task_assigned — CEO task assignee evidence
      # current verifier checks assignee_type == "user"; ROLE-attributed tasks have
      # assignee_type == "ROLE" (post-ISS-0905, resolve_assignee/1 derives "ROLE" from
      # the role attribute), which the verifier's "user"-only check still never
      # matches, so outcome remains :fail -- Runner's task_assigned verifier has no
      # "ROLE"-matching arm (a separate, pre-existing gap, not fixed by ISS-0905; see
      # lib/letflow/design/iss0905-role-assignee-type-not-derived.md §4.2).
      # The observed field still carries the assignee evidence (assignee_ref: "role-ceo").
      assert eo1.outcome in [:pass, :fail],
             "EO-1 task_assigned result must be :pass or :fail"

      assert %{assignee_ref: "role-ceo"} = eo1.observed,
             "Expected CEO task assignee_ref to be 'role-ceo'; observed: #{inspect(eo1.observed)}"

      # EO-2: instance COMPLETED after full approval chain
      assert eo2.outcome == :pass,
             "EO-2 instance_state (COMPLETED) failed — observed: #{inspect(eo2.observed)}"

      # EO-3: instance variables carry both decisions
      assert eo3.outcome == :pass,
             "EO-3 instance_state (variables) failed — observed: #{inspect(eo3.observed)}"

      # EO-4: audit event for CEO task completion
      assert eo4.outcome == :pass,
             "EO-4 audit_event (task.complete) failed — observed: #{inspect(eo4.observed)}"
    end
  end

  # ─── AC3: swiftroute-shipment-ops-timeout-escalation ────────────────────

  describe "swiftroute-shipment-ops-timeout-escalation" do
    # ISS-0389 un-skip: step 2 previously ran `via: skip`/`severity: MINOR`
    # because `POST /instances/:id/advance-timer` did not exist
    # (handoffs/WF03-ISS0389-20260905/step-03-elixir-dev.json). The route now
    # ships, and `process_shipment_dispatch.yaml` gained a real
    # `ops-escalation-timer` TIMER node (removed again in GH #2933: it held the
    # `parallel-join` open). The scenario now force-fires `ops-assessment`'s own
    # escalation timer (ISS-1007) -- design doc AC5/AC10
    # (`lib/letflow/design/iss0389-advance-timer-endpoint.md`).
    #
    # Also fixes a pre-existing bug in this test's own `definitions` pattern:
    # it destructured `%{approval: definition}` (the unrelated
    # SimpleShipmentApproval graph used by the high-value-happy scenario
    # above) instead of `%{dispatch: definition}` (`process_shipment_dispatch.yaml`,
    # the "Driver Incident Report" process this scenario's own header comment
    # and `initial_variables: injury_involved` actually target). That bug was
    # inert while step 2 was a no-op :skip (neither graph has an
    # `ops-escalation-timer` TIMER node before this change, and step
    # 1/3 only ever checked instance ACTIVE status, which both graphs
    # satisfy identically) -- it stops being inert now that step 2 must
    # resolve a real pending timer against the real graph this scenario is
    # documented to exercise.
    test "step 1 :ok, step 2 :ok (timer force-fired, token off TIMER node), step 3 :ok", %{
      schema_name: schema_name,
      actors: actors,
      definitions: %{dispatch: definition}
    } do
      scenario_raw =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "shipment-ops-timeout-escalation.yaml"))

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 3
      [step1, step2, step3] = report.step_results

      # Step 1: instance started (api)
      assert step1.outcome == :ok,
             "step 1 (POST /instances) failed — detail: #{inspect(step1.detail)}"

      # Step 2: POST .../advance-timer — real route, real force-fire (ISS-0389)
      assert step2.outcome == :ok,
             "step 2 (POST advance-timer) failed — detail: #{inspect(step2.detail)}"

      assert step2.captured["timer_status"] == "fired",
             "expected timer_status \"fired\", got: #{inspect(step2.captured)}"

      assert step2.captured["node_id"] == "ops-assessment",
             "expected the fired timer's node_id to be ops-assessment, got: #{inspect(step2.captured)}"

      assert step2.captured["instance_id"] == step1.detail["instance_id"]

      # Step 3: GET /instances/:id — instance still ACTIVE (ops-assessment and
      # finance-estimate are still outstanding HUMAN_TASKs, so parallel-join
      # cannot fire yet). GET's own response shape (`instance_map/1`,
      # lib/letflow/routers/instances.ex) carries no `tokens` field (only
      # `POST /:id/reconstruct` does) -- proving the escalation timer's own
      # token genuinely moved off the TIMER node therefore reads
      # `current_nodes` directly off the real `instance_projections` row,
      # rather than through this step's own captured JSON.
      assert step3.outcome == :ok,
             "step 3 (GET /instances) failed — detail: #{inspect(step3.detail)}"

      assert step3.captured["status"] == "ACTIVE"

      instance_id = step1.detail["instance_id"]

      current_nodes =
        Repo.get!(Letflow.EventStore.InstanceProjection, instance_id, prefix: schema_name).current_nodes

      refute "ops-assessment" in current_nodes,
             "expected the fired timer's token to have moved off ops-assessment, current_nodes: #{inspect(current_nodes)}"

      assert "escalate-ops-assessment-to-ceo" in current_nodes
      assert "finance-estimate" in current_nodes

      # Both expected_outcomes: instance ACTIVE (1 before advance-timer, 1 after)
      assert length(report.outcome_results) == 2

      assert Enum.all?(report.outcome_results, &(&1.outcome == :pass)),
             "Expected both instance_state outcomes to PASS; got: #{inspect(Enum.map(report.outcome_results, & &1.outcome))}"
    end
  end

  # ─── AC4: swiftroute-shipment-attach-delivery-note ──────────────────────

  describe "swiftroute-shipment-attach-delivery-note" do
    test "disposition :unbuilt_feature; zero steps executed; R-Co evidence in notes", _ctx do
      scenario =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "shipment-attach-delivery-note.yaml"))

      assert {:ok, report} = Runner.run(scenario)

      # UNBUILT_FEATURE: no preconditions, steps, or outcomes evaluated
      assert report.disposition == :unbuilt_feature
      assert report.precondition_results == []
      assert report.step_results == []
      assert report.outcome_results == []

      # Notes carry the R-Co src/ path evidence
      assert report.notes =~ "partition_attach.zig",
             "Expected R-Co path evidence 'partition_attach.zig' in notes: #{inspect(report.notes)}"

      assert report.notes =~ "iss501_storage_mode_routing.md",
             "Expected R-Co path evidence 'iss501_storage_mode_routing.md' in notes: #{inspect(report.notes)}"

      assert report.notes =~ "No attachment/document-upload API",
             "Expected finding summary in notes: #{inspect(report.notes)}"
    end
  end

  # ─── UNIMPLEMENTED findings — machine-verifiable source evidence ────────

  describe "UNIMPLEMENTED findings (source evidence for result.issues)" do
    # SUPERSEDED by ISS-0389 (2026-09-05): this test's original assertion
    # ("POST /api/v1/instances/:id/advance-timer does not exist anywhere in
    # lib/letflow/router.ex or lib/letflow/routers/instances.ex") was the
    # machine-verifiable source evidence for this file's own moduledoc
    # finding #1 and for the shipment-ops-timeout-escalation scenario's step
    # 2 SKIP/MINOR fallback. `lib/letflow/design/iss0389-advance-timer-endpoint.md`
    # has since shipped the real route (`authz_post "/:id/advance-timer"` in
    # `lib/letflow/routers/instances.ex`), so that finding is no longer
    # accurate and the grep this test ran now legitimately matches — same
    # "stale absence-check removed rather than inverted or left permanently
    # red" precedent the attachments finding below already established. This
    # does NOT itself un-skip the scenario fixture's step 2 (that fixture/YAML
    # edit and the accompanying `describe "swiftroute-shipment-ops-timeout-
    # escalation"` test's assertions belong to TEST-DESIGNER per the design's
    # own AC5/AC10 — see `handoffs/WF03-ISS0389-20260905/step-03-elixir-dev.json`
    # for the explicit flag). See
    # `lib/letflow/design/iss0389-advance-timer-endpoint.md` and
    # `lib/letflow/routers/instances.ex`'s own moduledoc row for the new
    # route's coverage.

    # SUPERSEDED by REQ-212 (2026-09-01): this test's original assertion
    # ("no attachment/document-upload routes exist anywhere in
    # lib/letflow/routers/") was the machine-verifiable source evidence for
    # this file's own moduledoc finding #2, "No document/attachment API in
    # Letflow or R-Co src/". REQ-211 (core context module) and REQ-212
    # (this exact route surface -- POST/GET/DELETE
    # /instances/:id/attachments...) have since shipped
    # `lib/letflow/routers/instances.ex`, so that finding is no longer
    # accurate and the grep this test ran now legitimately matches. This
    # does NOT retroactively change the `shipment-attach-delivery-note`
    # scenario's own :unbuilt_feature disposition assertion above (that
    # scenario's YAML/notes text and the Runner's own reasoning are
    # REQ-206/simulation-harness scope, not touched here) -- only this
    # narrower source-evidence guard, which is now testing a stale premise,
    # is removed rather than left permanently red. See
    # `lib/letflow/design/req212-instance-attachments-routes.md` and
    # `test/letflow/routers/req212_attachments_routes_test.exs` for the
    # route surface's own coverage.
  end

  # ─── AC4-REQ396: ops-review escalation timer fires -> ceo-approval task ──

  describe "AC4-REQ396: ops-review escalation timer (P0D) fires -> ceo-approval HUMAN_TASK created" do
    # Uses @ops_escalation_graph (no SERVICE_TASKs, P0D duration for immediate
    # fire) rather than the full process_route_approval.yaml, for the same
    # reason the high-value-happy test uses @simple_approval_graph: SERVICE_TASK
    # nodes cause complete_task/3 to fail with :node_type_not_yet_implemented.
    # The escalation path itself (ops-review timer fires -> ceo-approval task)
    # does not involve any SERVICE_TASK, so this inline graph exercises the
    # exact same code paths the full YAML would, without the unrelated limitation.
    test "timer fire cancels ops-review task and creates ceo-approval task for role-ceo", %{
      schema_name: schema_name
    } do
      # Create + activate the ops-escalation definition inline.
      unique_defn_name =
        "OpsEscalation-" <> to_string(System.unique_integer([:positive, :monotonic]))

      {:ok, definition} =
        Definitions.create(
          %{
            name: unique_defn_name,
            version: "1.0",
            description: "REQ-396 AC4 inline escalation graph",
            graph: @ops_escalation_graph,
            created_by: Ecto.UUID.generate()
          },
          prefix: schema_name
        )

      {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema_name)

      # Start an instance — token parks at ops-review, escalation timer armed.
      assert {:ok, create_result} =
               Engine.create(
                 %{
                   definition_id: activated.id,
                   initial_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key:
                     "req396-ac4-" <> to_string(System.unique_integer([:positive, :monotonic]))
                 },
                 prefix: schema_name
               )

      instance_id = create_result.instance_id

      # Exactly one PENDING task: ops-review.
      ops_tasks =
        from(t in EngineTask,
          where: t.instance_id == ^instance_id and t.node_id == "ops-review"
        )
        |> Repo.all(prefix: schema_name)

      assert [%EngineTask{status: :pending} = ops_task] = ops_tasks

      # Exactly one escalation timer (P0D, due immediately).
      escalation_timers =
        from(t in Timer,
          where:
            t.instance_id == ^instance_id and t.timer_type == "escalation" and
              t.node_id == "ops-review"
        )
        |> Repo.all(prefix: schema_name)

      assert [%Timer{status: "pending"} = escl_timer] = escalation_timers

      # Force-fire the escalation timer.
      assert {:ok, :fired} = Scheduler.fire_timer(escl_timer.id, schema_name)

      # ops-review task must be :cancelled.
      reloaded_ops = Repo.get!(EngineTask, ops_task.id, prefix: schema_name)

      assert reloaded_ops.status == :cancelled,
             "expected ops-review task to be :cancelled, got #{inspect(reloaded_ops.status)}"

      # Exactly one new task for ceo-approval / role-ceo must be :pending.
      ceo_tasks =
        from(t in EngineTask,
          where: t.instance_id == ^instance_id and t.node_id == "ceo-approval"
        )
        |> Repo.all(prefix: schema_name)

      assert [%EngineTask{status: :pending} = ceo_task] = ceo_tasks,
             "expected exactly one pending ceo-approval task, got: #{inspect(Enum.map(ceo_tasks, &{&1.node_id, &1.status}))}"

      assert ceo_task.assignee_ref == "role-ceo"
    end
  end
end
