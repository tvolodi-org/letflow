defmodule Letflow.Engine.LuaScriptAuditRetiredTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC16 (advisor Q11, C17; design `lib/letflow/design/gh2534-7c-script-handler.md`
  sections 3.2 and 10): `lua_script_execution_audit` is read-only history. The writer function
  is gone, the database refuses INSERT/UPDATE/DELETE (`LF001`), no `lib/` code writes the
  table, and existing rows stay readable -- the latter on a DEDICATED, non-pooled tenant schema
  migrated to the version before the read-only trigger (no trigger is ever disabled; there is
  no TRUNCATE trigger, so the pooled reset is untouched).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine.LuaScriptAudit
  alias Letflow.Engine.LuaScriptAudit.AuditRecord
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @read_only_version 20_261_015_100_002

  defp refused?(fun) do
    Repo.transaction(fn ->
      try do
        fun.()
        Repo.rollback(:not_refused)
      rescue
        e in Postgrex.Error -> Repo.rollback({:refused, e.postgres[:pg_code]})
      end
    end)
  end

  test "no writer" do
    Code.ensure_loaded!(LuaScriptAudit)
    refute function_exported?(LuaScriptAudit, :execute_script_for_audit, 6)
    assert Code.ensure_loaded?(LuaScriptAudit.Executor)

    assert Letflow.Engine.LuaScriptAudit.Executor in (Letflow.Engine.Lua.Executor.module_info(
                                                        :attributes
                                                      )[:behaviour] || [])
  end

  test "row trigger refuses INSERT (inside a rolled-back transaction)" do
    %{schema_name: schema} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2534-7c-lsa")

    assert {:error, {:refused, "LF001"}} =
             refused?(fn ->
               Repo.query!(
                 ~s(INSERT INTO "#{schema}".lua_script_execution_audit ) <>
                   "(id, instance_id, manifest_hash, actor_id, inserted_at, updated_at) " <>
                   "VALUES ($1, $2, 'h', $3, now(), now())",
                 [Ecto.UUID.bingenerate(), Ecto.UUID.bingenerate(), Ecto.UUID.bingenerate()]
               )
             end)

    assert Repo.aggregate(AuditRecord, :count, prefix: schema) == 0
  end

  test "history readable (dedicated tenant); UPDATE and DELETE refused there" do
    # real commits (the migrator runs in its own process), like TenantFixture; cleaned on exit
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{slug: Letflow.TenantSlugFixture.unique_slug("gh2534-7c-lsa-hist"), display_name: "LSA"},
        :disabled
      )
      |> Repo.insert!()

    {:ok, %{schema_name: schema}} = TenantProvisioning.provision_tenant_schema(tenant.id)

    on_exit(fn ->
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))

      Repo.delete_all(from(r in TenantProvisioning.Registration, where: r.schema_name == ^schema))

      Repo.delete_all(from(x in Tenant, where: x.id == ^tenant.id))
    end)

    migrations = TenantProvisioning.tenant_scoped_migrations()

    before_version =
      migrations
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&(&1 < @read_only_version))
      |> Enum.max()

    Ecto.Migrator.run(Repo, migrations, :up, to: before_version, prefix: schema, log: false)

    {:ok, history} =
      %AuditRecord{}
      |> AuditRecord.insert_changeset(%{
        instance_id: Ecto.UUID.generate(),
        manifest_hash: "history-hash",
        actor_id: Ecto.UUID.generate()
      })
      |> Repo.insert(prefix: schema)

    Ecto.Migrator.run(Repo, migrations, :up, all: true, prefix: schema, log: false)

    assert [%AuditRecord{id: id, manifest_hash: "history-hash"}] =
             Repo.all(AuditRecord, prefix: schema)

    assert id == history.id

    assert {:error, {:refused, "LF001"}} =
             refused?(fn ->
               %AuditRecord{}
               |> AuditRecord.insert_changeset(%{
                 instance_id: Ecto.UUID.generate(),
                 manifest_hash: "second",
                 actor_id: Ecto.UUID.generate()
               })
               |> Repo.insert!(prefix: schema)
             end)

    assert {:error, {:refused, "LF001"}} =
             refused?(fn ->
               Repo.query!(
                 ~s(UPDATE "#{schema}".lua_script_execution_audit SET manifest_hash = 'x')
               )
             end)

    assert {:error, {:refused, "LF001"}} =
             refused?(fn ->
               Repo.query!(~s(DELETE FROM "#{schema}".lua_script_execution_audit))
             end)

    assert [%AuditRecord{manifest_hash: "history-hash"}] = Repo.all(AuditRecord, prefix: schema)
  end

  test "no lib writer scan" do
    sources = Path.wildcard("lib/**/*.ex")
    assert "lib/letflow/engine/lua_script_audit.ex" in sources

    writers =
      Enum.filter(sources, fn path ->
        source = File.read!(path)

        (source =~ "AuditRecord" and path != "lib/letflow/engine/lua_script_audit.ex") or
          source =~ ~r/INSERT INTO[^;]*lua_script_execution_audit/ or
          (path == "lib/letflow/engine/lua_script_audit.ex" and source =~ "Repo.")
      end)

    assert writers == []
  end
end
