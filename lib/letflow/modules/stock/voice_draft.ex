defmodule Letflow.Modules.Stock.VoiceDraft do
  @moduledoc """
  T-1341 / D2a (`docs/assets/voice-port-design.md` sections 4 and 5): parse the model's JSON answer and run
  the server check on it. Pure: no database, no network, no clock. The answer is never trusted.

  `parse_answer/1` accepts exactly the seven draft keys with the right types, else `{:error, :bad_answer}`
  (never a partial draft). `check/3` takes the parsed answer, the transcript and the catalog
  (`%{items: [...], locations: [...]}`, only the caller tenant's records, passed by the route of D2c) and
  returns the draft with a `dropped` list `[%{field, value, reason}]`. `value` is the model's raw value.

  Reasons: `unknown_kind`, `unknown_item`, `duplicate_item`, `unknown_location`, `location_not_said`,
  `to_location_not_transfer`, `negative_quantity`, and `bad_quantity` (zero on a kind other than count; added
  by D2a, section 4 lists no reason for it). Location words are tested before the code, so a code the
  tenant does not have with words absent from the phrase gives `location_not_said`.
  Known gaps (design section 5): the quantity is not compared with the transcript; a wrong code with the
  right words is kept.
  """

  @keys ~w(kind item_codes location_words location_code to_location_words to_location_code quantity)
  @kinds ~w(receipt issue transfer count)

  @type dropped :: %{field: String.t(), value: term(), reason: String.t()}

  @spec parse_answer(term()) :: {:ok, map()} | {:error, :bad_answer}
  def parse_answer(text) when is_binary(text) do
    stripped = Regex.replace(~r/<think>.*?<\/think>/s, text, "")

    with [json] <- Regex.run(~r/\{.*\}/s, stripped),
         {:ok, %{} = map} <- Jason.decode(json),
         true <- Enum.sort(Map.keys(map)) == Enum.sort(@keys),
         true <- valid_types?(map) do
      {:ok, map}
    else
      _ -> {:error, :bad_answer}
    end
  end

  def parse_answer(_), do: {:error, :bad_answer}

  defp valid_types?(m) do
    is_binary(m["kind"]) and
      is_list(m["item_codes"]) and Enum.all?(m["item_codes"], &is_binary/1) and
      Enum.all?(~w(location_words location_code to_location_words to_location_code), fn k ->
        is_nil(m[k]) or is_binary(m[k])
      end) and
      (is_nil(m["quantity"]) or is_number(m["quantity"]))
  end

  @spec check(map(), String.t(), map()) :: map()
  def check(answer, transcript, %{items: items, locations: locations}) do
    transcript = if is_binary(transcript), do: transcript, else: ""
    items = Enum.reject(items, &(Map.get(&1, :active) == false))
    locations = Enum.reject(locations, &(Map.get(&1, :active) == false))

    {kind, d1} = check_kind(answer["kind"])
    {kept_items, d2} = check_items(answer["item_codes"], items)

    {location, d3} =
      check_location(
        "location",
        answer["location_words"],
        answer["location_code"],
        transcript,
        locations
      )

    {to_location, d4} =
      if kind == "transfer" do
        check_location(
          "to_location",
          answer["to_location_words"],
          answer["to_location_code"],
          transcript,
          locations
        )
      else
        {nil, not_transfer(answer)}
      end

    {quantity, d5} = check_quantity(answer["quantity"], kind)

    %{
      kind: kind,
      items: kept_items,
      location: location,
      to_location: to_location,
      quantity: quantity,
      transcript: transcript,
      dropped: d1 ++ d2 ++ d3 ++ d4 ++ d5
    }
  end

  defp check_kind(kind) when kind in @kinds or kind == "unknown", do: {kind, []}
  defp check_kind(kind), do: {"unknown", [drop("kind", kind, "unknown_kind")]}

  defp check_items(codes, items) do
    by_code = Map.new(items, &{&1.code, &1})

    {kept, _seen, dropped} =
      Enum.reduce(codes, {[], MapSet.new(), []}, fn code, {kept, seen, dropped} ->
        cond do
          MapSet.member?(seen, code) ->
            {kept, seen, [drop("item_codes", code, "duplicate_item") | dropped]}

          item = by_code[code] ->
            {[Map.take(item, [:id, :code, :name]) | kept], MapSet.put(seen, code), dropped}

          true ->
            {kept, seen, [drop("item_codes", code, "unknown_item") | dropped]}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(dropped)}
  end

  defp check_location(_field, nil, nil, _transcript, _locations), do: {nil, []}

  defp check_location(field, words, code, transcript, locations) do
    cond do
      not said?(words, transcript) ->
        {nil, [drop(field, code || words, "location_not_said")]}

      loc = code && Enum.find(locations, &(&1.code == code)) ->
        {Map.take(loc, [:id, :code, :name]), []}

      true ->
        {nil, [drop(field, code || words, "unknown_location")]}
    end
  end

  defp not_transfer(answer) do
    case answer["to_location_code"] || answer["to_location_words"] do
      nil -> []
      value -> [drop("to_location", value, "to_location_not_transfer")]
    end
  end

  defp said?(words, transcript) when is_binary(words) do
    w = normalize(words)
    w != "" and String.contains?(normalize(transcript), w)
  end

  defp said?(_, _), do: false

  defp normalize(text) do
    text |> String.downcase() |> String.replace("ё", "е") |> String.replace(~r/\s+/u, "")
  end

  defp check_quantity(nil, _kind), do: {nil, []}

  defp check_quantity(q, kind) do
    d = if is_float(q), do: Decimal.from_float(q), else: Decimal.new(q)

    cond do
      Decimal.negative?(d) -> {nil, [drop("quantity", text(d), "negative_quantity")]}
      Decimal.eq?(d, 0) and kind != "count" -> {nil, [drop("quantity", text(d), "bad_quantity")]}
      true -> {text(d), []}
    end
  end

  defp text(d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp drop(field, value, reason), do: %{field: field, value: value, reason: reason}
end
