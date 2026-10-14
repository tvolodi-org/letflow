# Letflow.Repo.Migrations.CreateRoleScopeGrants
#
# REQ-497 / GH #2533 PR 1a (decision 0051 D1, D3, D8) -- see
# lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md section 1 for the
# design.
#
# The per-tenant `role_scope_grants` table, with its backfill and the T9 assert, in ONE
# migration transaction: lock A (the tenant admin advisory lock) is the FIRST command, then the
# DDL, then the backfill of one tenant-wide GROUP row per `:platform_role` binding, the frozen
# T9 count (aborts the migration when non-zero) and one `scope.backfill_completed` audit entry
# for a real tenant that had bindings.
#
# The insert and the T9 count are frozen SQL here, NOT calls into
# `Letflow.Identity.RoleScopeGrants`: a replayed historical migration must keep its semantics
# when application code evolves (precedent: 20260926010001_backfill_exam_tenant_modules.exs).
# Parity with the application's T9 function is pinned by a test.
#
# PLACEMENT: per-tenant (0006 D2: no tenant_id column). No FK on `scope_node_id` in 1a: it is
# deferred to stage 2 (GH #2535), design section 1.3.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, and so is this
# file's registration in `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`.
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7); the only
# interpolation is the schema name from `prefix()`. The lock key is a bound parameter.
defmodule Letflow.Repo.Migrations.CreateRoleScopeGrants do
  use Ecto.Migration

  @migration_version 20_261_015_025_331

  @typedoc "The counts `run_backfill!/1` returns (design section 1.2)."
  @type backfill_counts :: %{
          platform_role_bindings: non_neg_integer(),
          group_rows_inserted: non_neg_integer(),
          user_rows_inserted: 0,
          process_routing_bindings_skipped: non_neg_integer(),
          bindings_without_row_after: 0
        }

  @spec up() :: any()
  def up do
    if prefix() do
      schema = prefix()

      # Lock A before any DDL or read (design section 1.2, SEC advisory 1).
      execute(fn -> lock_tenant_admins_in_migration!(schema) end)
      create_objects(schema)
      execute(fn -> run_backfill!(schema) end)
    end
  end

  @spec down() :: any()
  def down do
    if prefix() do
      drop table(:role_scope_grants, prefix: prefix())
    end
  end

  @doc """
  Takes the tenant admin lock (`Letflow.Identity.tenant_admin_lock_key/1`, bound) for the
  rest of the migration transaction. Public only so a test migration can drive it.
  """
  @spec lock_tenant_admins_in_migration!(schema :: String.t()) :: :ok
  def lock_tenant_admins_in_migration!(schema) do
    Letflow.Repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [
      Letflow.Identity.tenant_admin_lock_key(schema)
    ])

    :ok
  end

  @doc """
  Queues the DDL of the table, its CHECKs and its indexes (no FK in 1a). Must be called from
  a migration's `up/0`. Public only so a test migration can drive it.
  """
  @spec create_objects(schema :: String.t()) :: any()
  def create_objects(schema) do
    create table(:role_scope_grants, primary_key: false, prefix: schema) do
      add :id, :binary_id, primary_key: true
      add :principal_type, :text, null: false
      add :principal_id, :binary_id, null: false
      add :role, :text, null: false
      add :scope_node_id, :text
      add :tenant_wide, :boolean, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:role_scope_grants, :role_scope_grants_tenant_wide_xor_node,
             check:
               "(tenant_wide AND scope_node_id IS NULL) OR " <>
                 "(NOT tenant_wide AND scope_node_id IS NOT NULL)",
             prefix: schema
           )

    create constraint(:role_scope_grants, :role_scope_grants_principal_type_check,
             check: "principal_type IN ('user', 'group')",
             prefix: schema
           )

    create index(:role_scope_grants, [:principal_type, :principal_id, :role],
             name: :role_scope_grants_principal_role_idx,
             prefix: schema
           )

    create unique_index(:role_scope_grants, [:principal_type, :principal_id, :role],
             name: :role_scope_grants_tenant_wide_uniq,
             where: "tenant_wide",
             prefix: schema
           )

    create unique_index(
             :role_scope_grants,
             [:principal_type, :principal_id, :role, :scope_node_id],
             name: :role_scope_grants_scoped_uniq,
             where: "NOT tenant_wide",
             prefix: schema
           )

    create index(:role_scope_grants, [:scope_node_id],
             name: :role_scope_grants_scope_node_id_idx,
             where: "scope_node_id IS NOT NULL",
             prefix: schema
           )
  end

  @doc """
  The backfill (design section 1.4): counts the bindings, inserts one tenant-wide group row
  per `:platform_role` binding (idempotent), asserts T9 is 0 and writes the
  `scope.backfill_completed` audit entry for a real tenant with bindings. Lock A must already
  be held. Raises (aborting the migration) on a gap or an audit failure.
  """
  @spec run_backfill!(schema :: String.t()) :: backfill_counts()
  def run_backfill!(schema) do
    %Postgrex.Result{rows: [[platform_role_bindings, process_routing_bindings]]} =
      Letflow.Repo.query!(
        """
        SELECT count(*) FILTER (WHERE kind = 'platform_role'),
               count(*) FILTER (WHERE kind = 'process_routing_role')
          FROM "#{schema}".tenant_role
        """,
        []
      )

    %Postgrex.Result{num_rows: group_rows_inserted} =
      Letflow.Repo.query!(
        """
        INSERT INTO "#{schema}".role_scope_grants
          (id, principal_type, principal_id, role, scope_node_id, tenant_wide,
           inserted_at, updated_at)
        SELECT gen_random_uuid(), 'group', t.group_id, t.name, NULL, true, now(), now()
          FROM "#{schema}".tenant_role t
         WHERE t.kind = 'platform_role'
        ON CONFLICT (principal_type, principal_id, role) WHERE tenant_wide DO NOTHING
        """,
        []
      )

    :ok = assert_no_gap!(schema)

    counts = %{
      platform_role_bindings: platform_role_bindings,
      group_rows_inserted: group_rows_inserted,
      user_rows_inserted: 0,
      process_routing_bindings_skipped: process_routing_bindings,
      bindings_without_row_after: 0
    }

    :ok = audit_backfill!(schema, counts)
    counts
  end

  @doc """
  The frozen T9 count: `:platform_role` bindings with no group row of any `tenant_wide` value.
  Raises `RuntimeError` (message prefix `"role_scope_grants backfill gap:"`, count only, INV-4)
  when it is non-zero.
  """
  @spec assert_no_gap!(schema :: String.t()) :: :ok
  def assert_no_gap!(schema) do
    %Postgrex.Result{rows: [[gap]]} =
      Letflow.Repo.query!(
        """
        SELECT count(*)
          FROM "#{schema}".tenant_role t
         WHERE t.kind = 'platform_role'
           AND NOT EXISTS (
             SELECT 1
               FROM "#{schema}".role_scope_grants g
              WHERE g.principal_type = 'group'
                AND g.principal_id = t.group_id
                AND g.role = t.name
           )
        """,
        []
      )

    if gap != 0, do: raise(RuntimeError, "role_scope_grants backfill gap: #{gap}")

    :ok
  end

  # Design section 1.5: only for a real tenant schema (skips `tenant_template`) that had
  # bindings (a new tenant replays before seeding, so it has none and gets no entry).
  defp audit_backfill!(schema, counts) do
    with {:ok, tenant_id} <- Letflow.TenantProvisioning.tenant_id_for_schema_name(schema),
         true <- counts.platform_role_bindings > 0 do
      attrs = %{
        actor_id: nil,
        action: "scope.backfill_completed",
        resource_type: "role_scope_grants",
        resource_id: tenant_id,
        before_state: nil,
        after_state: %{
          "source" => "migration",
          "migration_version" => @migration_version,
          "platform_role_bindings" => counts.platform_role_bindings,
          "group_rows_inserted" => counts.group_rows_inserted,
          "user_rows_inserted" => 0,
          "process_routing_bindings_skipped" => counts.process_routing_bindings_skipped,
          "bindings_without_row_after" => 0
        },
        trace_id: nil
      }

      case Letflow.Audit.insert_entry(Letflow.Repo, attrs, schema) do
        {:ok, _entry} -> :ok
        {:error, _reason} -> raise RuntimeError, "role_scope_grants backfill audit failed"
      end
    else
      _skip -> :ok
    end
  end
end
