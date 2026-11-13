defmodule Letflow.Modules.UpgradePlanTest do
  @moduledoc """
  REQ-768 / T-1395, the pure parts of `Letflow.Modules.UpgradePlan`: C-U (the change class and
  reason of every entity diff), H1 (`compute_hash/1` moves with each input) and L1 (the module
  reads no record, event or audit data). The route tests are in
  `test/letflow/routers/tenant_modules_upgrade_plan_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.UpgradePlan

  defp field(name, extra \\ %{}), do: Map.merge(%{"name" => name, "type" => "string"}, extra)

  defp json(fields, extra \\ %{}),
    do: Map.merge(%{"display_name" => "T", "fields" => fields, "indexes" => []}, extra)

  describe "C-U classify_entity/2" do
    test "equal after key normalisation is unchanged" do
      a = json([field("a"), field("b")])
      assert UpgradePlan.classify_entity(a, json([field("a"), field("b")])) == :unchanged
    end

    test "an optional field added is A" do
      assert {"A", "optional_field_added"} =
               UpgradePlan.classify_entity(json([field("a")]), json([field("a"), field("n")]))
    end

    test "a required field added is B" do
      new = json([field("a"), field("n", %{"required" => true})])
      assert {"B", "required_field_added"} = UpgradePlan.classify_entity(json([field("a")]), new)
    end

    test "a field removed is B" do
      assert {"B", "field_removed"} =
               UpgradePlan.classify_entity(json([field("a"), field("b")]), json([field("a")]))
    end

    test "a type change, a tightening and any other key change are B" do
      old = json([field("a")])

      assert {"B", "field_type_changed"} =
               UpgradePlan.classify_entity(old, json([field("a", %{"type" => "integer"})]))

      assert {"B", "required_tightened"} =
               UpgradePlan.classify_entity(old, json([field("a", %{"required" => true})]))

      assert {"B", "field_changed"} =
               UpgradePlan.classify_entity(old, json([field("a", %{"enum" => ["x"]})]))
    end

    test "T-1882: dropping required (and nothing else of the field) is A, other changes stay B" do
      old = json([field("a", %{"required" => true})])

      assert {"A", "required_relaxed"} = UpgradePlan.classify_entity(old, json([field("a")]))

      assert {"A", "required_relaxed"} =
               UpgradePlan.classify_entity(old, json([field("a", %{"required" => false})]))

      assert {"B", "field_changed"} =
               UpgradePlan.classify_entity(old, json([field("a", %{"enum" => ["x"]})]))

      assert {"B", "field_type_changed"} =
               UpgradePlan.classify_entity(old, json([field("a", %{"type" => "integer"})]))
    end

    test "indexes: plain add is A, unique add or any removal is B" do
      base = json([field("a")])
      idx = %{"name" => "i1", "fields" => ["a"]}

      assert {"A", "index_added"} =
               UpgradePlan.classify_entity(base, Map.put(base, "indexes", [idx]))

      assert {"B", "index_changed"} =
               UpgradePlan.classify_entity(
                 base,
                 Map.put(base, "indexes", [Map.put(idx, "unique", true)])
               )

      assert {"B", "index_changed"} =
               UpgradePlan.classify_entity(Map.put(base, "indexes", [idx]), base)
    end

    test "description alone is A, an unknown top-level key is B, the worst class wins" do
      base = json([field("a")])

      assert {"A", "metadata_changed"} =
               UpgradePlan.classify_entity(base, Map.put(base, "description", "x"))

      assert {"B", "field_changed"} =
               UpgradePlan.classify_entity(base, Map.put(base, "write_class", "x"))

      mixed = json([field("a"), field("n"), field("r", %{"required" => true})])
      assert {"B", "required_field_added"} = UpgradePlan.classify_entity(base, mixed)
    end
  end

  describe "H1 compute_hash/1" do
    @inputs %{
      "v" => 1,
      "module_id" => "stock",
      "target_version" => "0.14.0",
      "compiled_manifest_hash" => "h1",
      "upgrade_path_available" => true,
      "steps" => [],
      "entity_content" => %{"e" => "x"},
      "process_content" => %{"p@1" => "y"},
      "tenant" => %{
        "applied_version" => "0.10.0",
        "installed_manifest_hash" => "i",
        "accepted" => ["a"],
        "active_entity_definition_ids" => %{"e" => "id1"},
        "stamped_definition_ids" => ["d1"],
        "settings_hash" => "s"
      }
    }

    test "the same inputs give the same 64-hex hash, key order does not matter" do
      hash = UpgradePlan.compute_hash(@inputs)
      assert hash =~ ~r/^[0-9a-f]{64}$/
      assert hash == UpgradePlan.compute_hash(Map.new(Enum.reverse(Map.to_list(@inputs))))
    end

    test "each input class changes the hash" do
      base = UpgradePlan.compute_hash(@inputs)

      changed = [
        Map.put(@inputs, "target_version", "0.15.0"),
        Map.put(@inputs, "compiled_manifest_hash", "h2"),
        Map.put(@inputs, "upgrade_path_available", false),
        Map.put(@inputs, "steps", [%{"id" => "s1", "from" => "a", "to" => "b"}]),
        Map.put(@inputs, "entity_content", %{"e" => "z"}),
        Map.put(@inputs, "process_content", %{"p@1" => "z"}),
        put_in(@inputs, ["tenant", "applied_version"], "0.9.0"),
        put_in(@inputs, ["tenant", "installed_manifest_hash"], "j"),
        put_in(@inputs, ["tenant", "accepted"], ["a", "b"]),
        put_in(@inputs, ["tenant", "active_entity_definition_ids"], %{"e" => "id2"}),
        put_in(@inputs, ["tenant", "stamped_definition_ids"], ["d1", "d2"]),
        put_in(@inputs, ["tenant", "settings_hash"], "t")
      ]

      hashes = Enum.map(changed, &UpgradePlan.compute_hash/1)
      assert Enum.all?(hashes, &(&1 != base))
      assert length(Enum.uniq(hashes)) == length(hashes)
    end
  end

  test "L1 the module names no record, event store or audit module" do
    {:ok, source} = File.read("lib/letflow/modules/upgrade_plan.ex")
    code = source |> String.split("\n") |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    body = Enum.join(code, "\n")

    refute body =~ "Letflow.Records"
    refute body =~ "Letflow.EventStore"
    refute body =~ "Letflow.Audit"
    refute body =~ "Map.from_struct"
  end
end
