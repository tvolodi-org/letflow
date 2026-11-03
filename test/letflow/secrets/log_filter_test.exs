defmodule Letflow.Secrets.LogFilterTest do
  @moduledoc """
  Tests for REQ-190 AC7's second half -- proving `Letflow.Secrets.LogFilter` (the real
  `:logger` primary filter `Letflow.Application.start/2` registers) actually intercepts
  a real `Logger` call and redacts sensitive-keyed metadata before it reaches captured
  output, not just that the underlying pure function
  (`Letflow.Secrets.Redaction.redact_map/1`, covered by `redaction_test.exs`) is
  correct in isolation. See `test/specs/REQ-190.md`.

  `async: false`: `:logger.add_primary_filter/2` is a node-global registration this
  test relies on already being in place (via `Letflow.Application.start/2`, which ran
  once at suite boot) -- no per-test mutation of the filter itself, but log capture
  ordering is safer serialized alongside every other test file that touches `Logger`
  configuration in this codebase.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Test.LoggerCollector

  require Logger

  # ISS-1038: these tests use the attributed `LoggerCollector` (own events only) instead of the
  # global `capture_log/2`, whose absence assertions ("no [REDACTED]") could see another
  # process's event. The message-only text does not show metadata, so `raw: true` is passed to
  # include the inspected event (metadata map) in the captured string. This is a
  # test-visibility mechanism only; it does not change
  # which filter runs or what it redacts -- `Letflow.Secrets.LogFilter.filter/2`
  # (registered once, node-wide, by `Letflow.Application.start/2`) has already run
  # on `log_event.meta` before the formatter ever sees it.
  test "a Logger call carrying a value under a sensitive key emits [REDACTED] in captured output, not the plaintext" do
    {_, entries} =
      LoggerCollector.capture(
        fn ->
          Logger.info("webhook signing key resolved", secret: "sh-do-not-leak-me")
        end,
        attribute_to: self(),
        raw: true
      )

    log = LoggerCollector.text(entries)

    assert log =~ "[REDACTED]"
    refute log =~ "sh-do-not-leak-me"
  end

  test "a Logger call with no sensitive-keyed metadata is unaffected" do
    {_, entries} =
      LoggerCollector.capture(
        fn ->
          Logger.info("ordinary log line", request_id: "req-123")
        end,
        attribute_to: self(),
        raw: true
      )

    log = LoggerCollector.text(entries)

    assert log =~ "ordinary log line"
    assert log =~ "req-123"
    refute log =~ "[REDACTED]"
  end

  # ISS-0772 regression: LogFilter.filter/2 redacts only `log_event.meta` --
  # never `log_event.msg` -- so a value interpolated into the message string
  # is NOT redacted, even under a sensitive-looking name. This confirms the
  # existing (narrower-than-docs-once-claimed) behavior is unchanged, and is
  # exactly why `Letflow.TenantProvisioning.MigrationReplayBoot` was changed
  # (ISS-0772 fix) to pass its variable data as metadata rather than
  # interpolating it into the message.
  test "a value interpolated into the message string is NOT redacted, even if secret-shaped" do
    secret = "sh-do-not-leak-me"

    {_, entries} =
      LoggerCollector.capture(
        fn ->
          Logger.info("webhook signing key resolved: secret=#{secret}")
        end,
        attribute_to: self(),
        raw: true
      )

    log = LoggerCollector.text(entries)

    assert log =~ secret
    refute log =~ "[REDACTED]"
  end

  test "passing the same value as metadata instead of interpolating it IS redacted" do
    secret = "sh-do-not-leak-me"

    {_, entries} =
      LoggerCollector.capture(
        fn ->
          Logger.info("webhook signing key resolved", secret: secret)
        end,
        attribute_to: self(),
        raw: true
      )

    log = LoggerCollector.text(entries)

    assert log =~ "[REDACTED]"
    refute log =~ secret
  end
end
