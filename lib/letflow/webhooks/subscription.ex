defmodule Letflow.Webhooks.Subscription do
  @moduledoc """
  Ecto schema for the `webhook_subscriptions` table. See
  `lib/letflow/design/req181-webhooks-core.md` §2. Ordinary `Ecto.Schema`, no
  process — matches `Letflow.Dlq.Entry`/`Letflow.Identity.ApiToken`'s
  plain-CRUD-table precedent.

  ## `status` — closed `Ecto.Enum`, uppercase (design §0.3/§2.1)

  Stored as the two literal uppercase strings `"ACTIVE"`/`"PAUSED"` —
  deliberately a DIFFERENT convention from `Letflow.Dlq.Entry.status`'s
  lowercase values. This is a different table with its own contract
  (`web/src/types/api.ts`'s `WebhookSubscription.status`), not a re-use of
  the DLQ enum's casing.

  ## `secret_ref`/`secret_key_id` — envelope-encrypted reference storage
  ## (REQ-190, superseding `secret_hash`)

  As of REQ-190 (`docs/migration/decisions/0016-secrets-storage-backend.md`
  §F, `lib/letflow/design/req190-secrets-core.md` §5), the HMAC signing key
  is written into the global `secrets` table via `Letflow.Secrets.put/2` and
  this schema stores only **`secret_ref`** (the unpinned
  `sec://tenant/<tenant>/webhook/<name>` reference — always resolves to the
  current active signing key) and **`secret_key_id`** (the pinned version at
  creation time). The `secret_hash` DB column still exists (blanked to
  `NULL` by `20260830000004_add_secret_ref_to_webhook_subscriptions.exs`,
  not dropped — a blank-not-drop keeps the migration reversible without a
  backfill on rollback and doesn't break any code still referencing the
  column name, the same shape decision 0016 §F traces to `GBL-128`) but
  this struct has **no field mapping to it** — `Ecto.Schema` tolerates an
  unmapped column silently. A hash was never usable as an HMAC signing key
  in the first place (0016 §F): HMAC-SHA256 requires the actual key bytes to
  compute a reproducible MAC, which a one-way hash cannot supply.

  **The plaintext secret is never assigned to any field on this schema,
  never passed to `Ecto.Changeset.cast/3`, and no changeset function defined
  below accepts a `"secret"`/`"plaintext"` key even if a caller supplied
  one** — `Letflow.Secrets.put/2` computes and persists the envelope-encrypted
  ciphertext itself (in the `secrets` table, not here); this module only
  ever holds the resulting reference/key_id, matching the same
  structurally-impossible-not-just-policy invariant `Letflow.Identity.ApiToken`
  established for `token_hash` (INV-4).

  There is deliberately **no `hmac_secret_once` field on this struct at
  all** — it is not persisted anywhere, it exists only as a key in
  `Letflow.Webhooks.create/2`'s own return map. A `Subscription` struct,
  wherever it appears, never carries a plaintext or an `hmac_secret_once`
  key — this is what makes "list/1 or get never includes the plaintext
  secret" true by construction, not by a serialization-layer filter that
  could be forgotten at a future route layer.

  ## `event_types` — plain `{:array, :string}` (design §0.2)

  An open, extensible set — no closed vocabulary is named anywhere reachable
  from this requirement.

  ## No `@schema_prefix`

  Like every other tenant-scoped table in this schema, `webhook_subscriptions`
  lives in many Postgres schemas — one per tenant — so every read and write
  must pass `prefix: schema_name` explicitly at call time.

  ## `created_at`, not `timestamps/1` (design §1)

  `WebhookSubscription`'s contract names `created_at`, and no acceptance
  criterion requires this module to populate an `updated_at` column, so this
  schema declares `created_at` explicitly rather than reaching for the
  `timestamps/1` macro.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "webhook_subscriptions" do
    field(:tenant_id, Ecto.UUID)
    field(:target_url, :string)
    field(:secret_ref, :string)
    field(:secret_key_id, :integer)
    field(:description, :string)
    field(:event_types, {:array, :string}, default: [])

    field(:status, Ecto.Enum,
      values: [:ACTIVE, :PAUSED],
      default: :ACTIVE
    )

    field(:consecutive_failures, :integer, default: 0)
    field(:last_attempt_at, :utc_datetime)
    field(:last_failure_at, :utc_datetime)
    field(:paused_at, :utc_datetime)
    field(:created_at, :utc_datetime)
    # REQ-565 slice 2: the linked outbound integration mapping, or nil (unmapped delivery).
    # No foreign key; see `Letflow.Webhooks.update/3`.
    field(:outbound_mapping_id, :binary_id)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          tenant_id: Ecto.UUID.t(),
          target_url: String.t(),
          secret_ref: String.t(),
          secret_key_id: pos_integer(),
          description: String.t() | nil,
          event_types: [String.t()],
          status: :ACTIVE | :PAUSED,
          consecutive_failures: non_neg_integer(),
          last_attempt_at: DateTime.t() | nil,
          last_failure_at: DateTime.t() | nil,
          paused_at: DateTime.t() | nil,
          created_at: DateTime.t(),
          outbound_mapping_id: Ecto.UUID.t() | nil
        }

  @doc """
  Structural changeset for `Letflow.Webhooks.create/2`. Casts
  `:id, :target_url, :secret_ref, :secret_key_id, :description,
  :event_types, :tenant_id, :created_at` — all caller/context-module-supplied
  at insert time. `:id` is cast (REQ-190, design §5.4 step 2) because
  `create/2` now generates the subscription's id explicitly via
  `Ecto.UUID.generate/0` **before** this changeset is built, so the same id
  can be used as `Letflow.Secrets.put/2`'s `name` — standard Ecto behavior:
  `@primary_key {:id, :binary_id, autogenerate: true}` already permits an
  explicit id to be supplied instead of autogenerated. `secret_ref`/
  `secret_key_id` are computed by the context module (via
  `Letflow.Secrets.put/2`) before this changeset ever sees `attrs` (REQ-190,
  design §5.4 step 3). `created_at` is computed by `create/2` via
  `current_timestamp()` and must be cast here or `cast/3` silently drops it,
  leaving the NOT NULL `created_at` column unset and the insert failing with
  a `not_null_violation`. `status` is **not** cast here — it is fixed at
  `:ACTIVE` via `put_change/3`, never accepted from `attrs`.
  `consecutive_failures` defaults to `0` via the schema's own column default
  and this changeset's `put_change/3` — not caller-settable at creation
  either.
  """
  @spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def insert_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :id,
      :target_url,
      :secret_ref,
      :secret_key_id,
      :description,
      :event_types,
      :tenant_id,
      :created_at
    ])
    |> validate_required([:id, :target_url, :secret_ref, :secret_key_id, :tenant_id, :created_at])
    |> put_change(:status, :ACTIVE)
    |> put_change(:consecutive_failures, 0)
  end

  @doc """
  Structural changeset for `Letflow.Webhooks.update/3`'s status/is_active
  reconciliation (design §3.3). Casts exactly `:status, :paused_at` — the
  two columns that reconciliation ever writes together. Does not touch
  `:target_url, :description, :event_types` — a future requirement that lets
  a caller PATCH those would add its own changeset function, not extend this
  one silently.
  """
  @spec status_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def status_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:status, :paused_at])
    |> validate_required([:status])
  end

  @doc """
  Structural changeset for linking or clearing the outbound integration mapping (REQ-565 slice 2).
  Casts exactly `:outbound_mapping_id`; the caller has already proven the mapping exists, is
  outbound and belongs to the tenant.
  """
  @spec link_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def link_changeset(subscription, attrs) do
    cast(subscription, attrs, [:outbound_mapping_id])
  end

  @doc """
  Structural changeset for `Letflow.Webhooks`' private
  `record_delivery_failure/2` write path (REQ-183, design
  §3.4/§3.4.1). Casts exactly `:consecutive_failures, :last_failure_at,
  :status, :paused_at` — the first writer of `consecutive_failures`/
  `last_failure_at` since `insert_changeset/2` defaulted
  `consecutive_failures` to `0` and never wrote `last_failure_at` at all.
  `validate_required/2` on `:consecutive_failures, :last_failure_at` — both
  are always computed by the caller before this changeset is built; `:status`
  and `:paused_at` are only written together when the auto-pause threshold is
  reached, otherwise omitted from `attrs` entirely.
  """
  @spec failure_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def failure_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:consecutive_failures, :last_failure_at, :status, :paused_at])
    |> validate_required([:consecutive_failures, :last_failure_at])
  end
end
