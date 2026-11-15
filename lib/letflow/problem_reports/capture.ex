defmodule Letflow.ProblemReports.Capture do
  @moduledoc """
  T-1948: the cut-down of a problem report. Pure, no DB. `parse/1` turns the request body into the
  `text` and the `context` that may be stored, or refuses it.

  ## Whitelist

  Only the keys listed in `parse_context/1` are kept, at every level, each with a cap; every other key
  (`tenant_id`, `user_id`, `roles`, `email`, `screenshot`, ...) is dropped silently. After the whitelist
  `Letflow.Secrets.Redaction.redact_map/1` runs once more as a floor.

  ## Text mask (`mask/1`)

  Applied to `text`, `route`, `actions[].name`, `crash.name` and `crash.message`; NOT to the fields that
  are already shape-checked (`at`, request `path`, `error_code`, `trace_id`, `method`, `status`,
  `browser`, `ui_language`), because masking would corrupt them. Six rules in this order, each a global
  replace: Bearer value, JWT shape, `sk-` key, `password|secret|token|api_key` assignment, e-mail, phone.
  The browser runs the same rules first (follow-up web task); the literal input/output pairs of
  `test/letflow/problem_reports/capture_test.exs` are shared with it.

  The phone rule is two stages: a candidate regex picks runs of ASCII digits joined only by space, `(`,
  `)` or `-`; then the candidate is masked only if it starts with `+` and holds at least 10 digits, or
  holds exactly 11 digits and starts with 7 or 8. Dates, amounts, inventory and SR numbers are kept.
  Known limits, accepted: an 11-digit number starting with 7 or 8 that is not a phone is masked
  (over-mask, visible in the preview before consent); a national phone followed by another number after
  a space is not masked; IIN/BIN (12 digits) are not masked (a BIN is needed in asset reports and the
  user sees the text before sending). The regexes take no `u` flag and use explicit ASCII classes, so
  they behave like a JS regex without `u`.
  """

  alias Letflow.Secrets.Redaction

  @max_text 4000
  @max_actions 20
  @max_requests 10
  @max_entity_ids 8
  @methods ~w(GET POST PUT PATCH DELETE)
  @action_kinds ~w(click nav)
  @languages ~w(en ru kk)

  @bearer ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]+/i
  @jwt ~r/\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/
  @sk ~r/\bsk-[A-Za-z0-9_-]{16,}/
  @assign ~r/\b(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S+/i
  @email ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
  @phone ~r/(?<![0-9A-Za-z+])\+?[0-9](?:[ ()-]{1,2}[0-9]|[0-9])*(?![0-9A-Za-z])/
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @max_images 3
  @max_image_bytes 5_242_880
  @accepted_content_types ~w(image/png image/jpeg)

  @spec parse(term()) ::
          {:ok, %{text: String.t(), context: map(), images: list()}}
          | {:error, {:invalid, String.t()}}
  def parse(body) when is_map(body) do
    with {:ok, text} <- parse_text(Map.get(body, "text")),
         {:ok, context} <- parse_context(Map.get(body, "context")),
         {:ok, images} <- parse_images(Map.get(body, "images")) do
      {:ok, %{text: text, context: context, images: images}}
    end
  end

  def parse(_other), do: {:error, {:invalid, "text"}}

  @doc """
  Parses the optional `images` list from a problem report body. Accepts nil/absent → empty list.
  Each item must be `%{"data_base64" => str, "content_type" => ct}` where ct is `image/png` or
  `image/jpeg`. Decodes base64, checks magic bytes and size ≤ 5 MB.
  Returns `{:ok, [%{content_type, bytes, size}]}` or an error.
  """
  @spec parse_images(term()) ::
          {:ok, list(%{content_type: String.t(), bytes: binary(), size: non_neg_integer()})}
          | {:error, {:invalid, String.t()}}
  def parse_images(nil), do: {:ok, []}

  def parse_images(list) when is_list(list) and length(list) <= @max_images do
    result =
      Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
        case parse_image(item) do
          {:ok, img} -> {:cont, {:ok, acc ++ [img]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    result
  end

  def parse_images(_other), do: {:error, {:invalid, "images"}}

  defp parse_image(%{"data_base64" => b64, "content_type" => ct})
       when is_binary(b64) and ct in @accepted_content_types do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, bytes} ->
        size = byte_size(bytes)

        with true <- (size >= 1 and size <= @max_image_bytes) || {:error, :image_too_large},
             {:ok, sniffed_ct} <- sniff_magic(bytes),
             true <- sniffed_ct == ct || {:error, :type_mismatch} do
          {:ok, %{content_type: ct, bytes: bytes, size: size}}
        else
          {:error, _} -> {:error, {:invalid, "images"}}
        end

      :error ->
        {:error, {:invalid, "images"}}
    end
  end

  defp parse_image(_other), do: {:error, {:invalid, "images"}}

  defp sniff_magic(<<0x89, 0x50, 0x4E, 0x47, _::binary>>), do: {:ok, "image/png"}
  defp sniff_magic(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp sniff_magic(_), do: {:error, :bad_image_type}

  # ── text ────────────────────────────────────────────────────────────────

  defp parse_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    len = String.length(trimmed)

    if len >= 1 and len <= @max_text do
      # Masking can lengthen the text ("Bearer x" -> "Bearer [REDACTED]"): re-check the cap after it.
      masked = mask(trimmed)
      if String.length(masked) <= @max_text, do: {:ok, masked}, else: {:error, {:invalid, "text"}}
    else
      {:error, {:invalid, "text"}}
    end
  end

  defp parse_text(_other), do: {:error, {:invalid, "text"}}

  # ── context ─────────────────────────────────────────────────────────────

  defp parse_context(nil), do: {:ok, %{}}

  defp parse_context(context) when is_map(context) do
    parsed =
      %{}
      |> put_present("route", route(Map.get(context, "route")))
      |> put_present("entity_ids", entity_ids(Map.get(context, "entity_ids")))
      |> put_present("browser", browser(Map.get(context, "browser")))
      |> put_present("ui_language", ui_language(Map.get(context, "ui_language")))
      |> put_present("actions", actions(Map.get(context, "actions")))
      |> put_present("requests", requests(Map.get(context, "requests")))
      |> put_present("crash", crash(Map.get(context, "crash")))

    {:ok, Redaction.redact_map(parsed)}
  end

  defp parse_context(_other), do: {:error, {:invalid, "context"}}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp route(value) when is_binary(value), do: value |> normalize_path() |> cap(300) |> mask()
  defp route(_other), do: nil

  # SR-1 (T-2009): the ids of the entities on screen (document id, card id), taken by the browser from the
  # route params and the query. Ids only: a key is a short snake_case name, a value is one id token
  # (letters, digits, `_`, `-`; no text, no `@`, no spaces). Anything else is dropped, never masked.
  defp entity_ids(%{} = ids) do
    result =
      ids
      |> Enum.flat_map(fn
        {key, value} when is_binary(key) and is_binary(value) ->
          if Regex.match?(~r/\A[a-z][a-z0-9_]{0,39}\z/, key) and
               Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, value),
             do: [{key, value}],
             else: []

        _dropped ->
          []
      end)
      |> Enum.sort()
      |> Enum.take(@max_entity_ids)
      |> Map.new()

    if map_size(result) == 0, do: nil, else: result
  end

  defp entity_ids(_other), do: nil

  defp browser(%{} = browser) do
    result =
      %{}
      |> put_present("user_agent", one_line(string_cap(Map.get(browser, "user_agent"), 300)))
      |> put_present(
        "viewport",
        matching(Map.get(browser, "viewport"), ~r/\A[0-9]{1,5}x[0-9]{1,5}\z/)
      )
      |> put_present("language", matching(Map.get(browser, "language"), ~r/\A[A-Za-z-]{2,16}\z/))

    if map_size(result) == 0, do: nil, else: result
  end

  defp browser(_other), do: nil

  defp ui_language(value) when value in @languages, do: value
  defp ui_language(_other), do: nil

  defp actions(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"kind" => kind, "name" => name} = entry when kind in @action_kinds and is_binary(name) ->
        name = if kind == "nav", do: normalize_path(name), else: name

        [
          %{}
          |> put_present("at", string_cap(Map.get(entry, "at"), 40))
          |> Map.put("kind", kind)
          |> Map.put("name", name |> cap(80) |> mask())
        ]

      _dropped ->
        []
    end)
    |> Enum.take(-@max_actions)
  end

  defp actions(_other), do: nil

  defp requests(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"method" => method} = entry when method in @methods ->
        [
          %{"method" => method}
          |> put_present("at", string_cap(Map.get(entry, "at"), 40))
          |> put_present("path", request_path(Map.get(entry, "path")))
          |> put_present("status", status(Map.get(entry, "status")))
          |> put_present(
            "trace_id",
            matching(Map.get(entry, "trace_id"), ~r/\A[A-Za-z0-9_-]{1,64}\z/)
          )
          |> put_present("error_code", error_code(Map.get(entry, "error_code")))
        ]

      _dropped ->
        []
    end)
    |> Enum.take(-@max_requests)
  end

  defp requests(_other), do: nil

  defp request_path(path) when is_binary(path), do: path |> normalize_path() |> cap(300)
  defp request_path(_other), do: nil

  defp status(status) when is_integer(status) and status >= 0 and status <= 599, do: status
  defp status(_other), do: nil

  defp error_code(code) when is_binary(code) and byte_size(code) <= 80 do
    matching(code, ~r/\A[A-Za-z0-9_.:\/-]+\z/)
  end

  defp error_code(_other), do: nil

  defp crash(%{} = crash) do
    result =
      %{}
      |> put_present("name", masked_cap(Map.get(crash, "name"), 80))
      |> put_present("message", masked_cap(Map.get(crash, "message"), 300))

    if map_size(result) == 0, do: nil, else: result
  end

  defp crash(_other), do: nil

  defp string_cap(value, max) when is_binary(value), do: cap(value, max)
  defp string_cap(_other, _max), do: nil

  # A one-line field never carries a line break or control character (it is printed into a frame).
  defp one_line(value) when is_binary(value),
    do:
      value
      |> String.replace(~r/[\x00-\x1f\x7f]+/, " ")
      |> String.replace(["\u2028", "\u2029", "\u0085"], " ")

  defp one_line(other), do: other

  defp masked_cap(value, max) when is_binary(value), do: value |> cap(max) |> mask()
  defp masked_cap(_other, _max), do: nil

  defp matching(value, regex) when is_binary(value) do
    if Regex.match?(regex, value), do: value, else: nil
  end

  defp matching(_other, _regex), do: nil

  defp cap(value, max), do: String.slice(value, 0, max)

  # ── path normalisation ──────────────────────────────────────────────────

  @doc """
  Drops `?query` and `#hash`; a segment that is a UUID, holds 3 or more digits or is longer than 40
  characters becomes `:id`.
  """
  @spec normalize_path(String.t()) :: String.t()
  def normalize_path(path) when is_binary(path) do
    base = path |> String.split(["?", "#"], parts: 2) |> hd()

    base
    |> String.split("/")
    |> Enum.map_join("/", fn segment ->
      cond do
        segment == "" -> segment
        Regex.match?(@uuid, segment) -> ":id"
        String.length(segment) > 40 -> ":id"
        length(Regex.scan(~r/[0-9]/, segment)) >= 3 -> ":id"
        true -> segment
      end
    end)
  end

  # ── mask ────────────────────────────────────────────────────────────────

  @doc "The text mask, six rules in order (see the moduledoc)."
  @spec mask(String.t()) :: String.t()
  def mask(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@bearer, &1, "Bearer [REDACTED]"))
    |> then(&Regex.replace(@jwt, &1, "[REDACTED]"))
    |> then(&Regex.replace(@sk, &1, "[REDACTED]"))
    |> then(&Regex.replace(@assign, &1, "\\1=[REDACTED]"))
    |> then(&Regex.replace(@email, &1, "[email]"))
    |> then(&Regex.replace(@phone, &1, fn candidate -> mask_phone(candidate) end))
  end

  defp mask_phone(candidate) do
    digits = length(Regex.scan(~r/[0-9]/, candidate))

    cond do
      String.starts_with?(candidate, "+") and digits >= 10 -> "[phone]"
      digits == 11 and String.first(candidate) in ["7", "8"] -> "[phone]"
      true -> candidate
    end
  end
end
