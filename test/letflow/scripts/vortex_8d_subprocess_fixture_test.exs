defmodule Letflow.Scripts.Vortex8dSubprocessFixtureTest do
  @moduledoc """
  ISS-0929 / Q-929 regression guard (F1-F7 + in-memory mutants M-a..M-f of
  `lib/letflow/design/q929-vortex-8d-corrective-action-subprocess.md` section 8.1).

  The Vortex "Supplier Quality Deviation" SUB_PROCESS node `corrective-action-subprocess`
  must late-bind an existing child definition ("8D Corrective Action") by
  `definition_name`; the child must be a START -> HUMAN_TASK(role-procurement-manager)
  -> END graph; the seed script must seed the child before the parent; the alias sidecar
  must map the corpus id to the child name; the parent version must be bumped to 1.2.

  Pure: file reads only, no DB. Each guard is a `check_*` function over decoded
  documents / script text so the same logic is re-applied to mutated in-memory copies
  to prove it fires. See `test/specs/ISS-0929.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph

  @root Path.expand("../../..", __DIR__)
  @parent_path "test/fixtures/qa/vortex_supplier_quality_deviation_process_definition.json"
  @child_path "test/fixtures/qa/vortex_8d_corrective_action_definition.json"
  @alias_path "test/fixtures/uat/process-definition-aliases/proc-vortex-8d-corrective-action.yaml"
  @seed_path "scripts/seed_vortex_definition.sh"
  @child_alias "proc-vortex-8d-corrective-action"
  @parent_alias "proc-vortex-supplier-quality-deviation"

  # ---------------------------------------------------------------------------------
  # Helpers (no optional-argument defaults -- anti-patterns.md ISS-0069)
  # ---------------------------------------------------------------------------------

  defp read!(rel), do: @root |> Path.join(rel) |> File.read!()
  defp json!(rel), do: rel |> read!() |> Jason.decode!()

  defp alias_doc do
    {:ok, doc} = YamlElixir.read_from_file(Path.join(@root, @alias_path))
    doc
  end

  defp node(doc, id), do: Enum.find(doc["graph"]["nodes"], &(&1["id"] == id))

  defp nodes_of_type(doc, type),
    do: Enum.filter(doc["graph"]["nodes"], &(&1["node_type"] == type))

  defp version_tuple(v),
    do: v |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()

  defp put_node(doc, node_id, fun) do
    update_in(doc, ["graph", "nodes"], fn ns ->
      Enum.map(ns, fn n -> if n["id"] == node_id, do: fun.(n), else: n end)
    end)
  end

  defp index_of(src, needle) do
    case :binary.match(src, needle) do
      {i, _} -> i
      :nomatch -> nil
    end
  end

  # ---------------------------------------------------------------------------------
  # Guards: each returns a list of violations ([] = clean)
  # ---------------------------------------------------------------------------------

  defp check_f1(parent) do
    case get_in(node(parent, "corrective-action-subprocess"), ["attributes", "definition_name"]) do
      n when is_binary(n) and n != "" -> []
      other -> ["F1 definition_name missing/empty: #{inspect(other)}"]
    end
  end

  defp check_f2(parent, child) do
    name = get_in(node(parent, "corrective-action-subprocess"), ["attributes", "definition_name"])

    if name == child["name"],
      do: [],
      else: ["F2 #{inspect(name)} != child name #{inspect(child["name"])}"]
  end

  defp check_f3(child) do
    case Graph.from_map(child["graph"]) do
      {:ok, g} ->
        [
          Graph.validate_graph(g),
          Graph.validate_node_attributes(g),
          Graph.validate_edge_conditions(g)
        ]
        |> Enum.flat_map(fn r ->
          if r.valid, do: r.violations, else: [:invalid | r.violations]
        end)

      :error ->
        [:from_map_error]
    end
  end

  defp check_f4(parent, child) do
    humans = nodes_of_type(child, "HUMAN_TASK")
    role_ok = match?([%{"attributes" => %{"role" => "role-procurement-manager"}}], humans)

    sub_attrs = node(parent, "corrective-action-subprocess")["attributes"] || %{}

    [
      if(role_ok, do: nil, else: "F4 child needs exactly one procurement HUMAN_TASK"),
      if(nodes_of_type(child, "SERVICE_TASK") == [],
        do: nil,
        else: "F4 child must have no SERVICE_TASK"
      ),
      if(Map.has_key?(sub_attrs, "interface"),
        do: "F4 parent SUB_PROCESS must not declare interface",
        else: nil
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp check_f5(seed_src) do
    child_idx = index_of(seed_src, "\"#{@child_alias}\"")
    parent_idx = index_of(seed_src, "\"#{@parent_alias}\"")

    cond do
      index_of(seed_src, @child_path) == nil -> ["F5 seed script lacks the child fixture path"]
      child_idx == nil -> ["F5 seed script lacks the child alias"]
      parent_idx == nil -> ["F5 seed script lacks the parent alias"]
      child_idx > parent_idx -> ["F5 child seeded after parent"]
      true -> []
    end
  end

  defp check_f6(alias_map, child) do
    fixture_ok =
      is_binary(alias_map["fixture"]) and File.exists?(Path.join(@root, alias_map["fixture"]))

    [
      if(alias_map["definition_name"] == child["name"],
        do: nil,
        else: "F6 alias definition_name != child name"
      ),
      if(alias_map["process_id"] == @child_alias, do: nil, else: "F6 alias process_id mismatch"),
      if(fixture_ok, do: nil, else: "F6 alias fixture path does not exist")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp check_f7(parent) do
    if version_tuple(parent["version"]) > version_tuple("1.1"),
      do: [],
      else: ["F7 parent version #{parent["version"]} is not > 1.1"]
  end

  # ---------------------------------------------------------------------------------
  # Guards against the real files
  # ---------------------------------------------------------------------------------

  describe "real files" do
    test "F1 parent corrective-action-subprocess has a non-empty definition_name" do
      assert check_f1(json!(@parent_path)) == []
    end

    test "F2 definition_name equals the child fixture name (8D Corrective Action)" do
      child = json!(@child_path)
      assert child["name"] == "8D Corrective Action"
      assert check_f2(json!(@parent_path), child) == []
    end

    test "F3 child graph passes graph, node-attribute and edge-condition validation" do
      assert check_f3(json!(@child_path)) == []
    end

    test "F4 child has one procurement HUMAN_TASK, no SERVICE_TASK; parent has no interface" do
      assert check_f4(json!(@parent_path), json!(@child_path)) == []
    end

    test "F5 seed script seeds the 8D child (fixture + alias) before the parent" do
      assert check_f5(read!(@seed_path)) == []
    end

    test "F6 alias sidecar maps the corpus id to the child name and an existing fixture" do
      assert check_f6(alias_doc(), json!(@child_path)) == []
    end

    test "F7 parent fixture version is bumped to 1.7 (> 1.1; 1.5 = ISS-1003 explicit default-to-critical; 1.6 = ISS-1002 D-ESC timers; 1.7 = REQ-462 required_outputs)" do
      parent = json!(@parent_path)
      assert parent["version"] == "1.8"
      assert check_f7(parent) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # In-memory mutants: each guard must fire on a mutated copy
  # ---------------------------------------------------------------------------------

  describe "in-memory mutants" do
    test "M-a removing definition_name trips F1 and F2" do
      parent =
        put_node(
          json!(@parent_path),
          "corrective-action-subprocess",
          &Map.delete(&1, "attributes")
        )

      assert check_f1(parent) != []
      assert check_f2(parent, json!(@child_path)) != []
    end

    test "M-b changing the child name by one character trips F2 and F6" do
      child = Map.put(json!(@child_path), "name", "8D Corrective Actions")
      assert check_f2(json!(@parent_path), child) != []
      assert check_f6(alias_doc(), child) != []
    end

    test "M-c removing the HUMAN_TASK role trips F4" do
      child =
        put_node(json!(@child_path), "corrective-action-8d", &Map.put(&1, "attributes", %{}))

      assert check_f4(json!(@parent_path), child) != []
    end

    test "M-c2 a wrong role trips F4" do
      child =
        put_node(
          json!(@child_path),
          "corrective-action-8d",
          &Map.put(&1, "attributes", %{"role" => "role-quality-manager"})
        )

      assert check_f4(json!(@parent_path), child) != []
    end

    test "M-c3 a SERVICE_TASK in the child trips F4" do
      child =
        update_in(json!(@child_path), ["graph", "nodes"], fn ns ->
          ns ++ [%{"id" => "x", "node_type" => "SERVICE_TASK"}]
        end)

      assert check_f4(json!(@parent_path), child) != []
    end

    test "M-d dropping the child seed call, or reversing the order, trips F5" do
      src = read!(@seed_path)
      assert check_f5(String.replace(src, @child_alias, "proc-removed")) != []

      swapped =
        src
        |> String.replace("\"#{@child_alias}\"", "\"TMP\"")
        |> String.replace("\"#{@parent_alias}\"", "\"#{@child_alias}\"")
        |> String.replace("\"TMP\"", "\"#{@parent_alias}\"")

      assert check_f5(swapped) != []
    end

    test "M-e reverting the parent version to 1.1 trips F7" do
      assert check_f7(Map.put(json!(@parent_path), "version", "1.1")) != []
    end

    test "M-f an alias fixture path that does not exist trips F6" do
      bad = Map.put(alias_doc(), "fixture", "test/fixtures/qa/does_not_exist.json")
      assert check_f6(bad, json!(@child_path)) != []
    end
  end
end
