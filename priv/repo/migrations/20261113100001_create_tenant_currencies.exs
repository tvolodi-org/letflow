# Letflow.Repo.Migrations.CreateTenantCurrencies
#
# REQ-823 / GH #4394 (currency directory C1) -- the tenant's switches over the platform currency
# list: `active` per code and at most one `tenant_currency` row. Switches are public reference
# data, not secrets.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), with `tenant_id uuid NOT NULL` in the
# row as well. The table starts empty in every schema: no existing row is altered, and a tenant
# without a row reads KZT as today (Letflow.Currencies reading rule).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard is MANDATORY, and this file is
# registered in Letflow.TenantProvisioning's manifest (both halves are required). The only
# interpolated value is the trusted `prefix()` schema name, quoted as an identifier (INV-7).
defmodule Letflow.Repo.Migrations.CreateTenantCurrencies do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".tenant_currencies (
        id uuid PRIMARY KEY,
        tenant_id uuid NOT NULL,
        code text NOT NULL CHECK (code ~ '^[A-Z]{3}$'),
        active boolean NOT NULL DEFAULT false,
        tenant_currency boolean NOT NULL DEFAULT false,
        updated_by uuid,
        inserted_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL
      )
      """)

      execute(
        ~s|CREATE UNIQUE INDEX tenant_currencies_code_index ON "#{schema}".tenant_currencies (code)|
      )

      execute(
        ~s|CREATE UNIQUE INDEX tenant_currencies_one_tenant_currency_index ON "#{schema}".tenant_currencies (tenant_currency) WHERE tenant_currency|
      )
    end
  end

  def down do
    if prefix() do
      execute(~s|DROP TABLE IF EXISTS "#{prefix()}"."tenant_currencies"|)
    end
  end
end
