defmodule Letflow.Definitions.Req462ShippedRequiredOutputsAdoptionTest do
  @moduledoc """
  REQ-462 -- the validator-side proof of the `required_outputs` adoption on the four shipped QA
  definitions (SwiftRoute "Shipment Approval", Meridian "Loan Origination", Vortex "Production
  Order Release", Vortex "Supplier Quality Deviation").

  Each definition is registered through the real `Definitions.create_with_variable_schemas/3`
  (the same path the seed scripts take) and validated through the real
  `Definitions.validate_definition_graph/2` (the surface behind `POST /definitions/:id/validate`),
  then activated (which re-runs every validator, so REQ-461 check 2 is a hard gate here).

  Pins:
    * validator status OK: `valid: true`, no violations (check 2, a VIOLATION, included);
    * REQ-461 check 3 emits NO `decision_key_not_required:` warning for any of the thirteen adopted
      node/key pairs, asserted per key and per node id;
    * the adopted set is EXACT per definition (a stray adoption, or a lost one, fails);
    * the remaining check-3 warnings are exactly the measured, deliberately unadopted ones.

  See `test/specs/REQ-462.md`. Real Postgres, `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Definitions.{Graph, SemanticValidation}
  alias Letflow.TenantFixture

  @qa Path.expand("../../fixtures/qa", __DIR__)

  # {fixture file, expected version, %{node_id => required_outputs}} -- the exact adopted set.
  @definitions %{
    swiftroute: {
      "swiftroute_process_definition.json",
      "1.7",
      %{"ops-review" => ["ops_decision"], "ceo-approval" => ["ceo_decision"]}
    },
    meridian: {
      "meridian_loan_origination_process_definition.json",
      "1.16",
      %{
        "l1-approval" => ["l1_decision"],
        "escalate-l1-approval-to-cro" => ["l1_decision"],
        "l2-approval" => ["l2_decision"],
        "escalate-l2-approval-to-ceo" => ["l2_decision"],
        "kyc-manual-review" => ["kyc_outcome"]
      }
    },
    vortex_release: {
      "vortex_production_order_release_process_definition.json",
      "1.9",
      %{
        "capacity-review" => ["capacity_decision"],
        "escalate-to-ceo" => ["capacity_decision"],
        "budget-approval" => ["budget_decision"],
        "escalate-budget-approval-to-finance-director" => ["budget_decision"]
      }
    },
    vortex_deviation: {
      "vortex_supplier_quality_deviation_process_definition.json",
      "1.7",
      %{
        "severity-classification" => ["severity"],
        "escalate-severity-classification-to-ceo" => ["severity"]
      }
    }
  }

  # The thirteen adopted {definition, node id, key} triples (REQ-462 BUILDS item 1, a..l, plus the
  # Q-1051 / GH #2395 L1 CRO escalation node, which declares the same l1_decision as l1-approval).
  @adopted [
    {:swiftroute, "ops-review", "ops_decision"},
    {:swiftroute, "ceo-approval", "ceo_decision"},
    {:meridian, "l1-approval", "l1_decision"},
    {:meridian, "escalate-l1-approval-to-cro", "l1_decision"},
    {:meridian, "l2-approval", "l2_decision"},
    {:meridian, "escalate-l2-approval-to-ceo", "l2_decision"},
    {:meridian, "kyc-manual-review", "kyc_outcome"},
    {:vortex_release, "capacity-review", "capacity_decision"},
    {:vortex_release, "escalate-to-ceo", "capacity_decision"},
    {:vortex_release, "budget-approval", "budget_decision"},
    {:vortex_release, "escalate-budget-approval-to-finance-director", "budget_decision"},
    {:vortex_deviation, "severity-classification", "severity"},
    {:vortex_deviation, "escalate-severity-classification-to-ceo", "severity"}
  ]

  # Deliberately NOT adopted (REQ-462 open_questions): they read keys of the batch's out-of-list set.
  @unadopted_meridian [
    "credit-memo-review",
    "credit-memo-escalation-review",
    "risk-assessment",
    "risk-assessment-escalation-review",
    "committee-vote-cro",
    "committee-vote-director",
    "committee-vote-ceo"
  ]

  @meridian_remaining_keys %{
    "credit_decision" => 3,
    "risk_rating" => 3,
    "committee_vote_cro" => 2,
    "committee_vote_director" => 2,
    "committee_vote_ceo" => 2
  }

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # --- helpers (no optional-argument defaults: anti-patterns.md ISS-0069) ----------------------

  defp doc!(name) do
    {file, _version, _adopted} = Map.fetch!(@definitions, name)
    @qa |> Path.join(file) |> File.read!() |> Jason.decode!()
  end

  defp expected_adopted(name), do: elem(Map.fetch!(@definitions, name), 2)

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # Registers the fixture like the seed does and returns {schema, definition}.
  defp register!(name) do
    schema = TenantFixture.provisioned_tenant!(slug_prefix: "req462v").schema_name
    doc = doc!(name)

    entries =
      Enum.map(doc["variable_schemas"], fn e ->
        %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
      end)

    assert {:ok, definition} =
             Definitions.create_with_variable_schemas(
               %{
                 name: unique("req462-def"),
                 version: doc["version"],
                 graph: doc["graph"],
                 created_by: Ecto.UUID.generate()
               },
               entries,
               prefix: schema
             )

    {schema, definition}
  end

  defp validated!(name) do
    {schema, definition} = register!(name)

    assert {:ok, result} = Definitions.validate_definition_graph(definition.id, prefix: schema)
    {schema, definition, result}
  end

  # "decision_key_not_required: <key> (definition '..', edge '..' from node '..' reads it; produced by: a, b)"
  defp warning_key(line) do
    [_, key] = Regex.run(~r/^decision_key_not_required: (\S+) /, line)
    key
  end

  defp warning_producers(line) do
    [_, ids] = Regex.run(~r/produced by: (.*)\)$/, line)
    String.split(ids, ", ")
  end

  # Check 3 is a pure function of the graph (SemanticValidation.decision_key_warnings/2); no DB.
  defp check3_lines(name) do
    doc = doc!(name)
    assert {:ok, graph} = Graph.from_map(doc["graph"])
    SemanticValidation.decision_key_warnings(graph, "req462-" <> to_string(name))
  end

  defp human_task_required_outputs(doc) do
    for %{"node_type" => "HUMAN_TASK"} = node <- doc["graph"]["nodes"],
        ro = get_in(node, ["attributes", "required_outputs"]),
        ro not in [nil, []],
        into: %{},
        do: {node["id"], ro}
  end

  # --- (1) status OK incl. check 2 ---------------------------------------------------------------

  describe "validator status OK for every changed definition" do
    for name <- [:swiftroute, :meridian, :vortex_release, :vortex_deviation] do
      test "#{name}: valid, no violation, and the definition activates (check 2 is a gate)" do
        {schema, definition, result} = validated!(unquote(name))

        assert %{valid: true, violations: []} = result

        assert {:ok, %{definition: %{status: :active}}} =
                 Definitions.activate(definition.id, prefix: schema)
      end

      test "#{name}: every adopted key has a variable_schema in the fixture (check 2 input)" do
        doc = doc!(unquote(name))
        declared = MapSet.new(doc["variable_schemas"], & &1["variable_key"])

        for {_node, keys} <- expected_adopted(unquote(name)), key <- keys do
          assert key in declared, "required_outputs key #{key} has no variable_schema"
        end
      end
    end

    test "negative control: removing the variable_schema of an adopted key makes the validator report a violation" do
      schema = TenantFixture.provisioned_tenant!(slug_prefix: "req462vn").schema_name
      doc = doc!(:swiftroute)

      entries =
        for e <- doc["variable_schemas"], e["variable_key"] != "ops_decision" do
          %{variable_key: e["variable_key"], json_schema: e["json_schema"], description: nil}
        end

      assert {:ok, definition} =
               Definitions.create_with_variable_schemas(
                 %{
                   name: unique("req462-neg"),
                   version: doc["version"],
                   graph: doc["graph"],
                   created_by: Ecto.UUID.generate()
                 },
                 entries,
                 prefix: schema
               )

      assert {:ok, %{valid: false, violations: violations}} =
               Definitions.validate_definition_graph(definition.id, prefix: schema)

      assert Enum.any?(violations, &(&1.code == :required_output_without_variable_schema))
    end
  end

  # --- (2) no check-3 warning for any adopted node / key ------------------------------------------

  describe "REQ-461 check 3 emits no decision_key_not_required: warning for an adopted pair" do
    for {name, node_id, key} <- @adopted do
      test "#{node_id} (#{key}): no warning names the key or the node as a producer" do
        lines = check3_lines(unquote(name))

        refute Enum.any?(lines, &(warning_key(&1) == unquote(key))),
               "a decision_key_not_required: warning still names #{unquote(key)}: #{inspect(lines)}"

        refute Enum.any?(lines, &(unquote(node_id) in warning_producers(&1))),
               "a decision_key_not_required: warning still names #{unquote(node_id)} as producer"
      end
    end
  end

  # --- (3) adopted set exact + remaining warning counts -------------------------------------------

  describe "the adopted set is exact" do
    for name <- [:swiftroute, :meridian, :vortex_release, :vortex_deviation] do
      test "#{name}: the HUMAN_TASK nodes declaring required_outputs are exactly the adopted ones, each == [key]" do
        assert human_task_required_outputs(doc!(unquote(name))) == expected_adopted(unquote(name))
      end
    end

    test "the thirteen adopted triples cover the four definitions exactly (a..l, plus Q-1051's L1 CRO escalation)" do
      assert length(@adopted) == 13

      by_definition =
        Enum.group_by(@adopted, &elem(&1, 0), fn {_n, node, key} -> {node, [key]} end)

      for name <- Map.keys(@definitions) do
        assert Map.new(by_definition[name]) == expected_adopted(name)
      end
    end

    test "meridian: the unadopted decision tasks declare no required_outputs (a stray adoption is caught)" do
      nodes = doc!(:meridian)["graph"]["nodes"]

      for id <- @unadopted_meridian do
        node = Enum.find(nodes, &(&1["id"] == id))
        assert node["node_type"] == "HUMAN_TASK"

        assert get_in(node, ["attributes", "required_outputs"]) in [nil, []],
               "#{id} must stay unadopted"
      end
    end

    test "vortex deviation: severity-classification and its escalation declare exactly [\"severity\"]; false_positive is not required" do
      nodes = doc!(:vortex_deviation)["graph"]["nodes"]

      for id <- ["severity-classification", "escalate-severity-classification-to-ceo"] do
        node = Enum.find(nodes, &(&1["id"] == id))
        assert node["attributes"]["required_outputs"] == ["severity"]
      end
    end

    test "swiftroute: 0 remaining decision_key_not_required: warnings" do
      assert check3_lines(:swiftroute) == []
    end

    test "vortex release: 0 remaining decision_key_not_required: warnings" do
      assert check3_lines(:vortex_release) == []
    end

    test "vortex deviation: 0 remaining decision_key_not_required: warnings" do
      assert check3_lines(:vortex_deviation) == []
    end

    test "meridian: exactly 12 remaining warnings, all for the deliberately unadopted keys, with the measured per-key counts" do
      lines = check3_lines(:meridian)

      assert length(lines) == 12

      assert lines |> Enum.map(&warning_key/1) |> Enum.frequencies() ==
               @meridian_remaining_keys

      # every remaining warning is produced by an unadopted node only
      for line <- lines, producer <- warning_producers(line) do
        assert producer in @unadopted_meridian, "#{producer} unexpectedly listed in: #{line}"
      end
    end
  end

  # --- (4) versions ----------------------------------------------------------------------------------

  describe "versions" do
    test "swiftroute 1.7, meridian 1.16, vortex release 1.9, vortex deviation 1.7" do
      for {name, {_file, version, _adopted}} <- @definitions do
        assert doc!(name)["version"] == version, "#{name} version"
      end
    end

    test "each changed definition's description says why (mentions required_outputs)" do
      for name <- Map.keys(@definitions) do
        assert doc!(name)["description"] =~ "required_outputs", "#{name} description"
      end
    end
  end
end
