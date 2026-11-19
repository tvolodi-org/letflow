defmodule Letflow.Definitions.RequiredPermissionValidationTest do
  @moduledoc """
  Decision 0093 F1 / T5: the optional `required_permission` attribute is a
  known, tenant-scope permission name on a HUMAN_TASK only. These are pure
  graph-validator tests; no tenant or database is involved.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node

  defp graph_with_attribute(node_type, attributes) do
    %Graph{
      nodes: [
        %Node{id: "node", node_type: node_type, attributes: attributes}
      ]
    }
  end

  defp codes(graph) do
    graph
    |> Graph.validate_node_attributes()
    |> Map.fetch!(:violations)
    |> Enum.map(& &1.code)
  end

  test "a known tenant-scope permission on a HUMAN_TASK is valid" do
    graph =
      graph_with_attribute(:HUMAN_TASK, %{
        "role" => "approver",
        "required_permission" => "AuditRead"
      })

    assert codes(graph) == []
  end

  test "an absent attribute is valid and leaves existing definitions unchanged" do
    assert codes(graph_with_attribute(:HUMAN_TASK, %{"role" => "approver"})) == []
  end

  test "T5: an unknown permission atom is refused" do
    graph =
      graph_with_attribute(:HUMAN_TASK, %{
        "role" => "approver",
        "required_permission" => "PermissionThatDoesNotExist"
      })

    assert codes(graph) == [:invalid_required_permission]
  end

  test "T5: a platform-scope permission is refused even though it is known" do
    graph =
      graph_with_attribute(:HUMAN_TASK, %{
        "role" => "approver",
        "required_permission" => "TenantsManage"
      })

    assert codes(graph) == [:invalid_required_permission]
  end

  test "T5: every non-string value, including null, is refused" do
    for value <- [nil, "", :AuditRead, 42, ["AuditRead"], %{"name" => "AuditRead"}] do
      graph =
        graph_with_attribute(:HUMAN_TASK, %{
          "role" => "approver",
          "required_permission" => value
        })

      assert codes(graph) == [:invalid_required_permission], "value #{inspect(value)}"
    end
  end

  test "the attribute is refused on a non-HUMAN_TASK node" do
    graph =
      graph_with_attribute(:SERVICE_TASK, %{
        "endpoint" => "https://service.example.test",
        "required_permission" => "AuditRead"
      })

    assert :required_permission_on_non_human_task in codes(graph)
  end
end
