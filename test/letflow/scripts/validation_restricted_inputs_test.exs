defmodule Letflow.Scripts.ValidationRestrictedInputsTest do
  @moduledoc """
  Decision 0062 R6 / Q4 (GH #2616 part 3), pure: `restricted_inputs` is a list of
  `%{"name", "from"}` objects; the former list of bare names is `:invalid_manifest`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Scripts.Validation

  @pair %{"entity_type" => "customer", "field" => "salary"}

  defp manifest(restricted_inputs) do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"cid" => %{"type" => "string"}, "amount" => %{"type" => "integer"}}
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"total" => %{"type" => "integer"}},
        "additionalProperties" => false
      },
      "fail_codes" => [],
      "restricted_inputs" => restricted_inputs
    }
  end

  defp entry(name, from \\ [@pair]), do: %{"name" => name, "from" => from}

  test "the object shape is accepted" do
    assert Validation.manifest(manifest([entry("cid"), entry("amount")])) == :ok
    assert Validation.manifest(manifest([])) == :ok
  end

  test "the retired bare-name list is invalid" do
    assert Validation.manifest(manifest(["cid"])) == {:error, :invalid_manifest}
  end

  test "each violation is :invalid_manifest" do
    for bad <- [
          [entry("nope")],
          [entry("cid", [])],
          [entry("cid"), entry("cid")],
          [entry("cid", [@pair, @pair])],
          [entry("cid", [%{"entity_type" => "customer"}])],
          [entry("cid", [%{"entity_type" => "Customer", "field" => "salary"}])],
          [entry("cid", [Map.put(@pair, "extra", 1)])],
          [Map.put(entry("cid"), "extra", 1)],
          [%{"name" => "cid"}],
          "cid"
        ] do
      assert Validation.manifest(manifest(bad)) == {:error, :invalid_manifest}, inspect(bad)
    end
  end

  test "more than eight from pairs is invalid" do
    from = for i <- 1..9, do: %{"entity_type" => "customer", "field" => "f#{i}"}
    assert Validation.manifest(manifest([entry("cid", from)])) == {:error, :invalid_manifest}
  end

  describe "restricted_input_entries/1" do
    test "normalises objects, reads a legacy bare name as from: [] and drops malformed entries" do
      m = %{"restricted_inputs" => [entry("cid"), "amount", 7, %{"name" => "x"}]}

      assert Validation.restricted_input_entries(m) == [
               %{"name" => "cid", "from" => [@pair]},
               %{"name" => "amount", "from" => []}
             ]

      assert Validation.restricted_input_entries(%{}) == []
      assert Validation.restricted_input_entries(nil) == []
    end
  end
end
