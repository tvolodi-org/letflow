defmodule Letflow.Migrations.CreateEntityTypeExtensionsTest do
  @moduledoc """
  REQ-576 / GH #3258 -- the tenant-scoped migration
  `priv/repo/migrations/20261027300001_create_entity_type_extensions.exs`.

  Real Postgres, real tenant schemas. Constraints are asserted through raw SQL on purpose: the
  DATABASE must refuse the rows (the schema module has no changeset).

  `async: false`: `TenantFixture` flips the SQL sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_027_300_001
  @module Letflow.Repo.Migrations.CreateEntityTypeExtensions
  @filename "20261027300001_create_entity_type_extensions.exs"

  setup do
    %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "t0663-mig")}
  end

  defp table_exists?(schema_name) do
    %{rows: [[present]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables " <>
          "WHERE table_schema = $1 AND table_name = 'entity_type_extensions')",
        [schema_name]
      )

    present
  end

  defp count(schema_name, table) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema_name}"."#{table}"|)
    n
  end

  # Raw INSERT, so only the database's own constraints decide. Returns :ok or the violated
  # constraint's name.
  defp insert_row(tenant, opts \\ []) do
    now = DateTime.utc_now()

    params = [
      Ecto.UUID.bingenerate(),
      Ecto.UUID.dump!(tenant.tenant_id),
      Keyword.get(opts, :entity_type, "order"),
      Keyword.get(opts, :kind, "field"),
      Keyword.get(opts, :name, "x_foo"),
      Keyword.get(opts, :spec, "{}"),
      1,
      Keyword.get(opts, :status, "active"),
      now,
      now
    ]

    sql =
      ~s(INSERT INTO "#{tenant.schema_name}".entity_type_extensions ) <>
        ~s[(id, tenant_id, entity_type, kind, name, spec, "position", status, inserted_at, updated_at) ] <>
        "VALUES ($1, $2, $3, $4, $5, $6::text::jsonb, $7, $8, $9, $10)"

    case Repo.query(sql, params) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{constraint: c}}} when is_binary(c) ->
        c

      {:error, %Postgrex.Error{postgres: %{code: code}}} ->
        code
    end
  end

  test "C1a table has exactly the stated columns, types and NOT NULL", %{tenant: tenant} do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, data_type, is_nullable FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'entity_type_extensions' ORDER BY column_name",
        [tenant.schema_name]
      )

    expected =
      [
        {"entity_type", "text"},
        {"id", "uuid"},
        {"inserted_at", "timestamp with time zone"},
        {"kind", "text"},
        {"name", "text"},
        {"position", "integer"},
        {"spec", "jsonb"},
        {"status", "text"},
        {"tenant_id", "uuid"},
        {"updated_at", "timestamp with time zone"}
      ]
      |> Enum.map(fn {c, t} -> [c, t, "NO"] end)

    assert rows == expected
  end

  test "C1b no foreign key constraint", %{tenant: tenant} do
    %{rows: rows} =
      Repo.query!(
        "SELECT constraint_name FROM information_schema.table_constraints " <>
          "WHERE table_schema = $1 AND table_name = 'entity_type_extensions' " <>
          "AND constraint_type = 'FOREIGN KEY'",
        [tenant.schema_name]
      )

    assert rows == []
  end

  test "C2a name must start with x_", %{tenant: tenant} do
    assert insert_row(tenant, name: "module_field") == "entity_type_extensions_name_chk"
    assert insert_row(tenant, name: "xfoo") == "entity_type_extensions_name_chk"
    assert insert_row(tenant, name: "x_foo") == :ok
  end

  test "C2b kind, status and spec checks", %{tenant: tenant} do
    assert insert_row(tenant, kind: "validation") == "entity_type_extensions_kind_chk"
    assert insert_row(tenant, status: "deleted") == "entity_type_extensions_status_chk"
    assert insert_row(tenant, spec: "[]") == "entity_type_extensions_spec_chk"
    assert insert_row(tenant, status: "retired", spec: ~s({"a": 1})) == :ok
  end

  test "C2c unique on (tenant_id, entity_type, name)", %{tenant: tenant} do
    assert insert_row(tenant) == :ok
    assert insert_row(tenant) == "entity_type_extensions_tenant_type_name_index"
    assert insert_row(tenant, entity_type: "invoice") == :ok
  end

  test "C3a a new tenant has the table with zero rows", %{tenant: tenant} do
    assert table_exists?(tenant.schema_name)
    assert count(tenant.schema_name, "entity_type_extensions") == 0
  end

  test "C3b replay over a provisioned tenant creates the empty table, other counts unchanged",
       %{tenant: tenant} do
    schema = tenant.schema_name
    defs = count(schema, "entity_definitions")
    procs = count(schema, "process_definitions")

    Repo.query!(~s(DROP TABLE "#{schema}".entity_type_extensions))
    Repo.query!(~s(DELETE FROM "#{schema}".schema_migrations WHERE version = $1), [@version])
    refute table_exists?(schema)

    assert {:ok, versions} = TenantProvisioning.replay_migrations(tenant.tenant_id)
    assert @version in versions
    assert table_exists?(schema)
    assert count(schema, "entity_type_extensions") == 0
    assert count(schema, "entity_definitions") == defs
    assert count(schema, "process_definitions") == procs
  end

  test "C3c no prefix creates nothing in public; guard precedes CREATE TABLE" do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables " <>
          "WHERE table_schema = 'public' AND table_name = 'entity_type_extensions'"
      )

    assert n == 0

    source = File.read!(Path.join(["priv", "repo", "migrations", @filename]))
    assert source =~ "TENANT-SCOPED MIGRATION"
    {guard_at, _} = :binary.match(source, "if prefix() do")
    {create_at, _} = :binary.match(source, "CREATE TABLE")
    assert guard_at < create_at
  end

  test "C4a manifest lists the migration as the last row with the file's version" do
    migrations = TenantProvisioning.tenant_scoped_migrations()
    assert List.last(migrations) == {@version, @module}
    assert String.starts_with?(@filename, Integer.to_string(@version))
  end

  test "C4b down drops the table in that schema only", %{tenant: a} do
    b = TenantFixture.provisioned_tenant!(slug_prefix: "t0663-mig-b")
    assert insert_row(a) == :ok
    assert insert_row(b) == :ok

    Ecto.Migrator.run(Repo, [{@version, @module}], :down,
      all: true,
      prefix: a.schema_name,
      log: false
    )

    refute table_exists?(a.schema_name)
    assert table_exists?(b.schema_name)
    assert count(b.schema_name, "entity_type_extensions") == 1
  end
end
