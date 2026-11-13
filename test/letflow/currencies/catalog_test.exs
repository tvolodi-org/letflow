defmodule Letflow.Currencies.CatalogTest do
  @moduledoc """
  REQ-823 / GH #4394 criterion 1: the platform list file and `Letflow.Currencies.Catalog`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Currencies.Catalog

  @path "priv/currencies/iso4217.json"

  test "C1 the file is well formed and the catalog returns exactly its entries" do
    file = @path |> File.read!() |> Jason.decode!()
    assert is_binary(file["source"]) and String.trim(file["source"]) != ""
    entries = file["currencies"]
    assert [_ | _] = entries

    for e <- entries do
      assert e["code"] =~ ~r/^[A-Z]{3}$/
      assert e["numeric_code"] =~ ~r/^[0-9]{3}$/
      assert is_integer(e["minor_units"]) and e["minor_units"] in 0..4
      assert e["names"] |> Map.keys() |> Enum.sort() == ["en", "kk", "ru"]

      for {_lang, name} <- e["names"] do
        assert is_binary(name) and String.trim(name) != ""
      end
    end

    codes = Enum.map(entries, & &1["code"])
    assert codes == Enum.uniq(codes)
    numeric = Enum.map(entries, & &1["numeric_code"])
    assert numeric == Enum.uniq(numeric)
    assert "KZT" in codes

    kzt = Enum.find(entries, &(&1["code"] == "KZT"))
    assert kzt["numeric_code"] == "398" and kzt["minor_units"] == 2

    expected =
      entries
      |> Enum.map(fn e ->
        %{
          code: e["code"],
          numeric_code: e["numeric_code"],
          minor_units: e["minor_units"],
          names: e["names"]
        }
      end)
      |> Enum.sort_by(& &1.code)

    assert Catalog.all() == expected
    assert Catalog.codes() == Enum.sort(codes)
    assert Catalog.source() == file["source"]
    assert Catalog.get("KZT").code == "KZT"
    assert Catalog.get("kzt") == nil
    assert Catalog.get(nil) == nil
    assert Catalog.default_code() == "KZT"
  end
end
