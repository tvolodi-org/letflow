defmodule Letflow.Definitions.SolutionPackOverride do
  @moduledoc """
  Ecto schema for the per-tenant table `solution_pack_overrides` (REQ-596 / GH #3353 part A,
  decision 0069 D2/D3). One row per `(override_id, override_version)`; rows are only ever
  inserted (see `Letflow.Definitions.SolutionPackOverrides`). `status` is `active`, `retired` or
  `orphaned` (REQ-617: the artefact left the pack or the property is no longer overridable).

  There is no `tenant_id` column: the tenant is the schema `:prefix` (decision 0006 D2), and the
  schema carries no `@schema_prefix`, so every call must pass `prefix:`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "solution_pack_overrides" do
    field(:override_id, Ecto.UUID)
    field(:override_version, :integer)
    field(:pack_id, :string)
    field(:artefact_type, :string)
    field(:artefact_id, :string)
    field(:made_against, :string)
    field(:patch, :map)
    field(:patch_hash, :string)
    field(:status, :string)
    field(:reason, :string)
    field(:created_by, Ecto.UUID)
    field(:inserted_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
