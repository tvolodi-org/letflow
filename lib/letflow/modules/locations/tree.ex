defmodule Letflow.Modules.Locations.Tree do
  @moduledoc """
  Write path of the `location_node` tree (GH #3591 / REQ-645, decision 0066): `create_node/3`, called
  through `Letflow.Modules.Locations.create_node/3`. The moves and retirements of REQ-646 are added
  here, beside it, and take the same tree lock (`lock!/1`).

  The tree is stored as the parent link only (a real foreign key in the pack); no path and no depth
  is stored and no depth bound exists. The module is the Owner of its own type, so the write goes
  through `Letflow.Entities.Records` with the module authority; the scope index of decision 0051 is
  not touched.

  `prefix` must come from the authenticated tenant on the server side, never from attrs or opts.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Records
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @types ["location_node"]
  @allowed ~w(code name node_kind parent_id segment address location_type external_ref_system external_ref_id)
  @optional ~w(parent_id segment address location_type external_ref_system external_ref_id)

  @doc """
  Creates a `location_node` in tenant schema `prefix` and returns the live record map of
  `Letflow.Modules.Locations.lookup/2`.

  `attrs` (string keys): `code`, `name`, `node_kind` (any non-blank text) are required; `parent_id`
  (nil or absent = root), `segment` (no dash), `address`, `location_type`, `external_ref_system`,
  `external_ref_id` are optional (a nil value is dropped). Any other key is
  `{:error, {:field_not_allowed, key}}`. The node is created active.

  `opts` (a map, a missing key raises `ArgumentError`): `:actor_id` (uuid), `:idempotency_key`
  (text), and optional `:address_pattern`: absent or nil = the address is free (stored as given or
  not stored); `:segments` = the address is the segments of the ancestors from the top down plus
  the node's own segment, joined by `-`, an ancestor without a segment is skipped.

  Refusals, in this order: `:parent_not_found` (not a uuid, unknown, retired, another type or
  another tenant: one answer), `:parent_inactive`, `{:field_not_allowed, key}`,
  `{:field_invalid, field}`, then the record errors of `Records.create_record/3` (a duplicate code or
  address is `{:record_payload_invalid, violations}`). Nothing is written on a refusal. A replay with
  the same idempotency key returns the original record (the parent checks are not repeated).
  """
  @spec create_node(prefix :: String.t(), attrs :: map(), opts :: map()) ::
          {:ok, map()} | {:error, term()}
  def create_node(prefix, attrs, opts)
      when is_binary(prefix) and is_map(attrs) and is_map(opts) do
    actor_id = fetch_opt!(opts, :actor_id)
    idem = fetch_opt!(opts, :idempotency_key)

    unless is_binary(actor_id) and match?({:ok, _}, Ecto.UUID.cast(actor_id)),
      do: raise(ArgumentError, "create_node/3 opts :actor_id must be a uuid")

    unless is_binary(idem),
      do: raise(ArgumentError, "create_node/3 opts :idempotency_key must be text")

    if replay?(prefix, idem) do
      replay(prefix, attrs, actor_id, idem)
    else
      create_locked(prefix, attrs, actor_id, idem, Map.get(opts, :address_pattern))
    end
  end

  # Records detects a replay by failing its own multi and reading the original afterwards, which a
  # surrounding transaction cannot survive. A key that is already claimed therefore skips the lock
  # and the checks and goes to Records alone, which returns the original or `:idempotency_key_reuse`.
  defp replay?(prefix, idem) do
    Repo.exists?(from(i in IdempotencyRecord, where: i.idempotency_key == ^idem), prefix: prefix)
  end

  defp replay(prefix, attrs, actor_id, idem) do
    fv = attrs |> drop_nils() |> Map.put("active", true)

    with {:ok, record_id} <- write(prefix, fv, actor_id, idem) do
      ReadApi.lookup(prefix, record_id, @types)
    end
  end

  defp create_locked(prefix, attrs, actor_id, idem, pattern) do
    Repo.transaction(fn ->
      lock!(prefix)

      with {:ok, parent_id} <- check_parent(prefix, attrs),
           :ok <- check_keys(attrs),
           :ok <- check_required(attrs),
           :ok <- check_segment(attrs),
           {:ok, fv} <- build_values(prefix, attrs, parent_id, pattern),
           {:ok, record_id} <- write(prefix, fv, actor_id, idem),
           {:ok, node} <- ReadApi.lookup(prefix, record_id, @types) do
        node
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc false
  # The tree lock: one transaction-scoped advisory lock per tenant, key bound as a parameter.
  @spec lock!(String.t()) :: :ok
  def lock!(prefix) when is_binary(prefix) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":location_node_tree"
    ])

    :ok
  end

  defp fetch_opt!(opts, key) do
    case Map.fetch(opts, key) do
      {:ok, v} when not is_nil(v) -> v
      _ -> raise ArgumentError, "create_node/3 opts needs #{inspect(key)}"
    end
  end

  # a/b: parent exists and is live (any failure to read is one answer), and is active.
  defp check_parent(prefix, attrs) do
    case Map.get(attrs, "parent_id") do
      nil ->
        {:ok, nil}

      pid ->
        case ReadApi.lookup(prefix, pid, @types) do
          {:ok, %{"active" => true}} -> {:ok, pid}
          {:ok, _} -> {:error, :parent_inactive}
          {:error, :not_found} -> {:error, :parent_not_found}
        end
    end
  end

  # c: first offending key in sorted order.
  defp check_keys(attrs) do
    case attrs |> Map.keys() |> Enum.reject(&(&1 in @allowed)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> {:error, {:field_not_allowed, key}}
    end
  end

  # d
  defp check_required(attrs) do
    Enum.find_value(~w(node_kind code name), :ok, fn f ->
      if non_blank?(Map.get(attrs, f)), do: nil, else: {:error, {:field_invalid, f}}
    end)
  end

  defp check_segment(attrs) do
    case Map.get(attrs, "segment") do
      nil ->
        :ok

      seg ->
        if non_blank?(seg) and not String.contains?(seg, "-"),
          do: :ok,
          else: {:error, {:field_invalid, "segment"}}
    end
  end

  defp non_blank?(v), do: is_binary(v) and String.trim(v) != ""

  # e
  defp build_values(prefix, attrs, parent_id, pattern) do
    fv = attrs |> drop_nils() |> Map.put("active", true)

    case pattern do
      nil ->
        {:ok, fv}

      :segments ->
        cond do
          Map.has_key?(fv, "address") ->
            {:error, {:field_invalid, "address"}}

          not Map.has_key?(fv, "segment") ->
            {:error, {:field_invalid, "segment"}}

          true ->
            segs = ancestor_segments(prefix, parent_id) ++ [fv["segment"]]
            {:ok, Map.put(fv, "address", Enum.join(segs, "-"))}
        end

      _other ->
        {:error, {:field_invalid, "address"}}
    end
  end

  defp drop_nils(attrs),
    do: attrs |> Enum.reject(fn {k, v} -> is_nil(v) and k in @optional end) |> Map.new()

  # Top-down segments of the ancestors; stops at a nil, unknown or already visited id.
  defp ancestor_segments(prefix, parent_id), do: walk(prefix, parent_id, MapSet.new(), [])

  defp walk(_prefix, nil, _seen, acc), do: acc

  defp walk(prefix, id, seen, acc) do
    with false <- MapSet.member?(seen, id),
         {:ok, node} <- ReadApi.lookup(prefix, id, @types) do
      acc = if non_blank?(node["segment"]), do: [node["segment"] | acc], else: acc
      walk(prefix, node["parent_id"], MapSet.put(seen, id), acc)
    else
      _ -> acc
    end
  end

  # f
  defp write(prefix, fv, actor_id, idem) do
    attrs = %{
      entity_type: "location_node",
      field_values: fv,
      actor_id: actor_id,
      idempotency_key: idem
    }

    # scope-all: SEC-518-R1 (locations module, tenant-wide type; own-record system path)
    case Records.create_record(attrs, prefix, ManagedTypes.owner_for!(Letflow.Modules.Locations)) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = err -> err
    end
  end
end
