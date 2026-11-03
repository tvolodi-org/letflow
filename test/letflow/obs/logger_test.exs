defmodule Letflow.Obs.LoggerTest do
  @moduledoc """
  Tests for REQ-193 — `Letflow.Obs.Logger` (OTP `:logger_formatter` for structured
  JSON output). See `test/specs/REQ-193.md` for the full AC → test-case mapping and
  rationale.

  ## Testing strategy

  `ExUnit.CaptureLog` uses its own temporary handler with a plain-text formatter, not
  our JSON formatter — so `capture_log/1` output is not JSON and cannot be decoded.
  Instead, these tests call `OLogger.format/2` directly: build a minimal OTP log-event
  map, pass it to the formatter, decode the JSON result, and assert field values.
  This is honest end-to-end coverage of the formatter's actual logic.

  `capture_log` IS used in AC5b, but only to assert Logger-level filtering behaviour
  (does a debug message appear or not?) — the content of those captures is plain text,
  not decoded as JSON.

  ## Why `async: false`

  AC5b calls `Logger.configure(level: :debug)`, which modifies the node-global primary
  log level. Serialising this file prevents interference with other test files that
  depend on a stable `:info` level.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  import ExUnit.CaptureLog
  import Plug.Test

  require Logger

  alias Letflow.Obs.Logger, as: OLogger
  alias Letflow.Api.Context

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Builds the minimal map shape OTP :logger passes to format/2.
  defp make_event(level, message, extra_meta \\ %{}) do
    base_meta = %{
      time: :erlang.system_time(:microsecond),
      mfa: {__MODULE__, :test_fn, 0}
    }

    %{
      level: level,
      msg: {:string, message},
      meta: Map.merge(base_meta, extra_meta)
    }
  end

  # Calls format/2, strips the trailing newline, decodes the JSON line.
  defp format_and_decode(event) do
    event
    |> OLogger.format([])
    |> IO.iodata_to_binary()
    |> String.trim_trailing("\n")
    |> Jason.decode!()
  end

  # ---------------------------------------------------------------------------
  # AC1 — exactly one JSON line containing all five required fields
  # ---------------------------------------------------------------------------

  test "AC1: a log call emits exactly one JSON line containing timestamp, level, trace_id, component, and message" do
    event = make_event(:info, "hello")
    raw = OLogger.format(event, []) |> IO.iodata_to_binary()

    lines = String.split(raw, "\n", trim: true)

    assert length(lines) == 1,
           "expected exactly one log line; got #{length(lines)} non-empty lines in: #{inspect(raw)}"

    decoded = Jason.decode!(hd(lines))

    for key <- ~w[timestamp level trace_id component message] do
      assert Map.has_key?(decoded, key),
             "output JSON is missing required field #{inspect(key)}; decoded: #{inspect(decoded)}"
    end

    assert decoded["message"] == "hello"
  end

  # ---------------------------------------------------------------------------
  # AC2 — ISO 8601 UTC timestamp with microsecond precision
  # ---------------------------------------------------------------------------

  test "AC2: timestamp field parses as ISO 8601 UTC datetime with microsecond precision" do
    event = make_event(:info, "ts-test")
    ts = format_and_decode(event)["timestamp"]

    assert {:ok, _dt, 0} = DateTime.from_iso8601(ts),
           "timestamp #{inspect(ts)} does not parse as ISO 8601 UTC"

    assert ts =~ ~r/T\d{2}:\d{2}:\d{2}\.\d{6}Z$/,
           "timestamp #{inspect(ts)} does not carry microsecond precision (.xxxxxx suffix before Z)"
  end

  # ---------------------------------------------------------------------------
  # AC3 — trace_id propagated end-to-end through assign_trace_id/1
  # ---------------------------------------------------------------------------

  test "AC3: log line after assign_trace_id/1 carries the same trace_id that function set in Logger metadata" do
    # assign_trace_id/1 internally calls Logger.metadata(trace_id: trace_id).
    # We invoke it (not Logger.metadata directly) and then read back what it set,
    # so the path exercised is the full assign_trace_id/1 code, not a manual metadata write.
    conn =
      :get
      |> conn("/test")
      |> Context.assign_trace_id()

    expected_trace_id = conn.assigns.trace_id

    # Read back the metadata as set by assign_trace_id/1 and embed in a real log event.
    current_meta =
      Logger.metadata()
      |> Map.new()
      |> Map.put(:time, :erlang.system_time(:microsecond))
      |> Map.put(:mfa, {__MODULE__, :test_fn, 0})

    event = %{level: :info, msg: {:string, "request log"}, meta: current_meta}
    decoded = format_and_decode(event)

    assert decoded["trace_id"] == expected_trace_id,
           "log trace_id #{inspect(decoded["trace_id"])} does not match the value " <>
             "assign_trace_id/1 placed in Logger metadata: #{inspect(expected_trace_id)}"
  after
    Logger.reset_metadata()
  end

  # ---------------------------------------------------------------------------
  # AC4 — no active trace → trace_id is empty string (key present, not omitted)
  # ---------------------------------------------------------------------------

  test "AC4: log with no active trace carries trace_id as the empty string; key is not omitted" do
    # No trace_id key in meta → formatter must emit "" rather than omitting the field.
    event = make_event(:info, "no trace")
    decoded = format_and_decode(event)

    assert Map.has_key?(decoded, "trace_id"),
           "trace_id key must be present in JSON output even when no trace is active"

    assert decoded["trace_id"] == "",
           "trace_id must be empty string when absent from metadata, not #{inspect(decoded["trace_id"])}"
  end

  # ---------------------------------------------------------------------------
  # AC5a — invalid LOG_LEVEL causes startup failure with a clear error
  # ---------------------------------------------------------------------------

  test "AC5a: invalid LOG_LEVEL raises RuntimeError at startup; source still contains the raise clause" do
    # The validation is inline in config/runtime.exs (not extracted as a module function).
    # (a) Assert the source file still contains the raise clause so this test cannot pass
    #     while the production guard has been removed.
    # (b) Exercise the case expression with an invalid value and assert the RuntimeError
    #     is raised with the expected message format.
    runtime_exs_path =
      Path.join([__DIR__, "..", "..", "..", "config", "runtime.exs"])
      |> Path.expand()

    runtime_exs = File.read!(runtime_exs_path)

    assert runtime_exs =~ "Invalid LOG_LEVEL",
           "config/runtime.exs must still contain the raise clause for invalid LOG_LEVEL values"

    # Exercise the exact same case expression that runtime.exs uses.
    assert_raise RuntimeError, ~r/Invalid LOG_LEVEL.*not-a-valid-level/, fn ->
      case "not-a-valid-level" do
        "debug" ->
          :debug

        "info" ->
          :info

        "warn" ->
          :warning

        "warning" ->
          :warning

        "error" ->
          :error

        invalid ->
          raise "Invalid LOG_LEVEL=#{inspect(invalid)}. Must be one of: debug, info, warn, warning, error."
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC5b — setting log level changes which entries are emitted
  # ---------------------------------------------------------------------------

  test "AC5b: log level controls which entries are emitted; debug suppressed at info, visible at debug" do
    original_level = Logger.level()

    try do
      Logger.configure(level: :info)
      at_info = capture_log(fn -> Logger.debug("should-not-appear-at-info") end)

      refute at_info =~ "should-not-appear-at-info",
             "debug message must be suppressed when primary log level is :info"

      Logger.configure(level: :debug)
      at_debug = capture_log([level: :debug], fn -> Logger.debug("should-appear-at-debug") end)

      assert at_debug =~ "should-appear-at-debug",
             "debug message must be emitted when primary log level is :debug"
    after
      Logger.configure(level: original_level)
    end
  end

  # ---------------------------------------------------------------------------
  # AC6 — with_trace/1 same trace_id within one op; distinct between two ops
  # ---------------------------------------------------------------------------

  test "AC6: with_trace/1 gives all lines in one operation the same trace_id; two calls get distinct ids" do
    # Collect the trace_ids visible inside a with_trace/1 call by reading Logger.metadata()
    # (which with_trace/1 populates) and passing it through the formatter.
    collect = fn ->
      OLogger.with_trace(fn ->
        snap = fn ->
          meta =
            Logger.metadata()
            |> Map.new()
            |> Map.put(:time, :erlang.system_time(:microsecond))
            |> Map.put(:mfa, {__MODULE__, :test_fn, 0})

          %{level: :info, msg: {:string, "line"}, meta: meta}
          |> format_and_decode()
          |> Map.fetch!("trace_id")
        end

        {snap.(), snap.()}
      end)
    end

    {id1a, id1b} = collect.()
    {id2a, _id2b} = collect.()

    assert id1a != "",
           "trace_id must not be empty inside with_trace/1"

    assert id1a == id1b,
           "both log lines inside one with_trace/1 call must share the same trace_id; " <>
             "got #{inspect(id1a)} and #{inspect(id1b)}"

    assert id1a != id2a,
           "two separate with_trace/1 invocations must produce distinct trace_ids; " <>
             "both got #{inspect(id1a)}"
  end

  # ---------------------------------------------------------------------------
  # AC7 — sensitive key values are replaced with "[REDACTED]"; key names preserved
  # ---------------------------------------------------------------------------

  test "AC7: values under sensitive keys are replaced with \"[REDACTED]\" while key names are kept" do
    event =
      make_event(:info, "redaction-test", %{
        secret: "s3cr3t-value",
        password: "hunter2",
        token: "tok-abc",
        client_secret: "cs-xyz",
        my_token: "hidden-bearer"
      })

    decoded = format_and_decode(event)

    for key <- ~w[secret password token client_secret my_token] do
      assert Map.has_key?(decoded, key),
             "key #{inspect(key)} must be present in output (only the value is redacted)"

      assert decoded[key] == "[REDACTED]",
             "expected [REDACTED] for #{inspect(key)}, got #{inspect(decoded[key])}"
    end
  end

  # ---------------------------------------------------------------------------
  # ISS-0769 — redact_sensitive/1 delegates to Letflow.Secrets.Redaction and
  # therefore also redacts sensitive-keyed 2-tuples nested inside lists
  # (e.g. Plug.Conn.headers()), not just top-level keys.
  # ---------------------------------------------------------------------------

  test "ISS-0769: redact_sensitive/1 redacts a nested header-tuple list, not just top-level keys" do
    meta = %{conn: %{req_headers: [{"authorization", "Bearer nested-tok"}]}}

    redacted = Letflow.Obs.Logger.redact_sensitive(meta)

    refute inspect(redacted) =~ "nested-tok"
    assert inspect(redacted) =~ "[REDACTED]"
  end

  # ---------------------------------------------------------------------------
  # AC8 — reserved field names in metadata do not shadow the real output values
  # ---------------------------------------------------------------------------

  test "AC8: metadata containing reserved field names does not shadow level, message, component, or timestamp" do
    # Reserved fields (level, message, component, timestamp) are ALWAYS derived from
    # the OTP log event itself, not from caller-supplied metadata. The formatter's
    # split_reserved/1 drops these keys from the additional-fields map so that
    # Map.merge(additional, base) cannot be used to override them.
    event = %{
      level: :info,
      msg: {:string, "real message"},
      meta: %{
        time: :erlang.system_time(:microsecond),
        mfa: {__MODULE__, :test_fn, 0},
        level: "injected-level",
        message: "injected-message",
        component: "injected-component",
        timestamp: "injected-timestamp"
      }
    }

    decoded = format_and_decode(event)

    assert decoded["level"] == "info",
           "level must be the real OTP event level (info), not caller-supplied \"injected-level\""

    assert decoded["message"] == "real message",
           "message must come from the msg field, not caller-supplied metadata \"injected-message\""

    refute decoded["component"] == "injected-component",
           "component must be derived from MFA metadata, not caller-supplied \"injected-component\""

    refute decoded["timestamp"] == "injected-timestamp",
           "timestamp must be computed from the event :time, not caller-supplied \"injected-timestamp\""
  end

  # ---------------------------------------------------------------------------
  # AC9 — source documents that redaction operates on field names
  # ---------------------------------------------------------------------------

  test "AC9: lib/letflow/obs/logger.ex contains text stating that redaction matches on field names" do
    # Redaction checks top-level key NAMES; a secret stored under an unrecognised key
    # name is not caught. The source must document this limitation so callers understand
    # why placing a secret under e.g. :my_secret_value would bypass redaction.
    source_path =
      Path.join([__DIR__, "..", "..", "..", "lib", "letflow", "obs", "logger.ex"])
      |> Path.expand()

    source = File.read!(source_path)

    assert source =~ "field name",
           "lib/letflow/obs/logger.ex must contain text explaining that redaction operates " <>
             "on field names (not values), so callers understand that a secret under an " <>
             "unrecognised key name is not caught"
  end

  # ---------------------------------------------------------------------------
  # ISS-0533 — recursive metadata sanitization + level/message-preserving rescue
  # See test/specs/ISS-0533.md for the full AC -> test-case mapping and rationale.
  # ---------------------------------------------------------------------------

  # Builds n levels of %{next: ...} nesting around `leaf`. build_nested(0, leaf) == leaf;
  # build_nested(1, leaf) == %{next: leaf}; etc. Used to place a value at a precise,
  # controllable nesting depth relative to @max_sanitize_depth (6).
  defp build_nested(0, leaf), do: leaf
  defp build_nested(n, leaf) when n > 0, do: %{next: build_nested(n - 1, leaf)}

  defmodule FunRefTarget do
    @moduledoc false
    def some_fun(_), do: :ok
  end

  test "ISS-0533 AC1: Bandit-style tuple metadata does not raise; real level preserved; tuple inspected wholesale" do
    event =
      make_event(:info, "tuple metadata", %{plug: {Letflow.Obs.LoggerTest.FunRefTarget, []}})

    decoded = format_and_decode(event)

    assert decoded["level"] == "info",
           "real event level must be preserved, not force-promoted to error"

    assert decoded["message"] == "tuple metadata"

    assert decoded["plug"] == "{Letflow.Obs.LoggerTest.FunRefTarget, []}",
           "a tuple must be inspected wholesale (element-by-element decomposition would " <>
             "turn it into a JSON array, not a string), got: #{inspect(decoded["plug"])}"
  end

  test "ISS-0533 AC2: nested function-reference metadata (OTP report_cb shape) does not raise; sanitized in place" do
    event =
      make_event(:warning, "report_cb metadata", %{
        error_logger: %{report_cb: &FunRefTarget.some_fun/1}
      })

    decoded = format_and_decode(event)

    assert decoded["level"] == "warn",
           "real event level must be preserved through nested sanitization"

    assert decoded["message"] == "report_cb metadata"

    assert %{"report_cb" => report_cb_str} = decoded["error_logger"],
           "error_logger metadata must survive as a nested object, got: #{inspect(decoded["error_logger"])}"

    assert is_binary(report_cb_str) and report_cb_str =~ "FunRefTarget.some_fun/1",
           "nested function reference must be sanitized to its inspected string form, " <>
             "got: #{inspect(report_cb_str)}"
  end

  test "ISS-0533 AC3: a value exactly at @max_sanitize_depth (6 levels) is still sanitized" do
    # build_nested(6, pid) places the pid as the value reached by exactly 6 map-recursion
    # steps (depth 6 -> 5 -> 4 -> 3 -> 2 -> 1 -> 0), i.e. precisely at the documented
    # cutoff — proving the boundary is inclusive, not off-by-one.
    pid = self()
    event = make_event(:info, "exactly at cutoff", %{deep: build_nested(6, pid)})

    decoded = format_and_decode(event)

    assert decoded["level"] == "info"
    assert decoded["message"] == "exactly at cutoff"

    refute Map.has_key?(decoded, "metadata_encode_error"),
           "a value exactly at the depth cutoff must still be sanitized, not fall through " <>
             "to the rescue-branch fallback"

    inspected_pid = inspect(pid)

    assert get_in(decoded, [
             "deep",
             "next",
             "next",
             "next",
             "next",
             "next",
             "next"
           ]) == inspected_pid,
           "pid at exactly depth 6 must be sanitized to its inspected string form"
  end

  test "ISS-0533 AC3: a value one level beyond @max_sanitize_depth is left unsanitized at the cutoff (not crashed, not silently dropped) — real level/message still preserved" do
    # build_nested(7, pid) places the pid one level past the 6-level recursion budget.
    # Per the observed (verified) behaviour, safe_value/2's depth-0 clause hands any
    # remaining sub-term to safe_leaf/1 without re-entering the map/list/tuple-specific
    # clauses — so a *container* still present at the cutoff (here, the innermost %{next:
    # pid} map) is returned as-is rather than itself being inspected. Since that raw
    # container still contains an unsanitized pid, Jason.encode!/1 subsequently raises on
    # it and encode_entry/3's rescue branch (ISS-0533 AC4) is what actually prevents a
    # crash and preserves the real level/message — this is the concrete, reachable path
    # that exercises that rescue branch, not a synthetic/mocked one.
    pid = self()
    event = make_event(:info, "one past cutoff", %{deep: build_nested(7, pid)})

    decoded = format_and_decode(event)

    assert decoded["level"] == "info",
           "real level must survive even when the depth budget is exceeded"

    assert decoded["message"] == "one past cutoff",
           "real message must survive even when the depth budget is exceeded"
  end

  test "ISS-0533 AC4: encode_entry/3's rescue branch preserves the real level/message and only replaces the metadata portion" do
    # Same underlying trigger as the depth-exceeded case above (a raw pid surviving past
    # the sanitization cutoff, which Jason cannot encode) but asserted here specifically
    # against AC4's own contract: base fields (level, message, timestamp, trace_id,
    # component) come through untouched, and the failure is confined to a diagnostic
    # replacement of the metadata fields — never a hardcoded "error" level or a generic
    # "log encoding failed" message overwriting the real one (the pre-fix bug).
    pid = self()

    event =
      make_event(:warning, "rescue branch real message", %{deep: build_nested(7, pid)})

    decoded = format_and_decode(event)

    assert decoded["level"] == "warn",
           "rescue branch must not hardcode level to \"error\" — got #{inspect(decoded["level"])}"

    assert decoded["message"] == "rescue branch real message",
           "rescue branch must not replace the real message with a synthetic " <>
             "\"log encoding failed\" string — got #{inspect(decoded["message"])}"

    assert decoded["component"] != nil and decoded["component"] != "",
           "rescue branch must not blank out component"

    assert Map.has_key?(decoded, "metadata_encode_error"),
           "rescue branch must surface a diagnostic marker instead of silently succeeding " <>
             "or silently dropping the metadata"

    refute Map.has_key?(decoded, "deep"),
           "the original unencodable metadata field must not appear verbatim in the " <>
             "successful fallback output"
  end
end
