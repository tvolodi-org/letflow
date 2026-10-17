# Letflow.Repo.Migrations.CreateScopeShadowCounters
#
# REQ-517 / GH #2535 PR 2b (design lib/letflow/design/req517-scoped-grants-admin-plane.md
# section 4.7.1) -- the persisted shadow evidence of the scope-enforcement rollout: per UTC
# day, the number of authorized requests observed while the tenant was in `shadow`
# (`metric = 'requests'`) and the would-deny count per reason (the closed six-value set).
# Written ONLY by `Letflow.Api.Scope.ShadowEvidence` (flush of an in-memory ETS counter,
# never on the request path); read by REQ-519's flip. Counts only: no id, no value.
#
# PLACEMENT: per-tenant (0006 D2: no tenant_id column). Every constraint name is explicit
# and under the 63-byte NAMEDATALEN limit.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# Reversible: `change/0` (create table + constraints; `down` drops the table).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`.
defmodule Letflow.Repo.Migrations.CreateScopeShadowCounters do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      create table(:scope_shadow_counters, primary_key: false, prefix: schema) do
        add :day, :date, null: false, primary_key: true
        add :metric, :text, null: false, primary_key: true
        add :count, :bigint, null: false, default: 0
        add :updated_at, :utc_datetime_usec, null: false
      end

      create constraint(:scope_shadow_counters, :scope_shadow_counters_count_check,
               check: "count >= 0",
               prefix: schema
             )

      create constraint(:scope_shadow_counters, :scope_shadow_counters_metric_check,
               check:
                 "metric IN ('requests', 'role_not_held', 'no_grant_rows', 'not_tenant_wide', " <>
                   "'out_of_scope', 'unresolvable', 'grants_unavailable')",
               prefix: schema
             )
    end
  end
end
