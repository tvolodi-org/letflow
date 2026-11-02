defmodule Letflow.Modules.CatalogItems.Import do
  @moduledoc """
  The import function of the catalog masters (GH #3602 / REQ-651, decision 0077 D5): one row of a
  file for `catalog_uom`, `catalog_item` or `catalog_counterparty`, called by the core through
  `Letflow.Modules.Catalog.call_import_function/5` as `row(prefix, entry, ctx)`. This is the only
  file of the module that holds the module's Owner (`ManagedTypes.owner_for!/1`, 0050 D7).

  Per row:

    1. a reference field (a module constant, `catalog_item.base_uom_id` -> `catalog_uom`) holds the
       external id of the target under the SAME external-ref system as the row. It is resolved in
       this tenant (`prefix` is the only tenant datum) to the record id of the live target:
       none, a deleted target, a cell that is not text, or a record id (which matches no external
       id) is `{:reference_not_found, field}`; a target with `active` false is
       `{:reference_inactive, field}`. The `field` is a constant here, never cell text.
    2. the row's external ref is written into the type's own `external_ref_system` and
       `external_ref_id` fields (the ref of the row wins over anything given in the cells), so the
       record-level key (REQ-505) and the unique field pair (0057 D1) hold the same values;
    3. `Records.upsert_record_by_external_ref/3` with the module's Owner writes the row. Values are
       validated by the type's definition as for any write; a missing required reference cell is
       left to that validation.

  `ctx.dry_run` is accepted and unused: the core owns the rollback. No effect outside `prefix`.
  """

  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Modules.CatalogItems

  @references %{"catalog_item" => [{"base_uom_id", "catalog_uom"}]}

  @spec row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, %{record_id: Ecto.UUID.t(), outcome: :created | :updated | :unchanged}}
          | {:error, term()}
  def row(prefix, %{entity_type: type, external_ref: %ExternalRef{} = ref} = entry, ctx)
      when is_binary(prefix) do
    with {:ok, field_values} <- resolve_references(type, entry.field_values, ref, prefix) do
      attrs = %{
        entity_type: type,
        external_ref: ExternalRef.to_payload(ref),
        field_values:
          Map.merge(field_values, %{
            "external_ref_system" => ref.system,
            "external_ref_id" => ref.id
          }),
        actor_id: ctx.actor_id,
        idempotency_key: ctx.idempotency_key
      }

      # scope-all: SEC-518-R1 (catalog_items module, tenant-wide types; import_scope_check/6 refuses a scoped caller)
      case Records.upsert_record_by_external_ref(
             attrs,
             prefix,
             ManagedTypes.owner_for!(CatalogItems)
           ) do
        {:ok, %{record: %Latest{record_id: record_id}, outcome: outcome}} ->
          {:ok, %{record_id: record_id, outcome: outcome}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp resolve_references(type, field_values, ref, prefix) do
    @references
    |> Map.get(type, [])
    |> Enum.reduce_while({:ok, field_values}, fn {field, target}, {:ok, acc} ->
      case Map.fetch(acc, field) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, cell} ->
          case resolve(cell, target, field, ref.system, prefix) do
            {:ok, record_id} -> {:cont, {:ok, Map.put(acc, field, record_id)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp resolve(cell, target, field, system, prefix) when is_binary(cell) do
    case Latest.get_by_external_ref(target, system, cell, prefix) do
      {:ok, %Latest{deleted: false, field_values: %{"active" => false}}} ->
        {:error, {:reference_inactive, field}}

      {:ok, %Latest{deleted: false, record_id: record_id}} ->
        {:ok, record_id}

      _absent_or_deleted ->
        {:error, {:reference_not_found, field}}
    end
  end

  defp resolve(_cell, _target, field, _system, _prefix),
    do: {:error, {:reference_not_found, field}}
end
