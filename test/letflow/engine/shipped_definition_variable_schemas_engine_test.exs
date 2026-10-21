defmodule Letflow.Engine.ShippedDefinitionVariableSchemasEngineTest do
  @moduledoc """
  ISS-1027 / Q-1009 (GH #2307) -- engine-level proof that the `variable_schemas` the shipped QA
  fixtures now carry are ENFORCED at task completion, through the REAL fixture, the real
  registration path (`Definitions.create_with_variable_schemas/3`, the function POST /definitions
  calls with the fixture's `variable_schemas` array), the real `Definitions.activate/2` (which, once
  a definition declares schemas, also runs REQ-372's field-existence/type check against every
  gateway condition) and the real `Engine.complete_task/3`.

  A completion with an out-of-enum value is REFUSED (REQ-459/REQ-460 amended the original REQ-061 behaviour):
  `{:error, {:output_refused, %{missing_keys: [], rejected_keys: [key]}}}`, a retryable 422 at the router. The
  instance stays `:active` (no ERROR, no EXECUTION_ERROR event), the value is NOT merged, the task stays pending
  and no TASK_COMPLETED is written -- instead of the process silently taking a default edge. A valid
  value is merged and routes to the intended node.

  Real Postgres, `async: false`. No HTTP: the dispatcher is not run; service-task outcomes are
  re-entered by hand exactly as `regulatory_review_timer_path_test.exs` does.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Event
  alias Letflow.TenantFixture

  @qa Path.expand("../../fixtures/qa", __DIR__)
  @loan "meridian_loan_origination_process_definition.json"
  @regulatory "meridian_regulatory_compliance_review_process_definition.json"
  @swiftroute "swiftroute_process_definition.json"
  @vortex_order "vortex_production_order_release_process_definition.json"

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # --- helpers (no optional-argument defaults: anti-patterns.md ISS-0069) -------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp fixture(file), do: @qa |> Path.join(file) |> File.read!() |> Jason.decode!()

  # Registers the fixture exactly as POST /definitions would (graph + variable_schemas array from
  # the fixture file itself), activates it, and starts one instance.
  defp start!(schema, file, initial_variables) do
    doc = fixture(file)

    entries =
      Enum.map(doc["variable_schemas"], fn e ->
        %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
      end)

    assert entries != [], "#{file} ships no variable_schemas"

    assert {:ok, definition} =
             Definitions.create_with_variable_schemas(
               %{
                 name: unique("iss1027-def"),
                 version: doc["version"],
                 graph: doc["graph"],
                 created_by: Ecto.UUID.generate()
               },
               entries,
               prefix: schema
             )

    assert {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: active.id,
                 initial_variables: initial_variables,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("iss1027-start")
               },
               prefix: schema
             )

    result.instance_id
  end

  defp tenant_schema!, do: TenantFixture.provisioned_tenant!(slug_prefix: "iss1027").schema_name

  defp task!(schema, instance_id, node_id) do
    assert [task] =
             EngineTask
             |> where([t], t.instance_id == ^instance_id and t.node_id == ^node_id)
             |> Repo.all(prefix: schema)

    task
  end

  defp complete(schema, task, output) do
    Engine.complete_task(
      task.id,
      %{
        output_variables: output,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique("iss1027-complete")
      },
      prefix: schema
    )
  end

  defp complete!(schema, task, output) do
    assert {:ok, _} = complete(schema, task, output)
  end

  defp projection(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema)

  defp event_count(schema, instance_id, type) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == ^type)
    |> Repo.aggregate(:count, prefix: schema)
  end

  # Asserts the full "rejected, not silently routed" contract for one completion.
  defp assert_rejected!(schema, instance_id, task, output, key) do
    before_vars = projection(schema, instance_id).variables
    completed_before = event_count(schema, instance_id, "TASK_COMPLETED")

    # REQ-459/REQ-460 amendment: a HUMAN_TASK completion with a schema-rejected value is now
    # REFUSED (retryable 422 at the router) before any state change; the instance is NOT put into
    # ERROR and no EXECUTION_ERROR event is written. The rejected key is named only when it is in
    # the task's own form (or required_outputs): a fixture task WITHOUT a form_schema (e.g. Vortex
    # capacity-review) is refused with both lists empty (design req459 section 3.2, INV-2).
    assert {:error, {:output_refused, %{missing_keys: [], rejected_keys: rejected}}} =
             complete(schema, task, output)

    assert rejected in [[key], []]

    proj = projection(schema, instance_id)
    assert proj.status == :active
    assert proj.variables == before_vars, "rejected value must not be merged"
    assert Repo.get!(EngineTask, task.id, prefix: schema).status == :pending
    assert event_count(schema, instance_id, "EXECUTION_ERROR") == 0
    assert event_count(schema, instance_id, "TASK_COMPLETED") == completed_before
  end

  # The kyc-aml-check SERVICE_TASK echoes kyc_status; re-enter its outcome by hand (no HTTP).
  defp kyc_screening_result!(schema, instance_id, kyc_status) do
    assert [row] =
             ServiceTaskDispatch
             |> where([d], d.instance_id == ^instance_id and d.node_id == "kyc-aml-check")
             |> Repo.all(prefix: schema)

    row = row |> Ecto.Changeset.change(%{status: :advanced}) |> Repo.update!(prefix: schema)

    assert {:ok, :advanced} =
             Engine.advance_after_service_task_outcome(
               row.id,
               {:advance, %{"kyc_status" => kyc_status}},
               Repo,
               schema
             )
  end

  @loan_vars %{"application_id" => "app-1027", "requested_amount_eur" => 100_000}

  # --- Meridian loan -----------------------------------------------------------------------

  describe "Meridian Loan Origination" do
    test "the fixture activates with its schemas (REQ-372 semantic check is clean) and starts" do
      schema = tenant_schema!()
      instance_id = start!(schema, @loan, @loan_vars)
      assert projection(schema, instance_id).status == :active
    end

    test "risk-assessment: an out-of-enum risk_rating is rejected, a valid one merges" do
      schema = tenant_schema!()

      bad = start!(schema, @loan, @loan_vars)

      assert_rejected!(
        schema,
        bad,
        task!(schema, bad, "risk-assessment"),
        %{"risk_rating" => "maybe"},
        "risk_rating"
      )

      good = start!(schema, @loan, @loan_vars)
      complete!(schema, task!(schema, good, "risk-assessment"), %{"risk_rating" => "low"})
      proj = projection(schema, good)
      assert proj.status == :active
      assert proj.variables["risk_rating"] == "low"
    end

    test "kyc-manual-review: kyc_outcome 'maybe' is rejected; 'cleared' merges and the review completes" do
      schema = tenant_schema!()

      bad = start!(schema, @loan, @loan_vars)
      kyc_screening_result!(schema, bad, "hit")
      review = task!(schema, bad, "kyc-manual-review")
      assert_rejected!(schema, bad, review, %{"kyc_outcome" => "maybe"}, "kyc_outcome")

      good = start!(schema, @loan, @loan_vars)
      kyc_screening_result!(schema, good, "hit")
      review = task!(schema, good, "kyc-manual-review")
      complete!(schema, review, %{"kyc_outcome" => "cleared"})
      assert projection(schema, good).variables["kyc_outcome"] == "cleared"
      assert Repo.get!(EngineTask, review.id, prefix: schema).status == :completed
    end

    test "kyc-manual-review: the values the fixture's own timeout stub echoes ('unresolved') are valid too" do
      schema = tenant_schema!()
      instance_id = start!(schema, @loan, @loan_vars)
      kyc_screening_result!(schema, instance_id, "inconclusive")

      complete!(schema, task!(schema, instance_id, "kyc-manual-review"), %{
        "kyc_outcome" => "unresolved"
      })

      assert projection(schema, instance_id).variables["kyc_outcome"] == "unresolved"
    end

    test "l1-approval: 'maybe' is rejected instead of falling to a default edge; 'approve' routes to l2-approval" do
      schema = tenant_schema!()

      drive = fn ->
        id = start!(schema, @loan, @loan_vars)
        kyc_screening_result!(schema, id, "clear")
        complete!(schema, task!(schema, id, "credit-memo-review"), %{"credit_decision" => "pass"})
        complete!(schema, task!(schema, id, "risk-assessment"), %{"risk_rating" => "low"})
        id
      end

      bad = drive.()
      assert "l1-approval" in projection(schema, bad).current_nodes

      assert_rejected!(
        schema,
        bad,
        task!(schema, bad, "l1-approval"),
        %{"l1_decision" => "maybe"},
        "l1_decision"
      )

      assert [] ==
               Repo.all(
                 from(t in EngineTask,
                   where: t.instance_id == ^bad and t.node_id == "l2-approval"
                 ),
                 prefix: schema
               )

      good = drive.()
      complete!(schema, task!(schema, good, "l1-approval"), %{"l1_decision" => "approve"})
      assert "l2-approval" in projection(schema, good).current_nodes
    end
  end

  # --- Meridian regulatory -----------------------------------------------------------------

  describe "Meridian Regulatory Compliance Review" do
    @review_vars %{"review_id" => "rev-1027"}

    test "risk-evaluation: an out-of-enum highest_severity is rejected; 'low' routes to findings-sign-off" do
      schema = tenant_schema!()

      bad = start!(schema, @regulatory, @review_vars)
      complete!(schema, task!(schema, bad, "evidence-collection"), %{})

      assert_rejected!(
        schema,
        bad,
        task!(schema, bad, "risk-evaluation"),
        %{"highest_severity" => "catastrophic"},
        "highest_severity"
      )

      good = start!(schema, @regulatory, @review_vars)
      complete!(schema, task!(schema, good, "evidence-collection"), %{})
      complete!(schema, task!(schema, good, "risk-evaluation"), %{"highest_severity" => "low"})
      assert projection(schema, good).current_nodes == ["findings-sign-off"]
    end

    test "findings-sign-off: cro_decision 'maybe' is rejected (no silent default); 'sign_off' proceeds" do
      schema = tenant_schema!()

      drive = fn ->
        id = start!(schema, @regulatory, @review_vars)
        complete!(schema, task!(schema, id, "evidence-collection"), %{})
        complete!(schema, task!(schema, id, "risk-evaluation"), %{"highest_severity" => "low"})
        id
      end

      bad = drive.()

      assert_rejected!(
        schema,
        bad,
        task!(schema, bad, "findings-sign-off"),
        %{"cro_decision" => "maybe"},
        "cro_decision"
      )

      good = drive.()
      complete!(schema, task!(schema, good, "findings-sign-off"), %{"cro_decision" => "sign_off"})
      refute "findings-sign-off" in projection(schema, good).current_nodes
    end

    test "remediation-subprocess (human): remediation_status 'maybe' is rejected; 'resolved' reaches findings-sign-off" do
      schema = tenant_schema!()

      drive = fn ->
        id = start!(schema, @regulatory, @review_vars)
        complete!(schema, task!(schema, id, "evidence-collection"), %{})

        complete!(schema, task!(schema, id, "risk-evaluation"), %{
          "highest_severity" => "critical"
        })

        id
      end

      bad = drive.()

      assert_rejected!(
        schema,
        bad,
        task!(schema, bad, "remediation-subprocess"),
        %{"remediation_status" => "maybe"},
        "remediation_status"
      )

      good = drive.()

      complete!(schema, task!(schema, good, "remediation-subprocess"), %{
        "remediation_status" => "resolved"
      })

      assert projection(schema, good).current_nodes == ["findings-sign-off"]
    end
  end

  # --- SwiftRoute / Vortex (one case each: same contract as the Meridian cases) -------------

  describe "SwiftRoute Shipment Approval" do
    test "ops-review: ops_decision 'maybe' is rejected; 'approve' and 'reject' are accepted and routed" do
      schema = tenant_schema!()
      vars = %{"shipment_id" => "shp-1027", "declared_value" => 100}

      bad = start!(schema, @swiftroute, vars)

      assert_rejected!(
        schema,
        bad,
        task!(schema, bad, "ops-review"),
        %{"ops_decision" => "maybe"},
        "ops_decision"
      )

      approved = start!(schema, @swiftroute, vars)
      complete!(schema, task!(schema, approved, "ops-review"), %{"ops_decision" => "approve"})
      # value 100 <= 500: straight to release-shipment, no CEO co-sign
      assert projection(schema, approved).current_nodes == ["release-shipment"]

      rejected = start!(schema, @swiftroute, vars)
      complete!(schema, task!(schema, rejected, "ops-review"), %{"ops_decision" => "reject"})
      assert projection(schema, rejected).current_nodes == ["notify-requester"]
    end
  end

  describe "Vortex Production Order Release" do
    test "capacity-review: capacity_decision 'maybe' is rejected; 'approve' and 'reject' are accepted and routed" do
      schema = tenant_schema!()
      vars = %{"order_id" => "ord-1027", "order_value_eur" => 5_000}

      bad = start!(schema, @vortex_order, vars)

      assert_rejected!(
        schema,
        bad,
        task!(schema, bad, "capacity-review"),
        %{"capacity_decision" => "maybe"},
        "capacity_decision"
      )

      approved = start!(schema, @vortex_order, vars)

      complete!(schema, task!(schema, approved, "capacity-review"), %{
        "capacity_decision" => "approve"
      })

      # 5000 <= 10000: no budget approval, straight to assign-line
      assert projection(schema, approved).current_nodes == ["assign-line"]

      rejected = start!(schema, @vortex_order, vars)

      complete!(schema, task!(schema, rejected, "capacity-review"), %{
        "capacity_decision" => "reject"
      })

      assert projection(schema, rejected).current_nodes == ["notify-planner-rejected"]
    end
  end
end
