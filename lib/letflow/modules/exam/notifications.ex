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
  only (INV-1). Part B adds `assigned/2` (`exam_assigned`) and `send_reminders/2`
  (`exam_reminder`); no product code calls either yet (the assignment write path and the reminder
  schedule are open).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Notifications
  alias Letflow.Notifications.Delivery
  alias Letflow.Repo

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

  @doc """
  Starts the `exam_assigned` delivery for a freshly written assignment (`Authoring.create_assignment/2`
  result record). Only an active `user` assignment sends; `all`, `group` and `org_unit` assignments
  and inactive ones send nothing and write no row. `trigger_ref` is the assignment record id.
  Never raises (INV-8); with the flag off it touches nothing.
  """
  @spec assigned(String.t(), term()) :: :ok
  def assigned(prefix, %{record_id: record_id, field_values: %{} = fields}) do
    with true <- enabled?(),
         %{"assignee_type" => "user", "active" => true, "assignee_id" => user_id} <- fields,
         true <- is_binary(user_id) do
      exam_id = fields["exam_id"]
      deadline = deadline_text(fields["deadline"])

      Notifications.start_delivery(
        "exam_assigned",
        user_id,
        record_id,
        fn user, prefix, tenant -> assignment_values(user, prefix, tenant, exam_id, deadline) end,
        prefix
      )
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def assigned(_prefix, _assignment), do: :ok

  @doc """
  Starts one `exam_reminder` delivery for every active `user` assignment whose deadline lies after
  `now` and at most 24 hours from it (exactly 24 h is inside, exactly `now` is not), unless the
  assignee already has a submitted, auto-submitted or grading-pending session of that exam, or any
  `exam_reminder` row exists for the assignment (even a failed or skipped one). A deadline that is
  missing or not an offset ISO 8601 string (a naive value such as `2026-11-01T10:00:00`) counts as
  no deadline. Nobody calls this yet; the caller's schedule must not overlap two calls, because the
  dedupe reads the log row that the delivery task writes asynchronously. Never raises (INV-8).
  """
  @spec send_reminders(String.t(), DateTime.t()) :: :ok
  def send_reminders(prefix, %DateTime{} = now) do
    if enabled?() do
      from(r in Latest,
        where:
          r.entity_type == "exam_assignment" and r.deleted == false and
            fragment("?->>'assignee_type' = 'user'", r.field_values) and
            fragment("?->'active' = 'true'::jsonb", r.field_values)
      )
      |> Repo.all(prefix: prefix)
      |> Enum.each(&remind(prefix, &1, now))
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def send_reminders(_prefix, _now), do: :ok

  defp remind(prefix, %{record_id: assignment_id, field_values: fields}, now) do
    user_id = fields["assignee_id"]
    exam_id = fields["exam_id"]

    with true <- is_binary(user_id) and is_binary(exam_id),
         %DateTime{} = deadline <- parse_deadline(fields["deadline"]),
         true <- in_window?(deadline, now),
         false <- finished_session?(prefix, user_id, exam_id),
         false <- reminded?(prefix, assignment_id) do
      text = deadline_text(fields["deadline"])

      Notifications.start_delivery(
        "exam_reminder",
        user_id,
        assignment_id,
        fn user, prefix, tenant -> assignment_values(user, prefix, tenant, exam_id, text) end,
        prefix
      )
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp in_window?(deadline, now),
    do: DateTime.compare(deadline, now) == :gt and DateTime.diff(deadline, now, :second) <= 86_400

  defp finished_session?(prefix, user_id, exam_id) do
    statuses = ["submitted", "auto_submitted", "grading_pending"]

    from(r in Latest,
      where:
        r.entity_type == "session" and r.deleted == false and
          fragment("?->>'user_id' = ?", r.field_values, ^user_id) and
          fragment("?->>'exam_id' = ?", r.field_values, ^exam_id) and
          fragment("?->>'status' = ANY(?)", r.field_values, ^statuses)
    )
    |> Repo.exists?(prefix: prefix)
  end

  defp reminded?(prefix, assignment_id) do
    from(d in Delivery,
      where: d.template_key == "exam_reminder" and d.trigger_ref == ^assignment_id
    )
    |> Repo.exists?(prefix: prefix)
  end

  defp parse_deadline(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, deadline, _offset} -> deadline
      _error -> nil
    end
  end

  defp parse_deadline(_value), do: nil

  defp deadline_text(value) do
    case parse_deadline(value) do
      %DateTime{} = deadline -> deadline |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      nil -> ""
    end
  end

  defp assignment_values(user, prefix, tenant, exam_id, deadline) do
    %{
      "exam_title" =>
        Notifications.text(exam_title(exam_id, prefix, Notifications.locale_of(tenant))),
      "candidate_name" => candidate_name(user),
      "deadline" => deadline,
      "tenant_name" => Notifications.text(tenant && tenant.display_name)
    }
  end

  defp candidate_name(user),
    do:
      Notifications.text(
        if(user.display_name in [nil, ""], do: user.username, else: user.display_name)
      )

  defp values(user, prefix, tenant, exam_id, outcome) do
    %{
      "exam_title" =>
        Notifications.text(exam_title(exam_id, prefix, Notifications.locale_of(tenant))),
      "candidate_name" => candidate_name(user),
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
