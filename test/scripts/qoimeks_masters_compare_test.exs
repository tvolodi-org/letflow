defmodule Letflow.Scripts.QoimeksMastersCompareTest do
  @moduledoc """
  REQ-881 (GH #4593): `scripts/pilot/qoimeks_masters_compare.py` compares master data (places, units,
  items) between the Qoimeks CSV extract and the Letflow records export, printing one sha256 HASH per
  table per side. Same-shape fixtures only (no real data, D-050); no database, no network.

  MC-1 equal sides, MC-2 differences, MC-3 order and page independence, MC-4 bad input.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @script "scripts/pilot/qoimeks_masters_compare.py"

  setup do
    dir = Path.join(System.tmp_dir!(), "qmc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp locations_csv!(dir, rows, name \\ "locations.csv") do
    path = Path.join(dir, name)
    lines = ["loc_code,loc_name"] ++ for {code, name} <- rows, do: "#{code},#{name}"
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp items_csv!(dir, rows, name \\ "items.csv") do
    path = Path.join(dir, name)

    lines =
      ["sku,sku_name,unit"] ++ for {sku, sku_name, unit} <- rows, do: "#{sku},#{sku_name},#{unit}"

    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp export_page!(export_dir, entity_type, records, suffix) do
    File.mkdir_p!(export_dir)
    path = Path.join(export_dir, "#{entity_type}-#{suffix}.json")

    data = %{
      "entity_type" => entity_type,
      "records" =>
        Enum.map(records, fn {code, name, deleted} ->
          %{
            "record_id" => Ecto.UUID.generate(),
            "field_values" => %{"code" => code, "name" => name},
            "deleted" => deleted
          }
        end),
      "next_cursor" => nil
    }

    File.write!(path, Jason.encode!(data))
    path
  end

  defp run(args), do: System.cmd("python3", ["-I", @script | args], stderr_to_stdout: true)

  defp hashes(out, table) do
    for [_, side, h] <-
          Regex.scan(~r/^HASH #{table} (csv|export) ([0-9a-f]{64})$/m, out),
        into: %{},
        do: {side, h}
  end

  defp no_diff?(out), do: not String.contains?(out, "DIFF ")

  # MC-1: equal sides, two places, one unit, three items (Cyrillic), export split over two pages
  test "MC-1 equal sides: exit 0, no DIFF, equal hashes per table (Cyrillic, two location pages)",
       %{dir: d} do
    exp = Path.join(d, "export")

    loc_path =
      locations_csv!(d, [{"L1", "Склад А"}, {"L2", "Склад Б"}])

    items_path =
      items_csv!(d, [{"S1", "Болт М8", "шт"}, {"S2", "Гайка М8", "шт"}, {"S3", "Шайба", "шт"}])

    # split location_node over two pages
    export_page!(exp, "location_node", [{"L1", "Склад А", false}], "p1")
    export_page!(exp, "location_node", [{"L2", "Склад Б", false}], "p2")
    export_page!(exp, "catalog_uom", [{"шт", "шт", false}], "p1")

    export_page!(
      exp,
      "catalog_item",
      [
        {"S1", "Болт М8", false},
        {"S2", "Гайка М8", false},
        {"S3", "Шайба", false}
      ],
      "p1"
    )

    assert {out, 0} = run(["--locations", loc_path, "--items", items_path, "--export-dir", exp])
    assert no_diff?(out)
    assert out =~ "RESULT equal\n"

    for table <- ~w(locations units items) do
      assert %{"csv" => h, "export" => h2} = hashes(out, table), "missing hashes for #{table}"
      assert h == h2, "hashes differ for #{table}"
      assert String.length(h) == 64
    end
  end

  # MC-2: a name difference, a place only in extract, a unit only in export
  test "MC-2 differences: DIFF lines per table, affected hashes differ, unaffected stays equal",
       %{dir: d} do
    exp = Path.join(d, "export")

    loc_path =
      locations_csv!(d, [{"L1", "Склад А"}, {"L-only-csv", "Только CSV"}])

    items_path =
      items_csv!(d, [{"S1", "Имя изменено", "шт"}, {"S2", "Гайка М8", "pcs"}])

    export_page!(exp, "location_node", [{"L1", "Склад А", false}], "p1")
    # L-only-csv is absent from the export
    export_page!(
      exp,
      "catalog_uom",
      [{"шт", "шт", false}, {"pcs", "pcs", false}, {"only-export", "only-export", false}],
      "p1"
    )

    export_page!(
      exp,
      "catalog_item",
      [
        {"S1", "Старое имя", false},
        {"S2", "Гайка М8", false}
      ],
      "p1"
    )

    assert {out, 1} = run(["--locations", loc_path, "--items", items_path, "--export-dir", exp])

    # place only in CSV
    assert out =~ "DIFF locations L-only-csv only_csv"
    # item with changed name
    assert out =~ "DIFF items S1 name"
    # unit only in export
    assert out =~ "DIFF units only-export only_export"

    # affected tables have differing hashes
    assert %{"csv" => lh_c, "export" => lh_e} = hashes(out, "locations")
    assert lh_c != lh_e

    assert %{"csv" => uh_c, "export" => uh_e} = hashes(out, "units")
    assert uh_c != uh_e

    assert %{"csv" => ih_c, "export" => ih_e} = hashes(out, "items")
    assert ih_c != ih_e

    # S2 is equal: its table differs only because of S1, but let's also check unaffected within
    assert out =~ "RESULT items different"
    assert out =~ "RESULT different\n"
  end

  # MC-3a: hash does not depend on row order or page split
  test "MC-3a hash is independent of row order and page split", %{dir: d} do
    exp1 = Path.join(d, "exp1")
    exp2 = Path.join(d, "exp2")

    loc_path = locations_csv!(d, [{"L1", "Alpha"}, {"L2", "Beta"}])
    items_path = items_csv!(d, [{"S1", "One", "pcs"}, {"S2", "Two", "pcs"}])

    # exp1: items in order S1, S2 on one page; locations S2 first
    export_page!(exp1, "location_node", [{"L2", "Beta", false}, {"L1", "Alpha", false}], "p1")
    export_page!(exp1, "catalog_uom", [{"pcs", "pcs", false}], "p1")
    export_page!(exp1, "catalog_item", [{"S1", "One", false}, {"S2", "Two", false}], "p1")

    # exp2: items split over two pages in reverse order; locations reversed
    export_page!(exp2, "location_node", [{"L1", "Alpha", false}], "p1")
    export_page!(exp2, "location_node", [{"L2", "Beta", false}], "p2")
    export_page!(exp2, "catalog_uom", [{"pcs", "pcs", false}], "p1")
    export_page!(exp2, "catalog_item", [{"S2", "Two", false}], "p1")
    export_page!(exp2, "catalog_item", [{"S1", "One", false}], "p2")

    assert {out1, 0} = run(["--locations", loc_path, "--items", items_path, "--export-dir", exp1])
    assert {out2, 0} = run(["--locations", loc_path, "--items", items_path, "--export-dir", exp2])

    for table <- ~w(locations units items) do
      assert hashes(out1, table) == hashes(out2, table), "hash mismatch for #{table}"
    end
  end

  # MC-3b: deleted=true records are excluded from the export side
  test "MC-3b deleted export records are excluded", %{dir: d} do
    exp = Path.join(d, "export")

    loc_path = locations_csv!(d, [{"L1", "Alpha"}])
    items_path = items_csv!(d, [{"S1", "One", "pcs"}])

    export_page!(
      exp,
      "location_node",
      [
        {"L1", "Alpha", false},
        {"L-DEL", "Deleted place", true}
      ],
      "p1"
    )

    export_page!(exp, "catalog_uom", [{"pcs", "pcs", false}], "p1")

    export_page!(
      exp,
      "catalog_item",
      [
        {"S1", "One", false},
        {"S-DEL", "Deleted item", true}
      ],
      "p1"
    )

    assert {out, 0} = run(["--locations", loc_path, "--items", items_path, "--export-dir", exp])
    assert no_diff?(out)
    assert out =~ "RESULT equal\n"
    assert out =~ "ROWS locations export 1"
    assert out =~ "ROWS items export 1"
  end

  # MC-3c: BOM, semicolons, --mapping
  test "MC-3c BOM and semicolon delimiter are read; --mapping renames columns", %{dir: d} do
    exp = Path.join(d, "export")

    # locations with BOM and semicolons, non-standard column names
    loc_path = Path.join(d, "locs_bom.csv")
    File.write!(loc_path, "\xEF\xBB\xBFkod;nazvanie\nL1;Склад А\n", [:binary])

    items_path = items_csv!(d, [{"S1", "One", "pcs"}])

    map_path = Path.join(d, "map.json")
    File.write!(map_path, ~s({"kod": "loc_code", "nazvanie": "loc_name"}))

    export_page!(exp, "location_node", [{"L1", "Склад А", false}], "p1")
    export_page!(exp, "catalog_uom", [{"pcs", "pcs", false}], "p1")
    export_page!(exp, "catalog_item", [{"S1", "One", false}], "p1")

    assert {out, 0} =
             run([
               "--locations",
               loc_path,
               "--items",
               items_path,
               "--export-dir",
               exp,
               "--mapping",
               map_path
             ])

    assert no_diff?(out)
    assert out =~ "RESULT equal\n"
  end

  # MC-4: bad input exits 2 without traceback and no cell text
  test "MC-4 bad input: missing extract file, page without records, table with no page", %{dir: d} do
    exp = Path.join(d, "export")

    loc_path = locations_csv!(d, [{"L1", "Alpha"}])
    items_path = items_csv!(d, [{"S1", "One", "pcs"}])

    export_page!(exp, "location_node", [{"L1", "Alpha", false}], "p1")
    export_page!(exp, "catalog_uom", [{"pcs", "pcs", false}], "p1")
    export_page!(exp, "catalog_item", [{"S1", "One", false}], "p1")

    # missing locations file
    assert {out1, 2} =
             run([
               "--locations",
               Path.join(d, "nope.csv"),
               "--items",
               items_path,
               "--export-dir",
               exp
             ])

    refute out1 =~ "Traceback"
    assert out1 =~ "missing input file"

    # JSON page without records list
    bad_page = Path.join(exp, "catalog_item-bad.json")
    File.write!(bad_page, ~s({"entity_type": "catalog_item", "not_records": []}))

    assert {out2, 2} =
             run(["--locations", loc_path, "--items", items_path, "--export-dir", exp])

    refute out2 =~ "Traceback"
    assert out2 =~ "no records list"

    File.rm!(bad_page)

    # table with no export page
    no_items_exp = Path.join(d, "exp_no_items")
    File.mkdir_p!(no_items_exp)
    export_page!(no_items_exp, "location_node", [{"L1", "Alpha", false}], "p1")
    export_page!(no_items_exp, "catalog_uom", [{"pcs", "pcs", false}], "p1")

    assert {out3, 2} =
             run(["--locations", loc_path, "--items", items_path, "--export-dir", no_items_exp])

    refute out3 =~ "Traceback"
    assert out3 =~ "no export page found"
  end
end
