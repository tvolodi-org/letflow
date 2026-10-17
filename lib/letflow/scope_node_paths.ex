defmodule Letflow.ScopeNodePaths do
  @moduledoc """
  The core-owned materialized-path security index over a tenant's scope tree
  (REQ-496, decision 0050 D8 and Deviation 1; design
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §6). Consumers:
  0051 D2/D3 (subtree reads for row scoping).

  One row per node in the tenant schema's `scope_node_paths` table: `path` is
  `"/<root id>/.../<node id>/"`, `depth` its segment count (root = 1, at most
  12). Retired nodes stay in the table with `retired_at` set.

  ## One writer

  `write/2` is the ONLY function that writes the table (design D9; enforced for
  module code by `mix letflow.check_scope_node_paths_writers`). It takes an
  operation tuple -- insert, move or retire -- and holds a
  `SHARE ROW EXCLUSIVE` table lock until the caller's transaction ends, which
  serialises every writer of one tenant's tree (closing the concurrent
  A-under-B / B-under-A cycle race) without blocking readers (design D10).

  Outside a transaction, `write/2` opens its own and rolls it back on a refusal.
  Inside a caller's transaction it never calls `Repo.rollback/1`: every refusal is
  detected by reads before the first write, so a refusal leaves the caller's
  transaction usable.

  ## Call order (a MUST for the org module, REQ-495)

  The table lock must always be taken before any per-type sequence row lock or
  org record row lock, so two org transactions can never deadlock on lock order:

    * an org `:insert` calls `lock!/1` FIRST, then `Records.create_record/2`
      (which takes the per-type `instance_sequences` `FOR UPDATE` row lock), then
      `write/2` (which re-takes the same table lock, re-entrantly). An insert
      refusal from `write/2` comes after the record write, so the caller MUST
      `Repo.rollback/1`;
    * a `:move` or `:retire` calls `write/2` FIRST, before the org record write.

  ## Lock waits

  No `lock_timeout` is set (a `SET LOCAL` would leak into the rest of the
  caller's transaction). A wait ends when the holder commits. A Postgres deadlock
  (`deadlock_detected`) or a server-side `lock_timeout`/`statement_timeout`
  RAISES `Postgrex.Error` out of `write/2`/`lock!/1` rather than returning a
  typed error: it aborts the caller's transaction and surfaces through HTTP as the
  pipeline's logged, detail-free 500 (INV-8: an internal fault, not caller
  input). `write/2` audits nothing; the org module audits tree changes (OQ-5).

  The table lock is never taken BEFORE the tenant admin lock
  (`Letflow.Identity.lock_tenant_admins!/1`) by any path that takes both (REQ-497 PR 1b,
  design `req497-1b-allowed-flag-shadow-n1.md` section 10): the scope-enforcement flip takes
  the admin lock, then the `tenants` row, then this lock.

  ## Grants and the retire guard (REQ-517)

  A grant writer holds the tenant admin lock A and a node share lock
  (`lock_active_node_for_share!/2`); a tree writer never takes A. `{:retire, n}` of a LIVE
  node first locks the node row `FOR NO KEY UPDATE` (waiting for a creator holding the share
  lock), THEN asks `Letflow.Identity.RoleScopeGrants.references_node?/2`, and refuses with
  `:node_has_grants` when a grant names the node. Only the node itself is checked (grants on
  its descendants stay valid), and a `:move` is never refused.

  ## LIKE patterns (INV-7)

  Every LIKE pattern is built by `like_prefix_pattern/1` and passed as a bound
  parameter. The table's identifier in `LOCK TABLE` comes from the validated
  server-side prefix, never from tenant data.
  """

  import Ecto.Query

  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths.Node
  alias Letflow.TenantProvisioning

  @max_depth 12
  @max_node_id_bytes 64
  @max_descendants_input 500

  @type node_id :: String.t()

  @type change ::
          {:insert, node_id(), parent_id :: node_id() | nil}
          | {:move, node_id(), new_parent_id :: node_id() | nil}
          | {:retire, node_id()}

  @type write_error ::
          :invalid_node_id
          | :node_exists
          | :node_not_found
          | :node_retired
          | :parent_not_found
          | :parent_retired
          | :cycle
          | :depth_exceeded
          | :node_has_grants
          | :invalid_schema_name

  @doc "The maximum tree depth `write/2` allows (root = 1)."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Applies one tree change in the tenant schema `prefix` (design §6.2) and returns
  the affected node row as stored afterwards.

    * `{:insert, n, nil}` adds root `n`; `{:insert, n, p}` adds `n` under the
      existing, non-retired `p` (`:node_exists`, `:parent_not_found`,
      `:parent_retired`, `:depth_exceeded`).
    * `{:move, n, np}` re-parents `n` and its whole subtree in one `UPDATE`
      (`nil` makes it a root): `:node_not_found`, `:node_retired`, `:cycle` (onto
      itself or into its own subtree), `:parent_not_found`, `:parent_retired`,
      `:depth_exceeded` (deepest descendant past 12). An unchanged parent is
      `{:ok, n}` with no write.
    * `{:retire, n}` sets `retired_at` on `n` only (`:node_not_found`);
      idempotent; descendants untouched. Refused with `:node_has_grants` while a grant row
      names `n` (REQ-517).

  Node ids are 1..64 bytes of valid UTF-8 with no `/` and no control
  characters (`:invalid_node_id`). See the moduledoc for locking, transaction
  and call-order rules.
  """
  @spec write(change(), prefix :: String.t()) :: {:ok, Node.t()} | {:error, write_error()}
  def write(change, prefix) when is_binary(prefix) do
    with :ok <- validate_change(change),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      if Repo.in_transaction?() do
        locked_apply(change, prefix)
      else
        Repo.transaction(fn ->
          case locked_apply(change, prefix) do
            {:ok, node} -> node
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end
    end
  end

  @doc """
  REQ-517 (design 3.7): `SELECT ... FOR SHARE` of the node row in the caller's transaction,
  held until it ends, and the row as read AFTER the lock (so a retire that committed while
  this call waited is seen). A grant creator calls it before inserting a scoped row.
  `{:error, :invalid_node_id | :node_not_found | :node_retired}`; raises `ArgumentError`
  outside a transaction.
  """
  @spec lock_active_node_for_share!(node_id :: term(), prefix :: String.t()) ::
          {:ok, Node.t()} | {:error, :invalid_node_id | :node_not_found | :node_retired}
  def lock_active_node_for_share!(node_id, prefix) when is_binary(prefix) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "Letflow.ScopeNodePaths.lock_active_node_for_share!/2 must be called inside a transaction"
    end

    with :ok <- validate_node_id(node_id),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         %Node{} = node <- lock_node_row_shared(node_id, prefix) do
      case node.retired_at do
        nil -> {:ok, node}
        _retired -> {:error, :node_retired}
      end
    else
      nil -> {:error, :node_not_found}
      {:error, :invalid_schema_name} -> {:error, :invalid_node_id}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Takes the tenant's `scope_node_paths` table lock (`SHARE ROW EXCLUSIVE`) in the
  caller's transaction, held until it ends; re-entrant. An org `:insert` calls
  this before its record write (see the moduledoc's call order). Raises
  `ArgumentError` when called outside a transaction or with an invalid prefix.
  """
  @spec lock!(prefix :: String.t()) :: :ok
  def lock!(prefix) when is_binary(prefix) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "Letflow.ScopeNodePaths.lock!/1 must be called inside a transaction"
    end

    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, _tenant_id} -> lock_table(prefix)
      {:error, :invalid_schema_name} -> raise ArgumentError, "invalid tenant schema prefix"
    end
  end

  @doc """
  The ancestors of `node_id` in the tenant schema `prefix`, root first, the node
  itself excluded (design §6.3). Retired ancestors are included.
  """
  @spec ancestors(node_id(), prefix :: String.t()) ::
          {:ok, [Node.t()]} | {:error, :invalid_node_id | :node_not_found | :invalid_schema_name}
  def ancestors(node_id, prefix) when is_binary(prefix) do
    with {:ok, %{ancestors: ancestors}} <- resolve(node_id, prefix), do: {:ok, ancestors}
  end

  @doc """
  REQ-517 2b (design 4.4): the node itself AND its ancestors (root first, retired ones
  included), with the same two reads as `ancestors/2`, which is expressed over this function.
  `Letflow.Api.Scope` uses it to see the resource node's own `retired_at`.
  """
  @spec resolve(node_id(), prefix :: String.t()) ::
          {:ok, %{node: Node.t(), ancestors: [Node.t()]}}
          | {:error, :invalid_node_id | :node_not_found | :invalid_schema_name}
  def resolve(node_id, prefix) when is_binary(prefix) do
    with :ok <- validate_node_id(node_id),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, node} <- fetch_node(node_id, prefix, :node_not_found) do
      ancestor_ids = node.path |> path_segments() |> Enum.drop(-1)

      ancestors =
        Repo.all(
          from(n in Node, where: n.node_id in ^ancestor_ids, order_by: [asc: n.depth]),
          prefix: prefix
        )

      {:ok, %{node: node, ancestors: ancestors}}
    end
  end

  @doc """
  Every node in the subtrees of `node_ids` in the tenant schema `prefix`, the
  given nodes themselves included (0051 D2 subtree semantics), ordered by
  `path` (design §6.3). Input is deduplicated; at most 500 ids
  (`:too_many_nodes`); unknown ids are ignored; `[]` gives `{:ok, []}`. Retired
  nodes are included -- the caller filters on `retired_at`.
  """
  @spec descendants_of([node_id()], prefix :: String.t()) ::
          {:ok, [Node.t()]} | {:error, :invalid_node_id | :too_many_nodes | :invalid_schema_name}
  def descendants_of(node_ids, prefix) when is_list(node_ids) and is_binary(prefix) do
    ids = Enum.uniq(node_ids)

    with :ok <- validate_node_ids(ids),
         :ok <- check_descendants_input_size(ids),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      paths =
        Repo.all(from(n in Node, where: n.node_id in ^ids, select: n.path), prefix: prefix)

      case paths do
        [] ->
          {:ok, []}

        paths ->
          patterns = Enum.map(paths, &like_prefix_pattern/1)

          # `LIKE ANY` uses Postgres's default escape character, backslash.
          {:ok,
           Repo.all(
             from(n in Node,
               where: fragment("? LIKE ANY(?)", n.path, type(^patterns, {:array, :string})),
               order_by: [asc: n.path]
             ),
             prefix: prefix
           )}
      end
    end
  end

  @doc """
  The LIKE pattern matching `path` and everything below it: escapes `\\`, `%`
  and `_` with a backslash, then appends `%`. The single escaping helper for
  every `scope_node_paths` LIKE query (0051 reuses it); pass the result as a
  bound parameter with `ESCAPE '\\'` (or rely on the default escape for
  `LIKE ANY`).
  """
  @spec like_prefix_pattern(path :: String.t()) :: String.t()
  def like_prefix_pattern(path) when is_binary(path) do
    escaped =
      path
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    escaped <> "%"
  end

  # ── write/2 internals ─────────────────────────────────────────────────────

  defp locked_apply(change, prefix) do
    :ok = lock_table(prefix)
    apply_change(change, prefix)
  end

  # Only called with a prefix `tenant_id_for_schema_name/1` already accepted.
  defp lock_table(prefix) do
    Repo.query!(~s|LOCK TABLE "#{prefix}".scope_node_paths IN SHARE ROW EXCLUSIVE MODE|)
    :ok
  end

  defp apply_change({:insert, node_id, parent_id}, prefix) do
    with :ok <- check_absent(node_id, prefix),
         {:ok, path, depth} <- insert_position(node_id, parent_id, prefix) do
      %Node{node_id: node_id, path: path, depth: depth}
      |> Ecto.Changeset.change()
      |> Repo.insert(prefix: prefix)
    end
  end

  defp apply_change({:move, node_id, new_parent_id}, prefix) do
    with {:ok, node} <- fetch_node(node_id, prefix, :node_not_found),
         :ok <- check_not_retired(node, :node_retired),
         {:ok, new_parent} <- move_target(node, new_parent_id, prefix) do
      if current_parent_id(node) == new_parent_id do
        {:ok, node}
      else
        move_subtree(node, new_parent, prefix)
      end
    end
  end

  defp apply_change({:retire, node_id}, prefix) do
    with {:ok, node} <- fetch_node(node_id, prefix, :node_not_found) do
      case node.retired_at do
        nil -> retire_live_node(node, prefix)
        _already_retired -> {:ok, node}
      end
    end
  end

  # REQ-517 (design 3.7, finding F2): the node row lock FIRST, then the grants read. Under
  # READ COMMITTED the read after the lock waits for and sees a grant a creator committed.
  defp retire_live_node(node, prefix) do
    case lock_node_row_for_update(node.node_id, prefix) do
      nil ->
        {:error, :node_not_found}

      %Node{retired_at: retired_at} = locked when not is_nil(retired_at) ->
        {:ok, locked}

      %Node{} = locked ->
        if RoleScopeGrants.references_node?(locked.node_id, prefix) do
          {:error, :node_has_grants}
        else
          now = DateTime.utc_now()

          locked
          |> Ecto.Changeset.change(retired_at: now, updated_at: now)
          |> Repo.update(prefix: prefix)
        end
    end
  end

  defp lock_node_row_shared(node_id, prefix) do
    Repo.one(from(n in Node, where: n.node_id == ^node_id, lock: "FOR SHARE"), prefix: prefix)
  end

  defp lock_node_row_for_update(node_id, prefix) do
    Repo.one(
      from(n in Node, where: n.node_id == ^node_id, lock: "FOR NO KEY UPDATE"),
      prefix: prefix
    )
  end

  defp check_absent(node_id, prefix) do
    case Repo.get(Node, node_id, prefix: prefix) do
      nil -> :ok
      %Node{} -> {:error, :node_exists}
    end
  end

  defp insert_position(node_id, nil, _prefix), do: {:ok, "/" <> node_id <> "/", 1}

  defp insert_position(node_id, parent_id, prefix) do
    with {:ok, parent} <- fetch_node(parent_id, prefix, :parent_not_found),
         :ok <- check_not_retired(parent, :parent_retired),
         :ok <- check_depth(parent.depth + 1) do
      {:ok, parent.path <> node_id <> "/", parent.depth + 1}
    end
  end

  # Checks in design §6.2's order; `nil` (move to root) needs none of them.
  defp move_target(_node, nil, _prefix), do: {:ok, nil}

  defp move_target(%Node{node_id: node_id}, node_id, _prefix), do: {:error, :cycle}

  defp move_target(node, new_parent_id, prefix) do
    with {:ok, new_parent} <- fetch_node(new_parent_id, prefix, :parent_not_found),
         :ok <- check_not_inside(new_parent, node),
         :ok <- check_not_retired(new_parent, :parent_retired) do
      {:ok, new_parent}
    end
  end

  defp check_not_inside(new_parent, node) do
    if String.starts_with?(new_parent.path, node.path), do: {:error, :cycle}, else: :ok
  end

  defp move_subtree(node, new_parent, prefix) do
    subtree = subtree_query(node.path)
    subtree_max = Repo.one(from(n in subtree, select: max(n.depth)), prefix: prefix)

    {new_path, new_depth} =
      case new_parent do
        nil -> {"/" <> node.node_id <> "/", 1}
        %Node{} -> {new_parent.path <> node.node_id <> "/", new_parent.depth + 1}
      end

    delta = new_depth - node.depth

    with :ok <- check_depth(subtree_max + delta) do
      now = DateTime.utc_now()

      Repo.update_all(
        from(n in subtree,
          update: [
            set: [
              path:
                fragment(
                  "?::text || substr(?, length(?::text) + 1)",
                  ^new_path,
                  n.path,
                  ^node.path
                ),
              updated_at: ^now
            ],
            inc: [depth: ^delta]
          ]
        ),
        [],
        prefix: prefix
      )

      {:ok, Repo.get!(Node, node.node_id, prefix: prefix)}
    end
  end

  # Every row whose path starts with `path` (the node itself included).
  defp subtree_query(path) do
    pattern = like_prefix_pattern(path)
    from(n in Node, where: fragment("? LIKE ? ESCAPE '\\'", n.path, ^pattern))
  end

  defp current_parent_id(%Node{path: path}) do
    case path |> path_segments() |> Enum.reverse() do
      [_self, parent | _rest] -> parent
      [_root] -> nil
    end
  end

  defp fetch_node(node_id, prefix, not_found_error) do
    case Repo.get(Node, node_id, prefix: prefix) do
      nil -> {:error, not_found_error}
      %Node{} = node -> {:ok, node}
    end
  end

  defp check_not_retired(%Node{retired_at: nil}, _error), do: :ok
  defp check_not_retired(%Node{}, error), do: {:error, error}

  defp check_depth(depth) when depth <= @max_depth, do: :ok
  defp check_depth(_depth), do: {:error, :depth_exceeded}

  defp path_segments(path), do: String.split(path, "/", trim: true)

  # ── validation ────────────────────────────────────────────────────────────

  defp validate_change({:insert, node_id, parent_id}),
    do: validate_node_ids([node_id | List.wrap(parent_id)])

  defp validate_change({:move, node_id, new_parent_id}),
    do: validate_node_ids([node_id | List.wrap(new_parent_id)])

  defp validate_change({:retire, node_id}), do: validate_node_id(node_id)
  defp validate_change(_other), do: {:error, :invalid_node_id}

  defp validate_node_ids(ids) do
    if Enum.all?(ids, &(validate_node_id(&1) == :ok)), do: :ok, else: {:error, :invalid_node_id}
  end

  defp validate_node_id(id)
       when is_binary(id) and byte_size(id) >= 1 and byte_size(id) <= @max_node_id_bytes do
    if String.valid?(id) and not String.match?(id, ~r/[\/\p{Cc}]/u),
      do: :ok,
      else: {:error, :invalid_node_id}
  end

  defp validate_node_id(_other), do: {:error, :invalid_node_id}

  defp check_descendants_input_size(ids) when length(ids) <= @max_descendants_input, do: :ok
  defp check_descendants_input_size(_ids), do: {:error, :too_many_nodes}
end
