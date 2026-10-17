# Letflow.Repo.Migrations.AddScopeNodeFkeyToRoleScopeGrants
#
# REQ-517 / GH #2535 PR 2a (decision 0051 D1; design
# lib/letflow/design/req517-scoped-grants-admin-plane.md section 3.6.1).
#
# The foreign key from `role_scope_grants.scope_node_id` to `scope_node_paths.node_id`,
# ON DELETE RESTRICT (a node a grant names can never be deleted). Lock A (the tenant admin
# advisory lock) is the FIRST command, then a frozen SQL precheck (not a call into application
# code: a replayed historical migration keeps its semantics) that aborts when a scoped row
# names an unknown node. The message carries the COUNT only (INV-4). Stage 1 wrote no scoped
# row, so every existing tenant passes.
#
# The constraint name is 36 bytes, under Postgres's 63-byte NAMEDATALEN limit. The only
# interpolation is the schema name from `prefix()` (INV-7); the lock key is a bound parameter.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
defmodule Letflow.Repo.Migrations.AddScopeNodeFkeyToRoleScopeGrants do
  use Ecto.Migration

  @spec up() :: any()
  def up do
    if prefix() do
      schema = prefix()

      execute(fn ->
        lock_tenant_admins_in_migration!(schema)
        assert_no_dangling_nodes!(schema)
      end)

      execute("""
      ALTER TABLE "#{schema}".role_scope_grants
        ADD CONSTRAINT role_scope_grants_scope_node_id_fkey
        FOREIGN KEY (scope_node_id) REFERENCES "#{schema}".scope_node_paths (node_id)
        ON DELETE RESTRICT
      """)
    end
  end

  @spec down() :: any()
  def down do
    if prefix() do
      schema = prefix()

      # A replay may find neither table (guarded by to_regclass on both).
      execute("""
      DO $$
      BEGIN
        IF to_regclass('"#{schema}".role_scope_grants') IS NOT NULL
           AND to_regclass('"#{schema}".scope_node_paths') IS NOT NULL THEN
          ALTER TABLE "#{schema}".role_scope_grants
            DROP CONSTRAINT IF EXISTS role_scope_grants_scope_node_id_fkey;
        END IF;
      END
      $$
      """)
    end
  end

  defp lock_tenant_admins_in_migration!(schema) do
    Letflow.Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [
      Letflow.Identity.tenant_admin_lock_key(schema)
    ])

    :ok
  end

  # Frozen precheck: raises with a count only when a scoped row names an unknown node.
  defp assert_no_dangling_nodes!(schema) do
    %Postgrex.Result{rows: [[dangling]]} =
      Letflow.Repo.query!(
        """
        SELECT count(*)
          FROM "#{schema}".role_scope_grants g
         WHERE g.scope_node_id IS NOT NULL
           AND NOT EXISTS (
             SELECT 1 FROM "#{schema}".scope_node_paths n WHERE n.node_id = g.scope_node_id
           )
        """,
        []
      )

    if dangling != 0, do: raise(RuntimeError, "role_scope_grants fk precheck: #{dangling}")

    :ok
  end
end
