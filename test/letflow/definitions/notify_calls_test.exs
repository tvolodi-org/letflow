defmodule Letflow.Definitions.NotifyCallsTest do
  @moduledoc """
  T-2592 (pilot gap G4): the rules of the NOTIFICATION STEP's declaration -- the
  one parse the activation fence and the dispatcher share.

  Test ids D1..D14.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.NotifyCalls

  defp declaration(overrides \\ %{}) do
    Map.merge(
      %{
        "template_key" => "tenant_registered",
        "recipient" => %{"var" => "admin_email"},
        "values" => %{
          "tenant_name" => %{"var" => "tenant_name"},
          "tenant_slug" => %{"const" => "acme"}
        }
      },
      overrides
    )
  end

  defp notify_node(declaration, node_type \\ :SERVICE_TASK, extra \\ %{}) do
    %Graph.Node{
      id: "notify",
      node_type: node_type,
      attributes: Map.merge(%{"notify" => declaration}, extra)
    }
  end

  defp codes(declaration, node_type, extra, extra_nodes) do
    the_node = notify_node(declaration, node_type, extra)

    the_node
    |> NotifyCalls.violations([the_node | extra_nodes])
    |> Enum.map(& &1.code)
  end

  describe "the declaration (the one parse)" do
    test "D1 a well-formed declaration parses" do
      assert {:ok, declaration} = NotifyCalls.parse(declaration())

      assert declaration.template_key == "tenant_registered"
      assert declaration.recipient_var == "admin_email"

      assert declaration.values == %{
               "tenant_name" => {:var, "tenant_name"},
               "tenant_slug" => {:const, "acme"}
             }
    end

    test "D2 an unknown template key is refused" do
      assert {:error, :notify_template_unknown} =
               NotifyCalls.parse(declaration(%{"template_key" => "no_such_template"}))
    end

    test "D3 a CONSTANT recipient is refused: the address never sits in the definition" do
      assert {:error, :notify_recipient_invalid} =
               NotifyCalls.parse(declaration(%{"recipient" => %{"const" => "admin@example.com"}}))
    end

    test "D4 an unknown key is refused" do
      assert {:error, :notify_unknown_key} =
               NotifyCalls.parse(declaration(%{"channel" => "email"}))
    end

    test "D5 a missing key is refused" do
      raw = declaration()
      raw = Map.delete(raw, "values")

      assert {:error, :notify_malformed} = NotifyCalls.parse(raw)
    end

    test "D6 a value that the template does not allow is refused" do
      assert {:error, :notify_value_unknown} =
               NotifyCalls.parse(
                 declaration(%{"values" => %{"realm_password" => %{"var" => "realm_password"}}})
               )
    end

    test "D7 a malformed value source is refused" do
      assert {:error, :notify_value_source_invalid} =
               NotifyCalls.parse(declaration(%{"values" => %{"tenant_name" => %{"nope" => 1}}}))
    end

    test "D8 a reserved engine key is refused" do
      assert {:error, :notify_value_source_invalid} =
               NotifyCalls.parse(
                 declaration(%{"values" => %{"tenant_name" => %{"var" => "_sys"}}})
               )
    end

    test "D9 a dotted variable name is refused" do
      assert {:error, :notify_recipient_invalid} =
               NotifyCalls.parse(declaration(%{"recipient" => %{"var" => "admin.email"}}))
    end
  end

  describe "the node rules" do
    test "D10 a node that carries another route beside the notification is refused" do
      assert [:notify_conflicting_route] =
               codes(declaration(), :SERVICE_TASK, %{"endpoint" => "https://example.com"}, [])
    end

    test "D11 a node that is not a SERVICE_TASK is refused" do
      assert [:notify_node_type_not_supported] = codes(declaration(), :HUMAN_TASK, %{}, [])
    end

    test "D12 a variable a person may write is refused (the T-2430 rule)" do
      human_task = %Graph.Node{
        id: "human",
        node_type: :HUMAN_TASK,
        attributes: %{"role" => "TENANT_ADMIN", "completer_inputs" => ["admin_email"]}
      }

      assert [:notify_input_source_refused] =
               codes(declaration(), :SERVICE_TASK, %{}, [human_task])
    end

    test "D13 the variables the step reads are listed" do
      assert NotifyCalls.read_keys([notify_node(declaration())]) == ["admin_email", "tenant_name"]
    end
  end

  describe "the graph validation" do
    test "D14 a SERVICE_TASK with a notification needs no endpoint" do
      graph = graph_with(declaration())

      assert Graph.validate_node_attributes(graph).violations == []
    end

    test "D15 a SERVICE_TASK with an invalid notification is refused" do
      graph = graph_with(declaration(%{"template_key" => "no_such_template"}))

      assert [%{code: :notify_template_unknown}] =
               Graph.validate_node_attributes(graph).violations
    end
  end

  defp graph_with(declaration) do
    {:ok, graph} =
      Graph.from_map(%{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "notify",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"notify" => declaration}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "notify"},
          %{"id" => "e2", "source" => "notify", "target" => "end"}
        ]
      })

    graph
  end
end
