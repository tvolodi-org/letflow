defmodule Letflow.Security.OutboundDispatchProbesTest do
  @moduledoc """
  G-06 of the team repo's `docs/security-coverage.md` §4: the **common
  dispatch-time probes** for outbound HTTP channels -- SSRF refusal, redirect
  handling and error sanitisation.

  `test/letflow/security/outbound_http_inventory_test.exs` proves, over the
  AST, that every outbound channel is classified and that a tenant-influenced
  one reaches the shared validator. This file proves the *behaviour* those
  rules assume, and it does so with ONE probe implementation that every
  channel is run through, so a channel added later is probed the same way
  instead of getting its own hand-written test.

  The three common probes:

    * **P1 SSRF refusal** -- a URL whose host is a blocked private range is
      refused AT THE DISPATCH POINT, and no socket is opened. The proof that
      no socket was opened is structural: the probe points the channel at a
      real local listener and asserts the listener received nothing.
    * **P2 redirect not followed** -- a 3xx answered by the target is NOT
      followed. The probe starts a second listener and points the first
      listener's `Location` header at it; the second listener must stay
      silent, and the channel must report the 3xx itself.
    * **P3 error sanitisation** -- a transport failure must not carry the
      request URL. The probe puts canaries in the URL userinfo, query and
      fragment (the parts that can carry a credential) and asserts none of
      them reaches the channel's failure value.

  ## Why the validation seam is switched off in P2 and P3

  The shared validator accepts only `https`, so a plain-HTTP local listener
  cannot be reached while the gate is on. P2 and P3 therefore switch the
  channel's own documented test seam off (the same
  `:service_task_ssrf_validation_enabled` /
  `:voice_url_validation_enabled` flags the product's own tests use) and
  switch it back in `on_exit`. The seam changes the URL CHECK, not the
  redirect or error behaviour under test; P1 always runs with the gate ON.

  `async: false` because the seam is a global application environment.

  ## Cost

  `@moduletag probe_cost_s: 5` -- eight short tests, no database, no
  external network (every peer is a listener on 127.0.0.1), no clock, no
  retry.
  """

  use ExUnit.Case, async: false

  @moduletag :security_probe
  @moduletag :unit
  @moduletag probe_cost_s: 5

  alias Letflow.Engine.ServiceTask.Config, as: ServiceTaskConfig
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Voice.Http, as: VoiceHttp

  @canary "CANARYOUTBOUND9f3a"

  @service_task_config %ServiceTaskConfig{
    node_id: "g06-probe",
    route_kind: :inline_url,
    method: :POST,
    timeout_ms: 1_000,
    retry_limit: 0
  }

  # ── the channels ────────────────────────────────────────────────────────────────────────────
  # A channel adapter says how to dispatch a URL through the channel, what a
  # refusal looks like, and which test seam turns the URL check off. The
  # probes below take an adapter, so a channel added later joins the same
  # three probes.
  defp service_task_channel do
    %{
      name: :service_task,
      seam_flag: :service_task_ssrf_validation_enabled,
      refusal: {:request_build_error, :target_url_not_allowed},
      dispatch: fn url -> ServiceTaskDispatcher.http_transport(@service_task_config, url, nil) end
    }
  end

  defp voice_channel do
    %{
      name: :voice,
      seam_flag: :voice_url_validation_enabled,
      refusal: {:error, :provider_error},
      dispatch: fn url -> VoiceHttp.post(url, [], "application/json", "{}", 2_000) end
    }
  end

  # ── P1: SSRF refusal at the dispatch point ──────────────────────────────────────────────────

  describe "P1: a private-range URL is refused at dispatch" do
    test "service_task: a loopback URL is refused and no connection is opened" do
      assert_refuses_private_url(service_task_channel())
    end

    test "voice: a loopback URL is refused and no connection is opened" do
      assert_refuses_private_url(voice_channel())
    end

    test "service_task: the cloud metadata address is refused" do
      assert service_task_channel().refusal ==
               service_task_channel().dispatch.("https://169.254.169.254/latest/meta-data/")
    end

    test "voice: the cloud metadata address is refused" do
      assert voice_channel().refusal ==
               voice_channel().dispatch.("https://169.254.169.254/latest/meta-data/")
    end
  end

  # ── P2: a redirect is not followed ──────────────────────────────────────────────────────────

  describe "P2: a 3xx is not followed" do
    test "service_task: the channel reports the 3xx and the redirect target is never asked" do
      assert_does_not_follow_redirect(service_task_channel())
    end

    test "voice: the channel reports the 3xx and the redirect target is never asked" do
      assert_does_not_follow_redirect(voice_channel())
    end
  end

  # ── P3: a transport failure does not carry the URL ──────────────────────────────────────────

  describe "P3: a transport failure carries no part of the URL" do
    test "service_task: the canaries in userinfo, query and fragment do not reach the error" do
      assert_error_carries_no_url(service_task_channel())
    end

    test "voice: the canaries in userinfo, query and fragment do not reach the error" do
      assert_error_carries_no_url(voice_channel())
    end
  end

  # ── the common probes ───────────────────────────────────────────────────────────────────────

  # P1: the channel refuses a loopback URL and never opens a socket to it.
  defp assert_refuses_private_url(channel) do
    %{port: port} = start_server(fn _path -> {200, [], "ok"} end)

    url = "https://127.0.0.1:#{port}/hook"

    assert channel.refusal == channel.dispatch.(url)
    refute_received {:outbound_probe_request, _path}
  end

  # P2: a 3xx is reported as a 3xx, and the host it points at is never asked.
  defp assert_does_not_follow_redirect(channel) do
    %{port: target_port} = start_server(fn _path -> {200, [], "followed"} end)

    %{port: port} =
      start_server(fn _path ->
        {302, [{"location", "http://127.0.0.1:#{target_port}/followed"}], ""}
      end)

    with_seam_off(channel, fn ->
      outcome = channel.dispatch.("http://127.0.0.1:#{port}/start")

      # the channel reports the redirect itself, not the target's answer
      assert status_of(outcome) == 302
      refute_received {:outbound_probe_request, "/followed"}
    end)
  end

  # P3: a transport failure carries no part of the URL.
  defp assert_error_carries_no_url(channel) do
    port = closed_port()
    url = "http://user:#{@canary}@127.0.0.1:#{port}/hook?token=#{@canary}##{@canary}"

    with_seam_off(channel, fn ->
      outcome = channel.dispatch.(url)

      refute inspect(outcome) =~ @canary
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  # The status the channel reports, whichever shape it uses.
  defp status_of({:http, status, _body}), do: status
  defp status_of({:ok, status, _body}), do: status
  defp status_of(other), do: other

  # Switch the channel's own test seam off for the duration of the probe and
  # put the previous value back afterwards.
  defp with_seam_off(channel, fun) do
    previous = Application.get_env(:letflow, channel.seam_flag)
    Application.put_env(:letflow, channel.seam_flag, false)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:letflow, channel.seam_flag)
      else
        Application.put_env(:letflow, channel.seam_flag, previous)
      end
    end
  end

  # A port that is bound and immediately closed, so a connection to it is
  # refused by the OS (no external host, no waiting for a timeout).
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # A real local HTTP/1.1 listener on 127.0.0.1. Every accepted request is
  # sent to the test process as `{:outbound_probe_request, path}`, so a probe
  # can assert that the channel really did (or really did not) talk to it.
  defp start_server(responder) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    owner = self()
    pid = spawn_link(fn -> accept_loop(listen, responder, owner) end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    %{port: port, pid: pid}
  end

  defp accept_loop(listen, responder, owner) do
    case :gen_tcp.accept(listen, 15_000) do
      {:ok, socket} ->
        handle_connection(socket, responder, owner)
        accept_loop(listen, responder, owner)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_connection(socket, responder, owner) do
    path = read_path(socket)
    send(owner, {:outbound_probe_request, path})
    {status, headers, body} = responder.(path)
    :gen_tcp.send(socket, response_bytes(status, headers, body))
    :gen_tcp.close(socket)
  end

  defp read_path(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} ->
        [request_line | _rest] = String.split(chunk, "\r\n")
        [_method, path | _tail] = String.split(request_line, " ")
        path

      {:error, _reason} ->
        ""
    end
  end

  defp response_bytes(status, headers, body) do
    header_lines =
      Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)

    "HTTP/1.1 #{status} Response\r\n" <>
      header_lines <>
      "content-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n" <>
      "\r\n" <>
      body
  end
end
