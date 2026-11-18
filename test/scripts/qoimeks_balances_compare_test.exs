defmodule Letflow.Scripts.QoimeksBalancesCompareTest do
  @moduledoc """
  T-2024 (RH-7): `scripts/pilot/qoimeks_balances_compare.py` compares the Letflow stock balances xlsx export with the
  Qoimeks `balances.csv` per item and place and prints one hash of the sorted (item, place, quantity) list per side.
  Same-shape fixtures only (no real data, D-050); the xlsx is written with Elixlsx, the library of the real export.
  No database, no network.

  BC-1 equal, BC-2 quantity difference, BC-3 only on one side, BC-4 hash independent of row order and lot split,
  BC-5 non-positive rows, BC-6 names, BC-7 bad input, BC-8 a complete multi-page JSON export, BC-9 an incomplete
  JSON page sequence.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Elixlsx.{Sheet, Workbook}

  @script "scripts/pilot/qoimeks_balances_compare.py"
  @header ~w(sku location org_unit responsible lot unit_ref quantity last_posting_seq)

  setup do
    dir = Path.join(System.tmp_dir!(), "qbc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp xlsx!(dir, rows, name \\ "x.xlsx") do
    body = for {sku, loc, qty} <- rows, do: [sku, loc, "OU", "E", "", "pcs", qty, 1]

    wb = %Workbook{
      sheets: [
        %Sheet{name: "balances", rows: [@header | body]},
        %Sheet{name: "report", rows: [["key", "value"]]}
      ]
    }

    path = Path.join(dir, name)
    {:ok, _} = Elixlsx.write_to(wb, path)
    path
  end

  defp csv!(dir, lines, name \\ "balances.csv") do
    path = Path.join(dir, name)
    File.write!(path, Enum.join(["sku,loc,qty,as_of" | lines], "\n") <> "\n")
    path
  end

  defp json_page!(dir, rows, next_cursor, name) do
    File.mkdir_p!(dir)

    body = %{
      "rows" =>
        Enum.map(rows, fn {sku, loc, qty} ->
          %{"sku" => sku, "location" => loc, "quantity" => qty}
        end),
      "next_cursor" => next_cursor
    }

    path = Path.join(dir, name)
    File.write!(path, Jason.encode!(body))
    path
  end

  defp run(args), do: System.cmd("python3", ["-I", @script | args], stderr_to_stdout: true)

  defp hashes(out) do
    for [_, side, h] <- Regex.scan(~r/^HASH (csv|xlsx|letflow) ([0-9a-f]{64})$/m, out),
        into: %{},
        do: {side, h}
  end

  test "BC-1 equal sides: exit 0, no DIFF, equal hashes (numbers and text cells, 3 decimals)", %{
    dir: d
  } do
    x = xlsx!(d, [{"001", "SHELF-A1", 10}, {"002", "SHELF-A1", 5.5}, {"003", "SHELF-B1", 0.125}])
    c = csv!(d, ["001,SHELF-A1,10,2026-01-15", "002,SHELF-A1,5.500,", "003,SHELF-B1,0.125,"])
    assert {out, 0} = run(["--xlsx", x, "--csv", c])
    refute out =~ "DIFF"
    assert out =~ "RESULT equal"
    assert %{"csv" => h, "xlsx" => h2} = hashes(out)
    assert h == h2
  end

  test "BC-2 a quantity difference is reported, hashes differ, exit 1", %{dir: d} do
    x = xlsx!(d, [{"001", "SHELF-A1", 10}, {"002", "SHELF-A1", 5}])
    c = csv!(d, ["001,SHELF-A1,10,", "002,SHELF-A1,5.5,"])
    assert {out, 1} = run(["--xlsx", x, "--csv", c])
    assert out =~ "DIFF quantity 002 SHELF-A1 csv=5.5 xlsx=5"
    assert out =~ "RESULT different"
    assert %{"csv" => a, "xlsx" => b} = hashes(out)
    assert a != b
  end

  test "BC-3 a row on one side only is reported on that side", %{dir: d} do
    x = xlsx!(d, [{"001", "SHELF-A1", 10}, {"009", "ZONE-B", 1}])
    c = csv!(d, ["001,SHELF-A1,10,", "004,ZONE-B,3,"])
    assert {out, 1} = run(["--xlsx", x, "--csv", c])
    assert out =~ "DIFF only_csv 004 ZONE-B csv=3 xlsx=-"
    assert out =~ "DIFF only_xlsx 009 ZONE-B csv=- xlsx=1"
    refute out =~ "DIFF quantity"
  end

  test "BC-4 hash ignores row order; lots of one item and place are summed", %{dir: d} do
    x = xlsx!(d, [{"002", "B", 2}, {"001", "A", 4}, {"001", "A", 6}])
    c = csv!(d, ["001,A,10,", "002,B,2,"])
    assert {out, 0} = run(["--xlsx", x, "--csv", c])
    assert out =~ "ROWS xlsx 2"
    # the hash is over the sorted lines "item TAB place TAB quantity"
    expected = :crypto.hash(:sha256, "001\tA\t10\n002\tB\t2\n") |> Base.encode16(case: :lower)
    assert %{"csv" => ^expected, "xlsx" => ^expected} = hashes(out)
  end

  test "BC-8 all rows of two JSON pages equal the same 60-row CSV", %{dir: d} do
    rows = for n <- 1..60, do: {"SKU-#{n}", "LOC-A", "#{n}.25"}
    {first, second} = Enum.split(rows, 50)
    pages = Path.join(d, "pages")
    json_page!(pages, first, "page-2", "page-001.json")
    json_page!(pages, second, nil, "page-002.json")
    c = csv!(d, for({sku, loc, qty} <- rows, do: "#{sku},#{loc},#{qty},"))

    assert {out, 0} = run(["--json-pages", pages, "--csv", c])
    refute out =~ "DIFF"
    assert out =~ "ROWS csv 60"
    assert out =~ "ROWS letflow 60"
    assert out =~ "RESULT equal"
    assert %{"csv" => h, "letflow" => h2} = hashes(out)
    assert h == h2
  end

  test "BC-9 a saved page with a next cursor is refused as an incomplete export", %{dir: d} do
    pages = Path.join(d, "pages")
    json_page!(pages, [{"001", "A", "1"}], "page-2", "page-001.json")
    c = csv!(d, ["001,A,1,"])

    assert {out, 2} = run(["--json-pages", pages, "--csv", c])
    assert out =~ "incomplete"
    refute out =~ "Traceback"

    json_page!(pages, [{"003", "C", "3"}], nil, "page-003.json")
    assert {out, 2} = run(["--json-pages", pages, "--csv", c])
    assert out =~ "without gaps"
    refute out =~ "Traceback"
  end

  test "BC-5 zero and negative rows are left out on both sides and counted; kept with the flag",
       %{dir: d} do
    x = xlsx!(d, [{"001", "A", 1}, {"002", "A", 0}])
    c = csv!(d, ["001,A,1,", "002,A,0,", "003,A,-2,"])
    assert {out, 0} = run(["--xlsx", x, "--csv", c])
    assert out =~ "LEFT_OUT csv nonpositive 2"
    assert out =~ "LEFT_OUT xlsx nonpositive 1"
    assert {out2, 1} = run(["--xlsx", x, "--csv", c, "--keep-nonpositive"])
    assert out2 =~ "DIFF only_csv 003 A csv=-2 xlsx=-"
  end

  test "BC-6 names from items.csv and locations.csv are printed next to the codes", %{dir: d} do
    x = xlsx!(d, [{"001", "SHELF-A1", 9}])
    c = csv!(d, ["001,SHELF-A1,10,"])
    File.write!(Path.join(d, "items.csv"), "sku,sku_name,unit\n001,Sample bolt,pcs\n")

    File.write!(
      Path.join(d, "locations.csv"),
      "loc_code,loc_name,loc_parent\nSHELF-A1,Sample shelf A1,\n"
    )

    assert {out, 1} =
             run([
               "--xlsx",
               x,
               "--csv",
               c,
               "--items",
               Path.join(d, "items.csv"),
               "--locations",
               Path.join(d, "locations.csv")
             ])

    assert out =~ "DIFF quantity 001 (Sample bolt) SHELF-A1 (Sample shelf A1) csv=10 xlsx=9"
  end

  test "BC-7 bad input exits 2 without a trace", %{dir: d} do
    x = xlsx!(d, [{"001", "A", 1}])
    File.write!(Path.join(d, "bad.xlsx"), "not a zip")
    bad_csv = Path.join(d, "bad.csv")
    File.write!(bad_csv, "a,b\n1,2\n")
    ok = csv!(d, ["001,A,1,"])
    nan = csv!(d, ["001,A,abc,"], "nan.csv")

    assert {o1, 2} = run(["--xlsx", Path.join(d, "bad.xlsx"), "--csv", ok])
    assert o1 =~ "xlsx is not readable"
    assert {o2, 2} = run(["--xlsx", x, "--csv", bad_csv])
    assert o2 =~ "lacks column"
    assert {o3, 2} = run(["--xlsx", x, "--csv", nan])
    assert o3 =~ "not a number"
    assert {_, 2} = run(["--xlsx", Path.join(d, "missing.xlsx"), "--csv", ok])
    refute o1 =~ "Traceback"
  end
end
