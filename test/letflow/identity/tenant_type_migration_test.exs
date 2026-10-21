defmodule Letflow.Identity.TenantTypeMigrationTest do
  @moduledoc """
  REQ-469 (GH #2476): migration `20261022000001_add_tenant_type_to_tenants`. Runs the migration's
  own `down`/`up` against the test database, so `async: false` and `Sandbox.mode(:auto)`; the
  column is always restored in `after`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Test.SandboxAutoMode

  @version 20_261_022_000_001
  @module Letflow.Repo.Migrations.AddTenantTypeToTenants

  setup do
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    SandboxAutoMode.enter_auto_mode!(Repo)

    Code.require_file(
      Path.expand("priv/repo/migrations/20261022000001_add_tenant_type_to_tenants.exs")
    )

    :ok
  end

  defp column do
    Repo.query!(
      "SELECT is_nullable, column_default FROM information_schema.columns " <>
        "WHERE table_name = 'tenants' AND table_schema = 'public' AND column_name = 'tenant_type'"
    ).rows
  end

  defp insert_tenant_without_type!(slug) do
    Repo.query!(
      "INSERT INTO tenants (id, slug, display_name, status, settings, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1, 'Pre', 'active', '{}', now(), now())",
      [slug]
    )
  end

  test "column is NOT NULL default 'test'; 'staging' violates the check constraint" do
    assert [["NO", default]] = column()
    assert default =~ "'test'"

    assert_raise Postgrex.Error, ~r/tenants_tenant_type_check/, fn ->
      Repo.query!(
        "INSERT INTO tenants (id, slug, display_name, status, settings, tenant_type, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), 'req469-staging', 'S', 'active', '{}', 'staging', now(), now())"
      )
    end
  end

  test "down removes the column; a row inserted while it is absent reads 'test' after up" do
    slug = "req469-pre-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      Ecto.Migrator.run(Repo, [{@version, @module}], :down, all: true, log: false)
      assert column() == []
      insert_tenant_without_type!(slug)
    after
      Ecto.Migrator.run(Repo, [{@version, @module}], :up, all: true, log: false)
    end

    assert [["NO", _]] = column()

    assert %{rows: [["test"]]} =
             Repo.query!("SELECT tenant_type FROM tenants WHERE slug = $1", [slug])

    Repo.query!("DELETE FROM tenants WHERE slug = $1", [slug])
  end
end
