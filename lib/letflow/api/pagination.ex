defmodule Letflow.Api.Pagination do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  The shared cursor-based pagination module every S4 list endpoint delegates
  to — ports `src/api/pagination.zig` (406 lines, R-Co's API-06). Design:
  `lib/letflow/design/api-pagination.md`.

  Pure: no `Plug.Conn` dependency (see `Letflow.Api.Pagination.Cursor`'s
  callers) and no `Ecto.Schema`/`Repo` call anywhere in this module — it only
  encodes/decodes an opaque payload string and validates a page-size
  parameter. Route handlers translate this module's error atoms into problem
  documents via `Letflow.Api.Error`/`Letflow.Api.Response`; this module itself
  never calls either (design §0.1).

  ## Security invariants

  **INV-1 / INV-5 (structural, not conventional).** `Cursor.t()` has exactly
  one field, `inner :: binary()`. There is no `tenant_id`, `schema`, or
  `prefix` field on the struct — no slot a decoded cursor could populate to
  widen or redirect a query's tenant scope. Tenant scoping is exclusively the
  caller's own request-context parameter (REQ-072, not yet implemented),
  never anything this module decodes. `cursor.inner` is a fully opaque byte
  string a caller may only parse for its own already-known
  sort-key/pagination fields via `parse_int_from_cursor/3`/`find_nth_colon/2`
  (design §0.3).

  **INV-8 (no unhandled crashes on realistic failure paths).** No function in
  this module raises on well-typed input — every fallible operation returns a
  tagged tuple, since cursor/page-size values are caller-controlled,
  network-facing input.

  **INV-9 (structural, not conventional).** `decode_cursor/4` never
  silently accepts an empty `prefix`. `check_prefix/2` raises
  `ArgumentError` immediately if `prefix == ""`, rather than allowing
  `String.starts_with?/2`'s documented empty-string-always-matches
  semantics to defeat cross-endpoint cursor isolation. This is a
  precondition on the *caller's own hardcoded literal* (see the
  "prefix is caller-internal configuration" note below), not a
  network-facing input validation — it exists to catch a future call
  site's programming mistake at the first test/request that exercises
  it, not to sanitize untrusted data.

  **Wall-clock time boundary.** `decode_cursor/4` is the only function in this
  module that reads wall-clock time (`System.system_time(:microsecond)`).
  This module is API-layer code; no pure S2/S3 module (e.g.
  `Letflow.Engine.Transition`) may call `decode_cursor/4` for its time-reading
  side effect.
  """

  @max_page_size 200
  @default_page_size 50
  @min_page_size 1
  @cursor_expiry_us 86_400_000_000

  defmodule Cursor do
    @moduledoc """
    PROVENANCE (historical, not current decision authority):
    An opaque decoded cursor payload. Ports `pagination.zig`'s `Cursor` struct
    (lines 61-72) minus its allocator/`deinit` fields — BEAM garbage
    collection has no caller-managed allocator or manual `free` to port.

    **`inner` is the only field** — see `Letflow.Api.Pagination`'s moduledoc
    for why this is the structural INV-1/INV-5 enforcement mechanism, not
    merely a documented convention.
    """

    defstruct [:inner]

    @type t :: %__MODULE__{inner: binary()}
  end

  defmodule Page do
    @moduledoc """
    PROVENANCE (historical, not current decision authority):
    The standardised page-response envelope. Ports `PageResponse(comptime T:
    type)` (`pagination.zig` lines 78-87) — Elixir has no generics, so
    `t(item)` is a documentation-only parameterised `@type` (the same
    technique Elixir's own `Enumerable.t()` uses), not a runtime distinction.
    """

    @derive {Jason.Encoder, only: [:items, :next_cursor, :count]}
    defstruct [:items, :next_cursor, count: 0]

    @type t(item) :: %__MODULE__{
            items: [item],
            next_cursor: String.t() | nil,
            count: non_neg_integer()
          }
  end

  # ── Constants (§1) ─────────────────────────────────────────────────────────

  @doc "The maximum accepted `page_size` (200)."
  @spec max_page_size() :: pos_integer()
  def max_page_size, do: @max_page_size

  @doc "The `page_size` used when the caller supplies none (50)."
  @spec default_page_size() :: pos_integer()
  def default_page_size, do: @default_page_size

  @doc "The minimum accepted `page_size` (1)."
  @spec min_page_size() :: pos_integer()
  def min_page_size, do: @min_page_size

  @doc "How long a minted cursor remains valid, in microseconds (24h)."
  @spec cursor_expiry_us() :: pos_integer()
  def cursor_expiry_us, do: @cursor_expiry_us

  # ── Page-size validation (§3) ────────────────────────────────────────────

  @doc """
  Parses a raw `page_size` query-param string into an integer, or rejects it.

  `nil` (param absent) is `{:ok, nil}`. A string is `{:ok, integer}` only if
  it parses via `Integer.parse/1` consuming the **entire** string with no
  remainder, and the parsed integer is non-negative; anything else
  (non-numeric, a decimal point, trailing garbage, a negative sign) is
  `{:error, :invalid_page_size}`.

  PROVENANCE (historical, not current decision authority):
  This is the parse-time concern the design's §0.1 calls out as having no
  direct `pagination.zig` counterpart: Zig's `validatePageSize(raw: ?u16)`
  takes an already-parsed `?u16`, a type boundary Elixir has no compile-time
  equivalent for.
  """
  @spec parse_page_size_param(String.t() | nil) ::
          {:ok, pos_integer() | nil} | {:error, :invalid_page_size}
  def parse_page_size_param(nil), do: {:ok, nil}

  def parse_page_size_param(raw) when is_binary(raw) do
    with {int, ""} <- Integer.parse(raw), true <- int >= 0 do
      {:ok, int}
    else
      _ -> {:error, :invalid_page_size}
    end
  end

  @doc """
  PROVENANCE (historical, not current decision authority):
  Range-validates an already-parsed page size. Ports `validatePageSize/1`
  (`pagination.zig` lines 97-108) almost verbatim: `nil` -> the default;
  `0` or `> #{@max_page_size}` -> reject; otherwise pass through unchanged.

  PROVENANCE (historical, not current decision authority):
  Reject, not clamp: no out-of-range input is ever rounded to a bound (design
  §0.2). `0` and `> #{@max_page_size}` share the same error atom, ported
  verbatim from `pagination.zig`'s single-member `PageSizeError` set rather
  than inventing a finer-grained atom R-Co itself does not have.
  """
  @spec validate_page_size(pos_integer() | nil) ::
          {:ok, pos_integer()} | {:error, :page_size_too_large}
  def validate_page_size(nil), do: {:ok, @default_page_size}
  def validate_page_size(0), do: {:error, :page_size_too_large}

  def validate_page_size(size) when is_integer(size) and size > 0 do
    if size > @max_page_size do
      {:error, :page_size_too_large}
    else
      {:ok, size}
    end
  end

  # ── Page response envelope (§2.2) ───────────────────────────────────────

  @doc """
  Builds the standardised page-response envelope. `count` is always
  `length(items)`, computed here — there is no separately-suppliable `count`
  parameter that could disagree with `items`'s actual length.
  """
  @spec page_response([item], String.t() | nil) :: Page.t(item) when item: var
  def page_response(items, next_cursor) do
    %Page{items: items, next_cursor: next_cursor, count: length(items)}
  end

  # ── Cursor encoding (§4) ─────────────────────────────────────────────────

  @doc """
  Encodes a raw cursor payload as an opaque base64url string (no padding).
  Cannot fail on a binary input.
  """
  @spec encode_cursor(binary()) :: binary()
  def encode_cursor(raw) when is_binary(raw), do: Base.url_encode64(raw, padding: false)

  # ── Cursor decoding — prefix + expiry validation (§5) ───────────────────

  @doc """
  PROVENANCE (historical, not current decision authority):
  Decodes and validates a cursor, in the same order `pagination.zig`'s
  `decodeCursor/5` performs its checks (lines 140-180):

    1. base64url-decode `encoded` -> `{:error, :invalid_base64}` on failure;
    2. `prefix` match against the decoded payload -> `{:error,
       :wrong_endpoint}` if the decoded value doesn't start with `prefix`
       (this is what makes a cursor minted by one endpoint unusable against a
       different endpoint's `decode_cursor/4` call);
    3. expiry check on the decimal microsecond timestamp starting at byte
       offset `expiry_ts_offset` -> `{:error, :invalid_cursor}` if that slice
       is missing/malformed, or `{:error, :expired}` if
       `now_us - timestamp > expiry_window_us`.

  `expiry_window_us` defaults to `cursor_expiry_us/0` (24h) so ordinary call
  sites only supply the three arguments that vary per endpoint.

  On success: `{:ok, %Cursor{inner: decoded}}`.

  `prefix` must be a non-empty, hardcoded, per-endpoint literal — never a
  value derived from the request, query string, path, or any other
  caller-controlled input; see the moduledoc's INV-9. An empty `prefix`
  raises `ArgumentError` rather than returning an error tuple, since this
  is a caller-contract violation, not cursor-payload validation (contrast
  with `{:error, :wrong_endpoint}`, which is about the decoded payload,
  never about `prefix` itself).
  """
  @spec decode_cursor(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Cursor.t()}
          | {:error, :invalid_base64}
          | {:error, :wrong_endpoint}
          | {:error, :expired}
          | {:error, :invalid_cursor}
  def decode_cursor(encoded, prefix, expiry_ts_offset, expiry_window_us \\ @cursor_expiry_us) do
    with {:ok, decoded} <- url_decode(encoded),
         :ok <- check_prefix(decoded, prefix),
         {:ok, ts} <- extract_expiry_timestamp(decoded, expiry_ts_offset),
         :ok <- check_expiry(ts, expiry_window_us) do
      {:ok, %Cursor{inner: decoded}}
    end
  end

  @spec url_decode(String.t()) :: {:ok, binary()} | {:error, :invalid_base64}
  defp url_decode(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  @spec check_prefix(binary(), String.t()) :: :ok | {:error, :wrong_endpoint}
  # INV-9: an empty prefix would make String.starts_with?/2 always match,
  # silently defeating cross-endpoint cursor isolation (ISS-0216). This is a
  # caller-contract violation (prefix is always a hardcoded, per-endpoint
  # literal — never request/query/path-derived), not cursor-payload
  # validation, so it raises instead of returning a tagged tuple.
  defp check_prefix(_decoded, "") do
    raise ArgumentError, """
    Letflow.Api.Pagination.decode_cursor/4 was called with an empty prefix.

    prefix must be a non-empty, hardcoded, per-endpoint literal — never a
    value derived from the request, query string, path, or any other
    caller-controlled input.

    An empty prefix defeats decode_cursor/4's cross-endpoint cursor
    isolation, since every decoded cursor payload trivially starts with the
    empty string (ISS-0216). See the moduledoc's INV-9 for the full
    invariant this precondition enforces.
    """
  end

  defp check_prefix(decoded, prefix) do
    if byte_size(decoded) >= byte_size(prefix) and String.starts_with?(decoded, prefix) do
      :ok
    else
      {:error, :wrong_endpoint}
    end
  end

  @spec extract_expiry_timestamp(binary(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_cursor}
  defp extract_expiry_timestamp(decoded, expiry_ts_offset) do
    if expiry_ts_offset >= byte_size(decoded) do
      {:error, :invalid_cursor}
    else
      ts_slice_len = byte_size(decoded) - expiry_ts_offset
      ts_slice = binary_part(decoded, expiry_ts_offset, ts_slice_len)

      ts_slice =
        case :binary.match(ts_slice, ":") do
          {colon_pos, _} -> binary_part(ts_slice, 0, colon_pos)
          :nomatch -> ts_slice
        end

      case ts_slice do
        "" ->
          {:error, :invalid_cursor}

        _ ->
          case Integer.parse(ts_slice) do
            {ts, ""} when ts >= 0 -> {:ok, ts}
            _ -> {:error, :invalid_cursor}
          end
      end
    end
  end

  @spec check_expiry(non_neg_integer(), non_neg_integer()) :: :ok | {:error, :expired}
  defp check_expiry(ts, expiry_window_us) do
    now_us = System.system_time(:microsecond)

    if now_us - ts > expiry_window_us do
      {:error, :expired}
    else
      :ok
    end
  end

  # ── Encode-side raw-payload builders (§6) ───────────────────────────────

  @doc """
  PROVENANCE (historical, not current decision authority):
  Builds a raw cursor payload of the shape `"<prefix><timestamp_us>:<key>"`
  (e.g. `"T:1716412800000000:abc123"`). Ports `buildRawCursor/4`
  (`pagination.zig` lines 193-200) minus its `allocator` parameter. Pass the
  result to `encode_cursor/1` to get the opaque string handed to the HTTP
  client as `next_cursor`.
  """
  @spec build_raw_cursor(String.t(), integer(), String.t()) :: binary()
  def build_raw_cursor(prefix, timestamp_us, key) do
    "#{prefix}#{timestamp_us}:#{key}"
  end

  @doc """
  PROVENANCE (historical, not current decision authority):
  Builds a raw cursor payload of the shape
  `"<prefix><sort_timestamp_us>:<key>:<cursor_created_at_us>"` (e.g.
  `"I:1716412800000000:abc123:1716412860000000"`). Ports
  `buildRawCursorTimestampKey/5` (`pagination.zig` lines 210-222) minus its
  `allocator` parameter.
  """
  @spec build_raw_cursor_timestamp_key(String.t(), integer(), String.t(), integer()) :: binary()
  def build_raw_cursor_timestamp_key(prefix, sort_timestamp_us, key, cursor_created_at_us) do
    "#{prefix}#{sort_timestamp_us}:#{key}:#{cursor_created_at_us}"
  end

  # ── Cursor-payload parsing utilities (§7) ───────────────────────────────

  @doc """
  PROVENANCE (historical, not current decision authority):
  Extracts a decimal integer from `decoded[offset, len]`. Ports
  `parseIntFromCursor/3` (`pagination.zig` lines 227-235). An out-of-bounds
  slice or a non-digit-only slice is `{:error, :invalid_cursor}`.

  This is one of the utilities an endpoint's own store/list function uses to
  pull its own sort-key fields out of `cursor.inner` — this module never
  interprets those fields itself (design §0.3).
  """
  @spec parse_int_from_cursor(binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, integer()} | {:error, :invalid_cursor}
  def parse_int_from_cursor(decoded, offset, len) do
    if offset + len > byte_size(decoded) do
      {:error, :invalid_cursor}
    else
      slice = binary_part(decoded, offset, len)

      case Integer.parse(slice) do
        {int, ""} -> {:ok, int}
        _ -> {:error, :invalid_cursor}
      end
    end
  end

  @doc """
  Casts a cursor-payload substring expected to be an Ecto `:binary_id` (UUID)
  component into its binary form, or rejects it. Companion to
  `parse_int_from_cursor/3` above for the binary_id case: an endpoint's own
  store/list function uses this to validate a domain field parsed out of
  `cursor.inner` before pinning it into a query against a `:binary_id`
  column -- this module never interprets `cursor.inner`'s domain fields on
  its own (design §0.3 is unchanged by this addition).
  """
  @spec cast_binary_id_component(String.t()) ::
          {:ok, Ecto.UUID.t()} | {:error, :invalid_cursor}
  def cast_binary_id_component(component) when is_binary(component) do
    case Ecto.UUID.cast(component) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_cursor}
    end
  end

  def cast_binary_id_component(_component), do: {:error, :invalid_cursor}

  @typedoc """
  One slot of a seek payload's shape for `decode_seek_parts/3`:

    * `:skip` -- validated as present, dropped from the result (the
      mint-time slot `decode_cursor/4`'s expiry check already read);
    * `:string` -- any non-empty string, returned as-is (ids that are not UUIDs);
    * `:uuid` -- an Ecto `:binary_id` component, cast via
      `cast_binary_id_component/1`;
    * `:int` -- a decimal integer within the int64 range;
    * `:datetime_us` -- a non-negative unix microsecond timestamp, returned
      as a `DateTime` (`DateTime.from_unix/2`, never `from_unix!/2`).
  """
  @type seek_part :: :skip | :string | :uuid | :int | :datetime_us

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @doc """
  Decodes the domain slots of a `decode_cursor/4`-validated seek payload,
  `"<prefix><slot>:<slot>:...:<last slot>"`, without ever raising on a
  malformed tail (INV-8, GH 2747). `shape` lists one `t:seek_part/0` per
  slot; the payload is split on `:` into exactly `length(shape)` parts (the
  last slot keeps any remaining colons). Returns `{:ok, values}` -- the
  decoded value of every non-`:skip` slot, in order -- or
  `{:error, :invalid_cursor}` for a missing slot, a non-numeric or
  out-of-range number, a timestamp `DateTime.from_unix/2` rejects, or a
  non-UUID `:uuid` slot.

  `decode_cursor/4` only validates the prefix and the first timestamp slot,
  so a cursor with a valid prefix and a mangled rest reaches this function.
  """
  @spec decode_seek_parts(binary(), String.t(), [seek_part(), ...]) ::
          {:ok, [term()]} | {:error, :invalid_cursor}
  def decode_seek_parts(inner, prefix, [_ | _] = shape)
      when is_binary(inner) and is_binary(prefix) do
    slots = length(shape)
    prefix_len = byte_size(prefix)

    with true <- byte_size(inner) >= prefix_len and String.starts_with?(inner, prefix),
         rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len),
         parts when length(parts) == slots <- String.split(rest, ":", parts: slots) do
      shape |> Enum.zip(parts) |> decode_seek_slots([])
    else
      _malformed -> {:error, :invalid_cursor}
    end
  end

  defp decode_seek_slots([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_seek_slots([{:skip, _part} | rest], acc), do: decode_seek_slots(rest, acc)

  defp decode_seek_slots([{type, part} | rest], acc) do
    case decode_seek_slot(type, part) do
      {:ok, value} -> decode_seek_slots(rest, [value | acc])
      {:error, :invalid_cursor} = error -> error
    end
  end

  defp decode_seek_slot(:string, ""), do: {:error, :invalid_cursor}

  defp decode_seek_slot(:string, part) do
    if String.valid?(part) and not String.contains?(part, <<0>>),
      do: {:ok, part},
      else: {:error, :invalid_cursor}
  end

  defp decode_seek_slot(:uuid, part), do: cast_binary_id_component(part)

  defp decode_seek_slot(:int, part) do
    case Integer.parse(part) do
      {int, ""} when int >= @int64_min and int <= @int64_max -> {:ok, int}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_seek_slot(:datetime_us, part) do
    with {:ok, us} when us >= 0 <- decode_seek_slot(:int, part),
         {:ok, datetime} <- DateTime.from_unix(us, :microsecond) do
      {:ok, datetime}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  @doc """
  PROVENANCE (historical, not current decision authority):
  Returns the zero-indexed byte position of the `n`-th `:` (1-indexed `n`,
  matching `pagination.zig`'s own 1-indexing) in `slice`, or `nil` if fewer
  than `n` colons exist. Ports `findNthColon/2` (`pagination.zig` lines
  239-248).
  """
  @spec find_nth_colon(binary(), pos_integer()) :: non_neg_integer() | nil
  def find_nth_colon(slice, n) when is_integer(n) and n > 0 do
    find_nth_colon_from(slice, n, 0, 0)
  end

  defp find_nth_colon_from(slice, n, count, offset) do
    case :binary.match(slice, ":", scope: {offset, byte_size(slice) - offset}) do
      {pos, _} ->
        count = count + 1
        if count == n, do: pos, else: find_nth_colon_from(slice, n, count, pos + 1)

      :nomatch ->
        nil
    end
  end
end
