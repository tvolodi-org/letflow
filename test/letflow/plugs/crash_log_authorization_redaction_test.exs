defmodule Letflow.Plugs.CrashLogAuthorizationRedactionTest do
  @moduledoc """
  Regression test for ISS-0769 -- a raw `Authorization` bearer-token value leaking
  into crash/error log output via Bandit's own `Bandit.Pipeline.run/5` `catch`
  clause, which passes the fully-built `conn` (including `conn.req_headers`) into
  `Logger.error/2` metadata on any unrescued exception.

  This exercises the REAL path: a real `Bandit` listener (started by this test --
  `config/test.exs`'s `start_http: false` only gates the application's own
  supervised listener), a real HTTP request via `:httpc`, and a deliberately
  raising plug -- not just `Letflow.Secrets.Redaction.redact_map/1` in isolation.
  See `lib/letflow/design/iss0769-crash-log-header-redaction.md` §4.3.

  `async: false`: starts a real listener on an OS-assigned port and touches
  process-global `:logger` state, same rationale as
  `test/letflow/secrets/log_filter_test.exs`.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  import ExUnit.CaptureLog

  @sentinel_token "sentinel-test-bearer-token-do-not-leak"

  defmodule RaisingPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      # Prove the Authorization header really is present on the conn Bandit built,
      # before deliberately raising -- don't just assume it.
      [_ | _] = get_req_header(conn, "authorization")
      raise "boom"
    end
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:inets)

    pid = start_supervised!({Bandit, plug: RaisingPlug, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    {:ok, port: port}
  end

  test "a crash mid-request does not leak the raw Authorization bearer token into logs",
       %{port: port} do
    url = ~c"http://127.0.0.1:#{port}/"
    headers = [{~c"authorization", ~c"Bearer #{@sentinel_token}"}]

    # `formatter: {Letflow.Obs.Logger, %{}}` -- the project's REAL configured
    # `:logger_formatter` (see `config/*.exs`), not `capture_log/2`'s own default
    # text formatter. This matters: Elixir's default `Logger.Formatter` silently
    # DROPS any metadata value that is a map or list (see
    # `lib/logger/formatter.ex`'s `metadata(_, list) when is_list(list), do: nil`
    # clause upstream) -- so with the default formatter, `conn`/`req_headers`
    # metadata would never be rendered at all, and this test would vacuously pass
    # regardless of whether redaction ran. `Letflow.Obs.Logger` is the formatter
    # actually configured for this application (it serializes maps/lists to JSON),
    # so using it here is what makes this a genuine test of the real behavior.
    log =
      capture_log([formatter: {Letflow.Obs.Logger, %{}}], fn ->
        # The server-side crash means :httpc gets a connection-closed/error result --
        # we only care about what got logged server-side, not the client-side outcome.
        _ = :httpc.request(:get, {url, headers}, [], [])
        # Give the async Logger.error/2 call (emitted from the connection process,
        # across Bandit's own process boundary) a moment to land before capture_log
        # returns.
        Process.sleep(200)
      end)

    refute log =~ @sentinel_token,
           "raw sentinel bearer token must never appear in captured crash-log output"

    assert log =~ "[REDACTED]",
           "expected redaction to have actually run, not just silently dropped the metadata"

    assert log =~ "boom",
           "sanity check: the crash log line must actually have been emitted"
  end
end
