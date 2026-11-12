defmodule Letflow.Modules.KeyHelpersTest do
  @moduledoc "B16#4 canary: expected values taken from the old private copies in views.ex and posting.ex."
  use ExUnit.Case, async: true

  alias Letflow.Modules.KeyHelpers

  describe "pad/1" do
    test "a full 5-element list is returned unchanged" do
      assert KeyHelpers.pad(["a", "b", "c", "d", "e"]) == ["a", "b", "c", "d", "e"]
    end

    test "a shorter list is padded with nil on the right" do
      assert KeyHelpers.pad(["a", "b"]) == ["a", "b", nil, nil, nil]
      assert KeyHelpers.pad(["x"]) == ["x", nil, nil, nil, nil]
      assert KeyHelpers.pad([]) == [nil, nil, nil, nil, nil]
    end

    test "a list longer than 5 is truncated to 5" do
      assert KeyHelpers.pad(["a", "b", "c", "d", "e", "f"]) == ["a", "b", "c", "d", "e"]
    end
  end

  describe "empty_to_nil/1" do
    test "empty string becomes nil" do
      assert KeyHelpers.empty_to_nil("") == nil
    end

    test "non-empty string is kept" do
      assert KeyHelpers.empty_to_nil("loc") == "loc"
    end

    test "nil is kept" do
      assert KeyHelpers.empty_to_nil(nil) == nil
    end

    test "non-string values pass through unchanged" do
      assert KeyHelpers.empty_to_nil(42) == 42
      assert KeyHelpers.empty_to_nil(:atom) == :atom
    end
  end
end
