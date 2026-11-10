defmodule Letflow.Engine.NodeEntries do
  @moduledoc """
  REQ-793 -- the writer of the `NODE_ENTERED` event (REQ-792 registered it, folds it as a
  replay no-op and refuses it to scripts).

  Every write that moves a token (instance start, task completion, service/script task
  completion, timer fire, sub-process completion) appends one
  `NODE_ENTERED {node_id, node_type, via_edge_id}` per node a token enters, in the same
  transaction as the write, right after the write's triggering event and before the
  projection reconcile (`EventStore.append/2`'s active-instance guard refuses an append once
  the projection is terminal, so the END entry must come first). The event changes no state:
  no outbox, webhook, backfill or replay effect.

  `Letflow.Engine.Transition` (the pure kernel, many exact-output test pins) is untouched.
  The entries are derived in the impure hop-chain layer by diffing the token list around
  each hop (`entries/4`) and carried as an engine-level element of the existing
  `pending_events` list, which every consumer filters by pattern:

      {:node_entered, node_id :: String.t(), node_type :: String.t(), via_edge_id :: String.t() | nil}

  ## Idempotency key

  `EventStore.append/2` requires an idempotency key on every event, so each entry carries a
  derived key `node_entered:<sha256 of the trigger's key and the instance id>:<index>`, never the caller's key
  itself (and short enough for any caller key). A replayed caller key is refused at the
  trigger event step, which rolls the whole transaction back before this step runs, so a
  replay adds no row.

  ## Known limitation

  Two edges with the same source and target: `via_edge_id` is the first in declaration
  order, even if the second was taken (an exact id would need a `Transition` change).
  """

  alias Ecto.Multi
  alias Letflow.Definitions.Graph
  alias Letflow.Engine.IdempotentReplay
  alias Letflow.Engine.Token
  alias Letflow.EventStore

  @type entry ::
          {:node_entered, String.t(), String.t(), String.t() | nil}

  @doc """
  The entries for ONE transition: tokens compared before/after, in `new_tokens` order.
  Never raises; an unknown shape yields no entry.
  """
  @spec entries(Graph.t(), [Token.t()], [Token.t()], String.t()) :: [entry()]
  def entries(%Graph{} = graph, previous_tokens, new_tokens, moved_token_id)
      when is_list(previous_tokens) and is_list(new_tokens) do
    previous_by_id = Map.new(previous_tokens, &{&1.token_id, &1})

    Enum.flat_map(new_tokens, fn %Token{} = token ->
      case Map.fetch(previous_by_id, token.token_id) do
        {:ok, %Token{node_id: previous_node}} ->
          if token.token_id == moved_token_id and token.node_id != previous_node do
            build(graph, token.node_id, first_edge_id(graph, previous_node, token.node_id))
          else
            []
          end

        :error ->
          build(graph, token.node_id, derived_via_edge(graph, previous_by_id, token))
      end
    end)
  end

  def entries(_graph, _previous, _new, _moved), do: []

  @doc "The entry for the START node an instance is created on."
  @spec start_entry(Graph.t()) :: [entry()]
  def start_entry(%Graph{nodes: nodes}) do
    case Enum.find(nodes, &(&1.node_type == :START)) do
      nil -> []
      node -> [{:node_entered, node.id, "START", nil}]
    end
  end

  @doc "Only the node-entered elements of a pending-event list."
  @spec only([term()]) :: [entry()]
  def only(pending_events) when is_list(pending_events),
    do: Enum.filter(pending_events, &match?({:node_entered, _, _, _}, &1))

  @doc "Everything but the node-entered elements of a pending-event list."
  @spec reject([term()]) :: [term()]
  def reject(pending_events) when is_list(pending_events),
    do: Enum.reject(pending_events, &match?({:node_entered, _, _, _}, &1))

  @doc """
  Adds one Multi step that appends every `:node_entered` element of `pending_events`, in
  order. Returns `multi` unchanged when there is none.
  """
  @spec append_multi(Multi.t(), String.t(), [term()], term(), term(), String.t(), term()) ::
          Multi.t()
  def append_multi(multi, instance_id, pending_events, actor_id, base_key, prefix, tag \\ nil) do
    case only(pending_events) do
      [] ->
        multi

      entries ->
        step =
          if tag == nil, do: {:node_entered, instance_id}, else: {:node_entered, instance_id, tag}

        Multi.run(multi, step, fn _repo, _changes ->
          append_all(
            entries,
            instance_id,
            actor_id,
            key_digest(base_key, instance_id, tag),
            prefix
          )
        end)
    end
  end

  defp append_all(entries, instance_id, actor_id, digest, prefix) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{:node_entered, node_id, node_type, via_edge_id}, index},
                                       {:ok, acc} ->
      event_attrs = %{
        instance_id: instance_id,
        event_type: "NODE_ENTERED",
        payload:
          Jason.encode!(%{node_id: node_id, node_type: node_type, via_edge_id: via_edge_id}),
        actor_id: actor_id,
        idempotency_key: "node_entered:" <> digest <> ":" <> Integer.to_string(index)
      }

      case EventStore.append(event_attrs, prefix: prefix) |> IdempotentReplay.fresh() do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, {:event_append_failed, reason}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end

  # The instance id and `tag` are part of the digest: one caller key can append for several
  # instances (a sub-process cascade) and several times for one instance (the write's own
  # entries, then the entries of a synchronously completing child's cascade).
  defp key_digest(base_key, instance_id, tag) do
    material = "#{if is_binary(base_key), do: base_key}|#{instance_id}|#{inspect(tag)}"
    :crypto.hash(:sha256, material) |> Base.encode16(case: :lower)
  end

  defp build(%Graph{nodes: nodes}, node_id, via_edge_id) do
    case Enum.find(nodes, &(&1.id == node_id)) do
      nil -> []
      node -> [{:node_entered, node.id, Atom.to_string(node.node_type), via_edge_id}]
    end
  end

  defp first_edge_id(%Graph{edges: edges}, source, target) do
    case Enum.find(edges, &(&1.source == source and &1.target == target)) do
      nil -> nil
      edge -> edge.id
    end
  end

  # A token that did not exist before the hop: a parallel split branch
  # (`<origin>/<index>`) or the merged token a join fires (`<origin>/<join>/joined`).
  defp derived_via_edge(graph, previous_by_id, %Token{token_id: token_id, node_id: node_id}) do
    cond do
      String.ends_with?(token_id, "/joined") ->
        join =
          Enum.find(graph.nodes, fn n ->
            String.ends_with?(token_id, "/" <> n.id <> "/joined") and
              first_edge_id(graph, n.id, node_id) != nil
          end)

        if join, do: first_edge_id(graph, join.id, node_id), else: nil

      true ->
        with {origin_id, index_str} <- split_last(token_id),
             {index, ""} <- Integer.parse(index_str),
             %Token{node_id: origin_node} <- Map.get(previous_by_id, origin_id),
             edge when not is_nil(edge) <-
               graph.edges |> Enum.filter(&(&1.source == origin_node)) |> Enum.at(index) do
          edge.id
        else
          _ -> nil
        end
    end
  end

  defp split_last(token_id) do
    case String.split(token_id, "/") do
      [_single] -> nil
      parts -> {parts |> Enum.drop(-1) |> Enum.join("/"), List.last(parts)}
    end
  end
end
