defmodule Letflow.Modules.Stock.DocumentNumbers do
  @moduledoc """
  GH 3735 R7: the gap-free document NUMBER (`RCP-2026-000001`) of the documents a movement row points at, for
  display in the Movements screen (`document_number`, additive; `document_id` stays).

  One batch per page: the `document_id`s that are valid uuids are loaded in one `Document` query and the
  `DocumentType` rows in one more, both with the tenant `prefix` (INV-1). `document_id` on a ledger entry is free
  text, so it is cast with `Ecto.UUID.cast/1` first and the `in ^ids` list is typed `:binary_id` (INV-7; a raw
  string would be a cast error). A row whose id is not a numbered document of this tenant gets `nil`; the lookup
  never raises for a realistic miss (INV-8) and a miss looks the same as a forbidden id (INV-5).

  The label is built like `Letflow.Documents` builds it: type prefix, the period for a yearly scope, the
  number padded to the type's width.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentType
  alias Letflow.Repo

  @doc "Adds `:document_number` (text or `nil`) to every movement view map of `views`."
  @spec put_numbers(String.t(), [map()]) :: [map()]
  def put_numbers(prefix, views) when is_binary(prefix) and is_list(views) do
    numbers = for_ids(prefix, Enum.map(views, & &1.document_id))
    Enum.map(views, &Map.put(&1, :document_number, Map.get(numbers, &1.document_id)))
  end

  @doc "A `%{document_id_text => number_label}` map for the ids that are numbered documents of the tenant."
  @spec for_ids(String.t(), [term()]) :: %{String.t() => String.t()}
  def for_ids(prefix, raw_ids) do
    ids =
      raw_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(fn raw ->
        case Ecto.UUID.cast(raw) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end
      end)
      |> Enum.uniq()

    if ids == [], do: %{}, else: load(prefix, ids)
  end

  defp load(prefix, ids) do
    docs =
      Repo.all(
        from(d in Document,
          where: d.id in type(^ids, {:array, :binary_id}) and not is_nil(d.number)
        ),
        prefix: prefix
      )

    keys = docs |> Enum.map(& &1.type_key) |> Enum.uniq()
    types = Repo.all(from(t in DocumentType, where: t.key in ^keys), prefix: prefix)
    by_key = Map.new(types, &{&1.key, &1})

    Enum.reduce(docs, %{}, fn doc, acc ->
      case Map.get(by_key, doc.type_key) do
        nil -> acc
        type -> Map.put(acc, doc.id, label(type, doc))
      end
    end)
  end

  defp label(type, %Document{number: number, period: period}) do
    padded = number |> Integer.to_string() |> String.pad_leading(type.number_pad, "0")

    case type.numbering_scope do
      :none -> type.number_prefix <> "-" <> padded
      _year -> type.number_prefix <> "-" <> period <> "-" <> padded
    end
  end
end
