defmodule Letflow.Scripts.SwiftrouteDecisionFormsFixtureTest do
  @moduledoc """
  ISS-1008 / Q-990 (GH #2277, audit finding PA-SWIFTROUTE-002) -- the SwiftRoute "Shipment
  Approval" QA fixture (v1.5) gives ops-review and ceo-approval a `form_schema` whose required,
  enumerated decision field is EXACTLY the variable the outgoing edges test.

  What this file pins, honestly (read, not assumed):

    * (a) definition level: the forms, the field names the edges/gateway read, the simulation copy
      kept in step, graph/semantic validation clean;
    * (b) engine level, through the real registration path (`create_with_variable_schemas/3`),
      `activate/2`, `Engine.create/2` and `Engine.complete_task/3`:
        - an out-of-enum value is REFUSED (retryable 422 `output_refused`, `rejected_keys` naming the
          key) and an explicit null decision is REFUSED the same way with `missing_keys` naming it
          (REQ-459/REQ-460): no state change, instance stays `:active`, no EXECUTION_ERROR;
        - approve / reject route as before;
        - REQ-462 (ISS-1008 AC3, now met): ops-review and ceo-approval declare `required_outputs`
          for the key their edges read, so a completion that OMITS the decision key is refused
          (`missing_keys: [key]`), the task stays open, the instance is unchanged, and a retry with a
          valid decision completes and routes. The two tests named by node id below replace the two
          former tests that pinned the old accepted-and-fail-closed behaviour.
        - the start form: the node model has no start form (`form_schema` is read only from
          HUMAN_TASK nodes), so `declared_value` is a required-by-convention initial variable,
          typed by `variable_schemas` (number); the limitation is stated in the description.

  Real Postgres, `async: false`. No HTTP.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Definitions.{Graph, SemanticValidation}
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Req462Adoption
  alias Letflow.TenantFixture

  @qa Path.expand("../../fixtures/qa/swiftroute_process_definition.json", __DIR__)
  @sim Path.expand("../../fixtures/simulation/swiftroute/process_route_approval.yaml", __DIR__)

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  defp qa, do: @qa |> File.read!() |> Jason.decode!()
  defp sim, do: YamlElixir.read_from_file!(@sim)

  defp node!(doc, id), do: Enum.find(doc["graph"]["nodes"], &(&1["id"] == id))

  defp form!(doc, id), do: get_in(node!(doc, id), ["attributes", "form_schema"])

  # Variables an outgoing edge condition of `source` reads.
  defp edge_vars(doc, source) do
    doc["graph"]["edges"]
    |> Enum.filter(&(&1["source"] == source and is_binary(&1["condition"])))
    |> Enum.flat_map(&Regex.scan(~r/variables\.([A-Za-z_][A-Za-z0-9_]*)/, &1["condition"]))
    |> Enum.map(fn [_, v] -> v end)
    |> Enum.uniq()
  end

  describe "definition level" do
    for {label, loader} <- [qa: :qa, sim: :sim],
        {node, var} <- [{"ops-review", "ops_decision"}, {"ceo-approval", "ceo_decision"}] do
      test "#{label}: #{node} has a form with required #{var} enum [approve, reject] that the edges read" do
        doc = apply(__MODULE__, :load_doc, [unquote(loader)])
        form = form!(doc, unquote(node))

        assert is_map(form), "#{unquote(node)} has no form_schema"
        assert form["type"] == "object"
        assert unquote(var) in form["required"]
        assert form["properties"][unquote(var)]["type"] == "string"
        assert form["properties"][unquote(var)]["enum"] == ["approve", "reject"]
        assert Map.keys(form["properties"]) == [unquote(var)]
        assert edge_vars(doc, unquote(node)) == [unquote(var)]
      end
    end

    test "the value gateway reads declared_value, which is declared as a number and described as required" do
      doc = qa()
      assert edge_vars(doc, "ceo-approval-gate") == ["declared_value"]

      declared = Map.new(doc["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})
      assert declared["declared_value"]["type"] == "number"

      assert doc["description"] =~ "declared_value"
      assert doc["description"] =~ "required"
    end

    test "version 1.7, the D-ESC line is kept verbatim and the v1.5 and v1.6 sentences are present" do
      doc = qa()
      assert doc["version"] == "1.7"
      assert doc["description"] =~ "Escalation follows D-ESC: timer -> higher role -> fail closed"
      assert doc["description"] =~ "v1.5"
    end

    test "the process validators report OK (graph, node attributes incl. form_schema CHK-20, conditions, semantics)" do
      for doc <- [qa(), sim()] do
        assert {:ok, graph} = Graph.from_map(doc["graph"])
        assert %{valid: true, violations: []} = Graph.validate_graph(graph)
        assert %{valid: true, violations: []} = Graph.validate_node_attributes(graph)
        assert %{valid: true, violations: []} = Graph.validate_edge_conditions(graph)
      end

      doc = qa()
      assert {:ok, graph} = Graph.from_map(doc["graph"])
      declared = Map.new(doc["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})
      assert %{valid: true, violations: []} = SemanticValidation.validate(graph, declared)
    end

    test "the simulation copy keeps its own 1.0 version" do
      assert sim()["version"] == "1.0"
    end
  end

  # --- engine level ---------------------------------------------------------------------------

  describe "engine level (real fixture, real completion path)" do
    test "ops-review: null and out-of-enum decisions are rejected; approve / reject route as before" do
      schema = tenant_schema!()
      vars = %{"shipment_id" => "shp-1008", "declared_value" => 100}

      for bad <- [nil, "maybe", "APPROVE", ""] do
        id = start!(schema, vars)

        assert_rejected!(
          schema,
          id,
          task!(schema, id, "ops-review"),
          %{"ops_decision" => bad},
          "ops_decision"
        )
      end

      approved = start!(schema, vars)
      complete!(schema, task!(schema, approved, "ops-review"), %{"ops_decision" => "approve"})
      assert projection(schema, approved).current_nodes == ["release-shipment"]

      rejected = start!(schema, vars)
      complete!(schema, task!(schema, rejected, "ops-review"), %{"ops_decision" => "reject"})
      assert projection(schema, rejected).current_nodes == ["notify-requester"]
    end

    test "ceo-approval: null and out-of-enum decisions are rejected; approve releases, reject auto-rejects" do
      schema = tenant_schema!()
      vars = %{"shipment_id" => "shp-1008", "declared_value" => 900}

      for bad <- [nil, "maybe", "Approve"] do
        id = at_ceo_approval!(schema, vars)

        assert_rejected!(
          schema,
          id,
          task!(schema, id, "ceo-approval"),
          %{"ceo_decision" => bad},
          "ceo_decision"
        )
      end

      approved = at_ceo_approval!(schema, vars)
      complete!(schema, task!(schema, approved, "ceo-approval"), %{"ceo_decision" => "approve"})
      assert projection(schema, approved).current_nodes == ["release-shipment"]

      rejected = at_ceo_approval!(schema, vars)
      complete!(schema, task!(schema, rejected, "ceo-approval"), %{"ceo_decision" => "reject"})
      assert projection(schema, rejected).current_nodes == ["auto-reject"]
    end

    # REQ-462 (a). Replaces the former pin of the old limitation (ops-review completed with the
    # decision key omitted was accepted and escalated to ceo-approval).
    test "ops-review: a completion omitting ops_decision is refused (422 output_refused, missing_keys [ops_decision]); a retry with a valid decision completes and routes" do
      schema = tenant_schema!()
      id = start!(schema, %{"shipment_id" => "shp-1008", "declared_value" => 100})

      Req462Adoption.assert_omitted_refused!(
        schema,
        id,
        "ops-review",
        "ops_decision",
        %{"unrelated_note" => "x"}
      )

      proj = projection(schema, id)
      assert proj.current_nodes == ["ops-review"]
      refute Map.has_key?(proj.variables, "ops_decision")

      # the old fail-closed route (ceo-approval) is NOT taken; the retry decides the route
      complete!(schema, task!(schema, id, "ops-review"), %{"ops_decision" => "approve"})
      assert projection(schema, id).current_nodes == ["release-shipment"]
      assert event_count(schema, id, "EXECUTION_ERROR") == 0

      # same omission on a high-value shipment: refused, then approve -> the CEO co-sign task
      high = start!(schema, %{"shipment_id" => "shp-1008", "declared_value" => 900})

      Req462Adoption.assert_omitted_refused!(
        schema,
        high,
        "ops-review",
        "ops_decision",
        %{"unrelated_note" => "x"}
      )

      complete!(schema, task!(schema, high, "ops-review"), %{"ops_decision" => "approve"})
      assert projection(schema, high).current_nodes == ["ceo-approval"]
    end

    # REQ-462 (b). Replaces the former pin of the old limitation (ceo-approval completed with the
    # decision key omitted was accepted and failed closed to auto-reject).
    test "ceo-approval: a completion omitting ceo_decision is refused (422 output_refused, missing_keys [ceo_decision]); a retry with a valid decision completes and routes" do
      schema = tenant_schema!()
      vars = %{"shipment_id" => "shp-1008", "declared_value" => 900}
      id = at_ceo_approval!(schema, vars)

      Req462Adoption.assert_omitted_refused!(
        schema,
        id,
        "ceo-approval",
        "ceo_decision",
        %{"unrelated_note" => "x"}
      )

      proj = projection(schema, id)
      assert proj.current_nodes == ["ceo-approval"]
      refute Map.has_key?(proj.variables, "ceo_decision")

      complete!(schema, task!(schema, id, "ceo-approval"), %{"ceo_decision" => "approve"})
      assert projection(schema, id).current_nodes == ["release-shipment"]

      rejected = at_ceo_approval!(schema, vars)

      Req462Adoption.assert_omitted_refused!(
        schema,
        rejected,
        "ceo-approval",
        "ceo_decision",
        %{"unrelated_note" => "x"}
      )

      complete!(schema, task!(schema, rejected, "ceo-approval"), %{"ceo_decision" => "reject"})
      assert projection(schema, rejected).current_nodes == ["auto-reject"]
      assert event_count(schema, rejected, "EXECUTION_ERROR") == 0
    end
  end

  # --- helpers (no optional-argument defaults: anti-patterns.md ISS-0069) ----------------------

  @doc false
  def load_doc(:qa), do: qa()
  def load_doc(:sim), do: sim()

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp tenant_schema!, do: TenantFixture.provisioned_tenant!(slug_prefix: "iss1008").schema_name

  defp start!(schema, initial_variables) do
    doc = qa()

    entries =
      Enum.map(doc["variable_schemas"], fn e ->
        %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
      end)

    assert {:ok, definition} =
             Definitions.create_with_variable_schemas(
               %{
                 name: unique("iss1008-def"),
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
                 idempotency_key: unique("iss1008-start")
               },
               prefix: schema
             )

    result.instance_id
  end

  # ops approves a high-value shipment -> the gateway sends it to the CEO co-sign task.
  defp at_ceo_approval!(schema, vars) do
    id = start!(schema, vars)
    complete!(schema, task!(schema, id, "ops-review"), %{"ops_decision" => "approve"})
    assert projection(schema, id).current_nodes == ["ceo-approval"]
    id
  end

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
        idempotency_key: unique("iss1008-complete")
      },
      prefix: schema
    )
  end

  defp complete!(schema, task, output), do: assert({:ok, _} = complete(schema, task, output))

  defp projection(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema)

  defp event_count(schema, instance_id, type) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == ^type)
    |> Repo.aggregate(:count, prefix: schema)
  end

  defp assert_rejected!(schema, instance_id, task, output, key) do
    before_vars = projection(schema, instance_id).variables

    # REQ-459/REQ-460 amendment: a HUMAN_TASK completion with a schema-rejected value is now
    # REFUSED (retryable 422 at the router) before any state change; the instance is NOT put into
    # ERROR and no EXECUTION_ERROR event is written. The key is named (in-form key).
    # A null decision is MISSING (BA ruling 2026-10-07: absent or null); any other bad value
    # (out-of-enum, wrong case, empty string) is REJECTED by the key's variable_schema enum.
    {expected_missing, expected_rejected} =
      if is_nil(output[key]), do: {[key], []}, else: {[], [key]}

    assert {:error,
            {:output_refused,
             %{missing_keys: ^expected_missing, rejected_keys: ^expected_rejected}}} =
             complete(schema, task, output)

    proj = projection(schema, instance_id)
    assert proj.status == :active
    assert proj.variables == before_vars, "rejected value must not be merged"
    assert Repo.get!(EngineTask, task.id, prefix: schema).status == :pending
  end
end
