defmodule Letflow.Identity.RoleScopeGrantsFkTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2a, AC 3 and the AC 12 column (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` sections 3.6.1 and 3.6.2; spec
  `test/specs/REQ-517-2a.md`, T-F1..T-F5):

    * the FK `role_scope_grants_scope_node_id_fkey` (`ON DELETE RESTRICT`) from
      `role_scope_grants.scope_node_id` to `scope_node_paths.node_id`: an unknown node is rejected
      at SQL level and mapped to `invalid_scope_node` by the changeset path, a referenced node
      cannot be deleted, `:up` / `:down` round-trip on a populated schema;
    * the frozen precheck aborts `:up` with a COUNT-only message when a scoped row names an unknown
      node (no node id in it);
    * the FK exists on a REPLAYED tenant and on a CLONED test tenant (the template path re-adds
      foreign keys);
    * `users.admin_flagged_service_principal` is `boolean NOT NULL DEFAULT false`, reversible;
    * both migrations are registered, in order, after `AllowExamManagedByStamp`.

  Runs `Ecto.Migrator.run/4` with the tenant prefix, as `TenantProvisioning.replay_migrations/2`
  does. Raw DDL against dedicated tenant schemas, so `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @fk_version 20_261_018_100_001
  @fk_migration Letflow.Repo.Migrations.AddScopeNodeFkeyToRoleScopeGrants
  @flag_version 20_261_018_100_002
  @flag_migration Letflow.Repo.Migrations.AddAdminFlaggedServicePrincipalToUsers
  @stamp_version 20_261_016_120_001
  @constraint "role_scope_grants_scope_node_id_fkey"

  setup do
    # Loads every manifest migration module (they are not compiled into the app).
    migrations = TenantProvisioning.tenant_scoped_migrations()
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r517-fk")
    {:ok, schema: tenant.schema_name, migrations: migrations}
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp migrate(schema, version, module, direction) do
    Ecto.Migrator.run(Repo, [{version, module}], direction,
      all: true,
      prefix: schema,
      log: false
    )
  end

  # `{delete rule, referenced table}` of the FK, or nil.
  defp fk(schema) do
    case Repo.query!(
           """
           SELECT c.confdeltype::text, rel.relname
             FROM pg_constraint c
             JOIN pg_namespace n ON n.oid = c.connamespace
             JOIN pg_class rel ON rel.oid = c.confrelid
            WHERE n.nspname = $1 AND c.conname = $2 AND c.contype = 'f'
           """,
           [schema, @constraint]
         ) do
      %{rows: [[rule, table]]} -> {rule, table}
      %{rows: []} -> nil
    end
  end

  defp raw_grant(schema, node_id) do
    Repo.query(
      ~s|INSERT INTO "#{schema}".role_scope_grants | <>
        ~s|(id, principal_type, principal_id, role, scope_node_id, tenant_wide, inserted_at, updated_at) | <>
        ~s|VALUES (gen_random_uuid(), 'group', gen_random_uuid(), 'TASK_WORKER', $1, false, now(), now())|,
      [node_id]
    )
  end

  defp flag_column(schema) do
    case Repo.query!(
           """
           SELECT data_type, is_nullable, column_default
             FROM information_schema.columns
            WHERE table_schema = $1 AND table_name = 'users'
              AND column_name = 'admin_flagged_service_principal'
           """,
           [schema]
         ) do
      %{rows: [[type, nullable, default]]} -> {type, nullable, default}
      %{rows: []} -> nil
    end
  end

  # ===========================================================================================
  describe "T-F1 an unknown node is rejected" do
    test "at SQL level (foreign_key_violation on the named constraint) and, through the changeset path, as :invalid_scope_node",
         %{schema: schema} do
      assert {:error,
              %Postgrex.Error{postgres: %{code: :foreign_key_violation, constraint: @constraint}}} =
               raw_grant(schema, "no-such-node")

      assert {:error, {:error, :invalid_scope_node}} =
               Repo.transaction(fn ->
                 Repo.rollback(
                   RoleScopeGrants.insert_scoped(
                     :group,
                     Ecto.UUID.generate(),
                     "TASK_WORKER",
                     "no-such-node",
                     schema
                   )
                 )
               end)

      node = RSG.node!(schema)
      assert {:ok, %{num_rows: 1}} = raw_grant(schema, node)
    end
  end

  # ===========================================================================================
  describe "T-F2 / T-F3 the constraint" do
    test "a referenced node cannot be deleted (RESTRICT); the constraint is ON DELETE RESTRICT on scope_node_paths",
         %{schema: schema} do
      node = RSG.node!(schema)
      assert {:ok, %{num_rows: 1}} = raw_grant(schema, node)

      assert fk(schema) == {"r", "scope_node_paths"}

      assert_raise Postgrex.Error, ~r/role_scope_grants_scope_node_id_fkey/, fn ->
        Repo.query!(~s|DELETE FROM "#{schema}".scope_node_paths WHERE node_id = $1|, [node])
      end

      assert %{rows: [[1]]} =
               Repo.query!(
                 ~s|SELECT count(*) FROM "#{schema}".scope_node_paths WHERE node_id = $1|,
                 [node]
               )
    end

    test "apply and rollback: present after :up, absent after :down, present again; the name is under the 63-byte limit",
         %{schema: schema} do
      assert fk(schema) == {"r", "scope_node_paths"}
      assert byte_size(@constraint) <= 63

      assert migrate(schema, @fk_version, @fk_migration, :down) == [@fk_version]
      assert fk(schema) == nil

      # the unknown node is now accepted by the table (no constraint), proving :down really dropped it
      assert {:ok, %{num_rows: 1}} = raw_grant(schema, "dangling")

      Repo.query!(~s|DELETE FROM "#{schema}".role_scope_grants WHERE scope_node_id = 'dangling'|)
      assert migrate(schema, @fk_version, @fk_migration, :up) == [@fk_version]
      assert fk(schema) == {"r", "scope_node_paths"}
    end

    test ":down is idempotent and guarded: rolling back twice does not raise", %{schema: schema} do
      assert migrate(schema, @fk_version, @fk_migration, :down) == [@fk_version]
      # the version row is gone, so a second run is a no-op rather than an error
      assert migrate(schema, @fk_version, @fk_migration, :down) == []
      assert fk(schema) == nil
    end
  end

  # ===========================================================================================
  describe "T-F4 the precheck" do
    test "a scoped row naming an unknown node aborts :up with the COUNT only; the constraint stays absent; removing the row lets :up succeed",
         %{schema: schema} do
      assert migrate(schema, @fk_version, @fk_migration, :down) == [@fk_version]
      assert {:ok, %{num_rows: 1}} = raw_grant(schema, "dangling-node-xyz")

      error =
        assert_raise RuntimeError, fn -> migrate(schema, @fk_version, @fk_migration, :up) end

      assert error.message == "role_scope_grants fk precheck: 1"
      refute error.message =~ "dangling-node-xyz"
      assert fk(schema) == nil

      Repo.query!(
        ~s|DELETE FROM "#{schema}".role_scope_grants WHERE scope_node_id = 'dangling-node-xyz'|
      )

      assert migrate(schema, @fk_version, @fk_migration, :up) == [@fk_version]
      assert fk(schema) == {"r", "scope_node_paths"}
    end

    test "the count is exact for several dangling rows and valid rows are not counted", %{
      schema: schema
    } do
      node = RSG.node!(schema)
      assert migrate(schema, @fk_version, @fk_migration, :down) == [@fk_version]

      for id <- ["gone-1", "gone-2", "gone-3", node], do: assert({:ok, _} = raw_grant(schema, id))

      error =
        assert_raise RuntimeError, fn -> migrate(schema, @fk_version, @fk_migration, :up) end

      assert error.message == "role_scope_grants fk precheck: 3"
    end
  end

  # ===========================================================================================
  describe "T-F5 the FK on a replayed tenant and on a cloned test tenant" do
    test "both carry the constraint and the flag column" do
      cloned = TenantFixture.provisioned_tenant!(slug_prefix: "r517-fk-clone")

      replayed =
        TenantFixture.provisioned_tenant!(slug_prefix: "r517-fk-replay", template: :replay)

      for %{schema_name: schema} <- [cloned, replayed] do
        assert fk(schema) == {"r", "scope_node_paths"}, schema
        assert flag_column(schema) == {"boolean", "NO", "false"}, schema
      end
    end
  end

  # ===========================================================================================
  describe "the flag column migration" do
    test "boolean NOT NULL DEFAULT false; rows survive :down and :up and read false afterwards",
         %{schema: schema} do
      user = RSG.user!(schema)
      assert flag_column(schema) == {"boolean", "NO", "false"}

      assert migrate(schema, @flag_version, @flag_migration, :down) == [@flag_version]
      assert flag_column(schema) == nil

      assert %{rows: [[1]]} =
               Repo.query!(~s|SELECT count(*) FROM "#{schema}".users WHERE id = $1|, [
                 Ecto.UUID.dump!(user.id)
               ])

      assert migrate(schema, @flag_version, @flag_migration, :up) == [@flag_version]
      assert flag_column(schema) == {"boolean", "NO", "false"}

      assert %{rows: [[false]]} =
               Repo.query!(
                 ~s|SELECT admin_flagged_service_principal FROM "#{schema}".users WHERE id = $1|,
                 [Ecto.UUID.dump!(user.id)]
               )
    end
  end

  # ===========================================================================================
  describe "manifest registration" do
    test "both migrations are registered, after AllowExamManagedByStamp and in order", %{
      migrations: migrations
    } do
      assert {@fk_version, @fk_migration} in migrations
      assert {@flag_version, @flag_migration} in migrations

      versions = Enum.map(migrations, &elem(&1, 0))
      index = fn v -> Enum.find_index(versions, &(&1 == v)) end

      assert index.(@stamp_version) < index.(@fk_version)
      assert index.(@fk_version) < index.(@flag_version)
    end
  end
end
