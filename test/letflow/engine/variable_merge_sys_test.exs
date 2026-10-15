defmodule Letflow.Engine.VariableMergeSysTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A1 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  2.1, D-A1.1, D-A1.2, 11 A1 "`_sys.` refusal in `merge/3`"): the reserved namespace in
  `Letflow.Engine.VariableMerge` -- `merge/3`'s step-0 refusal, `reserved_key?/1`,
  `reserved_keys/1`, `drop_reserved/1`, `sys_key?/1`, `sys_value?/1` and `put_sys/3`. Pure.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore.Registry.ValidationFailure

  @current %{"a" => 1, "b" => "two"}

  defp opaque(value), do: Process.get({__MODULE__, :never_set}, value)

  describe "merge/3 refuses a reserved top-level key" do
    test "bare \"_sys\" with a map value: rejected, value never carried, current unchanged even when other keys are valid" do
      incoming = %{"_sys" => %{"r" => "x"}, "c" => 3, "a" => 9}

      assert VariableMerge.merge(@current, incoming, nil) ==
               {:rejected, @current,
                [{:execution_error, "_sys", nil, :reserved_variable_key, []}]}
    end

    test "\"_sys.x\": same shape" do
      assert VariableMerge.merge(@current, %{"_sys.x" => 1}, %{}) ==
               {:rejected, @current,
                [{:execution_error, "_sys.x", nil, :reserved_variable_key, []}]}
    end

    test "the first reserved key in sorted order is reported" do
      incoming = %{"_sys.z" => 1, "_sys.b" => 2, "_sys" => 3}

      assert {:rejected, @current, [{:execution_error, "_sys", nil, :reserved_variable_key, []}]} =
               VariableMerge.merge(@current, incoming, nil)
    end

    test "an atom key :\"_sys.x\" is refused (string form compared)" do
      assert VariableMerge.merge(@current, %{:"_sys.x" => 1}, nil) ==
               {:rejected, @current,
                [{:execution_error, "_sys.x", nil, :reserved_variable_key, []}]}
    end

    test "a NESTED reserved key is not reserved: merged normally" do
      assert {:ok, merged, []} = VariableMerge.merge(@current, %{"c" => %{"_sys.x" => 1}}, nil)
      assert merged == Map.put(@current, "c", %{"_sys.x" => 1})
    end

    test "near-misses are ordinary keys: \"_system\", \"sys.x\", \"x_sys.y\", \"_SYS.x\"" do
      incoming = %{"_system" => 1, "sys.x" => 2, "x_sys.y" => 3, "_SYS.x" => 4}
      assert {:ok, merged, []} = VariableMerge.merge(%{}, incoming, nil)
      assert merged == incoming
    end

    test "the reserved check precedes a {:rejected, _} validation outcome for an earlier-sorted key" do
      failure = %ValidationFailure{field_path: "/", constraint: "type", actual: 1}
      validations = %{"A_first" => {:rejected, [failure]}}

      assert {:rejected, @current,
              [{:execution_error, "_sys.x", nil, :reserved_variable_key, []}]} =
               VariableMerge.merge(@current, %{"A_first" => 1, "_sys.x" => 2}, validations)
    end

    test "ordinary keys keep today's behaviour (insert + overwrite event; schema rejection shape)" do
      assert {:ok, %{"a" => 2, "b" => "two", "c" => 3}, [{:variable_overwritten, "a", 1, 2}]} =
               VariableMerge.merge(@current, %{"a" => 2, "c" => 3}, nil)

      failure = %ValidationFailure{field_path: "/", constraint: "type", actual: 2}

      assert {:rejected, @current,
              [{:execution_error, "a", 2, :variable_schema_rejected, [^failure]}]} =
               VariableMerge.merge(@current, %{"a" => 2}, %{"a" => {:rejected, [failure]}})
    end

    test "deterministic: two calls with equal arguments return equal results" do
      incoming = %{"_sys.b" => 1, "_sys.a" => 2, "x" => 3}

      assert VariableMerge.merge(@current, incoming, nil) ==
               VariableMerge.merge(@current, incoming, nil)
    end
  end

  describe "reserved_key?/1, reserved_keys/1, drop_reserved/1" do
    test "reserved_key?/1" do
      assert VariableMerge.reserved_key?("_sys")
      assert VariableMerge.reserved_key?("_sys.")
      assert VariableMerge.reserved_key?("_sys.r.seq")
      assert VariableMerge.reserved_key?(:_sys)
      assert VariableMerge.reserved_key?(:"_sys.x")
      refute VariableMerge.reserved_key?("_system")
      refute VariableMerge.reserved_key?("x")
      refute VariableMerge.reserved_key?(1)
      refute VariableMerge.reserved_key?({:_sys})
      refute VariableMerge.reserved_key?(nil)
    end

    test "reserved_keys/1 returns top-level reserved keys as sorted strings" do
      vars = %{"_sys.b" => 1, :"_sys.a" => 2, "_sys" => 3, "x" => %{"_sys.n" => 1}}
      assert VariableMerge.reserved_keys(vars) == ["_sys", "_sys.a", "_sys.b"]
      assert VariableMerge.reserved_keys(%{"x" => 1}) == []
      assert VariableMerge.reserved_keys(%{}) == []
    end

    test "drop_reserved/1 strips top-level reserved keys only" do
      vars = %{"_sys.b" => 1, :"_sys.a" => 2, "_sys" => 3, "x" => %{"_sys.n" => 1}, "y" => 2}
      assert VariableMerge.drop_reserved(vars) == %{"x" => %{"_sys.n" => 1}, "y" => 2}
      assert VariableMerge.drop_reserved(%{}) == %{}
    end
  end

  describe "sys_key?/1 and sys_value?/1 (CDV R1)" do
    test "sys_key?/1" do
      refute VariableMerge.sys_key?("_sys")
      refute VariableMerge.sys_key?("x")
      assert VariableMerge.sys_key?("_sys.r.seq")
      assert VariableMerge.sys_key?("_sys.r")
      assert VariableMerge.sys_key?("_sys.line_0.id")
      refute VariableMerge.sys_key?("_sys.")
      refute VariableMerge.sys_key?("_sys.r.")
      refute VariableMerge.sys_key?("_sys..r")
      refute VariableMerge.sys_key?("_sys.r-x")
      refute VariableMerge.sys_key?("_sys.r\n")
      refute VariableMerge.sys_key?(:"_sys.r")
      refute VariableMerge.sys_key?(%{})
      refute VariableMerge.sys_key?(nil)

      at_limit = "_sys." <> String.duplicate("a", 155)
      assert byte_size(at_limit) == 160
      assert VariableMerge.sys_key?(at_limit)
      refute VariableMerge.sys_key?(at_limit <> "a")
    end

    test "sys_value?/1" do
      refute VariableMerge.sys_value?(%{})
      refute VariableMerge.sys_value?(-1)
      refute VariableMerge.sys_value?(1.5)
      refute VariableMerge.sys_value?(nil)
      refute VariableMerge.sys_value?([1])
      assert VariableMerge.sys_value?(0)
      assert VariableMerge.sys_value?(7)
      assert VariableMerge.sys_value?(Ecto.UUID.generate())
    end
  end

  describe "put_sys/3" do
    test "sets a sys_key to a sys_value (GH #2621: tuple contract)" do
      id = Ecto.UUID.generate()

      assert {:ok, step} = VariableMerge.put_sys(%{"a" => 1}, "_sys.r", id)

      assert {:ok, %{"a" => 1, "_sys.r" => ^id, "_sys.r.seq" => 7}} =
               VariableMerge.put_sys(step, "_sys.r.seq", 7)
    end

    test "returns {:error, code} (no raise) on \"_sys\", \"x\", a value %{} and -1" do
      assert {:error, :invalid_sys_key_shape} = VariableMerge.put_sys(%{}, "_sys", 1)
      assert {:error, :invalid_sys_key_shape} = VariableMerge.put_sys(%{}, "x", 1)
      assert {:error, :invalid_sys_value_type} = VariableMerge.put_sys(%{}, "_sys.r", opaque(%{}))
      assert {:error, :invalid_sys_value_type} = VariableMerge.put_sys(%{}, "_sys.r.seq", -1)
    end

    test "a non-map first argument is {:error, _} for put_sys/3 and put_sys_replayed/3" do
      assert {:error, :invalid_variables} = VariableMerge.put_sys(opaque(nil), "x", 1)
      assert {:error, :invalid_variables} = VariableMerge.put_sys(opaque([]), "_sys.r", 1)

      assert {:error, :invalid_variables} =
               VariableMerge.put_sys_replayed(opaque(nil), "x", 1)
    end

    test "put_sys_replayed/3 keeps the stored-tier wide rule" do
      assert {:ok, %{"_sys.line_0.id" => "any string"}} =
               VariableMerge.put_sys_replayed(%{}, "_sys.line_0.id", "any string")

      assert {:ok, %{"_sys.r" => 3}} = VariableMerge.put_sys_replayed(%{}, "_sys.r", 3)

      assert {:error, :invalid_sys_key_shape} = VariableMerge.put_sys_replayed(%{}, "x", 1)

      assert {:error, :invalid_sys_value_type} =
               VariableMerge.put_sys_replayed(%{}, "_sys.r", opaque(%{}))

      assert {:error, :invalid_sys_value_type} = VariableMerge.put_sys_replayed(%{}, "_sys.r", -1)
    end

    test "sys_event_type/0" do
      assert VariableMerge.sys_event_type() == "INSTANCE_SYS_VARIABLES_SET"
    end
  end
end
