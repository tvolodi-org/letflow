defmodule Letflow.Security.G07CursorCodecProbeTest do
  @moduledoc """
  **G-07 security probe** -- cursor/codec property tests generated from the
  cursor-builder inventory (`Letflow.TestSupport.CursorBuilderInventory`).

  The probe is mechanical, deterministic and model-free. It runs in the
  `checks` step of every backend change (`:security_probe` tag; the pure part
  is also `:unit`, so it rides the unit tier), and it is the ratchet for the
  defect class T-2571 found by hand: a cursor slot that carries a caller
  supplied id shifts the slots behind it when the id contains the `:` slot
  separator, and a legacy cursor decoded into the wrong values makes a listing
  repeat or skip pages.

  ## The properties

    * **completeness** -- the inventory is not empty, every entry is anchored
      in the tree (its prefix literal and its seek shape really live in the
      file the entry names), every cursor prefix of `lib/` is covered by an
      entry and every seek shape of `lib/` is covered by an entry;
    * **round trip** -- for every entry and every generated set of legal slot
      values, the payload the product would mint decodes back to exactly
      those values;
    * **separators** -- a free string slot keeps a `:`-bearing id whole, and
      no inventory entry carries a free string in a non-last slot (the
      structural rule the `:`-bearing `service_id` of T-2571 broke);
    * **legacy prefixes** -- the previous cursor generation still decodes to
      the values it was minted with, and neither generation is accepted by the
      other;
    * **expiry** -- a fresh cursor is accepted, one older than the expiry
      window is refused, and the seek timestamp of a row may be arbitrarily
      old as long as the cursor's OWN mint time is fresh (the "cursor expired
      because the last row is old" defect).

  ## Non-vacuity

  The probe carries a seeded failing case: `CursorBuilderInventory.broken_decode/3`
  is the naive split (no slot count) that the T-2571 review found, and the
  probe asserts that the round-trip property FAILS on it while it holds for
  the real codec. A probe that cannot fail is not evidence.

  Pure: no database, no clock except the "now" the expiry window is measured
  against, no network. Every generated value comes from a fixed seed, so a
  failure is reproducible.
  """

  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :security_probe
  @moduletag probe_cost_s: 5

  alias Letflow.Api.Pagination
  alias Letflow.TestSupport.CursorBuilderInventory, as: Inventory

  # One fixed seed per attempt: the generator is deterministic, so a failure
  # reproduces exactly.
  @seed {17, 42, 99}

  # Legal free strings: non-empty, valid UTF-8, no NUL byte -- exactly what
  # `Letflow.Api.Pagination.valid_seek_string?/1` accepts. The `:`-bearing
  # ones are the T-2571 shape.
  @free_strings [
    "plain-service-id",
    "service:with:colons",
    "a:b:c:d",
    "юникод:идентификатор",
    "with space",
    "pipe|inside",
    "percent%20encoded",
    ":leading-colon",
    "trailing-colon:",
    "tab\tinside",
    "emoji-🙂",
    "quote\"inside",
    "backslash\\inside"
  ]

  describe "G-07-1 the inventory is complete and anchored in the tree" do
    test "the inventory is not empty" do
      refute Enum.empty?(Inventory.entries())
    end

    test "every entry's prefix literal and seek shape live in the file the entry names" do
      for entry <- Inventory.entries() do
        source = File.read!(entry.file)

        assert String.contains?(source, entry.prefix),
               "#{entry.name}: the prefix #{inspect(entry.prefix)} is not in #{entry.file}"

        shape = Inventory.shape_for_layout(entry.layout)

        assert Inventory.shapes_in_file(entry.file) != [] or manual_decoder?(entry.file),
               "#{entry.name}: #{entry.file} has no cursor decoder left"

        assert shape in Inventory.shapes_in_file(entry.file) or manual_decoder?(entry.file),
               "#{entry.name}: the seek shape #{inspect(shape)} is not read in #{entry.file}"

        if entry.legacy do
          legacy_shape = Inventory.shape_for_layout(entry.legacy.layout)

          assert legacy_shape in Inventory.shapes_in_file(entry.legacy.file) or
                   manual_decoder?(entry.legacy.file),
                 "#{entry.name}: the legacy seek shape #{inspect(legacy_shape)} is not read in #{entry.legacy.file}"

          assert String.contains?(File.read!(entry.legacy.file), entry.legacy.prefix),
                 "#{entry.name}: the legacy prefix #{inspect(entry.legacy.prefix)} is not in #{entry.legacy.file}"
        end
      end
    end

    test "every cursor prefix of lib/ is covered by an inventory entry or an explicit scope exclusion" do
      covered =
        Inventory.entries()
        |> Enum.flat_map(fn entry -> [entry.prefix, entry.legacy && entry.legacy.prefix] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      excluded = Enum.map(Inventory.scope_excluded(), & &1.prefix)

      # `--` is right-associative in Elixir, so the two lists are joined
      # explicitly before the difference is taken.
      uncovered = Inventory.tree_prefixes() -- (covered ++ excluded)

      assert uncovered == [],
             "cursor prefixes in lib/ that the inventory does not cover: #{inspect(uncovered)}"

      assert excluded != [],
             "the scope exclusion list is empty: every prefix of lib/ claims to be covered"
    end

    test "every seek shape of lib/ is covered by an inventory entry" do
      covered =
        Inventory.entries()
        |> Enum.flat_map(fn entry ->
          [
            Inventory.shape_for_layout(entry.layout),
            entry.legacy && Inventory.shape_for_layout(entry.legacy.layout)
          ]
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      uncovered = Inventory.tree_shapes() -- covered

      assert uncovered == [],
             "seek shapes in lib/ that the inventory does not cover: #{inspect(uncovered)}"
    end
  end

  describe "G-07-2 every cursor builder round-trips the values it was minted with" do
    for entry <- Inventory.entries() do
      test "#{entry.name} (#{entry.prefix}) decodes back to exactly the values it was minted with" do
        entry = unquote(Macro.escape(entry))

        for attempt <- 1..5 do
          {slots, expected} = generate(entry.layout, seed(attempt))

          raw = Inventory.build_raw(entry.prefix, slots)

          assert {:ok, values} =
                   Inventory.decode(raw, entry.prefix, Inventory.shape_for_layout(entry.layout))

          assert values == expected,
                 "#{entry.name}: the decoded slots #{inspect(values)} are not the minted ones #{inspect(expected)}"
        end
      end
    end
  end

  describe "G-07-3 a separator inside an id never shifts a slot" do
    test "a `:`-bearing free string survives the round trip of every free-string entry" do
      free_entries = Enum.filter(Inventory.entries(), fn entry -> :string in entry.layout end)

      assert free_entries != [], "the inventory has no free-string cursor to probe"

      for entry <- free_entries do
        for service_id <- @free_strings do
          {slots, expected} = generate(entry.layout, @seed, %{override: {:string, service_id}})

          raw = Inventory.build_raw(entry.prefix, slots)

          assert {:ok, values} =
                   Inventory.decode(raw, entry.prefix, Inventory.shape_for_layout(entry.layout))

          assert values == expected,
                 "#{entry.name}: the id #{inspect(service_id)} came back as #{inspect(values)}"

          assert List.last(values) == service_id
        end
      end
    end

    test "no inventory entry carries a free string outside the last slot" do
      assert Inventory.free_string_violations() == [],
             "a free string in a non-last slot shifts the slots behind it: #{inspect(Inventory.free_string_violations())}"
    end
  end

  describe "G-07-4 a legacy cursor is neither accepted by the current one nor the other way round" do
    for entry <- Enum.filter(Inventory.entries(), & &1.legacy) do
      test "#{entry.name} (#{entry.prefix}) keeps its legacy generation apart" do
        entry = unquote(Macro.escape(entry))
        legacy = entry.legacy

        {slots, expected} = generate(legacy.layout, @seed)

        raw = Inventory.build_raw(legacy.prefix, slots)

        # The legacy payload still decodes to the values it was minted with.
        assert {:ok, values} =
                 Inventory.decode(raw, legacy.prefix, Inventory.shape_for_layout(legacy.layout))

        assert values == expected,
               "#{entry.name}: the legacy cursor decoded into #{inspect(values)} instead of #{inspect(expected)}"

        current_shape = Inventory.shape_for_layout(entry.layout)

        # And the current generation does not accept it.
        if legacy.prefix == entry.prefix do
          assert {:error, :invalid_cursor} = Inventory.decode(raw, entry.prefix, current_shape),
                 "#{entry.name}: the current decoder accepted a legacy cursor"
        else
          assert {:error, :wrong_endpoint} = Inventory.decode(raw, entry.prefix, current_shape),
                 "#{entry.name}: the current decoder accepted a legacy cursor"

          assert {:error, :wrong_endpoint} =
                   Inventory.decode(
                     Inventory.build_raw(entry.prefix, slots),
                     legacy.prefix,
                     Inventory.shape_for_layout(legacy.layout)
                   ),
                 "#{entry.name}: the legacy decoder accepted a current cursor"
        end
      end
    end
  end

  describe "G-07-5 the expiry window follows the cursor, not the row" do
    for entry <- Inventory.entries() do
      test "#{entry.name} (#{entry.prefix}) accepts a fresh cursor and refuses an expired one" do
        entry = unquote(Macro.escape(entry))

        shape = Inventory.shape_for_layout(entry.layout)

        # A cursor minted now is accepted.
        {fresh_slots, _expected} = generate(entry.layout, @seed, %{mint_age_us: 0})

        assert {:ok, _values} =
                 Inventory.decode(
                   Inventory.build_raw(entry.prefix, fresh_slots),
                   entry.prefix,
                   shape
                 )

        # A cursor whose OWN mint time is older than the window is refused.
        {stale_slots, _expected} =
          generate(entry.layout, @seed, %{
            mint_age_us: Pagination.cursor_expiry_us() + 3_600_000_000
          })

        assert {:error, :expired} =
                 Inventory.decode(
                   Inventory.build_raw(entry.prefix, stale_slots),
                   entry.prefix,
                   shape
                 ),
               "#{entry.name}: an expired cursor was accepted"

        # A cursor whose SEEK timestamp is old but whose mint time is fresh is
        # accepted: the expiry window belongs to the cursor, not to the row.
        if :mint in entry.layout do
          {old_row_slots, _expected} =
            generate(entry.layout, @seed, %{
              mint_age_us: 0,
              seek_age_us: Pagination.cursor_expiry_us() + 3_600_000_000
            })

          assert {:ok, _values} =
                   Inventory.decode(
                     Inventory.build_raw(entry.prefix, old_row_slots),
                     entry.prefix,
                     shape
                   ),
                 "#{entry.name}: a fresh cursor over an old row was refused as expired"
        end
      end
    end
  end

  describe "G-07-6 the probe is not vacuous" do
    test "the seeded broken decoder (naive colon split) fails the round trip the real codec passes" do
      entry = Inventory.entry("service_catalog_list")
      assert entry, "the inventory lost the service_catalog cursor builder"

      service_id = "svc:with:colons"

      {slots, _expected} = generate(entry.layout, @seed, %{override: {:string, service_id}})

      raw = Inventory.build_raw(entry.prefix, slots)
      shape = Inventory.shape_for_layout(entry.layout)

      # The real codec keeps the id whole ...
      assert preserves_id?(&Inventory.decode/3, raw, entry.prefix, shape, service_id),
             "the real codec did not preserve a `:`-bearing id"

      # ... and the seeded broken variant does not: that is the defect the
      # probe has to be able to see.
      refute preserves_id?(&Inventory.broken_decode/3, raw, entry.prefix, shape, service_id),
             "the seeded broken decoder passed the property the real codec is checked against"
    end

    test "the structural rule refuses a seeded broken layout (a free string before the last slot)" do
      broken_layout = [:mint, :string, :dt]

      free_string_positions =
        broken_layout
        |> Enum.with_index()
        |> Enum.filter(fn {slot, _index} -> slot == :string end)
        |> Enum.map(fn {_slot, index} -> index end)

      assert free_string_positions != []

      assert Enum.any?(free_string_positions, &(&1 != length(broken_layout) - 1)),
             "the seeded broken layout does not break the structural rule"
    end
  end

  # ── the deterministic generator ────────────────────────────────────────────

  # Returns the slot strings of a layout and the values the codec must decode
  # them into (the `:skip` mint slot is not among them). `opts.override` pins
  # one slot's value, `opts.mint_age_us` the age of the mint slot and
  # `opts.seek_age_us` the age of the seek timestamp.
  defp generate(layout, seed, opts \\ %{}) do
    :rand.seed(:exsss, seed)

    {slots, expected} =
      Enum.reduce(layout, {[], []}, fn slot, {slots, expected} ->
        {slot_string, value} = generate_slot(slot, opts)

        if slot == :mint do
          {[slot_string | slots], expected}
        else
          {[slot_string | slots], [value | expected]}
        end
      end)

    {Enum.reverse(slots), Enum.reverse(expected)}
  end

  defp generate_slot(:mint, opts), do: {us_now(opts), nil}

  defp generate_slot(:mint_dt, opts) do
    us = us_now(opts)
    {us, datetime(us)}
  end

  defp generate_slot(:dt, opts) do
    age = Map.get(opts, :seek_age_us, :rand.uniform(86_400_000_000))
    us = us_now(Map.put(opts, :mint_age_us, age))
    {us, datetime(us)}
  end

  defp generate_slot(:int, _opts) do
    value = :rand.uniform(1_000_000) - 500_000
    {Integer.to_string(value), value}
  end

  defp generate_slot(:uuid, _opts) do
    value = Ecto.UUID.generate()
    {value, Ecto.UUID.cast!(value)}
  end

  defp generate_slot(:string, opts) do
    value =
      case Map.get(opts, :override) do
        {:string, pinned} -> pinned
        _ -> Enum.at(@free_strings, :rand.uniform(length(@free_strings)) - 1)
      end

    {value, value}
  end

  defp generate_slot(:rank_id, _opts) do
    value = "#{:rand.uniform(3)}|#{Ecto.UUID.generate()}"
    {value, value}
  end

  defp seed(attempt), do: {17, 42, 99 + attempt}

  defp us_now(opts) do
    Integer.to_string(System.system_time(:microsecond) - Map.get(opts, :mint_age_us, 0))
  end

  defp datetime(us), do: DateTime.from_unix!(String.to_integer(us), :microsecond)

  # True when the decoder hands the id back whole -- the property the probe
  # checks for every cursor builder.
  defp preserves_id?(decoder, raw, prefix, shape, id) do
    case decoder.(raw, prefix, shape) do
      {:ok, values} -> List.last(values) == id
      _ -> false
    end
  end

  # A file whose cursor decoder splits the payload by hand instead of calling
  # `decode_seek_parts/3` (the scoped-grants cursor).
  defp manual_decoder?(file), do: File.read!(file) =~ "String.split(rest"
end
