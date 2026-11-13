defmodule Letflow.Modules.Exam.ExamPackNoStrictDecimalTest do
  @moduledoc """
  GH #2775 (follow-up to #2654, decision 0060), surface X7: the exam runtime readers
  (`certificate_public_projection`, `session`, `snapshot`, `certificate`, `anti_cheat`) and the
  in-process `catalog_items` / `org` lookups return stored `field_values` without
  `Decimals.render_field_values/2`. That is only correct while no pack field of those types is
  `decimal_strict`: the managed runtime types cannot change strictness (`Stamp`), and
  `certificate.score_pct` is a number on purpose (decision 0060, "Why not always-string").

  This is a structural guard: it fails if someone flips a pack field to strict without revisiting
  those readers.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  # MES plan U1 (owner A.6): the three physical attributes of a catalog item are strict decimals
  # on purpose (exact strings, scale 9). The readers named above were revisited: a strict field
  # holds only the canonical string written by the strict path (gh2654 design, D10), so returning
  # the stored `field_values` as is yields the same string `render_field_values/2` would. Nothing in
  # the exam runtime reads these fields. Any other strict field still fails this guard.
  @allowed_strict MapSet.new([
                    {"catalog_item", "density_kg_per_l"},
                    {"catalog_item", "net_mass_kg"},
                    {"catalog_item", "net_volume_l"}
                  ])

  @modules_dir Path.join([File.cwd!(), "priv", "modules"])

  defp fields_of(module_dir) do
    for file <-
          Path.wildcard(Path.join([@modules_dir, module_dir, "entity_definitions", "*.json"])),
        definition = file |> File.read!() |> Jason.decode!(),
        field <- Map.get(definition, "fields", []) do
      {Map.fetch!(definition, "name"), field}
    end
  end

  for module_dir <- ~w(exam catalog_items org) do
    test "no #{module_dir} pack field is decimal_strict" do
      fields = fields_of(unquote(module_dir))
      assert fields != [] or unquote(module_dir) != "exam"

      strict = for {type, %{"decimal_strict" => true} = f} <- fields, do: {type, f["name"]}
      assert Enum.reject(strict, &MapSet.member?(@allowed_strict, &1)) == []
    end
  end

  test "certificate.score_pct is a plain (non-strict) decimal, so to_float in the public projection is right" do
    score_pct =
      for {"certificate", %{"name" => "score_pct"} = f} <- fields_of("exam"), do: f

    assert [%{"type" => "decimal"} = field] = score_pct
    refute Map.get(field, "decimal_strict", false)
  end
end
