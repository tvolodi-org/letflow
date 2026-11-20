defmodule Letflow.Modules.Stock.OldAppVoice do
  @moduledoc """
  K10 / REQ-911 (decision 0091 section 11c; old-client compatibility, status note section 5.3): the
  answer of `POST /api/voice` at the old Qoimeks address, built over the unchanged
  `Letflow.Modules.Stock.VoiceService.draft_audio/2`. Reached only through
  `Letflow.Modules.Catalog.old_app_voice/2`; `Letflow.Routers.SharedStockAccess` has parsed the
  multipart form by then, after authentication.

  `answer/2` takes the tenant schema `prefix` of the proved tenant (INV-1: the voice service reads only
  that schema's active item and place lists, and every row below is read from it) and the parsed form
  (only the parts `audio` and `lang` are passed on; the old server ignored the others). It returns
  `{:ok, body}` or `{:error, {status, body}}`; nothing is stored.

  The 200 body (the old app's `Draft`): `transcript`, `skus` (always; the catalog rows of
  `OldAppReads.sku_rows_for/2`, in the draft's order), and only when the draft has them `kind`
  (`receipt`, `issue`, `transfer`), `location` and `to_location` (catalog place rows) and `qty` (a JSON
  number). No count by voice (owner pruning D-150): a draft of kind `count` has no `kind` and no `qty`.

  Refusals follow the old server, `{"error": text}` plus `"source"` where it sent one: 400 `audio file is
  required (max 10 MB)`, 400 `lang must be ru or kk`, 503 and 502 with source `speech`, 422 `nothing was
  said`, 502 with source `llm`, and a plain 500 `internal error` for anything else (INV-8). A provider's
  message never reaches the answer, and this module logs nothing about the phrase.
  """

  alias Letflow.Modules.Stock.OldAppReads
  alias Letflow.Modules.Stock.VoiceService

  @kinds ~w(receipt issue transfer)

  @spec answer(String.t(), map()) :: {:ok, map()} | {:error, {pos_integer(), map()}}
  def answer(prefix, params) when is_binary(prefix) and is_map(params) do
    case VoiceService.draft_audio(prefix, Map.take(params, ["audio", "lang"])) do
      {:ok, %{} = draft} -> build(prefix, draft)
      {:error, {:refuse, _status, reason, extras}} -> refusal(reason, extras)
      _other -> internal()
    end
  end

  # -- the 200 body -------------------------------------------------------------------------------

  defp build(prefix, draft) do
    transcript = draft.transcript

    if is_binary(transcript) and String.trim(transcript) != "" do
      count? = draft.kind == "count"

      body =
        %{transcript: transcript, skus: OldAppReads.sku_rows_for(prefix, item_ids(draft))}
        |> put_present(:kind, if(draft.kind in @kinds, do: draft.kind))
        |> put_present(:location, place(prefix, draft.location))
        |> put_present(:to_location, place(prefix, draft.to_location))
        |> put_present(:qty, if(count?, do: nil, else: number(draft.quantity)))

      {:ok, body}
    else
      {:error, {422, %{error: "nothing was said"}}}
    end
  end

  defp item_ids(%{items: items}) when is_list(items), do: Enum.map(items, & &1.id)
  defp item_ids(_draft), do: []

  defp place(prefix, %{id: id}), do: OldAppReads.location_row_for(prefix, id)
  defp place(_prefix, _none), do: nil

  defp number(text) when is_binary(text) do
    case Decimal.parse(text) do
      {%Decimal{} = d, ""} ->
        if Decimal.integer?(d), do: Decimal.to_integer(d), else: Decimal.to_float(d)

      _other ->
        nil
    end
  end

  defp number(_none), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # -- refusals (the old server's texts) ------------------------------------------------------------

  defp refusal(reason, _extras) when reason in ["field_invalid", "audio_too_large"],
    do: {:error, {400, %{error: "audio file is required (max 10 MB)"}}}

  defp refusal("bad_language", _extras),
    do: {:error, {400, %{error: "lang must be ru or kk"}}}

  defp refusal("speech_off", _extras) do
    {:error,
     {503, %{error: "speech recognition is not configured on the server", source: "speech"}}}
  end

  defp refusal(_reason, %{"source" => "speech"}),
    do: {:error, {502, %{error: "speech recognition failed", source: "speech"}}}

  defp refusal(_reason, %{"source" => "llm"}),
    do: {:error, {502, %{error: "could not understand the phrase", source: "llm"}}}

  defp refusal(_reason, _extras), do: internal()

  defp internal, do: {:error, {500, %{error: "internal error"}}}
end
