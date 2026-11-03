defmodule Letflow.LoginDiscovery.Notifier.SmtpSinkRegistrationTest do
  @moduledoc """
  ISS-1019 (Q-1001 / GH #2288). `SmtpSink` used to insert a connection record with
  `handler: nil` and store the handler pid in a second step, so a reader (for example
  `open_connections/1` followed by `await_closed/2`) could see an open record that
  `await_closed/2` could not monitor. The record and the handler pid are now registered in
  one Agent call.

  The invariant pinned here: every record visible with `open?: true` has a pid handler.
  A watcher process spins on `SmtpSink.transcripts/1` (no sleeps) while the test opens
  `@connections` connections against a `:hang` sink, with busy processes widening the
  scheduling window. Fail-first: on the old sink the watcher observes records with
  `handler: nil`.

  `async: false`: it saturates the schedulers on purpose.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Test.SmtpHelpers, as: S
  alias Letflow.Test.SmtpSink

  @connections 300

  test "no open connection record is ever visible without its handler pid (#{@connections} connects)" do
    sink = S.start_sink!(:hang)
    parent = self()

    busy =
      for _ <- 1..System.schedulers_online() do
        spawn_link(fn -> spin() end)
      end

    watcher =
      spawn_link(fn ->
        receive do
          :start -> :ok
        end

        send(parent, {:watched, watch(sink, 0, 0)})
      end)

    send(watcher, :start)

    sockets =
      for _ <- 1..@connections do
        {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, sink.port, [:binary, active: false])
        socket
      end

    # Every accept has been recorded once the sink reports all connections.
    assert S.wait_until(fn -> SmtpSink.connections(sink) == @connections end)

    send(watcher, :stop)
    assert_receive {:watched, {bad, seen}}, 10_000

    Enum.each(busy, &Process.unlink/1)
    Enum.each(busy, &Process.exit(&1, :kill))

    assert bad == 0,
           "#{bad} reads saw an open connection record with handler: nil (of #{seen} reads)"

    assert seen > 0
    assert Enum.all?(SmtpSink.transcripts(sink), &is_pid(&1.handler))

    Enum.each(sockets, &:gen_tcp.close/1)
    assert :ok = SmtpSink.await_closed(sink, 10_000)
  end

  defp spin, do: spin()

  # Reads until told to stop; counts reads that saw an open record without a pid handler.
  defp watch(sink, bad, seen) do
    receive do
      :stop -> {bad, seen}
    after
      0 ->
        violations =
          Enum.count(SmtpSink.transcripts(sink), &(&1.open? and not is_pid(&1.handler)))

        watch(sink, bad + violations, seen + 1)
    end
  end
end
