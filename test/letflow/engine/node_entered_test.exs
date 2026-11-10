defmodule Letflow.Engine.NodeEnteredTest do
  @moduledoc """
  REQ-793 -- the engine appends one `NODE_ENTERED {node_id, node_type, via_edge_id}` event for
  every node a token enters, in the same transaction as the move, right after the write's
  triggering event, with no outbox/webhook effect and no replay effect.

  T-793-1 .. T-793-3, T-793-6, T-793-7, T-793-8: real Postgres, Sandbox `:auto`, one
  provisioned tenant per test. T-793-12: the pure `NodeEntries.entries/4`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Engine
  alias Letflow.Engine.NodeEntries
  alias Letflow.Engine.PinResolver.Lookup
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.Token
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(slug_prefix: "req793", display_name: "REQ-793 Test Tenant")
  end

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp task_node(id),
    do: %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "r"}}

  defp linear_graph do
    %{
      "nodes" => [%{"id" => "start", "node_type" => "START"}, task_node("a"), end_node()],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "a"},
        %{"id" => "e2", "source" => "a", "target" => "end"}
      ]
    }
  end

  defp end_node, do: %{"id" => "end", "node_type" => "END"}

  defp parallel_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        task_node("x"),
        task_node("y"),
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        end_node()
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "split"},
        %{"id" => "e2", "source" => "split", "target" => "x"},
        %{"id" => "e3", "source" => "split", "target" => "y"},
        %{"id" => "e4", "source" => "x", "target" => "join"},
        %{"id" => "e5", "source" => "y", "target" => "join"},
        %{"id" => "e6", "source" => "join", "target" => "end"}
      ]
    }
  end

  defp gateway_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        task_node("b"),
        task_node("c")
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gw"},
        %{"id" => "e2", "source" => "gw", "target" => "b", "condition" => "variables.p == 1"},
        %{"id" => "e3", "source" => "gw", "target" => "c", "is_default" => true},
        %{"id" => "e4", "source" => "b", "target" => "end"},
        %{"id" => "e5", "source" => "c", "target" => "end"}
      ]
    }
    |> Map.update!("nodes", &(&1 ++ [end_node()]))
  end

  defp active_definition!(schema, graph) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique("req793-def"),
                 version: "1.0.0",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema)

    activated
  end

  defp v1_pin_lookup do
    %Lookup{
      catalog_lookup: fn _ref -> {:error, :not_found} end,
      module_lookup: fn _ref -> {:error, :not_found} end,
      variable_schema_lookup: fn _tenant_id, _process_key ->
        {:ok, %{version: "v1", json_schema: nil}}
      end
    }
  end

  defp start!(schema, definition, variables \\ %{"p" => 0}, key \\ nil) do
    assert {:ok, instance} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: variables,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: key || unique("start"),
                 pin_lookup: v1_pin_lookup(),
                 pin_overrides: [%{kind: :variable_schema, ref: definition.name, version: "v1"}]
               },
               prefix: schema
             )

    instance.instance_id
  end

  defp complete!(schema, instance_id, node_id, key \\ nil) do
    task =
      EngineTask
      |> where(
        [t],
        t.instance_id == ^instance_id and t.node_id == ^node_id and t.status == :pending
      )
      |> Repo.one!(prefix: schema)

    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: key || unique("complete")
               },
               prefix: schema
             )
  end

  defp events(schema, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id)
    |> order_by([e], e.sequence_number)
    |> Repo.all(prefix: schema)
  end

  defp types(events), do: Enum.map(events, & &1.event_type)

  defp entered(events) do
    for %{event_type: "NODE_ENTERED"} = e <- events do
      payload = decode(e.payload)
      {payload["node_id"], payload["node_type"], payload["via_edge_id"]}
    end
  end

  defp decode(payload) when is_binary(payload), do: Jason.decode!(payload)
  defp decode(payload) when is_map(payload), do: Jason.decode!(Jason.encode!(payload))

  describe "T-793-1 START -> A -> END" do
    test "events and payloads" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema, linear_graph())
      id = start!(schema, definition)

      assert types(events(schema, id)) == ["INSTANCE_STARTED", "NODE_ENTERED", "NODE_ENTERED"]
      assert entered(events(schema, id)) == [{"start", "START", nil}, {"a", "HUMAN_TASK", "e1"}]

      complete!(schema, id, "a")
      all = events(schema, id)

      assert types(all) ==
               [
                 "INSTANCE_STARTED",
                 "NODE_ENTERED",
                 "NODE_ENTERED",
                 "TASK_COMPLETED",
                 "NODE_ENTERED"
               ]

      assert List.last(entered(all)) == {"end", "END", "e2"}
      # criterion 4: every entry follows its trigger event
      [_, _, _, completed, last] = all
      assert last.sequence_number > completed.sequence_number
    end
  end

  describe "T-793-2 exclusive gateway" do
    test "only the chosen branch is entered" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema, gateway_graph())
      id = start!(schema, definition, %{"p" => 0})

      assert entered(events(schema, id)) == [
               {"start", "START", nil},
               {"gw", "EXCLUSIVE_GATEWAY", "e1"},
               {"c", "HUMAN_TASK", "e3"}
             ]
    end
  end

  describe "T-793-3 parallel split and join" do
    test "one entry per branch, one for the join, one for END" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema, parallel_graph())
      id = start!(schema, definition)

      assert entered(events(schema, id)) == [
               {"start", "START", nil},
               {"split", "PARALLEL_GATEWAY", "e1"},
               {"x", "HUMAN_TASK", "e2"},
               {"y", "HUMAN_TASK", "e3"}
             ]

      complete!(schema, id, "x")
      assert List.last(entered(events(schema, id))) == {"join", "PARALLEL_GATEWAY", "e4"}

      complete!(schema, id, "y")
      tail = events(schema, id) |> entered() |> Enum.take(-2)
      assert tail == [{"join", "PARALLEL_GATEWAY", "e5"}, {"end", "END", "e6"}]
    end
  end

  describe "T-793-6 replay" do
    test "a same-key replay adds no event and no row carries the caller's key" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema, linear_graph())
      key = unique("same")
      id = start!(schema, definition, %{"p" => 0}, key)

      attrs = %{
        definition_id: definition.id,
        initial_variables: %{"p" => 0},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: key,
        pin_lookup: v1_pin_lookup(),
        pin_overrides: [%{kind: :variable_schema, ref: definition.name, version: "v1"}]
      }

      before = events(schema, id)
      # the replay answers (or refuses) without writing
      _ = Engine.create(attrs, prefix: schema)
      assert length(events(schema, id)) == length(before)

      keys =
        Repo.all(
          from(i in "event_idempotency",
            where: i.idempotency_key == ^key,
            select: i.idempotency_key
          ),
          prefix: schema
        )

      assert length(keys) == 1

      derived =
        Repo.all(
          from(i in "event_idempotency",
            where: like(i.idempotency_key, "node_entered:%"),
            select: i.idempotency_key
          ),
          prefix: schema
        )

      assert length(derived) == 2
      assert Enum.all?(derived, &(byte_size(&1) < 100))
    end
  end

  describe "T-793-7 cancel" do
    test "cancel writes no NODE_ENTERED" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema, linear_graph())
      id = start!(schema, definition)
      before = events(schema, id) |> entered() |> length()

      assert {:ok, _} =
               Engine.cancel_instance(
                 id,
                 %{actor_id: Ecto.UUID.generate(), idempotency_key: unique("cancel")},
                 prefix: schema
               )

      assert events(schema, id) |> entered() |> length() == before
    end
  end

  describe "T-793-8 replay equals projection, no outbox effect" do
    test "Reconstruction folds the entries as no-ops" do
      %{schema_name: schema} = provisioned_tenant()
      definition = active_definition!(schema, parallel_graph())
      id = start!(schema, definition)
      complete!(schema, id, "x")
      complete!(schema, id, "y")

      projection = Repo.get_by!(InstanceProjection, [instance_id: id], prefix: schema)

      assert {:ok, %{instance_state: state}} =
               Reconstruction.reconstruct_instance(id, prefix: schema)

      assert state.status == projection.status
      assert state.variables == projection.variables
      assert projection.last_event_seq == length(events(schema, id))
    end
  end

  describe "T-793-9 no other writer" do
    test "NODE_ENTERED is appended only by NodeEntries" do
      writers =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ ~s(event_type: "NODE_ENTERED",)))

      assert writers == ["lib/letflow/engine/node_entries.ex"]

      for dir <- ["priv", "lib/mix"],
          file <- Path.wildcard(dir <> "/**/*.{ex,exs}") do
        refute File.read!(file) =~ ~s(event_type: "NODE_ENTERED",), file
      end
    end
  end

  describe "T-793-12 NodeEntries.entries/4" do
    defp graph! do
      {:ok, g} = Engine.build_graph(parallel_graph())
      g
    end

    test "a moved token gets the edge it took" do
      g = graph!()
      prev = [%Token{token_id: "t", node_id: "x"}]
      new = [%Token{token_id: "t", node_id: "join"}]

      assert [{:node_entered, "join", "PARALLEL_GATEWAY", "e4"}] =
               NodeEntries.entries(g, prev, new, "t")
    end

    test "split branches take the index-th outgoing edge" do
      g = graph!()
      prev = [%Token{token_id: "t", node_id: "split"}]

      new = [
        %Token{token_id: "t/0", node_id: "x"},
        %Token{token_id: "t/1", node_id: "y"}
      ]

      assert [
               {:node_entered, "x", "HUMAN_TASK", "e2"},
               {:node_entered, "y", "HUMAN_TASK", "e3"}
             ] = NodeEntries.entries(g, prev, new, "t")
    end

    test "a merged join token takes the join's outgoing edge" do
      g = graph!()
      prev = [%Token{token_id: "t/1", node_id: "join"}]
      new = [%Token{token_id: "t/join/joined", node_id: "end"}]
      assert [{:node_entered, "end", "END", "e6"}] = NodeEntries.entries(g, prev, new, "t/1")
    end

    test "a token that stays or is removed yields nothing; unknown input never raises" do
      g = graph!()
      same = [%Token{token_id: "t", node_id: "x"}]
      assert [] = NodeEntries.entries(g, same, same, "t")
      assert [] = NodeEntries.entries(g, same, [], "t")
      assert [] = NodeEntries.entries(:nope, :nope, :nope, "t")
    end

    test "two parallel edges between the same nodes: the first wins" do
      {:ok, g} =
        Engine.build_graph(%{
          "nodes" => [%{"id" => "a", "node_type" => "HUMAN_TASK"}, end_node()],
          "edges" => [
            %{"id" => "f1", "source" => "a", "target" => "end"},
            %{"id" => "f2", "source" => "a", "target" => "end"}
          ]
        })

      assert %Graph{} = g

      assert [{:node_entered, "end", "END", "f1"}] =
               NodeEntries.entries(
                 g,
                 [%Token{token_id: "t", node_id: "a"}],
                 [%Token{token_id: "t", node_id: "end"}],
                 "t"
               )
    end

    test "start_entry names the START node" do
      assert [{:node_entered, "start", "START", nil}] = NodeEntries.start_entry(graph!())
    end
  end
end
