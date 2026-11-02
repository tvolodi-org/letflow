defmodule Letflow.Modules.Locations.Links do
  @moduledoc """
  Write path of `location_org_unit_link` (GH #3616 / REQ-662, decisions 0050 D3.2, 0066):
  `link_unit_location/4` and `unlink_unit_location/4`, called through `Letflow.Modules.Locations`.

  Each call is one transaction under the tenant tree lock (`Letflow.Modules.Locations.Tree.lock!/1`,
  so a link serialises with the retire and move of a location and a find-then-create of one pair is
  race-free; the unique index on the pair stays the backstop), writes through
  `Letflow.Entities.Records` with the locations module authority, and appends one audit entry
  (`location_org_unit_link.created|reactivated|retired`). A refusal writes neither record nor entry.

  A link is never deleted: unlinking sets `active` false, linking a pair that has an inactive link
  sets `active` true on the same record (the pair is unique). Linking an already linked pair is
  `{:ok, link}` with no write and no audit entry.

  Linking refuses, in this order: `:unit_not_found` (not a uuid, unknown, soft-deleted, another type
  or another tenant: one answer), `:unit_inactive`, `:location_not_found`, `:location_inactive`.
  Unlinking checks no liveness (it works when the unit or the location is retired) and answers
  `:link_not_found` for a pair without an active link, whatever the reason.

  Limits: a unit retired by `Letflow.Modules.Org.retire_unit/3` between the check and the commit
  (a different lock, in module org) can still get one link; `linked?/3` re-reads the unit and the
  link can be unlinked. No stock check exists on unlink (no ledger code yet); the slice that first
  posts stock under the D-065 rule decides whether an unlink with stock is refused.

  `prefix` must come from the authenticated tenant on the server side; it is the only tenant input.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Locations.Tree
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @type_name "location_org_unit_link"
  @fields ~w(location_id org_unit_id active)

  @doc """
  Links org unit `org_unit_id` to location `location_id` and returns the link in the
  `Letflow.Modules.ReadApi.lookup/3` shape (`record_id`, `entity_type`, `location_id`, `org_unit_id`,
  `active`). `opts` (a map): `:actor_id` (uuid) and `:idempotency_key` (text); a missing or bad one
  raises `ArgumentError`. See the moduledoc for the refusals. A replay with the same key returns the
  original result without a second record or audit entry.
  """
  @spec link_unit_location(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def link_unit_location(prefix, org_unit_id, location_id, opts)
      when is_binary(prefix) and is_map(opts) do
    {actor_id, idem} = write_opts!(opts, "link_unit_location/4")

    if replay?(prefix, idem) do
      replay_link(prefix, org_unit_id, location_id, actor_id, idem)
    else
      Repo.transaction(fn ->
        Tree.lock!(prefix)

        with {:ok, unit} <- check_unit(prefix, org_unit_id),
             {:ok, loc} <- check_location(prefix, location_id),
             {:ok, link} <- plan_link(prefix, unit, loc, actor_id, idem) do
          link
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Unlinks the pair: the active link gets `active` false (never deleted). `{:error, :link_not_found}`
  for a pair that has no active link (never linked, already unlinked, a non-uuid or unknown id, an
  id of another tenant). Works when the unit or the location is retired. `opts` as
  `link_unit_location/4`.
  """
  @spec unlink_unit_location(String.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, term()}
  def unlink_unit_location(prefix, org_unit_id, location_id, opts)
      when is_binary(prefix) and is_map(opts) do
    {actor_id, idem} = write_opts!(opts, "unlink_unit_location/4")

    if replay?(prefix, idem) do
      replay_unlink(prefix, org_unit_id, location_id, actor_id, idem)
    else
      Repo.transaction(fn ->
        Tree.lock!(prefix)

        case do_unlink(prefix, org_unit_id, location_id, actor_id, idem) do
          {:ok, link} -> link
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # --- link ------------------------------------------------------------------------------------

  defp check_unit(prefix, org_unit_id) do
    with {:ok, uuid} <- cast(org_unit_id, :unit_not_found),
         {:ok, unit} <- lookup_unit(prefix, uuid) do
      if unit["active"] == true, do: {:ok, unit["record_id"]}, else: {:error, :unit_inactive}
    end
  end

  defp lookup_unit(prefix, uuid) do
    case Org.lookup(prefix, uuid) do
      {:ok, %{"entity_type" => "org_unit"} = unit} -> {:ok, unit}
      _ -> {:error, :unit_not_found}
    end
  end

  defp check_location(prefix, location_id) do
    with {:ok, uuid} <- cast(location_id, :location_not_found) do
      case Locations.lookup(prefix, uuid) do
        {:ok, %{"active" => true} = loc} -> {:ok, loc["record_id"]}
        {:ok, _} -> {:error, :location_inactive}
        {:error, _} -> {:error, :location_not_found}
      end
    end
  end

  defp plan_link(prefix, unit, loc, actor_id, idem) do
    case find_link(prefix, unit, loc) do
      {:active, id, _fv} ->
        ReadApi.lookup(prefix, id, [@type_name])

      {:inactive, id, fv} ->
        change(prefix, id, fv, true, "location_org_unit_link.reactivated", actor_id, idem)

      :none ->
        fv = %{"location_id" => loc, "org_unit_id" => unit, "active" => true}

        with {:ok, id} <- write_create(prefix, fv, actor_id, idem),
             {:ok, link} <- ReadApi.lookup(prefix, id, [@type_name]),
             :ok <- audit(prefix, actor_id, "location_org_unit_link.created", id, nil, fv) do
          {:ok, link}
        end
    end
  end

  # --- unlink ----------------------------------------------------------------------------------

  defp do_unlink(prefix, org_unit_id, location_id, actor_id, idem) do
    with {:ok, unit} <- cast(org_unit_id, :link_not_found),
         {:ok, loc} <- cast(location_id, :link_not_found),
         {:active, id, fv} <- find_link(prefix, unit, loc) do
      change(prefix, id, fv, false, "location_org_unit_link.retired", actor_id, idem)
    else
      {:error, _} = err -> err
      _ -> {:error, :link_not_found}
    end
  end

  # --- shared ----------------------------------------------------------------------------------

  # One update of the stored document with `active` set, then the read and the audit entry.
  defp change(prefix, id, fv, active, action, actor_id, idem) do
    new_fv = Map.put(fv, "active", active)

    with {:ok, _} <- write_update(prefix, id, new_fv, actor_id, idem),
         {:ok, link} <- ReadApi.lookup(prefix, id, [@type_name]),
         :ok <- audit(prefix, actor_id, action, id, fv, new_fv) do
      {:ok, link}
    end
  end

  # The link of the pair among live records, any `active`. Ids are bound parameters (INV-7).
  defp find_link(prefix, unit, loc) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^@type_name and not r.deleted and
            fragment("?->>'location_id' = ?", r.field_values, ^loc) and
            fragment("?->>'org_unit_id' = ?", r.field_values, ^unit),
        select: {r.record_id, r.field_values},
        limit: 1
      )

    case Repo.one(query, prefix: prefix) do
      nil ->
        :none

      {id, fv} ->
        fv = Map.take(fv, @fields)
        if fv["active"] == true, do: {:active, id, fv}, else: {:inactive, id, fv}
    end
  end

  defp cast(id, reason) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      _ -> {:error, reason}
    end
  end

  defp cast(_, reason), do: {:error, reason}

  # --- replay ----------------------------------------------------------------------------------

  # Records detects a replay by failing its own multi, which a surrounding transaction cannot
  # survive. A claimed key therefore skips the lock and the checks and goes to Records alone, which
  # answers the original or `:idempotency_key_reuse`. The kind (create or update) must be the one of
  # the first call, because the fingerprint compares the event type: an existing link is tried as an
  # update first and, only on `:idempotency_key_reuse`, as the create the first call was.
  defp replay?(prefix, idem) do
    Repo.exists?(from(i in IdempotencyRecord, where: i.idempotency_key == ^idem), prefix: prefix)
  end

  defp replay_link(prefix, org_unit_id, location_id, actor_id, idem) do
    with {:ok, unit} <- cast(org_unit_id, :unit_not_found),
         {:ok, loc} <- cast(location_id, :location_not_found) do
      create_fv = %{"location_id" => loc, "org_unit_id" => unit, "active" => true}

      case find_link(prefix, unit, loc) do
        :none ->
          replay_create(prefix, create_fv, actor_id, idem)

        {_, id, fv} ->
          case write_update(prefix, id, Map.put(fv, "active", true), actor_id, idem) do
            {:ok, _} -> ReadApi.lookup(prefix, id, [@type_name])
            {:error, :idempotency_key_reuse} -> replay_create(prefix, create_fv, actor_id, idem)
            {:error, _} = err -> err
          end
      end
    end
  end

  defp replay_create(prefix, fv, actor_id, idem) do
    with {:ok, id} <- write_create(prefix, fv, actor_id, idem) do
      ReadApi.lookup(prefix, id, [@type_name])
    end
  end

  defp replay_unlink(prefix, org_unit_id, location_id, actor_id, idem) do
    with {:ok, unit} <- cast(org_unit_id, :link_not_found),
         {:ok, loc} <- cast(location_id, :link_not_found) do
      case find_link(prefix, unit, loc) do
        :none ->
          {:error, :link_not_found}

        {_, id, fv} ->
          with {:ok, _} <- write_update(prefix, id, Map.put(fv, "active", false), actor_id, idem) do
            ReadApi.lookup(prefix, id, [@type_name])
          end
      end
    end
  end

  # --- Records writes --------------------------------------------------------------------------

  defp write_create(prefix, fv, actor_id, idem) do
    attrs = %{
      entity_type: @type_name,
      field_values: fv,
      actor_id: actor_id,
      idempotency_key: idem
    }

    # scope-all: SEC-518-R1 (locations module, link type scoped by org_unit_id; own-record system path)
    case Records.create_record(attrs, prefix, ManagedTypes.owner_for!(Letflow.Modules.Locations)) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = err -> err
    end
  end

  defp write_update(prefix, record_id, fv, actor_id, idem) do
    attrs = %{
      entity_type: @type_name,
      record_id: record_id,
      field_values: fv,
      actor_id: actor_id,
      idempotency_key: idem
    }

    # scope-all: SEC-518-R1 (locations module, link type scoped by org_unit_id; own-record system path)
    case Records.update_record(attrs, prefix, ManagedTypes.owner_for!(Letflow.Modules.Locations)) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = err -> err
    end
  end

  # INV-8: Audit raises on a database failure; the transaction is already aborted then, so the
  # rescue only turns the raise into a refusal and runs no further query.
  defp audit(prefix, actor_id, action, record_id, before, after_state) do
    entry = %{
      actor_id: actor_id,
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

  defp write_opts!(opts, fname) do
    actor_id = fetch_opt!(opts, :actor_id, fname)
    idem = fetch_opt!(opts, :idempotency_key, fname)

    unless is_binary(actor_id) and match?({:ok, _}, Ecto.UUID.cast(actor_id)),
      do: raise(ArgumentError, "#{fname} opts :actor_id must be a uuid")

    unless is_binary(idem),
      do: raise(ArgumentError, "#{fname} opts :idempotency_key must be text")

    {actor_id, idem}
  end

  defp fetch_opt!(opts, key, fname) do
    case Map.fetch(opts, key) do
      {:ok, v} when not is_nil(v) -> v
      _ -> raise ArgumentError, "#{fname} opts needs #{inspect(key)}"
    end
  end
end
