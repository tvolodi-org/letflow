defmodule Letflow.ProblemReports.Status do
  @moduledoc """
  T-1949: best-effort status messages in the reporter's registered company, after commit.
  Development summaries never leave the platform schema. Mail is off unless the tenant enables
  bell copies and the recipient has not opted out. A purged company cannot break a decision.
  """

  alias Letflow.{Notifications, ProblemReports, TenantProvisioning, UserNotifications}

  @kinds %{
    :received => "problem_report_received",
    "develop" => "problem_report_in_work",
    "ask" => "problem_report_question",
    "answer" => "problem_report_answered",
    "fixed" => "problem_report_fixed",
    "reject" => "problem_report_not_done"
  }
  @labels %{
    "en" => %{
      "received" => "Received",
      "in_work" => "In work",
      "answered" => "Answered",
      "fixed" => "Fixed",
      "not_done" => "Not done"
    },
    "ru" => %{
      "received" => "Получено",
      "in_work" => "В работе",
      "answered" => "Дан ответ",
      "fixed" => "Исправлено",
      "not_done" => "Отклонено"
    },
    "kk" => %{
      "received" => "Қабылданды",
      "in_work" => "Жұмыста",
      "answered" => "Жауап берілді",
      "fixed" => "Түзетілді",
      "not_done" => "Қабылданбады"
    }
  }

  @doc "The status word for the tenant's locale, falling back to English."
  def label(status, locale), do: @labels |> Map.get(locale, @labels["en"]) |> Map.fetch!(status)

  @doc "Notifies only the reporter; always returns :ok, even after tenant deletion."
  def notify(report, event) do
    with {:ok, prefix} <- TenantProvisioning.registered_schema(report.reporter_tenant_id),
         {:ok, kind} <- Map.fetch(@kinds, event) do
      UserNotifications.notify(
        prefix,
        report.reporter_tenant_id,
        report.reporter_user_id,
        kind,
        report.id,
        ProblemReports.number(report)
      )

      if Notifications.email_copy_allowed?(
           prefix,
           report.reporter_tenant_id,
           report.reporter_user_id
         ) do
        Notifications.start_delivery(
          "problem_report_status",
          report.reporter_user_id,
          report.id,
          fn user, _prefix, tenant ->
            %{
              "user_name" => Notifications.text(user.display_name || user.username),
              "report_number" => ProblemReports.number(report),
              "status_text" => label(report.status, Notifications.locale_of(tenant)),
              "reply_text" =>
                Notifications.text(if(event == "develop", do: nil, else: report.reply_text)),
              "tenant_name" => Notifications.text(tenant && tenant.display_name)
            }
          end,
          prefix
        )
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
