defmodule Letflow.Definitions.RoleBinding do
  @moduledoc """
  Advisory listing of human-task roles that have no `tenant_role` binding in a
  tenant (REQ-455 check 4). A pure core (`task_roles/1`, `unbound/2`,
  `format_warning/2`) and one impure read (`bound_role_names/1`).

  REQ-464 check 4 adds the single-member advisory: `single_member_pairs/1`
  (pure), `member_counts/2` (one prefix-scoped counts-only read) and
  `format_single_member_warning/2`.

  Never writes: no binding is ever created here, and the result is a warning
  list, not a violation (Decision 0029 section 2 keeps required roles advisory
  and role seeding out of packs).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Definitions.Graph
  alias Letflow.Engine.ApprovalRuleSetting
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Repo

  @type task_role :: %{role_name: String.t(), node_ids: [String.t()]}

  @doc """
  Every role a HUMAN_TASK routes to (`attributes["role"]`,
  `attributes["escalation_role"]` and `attributes["reminder_role"]`
  (REQ-494), each when a non-blank binary, used raw),
  grouped by role name. `role_name` and `node_ids` are sorted ascending and
  deduplicated. Total on malformed attributes.
  """
  @spec task_roles(Graph.t()) :: [task_role()]
  def task_roles(%Graph{nodes: nodes}) do
    nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK and is_map(&1.attributes)))
    |> Enum.flat_map(fn node ->
      for key <- ["role", "escalation_role", "reminder_role"],
          name = Map.get(node.attributes, key),
          is_binary(name) and String.trim(name) != "",
          do: {name, node.id}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {name, ids} ->
      %{role_name: name, node_ids: ids |> Enum.uniq() |> Enum.sort()}
    end)
    |> Enum.sort_by(& &1.role_name)
  end

  @doc "Keeps the task roles whose name is not in `bound_names`, order preserved."
  @spec unbound([task_role()], MapSet.t(String.t())) :: [task_role()]
  def unbound(task_roles, %MapSet{} = bound_names) do
    Enum.reject(task_roles, &MapSet.member?(bound_names, &1.role_name))
  end

  @doc """
  Names of the roles bound in this tenant's `tenant_role` table (any `kind`),
  read through the prefix-scoped `RoleRegistry.list_roles/1`.
  """
  @spec bound_role_names(opts :: [prefix: String.t()]) :: MapSet.t(String.t())
  def bound_role_names(opts) do
    opts |> RoleRegistry.list_roles() |> MapSet.new(& &1.name)
  end

  @doc "The single place the wire text of an unbound-role warning is built."
  @spec format_warning(definition_name :: String.t(), task_role()) :: String.t()
  def format_warning(definition_name, %{role_name: role_name, node_ids: node_ids}) do
    "unbound_task_role: #{role_name} (definition '#{definition_name}', nodes: " <>
      Enum.join(node_ids, ", ") <> ")"
  end

  @doc """
  One warning per (definition, unbound role), definitions in input order. One
  `bound_role_names/1` read in total. `[]` when nothing is unbound.
  """
  @spec warnings_for_definitions([{String.t(), Graph.t()}], opts :: [prefix: String.t()]) ::
          [String.t()]
  def warnings_for_definitions(definitions, opts) do
    bound = bound_role_names(opts)

    Enum.flat_map(definitions, fn {name, %Graph{} = graph} ->
      graph |> task_roles() |> unbound(bound) |> Enum.map(&format_warning(name, &1))
    end)
  end

  @doc """
  REQ-464 check 4, pure half: the unordered pairs of HUMAN_TASK nodes where one
  lists the other in `distinct_from` and both route to the same
  `attributes["role"]` (not `escalation_role`; a blank or non-binary role is
  ignored). A pair named both ways yields ONE entry; `node_ids` is sorted
  ascending; entries are sorted by `{role_name, node_ids}`. Preceding, parallel
  and loop pairs are all included. Total on malformed attributes.
  """
  @spec single_member_pairs(Graph.t()) :: [task_role()]
  def single_member_pairs(%Graph{nodes: nodes}) do
    human = nodes |> Enum.uniq_by(& &1.id) |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    roles = for n <- human, role = task_role(n), into: %{}, do: {n.id, role}

    for node <- human,
        is_map(node.attributes),
        is_list(listed = Map.get(node.attributes, "distinct_from")),
        other <- Enum.uniq(listed),
        is_binary(other) and other != node.id,
        role = Map.get(roles, node.id),
        role == Map.get(roles, other),
        uniq: true do
      %{role_name: role, node_ids: Enum.sort([node.id, other])}
    end
    |> Enum.sort_by(&{&1.role_name, &1.node_ids})
  end

  defp task_role(%{attributes: attrs}) when is_map(attrs) do
    case Map.get(attrs, "role") do
      name when is_binary(name) -> if String.trim(name) == "", do: nil, else: name
      _other -> nil
    end
  end

  defp task_role(_node), do: nil

  @doc """
  REQ-464 check 4, impure half: how many members each named role has in the
  tenant (`opts[:prefix]`, explicit, INV-1). ONE query over `tenant_role` joined
  to `group_members`, counting DISTINCT `group_members.user_id` of the role's
  bound group regardless of `users.status` (design OQ-2; `users` is not joined).
  Only counts leave this function, never user ids, names or emails (INV-2). A
  role with no binding or no members is absent from the map. `[]` role names
  runs no query.
  """
  @spec member_counts(role_names :: [String.t()], opts :: [prefix: String.t()]) ::
          %{optional(String.t()) => non_neg_integer()}
  def member_counts([], _opts), do: %{}

  def member_counts(role_names, opts) when is_list(role_names) do
    prefix = Keyword.fetch!(opts, :prefix)

    from(t in TenantRole,
      join: m in GroupMember,
      on: m.group_id == t.group_id,
      where: t.name in ^role_names,
      group_by: t.name,
      select: {t.name, count(m.user_id, :distinct)}
    )
    |> Repo.all(prefix: prefix)
    |> Map.new()
  end

  @doc "The single place the wire text of a single-member-role warning is built."
  @spec format_single_member_warning(definition_name :: String.t(), task_role()) :: String.t()
  def format_single_member_warning(definition_name, %{role_name: role_name, node_ids: node_ids}) do
    "distinct_from_single_member_role: #{role_name} (definition '#{definition_name}', nodes: " <>
      Enum.join(node_ids, ", ") <> ")"
  end

  @doc """
  One warning per (definition, unordered pair) whose role has exactly one
  member, definitions in input order. Zero candidate pairs across all
  definitions: no query at all; candidate pairs but no single-member role: one
  `member_counts/2` read; at least one warning would be shown: that read plus ONE
  four-eyes settings read in total (T-1986).

  T-1986: a pair is not warned when EVERY node of the pair that lists the other in
  `distinct_from` is switched OFF in that definition (the runtime check reads the
  `distinct_from` of the node being completed, and OFF lets an interactive person
  approve their own work, so "no second person can ever be found" no longer holds).
  The warning is silenced regardless of credential. When the settings cannot be read
  every warning is kept and one line is logged: a warning fails toward "shown".
  """
  @spec single_member_warnings_for_definitions(
          [{String.t(), Graph.t()}],
          opts :: [prefix: String.t()]
        ) :: [String.t()]
  def single_member_warnings_for_definitions(definitions, opts) do
    candidates =
      Enum.map(definitions, fn {name, %Graph{} = graph} ->
        {name, graph, single_member_pairs(graph)}
      end)

    role_names =
      candidates
      |> Enum.flat_map(fn {_n, _g, pairs} -> Enum.map(pairs, & &1.role_name) end)
      |> Enum.uniq()

    if role_names == [] do
      []
    else
      counts = member_counts(role_names, opts)

      would_warn =
        for {name, graph, pairs} <- candidates,
            pair <- pairs,
            Map.get(counts, pair.role_name) == 1,
            do: {name, graph, pair}

      off = off_steps_for(would_warn, opts)

      for {name, graph, pair} <- would_warn,
          not silenced?(off, name, listers(graph, pair)),
          do: format_single_member_warning(name, pair)
    end
  end

  # One bulk read, only when a warning would be shown. `nil` = unreadable (keep every warning).
  defp off_steps_for([], _opts), do: MapSet.new()

  defp off_steps_for(would_warn, opts) do
    names = would_warn |> Enum.map(fn {name, _g, _p} -> name end) |> Enum.uniq()
    query_opts = if Repo.in_transaction?(), do: [mode: :savepoint], else: []

    case ApprovalRuleSetting.off_steps(Repo, Keyword.fetch!(opts, :prefix), names, query_opts) do
      {:ok, off} ->
        off

      {:error, :unreadable} ->
        Logger.warning(
          "distinct_from single-member warning: four-eyes settings unreadable: :unreadable"
        )

        nil
    end
  end

  defp silenced?(nil, _name, _listers), do: false
  defp silenced?(_off, _name, []), do: false

  defp silenced?(off, name, listers),
    do: Enum.all?(listers, &MapSet.member?(off, {name, &1}))

  # The nodes of the pair that list the other in `distinct_from` (same filter as
  # `single_member_pairs/1`).
  defp listers(%Graph{nodes: nodes}, %{node_ids: [x, y]}) do
    for node <- Enum.uniq_by(nodes, & &1.id),
        node.node_type == :HUMAN_TASK,
        node.id in [x, y],
        is_map(node.attributes),
        is_list(listed = Map.get(node.attributes, "distinct_from")),
        other = if(node.id == x, do: y, else: x),
        other in listed,
        do: node.id
  end
end
