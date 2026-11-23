defmodule Letflow.CreateUploadEventsTest do
  @moduledoc "T-2133 MG-UE-1..MG-UE-2: upload_events (last in manifest)."
  use Letflow.DataCase, async: false

  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.Repo.Migrations.CreateUploadEvents

  @version 20_261_117_300_001

  defp q(schema, sql, params), do: Repo.query(String.replace(sql, "S.", ~s("#{schema}".)), params)

  test "MG-UE-1 registered last, down and up on a fresh tenant, table exists after up" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2133-mig")
    schema = fx.schema_name

    assert {@version, CreateUploadEvents} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -8)

    assert :ok =
             Ecto.Migrator.down(Repo, @version, CreateUploadEvents, prefix: schema, log: false)

    assert {:error, _} = q(schema, "SELECT 1 FROM S.upload_events", [])
    assert :ok = Ecto.Migrator.up(Repo, @version, CreateUploadEvents, prefix: schema, log: false)
    assert {:ok, _} = q(schema, "SELECT 1 FROM S.upload_events", [])
  end

  test "MG-UE-2 upload_events in expected_tenant_tables" do
    assert "upload_events" in TenantFixture.expected_tenant_tables()
  end
end
