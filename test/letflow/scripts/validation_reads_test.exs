defmodule Letflow.Scripts.ValidationReadsTest do
  @moduledoc """
  GH 2534 PR 7b-2a, design `lib/letflow/design/gh2534-7b2a-script-policy.md` sections 3.1 and 4
  (pure, no DB):

    * AC8: the `reads` shape rules (each violation `:invalid_manifest`), including the reserved
      `"reads"` input property and the 200-row cap.
    * AC11b: `"id"` refused in `fields`, `restricted_fields` and `match.field`.
    * AC10: stored-test-case and dry-run `reads` fixtures (unknown read name, extra row key, too
      many rows, oversize, fixture without declared reads), and the input the script sees.
  """

  use ExUnit.Case, async: true

  alias Letflow.Scripts.Validation

  @input %{
    "type" => "object",
    "properties" => %{
      "cid" => %{"type" => "string"},
      "tier" => %{"type" => "string"},
      "n" => %{"type" => "integer"},
      "obj" => %{"type" => "object"}
    }
  }

  @by_id %{
    "name" => "cust",
    "entity_type" => "customer",
    "match" => %{"id_from" => "cid"},
    "fields" => ["name", "tier"]
  }

  @by_field %{
    "name" => "peers",
    "entity_type" => "customer",
    "match" => %{"field" => "tier", "value_from" => "tier"},
    "fields" => ["name"],
    "restricted_fields" => ["name"],
    "limit" => 5
  }

  defp manifest(reads, input \\ @input) do
    %{
      "input_schema" => input,
      "output_schema" => %{"type" => "object"},
      "fail_codes" => ["missing"],
      "reads" => reads
    }
  end

  defp case_with(reads),
    do: %{
      "name" => "c",
      "input" => %{"cid" => "x"},
      "expect" => %{"output" => %{}},
      "reads" => reads
    }

  describe "AC8: reads shape" do
    test "valid id and equality reads, an empty list and an absent key are accepted" do
      assert Validation.manifest(manifest([@by_id, @by_field])) == :ok
      assert Validation.manifest(manifest([])) == :ok
      assert Validation.manifest(Map.delete(manifest([]), "reads")) == :ok

      # the id match may carry limit 1 explicitly
      assert Validation.manifest(manifest([Map.put(@by_id, "limit", 1)])) == :ok

      # "reads" as an input property is only reserved when reads are declared
      reserved = put_in(@input, ["properties", "reads"], %{"type" => "object"})
      assert Validation.manifest(manifest([], reserved)) == :ok
    end

    test "every shape violation is invalid_manifest" do
      over_row_cap =
        for i <- 1..5, do: Map.merge(@by_field, %{"name" => "r#{i}", "limit" => 50})

      reserved = put_in(@input, ["properties", "reads"], %{"type" => "object"})

      cases = [
        {"reads not a list", %{"x" => @by_id}},
        {"entry not a map", ["cust"]},
        {"unknown entry key", [Map.put(@by_id, "where", %{})]},
        {"missing fields", [Map.delete(@by_id, "fields")]},
        {"missing match", [Map.delete(@by_id, "match")]},
        {"bad name", [Map.put(@by_id, "name", "Cust")]},
        {"duplicate names", [@by_id, Map.put(@by_field, "name", "cust")]},
        {"bad entity type", [Map.put(@by_id, "entity_type", "customer-x")]},
        {"empty fields", [Map.put(@by_id, "fields", [])]},
        {"duplicate fields", [Map.put(@by_id, "fields", ["name", "name"])]},
        {"65 fields", [Map.put(@by_id, "fields", for(i <- 1..65, do: "f#{i}"))]},
        {"bad field name", [Map.put(@by_id, "fields", ["Name"])]},
        {"restricted not a subset", [Map.put(@by_field, "restricted_fields", ["tier"])]},
        {"unknown match key", [Map.put(@by_id, "match", %{"id_from" => "cid", "x" => 1})]},
        {"both match kinds",
         [
           Map.put(@by_field, "match", %{
             "id_from" => "cid",
             "field" => "tier",
             "value_from" => "tier"
           })
         ]},
        {"id_from not an input property", [Map.put(@by_id, "match", %{"id_from" => "nope"})]},
        {"id_from not a string property", [Map.put(@by_id, "match", %{"id_from" => "n"})]},
        {"value_from an object property",
         [Map.put(@by_field, "match", %{"field" => "tier", "value_from" => "obj"})]},
        {"value_from not an input property",
         [Map.put(@by_field, "match", %{"field" => "tier", "value_from" => "nope"})]},
        {"equality match without limit", [Map.delete(@by_field, "limit")]},
        {"limit 0", [Map.put(@by_field, "limit", 0)]},
        {"limit 51", [Map.put(@by_field, "limit", 51)]},
        {"non-integer limit", [Map.put(@by_field, "limit", "5")]},
        {"id match with limit 2", [Map.put(@by_id, "limit", 2)]},
        {"nine entries", for(i <- 1..9, do: Map.put(@by_id, "name", "r#{i}"))},
        {"row caps over 200", over_row_cap}
      ]

      for {label, reads} <- cases do
        assert Validation.manifest(manifest(reads)) == {:error, :invalid_manifest}, label
      end

      assert Validation.manifest(manifest([@by_id], reserved)) == {:error, :invalid_manifest},
             "reserved reads input property"
    end
  end

  describe "AC11b: \"id\" is never a read field name" do
    test "in fields, restricted_fields or match.field" do
      for reads <- [
            [Map.put(@by_id, "fields", ["id", "name"])],
            [Map.merge(@by_field, %{"fields" => ["name", "id"], "restricted_fields" => ["id"]})],
            [Map.put(@by_field, "match", %{"field" => "id", "value_from" => "tier"})]
          ] do
        assert Validation.manifest(manifest(reads)) == {:error, :invalid_manifest},
               inspect(reads)
      end
    end
  end

  describe "AC10: reads fixtures" do
    test "a valid fixture is accepted on a stored case; an absent declared read becomes []" do
      m = manifest([@by_id, @by_field])

      fixture = %{
        "cust" => [%{"id" => "r1", "name" => "Ann", "tier" => "gold"}],
        "peers" => [%{"name" => "Bob"}, %{"id" => "r3"}]
      }

      assert Validation.test_cases([case_with(fixture)], m) == :ok
      assert Validation.test_cases([case_with(%{})], m) == :ok

      assert Validation.with_reads(%{"cid" => "x"}, %{"cust" => [%{"name" => "Ann"}]}, m) ==
               %{"cid" => "x", "reads" => %{"cust" => [%{"name" => "Ann"}], "peers" => []}}

      assert Validation.with_reads(%{"cid" => "x"}, nil, m) ==
               %{"cid" => "x", "reads" => %{"cust" => [], "peers" => []}}

      # no declared reads: the input is passed unchanged (7b-1)
      assert Validation.with_reads(%{"cid" => "x"}, nil, manifest([])) == %{"cid" => "x"}
    end

    test "unknown read name, extra row key, too many rows, oversize, non-list rows and a fixture without declared reads are refused" do
      m = manifest([@by_id, @by_field])
      big = String.duplicate("a", 17_000)

      for {label, fixture} <- [
            {"unknown read name", %{"other" => []}},
            {"extra row key", %{"cust" => [%{"ssn" => "1"}]}},
            {"too many rows (id read caps at 1)", %{"cust" => [%{"id" => "1"}, %{"id" => "2"}]}},
            {"too many rows (limit 5)", %{"peers" => for(i <- 1..6, do: %{"id" => "#{i}"})}},
            {"oversize", %{"peers" => [%{"name" => big}]}},
            {"rows not a list", %{"cust" => %{"id" => "1"}}},
            {"row not an object", %{"cust" => ["r1"]}},
            {"fixture not an object", ["cust"]}
          ] do
        assert Validation.test_cases([case_with(fixture)], m) == {:error, :invalid_test_case},
               label

        assert Validation.dry_run_input(%{"cid" => "x"}, fixture, m) == {:error, :invalid_input},
               label
      end

      none = manifest([])

      assert Validation.test_cases([case_with(%{})], none) == {:error, :invalid_test_case}
      assert Validation.dry_run_input(%{"cid" => "x"}, %{}, none) == {:error, :invalid_input}

      # a fifth key is still refused
      assert Validation.test_cases([Map.put(case_with(%{}), "extra", 1)], m) ==
               {:error, :invalid_test_case}
    end

    test "dry-run input: no fixture is allowed, a valid fixture is allowed, the input schema still applies" do
      m = manifest([@by_id])

      assert Validation.dry_run_input(%{"cid" => "x"}, nil, m) == :ok
      assert Validation.dry_run_input(%{"cid" => "x"}, %{"cust" => [%{"id" => "1"}]}, m) == :ok
      assert Validation.dry_run_input(%{"cid" => 1}, nil, m) == {:error, :invalid_input}
      assert Validation.dry_run_input("x", nil, m) == {:error, :invalid_input}
    end
  end
end
