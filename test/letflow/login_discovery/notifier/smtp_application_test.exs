defmodule Letflow.LoginDiscovery.Notifier.SmtpApplicationTest do
  @moduledoc """
  REQ-441 condition (2): starting the `:gen_smtp` application opens no listening
  socket. Evidence is two-fold and independent:

    * structural: the `gen_smtp` application spec has no `mod` (no application
      callback, so no supervisor or listener is started by it), and
      `:ranch.info/0` (its only dependency, which hosts listeners for
      `gen_smtp_server`) reports zero listeners afterwards;
    * behavioural: the set of OS sockets in the `listen` state is identical before
      and after `Application.ensure_all_started(:gen_smtp)` (the apps are stopped
      first so the start is real, not a no-op).
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  test "starting :gen_smtp opens no listening socket" do
    assert Application.spec(:gen_smtp, :mod) in [nil, []]

    :ok = stop_app(:gen_smtp)
    :ok = stop_app(:ranch)
    before_ports = listening_ports()

    try do
      assert {:ok, started} = Application.ensure_all_started(:gen_smtp)
      assert :gen_smtp in started
      assert :ranch in started

      assert listening_ports() == before_ports
      assert :ranch.info() == %{}
    after
      {:ok, _} = Application.ensure_all_started(:gen_smtp)
    end
  end

  defp stop_app(app) do
    case Application.stop(app) do
      :ok -> :ok
      {:error, {:not_started, ^app}} -> :ok
    end
  end

  # Sockets whose inet status includes :listen. :prim_inet.getstatus/1 is the
  # primitive behind :inet.getstat/2's status flags; there is no public API that
  # lists listening sockets.
  defp listening_ports do
    for port <- :erlang.ports(),
        Port.info(port, :name) == {:name, ~c"tcp_inet"},
        {:ok, flags} <- [:prim_inet.getstatus(port)],
        :listen in flags,
        into: MapSet.new() do
      port
    end
  end
end
