defmodule Letflow.Voice.VoiceRuntimeConfigTest do
  @moduledoc "REQ-740 AC2: config/runtime.exs voice block, evaluated with RuntimeConfigEval."
  use ExUnit.Case, async: false
  @moduletag :unit
  @moduletag :slow

  alias Letflow.Test.RuntimeConfigEval, as: R

  @key_marker "voicekeymarker-9f3a"

  @vars %{
    "LETFLOW_VOICE_STT_PROVIDER" => "openai_transcriptions",
    "LETFLOW_VOICE_STT_MODEL" => "whisper-1",
    "LETFLOW_VOICE_STT_BASE_URL" => "https://stt.example/v1",
    "LETFLOW_VOICE_STT_API_KEY" => @key_marker <> "-stt",
    "LETFLOW_VOICE_LLM_PROVIDER" => "openai_chat",
    "LETFLOW_VOICE_LLM_MODEL" => "gpt-x",
    "LETFLOW_VOICE_LLM_BASE_URL" => "https://llm.example/v1",
    "LETFLOW_VOICE_LLM_API_KEY" => @key_marker <> "-llm",
    "LETFLOW_VOICE_LLM_JSON_MODE" => "schema"
  }

  setup do
    R.isolate_env()
    :ok
  end

  defp voice(vars) do
    {{:ok, config}, stderr} = R.evaluate(vars)
    {config[:letflow][:voice], config, stderr}
  end

  test "R1 nine variables land under their keys" do
    {v, _config, _stderr} = voice(R.valid_base() |> Map.merge(@vars))

    assert v[:stt_provider] == "openai_transcriptions"
    assert v[:stt_model] == "whisper-1"
    assert v[:stt_base_url] == "https://stt.example/v1"
    assert v[:stt_api_key] == @key_marker <> "-stt"
    assert v[:llm_provider] == "openai_chat"
    assert v[:llm_model] == "gpt-x"
    assert v[:llm_base_url] == "https://llm.example/v1"
    assert v[:llm_api_key] == @key_marker <> "-llm"
    assert v[:llm_json_mode] == "schema"
    assert v[:timeout_ms] == 60_000
  end

  test "R2 none set: every value nil, timeout 60000" do
    {v, _config, _stderr} = voice(R.valid_base())
    assert Keyword.delete(v, :timeout_ms) |> Keyword.values() |> Enum.all?(&is_nil/1)
    assert length(Keyword.keys(v)) == 10
    assert v[:timeout_ms] == 60_000
  end

  test "R3 no other letflow key differs from a run with the nine unset" do
    {_, with_vars, _} = voice(R.valid_base() |> Map.merge(@vars))
    {_, without, _} = voice(R.valid_base())

    strip = fn c -> c |> R.merged() |> Keyword.get(:letflow) |> Keyword.delete(:voice) end

    # the master key / pepper are random per valid_base call: compare keys, not values
    assert Keyword.keys(strip.(with_vars)) == Keyword.keys(strip.(without))
  end

  test "R4 blank value is nil" do
    {v, _c, _s} = voice(R.valid_base() |> Map.merge(%{"LETFLOW_VOICE_STT_MODEL" => "   "}))
    assert v[:stt_model] == nil
  end

  test "R5 key marker is not in stderr" do
    {_v, _c, stderr} = voice(R.valid_base() |> Map.merge(@vars))
    refute stderr =~ @key_marker
  end
end
