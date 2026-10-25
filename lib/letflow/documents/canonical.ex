defmodule Letflow.Documents.Canonical do
  @moduledoc """
  Canonical form and content hash of a document version (REQ-542, GH #3164, decision 0056 D3).

  Pure: no database, no clock. `canonicalize/1` takes decoded content (a map) or JSON text and
  returns the canonical bytes, or refuses with one reason:

    * floats of any kind (`:float_not_allowed`), atoms other than `true`/`false`/`nil`, tuples and
      the like (`:unsupported_value`), non-string map keys (`:invalid_key`);
    * invalid UTF-8 (`:invalid_utf8`); strings and keys are put in NFC;
    * a key repeated in one object, in the JSON text or after NFC (`:duplicate_key`);
    * JSON text that does not decode, including `NaN`, `Infinity` and `1e999` (`:invalid_json`).

  The sorting and compaction are those of `Letflow.Repository.Canonicaliser.canonicalize_content/2`
  (reused, not copied; D3 forbids a third canonical JSON form).

  `content_hash/1` is `sha256(domain_tag || F(tenant) || F(document) || F(type) || F(legal entity) ||
  F(number) || F(version_no) || F(canonical content))` with `F(x) = <<byte_size(x)::64, x::binary>>`,
  lower-case hex. A nil legal entity is replaced by `legal_entity_sentinel/0`. A hash is never read
  from a caller: any extra key in the input is refused. REQ-543 recomputes through this module.
  """

  alias Letflow.Repository.Canonicaliser

  @domain_tag "letflow.document.v1"
  @sentinel "00000000-0000-0000-0000-000000000000"
  @hash_keys [
    :tenant_uuid,
    :document_id,
    :type_key,
    :legal_entity_id,
    :number,
    :version_no,
    :canonical_content
  ]

  @type reason ::
          :invalid_json
          | :float_not_allowed
          | :unsupported_value
          | :invalid_key
          | :invalid_utf8
          | :duplicate_key

  @doc "The legal entity used in the hash (and in REQ-543's sequence key) when a type has none."
  @spec legal_entity_sentinel() :: String.t()
  def legal_entity_sentinel, do: @sentinel

  @doc "Canonical bytes of decoded content (a map) or of JSON text."
  @spec canonicalize(map() | binary()) :: {:ok, binary()} | {:error, reason()}
  def canonicalize(text) when is_binary(text) do
    with {:ok, term} <- decode(text),
         {:ok, normal} <- normalize(term) do
      encode(normal)
    end
  end

  def canonicalize(term) when is_map(term) and not is_struct(term) do
    with {:ok, normal} <- normalize(term), do: encode(normal)
  end

  def canonicalize(_other), do: {:error, :unsupported_value}

  defp decode(text) do
    if String.valid?(text) do
      case Jason.decode(text, objects: :ordered_objects) do
        {:ok, term} -> {:ok, term}
        {:error, _reason} -> {:error, :invalid_json}
      end
    else
      {:error, :invalid_utf8}
    end
  end

  defp encode(normal) do
    case Canonicaliser.canonicalize_content("application/json", Jason.encode!(normal)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp normalize(%Jason.OrderedObject{values: pairs}), do: normalize_pairs(pairs)

  defp normalize(map) when is_map(map) and not is_struct(map),
    do: normalize_pairs(Map.to_list(map))

  defp normalize(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp normalize(value) when is_binary(value), do: nfc(value)
  defp normalize(value) when is_float(value), do: {:error, :float_not_allowed}

  defp normalize(value) when is_integer(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  defp normalize(_other), do: {:error, :unsupported_value}

  defp normalize_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with :ok <- check_key(key),
           {:ok, nfc_key} <- nfc(key),
           :ok <- check_new(acc, nfc_key),
           {:ok, normal} <- normalize(value) do
        {:cont, {:ok, Map.put(acc, nfc_key, normal)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp check_key(key) when is_binary(key), do: :ok
  defp check_key(_key), do: {:error, :invalid_key}

  defp check_new(acc, key) do
    if Map.has_key?(acc, key), do: {:error, :duplicate_key}, else: :ok
  end

  defp nfc(value) do
    if String.valid?(value) do
      {:ok, :unicode.characters_to_nfc_binary(value)}
    else
      {:error, :invalid_utf8}
    end
  end

  @doc """
  Hash of one document version. Takes exactly `tenant_uuid`, `document_id`, `type_key`,
  `legal_entity_id` (nil means the sentinel), `number`, `version_no` and `canonical_content`
  (the bytes from `canonicalize/1`). Anything else, including a `content_hash`, is refused.
  """
  @spec content_hash(map()) :: {:ok, String.t()} | {:error, :invalid_hash_input}
  def content_hash(inputs) when is_map(inputs) do
    with true <- inputs |> Map.keys() |> Enum.all?(&(&1 in @hash_keys)),
         {:ok, tenant} <- uuid(Map.get(inputs, :tenant_uuid)),
         {:ok, document} <- uuid(Map.get(inputs, :document_id)),
         {:ok, entity} <- entity(Map.get(inputs, :legal_entity_id)),
         type when is_binary(type) and type != "" <- Map.get(inputs, :type_key),
         number when is_integer(number) and number > 0 <- Map.get(inputs, :number),
         version when is_integer(version) and version > 0 <- Map.get(inputs, :version_no),
         content when is_binary(content) <- Map.get(inputs, :canonical_content) do
      {:ok,
       digest(@domain_tag, [
         tenant,
         document,
         type,
         entity,
         Integer.to_string(number),
         Integer.to_string(version),
         content
       ])}
    else
      _invalid -> {:error, :invalid_hash_input}
    end
  end

  def content_hash(_other), do: {:error, :invalid_hash_input}

  @doc false
  # The one place that hashes; public only so a test can vary the domain tag (the eighth input).
  @spec digest(binary(), [binary()]) :: String.t()
  def digest(domain_tag, fields) when is_binary(domain_tag) and is_list(fields) do
    framed =
      for field <- fields, into: domain_tag do
        <<byte_size(field)::unsigned-big-64, field::binary>>
      end

    :sha256 |> :crypto.hash(framed) |> Base.encode16(case: :lower)
  end

  defp entity(nil), do: {:ok, @sentinel}
  defp entity(value), do: uuid(value)

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp uuid(_other), do: :error
end
