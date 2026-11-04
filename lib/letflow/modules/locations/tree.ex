defmodule Letflow.Modules.Locations.Tree do
  @moduledoc """
  Write path of the `location_node` tree (GH #3591 / REQ-645, GH #3588 / REQ-646, decision 0066):
  `create_node/3`, `move_node/4`, `update_node/4` and `retire_node/3`, called through
  `Letflow.Modules.Locations`, and the subtree read `descendant_ids/2`. Every write takes the same
  tenant-wide tree lock (`lock!/1`) first, so two moves cannot each pass the cycle check and then
  close a loop together.

  A move is one `Records.update_record` of the moved node (its `parent_id`); the descendants are not
  written and no address is rewritten (the address is composed once, at create).

  The tree is stored as the parent link only (a real foreign key in the pack); no path and no depth
  is stored and no depth bound exists. The module is the Owner of its own type, so the write goes
  through `Letflow.Entities.Records` with the module authority; the scope index of decision 0051 is
  not touched.

  Audit (GH #3741 / REQ-705, decision 0078 D8): each accepted write appends one entry through
  `Letflow.Audit.insert_entry/3` inside the write's transaction, after the record write and under the
  tree lock, with `resource_type` `location_node`, the node's record id and the `:actor_id`:
  `location_node.created` (before nil), `location_node.updated`, `location_node.moved` and
  `location_node.retired`, with the stored field values before and after. A refused call, a no-op and a
  replay write none; a database failure of the entry rolls the write back as `{:error, :audit_failed}`.
  The import of the tree writes only through these functions, so imported rows are audited too.

  `prefix` must come from the authenticated tenant on the server side, never from attrs or opts.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
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
           {:ok, node} <- ReadApi.lookup(prefix, record_id, @types),
           {:ok, after_fv} <- stored_fields(prefix, node),
           :ok <- audit(prefix, actor_id, "location_node.created", record_id, nil, after_fv) do
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

  defp fetch_opt!(opts, key, fname \\ "create_node/3") do
    case Map.fetch(opts, key) do
      {:ok, v} when not is_nil(v) -> v
      _ -> raise ArgumentError, "#{fname} opts needs #{inspect(key)}"
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

  # ---------------------------------------------------------------------------------------------
  # REQ-646: move, update, retire, subtree read
  # ---------------------------------------------------------------------------------------------

  @updatable ~w(name node_kind segment address location_type external_ref_system external_ref_id)
  @prefix_re ~r/\A[a-z0-9_]+\z/

  @doc """
  Moves node `node_id` under `new_parent_id` (nil = to the top) with one write of the node only.

  Refusals, in this order: `:node_not_found` (not a uuid, unknown, retired-by-delete, another type or
  another tenant: one answer), `:parent_not_found`, `:parent_inactive`, `:cycle` (the new parent is
  the node or one of its descendants, found by walking the parent chain upward with a visited set, so
  a damaged chain ends too). Moving under the current parent is `{:ok, node}` with no event. The
  descendants and every address stay as they are. `opts`: `:actor_id`, `:idempotency_key`.
  """
  @spec move_node(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def move_node(prefix, node_id, new_parent_id, opts)
      when is_binary(prefix) and is_map(opts) do
    {actor_id, idem} = write_opts!(opts, "move_node/4")

    change = fn node, fv ->
      with {:ok, parent_id} <- check_move_parent(prefix, node, new_parent_id) do
        if same_id?(parent_id, node["parent_id"]),
          do: :noop,
          else: {:ok, put_or_drop(fv, "parent_id", parent_id)}
      end
    end

    write_locked(prefix, node_id, actor_id, idem, change, "location_node.moved")
  end

  @doc """
  Updates `name`, `node_kind`, `segment`, `address`, `location_type`, `external_ref_system` or
  `external_ref_id` of a node. Any other key (`parent_id`, `active`, `code`, ...) is
  `{:error, {:field_not_allowed, key}}`. A nil value removes an optional field; `name` and
  `node_kind` stay non-blank text and a `segment` has no dash (`{:field_invalid, field}`). No address
  is rewritten, not the node's own and not a descendant's. A duplicate address or external reference
  is the record error of `Records.update_record/3`. Stored keys the active definition no longer
  declares (the old `org_site_id`) are dropped from the rewritten document. `opts` as `move_node/4`.
  """
  @spec update_node(String.t(), term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def update_node(prefix, node_id, attrs, opts)
      when is_binary(prefix) and is_map(attrs) and is_map(opts) do
    {actor_id, idem} = write_opts!(opts, "update_node/4")

    change = fn _node, fv ->
      with :ok <- check_update_keys(attrs) do
        merged = attrs |> Enum.reduce(fv, fn {k, v}, acc -> put_or_drop(acc, k, v) end)

        with :ok <- check_required(merged), :ok <- check_segment(merged), do: {:ok, merged}
      end
    end

    write_locked(prefix, node_id, actor_id, idem, change, "location_node.updated")
  end

  @doc """
  Retires a node (`active` false). `{:error, :has_active_descendants}` while any live descendant is
  active; retiring a retired node is `{:ok, node}` with no event. There is no un-retire and no
  delete. `opts` as `move_node/4`.
  """
  @spec retire_node(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def retire_node(prefix, node_id, opts) when is_binary(prefix) and is_map(opts) do
    {actor_id, idem} = write_opts!(opts, "retire_node/3")

    change = fn node, fv ->
      cond do
        node["active"] == false -> :noop
        active_descendant?(prefix, node["record_id"]) -> {:error, :has_active_descendants}
        true -> {:ok, Map.put(fv, "active", false)}
      end
    end

    write_locked(prefix, node_id, actor_id, idem, change, "location_node.retired")
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

  # `change.(node, stored_fields)` returns `{:ok, new_fields}`, `:noop` or `{:error, reason}`.
  # A claimed idempotency key skips the lock and the checks (see `replay?/2`) and rebuilds the same
  # document from the node's current state, so Records answers the original or `:idempotency_key_reuse`.
  defp write_locked(prefix, node_id, actor_id, idem, change, action) do
    if replay?(prefix, idem) do
      with {:ok, node} <- ReadApi.lookup(prefix, node_id, @types),
           {:ok, fv} <- stored_fields(prefix, node),
           {:ok, new_fv} <- replay_change(change.(node, fv), fv),
           {:ok, _} <- update_doc(prefix, node["record_id"], new_fv, actor_id, idem) do
        ReadApi.lookup(prefix, node["record_id"], @types)
      else
        {:error, :not_found} -> {:error, :node_not_found}
        {:error, _} = err -> err
        :noop -> ReadApi.lookup(prefix, node_id, @types)
      end
    else
      locked(prefix, node_id, actor_id, idem, change, action)
    end
  end

  defp replay_change(:noop, _fv), do: :noop
  defp replay_change(other, _fv), do: other

  defp locked(prefix, node_id, actor_id, idem, change, action) do
    Repo.transaction(fn ->
      lock!(prefix)

      with {:ok, node} <- find_node(prefix, node_id),
           {:ok, fv} <- stored_fields(prefix, node),
           {:ok, node} <-
             apply_change(prefix, node, fv, change.(node, fv), actor_id, idem, action) do
        node
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp apply_change(_prefix, node, _fv, :noop, _actor, _idem, _action), do: {:ok, node}
  defp apply_change(_prefix, _node, _fv, {:error, _} = err, _actor, _idem, _action), do: err

  defp apply_change(prefix, node, before_fv, {:ok, new_fv}, actor_id, idem, action) do
    with {:ok, _} <- update_doc(prefix, node["record_id"], new_fv, actor_id, idem),
         {:ok, updated} <- ReadApi.lookup(prefix, node["record_id"], @types),
         {:ok, after_fv} <- stored_fields(prefix, updated),
         :ok <- audit(prefix, actor_id, action, node["record_id"], before_fv, after_fv) do
      {:ok, updated}
    end
  end

  # INV-8: Audit raises on a database failure; the transaction is already aborted then, so the
  # rescue only turns the raise into a refusal and runs no further query.
  defp audit(prefix, actor_id, action, record_id, before, after_state) do
    entry = %{
      actor_id: actor_id,
      action: action,
      resource_type: "location_node",
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

  defp find_node(prefix, node_id) do
    case ReadApi.lookup(prefix, node_id, @types) do
      {:ok, node} -> {:ok, node}
      {:error, :not_found} -> {:error, :node_not_found}
    end
  end

  # The stored document without the read-map extras, and without keys the active definition no
  # longer declares (Records validates the whole document with additionalProperties false).
  defp stored_fields(prefix, node) do
    fv = Map.drop(node, ["record_id", "entity_type"])

    case Letflow.Entities.Definitions.get_active_definition_by_name("location_node", prefix) do
      {:ok, %{definition_json: %{"fields" => fields}}} when is_list(fields) ->
        names = for %{"name" => n} <- fields, do: n
        {:ok, Map.take(fv, names)}

      _ ->
        {:ok, fv}
    end
  end

  defp put_or_drop(fv, key, nil), do: Map.delete(fv, key)
  defp put_or_drop(fv, key, value), do: Map.put(fv, key, value)

  defp same_id?(nil, nil), do: true
  defp same_id?(nil, _), do: false
  defp same_id?(_, nil), do: false
  defp same_id?(a, b), do: cast_id(a) == cast_id(b)

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, u} -> u
      _ -> id
    end
  end

  defp check_move_parent(_prefix, _node, nil), do: {:ok, nil}

  defp check_move_parent(prefix, node, new_parent_id) do
    case ReadApi.lookup(prefix, new_parent_id, @types) do
      {:error, :not_found} ->
        {:error, :parent_not_found}

      {:ok, %{"active" => true} = parent} ->
        if cycle?(prefix, node["record_id"], parent["record_id"], MapSet.new()),
          do: {:error, :cycle},
          else: {:ok, parent["record_id"]}

      {:ok, _} ->
        {:error, :parent_inactive}
    end
  end

  # Walks the chain from `cur` upward: true when it meets `node_id` or repeats a node.
  defp cycle?(_prefix, _node_id, nil, _seen), do: false

  defp cycle?(prefix, node_id, cur, seen) do
    cur = cast_id(cur)

    cond do
      cur == cast_id(node_id) ->
        true

      MapSet.member?(seen, cur) ->
        true

      true ->
        case ReadApi.lookup(prefix, cur, @types) do
          {:ok, n} -> cycle?(prefix, node_id, n["parent_id"], MapSet.put(seen, cur))
          {:error, _} -> false
        end
    end
  end

  defp check_update_keys(attrs) do
    case attrs |> Map.keys() |> Enum.reject(&(&1 in @updatable)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> {:error, {:field_not_allowed, key}}
    end
  end

  defp update_doc(prefix, record_id, fv, actor_id, idem) do
    attrs = %{
      entity_type: "location_node",
      record_id: record_id,
      field_values: fv,
      actor_id: actor_id,
      idempotency_key: idem
    }

    # scope-all: SEC-518-R1 (locations module, tenant-wide type; own-record system path)
    case Records.update_record(attrs, prefix, ManagedTypes.owner_for!(Letflow.Modules.Locations)) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = err -> err
    end
  end

  @doc """
  The record ids of all live descendants of `node_id` (children, their children, and so on), sorted
  as text, by one recursive query. A retired descendant is listed; a soft-deleted one and the nodes
  below it are not. A node id that is not a uuid, unknown, soft-deleted or of another type, a
  non-text `prefix` and a schema without the tables give `[]`; it never raises. A damaged
  (looping) chain ends, because the query is a `UNION`. Read-only; not a security check.
  """
  @spec descendant_ids(term(), term()) :: [String.t()]
  def descendant_ids(prefix, node_id) do
    with true <- is_binary(prefix) and Regex.match?(@prefix_re, prefix),
         {:ok, uuid} <- Ecto.UUID.cast(node_id),
         true <- subtree_tables?(prefix) do
      {:ok, bin} = Ecto.UUID.dump(uuid)
      %{rows: rows} = Repo.query!(subtree_sql(prefix, ""), [bin])
      Enum.map(rows, fn [id] -> id end)
    else
      _ -> []
    end
  end

  defp active_descendant?(prefix, node_id) do
    true = Regex.match?(@prefix_re, prefix)
    {:ok, bin} = Ecto.UUID.dump(node_id)

    case Repo.query!(subtree_sql(prefix, "AND l.field_values->>'active' = 'true'"), [bin]) do
      %{rows: [_ | _]} -> true
      _ -> false
    end
  end

  defp subtree_tables?(prefix) do
    {:ok, table} = Letflow.TenantProvisioning.table_name_for_entity_type("location_node")

    Letflow.TenantProvisioning.entity_table_exists?(prefix, table) and
      Letflow.TenantProvisioning.entity_table_exists?(prefix, "entity_record_latest")
  end

  # `prefix` is checked against `@prefix_re` or comes from the caller of a write that already read
  # the tenant; the node id is the bound `$1`. `extra` is a fixed literal of this module.
  defp subtree_sql(prefix, extra) when is_binary(prefix) do
    true = Regex.match?(@prefix_re, prefix)

    ~s"""
    WITH RECURSIVE sub(record_id) AS (
      SELECT t.record_id FROM "#{prefix}"."entity_location_node" t
        JOIN "#{prefix}".entity_record_latest l ON l.record_id = t.record_id
         AND l.entity_type = 'location_node' AND l.deleted = false
       WHERE t.parent_id = $1::uuid
         AND EXISTS (SELECT 1 FROM "#{prefix}".entity_record_latest n
                      WHERE n.record_id = $1::uuid AND n.entity_type = 'location_node'
                        AND n.deleted = false)
      UNION
      SELECT c.record_id FROM sub s
        JOIN "#{prefix}"."entity_location_node" c ON c.parent_id = s.record_id
        JOIN "#{prefix}".entity_record_latest l ON l.record_id = c.record_id
         AND l.entity_type = 'location_node' AND l.deleted = false
    )
    SELECT s.record_id::text FROM sub s
      JOIN "#{prefix}".entity_record_latest l ON l.record_id = s.record_id
     WHERE s.record_id <> $1::uuid #{extra}
     ORDER BY 1
    """
  end
end
