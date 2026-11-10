# Letflow.Repo.Migrations.AddSourceKeysToTenantLifecycles
#
# T-1621 / TA-SL5: SHA-256 digests of the visitor source and of the owner e-mail domain of a provisioner
# create, for the rolling 24 h creation budgets. GLOBAL table. Expand-only: both columns are nullable, so
# rows already on QA stay NULL and are simply not counted. Raw values are never stored.
defmodule Letflow.Repo.Migrations.AddSourceKeysToTenantLifecycles do
  use Ecto.Migration

  def change do
    alter table(:tenant_lifecycles) do
      add :source_ip_key, :binary
      add :email_domain_key, :binary
    end

    create index(:tenant_lifecycles, [:source_ip_key, :inserted_at])
    create index(:tenant_lifecycles, [:email_domain_key, :inserted_at])
  end
end
