defmodule Letflow.Engine.Req462VortexReleaseRequiredOutputsTest do
  @moduledoc """
  REQ-462 (g, h, i, j) -- the Vortex "Production Order Release" QA fixture (v1.6) declares
  `required_outputs` on `capacity-review` (capacity_decision), `escalate-to-ceo`
  (capacity_decision), `budget-approval` (budget_decision) and `escalate-budget-approval-to-finance-director`
  (budget_decision). These nodes have no `form_schema`, so REQ-461 check 3 is vacuous for them:
  these tests are the evidence.

  One test per node, NAMED BY NODE ID, on the real fixture and the real completion path: the
  decision key omitted (empty output, explicit null, other keys only) -> refused with
  `missing_keys: [key]` (rendered 422 `output_refused` by the tasks router), task still open,
  instance unchanged; then a valid value completes and routes.

  See `test/specs/REQ-462.md`. Real Postgres, `async: false`; no HTTP, no wall clock.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Req462Adoption, as: A

  @fixture "vortex_production_order_release_process_definition.json"
  @extra %{"unrelated_note" => "x"}

  setup do
    A.sandbox_auto!()
  end

  defp order!(value),
    do: A.started_instance!(@fixture, %{"order_id" => "ord-462", "order_value_eur" => value})

  # capacity approved with value > 10000 -> budget-approval pending.
  defp at_budget_approval! do
    {schema, id} = order!(50_000)

    A.complete!(schema, A.task!(schema, id, "capacity-review"), %{
      "capacity_decision" => "approve"
    })

    assert A.projection(schema, id).current_nodes == ["budget-approval"]
    {schema, id}
  end

  defp at_escalated_capacity! do
    {schema, id} = order!(5_000)
    assert A.fire_escalation!(schema, id).node_id == "capacity-review"
    assert A.projection(schema, id).current_nodes == ["escalate-to-ceo"]
    {schema, id}
  end

  defp at_escalated_budget! do
    {schema, id} = at_budget_approval!()
    assert A.fire_escalation!(schema, id).node_id == "budget-approval"

    assert A.projection(schema, id).current_nodes == [
             "escalate-budget-approval-to-finance-director"
           ]

    {schema, id}
  end

  test "capacity-review: omitting capacity_decision is refused (missing_keys [capacity_decision]), task open, instance unchanged; a valid decision routes" do
    {schema, id} = order!(5_000)
    A.assert_omitted_refused!(schema, id, "capacity-review", "capacity_decision", @extra)
    assert A.projection(schema, id).current_nodes == ["capacity-review"]

    A.complete!(schema, A.task!(schema, id, "capacity-review"), %{
      "capacity_decision" => "approve"
    })

    # value <= 10000: budget-gate -> assign-line
    assert A.projection(schema, id).current_nodes == ["assign-line"]

    {schema2, id2} = order!(5_000)
    A.assert_omitted_refused!(schema2, id2, "capacity-review", "capacity_decision", @extra)

    A.complete!(schema2, A.task!(schema2, id2, "capacity-review"), %{
      "capacity_decision" => "reject"
    })

    assert A.projection(schema2, id2).current_nodes == ["notify-planner-rejected"]
  end

  test "escalate-to-ceo: the D-ESC task inherits nothing; omitting capacity_decision is refused, task open, instance unchanged; a valid decision routes" do
    {schema, id} = at_escalated_capacity!()
    A.assert_omitted_refused!(schema, id, "escalate-to-ceo", "capacity_decision", @extra)
    assert A.projection(schema, id).current_nodes == ["escalate-to-ceo"]
    refute "auto-reject-order" in A.dispatched_nodes(schema, id)

    A.complete!(schema, A.task!(schema, id, "escalate-to-ceo"), %{
      "capacity_decision" => "approve"
    })

    assert A.projection(schema, id).current_nodes == ["assign-line"]

    {schema2, id2} = at_escalated_capacity!()
    A.assert_omitted_refused!(schema2, id2, "escalate-to-ceo", "capacity_decision", @extra)

    A.complete!(schema2, A.task!(schema2, id2, "escalate-to-ceo"), %{
      "capacity_decision" => "reject"
    })

    assert A.projection(schema2, id2).current_nodes == ["auto-reject-order"]
  end

  test "budget-approval: omitting budget_decision is refused (missing_keys [budget_decision]), task open, instance unchanged; a valid decision routes" do
    {schema, id} = at_budget_approval!()
    A.assert_omitted_refused!(schema, id, "budget-approval", "budget_decision", @extra)
    assert A.projection(schema, id).current_nodes == ["budget-approval"]

    A.complete!(schema, A.task!(schema, id, "budget-approval"), %{"budget_decision" => "approve"})
    assert A.projection(schema, id).current_nodes == ["assign-line"]

    {schema2, id2} = at_budget_approval!()
    A.assert_omitted_refused!(schema2, id2, "budget-approval", "budget_decision", @extra)

    A.complete!(schema2, A.task!(schema2, id2, "budget-approval"), %{
      "budget_decision" => "reject"
    })

    assert A.projection(schema2, id2).current_nodes == ["auto-reject-order"]
  end

  test "escalate-budget-approval-to-finance-director: the D-ESC task inherits nothing; omitting budget_decision is refused, task open, instance unchanged; a valid decision routes" do
    {schema, id} = at_escalated_budget!()

    A.assert_omitted_refused!(
      schema,
      id,
      "escalate-budget-approval-to-finance-director",
      "budget_decision",
      @extra
    )

    assert A.projection(schema, id).current_nodes == [
             "escalate-budget-approval-to-finance-director"
           ]

    refute "assign-line" in A.dispatched_nodes(schema, id)

    A.complete!(schema, A.task!(schema, id, "escalate-budget-approval-to-finance-director"), %{
      "budget_decision" => "approve"
    })

    assert A.projection(schema, id).current_nodes == ["assign-line"]

    {schema2, id2} = at_escalated_budget!()

    A.assert_omitted_refused!(
      schema2,
      id2,
      "escalate-budget-approval-to-finance-director",
      "budget_decision",
      @extra
    )

    A.complete!(schema2, A.task!(schema2, id2, "escalate-budget-approval-to-finance-director"), %{
      "budget_decision" => "reject"
    })

    assert A.projection(schema2, id2).current_nodes == ["auto-reject-order"]
  end
end
