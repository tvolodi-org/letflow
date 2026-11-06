defmodule Letflow.Modules.Stock.PrintLabelsI18nTest do
  @moduledoc """
  T-1461: verifies that every label key in CountPrint and DocumentPrint has non-empty ru and kk
  text, naming table and key on failure.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Stock.CountPrint
  alias Letflow.Modules.Stock.DocumentPrint

  @tables [
    {"CountPrint", CountPrint.labels()},
    {"DocumentPrint", DocumentPrint.labels()}
  ]

  @required_langs [:ru, :kk]

  describe "print label completeness" do
    test "every label key in CountPrint and DocumentPrint has non-empty ru and kk text" do
      gaps =
        for {table, labels} <- @tables,
            {key, texts} <- labels,
            lang <- @required_langs,
            value = Map.get(texts, lang),
            is_nil(value) or value == "" do
          "#{table}.#{key} missing or empty #{lang}"
        end

      assert gaps == [],
             "Print labels with missing or empty ru/kk text:\n" <> Enum.join(gaps, "\n")
    end
  end
end
