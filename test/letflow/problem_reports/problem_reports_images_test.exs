defmodule Letflow.ProblemReports.ProblemReportsImagesTest do
  @moduledoc """
  T-2015 IM6-IM8: image retention and purge (`ProblemReports.purge_old_report_images/1`).
  `async: false`: the platform pin is VM-global. Committed-tenant rows are removed by the fixture's
  own `on_exit` (the tenant drop cascades through the schema).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.ProblemReports
  alias Letflow.ProblemReports.{Report, ReportImage}
  alias Letflow.Repo
  alias Letflow.Support.OwnerListFixture, as: F
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  setup do
    %{p: p} = Fixture.three_tenants!()
    Fixture.pin!(p.tenant_id)
    {:ok, p: p}
  end

  defp insert_report(p) do
    Repo.insert!(
      %Report{
        tenant_id: p.tenant_id,
        reporter_tenant_id: p.tenant_id,
        reporter_user_id: Ecto.UUID.generate(),
        text: "retention test",
        consented_at: DateTime.utc_now()
      },
      prefix: p.schema_name
    )
  end

  defp insert_image(p, report, inserted_at, position \\ 1) do
    Repo.insert!(
      %ReportImage{
        report_id: report.id,
        position: position,
        content_type: "image/png",
        bytes: F.png(),
        size: byte_size(F.png()),
        inserted_at: inserted_at
      },
      prefix: p.schema_name
    )
  end

  defp all_images(p), do: Repo.all(from(i in ReportImage), prefix: p.schema_name)

  test "IM6 purge_old_report_images/1 deletes images older than 30 days and keeps newer ones",
       %{p: p} do
    report1 = insert_report(p)
    report2 = insert_report(p)
    now = DateTime.utc_now()
    old_time = DateTime.add(now, -(31 * 24 * 3600), :second)
    new_time = DateTime.add(now, -(1 * 24 * 3600), :second)

    old_img = insert_image(p, report1, old_time)
    new_img = insert_image(p, report2, new_time)

    assert {:ok, 1} = ProblemReports.purge_old_report_images(now: now)

    remaining_ids = all_images(p) |> Enum.map(& &1.id)
    refute old_img.id in remaining_ids
    assert new_img.id in remaining_ids
  end

  test "IM7 purge_old_report_images/1 returns {:ok, 0} when no images are older than 30 days",
       %{p: p} do
    report = insert_report(p)
    now = DateTime.utc_now()
    new_time = DateTime.add(now, -(1 * 24 * 3600), :second)
    insert_image(p, report, new_time)

    assert {:ok, 0} = ProblemReports.purge_old_report_images(now: now)
    assert length(all_images(p)) == 1
  end

  test "IM8 purge_old_report_images/1 returns {:error, :unavailable} when platform pin is absent",
       %{} do
    Fixture.unpin!()
    assert {:error, :unavailable} = ProblemReports.purge_old_report_images()
  end
end
