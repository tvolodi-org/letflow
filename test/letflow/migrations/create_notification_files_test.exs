defmodule Letflow.CreateNotificationFilesTest do
  @moduledoc """
  T-2596 (pilot gap G12): the tenant-scoped NOTIFICATION FILE AREA -- the table
  the "file" channel of a notification step writes into.

  Test ids MG-NF-1..MG-NF-3.
  """

  use Letflow.DataCase, async: false

  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.Repo.Migrations.CreateNotificationFiles

  @version 20_261_123_100_004

  defp q(schema, sql, params), do: Repo.query(String.replace(sql, "S.", ~s("#{schema}".)), params)

  test "MG-NF-1 registered last, down and up on a fresh tenant, the table exists after up" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2596-mig")
    schema = fx.schema_name

    assert {@version, CreateNotificationFiles} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -1)

    assert :ok =
             Ecto.Migrator.down(Repo, @version, CreateNotificationFiles,
               prefix: schema,
               log: false
             )

    assert {:error, _} = q(schema, "SELECT 1 FROM S.notification_files", [])

    assert :ok =
             Ecto.Migrator.up(Repo, @version, CreateNotificationFiles, prefix: schema, log: false)

    assert {:ok, _} = q(schema, "SELECT 1 FROM S.notification_files", [])
  end

  test "MG-NF-2 the row holds the bytes, the name and the retention moment" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2596-mig-cols")
    schema = fx.schema_name

    assert {:ok, _rows} =
             q(
               schema,
               """
               INSERT INTO S.notification_files
                 (id, tenant_id, name, template_key, content_type, byte_size, sha256, bytes,
                  trigger_ref, inserted_at, expires_at)
               VALUES
                 (gen_random_uuid(), $1, 'notice-abc.txt', 'tenant_registered', 'text/plain', 5,
                  'aaaa', '\\x0102030405'::bytea, gen_random_uuid(), now(), now() + interval '30 days')
               """,
               [Ecto.UUID.dump!(fx.tenant_id)]
             )

    assert {:ok, %{rows: [["notice-abc.txt", 5]]}} =
             q(schema, "SELECT name, byte_size FROM S.notification_files", [])
  end

  test "MG-NF-3 notification_files in expected_tenant_tables" do
    assert "notification_files" in TenantFixture.expected_tenant_tables()
  end
end
