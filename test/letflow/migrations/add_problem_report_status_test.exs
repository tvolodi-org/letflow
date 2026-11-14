defmodule Letflow.AddProblemReportStatusTest do
  @moduledoc "T-1949 MG2: status migration defaults and all decision-text checks."
  use Letflow.DataCase, async: false

  alias Letflow.{Repo, TenantFixture, TenantProvisioning}
  alias Letflow.ProblemReports.Report
  alias Letflow.Repo.Migrations.AddProblemReportStatus

  @version 20_261_114_200_001

  test "MG2 existing rows receive the default and all CHECKs reject invalid values" do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t1949-mig")

    assert {@version, AddProblemReportStatus} =
             List.keyfind(TenantProvisioning.tenant_scoped_migrations(), @version, 0)

    assert :ok =
             Ecto.Migrator.down(Repo, @version, AddProblemReportStatus,
               prefix: fx.schema_name,
               log: false
             )

    id = Ecto.UUID.generate()

    Repo.query!(
      ~s|INSERT INTO "#{fx.schema_name}".problem_reports (id, tenant_id, reporter_tenant_id, reporter_user_id, text, consented_at, inserted_at) VALUES ($1,$2,$2,$3,'old report',now(),now())|,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(fx.tenant_id), Ecto.UUID.dump!(Ecto.UUID.generate())]
    )

    assert :ok =
             Ecto.Migrator.up(Repo, @version, AddProblemReportStatus,
               prefix: fx.schema_name,
               log: false
             )

    report = Repo.get!(Report, id, prefix: fx.schema_name)
    assert report.status == "received"

    for field <- [:last_action, :reply_text, :dev_summary, :decided_at, :decided_by_user_id],
        do: assert(Map.fetch!(report, field) == nil)

    for {field, value} <- [
          status: "bad",
          last_action: "bad",
          reply_text: "",
          reply_text: String.duplicate("x", 4001),
          dev_summary: "",
          dev_summary: String.duplicate("x", 2001)
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.transaction(fn ->
                 case Repo.query(
                        ~s|UPDATE "#{fx.schema_name}".problem_reports SET "#{field}" = $1 WHERE id = $2|,
                        [value, Ecto.UUID.dump!(id)]
                      ) do
                   {:error, error} -> Repo.rollback(error)
                   other -> other
                 end
               end)
    end
  end
end
