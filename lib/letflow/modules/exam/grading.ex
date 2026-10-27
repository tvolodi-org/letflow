defmodule Letflow.Modules.Exam.Grading do
  @moduledoc """
  GH #3324 / REQ-588 part A -- the examiner's read side of the manual short-text grading queue.

  Read-only: `list_queue/2` and `get_answer/3`. Marking an answer and finalising the session are part B
  and live elsewhere.

  ## Tenant isolation (INV-1, INV-5)

  Every query runs with the caller's tenant `prefix` (from `conn.assigns.scoped_opts`, never from the
  request); no function here accepts a tenant identifier. The unscoped scans go through
  `Letflow.Modules.Exam.Session.scan_records/3`, the single SEC-518-R1 site, valid because the two
  grading routes are `:tenant_wide`. Every miss of `get_answer/3` (malformed id, absent row, another
  tenant's row, an already graded answer, a question that is not short text) is the same
  `{:error, :not_found}`.

  ## Redaction (INV-2)

  Responses are hand-assembled maps. No `field_values` map is ever passed through, so the answer key,
  the exam snapshot, the pass mark and the candidate's identity cannot reach a response; `session.user_id`
  is never read.

  ## Ordering and paging

  The queue is ordered by the session's submission time, then session id, then question id (the last makes
  the key total). `session.submitted_at` is not a queried field, so the tenant's pending rows are loaded
  and ordered here; the keyset cursor is `v1|<submitted_us>|<session_id>|<question_id>`, unsigned, and
  holds only a comparison value. If the pending set grows large, push the `grading_status` filter into the
  query via `idx_session_question_score_session_grading_status`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Pagination
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Exam.Session
  alias Letflow.Repo

  @locales ["kk", "ru", "en"]

  @type row :: %{
          session_id: String.t(),
          question_id: String.t(),
          exam_title: String.t(),
          stem: String.t(),
          max_score: float(),
          submitted_at: String.t()
        }

  @doc """
  One page of the pending queue. Options: `:cursor`, `:page_size`, `:exam_id`, `:locale`.
  """
  @spec list_queue(String.t(), keyword()) ::
          {:ok, %{items: [map()], next_cursor: String.t() | nil}}
          | {:error, :page_size_too_large | :invalid_cursor | :invalid_exam_id | term()}
  def list_queue(prefix, opts) when is_binary(prefix) and is_list(opts) do
    locale = Keyword.get(opts, :locale)

    with {:ok, page_size} <- Pagination.validate_page_size(Keyword.get(opts, :page_size)),
         {:ok, exam_id} <- cast_exam_id(Keyword.get(opts, :exam_id)),
         {:ok, cursor_key} <- decode_cursor(Keyword.get(opts, :cursor)),
         {:ok, scores} <- pending_scores(prefix),
         {:ok, sessions} <- grading_sessions(scores, exam_id, prefix) do
      candidates =
        scores
        |> Enum.flat_map(&queue_entry(&1, sessions))
        |> Enum.sort_by(& &1.key)
        |> Enum.filter(&(is_nil(cursor_key) or &1.key > cursor_key))

      {page, rest} = Enum.split(candidates, page_size)
      items = render_page(page, locale, prefix)

      next_cursor =
        if rest != [] and page != [],
          do: page |> List.last() |> Map.fetch!(:key) |> encode_cursor()

      {:ok, %{items: items, next_cursor: next_cursor}}
    end
  end

  @doc """
  The detail of one pending answer: the list row plus `text_answer`.
  """
  @spec get_answer(String.t(), term(), term(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def get_answer(prefix, raw_session_id, raw_question_id, opts \\ []) when is_binary(prefix) do
    with {:ok, session_id} <- cast_id(raw_session_id),
         {:ok, question_id} <- cast_id(raw_question_id),
         {:ok, [score | _]} <- pending_score(session_id, question_id, prefix),
         {:ok, session} <- Latest.get_live(session_id, "session", prefix),
         "grading_pending" <- fv(session, "status"),
         {:ok, question} <- Latest.get_live(question_id, "question", prefix),
         "shorttext" <- fv(question, "type") do
      locale = Keyword.get(opts, :locale)

      row =
        row(
          session_id,
          question_id,
          exam_title(fv(session, "exam_id"), locale, prefix),
          localized(fv(question, "stem"), locale, fv(question, "default_locale")),
          fv(score, "max_score"),
          fv(session, "submitted_at")
        )

      {:ok, Map.put(row, "text_answer", text_answer(session_id, question_id, prefix))}
    else
      _ -> {:error, :not_found}
    end
  end

  # ── Reads ───────────────────────────────────────────────────────────────

  defp pending_scores(prefix) do
    Session.scan_records(
      "session_question_score",
      [eq("grading_status", "pending_manual")],
      prefix
    )
  end

  defp pending_score(session_id, question_id, prefix) do
    with {:ok, rows} <-
           Session.scan_records(
             "session_question_score",
             [eq("session_id", session_id), eq("question_id", question_id)],
             prefix
           ) do
      case Enum.filter(rows, &(fv(&1, "grading_status") == "pending_manual")) do
        [] -> {:error, :not_found}
        pending -> {:ok, pending}
      end
    end
  end

  # The sessions of the pending rows that are still waiting for grading. `session_id` is a string
  # column on the score row while `Latest.record_id` is UUID-typed, so uncastable values are dropped
  # before the typed `in ^ids` query.
  defp grading_sessions(scores, exam_id, prefix) do
    ids =
      scores
      |> Enum.map(&fv(&1, "session_id"))
      |> Enum.flat_map(fn id ->
        case cast_id(id) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end
      end)
      |> Enum.uniq()

    query =
      from(r in Latest,
        where: r.entity_type == "session" and r.record_id in ^ids and r.deleted == false
      )

    sessions =
      query
      |> Repo.all(prefix: prefix)
      |> Enum.filter(&(fv(&1, "status") == "grading_pending"))
      |> Enum.filter(&(is_nil(exam_id) or fv(&1, "exam_id") == exam_id))
      |> Map.new(&{&1.record_id, &1})

    {:ok, sessions}
  end

  defp queue_entry(score, sessions) do
    with {:ok, session_id} <- cast_id(fv(score, "session_id")),
         {:ok, question_id} <- cast_id(fv(score, "question_id")),
         %{} = session <- Map.get(sessions, session_id),
         submitted_at when is_binary(submitted_at) <- fv(session, "submitted_at"),
         {:ok, dt, _offset} <- DateTime.from_iso8601(submitted_at) do
      [
        %{
          key: {DateTime.to_unix(dt, :microsecond), session_id, question_id},
          score: score,
          session: session,
          session_id: session_id,
          question_id: question_id
        }
      ]
    else
      _ -> []
    end
  end

  defp render_page(page, locale, prefix) do
    titles =
      page
      |> Enum.map(&fv(&1.session, "exam_id"))
      |> Enum.uniq()
      |> Map.new(&{&1, exam_title(&1, locale, prefix)})

    Enum.flat_map(page, fn entry ->
      case Latest.get_live(entry.question_id, "question", prefix) do
        {:ok, question} ->
          if fv(question, "type") == "shorttext" do
            [
              row(
                entry.session_id,
                entry.question_id,
                Map.fetch!(titles, fv(entry.session, "exam_id")),
                localized(fv(question, "stem"), locale, fv(question, "default_locale")),
                fv(entry.score, "max_score"),
                fv(entry.session, "submitted_at")
              )
            ]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp exam_title(exam_id, locale, prefix) do
    with {:ok, uuid} <- cast_id(exam_id),
         {:ok, exam} <- Latest.get_live(uuid, "exam", prefix) do
      localized(fv(exam, "title"), locale, nil)
    else
      _ -> ""
    end
  end

  defp text_answer(session_id, question_id, prefix) do
    with {:ok, [answer | _]} <-
           Session.scan_records(
             "session_answer",
             [eq("session_id", session_id), eq("question_id", question_id)],
             prefix
           ),
         text when is_binary(text) <- fv(answer, "text_answer") do
      text
    else
      _ -> ""
    end
  end

  # ── Shaping ─────────────────────────────────────────────────────────────

  # Exactly these keys, nothing else (INV-2).
  defp row(session_id, question_id, exam_title, stem, max_score, submitted_at) do
    %{
      "session_id" => session_id,
      "question_id" => question_id,
      "exam_title" => exam_title,
      "stem" => stem,
      "max_score" => number(max_score),
      "submitted_at" => submitted_at
    }
  end

  # The requested locale, else the question's default locale, else the first of kk, ru, en.
  defp localized(%{} = text, locale, default_locale) do
    [locale, default_locale | @locales]
    |> Enum.find_value("", fn l ->
      case is_binary(l) && Map.get(text, l) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp localized(_other, _locale, _default_locale), do: ""

  defp number(value) when is_float(value), do: value
  defp number(value) when is_integer(value), do: value * 1.0
  defp number(%Decimal{} = value), do: Decimal.to_float(value)

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> 0.0
    end
  end

  defp number(_other), do: 0.0

  # ── Ids, filters, cursor ────────────────────────────────────────────────

  defp fv(%{field_values: field_values}, key), do: Map.get(field_values, key)

  defp eq(field, value), do: %{field: field, op: :eq, value: value}

  defp cast_id(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_id(_other), do: :error

  defp cast_exam_id(nil), do: {:ok, nil}

  defp cast_exam_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_exam_id}
    end
  end

  defp cast_exam_id(_other), do: {:error, :invalid_exam_id}

  defp encode_cursor({us, session_id, question_id}),
    do: Pagination.encode_cursor("v1|#{us}|#{session_id}|#{question_id}")

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(encoded) when is_binary(encoded) do
    with {:ok, raw} <- Base.url_decode64(encoded, padding: false),
         ["v1", us, session_id, question_id] <- String.split(raw, "|"),
         {us, ""} <- Integer.parse(us),
         {:ok, session_id} <- Ecto.UUID.cast(session_id),
         {:ok, question_id} <- Ecto.UUID.cast(question_id) do
      {:ok, {us, session_id, question_id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_other), do: {:error, :invalid_cursor}
end
