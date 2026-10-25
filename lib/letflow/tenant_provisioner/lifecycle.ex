defmodule Letflow.TenantProvisioner.Lifecycle do
  @moduledoc """
  REQ-572 / decision 0072 D4: the global `tenant_lifecycles` row of a tenant made by the
  provisioner credential. A tenant without a row is invisible to `/admin/v1` (P6).

  `lifecycle` is `active | suspended | expired | deleted`; `purged_at` is null until a purge has run
  (set once, never cleared; a purged tenant keeps its row). `deletion_requested_at` and `purged_at`
  are written by the DELETE/purge slice, never by this one.
  """

  use Ecto.Schema

  @primary_key {:tenant_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "tenant_lifecycles" do
    field(:lifecycle, :string)
    field(:tier, :string)
    field(:language, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:deletion_requested_at, :utc_datetime_usec)
    field(:purged_at, :utc_datetime_usec)
    field(:owner_grant_stored, :boolean, default: false)

    timestamps()
  end

  @type t :: %__MODULE__{}
end
