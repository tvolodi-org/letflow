defmodule Letflow.Identity.TenantMembership do
  @moduledoc """
  Ecto schema for the `tenant_memberships` table (REQ-384 Part A, design
  `lib/letflow/design/req384-tenant-switcher-cache-isolation.md` §1.1-§1.2).

  Public-schema, global table — same tier as `Letflow.Identity.Tenant`, not
  tenant-scoped (no `opts[:prefix]` anywhere in this module or in
  `Letflow.Identity.list_memberships_for_subject/1`).

  **Admin-write-only.** Nothing in the JIT-provisioning or claim-mapping
  pipeline writes this table — a row here is created only via an explicit
  `PLATFORM_ADMIN` action (design §1.1; no such write path ships with
  REQ-384 itself, see design §10 OQ-2). This module accordingly exposes only
  `create_changeset/2` — no `update_changeset/2` — mirroring
  `Letflow.Identity.GroupMember`'s own insert-or-delete-only shape (a
  membership is granted or revoked, never edited in place).

  `subject_key` is a normalized (lower-cased, trimmed) email — the only
  cross-tenant identity key this codebase has today (design §10 OQ-1 names
  the tradeoff explicitly: two humans sharing an email string across two
  tenants' independently-provisioned `users` rows would be treated as the
  same switchable identity if a `PLATFORM_ADMIN` ever linked them).

  `normalize_subject_key/1` is exported (not private) because
  `Letflow.Routers.Identity`'s `GET /me/memberships` handler must normalize
  the caller's own looked-up email **exactly the same way** this
  changeset's write path does before querying — a mismatch between write-
  and read-side normalization would silently hide or duplicate memberships
  (design §2.2 point 2). This is the single shared implementation both
  sides call.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "tenant_memberships" do
    field(:subject_key, :string)
    belongs_to(:tenant, Letflow.Identity.Tenant, type: :binary_id)
    field(:display_label, :string)

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          subject_key: String.t(),
          tenant_id: Ecto.UUID.t(),
          display_label: String.t() | nil,
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  @doc """
  Changeset for creating a membership row (design §1.2). Casts
  `[:subject_key, :tenant_id, :display_label]`, requires `:subject_key` and
  `:tenant_id`, normalizes `:subject_key` via `normalize_subject_key/1`
  (lower-case, trim) before validating it is email-shaped — a light shape
  check, not full RFC 5322 validation, matching the "shape check, not full
  validation" discipline `Letflow.Identity.Tenant.settings_changeset/2`
  already applies to `locales` (design §1.2).

  No `update_changeset/2` exists on this module — see moduledoc.
  """
  @spec create_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
  def create_changeset(membership, attrs) do
    membership
    |> cast(attrs, [:subject_key, :tenant_id, :display_label])
    |> validate_required([:subject_key, :tenant_id])
    |> normalize_subject_key_change()
    |> validate_change(:subject_key, &validate_email_shape/2)
    |> unique_constraint([:subject_key, :tenant_id])
  end

  @doc """
  Lower-cases and trims `email` — the single normalization both
  `create_changeset/2` (write side) and `Letflow.Routers.Identity`'s
  `GET /me/memberships` handler (read side) apply, so a membership row's
  `subject_key` and a lookup's query key are always comparable (design §2.2
  point 2).
  """
  @spec normalize_subject_key(String.t()) :: String.t()
  def normalize_subject_key(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp normalize_subject_key_change(changeset) do
    update_change(changeset, :subject_key, fn
      value when is_binary(value) -> normalize_subject_key(value)
      other -> other
    end)
  end

  @email_shape_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+\z/

  @doc """
  The shared light email-shape predicate (REQ-435, design §1.5): true only for
  a binary matching the `local@domain.tld` shape. Exported so
  `Letflow.LoginDirectory` and this module's changeset agree on what a valid
  address is, with one implementation. Not full RFC 5322 validation.
  """
  @spec email_shape?(term()) :: boolean()
  def email_shape?(value) when is_binary(value), do: Regex.match?(@email_shape_regex, value)
  def email_shape?(_value), do: false

  defp validate_email_shape(:subject_key, value) do
    if email_shape?(value) do
      []
    else
      [subject_key: "must look like an email address"]
    end
  end
end
