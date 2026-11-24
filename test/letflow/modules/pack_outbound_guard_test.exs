defmodule Letflow.Modules.PackOutboundGuardTest do
  @moduledoc """
  T-2724 (pilot gap G14, decision record G2 (c)): a tenant's outbound allow-list is
  deny by default, so a module-shipped process definition that reaches outside the
  tenant (a notification step, an inline HTTP `endpoint`) could never be switched on in
  a fresh tenant. This guard is DERIVED from the tree: it reads every
  `priv/modules/*/pack.json` and fails on a shipped process graph that has such a node,
  unless the destination is system-listed -- the pack's node names an entry of
  `@system_listed` with a reason (`shipped definition <name>`).

  The list is empty today (assets 7, maintenance 1, stock 10 definitions: no outbound
  node). Listing a shipped destination is a reviewed decision, not a way to silence the
  guard.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.OutboundDestinations

  # [{{pack_dir, process_key, node_id}, reason}]; a reason must read "shipped definition <name>".
  @system_listed []

  defp packs, do: Path.wildcard("priv/modules/*/pack.json") |> Enum.sort()

  @doc false
  def outbound_nodes(graph_map) do
    case Graph.from_map(graph_map) do
      {:ok, %Graph{nodes: nodes}} ->
        for node <- nodes, OutboundDestinations.node_target(node) != nil, do: node.id

      :error ->
        []
    end
  end

  defp listed?(pack_dir, key, node_id) do
    case List.keyfind(@system_listed, {pack_dir, key, node_id}, 0) do
      {_, reason} -> reason == "shipped definition " <> key
      nil -> false
    end
  end

  defp unlisted(pack_dir, definitions) do
    for %{"process_key" => key, "graph" => graph} <- definitions,
        is_map(graph),
        node_id <- outbound_nodes(graph),
        not listed?(pack_dir, key, node_id),
        do: {pack_dir, key, node_id}
  end

  test "the tree has packs to scan" do
    assert length(packs()) >= 9
  end

  test "G-OUT-1: no shipped process graph has an unlisted outbound node" do
    offenders =
      for path <- packs(),
          document = path |> File.read!() |> Jason.decode!(),
          bad <- unlisted(Path.basename(Path.dirname(path)), List.wrap(document["definitions"])),
          do: bad

    assert offenders == []
  end

  test "G-OUT-2 (negative fixture): an outbound node in a pack graph is caught" do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => "https://example.test/hook"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "end"}
      ]
    }

    assert outbound_nodes(graph) == ["call"]

    assert unlisted("fixture", [%{"process_key" => "rogue", "graph" => graph}]) ==
             [{"fixture", "rogue", "call"}]
  end
end
