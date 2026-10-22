defmodule Letflow.TenantProvisioningScriptEventsTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC17 (design `lib/letflow/design/gh2534-7c-script-handler.md` 0.3, 3, 6):
  `SCRIPT_TASK_COMPLETED` and `SCRIPT_RUN_RECORDED` are registered for a newly provisioned
  tenant and, after `replay_migrations/1`, for a tenant provisioned before the change; both
  7c-1 migrations replay idempotently.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore.Registry.EventType
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @types ["SCRIPT_TASK_COMPLETED", "SCRIPT_RUN_RECORDED"]
  @versions [20_261_015_100_001, 20_261_015_100_002]

  defp registered(schema) do
    EventType
    |> where([t], t.name in ^@types)
    |> select([t], {t.name, t.schema_version})
    |> Repo.all(prefix: schema)
    |> Enum.sort()
  end

  test "new tenant seeded" do
    %{schema_name: schema} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2534-7c-ev")
    assert registered(schema) == [{"SCRIPT_RUN_RECORDED", 1}, {"SCRIPT_TASK_COMPLETED", 2}]
  end

  test "existing tenant seeded on replay" do
    %{tenant_id: tenant_id, schema_name: schema} =
      TenantFixture.provisioned_tenant!(slug_prefix: "gh2534-7c-ev-old")

    # a tenant provisioned before 7c-1 has neither type
    {2, _} = Repo.delete_all(from(t in EventType, where: t.name in ^@types), prefix: schema)
    assert registered(schema) == []

    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
    assert registered(schema) == [{"SCRIPT_RUN_RECORDED", 1}, {"SCRIPT_TASK_COMPLETED", 2}]
  end

  test "migrations idempotent" do
    %{tenant_id: tenant_id, schema_name: schema} =
      TenantFixture.provisioned_tenant!(slug_prefix: "gh2534-7c-ev-mig")

    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)

    applied =
      Repo.all(
        from(m in "schema_migrations", where: m.version in ^@versions, select: m.version),
        prefix: schema
      )

    assert Enum.sort(applied) == @versions

    %{rows: [[table]]} =
      Repo.query!("SELECT to_regclass($1)::text", ["#{schema}.script_task_dispatches"])

    assert table =~ "script_task_dispatches"

    %{rows: triggers} =
      Repo.query!(
        "SELECT tgname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND NOT t.tgisinternal " <>
          "AND tgname IN ('script_task_dispatches_guard', 'lua_script_execution_audit_read_only')",
        [schema]
      )

    assert Enum.sort(List.flatten(triggers)) ==
             ["lua_script_execution_audit_read_only", "script_task_dispatches_guard"]
  end
end
