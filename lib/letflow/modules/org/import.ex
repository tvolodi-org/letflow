defmodule Letflow.Modules.Org.Import do
  @moduledoc """
  The import function of the org units, positions and employees (GH #3599 / REQ-654, decision 0077
  D5): one row of a file for `org_unit`, `org_position` or `org_employee`, called by the core
  through `Letflow.Modules.Catalog.call_import_function/5` as `row(prefix, entry, ctx)`. Every
  write goes through `Letflow.Modules.Org.create_unit/3`, `update_unit/4`, `move_unit/4`,
  `create_position/3`, `update_position/4`, `create_employee/3`, `update_employee/4` and
  `transfer_employee/5`, so the scope tree index, the tree, reference and uniqueness rules and
  the audit entry hold for imported rows. This file calls no `Records`, no `Audit`, no
  `ScopeNodePaths`, holds no Owner and writes no row itself.

  Per row:

    1. the cells are checked: only the importable columns are allowed (`active` is refused with
       the header `active`: retiring stays `retire_unit/3` and the like), required cells must be
       text;
    2. a reference cell (`legal_entity_id`, `site_id`, `parent`, `org_unit_id`, `position_id`)
       holds the external id of the target under the SAME external-ref system as the row. It is
       resolved in this tenant (`prefix` is the only tenant datum) to the record id of the live
       target through the promoted `external_ref_system` / `external_ref_id` columns of the
       target's table (the org write functions never set the record-level reference, so
       `Latest.get_by_external_ref/4` finds nothing). None, a deleted target, a record id, another
       tenant's id or a non-text cell is `{:reference_not_found, field}` with `field` a constant.
       An inactive target is left to the write function (`:unit_inactive` and the like). Legal
       entities and sites are not imported: they must exist, created with a matching external
       reference;
    3. an existing row is found by the field pair of its own table. The row is the full desired
       state of the importable fields (an absent optional cell clears the value). A row equal to
       the stored record writes nothing (`:unchanged`);
    4. a new key calls the create function; an existing one the update function and then the
       move (`org_unit.parent`) or transfer (`org_employee` unit and position), in one
       transaction, so a refused row changes nothing. A changed `code` is handed to the update
       function, which refuses it. A position's unit cannot change: `{:field_not_allowed,
       "org_unit_id"}`.

  Cell text never goes into an error tuple (employee names and user ids are personal data).
  `ctx.dry_run` is accepted and unused: the core owns the rollback. No effect outside `prefix`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Org
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @ignored ~w(external_ref_system external_ref_id)

  @importable %{
    "org_unit" => ~w(code name legal_entity_id site_id parent),
    "org_position" => ~w(code name org_unit_id),
    "org_employee" => ~w(code full_name org_unit_id position_id user_id)
  }

  @required %{
    "org_unit" => ~w(code name legal_entity_id site_id),
    "org_position" => ~w(code name org_unit_id),
    "org_employee" => ~w(code full_name org_unit_id)
  }

  # The reference columns of each type: {header, target type}.
  @references %{
    "org_unit" => [
      {"legal_entity_id", "org_legal_entity"},
      {"site_id", "org_site"},
      {"parent", "org_unit"}
    ],
    "org_position" => [{"org_unit_id", "org_unit"}],
    "org_employee" => [{"org_unit_id", "org_unit"}, {"position_id", "org_position"}]
  }

  @tables %{
    "org_legal_entity" => "entity_org_legal_entity",
    "org_site" => "entity_org_site",
    "org_unit" => "entity_org_unit",
    "org_position" => "entity_org_position",
    "org_employee" => "entity_org_employee"
  }

  @spec row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, %{record_id: Ecto.UUID.t(), outcome: :created | :updated | :unchanged}}
          | {:error, term()}
  def row(
        prefix,
        %{entity_type: type, external_ref: %ExternalRef{} = ref} = entry,
        ctx
      )
      when is_binary(prefix) and is_map_key(@importable, type) do
    cells = entry.field_values |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    with :ok <- check_cells(type, cells),
         {:ok, refs} <- resolve_all(prefix, type, cells, ref.system),
         {:ok, existing} <- find(prefix, type, ref.system, ref.id) do
      opts = fn suffix ->
        %{actor_id: ctx.actor_id, idempotency_key: ctx.idempotency_key <> suffix}
      end

      case existing do
        nil -> create(prefix, type, cells, refs, ref, opts)
        {:deleted, _} -> {:error, {:external_ref_record_deleted, ref}}
        {:live, id} -> upsert(prefix, type, id, cells, refs, opts)
      end
    end
  end

  # --- cells ----------------------------------------------------------------------------------

  defp check_cells(type, cells) do
    keys = Map.keys(cells)

    cond do
      "active" in keys ->
        {:error, {:field_not_allowed, "active"}}

      Enum.any?(keys, &(&1 not in @importable[type] and &1 not in @ignored)) ->
        {:error, :field_not_allowed}

      true ->
        check_required(type, cells)
    end
  end

  defp check_required(type, cells) do
    case Enum.find(@required[type], &(not text?(Map.get(cells, &1)))) do
      nil ->
        if is_binary(Map.get(cells, "user_id", "")),
          do: :ok,
          else: {:error, {:field_invalid, "user_id"}}

      field ->
        {:error, {:field_invalid, field}}
    end
  end

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  # --- references -----------------------------------------------------------------------------

  # {:ok, %{header => record id | nil}} for every reference header of the type.
  defp resolve_all(prefix, type, cells, system) do
    Enum.reduce_while(@references[type], {:ok, %{}}, fn {field, target}, {:ok, acc} ->
      case Map.fetch(cells, field) do
        :error ->
          {:cont, {:ok, Map.put(acc, field, nil)}}

        {:ok, cell} when is_binary(cell) ->
          case find(prefix, target, system, cell) do
            {:ok, {:live, id}} -> {:cont, {:ok, Map.put(acc, field, id)}}
            _ -> {:halt, {:error, {:reference_not_found, field}}}
          end

        {:ok, _} ->
          {:halt, {:error, {:reference_not_found, field}}}
      end
    end)
  end

  # {:ok, nil | {:live, id} | {:deleted, id}}; one Ecto query, tenant by `prefix`, the table a
  # literal of @tables (never input).
  defp find(prefix, type, system, id) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      case Repo.one(query(type, system, id), prefix: prefix) do
        nil -> {:ok, nil}
        {record_id, false} -> {:ok, {:live, record_id}}
        {record_id, true} -> {:ok, {:deleted, record_id}}
      end
    end
  end

  for {type, table} <- @tables do
    defp query(unquote(type), system, id) do
      from(t in unquote(table),
        join: l in Latest,
        on: l.record_id == t.record_id and l.entity_type == unquote(type),
        where: t.external_ref_system == ^system and t.external_ref_id == ^id,
        select: {type(t.record_id, Ecto.UUID), l.deleted}
      )
    end
  end

  # --- create ---------------------------------------------------------------------------------

  defp create(prefix, type, cells, refs, ref, opts) do
    attrs =
      cells
      |> Map.drop(@ignored)
      |> Map.merge(Map.reject(refs, fn {_k, v} -> is_nil(v) end))
      |> Map.merge(%{"external_ref_system" => ref.system, "external_ref_id" => ref.id})

    transact(fn ->
      with {:ok, rec} <- create_fun(type, prefix, attrs, opts.("#create")) do
        {:ok, %{record_id: rec["record_id"], outcome: :created}}
      end
    end)
  end

  defp create_fun("org_unit", prefix, attrs, opts), do: Org.create_unit(prefix, attrs, opts)

  defp create_fun("org_position", prefix, attrs, opts),
    do: Org.create_position(prefix, attrs, opts)

  defp create_fun("org_employee", prefix, attrs, opts),
    do: Org.create_employee(prefix, attrs, opts)

  # --- upsert ---------------------------------------------------------------------------------

  defp upsert(prefix, type, id, cells, refs, opts) do
    {:ok, stored} = Org.lookup(prefix, id)

    case plan(type, cells, refs, stored) do
      {:error, _} = error ->
        error

      {:ok, %{update: update, move: move}} when update == %{} and move == :none ->
        {:ok, %{record_id: id, outcome: :unchanged}}

      {:ok, %{update: update, move: move}} ->
        transact(fn ->
          with :ok <- maybe_update(type, prefix, id, update, opts),
               :ok <- maybe_move(type, prefix, id, move, opts) do
            {:ok, %{record_id: id, outcome: :updated}}
          end
        end)
    end
  end

  defp plan("org_unit", cells, refs, stored) do
    update =
      %{}
      |> put_changed("name", cells["name"], stored)
      |> put_changed("code", cells["code"], stored)
      |> put_changed("legal_entity_id", refs["legal_entity_id"], stored)
      |> put_changed("site_id", refs["site_id"], stored)

    move = if refs["parent"] == stored["parent"], do: :none, else: {:unit, refs["parent"]}
    {:ok, %{update: update, move: move}}
  end

  defp plan("org_position", cells, refs, stored) do
    if refs["org_unit_id"] == stored["org_unit_id"] do
      update =
        %{}
        |> put_changed("name", cells["name"], stored)
        |> put_changed("code", cells["code"], stored)

      {:ok, %{update: update, move: :none}}
    else
      {:error, {:field_not_allowed, "org_unit_id"}}
    end
  end

  defp plan("org_employee", cells, refs, stored) do
    update =
      %{}
      |> put_changed("full_name", cells["full_name"], stored)
      |> put_changed("code", cells["code"], stored)
      |> put_changed("user_id", cells["user_id"], stored)

    move =
      if refs["org_unit_id"] == stored["org_unit_id"] and
           refs["position_id"] == stored["position_id"],
         do: :none,
         else: {:employee, refs["org_unit_id"], refs["position_id"]}

    {:ok, %{update: update, move: move}}
  end

  defp put_changed(acc, key, new, stored) do
    if new == Map.get(stored, key), do: acc, else: Map.put(acc, key, new)
  end

  defp maybe_update(_type, _prefix, _id, attrs, _opts) when attrs == %{}, do: :ok

  defp maybe_update(type, prefix, id, attrs, opts) do
    result =
      case type do
        "org_unit" -> Org.update_unit(prefix, id, attrs, opts.("#update"))
        "org_position" -> Org.update_position(prefix, id, attrs, opts.("#update"))
        "org_employee" -> Org.update_employee(prefix, id, attrs, opts.("#update"))
      end

    with {:ok, _} <- result, do: :ok
  end

  defp maybe_move(_type, _prefix, _id, :none, _opts), do: :ok

  defp maybe_move(_type, prefix, id, {:unit, parent}, opts) do
    with {:ok, _} <- Org.move_unit(prefix, id, parent, opts.("#move")), do: :ok
  end

  defp maybe_move(_type, prefix, id, {:employee, unit, position}, opts) do
    with {:ok, _} <- Org.transfer_employee(prefix, id, unit, position, opts.("#transfer")),
         do: :ok
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
