defmodule Letflow.Scripts.QoimeksGenTest do
  @moduledoc """
  T-2047: synthetic dataset generator for the qoimeks-qa rehearsal. Verifies that
  `scripts/pilot/qoimeks_gen.py` produces the specified sizes and that
  `scripts/pilot/qoimeks_convert.py` accepts its output with `--allow-drops`.
  No database and no network.

  GN-1 generator exits 0 and writes three CSV files.
  GN-2 generator output has the specified sizes (666 items, 142 location nodes, 610 balance rows).
  GN-3 generator is deterministic: same seed produces identical files.
  GN-4 converter accepts generator output; expected counts are correct; G4/G8 drops appear.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @gen_script "scripts/pilot/qoimeks_gen.py"
  @convert_script "scripts/pilot/qoimeks_convert.py"
  @sys "qoimeks-rehearsal"

  setup do
    dir = Path.join(System.tmp_dir!(), "qgt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp gen(out, extra \\ []) do
    System.cmd("python3", ["-I", @gen_script, "--out", out] ++ extra, stderr_to_stdout: true)
  end

  defp convert(indir, out) do
    System.cmd(
      "python3",
      [
        "-I",
        @convert_script,
        "convert",
        "--in",
        indir,
        "--out",
        out,
        "--system",
        @sys,
        "--org-unit-ext",
        "U1",
        "--responsible-ext",
        "E1",
        "--received-on",
        "2026-01-01",
        "--allow-drops"
      ],
      stderr_to_stdout: true
    )
  end

  defp counts(out) do
    out
    |> Path.join("expected_counts.txt")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(&List.to_tuple(String.split(&1, " ")))
  end

  # Count data rows (lines excluding the header; handles \r\n and \n, strips trailing blank).
  defp csv_data_rows(path) do
    File.read!(path)
    |> String.split(~r/\r?\n/, trim: true)
    |> length()
    |> Kernel.-(1)
  end

  test "GN-1 generator exits 0 and writes three CSV files", %{dir: dir} do
    out = Path.join(dir, "in")
    assert {_, 0} = gen(out)
    assert File.exists?(Path.join(out, "locations.csv"))
    assert File.exists?(Path.join(out, "items.csv"))
    assert File.exists?(Path.join(out, "balances.csv"))
  end

  test "GN-2 generator output has the specified sizes", %{dir: dir} do
    out = Path.join(dir, "in")
    gen(out)
    # 1 warehouse + 7 zones + (20 + 6*19) racks = 142 total location nodes
    assert csv_data_rows(Path.join(out, "locations.csv")) == 142
    assert csv_data_rows(Path.join(out, "items.csv")) == 666
    # 600 positive + 3 negative + 3 zero + 4 comma-decimal quantities
    assert csv_data_rows(Path.join(out, "balances.csv")) == 610
  end

  test "GN-3 generator is deterministic: same seed produces identical files", %{dir: dir} do
    out1 = Path.join(dir, "in1")
    out2 = Path.join(dir, "in2")
    gen(out1, ["--seed", "42"])
    gen(out2, ["--seed", "42"])

    for f <- ["locations.csv", "items.csv", "balances.csv"] do
      assert File.read!(Path.join(out1, f)) == File.read!(Path.join(out2, f)), f
    end
  end

  test "GN-4 converter accepts generator output; expected counts are correct; G4 skips and G8 drops appear",
       %{dir: dir} do
    in_dir = Path.join(dir, "in")
    out_dir = Path.join(dir, "out")
    gen(in_dir)
    assert {text, 0} = convert(in_dir, out_dir)
    # G4: zero rows are skipped and negative rows are loaded; G8 comma decimals remain drops.
    assert text =~ "skipped total 3"
    assert text =~ "quantity_zero"
    refute text =~ "quantity_not_positive"
    assert text =~ "quantity_comma_decimal"
    assert text =~ "dropped total 4"
    c = counts(out_dir)
    assert c["records.location_node"] == "142"
    assert c["records.catalog_item"] == "666"
    assert c["records.catalog_uom"] == "1"
    assert c["records.stock_opening_line"] == "603"
    assert c["documents"] == "7"
  end

  defp read_csv(path), do: path |> File.read!() |> String.split(~r/\r?\n/, trim: true)

  test "GN-5 default output is unchanged by the places option being off", %{dir: dir} do
    plain = Path.join(dir, "plain")
    places = Path.join(dir, "places")
    gen(plain)
    assert {_, 0} = gen(places, ["--with-places"])
    assert hd(read_csv(Path.join(plain, "items.csv"))) == "sku,sku_name,unit"

    assert File.read!(Path.join(plain, "locations.csv")) ==
             File.read!(Path.join(places, "locations.csv"))

    # the plain run still has digits-only codes
    refute Enum.any?(tl(read_csv(Path.join(plain, "items.csv"))), &(&1 =~ ~r/^[^\d,]/))
  end

  test "GN-6 with-places adds usual places and lettered Latin and Cyrillic codes", %{dir: dir} do
    out = Path.join(dir, "in")
    assert {_, 0} = gen(out, ["--with-places"])
    [header | rows] = read_csv(Path.join(out, "items.csv"))
    assert header == "sku,sku_name,unit,home_loc,alt_loc"
    assert length(rows) == 666
    cols = Enum.map(rows, &String.split(&1, ","))
    assert Enum.count(cols, fn [_, _, _, h, _] -> h != "" end) == 222
    assert Enum.count(cols, fn [_, _, _, _, a] -> a != "" end) == 74
    skus = Enum.map(cols, &hd/1)
    assert length(Enum.uniq(skus)) == 666
    assert Enum.any?(skus, &(&1 =~ ~r/^[A-Z]{2}\d{4}$/))
    assert Enum.any?(skus, &(&1 =~ ~r/^[\x{0400}-\x{04FF}]{2}\d{4}$/u))
  end

  test "GN-7 with-places output converts with every place known", %{dir: dir} do
    in_dir = Path.join(dir, "in")
    out_dir = Path.join(dir, "out")
    gen(in_dir, ["--with-places"])
    assert {text, 0} = convert(in_dir, out_dir)
    assert text =~ "dropped total 4"
    c = counts(out_dir)
    assert c["records.catalog_item"] == "666"
    assert c["records.stock_opening_line"] == "603"
  end
end
