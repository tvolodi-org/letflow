defmodule Letflow.Scripts.ValidationEntityWriteTest do
  @moduledoc """
  REQ-601 / GH #3380 criterion 1 (decision 0065 D8, slice E-2 part A), pure: `Validation.manifest/2`
  for the hook kind `entity_write` and its required `derived_fields` list.
  """

  use ExUnit.Case, async: true

  alias Letflow.Scripts.Validation

  defp manifest(extra \\ %{}) do
    Map.merge(
      %{
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"amount" => %{"type" => "integer"}}
        },
        "output_schema" => %{
          "type" => "object",
          "properties" => %{"total" => %{"type" => "integer"}},
          "additionalProperties" => false
        },
        "fail_codes" => [],
        "derived_fields" => ["total"]
      },
      extra
    )
  end

  defp invalid(manifest, kind \\ "entity_write"),
    do:
      assert(
        Validation.manifest(manifest, kind) == {:error, :invalid_manifest},
        inspect(manifest)
      )

  test "T-V1 a valid entity_write manifest" do
    assert Validation.manifest(manifest(), "entity_write") == :ok
  end

  test "T-V2 a missing derived_fields is refused" do
    invalid(Map.delete(manifest(), "derived_fields"))
  end

  test "T-V3 an empty derived_fields is refused" do
    invalid(manifest(%{"derived_fields" => []}))
  end

  test "T-V4 a non-list derived_fields is refused" do
    invalid(manifest(%{"derived_fields" => "total"}))
    invalid(manifest(%{"derived_fields" => %{"total" => true}}))
  end

  test "T-V5 a duplicate entry is refused" do
    invalid(manifest(%{"derived_fields" => ["total", "total"]}))
  end

  test "T-V6 a malformed entry is refused" do
    invalid(manifest(%{"derived_fields" => ["Bad Field"]}))
    invalid(manifest(%{"derived_fields" => [1]}))
    invalid(manifest(%{"derived_fields" => [nil]}))
    invalid(manifest(%{"derived_fields" => [""]}))
  end

  test "T-V7 an over-long entry and too many entries are refused" do
    assert Validation.manifest(
             manifest(%{"derived_fields" => ["a" <> String.duplicate("b", 63)]}),
             "entity_write"
           ) == :ok

    invalid(manifest(%{"derived_fields" => ["a" <> String.duplicate("b", 64)]}))
    invalid(manifest(%{"derived_fields" => for(i <- 1..33, do: "f#{i}")}))
  end

  test "T-V8 a valid reads list stays valid for entity_write" do
    reads = [
      %{
        "name" => "r",
        "entity_type" => "customer",
        "match" => %{"id_from" => "cid"},
        "fields" => ["name"]
      }
    ]

    input_schema = %{
      "type" => "object",
      "properties" => %{"amount" => %{"type" => "integer"}, "cid" => %{"type" => "string"}}
    }

    assert Validation.manifest(
             manifest(%{"reads" => reads, "input_schema" => input_schema}),
             "entity_write"
           ) == :ok
  end

  test "T-V9 other hook kinds refuse derived_fields" do
    for kind <- ["service_task", "form_validation", "entity_event"] do
      invalid(manifest(), kind)
    end
  end

  test "T-V10 manifest/1 is unchanged" do
    assert Validation.manifest(Map.delete(manifest(), "derived_fields")) == :ok
    assert Validation.manifest(manifest()) == {:error, :invalid_manifest}
  end
end
