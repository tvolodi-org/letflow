defmodule Letflow.CreateErrorGroupsTest do
  @moduledoc """
  T-1951 EC-17: the tenant migration that creates the empty `error_groups` table: manifest registration,
  shape, the unique signature index and the source/kind CHECKs. `async: false` (tenant DDL).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo.Migrations.CreateErrorGroups
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_114_300_001

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1951-mig")
    {:ok, schema: tenant.schema_name}
  end

  test "EC-17 registered last, in the expected tables, empty, with the planned columns", %{
    schema: schema
  } do
    assert {@version, CreateErrorGroups} =
             List.keyfind(TenantProvisioning.tenant_scoped_migrations(), @version, 0)

    assert "error_groups" in TenantFixture.expected_tenant_tables()
    assert %{rows: [[0]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".error_groups|)

    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'error_groups'",
        [schema]
      )

    assert rows |> List.flatten() |> Enum.sort() ==
             ~w(alerted_new_at count error_type first_seen_at growth_alerted_hour hour_bucket hour_count id inserted_at kind last_seen_at last_trace_ids method route seq signature source status tenant_id tenant_ids top_frame updated_at message)
             |> Enum.sort()

    %{rows: [[idx]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_indexes WHERE schemaname = $1 AND tablename = 'error_groups' " <>
          "AND indexname = 'error_groups_signature_index'",
        [schema]
      )

    assert idx == 1
  end

  test "EC-17 the CHECKs refuse an unknown source and kind, the signature is unique", %{
    schema: schema
  } do
    insert = fn sig, source, kind ->
      Repo.query(
        ~s|INSERT INTO "#{schema}".error_groups (id, tenant_id, signature, source, kind, method, route, error_type, top_frame, status, hour_bucket, first_seen_at, last_seen_at, inserted_at, updated_at) | <>
          "VALUES (gen_random_uuid(), gen_random_uuid(), $1, $2, $3, 'GET', '/r', 'E', '', 500, now(), now(), now(), now(), now())",
        [sig, source, kind]
      )
    end

    assert {:ok, _} = insert.("s1", "server", "exception")
    assert {:error, %Postgrex.Error{}} = insert.("s2", "x", "exception")
    assert {:error, %Postgrex.Error{}} = insert.("s3", "server", "y")
    assert {:error, %Postgrex.Error{}} = insert.("s1", "server", "exception")
  end
end
