defmodule Letflow.CreateSharedStockAccessTest do
  @moduledoc "REQ-858 MG-1..MG-2: shared_stock_access tenant-scoped migration."
  use Letflow.DataCase, async: false

  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.Repo.Migrations.CreateSharedStockAccess

  @version 20_261_117_400_001

  defp q(schema, sql, params \\ []),
    do: Repo.query(String.replace(sql, "S.", ~s("#{schema}".)), params)

  test "MG-1 registered second to last (REQ-859 is last), down and up on a fresh tenant, table exists after up and starts empty" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2088-mig")
    schema = fx.schema_name

    assert {@version, CreateSharedStockAccess} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -7)

    assert {:ok, %{rows: [[0]]}} = q(schema, "SELECT count(*) FROM S.shared_stock_access")

    assert :ok =
             Ecto.Migrator.down(Repo, @version, CreateSharedStockAccess,
               prefix: schema,
               log: false
             )

    assert {:error, _} = q(schema, "SELECT 1 FROM S.shared_stock_access")

    assert :ok =
             Ecto.Migrator.up(Repo, @version, CreateSharedStockAccess,
               prefix: schema,
               log: false
             )

    assert {:ok, _} = q(schema, "SELECT 1 FROM S.shared_stock_access")
  end

  test "MG-2 the hash column refuses a non-hex value" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2088-chk")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             q(
               fx.schema_name,
               "INSERT INTO S.shared_stock_access (id, token_hash, actor_id, created_by_user_id, created_at, inserted_at, updated_at) VALUES ($1,'not-a-hash',$1,$1,now(),now(),now())",
               [Ecto.UUID.bingenerate()]
             )
  end
end
