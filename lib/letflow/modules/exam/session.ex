defmodule Letflow.Modules.Exam.Session do
  @moduledoc """
  REQ-332 -- live exam-session runtime: start, autosave, submit, and the
  system-triggered auto-finalize path. Ported from
  `backend/internal/sessions/service.go`'s `CreateSession`/`SaveAnswer`/
  `SubmitSession` (FR-BB35/FR-BB37/FR-BB39, roadmap 3.5/3.7/3.9). Authorized
  by `lib/letflow/design/req330-exam-live-session.md` §7's rule-2 module
  table, `Letflow.Modules.Exam.Session` row -- read that document in full before
  changing this module's responsibilities.

  ## Rule-2 justification (verbatim from the design doc's table, REQ-330/0022 rule 2)

  **Why not A (a definition).** Orchestrates a stateful, multi-step write
  sequence (eligibility checks in a fixed order, seeded materialization,
  ownership-checked autosave/submit) with server-authoritative deadline
  comparison against wall-clock time -- an entity definition has no
  execution semantics and cannot run a multi-step `with`-chain or compare
  against `DateTime.utc_now()`.

  **Why not B (a generic platform capability).** The eligibility rule set
  (assignment, exam-active/archived, availability window, attempt limits,
  one-open-session) and the ownership/deadline guards are all specific to
  this vertical's session-lifecycle vocabulary (0022 rule 1); nothing
  outside this vertical shares this exact rule set today.

  ## NO per-session process or process-lookup table (REQ-045/decision 0022, non-negotiable)

  This module deliberately names none of the three forbidden mechanisms
  literally in its own source, so that a `grep` for them across
  `lib/letflow/exam/` (REQ-332's own acceptance criterion) returns zero
  hits, including in prose -- not just zero real usages.

  This is a plain module with ordinary functions over `Letflow.Entities.Records`/
  `Letflow.Entities.Query`, exactly like `Letflow.Engine`'s own
  "Process-vs-row decision." Concurrency at `submit/3`/`finalize_expired/3`
  (via `lock_session_row/2`) and at `create/3` (via `lock_exam_row/2`) is
  arbitrated by a real Postgres row lock (`lock("FOR UPDATE")`, the same
  idiom `lib/letflow/event_store.ex`'s `lock_and_increment_sequence/3`
  already uses), never by an in-memory process. See `create_with_seed/4`'s
  own comment for why `create/3`'s lock is taken on the `exam` row rather
  than a `session` row.

  ## Data lives in bucket A -- no migration, no Ecto schema here

  Every read and write goes through `Letflow.Entities.Records`
  (create/update) and `Letflow.Entities.Query.Compiler` +
  `Letflow.Entities.Record.Latest` (read). `session`, `session_question`,
  `session_answer` and `session_question_score` (REQ-329) are the only
  entity types this module writes; `exam`, `question` and `answer_option`
  (P1) are read-only inputs.

  ## Autosave write path -- REQ-330's own conclusion, implemented exactly

  Decision `0030`/the design doc §3 measured autosave cost and concluded:
  **"Autosave is implemented via the ORDINARY `Letflow.Entities.Records`/
  `Letflow.Entities.Query` write path, with no fast path, no second write
  mechanism, and no new bucket-B capability built or required."**
  `autosave_answer/4`'s `upsert_answer/5` below does exactly that: an
  ordinary `Letflow.Entities.Query.Compiler` read to find any existing
  `session_answer` row for `(session_id, question_id)`, then an ordinary
  `Letflow.Entities.Records.update_record/2` or `create_record/2` -- no
  fast path, no second write mechanism.

  ## Assignment check (REQ-582) -- enforced, fails closed

  REQ-332's eligibility pipeline is ported from `service.go`'s
  `CreateSession`, whose first check is that the candidate is *assigned* to
  the exam. Until REQ-582 part B that check (`check_assigned/3`) was a
  documented no-op because no `exam_assignment` entity existed (REQ-582
  part A authored it). It now reads the exam's **active** `exam_assignment`
  records under the tenant prefix and starts the session only when one
  matches the candidate:

    * `all` -- every candidate;
    * `user` -- `assignee_id` equals the candidate's user id;
    * `group` -- the candidate is a member of the group `assignee_id`;
    * `org_unit` -- the candidate has an **active** membership in exactly
      that unit (child units do not count; no org module installed matches
      nobody).

  No assignment, only withdrawn (`active: false`) ones, a missing
  `exam_assignment` definition, a malformed or missing `assignee_id` all
  answer `{:error, :not_assigned}` (fail closed, no exception). The check
  stays before the status, window and attempt checks.

  ## A second, narrower flagged gap -- `submission_outcome()`'s raw sums on the idempotent-replay path

  The `session` entity (REQ-329) persists only `score_pct` and `passed`,
  not the raw `sum(score)`/`sum(max_score)` `score_session/3` computes.
  When `submit/3`/`get_session_for_user/3` return the **recorded** outcome
  of an already-submitted session (the idempotent path), `total_score`/
  `total_max_score` are reconstructed as `percentage`/`100.0` rather than
  the original raw sums, which are not persisted anywhere. This is a
  precision-preserving approximation, not a bug: `percentage` and `passed`
  -- the two fields REQ-332's own acceptance criteria and REQ-331's sweep
  actually consume -- are exact.

  ## Certificate issuance -- explicitly out of scope

  No certificate module, no PDF/QR dependency, no placeholder. See
  `mix.exs`'s unchanged dependency list.

  ## REQ-335 addition -- `get_session_state_for_user/3`

  REQ-335 (the HTTP route surface REQ-332/REQ-333 left unbuilt) added this
  one read-composition function so `Letflow.Modules.Exam.Router`' session-
  state route stays a thin composition layer with no execution semantics of
  its own, matching that requirement's own scope note. No new bucket-C
  reasoning is added by it -- it reuses this module's own private
  `query_all/3`/`fv/2`/`question_type_atom/1` helpers and adds no new
  eligibility rule, write path, or state transition. See that function's own
  `@doc` for the redaction decision it implements.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.FieldPolicy
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.Cursor
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.QuestionSetResolver
  alias Letflow.Modules.Exam.Scoring
  alias Letflow.Modules.Exam.Snapshot
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @default_available_exams_page_size 100

  @type eligibility_error ::
          :not_assigned
          | :exam_archived
          | :exam_not_active
          | :outside_availability_window
          | :attempts_exhausted
          | {:session_already_open, session_id :: String.t()}

  @typedoc """
  GH #2682 / REQ-511 -- `{:grading_error, reason}` is the typed failure of everything that reads or
  builds the exam snapshot (see `Letflow.Modules.Exam.Snapshot`); `{:snapshot_error, reason}` means
  the snapshot prerequisites (the `session.exam_snapshot` field, its restriction row) are not in
  place yet, i.e. the rollout has not run.
  """
  @type snapshot_failure ::
          Snapshot.grading_error()
          | {:snapshot_error,
             :definition_missing | :restrictions_missing | :audit_failed | :write_failed}

  @type autosave_error ::
          :session_not_found
          | :not_owner
          | :session_not_in_progress
          | :deadline_passed
          | :question_not_in_session
          | :answer_shape_invalid
          | :option_not_in_question
          | snapshot_failure()

  @type submit_error :: :session_not_found | :not_owner | snapshot_failure()

  @type submission_outcome :: %{
          status: :submitted | :grading_pending | :auto_submitted,
          total_score: float(),
          total_max_score: float(),
          percentage: float(),
          passed: boolean() | nil
        }

  @type session_view :: %{
          id: String.t(),
          exam_id: String.t(),
          candidate_id: String.t(),
          status: :in_progress | :submitted | :auto_submitted | :grading_pending,
          seed: integer(),
          started_at: DateTime.t(),
          expires_at: DateTime.t(),
          score_pct: float() | nil,
          passed: boolean() | nil
        }

  @type answer_attrs :: %{
          required(:question_id) => String.t(),
          required(:selected_option_ids) => [String.t()],
          required(:time_spent_seconds) => non_neg_integer(),
          optional(:text_answer) => String.t() | nil
        }

  @type exam_row :: Latest.t() | Compiler.entity_row()

  # -----------------------------------------------------------------------
  # list_available_exams/2 (ISS-0718)
  # -----------------------------------------------------------------------

  @doc """
  Lists the `exam` entity records a CANDIDATE may currently start a session
  against (`lib/letflow/design/iss0718-candidate-exam-list-route.md` §1.2).

  `entity_type: "exam"` and `filters: [status eq "active", deleted eq false]`
  (GH #2760: a soft-deleted exam is never offered) are hardcoded
  in this function's own body, never derived from `opts` or any caller
  input -- `opts` carries pagination (`:cursor`, `:page_size`, default
  #{@default_available_exams_page_size} when `:page_size` is omitted or
  `nil`) and the REQUIRED `:scope` (REQ-518: the caller's allowed node set, a
  `Types.scope_set()`, read with `Keyword.fetch!/2`, so a missing key raises; it is passed to
  `Compiler.compile/3`) and the REQUIRED `:user_id` (the caller, read with `Keyword.fetch!/2`
  after pagination, so the `:scope` contract above still raises first). Reuses the same
  three-step read pipeline `Letflow.Routers.Entities`' generic `POST /entities/query` route
  calls (`Compiler.compile/3`, `Allowlist.load/2`, `Cursor.paginate/5`) -- library
  modules, not HTTP-route-specific. The page then gets the same `FieldGrants` redaction that
  route applies: the caller's restriction set for `"exam"` (`FieldPolicy.restriction_set/2`)
  replaces every restricted `field_values` entry with the sentinel before the rows are
  rendered. No row exists for entity_type "exam" today (design doc §6 OQ-1), so this changes
  nothing for the present data; it closes the gap for a restriction added later.
  """
  @spec list_available_exams(prefix :: String.t(), opts :: keyword()) ::
          {:ok, %{items: [exam_row()], next_cursor: String.t() | nil}}
          | {:error, term()}
  def list_available_exams(prefix, opts) when is_binary(prefix) and is_list(opts) do
    request = %{
      entity_type: "exam",
      # GH #2760: a soft-deleted exam is not offered (start refuses it).
      filters: [
        %{field: "status", op: :eq, value: "active"},
        %{field: "deleted", op: :eq, value: false}
      ],
      sort: [],
      join: []
    }

    paginate_opts = %{
      cursor: Keyword.get(opts, :cursor),
      page_size: Keyword.get(opts, :page_size) || @default_available_exams_page_size
    }

    scope = Keyword.fetch!(opts, :scope)

    with {:ok, compiled} <- Compiler.compile(request, prefix, scope),
         {:ok, allowlist} <- Allowlist.load(request.entity_type, prefix),
         user_id = Keyword.fetch!(opts, :user_id),
         paginate_opts = Map.put(paginate_opts, :user_id, user_id),
         {:ok, page} <- Cursor.paginate(request, compiled, allowlist, paginate_opts, prefix),
         {:ok, restrictions} <-
           FieldPolicy.restriction_set(%{user_id: user_id, prefix: prefix}, "exam") do
      page = FieldGrants.redact_page(page, restrictions)
      {:ok, %{items: page.items, next_cursor: page.next_cursor}}
    end
  end

  # -----------------------------------------------------------------------
  # create/3
  # -----------------------------------------------------------------------

  @doc """
  Starts a new session for `candidate_id` on `exam_id` (design §8):
  eligibility checks in order (assignment*, exam active/archived,
  availability window, attempt limit, no already-open session), then a
  fresh seed is drawn and the question set is resolved and materialised.

  \\* see this module's moduledoc "Assignment check (REQ-582)" section -- the
  check is enforced and fails closed.
  """
  @spec create(candidate_id :: String.t(), exam_id :: String.t(), prefix :: String.t()) ::
          {:ok, session_view()} | {:error, eligibility_error() | snapshot_failure()}
  def create(candidate_id, exam_id, prefix)
      when is_binary(candidate_id) and is_binary(exam_id) and is_binary(prefix) do
    create_with_seed(candidate_id, exam_id, prefix, draw_seed())
  end

  @doc false
  # Test seam only (NOT part of REQ-330's authorized 3-arg `create/3`
  # contract) -- lets tests prove seeded reproducibility end-to-end without
  # depending on the internally-drawn random seed. `create/3` is a thin
  # wrapper over this function with a freshly drawn seed.
  #
  # REVIEWER finding (WF02-REQ332-20260913 rework): the whole eligibility
  # -check-then-materialize pipeline now runs inside one `Repo.transaction/1`
  # that opens by taking a real Postgres row lock (`lock("FOR UPDATE")`,
  # `lock_exam_row/2` below) on the `exam` entity's own `entity_record_latest`
  # row for `exam_id` -- the same idiom `lock_session_row/2` already uses for
  # `submit/3`/`finalize_expired/3`, just scoped to the exam row rather than
  # a session row (no `session` row exists yet at create-time to lock: that
  # is exactly the row this call is about to create). Two concurrent
  # `create/3` calls for the same `exam_id` now serialize on that lock, so
  # the second call's "no open session" / "attempts exhausted" read
  # (`query_all("session", ...)` below) is guaranteed to observe the first
  # call's write before deciding -- closing the race REVIEWER identified
  # (both callers reading zero sessions before either wrote one). This is
  # intentionally coarser-grained than a per-`(candidate_id, exam_id)` lock
  # (it serializes *all* candidates starting the same exam concurrently, not
  # just the same candidate racing themselves) because no
  # per-`(candidate_id, exam_id)` row/unique-constraint exists in the schema
  # to lock on instead, and adding one is a migration/entity-definition
  # change outside this requirement's authorized scope (REQ-329/
  # CODE-DESIGNER territory, per REVIEWER's own instruction). Correctness
  # over concurrency: a brief lock held for one exam-start's eligibility
  # checks plus materialization is an acceptable trade here.
  @spec create_with_seed(String.t(), String.t(), String.t(), integer()) ::
          {:ok, session_view()} | {:error, eligibility_error() | snapshot_failure() | term()}
  def create_with_seed(candidate_id, exam_id, prefix, seed) do
    Repo.transaction(fn -> create_txn(candidate_id, exam_id, prefix, seed) end)
  end

  defp create_txn(candidate_id, exam_id, prefix, seed) do
    with {:ok, exam} <- lock_exam_row(exam_id, prefix),
         :ok <- check_assigned(candidate_id, exam_id, prefix),
         :ok <- check_exam_status(exam),
         :ok <- check_availability_window(exam),
         {:ok, existing_sessions} <-
           query_all("session", [eq("exam_id", exam_id), eq("user_id", candidate_id)], prefix),
         :ok <- check_attempts_exhausted(existing_sessions, fv(exam, "max_attempts")),
         :ok <- check_no_open_session(existing_sessions),
         {:ok, session_view} <- materialize_session(candidate_id, exam_id, exam, prefix, seed) do
      session_view
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # -----------------------------------------------------------------------
  # get_session_for_user/3
  # -----------------------------------------------------------------------

  @spec get_session_for_user(
          session_id :: String.t(),
          user_id :: String.t(),
          prefix :: String.t()
        ) ::
          {:ok, session_view()} | {:error, :session_not_found | :not_owner}
  def get_session_for_user(session_id, user_id, prefix) do
    case Latest.get(session_id, "session", prefix) do
      {:ok, session} ->
        if fv(session, "user_id") == user_id do
          {:ok, session_view(session)}
        else
          {:error, :not_owner}
        end

      {:error, :not_found} ->
        {:error, :session_not_found}

      {:error, :invalid_schema_name} = error ->
        error
    end
  end

  # -----------------------------------------------------------------------
  # get_snapshot_for_user/3 (GH #2682 / REQ-511 PR b)
  # -----------------------------------------------------------------------

  @doc """
  The VERIFIED snapshot of the owner's session, for the certificate path (design 6, 17.2). The
  certificate module calls ONLY this function and never reads the live exam.

  Ownership first (`:session_not_found` / `:not_owner`, rendered as one 404). A present snapshot
  is returned verified. An absent one on a `submitted` session goes to
  `Snapshot.ensure_certificate_facts/3` (certificate-only `late_certificate` facts, once, only for a
  record inserted before the cutover); on any other status it is `{:grading_error,
  :snapshot_missing}` with no write.
  """
  @spec get_snapshot_for_user(
          session_id :: String.t(),
          user_id :: String.t(),
          prefix :: String.t()
        ) ::
          {:ok, Snapshot.snapshot()}
          | {:error, :session_not_found | :not_owner | snapshot_failure()}
  def get_snapshot_for_user(session_id, user_id, prefix) do
    with {:ok, session_record} <- fetch_session(session_id, prefix),
         :ok <- check_owner(session_record, user_id) do
      case Snapshot.fetch_verified(session_record.field_values) do
        {:ok, _snapshot} = ok ->
          ok

        {:error, {:grading_error, :snapshot_missing}} ->
          if fv(session_record, "status") == "submitted",
            do: Snapshot.ensure_certificate_facts(session_id, user_id, prefix),
            else: {:error, {:grading_error, :snapshot_missing}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # -----------------------------------------------------------------------
  # get_session_state_for_user/3 (REQ-335)
  # -----------------------------------------------------------------------

  @type question_state :: %{
          question_id: String.t(),
          sort_order: integer(),
          type: :single | :multiple | :true_false | :likert | :short_text,
          stem: term(),
          options: [%{id: String.t(), text: term()}]
        }

  @type saved_answer :: %{
          selected_option_ids: [String.t()],
          text_answer: String.t() | nil,
          time_spent_seconds: non_neg_integer() | nil,
          saved_at: String.t() | nil
        }

  @type session_state_view :: %{
          session: session_view(),
          remaining_seconds: non_neg_integer(),
          questions: [question_state()],
          answers: %{String.t() => saved_answer()}
        }

  @doc """
  REQ-335 -- `Letflow.Modules.Exam.Router`' session-state read route calls
  this, not `get_session_for_user/3` alone, because a candidate resuming a
  session needs the materialised question set to render it, not just the
  session envelope. Ownership is delegated entirely to
  `get_session_for_user/3` (same `:session_not_found`/`:not_owner` errors,
  same 404-not-403 shape).

  ## REQ-335's own redaction decision, implemented here (not via FieldGrants)

  Every question/option field is HAND-SELECTED, never delegated to a generic
  entity-record serializer: `question_state/0` carries only `question_id`,
  `sort_order`, `type` and `stem` from `question` (never `explanation`,
  which narrates the correct answer, nor `difficulty`/`category_id`/
  `status`/`version`, which add nothing a candidate needs); each option
  carries only `id` and `text` from `answer_option` (never `is_correct`,
  `likert_weight` or `likert_polarity`). `Letflow.Entities.Query.FieldGrants`
  (REQ-231) was considered and rejected for this route: it redacts fields
  within ONE `Letflow.Entities.Query.Compiler` result page for ONE entity
  type, but this response is a hand-composed view joining four entity types
  (`session`, `session_question`, `question`, `answer_option`,
  `session_answer`) with no single query result for a `FieldGrants` call to
  redact. Hand-selecting fields makes leaking `is_correct` a compile-time-
  visible omission rather than a runtime configuration dependency.

  ISS-0647 (SECURITY-REVIEWER): this hand-redaction only ever protected
  THIS route. `TASK_WORKER` -- the role REQ-335 grants every exam-session
  permission to -- already held `:EntitiesQuery`/`:EntitiesAggregate`
  before REQ-335 existed, and until ISS-0647's fix, this pack configured
  no `entity_field_restrictions` row for `is_correct`/`likert_weight`/
  `likert_polarity`/`explanation` at all -- so a candidate could read every
  one of them in clear via the GENERIC `POST /entities/query` route
  directly against `question`/`answer_option`, entirely bypassing this
  function's own careful field selection. `Letflow.Packs.Bilimbaga.
  seed_answer_key_field_restrictions!/1` seeded exactly those four
  `entity_field_restrictions` rows (REQ-411 moved this to
  `Letflow.Modules.Exam.on_install/2`; GH #2682 added a fifth pair,
  `session.exam_snapshot`, so `Letflow.Modules.Exam.answer_key_fields/0` now
  lists five) wherever this pack's real entity definitions are provisioned,
  closing that second path — see that
  module's moduledoc for the full account. This function's own
  hand-selection is left unchanged and stays defense-in-depth; it was
  never the vulnerable half.
  """
  @spec get_session_state_for_user(
          session_id :: String.t(),
          user_id :: String.t(),
          prefix :: String.t()
        ) ::
          {:ok, session_state_view()}
          | {:error, :session_not_found | :not_owner | snapshot_failure()}
  def get_session_state_for_user(session_id, user_id, prefix) do
    with {:ok, session_record} <- fetch_session(session_id, prefix),
         :ok <- check_owner(session_record, user_id),
         {:ok, type_source} <- state_type_source(session_record, user_id, prefix),
         session = session_view(session_record),
         {:ok, session_questions} <-
           query_all("session_question", [eq("session_id", session_id)], prefix),
         sorted_questions = Enum.sort_by(session_questions, &fv(&1, "sort_order")),
         {:ok, questions} <- build_question_states(sorted_questions, type_source, prefix),
         {:ok, session_answers} <-
           query_all("session_answer", [eq("session_id", session_id)], prefix) do
      {:ok,
       %{
         session: session,
         remaining_seconds: DateTime.diff(session.expires_at, utc_now(), :second) |> max(0),
         questions: questions,
         answers: answer_map(session_answers)
       }}
    end
  end

  # GH #2682 / REQ-511, design 5.3 and 17.1: where a question's TYPE comes from. An `in_progress`
  # session needs a structurally valid snapshot (it can still be scored and autosaved), and a
  # failure is a typed grading error. A terminal session can never be scored or autosaved again,
  # so reading it must never fail or write because of the snapshot: it uses the snapshot item when
  # there is one and the live question type as display data otherwise.
  #
  # PR b (design 9.1, 17.1): an `in_progress` session with NO snapshot (started before the
  # cutover) is a touch - `Snapshot.ensure/3` builds a late one under the row lock, once. A
  # terminal session is never a touch: no ensure, no write, no error.
  defp state_type_source(session_record, user_id, prefix) do
    snapshot_result = Snapshot.fetch_structural(session_record.field_values)

    case {fv(session_record, "status"), snapshot_result} do
      {"in_progress", {:ok, snapshot}} ->
        {:ok, {:strict, snapshot}}

      {"in_progress", {:error, {:grading_error, :snapshot_missing}}} ->
        with {:ok, snapshot} <- Snapshot.ensure(session_record.record_id, user_id, prefix) do
          {:ok, {:strict, snapshot}}
        end

      {"in_progress", {:error, _reason} = error} ->
        error

      {_terminal, {:ok, snapshot}} ->
        {:ok, {:lenient, snapshot}}

      {_terminal, {:error, _reason}} ->
        {:ok, {:lenient, nil}}
    end
  end

  defp state_question_type({:strict, snapshot}, question_id, _question),
    do: Snapshot.question_type(snapshot, question_id)

  defp state_question_type({:lenient, nil}, _question_id, question),
    do: {:ok, question_type_atom(fv(question, "type"))}

  defp state_question_type({:lenient, snapshot}, question_id, question) do
    case Snapshot.question_type(snapshot, question_id) do
      {:ok, _type} = ok -> ok
      {:error, _reason} -> {:ok, question_type_atom(fv(question, "type"))}
    end
  end

  defp build_question_states(session_questions, type_source, prefix) do
    session_questions
    |> Enum.reduce_while({:ok, []}, fn session_question, {:ok, acc} ->
      case build_question_state(session_question, type_source, prefix) do
        {:ok, question_state} -> {:cont, {:ok, [question_state | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _reason} = error -> error
    end
  end

  defp build_question_state(session_question, type_source, prefix) do
    question_id = fv(session_question, "question_id")

    case Latest.get(question_id, "question", prefix) do
      {:ok, question} ->
        option_ids = fv(session_question, "options_order") || []

        with {:ok, type} <- state_question_type(type_source, question_id, question),
             {:ok, options} <- build_option_states(type, question_id, option_ids, prefix) do
          {:ok,
           %{
             question_id: question_id,
             sort_order: fv(session_question, "sort_order"),
             type: type,
             stem: fv(question, "stem"),
             options: options
           }}
        end

      {:error, :not_found} ->
        {:error, {:question_not_found, question_id}}

      {:error, :invalid_schema_name} = error ->
        error
    end
  end

  defp build_option_states(:short_text, _question_id, _option_ids, _prefix), do: {:ok, []}

  defp build_option_states(_type, question_id, option_ids, prefix) do
    with {:ok, option_records} <-
           query_all("answer_option", [eq("question_id", question_id)], prefix) do
      by_id = Map.new(option_records, &{&1.record_id, &1})

      options =
        option_ids
        |> Enum.filter(&Map.has_key?(by_id, &1))
        |> Enum.map(fn option_id ->
          option = Map.fetch!(by_id, option_id)
          %{id: option_id, text: fv(option, "text")}
        end)

      {:ok, options}
    end
  end

  defp answer_map(session_answers) do
    Map.new(session_answers, fn answer ->
      {fv(answer, "question_id"),
       %{
         selected_option_ids: fv(answer, "selected_option_ids") || [],
         text_answer: fv(answer, "text_answer"),
         time_spent_seconds: fv(answer, "time_spent_seconds"),
         saved_at: fv(answer, "saved_at")
       }}
    end)
  end

  # -----------------------------------------------------------------------
  # autosave_answer/4
  # -----------------------------------------------------------------------

  @doc """
  Autosaves one answer (design §8, FR-BB37/roadmap 3.7). Validation order:
  non-negative time-spent, ownership, in-progress, server-side deadline,
  question-in-session, answer-shape-for-type, every selected option belongs
  to this question. Response always carries `remaining_seconds` clamped at
  zero -- the client clock never satisfies this, since no client-supplied
  timestamp is ever accepted (roadmap 3.7).

  ISS-0650: `text_answer` is the free-text answer for a `:short_text`
  question -- optional in `answer_attrs()` (a map missing the key behaves
  exactly like one carrying `text_answer: nil`) so every existing caller
  that never sends it keeps working unchanged. `check_answer_shape/3`
  rejects a non-nil `text_answer` for every OTHER question type, and rejects
  a non-nil/non-binary `text_answer` for `:short_text` -- see that
  function.
  """
  @spec autosave_answer(
          session_id :: String.t(),
          user_id :: String.t(),
          answer_attrs :: answer_attrs(),
          prefix :: String.t()
        ) :: {:ok, %{remaining_seconds: non_neg_integer()}} | {:error, autosave_error()}
  def autosave_answer(
        session_id,
        user_id,
        %{
          question_id: question_id,
          selected_option_ids: selected_option_ids,
          time_spent_seconds: time_spent_seconds
        } = attrs,
        prefix
      ) do
    text_answer = Map.get(attrs, :text_answer)

    with :ok <- check_non_negative(time_spent_seconds),
         {:ok, session} <- fetch_session(session_id, prefix),
         :ok <- check_owner(session, user_id),
         :ok <- check_in_progress(session),
         :ok <- check_deadline(session),
         {:ok, session_question} <- fetch_session_question(session_id, question_id, prefix),
         {:ok, type} <- snapshot_question_type(session, question_id, user_id, prefix),
         :ok <- check_answer_shape(type, selected_option_ids, text_answer),
         :ok <- check_options_belong(session_question, selected_option_ids),
         :ok <-
           upsert_answer(
             session_id,
             question_id,
             selected_option_ids,
             text_answer,
             time_spent_seconds,
             parse_dt!(fv(session, "started_at")),
             user_id,
             prefix
           ) do
      {:ok, %{remaining_seconds: remaining_seconds(session)}}
    end
  end

  # -----------------------------------------------------------------------
  # submit/3
  # -----------------------------------------------------------------------

  @doc """
  Submits a session (design §8, FR-BB39/roadmap 3.9). Idempotent: an
  already-submitted/auto-submitted/grading-pending session returns the
  recorded outcome without re-scoring. Two concurrent submits of the same
  session produce exactly one scored outcome -- enforced by a real Postgres
  row lock (`lock("FOR UPDATE")`) on the session row, held for the whole
  transaction.
  """
  @spec submit(session_id :: String.t(), user_id :: String.t(), prefix :: String.t()) ::
          {:ok, submission_outcome()} | {:error, submit_error() | term()}
  def submit(session_id, user_id, prefix) do
    Repo.transaction(fn -> submit_txn(session_id, user_id, prefix) end)
  end

  defp submit_txn(session_id, user_id, prefix) do
    case lock_session_row(session_id, prefix) do
      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, session} ->
        cond do
          fv(session, "user_id") != user_id ->
            Repo.rollback(:not_owner)

          fv(session, "status") in ["submitted", "auto_submitted", "grading_pending"] ->
            outcome_from_session(session)

          true ->
            case score_and_persist(session, prefix, audit_actor_id: user_id) do
              {:ok, outcome} -> outcome
              {:error, reason} -> Repo.rollback(reason)
            end
        end
    end
  end

  # -----------------------------------------------------------------------
  # finalize_expired/3 -- system-triggered path (REQ-331's configured
  # callback, design §2/§8). No ownership check (the caller is the sweep,
  # not a candidate); `submitted_at` is forced to `deadline_at`, never to
  # the wall-clock time of the call.
  # -----------------------------------------------------------------------

  @spec finalize_expired(
          session_id :: String.t(),
          deadline_at :: DateTime.t(),
          prefix :: String.t()
        ) ::
          {:ok, submission_outcome()} | {:error, term()}
  def finalize_expired(session_id, %DateTime{} = deadline_at, prefix) do
    Repo.transaction(fn -> finalize_txn(session_id, deadline_at, prefix) end)
  end

  defp finalize_txn(session_id, deadline_at, prefix) do
    case lock_session_row(session_id, prefix) do
      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, session} ->
        if fv(session, "status") in ["submitted", "auto_submitted", "grading_pending"] do
          outcome_from_session(session)
        else
          case score_and_persist(session, prefix,
                 submitted_at: deadline_at,
                 status_override: :auto_submitted
               ) do
            {:ok, outcome} -> outcome
            {:error, reason} -> Repo.rollback(reason)
          end
        end
    end
  end

  # =======================================================================
  # Eligibility checks (private, single-caller -- see design §7's note on
  # why these are not their own module)
  # =======================================================================

  # Locked replacement for the plain `Latest.get/3` read `fetch_exam/2` used
  # to do -- same `:not_found` -> `:exam_not_active` mapping and same
  # `:invalid_schema_name` passthrough (mirrors `Latest.get/3`'s own guard),
  # but taken with `lock("FOR UPDATE")` so `create_txn/4`'s whole
  # eligibility-check-plus-materialize sequence serializes per `exam_id`.
  # See `create_with_seed/4`'s moduledoc-style comment above for why this
  # exam-row lock, not a `lock_session_row/2`-style session-row lock, is
  # what closes REVIEWER's create/3 race.
  defp lock_exam_row(exam_id, prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      # GH #2760: `deleted == false` in the locked WHERE (re-evaluated after the
      # FOR UPDATE wait under READ COMMITTED), so a soft-deleted exam, even an
      # archived one, answers :exam_not_active exactly like a nonexistent one.
      query =
        from(r in Latest,
          where: r.entity_type == "exam" and r.record_id == ^exam_id and r.deleted == false
        )

      case query |> Ecto.Query.lock("FOR UPDATE") |> Repo.one(prefix: prefix) do
        nil -> {:error, :exam_not_active}
        row -> {:ok, row}
      end
    end
  end

  # REQ-582 part B: fail closed. The exam's active `exam_assignment` rows are read under the
  # tenant prefix only (INV-1/INV-6); one matching row is enough. A tenant with no
  # `exam_assignment` definition yet answers :not_assigned too, never a different error.
  defp check_assigned(candidate_id, exam_id, prefix) do
    # scope-all: SEC-518-R1
    case query_all("exam_assignment", [eq("exam_id", exam_id), eq("active", true)], prefix) do
      {:ok, rows} ->
        if Enum.any?(rows, &assignment_matches?(&1, candidate_id, prefix)),
          do: :ok,
          else: {:error, :not_assigned}

      {:error, :entity_type_not_found} ->
        {:error, :not_assigned}

      {:error, _reason} = other ->
        other
    end
  end

  defp assignment_matches?(row, candidate_id, prefix) do
    assignee_id = fv(row, "assignee_id")

    case fv(row, "assignee_type") do
      "all" -> true
      "user" -> is_binary(assignee_id) and assignee_id == candidate_id
      "group" -> group_assignment_matches?(assignee_id, candidate_id, prefix)
      "org_unit" -> org_unit_assignment_matches?(assignee_id, candidate_id, prefix)
      _other -> false
    end
  end

  # `Identity.group_member?/3` raises on a non-UUID id, so the id is cast first (INV-8).
  defp group_assignment_matches?(assignee_id, candidate_id, prefix) when is_binary(assignee_id) do
    case Ecto.UUID.cast(assignee_id) do
      {:ok, group_id} -> Letflow.Identity.group_member?(group_id, candidate_id, prefix)
      :error -> false
    end
  end

  defp group_assignment_matches?(_assignee_id, _candidate_id, _prefix), do: false

  # Exact organisational-unit match (REQ-582 open question 2): an active membership in the
  # assigned unit itself; child units do not count. No org module installed matches nobody.
  defp org_unit_assignment_matches?(assignee_id, candidate_id, prefix)
       when is_binary(assignee_id) do
    if Letflow.Modules.Installs.installed?("org", prefix: prefix) do
      # scope-all: SEC-518-R1
      filters = [eq("user_id", candidate_id), eq("org_unit_id", assignee_id), eq("active", true)]

      case query_all("org_unit_membership", filters, prefix) do
        {:ok, [_ | _]} -> true
        _none_or_error -> false
      end
    else
      false
    end
  end

  defp org_unit_assignment_matches?(_assignee_id, _candidate_id, _prefix), do: false

  defp check_exam_status(exam) do
    case fv(exam, "status") do
      "archived" -> {:error, :exam_archived}
      "active" -> :ok
      _other -> {:error, :exam_not_active}
    end
  end

  defp check_availability_window(exam) do
    now = DateTime.utc_now()

    with :ok <- check_available_from(exam, now) do
      check_available_until(exam, now)
    end
  end

  defp check_available_from(exam, now) do
    case fv(exam, "available_from") do
      nil ->
        :ok

      value ->
        if DateTime.compare(now, parse_dt!(value)) == :lt,
          do: {:error, :outside_availability_window},
          else: :ok
    end
  end

  defp check_available_until(exam, now) do
    case fv(exam, "available_until") do
      nil ->
        :ok

      value ->
        if DateTime.compare(now, parse_dt!(value)) == :gt,
          do: {:error, :outside_availability_window},
          else: :ok
    end
  end

  defp check_attempts_exhausted(sessions, max_attempts) do
    finished =
      Enum.count(
        sessions,
        &(fv(&1, "status") in ["submitted", "auto_submitted", "grading_pending"])
      )

    if finished >= max_attempts, do: {:error, :attempts_exhausted}, else: :ok
  end

  # Q-1076 / GH #2433: the error carries the id of the candidate's own open session, so a
  # reloaded page can resume it. `sessions` is create_txn's query for this exam and this
  # candidate under the tenant prefix, so the id can never be another candidate's or another
  # tenant's session.
  defp check_no_open_session(sessions) do
    case Enum.find(sessions, &(fv(&1, "status") == "in_progress")) do
      nil -> :ok
      open -> {:error, {:session_already_open, normalize_record_id(open.record_id)}}
    end
  end

  # =======================================================================
  # Materialization (create path)
  # =======================================================================

  defp materialize_session(candidate_id, exam_id, exam, prefix, seed) do
    shuffle_options? = fv(exam, "shuffle_options") == true

    with :ok <- Snapshot.check_prerequisites(prefix),
         {:ok, rules, pool, manual_questions} <- fetch_question_pools(exam_id, prefix),
         {:ok, resolved_random} <-
           QuestionSetResolver.resolve(
             rules,
             pool,
             fv(exam, "shuffle_questions") == true,
             shuffle_options?,
             seed
           ) do
      resolved_manual_unindexed =
        Enum.map(manual_questions, fn %{question_id: question_id, option_ids: option_ids} ->
          %{
            question_id: question_id,
            options_order:
              if shuffle_options? do
                Enum.shuffle(option_ids)
              else
                option_ids
              end
          }
        end)

      resolved_manual =
        resolved_manual_unindexed
        |> Enum.with_index(length(resolved_random))
        |> Enum.map(fn {row, index} -> Map.put(row, :sort_order, index) end)

      now = utc_now()
      expires_at = DateTime.add(now, fv(exam, "time_limit_minutes") * 60, :second)

      # GH #2682 / REQ-511, design 4.3: the snapshot is built from the rows already loaded for the
      # resolved set, under the exam row lock, and written in the SAME create call as the
      # session, so a session created after this change never exists without its snapshot.
      order = Enum.map(resolved_random ++ resolved_manual, & &1.question_id)

      sources =
        pool
        |> Map.values()
        |> List.flatten()
        |> Enum.concat(manual_questions)
        |> Map.new(&{&1.question_id, &1.source})

      with {:ok, usable} <- refuse_drawn(sources, order),
           {:ok, snapshot} <-
             Snapshot.build_from_resolved(
               exam.field_values,
               usable,
               order,
               %{origin: :start, exam_id: exam_id, taken_at: now}
             ),
           session_attrs =
             %{
               "exam_id" => exam_id,
               "user_id" => candidate_id,
               "status" => "in_progress",
               "seed" => seed,
               "started_at" => iso8601(now),
               "expires_at" => iso8601(expires_at),
               "passed" => false,
               "exam_snapshot" => snapshot
             },
           {:ok, %{record: session_record}} <-
             write_record("session", session_attrs, candidate_id, prefix),
           :ok <-
             persist_session_questions(
               session_record.record_id,
               resolved_random,
               resolved_manual,
               candidate_id,
               prefix
             ) do
        {:ok, session_view(session_record)}
      end
    end
  end

  # GH #2762: a question's snapshot source as read at start. `{:error, ...}` is the refusal carried
  # (not raised) until the draw shows whether the question is actually used.
  @typep wrapped_source ::
           {:usable, Snapshot.question_source()}
           | {:error, {:grading_error, {:key_missing, String.t()}}}

  # The resolver row (`question_id`, `option_ids`) plus the `source` the snapshot needs.
  @typep session_row :: %{
           question_id: String.t(),
           option_ids: [String.t()],
           source: wrapped_source()
         }

  # GH #2762: only DRAWN questions (`order`; pins are always in it) can refuse the start, with the
  # first refusal in `order`; an undrawn broken pool question does not block. Unwraps the drawn
  # sources to plain `question_source` maps for `Snapshot.build_from_resolved/4`.
  @spec refuse_drawn(%{optional(String.t()) => wrapped_source()}, [String.t()]) ::
          {:ok, %{optional(String.t()) => Snapshot.question_source()}}
          | {:error, {:grading_error, {:key_missing, String.t()}}}
  defp refuse_drawn(sources, order) do
    drawn = Map.take(sources, order)

    refusal =
      Enum.find_value(order, fn question_id ->
        case Map.get(drawn, question_id) do
          {:error, _reason} = error -> error
          _usable_or_absent -> nil
        end
      end)

    refusal || {:ok, Map.new(drawn, fn {id, {:usable, source}} -> {id, source} end)}
  end

  defp fetch_question_pools(exam_id, prefix) do
    # GH #2779: a soft-deleted rule is never read; an exam left with no live rule is refused
    # (an empty session is never valid).
    with {:ok, rule_records} <-
           query_all(
             "exam_question_rule",
             [eq("exam_id", exam_id), eq("deleted", false)],
             prefix
           ),
         :ok <- require_live_rules(rule_records) do
      random_rules =
        rule_records
        |> Enum.filter(&(fv(&1, "mode") == "random"))
        |> Enum.sort_by(&fv(&1, "sort_order"))

      manual_rules =
        rule_records
        |> Enum.filter(&(fv(&1, "mode") == "manual"))
        |> Enum.sort_by(&fv(&1, "sort_order"))

      rules =
        Enum.map(random_rules, fn r -> %{pool_id: fv(r, "category_id"), count: fv(r, "count")} end)

      pool_ids = rules |> Enum.map(& &1.pool_id) |> Enum.uniq()

      with {:ok, pool} <- fetch_pools(pool_ids, prefix),
           {:ok, manual_questions} <- fetch_manual_rules(manual_rules, prefix) do
        {:ok, rules, pool, manual_questions}
      end
    end
  end

  defp require_live_rules([]), do: {:error, :no_question_rules}
  defp require_live_rules(_rule_records), do: :ok

  defp fetch_pools(pool_ids, prefix) do
    pool_ids
    |> Enum.reduce_while({:ok, %{}}, fn pool_id, {:ok, acc} ->
      case fetch_pool_questions(pool_id, prefix) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, pool_id, rows)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_manual_rules(manual_rules, prefix) do
    manual_rules
    |> Enum.reduce_while({:ok, []}, fn rule, {:ok, acc} ->
      case fetch_manual_questions(rule.record_id, prefix) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_pool_questions(category_id, prefix) do
    with {:ok, questions} <-
           query_all(
             "question",
             # GH #2759: a soft-deleted active question is never drawn from the pool.
             [eq("category_id", category_id), eq("status", "active"), eq("deleted", false)],
             prefix
           ) do
      questions
      |> Enum.reduce_while({:ok, []}, fn question, {:ok, acc} ->
        case fetch_question_row(normalize_record_id(question.record_id), question, prefix) do
          {:ok, row} -> {:cont, {:ok, [row | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        {:error, _reason} = error -> error
      end
    end
  end

  # One resolver row (`question_id`, `option_ids`) plus the `:source` the snapshot needs (design
  # 4.3 step 2): the question's stored type and its option rows' key fields. The option rows are
  # the ones this function always loaded to get the ids; nothing extra is queried for a pool.
  # `source` is `{:usable, source}` or the `{:error, ...}` key_missing refusal (see `wrapped_source`).
  @spec fetch_question_row(String.t(), map(), String.t()) ::
          {:ok, session_row()} | {:error, term()}
  defp fetch_question_row(question_id, question, prefix) do
    with {:ok, options} <- query_all("answer_option", [eq("question_id", question_id)], prefix) do
      type = fv(question, "type")
      sorted = Enum.sort_by(options, &fv(&1, "sort_order"))

      # GH #2762: soft-deleted options are excluded (all rows are read so the shared rule sees
      # them). A question left with no live key is NOT failed here: it is carried as a refusal
      # and refused only if the draw picks it (`refuse_drawn/2`), so the pool is not shrunk.
      case Snapshot.live_options(sorted, %{type: type, question_id: question_id}, :start) do
        {:ok, live} ->
          source = %{
            type: type,
            options:
              Enum.map(live, fn option ->
                %{
                  id: normalize_record_id(option.record_id),
                  is_correct: fv(option, "is_correct"),
                  likert_weight: fv(option, "likert_weight"),
                  likert_polarity: fv(option, "likert_polarity")
                }
              end)
          }

          {:ok,
           %{
             question_id: question_id,
             option_ids: Enum.map(live, &normalize_record_id(&1.record_id)),
             source: {:usable, source}
           }}

        {:error, _reason} = refusal ->
          {:ok, %{question_id: question_id, option_ids: [], source: refusal}}
      end
    end
  end

  # ISS-0722 -- manual-mode question pinning: reads exam_manual_question rows
  # for a single mode: "manual" exam_question_rule, ordered by the pin's own
  # sort_order, and mirrors fetch_pool_questions/2's fetch_option_ids/2 reuse
  # verbatim. A rule with zero pinned rows errors rather than silently
  # contributing zero questions (design doc §3/§6) -- this is the fix's own
  # answer to the class of bug ISS-0722 reports, applied to the new path too.
  @spec fetch_manual_questions(rule_id :: String.t(), prefix :: String.t()) ::
          {:ok, [session_row()]} | {:error, :manual_rule_empty | term()}
  defp fetch_manual_questions(rule_id, prefix) do
    # GH #2779: a soft-deleted pick is never read.
    with {:ok, pins} <-
           query_all(
             "exam_manual_question",
             [eq("rule_id", rule_id), eq("deleted", false)],
             prefix
           ) do
      if pins == [] do
        {:error, :manual_rule_empty}
      else
        pins
        |> Enum.sort_by(&fv(&1, "sort_order"))
        |> Enum.reduce_while({:ok, []}, fn pin, {:ok, acc} ->
          case fetch_pinned_question_row(fv(pin, "question_id"), prefix) do
            {:ok, row} -> {:cont, {:ok, [row | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, rows} -> {:ok, Enum.reverse(rows)}
          {:error, _reason} = error -> error
        end
      end
    end
  end

  # Design 4.3 step 2: a pin used to be read without ever loading its question. The snapshot needs
  # the question's type, so one `Latest.get_live` is added, and a pin whose question is missing,
  # soft-deleted or not `active` is a start failure instead of a silent skip.
  defp fetch_pinned_question_row(question_id, prefix) do
    # `Latest.get_live/3` raises Ecto.Query.CastError on a non-UUID id, so a malformed pin is a typed
    # start failure here instead. GH #2759: get_live/3 reports a soft-deleted question as
    # `:not_found`, so it is indistinguishable from a missing one.
    with {:ok, _uuid} <- Ecto.UUID.cast(question_id) do
      case Latest.get_live(question_id, "question", prefix) do
        {:ok, question} ->
          if fv(question, "status") == "active",
            do: fetch_question_row(question_id, question, prefix),
            else: {:error, {:question_not_found, question_id}}

        {:error, :not_found} ->
          {:error, {:question_not_found, question_id}}

        {:error, :invalid_schema_name} = error ->
          error
      end
    else
      :error -> {:error, {:question_not_found, question_id}}
    end
  end

  @spec persist_session_questions(
          session_id :: String.t(),
          resolved_random :: [QuestionSetResolver.resolved_question()],
          resolved_manual :: [QuestionSetResolver.resolved_question()],
          actor_id :: String.t(),
          prefix :: String.t()
        ) :: :ok | {:error, term()}
  defp persist_session_questions(session_id, resolved_random, resolved_manual, actor_id, prefix) do
    with :ok <- write_question_rows(session_id, resolved_random, actor_id, prefix),
         :ok <- write_question_rows(session_id, resolved_manual, actor_id, prefix) do
      :ok
    end
  end

  @spec write_question_rows(
          session_id :: String.t(),
          rows :: [QuestionSetResolver.resolved_question()],
          actor_id :: String.t(),
          prefix :: String.t()
        ) :: :ok | {:error, term()}
  defp write_question_rows(session_id, rows, actor_id, prefix) do
    Enum.reduce_while(rows, :ok, fn resolved_question, :ok ->
      attrs = %{
        "session_id" => session_id,
        "question_id" => resolved_question.question_id,
        "sort_order" => resolved_question.sort_order,
        "options_order" => resolved_question.options_order
      }

      case write_record("session_question", attrs, actor_id, prefix) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # =======================================================================
  # Autosave helpers
  # =======================================================================

  defp check_non_negative(time_spent_seconds) do
    if is_integer(time_spent_seconds) and time_spent_seconds >= 0 do
      :ok
    else
      {:error, :answer_shape_invalid}
    end
  end

  defp fetch_session(session_id, prefix) do
    case Latest.get(session_id, "session", prefix) do
      {:ok, session} -> {:ok, session}
      {:error, :not_found} -> {:error, :session_not_found}
      {:error, :invalid_schema_name} = error -> error
    end
  end

  defp check_owner(session, user_id) do
    if fv(session, "user_id") == user_id, do: :ok, else: {:error, :not_owner}
  end

  defp check_in_progress(session) do
    if fv(session, "status") == "in_progress", do: :ok, else: {:error, :session_not_in_progress}
  end

  # Server-side deadline enforcement (roadmap 3.7/3.9) -- compares
  # `DateTime.utc_now()` against the session's OWN STORED `expires_at`.
  # There is no client-supplied timestamp anywhere in this function's
  # parameter list for a caller to substitute.
  defp check_deadline(session) do
    if DateTime.compare(utc_now(), parse_dt!(fv(session, "expires_at"))) == :gt do
      {:error, :deadline_passed}
    else
      :ok
    end
  end

  defp fetch_session_question(session_id, question_id, prefix) do
    case query_all(
           "session_question",
           [eq("session_id", session_id), eq("question_id", question_id)],
           prefix
         ) do
      {:ok, [session_question | _rest]} -> {:ok, session_question}
      {:ok, []} -> {:error, :question_not_in_session}
      {:error, reason} -> {:error, reason}
    end
  end

  # GH #2682 / REQ-511, design 5.2: the type used for the shape check comes from the session's
  # own snapshot, never from the live question row (an edit mid-session must not make the shape
  # check, the display and the scoring disagree). Ownership and `in_progress` were checked by the
  # caller before this runs.
  #
  # PR b: a snapshotless session (started before the cutover) gets its late snapshot here, AFTER
  # the ownership / in-progress / deadline checks (a non-owner can never trigger a write).
  defp snapshot_question_type(session, question_id, user_id, prefix) do
    snapshot_result =
      case Snapshot.fetch_structural(session.field_values) do
        {:error, {:grading_error, :snapshot_missing}} ->
          Snapshot.ensure(session.record_id, user_id, prefix)

        other ->
          other
      end

    with {:ok, snapshot} <- snapshot_result do
      # The caller already found this question's `session_question` row, so a snapshot without
      # its item is a typed grading error (`{:question_item_missing, id}`), never "not in session".
      Snapshot.question_type(snapshot, question_id)
    end
  end

  # ISS-0650: `:short_text` now validates `text_answer` instead of (in
  # addition to) the pre-existing "selected_option_ids must be empty" rule
  # -- a short-text question never carries selected options, so that check
  # stays. Every OTHER type rejects a non-nil `text_answer` outright: a
  # client sending free text for a single/multiple/true_false/likert
  # question is a shape error, not something to silently drop, matching
  # this function's existing strict-shape-per-type intent.
  defp check_answer_shape(type, selected_option_ids, text_answer) do
    count = length(selected_option_ids || [])

    cond do
      type == :short_text and count > 0 ->
        {:error, :answer_shape_invalid}

      type == :short_text and not is_nil(text_answer) and not is_binary(text_answer) ->
        {:error, :answer_shape_invalid}

      type != :short_text and not is_nil(text_answer) ->
        {:error, :answer_shape_invalid}

      type in [:single, :true_false] and count > 1 ->
        {:error, :answer_shape_invalid}

      true ->
        :ok
    end
  end

  defp check_options_belong(session_question, selected_option_ids) do
    allowed = MapSet.new(fv(session_question, "options_order") || [])

    if Enum.all?(selected_option_ids || [], &MapSet.member?(allowed, &1)) do
      :ok
    else
      {:error, :option_not_in_question}
    end
  end

  defp upsert_answer(
         session_id,
         question_id,
         selected_option_ids,
         text_answer,
         time_spent_seconds,
         started_at,
         user_id,
         prefix
       ) do
    # ISS-0650: `text_answer` (:string, required: false in the entity
    # definition -- session_answer.json) is a JSON-SCHEMA-optional field,
    # not a nullable one: the generated schema has no `null` in its `type`,
    # so a present-but-`nil` value fails `Letflow.Entities.Validator`'s
    # `/text_answer` type check even though an ABSENT key passes (that is
    # exactly what `required: false` means). The key is therefore only
    # added when there is a real value -- this is also correct for
    # `Records.update_record/2`'s full-replacement write (moduledoc "Updates
    # ... with a full replacement field_values"): omitting the key on a
    # later save genuinely clears a prior text answer, it does not leave a
    # stale one behind.
    now = utc_now()

    base_attrs = %{
      "session_id" => session_id,
      "question_id" => question_id,
      "selected_option_ids" => selected_option_ids || [],
      "saved_at" => iso8601(now)
    }

    attrs =
      if is_nil(text_answer),
        do: base_attrs,
        else: Map.put(base_attrs, "text_answer", text_answer)

    case query_all(
           "session_answer",
           [eq("session_id", session_id), eq("question_id", question_id)],
           prefix
         ) do
      {:ok, [existing | _rest]} ->
        # Q-1075 / GH #2432: the stored time is the max of what is stored and what the
        # client reports, bounded by the session's own elapsed time (see bounded_time_spent/4).
        time_value =
          bounded_time_spent(time_spent_seconds, stored_time_spent(existing), started_at, now)

        # scope-all: SEC-518-R1 (exam module, own-record system path)
        write_result =
          Records.update_record(
            %{
              entity_type: "session_answer",
              record_id: normalize_record_id(existing.record_id),
              field_values: Map.put(attrs, "time_spent_seconds", time_value),
              actor_id: user_id,
              idempotency_key: Ecto.UUID.generate()
            },
            prefix,
            exam_owner()
          )

        ok_or_error(write_result)

      {:ok, []} ->
        time_value = bounded_time_spent(time_spent_seconds, 0, started_at, now)

        ok_or_error(
          write_record(
            "session_answer",
            Map.put(attrs, "time_spent_seconds", time_value),
            user_id,
            prefix
          )
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Q-1075 / GH #2432: the client reports the running total of time spent on a question
  # (client-reported, not server-measured: a per-question "shown" event is out of scope).
  # Each save takes max(stored, received), so within one save the value is monotonic. Then the
  # value is CLAMPED to the session's own elapsed wall-clock time, so it cannot exceed the time
  # the session has existed. Known limits: concurrent saves on the same question have no row
  # lock, so one can overwrite a higher value; and legacy values above the bound can be lowered by
  # the clamp on the next save. The bound is per question, so the sum across questions is not
  # bounded (a client-reported value; no reader sums it). A clamp, not a rejection: an over-large
  # value must not lose the candidate's answer save mid-exam; the save still succeeds.
  defp bounded_time_spent(received, stored, started_at, now) do
    elapsed = max(DateTime.diff(now, started_at, :second), 0)
    min(max(stored, received), elapsed)
  end

  defp stored_time_spent(answer) do
    case fv(answer, "time_spent_seconds") do
      seconds when is_integer(seconds) -> seconds
      _ -> 0
    end
  end

  defp remaining_seconds(session) do
    expires_at = parse_dt!(fv(session, "expires_at"))
    DateTime.diff(expires_at, utc_now(), :second) |> max(0)
  end

  # =======================================================================
  # Submit / scoring
  # =======================================================================

  defp lock_session_row(session_id, prefix) do
    query = from(r in Latest, where: r.entity_type == "session" and r.record_id == ^session_id)

    case query |> Ecto.Query.lock("FOR UPDATE") |> Repo.one(prefix: prefix) do
      nil -> {:error, :session_not_found}
      row -> {:ok, row}
    end
  end

  # GH #2682 / REQ-511, design 5.1: scoring reads ONLY the session's own snapshot (digest
  # verified) plus the candidate's answers. No `exam`, `question` or `answer_option` row is read,
  # and there is no default threshold: a missing or invalid key is a typed grading error and the
  # caller's transaction rolls back, leaving the session `in_progress`.
  #
  # PR b (design 9, 17.2): a session with no snapshot that started before the cutover gets a late
  # one here (`Snapshot.ensure_locked/2`, reads only). The late snapshot is persisted by the ONE
  # `session` update below (`session_after` carries it), and its audit entry is the last
  # statement, so the lock order matches a plain submit (session row, score sequence, session
  # sequence, audit chain). `audit_actor_id` is the submitting candidate; the system sweep passes
  # none (audit actor `nil`).
  defp score_and_persist(session, prefix, opts) do
    submitted_at = Keyword.get(opts, :submitted_at, utc_now())
    status_override = Keyword.get(opts, :status_override)
    audit_actor_id = Keyword.get(opts, :audit_actor_id)

    with {:ok, snapshot, session_after, provenance} <- Snapshot.ensure_locked(session, prefix),
         {:ok, questions} <- Snapshot.to_scoring_questions(snapshot),
         {:ok, threshold} <- Snapshot.threshold(snapshot),
         {:ok, answers} <- load_answers(session.record_id, prefix),
         {:ok, %{per_question: scores, outcome: outcome0}} <-
           score_questions(questions, answers, threshold) do
      outcome = maybe_override_status(outcome0, status_override)

      with :ok <-
             persist_scores(
               session.record_id,
               fv(session, "exam_id"),
               scores,
               fv(session, "user_id"),
               prefix
             ),
           :ok <-
             Snapshot.record_late_after_persist(
               provenance,
               session,
               snapshot,
               audit_actor_id,
               prefix,
               fn ->
                 update_session_after_submit(session_after, outcome, submitted_at, prefix)
               end
             ) do
        {:ok, outcome}
      end
    end
  end

  # `Scoring` returns only the atom for a keyless question; the id comes from the validated
  # snapshot rows (defence in depth: `Snapshot.to_scoring_questions/1` already rejects these).
  defp score_questions(questions, answers, threshold) do
    case Scoring.score_session(questions, answers, threshold) do
      {:ok, _scored} = ok ->
        ok

      {:error, :question_without_correct_option} ->
        keyless =
          Enum.find(
            questions,
            &(&1.type in [:single, :true_false, :multiple] and &1.correct_option_ids == [])
          )

        case keyless do
          nil -> {:error, {:grading_error, :snapshot_corrupt}}
          %{question_id: question_id} -> {:error, {:grading_error, {:key_missing, question_id}}}
        end
    end
  end

  defp maybe_override_status(outcome, nil), do: outcome

  defp maybe_override_status(%{status: :submitted} = outcome, override),
    do: %{outcome | status: override}

  defp maybe_override_status(outcome, _override), do: outcome

  defp load_answers(session_id, prefix) do
    with {:ok, session_answers} <-
           query_all("session_answer", [eq("session_id", session_id)], prefix) do
      {:ok,
       Map.new(session_answers, fn answer ->
         {fv(answer, "question_id"),
          %{
            selected_option_ids: fv(answer, "selected_option_ids") || [],
            text_answer: fv(answer, "text_answer")
          }}
       end)}
    end
  end

  defp persist_scores(session_id, exam_id, scores, actor_id, prefix) do
    declared = declared_score_fields(prefix)

    Enum.reduce_while(scores, :ok, fn score, :ok ->
      attrs =
        %{
          "session_id" => session_id,
          "question_id" => score.question_id,
          "score" => to_float(score.score),
          "max_score" => to_float(score.max_score),
          "grading_status" => Atom.to_string(score.grading_status)
        }
        |> put_declared("exam_id", exam_id, declared)
        |> put_correct(score, declared)

      case write_record("session_question_score", attrs, actor_id, prefix) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # REQ-594: `exam_id` and `correct` are written only when the tenant's ACTIVE
  # `session_question_score` definition declares them (record writes are validated against it with
  # additionalProperties: false). A tenant still on the previous definition, before
  # `ensure_exam_analytics_definitions/1` ran, keeps today's row shape so submit keeps working.
  # Read once per scoring call, not per row; any lookup error means "nothing declared" and
  # `Records` reports its own error if the type is really missing.
  defp declared_score_fields(prefix) do
    case Definitions.get_active_definition_by_name("session_question_score", prefix) do
      {:ok, %{definition_json: %{"fields" => fields}}} when is_list(fields) ->
        MapSet.new(fields, &Map.get(&1, "name"))

      _ ->
        MapSet.new()
    end
  end

  defp put_declared(attrs, key, value, declared) do
    if MapSet.member?(declared, key), do: Map.put(attrs, key, value), else: attrs
  end

  # `correct` compares the unrounded floats that are also written to `score` / `max_score` (the
  # column rounds to 4 decimals; scoring caps at 1.0, so a rounding collision is not reachable).
  # A pending_manual row gets no `correct` key at all (never nil).
  defp put_correct(attrs, %{grading_status: :graded} = score, declared) do
    put_declared(attrs, "correct", to_float(score.score) == to_float(score.max_score), declared)
  end

  defp put_correct(attrs, _score, _declared), do: attrs

  defp update_session_after_submit(session, outcome, submitted_at, prefix) do
    # Record updates are a FULL replacement of `field_values`, so the new map starts from the
    # locked row's own values: `exam_snapshot` (and any other field) is carried forward unchanged
    # (design 5.4, invariant I-1). Only the four outcome fields are overwritten.
    attrs =
      Map.merge(session.field_values, %{
        "status" => Atom.to_string(outcome.status),
        "submitted_at" => iso8601(submitted_at),
        "score_pct" => to_float(outcome.percentage),
        "passed" => outcome.passed || false
      })

    ok_or_error(
      # scope-all: SEC-518-R1 (exam module, own-record system path)
      Records.update_record(
        %{
          entity_type: "session",
          record_id: session.record_id,
          field_values: attrs,
          actor_id: fv(session, "user_id"),
          idempotency_key: Ecto.UUID.generate()
        },
        prefix,
        exam_owner()
      )
    )
  end

  # See this module's moduledoc's second flagged gap: the raw sums are
  # reconstructed, not replayed, on the idempotent path.
  defp outcome_from_session(session) do
    status = session_status_atom(fv(session, "status"))
    percentage = to_float(fv(session, "score_pct") || 0)

    %{
      status: status,
      total_score: percentage,
      total_max_score: 100.0,
      percentage: percentage,
      passed: passed_for_status(status, session)
    }
  end

  # =======================================================================
  # Shared plumbing
  # =======================================================================

  defp fv(%{field_values: field_values}, key), do: Map.get(field_values, key)

  # ISS-0648 companion finding (beyond the design doc's own §2.2.1 scope,
  # empirically discovered while proving acceptance criterion 12): once an
  # entity type is promoted to a real per-entity-type table,
  # `Letflow.Entities.Query.Compiler`'s `select_entity_row/1` returns
  # `record_id` as the RAW 16-byte UUID binary Postgrex hands back for an
  # untyped schemaless `select` -- never cast to the hyphenated string form
  # `Compiler.entity_row()`'s own `@type` already promises
  # (`record_id: String.t()`). `upsert_answer/5` below passes an existing
  # `session_answer` row's `record_id` (session_answer is one of this fix's
  # own §4 blast-radius entity types) straight into
  # `Records.update_record/2`, which later fails encoding it as JSON for the
  # event payload -- confirmed empirically:
  # `test/letflow/exam/session_test.exs`'s "a second save on the same
  # question upserts, not duplicates" test raised `Jason.EncodeError`
  # against exactly this raw binary once session_answer started being
  # promoted (this fix's own trigger). This is NOT a new mechanism: it is
  # the identical normalization `lib/letflow/routers/entities.ex`'s own
  # `normalise_record_id/1` already applies for exactly this reason
  # (REQ-300/ISS-0600) -- reused here rather than re-invented.
  defp normalize_record_id(<<_::binary-size(16)>> = raw), do: Ecto.UUID.load!(raw)
  defp normalize_record_id(record_id) when is_binary(record_id), do: record_id

  defp eq(field, value), do: %{field: field, op: :eq, value: value}

  defp query_all(entity_type, filters, prefix) do
    # scope-all: SEC-518-R1
    with {:ok, query} <-
           Compiler.compile(%{entity_type: entity_type, filters: filters}, prefix, :all) do
      {:ok, Repo.all(query, prefix: prefix)}
    end
  end

  defp write_record(entity_type, field_values, actor_id, prefix) do
    # scope-all: SEC-518-R1 (exam module, own-record system path)
    Records.create_record(
      %{
        entity_type: entity_type,
        field_values: field_values,
        actor_id: actor_id,
        idempotency_key: Ecto.UUID.generate()
      },
      prefix,
      exam_owner()
    )
  end

  # GH #2596: the exam module's own Owner, passed to every `Records` write so the six runtime
  # types can be managed (`Exam.manifest().manages_entity_types`). Built per call, never stored.
  @spec exam_owner() :: ManagedTypes.Owner.t()
  defp exam_owner, do: ManagedTypes.owner_for!(Exam)

  defp ok_or_error({:ok, _result}), do: :ok
  defp ok_or_error({:error, _reason} = error), do: error

  defp session_view(session) do
    status = session_status_atom(fv(session, "status"))
    raw_score_pct = fv(session, "score_pct")

    %{
      id: session.record_id,
      exam_id: fv(session, "exam_id"),
      candidate_id: fv(session, "user_id"),
      status: status,
      seed: fv(session, "seed"),
      started_at: parse_dt!(fv(session, "started_at")),
      expires_at: parse_dt!(fv(session, "expires_at")),
      score_pct: if(is_nil(raw_score_pct), do: nil, else: to_float(raw_score_pct)),
      passed: passed_for_status(status, session)
    }
  end

  @spec session_status_atom(String.t()) ::
          :in_progress | :submitted | :auto_submitted | :grading_pending
  defp session_status_atom("in_progress"), do: :in_progress
  defp session_status_atom("submitted"), do: :submitted
  defp session_status_atom("auto_submitted"), do: :auto_submitted
  defp session_status_atom("grading_pending"), do: :grading_pending

  # Shared by `outcome_from_session/1` and `session_view/1`: a `passed` fact
  # is only a decided fact once a session lands in :submitted/:auto_submitted.
  # `:grading_pending` is not decided (short-text answers await manual
  # grading). `:in_progress` empirically is not either -- unlike `score_pct`
  # (`required: false` in the entity definition, genuinely absent until
  # `update_session_after_submit/4` first writes it), `passed` is
  # `required: true` (source column `NOT NULL DEFAULT FALSE`), so
  # `create/3` persists the same `false` placeholder at session creation
  # that `update_session_after_submit/4` later writes for a pending outcome
  # (`outcome.passed || false`) -- there is no "absent" state for this field
  # to fall back on, only "decided" vs. "placeholder." Both non-decided
  # statuses must therefore be handled explicitly here, not just
  # `:grading_pending`, or `:in_progress` would leak the DB's placeholder
  # `false` as if it were a real value (this file's own design doc
  # under-specified this -- confirmed empirically via
  # `test/letflow/exam/session_test.exs`'s ISS-0674 `:in_progress` case).
  @spec passed_for_status(:in_progress | :submitted | :auto_submitted | :grading_pending, map()) ::
          boolean() | nil
  defp passed_for_status(status, _session) when status in [:in_progress, :grading_pending],
    do: nil

  defp passed_for_status(_status, session), do: fv(session, "passed")

  defp question_type_atom("single"), do: :single
  defp question_type_atom("multiple"), do: :multiple
  defp question_type_atom("truefalse"), do: :true_false
  defp question_type_atom("likert"), do: :likert
  defp question_type_atom("shorttext"), do: :short_text

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_dt!(value) when is_binary(value) do
    {:ok, dt, _offset} = DateTime.from_iso8601(value)
    dt
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp draw_seed, do: :rand.uniform(1_000_000_000_000)
end
