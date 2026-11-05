defmodule Letflow.Modules.Stock.VoiceService do
  @moduledoc """
  REQ-741 / GH #3879: the flow behind `POST /voice/draft` (audio) and `POST /voice/draft-text` of
  module `stock`. Validate the request, transcribe (audio only), read the caller's own active item and
  location lists, ask the language model, check the answer on the server (`VoiceDraft.check/3`).

  Read only: nothing is stored and this module never logs request data (transcript, typed text,
  prompt, catalog names). The tenant is the `prefix` the router takes from the token. Results:
  `{:ok, body}` or `{:error, {:refuse, status, reason, extras}}`, or `{:error, :not_found}` when the
  tenant schema cannot be read.

  The provider clients come from the app env `:voice_clients` (`:speech`, `:model`); only a test sets
  it. A client that raises is counted as `:provider_error`; its message is never kept (INV-4, INV-8).
  """

  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.VoiceDraft
  alias Letflow.Modules.Stock.VoicePrompt
  alias Letflow.Voice.Settings

  @max_audio_bytes 10_485_760
  @langs ~w(ru kk)

  @doc "The audio route. `params` is the parsed multipart form."
  @spec draft_audio(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def draft_audio(prefix, params) do
    with :ok <- allowed_keys(params, ["audio", "lang"]),
         {:ok, path} <- upload(params),
         {:ok, lang} <- lang(params, true),
         :ok <- size(path),
         {:ok, audio} <- read(path),
         {:ok, content_type} <- content_type(audio),
         {:ok, settings} <- speech_settings(),
         {:ok, transcript} <- transcribe(settings, audio, content_type, lang) do
      run(prefix, transcript)
    end
  end

  @doc "The typed route. `params` is the parsed JSON body."
  @spec draft_text(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def draft_text(prefix, params) do
    with :ok <- allowed_keys(params, ["text", "lang"]),
         {:ok, text} <- text(params),
         {:ok, _lang} <- lang(params, false) do
      run(prefix, text)
    end
  end

  # -- validation ----------------------------------------------------------------------------------

  defp allowed_keys(params, allowed) when is_map(params) and not is_struct(params) do
    case params |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> refuse(422, "field_not_allowed", %{"field" => to_string(key)})
    end
  end

  defp allowed_keys(_params, allowed) do
    field = if "text" in allowed, do: "text", else: "audio"
    refuse(422, "field_invalid", %{"field" => field})
  end

  defp text(%{"text" => text}) when is_binary(text) do
    if String.valid?(text) and String.trim(text) != "",
      do: {:ok, text},
      else: refuse(422, "field_invalid", %{"field" => "text"})
  end

  defp text(_), do: refuse(422, "field_invalid", %{"field" => "text"})

  defp upload(%{"audio" => %Plug.Upload{path: path}}) when is_binary(path), do: {:ok, path}
  defp upload(_), do: refuse(422, "field_invalid", %{"field" => "audio"})

  defp lang(%{"lang" => lang}, _required) when lang in @langs, do: {:ok, lang}
  defp lang(%{"lang" => _}, _required), do: refuse(422, "bad_language")
  defp lang(_params, true), do: refuse(422, "bad_language")
  defp lang(_params, false), do: {:ok, nil}

  # The part is on disk already; the size is read from the file system before any byte is read.
  defp size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @max_audio_bytes ->
        refuse(413, "audio_too_large", %{"source" => "speech"})

      {:ok, %File.Stat{}} ->
        :ok

      _ ->
        refuse(422, "field_invalid", %{"field" => "audio"})
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, audio} -> {:ok, audio}
      _ -> refuse(422, "field_invalid", %{"field" => "audio"})
    end
  end

  # The format comes from the bytes, never from the part's declared content type.
  defp content_type(<<_::binary-size(4), "ftyp", _::binary>>), do: {:ok, "audio/mp4"}
  defp content_type(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: {:ok, "audio/webm"}
  defp content_type(_), do: refuse(415, "audio_format", %{"source" => "speech"})

  # -- providers -----------------------------------------------------------------------------------

  defp speech_settings do
    case Settings.speech() do
      {:ok, settings} -> {:ok, settings}
      _ -> refuse(503, "speech_off", %{"source" => "speech"})
    end
  end

  defp transcribe(settings, audio, content_type, lang) do
    case guarded(fn -> speech_client().transcribe(settings, audio, content_type, lang) end) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, reason} -> provider_refusal(reason, "speech")
    end
  end

  defp run(prefix, transcript) do
    case Settings.model() do
      {:ok, model} -> with_model(prefix, model, transcript)
      _ -> {:ok, model_off(transcript)}
    end
  end

  defp with_model(prefix, model, transcript) do
    with {:ok, items} <- items(prefix),
         {:ok, locations} <- locations(prefix),
         prompt = VoicePrompt.build(items, locations),
         {:ok, answer} <- complete(model, prompt, transcript),
         {:ok, parsed} <- parse(answer) do
      {:ok, VoiceDraft.check(parsed, transcript, %{items: items, locations: locations})}
    end
  end

  defp complete(model, prompt, transcript) do
    case guarded(fn -> model_client().complete(model, prompt, transcript) end) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, reason} -> provider_refusal(reason, "llm")
    end
  end

  defp parse(answer) do
    case VoiceDraft.parse_answer(answer) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, :bad_answer} -> refuse(502, "bad_answer", %{"source" => "llm"})
    end
  end

  # A raising or misbehaving client is a provider error; nothing of it is inspected or logged.
  defp guarded(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      _ -> {:error, :provider_error}
    end
  rescue
    _ -> {:error, :provider_error}
  catch
    _, _ -> {:error, :provider_error}
  end

  defp provider_refusal(:provider_timeout, source),
    do: refuse(504, "provider_timeout", %{"source" => source})

  defp provider_refusal(:refused, source), do: refuse(502, "refused", %{"source" => source})
  defp provider_refusal(:truncated, source), do: refuse(502, "truncated", %{"source" => source})

  defp provider_refusal(_other, source),
    do: refuse(502, "provider_error", %{"source" => source})

  defp model_off(transcript) do
    %{
      kind: "unknown",
      items: [],
      location: nil,
      to_location: nil,
      quantity: nil,
      transcript: transcript,
      dropped: [],
      notice: "llm_off"
    }
  end

  # -- the tenant's lists (INV-6) ------------------------------------------------------------------

  defp items(prefix) do
    with {:ok, records} <- CatalogItems.list_active(prefix) do
      units = unit_codes(prefix, records)

      {:ok,
       Enum.map(records, fn r ->
         %{
           id: r["record_id"],
           code: r["code"],
           name: r["name"],
           base_unit: Map.get(units, r["base_uom_id"], "")
         }
       end)}
    end
  end

  defp unit_codes(prefix, records) do
    records
    |> Enum.map(& &1["base_uom_id"])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(fn id ->
      case CatalogItems.lookup(prefix, id) do
        {:ok, %{"entity_type" => "catalog_uom", "code" => code}} when is_binary(code) ->
          {id, code}

        _ ->
          {id, ""}
      end
    end)
  end

  defp locations(prefix) do
    with {:ok, records} <- Locations.list_active(prefix) do
      {:ok, Enum.map(records, &%{id: &1["record_id"], code: &1["code"], name: &1["name"]})}
    end
  end

  # -- seams ---------------------------------------------------------------------------------------

  defp speech_client, do: client(:speech, Letflow.Voice.SpeechClient)
  defp model_client, do: client(:model, Letflow.Voice.ModelClient)

  defp client(key, default) do
    :letflow |> Application.get_env(:voice_clients, []) |> Keyword.get(key, default)
  end

  defp refuse(status, reason, extras \\ %{}), do: {:error, {:refuse, status, reason, extras}}
end
