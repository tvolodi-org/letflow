defmodule Letflow.Voice.ModelClient do
  @moduledoc """
  REQ-740: OpenAI-style chat client (`POST <base URL>/chat/completions`, JSON). Source of any
  error: `llm` (the route of REQ-741 attaches it; the atoms here are bare). One call, one
  request, no retry. The `<think>` stripping and the JSON parse of the content belong to
  the Check module (REQ-739), not here. See `Letflow.Voice.Http` for INV-4 / INV-9.
  """

  alias Letflow.Voice.{Http, Settings}

  @draft_keys ~w(kind item_codes location_words location_code to_location_words to_location_code quantity)

  @spec complete(Settings.Model.t(), binary(), binary()) ::
          {:ok, String.t()}
          | {:error, :provider_error | :provider_timeout | :truncated | :refused}
  def complete(%Settings.Model{} = s, system_prompt, user_text)
      when is_binary(system_prompt) and is_binary(user_text) do
    payload =
      %{
        "model" => s.model,
        "messages" => [
          %{"role" => "system", "content" => system_prompt},
          %{"role" => "user", "content" => user_text}
        ]
      }
      |> put_format(s.json_mode)

    url = String.trim_trailing(s.base_url, "/") <> "/chat/completions"
    headers = [{"authorization", "Bearer " <> s.api_key}]

    with {:ok, body} <- Jason.encode(payload) do
      case Http.post(url, headers, "application/json", body, Settings.timeout_ms()) do
        {:ok, status, resp} when status >= 200 and status < 300 -> interpret(resp)
        {:ok, _status, _resp} -> {:error, :provider_error}
        {:error, _} = error -> error
      end
    else
      _ -> {:error, :provider_error}
    end
  end

  def complete(_settings, _system, _user), do: {:error, :provider_error}

  defp put_format(payload, :schema) do
    string = %{"type" => "string"}
    nullable = %{"type" => ["string", "null"]}

    schema = %{
      "type" => "object",
      "properties" => %{
        "kind" => string,
        "item_codes" => %{"type" => "array", "items" => string},
        "location_words" => nullable,
        "location_code" => nullable,
        "to_location_words" => nullable,
        "to_location_code" => nullable,
        "quantity" => %{"type" => ["number", "null"]}
      },
      "required" => @draft_keys,
      "additionalProperties" => false
    }

    Map.put(payload, "response_format", %{
      "type" => "json_schema",
      "json_schema" => %{"name" => "stock_draft", "strict" => true, "schema" => schema}
    })
  end

  defp put_format(payload, :object),
    do: Map.put(payload, "response_format", %{"type" => "json_object"})

  defp put_format(payload, :prompt), do: payload

  defp interpret(resp) do
    with {:ok, %{"choices" => [choice | _]}} <- Jason.decode(resp),
         true <- is_map(choice) do
      message = Map.get(choice, "message")
      message = if is_map(message), do: message, else: %{}

      cond do
        Map.get(message, "refusal") != nil -> {:error, :refused}
        Map.get(choice, "finish_reason") == "length" -> {:error, :truncated}
        is_binary(Map.get(message, "content")) -> {:ok, Map.get(message, "content")}
        true -> {:error, :provider_error}
      end
    else
      _ -> {:error, :provider_error}
    end
  end
end
