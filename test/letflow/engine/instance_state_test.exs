defmodule Letflow.Engine.InstanceStateTest do
  @moduledoc """
  Struct-shape sanity tests for `Letflow.Engine.InstanceState` (REQ-044,
  design doc §2). `Letflow.Engine.Transition`'s own tests
  (`test/letflow/engine/transition_test.exs`) exercise every REQ-044
  acceptance criterion end to end using real `InstanceState` values; this
  file only locks in the struct's documented default values and its one
  enforced key, so a future accidental default change (e.g. `status: :active`
  silently becoming `nil`, or `tokens: []` becoming `nil`) fails here
  directly instead of showing up as a confusing, indirect failure deep inside
  a `Transition` test. See `test/specs/REQ-044.md`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Engine.InstanceState

  test "a freshly constructed InstanceState carries the documented defaults (design doc §2)" do
    state = %InstanceState{instance_id: "inst-1"}

    assert state.instance_id == "inst-1"
    assert state.status == :active
    assert state.tokens == []
    assert state.variables == %{}
    assert state.pending_task_nodes == []
  end

  test "instance_id is enforced -- constructing without it raises, rather than silently defaulting to nil" do
    assert_raise ArgumentError, fn ->
      struct!(InstanceState, %{})
    end
  end
end
