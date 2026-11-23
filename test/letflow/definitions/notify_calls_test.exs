defmodule Letflow.Definitions.NotifyCallsTest do
  @moduledoc """
  T-2592 (pilot gap G4): the rules of the NOTIFICATION STEP's declaration -- the
  one parse the activation fence and the dispatcher share.

  Test ids D1..D14.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.NotifyCalls
  alias Letflow.Definitions.StepMapping

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

  describe "the byte bounds (SF-01), one byte over each cap" do
    test "D23 a template key one byte over 64 is refused; 64 bytes pass the bound" do
      assert {:error, :notify_template_unknown} =
               NotifyCalls.parse(declaration(%{"template_key" => String.duplicate("a", 65)}))
    end

    test "D24 a variable name one byte over 255 is refused" do
      over = String.duplicate("a", 256)

      assert {:error, :notify_recipient_invalid} =
               NotifyCalls.parse(declaration(%{"recipient" => %{"var" => over}}))

      assert {:error, :notify_value_source_invalid} =
               NotifyCalls.parse(declaration(%{"values" => %{"tenant_name" => %{"var" => over}}}))

      at_cap = String.duplicate("a", 255)
      assert {:ok, _} = NotifyCalls.parse(declaration(%{"recipient" => %{"var" => at_cap}}))
    end

    test "D25 a constant one byte over 4096 is refused; 4096 bytes pass" do
      const = fn n ->
        %{"values" => %{"tenant_slug" => %{"const" => String.duplicate("a", n)}}}
      end

      assert {:error, :notify_value_source_invalid} = NotifyCalls.parse(declaration(const.(4097)))
      assert {:ok, _} = NotifyCalls.parse(declaration(const.(4096)))
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

    test "D16 a node that is not a SERVICE_TASK is refused in the DRAFT, not only at activation" do
      # The node type is one of the rules the declaration states, so the draft
      # path refuses it too: a HUMAN_TASK carrying a `notify` attribute is not
      # stored and then switched on.
      graph =
        graph_with(declaration(), node_type: "HUMAN_TASK", extra_attributes: %{"role" => "A"})

      assert [%{code: :notify_node_type_not_supported}] =
               Graph.validate_node_attributes(graph).violations
    end
  end

  describe "the typed mapping (T-2594's rule, carried to the notification step)" do
    test "D19 the mapping is derived from the declaration: the reads, and no writes" do
      node = notify_node(declaration())

      assert [mapping] = NotifyCalls.mappings([node], %{})

      assert mapping.node_id == "notify"
      # the recipient's variable and the variables of the values; a constant
      # value is not a variable, so it is not a read
      assert mapping.read_names == ["admin_email", "tenant_name"]
      assert mapping.reads == %{"admin_email" => "string", "tenant_name" => "string"}
      # a notification leaves the process: it writes no variable
      assert mapping.writes == %{}
      assert mapping.write_names == []
    end

    test "D20 the type of a read is the type the DEFINITION declares for it" do
      node = notify_node(declaration())

      fields = %{
        "admin_email" => %{"type" => "string"},
        "tenant_name" => %{"type" => "integer"}
      }

      assert [mapping] = NotifyCalls.mappings([node], fields)
      assert mapping.reads == %{"admin_email" => "string", "tenant_name" => "integer"}
    end

    test "D21 a read the definition does not declare is refused by the typed rule" do
      node = notify_node(declaration())

      violations =
        StepMapping.violations(NotifyCalls.mappings([node], %{}), %{}, MapSet.new())

      assert [
               %{code: :step_mapping_variable_undeclared, side: :reads, name: "admin_email"},
               %{code: :step_mapping_variable_undeclared, side: :reads, name: "tenant_name"}
             ] = violations
    end

    test "D22 the activation fence binds the notification step's reads to variable_schemas" do
      node = notify_node(declaration())

      # The definition declares nothing: the notify step's reads are not among
      # the declared variable schemas, so the typed fence refuses them.
      violations = Definitions.step_mapping_violations([node], %{}, "a_tenant_schema")

      assert [
               %{code: :step_mapping_variable_undeclared, side: :reads, name: "admin_email"},
               %{code: :step_mapping_variable_undeclared, side: :reads, name: "tenant_name"}
             ] = violations
    end
  end

  defp graph_with(declaration, opts \\ []) do
    node_type = Keyword.get(opts, :node_type, "SERVICE_TASK")
    extra = Keyword.get(opts, :extra_attributes, %{})

    {:ok, graph} =
      Graph.from_map(%{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "notify",
            "node_type" => node_type,
            "attributes" => Map.merge(%{"notify" => declaration}, extra)
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
