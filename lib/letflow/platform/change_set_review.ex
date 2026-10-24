defmodule Letflow.Platform.ChangeSetReview do
  @moduledoc """
  REQ-535 (GH #3098): a pure review of a whole set of platform-wide schema
  changes, run before any company workspace is opened. No database, no
  tenant data, no route (INV-1 is not engaged); `Letflow.Platform.MigrationRollout`
  is untouched and does not call it.

  Classes follow decision 0055 D2 (A additive, B step required, C forbidden):

    * `add_column` that is nullable or has a default: Class A.
    * `add_column` that is NOT NULL without a default (a "new required
      field"): Class B, needs a covering step.
    * `set_not_null` (constraint tightening on an existing field): Class B,
      covered by an earlier `backfill` of the same column (or an earlier
      `add_column` of it with a default) AND acknowledged in `ack_destructive`.
    * `backfill`: Class A.
    * `rewrite_stored_history`: holds every workspace locked for an unbounded
      time. 0055 does not class it (open question of REQ-535), so it is
      reported as violation kind `:unbounded_lock` with `class: nil`.

  "Ordered before" means earlier in `changes`. The verdict depends on the set
  alone: violations are sorted by change id and the plan is keyed by id, so
  reordering changes that have no backfill/set_not_null ordering between them
  gives an equal result. The whole set is reviewed, not stopped at the first
  violation. Whether a platform-wide set must demand `ack_destructive` is
  left open; `:missing_ack` only reports its absence.

  Input: `%{changes: [change], ack_destructive: [change_id]}`. Unknown kinds,
  missing fields and duplicate ids return `{:error, {:invalid_change_set, reason}}`.
  """

  @type violation :: %{
          change_id: String.t(),
          change: map(),
          kind: :unbounded_lock | :not_covered | :missing_ack,
          class: :b | nil,
          missing: atom()
        }

  @required %{
    add_column: [:entity_type, :attribute, :pg_type, :nullable],
    backfill: [:entity_type, :attribute],
    set_not_null: [:entity_type, :attribute],
    rewrite_stored_history: [:entity_type]
  }

  @spec review(map()) ::
          {:ok, %{classes: %{String.t() => :a | :b | nil}, class_b_ids: [String.t()]}}
          | {:error, {:rejected, [violation()]}}
          | {:error, {:invalid_change_set, term()}}
  def review(%{changes: changes} = change_set) when is_list(changes) do
    acks = Map.get(change_set, :ack_destructive, [])

    with :ok <- validate_acks(acks),
         :ok <- validate_changes(changes) do
      violations =
        changes
        |> Enum.with_index()
        |> Enum.flat_map(fn {change, idx} -> check(change, Enum.take(changes, idx), acks) end)
        |> Enum.sort_by(& &1.change_id)

      case violations do
        [] -> {:ok, plan(changes)}
        _ -> {:error, {:rejected, violations}}
      end
    end
  end

  def review(_), do: {:error, {:invalid_change_set, :changes_required}}

  defp validate_acks(acks) do
    if is_list(acks) and Enum.all?(acks, &is_binary/1),
      do: :ok,
      else: {:error, {:invalid_change_set, :invalid_ack_destructive}}
  end

  defp validate_changes(changes) do
    changes
    |> Enum.reduce_while({:ok, MapSet.new()}, fn change, {:ok, seen} ->
      case validate_change(change, seen) do
        :ok -> {:cont, {:ok, MapSet.put(seen, change.id)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp validate_change(%{id: id, kind: kind} = change, seen) when is_binary(id) do
    cond do
      MapSet.member?(seen, id) ->
        {:error, {:invalid_change_set, {:duplicate_id, id}}}

      not is_map_key(@required, kind) ->
        {:error, {:invalid_change_set, {:unknown_kind, id, kind}}}

      true ->
        case Enum.find(@required[kind], &(not valid_field?(change, &1))) do
          nil -> :ok
          field -> {:error, {:invalid_change_set, {:missing_field, id, field}}}
        end
    end
  end

  defp validate_change(_, _), do: {:error, {:invalid_change_set, :id_and_kind_required}}

  defp valid_field?(change, :nullable), do: is_boolean(Map.get(change, :nullable))
  defp valid_field?(change, field), do: is_binary(Map.get(change, field))

  defp check(%{kind: :rewrite_stored_history} = c, _before, _acks),
    do: [violation(c, :unbounded_lock, nil, :bounded_change)]

  defp check(%{kind: :add_column, nullable: false} = c, _before, _acks) do
    if has_default?(c), do: [], else: [violation(c, :not_covered, :b, :default_or_backfill)]
  end

  defp check(%{kind: :set_not_null} = c, before, acks) do
    cond do
      not Enum.any?(before, &covers?(&1, c)) -> [violation(c, :not_covered, :b, :backfill)]
      c.id not in acks -> [violation(c, :missing_ack, :b, :ack_destructive)]
      true -> []
    end
  end

  defp check(_change, _before, _acks), do: []

  defp covers?(%{kind: :backfill} = b, c), do: same_column?(b, c)
  defp covers?(%{kind: :add_column} = a, c), do: same_column?(a, c) and has_default?(a)
  defp covers?(_, _), do: false

  defp same_column?(a, b), do: a.entity_type == b.entity_type and a.attribute == b.attribute
  defp has_default?(change), do: Map.get(change, :default) != nil

  defp violation(change, kind, class, missing),
    do: %{change_id: change.id, change: change, kind: kind, class: class, missing: missing}

  defp plan(changes) do
    classes = Map.new(changes, &{&1.id, class_of(&1)})

    b_ids =
      classes |> Enum.filter(fn {_, c} -> c == :b end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    %{classes: classes, class_b_ids: b_ids}
  end

  defp class_of(%{kind: :set_not_null}), do: :b
  defp class_of(%{kind: :add_column, nullable: false}), do: :b
  defp class_of(_), do: :a
end
