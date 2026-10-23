defmodule Letflow.Entities.Query.CursorSeal do
  @moduledoc """
  Authenticated encryption of the resume key inside an entity-query cursor (GH #2698).

  The cursor's sort values can belong to restricted fields, so a MAC alone is not enough:
  the key JSON is encrypted (AES-256-GCM) and authenticated in one step. The associated
  data binds the token to the tenant schema `prefix`, the `user_id`, the entity type, the
  sort clause list and the cleartext mint timestamp, so a token replayed by another user,
  under another tenant, another sort or type, or with an extended expiry fails to open.

  The key is `HMAC-SHA256(master, "letflow/query-cursor/v1")` where `master` is the 32-byte
  `:secrets_master_key` (the same material `Letflow.Secrets` uses; same derivation idiom as
  `Letflow.Api.AuthzDenyLog.subkey/0`). No new environment variable. There is no random
  fallback: a malformed master key raises (fail closed, INV-4). Rotating the master key
  invalidates outstanding cursors (400 `invalid cursor`); they live 24 h anyway.

  Token = `base64url(nonce(12) <> ciphertext <> tag(16))`. `open/2` never raises on a
  malformed token (INV-8).
  """

  @label "letflow/query-cursor/v1"
  @nonce_bytes 12
  @tag_bytes 16

  @type aad_ctx :: %{
          required(:prefix) => String.t(),
          required(:user_id) => String.t(),
          required(:entity_type) => String.t(),
          required(:sort) => [[String.t()]],
          required(:mint_us) => integer()
        }

  @doc "Seals `plaintext` (the resume-key JSON) under `ctx`; returns a URL-safe token."
  @spec seal(binary(), aad_ctx()) :: String.t()
  def seal(plaintext, ctx) when is_binary(plaintext) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), nonce, plaintext, aad(ctx), true)

    Base.url_encode64(nonce <> ciphertext <> tag, padding: false)
  end

  @doc "Opens `token` under `ctx`; `:error` on any mismatch or malformed input."
  @spec open(term(), aad_ctx()) :: {:ok, binary()} | :error
  def open(token, ctx) when is_binary(token) do
    with {:ok, raw} <- Base.url_decode64(token, padding: false),
         true <- byte_size(raw) > @nonce_bytes + @tag_bytes,
         ct_size = byte_size(raw) - @nonce_bytes - @tag_bytes,
         <<nonce::binary-size(@nonce_bytes), ciphertext::binary-size(^ct_size),
           tag::binary-size(@tag_bytes)>> <- raw,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key(),
             nonce,
             ciphertext,
             aad(ctx),
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _ -> :error
    end
  end

  def open(_token, _ctx), do: :error

  defp aad(%{prefix: prefix, user_id: user_id, entity_type: entity_type, sort: sort, mint_us: us}) do
    Jason.encode!(["v1", prefix, user_id, entity_type, sort, us])
  end

  defp key do
    case Application.fetch_env!(:letflow, :secrets_master_key) do
      master when is_binary(master) and byte_size(master) == 32 ->
        :crypto.mac(:hmac, :sha256, master, @label)

      _ ->
        raise ArgumentError, "secrets_master_key must be a 32-byte binary"
    end
  end
end
