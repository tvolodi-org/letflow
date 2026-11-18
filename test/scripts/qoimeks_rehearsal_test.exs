defmodule Letflow.Scripts.QoimeksRehearsalTest do
  @moduledoc """
  T-1616 (B4#11): the Qoimeks rehearsal tooling, `scripts/pilot/qoimeks_convert.py` (CSV extract -> xlsx import files,
  `headers` sub-command) and `scripts/pilot/qoimeks_compare.sh` (expected counts vs a `demo_counts.sh snapshot`).
  No database and no network; the converter output is read back with the production reader `XlsxImport`.

  CV-1..CV-9, CV-G3 (usual place, G3), CV-G4a..b (negative and zero balances, G4),
  CV-G12a..e (codes, G12) and CV-13a..c (per-file mappings and explicit blank-name fallback) converter,
  CP-1..CP-4 count comparison. CP-5 (CI path) is in `ci_backend_path_filter_test.exs`.
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
  @code_cols ~w(value kind external_ref_system external_ref_id)
  @assignment_cols ~w(code_id target_type target_id external_ref_system external_ref_id)

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

  defp write_blank_name_csvs(dir) do
    write_csvs(
      dir,
      "loc_code,loc_name,loc_parent\nL1,,\nL2,Named place,\n",
      "sku,sku_name,unit,home_loc\nS1,,pcs,\nS2,Named item,pcs,L1\nS3,Other item,pcs,\n",
      "sku,loc,qty\nS1,L1,1\nS2,L2,2\nS3,L1,3\n"
    )
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
               "04-opening-lines-01.xlsx",
               "04-opening-lines-02.xlsx"
             ]

      assert Enum.map(m["files"], &{&1["entity_type"], &1["rows"]}) == [
               {"location_node", 5},
               {"catalog_uom", 3},
               {"catalog_item", 6},
               {"stock_opening_line", 6},
               {"stock_opening_line", 1}
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

    test "CV-4 balance drops carry constant reasons; zero rows are skipped; allow-drops exits 0",
         %{dir: dir} do
      out = Path.join(dir, "o")
      assert {text, 3} = convert(@fixture, out)
      assert text =~ "skipped balances row 6: quantity_zero"
      refute text =~ "dropped balances row 6: quantity_not_positive"
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

    test "CV-G4a negative balances follow positive files in an all-negative document", %{dir: dir} do
      out = Path.join(dir, "o-g4")
      assert {_, 3} = convert(@fixture, out)
      m = manifest(out)

      assert Enum.take(m["upload_order"], -2) == [
               "04-opening-lines-01.xlsx",
               "04-opening-lines-02.xlsx"
             ]

      positive = read!(Path.join(out, "04-opening-lines-01.xlsx"), @line_cols)
      assert length(positive) == 6

      assert Enum.all?(positive, fn {_, row} ->
               Decimal.compare(Decimal.new(row["quantity"]), 0) == :gt
             end)

      assert [{2, negative}] = read!(Path.join(out, "04-opening-lines-02.xlsx"), @line_cols)
      assert negative["header_id"] == "QOI-HDR-02"
      assert negative["catalog_item_id"] == "SKU-6"
      assert negative["location_id"] == "WH-1"
      assert negative["quantity"] == "-7"
      assert negative["external_ref_id"] == "BAL:5:SKU-6:WH-1"

      assert [_, second] = m["headers"]
      assert second["id"] == "QOI-HDR-02"
      assert second["file"] == "04-opening-lines-02.xlsx"
      assert second["rows"] == 1
      assert second["bootstrap"]["quantity"] == "-7"
    end

    test "CV-G4b zero and negative-zero rows are skips, never drops or opening lines", %{dir: dir} do
      indir =
        write_csvs(
          Path.join(dir, "in-g4-zero"),
          "loc_code,loc_name,loc_parent\nL1,Sample L1,\n",
          "sku,sku_name,unit\nS1,Sample S1,pcs\n",
          "sku,loc,qty\nS1,L1,0\nS1,L1,-0\nS1,L1,-0.000\n"
        )

      out = Path.join(dir, "o-g4-zero")
      assert {text, 0} = convert(indir, out)
      report = File.read!(Path.join(out, "report.txt"))
      assert report =~ "skipped:\nskipped balances row 1: quantity_zero"
      assert report =~ "skipped balances row 2: quantity_zero"
      assert report =~ "skipped balances row 3: quantity_zero"
      assert report =~ "skipped total 3"
      assert report =~ "dropped total 0"
      refute report =~ "dropped balances"
      refute text =~ "quantity_not_positive"
      refute File.exists?(Path.join(out, "04-opening-lines-01.xlsx"))
      assert manifest(out)["headers"] == []
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
               "documents" => "2",
               "items_with_default_location" => "0",
               "records.catalog_item" => "6",
               "records.catalog_uom" => "3",
               "records.code_assignment" => "0",
               "records.code_tag" => "0",
               "records.location_node" => "5",
               "records.stock_opening_line" => "7"
             }
    end

    test "CV-G3 the usual place is carried, the second place is counted and not imported", %{
      dir: dir
    } do
      indir =
        write_csvs(
          Path.join(dir, "g3"),
          "loc_code,loc_name,loc_parent\nL1,Sample L1,\nL2,Sample L2,\n",
          "sku,sku_name,unit,home_loc,alt_loc\nA,Sample A,pcs,L1,L2\nB,Sample B,pcs,L2,\n" <>
            "C,Sample C,pcs,,\nD,Sample D,pcs,NOPE,L1\nE,Sample E,pcs,,L1\n",
          "sku,loc,qty\nA,L1,1\n"
        )

      out = Path.join(dir, "o")
      assert {text, 3} = convert(indir, out)
      # D has an unknown usual place: dropped with a constant reason, no cell text
      assert text =~ "dropped items row 4: unknown_default_location"
      refute text =~ "NOPE"
      # second places of the kept items (A and E); D is dropped and not counted
      assert text =~ "items with a second place, not imported (G3) 2"
      assert counts(out)["items_with_default_location"] == "2"
      assert counts(out)["records.catalog_item"] == "4"

      cols =
        ~w(code name base_uom_id kind active external_ref_system external_ref_id default_location_id)

      rows = read!(Path.join(out, "03-items-01.xlsx"), cols)
      by_code = Map.new(rows, fn {_, fv} -> {fv["code"], fv} end)
      assert by_code["A"]["default_location_id"] == "L1"
      assert by_code["B"]["default_location_id"] == "L2"
      refute Map.has_key?(by_code["C"], "default_location_id")
      # the second place is in no file
      refute Map.has_key?(by_code["A"], "alt_loc")
      assert Enum.sort(Map.keys(by_code["A"])) == Enum.sort(cols)
    end

    test "CV-G3b without the place columns the items file has the old header", %{dir: dir} do
      out = Path.join(dir, "o")
      convert(@fixture, out)

      rows =
        read!(
          Path.join(out, "03-items-01.xlsx"),
          ~w(code name base_uom_id kind active external_ref_system external_ref_id)
        )

      refute Enum.any?(rows, fn {_, fv} -> Map.has_key?(fv, "default_location_id") end)

      assert File.read!(Path.join(out, "report.txt")) =~
               "items with a second place, not imported (G3) 0"
    end

    test "CV-G12a item barcodes become codes and assignments in upload order", %{dir: dir} do
      indir =
        write_csvs(
          Path.join(dir, "g12a"),
          "loc_code,loc_name,loc_parent\nL1,Sample L1,\n",
          "sku,sku_name,unit,Штрихкод\nA,Sample A,pcs,4870001112223\nB,Sample B,pcs,\nC,Sample C,pcs,QR-7\n",
          "sku,loc,qty\nA,L1,1\n"
        )

      map = Path.join(dir, "g12-map.json")
      File.write!(map, ~s({"Штрихкод": "barcode"}))
      out = Path.join(dir, "o-g12a")
      assert {_, 0} = convert(indir, out, ["--mapping", map])

      assert manifest(out)["upload_order"] == [
               "01-locations-01.xlsx",
               "02-uoms.xlsx",
               "03-items-01.xlsx",
               "06-codes-01.xlsx",
               "07-code-assignments-01.xlsx",
               "04-opening-lines-01.xlsx"
             ]

      assert Enum.map(read!(Path.join(out, "06-codes-01.xlsx"), @code_cols), fn {_, r} ->
               {r["value"], r["kind"], r["external_ref_system"], r["external_ref_id"]}
             end) == [
               {"4870001112223", "barcode", @sys, "4870001112223"},
               {"QR-7", "barcode", @sys, "QR-7"}
             ]

      assert Enum.map(
               read!(Path.join(out, "07-code-assignments-01.xlsx"), @assignment_cols),
               fn {_, r} ->
                 {r["code_id"], r["target_type"], r["target_id"], r["external_ref_system"],
                  r["external_ref_id"]}
               end
             ) == [
               {"4870001112223", "catalog_item", "A", @sys, "4870001112223"},
               {"QR-7", "catalog_item", "C", @sys, "QR-7"}
             ]

      assert counts(out)["records.code_tag"] == "2"
      assert counts(out)["records.code_assignment"] == "2"
    end

    test "CV-G12b without code inputs only the two zero count lines are added", %{dir: dir} do
      # Fixed pre-REQ-852 converter: compare on positive balances only, so the later REQ-837
      # negative-file and zero-skip rules do not obscure the G12 comparison.
      indir =
        write_csvs(
          Path.join(dir, "in-g12b"),
          File.read!(Path.join(@fixture, "locations.csv")),
          File.read!(Path.join(@fixture, "items.csv")),
          "sku,loc,qty,as_of\n001,SHELF-A1,10,2026-01-15\n002,SHELF-A1,5.5,\n"
        )

      baseline = Path.join(dir, "baseline/scripts/pilot/qoimeks_convert.py")
      File.mkdir_p!(Path.dirname(baseline))
      {source, 0} = System.cmd("git", ["show", "f83e6ccaf:scripts/pilot/qoimeks_convert.py"])
      File.write!(baseline, source)
      old_out = Path.join(dir, "old")
      new_out = Path.join(dir, "new")

      args = [
        "convert",
        "--in",
        indir,
        "--out",
        old_out,
        "--system",
        @sys,
        "--org-unit-ext",
        "U1",
        "--responsible-ext",
        "E1",
        "--received-on",
        "2026-02-01"
      ]

      assert {_, 0} = System.cmd("python3", ["-I", baseline | args], stderr_to_stdout: true)
      assert {_, 0} = convert(indir, new_out)
      old_manifest = manifest(old_out)
      new_manifest = manifest(new_out)
      assert Map.fetch!(new_manifest, "blank_name_fallback") == nil
      assert Map.delete(new_manifest, "blank_name_fallback") == old_manifest

      for name <- Enum.map(old_manifest["files"], & &1["file"]) do
        assert File.read!(Path.join(new_out, name)) == File.read!(Path.join(old_out, name)), name
      end

      refute File.exists?(Path.join(new_out, "06-codes-01.xlsx"))
      refute File.exists?(Path.join(new_out, "07-code-assignments-01.xlsx"))

      for name <- ["expected_counts.txt", "report.txt"] do
        old_lines = old_out |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
        new_lines = new_out |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
        assert new_lines -- old_lines == ["records.code_assignment 0", "records.code_tag 0"], name
      end
    end

    test "CV-G12c codes.csv adds SKU and place codes and de-duplicates an item barcode", %{
      dir: dir
    } do
      indir =
        write_csvs(
          Path.join(dir, "g12c"),
          "loc_code,loc_name,loc_parent\nL1,Sample L1,\n",
          "sku,sku_name,unit,barcode\nA,Sample A,pcs,4870001112223\nB,Sample B,pcs,\n",
          "sku,loc,qty\n"
        )

      File.write!(Path.join(indir, "codes.csv"), """
      object_type,object_code,code_type,code
      sku,A,ean13,4870001112223
      sku,B,qr, QR-B
      location,L1,code128,LOC-L1
      """)

      out = Path.join(dir, "o-g12c")
      assert {_, 0} = convert(indir, out)
      codes = read!(Path.join(out, "06-codes-01.xlsx"), @code_cols)

      assert Enum.map(codes, fn {_, r} -> {r["value"], r["kind"]} end) == [
               {"4870001112223", "barcode"},
               {"QR-B", "qr"},
               {"LOC-L1", "barcode"}
             ]

      assignments = read!(Path.join(out, "07-code-assignments-01.xlsx"), @assignment_cols)

      assert Enum.map(assignments, fn {_, r} ->
               {r["code_id"], r["target_type"], r["target_id"]}
             end) == [
               {"4870001112223", "catalog_item", "A"},
               {"QR-B", "catalog_item", "B"},
               {"LOC-L1", "location_node", "L1"}
             ]
    end

    test "CV-G12d code drops have constant reasons, row numbers and no cell text", %{dir: dir} do
      indir =
        write_csvs(
          Path.join(dir, "g12d"),
          "loc_code,loc_name,loc_parent\nL1,Sample L1,\n",
          "sku,sku_name,unit,barcode\nA,Sample A,pcs,SHARED\nB,Sample B,pcs,\n",
          "sku,loc,qty\n"
        )

      File.write!(Path.join(indir, "codes.csv"), """
      object_type,object_code,code_type,code
      sku,A,ean13,BAD CODE
      sku,A,ean14,UNKNOWN-TYPE
      pallet,A,ean13,PALLET-CODE
      sku,MISSING,ean13,MISSING-ITEM-CODE
      location,MISSING,ean13,MISSING-LOC-CODE
      sku,B,ean13,SHARED
      sku,A,ean13,BAD\tCODE
      sku,B,qr,QR-SURVIVOR
      """)

      out = Path.join(dir, "o-g12d")
      assert {_, 3} = convert(indir, out)
      assert {_, 0} = convert(indir, Path.join(dir, "o-g12d-allow"), ["--allow-drops"])
      report = File.read!(Path.join(out, "report.txt"))

      for {row, reason} <- [
            {1, "code_invalid"},
            {2, "code_type_unknown"},
            {3, "code_object_type_unknown"},
            {4, "code_unknown_item"},
            {5, "code_unknown_location"},
            {6, "code_taken"},
            {7, "code_invalid"}
          ] do
        assert report =~ "dropped codes row #{row}: #{reason}"
      end

      for secret <- ~w(BAD UNKNOWN-TYPE PALLET-CODE MISSING-ITEM-CODE MISSING-LOC-CODE SHARED) do
        refute report =~ secret
      end

      codes = read!(Path.join(out, "06-codes-01.xlsx"), @code_cols)
      assert Enum.map(codes, fn {_, r} -> r["value"] end) == ["SHARED", "QR-SURVIVOR"]

      assignments = read!(Path.join(out, "07-code-assignments-01.xlsx"), @assignment_cols)

      assert Enum.map(assignments, fn {_, r} -> {r["code_id"], r["target_id"]} end) == [
               {"SHARED", "A"},
               {"QR-SURVIVOR", "B"}
             ]
    end

    test "CV-G12e 201 codes split both code file types at 200 rows", %{dir: dir} do
      indir =
        write_csvs(
          Path.join(dir, "g12e"),
          "loc_code,loc_name,loc_parent\nL1,Sample L1,\n",
          "sku,sku_name,unit\nA,Sample A,pcs\n",
          "sku,loc,qty\n"
        )

      File.write!(Path.join(indir, "codes.csv"), """
      object_type,object_code,code_type,code
      #{Enum.map_join(1..201, "\n", &"sku,A,ean13,CODE-#{&1}")}
      """)

      out = Path.join(dir, "o-g12e")
      assert {_, 0} = convert(indir, out)
      m = manifest(out)

      for type <- ["code_tag", "code_assignment"] do
        assert Enum.map(m["files"], fn f -> if f["entity_type"] == type, do: f["rows"] end)
               |> Enum.reject(&is_nil/1) == [200, 1]
      end

      assert length(read!(Path.join(out, "06-codes-01.xlsx"), @code_cols)) == 200
      assert length(read!(Path.join(out, "06-codes-02.xlsx"), @code_cols)) == 1
      assert length(read!(Path.join(out, "07-code-assignments-01.xlsx"), @assignment_cols)) == 200
      assert length(read!(Path.join(out, "07-code-assignments-02.xlsx"), @assignment_cols)) == 1
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

      assert {_, 0} = convert(indir, Path.join(dir, "o7"))
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

    test "CV-13a per-file mapping separates equal names and accepts a flat location list", %{
      dir: dir
    } do
      indir =
        write_csvs(
          Path.join(dir, "in13a"),
          "code,name,active\nL1,Place One,true\n",
          "code,name,unit,active,location_code,alt_location_code\nS1,Item One,pcs,true,L1,\n",
          "sku_code,location_code,qty\nS1,L1,2\n"
        )

      File.write!(Path.join(indir, "codes.csv"), "object,target,format,value\nsku,S1,ean13,C-1\n")

      map = Path.join(dir, "map13a.json")

      File.write!(
        map,
        Jason.encode!(%{
          "locations" => %{"code" => "loc_code", "name" => "loc_name"},
          "items" => %{
            "code" => "sku",
            "name" => "sku_name",
            "location_code" => "home_loc",
            "alt_location_code" => "alt_loc"
          },
          "balances" => %{"sku_code" => "sku", "location_code" => "loc"},
          "codes" => %{
            "object" => "object_type",
            "target" => "object_code",
            "format" => "code_type",
            "value" => "code"
          }
        })
      )

      out = Path.join(dir, "o13a")
      assert {_, 0} = convert(indir, out, ["--mapping", map])
      assert [{2, location}] = read!(Path.join(out, "01-locations-01.xlsx"), @loc_cols)
      assert location["code"] == "L1"
      assert location["name"] == "Place One"
      assert Map.get(location, "parent_id", "") == ""

      item_cols = @item_cols ++ ~w(default_location_id)
      assert [{2, item}] = read!(Path.join(out, "03-items-01.xlsx"), item_cols)
      assert item["code"] == "S1"
      assert item["name"] == "Item One"
      assert item["default_location_id"] == "L1"
      assert [{2, line}] = read!(Path.join(out, "04-opening-lines-01.xlsx"), @line_cols)
      assert line["catalog_item_id"] == "S1"
      assert line["location_id"] == "L1"
      assert line["quantity"] == "2"
      assert [{2, code}] = read!(Path.join(out, "06-codes-01.xlsx"), @code_cols)
      assert code["value"] == "C-1"
      assert code["kind"] == "barcode"
      assert Map.fetch!(manifest(out), "blank_name_fallback") == nil
    end

    test "CV-13b blank-name fallback is off by default and existing drops still cascade", %{
      dir: dir
    } do
      indir = write_blank_name_csvs(Path.join(dir, "in13b"))
      out = Path.join(dir, "o13b")
      assert {report, 3} = convert(indir, out)
      assert report =~ "dropped locations row 1: missing_name"
      assert report =~ "dropped items row 1: missing_name"
      assert report =~ "dropped items row 2: unknown_default_location"
      assert report =~ "dropped balances row 1: unknown_item"
      assert report =~ "dropped balances row 2: unknown_item"
      assert report =~ "dropped balances row 3: unknown_location"
      refute report =~ "blank names replaced by code:"
      assert Map.fetch!(manifest(out), "blank_name_fallback") == nil
    end

    test "CV-13c blank-name fallback uses codes and reports only counts and row numbers", %{
      dir: dir
    } do
      indir = write_blank_name_csvs(Path.join(dir, "in13c"))
      out = Path.join(dir, "o13c")
      assert {_, 0} = convert(indir, out, ["--blank-name-fallback", "code"])
      report = File.read!(Path.join(out, "report.txt"))
      assert report =~ "blank names replaced by code: 2"
      assert report =~ "blank name replaced by code locations row 1"
      assert report =~ "blank name replaced by code items row 1"
      assert report =~ "dropped total 0"
      refute report =~ "L1"
      refute report =~ "S1"
      assert Map.fetch!(manifest(out), "blank_name_fallback") == "code"
      assert counts(out)["records.location_node"] == "2"
      assert counts(out)["records.catalog_item"] == "3"
      assert counts(out)["records.stock_opening_line"] == "3"

      locations = read!(Path.join(out, "01-locations-01.xlsx"), @loc_cols)
      assert Enum.any?(locations, fn {_, row} -> row["code"] == "L1" and row["name"] == "L1" end)

      items =
        read!(Path.join(out, "03-items-01.xlsx"), @item_cols ++ ~w(default_location_id))

      assert Enum.any?(items, fn {_, row} -> row["code"] == "S1" and row["name"] == "S1" end)
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

    test "CP-G3 the usual-place count is compared like a record count", %{dir: dir} do
      expected = "items_with_default_location 2\n"
      snap = @snapshot <> "tenant.demo.items_with_default_location 2\n"
      assert {"OK counts equal\n", 0} = compare(dir, expected, snap)
      assert {"DIFF items_with_default_location 2 0\n", 1} = compare(dir, expected, @snapshot)
    end

    test "CP-4 zero counts with the real snapshot shape", %{dir: dir} do
      assert {_, 0} = compare(dir, "records.catalog_uom 0\n", @snapshot)

      assert {"DIFF records.catalog_uom 2 0\n", 1} =
               compare(dir, "records.catalog_uom 2\n", @snapshot)
    end
  end
end
