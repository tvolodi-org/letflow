defmodule Letflow.Modules.ReadApi do
  @moduledoc """
  Shared body of the foundation modules' read API (decision 0050 D2; GH #2905): `lookup/3` and
  `active?/3` for a module that owns a fixed list of entity types. `Letflow.Modules.Org` and
  `Letflow.Modules.CatalogItems` delegate to it, so the contract lives in one place.

  Contract: `{:ok, record_map} | {:error, :not_found}`. The map has string keys `"record_id"`,
  `"entity_type"` and every stored field value. A non-uuid id, an unknown uuid, a soft-deleted
  record and a non-text `prefix` are all `{:error, :not_found}`, never a raise. Isolation is by
  `prefix` alone (derived server-side from the authenticated tenant, never from HTTP input).
  """

  alias Letflow.Entities.Record.Latest

  @doc "The live record `id` in tenant schema `prefix`, searched across `types` in order."
  @spec lookup(prefix :: term(), id :: term(), types :: [String.t()]) ::
          {:ok, map()} | {:error, :not_found}
  def lookup(prefix, id, types) when is_binary(prefix) do
    with {:ok, record_id} <- Ecto.UUID.cast(id),
         {:ok, row} <- first_live(prefix, record_id, types) do
      {:ok, to_map(row)}
    else
      _ -> {:error, :not_found}
    end
  end

  def lookup(_prefix, _id, _types), do: {:error, :not_found}

  @doc "True only for an existing, non-deleted record of `types` whose `active` field is `true`."
  @spec active?(prefix :: term(), id :: term(), types :: [String.t()]) :: boolean()
  def active?(prefix, id, types) do
    match?({:ok, %{"active" => true}}, lookup(prefix, id, types))
  end

  defp first_live(_prefix, _record_id, []), do: {:error, :not_found}

  defp first_live(prefix, record_id, [type | rest]) do
    case Latest.get_live(record_id, type, prefix) do
      {:ok, _row} = found -> found
      _ -> first_live(prefix, record_id, rest)
    end
  end

  defp to_map(%Latest{} = row) do
    Map.merge(row.field_values, %{"record_id" => row.record_id, "entity_type" => row.entity_type})
  end
end
