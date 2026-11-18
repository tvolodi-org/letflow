defmodule Letflow.Identity.OnboardingRecord do
  @moduledoc """
  Ecto schema for the `onboarding_registry` table (REQ-076). Structurally global,
  like `tenants`/`tenant_schemas` — see
  `lib/letflow/design/req076-identity-tokens-roles-onboarding.md` §8.1. `id` is the
  `onboarding_id` the requirement text and R-Co both use — no separate column.

  This design's onboarding flow is fully synchronous
  (`Letflow.Identity.create_onboarding/1`'s own @doc) — a row is only ever inserted
  once its `tenant_id` already refers to a real, existing tenant, so there is no
  `:pending` state to represent here (a real divergence from R-Co's saga-backed
  table, deliberate — see the design doc §8.5's "not ported" list).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "onboarding_registry" do
    field(:tenant_id, :binary_id)
    field(:slug, :string)
    field(:hostname, :string)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Changes only the company host, preserving the onboarding identity."
  @spec hostname_changeset(t(), map()) :: Ecto.Changeset.t()
  def hostname_changeset(%__MODULE__{} = record, attrs) do
    record
    |> cast(attrs, [:hostname])
    |> validate_required([:hostname])
    |> unique_constraint(:hostname)
  end

  @doc """
  Insert changeset for `Letflow.Identity.create_onboarding/1`. `attrs` carries
  `tenant_id`/`slug`/`hostname` — all three required.
  """
  @spec insert_changeset(t(), map()) :: Ecto.Changeset.t()
  def insert_changeset(%__MODULE__{} = record, attrs) do
    record
    |> cast(attrs, [:tenant_id, :slug, :hostname])
    |> validate_required([:tenant_id, :slug, :hostname])
    |> unique_constraint(:hostname)
    |> foreign_key_constraint(:tenant_id)
  end
end
