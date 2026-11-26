defmodule Letflow.TenantProvisioner.Admission do
  @moduledoc """
  T-2727 (pilot gap G17c; `docs/platform-register-tenant-v2.md` section 5): the global
  `tenant_admissions` row, the RESERVATION a create that runs through the
  `platform.register_tenant` definition makes in front of the definition (demo cap and daily
  budgets). `tenant.record_lifecycle` reads it by tenant id and writes the `tenant_lifecycles` row from
  it, so no digest and no expiry value travels through the instance variables.

  Digests only: no raw e-mail, no raw source value, no realm, no name.
  """

  use Ecto.Schema

  @primary_key {:tenant_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "tenant_admissions" do
    field(:tier, :string)
    field(:language, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:source_ip_key, :binary)
    field(:email_domain_key, :binary)
    field(:request_fingerprint, :binary)
    field(:instance_id, :binary_id)

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}
end
