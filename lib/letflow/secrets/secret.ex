defmodule Letflow.Secrets.Secret do
  @moduledoc """
  Ecto schema for the global `secrets` table. See
  `lib/letflow/design/req190-secrets-core.md` §4. Ordinary `Ecto.Schema`, no
  process — no `@schema_prefix`, since this table is global (0016 §B), not
  tenant-scoped like every other business table in this codebase.

  ## No `plaintext` field, ever (design §4)

  No field on this struct is ever named `plaintext`, and no changeset
  function below accepts a `"plaintext"`/`:plaintext` key — `Letflow.Secrets`
  computes `ciphertext`/`wrapped_data_key`/etc. itself before ever
  constructing a changeset; the plaintext value never reaches this module.
  Same "structurally impossible, not just policy" pattern
  `Letflow.Webhooks.Subscription` already establishes for `secret_hash`.

  ## `created_by` immutability (design §3.3/§7)

  `disable_changeset/2` casts only `:status, :disabled_at` — `created_by` is
  never in any changeset's cast list, structurally preventing R-Co's
  `disableSecretVersion` defect (overwriting `created_by` with the disabling
  actor).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "secrets" do
    field(:tenant_id, Ecto.UUID)
    field(:namespace, :string)
    field(:name, :string)
    field(:key_id, :integer)

    field(:purpose, Ecto.Enum, values: [:webhook_hmac, :generic, :script_hmac])
    field(:status, Ecto.Enum, values: [:active, :disabled, :deleted], default: :active)

    field(:algorithm, Ecto.Enum, values: [:aes_256_gcm])
    field(:wrapped_key_algorithm, Ecto.Enum, values: [:aes_256_gcm])

    field(:ciphertext, :binary)
    field(:wrapped_data_key, :binary)
    field(:nonce, :binary)
    field(:wrap_nonce, :binary)
    field(:auth_tag, :binary)
    field(:wrap_auth_tag, :binary)
    field(:aad, :binary)

    field(:wrapping_key_ref, :string)
    field(:wrapping_key_version, :integer, default: 1)

    field(:created_at, :utc_datetime)
    field(:created_by, :string)
    field(:disabled_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          namespace: String.t(),
          name: String.t(),
          key_id: pos_integer(),
          purpose: :webhook_hmac | :generic | :script_hmac,
          status: :active | :disabled | :deleted,
          algorithm: :aes_256_gcm,
          wrapped_key_algorithm: :aes_256_gcm,
          ciphertext: binary(),
          wrapped_data_key: binary(),
          nonce: binary(),
          wrap_nonce: binary(),
          auth_tag: binary(),
          wrap_auth_tag: binary(),
          aad: binary(),
          wrapping_key_ref: String.t(),
          wrapping_key_version: pos_integer(),
          created_at: DateTime.t(),
          created_by: String.t(),
          disabled_at: DateTime.t() | nil,
          deleted_at: DateTime.t() | nil
        }

  @name_format ~r/^[a-z0-9_-]+$/

  @doc """
  Structural changeset for `Letflow.Secrets.put/2`. Casts every column
  except `:disabled_at`/`:deleted_at` (both remain `nil` at insert).
  `validate_format/3` on `:namespace`/`:name` is defense in depth alongside
  `put/2`'s own pre-DB regex check (design §3.1 step 1) — this is what
  actually enforces the format at the DB-write boundary if that pre-check
  were ever bypassed by a future caller.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(secret, attrs) do
    secret
    |> cast(attrs, [
      :tenant_id,
      :namespace,
      :name,
      :key_id,
      :purpose,
      :status,
      :algorithm,
      :wrapped_key_algorithm,
      :wrapped_data_key,
      :nonce,
      :wrap_nonce,
      :auth_tag,
      :wrap_auth_tag,
      :aad,
      :wrapping_key_ref,
      :wrapping_key_version,
      :created_at,
      :created_by
    ])
    # `:ciphertext` is cast separately with `empty_values: []` so a 0-byte
    # value actually reaches `changes` instead of being cast-time-filtered
    # to "not present" (Ecto's `cast/4` treats any value matching
    # `changeset.empty_values`, default `[""]`, as absent -- and `""`/`<<>>`
    # are the same term in Elixir, so a 0-byte `:binary` is
    # indistinguishable from an empty string at that filter).
    |> cast(attrs, [:ciphertext], empty_values: [])
    |> validate_required([
      :tenant_id,
      :namespace,
      :name,
      :key_id,
      :purpose,
      :status,
      :algorithm,
      :wrapped_key_algorithm,
      :wrapped_data_key,
      :nonce,
      :wrap_nonce,
      :auth_tag,
      :wrap_auth_tag,
      :aad,
      :wrapping_key_ref,
      :wrapping_key_version,
      :created_at,
      :created_by
    ])
    |> validate_ciphertext_present()
    |> validate_format(:namespace, @name_format)
    |> validate_format(:name, @name_format)
    |> unique_constraint([:tenant_id, :namespace, :name, :key_id],
      name: :secrets_tenant_namespace_name_key_id_index
    )
  end

  # `validate_required/2` itself independently re-checks each field against
  # `changeset.empty_values` (default `[""]`), regardless of how the value
  # reached `changes` -- so even after the `empty_values: []` cast above
  # puts a literal `""` into `changes.ciphertext`, `validate_required/2`
  # would still call it blank (`"" in [""]` is `true`). A 0-byte ciphertext
  # is a valid ciphertext for a 0-byte plaintext (AES-256-GCM ciphertext
  # length always equals plaintext length), not a missing value, so this
  # checks only genuine absence (`nil`, or never cast at all) and bypasses
  # `changeset.empty_values` entirely.
  @spec validate_ciphertext_present(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_ciphertext_present(changeset) do
    case Map.get(changeset.changes, :ciphertext, changeset.data.ciphertext) do
      nil -> add_error(changeset, :ciphertext, "can't be blank", validation: :required)
      _binary -> changeset
    end
  end

  @doc """
  Structural changeset for `Letflow.Secrets.disable/2`. Casts **only**
  `:status, :disabled_at` — `created_by` is never in this changeset's cast
  list at all (design §3.3/§7's structural fix for R-Co's `created_by`-
  overwrite defect).
  """
  @spec disable_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def disable_changeset(secret, attrs) do
    secret
    |> cast(attrs, [:status, :disabled_at])
    |> validate_required([:status, :disabled_at])
  end
end
