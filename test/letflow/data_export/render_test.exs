defmodule Letflow.DataExport.RenderTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.DataExport.{Dataset, Render}
  @now ~U[2026-11-14 08:00:00Z]

  defp export(format, extra \\ %{}) do
    Map.merge(
      %{
        id: "stock_balances",
        format: format,
        filters: %{},
        meta: [{"cutoff_seq", 1}],
        cap: 3,
        truncated: false,
        columns: Dataset.columns([:quantity, :document_number, :name], %{quantity: :number}),
        rows: [%{quantity: "-5", document_number: "=SUM(A1)", name: "A,B"}]
      },
      extra
    )
  end

  test "DX-8 multiple datasets bundle files and an honest manifest" do
    second = export("json", %{id: "asset_balances", truncated: true})
    assert {:ok, file} = Render.render([export("csv"), second], "en", @now)
    assert file.type == "application/zip"
    assert file.name == "letflow-export-20261114.zip"
    {:ok, entries} = :zip.unzip(file.body, [:memory])
    entries = Map.new(entries, fn {name, bytes} -> {List.to_string(name), bytes} end)

    assert Enum.sort(Map.keys(entries)) ==
             ~w(asset-balances-20261114.json manifest.json stock-balances-20261114.csv)

    assert [a, b] = Jason.decode!(entries["manifest.json"])

    assert a == %{
             "id" => "stock_balances",
             "file" => "stock-balances-20261114.csv",
             "format" => "csv",
             "rows" => 1,
             "truncated" => false,
             "cap" => 3
           }

    assert b["truncated"] and b["rows"] == 1
  end

  test "DX-9 csv has no BOM, guards only text, quotes commas, uses CRLF" do
    assert {:ok, file} = Render.render([export("csv")], "ru", @now)
    assert file.body == "quantity,document_number,name\r\n-5,'=SUM(A1),\"A,B\"\r\n"
    assert file.type == "text/csv; charset=utf-8"
  end

  test "DX-4 provider columns distinguish references from the asset literal unit" do
    for id <- ~w(stock_balances stock_movements) do
      columns = Letflow.Modules.Stock.DataExport.columns(id) |> Map.new(&{&1.key, &1.kind})
      assert columns.unit_ref == {:ref, "catalog_uom"}
      assert columns.sku == {:ref, "catalog_item"}
    end

    columns =
      Letflow.Modules.Assets.DataExport.columns("asset_balances") |> Map.new(&{&1.key, &1.kind})

    assert columns.unit_ref == :text
    assert columns.asset == {:ref, "assets_card"}
  end

  test "DX-10 json contract keeps quantities as strings" do
    {:ok, file} = Render.render([export("json")], "kk", @now)
    body = Jason.decode!(file.body)

    assert Enum.sort(Map.keys(body)) ==
             ~w(cap columns dataset filters generated_at ids lang meta rows rows_total_written truncated)

    assert body["rows"] == [
             %{"quantity" => "-5", "document_number" => "=SUM(A1)", "name" => "A,B"}
           ]

    assert body["ids"] == "machine" and body["lang"] == "kk"
    assert body["columns"] == ~w(quantity document_number name)
  end

  test "DX-9 empty datasets retain their headers and write zero rows" do
    for format <- ~w(csv json xlsx) do
      {:ok, file} = Render.render([export(format, %{rows: []})], "en", @now)

      case format do
        "csv" ->
          assert file.body == "quantity,document_number,name\r\n"

        "json" ->
          body = Jason.decode!(file.body)
          assert body["rows"] == [] and body["rows_total_written"] == 0 and not body["truncated"]

        "xlsx" ->
          {:ok, pkg} = XlsxReader.open(file.body, source: :binary)
          assert {:ok, [~w(quantity document_number name)]} == XlsxReader.sheet(pkg, "data")
      end
    end
  end

  test "DX-6 xlsx reports truncation in all three languages and preserves exact large numbers" do
    for {lang, yes, note} <- [
          {"en", "yes", "Truncated"},
          {"ru", "да", "усечены"},
          {"kk", "иә", "қысқартылды"}
        ] do
      value =
        export("xlsx", %{
          truncated: true,
          rows: [
            %{quantity: "1234567890123456", document_number: "=SUM(A1)"},
            %{quantity: "1000000000000000", document_number: "RCP-1"}
          ]
        })

      {:ok, file} = Render.render([value], lang, @now)
      {:ok, pkg} = XlsxReader.open(file.body, source: :binary)
      {:ok, [header, row, numeric]} = XlsxReader.sheet(pkg, "data")
      assert header == ~w(quantity document_number name)
      assert Enum.take(row, 2) == ["1234567890123456", "=SUM(A1)"]
      assert is_number(hd(numeric)) and hd(numeric) == 1_000_000_000_000_000
      {:ok, rows} = XlsxReader.sheet(pkg, "report")
      report = Map.new(rows, fn [k | values] -> {k, List.first(values)} end)
      assert report["truncated"] == yes
      assert report["note"] =~ note
    end
  end
end
