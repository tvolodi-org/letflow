defmodule Letflow.AddOwnerReviewItemsTest do
  @moduledoc "T-1963 MG3: the owner-list class of problem_reports, its thread and image tables."
  use Letflow.DataCase, async: false

  alias Letflow.ProblemReports.Report
  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.Repo.Migrations.AddOwnerReviewItems

  @version 20_261_115_100_001

  defp q(sql, params), do: Repo.query(sql, params)

  defp insert_review(schema, tenant_id, overrides \\ []) do
    o = Map.merge(%{ref: "O-001", kind: "review", status: "for_review"}, Map.new(overrides))

    q(
      ~s|INSERT INTO "#{schema}".problem_reports (id, tenant_id, reporter_tenant_id, text, consented_at, inserted_at, class, owner_ref, kind, status) | <>
        "VALUES ($1,$2,$2,'title',now(),now(),'review',$3,$4,$5)",
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(tenant_id),
        o.ref,
        o.kind,
        o.status
      ]
    )
  end

  test "MG3 registered last; existing rows stay problem; every CHECK refuses its bad value" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t1963-mig")
    schema = fx.schema_name

    assert {@version, AddOwnerReviewItems} =
             List.last(TenantProvisioning.tenant_scoped_migrations())

    assert :ok =
             Ecto.Migrator.down(Repo, @version, AddOwnerReviewItems, prefix: schema, log: false)

    id = Ecto.UUID.generate()

    Repo.query!(
      ~s|INSERT INTO "#{schema}".problem_reports (id, tenant_id, reporter_tenant_id, reporter_user_id, text, consented_at, inserted_at, status) VALUES ($1,$2,$2,$3,'old report',now(),now(),'in_work')|,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(fx.tenant_id), Ecto.UUID.dump!(Ecto.UUID.generate())]
    )

    assert :ok = Ecto.Migrator.up(Repo, @version, AddOwnerReviewItems, prefix: schema, log: false)

    old = Repo.get!(Report, id, prefix: schema)

    assert {old.class, old.status, old.owner_ref, old.cycle, old.tasks} ==
             {"problem", "in_work", nil, 1, []}

    # a valid review row, no reporting user
    assert {:ok, _} = insert_review(schema, fx.tenant_id)
    # unique owner_ref
    assert {:error, %{postgres: %{code: :unique_violation}}} = insert_review(schema, fx.tenant_id)

    # owner_ref shape, kind and status per class
    assert {:error, %{postgres: %{constraint: "problem_reports_owner_ref"}}} =
             insert_review(schema, fx.tenant_id, ref: "X-1")

    assert {:error, %{postgres: %{constraint: "problem_reports_kind"}}} =
             insert_review(schema, fx.tenant_id, ref: "O-002", kind: "bogus")

    assert {:error, %{postgres: %{constraint: "problem_reports_status"}}} =
             insert_review(schema, fx.tenant_id, ref: "O-003", status: "received")

    assert {:error, %{postgres: %{constraint: "problem_reports_status"}}} =
             q(~s|UPDATE "#{schema}".problem_reports SET status = 'ready' WHERE id = $1|, [
               Ecto.UUID.dump!(id)
             ])

    assert {:error, %{postgres: %{constraint: "problem_reports_class"}}} =
             q(~s|UPDATE "#{schema}".problem_reports SET class = 'other' WHERE id = $1|, [
               Ecto.UUID.dump!(id)
             ])

    assert {:error, %{postgres: %{constraint: "problem_reports_reporter"}}} =
             q(~s|UPDATE "#{schema}".problem_reports SET reporter_user_id = NULL WHERE id = $1|, [
               Ecto.UUID.dump!(id)
             ])

    assert {:error, %{postgres: %{constraint: "problem_reports_kind"}}} =
             q(~s|UPDATE "#{schema}".problem_reports SET kind = 'review' WHERE id = $1|, [
               Ecto.UUID.dump!(id)
             ])

    # thread and images: CHECKs, unique position, cascade
    %{rows: [[item]]} =
      Repo.query!(~s|SELECT id FROM "#{schema}".problem_reports WHERE owner_ref = 'O-001'|)

    comment = Ecto.UUID.generate()

    comment_sql =
      ~s|INSERT INTO "#{schema}".problem_report_comments (id, tenant_id, report_id, author, type, cycle, inserted_at) VALUES ($1,$2,$3,$4,$5,1,now())|

    assert {:ok, _} =
             q(comment_sql <> "", [
               Ecto.UUID.dump!(comment),
               Ecto.UUID.dump!(fx.tenant_id),
               item,
               "owner",
               "finding"
             ])

    assert {:error, %{postgres: %{constraint: "problem_report_comments_author"}}} =
             q(comment_sql, [
               Ecto.UUID.dump!(Ecto.UUID.generate()),
               Ecto.UUID.dump!(fx.tenant_id),
               item,
               "robot",
               "finding"
             ])

    assert {:error, %{postgres: %{constraint: "problem_report_comments_type"}}} =
             q(comment_sql, [
               Ecto.UUID.dump!(Ecto.UUID.generate()),
               Ecto.UUID.dump!(fx.tenant_id),
               item,
               "owner",
               "bogus"
             ])

    image_sql =
      ~s|INSERT INTO "#{schema}".problem_report_comment_images (id, tenant_id, report_id, comment_id, position, content_type, byte_size, bytes, inserted_at) VALUES ($1,$2,$3,$4,$5,$6,$7,'\\x01',now())|

    image = fn pos, type, size ->
      q(image_sql, [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(fx.tenant_id),
        item,
        Ecto.UUID.dump!(comment),
        pos,
        type,
        size
      ])
    end

    assert {:ok, _} = image.(1, "image/png", 1)
    assert {:error, %{postgres: %{code: :unique_violation}}} = image.(1, "image/png", 1)

    assert {:error, %{postgres: %{constraint: "problem_report_images_position"}}} =
             image.(7, "image/png", 1)

    assert {:error, %{postgres: %{constraint: "problem_report_images_type"}}} =
             image.(2, "image/gif", 1)

    assert {:error, %{postgres: %{constraint: "problem_report_images_size"}}} =
             image.(2, "image/png", 0)

    assert {:error, %{postgres: %{constraint: "problem_report_images_size"}}} =
             image.(2, "image/png", 5_242_881)

    Repo.query!(~s|DELETE FROM "#{schema}".problem_reports WHERE id = $1|, [item])

    assert %{rows: [[0]]} =
             Repo.query!(~s|SELECT count(*) FROM "#{schema}".problem_report_comments|)

    assert %{rows: [[0]]} =
             Repo.query!(~s|SELECT count(*) FROM "#{schema}".problem_report_comment_images|)

    # down removes review rows and restores the old shape
    assert {:ok, _} = insert_review(schema, fx.tenant_id, ref: "O-009")

    assert :ok =
             Ecto.Migrator.down(Repo, @version, AddOwnerReviewItems, prefix: schema, log: false)

    assert %{rows: [[1]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".problem_reports|)
    assert :ok = Ecto.Migrator.up(Repo, @version, AddOwnerReviewItems, prefix: schema, log: false)
  end
end
