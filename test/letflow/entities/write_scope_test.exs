defmodule Letflow.Entities.WriteScopeTest do
  use ExUnit.Case, async: true

  alias Letflow.Entities.ImportAccess
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.WriteScope

  describe "Types.cast_scope_set/1" do
    test "accepts the three shapes and normalises an empty node list to :none" do
      assert {:ok, :all} = Types.cast_scope_set(:all)
      assert {:ok, :none} = Types.cast_scope_set(:none)
      assert {:ok, :none} = Types.cast_scope_set({:nodes, []})
      assert {:ok, {:nodes, ["a"]}} = Types.cast_scope_set({:nodes, ["a"]})
    end

    test "rejects malformed sets" do
      for bad <- [nil, :some, {:nodes, [1]}, {:nodes, "a"}, {:all, []}] do
        assert :error = Types.cast_scope_set(bad)
      end
    end
  end

  describe "WriteScope.new/2" do
    test "builds a validated struct" do
      assert %WriteScope{scope: {:nodes, ["n"]}, declaration: {:column, "branch_id"}} =
               WriteScope.new({:nodes, ["n"]}, {:column, "branch_id"})

      assert %WriteScope{scope: :all, declaration: :unscoped} = WriteScope.new(:all, :unscoped)
    end

    test "a malformed scope or declaration fails at the boundary" do
      assert_raise ArgumentError, fn -> WriteScope.new({:nodes, [1]}, :unscoped) end
      assert_raise ArgumentError, fn -> WriteScope.new(:all, {:column, 5}) end
      assert_raise ArgumentError, fn -> WriteScope.new(:all, :bogus) end
    end

    test "a half-built struct does not compile" do
      assert_raise ArgumentError, ~r/enforce_keys|keys must also be given/, fn ->
        Code.eval_string("%Letflow.Entities.WriteScope{scope: :all}")
      end
    end
  end

  describe "ImportAccess.new/2" do
    test "builds a validated struct" do
      assert %ImportAccess{access: :hidden, scope: :all} = ImportAccess.new(:hidden, :all)
      assert %ImportAccess{scope: :none} = ImportAccess.new({:open, MapSet.new()}, {:nodes, []})
    end

    test "malformed access or scope fails at the boundary" do
      assert_raise ArgumentError, fn -> ImportAccess.new(:open, :all) end
      assert_raise ArgumentError, fn -> ImportAccess.new(:hidden, {:nodes, [:x]}) end
    end
  end
end
