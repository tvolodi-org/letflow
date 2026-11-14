defmodule Letflow.ProblemReports.StatusTest do
  @moduledoc "T-1949 S1-S4 N3: status bell and opt-in mail stay in the reporter's company."
  use Letflow.DataCase, async: false

  import Ecto.Query
  alias Letflow.{Notifications, ProblemReports, Repo, UserNotifications}
  alias Letflow.ProblemReports.{Inbox, Report, Status}
  alias Letflow.Notifications.Delivery
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.LoginDiscoveryNotifierDouble, as: Double

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    Fixture.mint_token!(tenants.a, ["TASK_WORKER"])
    user = Repo.one!(Letflow.Identity.User, prefix: tenants.a.schema_name)

    Letflow.Test.SmtpHelpers.put_app_env!(Letflow.LoginDiscovery.Notifier,
      adapter: Double,
      timeout_ms: 1000,
      max_concurrent: 5
    )

    Double.set_owner(self())
    on_exit(&Double.reset/0)
    {:ok, Map.merge(tenants, %{user: user})}
  end

  defp submit!(ctx) do
    {:ok, report} =
      ProblemReports.submit(
        %{tenant_id: ctx.a.tenant_id, user_id: ctx.user.id},
        ctx.a.schema_name,
        %{
          "consent" => true,
          "text" => "Commissioning fails when a purchase date is supplied",
          "context" => %{}
        }
      )

    Repo.get!(Report, report.id, prefix: ctx.p.schema_name)
  end

  defp mail_on!(a, locale \\ "en") do
    Repo.get!(Letflow.Identity.Tenant, a.tenant_id)
    |> Ecto.Changeset.change(
      settings: %{"notifications.email_copy" => true, "default_locale" => locale}
    )
    |> Repo.update!()
  end

  # The delivery is supervised and writes its log after calling the adapter.
  defp await_rows(prefix, count) do
    Enum.reduce_while(1..100, [], fn _, _ ->
      rows = Repo.all(Delivery, prefix: prefix)

      if length(rows) >= count do
        {:halt, rows}
      else
        receive do
        after
          20 -> :ok
        end

        {:cont, rows}
      end
    end)
  end

  test "S1 S2 N3 received and every decision bell belong only to the reporter", ctx do
    report = submit!(ctx)
    assert report.status == "received"

    assert [%{"kind" => "problem_report_received", "ref_id" => ref, "title" => number}] =
             UserNotifications.list(ctx.a.schema_name, ctx.user.id).items

    assert ref == report.id
    assert number == ProblemReports.number(report)

    for {action, kind} <- [
          {"develop", "in_work"},
          {"ask", "question"},
          {"answer", "answered"},
          {"fixed", "fixed"},
          {"reject", "not_done"}
        ] do
      r = if action == "develop", do: report, else: submit!(ctx)

      assert {:ok, _} =
               Inbox.decide(
                 r.id,
                 %{"action" => action, "text" => "Investigate date persistence"},
                 Ecto.UUID.generate()
               )

      bell =
        Repo.all(
          from(n in Letflow.UserNotifications.Notification,
            where: n.ref_id == ^r.id and n.kind == ^("problem_report_" <> kind)
          ),
          prefix: ctx.a.schema_name
        )

      assert [%{user_id: uid, tenant_id: tid}] = bell
      assert uid == ctx.user.id
      assert tid == ctx.a.tenant_id
    end

    for fx <- [ctx.b, ctx.p] do
      assert Repo.all(Letflow.UserNotifications.Notification, prefix: fx.schema_name) == []
      assert Repo.all(Delivery, prefix: fx.schema_name) == []
    end
  end

  test "S3 mail is off by default and respects recipient opt-out", ctx do
    assert Notifications.email_copy_allowed?(ctx.a.schema_name, ctx.a.tenant_id, ctx.user.id) ==
             false

    submit!(ctx)
    assert Repo.all(Delivery, prefix: ctx.a.schema_name) == []
    mail_on!(ctx.a)

    assert {:ok, _} =
             Letflow.UserPreferences.put(ctx.a.schema_name, ctx.user.id, %{
               "notifications.email" => "off"
             })

    refute Notifications.email_copy_allowed?(ctx.a.schema_name, ctx.a.tenant_id, ctx.user.id)
    submit!(ctx)
    assert Repo.all(Delivery, prefix: ctx.a.schema_name) == []
  end

  @tag timeout: 30_000
  test "S3 each opt-in status mail uses the template and no development summary", ctx do
    mail_on!(ctx.a, "ru")
    report = submit!(ctx)
    assert_receive {:deliver_message, received}, 3000
    assert received.to == ctx.user.email
    assert received.subject =~ "Получено"

    assert [%{template_key: "problem_report_status", trigger_ref: ref}] =
             await_rows(ctx.a.schema_name, 1)

    assert ref == report.id

    for {action, label} <- [{"develop", "В работе"}, {"ask", "В работе"}, {"answer", "Дан ответ"}] do
      assert {:ok, _} =
               Inbox.decide(
                 report.id,
                 %{"action" => action, "text" => "Investigate date persistence"},
                 Ecto.UUID.generate()
               )

      assert_receive {:deliver_message, msg}, 3000
      assert msg.subject =~ label

      if action == "develop",
        do: refute(msg.body =~ "Investigate"),
        else: assert(msg.body =~ "Investigate")
    end

    assert length(await_rows(ctx.a.schema_name, 4)) == 4

    for {action, label} <- [{"fixed", "Исправлено"}, {"reject", "Отклонено"}] do
      r = submit!(ctx)
      assert_receive {:deliver_message, _}, 3000

      assert {:ok, _} =
               Inbox.decide(r.id, %{"action" => action, "text" => "Done"}, Ecto.UUID.generate())

      assert_receive {:deliver_message, msg}, 3000
      assert msg.subject =~ label
    end

    assert length(await_rows(ctx.a.schema_name, 8)) == 8
    for fx <- [ctx.b, ctx.p], do: assert(Repo.all(Delivery, prefix: fx.schema_name) == [])
    assert Status.label("fixed", "kk") == "Түзетілді"
    assert Status.label("fixed", "unknown") == "Fixed"
  end

  test "S4 a purged reporter registration never breaks an owner decision", ctx do
    report = submit!(ctx)
    # An unregistered id represents the tenant after the registry entry has been removed.
    report
    |> Ecto.Changeset.change(reporter_tenant_id: Ecto.UUID.generate())
    |> Repo.update!(prefix: ctx.p.schema_name)

    assert {:ok, %{"status" => "fixed"}} =
             Inbox.decide(report.id, %{"action" => "fixed"}, Ecto.UUID.generate())

    assert length(Repo.all(Letflow.UserNotifications.Notification, prefix: ctx.a.schema_name)) ==
             1

    for fx <- [ctx.b, ctx.p],
        do: assert(Repo.all(Letflow.UserNotifications.Notification, prefix: fx.schema_name) == [])
  end
end
