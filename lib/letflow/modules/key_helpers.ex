defmodule Letflow.Modules.KeyHelpers do
  @moduledoc """
  B16#4: shared helpers for ledger dimension key lists (slot lists of up to five elements).

  `pad/1` and `empty_to_nil/1` were defined identically in five places:
  `Letflow.Modules.Assets.Views`, `Letflow.Modules.Stock.Views`,
  `Letflow.Modules.Assets.Documents.Posting`,
  `Letflow.Modules.Assets.Documents.KindChangePosting`, and
  `Letflow.Modules.Stock.Documents.Posting`. They are pure, have no dependency on
  Postgres or any context, and belong here rather than in a module-specific file.
  """

  @slots 5

  @doc """
  Pads a slot list to exactly #{@slots} elements by appending `nil` values on the right,
  or truncates to #{@slots} if the list is longer.
  """
  @spec pad(list()) :: [term()]
  def pad(k),
    do: k |> Enum.take(@slots) |> then(&(&1 ++ List.duplicate(nil, @slots - length(&1))))

  @doc "Converts an empty string to `nil`; passes any other value through unchanged."
  @spec empty_to_nil(term()) :: term()
  def empty_to_nil(""), do: nil
  def empty_to_nil(value), do: value
end
