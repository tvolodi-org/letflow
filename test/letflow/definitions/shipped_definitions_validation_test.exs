defmodule Letflow.Definitions.ShippedDefinitionsValidationTest do
  @moduledoc """
  REQ-455 AC5: every process definition shipped in the repository or seeded by
  `scripts/` is run through the validator, so a definition with a dead end, an
  unreachable node or a decision without a default route cannot ship (the gap that
  reached UAT as ISS-0928).

  Discovery is by STRUCTURE, never a hand list, so a newly added fixture is covered
  without editing this file: every `priv/**/*.json`, `test/fixtures/qa/*.json` and
  `test/fixtures/simulation/**/process_*.yaml` whose decoded form has a `"graph"` map
  with `"nodes"` and `"edges"` lists (QA / simulation shape) or a `"definitions"` list
  of such entries (solution-pack shape) is a definition. Two guards keep the discovery
  honest: every fixture path a `scripts/seed_*_definition.sh` references must have been
  discovered, and the discovered count must not collapse below the 12 known today.

  Each graph goes through `Graph.validate_graph/1`, `validate_node_attributes/1`,
  `validate_edge_conditions/1`, `validate_flow/1` and `SemanticValidation.validate/2`
  (with no declared fields, as at an unregistered-schema install), and must report zero
  violations.

  `async: true`, read-only file I/O, no clock, no randomness.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.SemanticValidation

  @root Path.expand("../../..", __DIR__)

  # [{source_path_relative_to_root, label, graph_map}]
  defp discover do
    json_files =
      Path.wildcard(Path.join(@root, "priv/**/*.json")) ++
        Path.wildcard(Path.join(@root, "test/fixtures/qa/*.json"))

    yaml_files = Path.wildcard(Path.join(@root, "test/fixtures/simulation/**/process_*.yaml"))

    decoded =
      Enum.map(json_files, &{&1, &1 |> File.read!() |> Jason.decode!()}) ++
        Enum.map(yaml_files, &{&1, YamlElixir.read_from_file!(&1)})

    Enum.flat_map(decoded, fn {path, doc} ->
      rel = Path.relative_to(path, @root)

      case doc do
        %{"definitions" => defs} when is_list(defs) ->
          for {entry, i} <- Enum.with_index(defs),
              graph?(entry),
              do: {rel, "#{rel}[#{i}]", entry["graph"], declared_of(doc)}

        doc when is_map(doc) ->
          if graph?(doc), do: [{rel, rel, doc["graph"], declared_of(doc)}], else: []

        _ ->
          []
      end
    end)
  end

  # REQ-462: check 2 (required_output_without_variable_schema) needs the definition's own
  # registered variable_schemas (QA shape: top-level `variable_schemas` with a `variable_key`),
  # as at validate/activate. Solution-pack shaped entries register none here (%{}).
  defp declared_of(%{"variable_schemas" => entries}) when is_list(entries) do
    for %{"variable_key" => key} = entry <- entries,
        is_binary(key),
        into: %{},
        do: {key, Map.get(entry, "json_schema", %{})}
  end

  defp declared_of(_doc), do: %{}

  defp graph?(%{"graph" => %{"nodes" => nodes, "edges" => edges}})
       when is_list(nodes) and is_list(edges),
       do: true

  defp graph?(_), do: false

  defp violations_for(graph_map, declared) do
    assert {:ok, graph} = Graph.from_map(graph_map)

    Graph.validate_graph(graph).violations ++
      Graph.validate_node_attributes(graph).violations ++
      Graph.validate_edge_conditions(graph).violations ++
      Graph.validate_flow(graph).violations ++
      SemanticValidation.validate(graph, declared).violations
  end

  # fixture paths named by the seed scripts
  defp seed_script_fixture_refs do
    @root
    |> Path.join("scripts/seed_*_definition.sh")
    |> Path.wildcard()
    |> Enum.flat_map(fn script ->
      ~r{test/fixtures/[A-Za-z0-9_./-]+\.json}
      |> Regex.scan(File.read!(script))
      |> List.flatten()
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  describe "discovery guards" do
    test "at least the 12 known shipped definitions (6 QA, 6 simulation) are discovered" do
      sources = discover() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      assert length(sources) >= 12,
             "discovered only #{length(sources)} definition files: #{inspect(sources)}"

      assert Enum.count(sources, &String.starts_with?(&1, "test/fixtures/qa/")) >= 6
      assert Enum.count(sources, &String.starts_with?(&1, "test/fixtures/simulation/")) >= 6
    end

    test "every fixture a scripts/seed_*_definition.sh references was discovered as a definition" do
      refs = seed_script_fixture_refs()
      assert length(refs) >= 6, "seed scripts reference only #{inspect(refs)}"

      discovered = discover() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      missing = Enum.reject(refs, &MapSet.member?(discovered, &1))

      assert missing == [],
             "seed-referenced fixtures not discovered as definitions: #{inspect(missing)}"
    end
  end

  describe "every shipped definition passes every validator" do
    test "zero violations from structural, attribute, edge-condition, flow and semantic validation" do
      failures =
        for {_source, label, graph_map, declared} <- discover(),
            violations = violations_for(graph_map, declared),
            violations != [] do
          {label, Enum.map(violations, &{&1.code, &1.message})}
        end

      assert failures == [],
             "shipped definitions failing validation:\n" <> inspect(failures, pretty: true)
    end
  end
end
