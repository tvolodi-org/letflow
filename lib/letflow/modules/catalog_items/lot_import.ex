defmodule Letflow.Modules.CatalogItems.LotImport do
  @moduledoc """
  The import function of the lot master (GH #3599 / REQ-654, decision 0077 D5): one row of a file
  for `catalog_lot`, called by the core through `Letflow.Modules.CatalogItems.import_row/3`. Every
  write goes through `Letflow.Modules.CatalogItems.create_lot/3` and `update_lot/4`. This file
  calls no `Records`, no `Audit` and holds no Owner.

  Per row:

    1. the cells are checked: only `item_id code producer mark expiry_date` are allowed (`active`
       is refused with the header `active`: retiring stays `retire_lot/3`); `item_id` and `code`
       must be text;
    2. `item_id` holds the external id of a `catalog_item` under the SAME external-ref system as
       the row (items are imported by REQ-651, which sets the record-level reference). Resolved
       like the item references of `Letflow.Modules.CatalogItems.Import`: none is
       `{:reference_not_found, "item_id"}`, an inactive item `{:reference_inactive, "item_id"}`;
    3. an existing lot is found by the field pair `external_ref_system` / `external_ref_id` of
       `entity_catalog_lot`. The row is the full desired state (an absent optional cell clears the
       value); an equal row writes nothing (`:unchanged`). A changed `code` is handed to
       `update_lot/4`, which refuses it; a changed item is `{:field_not_allowed, "item_id"}`.

  `ctx.dry_run` is accepted and unused: the core owns the rollback. No effect outside `prefix`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.CatalogItems.Import
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @importable ~w(item_id code producer mark expiry_date)
  @ignored ~w(external_ref_system external_ref_id)
  @optional ~w(producer mark expiry_date)

  @spec row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, %{record_id: Ecto.UUID.t(), outcome: :created | :updated | :unchanged}}
          | {:error, term()}
  def row(
        prefix,
        %{entity_type: "catalog_lot", external_ref: %ExternalRef{} = ref} = entry,
        ctx
      )
      when is_binary(prefix) do
    cells = entry.field_values |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    with :ok <- check_cells(cells),
         {:ok, item_id} <-
           Import.resolve(cells["item_id"], "catalog_item", "item_id", ref.system, prefix),
         {:ok, existing} <- find(prefix, ref.system, ref.id) do
      opts = fn suffix ->
        %{actor_id: ctx.actor_id, idempotency_key: ctx.idempotency_key <> suffix}
      end

      case existing do
        nil -> create(prefix, cells, item_id, ref, opts)
        {:deleted, _} -> {:error, {:external_ref_record_deleted, ref}}
        {:live, id} -> upsert(prefix, id, cells, item_id, opts)
      end
    end
  end

  defp check_cells(cells) do
    keys = Map.keys(cells)

    cond do
      "active" in keys ->
        {:error, {:field_not_allowed, "active"}}

      Enum.any?(keys, &(&1 not in @importable and &1 not in @ignored)) ->
        {:error, :field_not_allowed}

      true ->
        case Enum.find(~w(item_id code), &(not text?(Map.get(cells, &1)))) do
          nil -> :ok
          field -> {:error, {:field_invalid, field}}
        end
    end
  end

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  # {:ok, nil | {:live, id} | {:deleted, id}}; one Ecto query, tenant by `prefix`.
  defp find(prefix, system, id) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(t in "entity_catalog_lot",
          join: l in Latest,
          on: l.record_id == t.record_id and l.entity_type == "catalog_lot",
          where: t.external_ref_system == ^system and t.external_ref_id == ^id,
          select: {type(t.record_id, Ecto.UUID), l.deleted}
        )

      case Repo.one(query, prefix: prefix) do
        nil -> {:ok, nil}
        {record_id, false} -> {:ok, {:live, record_id}}
        {record_id, true} -> {:ok, {:deleted, record_id}}
      end
    end
  end

  defp create(prefix, cells, item_id, ref, opts) do
    attrs =
      cells
      |> Map.drop(@ignored)
      |> Map.merge(%{
        "item_id" => item_id,
        "external_ref_system" => ref.system,
        "external_ref_id" => ref.id
      })

    transact(fn ->
      with {:ok, lot} <- CatalogItems.create_lot(prefix, attrs, opts.("#create")) do
        {:ok, %{record_id: lot["record_id"], outcome: :created}}
      end
    end)
  end

  defp upsert(prefix, id, cells, item_id, opts) do
    {:ok, stored} = CatalogItems.lookup(prefix, id)

    if item_id != stored["item_id"] do
      {:error, {:field_not_allowed, "item_id"}}
    else
      update =
        Enum.reduce(["code" | @optional], %{}, fn k, acc ->
          new = Map.get(cells, k)
          if new == Map.get(stored, k), do: acc, else: Map.put(acc, k, new)
        end)

      if update == %{} do
        {:ok, %{record_id: id, outcome: :unchanged}}
      else
        transact(fn ->
          with {:ok, _} <- CatalogItems.update_lot(prefix, id, update, opts.("#update")) do
            {:ok, %{record_id: id, outcome: :updated}}
          end
        end)
      end
    end
  end

  defp transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
