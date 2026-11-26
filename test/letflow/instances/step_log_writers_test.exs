defmodule Letflow.Instances.StepLogWritersTest do
  @moduledoc """
  Class test for the step log (T-2602, rows R1/R2): the step log's reading of
  an event is derived from the REAL writers in `lib/`, not from a hand list.

    * every completion event type the tree writes (`*_COMPLETED`,
      `TIMER_FIRED`) is in `StepLog.completion_event_types/0`, and every type
      in that list has a writer that puts a top-level `node_id` in its payload;
    * the EXECUTION_ERROR writer names the failed node under `affected`
      (kind "node"), which is where the step log reads it.

  A writer that renames or moves `node_id`, or a sixth completion type, turns
  this red instead of leaving a visit silently open.
  """
  use ExUnit.Case, async: true

  alias Letflow.Instances.StepLog

  @lib_files Path.wildcard("lib/**/*.ex")

  # Event types written as `event_type: "X",` in a map/keyword (a writer),
  # with the text of the lines around it (the payload is often built just above).
  defp writers do
    for file <- @lib_files,
        not String.ends_with?(file, "instances/step_log.ex"),
        lines = file |> File.read!() |> String.split("\n"),
        {line, idx} <- Enum.with_index(lines),
        [_, type] <- [Regex.run(~r/^\s*event_type: "([A-Z_]+)",\s*$/, line)],
        do: {type, file, lines |> Enum.slice(max(idx - 60, 0), 90) |> Enum.join("\n")}
  end

  test "every completion event type the tree writes is read by the step log" do
    written =
      writers()
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&(String.ends_with?(&1, "_COMPLETED") or &1 == "TIMER_FIRED"))
      |> Enum.uniq()
      |> Enum.sort()

    assert written != []
    assert written == Enum.sort(StepLog.completion_event_types())
  end

  test "each completion writer puts a top-level node_id in its payload" do
    by_type = writers() |> Enum.group_by(&elem(&1, 0))

    for type <- StepLog.completion_event_types() do
      assert [_ | _] = found = Map.get(by_type, type, []), "no writer of #{type}"

      assert Enum.any?(found, fn {_, _, body} -> body =~ ~r/\bnode_id:|"node_id" =>/ end),
             "no writer of #{type} writes a top-level node_id"
    end
  end

  test "the EXECUTION_ERROR writer names the node under affected, as the step log reads it" do
    src = File.read!("lib/letflow/engine/execution_error.ex")
    assert src =~ ~r/encode_affected\(\{:node, node_id\}\)/
    assert src =~ ~r/"kind" => "node"/

    log = File.read!("lib/letflow/instances/step_log.ex")
    assert log =~ "affected"
  end
end
