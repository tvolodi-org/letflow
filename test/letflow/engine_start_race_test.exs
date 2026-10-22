defmodule Letflow.EngineStartRaceTest do
  @moduledoc """
  GH #2577 (AC 1, T-start-race) -- two same-key starts that both pass `start_replay_check/3`
  before either inserts. The loser's INSTANCE_STARTED append finds the key claimed, its Multi
  rolls back, and it answers the winner's instance (`resolve_start_race/5`).

  The interleaving is forced by the `:engine_test_seams` gate in `Letflow.Engine.create/2`: both
  starts park after their replay check, and the test releases them together.

  Real Postgres, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp active_definition!(schema_name) do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }

    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique("gh2577race-def"),
                 version: "1.0.0",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  test "two same-key starts both pass the replay check and answer one instance" do
    %{schema_name: schema} =
      TenantFixture.provisioned_tenant!(slug_prefix: "gh2577race", display_name: "GH-2577 Race")

    definition = active_definition!(schema)
    key = unique("start-race")
    actor_id = Ecto.UUID.generate()

    attrs = %{
      definition_id: definition.id,
      initial_variables: %{},
      actor_id: actor_id,
      idempotency_key: key
    }

    # arm the gate for this key only; the test is async: false, so no other start sees it
    :persistent_term.put({Engine, :start_race_gate}, {self(), key})
    on_exit(fn -> :persistent_term.erase({Engine, :start_race_gate}) end)

    first = Task.async(fn -> Engine.create(attrs, prefix: schema) end)
    second = Task.async(fn -> Engine.create(attrs, prefix: schema) end)

    # both starts have passed start_replay_check/3 and are parked before any insert
    assert_receive {:start_race_arrived, first_pid}, 5_000
    assert_receive {:start_race_arrived, second_pid}, 5_000
    assert first_pid != second_pid

    send(first_pid, :start_race_go)
    send(second_pid, :start_race_go)

    assert {:ok, one} = Task.await(first, 10_000)
    assert {:ok, two} = Task.await(second, 10_000)
    assert one.instance_id == two.instance_id

    # one INSTANCE_STARTED for the key, and one projection row for the instance
    started =
      Event
      |> where([e], e.idempotency_key == ^key and e.event_type == "INSTANCE_STARTED")
      |> Repo.all(prefix: schema)

    assert [_one] = started

    assert [_row] =
             InstanceProjection
             |> where([p], p.definition_id == ^definition.id)
             |> Repo.all(prefix: schema)
  end
end
