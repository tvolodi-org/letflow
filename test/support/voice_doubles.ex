defmodule Letflow.Support.VoiceDoubles do
  @moduledoc """
  REQ-741: provider doubles of the stock voice routes. `install!/1` points `:voice_clients` at the
  doubles below and sets the platform voice settings; the doubles send what they were called with to
  the test process (`{:speech, content_type, lang, bytes}`, `{:model, prompt, text}`) and answer the
  canned result: `{:ok, text}`, `{:error, atom}` or `:raise`.
  """

  @key "sk-test-secret-key-0001"
  @sentinel "PROVIDER-BODY-SENTINEL"

  def api_key, do: @key
  def sentinel, do: @sentinel

  @doc """
  Options: `:speech` and `:model` (canned results), `:speech_on` and `:model_on` (settings, default true).
  """
  def install!(opts \\ []) do
    orig_clients = Application.get_env(:letflow, :voice_clients)
    orig_voice = Application.get_env(:letflow, :voice)
    orig_double = Application.get_env(:letflow, :voice_double)

    Application.put_env(:letflow, :voice_clients,
      speech: Letflow.Support.VoiceDoubles.Speech,
      model: Letflow.Support.VoiceDoubles.Model
    )

    Application.put_env(:letflow, :voice_double, %{
      pid: self(),
      speech: Keyword.get(opts, :speech, {:ok, "transcript"}),
      model: Keyword.get(opts, :model, {:ok, answer()})
    })

    Application.put_env(:letflow, :voice, settings(opts))

    ExUnit.Callbacks.on_exit(fn ->
      restore(:voice_clients, orig_clients)
      restore(:voice, orig_voice)
      restore(:voice_double, orig_double)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:letflow, key)
  defp restore(key, value), do: Application.put_env(:letflow, key, value)

  defp settings(opts) do
    speech =
      if Keyword.get(opts, :speech_on, true),
        do: [
          stt_provider: "openai_transcriptions",
          stt_model: "stt-m",
          stt_base_url: "https://stt.example.test/v1",
          stt_api_key: @key
        ],
        else: []

    model =
      if Keyword.get(opts, :model_on, true),
        do: [
          llm_provider: "openai_chat",
          llm_model: "llm-m",
          llm_base_url: "https://llm.example.test/v1",
          llm_api_key: @key
        ],
        else: []

    speech ++ model
  end

  @doc "A well-formed model answer (JSON text); `overrides` replace keys."
  def answer(overrides \\ %{}) do
    %{
      "kind" => "receipt",
      "item_codes" => [],
      "location_words" => nil,
      "location_code" => nil,
      "to_location_words" => nil,
      "to_location_code" => nil,
      "quantity" => nil
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  def respond(%{} = state, key, call) do
    send(state.pid, call)

    case Map.fetch!(state, key) do
      :raise -> raise "double raised #{@sentinel}"
      result -> result
    end
  end

  defmodule Speech do
    @moduledoc false
    def transcribe(_settings, audio, content_type, lang) do
      state = Application.fetch_env!(:letflow, :voice_double)

      Letflow.Support.VoiceDoubles.respond(
        state,
        :speech,
        {:speech, content_type, lang, byte_size(audio)}
      )
    end
  end

  defmodule Model do
    @moduledoc false
    def complete(_settings, prompt, text) do
      state = Application.fetch_env!(:letflow, :voice_double)
      Letflow.Support.VoiceDoubles.respond(state, :model, {:model, prompt, text})
    end
  end
end
