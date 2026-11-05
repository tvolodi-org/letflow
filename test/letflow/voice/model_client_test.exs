defmodule Letflow.Voice.ModelClientTest do
  @moduledoc "REQ-740 AC3, AC4, AC6 for the model client, against the local Letflow.WebhookTestServer."
  use ExUnit.Case, async: false
  @moduletag :unit

  import ExUnit.CaptureLog

  alias Letflow.Voice.{ModelClient, Settings}
  alias Letflow.WebhookTestServer

  @key "mq3z-model-key-REQ740"
  @sentinel "MODEL-ANSWER-SENTINEL-88"
  @system "SYSTEM-PROMPT-SENTINEL-11"
  @user "USER-TEXT-SENTINEL-22"

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

  defp settings(base, mode),
    do: %Settings.Model{model: "gpt-x", base_url: base, api_key: @key, json_mode: mode}

  defp base(server), do: "http://127.0.0.1:#{server.port}/v1"
  defp run(base, mode \\ :prompt), do: ModelClient.complete(settings(base, mode), @system, @user)

  defp answer(content, extra \\ %{}) do
    msg = Map.merge(%{"role" => "assistant", "content" => content}, Map.get(extra, :message, %{}))

    Jason.encode!(%{
      "choices" => [%{"message" => msg, "finish_reason" => Map.get(extra, :finish, "stop")}]
    })
  end

  defp request_body do
    assert_receive {:webhook_test_server_request, req}
    {req, Jason.decode!(req.body)}
  end

  test "M1a schema mode body" do
    server = WebhookTestServer.start(200, answer("{}"))
    assert {:ok, "{}"} = run(base(server), :schema)
    {req, body} = request_body()
    assert req.path == "/v1/chat/completions"
    assert req.headers["authorization"] == "Bearer " <> @key
    rf = body["response_format"]
    assert rf["type"] == "json_schema"
    assert rf["json_schema"]["strict"] == true
    schema = rf["json_schema"]["schema"]
    assert schema["additionalProperties"] == false
    assert length(schema["required"]) == 7
    assert Enum.sort(schema["required"]) == Enum.sort(Map.keys(schema["properties"]))
  end

  test "M1b object mode body" do
    server = WebhookTestServer.start(200, answer("{}"))
    assert {:ok, _} = run(base(server), :object)
    {_req, body} = request_body()
    assert body["response_format"] == %{"type" => "json_object"}
  end

  test "M1c prompt mode body has no response_format" do
    server = WebhookTestServer.start(200, answer("{}"))
    assert {:ok, _} = run(base(server), :prompt)
    {_req, body} = request_body()
    refute Map.has_key?(body, "response_format")
  end

  test "M2 messages are system then user" do
    server = WebhookTestServer.start(200, answer("ok"))
    assert {:ok, "ok"} = run(base(server))
    {_req, body} = request_body()
    assert body["model"] == "gpt-x"

    assert body["messages"] == [
             %{"role" => "system", "content" => @system},
             %{"role" => "user", "content" => @user}
           ]
  end

  test "M3 content" do
    server = WebhookTestServer.start(200, answer("the content"))
    assert {:ok, "the content"} = run(base(server))
  end

  test "M4 finish_reason length is truncated" do
    server = WebhookTestServer.start(200, answer("partial", %{finish: "length"}))
    assert {:error, :truncated} = run(base(server))
  end

  test "M5 refusal" do
    server = WebhookTestServer.start(200, answer(nil, %{message: %{"refusal" => "no"}}))
    assert {:error, :refused} = run(base(server))
  end

  test "M6 non-2xx" do
    server = WebhookTestServer.start(500, answer(@sentinel))
    assert {:error, :provider_error} = run(base(server))
  end

  test "M7 unreadable body and missing content" do
    server = WebhookTestServer.start(200, "garbage " <> @sentinel)
    assert {:error, :provider_error} = run(base(server))
    server2 = WebhookTestServer.start(200, ~s({"choices":[]}))
    assert {:error, :provider_error} = run(base(server2))
  end

  test "M8 timeout" do
    server =
      WebhookTestServer.start_with_responder(fn _ ->
        Process.sleep(600)
        {200, answer("late")}
      end)

    Application.put_env(:letflow, :voice, timeout_ms: 200)
    assert {:error, :provider_timeout} = run(base(server))
  end

  test "M9 no retry" do
    server = WebhookTestServer.start(500, "x")
    assert {:error, :provider_error} = run(base(server))
    assert_receive {:webhook_test_server_request, _}
    refute_receive {:webhook_test_server_request, _}, 300
  end

  test "M10 http URL with validation on: refused, no connection" do
    Application.put_env(:letflow, :voice_url_validation_enabled, true)
    server = WebhookTestServer.start(200, answer("x"))
    assert {:error, :provider_error} = run(base(server))
    refute_receive {:webhook_test_server_request, _}, 200
  end

  test "M11 https loopback with validation on: refused before connect" do
    Application.put_env(:letflow, :voice_url_validation_enabled, true)
    server = WebhookTestServer.start(200, answer("x"))
    assert {:error, :provider_error} = run("https://127.0.0.1:#{server.port}/v1")
    refute_receive {:webhook_test_server_request, _}, 200
  end

  test "M12 sentinels absent from results, inspect and log" do
    server = WebhookTestServer.start(500, answer(@sentinel))
    log = capture_log(fn -> send(self(), {:res, run(base(server))}) end)
    assert_received {:res, res}
    out = inspect(res)

    for s <- [@sentinel, @key, "Bearer", @system, @user],
        do:
          (
            refute out =~ s
            refute log =~ s
          )

    ok = WebhookTestServer.start(200, answer("fine"))
    log2 = capture_log(fn -> send(self(), {:res, run(base(ok))}) end)
    for s <- [@key, @system, @user], do: refute(log2 =~ s)
  end

  test "X2 no module outside lib/letflow/voice references Letflow.Voice" do
    hits =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.starts_with?(&1, "lib/letflow/voice/"))
      |> Enum.filter(&(File.read!(&1) =~ "Letflow.Voice"))

    assert hits == []
  end

  test "X3 voice files reference no Repo, Principal, Logger or tenant (INV-1/INV-4 evidence)" do
    for f <- Path.wildcard("lib/letflow/voice/*.ex") do
      src = File.read!(f)

      for word <- ["Repo", "Principal", "Logger", "tenant"],
          do: refute(src =~ word, "#{f} mentions #{word}")
    end
  end
end
