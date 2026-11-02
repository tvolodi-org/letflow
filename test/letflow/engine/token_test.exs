defmodule Letflow.Engine.TokenTest do
  @moduledoc """
  Struct-shape sanity tests for `Letflow.Engine.Token` (REQ-044, design doc
  §3). Complements `test/letflow/engine/transition_test.exs`, which exercises
  every REQ-044 acceptance criterion against real `Token` values built via
  this same struct. See `test/specs/REQ-044.md`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Engine.Token

  test "a freshly constructed Token carries the documented defaults (design doc §3)" do
    token = %Token{node_id: "n1", token_id: "t1"}

    assert token.node_id == "n1"
    assert token.token_id == "t1"
    assert token.branch_id == nil
    assert token.waiting_child_instance_id == nil
  end

  test "node_id and token_id are both enforced -- constructing without either raises, rather than silently defaulting to nil" do
    assert_raise ArgumentError, fn -> struct!(Token, %{token_id: "t1"}) end
    assert_raise ArgumentError, fn -> struct!(Token, %{node_id: "n1"}) end
  end
end
