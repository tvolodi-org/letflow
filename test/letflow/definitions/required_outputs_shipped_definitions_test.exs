defmodule Letflow.Definitions.RequiredOutputsShippedDefinitionsTest do
  @moduledoc """
  REQ-461 AC7: every process definition shipped in the repository is run through the new
  checks, so a shipped definition can never fail the new violation classes, and the count of
  new WARNINGS per definition is recorded.

  Discovery mirrors `shipped_definitions_validation_test.exs` (by STRUCTURE, not a hand
  list): every `priv/**/*.json`, `test/fixtures/qa/*.json` and
  `test/fixtures/simulation/**/process_*.yaml` that decodes to a `"graph"` map (QA /
  simulation shape) or a `"definitions"` list of such entries (solution-pack shape).

  For each definition the test runs, as the real surfaces would:
    * `Graph.validate_node_attributes/1` (CHK-25, check 1; runs at create/update/import/install)
    * `SemanticValidation.validate/2` with the definition's own registered variable_schemas
      (check 2; runs at validate and activate), taken from the fixture's `variable_schemas`
    * `SemanticValidation.decision_key_warnings/2` (check 3, a WARNING)

  and asserts ZERO new violations (codes `:invalid_required_outputs`,
  `:required_outputs_on_non_human_task`, `:required_output_without_variable_schema`). It
  prints one stable line per definition and does NOT fail on warnings:

      REQ-461 shipped-definition findings: <path> violations=<n> warnings=<n>

  `async: true`, read-only file I/O, no clock, no randomness.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.RoleBinding
  alias Letflow.Definitions.SemanticValidation

  @root Path.expand("../../..", __DIR__)
  @new_codes [
    :invalid_required_outputs,
    :required_outputs_on_non_human_task,
    :required_output_without_variable_schema
  ]
  @distinct_from_codes [
    :invalid_distinct_from,
    :distinct_from_on_non_human_task,
    :distinct_from_self_reference,
    :distinct_from_unknown_node,
    :distinct_from_not_human_task,
    :distinct_from_downstream_only
  ]

  # [{label, graph_map, declared_fields}]
  defp discover do
    json_files =
      Path.wildcard(Path.join(@root, "priv/**/*.json")) ++
        Path.wildcard(Path.join(@root, "test/fixtures/qa/*.json"))

    yaml_files = Path.wildcard(Path.join(@root, "test/fixtures/simulation/**/process_*.yaml"))

    decoded =
      Enum.map(json_files, &{&1, &1 |> File.read!() |> Jason.decode!()}) ++
        Enum.map(yaml_files, &{&1, YamlElixir.read_from_file!(&1)})

    decoded
    |> Enum.flat_map(fn {path, doc} ->
      rel = Path.relative_to(path, @root)

      case doc do
        %{"definitions" => defs} when is_list(defs) ->
          for {entry, i} <- Enum.with_index(defs),
              graph?(entry),
              do: {"#{rel}[#{i}]", entry["graph"], declared_fields(doc, entry["definition_id"])}

        doc when is_map(doc) ->
          if graph?(doc), do: [{rel, doc["graph"], declared_fields(doc, nil)}], else: []

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp graph?(%{"graph" => %{"nodes" => nodes, "edges" => edges}})
       when is_list(nodes) and is_list(edges),
       do: true

  defp graph?(_), do: false

  # QA shape: top-level `variable_schemas: [%{"variable_key", "json_schema"}]` (what POST
  # /definitions registers). Pack shape: `[%{"definition_id", "schema_name", ...}]` rows whose
  # `definition_id` is the definition's source id. Anything else registers nothing (%{}).
  defp declared_fields(%{"variable_schemas" => entries}, source_id) when is_list(entries) do
    Enum.reduce(entries, %{}, fn
      %{"variable_key" => key} = entry, acc when is_binary(key) ->
        Map.put(acc, key, Map.get(entry, "json_schema", %{}))

      %{"schema_name" => key, "definition_id" => id}, acc
      when is_binary(key) and id == source_id ->
        Map.put(acc, key, %{})

      _other, acc ->
        acc
    end)
  end

  defp declared_fields(_doc, _source_id), do: %{}

  defp findings(graph_map, label, declared) do
    assert {:ok, graph} = Graph.from_map(graph_map)

    violations =
      Enum.filter(
        Graph.validate_node_attributes(graph).violations ++
          SemanticValidation.validate(graph, declared).violations,
        &(&1.code in @new_codes)
      )

    {violations, SemanticValidation.decision_key_warnings(graph, label)}
  end

  describe "every shipped definition against the REQ-461 checks" do
    test "discovery still finds the known shipped definitions (the guard against an empty pass)" do
      labels = Enum.map(discover(), &elem(&1, 0))
      assert length(labels) >= 12, "discovered only #{inspect(labels)}"
      assert Enum.count(labels, &String.starts_with?(&1, "test/fixtures/qa/")) >= 6
      assert Enum.count(labels, &String.starts_with?(&1, "test/fixtures/simulation/")) >= 6
    end

    test "zero new violations per definition; per-definition violation and warning counts are printed, warnings never fail" do
      results =
        for {label, graph_map, declared} <- discover() do
          {violations, warnings} = findings(graph_map, label, declared)

          IO.puts(
            "REQ-461 shipped-definition findings: #{label} violations=#{length(violations)} warnings=#{length(warnings)}"
          )

          {label, violations}
        end

      failures =
        for {label, [_ | _] = violations} <- results,
            do: {label, Enum.map(violations, &{&1.code, &1.message})}

      assert failures == [],
             "shipped definitions failing the REQ-461 violation classes:\n" <>
               inspect(failures, pretty: true)
    end
  end

  describe "every shipped definition against the REQ-464 distinct_from checks" do
    test "zero distinct_from violations and zero single-member candidate pairs per definition; the counts are printed" do
      results =
        for {label, graph_map, _declared} <- discover() do
          assert {:ok, graph} = Graph.from_map(graph_map)

          violations =
            Enum.filter(
              Graph.validate_node_attributes(graph).violations,
              &(&1.code in @distinct_from_codes)
            )

          pairs = RoleBinding.single_member_pairs(graph)

          using =
            Enum.count(graph.nodes, fn node ->
              is_map(node.attributes) and Map.has_key?(node.attributes, "distinct_from")
            end)

          IO.puts(
            "REQ-464 shipped-definition findings: #{label} violations=#{length(violations)} " <>
              "candidate_pairs=#{length(pairs)} nodes_using_distinct_from=#{using}"
          )

          {label, violations, pairs}
        end

      assert length(results) >= 12

      failures =
        for {label, [_ | _] = violations, _pairs} <- results,
            do: {label, Enum.map(violations, &{&1.code, &1.message})}

      assert failures == [],
             "shipped definitions failing the REQ-464 distinct_from checks (count #{length(failures)}):
" <>
               inspect(failures, pretty: true)

      pair_failures = for {label, _v, [_ | _] = pairs} <- results, do: {label, pairs}

      assert pair_failures == [],
             "shipped definitions with single-member candidate pairs (count #{length(pair_failures)}):
" <>
               inspect(pair_failures, pretty: true)
    end
  end
end
