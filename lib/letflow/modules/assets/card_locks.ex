defmodule Letflow.Modules.Assets.CardLocks do
  @moduledoc """
  T-1490 / G3 (`docs/uat/ba-decisions/T-1486.md`, `docs/assets/asset-register.md` section 3): after the
  first posted document that names an asset card, its `inventory_number` and `kind` are read-only.

  A card "has a posting" when a document that names it carries a `posted` mark, whether or not the
  document was reversed later (a reversal leaves entries in the ledger, REQ-752). A draft or an
  issued-only document does not lock. The documents that name a card are the lines of every kind of
  `Kinds.all/0`: key `asset_id`, and for a change of kind the stored `asset_card_id`. The opening
  document does not post yet, so it locks nothing until it does.

  `check/4` runs inside `Cards.update_card/4`, under the per-card advisory lock, before anything is
  written. Residual race: posting handlers do not take that lock, so one PATCH that passes the check
  just before a posting commits can slip through; not closed here.

  Isolation by `prefix` alone on every query (INV-1); every value is bound (INV-7).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Assets.Documents.Kinds
  alias Letflow.Modules.Assets.Documents.Posting
  alias Letflow.Repo

  @doc """
  `:ok` when neither `inventory_number` nor `kind` differs between `stored_fv` (the card before the
  change) and `merged_fv` (after the caller's body is merged in), or when the card has no posted
  document; else the first locked field, inventory number first.
  """
  @spec check(String.t(), term(), map(), map()) ::
          :ok | {:error, :inventory_number_locked | :kind_locked}
  def check(prefix, card_id, stored_fv, merged_fv)
      when is_binary(prefix) and is_map(stored_fv) and is_map(merged_fv) do
    changed =
      Enum.find(
        [{"inventory_number", :inventory_number_locked}, {"kind", :kind_locked}],
        fn {key, _} -> Map.get(stored_fv, key) != Map.get(merged_fv, key) end
      )

    case changed do
      nil -> :ok
      {_key, reason} -> if posted?(prefix, card_id), do: {:error, reason}, else: :ok
    end
  end

  @doc "True when a document that names card `card_id` carries a `posted` mark."
  @spec posted?(String.t(), term()) :: boolean()
  def posted?(prefix, card_id) when is_binary(prefix) and is_binary(card_id) do
    doc_ids =
      Kinds.all()
      |> Enum.flat_map(fn spec -> document_ids(prefix, spec, card_id) end)
      |> Enum.uniq()

    marks = Posting.marks(prefix, doc_ids)
    Enum.any?(doc_ids, fn id -> Map.has_key?(Map.get(marks, id, %{}), "posted") end)
  end

  def posted?(_prefix, _card_id), do: false

  defp line_key(%{kind: "kind_change"}), do: "asset_card_id"
  defp line_key(_spec), do: "asset_id"

  defp document_ids(prefix, spec, card_id) do
    key = line_key(spec)

    header_ids =
      Repo.all(
        from(l in Latest,
          where:
            l.entity_type == ^spec.line_type and not l.deleted and
              fragment("?->>? = ?", l.field_values, ^key, ^card_id),
          select: fragment("?->>'header_id'", l.field_values)
        ),
        prefix: prefix
      )
      |> Enum.flat_map(fn id ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end
      end)
      |> Enum.uniq()

    headers(prefix, spec.type_key, header_ids)
  end

  defp headers(_prefix, _type, []), do: []

  defp headers(prefix, type, header_ids) do
    Repo.all(
      from(h in Latest,
        where: h.entity_type == ^type and not h.deleted and h.record_id in ^header_ids,
        select: fragment("?->>'document_id'", h.field_values)
      ),
      prefix: prefix
    )
    |> Enum.reject(&is_nil/1)
  end
end
