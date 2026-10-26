defmodule Letflow.RecordTriggersMigrationTest do
  @moduledoc """
  REQ-570 / GH #3248 (criterion 3): the tenant migration that creates `record_trigger_bindings` and
  widens the `script_rules_hook_kind` CHECK to allow `entity_event`. `async: false` (tenant
  provisioning and DDL).
  """

  use Letflow.DataCase, async: false

  alias Letflow.RecordTriggersFixture
  alias Letflow.Scripts.ScriptRule
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_026_400_001
  @module Letflow.Repo.Migrations.CreateRecordTriggerBindings

  setup do
    {:ok, schema: TenantFixture.provisioned_tenant!(slug_prefix: "r570-mig").schema_name}
  end

  defp table_exists?(schema) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables " <>
          "WHERE table_schema = $1 AND table_name = 'record_trigger_bindings'",
        [schema]
      )

    n == 1
  end

  test "M1 a provisioned tenant has the table, its unique index and no foreign key", %{
    schema: schema
  } do
    assert table_exists?(schema)

    %{rows: [[unique_def]]} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 " <>
          "AND indexname = 'record_trigger_bindings_entity_type_event_index'",
        [schema]
      )

    assert unique_def =~ "UNIQUE"
    assert unique_def =~ "(entity_type, event)"

    %{rows: [[fks]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid " <>
          "JOIN pg_namespace n ON n.oid = t.relnamespace " <>
          "WHERE n.nspname = $1 AND t.relname = 'record_trigger_bindings' AND c.contype = 'f'",
        [schema]
      )

    assert fks == 0

    assert %ScriptRule{hook_kind: "entity_event"} =
             RecordTriggersFixture.script!(schema, "entity_event", :draft)

    assert_raise Ecto.ConstraintError, ~r/script_rules_hook_kind/, fn ->
      RecordTriggersFixture.script!(schema, "bogus", :draft)
    end
  end

  test "M2 the migration is registered for new tenants" do
    assert {@version, @module} in TenantProvisioning.tenant_scoped_migrations()
  end

  test "M3 an existing tenant gets the table by running the migration over it, empty", %{
    schema: schema
  } do
    Ecto.Migrator.run(Repo, [{@version, @module}], :down, all: true, prefix: schema, log: false)
    refute table_exists?(schema)

    assert_raise Ecto.ConstraintError, ~r/script_rules_hook_kind/, fn ->
      RecordTriggersFixture.script!(schema, "entity_event", :draft)
    end

    Ecto.Migrator.run(Repo, [{@version, @module}], :up, all: true, prefix: schema, log: false)
    assert table_exists?(schema)
    %{rows: rows} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".record_trigger_bindings|)
    assert rows == [[0]]
    assert %ScriptRule{} = RecordTriggersFixture.script!(schema, "entity_event", :draft)
  end
end
