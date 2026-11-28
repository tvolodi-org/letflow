defmodule Letflow.PlatformProcesses.DefinitionV3Test do
  @moduledoc """
  T-3154 (owner item 11 / D-195, slice G2; `docs/platform-register-tenant-v2.md` section 12): the v3
  document of `platform.register_tenant`. It is v2 with a realm gateway and the
  `provision_realm_and_invite` step before `bind_realm`: a graph that parses and validates, a default
  edge that carries no condition, reads and writes derived from the catalogue, the typed context, and
  the seed's upgrade over a stamped v2.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.Graph
  alias Letflow.PlatformProcesses.{DefinitionV2, DefinitionV3}

  defp node_ids, do: Enum.map(DefinitionV3.graph()["nodes"], & &1["id"])

  test "D1 the realm gateway and the provision step sit between record_onboarding and bind_realm" do
    assert node_ids() ==
             ~w(start validate create provision record_lifecycle record_onboarding realm_gate
                provision_realm bind_realm grant_first_admins install_default_modules notify_gate
                notify end)

    assert {:ok, %Graph{} = parsed} = Graph.from_map(DefinitionV3.graph())
    assert %{valid: true} = Graph.validate_graph(parsed)

    edges = DefinitionV3.graph()["edges"]
    from_gate = Enum.filter(edges, &(&1["source"] == "realm_gate"))
    default = Enum.find(from_gate, &(Map.get(&1, "is_default") == true))
    other = Enum.find(from_gate, &(Map.get(&1, "is_default") != true))

    # realm supplied (or nobody to invite): bind_realm as in v2; absent: provision, then bind
    assert default["target"] == "bind_realm" and not Map.has_key?(default, "condition")
    assert other["target"] == "provision_realm"
    assert other["condition"] == "variables.provision_realm == true"
    assert Enum.any?(edges, &(&1["source"] == "provision_realm" and &1["target"] == "bind_realm"))

    assert Enum.any?(
             edges,
             &(&1["source"] == "record_onboarding" and &1["target"] == "realm_gate")
           )

    refute Enum.any?(
             edges,
             &(&1["source"] == "record_onboarding" and &1["target"] == "bind_realm")
           )
  end

  test "D2 every other node of v2 is carried over unchanged" do
    v2 = Map.new(DefinitionV2.graph()["nodes"], &{&1["id"], &1})
    v3 = Map.new(DefinitionV3.graph()["nodes"], &{&1["id"], &1})

    for {id, node} <- v2, do: assert(v3[id] == node, "node #{id} drifted from v2")
  end

  test "D3 the provision step reads the tenant id (a step output) and writes only the realm id" do
    node = Enum.find(DefinitionV3.graph()["nodes"], &(&1["id"] == "provision_realm"))
    call = node["attributes"]["platform_call"]

    assert call["function"] == "tenant.provision_realm_and_invite"
    assert call["writes"] == %{"realm_id" => "string"}
    assert call["args"]["tenant_id"] == %{"var" => "tenant_id"}
    # no password anywhere: not an argument, not a write
    refute Enum.any?(Map.keys(call["args"]) ++ Map.keys(call["writes"]), &(&1 =~ "password"))
  end

  test "D4 the typed context declares the new start variables and every read and write" do
    declared = Map.new(DefinitionV3.variable_schemas(), &{&1.variable_key, &1.json_schema})

    assert declared["provision_realm"] == %{"type" => "boolean"}
    assert declared["language"] == %{"type" => "string"}

    for node <- DefinitionV3.graph()["nodes"],
        call = get_in(node, ["attributes", "platform_call"]) do
      for name <- Map.keys(call["reads"]) ++ Map.keys(call["writes"]) do
        assert Map.has_key?(declared, name), "#{name} is not declared"
      end
    end

    attrs = DefinitionV3.attrs()
    assert attrs.version == "3" and attrs.name == "platform.register_tenant"
    assert attrs.start_permission == "TenantsManage"
    refute Map.has_key?(attrs, :created_by)
  end
end
