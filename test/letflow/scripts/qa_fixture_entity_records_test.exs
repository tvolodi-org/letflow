defmodule Letflow.Scripts.QaFixtureEntityRecordsTest do
  @moduledoc """
  GH #2942: every row of a `test/fixtures/qa/*_records.json` import payload must pass
  `Letflow.Entities.Record.Validator` for the entity definition fixture it is seeded against
  (`<prefix>_entity_definition.json`). Before the fix the production_batch rows carried
  `cost_figure` as a JSON string, which a non-strict `:decimal` field (JSON Schema `number`)
  refuses, so the import rejected every row.

  Pure: reads fixtures and calls the validator, no DB or network.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Entities.Record.Validator

  @fixture_dir Path.expand("../../fixtures/qa", __DIR__)

  @pairs (for records_path <-
                Path.wildcard(Path.join(@fixture_dir, "*_records.json")) |> Enum.sort() do
            prefix = String.replace_suffix(Path.basename(records_path), "_records.json", "")
            {prefix, records_path, Path.join(@fixture_dir, prefix <> "_entity_definition.json")}
          end)

  defp definition(path) do
    json = path |> File.read!() |> Jason.decode!()

    fields =
      for f <- json["fields"] do
        base = %{name: f["name"], type: String.to_existing_atom(f["type"])}

        Enum.reduce(
          [
            {"required", :required},
            {"queried", :queried},
            {"enum_values", :enum_values},
            {"decimal_precision", :decimal_precision},
            {"decimal_scale", :decimal_scale},
            {"decimal_strict", :decimal_strict},
            {"min", :min},
            {"max", :max},
            {"non_negative", :non_negative}
          ],
          base,
          fn {key, atom}, acc ->
            if Map.has_key?(f, key), do: Map.put(acc, atom, f[key]), else: acc
          end
        )
      end

    %{name: json["name"], display_name: json["display_name"], fields: fields}
  end

  test "the fixture pairs were found" do
    assert length(@pairs) >= 1
    assert Enum.any?(@pairs, fn {prefix, _, _} -> prefix == "vortex_production_batch" end)
  end

  for {prefix, records_path, definition_path} <- @pairs do
    test "#{prefix}: every record row validates against its entity definition" do
      assert File.exists?(unquote(definition_path))
      definition = definition(unquote(definition_path))
      rows = unquote(records_path) |> File.read!() |> Jason.decode!() |> Map.fetch!("records")
      assert rows != []

      failures =
        for row <- rows,
            {:error, violations} <- [
              Validator.normalize_record_payload(definition, row["field_values"])
            ] do
          {row["record_id"], violations}
        end

      assert failures == []
    end
  end
end
