defmodule Letflow.Engine.PlatformHostsRedactionTest do
  @moduledoc """
  SR-OPT-8 (decision 0062 R8, GH #2616 part 2): the in-process paths hide a labelled value the
  caller may not read. No production builder fills these contexts yet (the dispatch that wires
  SERVICE_TASK and plugin calls is later work), so each test builds the context directly. A context
  whose hidden set is missing (`nil`) hides every labelled value (fail closed).

  The WASM `read_variable` case lives with the other WASM host tests (`host_api_test.exs`).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine
  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.Engine.PluginInterface
  alias Letflow.Engine.PluginInterface.ExecutionContext
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Support.ScriptTaskFixture, as: F

  @label "customer.salary"
  @placeholder "__field_redacted__"

  defmodule ReadingHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface

    @impl true
    def handle_node(%ExecutionContext{variables: variables}), do: {:complete, variables}
  end

  defp plugin_context(overrides) do
    struct(
      ExecutionContext,
      Map.merge(
        %{
          instance_id: Ecto.UUID.generate(),
          definition_id: Ecto.UUID.generate(),
          node_id: "plugin",
          node_type: "PLUGIN",
          variables: %{"x" => 1, "w" => 2},
          node_config: %{},
          trace_id: "trace-redaction",
          variable_labels: %{"x" => [@label]},
          hidden_labels: MapSet.new([@label])
        },
        overrides
      )
    )
  end

  describe "SR-OPT-8(a,b) plugin handler context" do
    test "a labelled variable the caller may not read is hidden from the handler; the unlabelled one is clear" do
      assert {:complete, output} = PluginInterface.invoke(ReadingHandler, plugin_context(%{}), [])

      assert output == %{"x" => :__field_redacted__, "w" => 2}
    end

    test "a missing hidden set (nil) hides every labelled variable (fail closed)" do
      context = plugin_context(%{hidden_labels: nil})

      assert {:complete, %{"x" => :__field_redacted__, "w" => 2}} =
               PluginInterface.invoke(ReadingHandler, context, [])
    end

    test "a hidden set that does not name the label leaves the value clear" do
      context = plugin_context(%{hidden_labels: MapSet.new(["customer.ssn"])})

      assert {:complete, %{"x" => 1, "w" => 2}} =
               PluginInterface.invoke(ReadingHandler, context, [])
    end
  end

  describe "SR-OPT-8(c,d) Lua platform host" do
    defp lua_context(overrides) do
      Map.merge(
        Platform.empty_execution_context(),
        Map.merge(
          %{
            instance_id: nil,
            prefix: nil,
            variables: %{"x" => 1, "w" => 2},
            variable_labels: %{"x" => [@label]},
            hidden_labels: MapSet.new([@label])
          },
          overrides
        )
      )
    end

    test "read_variable returns the placeholder for a hidden labelled variable" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["variable:read"]), lua_context(%{}))

      assert {[@placeholder], _lua} = Lua.eval!(lua, "return platform.read_variable('x')")
      assert {[2], _lua} = Lua.eval!(lua, "return platform.read_variable('w')")
    end

    test "a missing hidden set (nil) makes read_variable return the placeholder (fail closed)" do
      context = lua_context(%{hidden_labels: nil})
      lua = Platform.install(Sandbox.new(), Capabilities.new(["variable:read"]), context)

      assert {[@placeholder], _lua} = Lua.eval!(lua, "return platform.read_variable('x')")
    end

    test "get_instance_state shows the placeholder for a hidden labelled variable" do
      t = F.tenant!("gh2616-lua")
      b = labelled_review!(t)

      context =
        lua_context(%{
          instance_id: b.instance_id,
          prefix: t.schema_name,
          variables: %{},
          variable_labels: %{},
          hidden_labels: nil
        })

      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["instance:read"]), context)

      {[state], _lua} =
        Lua.eval!(lua, "return platform.get_instance_state('#{b.instance_id}')")

      # A Lua table decodes to a list of {key, value} pairs.
      assert {"variables", variables} = List.keyfind(state, "variables", 0)
      assert List.keyfind(variables, "total", 0) == {"total", @placeholder}
    end
  end

  # START -> svc (script: total = 4, labelled) -> review (HUMAN_TASK) -> END
  defp labelled_review!(t) do
    graph = fn key, version ->
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "svc",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"script_key" => key, "script_version" => version}
          },
          %{
            "id" => "review",
            "node_type" => "HUMAN_TASK",
            "attributes" => %{"role" => "REVIEWER"}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "svc"},
          %{"id" => "e2", "source" => "svc", "target" => "review"},
          %{"id" => "e3", "source" => "review", "target" => "end"}
        ]
      }
    end

    b = F.bound_graph!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 2}, graph, [])
    {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)

    result =
      {:ok, %{"total" => 4},
       %{
         row: row,
         phase: :ran,
         outcome: :ok,
         detail: nil,
         fail_code: nil,
         hmac: nil,
         stats: nil,
         output_labels: %{"total" => [@label]}
       }}

    assert {:ok, :applied} = Engine.apply_script_task_result(F.claim(row), result, t.schema_name)
    b
  end
end
