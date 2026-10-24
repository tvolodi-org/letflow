defmodule Letflow.Scripts.VortexHumanTaskFormsTest do
  @moduledoc """
  GH #3140 -- every HUMAN_TASK of the three Vortex QA fixtures carries a `form_schema` whose
  properties cover the node's `required_outputs`, so the task inbox renders the decision inputs
  and Complete Task is accepted. Also pins the version bumps (the seed script is version-aware: a
  newer fixture version is created and activated, the prior ACTIVE one is deprecated) and runs
  each fixture through `Definitions.create` (graph rules).

  Real Postgres, `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.TenantFixture

  @qa Path.expand("../../fixtures/qa", __DIR__)

  # file => expected version
  @fixtures %{
    "vortex_production_order_release_process_definition.json" => "1.10",
    "vortex_supplier_quality_deviation_process_definition.json" => "1.8",
    "vortex_8d_corrective_action_definition.json" => "1.3"
  }

  defp doc(file), do: @qa |> Path.join(file) |> File.read!() |> Jason.decode!()

  defp human_tasks(doc),
    do: Enum.filter(doc["graph"]["nodes"], &(&1["node_type"] == "HUMAN_TASK"))

  test "every HUMAN_TASK has a form_schema covering its required_outputs" do
    for {file, _} <- @fixtures, node <- human_tasks(doc(file)) do
      attrs = node["attributes"]
      form = attrs["form_schema"]
      assert is_map(form), "#{file}: #{node["id"]} has no form_schema"
      assert form["type"] == "object"
      props = Map.keys(form["properties"])

      for key <- attrs["required_outputs"] || [] do
        assert key in props, "#{file}: #{node["id"]} form lacks #{key}"
        assert key in form["required"]
      end

      assert props != [], "#{file}: #{node["id"]} form has no fields"
    end
  end

  test "supplier deviation form also collects false_positive, which the routing reads" do
    for node <- human_tasks(doc("vortex_supplier_quality_deviation_process_definition.json")) do
      assert %{"type" => "boolean"} =
               Map.take(node["attributes"]["form_schema"]["properties"]["false_positive"], [
                 "type"
               ])
    end
  end

  test "each fixture is at its bumped version and Definitions.create accepts it" do
    %{schema_name: schema} =
      TenantFixture.provisioned_tenant!(slug_prefix: "vxfrm", display_name: "Vortex forms")

    for {file, version} <- @fixtures do
      d = doc(file)
      assert d["version"] == version

      assert {:ok, _} =
               Definitions.create(
                 %{
                   name: "vxfrm-" <> to_string(System.unique_integer([:positive])),
                   version: d["version"],
                   graph: d["graph"],
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: schema
               )
    end
  end
end
