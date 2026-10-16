defmodule Letflow.Definitions.OwnerStampMigrationTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R2 (design 4.10, section 14): the two tenant-scoped migrations are
  registered in the manifest, a provisioned tenant has the nullable stamp columns, the
  all-or-none CHECK and the immutability trigger, `tenant_modules.manifest_hash` is nullable
  with no default, and an EXISTING tenant lacking them receives them through the boot-time
  replay with every existing row NULL (no backfill; OQ-R7).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @stamp_version 20_261_016_100_001
  @stamp_module Letflow.Repo.Migrations.AddOwnerStampToProcessDefinitions
  @hash_version 20_261_016_100_002
  @hash_module Letflow.Repo.Migrations.AddManifestHashToTenantModules

  defp columns(schema, table, names) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, data_type, character_maximum_length, is_nullable, column_default " <>
          "FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 " <>
          "AND column_name = ANY($3) ORDER BY column_name",
        [schema, table, names]
      )

    rows
  end

  @stamp_columns ~w(owner_body_hash owner_manifest_hash owner_module owner_module_version)

  test "both migrations are registered in the tenant-scoped manifest" do
    manifest = TenantProvisioning.tenant_scoped_migrations()
    assert {@stamp_version, @stamp_module} in manifest
    assert {@hash_version, @hash_module} in manifest
  end

  test "a provisioned tenant has nullable, default-less stamp columns" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-r2-mig")

    assert columns(t.schema_name, "process_definitions", @stamp_columns) == [
             ["owner_body_hash", "character varying", 64, "YES", nil],
             ["owner_manifest_hash", "character varying", 64, "YES", nil],
             ["owner_module", "character varying", 255, "YES", nil],
             ["owner_module_version", "character varying", 255, "YES", nil]
           ]

    assert columns(t.schema_name, "tenant_modules", ["manifest_hash"]) ==
             [["manifest_hash", "character varying", 64, "YES", nil]]
  end

  test "the CHECK and the immutability trigger exist in the tenant schema" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-r2-mig-guard")

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*)::int FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid " <>
                 "JOIN pg_namespace n ON n.oid = r.relnamespace WHERE n.nspname = $1 " <>
                 "AND r.relname = 'process_definitions' " <>
                 "AND c.conname = 'process_definitions_owner_stamp_all_or_none'",
               [t.schema_name]
             )

    assert %{rows: [["process_definitions_owner_stamp_immutable"]]} =
             Repo.query!(
               "SELECT tg.tgname FROM pg_trigger tg JOIN pg_class r ON r.oid = tg.tgrelid " <>
                 "JOIN pg_namespace n ON n.oid = r.relnamespace WHERE n.nspname = $1 " <>
                 "AND r.relname = 'process_definitions' AND NOT tg.tgisinternal " <>
                 "AND tg.tgname = 'process_definitions_owner_stamp_immutable'",
               [t.schema_name]
             )
  end

  test "an existing tenant without the objects gets them through replay; rows stay NULL" do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-r2-mig-replay")
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

    q = fn sql -> Repo.query!(sql) end

    q.(
      "DROP TRIGGER process_definitions_owner_stamp_immutable " <>
        ~s[ON "#{schema}"."process_definitions"]
    )

    q.(~s[DROP FUNCTION "#{schema}".process_definitions_owner_stamp_guard()])

    q.(
      ~s[ALTER TABLE "#{schema}"."process_definitions" ] <>
        "DROP CONSTRAINT process_definitions_owner_stamp_all_or_none, " <>
        "DROP COLUMN owner_module, DROP COLUMN owner_module_version, " <>
        "DROP COLUMN owner_manifest_hash, DROP COLUMN owner_body_hash"
    )

    q.(~s[ALTER TABLE "#{schema}"."tenant_modules" DROP COLUMN manifest_hash])

    Repo.query!(
      ~s[DELETE FROM "#{schema}"."schema_migrations" WHERE version = ANY($1)],
      [[@stamp_version, @hash_version]]
    )

    assert columns(schema, "process_definitions", @stamp_columns) == []

    assert {:ok, applied} = TenantProvisioning.replay_migrations(t.tenant_id)
    assert @stamp_version in applied
    assert @hash_version in applied

    assert length(columns(schema, "process_definitions", @stamp_columns)) == 4
    assert length(columns(schema, "tenant_modules", ["manifest_hash"])) == 1

    assert %{rows: [[nil, nil, nil, nil]]} =
             Repo.query!(
               "SELECT owner_module, owner_module_version, owner_manifest_hash, owner_body_hash " <>
                 ~s[FROM "#{schema}"."process_definitions" WHERE id = $1],
               [Ecto.UUID.dump!(existing.id)]
             )

    # the replayed trigger is live: stamping the pre-existing row is refused
    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             Repo.query(
               ~s[UPDATE "#{schema}"."process_definitions" SET owner_module = 'm', ] <>
                 "owner_module_version = '1', owner_manifest_hash = 'h', owner_body_hash = 'h' " <>
                 "WHERE id = $1",
               [Ecto.UUID.dump!(existing.id)]
             )

    assert message =~ "immutable"
  end
end
