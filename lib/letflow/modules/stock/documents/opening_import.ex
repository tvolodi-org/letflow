defmodule Letflow.Modules.Stock.Documents.OpeningImport do
  @moduledoc """
  REQ-727 / GH #3773: the import function of `stock_opening_line` (manifest `:import_functions`),
  called by the core through `Letflow.Modules.Catalog.call_import_function/5` as `row(prefix, entry,
  ctx)` for one row of an xlsx file (decision 0079 D5, 0077). It writes DRAFT lines only: it never
  posts and does not run the line checks of 0079 D3 (the check route does).

  Per row, the first refusal wins and a refusal before the write writes nothing:

    1. each reference cell holds the external id of its target under the SAME external-ref system as
       the row (`header_id`, `org_unit_id`, `location_id`, `responsible_id`, `catalog_item_id`,
       `catalog_uom_id`, `catalog_lot_id`; the lot may be absent). The target is read through the
       owning module's `lookup_by_external_ref/4`; none, a record id, another tenant's record or a
       non-text cell is `{:reference_not_found, field}`, an inactive target
       `{:reference_inactive, field}`. `field` is a constant of this module, never cell text;
    2. the header's document must be a draft (`:document_not_draft`) and the row's org unit must be
       the header's (`:org_unit_mismatch`);
    3. the line is validated by `OpeningShape` (one definition of the quantity, price and date rules):
       `:quantity_invalid`, `:price_invalid`, otherwise `{:line_invalid, field}` (a line key, or nil);
    4. `Documents.upsert_opening_line/4` writes it under the document lock (`:lines_count` when a
       new line would be the 101st). The row's external ref pair is the line's pair.

  The header is found by the field pair of `stock_opening` in this tenant (the first by record id when
  two held the same pair); the line is found within the document only. `ctx.dry_run` is accepted and
  unused: the core owns the rollback. This file names no `Records` call and holds no Owner.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.Documents
  alias Letflow.Modules.Stock.Documents.OpeningShape
  alias Letflow.Repo

  # {cell, owning module, entity type, required}
  @refs [
    {"org_unit_id", Org, "org_unit", true},
    {"location_id", Locations, "location_node", true},
    {"responsible_id", Org, "org_employee", true},
    {"catalog_item_id", CatalogItems, "catalog_item", true},
    {"catalog_uom_id", CatalogItems, "catalog_uom", true},
    {"catalog_lot_id", CatalogItems, "catalog_lot", false}
  ]
  @plain ~w(quantity received_on unit_price line_value)
  @line_keys ~w(location_id responsible_id catalog_item_id catalog_uom_id catalog_lot_id quantity
                received_on unit_price line_value external_ref_system external_ref_id)

  @spec row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, %{record_id: Ecto.UUID.t(), outcome: :created | :updated | :unchanged}}
          | {:error, term()}
  def row(
        prefix,
        %{entity_type: "stock_opening_line", external_ref: %ExternalRef{} = ref} = entry,
        ctx
      )
      when is_binary(prefix) do
    cells = entry.field_values

    with {:ok, header} <- find_header(prefix, cells, ref.system),
         {:ok, resolved} <- resolve(prefix, cells, ref.system),
         {:ok, document} <- fetch_document(prefix, header),
         :ok <- draft(document),
         :ok <- same_unit(document, resolved),
         {:ok, line} <- line(cells, resolved, ref),
         {:ok, {line_id, outcome}} <-
           Documents.upsert_opening_line(prefix, header["document_id"], line, ctx.actor_id) do
      {:ok, %{record_id: line_id, outcome: outcome}}
    end
  end

  # -- references ---------------------------------------------------------------------------------

  defp find_header(prefix, cells, system) do
    case cells["header_id"] do
      cell when is_binary(cell) ->
        query =
          from(r in Latest,
            where:
              r.entity_type == "stock_opening" and not r.deleted and
                fragment("?->>'external_ref_system' = ?", r.field_values, ^system) and
                fragment("?->>'external_ref_id' = ?", r.field_values, ^cell),
            order_by: [asc: r.record_id],
            select: r.field_values,
            limit: 1
          )

        case Repo.one(query, prefix: prefix) do
          %{"document_id" => id} = fv when is_binary(id) -> {:ok, fv}
          _none -> {:error, {:reference_not_found, "header_id"}}
        end

      _absent_or_not_text ->
        {:error, {:reference_not_found, "header_id"}}
    end
  end

  defp resolve(prefix, cells, system) do
    Enum.reduce_while(@refs, {:ok, %{}}, fn {field, mod, type, required}, {:ok, acc} ->
      case {Map.get(cells, field), required} do
        {nil, false} ->
          {:cont, {:ok, acc}}

        {cell, _} when is_binary(cell) ->
          case mod.lookup_by_external_ref(prefix, type, system, cell) do
            {:ok, %{"active" => false}} -> {:halt, {:error, {:reference_inactive, field}}}
            {:ok, %{"record_id" => id}} -> {:cont, {:ok, Map.put(acc, field, id)}}
            {:error, :not_found} -> {:halt, {:error, {:reference_not_found, field}}}
          end

        _absent_or_not_text ->
          {:halt, {:error, {:reference_not_found, field}}}
      end
    end)
  end

  # -- document -----------------------------------------------------------------------------------

  defp fetch_document(prefix, header) do
    case Documents.fetch(prefix, header["document_id"]) do
      {:ok, %{kind: "opening"} = document} -> {:ok, document}
      _other -> {:error, {:reference_not_found, "header_id"}}
    end
  end

  defp draft(%{state: "draft"}), do: :ok
  defp draft(_document), do: {:error, :document_not_draft}

  defp same_unit(%{org_unit_id: unit}, %{"org_unit_id" => unit}), do: :ok
  defp same_unit(_document, _resolved), do: {:error, :org_unit_mismatch}

  # -- the line -----------------------------------------------------------------------------------

  # The cells that reach the shape check: the plain value cells, the resolved ids (not the header and
  # org unit, which the module sets) and the row's own ref pair (it wins over any cell).
  defp line(cells, resolved, %ExternalRef{system: system, id: id}) do
    raw =
      cells
      |> Map.take(@plain)
      |> Map.merge(Map.delete(resolved, "org_unit_id"))
      |> Map.merge(%{"external_ref_system" => system, "external_ref_id" => id})

    body = %{"kind" => "opening", "org_unit_id" => resolved["org_unit_id"], "lines" => [raw]}

    case OpeningShape.parse(body, :create) do
      {:ok, %{lines: [line]}} ->
        {:ok, line}

      {:error, {"quantity_invalid", _}} ->
        {:error, :quantity_invalid}

      {:error, {"price_invalid", %{"field" => field}}} when field in @line_keys ->
        {:error, {:price_invalid, field}}

      {:error, {"price_invalid", _}} ->
        {:error, :price_invalid}

      {:error, {_reason, %{"field" => field}}} when field in @line_keys ->
        {:error, {:line_invalid, field}}

      {:error, _other} ->
        {:error, {:line_invalid, nil}}
    end
  end
end
