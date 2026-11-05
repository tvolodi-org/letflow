defmodule Letflow.Migrations.TenantModulesAcceptedHashesTest do
  @moduledoc "REQ-769 / T-1371 A1: the accepted_manifest_hashes column on a provisioned tenant."

  use Letflow.DataCase, async: false

  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.TenantProvisioning

  test "A1 the column is text[] NOT NULL default empty and the migration is registered" do
    assert Enum.any?(TenantProvisioning.tenant_scoped_migrations(), fn {v, m} ->
             v == 20_261_106_100_001 and
               m == Letflow.Repo.Migrations.AddAcceptedManifestHashesToTenantModules
           end)

    %{schema: schema} = Mw.tenant!("t1371-mig")

    %{rows: [[type, nullable, default]]} =
      Repo.query!(
        "SELECT data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'tenant_modules' AND column_name = 'accepted_manifest_hashes'",
        [schema]
      )

    assert type == "ARRAY"
    assert nullable == "NO"
    assert default =~ "{}"

    assert [%{accepted_manifest_hashes: []}] =
             Repo.all(Letflow.Modules.TenantModule, prefix: schema)
  end
end
