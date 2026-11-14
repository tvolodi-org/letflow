defmodule Letflow.ProblemReports.Inbox do
  @moduledoc """
  T-1949: owner inbox in the configured platform company. Decisions serialize on the report
  row; their audit holds only status and length, never retained customer or reply text.
  Authorization belongs to the platform-scope `ProblemReportsManage` routes.

  T-1963: the same routes serve a second class of row, `review` (the owner list,
  `Letflow.ProblemReports.Review`): `list/1` takes `class=problem|review` (default `problem`), `get/1`
  answers either class, and `decide/3` is for problem reports only (a review row is a 404).
  """

  import Ecto.Query
  require Logger

  alias Letflow.{Audit, PlatformTenant, ProblemReports, Repo}
  alias Letflow.ProblemReports.{Capture, Report, Review, Status}

  @actions ~w(answer develop reject ask fixed)
  @closed ~w(answered fixed not_done)

  @doc "Pure, closed transition table; closed reports cannot be reopened."
  def transition(status, action) when status in @closed and action in @actions,
    do: {:error, :report_closed}

  def transition(status, action) when status in ~w(received in_work) and action in @actions do
    {:ok,
     Map.fetch!(
       %{
         "answer" => "answered",
         "develop" => "in_work",
         "reject" => "not_done",
         "ask" => "in_work",
         "fixed" => "fixed"
       },
       action
     )}
  end

  def transition(_status, _action), do: {:error, {:invalid, "action"}}

  @doc "Validates and masks decision text; development summaries must use the owner's words."
  def check_text(action, text, report) when action in @actions do
    text = if is_nil(text) and action == "fixed", do: "", else: text
    cap = if action == "develop", do: 2000, else: 4000

    cond do
      not is_binary(text) ->
        {:error, {:invalid, "text"}}

      length(String.codepoints(String.trim(text))) > cap ->
        {:error, {:invalid, "text"}}

      String.trim(text) == "" and action != "fixed" ->
        {:error, {:invalid, "text"}}

      action == "develop" and copies_report?(text, report) ->
        {:error, :summary_copies_report}

      true ->
        clean = text |> String.trim() |> Capture.mask()
        # PostgreSQL char_length counts codepoints, including combining marks. Masking may
        # lengthen a short address, so enforce the same cap on the final stored value too.
        if length(String.codepoints(clean)) > cap do
          {:error, {:invalid, "text"}}
        else
          {:ok, if(clean == "", do: nil, else: clean)}
        end
    end
  end

  def check_text(_action, _text, _report), do: {:error, {:invalid, "action"}}

  defp normalize(text),
    do: text |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp copies_report?(text, report) do
    summary = normalize(text)
    original = normalize(report.text)
    chars = String.graphemes(original)
    size = min(length(chars), 30)

    copied_text =
      size >= 10 and
        Enum.any?(
          Enum.chunk_every(chars, size, 1, :discard),
          &String.contains?(summary, Enum.join(&1))
        )

    copied_text or
      Enum.any?([report.reporter_name, report.reporter_tenant_name], fn name ->
        is_binary(name) and String.length(normalize(name)) >= 3 and
          String.contains?(summary, normalize(name))
      end)
  end

  @doc "Newest first, keyset-paged owner summaries."
  def list(params) do
    case Map.get(params, "class", "problem") do
      "problem" -> list_problems(params)
      "review" -> Review.list(params)
      _ -> {:error, :invalid_query}
    end
  end

  defp list_problems(params) do
    with {:ok, prefix} <- prefix(),
         {:ok, status} <- filter(Map.get(params, "status", "open")),
         {:ok, limit} <- integer(Map.get(params, "limit", "50"), 1, 100),
         {:ok, before} <- before_seq(Map.get(params, "before")) do
      query =
        from(r in Report, where: r.class == "problem", order_by: [desc: r.seq], limit: ^limit)

      query = if status == [], do: query, else: from(r in query, where: r.status in ^status)
      query = if before, do: from(r in query, where: r.seq < ^before), else: query
      rows = Repo.all(query, prefix: prefix)
      next = if length(rows) == limit, do: List.last(rows).seq, else: nil
      {:ok, %{"reports" => Enum.map(rows, &summary/1), "next_before" => next}}
    end
  rescue
    _ -> {:error, :internal}
  end

  defp filter("open"), do: {:ok, ~w(received in_work)}
  defp filter("closed"), do: {:ok, @closed}
  defp filter("all"), do: {:ok, []}
  defp filter(_), do: {:error, :invalid_query}
  defp before_seq(nil), do: {:ok, nil}
  defp before_seq(value), do: integer(value, 1, 9_223_372_036_854_775_807)

  defp integer(value, low, high) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= low and n <= high -> {:ok, n}
      _ -> {:error, :invalid_query}
    end
  end

  defp integer(_, _, _), do: {:error, :invalid_query}

  @doc "Reads a report from the platform schema only."
  def get(id) do
    with {:ok, prefix} <- prefix(),
         {:ok, id} <- cast_id(id),
         %Report{} = report <- Repo.get(Report, id, prefix: prefix) do
      if report.class == "review", do: Review.get(id), else: {:ok, detail(report)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  rescue
    _ -> {:error, :internal}
  end

  @doc "Commits the decision and its audit atomically, then notifies the reporter best effort."
  def decide(id, body, actor_user_id) when is_map(body) do
    with {:ok, prefix} <- prefix(), {:ok, id} <- cast_id(id) do
      result =
        Repo.transaction(fn ->
          report =
            Repo.one(
              from(r in Report, where: r.id == ^id and r.class == "problem", lock: "FOR UPDATE"),
              prefix: prefix
            )

          if is_nil(report), do: Repo.rollback(:not_found)
          action = Map.get(body, "action")

          with {:ok, status} <- transition(report.status, action),
               {:ok, text} <- check_text(action, Map.get(body, "text"), report) do
            attrs = %{
              status: status,
              last_action: action,
              reply_text: if(action == "develop", do: nil, else: text),
              dev_summary: if(action == "develop", do: text, else: report.dev_summary),
              decided_by_user_id: actor_user_id,
              decided_at: DateTime.utc_now()
            }

            stored = report |> Ecto.Changeset.change(attrs) |> Repo.update!(prefix: prefix)

            audit_result =
              Audit.insert_entry(
                Repo,
                %{
                  actor_id: actor_user_id,
                  action: "problem_report.decided",
                  resource_type: "problem_report",
                  resource_id: ProblemReports.number(report),
                  before_state: nil,
                  after_state: %{
                    "number" => ProblemReports.number(report),
                    "action" => action,
                    "from_status" => report.status,
                    "to_status" => status,
                    "text_length" => String.length(text || "")
                  }
                },
                prefix
              )

            case audit_result do
              {:ok, _entry} -> stored
              {:error, _reason} -> Repo.rollback(:internal)
            end
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, report} ->
          Status.notify(report, report.last_action)
          {:ok, detail(report)}

        error ->
          error
      end
    end
  rescue
    error ->
      Logger.error("problem report decision failed: #{inspect(error.__struct__)}")
      {:error, :internal}
  end

  def decide(_id, _body, _actor), do: {:error, {:invalid, "action"}}

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp prefix do
    case PlatformTenant.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :unavailable}
    end
  end

  defp summary(r) do
    %{
      "id" => r.id,
      "number" => ProblemReports.number(r),
      "class" => "problem",
      "status" => r.status,
      "last_action" => r.last_action,
      "received_at" => r.consented_at,
      "decided_at" => r.decided_at,
      "reporter" => %{"tenant_name" => r.reporter_tenant_name, "name" => r.reporter_name},
      "text_preview" => String.slice(r.text, 0, 140)
    }
  end

  defp detail(r) do
    summary(r)
    |> Map.delete("text_preview")
    |> Map.merge(%{
      "decided_by_user_id" => r.decided_by_user_id,
      "reporter" => %{
        "tenant_id" => r.reporter_tenant_id,
        "tenant_name" => r.reporter_tenant_name,
        "user_id" => r.reporter_user_id,
        "name" => r.reporter_name,
        "roles" => r.reporter_roles,
        "permissions" => r.reporter_permissions
      },
      "text" => r.text,
      "context" => r.context,
      "server_version" => r.server_version,
      "trace_id" => r.trace_id,
      "reply_text" => r.reply_text,
      "dev_summary" => r.dev_summary
    })
  end
end
