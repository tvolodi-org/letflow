# Letflow.Repo.Migrations.AddCatalogEndpointUrlReservedRefGuard
#
# GH #2638. Implements lib/letflow/design/gh2638-catalog-endpoint-sys-db-guard.md
# (rev 2). Database backstop for the GH #2623 changeset refusal: a catalog
# `endpoint_url` may not reference the engine's reserved `_sys` variable namespace.
# A CHECK on both `service_catalog` and `service_catalog_versions` closes the
# residual that any non-changeset writer (insert_all, operator SQL, a future code
# path) would otherwise bypass.
#
# GLOBAL -- no `prefix:`, not registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0. Both tables are global
# (20260830000001, 20260921000004); this migration inherits that, not a fresh decision.
#
# The pattern is held ONCE, as @reserved_ref_pattern, and spliced into the pre-flight
# and both constraints. It is PostgreSQL ARE, case-SENSITIVE (`~`), and is the Elixir
# placeholder grammar (`\{\{\s*variables\.KEY\s*\}\}`, KEY filtered by
# `VariableMerge.reserved_key?/1`) with `\s` spelled as the explicit ASCII set (not
# `\s`, which follows the DB locale and could match Unicode spaces). A change to that
# grammar or to `reserved_key?/1` must ship a NEW migration replacing both CHECKs.
#
# Pre-flight: the migration aborts, with counts only (never a URL or a name; INV-2/INV-5),
# if either table already holds a violating row. Then NOT VALID + VALIDATE: the split is
# the form that stays correct if the tables grow and the DDL transaction is lifted.
defmodule Letflow.Repo.Migrations.AddCatalogEndpointUrlReservedRefGuard do
  use Ecto.Migration

  @reserved_ref_pattern ~S"\{\{[ \t\n\v\f\r]*variables\._sys(\.[a-zA-Z0-9_.]*)?[ \t\n\v\f\r]*\}\}"

  @live_check :chk_service_catalog_endpoint_url_no_reserved_ref
  @versions_check :chk_service_catalog_versions_endpoint_url_no_reserved_ref

  def up do
    execute("""
    DO $preflight$
    DECLARE
      live_hits bigint;
      version_hits bigint;
    BEGIN
      SELECT count(*) INTO live_hits FROM service_catalog
        WHERE endpoint_url ~ '#{@reserved_ref_pattern}';
      SELECT count(*) INTO version_hits FROM service_catalog_versions
        WHERE endpoint_url ~ '#{@reserved_ref_pattern}';
      IF live_hits > 0 OR version_hits > 0 THEN
        RAISE EXCEPTION
          'GH #2638 pre-flight: % service_catalog and % service_catalog_versions row(s) have an endpoint_url referencing the reserved engine variable namespace; publish a corrected version or delete the entry, then re-run the migration',
          live_hits, version_hits;
      END IF;
    END
    $preflight$
    """)

    create constraint(:service_catalog, @live_check,
             check: "endpoint_url !~ '#{@reserved_ref_pattern}'",
             validate: false
           )

    create constraint(:service_catalog_versions, @versions_check,
             check: "endpoint_url !~ '#{@reserved_ref_pattern}'",
             validate: false
           )

    execute("ALTER TABLE service_catalog VALIDATE CONSTRAINT #{@live_check}")
    execute("ALTER TABLE service_catalog_versions VALIDATE CONSTRAINT #{@versions_check}")
  end

  def down do
    execute("ALTER TABLE service_catalog_versions DROP CONSTRAINT IF EXISTS #{@versions_check}")
    execute("ALTER TABLE service_catalog DROP CONSTRAINT IF EXISTS #{@live_check}")
  end
end
