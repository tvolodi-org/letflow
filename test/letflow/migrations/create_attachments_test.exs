defmodule Letflow.CreateAttachmentsTest do
  @moduledoc "T-2040 MG-1..MG-4: attachment_blobs and attachment_links (last in manifest)."
  use Letflow.DataCase, async: false

  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.Repo.Migrations.CreateAttachments

  @version 20_261_116_200_001

  defp q(schema, sql, params), do: Repo.query(String.replace(sql, "S.", ~s("#{schema}".)), params)

  defp check_violation?(result) do
    match?(
      {:error, %Postgrex.Error{postgres: %{code: code}}} when code in [:check_violation],
      result
    )
  end

  defp blob_row(schema, sha, bytes) do
    q(
      schema,
      "INSERT INTO S.attachment_blobs (id, tenant_id, sha256, content_type, byte_size, bytes, inserted_at) VALUES ($1,$2,$3,'image/png',$4,$5,now()) RETURNING id",
      [Ecto.UUID.bingenerate(), Ecto.UUID.bingenerate(), sha, byte_size(bytes), bytes]
    )
  end

  defp link_sql(extra_cols, extra_vals) do
    "INSERT INTO S.attachment_links (id, tenant_id, owner_kind, owner_id, purpose, position, blob_id, uploaded_by, inserted_at, updated_at#{extra_cols}) VALUES (gen_random_uuid(), gen_random_uuid(), 'assets_card', $1, 'photo', $2, $3, gen_random_uuid(), now(), now()#{extra_vals})"
  end

  test "MG-1 registered last, down and up on a fresh tenant, both tables exist" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2040-mig")
    schema = fx.schema_name

    assert {@version, CreateAttachments} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -10)

    assert :ok = Ecto.Migrator.down(Repo, @version, CreateAttachments, prefix: schema, log: false)
    assert {:error, _} = q(schema, "SELECT 1 FROM S.attachment_blobs", [])
    assert :ok = Ecto.Migrator.up(Repo, @version, CreateAttachments, prefix: schema, log: false)
    assert {:ok, _} = q(schema, "SELECT 1 FROM S.attachment_blobs", [])
    assert {:ok, _} = q(schema, "SELECT 1 FROM S.attachment_links", [])
  end

  test "MG-2 CHECKs refuse bad content type, size mismatch, position 0 and a 201-char caption" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2040-chk")
    schema = fx.schema_name
    sha = String.duplicate("a", 64)

    assert {:ok, %{rows: [[blob_id]]}} = blob_row(schema, sha, "bytes")

    assert check_violation?(
             q(
               schema,
               "INSERT INTO S.attachment_blobs (id, tenant_id, sha256, content_type, byte_size, bytes, inserted_at) VALUES ($1,$2,$3,'image/gif',1,$4,now())",
               [Ecto.UUID.bingenerate(), Ecto.UUID.bingenerate(), String.duplicate("b", 64), "x"]
             )
           )

    assert check_violation?(
             q(
               schema,
               "INSERT INTO S.attachment_blobs (id, tenant_id, sha256, content_type, byte_size, bytes, inserted_at) VALUES ($1,$2,$3,'image/png',99,$4,now())",
               [Ecto.UUID.bingenerate(), Ecto.UUID.bingenerate(), String.duplicate("c", 64), "x"]
             )
           )

    owner = Ecto.UUID.bingenerate()
    assert check_violation?(q(schema, link_sql("", ""), [owner, 0, blob_id]))

    assert check_violation?(
             q(schema, link_sql(", caption", ", $4"), [
               owner,
               1,
               blob_id,
               String.duplicate("a", 201)
             ])
           )

    assert {:ok, _} =
             q(schema, link_sql(", caption", ", $4"), [
               owner,
               1,
               blob_id,
               String.duplicate("a", 200)
             ])
  end

  test "MG-3 a referenced blob cannot be deleted (ON DELETE RESTRICT)" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2040-fk")
    schema = fx.schema_name
    assert {:ok, %{rows: [[blob_id]]}} = blob_row(schema, String.duplicate("d", 64), "bytes")
    assert {:ok, _} = q(schema, link_sql("", ""), [Ecto.UUID.bingenerate(), 1, blob_id])

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             q(schema, "DELETE FROM S.attachment_blobs WHERE id = $1", [blob_id])
  end

  test "MG-4 one main per owner and purpose, one position per slot" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2040-uq")
    schema = fx.schema_name
    assert {:ok, %{rows: [[blob_id]]}} = blob_row(schema, String.duplicate("e", 64), "bytes")
    assert {:ok, %{rows: [[blob2]]}} = blob_row(schema, String.duplicate("f", 64), "bytes2")
    owner = Ecto.UUID.bingenerate()

    assert {:ok, _} = q(schema, link_sql(", is_main", ", true"), [owner, 1, blob_id])

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             q(schema, link_sql(", is_main", ", true"), [owner, 2, blob2])

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             q(schema, link_sql("", ""), [owner, 1, blob2])
  end
end
