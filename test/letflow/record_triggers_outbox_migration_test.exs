defmodule Letflow.RecordTriggersOutboxMigrationTest do
  @moduledoc """
  REQ-606 / GH #3411 part 1 (criterion 1): the tenant migration that creates `record_trigger_outbox`.
  `async: false` (tenant provisioning and DDL).
  """

  use Letflow.DataCase, async: false

  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_029_200_001
  @module Letflow.Repo.Migrations.CreateRecordTriggerOutbox

  setup do
    {:ok, schema: TenantFixture.provisioned_tenant!(slug_prefix: "r606-mig").schema_name}
  end

  defp table_exists?(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables " <>
          "WHERE table_schema = $1 AND table_name = 'record_trigger_outbox'",
        [schema]
      )

    n == 1
  end

  test "M1 a provisioned tenant has the table, the partial index, defaults and no tenant_id", %{
    schema: schema
  } do
    assert table_exists?(schema)

    %{rows: [[index_def]]} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 " <>
          "AND indexname = 'record_trigger_outbox_backlog_index'",
        [schema]
      )

    assert index_def =~ "WHERE"
    assert index_def =~ "pending"
    assert index_def =~ "running"

    %{rows: defaults} =
      Repo.query!(
        "SELECT column_name, column_default FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'record_trigger_outbox' " <>
          "AND column_name IN ('status', 'attempt')",
        [schema]
      )

    defaults = Map.new(defaults, fn [name, default] -> {name, default} end)
    assert defaults["status"] =~ "pending"
    assert defaults["attempt"] =~ "0"

    %{rows: [[tenant_id_columns]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'record_trigger_outbox' " <>
          "AND column_name = 'tenant_id'",
        [schema]
      )

    assert tenant_id_columns == 0
  end

  test "M2 the migration is registered for new tenants" do
    assert {@version, @module} in TenantProvisioning.tenant_scoped_migrations()
  end

  test "M2b an existing tenant gets the table by running the migration over it, empty", %{
    schema: schema
  } do
    Ecto.Migrator.run(Repo, [{@version, @module}], :down, all: true, prefix: schema, log: false)
    refute table_exists?(schema)

    Ecto.Migrator.run(Repo, [{@version, @module}], :up, all: true, prefix: schema, log: false)
    assert table_exists?(schema)

    assert %{rows: [[0]]} =
             Repo.query!(~s|SELECT count(*) FROM "#{schema}".record_trigger_outbox|)
  end

  test "M3 the table is in the tenant table list" do
    assert "record_trigger_outbox" in TenantFixture.expected_tenant_tables()
  end
end
