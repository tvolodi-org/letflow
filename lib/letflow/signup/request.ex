defmodule Letflow.Signup.Request do
  @moduledoc """
  T-1579 (TA-SL2a): one row of the public sign-up saga, keyed by the server-generated `tenant_id`.
  Global table (public schema); the tenant does not exist yet. See `Letflow.Signup`.
  """

  use Ecto.Schema

  @primary_key {:tenant_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "signup_requests" do
    field(:email, :string)
    field(:company_name, :string)
    field(:language, :string)
    field(:state, :string)
    field(:step, :string)
    field(:step_attempts, :integer, default: 0)
    field(:last_error, :string)
    field(:token_hash, :binary)
    field(:token_expires_at, :utc_datetime_usec)
    field(:send_count, :integer, default: 0)
    field(:last_sent_at, :utc_datetime_usec)
    field(:ip_key, :binary)
    # T-1620: SHA-256 of the e-mail domain (the plain domain is not stored); NULL on older rows.
    field(:domain_key, :binary)
    field(:terms_version, :string)
    field(:terms_accepted_at, :utc_datetime_usec)
    field(:verified_at, :utc_datetime_usec)
    # T-1593: realm step (decision 0085). The one-time password is never a column.
    field(:idp_realm_id, :string)
    field(:idp_issuer, :string)
    field(:template_version, :string)
    field(:claimed_at, :utc_datetime_usec)
    field(:credential_sent_at, :utc_datetime_usec)

    timestamps()
  end
end
