defmodule Letflow.Modules.Codes.Writes do
  @moduledoc """
  Write path of the `codes` module (GH #3615 / REQ-663): `receive_codes/3`, `assign_code/5`,
  `release_code/3`, `retire_code/3` and `change_code_value/4`, called through `Letflow.Modules.Codes`.
  The module is the Owner of its own types, so every write goes through `Letflow.Entities.Records` with
  `ManagedTypes.owner_for!(Letflow.Modules.Codes)`; no route, permission, migration or scope
  declaration is added (routes are REQ-667).

  Every function runs in one transaction under a tenant advisory lock keyed by the tenant schema and
  the text `codes` (bound parameter, INV-7), so two writers of one tenant's codes never interleave
  and R4 (one open assignment per code) holds without a storage guard. An accepted call writes one
  audit entry per changed code (`code.received`, `code.assigned`, `code.released`, `code.retired`,
  `code.value_changed`); a refusal writes neither a record nor an audit entry.

  `Records.update_record/3` replaces the whole document, so the tag and the assignment row are sent
  back as stored, merged with the change. A code id that is not a uuid, is unknown, soft-deleted, of
  another type or of another tenant is `{:error, :code_not_found}` (INV-5).

  ## Idempotency

  `opts` is a map with `:actor_id` (uuid) and `:idempotency_key` (text); a missing one raises
  `ArgumentError`. A call writes several rows, so each Records write gets the key plus a step suffix
  (`:tag`, `:assignment`, `:change`, `:0..:n` for a batch). Records detects a replay by failing its own
  multi, which a surrounding transaction cannot survive, so when the first derived key of the call is
  already claimed the function skips the lock and the checks and returns the CURRENT state, writing
  nothing. A replay with the same key and a different body (other entries, count or actor) is
  `{:error, :idempotency_key_reuse}` for `receive_codes/3`: each entry is offered to Records under its
  derived key and Records compares it with the stored event. The single-code writers still replay
  without comparing (runbook item 17).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Modules.Codes
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @kinds ~w(barcode qr epc tid)
  @targets ~w(location_node catalog_item catalog_lot)
  @max_batch 1000
  @kept ["record_id", "entity_type"]

  # --- receive --------------------------------------------------------------------------------

  @doc """
  Creates one `not_assigned` code per entry (maps with string keys `value` and `kind`). All or
  nothing: `{:error, :batch_size}` for a non-list, an empty list or more than 1000 entries;
  `{:error, {:entry_invalid, index, reason}}` for the first bad entry (`:value_invalid`,
  `:kind_invalid`, `:duplicate_in_batch`, `:value_taken`). Returns `{:ok, [code_map]}` in input order.
  """
  @spec receive_codes(String.t(), term(), map()) :: {:ok, [map()]} | {:error, term()}
  def receive_codes(prefix, entries, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "receive_codes/3")

    cond do
      not is_list(entries) or entries == [] or length(entries) > @max_batch ->
        {:error, :batch_size}

      replay?(prefix, idem <> ":0") ->
        replay_receive(prefix, entries, actor, idem)

      true ->
        Repo.transaction(fn ->
          lock!(prefix)

          with :ok <- check_entries(prefix, entries),
               {:ok, ids} <- create_all(prefix, entries, actor, idem) do
            Enum.map(ids, &view(prefix, &1))
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  # The key is claimed: the body must be the original one. Each entry is offered to Records under
  # its own derived key with the document the first call wrote; Records compares it with the stored
  # event (actor and field values) and answers the original or `:idempotency_key_reuse`, writing
  # nothing. A batch of another length leaves one derived key unclaimed or unused: also a reuse.
  defp replay_receive(prefix, entries, actor, idem) do
    n = length(entries)

    cond do
      replay?(prefix, "#{idem}:#{n}") ->
        {:error, :idempotency_key_reuse}

      not Enum.all?(0..(n - 1)//1, &replay?(prefix, "#{idem}:#{&1}")) ->
        {:error, :idempotency_key_reuse}

      true ->
        entries
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {entry, i}, {:ok, acc} ->
          case replay_entry(prefix, entry, actor, "#{idem}:#{i}") do
            {:ok, id} -> {:cont, {:ok, [id | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.map(&view(prefix, &1))}
          err -> err
        end
    end
  end

  defp replay_entry(prefix, %{"value" => v, "kind" => k}, actor, key) do
    create_record(
      prefix,
      "code_tag",
      %{"value" => v, "kind" => k, "status" => "not_assigned"},
      actor,
      key
    )
  end

  defp replay_entry(_prefix, _entry, _actor, _key), do: {:error, :idempotency_key_reuse}

  defp check_entries(prefix, entries) do
    indexed = Enum.with_index(entries)

    with :ok <- check_shapes(indexed) do
      values = for {%{"value" => v}, _} <- indexed, do: v
      taken = prefix |> tag_ids_by_values(values) |> Map.new(fn {_id, v} -> {v, true} end)
      check_unique(indexed, taken)
    end
  end

  defp check_shapes(indexed) do
    Enum.find_value(indexed, :ok, fn {entry, i} ->
      cond do
        not valid_value?(is_map(entry) && Map.get(entry, "value")) ->
          {:error, {:entry_invalid, i, :value_invalid}}

        Map.get(entry, "kind") not in @kinds ->
          {:error, {:entry_invalid, i, :kind_invalid}}

        true ->
          nil
      end
    end)
  end

  defp check_unique(indexed, taken) do
    result =
      Enum.reduce_while(indexed, MapSet.new(), fn {%{"value" => v}, i}, seen ->
        cond do
          MapSet.member?(seen, v) -> {:halt, {:error, {:entry_invalid, i, :duplicate_in_batch}}}
          Map.has_key?(taken, v) -> {:halt, {:error, {:entry_invalid, i, :value_taken}}}
          true -> {:cont, MapSet.put(seen, v)}
        end
      end)

    if match?({:error, _}, result), do: result, else: :ok
  end

  defp create_all(prefix, entries, actor, idem) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, i}, {:ok, acc} ->
      fv = %{"value" => entry["value"], "kind" => entry["kind"], "status" => "not_assigned"}

      with {:ok, id} <- create_record(prefix, "code_tag", fv, actor, "#{idem}:#{i}"),
           :ok <- audit(prefix, actor, "code.received", id, nil, fv) do
        {:cont, {:ok, [id | acc]}}
      else
        {:error, reason} -> {:halt, {:error, entry_error(reason, i)}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      err -> err
    end
  end

  defp entry_error(reason, i) do
    if taken_error?(reason), do: {:entry_invalid, i, :value_taken}, else: reason
  end

  # --- assign ---------------------------------------------------------------------------------

  @doc """
  Assigns a `not_assigned` code to a live, active record of `target_type` (`location_node`,
  `catalog_item` or `catalog_lot`). Refusals in order: `:code_not_found`, `:code_assigned`,
  `:code_retired`, `:target_type_not_allowed`, `:target_not_found`, `:target_inactive`, and
  `:assignment_conflict` when an open assignment already exists (nothing is written).
  Returns the code map of `Codes.resolve/2`.
  """
  @spec assign_code(String.t(), term(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def assign_code(prefix, code_id, target_type, target_id, opts)
      when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "assign_code/5")

    transact(prefix, code_id, idem, fn tag ->
      with :ok <- check_assignable(tag),
           {:ok, type} <- check_target_type(target_type),
           {:ok, target} <- check_target(prefix, type, target_id),
           :ok <- no_open(prefix, tag["record_id"]) do
        before = state(tag)
        now = now()

        a_fv = %{
          "code_id" => tag["record_id"],
          "target_type" => type,
          "target_id" => target,
          "assigned_at" => now,
          "assigned_by" => actor
        }

        with {:ok, aid} <-
               create_record(prefix, "code_assignment", a_fv, actor, idem <> ":assignment"),
             after_fv = Map.put(before, "status", "assigned"),
             {:ok, _} <- update_record(prefix, tag["record_id"], after_fv, actor, idem <> ":tag"),
             :ok <-
               audit(
                 prefix,
                 actor,
                 "code.assigned",
                 tag["record_id"],
                 before,
                 Map.put(after_fv, "assignment_id", aid)
               ) do
          :ok
        end
      end
    end)
  end

  defp check_assignable(%{"status" => "assigned"}), do: {:error, :code_assigned}
  defp check_assignable(%{"status" => "retired"}), do: {:error, :code_retired}
  defp check_assignable(_), do: :ok

  defp check_target_type(t) when is_binary(t) and t in @targets, do: {:ok, t}
  defp check_target_type(_), do: {:error, :target_type_not_allowed}

  defp check_target(prefix, type, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, target} <- ReadApi.lookup(prefix, uuid, [type]) do
      if target["active"] == true, do: {:ok, uuid}, else: {:error, :target_inactive}
    else
      _ -> {:error, :target_not_found}
    end
  end

  defp no_open(prefix, code_id) do
    if open_assignments(prefix, code_id) == [], do: :ok, else: {:error, :assignment_conflict}
  end

  # --- release / retire -----------------------------------------------------------------------

  @doc """
  Closes the open assignment of an `assigned` code and sets it `not_assigned`. A code that is not
  assigned is `{:error, :code_not_assigned}`; none or several open assignments is
  `{:error, :assignment_conflict}`.
  """
  @spec release_code(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def release_code(prefix, code_id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "release_code/3")

    transact(prefix, code_id, idem, fn tag ->
      with :ok <- if(tag["status"] == "assigned", do: :ok, else: {:error, :code_not_assigned}),
           [open] <- open_assignments(prefix, tag["record_id"]),
           {:ok, aid} <- close(prefix, open, actor, idem),
           before = state(tag),
           after_fv = Map.put(before, "status", "not_assigned"),
           {:ok, _} <- update_record(prefix, tag["record_id"], after_fv, actor, idem <> ":tag"),
           :ok <-
             audit(
               prefix,
               actor,
               "code.released",
               tag["record_id"],
               before,
               Map.put(after_fv, "assignment_id", aid)
             ) do
        :ok
      else
        {:error, _} = err -> err
        _ -> {:error, :assignment_conflict}
      end
    end)
  end

  @doc """
  Retires a code for good, closing its open assignment in the same transaction. An already retired
  code answers `{:ok, map}` with no write and no audit entry.
  """
  @spec retire_code(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def retire_code(prefix, code_id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "retire_code/3")

    transact(prefix, code_id, idem, fn
      %{"status" => "retired"} ->
        :noop

      tag ->
        before = state(tag)
        after_fv = Map.put(before, "status", "retired")

        with {:ok, aid} <- close_all(prefix, tag["record_id"], actor, idem),
             {:ok, _} <- update_record(prefix, tag["record_id"], after_fv, actor, idem <> ":tag"),
             :ok <-
               audit(
                 prefix,
                 actor,
                 "code.retired",
                 tag["record_id"],
                 before,
                 if(aid, do: Map.put(after_fv, "assignment_id", aid), else: after_fv)
               ) do
          :ok
        end
    end)
  end

  defp close_all(prefix, code_id, actor, idem) do
    case open_assignments(prefix, code_id) do
      [] -> {:ok, nil}
      [one] -> close(prefix, one, actor, idem)
      _ -> {:error, :assignment_conflict}
    end
  end

  # The only permitted update of a history row (R5): it closes an open assignment.
  defp close(prefix, %{"assignment_id" => aid}, actor, idem) do
    case ReadApi.lookup(prefix, aid, ["code_assignment"]) do
      {:ok, row} ->
        fv =
          row
          |> Map.drop(@kept)
          |> Map.merge(%{"released_at" => now(), "released_by" => actor})

        with {:ok, _} <-
               update_record(prefix, aid, fv, actor, idem <> ":assignment", "code_assignment") do
          {:ok, aid}
        end

      _ ->
        {:error, :assignment_conflict}
    end
  end

  # --- change value ---------------------------------------------------------------------------

  @doc """
  Gives a code a new value; the record id stays and the old value goes to `code_value_change`.
  Refusals in order: `:code_not_found`, `:code_retired`, `:value_invalid`, `:value_taken`. A value
  equal to the current one is `{:ok, map}` with no write. Status and open assignment are unchanged.
  """
  @spec change_code_value(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def change_code_value(prefix, code_id, new_value, opts)
      when is_binary(prefix) and is_map(opts) do
    {actor, idem} = opts!(opts, "change_code_value/4")

    transact(prefix, code_id, idem, fn tag ->
      cond do
        tag["status"] == "retired" ->
          {:error, :code_retired}

        not valid_value?(new_value) ->
          {:error, :value_invalid}

        new_value == tag["value"] ->
          :noop

        taken_by_other?(prefix, new_value, tag["record_id"]) ->
          {:error, :value_taken}

        true ->
          before = state(tag)
          after_fv = Map.put(before, "value", new_value)

          c_fv = %{
            "code_id" => tag["record_id"],
            "old_value" => tag["value"],
            "new_value" => new_value,
            "changed_at" => now(),
            "changed_by" => actor
          }

          with {:ok, _} <-
                 update_record(prefix, tag["record_id"], after_fv, actor, idem <> ":tag"),
               {:ok, _} <-
                 create_record(prefix, "code_value_change", c_fv, actor, idem <> ":change"),
               :ok <-
                 audit(prefix, actor, "code.value_changed", tag["record_id"], before, after_fv) do
            :ok
          end
      end
    end)
  end

  defp taken_by_other?(prefix, value, code_id) do
    prefix |> tag_ids_by_values([value]) |> Enum.any?(fn {id, _} -> id != code_id end)
  end

  # --- shared transaction ---------------------------------------------------------------------

  # `fun` gets the stored tag map and returns :ok, :noop or {:error, reason}. Returns the code view.
  defp transact(prefix, code_id, idem, fun) do
    if replay?(prefix, idem <> ":tag") do
      with {:ok, tag} <- fetch_tag(prefix, code_id), do: {:ok, view(prefix, tag["record_id"])}
    else
      Repo.transaction(fn ->
        lock!(prefix)

        with {:ok, tag} <- fetch_tag(prefix, code_id),
             result when result in [:ok, :noop] <- fun.(tag) do
          view(prefix, tag["record_id"])
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp fetch_tag(prefix, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, tag} <- ReadApi.lookup(prefix, uuid, ["code_tag"]) do
      {:ok, tag}
    else
      _ -> {:error, :code_not_found}
    end
  end

  defp replay?(prefix, key) do
    Repo.exists?(from(i in IdempotencyRecord, where: i.idempotency_key == ^key), prefix: prefix)
  end

  defp lock!(prefix) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [prefix <> ":codes"])
    :ok
  end

  # --- Records --------------------------------------------------------------------------------

  defp create_record(prefix, type, fv, actor, idem) do
    attrs = %{entity_type: type, field_values: fv, actor_id: actor, idempotency_key: idem}

    # scope-all: SEC-518-R1 (codes module, tenant-wide types; own-record system path)
    case Records.create_record(attrs, prefix, owner()) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, reason} -> {:error, map_taken(reason)}
    end
  end

  defp update_record(prefix, id, fv, actor, idem, type \\ "code_tag") do
    attrs = %{
      entity_type: type,
      record_id: id,
      field_values: fv,
      actor_id: actor,
      idempotency_key: idem
    }

    # scope-all: SEC-518-R1 (codes module, tenant-wide types; own-record system path)
    case Records.update_record(attrs, prefix, owner()) do
      {:ok, _} -> {:ok, id}
      {:error, reason} -> {:error, map_taken(reason)}
    end
  end

  defp owner, do: ManagedTypes.owner_for!(Codes)

  defp map_taken(reason), do: if(taken_error?(reason), do: :value_taken, else: reason)

  defp taken_error?({:record_payload_invalid, violations}),
    do: inspect(violations) =~ "uq_code_tag_value"

  defp taken_error?(_), do: false

  # INV-8: Audit raises on a database failure; the transaction is already aborted then, so the
  # rescue only turns the raise into a refusal and runs no further query.
  defp audit(prefix, actor, action, record_id, before, after_state) do
    entry = %{
      actor_id: actor,
      action: action,
      resource_type: "code_tag",
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

  # --- reads ----------------------------------------------------------------------------------

  defp tag_ids_by_values(prefix, values) do
    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == "code_tag" and l.deleted == false and
            fragment("?->>'value' = ANY(?)", l.field_values, type(^values, {:array, :string})),
        select: {l.record_id, fragment("?->>'value'", l.field_values)}
      ),
      prefix: prefix
    )
  end

  defp open_assignments(prefix, code_id) do
    prefix |> Codes.assignment_history(code_id) |> Enum.filter(&is_nil(&1["released_at"]))
  end

  # The `Codes.resolve/2` shape, also for a retired code (which `resolve/2` refuses).
  defp view(prefix, code_id) do
    {:ok, tag} = ReadApi.lookup(prefix, code_id, ["code_tag"])

    open =
      if tag["status"] == "assigned", do: List.first(open_assignments(prefix, code_id)), else: nil

    %{
      "code_id" => tag["record_id"],
      "value" => tag["value"],
      "kind" => tag["kind"],
      "status" => tag["status"],
      "target_type" => open && open["target_type"],
      "target_id" => open && open["target_id"],
      "assignment_id" => open && open["assignment_id"]
    }
  end

  defp state(tag), do: Map.drop(tag, @kept)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp valid_value?(v),
    do: is_binary(v) and v != "" and String.valid?(v) and not String.contains?(v, <<0>>)

  defp opts!(opts, fun) do
    actor = Map.get(opts, :actor_id)
    idem = Map.get(opts, :idempotency_key)

    unless is_binary(actor) and match?({:ok, _}, Ecto.UUID.cast(actor)),
      do: raise(ArgumentError, "#{fun} opts :actor_id must be a uuid")

    unless is_binary(idem), do: raise(ArgumentError, "#{fun} opts :idempotency_key must be text")

    {actor, idem}
  end
end
