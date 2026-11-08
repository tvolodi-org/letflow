defmodule Letflow.Modules.Assets.Documents.OpeningImport do
  @moduledoc """
  G6 (decision 0083 D7): the import function of `assets_opening_line` (manifest `:import_functions`),
  called by the core through `Letflow.Modules.Catalog.call_import_function/5` as `row(prefix, entry,
  ctx)` for one row of an xlsx file. It mirrors `Letflow.Modules.Stock.Documents.OpeningImport`
  (module `assets` cannot call `stock`, so the glue is copied). It writes DRAFT lines only: it never
  posts and does not run the D4 checks of the opening (duplicate asset, location rules, card linked,
  card already in the register); the check route (`POST /documents/:id/check`) shows those, so a
  file can be corrected on the screen. That is deliberate.

  The file columns are the entity field names (the core reader maps header cells to fields): the
  proposal columns `document` and `asset` of decision 0083 D7 are `header_id` and `asset_id`.

  Per row, the first refusal wins and a refusal before the write writes nothing:

    1. each reference cell holds the external id of its target under the SAME external-ref system as
       the row (`header_id`, `asset_id`, `location_id`, `material_responsible_id`, `actual_user_id`,
       and an optional `org_unit_id`). The target is read through the owning module; none, a record
       id, another tenant's record or a non-text cell is `{:reference_not_found, field}`, an inactive
       target `{:reference_inactive, field}`. `field` is a constant of this module, never cell text;
    2. the header's document must be an opening (else `reference_not_found`), a draft
       (`:document_not_draft`), and a given row org unit must be the header's (`:org_unit_mismatch`);
    3. the line is validated by `Shape` (one definition of the quantity grammar): a quantity the grammar
       refuses is `:quantity_invalid`, other refusals `{:line_invalid, field}` (a line key, or nil).
       Import-only rule: the quantity must be above zero (`:quantity_invalid`); a non-number never gets
       here (the core reader refuses it as `csv_invalid_decimal`), and hand-typed drafts still accept
       zero (the check reports it);
    4. `Documents.upsert_opening_line/4` writes it under the document lock (`:lines_count` when a new
       line would be the 101st). The row's external ref pair is the line's pair.

  The header is found by the field pair of `assets_opening` in this tenant (the first by record id when
  two held the same pair); the line is found within the document only. `ctx.dry_run` is accepted and
  unused: the core owns the rollback. This file names no `Records` call and holds no Owner.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Assets.Documents
  alias Letflow.Modules.Assets.Documents.Shape
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  # {cell, resolver, required}
  @refs [
    {"asset_id", :card, true},
    {"location_id", {Locations, "location_node"}, false},
    {"material_responsible_id", {Org, "org_employee"}, true},
    {"actual_user_id", {Org, "org_employee"}, false}
  ]
  @line_keys ~w(asset_id location_id material_responsible_id actual_user_id quantity external_ref_system external_ref_id)

  @spec row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, %{record_id: Ecto.UUID.t(), outcome: :created | :updated | :unchanged}}
          | {:error, term()}
  def row(
        prefix,
        %{entity_type: "assets_opening_line", external_ref: %ExternalRef{} = ref} = entry,
        ctx
      )
      when is_binary(prefix) do
    cells = entry.field_values

    with {:ok, header} <- find_header(prefix, cells, ref.system),
         {:ok, resolved} <- resolve(prefix, cells, ref.system),
         {:ok, unit} <- resolve_unit(prefix, cells, ref.system),
         {:ok, document} <- fetch_document(prefix, header),
         :ok <- draft(document),
         :ok <- same_unit(document, unit),
         {:ok, line} <- line(cells, resolved, document, ref),
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
              r.entity_type == "assets_opening" and not r.deleted and
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
    Enum.reduce_while(@refs, {:ok, %{}}, fn {field, source, required}, {:ok, acc} ->
      case {Map.get(cells, field), required} do
        {nil, false} ->
          {:cont, {:ok, acc}}

        {cell, _} when is_binary(cell) ->
          case lookup(source, prefix, system, cell) do
            {:ok, %{"active" => false}} -> {:halt, {:error, {:reference_inactive, field}}}
            {:ok, %{"record_id" => id}} -> {:cont, {:ok, Map.put(acc, field, id)}}
            {:error, :not_found} -> {:halt, {:error, {:reference_not_found, field}}}
          end

        _absent_or_not_text ->
          {:halt, {:error, {:reference_not_found, field}}}
      end
    end)
  end

  defp lookup(:card, prefix, system, cell),
    do: ReadApi.lookup_by_external_ref(prefix, "assets_card", system, cell, ["assets_card"])

  defp lookup({mod, type}, prefix, system, cell),
    do: mod.lookup_by_external_ref(prefix, type, system, cell)

  # The row's org unit is optional; given, it must resolve (and later equal the document's).
  defp resolve_unit(prefix, cells, system) do
    case Map.get(cells, "org_unit_id") do
      nil ->
        {:ok, nil}

      cell when is_binary(cell) ->
        case Org.lookup_by_external_ref(prefix, "org_unit", system, cell) do
          {:ok, %{"active" => false}} -> {:error, {:reference_inactive, "org_unit_id"}}
          {:ok, %{"record_id" => id}} -> {:ok, id}
          {:error, :not_found} -> {:error, {:reference_not_found, "org_unit_id"}}
        end

      _not_text ->
        {:error, {:reference_not_found, "org_unit_id"}}
    end
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

  defp same_unit(_document, nil), do: :ok
  defp same_unit(%{org_unit_id: unit}, unit), do: :ok
  defp same_unit(_document, _unit), do: {:error, :org_unit_mismatch}

  # -- the line -----------------------------------------------------------------------------------

  # The cells that reach the shape check: the plain quantity cell, the resolved ids and the row's own
  # ref pair (it wins over any cell). The stored line always gets the document's org unit.
  defp line(cells, resolved, document, %ExternalRef{system: system, id: id}) do
    raw =
      cells
      |> Map.take(["quantity"])
      |> Map.merge(Map.delete(resolved, "org_unit_id"))
      |> Map.merge(%{"external_ref_system" => system, "external_ref_id" => id})

    body = %{"kind" => "opening", "org_unit_id" => document.org_unit_id, "lines" => [raw]}

    case Shape.parse(body, :create) do
      {:ok, %{lines: [line]}} ->
        positive(line)

      {:error, {_reason, %{"field" => "quantity"}}} ->
        {:error, :quantity_invalid}

      {:error, {_reason, %{"field" => field}}} when field in @line_keys ->
        {:error, {:line_invalid, field}}

      {:error, _other} ->
        {:error, {:line_invalid, nil}}
    end
  end

  defp positive(%{"quantity" => quantity} = line) do
    if Decimal.compare(Decimal.new(quantity), 0) == :gt,
      do: {:ok, line},
      else: {:error, :quantity_invalid}
  end
end
