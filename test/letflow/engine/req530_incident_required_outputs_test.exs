defmodule Letflow.Engine.Req530IncidentRequiredOutputsTest do
  @moduledoc """
  REQ-530 (GH #3086) -- the Driver Incident Report QA fixture (v1.2) declares a form and
  `required_outputs` on its four people-steps: `ops-assessment` and `escalate-ops-assessment-to-ceo`
  (assessment_notes), `finance-estimate` and `escalate-finance-estimate-to-ceo` (estimated_cost_eur).
  `finance_notes` is optional and is in neither list.

  One test per node id, on the real fixture and the real completion path (`Engine.complete_task/3`
  through `Letflow.Req462Adoption`): the required key omitted is refused with `missing_keys`, the task
  stays open and the instance is unchanged; a valid value completes and is stored. The variable schema
  refuses a wrongly typed value (a string or -1 for estimated_cost_eur). The stalled path is covered
  by `swiftroute_escalation_timer_test.exs`.

  Real Postgres, `async: false`; no HTTP, no wall clock.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Req462Adoption, as: A
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer

  @fixture "swiftroute_incident_process_definition.json"
  @extra %{"unrelated_note" => "x"}

  setup do
    A.sandbox_auto!()
  end

  defp incident!,
    do: A.started_instance!(@fixture, %{"incident_id" => "inc-530", "injury_involved" => false})

  # Fires the escalation timer armed on `node_id` (the branches each arm one, so the route needs
  # the timer by node, as the REQ-462 helper does for a single timer).
  defp fire_escalation_at!(schema, instance_id, node_id) do
    timer =
      Timer
      |> where(
        [t],
        t.instance_id == ^instance_id and t.node_id == ^node_id and t.status == "pending"
      )
      |> Repo.one!(prefix: schema)

    assert {:ok, %Timer{}} = Scheduler.resolve_advance_target(instance_id, timer.id, schema)
    assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema)
  end

  defp at_escalated_ops! do
    {schema, id} = incident!()
    fire_escalation_at!(schema, id, "ops-assessment")

    assert A.projection(schema, id).current_nodes
           |> Enum.member?("escalate-ops-assessment-to-ceo")

    {schema, id}
  end

  defp at_escalated_finance! do
    {schema, id} = incident!()
    fire_escalation_at!(schema, id, "finance-estimate")

    assert A.projection(schema, id).current_nodes
           |> Enum.member?("escalate-finance-estimate-to-ceo")

    {schema, id}
  end

  # A wrongly typed value is refused by the variable schema, not by the omitted-key check.
  defp assert_refused_value!(schema, id, node_id, output) do
    task = A.task!(schema, id, node_id)
    before_state = A.projection(schema, id).variables

    assert {:error, _} = A.complete(schema, task, output),
           "#{node_id}: #{inspect(output)} must be refused"

    assert A.task_status(schema, task) == :pending
    assert A.projection(schema, id).variables == before_state
  end

  describe "ops-assessment" do
    test "omitting assessment_notes is refused (missing_keys [assessment_notes]), task open, instance unchanged; a note completes and is stored" do
      {schema, id} = incident!()
      A.assert_omitted_refused!(schema, id, "ops-assessment", "assessment_notes", @extra)
      assert "ops-assessment" in A.projection(schema, id).current_nodes

      A.complete!(schema, A.task!(schema, id, "ops-assessment"), %{
        "assessment_notes" => "Driver reported a cargo shift; no injury."
      })

      assert A.projection(schema, id).variables["assessment_notes"] ==
               "Driver reported a cargo shift; no injury."
    end
  end

  describe "escalate-ops-assessment-to-ceo" do
    test "omitting assessment_notes is refused (missing_keys [assessment_notes]), task open, instance unchanged; a note completes and is stored" do
      {schema, id} = at_escalated_ops!()

      A.assert_omitted_refused!(
        schema,
        id,
        "escalate-ops-assessment-to-ceo",
        "assessment_notes",
        @extra
      )

      assert "escalate-ops-assessment-to-ceo" in A.projection(schema, id).current_nodes
      refute "ops-auto-close" in A.dispatched_nodes(schema, id)

      A.complete!(schema, A.task!(schema, id, "escalate-ops-assessment-to-ceo"), %{
        "assessment_notes" => "CEO assessment after escalation."
      })

      assert A.projection(schema, id).variables["assessment_notes"] ==
               "CEO assessment after escalation."
    end
  end

  describe "finance-estimate" do
    test "omitting estimated_cost_eur is refused (missing_keys [estimated_cost_eur]), task open, instance unchanged; an estimate completes and is stored" do
      {schema, id} = incident!()
      A.assert_omitted_refused!(schema, id, "finance-estimate", "estimated_cost_eur", @extra)
      assert "finance-estimate" in A.projection(schema, id).current_nodes

      A.complete!(schema, A.task!(schema, id, "finance-estimate"), %{
        "estimated_cost_eur" => 850,
        "finance_notes" => "Tow and cargo write-off."
      })

      variables = A.projection(schema, id).variables
      assert variables["estimated_cost_eur"] == 850
      assert variables["finance_notes"] == "Tow and cargo write-off."
    end

    test "estimated_cost_eur as a string, or -1, is refused by the variable schema; task open" do
      {schema, id} = incident!()
      assert_refused_value!(schema, id, "finance-estimate", %{"estimated_cost_eur" => "850"})
      assert_refused_value!(schema, id, "finance-estimate", %{"estimated_cost_eur" => -1})
      assert A.task_status(schema, A.task!(schema, id, "finance-estimate")) == :pending
    end

    test "estimated_cost_eur 0 without finance_notes is a valid estimate and completes" do
      {schema, id} = incident!()

      A.complete!(schema, A.task!(schema, id, "finance-estimate"), %{"estimated_cost_eur" => 0})

      assert A.projection(schema, id).variables["estimated_cost_eur"] == 0
      refute Map.has_key?(A.projection(schema, id).variables, "finance_notes")
    end
  end

  describe "escalate-finance-estimate-to-ceo" do
    test "omitting estimated_cost_eur is refused (missing_keys [estimated_cost_eur]), task open, instance unchanged; an estimate completes and is stored" do
      {schema, id} = at_escalated_finance!()

      A.assert_omitted_refused!(
        schema,
        id,
        "escalate-finance-estimate-to-ceo",
        "estimated_cost_eur",
        @extra
      )

      assert "escalate-finance-estimate-to-ceo" in A.projection(schema, id).current_nodes
      refute "finance-auto-close" in A.dispatched_nodes(schema, id)

      A.complete!(schema, A.task!(schema, id, "escalate-finance-estimate-to-ceo"), %{
        "estimated_cost_eur" => 0
      })

      assert A.projection(schema, id).variables["estimated_cost_eur"] == 0
    end
  end

  test "the instance reaches COMPLETED only after both branches are completed with their required fields" do
    {schema, id} = incident!()

    A.complete!(schema, A.task!(schema, id, "ops-assessment"), %{
      "assessment_notes" => "Assessed."
    })

    assert A.projection(schema, id).status == :active
    refute "case-summary" in A.dispatched_nodes(schema, id)

    A.complete!(schema, A.task!(schema, id, "finance-estimate"), %{"estimated_cost_eur" => 120})

    assert "case-summary" in A.dispatched_nodes(schema, id)
    A.advance_service_task!(schema, id, "case-summary", %{})
    assert A.projection(schema, id).status == :completed
  end
end
