# Letflow.Repo.Migrations.AddDomainKeyToSignupRequests
#
# T-1620 (TA-SL3) -- per-e-mail-domain hourly cap of the public sign-up. One nullable column on the GLOBAL
# `signup_requests` table (no tenant schema, so the tenant-table pins do not move): the SHA-256 of the e-mail
# domain, never the plain domain (same privacy pattern as `ip_key`). Existing rows keep NULL and are simply
# not counted. The index serves the (domain_key, inserted_at) count under the sign-up advisory lock.
defmodule Letflow.Repo.Migrations.AddDomainKeyToSignupRequests do
  use Ecto.Migration

  def change do
    alter table(:signup_requests) do
      add :domain_key, :binary
    end

    create index(:signup_requests, [:domain_key, :inserted_at])
  end
end
