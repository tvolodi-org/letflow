defmodule Letflow.Modules.Stock.PrintLabelsI18nTest do
  @moduledoc """
  T-1461: verifies that every label key in CountPrint and DocumentPrint has non-empty ru and kk
  text, naming table and key on failure.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Stock.CountPrint
  alias Letflow.Modules.Stock.DocumentPrint

  @required_langs [:ru, :kk]

  # Returns one message per label whose ru or kk text is absent, nil, or blank.
  defp gaps(table, labels) do
    for {key, texts} <- labels,
        lang <- @required_langs,
        blank?(Map.get(texts, lang)) do
      "#{table}.#{key} missing or empty #{lang}"
    end
  end

  defp blank?(nil), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: true

  describe "gap detector" do
    test "flags a missing key, an empty text and a blank text, naming table and key" do
      labels = %{
        a: %{en: "x"},
        b: %{en: "x", ru: "", kk: "y"},
        c: %{en: "x", ru: "  ", kk: nil},
        ok: %{en: "x", ru: "r", kk: "k"}
      }

      found = gaps("T", labels)

      assert "T.a missing or empty ru" in found
      assert "T.a missing or empty kk" in found
      assert "T.b missing or empty ru" in found
      refute Enum.any?(found, &String.contains?(&1, "T.b missing or empty kk"))
      assert "T.c missing or empty ru" in found
      assert "T.c missing or empty kk" in found
      refute Enum.any?(found, &String.contains?(&1, "T.ok"))
    end
  end

  describe "print label completeness" do
    test "every label key in CountPrint and DocumentPrint has non-empty ru and kk text" do
      found =
        gaps("CountPrint", CountPrint.labels()) ++ gaps("DocumentPrint", DocumentPrint.labels())

      assert found == [],
             "Print labels with missing or empty ru/kk text:\n" <> Enum.join(found, "\n")
    end
  end
end
