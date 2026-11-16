defmodule Letflow.Voice.SpeechClient do
  @moduledoc """
  REQ-740 / REQ-863: speech-to-text client. Supports two provider kinds:
  - `:openai_transcriptions`: `POST <base URL>/audio/transcriptions`, bearer auth,
    multipart fields model/language/file.
  - `:elevenlabs`: `POST <base URL>/speech-to-text`, xi-api-key header auth,
    multipart fields model_id/language_code/tag_audio_events/file.

  Source of any error: `speech` (the route of REQ-741 attaches it; the atoms here are
  bare). One call, one request, no retry, 60 s limit from
  `Letflow.Voice.Settings.timeout_ms/0`. See `Letflow.Voice.Http` for INV-4 / INV-9.
  """

  alias Letflow.Voice.{Http, Settings}

  @spec transcribe(Settings.Speech.t(), binary(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :provider_error | :provider_timeout}
  def transcribe(%Settings.Speech{} = s, audio, content_type, lang)
      when is_binary(audio) and is_binary(content_type) and is_binary(lang) do
    if safe_token?(content_type) and safe_token?(lang) do
      case s.provider do
        :openai_transcriptions -> transcribe_openai(s, audio, content_type, lang)
        :elevenlabs -> transcribe_elevenlabs(s, audio, content_type, lang)
      end
    else
      {:error, :provider_error}
    end
  end

  def transcribe(_settings, _audio, _content_type, _lang), do: {:error, :provider_error}

  defp transcribe_openai(s, audio, content_type, lang) do
    boundary = "lf" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    body = multipart_openai(boundary, s.model, lang, audio, content_type)
    url = String.trim_trailing(s.base_url, "/") <> "/audio/transcriptions"
    headers = [{"authorization", "Bearer " <> s.api_key}]

    call(url, headers, boundary, body)
  end

  defp transcribe_elevenlabs(s, audio, content_type, lang) do
    boundary = "lf" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    body = multipart_elevenlabs(boundary, s.model, lang, audio, content_type)
    url = String.trim_trailing(s.base_url, "/") <> "/speech-to-text"
    headers = [{"xi-api-key", s.api_key}]

    call(url, headers, boundary, body)
  end

  defp call(url, headers, boundary, body) do
    case Http.post(
           url,
           headers,
           "multipart/form-data; boundary=" <> boundary,
           body,
           Settings.timeout_ms()
         ) do
      {:ok, status, resp} when status >= 200 and status < 300 -> parse(resp)
      {:ok, _status, _resp} -> {:error, :provider_error}
      {:error, _} = error -> error
    end
  end

  defp parse(resp) do
    case Jason.decode(resp) do
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
      _ -> {:error, :provider_error}
    end
  end

  # No CR, LF, quote or space: the value goes into a header or a form value.
  defp safe_token?(value), do: Regex.match?(~r/\A[A-Za-z0-9.+\/_-]+\z/, value)

  defp audio_ext(content_type) do
    cond do
      String.contains?(content_type, "m4a") or String.contains?(content_type, "mp4") -> "m4a"
      String.contains?(content_type, "webm") -> "webm"
      true -> "bin"
    end
  end

  defp multipart_openai(boundary, model, lang, audio, content_type) do
    ext = audio_ext(content_type)

    [
      field(boundary, "model", model),
      field(boundary, "language", lang),
      "--#{boundary}\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"audio.#{ext}\"\r\n",
      "Content-Type: #{content_type}\r\n\r\n",
      audio,
      "\r\n--#{boundary}--\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp multipart_elevenlabs(boundary, model, lang, audio, content_type) do
    ext = audio_ext(content_type)

    [
      field(boundary, "model_id", model),
      field(boundary, "language_code", lang),
      field(boundary, "tag_audio_events", "false"),
      "--#{boundary}\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"audio.#{ext}\"\r\n",
      "Content-Type: #{content_type}\r\n\r\n",
      audio,
      "\r\n--#{boundary}--\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp field(boundary, name, value) do
    "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
  end
end
