defmodule Letflow.Definitions.GraphValidationScriptTest do
  @moduledoc """
  REQ-569 / GH #3246 AC3 (decision 0067 D9, slice F-1): the HUMAN_TASK `validation_script_key` +
  `validation_script_version` pair in `Graph.validate_node_attributes/1`. Pure, no database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node

  defp graph_of(type, attrs),
    do: %Graph{nodes: [%Node{id: "review", node_type: type, attributes: attrs}], edges: []}

  defp reference_violations(type, attrs) do
    graph_of(type, attrs)
    |> Graph.validate_node_attributes()
    |> Map.fetch!(:violations)
    |> Enum.filter(&(&1.code == :invalid_script_reference))
  end

  defp human(attrs), do: Map.put(attrs, "role", "REVIEWER")

  test "G1 a well-formed pair passes" do
    attrs = human(%{"validation_script_key" => "check_amount", "validation_script_version" => 1})
    assert reference_violations(:HUMAN_TASK, attrs) == []
  end

  test "G1b a HUMAN_TASK without the attributes passes" do
    assert reference_violations(:HUMAN_TASK, human(%{})) == []
  end

  test "G2 a key that fails Validation.key?/1 is refused" do
    for key <- ["Bad", "1abc", "", 42, String.duplicate("a", 65)] do
      attrs = human(%{"validation_script_key" => key, "validation_script_version" => 1})
      assert [%{code: :invalid_script_reference}] = reference_violations(:HUMAN_TASK, attrs)
    end
  end

  test "G3 a version that is not an integer >= 1 is refused" do
    for version <- [0, "1", 1.5, nil, -1] do
      attrs =
        human(%{
          "validation_script_key" => "check_amount",
          "validation_script_version" => version
        })

      assert [_] = reference_violations(:HUMAN_TASK, attrs), inspect(version)
    end

    attrs = human(%{"validation_script_key" => "check_amount"})
    assert [_] = reference_violations(:HUMAN_TASK, attrs)
  end

  test "G4 only one of the two attributes is refused" do
    assert [_] = reference_violations(:HUMAN_TASK, human(%{"validation_script_version" => 1}))
  end

  test "G5 the message names the node id and neither attribute value" do
    attrs =
      human(%{"validation_script_key" => "Secret_Key_Value", "validation_script_version" => "77"})

    assert [%{message: message}] = reference_violations(:HUMAN_TASK, attrs)
    assert message =~ "review"
    refute message =~ "Secret_Key_Value"
    refute message =~ "77"
  end

  test "G6 another node type carrying validation_script_key is not read as a binding" do
    attrs = %{"validation_script_key" => "Bad", "validation_script_version" => 0}
    assert reference_violations(:SERVICE_TASK, attrs) == []
    assert reference_violations(:START, attrs) == []
  end
end
