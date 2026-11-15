defmodule Letflow.LoginDiscovery.Notifier.SmtpSinkRefuseTest do
  @moduledoc """
  T-1996: `NotifierNoLeakTest` "no leak: connection_refused" took 10.1 s in CI (the 10 s hard
  timeout of `Dispatch.attempt`) and the supervisor logged its brutal-kill report. The
  `:refuse_connection` sink only CLOSED its listener, so the port number was free for any other
  process on the shared host; a connect that lands on a taken port does not get a refusal.

  The sink must keep the port reserved (bound, not listening): a connect is refused at once and
  nothing else can bind the port while the sink lives.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Test.SmtpSink

  test "the refused port cannot be taken by another listener while the sink lives" do
    {:ok, sink} = SmtpSink.start(:refuse_connection)

    assert {:error, :eaddrinuse} =
             :gen_tcp.listen(sink.port, ip: {127, 0, 0, 1}, active: false)
  end

  test "a connect to the refused port is refused at once" do
    {:ok, sink} = SmtpSink.start(:refuse_connection)

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, sink.port, [active: false], 2_000)

    assert SmtpSink.connections(sink) == 0
  end
end
