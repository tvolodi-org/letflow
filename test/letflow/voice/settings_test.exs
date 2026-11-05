defmodule Letflow.Voice.SettingsTest do
  @moduledoc "REQ-740 AC1 (settings) and the inspect half of AC3 (INV-4)."
  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Voice.Settings

  @key "zq9k-secret-key-REQ740"

  setup do
    original = Application.get_env(:letflow, :voice)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:letflow, :voice)
  defp restore(v), do: Application.put_env(:letflow, :voice, v)

  defp put(cfg), do: Application.put_env(:letflow, :voice, cfg)

  defp stt(over \\ []) do
    Keyword.merge(
      [
        stt_provider: "openai_transcriptions",
        stt_model: "whisper-1",
        stt_base_url: "https://stt.example/v1",
        stt_api_key: @key
      ],
      over
    )
  end

  defp llm(over \\ []) do
    Keyword.merge(
      [
        llm_provider: "openai_chat",
        llm_model: "gpt-x",
        llm_base_url: "https://llm.example/v1",
        llm_api_key: @key
      ],
      over
    )
  end

  test "S1 speech ok" do
    put(stt())

    assert {:ok,
            %Settings.Speech{
              model: "whisper-1",
              base_url: "https://stt.example/v1",
              api_key: @key
            }} =
             Settings.speech()
  end

  for field <- [:stt_provider, :stt_model, :stt_base_url, :stt_api_key] do
    test "S2-5 speech off when #{field} is missing" do
      put(stt([{unquote(field), nil}]))
      assert Settings.speech() == :off
      put(stt([{unquote(field), ""}]))
      assert Settings.speech() == :off
    end
  end

  test "S6 speech unknown provider" do
    put(stt(stt_provider: "elevenlabs"))
    assert Settings.speech() == :off
  end

  test "S7 model ok, json mode unset gives prompt" do
    put(llm())
    assert {:ok, %Settings.Model{json_mode: :prompt, model: "gpt-x"}} = Settings.model()
  end

  for field <- [:llm_provider, :llm_model, :llm_base_url, :llm_api_key] do
    test "S8-11 model off when #{field} is missing" do
      put(llm([{unquote(field), nil}]))
      assert Settings.model() == :off
    end
  end

  test "S12 model unknown provider" do
    put(llm(llm_provider: "anthropic"))
    assert Settings.model() == :off
  end

  test "S13 unknown json mode is off" do
    put(llm(llm_json_mode: "yaml"))
    assert Settings.model() == :off
  end

  test "S14 each valid json mode" do
    for {s, a} <- [{"schema", :schema}, {"object", :object}, {"prompt", :prompt}] do
      put(llm(llm_json_mode: s))
      assert {:ok, %{json_mode: ^a}} = Settings.model()
    end
  end

  test "S15 nothing set: both off, default timeout" do
    Application.delete_env(:letflow, :voice)
    assert Settings.speech() == :off
    assert Settings.model() == :off
    assert Settings.timeout_ms() == 60_000
  end

  test "S16 inspect hides the key and its first four characters" do
    put(stt() ++ llm())
    {:ok, sp} = Settings.speech()
    {:ok, md} = Settings.model()

    for struct <- [sp, md] do
      out = inspect(struct)
      refute out =~ @key
      refute out =~ String.slice(@key, 0, 4)
    end
  end
end
