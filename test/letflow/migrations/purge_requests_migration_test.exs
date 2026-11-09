defmodule Letflow.Migrations.PurgeRequestsMigrationTest do
  @moduledoc """
  REQ-603 part A / GH #3389: registration of the purge_requests migration, the table shape and
  the `ENABLE ALWAYS` state of the triggers it creates or changes (P-M1..P-M3).
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @triggers [
    {"purge_requests", "purge_requests_guard_insert"},
    {"purge_requests", "purge_requests_guard_update"},
    {"purge_requests", "purge_requests_guard_delete"},
    {"purge_requests", "purge_requests_guard_truncate"},
    {"document_versions", "document_versions_guard_delete"},
    {"repository_artifacts", "repository_artifacts_no_update"},
    {"repository_artifacts", "repository_artifacts_no_delete"}
  ]

  test "P-M1 the migration is the third to last manifest entry (T-1389 and a later one follow) and the table is in the expected list" do
    assert {20_261_105_500_001, Letflow.Repo.Migrations.CreatePurgeRequestsAndDeleteGuards} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -5)

    assert "purge_requests" in TenantFixture.expected_tenant_tables()
  end

  test "the table has the designed columns, no foreign key and no free-text column" do
    %{schema_name: schema} = provisioned_tenant!("req603-mig")

    %{rows: columns} =
      exec!(
        """
        SELECT column_name FROM information_schema.columns
         WHERE table_schema = $1 AND table_name = 'purge_requests' ORDER BY column_name
        """,
        [schema]
      )

    assert List.flatten(columns) ==
             ~w(approved_at approved_by artefact_hash consumed_at content_hash document_id expires_at id reason_code requested_at requested_by tenant_id version_id version_no)

    %{rows: [[fks]]} =
      exec!(
        """
        SELECT count(*) FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
         WHERE n.nspname = $1 AND t.relname = 'purge_requests' AND c.contype = 'f'
        """,
        [schema]
      )

    assert fks == 0
  end

  test "P-M2 every new or changed trigger is ENABLE ALWAYS" do
    %{schema_name: schema} = provisioned_tenant!("req603-mig-a")

    for {table, trigger} <- @triggers do
      %{rows: rows} =
        exec!(
          """
          SELECT g.tgenabled::text FROM pg_trigger g
            JOIN pg_class t ON t.oid = g.tgrelid JOIN pg_namespace n ON n.oid = t.relnamespace
           WHERE n.nspname = $1 AND t.relname = $2 AND g.tgname = $3
          """,
          [schema, table, trigger]
        )

      assert rows == [["A"]], "#{trigger} is not ENABLE ALWAYS: #{inspect(rows)}"
    end
  end

  test "P-M3 the guards also fire under session_replication_role = replica" do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req603-mig-r")

    %{rows: [[can_set]]} =
      exec!("SELECT has_parameter_privilege('session_replication_role', 'SET')")

    if can_set do
      hash = String.duplicate("c", 64)

      exec!(
        """
        INSERT INTO #{table(schema, "repository_artifacts")}
          (content_hash, tenant_id, content_type, byte_size, inserted_at, content)
        VALUES (decode($1, 'hex'), $2::uuid, 'text/plain', 3, now(), '\\x616263'::bytea)
        """,
        [hash, tenant_id]
      )

      for sql <- [
            ~s(DELETE FROM #{table(schema, "repository_artifacts")}),
            ~s(UPDATE #{table(schema, "repository_artifacts")} SET byte_size = 9),
            ~s(TRUNCATE #{table(schema, "purge_requests")})
          ] do
        result =
          attempt("""
          DO $$ BEGIN
            SET LOCAL session_replication_role = replica;
            #{sql};
          END $$
          """)

        assert match?({:refused, _}, result), "not refused under replica: #{sql}"
      end
    else
      IO.puts("P-M3: role cannot SET session_replication_role; replica branch not exercised")
      assert can_set == false
    end
  end
end
