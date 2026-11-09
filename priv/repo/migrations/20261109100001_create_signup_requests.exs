# Letflow.Repo.Migrations.CreateSignupRequests
#
# T-1579 / TA-SL2a (docs/uat/ba-decisions/T-1567.md s5, decision 0084) -- the saga table of the public
# sign-up: one row per sign-up request, keyed by the server-generated `tenant_id` that SL2b will use for
# the real tenant. GLOBAL (public schema), no FK to `tenants` (the tenant does not exist yet).
#
# `email` is personal data: nulled when a row is closed as expired. The token exists only in the mail;
# `token_hash` is its SHA-256. One open sign-up per e-mail is enforced by the partial unique index.
defmodule Letflow.Repo.Migrations.CreateSignupRequests do
  use Ecto.Migration

  def change do
    create table(:signup_requests, primary_key: false) do
      add :tenant_id, :binary_id, primary_key: true
      add :email, :text
      add :company_name, :text, null: false
      add :language, :text, null: false
      add :state, :text, null: false
      add :step, :text, null: false
      add :step_attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :token_hash, :binary
      add :token_expires_at, :utc_datetime_usec
      add :send_count, :integer, null: false, default: 0
      add :last_sent_at, :utc_datetime_usec
      add :ip_key, :binary, null: false
      add :terms_version, :text, null: false
      add :terms_accepted_at, :utc_datetime_usec, null: false
      add :verified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:signup_requests, :signup_requests_state_chk,
             check:
               "state IN ('pending_verification', 'verified', 'provisioning', 'completed', 'expired', 'failed')"
           )

    create constraint(:signup_requests, :signup_requests_language_chk,
             check: "language IN ('ru', 'kk', 'en')"
           )

    create unique_index(:signup_requests, [:email],
             where: "state IN ('pending_verification', 'verified', 'provisioning')",
             name: :signup_requests_open_email_index
           )

    create unique_index(:signup_requests, [:token_hash], where: "token_hash IS NOT NULL")
    create index(:signup_requests, [:ip_key, :inserted_at])
    create index(:signup_requests, [:state, :inserted_at])
  end
end
