defmodule Letflow.OutboundAllowFixture do
  @moduledoc """
  Test helper for the G14 outbound allow-list (T-2597, T-2724).

  The list is deny by default, so a test that activates a definition with a
  notification, file or inline HTTP step in a fresh tenant must first open
  what the definition uses. This is the ONE place that does it: it goes
  through the public writer `Letflow.OutboundDestinations.add/4`, the same
  call a tenant administrator's route ends in. It bypasses nothing and does
  not touch the guard.

    * `allow_graph!/2` -- opens every channel and every literal HTTP host a
      graph map uses (a dynamic host stays refused, as in production);
    * `allow_definition!/2` -- the same for a stored definition row.
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.OutboundDestinations
  alias Letflow.Repo

  @doc "Opens the channels and literal hosts of `graph_map` for tenant `prefix`."
  @spec allow_graph!(String.t(), map()) :: :ok
  def allow_graph!(prefix, graph_map) when is_binary(prefix) and is_map(graph_map) do
    case Graph.from_map(graph_map) do
      {:ok, %Graph{nodes: nodes}} ->
        for node <- nodes, target = OutboundDestinations.node_target(node), target != nil do
          {channel, destination} = target
          {:ok, _} = OutboundDestinations.add(prefix, nil, channel, nil)

          if is_binary(destination) do
            {:ok, _} = OutboundDestinations.add(prefix, nil, channel, destination)
          end
        end

        :ok

      :error ->
        :ok
    end
  end

  @doc "Opens what the stored definition `definition_id` uses, for tenant `prefix`."
  @spec allow_definition!(String.t(), String.t()) :: :ok
  def allow_definition!(prefix, definition_id) when is_binary(prefix) do
    %ProcessDefinition{graph: graph} = Repo.get!(ProcessDefinition, definition_id, prefix: prefix)
    allow_graph!(prefix, graph)
  end
end
