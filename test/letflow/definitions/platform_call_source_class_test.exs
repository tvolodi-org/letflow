defmodule Letflow.Definitions.PlatformCallSourceClassTest do
  @moduledoc """
  The generated source-class probes of decision 0094 (T-2588, gap G2).

  `docs/g2-source-class-table.md` is the enumeration these tests implement. The
  probes read the compiled catalogue and every entry's declared inputs instead
  of copying their names, so a new catalogue entry is covered automatically.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.ActivatedBy
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.PlatformCalls
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Entry
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  @non_service_node_types [
    :START,
    :END,
    :HUMAN_TASK,
    :EXCLUSIVE_GATEWAY,
    :PARALLEL_GATEWAY,
    :TIMER,
    :SUB_PROCESS
  ]

  setup do
    tenant = Fx.tenant!("t2588-source-class")
    PlatformFx.pin!(tenant.tenant_id)
    admin = Fx.user!(tenant.schema_name, "source-admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    activator =
      Activator.from_auth_context(%{user_id: admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    %{prefix: tenant.schema_name, activator: activator}
  end

  defp entries do
    entries = Catalog.list(platform_tenant?: true)
    assert entries != []
    entries
  end

  defp const_args(entry) do
    Map.new(entry.inputs, fn input -> {input.name, %{"const" => "fixed-#{input.name}"}} end)
  end

  defp node(entry, args, node_type \\ :SERVICE_TASK) do
    %Graph.Node{
      id: "call",
      node_type: node_type,
      attributes: %{"platform_call" => %{"function" => entry.name, "args" => args}}
    }
  end

  defp codes(ctx, entry, args, node_type \\ :SERVICE_TASK, extra_nodes \\ []) do
    call_node = node(entry, args, node_type)

    call_node
    |> PlatformCalls.violations([call_node | extra_nodes], ctx.prefix, ctx.activator)
    |> Enum.map(& &1.code)
  end

  defp with_source(entry, input, source) do
    Map.put(const_args(entry), input.name, source)
  end

  test "A1/A2/A4: start, earlier-step and engine-owned variables are accepted", ctx do
    for entry <- entries(), input <- entry.inputs do
      for variable <- ["start_#{input.name}", "step_#{input.name}", "engine_#{input.name}"] do
        assert codes(ctx, entry, with_source(entry, input, %{"var" => variable})) == [],
               "#{entry.name}.#{input.name} must accept the trusted variable #{variable}"
      end
    end
  end

  test "A3: a completer-writable variable is refused for every write-like entry", ctx do
    human = %Graph.Node{
      id: "human",
      node_type: :HUMAN_TASK,
      attributes: %{"completer_inputs" => ["person_value"]}
    }

    for entry <- entries(), input <- entry.inputs do
      result =
        codes(ctx, entry, with_source(entry, input, %{"var" => "person_value"}), :SERVICE_TASK, [
          human
        ])

      if Entry.write_like?(entry) do
        assert :platform_call_input_source_refused in result,
               "#{entry.name}.#{input.name} must not be person-writable"
      else
        assert result == [], "the write-like source rule must not refuse read-only #{entry.name}"
      end
    end
  end

  test "A5: reserved engine variables are refused for every declared input", ctx do
    for entry <- entries(), input <- entry.inputs do
      assert :platform_call_arg_sys_reference in codes(
               ctx,
               entry,
               with_source(entry, input, %{"var" => "_sys"})
             ),
             "#{entry.name}.#{input.name} must reject a reserved engine key"
    end
  end

  test "A6: dotted variable names are refused for every declared input", ctx do
    for entry <- entries(), input <- entry.inputs do
      assert :platform_call_arg_source_invalid in codes(
               ctx,
               entry,
               with_source(entry, input, %{"var" => "section.#{input.name}"})
             ),
             "#{entry.name}.#{input.name} must treat a variable as one flat key"
    end
  end

  test "A7: a const source is accepted for every declared input", ctx do
    for entry <- entries() do
      assert codes(ctx, entry, const_args(entry)) == [],
             "#{entry.name} must accept designer-fixed const arguments"
    end
  end

  test "A7: a const literal is signed with the graph and is not a completion read key", ctx do
    call =
      Fx.call("tenant.create", %{
        "slug" => %{"const" => "signed-slug"},
        "name" => %{"const" => "Signed name"}
      })

    graph_map = Fx.graph(call)
    {:ok, graph} = Graph.from_map(graph_map)

    refute "slug" in PlatformCalls.read_keys(graph.nodes)
    refute "name" in PlatformCalls.read_keys(graph.nodes)

    draft = Fx.definition!(ctx.prefix, graph_map, "pcf-source-const-signed")

    assert {:ok, _} =
             Definitions.activate(draft.id, prefix: ctx.prefix, activator: ctx.activator)

    stored = Repo.get!(ProcessDefinition, draft.id, prefix: ctx.prefix)

    assert get_in(stored.graph, ["nodes", Access.at(1), "attributes", "platform_call"]) == call
    assert {:ok, :verified} = ActivatedBy.verify(stored.activated_by, stored, ctx.prefix)

    altered_call = put_in(call, ["args", "slug", "const"], "person-controlled-slug")
    altered_graph = Fx.graph(altered_call)
    refute OwnerStamp.graph_hash(altered_graph) == OwnerStamp.graph_hash(graph_map)

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^stored.id),
        [set: [graph: altered_graph]],
        prefix: ctx.prefix
      )

    tampered = Repo.get!(ProcessDefinition, stored.id, prefix: ctx.prefix)

    assert {:error, :mismatch} = ActivatedBy.verify(tampered.activated_by, tampered, ctx.prefix)
  end

  test "A8: every required argument is enforced for every catalogue entry", ctx do
    for entry <- entries(), input <- entry.inputs, input.required do
      args = Map.delete(const_args(entry), input.name)

      assert :platform_call_arg_missing in codes(ctx, entry, args),
             "#{entry.name}.#{input.name} is required"
    end
  end

  test "A9: unknown argument names are refused for every catalogue entry", ctx do
    for entry <- entries() do
      args = Map.put(const_args(entry), "undeclared_argument", %{"const" => "unexpected"})

      assert :platform_call_arg_unknown in codes(ctx, entry, args),
             "#{entry.name} must close its argument names"
    end
  end

  test "A10: malformed argument sources are refused for every declared input", ctx do
    malformed = [
      nil,
      %{},
      %{"var" => ""},
      %{"var" => "   "},
      %{"var" => "valid", "const" => "ambiguous"},
      %{"const" => "ambiguous", "var" => "valid"},
      "not-a-source-map"
    ]

    for entry <- entries(), input <- entry.inputs, source <- malformed do
      assert :platform_call_arg_source_invalid in codes(
               ctx,
               entry,
               with_source(entry, input, source)
             ),
             "#{entry.name}.#{input.name} accepted malformed source #{inspect(source)}"
    end
  end

  test "A11: unknown call keys are refused for every catalogue entry", ctx do
    for entry <- entries() do
      call_node = node(entry, const_args(entry))
      call = get_in(call_node.attributes, ["platform_call"])

      call_node = %{
        call_node
        | attributes:
            put_in(call_node.attributes, ["platform_call"], Map.put(call, "unexpected", true))
      }

      codes =
        call_node
        |> PlatformCalls.violations([call_node], ctx.prefix, ctx.activator)
        |> Enum.map(& &1.code)

      assert [:platform_call_unknown_key] = codes
    end
  end

  test "A12: malformed calls are refused instead of being guessed", ctx do
    for entry <- entries(),
        malformed <- [
          "not-a-call-map",
          %{},
          %{"function" => "", "args" => %{}},
          %{"function" => "   ", "args" => %{}},
          %{"function" => entry.name, "args" => "not-an-args-map"},
          %{"function" => entry.name, "args" => nil}
        ] do
      call_node = %Graph.Node{
        id: "call",
        node_type: :SERVICE_TASK,
        attributes: %{"platform_call" => malformed}
      }

      violations = PlatformCalls.violations(call_node, [call_node], ctx.prefix, ctx.activator)

      assert Enum.any?(violations, &(&1.code == :platform_call_malformed)),
             "malformed call #{inspect(malformed)} must have the stable malformed code"
    end
  end

  test "A14: non-service nodes are refused for every catalogue entry", ctx do
    for entry <- entries(), node_type <- @non_service_node_types do
      assert codes(ctx, entry, const_args(entry), node_type) == [
               :platform_call_node_type_not_supported
             ],
             "#{entry.name} on #{node_type} must be refused"
    end
  end
end
