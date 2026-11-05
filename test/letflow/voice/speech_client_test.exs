defmodule Letflow.Voice.SpeechClientTest do
  @moduledoc "REQ-740 AC3-AC5 for the speech client, against the local Letflow.WebhookTestServer."
  use ExUnit.Case, async: false
  @moduletag :unit

  import ExUnit.CaptureLog

  alias Letflow.Voice.{Settings, SpeechClient}
  alias Letflow.WebhookTestServer

  @key "kq7x-speech-key-REQ740"
  @sentinel "PROVIDER-ANSWER-SENTINEL-77"
  @audio "AUDIO-BYTES-SENTINEL-55"

  setup do
    orig_voice = Application.get_env(:letflow, :voice)
    orig_flag = Application.get_env(:letflow, :voice_url_validation_enabled)
    Application.put_env(:letflow, :voice_url_validation_enabled, false)
    Application.put_env(:letflow, :voice, timeout_ms: 2_000)

    on_exit(fn ->
      if orig_voice,
        do: Application.put_env(:letflow, :voice, orig_voice),
        else: Application.delete_env(:letflow, :voice)

      if is_nil(orig_flag),
        do: Application.delete_env(:letflow, :voice_url_validation_enabled),
        else: Application.put_env(:letflow, :voice_url_validation_enabled, orig_flag)
    end)

    :ok
  end

  defp settings(base), do: %Settings.Speech{model: "whisper-1", base_url: base, api_key: @key}
  defp base(server), do: "http://127.0.0.1:#{server.port}/v1"

  defp run(server_or_base, fun \\ nil) do
    s = settings(if is_binary(server_or_base), do: server_or_base, else: base(server_or_base))
    result = SpeechClient.transcribe(s, @audio, "audio/m4a", "ru")
    if fun, do: fun.(result), else: result
  end

  test "SP1 one POST with path, bearer header and multipart parts" do
    server = WebhookTestServer.start(200, ~s({"text":"hello"}))
    assert {:ok, "hello"} = run(server)
    assert_receive {:webhook_test_server_request, req}
    assert req.method == "POST"
    assert req.path == "/v1/audio/transcriptions"
    assert req.headers["authorization"] == "Bearer " <> @key
    assert req.headers["content-type"] =~ "multipart/form-data; boundary="
    assert req.body =~ ~s(name="model"\r\n\r\nwhisper-1)
    assert req.body =~ ~s(name="language"\r\n\r\nru)
    assert req.body =~ ~s(name="file"; filename="audio.m4a")
    assert req.body =~ "Content-Type: audio/m4a\r\n\r\n" <> @audio
  end

  test "SP2 200 with text" do
    server = WebhookTestServer.start(200, ~s({"text":"приём 5 штук"}))
    assert {:ok, "приём 5 штук"} = run(server)
  end

  test "SP3 non-2xx" do
    server = WebhookTestServer.start(500, ~s({"text":"#{@sentinel}"}))
    assert {:error, :provider_error} = run(server)
  end

  test "SP4 non-JSON" do
    server = WebhookTestServer.start(200, "not json " <> @sentinel)
    assert {:error, :provider_error} = run(server)
  end

  test "SP5 JSON without text" do
    server = WebhookTestServer.start(200, ~s({"other":"#{@sentinel}"}))
    assert {:error, :provider_error} = run(server)
  end

  test "SP6 timeout" do
    server =
      WebhookTestServer.start_with_responder(fn _ ->
        Process.sleep(600)
        {200, ~s({"text":"late"})}
      end)

    Application.put_env(:letflow, :voice, timeout_ms: 200)
    assert {:error, :provider_timeout} = run(server)
  end

  test "SP7 exactly one request, no retry" do
    server = WebhookTestServer.start(500, "x")
    assert {:error, :provider_error} = run(server)
    assert_receive {:webhook_test_server_request, _}
    refute_receive {:webhook_test_server_request, _}, 300
  end

  test "SP8 http URL with validation on: refused, no connection" do
    Application.put_env(:letflow, :voice_url_validation_enabled, true)
    server = WebhookTestServer.start(200, ~s({"text":"x"}))
    assert {:error, :provider_error} = run(server)
    refute_receive {:webhook_test_server_request, _}, 200
  end

  test "SP9 https loopback with validation on: refused before connect" do
    Application.put_env(:letflow, :voice_url_validation_enabled, true)
    server = WebhookTestServer.start(200, ~s({"text":"x"}))
    assert {:error, :provider_error} = run("https://127.0.0.1:#{server.port}/v1")
    refute_receive {:webhook_test_server_request, _}, 200
  end

  test "SP10 validation is evaluated on every call" do
    server = WebhookTestServer.start(200, ~s({"text":"x"}))
    assert {:ok, "x"} = run(server)
    assert_receive {:webhook_test_server_request, _}
    Application.put_env(:letflow, :voice_url_validation_enabled, true)
    assert {:error, :provider_error} = run(server)
    refute_receive {:webhook_test_server_request, _}, 200
  end

  test "SP11 a 3xx is a provider error and is not followed" do
    server = WebhookTestServer.start(302, "")
    assert {:error, :provider_error} = run(server)
    assert_receive {:webhook_test_server_request, _}
    refute_receive {:webhook_test_server_request, _}, 200
  end

  test "SP12 sentinels absent from results, inspect and log" do
    server = WebhookTestServer.start(500, ~s({"text":"#{@sentinel}"}))

    log =
      capture_log(fn ->
        send(self(), {:res, run(server)})
      end)

    assert_received {:res, res}
    out = inspect(res)

    for s <- [@sentinel, @key, "Bearer", @audio],
        do:
          (
            refute out =~ s
            refute log =~ s
          )

    ok_server = WebhookTestServer.start(200, ~s({"text":"#{@sentinel}"}))
    log2 = capture_log(fn -> send(self(), {:res, run(ok_server)}) end)
    refute log2 =~ @sentinel
    refute log2 =~ @key
    refute log2 =~ @audio
  end

  test "SP13 content type with CRLF is refused without a request" do
    server = WebhookTestServer.start(200, ~s({"text":"x"}))
    s = settings(base(server))

    assert {:error, :provider_error} =
             SpeechClient.transcribe(s, @audio, "audio/m4a\r\nX: y", "ru")

    assert {:error, :provider_error} =
             SpeechClient.transcribe(s, @audio, "audio/m4a", "ru\r\nX: y")

    refute_receive {:webhook_test_server_request, _}, 200
  end
end
