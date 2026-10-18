defmodule Letflow.TestSupport.CursorForgery do
  @moduledoc """
  Forges keyset cursors that are valid everywhere except one slot (GH #2747).

  A cursor is `Base.url_encode64(prefix <> slot <> ":" <> slot ...)`. A *layout* lists the
  slot types after the prefix, the FIRST slot being the mint time `decode_cursor/4` reads for
  expiry (`:mint` when a seek decoder skips it, `:mint_dt` when the same slot is also the
  sort key). The other types are `:dt` (unix microseconds), `:int`, `:uuid`, `:string`
  and `:rank_id` (`"<rank>|<uuid>"`, the definitions-search combined slot).

  `forgeries/2` yields one cursor per (slot, bad value), one per truncation, and one over-long
  tail where the last slot cannot swallow an extra colon. Test-only; compiled under
  `elixirc_paths(:test)`, never referenced from `lib/`.
  """

  alias Letflow.Api.Pagination

  @type slot_type :: :mint | :mint_dt | :dt | :int | :uuid | :string | :rank_id

  @typedoc "`{label, cursor, bad_mint?}` -- `bad_mint?` marks a forgery whose FIRST slot is bad."
  @type forgery :: {String.t(), String.t(), boolean()}

  @bad %{
    # A far-future mint is a VALID mint (it never expires and the slot is skipped), so it is
    # not forged for `:mint`; for `:mint_dt` the same slot is the sort key, so it IS bad there.
    mint: ["abc", "", "-1"],
    mint_dt: ["abc", "", "-1", "99999999999999999999"],
    dt: [
      "abc",
      "",
      "-1",
      "1.5",
      "99999999999999999999",
      "9223372036854775807",
      "253402300800000000"
    ],
    int: ["abc", "", "1.5", "9223372036854775808", "-9223372036854775809"],
    uuid: ["not-a-uuid", "", "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"],
    string: ["", "a" <> <<0>> <> "b", <<255>>, "ok" <> <<255, 254>>],
    rank_id: [
      "0|00000000-0000-4000-8000-000000000001",
      "4|00000000-0000-4000-8000-000000000001",
      "abc|00000000-0000-4000-8000-000000000001",
      "2|not-a-uuid",
      "2|",
      "|00000000-0000-4000-8000-000000000001",
      "2",
      ""
    ]
  }

  @doc "The current time in microseconds, as a slot string (a fresh mint)."
  @spec now_us() :: String.t()
  def now_us, do: Integer.to_string(System.system_time(:microsecond))

  @doc "A valid value for one slot type."
  @spec good(slot_type()) :: String.t()
  def good(:mint), do: now_us()
  def good(:mint_dt), do: now_us()
  def good(:dt), do: "1700000000000000"
  def good(:int), do: "5"
  def good(:uuid), do: Ecto.UUID.generate()
  def good(:string), do: "svc-1"
  def good(:rank_id), do: "2|" <> Ecto.UUID.generate()

  @doc "The encoded cursor for `prefix` and the given slot strings."
  @spec forge(String.t(), [String.t()]) :: String.t()
  def forge(prefix, slots), do: Pagination.encode_cursor(prefix <> Enum.join(slots, ":"))

  @doc "A fully valid forged cursor for `layout` (the positive control)."
  @spec valid(String.t(), [slot_type()]) :: String.t()
  def valid(prefix, layout), do: forge(prefix, Enum.map(layout, &good/1))

  @doc "Every single-fault forgery of `layout` (see the moduledoc)."
  @spec forgeries(String.t(), [slot_type(), ...]) :: [forgery()]
  def forgeries(prefix, layout) do
    valid_slots = Enum.map(layout, &good/1)

    per_slot =
      for {type, index} <- Enum.with_index(layout), bad <- Map.fetch!(@bad, type) do
        slots = List.replace_at(valid_slots, index, bad)
        {"#{prefix} slot #{index} #{type} #{inspect(bad)}", forge(prefix, slots), index == 0}
      end

    truncations =
      for keep <- 1..(length(layout) - 1)//1 do
        {"#{prefix} truncated to #{keep} slot(s)", forge(prefix, Enum.take(valid_slots, keep)),
         false}
      end

    over_long =
      if List.last(layout) == :string,
        do: [],
        else: [{"#{prefix} over-long tail", forge(prefix, valid_slots ++ ["junk"]), false}]

    per_slot ++ truncations ++ over_long
  end
end
