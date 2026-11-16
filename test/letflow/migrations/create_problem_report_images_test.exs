defmodule Letflow.CreateProblemReportImagesTest do
  @moduledoc "T-2015 MG-RI: problem_report_images migration (last in manifest)."
  use Letflow.DataCase, async: false

  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.Repo.Migrations.CreateProblemReportImages

  @version 20_261_116_100_001

  test "MG-RI registered last; table exists in a fresh tenant; CHECKs enforce content_type and size" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t2015-mig")
    schema = fx.schema_name

    assert {@version, CreateProblemReportImages} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -1)

    assert :ok =
             Ecto.Migrator.down(Repo, @version, CreateProblemReportImages,
               prefix: schema,
               log: false
             )

    assert :ok =
             Ecto.Migrator.up(Repo, @version, CreateProblemReportImages,
               prefix: schema,
               log: false
             )

    # Insert a valid problem_report to reference
    report_id = Ecto.UUID.generate()

    Repo.query!(
      ~s|INSERT INTO "#{schema}".problem_reports (id, tenant_id, reporter_tenant_id, reporter_user_id, text, consented_at, inserted_at) VALUES ($1,$2,$2,$3,'test',now(),now())|,
      [
        Ecto.UUID.dump!(report_id),
        Ecto.UUID.dump!(fx.tenant_id),
        Ecto.UUID.dump!(Ecto.UUID.generate())
      ]
    )

    image_id = Ecto.UUID.generate()
    png_bytes = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

    # Valid insert succeeds
    assert {:ok, _} =
             Repo.query(
               ~s|INSERT INTO "#{schema}".problem_report_images (id, report_id, position, content_type, bytes, size, inserted_at) VALUES ($1,$2,1,'image/png',$3,$4,now())|,
               [
                 Ecto.UUID.dump!(image_id),
                 Ecto.UUID.dump!(report_id),
                 png_bytes,
                 byte_size(png_bytes)
               ]
             )

    # content_type CHECK rejects unknown type
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.transaction(fn ->
               case Repo.query(
                      ~s|INSERT INTO "#{schema}".problem_report_images (id, report_id, position, content_type, bytes, size, inserted_at) VALUES ($1,$2,2,'image/gif',$3,$4,now())|,
                      [
                        Ecto.UUID.dump!(Ecto.UUID.generate()),
                        Ecto.UUID.dump!(report_id),
                        png_bytes,
                        byte_size(png_bytes)
                      ]
                    ) do
                 {:error, e} -> Repo.rollback(e)
                 ok -> ok
               end
             end)

    # size CHECK rejects 0
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.transaction(fn ->
               case Repo.query(
                      ~s|INSERT INTO "#{schema}".problem_report_images (id, report_id, position, content_type, bytes, size, inserted_at) VALUES ($1,$2,3,'image/png',$3,0,now())|,
                      [
                        Ecto.UUID.dump!(Ecto.UUID.generate()),
                        Ecto.UUID.dump!(report_id),
                        png_bytes
                      ]
                    ) do
                 {:error, e} -> Repo.rollback(e)
                 ok -> ok
               end
             end)

    # Unique index on (report_id, position) rejects a duplicate
    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.transaction(fn ->
               case Repo.query(
                      ~s|INSERT INTO "#{schema}".problem_report_images (id, report_id, position, content_type, bytes, size, inserted_at) VALUES ($1,$2,1,'image/png',$3,$4,now())|,
                      [
                        Ecto.UUID.dump!(Ecto.UUID.generate()),
                        Ecto.UUID.dump!(report_id),
                        png_bytes,
                        byte_size(png_bytes)
                      ]
                    ) do
                 {:error, e} -> Repo.rollback(e)
                 ok -> ok
               end
             end)
  end
end
