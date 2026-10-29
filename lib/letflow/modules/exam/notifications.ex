defmodule Letflow.Modules.Exam.Notifications do
  @moduledoc """
  Exam notification mails (REQ-597, GH #3363), part A: the `exam_result` mail the candidate gets
  when a session is scored. It rides the REQ-584 delivery log through
  `Letflow.Notifications.start_delivery/5`; this module owns only the exam wording and the flag.

  Default off: `config :letflow, :exam_notifications_enabled` (read by `enabled?/0` only; the
  string `"true"` is off). `result/3` is called by `Letflow.Modules.Exam.Session` after the submit
  transaction committed. It never raises and returns `:ok` whatever happens (INV-8), and with
  the flag off it touches nothing: no task, no row, no adapter call. A replayed submit or a
  grading-pending outcome (`passed: nil`) sends nothing.

  The delivery log holds ids only (INV-4); the recipient is looked up by the tenant `:prefix`
  only (INV-1). `exam_assigned` and `exam_reminder` are registered keys without a sender yet.
  """

  alias Letflow.Entities.Record.Latest
  alias Letflow.Notifications

  @locales ["en", "ru", "kk"]

  @doc "True only when the flag is the boolean `true`."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:letflow, :exam_notifications_enabled, false) == true

  @doc """
  Starts the `exam_result` delivery for a freshly scored session. `ref` carries the session,
  user and exam ids taken from the locked session row.
  """
  @spec result(String.t(), map(), map()) :: :ok
  def result(prefix, %{session_id: session_id, user_id: user_id, exam_id: exam_id}, outcome) do
    if enabled?() and sendable?(outcome) do
      Notifications.start_delivery(
        "exam_result",
        user_id,
        session_id,
        fn user, prefix, tenant -> values(user, prefix, tenant, exam_id, outcome) end,
        prefix
      )
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def result(_prefix, _ref, _outcome), do: :ok

  defp sendable?(%{status: status, passed: passed}) when is_boolean(passed),
    do: status in [:submitted, :auto_submitted]

  defp sendable?(_outcome), do: false

  defp values(user, prefix, tenant, exam_id, outcome) do
    %{
      "exam_title" =>
        Notifications.text(exam_title(exam_id, prefix, Notifications.locale_of(tenant))),
      "candidate_name" =>
        Notifications.text(
          if(user.display_name in [nil, ""], do: user.username, else: user.display_name)
        ),
      "result_status" => if(outcome.passed, do: "passed", else: "failed"),
      "score_percent" => score_percent(outcome.percentage),
      "tenant_name" => Notifications.text(tenant && tenant.display_name)
    }
  end

  defp score_percent(percentage) when is_number(percentage),
    do: :erlang.float_to_binary(Float.round(percentage * 1.0, 1), decimals: 1)

  defp score_percent(_other), do: ""

  defp exam_title(exam_id, prefix, locale) do
    with {:ok, %{field_values: %{"title" => title}}} <- Latest.get(exam_id, "exam", prefix) do
      localized(title, locale)
    else
      _other -> ""
    end
  end

  defp localized(title, _locale) when is_binary(title), do: title

  defp localized(%{} = title, locale) do
    Enum.find_value([locale | @locales], "", fn key ->
      case Map.get(title, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp localized(_title, _locale), do: ""
end
