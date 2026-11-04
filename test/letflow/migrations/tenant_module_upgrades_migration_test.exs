defmodule Letflow.TenantModuleUpgradesMigrationTest do
  @moduledoc """
  GH #3578 / REQ-640 criteria 6-8 (tests T1..T8): the tenant migration that creates the empty
  `tenant_module_upgrades` journal table, its schema, provisioning registration and isolation.
  `async: false` (tenant provisioning and DDL).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Repo.Migrations.CreateTenantModuleUpgrades
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_101_100_001
  @columns ~w(id module_id from_version to_version kind state plan_hash actor_id rationale step_id
              step_cursor steps_done touches catchup_from_seq runner_id epoch heartbeat_at
              started_at finished_at error_code)

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r640-mig")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  defp column_names(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'tenant_module_upgrades'",
        [schema]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp attrs(over \\ %{}),
    do:
      Map.merge(
        %{
          module_id: "catalog_items",
          from_version: "0.1.0",
          to_version: "0.2.0",
          kind: :upgrade,
          state: :planned
        },
        over
      )

  test "T1 exactly the 20 columns and no tenant_id", %{schema: schema} do
    assert column_names(schema) == Enum.sort(@columns)
    assert length(@columns) == 20
    refute "tenant_id" in column_names(schema)
  end

  test "T2 kind uninstall is refused, nothing inserted", %{schema: schema} do
    cs = TenantModuleUpgrade.changeset(%TenantModuleUpgrade{}, attrs(%{kind: :uninstall}))
    refute cs.valid?
    assert {:error, _} = Repo.insert(cs, prefix: schema)
    assert Repo.all(TenantModuleUpgrade, prefix: schema) == []
  end

  test "T3 five states accepted, a sixth is refused", %{schema: schema} do
    for state <- [:planned, :running, :failed, :done, :abandoned] do
      cs = TenantModuleUpgrade.changeset(%TenantModuleUpgrade{}, attrs(%{state: state}))
      assert {:ok, _} = Repo.insert(cs, prefix: schema)
    end

    refute TenantModuleUpgrade.changeset(%TenantModuleUpgrade{}, attrs(%{state: :bogus})).valid?
    assert length(Repo.all(TenantModuleUpgrade, prefix: schema)) == 5
  end

  test "T4 upgrade and rollback round-trip with defaults", %{schema: schema} do
    for kind <- [:upgrade, :rollback] do
      cs =
        TenantModuleUpgrade.changeset(
          %TenantModuleUpgrade{},
          attrs(%{kind: kind, touches: %{"a" => 1}})
        )

      assert {:ok, row} = Repo.insert(cs, prefix: schema)
      back = Repo.get!(TenantModuleUpgrade, row.id, prefix: schema)
      assert back.kind == kind
      assert back.epoch == 1
      assert back.steps_done == []
      assert back.touches == %{"a" => 1}
    end
  end

  test "T5 registered last, fresh tenant has it, replay restores a missing one", %{
    schema: schema,
    tenant_id: tenant_id
  } do
    # later migrations append after it (REQ-692 added CreateLedgerPerLedgerIdKeys, REQ-710
    # CreateLedgerPartitionedTables, REQ-711 MoveLedgerFksToPartitions)
    manifest = TenantProvisioning.tenant_scoped_migrations()
    assert {@version, CreateTenantModuleUpgrades} = Enum.at(manifest, -4)

    assert {20_261_104_100_001, Letflow.Repo.Migrations.CreateLedgerPerLedgerIdKeys} =
             Enum.at(manifest, -3)

    assert {20_261_104_200_001, Letflow.Repo.Migrations.CreateLedgerPartitionedTables} =
             Enum.at(manifest, -2)

    assert {20_261_104_300_001, Letflow.Repo.Migrations.MoveLedgerFksToPartitions} =
             List.last(manifest)

    assert column_names(schema) != []

    Repo.query!(~s(DROP TABLE "#{schema}".tenant_module_upgrades))
    Repo.query!(~s(DELETE FROM "#{schema}".schema_migrations WHERE version = $1), [@version])
    assert column_names(schema) == []

    assert {:ok, _} = TenantProvisioning.replay_migrations(tenant_id)
    assert column_names(schema) == Enum.sort(@columns)
    assert Repo.all(TenantModuleUpgrade, prefix: schema) == []
  end

  test "T6 a row in tenant A is invisible in tenant B; no public table", %{schema: a} do
    b = TenantFixture.provisioned_tenant!(slug_prefix: "r640-mb").schema_name
    cs = TenantModuleUpgrade.changeset(%TenantModuleUpgrade{}, attrs())
    assert {:ok, _} = Repo.insert(cs, prefix: a)
    assert length(Repo.all(TenantModuleUpgrade, prefix: a)) == 1
    assert Repo.all(TenantModuleUpgrade, prefix: b) == []

    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' " <>
          "AND table_name = 'tenant_module_upgrades'"
      )

    assert rows == []
  end

  test "T7 the fixture table list carries the table" do
    assert "tenant_module_upgrades" in TenantFixture.expected_tenant_tables()

    assert Enum.count(TenantFixture.expected_tenant_tables(), &(&1 == "tenant_module_upgrades")) ==
             1
  end

  test "T8 only the schema, the provisioning list and moduledocs mention the table in lib" do
    hits =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "tenant_module_upgrades"))
      |> Enum.sort()

    assert hits == [
             "lib/letflow/modules/tenant_module_upgrade.ex",
             "lib/letflow/tenant_provisioning.ex"
           ]
  end
end
