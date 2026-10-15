defmodule Letflow.Definitions.ActivatedByMigrationTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B1 (TDV F1): `process_definitions.activated_by` is a nullable jsonb
  column with no default and no backfill, registered in the tenant-scoped manifest, and an
  EXISTING tenant lacking it receives it through the boot-time replay with every existing row
  NULL.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_015_200_001
  @module Letflow.Repo.Migrations.AddActivatedByToProcessDefinitions

  defp column(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT data_type, is_nullable, column_default FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'process_definitions' " <>
          "AND column_name = 'activated_by'",
        [schema]
      )

    rows
  end

  test "registered in the tenant-scoped manifest" do
    assert {@version, @module} in TenantProvisioning.tenant_scoped_migrations()
  end

  test "a provisioned tenant has a nullable jsonb column with no default" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-b1-mig")
    assert [["jsonb", "YES", nil]] = column(t.schema_name)
  end

  test "an existing tenant without the column gets it through replay; rows stay NULL" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-b1-replay")
    schema = t.schema_name

    existing =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: "pre-existing",
        version: "1",
        graph: %{"nodes" => [], "edges" => []},
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: schema)

    Repo.query!(~s(ALTER TABLE "#{schema}"."process_definitions" DROP COLUMN activated_by))

    Repo.query!(~s(DELETE FROM "#{schema}"."schema_migrations" WHERE version = $1), [@version])

    assert column(schema) == []

    assert {:ok, applied} = TenantProvisioning.replay_migrations(t.tenant_id)
    assert @version in applied

    assert [["jsonb", "YES", nil]] = column(schema)

    assert %{rows: [[nil]]} =
             Repo.query!(
               ~s(SELECT activated_by FROM "#{schema}"."process_definitions" WHERE id = $1),
               [Ecto.UUID.dump!(existing.id)]
             )
  end
end
