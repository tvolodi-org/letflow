defmodule Letflow.Engine.LuaNumberMarshallingTest do
  @moduledoc """
  Tests for `Letflow.Engine.LuaNumberMarshalling` (REQ-150 §3, built by REQ-159). See
  `test/specs/REQ-159.md` §1 for the full test-case rationale.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Engine.LuaNumberMarshalling

  describe "to_lua/1" do
    test "returns an integer unchanged" do
      assert LuaNumberMarshalling.to_lua(3) === 3
    end

    test "returns a float unchanged, including a whole-number float -- still is_float/1" do
      result = LuaNumberMarshalling.to_lua(3.0)

      assert result === 3.0
      assert is_float(result)
    end

    test "returns nil unchanged" do
      assert LuaNumberMarshalling.to_lua(nil) == nil
    end

    test "returns a non-numeric, non-nil value unchanged" do
      assert LuaNumberMarshalling.to_lua("a string") == "a string"
      assert LuaNumberMarshalling.to_lua(true) == true
      assert LuaNumberMarshalling.to_lua(%{"a" => 1}) == %{"a" => 1}
    end
  end

  describe "from_lua/1" do
    test "returns an integer unchanged" do
      assert LuaNumberMarshalling.from_lua(3) === 3
    end

    test "returns a whole-number float unchanged -- still is_float/1" do
      result = LuaNumberMarshalling.from_lua(3.0)

      assert result === 3.0
      assert is_float(result)
    end

    test "returns nil unchanged" do
      assert LuaNumberMarshalling.from_lua(nil) == nil
    end

    test "returns a non-numeric, non-nil value unchanged" do
      assert LuaNumberMarshalling.from_lua("a string") == "a string"
      assert LuaNumberMarshalling.from_lua(false) == false
      assert LuaNumberMarshalling.from_lua([1, 2, 3]) == [1, 2, 3]
    end
  end
end
