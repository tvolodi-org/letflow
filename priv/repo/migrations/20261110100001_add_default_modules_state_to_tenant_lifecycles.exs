# Letflow.Repo.Migrations.AddDefaultModulesStateToTenantLifecycles
#
# T-1580 / TA-SL4 (decision 0072 D8): the state of the default-module install that runs as the last step of
# a provisioner create. GLOBAL table (like `owner_grant_stored`); not a tenant-scoped migration.
# Expand-only: existing rows (already on QA) get `not_applicable` from the column default, so a replay of an
# old tenant installs nothing. `default_modules_failure` holds `"<module_id>:<code>"` only, never SQL text.
defmodule Letflow.Repo.Migrations.AddDefaultModulesStateToTenantLifecycles do
  use Ecto.Migration

  def change do
    alter table(:tenant_lifecycles) do
      add :default_modules_state, :text, null: false, default: "not_applicable"
      add :default_modules_failure, :text
    end

    create constraint(:tenant_lifecycles, :tenant_lifecycles_default_modules_state_chk,
             check: "default_modules_state IN ('not_applicable', 'pending', 'done', 'failed')"
           )
  end
end
