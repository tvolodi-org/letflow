# Letflow.Repo.Migrations.AddVariableLabelsToInstanceProjections
#
# GH #2616, decision record 0062 R2 (restriction-carrying variables, part 1): per-variable
# restriction labels (`%{"var" => ["entity_type.field_name"]}`) stored beside `variables`.
# A label holds a name, never a value.
#
# EXISTING ROWS: `instance_projections` carries live rows in every tenant. The column has a
# DB-level default `{}` (a constant default is metadata-only in Postgres, no table rewrite), and
# `{}` is the correct value for every pre-existing instance: until this change no stored variable
# was derived from a restricted field (the C10 refusal rejected every labelled opt-in).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. Registered in
# Letflow.TenantProvisioning.@tenant_scoped_migration_manifest (both halves are mandatory).
# Sorts after 20260818110001 and 20260901030001, whose table it alters.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7).
defmodule Letflow.Repo.Migrations.AddVariableLabelsToInstanceProjections do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:instance_projections, prefix: prefix()) do
        add :variable_labels, :map, null: false, default: %{}
      end
    end
  end
end
