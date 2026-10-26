defmodule Letflow.Scripts.ValidationFormValidationTest do
  @moduledoc """
  REQ-581 / GH #3298 criterion 1 (decision 0067 D9, slice F-2), pure: `Validation.manifest/2` for the
  hook kind `form_validation` (`refusal_codes`, `fields`, `fail_codes == []`, no `reads`).
  """

  use ExUnit.Case, async: true

  alias Letflow.Scripts.Validation

  defp manifest(extra \\ %{}) do
    Map.merge(
      %{
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"note" => %{"type" => "string"}}
        },
        "output_schema" => %{
          "type" => "object",
          "properties" => %{
            "ok" => %{"type" => "boolean"},
            "code" => %{"type" => "string"},
            "fields" => %{"type" => "array"}
          },
          "additionalProperties" => false
        },
        "fail_codes" => [],
        "refusal_codes" => ["too_short"],
        "fields" => ["note"]
      },
      extra
    )
  end

  defp invalid(manifest, kind \\ "form_validation"),
    do:
      assert(
        Validation.manifest(manifest, kind) == {:error, :invalid_manifest},
        inspect(manifest)
      )

  test "M1 a valid form_validation manifest" do
    assert Validation.manifest(manifest(), "form_validation") == :ok
  end

  test "M1b empty code lists are allowed" do
    assert Validation.manifest(
             manifest(%{"refusal_codes" => [], "fields" => []}),
             "form_validation"
           ) ==
             :ok
  end

  test "M2 refusal_codes missing" do
    invalid(Map.delete(manifest(), "refusal_codes"))
  end

  test "M3 fields missing" do
    invalid(Map.delete(manifest(), "fields"))
  end

  test "M4 refusal_codes not a list" do
    invalid(manifest(%{"refusal_codes" => "too_short"}))
  end

  test "M5 fields not a list" do
    invalid(manifest(%{"fields" => %{"note" => true}}))
  end

  test "M6 duplicate entries" do
    invalid(manifest(%{"refusal_codes" => ["a", "a"]}))
    invalid(manifest(%{"fields" => ["note", "note"]}))
  end

  test "M7 malformed entries" do
    invalid(manifest(%{"refusal_codes" => ["Bad-Code"]}))
    invalid(manifest(%{"refusal_codes" => [1]}))
    invalid(manifest(%{"fields" => ["Bad Field"]}))
    invalid(manifest(%{"fields" => [nil]}))
  end

  test "M8 more than 32 entries" do
    many = for i <- 1..33, do: "c#{i}"
    invalid(manifest(%{"refusal_codes" => many}))
    invalid(manifest(%{"fields" => many}))
  end

  test "M9 fail_codes must be empty" do
    invalid(manifest(%{"fail_codes" => ["x"]}))
    invalid(Map.delete(manifest(), "fail_codes"))
  end

  test "M10 and M11 a reads key, even an empty one" do
    invalid(manifest(%{"reads" => []}))

    invalid(
      manifest(%{
        "reads" => [
          %{
            "name" => "r",
            "entity_type" => "customer",
            "match" => %{"id_from" => "note"},
            "fields" => ["name"]
          }
        ]
      })
    )
  end

  test "M12 and M13 the same keys on service_task are unknown" do
    invalid(Map.delete(manifest(), "fields"), "service_task")
    invalid(Map.delete(manifest(), "refusal_codes"), "service_task")
    invalid(manifest(), "service_task")
    invalid(manifest(), "entity_event")
  end

  test "M14 manifest/1 is manifest/2 for service_task" do
    plain = Map.drop(manifest(), ["refusal_codes", "fields"])
    assert Validation.manifest(plain) == Validation.manifest(plain, "service_task")
    assert Validation.manifest(plain) == :ok
    assert Validation.manifest(manifest()) == {:error, :invalid_manifest}
    assert Validation.manifest("x", "form_validation") == {:error, :invalid_manifest}
  end
end
