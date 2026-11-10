defmodule Letflow.Scripts.QoimeksRehearsalTest do
  @moduledoc """
  T-1616 (B4#11): the Qoimeks rehearsal tooling, `scripts/pilot/qoimeks_convert.py` (CSV extract -> xlsx import files,
  `headers` sub-command) and `scripts/pilot/qoimeks_compare.sh` (expected counts vs a `demo_counts.sh snapshot`).
  No database and no network; the converter output is read back with the production reader `XlsxImport`.

  CV-1..CV-9 converter, CP-1..CP-4 count comparison. CP-5 (CI path) is in `ci_backend_path_filter_test.exs`.
  The files go through the real stock import routes in `Letflow.Modules.Stock.QoimeksFilesTest` (ST-1..ST-3).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Entities.XlsxImport

  @script "scripts/pilot/qoimeks_convert.py"
  @compare "scripts/pilot/qoimeks_compare.sh"
  @fixture "test/fixtures/qoimeks_rehearsal"
  @sys "qoimeks-rehearsal"

  @loc_cols ~w(code name node_kind parent_id external_ref_system external_ref_id)
  @uom_cols ~w(code name active external_ref_system external_ref_id)
  @item_cols ~w(code name base_uom_id kind active external_ref_system external_ref_id)
  @line_cols ~w(header_id org_unit_id location_id responsible_id catalog_item_id catalog_uom_id
                quantity received_on external_ref_system external_ref_id)

  setup do
    dir = Path.join(System.tmp_dir!(), "qrt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp py(args), do: System.cmd("python3", ["-I", @script | args], stderr_to_stdout: true)

  defp convert(indir, out, extra \\ []) do
    py(
      ["convert", "--in", indir, "--out", out, "--system", @sys, "--org-unit-ext", "U1"] ++
        ["--responsible-ext", "E1", "--received-on", "2026-02-01"] ++ extra
    )
  end

  defp fields(cols), do: Enum.map(cols, &%{"name" => &1, "type" => "string"})

  # The file's rows as read by the production reader (upsert mode: the external ref pair is part of the header).
  defp read!(path, cols) do
    assert {:ok, rows} =
             XlsxImport.convert(
               File.read!(path),
               fields(cols -- ~w(external_ref_system external_ref_id)),
               upsert: true
             )

    for %{result: {:ok, entry}} = r <- rows do
      ref = Map.fetch!(entry, "external_ref")

      {r.line,
       Map.merge(entry["field_values"], %{
         "external_ref_system" => ref["system"],
         "external_ref_id" => ref["id"]
       })}
    end
  end

  defp manifest(out), do: out |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

  defp counts(out) do
    out
    |> Path.join("expected_counts.txt")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(&List.to_tuple(String.split(&1, " ")))
  end

  defp write_csvs(dir, loc, items, bals) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "locations.csv"), loc)
    File.write!(Path.join(dir, "items.csv"), items)
    File.write!(Path.join(dir, "balances.csv"), bals)
    dir
  end

  describe "convert" do
    test "CV-1 happy path: files, order, counts, reproducible bytes", %{dir: dir} do
      out = Path.join(dir, "o1")
      assert {_, 3} = convert(@fixture, out)
      assert {_, 3} = convert(@fixture, Path.join(dir, "o2"))
      m = manifest(out)

      assert m["upload_order"] == [
               "01-locations-01.xlsx",
               "02-uoms.xlsx",
               "03-items-01.xlsx",
               "04-opening-lines-01.xlsx"
             ]

      assert Enum.map(m["files"], &{&1["entity_type"], &1["rows"]}) == [
               {"location_node", 5},
               {"catalog_uom", 3},
               {"catalog_item", 6},
               {"stock_opening_line", 6}
             ]

      for f <- m["upload_order"] do
        assert File.read!(Path.join(out, f)) == File.read!(Path.join([dir, "o2", f])), f
      end

      assert {_, 0} = convert(@fixture, Path.join(dir, "o3"), ["--allow-drops"])
    end

    test "CV-2 headers equal the importer lists; fixed node_kind and kind", %{dir: dir} do
      out = Path.join(dir, "o")
      convert(@fixture, out)

      assert [{2, loc} | _] = read!(Path.join(out, "01-locations-01.xlsx"), @loc_cols)
      assert loc["node_kind"] == "location"
      assert [{2, _} | _] = read!(Path.join(out, "02-uoms.xlsx"), @uom_cols)
      assert [{2, item} | _] = read!(Path.join(out, "03-items-01.xlsx"), @item_cols)
      assert item["kind"] == "material"
      assert item["code"] == "001"
      assert [{2, line} | _] = read!(Path.join(out, "04-opening-lines-01.xlsx"), @line_cols)
      assert line["header_id"] == "QOI-HDR-01"
      assert line["org_unit_id"] == "U1"
      assert line["quantity"] == "10"
      assert line["received_on"] == "2026-01-15"
    end

    test "CV-3 parents precede children; unknown parent is a reject", %{dir: dir} do
      out = Path.join(dir, "o")
      convert(@fixture, out)

      codes =
        for {_, e} <- read!(Path.join(out, "01-locations-01.xlsx"), @loc_cols), do: e["code"]

      assert codes |> Enum.find_index(&(&1 == "WH-1")) < Enum.find_index(codes, &(&1 == "ZONE-A"))

      assert Enum.find_index(codes, &(&1 == "ZONE-A")) <
               Enum.find_index(codes, &(&1 == "SHELF-A1"))

      indir =
        write_csvs(
          Path.join(dir, "in3"),
          "loc_code,loc_name,loc_parent\nA,Sample A,\nB,Sample B,GHOST\nC,Sample C,B\n",
          "sku,sku_name,unit\n",
          "sku,loc,qty\n"
        )

      assert {out3, 3} = convert(indir, Path.join(dir, "o3"))
      assert out3 =~ "dropped locations row 2: unknown_parent"
      assert out3 =~ "dropped locations row 3: parent_rejected_or_cycle"
      assert counts(Path.join(dir, "o3"))["records.location_node"] == "1"
    end

    test "CV-4 balance drops carry constant reasons; allow-drops exits 0", %{dir: dir} do
      out = Path.join(dir, "o")
      assert {text, 3} = convert(@fixture, out)
      assert text =~ "dropped balances row 6: quantity_not_positive"
      assert text =~ "dropped balances row 7: unknown_item"

      indir =
        write_csvs(
          Path.join(dir, "in4"),
          "loc_code,loc_name,loc_parent\nL1,Sample L1,\n",
          "sku,sku_name,unit\nS1,Sample S1,pcs\n",
          "sku,loc,qty\nS1,L1,1\nS1,L1,2\nS1,NOLOC,1\nS1,L1,1,5\nS1,L1,\"1,5\"\nS1,L1,abc\n"
        )

      assert {text, 3} = convert(indir, Path.join(dir, "o4"))
      assert text =~ "row 2: duplicate_balance"
      assert text =~ "row 3: unknown_location"
      assert text =~ "row 5: quantity_comma_decimal"
      assert text =~ "row 6: quantity_invalid"
      assert {_, 0} = convert(indir, Path.join(dir, "o4b"), ["--allow-drops"])
    end

    test "CV-4b surplus fields are rejected, not truncated", %{dir: dir} do
      indir =
        write_csvs(
          Path.join(dir, "in4s"),
          "loc_code,loc_name,loc_parent\nL1,Sample L1,\n",
          "sku,sku_name,unit\nS1,Sample S1,pcs\n",
          "sku,loc,qty\nS1,L1,1,5\n"
        )

      assert {text, 3} = convert(indir, Path.join(dir, "o4s"))
      assert text =~ "dropped balances row 1: too_many_fields"
    end

    test "CV-5 splitting: 200 rows per file, 100 lines per header", %{dir: dir} do
      locs = "loc_code,loc_name,loc_parent\nL1,Sample L1,\n"
      skus = Enum.map_join(1..250, "", &"S#{&1},Sample #{&1},pcs\n")
      bals = Enum.map_join(1..230, "", &"S#{&1},L1,#{&1}\n")

      indir =
        write_csvs(
          Path.join(dir, "in5"),
          locs,
          "sku,sku_name,unit\n" <> skus,
          "sku,loc,qty\n" <> bals
        )

      out = Path.join(dir, "o5")
      assert {_, 0} = convert(indir, out)
      m = manifest(out)
      items = for %{"entity_type" => "catalog_item", "rows" => n} <- m["files"], do: n
      lines = for %{"entity_type" => "stock_opening_line", "rows" => n} <- m["files"], do: n
      assert items == [200, 50]
      assert lines == [100, 100, 30]
      assert Enum.map(m["headers"], & &1["id"]) == ["QOI-HDR-01", "QOI-HDR-02", "QOI-HDR-03"]
      assert counts(out)["documents"] == "3"
    end

    test "CV-6 expected counts equal the post-drop rows", %{dir: dir} do
      out = Path.join(dir, "o")
      convert(@fixture, out)

      assert counts(out) == %{
               "documents" => "1",
               "records.catalog_item" => "6",
               "records.catalog_uom" => "3",
               "records.location_node" => "5",
               "records.stock_opening_line" => "6"
             }
    end

    test "CV-7 --out inside the repository is refused and nothing is written; no cell text in the report",
         %{dir: dir} do
      inside = Path.join(File.cwd!(), "qrt_refused_#{System.unique_integer([:positive])}")
      assert {text, 2} = convert(@fixture, inside)
      assert text =~ "inside the repository"
      refute File.exists?(inside)

      indir =
        write_csvs(
          Path.join(dir, "in7"),
          "loc_code,loc_name,loc_parent\nL1,Sample L1,\n",
          "sku,sku_name,unit\nS1,Sentinel Customer Name,pcs\n",
          "sku,loc,qty\nS1,L1,0\n"
        )

      assert {_, 3} = convert(indir, Path.join(dir, "o7"))
      refute File.read!(Path.join([dir, "o7", "report.txt"])) =~ "Sentinel"
    end

    test "CV-9 an empty locations CSV writes no locations file", %{dir: dir} do
      indir =
        write_csvs(
          Path.join(dir, "in9"),
          "loc_code,loc_name,loc_parent\n",
          "sku,sku_name,unit\n",
          "sku,loc,qty\n"
        )

      out = Path.join(dir, "o9")
      assert {text, 0} = convert(indir, out)
      assert text =~ "no rows for location_node: no file written"
      assert counts(out)["records.location_node"] == "0"
      refute File.exists?(Path.join(out, "01-locations-01.xlsx"))
    end

    test "mapping renames extract columns; semicolon delimiter and BOM are read", %{dir: dir} do
      indir =
        write_csvs(
          Path.join(dir, "in10"),
          "﻿kod;nazvanie;roditel\nL1;Sample L1;\n",
          "sku,sku_name,unit\nS1,Sample S1,pcs\n",
          "sku,loc,qty\nS1,L1,2\n"
        )

      map = Path.join(dir, "map.json")
      File.write!(map, ~s({"kod": "loc_code", "nazvanie": "loc_name", "roditel": "loc_parent"}))
      assert {_, 0} = convert(indir, Path.join(dir, "o10"), ["--mapping", map])
      assert {out, 2} = convert(indir, Path.join(dir, "o10b"))
      assert out =~ "no column loc_code"
    end
  end

  describe "headers" do
    # Fabricated responses with the shape of the import route: results[] with line and record_id.
    defp fake_responses(out, rdir, skip \\ nil) do
      File.mkdir_p!(rdir)

      for %{"file" => f, "rows" => n} <- manifest(out)["files"],
          not String.starts_with?(f, "04-"),
          f != skip do
        results =
          for line <- 2..(n + 1),
              do: %{"line" => line, "outcome" => "created", "record_id" => Ecto.UUID.generate()}

        File.write!(
          Path.join(rdir, Path.rootname(f) <> ".json"),
          Jason.encode!(%{"results" => results})
        )
      end
    end

    test "CV-8 one body per header, one bootstrap line equal to the first file row", %{dir: dir} do
      out = Path.join(dir, "o")
      convert(@fixture, out)
      rdir = Path.join(dir, "resp")
      fake_responses(out, rdir)
      u1 = Ecto.UUID.generate()
      u2 = Ecto.UUID.generate()

      assert {_, 0} =
               py([
                 "headers",
                 "--out",
                 out,
                 "--responses",
                 rdir,
                 "--org-unit-id",
                 u1,
                 "--responsible-id",
                 u2
               ])

      body = out |> Path.join("headers/QOI-HDR-01.json") |> File.read!() |> Jason.decode!()
      assert body["kind"] == "opening"
      assert body["org_unit_id"] == u1
      assert body["external_ref_system"] == @sys
      assert body["external_ref_id"] == "QOI-HDR-01"
      assert [line] = body["lines"]
      assert line["responsible_id"] == u2

      for k <- ~w(location_id catalog_item_id catalog_uom_id),
          do: assert({:ok, _} = Ecto.UUID.cast(line[k]))

      assert [{2, first} | _] = read!(Path.join(out, "04-opening-lines-01.xlsx"), @line_cols)
      assert line["external_ref_system"] == first["external_ref_system"]
      assert line["external_ref_id"] == first["external_ref_id"]
      assert line["quantity"] == first["quantity"]
      assert line["received_on"] == first["received_on"]
    end

    test "CV-8 a missing response is exit 2; --out inside the repo is refused", %{dir: dir} do
      out = Path.join(dir, "o")
      convert(@fixture, out)
      rdir = Path.join(dir, "resp")
      fake_responses(out, rdir, "03-items-01.xlsx")
      u = Ecto.UUID.generate()

      assert {text, 2} =
               py([
                 "headers",
                 "--out",
                 out,
                 "--responses",
                 rdir,
                 "--org-unit-id",
                 u,
                 "--responsible-id",
                 u
               ])

      assert text =~ "no usable response"

      assert {_, 2} =
               py([
                 "headers",
                 "--out",
                 File.cwd!(),
                 "--responses",
                 rdir,
                 "--org-unit-id",
                 u,
                 "--responsible-id",
                 u
               ])
    end
  end

  describe "compare" do
    @snapshot """
    tenant.demo.documents 1
    tenant.demo.modules_active 3
    tenant.demo.records.catalog_item 6
    tenant.demo.records.location_node 5
    tenant.demo.records.stock_opening_line 6
    tenants 2
    """

    defp compare(dir, expected, snapshot, slug \\ "demo") do
      e = Path.join(dir, "expected.txt")
      s = Path.join(dir, "snapshot.txt")
      if expected, do: File.write!(e, expected)
      if snapshot, do: File.write!(s, snapshot)
      System.cmd("bash", [@compare, e, s, slug], stderr_to_stdout: true)
    end

    @expected """
    documents 1
    records.catalog_item 6
    records.catalog_uom 0
    records.location_node 5
    records.stock_opening_line 6
    """

    test "CP-1 equal counts exit 0 (an absent type matches an expected 0 - CP-4)", %{dir: dir} do
      assert {"OK counts equal\n", 0} = compare(dir, @expected, @snapshot)
    end

    test "CP-2 a difference is printed and exits 1", %{dir: dir} do
      snap = String.replace(@snapshot, "location_node 5", "location_node 4")
      assert {"DIFF records.location_node 5 4\n", 1} = compare(dir, @expected, snap)
    end

    test "CP-3 missing or empty file, or a wrong slug, exits 2", %{dir: dir} do
      assert {_, 2} = compare(Path.join(dir, "nope"), nil, nil)
      assert {_, 2} = compare(dir, "", @snapshot)
      assert {_, 2} = compare(dir, @expected, "")
      assert {text, 2} = compare(dir, @expected, @snapshot, "other")
      assert text =~ "modules_active"
      assert {_, 2} = compare(dir, @expected, @snapshot, "bad slug;")
    end

    test "CP-4 zero counts with the real snapshot shape", %{dir: dir} do
      assert {_, 0} = compare(dir, "records.catalog_uom 0\n", @snapshot)

      assert {"DIFF records.catalog_uom 2 0\n", 1} =
               compare(dir, "records.catalog_uom 2\n", @snapshot)
    end
  end
end
