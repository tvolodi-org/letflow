defmodule Letflow.PlatformProcesses.DefinitionTest do
  @moduledoc """
  The DOCUMENT of the pilot's registration definition (T-2595, gap G9 of the
  "Register a tenant" pilot): the graph, the typed context and the declared
  start permission.

  Pure: no database, no clock. The seed writes this document and the engine
  reads the row that carries it, so the tests here pin what the seed ships:
  the steps and their order, the typed mapping of every step, the notification
  step's declaration and the start permission.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.NotifyCalls
  alias Letflow.Definitions.StartPermission
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformProcesses.Definition

  test "the key, the version and the description are the ones the pilot names" do
    assert Definition.name() == "platform.register_tenant"
    assert Definition.version() == "1"
    assert is_binary(Definition.description())
  end

  test "the steps are in the order of the chain, and the graph is structurally valid" do
    graph = Definition.graph()

    assert [
             %{"id" => "start", "node_type" => "START"},
             %{"id" => "validate", "node_type" => "SERVICE_TASK"},
             %{"id" => "create", "node_type" => "SERVICE_TASK"},
             %{"id" => "provision", "node_type" => "SERVICE_TASK"},
             %{"id" => "bind_realm", "node_type" => "SERVICE_TASK"},
             %{"id" => "grant_first_admins", "node_type" => "SERVICE_TASK"},
             %{"id" => "notify", "node_type" => "SERVICE_TASK"},
             %{"id" => "end", "node_type" => "END"}
           ] = graph["nodes"]

    assert [
             %{"source" => "start", "target" => "validate"},
             %{"source" => "validate", "target" => "create"},
             %{"source" => "create", "target" => "provision"},
             %{"source" => "provision", "target" => "bind_realm"},
             %{"source" => "bind_realm", "target" => "grant_first_admins"},
             %{"source" => "grant_first_admins", "target" => "notify"},
             %{"source" => "notify", "target" => "end"}
           ] = graph["edges"]

    assert {:ok, %Graph{} = parsed} = Graph.from_map(graph)
    assert %{valid: true} = Graph.validate_graph(parsed)
    assert %{valid: true} = Graph.validate_node_attributes(parsed)
    assert %{valid: true} = Graph.validate_edge_conditions(parsed)
    assert %{valid: true} = Graph.validate_flow(parsed)
  end

  test "every platform-call step names a function of the compiled catalogue, with the arguments the catalogue declares" do
    calls = platform_calls()

    assert [
             {"validate", "tenant.validate"},
             {"create", "tenant.create"},
             {"provision", "tenant.provision"},
             {"bind_realm", "tenant.bind_realm"},
             {"grant_first_admins", "tenant.grant_first_admins"}
           ] = calls

    Enum.each(calls, fn {_node_id, function} ->
      assert {:ok, entry} = Catalog.fetch(function)
      assert entry.family == :platform
      assert entry.platform_tenant_only
      assert entry.permission == :TenantsManage
    end)
  end

  test "every step declares its typed mapping, and the mapping agrees with the catalogue" do
    graph = Definition.graph()

    Enum.each(graph["nodes"], fn node ->
      call = get_in(node, ["attributes", "platform_call"])

      if call do
        assert {:ok, entry} = Catalog.fetch(call["function"])

        # every argument is a declared input, and every required one is there
        declared = Map.new(entry.inputs, &{&1.name, &1})

        Enum.each(Map.keys(call["args"]), fn name ->
          assert Map.has_key?(declared, name), "argument #{name} is not an input of the entry"
        end)

        Enum.each(entry.inputs, fn input ->
          if input.required do
            assert Map.has_key?(call["args"], input.name)
          end
        end)

        # the reads are the variables the step takes from a variable, the
        # writes are the outputs the function produces
        reads =
          entry.inputs
          |> Enum.filter(fn input -> match?(%{"var" => _}, Map.get(call["args"], input.name)) end)
          |> Map.new(fn input -> {input.name, type_name(input.type)} end)

        writes =
          Map.new(entry.outputs, fn output -> {output.name, type_name(output.type)} end)

        assert call["reads"] == reads
        assert call["writes"] == writes
      end
    end)
  end

  test "the typed context declares every variable a step reads or writes" do
    declared = Definition.variable_schemas() |> Map.new(&{&1.variable_key, &1.json_schema})

    for node <- Definition.graph()["nodes"] do
      call = get_in(node, ["attributes", "platform_call"])

      if call do
        Enum.each(Map.keys(call["reads"]), fn name -> assert Map.has_key?(declared, name) end)
        Enum.each(Map.keys(call["writes"]), fn name -> assert Map.has_key?(declared, name) end)
      end
    end

    # the start's own names are declared too: the screen sends them, and a
    # definition that renames one of them cannot be started from the screen
    Enum.each(["slug", "name", "hostname", "realm_id", "admin_email"], fn name ->
      assert Map.has_key?(declared, name)
    end)

    # the outputs of the steps
    Enum.each(["tenant_id", "schema_name"], fn name ->
      assert Map.has_key?(declared, name)
    end)
  end

  test "the notification step sends the registered template to a variable, with the template's own placeholders" do
    notify = notify_node()

    assert {:ok, declaration} = NotifyCalls.parse(get_in(notify, ["attributes", "notify"]))

    assert declaration.template_key == "tenant_registered"
    assert declaration.recipient_var == "admin_email"

    # the recipient is a VARIABLE, never a constant address (INV-4)
    assert %{"var" => "admin_email"} = get_in(notify, ["attributes", "notify", "recipient"])

    assert declaration.values == %{
             "tenant_name" => {:var, "name"},
             "tenant_slug" => {:var, "slug"},
             "registered_by" => {:var, "admin_email"}
           }
  end

  test "the notification step and the catalogue calls never share a node" do
    Enum.each(Definition.graph()["nodes"], fn node ->
      attributes = Map.get(node, "attributes", %{})

      refute Map.has_key?(attributes, "notify") and Map.has_key?(attributes, "platform_call")
      refute Map.has_key?(attributes, "endpoint")
      refute Map.has_key?(attributes, "service_id")
      refute Map.has_key?(attributes, "script_key")
    end)
  end

  test "the definition declares the start permission of the chain" do
    assert Definition.start_permission() == "TenantsManage"

    # the declaration may not be weaker than the steps need
    {:ok, %Graph{} = parsed} = Graph.from_map(Definition.graph())

    assert StartPermission.required(parsed) == [:TenantsManage]
  end

  test "the attributes carry the graph, the version and the start permission, and no creator" do
    attrs = Definition.attrs()

    assert attrs.name == "platform.register_tenant"
    assert attrs.version == "1"
    assert attrs.graph == Definition.graph()
    assert attrs.start_permission == "TenantsManage"
    refute Map.has_key?(attrs, :created_by)
  end

  defp platform_calls do
    Definition.graph()["nodes"]
    |> Enum.flat_map(fn node ->
      case get_in(node, ["attributes", "platform_call"]) do
        nil -> []
        call -> [{node["id"], call["function"]}]
      end
    end)
  end

  defp notify_node do
    Definition.graph()["nodes"]
    |> Enum.find(fn node -> node["id"] == "notify" end)
  end

  defp type_name(:string), do: "string"
  defp type_name(:uuid), do: "string"
  defp type_name(:number), do: "number"
  defp type_name(:integer), do: "integer"
  defp type_name(:boolean), do: "boolean"
  defp type_name(:object), do: "object"
  defp type_name(:array), do: "array"
  defp type_name(_other), do: "string"

  # T-2742: the web test of the designer (`DefinitionEditorPage.registerTenant.test.tsx`) mounts the page with THIS
  # document, read from the checked-in copy. A change of `Definition.graph/0` that does not refresh the copy fails here.
  # Refresh: MIX_ENV=test mix run --no-start -e 'File.write!("test/fixtures/platform_processes/register_tenant_graph.json", Jason.encode!(Letflow.PlatformProcesses.Definition.graph(), pretty: true) <> "\n")'
  test "the checked-in copy the designer test mounts is the document the seed writes" do
    copy =
      "test/fixtures/platform_processes/register_tenant_graph.json"
      |> File.read!()
      |> Jason.decode!()

    assert copy == Definition.graph() |> Jason.encode!() |> Jason.decode!()
  end
end
