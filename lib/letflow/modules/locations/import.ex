defmodule Letflow.Modules.Locations.Import do
  @moduledoc """
  The import function of the location tree (GH #3601 / REQ-652, decision 0077 D5): one row of a file
  for `location_node`, called by the core through `Letflow.Modules.Catalog.call_import_function/5`
  as `row(prefix, entry, ctx)`. Every write goes through `Letflow.Modules.Locations.create_node/3`,
  `move_node/4` and `update_node/4`, so the tree rules (cycle walk, inactive parent, tree lock) hold
  for imported rows. This file calls no `Records`, holds no Owner and writes no row itself.

  Per row:

    1. the cells are checked: only the importable columns are allowed (`active` is refused with the
       header `active`: retiring stays `retire_node/3`), `code`, `name`, `node_kind` must be text;
    2. `parent_id` holds the external id of the parent under the SAME external-ref system as the row.
       It is resolved in this tenant (`prefix` is the only tenant datum) to the record id of the
       live parent: none, a parent later in the file, a record id, another tenant's node or a
       non-text cell is `{:reference_not_found, "parent_id"}`. A retired parent is left to Tree
       (`:parent_inactive`);
    3. an existing node is found by the field pair `external_ref_system` / `external_ref_id` of the
       promoted table (the Tree functions never set the record-level master reference, so
       `Latest.get_by_external_ref/4` finds no location node). The row is the full desired state of
       the importable fields: an absent optional cell clears the value. A row equal to the stored
       node writes nothing (`:unchanged`);
    4. a new key calls `create_node/3`; an existing one `update_node/4` and then `move_node/4`, in
       one transaction, so a refused row changes nothing. A changed `code` is handed to
       `update_node/4`, which refuses it (`{:field_not_allowed, "code"}`).

  `ctx.dry_run` is accepted and unused: the core owns the rollback. No effect outside `prefix`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Locations
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @importable ~w(code name node_kind parent_id segment address location_type)
  @ignored ~w(external_ref_system external_ref_id)
  @plain ~w(name node_kind segment address location_type)
  @required ~w(code name node_kind)

  @spec row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, %{record_id: Ecto.UUID.t(), outcome: :created | :updated | :unchanged}}
          | {:error, term()}
  def row(
        prefix,
        %{entity_type: "location_node", external_ref: %ExternalRef{} = ref} = entry,
        ctx
      )
      when is_binary(prefix) do
    cells = entry.field_values

    with :ok <- check_cells(cells),
         {:ok, parent} <- resolve_parent(prefix, cells, ref.system),
         {:ok, existing} <- find(prefix, ref.system, ref.id) do
      opts = fn suffix ->
        %{actor_id: ctx.actor_id, idempotency_key: ctx.idempotency_key <> suffix}
      end

      case existing do
        nil -> create(prefix, cells, parent, ref, opts)
        {:deleted, _} -> {:error, {:external_ref_record_deleted, ref}}
        {:live, id} -> upsert(prefix, id, cells, parent, opts)
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
        check_required(cells)
    end
  end

  defp check_required(cells) do
    case Enum.find(@required, &(not text?(Map.get(cells, &1)))) do
      nil -> :ok
      field -> {:error, {:field_invalid, field}}
    end
  end

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  defp resolve_parent(prefix, cells, system) do
    case Map.fetch(cells, "parent_id") do
      :error ->
        {:ok, nil}

      {:ok, cell} when is_binary(cell) ->
        case find(prefix, system, cell) do
          {:ok, {:live, id}} -> {:ok, id}
          _ -> {:error, {:reference_not_found, "parent_id"}}
        end

      {:ok, _} ->
        {:error, {:reference_not_found, "parent_id"}}
    end
  end

  # {:ok, nil | {:live, id} | {:deleted, id}}; one Ecto query, tenant by `prefix`.
  defp find(prefix, system, id) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(t in "entity_location_node",
          join: l in Latest,
          on: l.record_id == t.record_id and l.entity_type == "location_node",
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

  defp create(prefix, cells, parent, ref, opts) do
    attrs =
      cells
      |> Map.drop(@ignored ++ ["parent_id"])
      |> Map.merge(%{
        "parent_id" => parent,
        "external_ref_system" => ref.system,
        "external_ref_id" => ref.id
      })

    transact(fn ->
      with {:ok, node} <- Locations.create_node(prefix, attrs, opts.("#create")) do
        {:ok, %{record_id: node["record_id"], outcome: :created}}
      end
    end)
  end

  defp upsert(prefix, id, cells, parent, opts) do
    {:ok, stored} = Locations.lookup(prefix, id)

    update_attrs =
      Enum.reduce(@plain, %{}, fn k, acc ->
        new = Map.get(cells, k)
        if new == Map.get(stored, k), do: acc, else: Map.put(acc, k, new)
      end)

    update_attrs =
      if cells["code"] == stored["code"],
        do: update_attrs,
        else: Map.put(update_attrs, "code", cells["code"])

    move? = parent != stored["parent_id"]

    if update_attrs == %{} and not move? do
      {:ok, %{record_id: id, outcome: :unchanged}}
    else
      transact(fn ->
        with :ok <- maybe_update(prefix, id, update_attrs, opts),
             :ok <- maybe_move(prefix, id, parent, move?, opts) do
          {:ok, %{record_id: id, outcome: :updated}}
        end
      end)
    end
  end

  defp maybe_update(_prefix, _id, attrs, _opts) when attrs == %{}, do: :ok

  defp maybe_update(prefix, id, attrs, opts) do
    with {:ok, _} <- Locations.update_node(prefix, id, attrs, opts.("#update")), do: :ok
  end

  defp maybe_move(_prefix, _id, _parent, false, _opts), do: :ok

  defp maybe_move(prefix, id, parent, true, opts) do
    with {:ok, _} <- Locations.move_node(prefix, id, parent, opts.("#move")), do: :ok
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
