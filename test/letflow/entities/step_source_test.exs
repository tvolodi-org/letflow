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

  test "every UUID field is stored in cast (lowercase) form, as the metadata always carried" do
    for {field, uuid} <- [
          instance_id: @instance,
          definition_id: @definition,
          activator_id: @activator,
          task_id: @task
        ] do
      assert {:ok, source} = StepSource.new(attrs(%{field => String.upcase(uuid)}))
      assert Map.fetch!(source, field) == uuid, inspect(field)
      assert StepSource.to_metadata(source)["source." <> Atom.to_string(field)] == uuid
    end

    assert {:ok, source} =
             StepSource.new(attrs(%{task_id: nil, dispatch_id: String.upcase(@dispatch)}))

    assert source.dispatch_id == @dispatch
    assert StepSource.to_metadata(source)["source.dispatch_id"] == @dispatch
  end

  test "the origin and the step idempotency key are derived from the struct" do
    assert {:ok, task} = StepSource.new(attrs(%{line_index: 7}))
    assert StepSource.origin(task) == {:task, @task}
    assert StepSource.idempotency_key(task) == "sys:step:" <> @task <> ":7"

    assert {:ok, dispatch} = StepSource.new(attrs(%{task_id: nil, dispatch_id: @dispatch}))
    assert StepSource.origin(dispatch) == {:dispatch, @dispatch}
    assert StepSource.idempotency_key(dispatch) == "sys:step:" <> @dispatch <> ":2"
  end

  # C0 delta F1 (GH #2587 PR C): the key is derived from the CAST (lowercase) id, never from the
  # caller's spelling, so an uppercase producer id and a lowercase one name the same key.
  test "F1: the idempotency key uses the cast-lowercased origin id" do
    assert {:ok, task} = StepSource.new(attrs(%{task_id: String.upcase(@task)}))
    assert StepSource.idempotency_key(task) == "sys:step:" <> @task <> ":2"
    assert StepSource.origin(task) == {:task, @task}

    assert {:ok, dispatch} =
             StepSource.new(attrs(%{task_id: nil, dispatch_id: String.upcase(@dispatch)}))

    assert StepSource.idempotency_key(dispatch) == "sys:step:" <> @dispatch <> ":2"
    assert StepSource.idempotency_key(dispatch) =~ ~r/\Asys:step:[0-9a-f-]+:2\z/
  end

  # C0 delta F2: a struct that did not come from new/1 (both or neither origin id, a non-integer
  # ordinal) is a programming error that names its cause instead of a bare FunctionClauseError /
  # CaseClauseError.
  test "F2: origin/1, idempotency_key/1 and to_metadata/1 raise ArgumentError on a malformed struct" do
    base = %{
      kind: "process_step",
      instance_id: @instance,
      node_id: "n",
      definition_id: @definition,
      definition_version: "1",
      line_index: 0,
      activator_id: @activator
    }

    neither = struct!(StepSource, base)
    both = struct!(StepSource, Map.merge(base, %{task_id: @task, dispatch_id: @dispatch}))
    bad_ordinal = struct!(StepSource, Map.merge(base, %{task_id: @task, write_ordinal: "x"}))

    for malformed <- [neither, both] do
      assert_raise ArgumentError, ~r/malformed step source/, fn ->
        StepSource.origin(malformed)
      end

      assert_raise ArgumentError, ~r/malformed step source/, fn ->
        StepSource.idempotency_key(malformed)
      end
    end

    assert_raise ArgumentError, ~r/malformed step source/, fn ->
      StepSource.to_metadata(neither)
    end

    assert_raise ArgumentError, ~r/malformed step source/, fn ->
      StepSource.idempotency_key(bad_ordinal)
    end
  end

  test "an absent task_id key with dispatch_id set is a dispatch origin" do
    dispatch_only = attrs() |> Map.delete(:task_id) |> Map.put(:dispatch_id, @dispatch)
    assert {:ok, source} = StepSource.new(dispatch_only)
    assert source.task_id == nil
    assert source.dispatch_id == @dispatch
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
      attrs(%{kind: nil}),
      attrs(%{dispatch_id: "nope", task_id: nil}),
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

  describe "handler writes (GH #2590 / REQ-501 R4a, design 4.4)" do
    defp handler_attrs(overrides \\ %{}) do
      attrs(
        Map.merge(
          %{handler: %{module_id: "fixture_ledger", name: "post_entry"}, write_ordinal: 2},
          overrides
        )
      )
    end

    test "a declarative line is unchanged: nil handler and ordinal, key = line_index, 8 keys" do
      assert {:ok, source} = StepSource.new(attrs())
      assert source.handler == nil and source.write_ordinal == nil
      assert StepSource.line_key(source) == 2
      assert StepSource.idempotency_key(source) == "sys:step:" <> @task <> ":2"
      assert map_size(StepSource.to_metadata(source)) == 8
    end

    test "explicit nil handler and ordinal are the declarative line (Records re-runs new/1)" do
      assert {:ok, source} = StepSource.new(attrs(%{handler: nil, write_ordinal: nil}))
      assert {:ok, ^source} = StepSource.new(Map.from_struct(source))
    end

    test "a handler write: key 20 + line_index * 50 + ordinal, idempotency key with ordinal" do
      assert {:ok, source} = StepSource.new(handler_attrs())
      assert StepSource.line_key(source) == 20 + 2 * 50 + 2
      assert StepSource.idempotency_key(source) == "sys:step:" <> @task <> ":2:2"
      assert StepSource.call_key(2) == 120
      assert {:ok, ^source} = StepSource.new(Map.from_struct(source))
    end

    test "the metadata gains exactly the three handler keys; the 8 existing are identical" do
      assert {:ok, plain} = StepSource.new(attrs())
      assert {:ok, source} = StepSource.new(handler_attrs())
      metadata = StepSource.to_metadata(source)

      assert Map.take(metadata, Map.keys(StepSource.to_metadata(plain))) ==
               StepSource.to_metadata(plain)

      assert Map.drop(metadata, Map.keys(StepSource.to_metadata(plain))) == %{
               "source.handler_module" => "fixture_ledger",
               "source.handler_name" => "post_entry",
               "source.write_ordinal" => "2"
             }
    end

    test "handler keys and declarative keys never collide (ordinals 1..49, indexes 0..19)" do
      declarative =
        for index <- 0..19 do
          {:ok, s} = StepSource.new(attrs(%{line_index: index}))
          StepSource.line_key(s)
        end

      handler_keys =
        for index <- 0..19, ordinal <- 0..49 do
          if ordinal == 0 do
            StepSource.call_key(index)
          else
            {:ok, s} = StepSource.new(handler_attrs(%{line_index: index, write_ordinal: ordinal}))
            StepSource.line_key(s)
          end
        end

      assert length(Enum.uniq(handler_keys)) == length(handler_keys)
      assert Enum.all?(declarative, &(&1 < 20))
      assert Enum.all?(handler_keys, &(&1 >= 20))
      assert MapSet.disjoint?(MapSet.new(declarative), MapSet.new(handler_keys))
    end

    test "S3: the declarative overflow key (20) equals call_key(0); the 20-line cap keeps them apart" do
      # StepWrites names its overflow failure {:line, 20, :build} (@max_lines = 20) and the first
      # handler call's call-level key is also 20. They never coexist because the engine caps the
      # COMBINED declarative + handler line count at 20 before any Multi is built (R4b).
      assert StepSource.call_key(0) == 20
      assert StepSource.declared_line_index(20) == 0
    end

    test "declared_line_index/1 maps a handler-range key back to the declared index" do
      for index <- [0, 1, 7, 19], ordinal <- [0, 1, 49] do
        assert StepSource.declared_line_index(StepSource.call_key(index) + ordinal) == index
      end

      assert StepSource.declared_line_index(3) == :declarative
    end

    test "the handler idempotency key stays in the closed charset and under 255 bytes" do
      assert {:ok, source} = StepSource.new(handler_attrs(%{line_index: 19, write_ordinal: 49}))
      key = StepSource.idempotency_key(source)
      assert key =~ ~r/\Asys:step:[A-Za-z0-9:_.-]+\z/
      assert byte_size(key) <= 255
    end

    test "handler and write_ordinal are both-or-neither, well formed, and closed" do
      invalid = [
        handler_attrs(%{write_ordinal: nil}),
        attrs(%{write_ordinal: 2}),
        handler_attrs(%{write_ordinal: 0}),
        handler_attrs(%{write_ordinal: 50}),
        handler_attrs(%{write_ordinal: "2"}),
        handler_attrs(%{write_ordinal: 1.0}),
        handler_attrs(%{handler: %{module_id: "fixture_ledger"}}),
        handler_attrs(%{
          handler: %{module_id: "fixture_ledger", name: "post_entry", targets: []}
        }),
        handler_attrs(%{handler: %{module_id: "Fixture", name: "post_entry"}}),
        handler_attrs(%{handler: %{module_id: "fixture_ledger", name: "9bad"}}),
        handler_attrs(%{handler: %{module_id: "fixture_ledger", name: ""}}),
        handler_attrs(%{
          handler: %{module_id: "fixture_ledger", name: String.duplicate("a", 65)}
        }),
        handler_attrs(%{handler: %{module_id: :fixture_ledger, name: "post_entry"}}),
        handler_attrs(%{handler: %{"module_id" => "fixture_ledger", "name" => "post_entry"}}),
        handler_attrs(%{handler: "fixture_ledger/post_entry"})
      ]

      for input <- invalid do
        assert StepSource.new(input) == {:error, :invalid_step_source}, inspect(input)
      end
    end
  end
end
