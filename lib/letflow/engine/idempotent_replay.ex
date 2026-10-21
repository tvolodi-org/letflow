defmodule Letflow.Engine.IdempotentReplay do
  @moduledoc """
  GH #2577 -- what an engine command does when `Letflow.EventStore.append/2` answers
  `{:ok, %{is_duplicate: true}}` (the idempotency key was already claimed).

  `append/2` runs its own `Repo.transaction/1`, nested inside the engine's `Ecto.Multi`.
  On a duplicate key its inner Multi fails at `:idempotency`; `DBConnection` marks the
  enclosing transaction aborted, so nothing the engine wrote in the outer transaction can
  commit, and the next query (or the commit itself) raises. The raise reached callers as an
  untyped failure (`{:transaction_failed, _}`, contention, `:raised`) instead of the original
  result.

  - `fresh/1` is the guard each engine append step pipes its append result through. It adds
    no atomicity (the abort above already prevents the commit); it turns the duplicate into a
    typed Multi failure `{:idempotent_replay, original_event}` that the command's
    `interpret_*_result` can map to the original result. It must be the LAST expression of
    its Multi step: the connection is already aborted, so no query may follow it.
  - `lookup/3` reads the event that claimed a key, tenant-prefixed (INV-1), resolving an
    oversized `$ref` payload.

  Binding of a key to a request follows GH #2543: a key reused for another event type, actor
  or instance (or, where the payload allows the comparison, another payload) is
  `{:error, :idempotency_key_reuse}`, never the original's data.
  """

  import Ecto.Query, only: [where: 3, select: 3]

  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.StoredPayload
  alias Letflow.Repo

  @doc """
  Maps an `EventStore.append/2` result for use as the value of a Multi step.
  """
  @spec fresh({:ok, map()} | {:error, term()}) ::
          {:ok, map()} | {:error, {:idempotent_replay, Event.t()}} | {:error, term()}
  def fresh({:ok, %{is_duplicate: true, event: %Event{} = original}}),
    do: {:error, {:idempotent_replay, original}}

  def fresh(other), do: other

  @doc """
  The event that claimed `key` in tenant schema `prefix`, with an oversized payload resolved.
  Runs on `repo` so a caller inside a transaction stays on its connection.
  """
  @spec lookup(Ecto.Repo.t(), String.t(), String.t()) ::
          :none | {:ok, Event.t()} | {:error, {:idempotency_lookup_failed, term()}}
  def lookup(repo \\ Repo, key, prefix) when is_binary(key) and is_binary(prefix) do
    case repo.get_by(IdempotencyRecord, [idempotency_key: key], prefix: prefix) do
      nil ->
        :none

      %IdempotencyRecord{event_id: event_id, event_created_at: event_created_at} ->
        Event
        |> where([e], e.event_id == ^event_id and e.created_at == ^event_created_at)
        |> repo.one(prefix: prefix)
        |> case do
          nil -> {:error, {:idempotency_lookup_failed, :original_event_missing}}
          %Event{} = event -> resolve_payload(repo, event, prefix)
        end
    end
  end

  defp resolve_payload(repo, %Event{payload: %{"$ref" => ref} = payload} = event, prefix)
       when map_size(payload) == 1 and is_binary(ref) do
    StoredPayload
    |> where([sp], sp.event_id == ^ref)
    |> select([sp], sp.payload)
    |> repo.one(prefix: prefix)
    |> case do
      %{} = full -> {:ok, %Event{event | payload: full}}
      nil -> {:error, {:idempotency_lookup_failed, :payload_missing}}
    end
  end

  defp resolve_payload(_repo, %Event{} = event, _prefix), do: {:ok, event}

  @doc "Both sides cast to canonical UUIDs; a cast error on either side means \"not the same\"."
  @spec same_uuid?(term(), term()) :: boolean()
  def same_uuid?(a, b) do
    case {Ecto.UUID.cast(a), Ecto.UUID.cast(b)} do
      {{:ok, same}, {:ok, same}} -> true
      _ -> false
    end
  end

  @doc "A value as the event store would hand it back: through the JSON encoder and decoder."
  @spec canonical_json(term()) :: term()
  def canonical_json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
