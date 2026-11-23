defmodule Letflow.CreateStockCreateIdempotencyTest do
  @moduledoc "REQ-846 MG-1..MG-2: stock_create_idempotency tenant-scoped migration."
  use Letflow.DataCase, async: false

  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.Repo.Migrations.CreateStockCreateIdempotency

  @version 20_261_117_200_001

  defp q(schema, sql, params),
    do: Repo.query(String.replace(sql, "S.", ~s("#{schema}".)), params)

  test "MG-1 registered last, down and up on a fresh tenant, table exists after up" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2076-mig")
    schema = fx.schema_name

    assert {@version, CreateStockCreateIdempotency} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -10)

    assert :ok =
             Ecto.Migrator.down(Repo, @version, CreateStockCreateIdempotency,
               prefix: schema,
               log: false
             )

    assert {:error, _} = q(schema, "SELECT 1 FROM S.stock_create_idempotency", [])

    assert :ok =
             Ecto.Migrator.up(Repo, @version, CreateStockCreateIdempotency,
               prefix: schema,
               log: false
             )

    assert {:ok, _} = q(schema, "SELECT 1 FROM S.stock_create_idempotency", [])
  end

  test "MG-2 key is the primary key; a 256-char key is accepted and unique" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2076-chk")
    schema = fx.schema_name
    doc_id = Ecto.UUID.bingenerate()
    hash = String.duplicate("a", 64)

    # A 256-character key (the maximum for :stock_create) is accepted.
    long_key = String.duplicate("x", 256)

    assert {:ok, _} =
             q(
               schema,
               "INSERT INTO S.stock_create_idempotency (key, document_id, body_hash) VALUES ($1,$2,$3)",
               [
                 long_key,
                 doc_id,
                 hash
               ]
             )

    # Duplicate key is rejected.
    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             q(
               schema,
               "INSERT INTO S.stock_create_idempotency (key, document_id, body_hash) VALUES ($1,$2,$3)",
               [
                 long_key,
                 doc_id,
                 hash
               ]
             )

    # Short key also works.
    short_key = "client:stock_create:test"

    assert {:ok, _} =
             q(
               schema,
               "INSERT INTO S.stock_create_idempotency (key, document_id, body_hash) VALUES ($1,$2,$3)",
               [
                 short_key,
                 Ecto.UUID.bingenerate(),
                 String.duplicate("b", 64)
               ]
             )
  end
end
