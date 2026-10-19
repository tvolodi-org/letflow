defmodule Letflow.Api.PaginationTest do
  @moduledoc """
  Tests for `Letflow.Api.Pagination` (REQ-067, spec: `test/specs/REQ-067.md`).

  Pure unit tests — `Letflow.Api.Pagination` has no `Plug.Conn` and no
  `Ecto.Repo` dependency, so plain `ExUnit.Case` is used, matching
  `test/letflow/api/response_test.exs`'s precedent for DB-free surface.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Letflow.Api.Pagination
  alias Letflow.Api.Pagination.Cursor

  # ── AC1: constants, asserted via accessor, not a duplicated literal ────────

  describe "constants" do
    test "max_page_size/0 returns 200" do
      assert Pagination.max_page_size() == 200
    end

    test "default_page_size/0 returns 50" do
      assert Pagination.default_page_size() == 50
    end

    test "min_page_size/0 returns 1" do
      assert Pagination.min_page_size() == 1
    end

    test "cursor_expiry_us/0 returns 86_400_000_000" do
      assert Pagination.cursor_expiry_us() == 86_400_000_000
    end
  end

  # ── AC2: page-size validation, reject not clamp ────────────────────────────

  describe "parse_page_size_param/1" do
    test "nil is {:ok, nil}" do
      assert Pagination.parse_page_size_param(nil) == {:ok, nil}
    end

    test "an ordinary numeric string parses" do
      assert Pagination.parse_page_size_param("50") == {:ok, 50}
    end

    test "a non-numeric string is rejected" do
      assert Pagination.parse_page_size_param("abc") == {:error, :invalid_page_size}
    end

    test "trailing garbage after digits is rejected" do
      assert Pagination.parse_page_size_param("20x") == {:error, :invalid_page_size}
    end

    test "a decimal point is rejected" do
      assert Pagination.parse_page_size_param("3.5") == {:error, :invalid_page_size}
    end

    test "a negative sign is rejected" do
      assert Pagination.parse_page_size_param("-5") == {:error, :invalid_page_size}
    end
  end

  describe "validate_page_size/1" do
    test "nil defaults to 50" do
      assert Pagination.validate_page_size(nil) == {:ok, 50}
    end

    test "0 is rejected (below MIN_PAGE_SIZE)" do
      assert Pagination.validate_page_size(0) == {:error, :page_size_too_large}
    end

    test "201 is rejected (above MAX_PAGE_SIZE)" do
      assert Pagination.validate_page_size(201) == {:error, :page_size_too_large}
    end

    test "1 (MIN_PAGE_SIZE boundary) succeeds" do
      assert Pagination.validate_page_size(1) == {:ok, 1}
    end

    test "200 (MAX_PAGE_SIZE boundary) succeeds -- proves reject, not clamp" do
      # A clamp implementation (min(size, 200)) would make 201 above return
      # {:ok, 200} instead of an error; pinning both fences here.
      assert Pagination.validate_page_size(200) == {:ok, 200}
    end
  end

  # ── AC3: cross-endpoint prefix rejection ───────────────────────────────────

  describe "decode_cursor/4 and prefix validation (AC3)" do
    test "rejects a cursor minted with a different prefix" do
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "task-1")
      encoded = Pagination.encode_cursor(raw)

      assert Pagination.decode_cursor(encoded, "I:", 2) == {:error, :wrong_endpoint}
    end

    test "accepts the same cursor decoded with its own prefix" do
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "task-1")
      encoded = Pagination.encode_cursor(raw)

      assert {:ok, %Cursor{inner: ^raw}} = Pagination.decode_cursor(encoded, "T:", 2)
    end

    test "rejects a decoded payload shorter than the prefix" do
      encoded = Pagination.encode_cursor("x")

      assert Pagination.decode_cursor(encoded, "PREFIX:", 0) == {:error, :wrong_endpoint}
    end

    # ISS-0216: an empty prefix used to make String.starts_with?/2 match
    # unconditionally (every binary "starts with" ""), so check_prefix/2
    # returned :ok for ANY decoded payload regardless of which endpoint
    # minted it -- defeating cross-endpoint cursor isolation. The fix
    # (lib/letflow/api/pagination.ex check_prefix/2's new leading clause)
    # raises ArgumentError instead. See test/specs/ISS-0216.md.
    test "ISS-0216: an empty prefix raises ArgumentError instead of silently matching" do
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "task-1")
      encoded = Pagination.encode_cursor(raw)

      assert_raise ArgumentError, ~r/empty prefix/, fn ->
        Pagination.decode_cursor(encoded, "", 2)
      end
    end

    test "ISS-0216: an empty prefix raises even against a payload with no colons at all" do
      # Pins that the raise fires purely on prefix == "" -- independent of
      # decoded's own shape -- so a future change couldn't reintroduce the
      # bypass by special-casing "well-formed" cursors only.
      encoded = Pagination.encode_cursor("anything")

      assert_raise ArgumentError, fn ->
        Pagination.decode_cursor(encoded, "", 0)
      end
    end
  end

  # ── AC4: expiry checking, no wall-clock waiting ────────────────────────────

  describe "decode_cursor/4 and expiry (AC4)" do
    test "rejects a cursor built with a deliberately old timestamp" do
      # Fixed at the Unix epoch -- unconditionally more than 24h in the past
      # relative to any real clock read, with no sleep or clock manipulation.
      raw = Pagination.build_raw_cursor("T:", 0, "task-1")
      encoded = Pagination.encode_cursor(raw)

      assert Pagination.decode_cursor(encoded, "T:", 2) == {:error, :expired}
    end

    test "accepts a cursor built with the current timestamp" do
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "task-1")
      encoded = Pagination.encode_cursor(raw)

      assert {:ok, %Cursor{}} = Pagination.decode_cursor(encoded, "T:", 2)
    end

    test "honours a custom expiry_window_us narrower than the default" do
      five_seconds_ago = System.system_time(:microsecond) - 5_000_000
      raw = Pagination.build_raw_cursor("T:", five_seconds_ago, "task-1")
      encoded = Pagination.encode_cursor(raw)

      # 1s window, but the cursor is ~5s old: proves the 4th argument is
      # genuinely read, not silently overridden by the 24h default.
      assert Pagination.decode_cursor(encoded, "T:", 2, 1_000_000) == {:error, :expired}
    end
  end

  # ── AC5 / INV-1: tenant isolation is structural, not conventional ──────────

  describe "Cursor struct and tenant isolation (AC5, security-load-bearing)" do
    test "Cursor's struct fields are exactly [:inner]" do
      fields = %Cursor{} |> Map.from_struct() |> Map.keys()

      assert fields == [:inner]
    end

    # Fixture-only: NOT application code. Stands in for "this endpoint's own
    # request-context scoping" (REQ-072, not yet implemented). The cursor
    # itself carries no tenant field for this lookup to (correctly or
    # incorrectly) honour -- tenant_scope is supplied independently.
    defp fixture_rows do
      [
        %{tenant: :tenant_a, id: "a-1", name: "alpha-one"},
        %{tenant: :tenant_a, id: "a-2", name: "alpha-two"},
        %{tenant: :tenant_b, id: "b-1", name: "bravo-one"},
        %{tenant: :tenant_b, id: "b-2", name: "bravo-two"}
      ]
    end

    defp fixture_list(tenant_scope, %Cursor{inner: inner}) do
      # This "endpoint" only ever knows how to filter by the tenant_scope it
      # was independently called with -- it has no code path that could pull
      # a tenant out of `inner`, because `inner` never contains one (it is
      # "<prefix><timestamp>:<key>", built entirely from a row id).
      _ = inner

      fixture_rows()
      |> Enum.filter(&(&1.tenant == tenant_scope))
    end

    test "a cursor minted from tenant A's data cannot surface tenant A's rows when replayed scoped to tenant B" do
      # Mint the cursor while "iterating" tenant A -- its key is one of
      # tenant A's own row ids.
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "a-1")
      encoded = Pagination.encode_cursor(raw)

      # decode_cursor/4 succeeds regardless of which tenant "produced" the
      # cursor -- it has no tenant concept at all.
      assert {:ok, %Cursor{} = cursor} = Pagination.decode_cursor(encoded, "T:", 2)

      # Replay against a request scoped to tenant B.
      tenant_b_rows = fixture_list(:tenant_b, cursor)

      assert Enum.all?(tenant_b_rows, &(&1.tenant == :tenant_b))
      refute Enum.any?(tenant_b_rows, &(&1.tenant == :tenant_a))

      assert tenant_b_rows == [
               %{tenant: :tenant_b, id: "b-1", name: "bravo-one"},
               %{tenant: :tenant_b, id: "b-2", name: "bravo-two"}
             ]

      # And, so this isn't vacuous: the same cursor replayed scoped to
      # tenant A really does return tenant A's own rows -- the fixture lookup
      # genuinely works, it just never consulted the cursor for scope.
      tenant_a_rows = fixture_list(:tenant_a, cursor)
      assert Enum.all?(tenant_a_rows, &(&1.tenant == :tenant_a))
    end
  end

  # ── AC6: pagination completeness across 3+ pages ───────────────────────────

  describe "pagination completeness (AC6)" do
    defp fixture_all_items, do: for(i <- 1..25, do: %{sort_key: i, id: "item-#{i}"})

    # Rounds trip the cursor between pages through the module's own
    # encode/decode/build/parse functions, rather than passing the raw sort
    # key between pages directly -- so the module under test is actually
    # exercised, not just this fixture's bookkeeping.
    defp fixture_page(items, page_size, cursor) do
      after_key =
        case cursor do
          nil ->
            0

          %Cursor{inner: inner} ->
            # The prefix "T:" itself contains a colon (the 1st), so the
            # timestamp/key separator is the 2nd colon in the payload.
            colon = Pagination.find_nth_colon(inner, 2)

            {:ok, key} =
              Pagination.parse_int_from_cursor(inner, colon + 1, byte_size(inner) - colon - 1)

            key
        end

      page_items =
        items
        |> Enum.filter(&(&1.sort_key > after_key))
        |> Enum.sort_by(& &1.sort_key)
        |> Enum.take(page_size)

      next_cursor =
        if length(page_items) < page_size do
          nil
        else
          last = List.last(page_items)
          # The timestamp component is the current time (this fixture cares
          # about the sort key carried after the colon, not expiry); a fixed
          # past literal here would be rejected as expired by decode_cursor/4.
          raw =
            Pagination.build_raw_cursor(
              "T:",
              System.system_time(:microsecond),
              "#{last.sort_key}"
            )

          encoded = Pagination.encode_cursor(raw)
          {:ok, decoded} = Pagination.decode_cursor(encoded, "T:", 2)
          decoded
        end

      {page_items, next_cursor}
    end

    test "paging through 3+ pages returns every row exactly once, no dup, no gap" do
      items = fixture_all_items()

      {page1, cursor1} = fixture_page(items, 10, nil)
      {page2, cursor2} = fixture_page(items, 10, cursor1)
      {page3, cursor3} = fixture_page(items, 10, cursor2)

      assert length(page1) == 10
      assert length(page2) == 10
      assert length(page3) == 5
      assert cursor3 == nil

      all_ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)

      assert length(all_ids) == 25
      assert Enum.uniq(all_ids) == all_ids
      assert Enum.sort(all_ids) == Enum.sort(Enum.map(items, & &1.id))
    end

    test "the final page reports no next_cursor" do
      items = fixture_all_items()

      {_page1, cursor1} = fixture_page(items, 10, nil)
      {_page2, cursor2} = fixture_page(items, 10, cursor1)
      {_page3, cursor3} = fixture_page(items, 10, cursor2)

      refute cursor1 == nil
      refute cursor2 == nil
      assert cursor3 == nil
    end
  end

  # ── round-trip and decode edge cases (design §4/§5) ────────────────────────

  describe "encode_cursor/1 and decode_cursor/4 round trip" do
    test "round-trip preserves inner exactly" do
      # A current timestamp, not the fixed literal used by the exact-format
      # case below -- this case is about round-trip fidelity, not the format
      # string, and a fixed past literal would (correctly) be rejected as
      # expired by decode_cursor/4's default expiry window.
      raw = Pagination.build_raw_cursor("T:", System.system_time(:microsecond), "abc123")

      assert {:ok, %Cursor{inner: ^raw}} =
               raw |> Pagination.encode_cursor() |> Pagination.decode_cursor("T:", 2)
    end

    test "rejects invalid base64" do
      assert Pagination.decode_cursor("not valid base64!!", "T:", 2) == {:error, :invalid_base64}
    end

    test "rejects a cursor with a malformed timestamp slice" do
      raw = "T:abc:key1"
      encoded = Pagination.encode_cursor(raw)

      assert Pagination.decode_cursor(encoded, "T:", 2) == {:error, :invalid_cursor}
    end

    test "rejects when expiry_ts_offset is past the end of the decoded payload" do
      raw = "T:1"
      encoded = Pagination.encode_cursor(raw)

      assert Pagination.decode_cursor(encoded, "T:", 100) == {:error, :invalid_cursor}
    end
  end

  # ── parse_int_from_cursor/3 and find_nth_colon/2 ───────────────────────────

  describe "parse_int_from_cursor/3" do
    test "extracts an in-bounds integer" do
      decoded = "T:12345:key1"

      assert Pagination.parse_int_from_cursor(decoded, 2, 5) == {:ok, 12345}
    end

    test "rejects an out-of-bounds offset/len" do
      decoded = "T:123"

      assert Pagination.parse_int_from_cursor(decoded, 2, 100) == {:error, :invalid_cursor}
    end

    test "rejects a non-digit slice" do
      decoded = "T:abcde"

      assert Pagination.parse_int_from_cursor(decoded, 2, 5) == {:error, :invalid_cursor}
    end
  end

  # ── cast_binary_id_component/1 (ISS-0522) ──────────────────────────────────
  #
  # ISS-0522: an endpoint's own list function (e.g.
  # Letflow.Entities.Definitions.list_definitions/2) used to pin a cursor's
  # raw id_str substring straight into a :binary_id-typed WHERE clause, so a
  # non-UUID id component reached Repo.all/2 unvalidated and raised
  # Ecto.Query.CastError -- outside every `with`-chain error arm, unhandled.
  # cast_binary_id_component/1 is the shared guard (design:
  # lib/letflow/design/iss0522-cursor-uuid-cast-guard.md) a call site now
  # uses to validate that substring itself, before it ever reaches a query,
  # translating Ecto.UUID.cast/1's bare :error into this module's
  # established {:error, :invalid_cursor} shape (matching
  # decode_list_definitions_cursor/1's own catch-all atom). See
  # test/specs/ISS-0522.md.
  describe "cast_binary_id_component/1 (ISS-0522)" do
    test "a valid UUID string casts to {:ok, binary}, matching Ecto.UUID.cast/1's own shape" do
      uuid = Ecto.UUID.generate()

      assert Pagination.cast_binary_id_component(uuid) == Ecto.UUID.cast(uuid)
      assert {:ok, ^uuid} = Pagination.cast_binary_id_component(uuid)
    end

    test "a non-UUID string is rejected with {:error, :invalid_cursor}, not a raise" do
      assert Pagination.cast_binary_id_component("not-a-uuid") == {:error, :invalid_cursor}
    end

    test "an empty string is rejected with {:error, :invalid_cursor}" do
      assert Pagination.cast_binary_id_component("") == {:error, :invalid_cursor}
    end

    test "a UUID-length string with non-hex characters is rejected" do
      # Same byte length as a real UUID (36 chars incl. hyphens), but the
      # hex groups are replaced with non-hex letters -- proves the guard
      # checks content, not merely length/shape.
      assert Pagination.cast_binary_id_component("zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz") ==
               {:error, :invalid_cursor}
    end

    test "non-binary input is rejected with {:error, :invalid_cursor} instead of a pattern-match failure" do
      assert Pagination.cast_binary_id_component(12345) == {:error, :invalid_cursor}
      assert Pagination.cast_binary_id_component(nil) == {:error, :invalid_cursor}
    end
  end

  # ── decode_seek_parts/3 (GH 2747) ──────────────────────────────────────────
  #
  # GH 2747: every keyset decoder used to `String.split/3`-match and
  # `String.to_integer/1` the cursor tail, so a cursor with a valid prefix and a
  # mangled tail raised (500) instead of being refused (400). decode_seek_parts/3 is
  # the one shared decoder; these cases pin its contract slot type by slot type.
  # See test/specs/GH-2747.md.

  describe "decode_seek_parts/3 (GH 2747)" do
    @seek_prefix "X:"
    @max_datetime_us 253_402_300_799_999_999
    @int64_max 9_223_372_036_854_775_807
    @int64_min -9_223_372_036_854_775_808

    defp seek(rest, shape), do: Pagination.decode_seek_parts(@seek_prefix <> rest, "X:", shape)

    test "a valid payload round-trips every slot type; :skip is absent from the result" do
      uuid = Ecto.UUID.generate()
      us = 1_700_000_000_123_456

      assert {:ok, ["svc-1", ^uuid, 42, datetime]} =
               seek("999:svc-1:#{uuid}:42:#{us}", [:skip, :string, :uuid, :int, :datetime_us])

      assert DateTime.to_unix(datetime, :microsecond) == us
    end

    test ":skip alone yields an empty result list" do
      assert seek("999", [:skip]) == {:ok, []}
    end

    test "a payload that does not start with the prefix is refused" do
      assert Pagination.decode_seek_parts("Y:1:2", "X:", [:skip, :int]) ==
               {:error, :invalid_cursor}

      assert Pagination.decode_seek_parts("X", "X:", [:int]) == {:error, :invalid_cursor}
    end

    test "an empty tail and a missing slot are refused" do
      uuid = Ecto.UUID.generate()

      assert seek("", [:skip, :uuid, :int]) == {:error, :invalid_cursor}
      assert seek("999", [:skip, :uuid, :int]) == {:error, :invalid_cursor}
      assert seek("999:#{uuid}", [:skip, :uuid, :int]) == {:error, :invalid_cursor}
      # a trailing colon leaves the last slot empty, which no numeric/uuid slot accepts
      assert seek("999:#{uuid}:", [:skip, :uuid, :int]) == {:error, :invalid_cursor}
    end

    test "the last slot keeps any further colons" do
      assert seek("1:a:b:c", [:skip, :string]) == {:ok, ["a:b:c"]}
      assert seek("1:2:a:b", [:skip, :int, :string]) == {:ok, [2, "a:b"]}
    end

    test "extra colons after a non-string last slot are refused, not truncated" do
      assert seek("1:2:3", [:skip, :int]) == {:error, :invalid_cursor}
      assert seek("1:#{Ecto.UUID.generate()}:x", [:skip, :uuid]) == {:error, :invalid_cursor}
    end

    test ":int and :datetime_us refuse non-numeric text" do
      for bad <- ["abc", "", "1.5", "5abc", "0x10", "1e3", " 5", "5 "] do
        assert {bad, seek("1:#{bad}", [:skip, :int])} == {bad, {:error, :invalid_cursor}}
        assert {bad, seek("1:#{bad}", [:skip, :datetime_us])} == {bad, {:error, :invalid_cursor}}
      end
    end

    test ":int accepts the int64 bounds and refuses one past either" do
      assert seek("1:#{@int64_max}", [:skip, :int]) == {:ok, [@int64_max]}
      assert seek("1:#{@int64_min}", [:skip, :int]) == {:ok, [@int64_min]}
      assert seek("1:0", [:skip, :int]) == {:ok, [0]}
      assert seek("1:-7", [:skip, :int]) == {:ok, [-7]}

      assert seek("1:#{@int64_max + 1}", [:skip, :int]) == {:error, :invalid_cursor}
      assert seek("1:#{@int64_min - 1}", [:skip, :int]) == {:error, :invalid_cursor}
      assert seek("1:#{String.duplicate("9", 40)}", [:skip, :int]) == {:error, :invalid_cursor}
    end

    test ":datetime_us refuses a negative timestamp and accepts zero" do
      assert seek("1:-1", [:skip, :datetime_us]) == {:error, :invalid_cursor}
      assert {:ok, [epoch]} = seek("1:0", [:skip, :datetime_us])
      assert epoch == ~U[1970-01-01 00:00:00.000000Z]
    end

    test ":datetime_us refuses a timestamp DateTime.from_unix/2 rejects (invalid_unix_time)" do
      # A valid int64 that is not a representable DateTime; from_unix!/2 used to raise on it.
      assert seek("1:#{@int64_max}", [:skip, :datetime_us]) == {:error, :invalid_cursor}
      assert seek("1:#{@max_datetime_us + 1}", [:skip, :datetime_us]) == {:error, :invalid_cursor}
      assert seek("1:99999999999999999999", [:skip, :datetime_us]) == {:error, :invalid_cursor}
    end

    test ":datetime_us accepts the largest representable timestamp, to the microsecond" do
      assert {:ok, [datetime]} = seek("1:#{@max_datetime_us}", [:skip, :datetime_us])
      assert datetime == ~U[9999-12-31 23:59:59.999999Z]
      assert DateTime.to_unix(datetime, :microsecond) == @max_datetime_us
    end

    test ":datetime_us keeps microsecond precision" do
      assert {:ok, [datetime]} = seek("1:1700000000000001", [:skip, :datetime_us])
      assert datetime.microsecond == {1, 6}
    end

    test ":string refuses an empty slot, a NUL byte and invalid UTF-8" do
      assert seek("1:", [:skip, :string]) == {:error, :invalid_cursor}
      assert seek("1:a" <> <<0>> <> "b", [:skip, :string]) == {:error, :invalid_cursor}
      assert seek("1:" <> <<0>>, [:skip, :string]) == {:error, :invalid_cursor}
      assert seek("1:" <> <<255>>, [:skip, :string]) == {:error, :invalid_cursor}
      assert seek("1:ok" <> <<255, 254>>, [:skip, :string]) == {:error, :invalid_cursor}
    end

    test ":string accepts a multi-byte UTF-8 id verbatim" do
      assert seek("1:svc-é-日本", [:skip, :string]) == {:ok, ["svc-é-日本"]}
    end

    test ":uuid refuses anything that is not a UUID" do
      for bad <- ["not-a-uuid", "", "1234", "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"] do
        assert {bad, seek("1:#{bad}", [:skip, :uuid])} == {bad, {:error, :invalid_cursor}}
      end
    end

    test ":uuid returns the canonical lower-case form of an upper-case UUID" do
      uuid = Ecto.UUID.generate()

      assert seek("1:" <> String.upcase(uuid), [:skip, :uuid]) == {:ok, [uuid]}
    end

    test "the first bad slot decides: a good prefix of slots does not mask a bad later one" do
      uuid = Ecto.UUID.generate()

      assert seek("1:#{uuid}:abc", [:skip, :uuid, :int]) == {:error, :invalid_cursor}
      assert seek("1:nope:5", [:skip, :uuid, :int]) == {:error, :invalid_cursor}
    end

    property "never raises: any binary tail yields {:ok, _} or {:error, :invalid_cursor}" do
      check all(
              tail <- StreamData.binary(max_length: 80),
              shape <-
                StreamData.list_of(
                  StreamData.member_of([:skip, :string, :uuid, :int, :datetime_us]),
                  min_length: 1,
                  max_length: 4
                )
            ) do
        result = Pagination.decode_seek_parts(@seek_prefix <> tail, "X:", shape)

        assert match?({:ok, _}, result) or result == {:error, :invalid_cursor}
      end
    end
  end

  describe "find_nth_colon/2" do
    test "finds the n-th colon, 1-indexed" do
      slice = "a:bb:ccc:d"

      assert Pagination.find_nth_colon(slice, 1) == 1
      assert Pagination.find_nth_colon(slice, 2) == 4
      assert Pagination.find_nth_colon(slice, 3) == 8
    end

    test "returns nil when fewer than n colons exist" do
      slice = "a:bb:ccc"

      assert Pagination.find_nth_colon(slice, 5) == nil
    end
  end

  # ── build_raw_cursor/3 and build_raw_cursor_timestamp_key/4 exact format ──

  describe "raw cursor builders" do
    test ~s(build_raw_cursor produces "<prefix><timestamp_us>:<key>") do
      assert Pagination.build_raw_cursor("T:", 1_716_412_800_000_000, "abc123") ==
               "T:1716412800000000:abc123"
    end

    test ~s(build_raw_cursor_timestamp_key produces "<prefix><ts>:<key>:<created_at>") do
      assert Pagination.build_raw_cursor_timestamp_key(
               "I:",
               1_716_412_800_000_000,
               "abc123",
               1_716_412_860_000_000
             ) == "I:1716412800000000:abc123:1716412860000000"
    end
  end

  # ── page_response/2 ─────────────────────────────────────────────────────────

  describe "page_response/2" do
    test "count is always length(items), independent of caller input" do
      page = Pagination.page_response(["a", "b", "c"], "next-cursor-token")

      assert page.items == ["a", "b", "c"]
      assert page.count == 3
      assert page.next_cursor == "next-cursor-token"
    end

    test "count is 0 for an empty item list, next_cursor nil" do
      page = Pagination.page_response([], nil)

      assert page.count == 0
      assert page.next_cursor == nil
    end
  end
end
