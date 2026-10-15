defmodule Letflow.Engine.VariableMergeSysTypesTest do
  @moduledoc """
  GH #2621 (design `lib/letflow/design/gh2621-sys-value-types.md` D-5..D-7, D-10): the STRICT
  tier of the reserved `_sys` namespace, `sys_key_kind/1`, `check_sys_entry/2`,
  `check_sys_values/1` and the tuple-returning `put_sys/3`. Pure.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Letflow.Engine.VariableMerge

  @uuid "0b6f3b0e-4a47-4d4e-9d5c-3f2a8b1c7e55"
  @int64_max 9_223_372_036_854_775_807

  # Keeps the compile-time type checker quiet for deliberately off-spec terms.
  defp opaque(value), do: Process.get({__MODULE__, :never_set}, value)

  describe "check_sys_entry/2 value types" do
    test "a canonical lowercase UUID passes under an id key" do
      assert :ok = VariableMerge.check_sys_entry("_sys.r", @uuid)
    end

    test "a non-UUID, uppercase, unhyphenated, integer and map value is refused under an id key" do
      for bad <- [
            "not-a-uuid",
            String.upcase(@uuid),
            String.replace(@uuid, "-", ""),
            @uuid <> "\n",
            7,
            %{},
            nil
          ] do
        assert {:error, :invalid_sys_value_type} =
                 VariableMerge.check_sys_entry("_sys.r", opaque(bad)),
               "accepted: #{inspect(bad)}"
      end
    end

    test "a seq key holds an integer in 0..int64 max" do
      assert :ok = VariableMerge.check_sys_entry("_sys.r.seq", 0)
      assert :ok = VariableMerge.check_sys_entry("_sys.r.seq", @int64_max)
    end

    test "a seq key refuses negative, float, string, boolean, nil, map, list, > int64" do
      for bad <- [-1, 7.0, "7", true, nil, %{}, [1], @int64_max + 1] do
        assert {:error, :invalid_sys_value_type} =
                 VariableMerge.check_sys_entry("_sys.r.seq", opaque(bad)),
               "accepted: #{inspect(bad)}"
      end
    end
  end

  describe "key shapes" do
    test "unknown shapes are :invalid_sys_key_shape" do
      long = "_sys." <> String.duplicate("a", 156)
      assert byte_size(long) == 161

      for bad <- [
            "_sys",
            "_sys.",
            "_sys.a.b",
            "_sys.a.seq.seq",
            "_sys.a-b",
            "_sys.a\n",
            :"_sys.a",
            long,
            "x",
            nil,
            %{}
          ] do
        assert {:error, :invalid_sys_key_shape} =
                 VariableMerge.check_sys_entry(opaque(bad), 1),
               "accepted: #{inspect(bad)}"

        assert :unknown = VariableMerge.sys_key_kind(opaque(bad))
      end
    end

    test "the 160-byte limit is inclusive, for the id key and for its seq key" do
      id_160 = "_sys." <> String.duplicate("a", 155)
      assert byte_size(id_160) == 160
      assert :id = VariableMerge.sys_key_kind(id_160)
      assert :unknown = VariableMerge.sys_key_kind(id_160 <> "a")
      assert :unknown = VariableMerge.sys_key_kind(id_160 <> ".seq")
      seq_160 = "_sys." <> String.duplicate("a", 151) <> ".seq"
      assert byte_size(seq_160) == 160
      assert :seq = VariableMerge.sys_key_kind(seq_160)
    end

    test "a variable named seq: _sys.seq is its id, _sys.seq.seq its seq" do
      assert :id = VariableMerge.sys_key_kind("_sys.seq")
      assert :seq = VariableMerge.sys_key_kind("_sys.seq.seq")
      assert :ok = VariableMerge.check_sys_entry("_sys.seq", @uuid)
      assert :ok = VariableMerge.check_sys_entry("_sys.seq.seq", 1)
    end
  end

  describe "check_sys_values/1" do
    test "a valid map is :ok; a non-map is :not_a_map" do
      assert :ok = VariableMerge.check_sys_values(%{"_sys.r" => @uuid, "_sys.r.seq" => 7})
      assert :ok = VariableMerge.check_sys_values(%{})
      assert {:error, :not_a_map} = VariableMerge.check_sys_values(opaque([1]))
    end

    test "offending pairs come back sorted by key" do
      assert {:error, [{"_sys.a", :invalid_sys_value_type}, {"zzz", :invalid_sys_key_shape}]} =
               VariableMerge.check_sys_values(%{"zzz" => 1, "_sys.a" => "no", "_sys.b" => @uuid})
    end

    test "exactly 40 keys (20 id/seq pairs) is accepted" do
      values =
        Enum.reduce(0..19, %{}, fn i, acc ->
          acc |> Map.put("_sys.l#{i}", @uuid) |> Map.put("_sys.l#{i}.seq", i)
        end)

      assert map_size(values) == 40
      assert :ok = VariableMerge.check_sys_values(values)
    end

    test "41 keys: only the single count failure, the per-pair pass is skipped" do
      # 41 keys, every one of them also individually invalid.
      values = Map.new(0..40, fn i -> {"bad#{i}", -1} end)
      assert map_size(values) == 41

      assert {:error, [{:values, :too_many_keys}]} = VariableMerge.check_sys_values(values)
    end
  end

  describe "put_sys/3" do
    test "{:ok, map} on a valid pair; the input map is untouched" do
      input = %{"a" => 1}

      assert {:ok, %{"a" => 1, "_sys.r" => @uuid}} =
               VariableMerge.put_sys(input, "_sys.r", @uuid)

      assert input == %{"a" => 1}
    end

    test "{:error, code} and no raise on each bad input" do
      assert {:error, :invalid_sys_key_shape} = VariableMerge.put_sys(%{}, "x", @uuid)
      assert {:error, :invalid_sys_key_shape} = VariableMerge.put_sys(%{}, "_sys.a.b", @uuid)
      assert {:error, :invalid_sys_value_type} = VariableMerge.put_sys(%{}, "_sys.r", "nope")
      assert {:error, :invalid_sys_value_type} = VariableMerge.put_sys(%{}, "_sys.r.seq", -1)
      assert {:error, :invalid_sys_value_type} = VariableMerge.put_sys(%{}, "_sys.r.seq", 7.0)
    end
  end

  describe "properties" do
    test "check_sys_entry/2 and put_sys/3 never raise; ok iff a known shape with its type" do
      check all(
              key <-
                StreamData.one_of([
                  StreamData.string(:printable, max_length: 20),
                  StreamData.member_of(["_sys.r", "_sys.r.seq", "_sys", "_sys.a.b"]),
                  StreamData.atom(:alphanumeric),
                  StreamData.integer()
                ]),
              value <-
                StreamData.one_of([
                  StreamData.string(:printable, max_length: 40),
                  StreamData.member_of([@uuid, String.upcase(@uuid)]),
                  StreamData.integer(),
                  StreamData.member_of([0.0, 7.0, -1.5]),
                  StreamData.boolean(),
                  StreamData.constant(nil),
                  StreamData.constant(%{})
                ])
            ) do
        expected_ok? =
          case VariableMerge.sys_key_kind(key) do
            :id -> is_binary(value) and value == @uuid
            :seq -> is_integer(value) and value >= 0 and value <= @int64_max
            :unknown -> false
          end

        assert VariableMerge.check_sys_entry(key, value) == :ok == expected_ok?
        assert match?({:ok, _}, VariableMerge.put_sys(%{}, key, value)) == expected_ok?
      end
    end
  end
end
