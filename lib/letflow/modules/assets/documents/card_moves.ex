defmodule Letflow.Modules.Assets.Documents.CardMoves do
  @moduledoc """
  T-1489 / G2 (owner decision D-111: one asset card is ONE org unit): the card moves of a posted hand
  over and of its reversal. The register is the single source of the holder; the card's `org_unit_id`
  (its access scope column) follows the last posted document.

  `forward/3` and `backward/3` are the router-side half: they READ the cards of a document's lines
  (prefix-scoped, INV-1) and return the list the posting carries as its literal key `"card_moves"`;
  `Letflow.Modules.Assets.Handlers` turns each entry into one `HandlerWrites.update/3` in the posting
  transaction, so the ledger entry and the card move commit together or not at all.

  An entry is `%{"asset" => card id, "from" => unit | nil, "to" => unit}`.

  | Case | Entry |
  |---|---|
  | forward, `to_org_unit_id != org_unit_id`, `fixed` or `intangible` card, unit is the header unit or empty | `from` = the card's unit, `to` = the destination |
  | forward, any other card (`low_value`, a unit that is neither, retired or missing) | none |
  | backward, card currently at the destination unit | `from` = destination, `to` = the header unit |
  | backward, card anywhere else (a hand over posted before this change, an empty card, a later hand over moved it on) | none: the ledger reversal still posts and the card is left |

  A `low_value` card is never moved here: its quantity can sit in several units, and the split by a
  partial hand over (D-111) is a follow-up. At most `max_moves/0` entries are returned (the write
  slots of one completion are 49, shared with the mark and the ledger entry); more is
  `{:error, :too_many_card_moves}` and nothing is started.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Repo

  @max_moves 45
  @moved_kinds ~w(fixed intangible)

  @doc "The most card moves one posting carries."
  @spec max_moves() :: pos_integer()
  def max_moves, do: @max_moves

  @doc "The moves of a hand over with `header` and `lines` (the issued content)."
  @spec forward(String.t(), map(), [map()]) :: {:ok, [map()]} | {:error, :too_many_card_moves}
  def forward(prefix, header, lines), do: moves(prefix, header, lines, :forward)

  @doc "The moves that restore the cards of the (posted) hand over `header` and `lines`."
  @spec backward(String.t(), map(), [map()]) :: {:ok, [map()]} | {:error, :too_many_card_moves}
  def backward(prefix, header, lines), do: moves(prefix, header, lines, :backward)

  defp moves(prefix, header, lines, direction) do
    from_unit = Map.get(header, "org_unit_id")
    to_unit = Map.get(header, "to_org_unit_id")

    if is_binary(from_unit) and is_binary(to_unit) and from_unit != to_unit do
      cards = cards(prefix, lines)

      entries =
        cards
        |> Enum.flat_map(fn {id, card} -> entry(direction, id, card, from_unit, to_unit) end)
        |> Enum.sort_by(& &1["asset"])

      if length(entries) > @max_moves, do: {:error, :too_many_card_moves}, else: {:ok, entries}
    else
      {:ok, []}
    end
  end

  defp entry(:forward, id, %{"kind" => kind, "org_unit_id" => unit}, from_unit, to_unit)
       when kind in @moved_kinds and (is_nil(unit) or unit == from_unit),
       do: [%{"asset" => id, "from" => unit, "to" => to_unit}]

  defp entry(:backward, id, %{"kind" => kind, "org_unit_id" => to_unit}, from_unit, to_unit)
       when kind in @moved_kinds,
       do: [%{"asset" => id, "from" => to_unit, "to" => from_unit}]

  defp entry(_direction, _id, _card, _from_unit, _to_unit), do: []

  # `%{card id => field_values}` of the live cards named by the lines (one query, one row per id).
  defp cards(prefix, lines) do
    ids =
      lines
      |> Enum.map(&Map.get(&1, "asset_id"))
      |> Enum.flat_map(fn id ->
        case is_binary(id) && Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          _invalid -> []
        end
      end)
      |> Enum.uniq()

    from(l in Latest,
      where: l.entity_type == "assets_card" and l.record_id in ^ids and not l.deleted,
      select: {l.record_id, l.field_values}
    )
    |> Repo.all(prefix: prefix)
    |> Map.new(fn {id, values} -> {id, Map.update(values, "org_unit_id", nil, & &1)} end)
  end
end
