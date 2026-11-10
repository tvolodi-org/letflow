# Letflow.Repo.Migrations.AddProvisioningToSignupRequests
#
# T-1593 (TA-SL2b part a, decision 0085) -- the realm step of the public sign-up saga. Five nullable
# columns on the GLOBAL `signup_requests` table (no tenant schema, so the tenant-table pins do not move):
# what the provisioner answered (realm, issuer, template version -- never the one-time password, INV-4),
# the compare-and-set claim that stops a second POST, and when the credential mail went out.
# Existing rows keep NULLs; `step` has no check constraint, `state_chk` already allows provisioning/failed.
defmodule Letflow.Repo.Migrations.AddProvisioningToSignupRequests do
  use Ecto.Migration

  def change do
    alter table(:signup_requests) do
      add :idp_realm_id, :text
      add :idp_issuer, :text
      add :template_version, :text
      add :claimed_at, :utc_datetime_usec
      add :credential_sent_at, :utc_datetime_usec
    end
  end
end
