defmodule Letflow.LoginDiscovery.Notifier.SmtpSinkAwaitClosedTest do
  @moduledoc """
  ISS-0996 (Q-978 / GH #2259). `Smtp.deliver_tenant_list/2` returns as soon as the client
  has *sent* QUIT, possibly before the sink handler has recorded it. Readers of the
  sink's transcript must call `SmtpSink.await_closed/2` first. This suite pins that:

    * the formerly racy delivery-then-assert-order sequence, run back-to-back `@loops`
      times, never observes a transcript missing its tail;
    * `await_closed/2` is deterministic (no sleep) and fails loudly on a connection that
      never closes.

  `async: false`: application env, OS env and the sink (same as the suites it guards).
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.LoginDiscovery.Notifier.Smtp
  alias Letflow.Test.SmtpHelpers, as: S
  alias Letflow.Test.SmtpSink

  @recipient "typed.address+tag@example.org"
  @tenants [%{slug: "acme-co", display_name: "Acme Corp"}]
  @loops 50

  test "QUIT is the last recorded command and the connection closed, #{@loops} deliveries in a row" do
    for i <- 1..@loops do
      sink = S.start_sink!(:accept)
      S.configure_smtp!(sink, [])

      assert Smtp.deliver_tenant_list(@recipient, @tenants) == :ok
      assert :ok = SmtpSink.await_closed(sink)

      assert [%{commands: commands, open?: false}] = SmtpSink.transcripts(sink),
             "iteration #{i}: transcript not closed"

      assert List.first(commands) == "QUIT", "iteration #{i}: commands #{inspect(commands)}"
      assert Enum.count(commands, &(&1 == "DATA")) == 1
    end
  end

  test "await_closed/2 raises a clear error when a connection never closes, and returns once it does" do
    sink = S.start_sink!(:hang)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, sink.port, [:binary, active: false])
    assert S.wait_until(fn -> SmtpSink.open_connections(sink) == 1 end)

    error = assert_raise RuntimeError, fn -> SmtpSink.await_closed(sink, 100) end
    assert error.message =~ "still open after 100ms"

    :gen_tcp.close(socket)
    assert :ok = SmtpSink.await_closed(sink, 5_000)
    assert SmtpSink.open_connections(sink) == 0
  end

  test "await_closed/2 with no connection is a no-op" do
    assert :ok = SmtpSink.await_closed(S.start_sink!(:accept))
  end
end
