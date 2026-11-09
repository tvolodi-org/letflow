defmodule Letflow.Modules.Assets.Import do
  @moduledoc """
  The import function of the asset card (GH #3899 / REQ-762, decision 0077 D5, spec
  `docs/assets/asset-xlsx.md`): one row of a file for `assets_card`, called by the core through
  `Letflow.Modules.Catalog.call_import_function/5` as `import_card(prefix, entry, ctx)`. Every write
  goes through `Letflow.Modules.Assets.Cards.create_card/3` and `update_card/4`, so the card rules,
  the unique inventory number and the audit entry hold for imported rows. This file calls no
  `Repo`, no `Records`, no `Audit`, holds no Owner and writes no row itself. The import never
  places an asset, posts, or creates a document or a balance.

  The 200-row cap, the dry run, the upsert mode and the refusal of a scoped caller belong to the core
  route (decision 0077 D1, `import_scope_check/6`); nothing here repeats them.

  Per row, the first refusal wins and a refusal before the write writes nothing:

    1. only the template columns are allowed (`active` is refused: retiring stays `retire_card/3`);
    2. `inventory_number`, `name`, `kind` and `org_unit_id` must be non-blank text;
    3. `kind` is `fixed`, `low_value` or `intangible`;
    4. `org_unit_id` holds the external id of the org unit under the SAME external-ref system as the
       row; it is resolved in this tenant (`prefix` only) to the record id of an active unit;
    5. the card is found by the row's external reference pair; the row is the full desired state of
       the importable fields (an absent optional cell clears the value);
    6. a new key calls `create_card/3`; an existing one `update_card/4`. A row equal to the stored
       card is `:unchanged` (nothing is written).

  Money and depreciation cells arrive as strict decimal text from the core reader (`decimal_strict`)
  and are stored as typed. Cell text never goes into an error tuple. `ctx.dry_run` is accepted and
  unused: the core owns the rollback.
  """

  alias Letflow.Entities.ExternalRef
  alias Letflow.Modules.Assets.Cards
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi

  @ignored ~w(external_ref_system external_ref_id)
  @columns ~w(inventory_number name kind org_unit_id acquisition_date currency acquisition_cost
              accumulated_depreciation book_value depreciation_as_of valid_until)
  @required ~w(inventory_number name kind org_unit_id)
  @money ~w(acquisition_cost accumulated_depreciation book_value)
  @kinds ~w(fixed low_value intangible)

  @spec import_card(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, %{record_id: Ecto.UUID.t(), outcome: :created | :updated | :unchanged}}
          | {:error, term()}
  def import_card(prefix, %{external_ref: %ExternalRef{} = ref} = entry, ctx)
      when is_binary(prefix) do
    cells = entry.field_values |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    with :ok <- check_cells(cells),
         :ok <- check_required(cells),
         :ok <- check_kind(cells),
         {:ok, unit_id} <- resolve_unit(prefix, ref.system, cells["org_unit_id"]) do
      attrs = desired(cells, unit_id, ref)

      opts = fn suffix ->
        %{
          actor_id: ctx.actor_id,
          idempotency_key: ctx.idempotency_key <> suffix,
          holder_source: :import
        }
      end

      case ReadApi.lookup_by_external_ref(prefix, "assets_card", ref.system, ref.id, [
             "assets_card"
           ]) do
        {:error, :not_found} -> create(prefix, attrs, opts.("#create"))
        {:ok, stored} -> update(prefix, stored, attrs, opts.("#update"))
      end
    end
  end

  # --- cells ----------------------------------------------------------------------------------

  defp check_cells(cells) do
    keys = Map.keys(cells)

    cond do
      "active" in keys ->
        {:error, {:field_not_allowed, "active"}}

      Enum.any?(keys, &(&1 not in @columns and &1 not in @ignored)) ->
        {:error, :field_not_allowed}

      true ->
        :ok
    end
  end

  defp check_required(cells) do
    case Enum.find(@required, &(not text?(Map.get(cells, &1)))) do
      nil -> :ok
      header -> {:error, {:asset_field_required, header}}
    end
  end

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  defp check_kind(%{"kind" => kind}) when kind in @kinds, do: :ok
  defp check_kind(_cells), do: {:error, :asset_kind_invalid}

  defp resolve_unit(prefix, system, cell) do
    case Org.lookup_by_external_ref(prefix, "org_unit", system, cell) do
      {:error, :not_found} -> {:error, {:reference_not_found, "org_unit_id"}}
      {:ok, %{"active" => false}} -> {:error, {:reference_inactive, "org_unit_id"}}
      {:ok, %{"record_id" => id}} -> {:ok, id}
    end
  end

  # The full desired state: an absent or blank optional cell is nil (create drops it, update
  # removes it).
  defp desired(cells, unit_id, ref) do
    @columns
    |> Map.new(fn col ->
      v = Map.get(cells, col)
      {col, if(is_binary(v) and String.trim(v) == "", do: nil, else: v)}
    end)
    |> Map.put("org_unit_id", unit_id)
    |> Map.put("external_ref_system", ref.system)
    |> Map.put("external_ref_id", ref.id)
  end

  # --- writes ---------------------------------------------------------------------------------

  defp create(prefix, attrs, opts) do
    case Cards.create_card(prefix, attrs, opts) do
      {:ok, card} -> {:ok, %{record_id: card["record_id"], outcome: :created}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp update(prefix, stored, attrs, opts) do
    attrs = keep_equal_money(attrs, stored)

    case Cards.update_card(prefix, stored["record_id"], attrs, opts) do
      {:ok, ^stored} -> {:ok, %{record_id: stored["record_id"], outcome: :unchanged}}
      {:ok, card} -> {:ok, %{record_id: card["record_id"], outcome: :updated}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  # The store keeps a money cell at a fixed scale ("1000.500000000" for "1000.50"), so a text compare
  # would call every re-imported row changed. A cell numerically equal to the stored one keeps the
  # stored text, so `update_card/4` sees no change and writes nothing.
  defp keep_equal_money(attrs, stored) do
    Map.new(attrs, fn {col, v} ->
      if col in @money and equal_decimal?(v, stored[col]), do: {col, stored[col]}, else: {col, v}
    end)
  end

  defp equal_decimal?(a, b) when is_binary(a) and is_binary(b) do
    with {da, ""} <- Decimal.parse(a), {db, ""} <- Decimal.parse(b) do
      Decimal.equal?(da, db)
    else
      _ -> false
    end
  end

  defp equal_decimal?(_a, _b), do: false

  @doc false
  # Maps the Cards refusals to the constant reasons of the import (rendered by the core's
  # `import_reason_json/1`). `:kind_locked` and `:inventory_number_locked` come from `CardLocks` (T-1490).
  @spec refusal(term()) :: term()
  def refusal(:valid_until_not_allowed), do: :asset_valid_until_not_allowed
  def refusal(:currency_mismatch), do: :asset_currency_mismatch
  def refusal(:kind_locked), do: :asset_kind_locked
  def refusal(:inventory_number_locked), do: :asset_inventory_number_locked
  def refusal(:org_unit_not_active), do: {:reference_inactive, "org_unit_id"}
  def refusal(:card_inactive), do: :card_inactive

  def refusal({:record_payload_invalid, violations}) do
    fields =
      violations
      |> List.wrap()
      |> Enum.flat_map(fn
        %{path: [field | _]} when is_binary(field) ->
          [field]

        %{field_path: path} when is_binary(path) ->
          [path |> String.split("/", trim: true) |> List.first()]

        _ ->
          []
      end)

    cond do
      "inventory_number" in fields -> :asset_inventory_number_taken
      (field = Enum.find(fields, &(&1 in @columns))) != nil -> {:field_invalid, field}
      true -> :asset_row_invalid
    end
  end

  def refusal(other), do: other
end
