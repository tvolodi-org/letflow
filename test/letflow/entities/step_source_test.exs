defmodule Letflow.Entities.StepSourceTest do
  @moduledoc """
  GH #2627: `StepSource.new/1` validates exactly the invariants `Records` used to
  validate on the map, and `to_metadata/1` is byte-identical to the flat
  `source.*` event metadata of the design (D-A2.5). Pure functions, `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.StepSource

  @instance "11111111-1111-4111-8111-111111111111"
  @task "22222222-2222-4222-8222-222222222222"
  @dispatch "33333333-3333-4333-8333-333333333333"
  @definition "44444444-4444-4444-8444-444444444444"
  @activator "55555555-5555-4555-8555-555555555555"

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        kind: "process_step",
        instance_id: @instance,
        task_id: @task,
        node_id: "approve_order",
        definition_id: @definition,
        definition_version: "1.0.0",
        line_index: 2,
        activator_id: @activator
      },
      overrides
    )
  end

  test "to_metadata/1 is the literal flat string map (task origin)" do
    assert {:ok, source} = StepSource.new(attrs())

    assert StepSource.to_metadata(source) == %{
             "source.kind" => "process_step",
             "source.instance_id" => "11111111-1111-4111-8111-111111111111",
             "source.task_id" => "22222222-2222-4222-8222-222222222222",
             "source.node_id" => "approve_order",
             "source.definition_id" => "44444444-4444-4444-8444-444444444444",
             "source.definition_version" => "1.0.0",
             "source.line_index" => "2",
             "source.activator_id" => "55555555-5555-4555-8555-555555555555"
           }
  end

  test "a dispatch origin is source.dispatch_id and never source.task_id" do
    assert {:ok, source} = StepSource.new(attrs(%{task_id: nil, dispatch_id: @dispatch}))
    metadata = StepSource.to_metadata(source)
    assert metadata["source.dispatch_id"] == @dispatch
    refute Map.has_key?(metadata, "source.task_id")
    assert map_size(metadata) == 8
  end

  test "kind defaults to process_step when omitted and is the stored value" do
    assert {:ok, source} = StepSource.new(Map.delete(attrs(), :kind))
    assert source.kind == "process_step"
    assert StepSource.to_metadata(source)["source.kind"] == "process_step"
  end

  test "UUIDs are stored in cast (lowercase) form, as the metadata always carried" do
    assert {:ok, source} = StepSource.new(attrs(%{instance_id: String.upcase(@instance)}))
    assert source.instance_id == @instance
  end

  test "boundaries: node_id 1 and 1024 bytes, version 1 and 255 bytes, line_index 0" do
    for overrides <- [
          %{node_id: "n"},
          %{node_id: String.duplicate("n", 1024)},
          %{definition_version: "v"},
          %{definition_version: String.duplicate("v", 255)},
          %{line_index: 0}
        ] do
      assert {:ok, %StepSource{}} = StepSource.new(attrs(overrides)), inspect(overrides)
    end
  end

  test "every invalid input is {:error, :invalid_step_source}, never a raise" do
    invalid = [
      attrs(%{kind: "client"}),
      attrs(%{dispatch_id: @dispatch}),
      attrs(%{task_id: nil}),
      attrs(%{task_id: "nope"}),
      attrs(%{instance_id: "nope"}),
      attrs(%{definition_id: 5}),
      attrs(%{activator_id: nil}),
      attrs(%{node_id: ""}),
      attrs(%{node_id: String.duplicate("n", 1025)}),
      attrs(%{node_id: <<0xFF, 0xFE>>}),
      attrs(%{definition_version: ""}),
      attrs(%{definition_version: 3}),
      attrs(%{definition_version: String.duplicate("v", 256)}),
      attrs(%{definition_version: <<0xFF>>}),
      attrs(%{line_index: -1}),
      attrs(%{line_index: "0"}),
      attrs(%{line_index: 1.0}),
      attrs(%{extra: "x"}),
      %{},
      struct!(StepSource,
        kind: "process_step",
        instance_id: @instance,
        node_id: "n",
        definition_id: @definition,
        definition_version: "1",
        line_index: 0,
        activator_id: @activator
      ),
      "nope",
      nil,
      [kind: "process_step"]
    ]

    for input <- invalid do
      assert StepSource.new(input) == {:error, :invalid_step_source}, inspect(input)
    end
  end

  test "string-keyed maps are refused (the struct is built server-side from atoms)" do
    string_keyed = Map.new(attrs(), fn {k, v} -> {Atom.to_string(k), v} end)
    assert StepSource.new(string_keyed) == {:error, :invalid_step_source}
  end
end
