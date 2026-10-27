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
  The question lineage rules (one successor, version order) are REQ-586 part B.
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

  @doc "Checks a create (`record_id` nil) or update of `entity_type` carrying `field_values`."
  @spec check_write(String.t(), String.t() | nil, map(), String.t()) ::
          :ok | {:error, {:authoring_rule, reason()}}
  def check_write(entity_type, record_id, field_values, prefix)
      when entity_type in @tree_types and is_map(field_values) and is_binary(prefix) do
    case Map.get(field_values, "parent_id") do
      nil -> :ok
      parent_id -> check_parent(entity_type, record_id, parent_id, prefix)
    end
  end

  def check_write(_entity_type, _record_id, _field_values, _prefix), do: :ok

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
