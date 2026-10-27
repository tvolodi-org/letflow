defmodule Letflow.Modules.Exam.AuthoringRules do
  @moduledoc """
  REQ-586 part A (GH #3315): the tree write rules of the exam authoring surface for the
  `parent_id` column of `category` (the category tree) and `question` (version lineage).

  A separate module from `Letflow.Modules.Exam.Authoring` so that module keeps exactly its three
  `Records.*_record` call sites. This module makes no `Records` call and reads only the caller's
  `prefix` (`entity_record_latest`, INV-1); every query is bound (INV-7).

  Rules (all answer `:ok | {:error, {:authoring_rule, reason}}`):

    * `parent_not_found`: `parent_id` is not a UUID, or names no live record of the same type in
      this tenant. An absent, soft-deleted, wrong-type or other-tenant id (which cannot exist in
      this schema) all give the same reason (INV-5).
    * `parent_cycle` (category, update): the parent is the record itself, or the record is met
      walking up from the proposed parent. The walk keeps a visited set, so a cycle that already
      exists terminates. Two truly concurrent re-parents can still form a cycle (no lock is
      taken, so `Records` stays top-level and an idempotent replay works as before); the visited
      set keeps that state harmless.
    * `category_has_children` / `question_has_children` (delete): a live record names the
      record as its parent.

  Rules read `entity_record_latest`, not the promoted column, so they work without a column
  promotion row. A tenant whose active definition does not declare `parent_id` (not upgraded
  yet) skips the parent checks: `Records` then answers its undeclared-field rejection.
  A replayed create re-runs the rule before `Records`; a refusal consumes no idempotency key.

  REQ-586 part B, the `question` lineage rules, judged on the record `Records` will write (the
  body, with the stored values of the caller's restricted keys carried over):

    * `lineage_branch`: the proposed parent already has another live question child.
    * `version_not_increasing`: the version is not above the parent's, or not below a child's.
    * `lineage_active_conflict`: the record is active, or is re-parented, and the lineage
      (ancestors plus descendants) would then hold more than one active member. Draft, review
      and archived writes with an unchanged parent are never refused by this rule.

  Like the cycle race above, two truly concurrent activations can both pass (no lock is taken).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Record.Latest
  alias Letflow.Repo

  @tree_types ["category", "question"]

  @type reason ::
          :parent_cycle
          | :parent_not_found
          | :category_has_children
          | :question_has_children
          | :lineage_branch
          | :version_not_increasing
          | :lineage_active_conflict

  @doc """
  Checks a create (`record_id` nil) or update of `entity_type` carrying `field_values`.

  `preserve_keys` are the caller's restricted fields on an update: `Records` writes their STORED
  values instead of the body's, so the `question` lineage rules judge that resulting record.
  """
  @spec check_write(String.t(), String.t() | nil, map(), String.t(), MapSet.t(String.t())) ::
          :ok | {:error, {:authoring_rule, reason()}}
  def check_write(entity_type, record_id, field_values, prefix, preserve_keys \\ MapSet.new())

  def check_write("question", record_id, field_values, prefix, preserve_keys)
      when is_map(field_values) and is_binary(prefix) do
    stored = stored_row(record_id, prefix)

    case stored do
      :missing ->
        :ok

      _ ->
        resulting = resulting_values(field_values, stored, preserve_keys)

        with :ok <- check_question_parent(record_id, resulting, prefix) do
          if declares_parent_id?("question", prefix),
            do: check_lineage(record_id, resulting, stored, prefix),
            else: :ok
        end
    end
  end

  def check_write(entity_type, record_id, field_values, prefix, _preserve_keys)
      when entity_type in @tree_types and is_map(field_values) and is_binary(prefix) do
    case Map.get(field_values, "parent_id") do
      nil -> :ok
      parent_id -> check_parent(entity_type, record_id, parent_id, prefix)
    end
  end

  def check_write(_entity_type, _record_id, _field_values, _prefix, _preserve_keys), do: :ok

  @doc "Checks the soft delete of `record_id`: refused while a live record names it as parent."
  @spec check_delete(String.t(), String.t(), String.t()) ::
          :ok | {:error, {:authoring_rule, reason()}}
  def check_delete(entity_type, record_id, prefix)
      when entity_type in @tree_types and is_binary(record_id) and is_binary(prefix) do
    query =
      from(l in Latest,
        where:
          l.entity_type == ^entity_type and l.deleted == false and
            fragment("?->>'parent_id' = ?", l.field_values, ^record_id),
        select: 1,
        limit: 1
      )

    case Repo.one(query, prefix: prefix) do
      nil -> :ok
      1 -> {:error, {:authoring_rule, children_reason(entity_type)}}
    end
  end

  def check_delete(_entity_type, _record_id, _prefix), do: :ok

  # nil on create; :missing when an update names no live row (Records answers its own not-found).
  defp stored_row(nil, _prefix), do: nil

  defp stored_row(record_id, prefix) do
    case Latest.get_live(record_id, "question", prefix) do
      {:ok, row} -> row
      _ -> :missing
    end
  end

  # The same expression as `Records.merge_preserved/3`.
  defp resulting_values(field_values, stored, preserve_keys) do
    stored_values = if stored, do: stored.field_values, else: %{}
    keys = Enum.to_list(preserve_keys)

    field_values
    |> Map.drop(keys)
    |> Map.merge(Map.take(stored_values, keys))
  end

  defp check_question_parent(record_id, resulting, prefix) do
    case Map.get(resulting, "parent_id") do
      nil -> :ok
      parent_id -> check_parent("question", record_id, parent_id, prefix)
    end
  end

  defp check_lineage(record_id, resulting, stored, prefix) do
    parent = resulting_parent(resulting, prefix)

    with :ok <- check_branch(record_id, parent, prefix),
         :ok <- check_version(record_id, resulting, parent, prefix) do
      check_active(record_id, resulting, stored, parent, prefix)
    end
  end

  defp resulting_parent(resulting, prefix) do
    with parent_id when is_binary(parent_id) <- Map.get(resulting, "parent_id"),
         {:ok, uuid} <- Ecto.UUID.cast(parent_id),
         {:ok, parent} <- fetch_live(uuid, "question", prefix) do
      parent
    else
      _ -> nil
    end
  end

  defp check_branch(_record_id, nil, _prefix), do: :ok

  defp check_branch(record_id, parent, prefix) do
    if Enum.any?(children_of(parent.record_id, prefix), &(to_string(&1.record_id) != record_id)),
      do: refuse(:lineage_branch),
      else: :ok
  end

  defp check_version(record_id, resulting, parent, prefix) do
    case Map.get(resulting, "version") do
      v when is_integer(v) ->
        child_versions =
          if record_id,
            do: record_id |> children_of(prefix) |> Enum.map(&version_of/1),
            else: []

        parent_version = if parent, do: version_of(parent)

        if (is_integer(parent_version) and v <= parent_version) or
             Enum.any?(child_versions, &(is_integer(&1) and v >= &1)),
           do: refuse(:version_not_increasing),
           else: :ok

      _ ->
        :ok
    end
  end

  defp check_active(record_id, resulting, stored, parent, prefix) do
    active? = Map.get(resulting, "status") == "active"
    stored_parent = if stored, do: parent_of(stored)
    parent_changed? = record_id != nil and Map.get(resulting, "parent_id") != stored_parent

    if active? or parent_changed? do
      members = ancestors(parent, MapSet.new(), [], prefix) ++ descendants(record_id, prefix)

      others =
        Enum.count(members, fn m ->
          to_string(m.record_id) != record_id and status_of(m) == "active"
        end)

      if others + if(active?, do: 1, else: 0) > 1,
        do: refuse(:lineage_active_conflict),
        else: :ok
    else
      :ok
    end
  end

  defp ancestors(nil, _seen, acc, _prefix), do: acc

  defp ancestors(%{record_id: id} = row, seen, acc, prefix) do
    if MapSet.member?(seen, id) do
      acc
    else
      next =
        with next when is_binary(next) <- parent_of(row),
             {:ok, uuid} <- Ecto.UUID.cast(next),
             {:ok, ancestor} <- fetch_live(uuid, "question", prefix) do
          ancestor
        else
          _ -> nil
        end

      ancestors(next, MapSet.put(seen, id), [row | acc], prefix)
    end
  end

  defp descendants(nil, _prefix), do: []

  defp descendants(record_id, prefix),
    do: descend([record_id], MapSet.new([record_id]), [], prefix)

  defp descend([], _seen, acc, _prefix), do: acc

  defp descend([id | rest], seen, acc, prefix) do
    kids =
      id |> children_of(prefix) |> Enum.reject(&MapSet.member?(seen, to_string(&1.record_id)))

    ids = Enum.map(kids, &to_string(&1.record_id))
    descend(rest ++ ids, Enum.reduce(ids, seen, &MapSet.put(&2, &1)), kids ++ acc, prefix)
  end

  defp children_of(parent_id, prefix) do
    parent_id = to_string(parent_id)

    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == "question" and l.deleted == false and
            fragment("?->>'parent_id' = ?", l.field_values, ^parent_id),
        select: %{record_id: l.record_id, field_values: l.field_values}
      ),
      prefix: prefix
    )
  end

  defp version_of(%{field_values: %{"version" => v}}), do: v
  defp version_of(_row), do: nil

  defp status_of(%{field_values: %{"status" => s}}), do: s
  defp status_of(_row), do: nil

  defp refuse(reason), do: {:error, {:authoring_rule, reason}}

  defp children_reason("category"), do: :category_has_children
  defp children_reason("question"), do: :question_has_children

  defp check_parent(entity_type, record_id, parent_id, prefix) do
    if declares_parent_id?(entity_type, prefix) do
      with {:ok, parent_uuid} <- cast_parent(parent_id),
           {:ok, parent} <- fetch_live(parent_uuid, entity_type, prefix) do
        check_cycle(entity_type, record_id, parent, prefix)
      else
        _ -> {:error, {:authoring_rule, :parent_not_found}}
      end
    else
      :ok
    end
  end

  defp declares_parent_id?(entity_type, prefix) do
    case Definitions.get_active_definition_by_name(entity_type, prefix) do
      {:ok, %{definition_json: %{"fields" => fields}}} when is_list(fields) ->
        Enum.any?(fields, &(is_map(&1) and Map.get(&1, "name") == "parent_id"))

      _ ->
        false
    end
  end

  defp cast_parent(parent_id) when is_binary(parent_id), do: Ecto.UUID.cast(parent_id)
  defp cast_parent(_other), do: :error

  defp fetch_live(uuid, entity_type, prefix), do: Latest.get_live(uuid, entity_type, prefix)

  defp check_cycle("category", record_id, parent, prefix) when is_binary(record_id) do
    if walk_up(parent, record_id, MapSet.new(), prefix),
      do: {:error, {:authoring_rule, :parent_cycle}},
      else: :ok
  end

  defp check_cycle(_entity_type, _record_id, _parent, _prefix), do: :ok

  # true when `record_id` is met on the chain from `current` to the root.
  defp walk_up(%{record_id: current_id} = current, record_id, seen, prefix) do
    cond do
      current_id == record_id ->
        true

      MapSet.member?(seen, current_id) ->
        false

      true ->
        next = parent_of(current)

        with next when is_binary(next) <- next,
             {:ok, uuid} <- Ecto.UUID.cast(next),
             {:ok, ancestor} <- fetch_live(uuid, "category", prefix) do
          walk_up(ancestor, record_id, MapSet.put(seen, current_id), prefix)
        else
          _ -> false
        end
    end
  end

  defp parent_of(%{field_values: %{"parent_id" => parent_id}}), do: parent_id
  defp parent_of(_record), do: nil
end
