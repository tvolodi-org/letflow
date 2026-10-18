defmodule Letflow.Entities.ScopedWritesTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-ii (design `lib/letflow/design/req518-compiler-scope-filter.md`
  5.3, 5.4, 5.6; spec `test/specs/REQ-518-2c-ii.md`): the PURE rules of a scoped caller's write.

    * `ScopeResolver.record_scope/1` (the exported resolver of the route walk): `:tenant_wide`,
      `{:node, v}` only for a non-empty STRING under the declared column, `:unresolvable` for
      everything else, never raising on a malformed argument;
    * `ScopedWrites.check_new_value/3`: set membership of a string, never a node read, so
      a NULL, missing, numeric, nested, hostile, case-different or nonexistent value is the same
      `:refused`; `:none` refuses everything; `:all` and an `:unscoped` declaration allow;
    * `ScopedWrites.check_batch/3`: one bad entry in ANY position refuses the batch, an entry
      without `field_values` or a non-map entry is refused;
    * `ScopedWrites.type_gate/3` for the two sets that need no database.

  No database and no global state, so `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.ScopedWrites
  alias Letflow.Entities.ScopeResolver

  @column {:column, "scope_node"}
  @in_a {:nodes, ["sf-a", "sf-a1", "sf-a2x"]}

  describe "ScopeResolver.record_scope/1" do
    test "a :tenant_wide declaration is :tenant_wide whatever the values" do
      assert ScopeResolver.record_scope(%{declaration: :tenant_wide}) == :tenant_wide

      assert ScopeResolver.record_scope(%{declaration: :tenant_wide, field_values: %{"x" => 1}}) ==
               :tenant_wide
    end

    test "a column declaration resolves to {:node, v} only for a non-empty string" do
      assert ScopeResolver.record_scope(%{
               declaration: @column,
               field_values: %{"scope_node" => "sf-a"}
             }) == {:node, "sf-a"}

      for bad <- [nil, "", 5, 1.5, true, ["sf-a"], %{"id" => "sf-a"}, :sf_a] do
        assert ScopeResolver.record_scope(%{
                 declaration: @column,
                 field_values: %{"scope_node" => bad}
               }) == :unresolvable,
               inspect(bad)
      end

      assert ScopeResolver.record_scope(%{declaration: @column, field_values: %{}}) ==
               :unresolvable

      assert ScopeResolver.record_scope(%{
               declaration: @column,
               field_values: %{"other" => "sf-a"}
             }) == :unresolvable
    end

    test "the value of ANOTHER column is never read; atom keys are not string keys" do
      assert ScopeResolver.record_scope(%{
               declaration: {:column, "region"},
               field_values: %{"scope_node" => "sf-a"}
             }) == :unresolvable

      assert ScopeResolver.record_scope(%{
               declaration: @column,
               field_values: %{scope_node: "sf-a"}
             }) ==
               :unresolvable
    end

    test "an undeclared type and malformed arguments are :unresolvable and never raise" do
      for arg <- [
            %{declaration: :undeclared, field_values: %{"scope_node" => "sf-a"}},
            %{declaration: @column, field_values: "text"},
            %{declaration: @column, field_values: nil},
            %{declaration: {:column, 5}, field_values: %{}},
            %{declaration: @column},
            %{},
            nil,
            "x",
            [1]
          ] do
        assert ScopeResolver.record_scope(arg) == :unresolvable, inspect(arg)
      end
    end
  end

  describe "ScopedWrites.check_new_value/3" do
    test "a string in the set is :ok; every other value is :refused" do
      for node <- @in_a |> elem(1) do
        assert ScopedWrites.check_new_value(%{"scope_node" => node}, @column, @in_a) == :ok
      end

      for bad <- [
            "sf-b",
            "sf-root",
            "sf-a2",
            "sf-a3",
            "no-such-node",
            "SF-A",
            " sf-a",
            "sf-a ",
            "sf-a%",
            "sf-a\\",
            "sf-a' OR '1'='1",
            "",
            nil,
            5,
            ["sf-a"],
            %{"x" => "sf-a"}
          ] do
        assert ScopedWrites.check_new_value(%{"scope_node" => bad}, @column, @in_a) == :refused,
               inspect(bad)
      end

      assert ScopedWrites.check_new_value(%{}, @column, @in_a) == :refused
    end

    test "non-map field_values are :refused for a scoped set" do
      for fv <- [nil, 5, "x", ["sf-a"]] do
        assert ScopedWrites.check_new_value(fv, @column, @in_a) == :refused, inspect(fv)
      end
    end

    test ":tenant_wide and :undeclared declarations are refused for a scoped set, even with a node in it" do
      for declaration <- [:tenant_wide, :undeclared] do
        assert ScopedWrites.check_new_value(%{"scope_node" => "sf-a"}, declaration, @in_a) ==
                 :refused
      end
    end

    test ":none refuses everything, including a value that would be in any set" do
      assert ScopedWrites.check_new_value(%{"scope_node" => "sf-a"}, @column, :none) == :refused
      assert ScopedWrites.check_new_value(%{}, @column, :none) == :refused

      assert ScopedWrites.check_new_value(%{"scope_node" => "sf-a"}, :tenant_wide, :none) ==
               :refused
    end

    test ":all and an :unscoped declaration allow whatever the value" do
      for fv <- [%{}, %{"scope_node" => nil}, %{"scope_node" => "anything"}, nil, 5] do
        assert ScopedWrites.check_new_value(fv, @column, :all) == :ok
        assert ScopedWrites.check_new_value(fv, :tenant_wide, :all) == :ok
        assert ScopedWrites.check_new_value(fv, :unscoped, @in_a) == :ok
        assert ScopedWrites.check_new_value(fv, :unscoped, :all) == :ok
      end
    end

    test "an empty node list admits nothing" do
      assert ScopedWrites.check_new_value(%{"scope_node" => "sf-a"}, @column, {:nodes, []}) ==
               :refused
    end
  end

  describe "ScopedWrites.check_batch/3" do
    defp entry(node), do: %{"field_values" => %{"scope_node" => node}}

    test "an all-in-scope batch (and an empty one) is :ok" do
      assert ScopedWrites.check_batch(
               [entry("sf-a"), entry("sf-a1"), entry("sf-a2x")],
               @column,
               @in_a
             ) ==
               :ok

      assert ScopedWrites.check_batch([], @column, @in_a) == :ok
    end

    test "ONE bad entry in ANY position refuses the whole batch, whatever the reason" do
      bad = ["sf-b", nil, "", "sf-a3", "no-such-node", 5, ["sf-a"]]

      for value <- bad, position <- 0..2 do
        entries = List.insert_at([entry("sf-a"), entry("sf-a1")], position, entry(value))

        assert ScopedWrites.check_batch(entries, @column, @in_a) == :refused,
               "#{inspect(value)} @ #{position}"
      end
    end

    test "an entry without field_values, with non-map field_values, or that is not a map is refused" do
      for odd <- [
            %{"record_id" => "x"},
            %{"field_values" => 5},
            %{"field_values" => nil},
            "str",
            nil,
            7
          ] do
        assert ScopedWrites.check_batch([entry("sf-a"), odd], @column, @in_a) == :refused,
               inspect(odd)
      end
    end

    test "every entry is judged (no short-circuit on the first good one)" do
      assert ScopedWrites.check_batch(
               List.duplicate(entry("sf-a"), 199) ++ [entry("sf-b")],
               @column,
               @in_a
             ) == :refused
    end

    test ":none refuses even a good batch; :all and :unscoped allow even a bad one" do
      assert ScopedWrites.check_batch([entry("sf-a")], @column, :none) == :refused
      assert ScopedWrites.check_batch([entry(nil), "junk"], @column, :all) == :ok
      assert ScopedWrites.check_batch([entry(nil), "junk"], :unscoped, @in_a) == :ok
    end

    test ":tenant_wide and :undeclared declarations refuse any batch for a scoped set" do
      for declaration <- [:tenant_wide, :undeclared] do
        assert ScopedWrites.check_batch([entry("sf-a")], declaration, @in_a) == :refused
      end
    end
  end

  describe "ScopedWrites.type_gate/3 (the sets that need no database)" do
    test "scope :all is {:ok, :unscoped} for any type; :none is refused for any type" do
      assert ScopedWrites.type_gate("anything", :all, "tenant_x") == {:ok, :unscoped}
      assert ScopedWrites.type_gate("anything", :none, "tenant_x") == :refused
    end
  end
end
