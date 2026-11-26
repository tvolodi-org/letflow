defmodule Letflow.Scripts.BpPlatform01StepLogTest do
  use ExUnit.Case, async: true

  # T-2840: the step-log expectations of C2 and G5 follow the SEEDED v2 definition
  # (`Letflow.PlatformProcesses.DefinitionV2`: ... install_default_modules -> notify_gate ->
  # notify -> end), not v1's node list. Real log: smoke run 20261126T035144Z-25c9dc.
  @scenario "test/uat/processes/BP-PLATFORM-01-register-tenant.json"

  defp expected_nodes(step_id) do
    steps = @scenario |> File.read!() |> Jason.decode!() |> Map.fetch!("steps")
    json = steps |> Enum.find(&(&1["id"] == step_id)) |> get_in(["expect", "json"])

    json
    |> Enum.flat_map(fn
      {"$.steps[" <> rest, id} when is_binary(id) ->
        case Integer.parse(rest) do
          {i, "].node_id"} -> [{i, id}]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp v2_walk do
    nodes = Letflow.PlatformProcesses.DefinitionV2.graph()["nodes"] |> Enum.map(& &1["id"])
    # the timeline lists the start row at [0]; the scenario asserts from [1]
    tl(nodes)
  end

  test "C2 and G5 name every node of the seeded v2 walk (notify_admin true), in order" do
    assert v2_walk() == expected_nodes("C2")
    assert v2_walk() == expected_nodes("G5")
    assert "notify_gate" in expected_nodes("C2")
  end
end
