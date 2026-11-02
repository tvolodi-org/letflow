defmodule Letflow.Modules.CatalogItems.Lots do
  @moduledoc """
  Write path of the `catalog_lot` master (GH #3614 / REQ-664): `create_lot/3`, `update_lot/4` and
  `retire_lot/3`, called through `Letflow.Modules.CatalogItems`. The module is the Owner of its own
  types, so the writes go through `Letflow.Entities.Records` with the module authority; no route, no
  permission and no scope declaration is added.

  Every writer runs in one transaction under a tenant advisory lock (it serialises the check of one
  code per item, which the pack's validator enforces), writes the record and appends one audit entry
  (`catalog_lot.created`, `catalog_lot.updated`, `catalog_lot.retired`); a refusal writes neither.
  Every value is checked before `Records` is called, because `Records` raises on a malformed date or a
  non-uuid `item_id` (runbook item 19).

  `Records.update_record/3` replaces the whole document, so `update_lot/4` and `retire_lot/3` send the
  stored fields merged with the change. `prefix` must come from the authenticated tenant on the server
  side, never from attrs or opts.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @type_name "catalog_lot"
  @create_keys ~w(item_id code producer mark expiry_date external_ref_system external_ref_id)
  @update_keys ~w(producer mark expiry_date external_ref_system external_ref_id)
  @text_keys ~w(producer mark external_ref_system external_ref_id)
  @kept ["record_id", "entity_type"]

  @doc """
  Creates a lot of an active item. `attrs` (string keys): `item_id` and `code` are required;
  `producer`, `mark`, `expiry_date` (`YYYY-MM-DD`), `external_ref_system`, `external_ref_id` are
  optional (nil is dropped). Any other key is `{:error, {:field_not_allowed, key}}`.

  Refusals: `{:field_not_allowed, key}`, `:item_not_found` (not a uuid, unknown, retired record of
  another type, another tenant: one answer), `:item_inactive`, `{:field_invalid, field}`, then the
  record errors of `Records.create_record/3` (a second lot code for the same item is
  `{:record_payload_invalid, violations}`). `opts` is a map with `:actor_id` (uuid) and
  `:idempotency_key` (text); a missing key raises `ArgumentError`. Returns the record map of
  `CatalogItems.lookup/2`.
  """
  @spec create_lot(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_lot(prefix, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "create_lot/3")

    if is_map(attrs) do
      persist(prefix, actor, idem, "catalog_lot.created", fn -> prepare_create(prefix, attrs) end)
    else
      {:error, {:field_invalid, "attrs"}}
    end
  end

  @doc """
  Changes the optional fields (`producer mark expiry_date external_ref_system external_ref_id`) of a
  lot; a nil value clears the field. `item_id`, `code`, `active` and any other key is
  `{:error, {:field_not_allowed, key}}`. An unknown lot (or the id of another type or tenant) is
  `{:error, :lot_not_found}`, checked first. A retired lot may still be updated.
  """
  @spec update_lot(String.t(), term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def update_lot(prefix, id, attrs, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "update_lot/4")

    if is_map(attrs) do
      persist(prefix, actor, idem, "catalog_lot.updated", fn ->
        prepare_update(prefix, id, attrs)
      end)
    else
      {:error, {:field_invalid, "attrs"}}
    end
  end

  @doc """
  Retires a lot (`active` false); it is never deleted. A lot that is already retired is returned
  unchanged with no write and no audit entry. An unknown lot is `{:error, :lot_not_found}`.
  """
  @spec retire_lot(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def retire_lot(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "retire_lot/3")
    persist(prefix, actor, idem, "catalog_lot.retired", fn -> prepare_retire(prefix, id) end)
  end

  # --- transaction ----------------------------------------------------------------------------

  # `prepare` returns `{:write, kind, record_id | nil, before, fv}`, `{:noop, lot}` or `{:error, _}`.
  defp persist(prefix, actor, idem, action, prepare) do
    if replay?(prefix, idem) do
      # Records detects a replay by failing its own multi, which a surrounding transaction cannot
      # survive: a claimed key goes to Records alone and returns the original or the reuse error.
      with {:write, kind, id, _before, fv} <- prepare.(),
           {:ok, record_id} <- write(prefix, kind, id, fv, actor, idem) do
        ReadApi.lookup(prefix, record_id, [@type_name])
      else
        {:noop, lot} -> {:ok, lot}
        {:error, _} = err -> err
      end
    else
      Repo.transaction(fn ->
        lock!(prefix)

        case prepare.() do
          {:noop, lot} ->
            lot

          {:write, kind, id, before, fv} ->
            with {:ok, record_id} <- write(prefix, kind, id, fv, actor, idem),
                 {:ok, lot} <- ReadApi.lookup(prefix, record_id, [@type_name]),
                 :ok <- audit(prefix, actor, action, record_id, before, state(lot)) do
              lot
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  defp replay?(prefix, idem) do
    Repo.exists?(from(i in IdempotencyRecord, where: i.idempotency_key == ^idem), prefix: prefix)
  end

  defp lock!(prefix) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":catalog_lot"
    ])

    :ok
  end

  defp write(prefix, :create, _id, fv, actor, idem) do
    attrs = %{entity_type: @type_name, field_values: fv, actor_id: actor, idempotency_key: idem}

    # scope-all: SEC-518-R1 (catalog_items module, tenant-wide type; own-record system path)
    case Records.create_record(attrs, prefix, owner()) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = err -> err
    end
  end

  defp write(prefix, :update, id, fv, actor, idem) do
    attrs = %{
      entity_type: @type_name,
      record_id: id,
      field_values: fv,
      actor_id: actor,
      idempotency_key: idem
    }

    # scope-all: SEC-518-R1 (catalog_items module, tenant-wide type; own-record system path)
    case Records.update_record(attrs, prefix, owner()) do
      {:ok, _} -> {:ok, id}
      {:error, _} = err -> err
    end
  end

  defp owner, do: ManagedTypes.owner_for!(CatalogItems)

  # INV-8: Audit raises on a database failure; the transaction is already aborted then, so the
  # rescue only turns the raise into a refusal and runs no further query.
  defp audit(prefix, actor, action, record_id, before, after_state) do
    entry = %{
      actor_id: actor,
      action: action,
      resource_type: @type_name,
      resource_id: record_id,
      before_state: before,
      after_state: after_state
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  # --- preparation ----------------------------------------------------------------------------

  defp prepare_create(prefix, attrs) do
    with :ok <- check_keys(attrs, @create_keys),
         {:ok, item_id} <- check_item(prefix, Map.get(attrs, "item_id")),
         :ok <- check_code(Map.get(attrs, "code")),
         {:ok, _} <- check_values(attrs) do
      fv =
        attrs
        |> drop_nils()
        |> Map.put("item_id", item_id)
        |> Map.put("active", true)

      {:write, :create, nil, nil, fv}
    end
  end

  defp prepare_update(prefix, id, attrs) do
    with {:ok, lot} <- fetch_lot(prefix, id),
         :ok <- check_keys(attrs, @update_keys),
         {:ok, _} <- check_values(attrs) do
      stored = state(lot)
      cleared = for {k, nil} <- attrs, do: k
      fv = stored |> Map.drop(cleared) |> Map.merge(drop_nils(attrs))
      {:write, :update, lot["record_id"], stored, fv}
    end
  end

  defp prepare_retire(prefix, id) do
    with {:ok, lot} <- fetch_lot(prefix, id) do
      if lot["active"] == false do
        {:noop, lot}
      else
        stored = state(lot)
        {:write, :update, lot["record_id"], stored, Map.put(stored, "active", false)}
      end
    end
  end

  defp fetch_lot(prefix, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, lot} <- ReadApi.lookup(prefix, uuid, [@type_name]) do
      {:ok, lot}
    else
      _ -> {:error, :lot_not_found}
    end
  end

  defp state(lot), do: Map.drop(lot, @kept)

  defp check_keys(attrs, allowed) do
    case attrs |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> {:error, {:field_not_allowed, key}}
    end
  end

  defp check_item(prefix, item_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(item_id),
         {:ok, %{"entity_type" => "catalog_item"} = item} <- CatalogItems.lookup(prefix, uuid) do
      if item["active"] == true, do: {:ok, uuid}, else: {:error, :item_inactive}
    else
      _ -> {:error, :item_not_found}
    end
  end

  defp check_code(code) do
    if is_binary(code) and String.trim(code) != "",
      do: :ok,
      else: {:error, {:field_invalid, "code"}}
  end

  defp check_values(attrs) do
    bad_text =
      Enum.find(@text_keys, fn k ->
        v = Map.get(attrs, k)
        not is_nil(v) and not is_binary(v)
      end)

    cond do
      bad_text -> {:error, {:field_invalid, bad_text}}
      not valid_date?(Map.get(attrs, "expiry_date")) -> {:error, {:field_invalid, "expiry_date"}}
      true -> {:ok, attrs}
    end
  end

  defp valid_date?(nil), do: true

  defp valid_date?(v) when is_binary(v),
    do: Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, v) and match?({:ok, _}, Date.from_iso8601(v))

  defp valid_date?(_), do: false

  defp drop_nils(attrs), do: attrs |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp opts!(opts, fun) do
    actor = Map.get(opts, :actor_id)
    idem = Map.get(opts, :idempotency_key)

    unless is_binary(actor) and match?({:ok, _}, Ecto.UUID.cast(actor)),
      do: raise(ArgumentError, "#{fun} opts :actor_id must be a uuid")

    unless is_binary(idem), do: raise(ArgumentError, "#{fun} opts :idempotency_key must be text")

    {actor, idem}
  end
end
