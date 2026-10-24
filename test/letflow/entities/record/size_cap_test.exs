defmodule Letflow.Entities.Record.SizeCapTest do
  @moduledoc """
  GH #2689 / REQ-514: the pure entity-side byte cap. Measure = `byte_size(Jason.encode!(term))`;
  boundaries are asserted in that unit (a string of N ASCII chars is N + 2 bytes).
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Record.SizeCap

  @value_max 65_536
  @record_max 262_144

  defp str(bytes), do: String.duplicate("x", bytes - 2)

  # A map of `n` filler values (each under the value cap) whose encoding is exactly `target` bytes.
  defp record_of_size(target) do
    filler = %{"a" => str(60_000), "b" => str(60_000), "c" => str(60_000), "d" => str(60_000)}
    base = byte_size(Jason.encode!(Map.put(filler, "e", "")))
    missing = target - base
    map = Map.put(filler, "e", String.duplicate("y", missing))
    assert byte_size(Jason.encode!(map)) == target
    map
  end

  test "U4 limits are pinned (a change is a reviewed diff)" do
    assert SizeCap.caps(:standard) == %{value_max_bytes: 65_536, record_max_bytes: 262_144}
    assert SizeCap.caps(:module) == %{value_max_bytes: 4_194_304, record_max_bytes: 5_242_880}
  end

  test "U1 a value encoding to exactly the cap is accepted, one byte over is refused" do
    at = str(@value_max)
    assert byte_size(Jason.encode!(at)) == @value_max
    assert :ok = SizeCap.check(%{"v" => at}, :standard)

    assert {:error, {:record_size_exceeded, :value}} =
             SizeCap.check(%{"v" => at <> "x"}, :standard)
  end

  test "U2 a record encoding to exactly the cap is accepted, one byte over is refused" do
    assert :ok = SizeCap.check(record_of_size(@record_max), :standard)

    assert {:error, {:record_size_exceeded, :record}} =
             SizeCap.check(record_of_size(@record_max + 1), :standard)
  end

  test "U3 multibyte, escaped and structured values are counted by encoded bytes" do
    # two-byte characters: 32_767 of them = 65_534 bytes + 2 quotes
    two = String.duplicate("é", 32_767)
    assert byte_size(Jason.encode!(two)) == @value_max
    assert :ok = SizeCap.check(%{"v" => two}, :standard)

    assert {:error, {:record_size_exceeded, :value}} =
             SizeCap.check(%{"v" => two <> "x"}, :standard)

    # a newline encodes to two bytes ("\n")
    esc = String.duplicate("\n", 32_767)
    assert byte_size(Jason.encode!(esc)) == @value_max
    assert :ok = SizeCap.check(%{"v" => esc}, :standard)

    assert {:error, {:record_size_exceeded, :value}} =
             SizeCap.check(%{"v" => esc <> "x"}, :standard)

    # a :json map / :localized_text value is measured as its encoding
    json = %{"k" => String.duplicate("z", @value_max)}
    assert {:error, {:record_size_exceeded, :value}} = SizeCap.check(%{"v" => json}, :standard)
    loc = %{"en" => String.duplicate("z", @value_max)}
    assert {:error, {:record_size_exceeded, :value}} = SizeCap.check(%{"v" => loc}, :standard)
  end

  test "a map over both caps reports the record" do
    big = %{"a" => str(@record_max + 10)}
    assert {:error, {:record_size_exceeded, :record}} = SizeCap.check(big, :standard)
  end

  test "U4 the module profile admits a snapshot-sized value, with its own boundary" do
    mib = String.duplicate("x", 1_048_576)
    assert :ok = SizeCap.check(%{"v" => mib}, :module)
    assert {:error, {:record_size_exceeded, _}} = SizeCap.check(%{"v" => mib}, :standard)

    max = String.duplicate("x", 4_194_304 - 2)
    assert :ok = SizeCap.check(%{"v" => max}, :module)

    assert {:error, {:record_size_exceeded, :value}} =
             SizeCap.check(%{"v" => max <> "x"}, :module)
  end

  test "a term Jason cannot encode is :record_not_encodable" do
    assert {:error, :record_not_encodable} = SizeCap.check(%{"v" => {:a, :tuple}}, :standard)
    assert {:error, :record_not_encodable} = SizeCap.check(%{"v" => self()}, :standard)
  end

  describe "stored oversize records (Item 4)" do
    test "U5 an unchanged oversize value is not measured, a small change is accepted" do
      over = str(@value_max + 100)
      stored = %{"big" => over, "n" => "a"}
      assert :ok = SizeCap.check(%{"big" => over, "n" => "b"}, :standard, stored)
    end

    test "U6 a changed oversize value is refused" do
      stored = %{"big" => str(@value_max + 100)}
      changed = %{"big" => str(@value_max + 200)}
      assert {:error, {:record_size_exceeded, :value}} = SizeCap.check(changed, :standard, stored)
    end

    test "U6b a stored record over the record cap lifts the record cap, not the value cap" do
      stored = record_of_size(@record_max + 1000)
      assert :ok = SizeCap.check(Map.put(stored, "a", "changed"), :standard, stored)
    end

    test "U6c a new oversize key on an oversize stored record is refused" do
      stored = record_of_size(@record_max + 1000)
      new = Map.put(stored, "fresh", str(@value_max + 1))
      assert {:error, {:record_size_exceeded, :value}} = SizeCap.check(new, :standard, stored)
    end

    test "a create (stored nil) gets the plain caps" do
      assert {:error, {:record_size_exceeded, :value}} =
               SizeCap.check(%{"v" => str(@value_max + 1)}, :standard, nil)
    end
  end
end
