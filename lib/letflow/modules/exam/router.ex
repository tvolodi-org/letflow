defmodule Letflow.Modules.Exam.Router do
  @moduledoc """
  REQ-335 -- the candidate-facing exam-session HTTP surface REQ-332
  (`Letflow.Modules.Exam.Session`) and REQ-333 (`Letflow.Modules.Exam.AntiCheat`) explicitly
  left unbuilt. A thin composition layer, no execution semantics of its
  own: every route below delegates its actual eligibility/ownership/
  deadline/debounce logic to those two already-authorized runtime modules
  (REQ-330's rule-2 bucket-C justifications for both are unchanged by this
  requirement -- see each module's own moduledoc). Moved to
  `lib/letflow/modules/exam/router.ex` by REQ-410 and mounted at
  `/api/v1/modules/exam/exam-sessions` via `Letflow.Routers.Modules`'s D4/D5
  gate (REQ-404), replacing the previous direct core-mount at `/exam-sessions`
  in `Letflow.Plugs.ApiPipeline`. A candidate sitting an exam is an
  authenticated tenant user -- NOT decision `0028`'s unauthenticated
  capability-handle pattern.

  Reference source: `backend/internal/sessions/handler.go`
  (`CreateSession`/`SaveAnswer`/`ReportEvent`/`SubmitSession`/
  `GetSessionState`). `SaveAnswer`'s real registration is
  `PUT .../sessions/:id/answers/:questionId` (the R-Co portal path; a
  reference only, NOT mounted in Letflow) -- re-verified against that
  reference's own handler comment and `SessionOptionResponse`'s shape
  (`ID`/`Text` only, confirming the redaction decision below), not assumed
  from the POST this requirement's own description inferred. The live
  Letflow route is
  `PUT /api/v1/modules/exam/exam-sessions/:id/answers/:question_id`.

  ## Route table

  | Handler | Method/path | Delegate | Permission | Response |
  |---|---|---|---|---|
  | start_session | `POST /exam-sessions` | `Letflow.Modules.Exam.Session.create/3`, then `Letflow.Modules.Exam.Session.get_session_state_for_user/3` for the 201 body | `ExamSessionStart` | 201 / 400 / 403 / 409 / 422 |
  | list_available_exams | `GET /exam-sessions/available` (ISS-0718) | `Letflow.Modules.Exam.Session.list_available_exams/2` | `ExamSessionStart` | 200 / 400 / 403 |
  | get_session_state | `GET /exam-sessions/:id` | `Letflow.Modules.Exam.Session.get_session_state_for_user/3` | `ExamSessionRead` | 200 / 404 |
  | autosave_answer | `PUT /exam-sessions/:id/answers/:question_id` | `Letflow.Modules.Exam.Session.autosave_answer/4` | `ExamSessionSave` | 200 / 400 / 404 / 422 |
  | submit_session | `POST /exam-sessions/:id/submit` | `Letflow.Modules.Exam.Session.submit/3` | `ExamSessionSubmit` | 200 / 404 |
  | report_event | `POST /exam-sessions/:id/events` | `Letflow.Modules.Exam.AntiCheat.record_signal/4` | `ExamSessionReportEvent` | 200 / 400 / 404 / 422 |
  | authoring_create | `POST /authoring/:entity_type` (GH #2680) | `Letflow.Modules.Exam.Authoring.create/2` | `ExamAuthoringWrite` | 201 / 400 / 403 / 404 / 422 |
  | authoring_update | `PUT /authoring/:entity_type/:record_id` (GH #2680) | `Letflow.Modules.Exam.Authoring.update/2` | `ExamAuthoringWrite` | 200 / 400 / 403 / 404 / 409 / 422 |
  | authoring_delete | `DELETE /authoring/:entity_type/:record_id` (GH #2680) | `Letflow.Modules.Exam.Authoring.delete/2` | `ExamAuthoringWrite` | 200 / 400 / 403 / 404 / 409 |
  | issue_certificate | `POST /exam-sessions/:id/certificate` | `Letflow.Modules.Exam.Certificate.issue_or_get_for_user/3` (REQ-355) | `ExamCertificateIssue` | 200 / 404 / 409 |
  | download_certificate | `GET /exam-sessions/:id/certificate/download` | `Letflow.Modules.Exam.Certificate.issue_or_get_for_user/3` + `Letflow.Modules.Exam.CertificateDocument.render/2` (REQ-356) | `ExamCertificateIssue` | 200 (`application/pdf`) / 404 / 409 |
  | list_grading_queue | `GET /grading-queue` (GH #3324) | `Letflow.Modules.Exam.Grading.list_queue/2` | `ExamGradingRead` | 200 / 400 / 403 |
  | get_grading_answer | `GET /grading-queue/:session_id/:question_id` (GH #3324) | `Letflow.Modules.Exam.Grading.get_answer/4` | `ExamGradingRead` | 200 / 403 / 404 |

  ## Deliberately NOT routed here, and why (REQ-335's own scope fence)

    * **Manual short-text grading, mark half** (`HandleGradeAnswer`, FR-BB42) -- the queue and
      detail reads are routed (GH #3324, REQ-588 part A); marking an answer and finalising the
      session are part B and not routed yet.
    * **Adaptive next-question selection** (`GetNextQuestion`, FR-BB72) --
      the stage file names adaptive selection as an unimplemented bucket-C
      behaviour with its own future requirement; no runtime exists to route
      to.
    * **Cross-session history / results-list views**
      (`GetExamHistory`/`HandleGetMyResults`, FR-BB41/FR-BB46) -- outside
      REQ-330's five analysed behaviours (start, autosave, submit,
      anti-cheat signal, and this route's own state read); `GetSessionResult`
      is also not routed here for the same reason -- a *result* view is a
      sixth behaviour this requirement's own dependency chain (REQ-330's
      five) never authorized, not a subset of the *state* read this module
      does implement.

  ## Permission vocabulary -- candidate-reachable, not `PLATFORM_ADMIN`-only

  `ExamSessionStart`/`ExamSessionRead`/`ExamSessionSave`/`ExamSessionSubmit`/
  `ExamSessionReportEvent`/`ExamCertificateIssue` (the first five minted in `Letflow.Api.Authorization`, the sixth, `ExamCertificateIssue`, declared by this module's manifest, following
  the `Entities*` naming precedent) are granted to `:CANDIDATE` -- a
  dedicated role added by ISS-0646 (see decision 0013's addendum) holding
  exactly these six permissions and nothing else, via
  `Letflow.Api.Authorization`'s `role_allows?(:CANDIDATE, ...)` clause. A
  candidate sitting an exam is exactly that: an ordinary authenticated
  tenant user reaching their OWN session. `TASK_WORKER` no longer holds
  these permissions. See `Letflow.Api.Authorization`'s own moduledoc
  "ExamSession*" section for the full reasoning, and its
  `endpoint_policy_key/2` clauses for the five real matrix entries backing
  these atoms (proven by `test/letflow/api/authorization_enforcement_test.exs`
  -- none is on that test's allowlist, none evaluates `:Unknown`).

  `ExamAuthoringWrite` (GH #2680) is the exception: it gates the authoring write routes, is declared
  by the exam manifest only and has NO `role_grants`, so it is held through the core rules alone
  (PLATFORM_ADMIN and TENANT_ADMIN). CANDIDATE and PROCESS_OPERATOR do not hold it.

  `ExamGradingRead` (GH #3324) is the same kind: manifest-only, no `role_grants`, PLATFORM_ADMIN and
  TENANT_ADMIN only; it gates the two grading-queue reads.

  ## Ownership and tenant isolation (INV-1, INV-5, INV-8)

  No route below accepts a caller-supplied candidate identity. The
  candidate is always `conn.assigns.auth_context.user_id` (the authenticated
  caller's own id, resolved by `Letflow.Plugs.AuthPipeline` from their
  token) -- a path `:id` is a SESSION id, never a candidate id, and is never
  trusted as one. `prefix` always comes from `conn.assigns.scoped_opts`
  (`Letflow.Plugs.Authorize`'s own resolution), exactly as
  `Letflow.Routers.Entities` does; this router performs no `Repo` call of
  any kind. Every session-scoped delegate call passes straight through to
  `Letflow.Modules.Exam.Session`'s/`Letflow.Modules.Exam.AntiCheat`'s own
  `(:session_not_found | :not_owner)` ownership guard, and BOTH outcomes
  render through the exact same `Letflow.Api.Response.not_found/1` call --
  no detail, no distinguishing body -- so a candidate probing another
  candidate's `session_id` (same tenant or a different one; a session
  outside the caller's tenant is already invisible to the prefix-scoped
  `Letflow.Entities.Record.Latest.get/3` lookup those modules use) gets
  byte-identical 404s to a genuinely nonexistent id. A malformed
  (non-UUID) `:id`/`exam_id` is cast at the router boundary
  (`cast_uuid/1` below) and folded into that SAME path BEFORE any delegate
  call, for the same reason `Letflow.Routers.Entities`' own
  `cast_record_id/1` exists: `Letflow.Entities.Record.Latest`'s
  `record_id` column is `Ecto.UUID`-typed, and an uncast malformed string
  reaching a `Repo` query built against it raises `Ecto.Query.CastError`
  rather than returning a graceful not-found.

  ## The `is_correct`/answer-key redaction decision (REQ-335's own open question)

  `get_session_state`'s response NEVER carries `is_correct`,
  `likert_weight`, `likert_polarity` (from `answer_option`) or `explanation`
  (from `question`, which narrates the correct answer). The mitigation
  chosen is **hand-assembly, not a `Letflow.Entities.Query`-module
  field-redaction restriction** -- implemented one layer down, in
  `Letflow.Modules.Exam.Session.get_session_state_for_user/3` (that function's own
  `@doc` states the full reasoning: this response joins four entity types
  with no single `Letflow.Entities.Query.Compiler` result page for
  `FieldGrants` to redact, and this pack's `answer_option.json` itself
  records that no `entity_field_restrictions` row is configured for
  `is_correct` today, so a `FieldGrants`-based route would currently leak it
  outright). This router never touches `question`/`answer_option`
  `field_values` directly and never delegates to a generic entity-record
  serializer -- it only ever renders the already-redacted map
  `get_session_state_for_user/3` returns.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.RecordAccess
  alias Letflow.Entities.Record.Decimals
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Exam.AntiCheat
  alias Letflow.Modules.Exam.Authoring
  alias Letflow.Modules.Exam.Certificate
  alias Letflow.Modules.Exam.CertificateDocument
  alias Letflow.Modules.Exam.Grading
  alias Letflow.Modules.Exam.Session
  alias Letflow.Idempotency
  alias Letflow.PublicRead
  alias Letflow.Routers.Entities.RecordWrites

  import Letflow.Routers.Entities.Support, only: [restricted_fields_refusal: 1]

  # GH #2682 / REQ-511, design 7.4: constant response bodies for the two snapshot failure classes.
  # The body never carries the reason, ids or values (INV-4/INV-5); the reason is logged.
  @grading_failed_detail "exam grading failed; the session was not scored"
  @content_invalid_detail "exam content is invalid; the session was not started"
  @pinned_question_detail "exam pins an unavailable question"
  @upgrading_detail "exam service is being upgraded; retry shortly"

  # ── Start session ───────────────────────────────────────────────────────

  authz_post "/exam-sessions", :ExamSessionStart do
    handle_start_session(conn)
  end

  # ── Available-exams list (ISS-0718) ─────────────────────────────────────
  #
  # Reuses the EXISTING `:ExamSessionStart` permission -- no new atom minted,
  # CANDIDATE's role_allows?/2 six-member list is unchanged (see
  # lib/letflow/design/iss0718-candidate-exam-list-route.md §0). Declared
  # ABOVE "/:id" below for readability only, matching the ordering-note
  # convention this file already uses at "/:id" vs the deeper write routes:
  # a literal "/available" segment always wins over the "/:id" wildcard in
  # Plug.Router's compiled matcher regardless of declaration order.

  authz_get "/exam-sessions/available", :ExamSessionStart do
    handle_list_available_exams(conn)
  end

  # ── Session-state read ──────────────────────────────────────────────────
  #
  # ⛔ Declared ABOVE the write routes below for readability only -- no
  # ordering hazard: GET and POST/PUT are independent Plug.Router dispatch
  # tables, and "/:id" (1 segment) cannot collide with "/:id/answers/:qid"
  # or "/:id/submit"/"/:id/events" (2-3 segments) regardless of order.

  authz_get "/exam-sessions/:id", :ExamSessionRead do
    handle_get_session_state(conn, conn.params["id"])
  end

  # ── Autosave ─────────────────────────────────────────────────────────────
  #
  # The live route is `PUT /api/v1/modules/exam/exam-sessions/:id/answers/:question_id`.
  # PUT matches the R-Co reference's registration in
  # backend/internal/sessions/handler.go (`PUT .../sessions/:id/answers/:questionId`,
  # a reference path only, not mounted here) -- re-verified against that
  # reference, not the POST this requirement's own description inferred.

  authz_put "/exam-sessions/:id/answers/:question_id", :ExamSessionSave do
    handle_autosave_answer(conn, conn.params["id"], conn.params["question_id"])
  end

  # ── Submit ───────────────────────────────────────────────────────────────

  authz_post "/exam-sessions/:id/submit", :ExamSessionSubmit do
    handle_submit_session(conn, conn.params["id"])
  end

  # ── Anti-cheat signal report ─────────────────────────────────────────────

  authz_post "/exam-sessions/:id/events", :ExamSessionReportEvent do
    handle_report_event(conn, conn.params["id"])
  end

  # ── Certificate issuance (REQ-355) ──────────────────────────────────────
  #
  # Idempotent issue-on-first-request: the first call for an eligible
  # session creates the certificate, every later call for the SAME session
  # returns the identical, already-issued record. See
  # Letflow.Modules.Exam.Certificate's own moduledoc for the full guard order and
  # idempotency guarantee -- this route is a thin composition layer over it,
  # same shape as every other route in this module.

  authz_post "/exam-sessions/:id/certificate", :ExamCertificateIssue do
    handle_issue_certificate(conn, conn.params["id"])
  end

  # ── Certificate document download (REQ-356) ──────────────────────────────
  #
  # Reuses `:ExamCertificateIssue` rather than minting a new permission atom:
  # this route's own eligibility/ownership check IS
  # `Letflow.Modules.Exam.Certificate.issue_or_get_for_user/3` (the identical
  # idempotent issue-or-fetch call the issuance route above makes -- a
  # candidate who can download a certificate is, by definition, exactly a
  # candidate who could issue/fetch one), so no new authorization semantics
  # exist here that would justify growing `Letflow.Api.Authorization`'s
  # permission matrix for a rendering-only requirement's own scope.

  authz_get "/exam-sessions/:id/certificate/download", :ExamCertificateIssue do
    handle_download_certificate(conn, conn.params["id"])
  end

  # ── Authoring writes (GH #2680 / REQ-510 slice 1) ───────────────────────
  #
  # The module's own write surface for the ten authoring types, gated by the dedicated
  # `:ExamAuthoringWrite` permission. No `scope:` option: the route-scope default is the
  # fail-closed `:tenant_wide`, as for every route here.

  authz_post "/authoring/:entity_type", :ExamAuthoringWrite do
    handle_authoring_create(conn, conn.params["entity_type"])
  end

  authz_put "/authoring/:entity_type/:record_id", :ExamAuthoringWrite do
    handle_authoring_update(conn, conn.params["entity_type"], conn.params["record_id"])
  end

  authz_delete "/authoring/:entity_type/:record_id", :ExamAuthoringWrite do
    handle_authoring_delete(conn, conn.params["entity_type"], conn.params["record_id"])
  end

  # ── Examiner grading queue, read half (GH #3324 / REQ-588 part A) ───────
  #
  # Gated by the manifest-only `:ExamGradingRead` (no role_grants: PLATFORM_ADMIN and TENANT_ADMIN
  # through the core rules). No `scope:` option: fail-closed `:tenant_wide`. No tenant parameter.

  authz_get "/grading-queue", :ExamGradingRead do
    handle_list_grading_queue(conn)
  end

  authz_get "/grading-queue/:session_id/:question_id", :ExamGradingRead do
    handle_get_grading_answer(conn, conn.params["session_id"], conn.params["question_id"])
  end

  authz_unmatched(:ordinary)

  # ══ POST /exam-sessions ═══════════════════════════════════════════════
  #
  # `candidate_id` is ALWAYS conn.assigns.auth_context.user_id -- `exam_id`
  # is the only caller-supplied identifier here, and it names an exam, not a
  # candidate, so INV-1's "never trust a caller-supplied identity" concern
  # does not apply to it the way it applies to every :id below.

  @start_session_schema [
    %FieldConstraint{name: "exam_id", required: true, type: :string, reject_empty_string: true}
  ]

  defp handle_start_session(conn) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@start_session_schema, body),
         {:ok, exam_id} <- cast_uuid(Map.fetch!(attrs, "exam_id")) do
      render_start_session(
        conn,
        Session.create(candidate_id, exam_id, prefix),
        candidate_id,
        prefix
      )
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      # A malformed (non-UUID) exam_id can never resolve to a real exam --
      # the SAME outcome create/3 itself produces for a nonexistent exam_id
      # (lock_exam_row/2's nil branch -> :exam_not_active), reached without
      # ever handing Ecto a value that would raise Ecto.Query.CastError.
      :error ->
        render_start_session(conn, {:error, :exam_not_active}, candidate_id, prefix)
    end
  end

  # design (this module's own moduledoc): create/3's session_view() carries
  # no materialised question set, but a candidate starting a session needs
  # one to render the exam immediately -- so a successful create is followed
  # by ONE get_session_state_for_user/3 call, the same call the read route
  # itself uses, rather than inventing a second response-shaping path.
  defp render_start_session(conn, {:ok, %{id: session_id}}, candidate_id, prefix) do
    case Session.get_session_state_for_user(session_id, candidate_id, prefix) do
      {:ok, state} ->
        Response.created(conn, session_state_json(state))

      {:error, reason} ->
        Logger.warning(
          "exam session state read failed immediately after create: #{inspect(reason)}"
        )

        Response.internal_error(conn)
    end
  end

  # design §create/3's eligibility_error(), mirroring
  # backend/internal/sessions/handler.go's CreateSession status choices.
  defp render_start_session(conn, {:error, :not_assigned}, _candidate_id, _prefix),
    do: Response.forbidden(conn, "you are not assigned to this exam")

  defp render_start_session(conn, {:error, :exam_archived}, _candidate_id, _prefix),
    do: Response.forbidden(conn, "this exam has been archived and is no longer available")

  defp render_start_session(conn, {:error, :exam_not_active}, _candidate_id, _prefix),
    do: Response.unprocessable(conn, "this exam is not currently active")

  defp render_start_session(conn, {:error, :outside_availability_window}, _candidate_id, _prefix),
    do: Response.unprocessable(conn, "this exam is not available at this time")

  defp render_start_session(conn, {:error, :attempts_exhausted}, _candidate_id, _prefix),
    do: Response.unprocessable(conn, "you have used all allowed attempts for this exam")

  # Q-1076 / GH #2433: the same 409 problem document as before, plus one additive
  # `session_id` member (Letflow.Api.Error's `extensions` merge in serialise/1). type, title,
  # status and detail are unchanged. The id is the candidate's own open session for this exam.
  defp render_start_session(
         conn,
         {:error, {:session_already_open, session_id}},
         _candidate_id,
         _prefix
       ) do
    problem = %{
      Letflow.Api.Error.conflict("you already have an active session for this exam")
      | extensions: %{"session_id" => session_id}
    }

    Response.send_problem(conn, problem)
  end

  # GH #2682 / REQ-511: a manual pin names a question that is missing, not active, or not a
  # valid id. Constant body: no id, no reason text (INV-4/INV-5); the id is logged.
  defp render_start_session(
         conn,
         {:error, {:question_not_found, question_id}},
         _candidate_id,
         _prefix
       ) do
    Logger.error(
      "exam start refused: a pinned question is unavailable " <>
        "question_id=#{inspect(question_id)} tenant_prefix=#{prefix!(conn)}"
    )

    Response.unprocessable(conn, @pinned_question_detail)
  end

  defp render_start_session(
         conn,
         {:error, {kind, _reason} = failure},
         _candidate_id,
         _prefix
       )
       when kind in [:grading_error, :snapshot_error],
       do: render_snapshot_failure(conn, failure, @content_invalid_detail, "start")

  defp render_start_session(conn, {:error, reason}, _candidate_id, _prefix) do
    Logger.warning("exam session create failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ GET /exam-sessions/:id ═════════════════════════════════════════════

  defp handle_get_session_state(conn, raw_session_id) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    case cast_uuid(raw_session_id) do
      {:ok, session_id} ->
        render_get_session_state(
          conn,
          Session.get_session_state_for_user(session_id, candidate_id, prefix)
        )

      :error ->
        Response.not_found(conn)
    end
  end

  # INV-5: :session_not_found and :not_owner render through the IDENTICAL
  # zero-detail Response.not_found/1 call -- a candidate probing another
  # candidate's session_id cannot distinguish "not yours" from "does not
  # exist" from the response bytes.
  defp render_get_session_state(conn, {:ok, state}),
    do: Response.ok(conn, session_state_json(state))

  defp render_get_session_state(conn, {:error, :session_not_found}), do: Response.not_found(conn)
  defp render_get_session_state(conn, {:error, :not_owner}), do: Response.not_found(conn)

  defp render_get_session_state(conn, {:error, {kind, _reason} = failure})
       when kind in [:grading_error, :snapshot_error],
       do: render_snapshot_failure(conn, failure, @grading_failed_detail, "state")

  defp render_get_session_state(conn, {:error, reason}) do
    Logger.warning("exam session state read failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ GET /exam-sessions/available (ISS-0718) ═══════════════════════════
  #
  # `entity_type: "exam"` + `status: "active"` filtering is hardcoded
  # server-side in Session.list_available_exams/2 -- this route accepts no
  # caller-supplied entity-type or filter selection, only pagination
  # (`cursor`/`page_size`, same flat-query-string shape
  # Letflow.Routers.Entities' own `GET /entities/definitions` route uses).
  #
  # Field values are redacted by FieldGrants inside Session.list_available_exams/2,
  # keyed by the caller's own user id (the same rule as POST /entities/query).
  # The caller is never taken from the request.

  defp handle_list_available_exams(conn) do
    prefix = prefix!(conn)
    conn = fetch_query_params(conn)
    query = conn.query_params

    case Pagination.parse_page_size_param(Map.get(query, "page_size")) do
      {:ok, page_size} ->
        # scope-all: exam routes are :tenant_wide until reclassified (walk guard :exam_route_reclassified)
        opts = [
          cursor: Map.get(query, "cursor"),
          page_size: page_size,
          scope: :all,
          user_id: conn.assigns.auth_context.user_id
        ]

        render_list_available_exams(
          conn,
          Session.list_available_exams(prefix, opts),
          prefix
        )

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")
    end
  end

  defp render_list_available_exams(
         conn,
         {:ok, %{items: items, next_cursor: next_cursor}},
         prefix
       ) do
    # `exam` is tenant-extensible: a tenant may add a decimal_strict field
    # (decision 0060), which must be a string on the wire exactly as on the
    # entities router. `%{}` (the pack default) is a no-op.
    specs = Definitions.strict_specs("exam", prefix)

    Response.ok(conn, %{
      "items" => Enum.map(items, &exam_row_json(&1, specs)),
      "next_cursor" => next_cursor
    })
  end

  # Duplicated locally rather than reusing Letflow.Routers.Entities' private
  # render_query_error/2 (design §6 OQ-2 -- that function is defp, not
  # importable across routers; this file's own established convention is
  # each router owns its own JSON/error shaping, matching exam_row_json/1
  # below). Only the error shapes this route's hardcoded, well-formed
  # request can actually surface are handled explicitly; anything else logs
  # and falls through to a detail-free 500, same as every other unexpected
  # branch in this router.
  defp render_list_available_exams(conn, {:error, :page_size_too_large}, _prefix),
    do: Response.bad_request(conn, Letflow.Api.Pagination.page_size_error_message())

  defp render_list_available_exams(conn, {:error, :invalid_cursor}, _prefix),
    do: Response.bad_request(conn, "invalid cursor")

  defp render_list_available_exams(conn, {:error, :wrong_endpoint}, _prefix),
    do: Response.bad_request(conn, "cursor is not valid for this endpoint")

  defp render_list_available_exams(conn, {:error, :resume_key_arity_mismatch}, _prefix),
    do: Response.bad_request(conn, "cursor does not match this request's sort clause")

  defp render_list_available_exams(conn, {:error, reason}, _prefix) do
    Logger.warning("available-exams list failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ GET /grading-queue, GET /grading-queue/:session_id/:question_id ═════
  #
  # Reads only, delegated to `Letflow.Modules.Exam.Grading`. The prefix comes from `scoped_opts`;
  # every not-found case (malformed id, absent, another tenant's, already graded, not short text)
  # renders the one `Response.not_found/1` call (INV-5). The optional `locale` query parameter picks
  # the language of `stem` and `exam_title`.

  defp handle_list_grading_queue(conn) do
    prefix = prefix!(conn)
    conn = fetch_query_params(conn)
    query = conn.query_params

    case Pagination.parse_page_size_param(Map.get(query, "page_size")) do
      {:ok, page_size} ->
        opts = [
          cursor: Map.get(query, "cursor"),
          page_size: page_size,
          exam_id: Map.get(query, "exam_id"),
          locale: Map.get(query, "locale")
        ]

        render_list_grading_queue(conn, Grading.list_queue(prefix, opts))

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")
    end
  end

  defp render_list_grading_queue(conn, {:ok, %{items: items, next_cursor: next_cursor}}),
    do: Response.ok(conn, %{"items" => items, "next_cursor" => next_cursor})

  defp render_list_grading_queue(conn, {:error, :page_size_too_large}),
    do: Response.bad_request(conn, Pagination.page_size_error_message())

  defp render_list_grading_queue(conn, {:error, :invalid_cursor}),
    do: Response.bad_request(conn, "invalid cursor")

  defp render_list_grading_queue(conn, {:error, :invalid_exam_id}),
    do: Response.bad_request(conn, "invalid exam_id")

  defp render_list_grading_queue(conn, {:error, reason}) do
    Logger.warning("grading queue list failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  defp handle_get_grading_answer(conn, session_id, question_id) do
    conn = fetch_query_params(conn)

    case Grading.get_answer(prefix!(conn), session_id, question_id,
           locale: Map.get(conn.query_params, "locale")
         ) do
      {:ok, detail} -> Response.ok(conn, detail)
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  # ══ PUT /exam-sessions/:id/answers/:question_id ═══════════════════════
  #
  # `question_id` comes from the PATH, never the body -- one answer per
  # route call, matching backend/internal/sessions/handler.go's own
  # `PUT .../answers/:questionId` shape. `selected_option_ids` defaults to
  # `[]` when absent (a short-text question's autosave carries none), never
  # to `nil` -- Session.autosave_answer/4's own answer_attrs() map pattern
  # requires the key present. ISS-0650: `text_answer` (a short-text
  # question's free-text answer) is genuinely optional -- absent for every
  # OTHER question type's autosave, and `Session.check_answer_shape/3`
  # rejects a non-nil value sent for any of them.

  @autosave_schema [
    %FieldConstraint{name: "selected_option_ids", required: false, type: :array},
    %FieldConstraint{name: "time_spent_seconds", required: true, type: :integer},
    %FieldConstraint{name: "text_answer", required: false, type: :string}
  ]

  defp handle_autosave_answer(conn, raw_session_id, question_id) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    with {:ok, session_id} <- cast_session_id(raw_session_id),
         {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@autosave_schema, body) do
      answer_attrs = %{
        question_id: question_id,
        selected_option_ids: Map.get(attrs, "selected_option_ids", []),
        time_spent_seconds: Map.fetch!(attrs, "time_spent_seconds"),
        text_answer: Map.get(attrs, "text_answer")
      }

      render_autosave(
        conn,
        Session.autosave_answer(session_id, candidate_id, answer_attrs, prefix)
      )
    else
      :not_found ->
        Response.not_found(conn)

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # design (autosave_error()), mirroring handler.go's SaveAnswer status
  # choices. :session_not_found and :not_owner render through the SAME
  # zero-detail 404 (INV-5).
  defp render_autosave(conn, {:ok, %{remaining_seconds: remaining_seconds}}) do
    Response.ok(conn, %{"remaining_seconds" => remaining_seconds})
  end

  defp render_autosave(conn, {:error, :session_not_found}), do: Response.not_found(conn)
  defp render_autosave(conn, {:error, :not_owner}), do: Response.not_found(conn)

  defp render_autosave(conn, {:error, :session_not_in_progress}),
    do: Response.unprocessable(conn, "session is not in progress")

  defp render_autosave(conn, {:error, :deadline_passed}),
    do: Response.unprocessable(conn, "your exam session has expired")

  defp render_autosave(conn, {:error, :question_not_in_session}),
    do: Response.bad_request(conn, "question does not belong to this session")

  defp render_autosave(conn, {:error, :answer_shape_invalid}),
    do: Response.bad_request(conn, "answer shape is invalid for this question type")

  defp render_autosave(conn, {:error, :option_not_in_question}) do
    Response.bad_request(
      conn,
      "one or more supplied option ids do not belong to this question"
    )
  end

  defp render_autosave(conn, {:error, {kind, _reason} = failure})
       when kind in [:grading_error, :snapshot_error],
       do: render_snapshot_failure(conn, failure, @grading_failed_detail, "autosave")

  defp render_autosave(conn, {:error, reason}) do
    Logger.warning("exam session autosave failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ POST /exam-sessions/:id/submit ═════════════════════════════════════

  defp handle_submit_session(conn, raw_session_id) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    case cast_uuid(raw_session_id) do
      {:ok, session_id} ->
        render_submit(conn, Session.submit(session_id, candidate_id, prefix))

      :error ->
        Response.not_found(conn)
    end
  end

  defp render_submit(conn, {:ok, outcome}),
    do: Response.ok(conn, submission_outcome_json(outcome))

  defp render_submit(conn, {:error, :session_not_found}), do: Response.not_found(conn)
  defp render_submit(conn, {:error, :not_owner}), do: Response.not_found(conn)

  defp render_submit(conn, {:error, {kind, _reason} = failure})
       when kind in [:grading_error, :snapshot_error],
       do: render_snapshot_failure(conn, failure, @grading_failed_detail, "submit")

  defp render_submit(conn, {:error, reason}) do
    Logger.warning("exam session submit failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ POST /exam-sessions/:id/certificate ═══════════════════════════════
  #
  # `candidate_id` is ALWAYS conn.assigns.auth_context.user_id, same as
  # every other route in this module -- REQ-355's own scope fence is a
  # candidate requesting issuance for THEIR OWN session, never a
  # caller-supplied candidate identity.

  defp handle_issue_certificate(conn, raw_session_id) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    case cast_uuid(raw_session_id) do
      {:ok, session_id} ->
        render_issue_certificate(
          conn,
          Certificate.issue_or_get_for_user(candidate_id, session_id, prefix)
        )

      :error ->
        Response.not_found(conn)
    end
  end

  # REQ-357 -- on the FIRST issuance only (never on an idempotent replay),
  # mint a Letflow.PublicRead capability handle for this certificate and
  # return the one-time plaintext to the candidate as "public_handle" on
  # the AUTHENTICATED response. `resource_id` MUST be `record.id` (the
  # Ecto primary key `Letflow.Modules.Exam.CertificatePublicProjection.schema/0`'s
  # `Repo.get/3` matches against), never `record.record_id` -- see the
  # design's §2.2/§5.2. `tenant_id` comes from `conn.assigns.auth_context`,
  # same as every other tenant-scoped write in this router -- never
  # request-supplied (INV-1). No second permission check is added here:
  # `:ExamCertificateIssue` (this route's own policy-key gate) already
  # authorizes this in-process call -- see the design's §5.5 for why no
  # `:PublicReadHandlesIssue` consumer is introduced by this requirement.
  #
  # A mint failure is non-blocking relative to the certificate itself
  # (already durably created, its own transaction already committed): the
  # route still responds 200 with the certificate and simply omits
  # "public_handle", logging a warning -- see the design's §5.3 for why no
  # shared transaction wraps both writes.
  defp render_issue_certificate(conn, {:ok, %{first_issuance: true} = certificate}) do
    tenant_id = conn.assigns.auth_context.tenant_id
    body = certificate_json(certificate)

    body =
      case PublicRead.issue_handle(tenant_id, "certificate", certificate.public_read_resource_id) do
        {:ok, %{handle: plaintext}} ->
          Map.put(body, "public_handle", plaintext)

        {:error, reason} ->
          Logger.warning("certificate public-read handle mint failed: #{inspect(reason)}")
          body
      end

    Response.ok(conn, body)
  end

  defp render_issue_certificate(conn, {:ok, certificate}),
    do: Response.ok(conn, certificate_json(certificate))

  # :session_not_found and :not_owner render through the SAME zero-detail
  # 404 (INV-5) -- the identical pair every other route in this module
  # already renders this way.
  defp render_issue_certificate(conn, {:error, :session_not_found}), do: Response.not_found(conn)
  defp render_issue_certificate(conn, {:error, :not_owner}), do: Response.not_found(conn)

  # Three DISTINCT 409 messages -- see Letflow.Modules.Exam.Certificate's own
  # moduledoc "grading_pending is not a passed: false refusal" for why
  # :grading_pending gets its own honest message rather than reusing
  # :session_not_passed's.
  defp render_issue_certificate(conn, {:error, :grading_pending}) do
    Response.conflict(
      conn,
      "this session contains a short-answer question awaiting grading and is not yet eligible for a certificate"
    )
  end

  defp render_issue_certificate(conn, {:error, :session_not_submitted}) do
    Response.conflict(conn, "session has not been submitted yet")
  end

  defp render_issue_certificate(conn, {:error, :exam_not_certifiable}) do
    Response.conflict(conn, "this exam does not issue certificates")
  end

  defp render_issue_certificate(conn, {:error, :session_not_passed}) do
    Response.conflict(conn, "session was not passed")
  end

  # GH #2682 / REQ-511 PR b: the certificate facts come from the session snapshot, so a grading
  # error is a constant-detail 500 and a snapshot error (rollout not run, late write/audit failed)
  # a constant-detail 503, never the reason (INV-4/INV-5).
  defp render_issue_certificate(conn, {:error, {kind, _reason} = failure})
       when kind in [:grading_error, :snapshot_error],
       do: render_snapshot_failure(conn, failure, @grading_failed_detail, "certificate")

  # ISS-0676 -- this catch-all is a deliberate, accepted idiom, not an
  # oversight. `Letflow.Modules.Exam.Certificate.issue_error/0`
  # (certificate.ex:205-...) is a `@type` union, and Elixir/Dialyzer give no
  # compile-time exhaustiveness check of this clause set against it -- a
  # real `mix dialyzer` run performed for this issue confirmed adding an
  # atom to that union (with or without an explicit `@spec` on this
  # function naming the type) produces zero warnings, because this very
  # catch-all widens the accepted type to `term()`. `render_autosave/2` and
  # `render_submit/2` above use the identical catch-all-plus-`Logger.warning`
  # shape against `Letflow.Modules.Exam.Session`'s own error unions
  # (session.ex:129-146) -- this is that established, REVIEWER-accepted
  # precedent, not a one-off.
  #
  # When adding a new atom to `issue_error`: add a matching clause ABOVE
  # this one, and add a case to
  # `test/letflow/routers/exam_sessions_test.exs`'s "every issue_error atom
  # ... renders its own distinct response" test (ISS-0676) proving the new
  # atom reaches its own clause. Skipping either step means the new atom
  # silently falls through to the generic 500 below, with no compiler or
  # Dialyzer warning to catch the omission.
  defp render_issue_certificate(conn, {:error, reason}) do
    Logger.warning("exam certificate issuance failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ GET /exam-sessions/:id/certificate/download ════════════════════════
  #
  # REQ-356. Issues-or-fetches (idempotent, same as the POST route above),
  # then renders PDF bytes FRESH on every request (with a freshly minted
  # verification handle, REQ-592) via
  # `Letflow.Modules.Exam.CertificateDocument.render/2` -- nothing is read from or
  # written to any attachment store; see that module's own moduledoc
  # "Storage" section for the full regenerate-vs-persist statement.

  defp handle_download_certificate(conn, raw_session_id) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    case cast_uuid(raw_session_id) do
      {:ok, session_id} ->
        render_download_certificate(
          conn,
          Certificate.issue_or_get_for_user(candidate_id, session_id, prefix)
        )

      :error ->
        Response.not_found(conn)
    end
  end

  defp render_download_certificate(conn, {:ok, certificate}) do
    # `verification.code` (REQ-592): a fresh `PublicRead` handle (decision
    # 0028) is minted on EVERY download, because only the hash is stored and
    # the plaintext exists solely at mint time. The resource id is
    # `public_read_resource_id` (the Ecto PK that `CertificatePublicProjection`
    # matches), never `certificate.id` (the entity record id). The tenant comes
    # from the token context only. A mint failure is a 500: a PDF with a dead QR
    # is worse than no PDF. Earlier PDFs and the first-issuance `public_handle`
    # stay valid (no revocation; 0028 OQ-3 stays open). Nothing here is logged
    # with a handle.
    tenant_id = conn.assigns.auth_context.tenant_id

    case PublicRead.issue_handle(tenant_id, "certificate", certificate.public_read_resource_id) do
      {:ok, %{handle: code}} ->
        send_certificate_pdf(conn, certificate, code)

      {:error, reason} ->
        Logger.warning(
          "exam certificate download: public-read handle mint failed: #{inspect(reason)}"
        )

        Response.internal_error(conn)
    end
  end

  defp render_download_certificate(conn, {:error, :session_not_found}),
    do: Response.not_found(conn)

  defp render_download_certificate(conn, {:error, :not_owner}), do: Response.not_found(conn)

  defp render_download_certificate(conn, {:error, :grading_pending}) do
    Response.conflict(
      conn,
      "this session contains a short-answer question awaiting grading and is not yet eligible for a certificate"
    )
  end

  defp render_download_certificate(conn, {:error, :session_not_submitted}) do
    Response.conflict(conn, "session has not been submitted yet")
  end

  defp render_download_certificate(conn, {:error, :exam_not_certifiable}) do
    Response.conflict(conn, "this exam does not issue certificates")
  end

  defp render_download_certificate(conn, {:error, :session_not_passed}) do
    Response.conflict(conn, "session was not passed")
  end

  defp render_download_certificate(conn, {:error, {kind, _reason} = failure})
       when kind in [:grading_error, :snapshot_error],
       do: render_snapshot_failure(conn, failure, @grading_failed_detail, "certificate_download")

  defp render_download_certificate(conn, {:error, reason}) do
    Logger.warning("exam certificate download failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  defp send_certificate_pdf(conn, certificate, code) do
    verification = %{base_url: certificate_verify_base_url(), code: code}

    case CertificateDocument.render(certificate, verification) do
      {:ok, bytes} ->
        conn
        |> put_resp_content_type("application/pdf", nil)
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"certificate-#{certificate.id}.pdf\""
        )
        |> send_resp(200, bytes)

      {:error, reason} ->
        Logger.warning("exam certificate document render failed: #{inspect(reason)}")
        Response.internal_error(conn)
    end
  end

  # Read at the point of use via `System.get_env/1`, matching
  # `Letflow.Routers.TenantConfig.idp_base_url/0`'s own INV-4-compliant
  # style (never threaded through a struct field, never logged) -- a
  # verification base URL is not secret material, but the resolution style
  # follows that precedent regardless. `@default_certificate_verify_base_url`
  # matches this project's own dev HTTP port (`config/dev.exs`'s
  # `http_port: 4000`).
  @default_certificate_verify_base_url "http://localhost:4000"

  defp certificate_verify_base_url do
    System.get_env("CERTIFICATE_VERIFY_BASE_URL") || @default_certificate_verify_base_url
  end

  # ══ POST /exam-sessions/:id/events ═════════════════════════════════════
  #
  # `action_taken` is NEVER accepted from the caller -- there is no such
  # field in @report_event_schema, matching AntiCheat.record_signal/4's own
  # parameter list (no action_taken argument at all).

  @report_event_schema [
    %FieldConstraint{name: "type", required: true, type: :string, reject_empty_string: true}
  ]

  defp handle_report_event(conn, raw_session_id) do
    candidate_id = conn.assigns.auth_context.user_id
    prefix = prefix!(conn)

    with {:ok, session_id} <- cast_session_id(raw_session_id),
         {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@report_event_schema, body) do
      signal_type = signal_type_atom(Map.fetch!(attrs, "type"))

      render_report_event(
        conn,
        AntiCheat.record_signal(session_id, candidate_id, signal_type, prefix)
      )
    else
      :not_found ->
        Response.not_found(conn)

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # Closed-set conversion -- NEVER String.to_existing_atom/1 on caller input.
  # An unrecognized string maps to a fixed literal atom that is a member of
  # no valid @valid_signal_types list AntiCheat.record_signal/4 checks
  # against, so it is rejected there as :invalid_signal_type -- exactly the
  # same outcome check_signal_type/1 gives a truly invalid value, without
  # ever calling String.to_existing_atom/1 on untrusted input.
  defp signal_type_atom("tab_switch"), do: :tab_switch
  defp signal_type_atom("blur"), do: :blur
  defp signal_type_atom("fullscreen_exit"), do: :fullscreen_exit
  defp signal_type_atom(_other), do: :__invalid_signal_type__

  # design (signal_error()), mirroring handler.go's ReportEvent status
  # choices. :session_not_found and :not_owner render through the SAME
  # zero-detail 404 (INV-5).
  defp render_report_event(conn, {:ok, outcome}),
    do: Response.ok(conn, signal_outcome_json(outcome))

  defp render_report_event(conn, {:error, :session_not_found}), do: Response.not_found(conn)
  defp render_report_event(conn, {:error, :not_owner}), do: Response.not_found(conn)

  defp render_report_event(conn, {:error, :invalid_signal_type}) do
    Response.bad_request(conn, "type must be one of: tab_switch, blur, fullscreen_exit")
  end

  defp render_report_event(conn, {:error, :session_not_in_progress}),
    do: Response.unprocessable(conn, "session is not in progress")

  defp render_report_event(conn, {:error, :deadline_passed}),
    do: Response.unprocessable(conn, "your exam session has expired")

  defp render_report_event(conn, {:error, {kind, _reason} = failure})
       when kind in [:grading_error, :snapshot_error],
       do: render_snapshot_failure(conn, failure, @grading_failed_detail, "report_event")

  defp render_report_event(conn, {:error, reason}) do
    Logger.warning("exam session anti-cheat signal report failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # `{:grading_error, _}` -> 500 problem with a constant detail; `{:snapshot_error, _}` (the
  # rollout has not run, or a snapshot write failed) -> 503 with a constant detail. The reason tag
  # (atoms and ids only), the session id from the path and the tenant prefix go to the log.
  defp render_snapshot_failure(conn, {kind, reason}, detail, route) do
    Logger.error(
      "exam #{kind} on #{route}: reason=#{inspect(reason)} " <>
        "session_id=#{inspect(Map.get(conn.path_params, "id"))} tenant_prefix=#{prefix!(conn)}"
    )

    case kind do
      :grading_error -> Response.internal_error(conn, detail)
      :snapshot_error -> Response.service_unavailable(conn, @upgrading_detail)
    end
  end

  # ══ Authoring writes: POST/PUT/DELETE /authoring/:entity_type[/:record_id] ═══
  #
  # Bodies and responses are byte-compatible with `Letflow.Routers.Entities.RecordWrites` (the
  # generic routes), whose renderer is reused, so the web switch is a path swap. Order (INV-5):
  # permission plug (403 before any lookup) -> `Authoring.access/3` (a type outside the allow-list
  # is the constant 404) -> record id cast (a bad id is the same 404) -> body -> command. `actor_id`
  # is the authenticated user, `prefix` comes from `scoped_opts` (INV-1), `entity_type` from the path
  # only. A `:hidden` type is validated like an absent one and then answers as an absent one.

  @max_int8 9_223_372_036_854_775_807

  @authoring_write_schema [
    %FieldConstraint{name: "field_values", required: true, type: :object},
    %FieldConstraint{
      name: "idempotency_key",
      required: false,
      type: :string,
      reject_empty_string: true
    }
  ]

  @authoring_update_schema @authoring_write_schema ++
                             [
                               %FieldConstraint{
                                 name: "expected_last_event_global_seq",
                                 required: false,
                                 type: :integer,
                                 min_value: 0,
                                 max_value: @max_int8
                               }
                             ]

  defp handle_authoring_create(conn, entity_type) do
    prefix = prefix!(conn)
    actor_id = conn.assigns.auth_context.user_id

    with access when access != :not_authoring <- Authoring.access(actor_id, entity_type, prefix),
         {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@authoring_write_schema, body),
         {:ok, resolved} <- Idempotency.from_body(attrs, :rec, actor_id) do
      field_values = Map.fetch!(attrs, "field_values")

      command_attrs = %{
        entity_type: entity_type,
        field_values: field_values,
        actor_id: actor_id,
        idempotency_key: resolved.key
      }

      case authoring_write_point(access, field_values) do
        {:run, restricted} ->
          render_authoring(conn, Authoring.create(command_attrs, prefix), :created, restricted)

        {:refuse, :restricted_field} ->
          restricted_fields_refusal(conn)

        {:refuse, :hidden} ->
          render_authoring(conn, RecordAccess.hidden_result(entity_type), :created, MapSet.new())
      end
    else
      :not_authoring -> Response.not_found(conn)
      other -> render_authoring_input_error(conn, other)
    end
  end

  defp handle_authoring_update(conn, entity_type, raw_record_id) do
    prefix = prefix!(conn)
    actor_id = conn.assigns.auth_context.user_id

    with access when access != :not_authoring <- Authoring.access(actor_id, entity_type, prefix),
         {:ok, record_id} <- cast_uuid(raw_record_id),
         {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@authoring_update_schema, body),
         {:ok, resolved} <- Idempotency.from_body(attrs, :rec, actor_id) do
      field_values = Map.fetch!(attrs, "field_values")

      command_attrs = %{
        entity_type: entity_type,
        record_id: record_id,
        field_values: field_values,
        actor_id: actor_id,
        idempotency_key: resolved.key,
        expected_last_event_global_seq: Map.get(attrs, "expected_last_event_global_seq")
      }

      # PUT replaces `field_values` wholesale: a body naming a restricted key is refused, otherwise
      # the stored values of the actor's restricted keys are carried over (`preserve_keys`).
      case authoring_write_point(access, field_values) do
        {:run, restricted} ->
          command_attrs =
            if MapSet.size(restricted) > 0,
              do: Map.put(command_attrs, :preserve_keys, restricted),
              else: command_attrs

          render_authoring(conn, Authoring.update(command_attrs, prefix), :ok, restricted)

        {:refuse, :restricted_field} ->
          restricted_fields_refusal(conn)

        {:refuse, :hidden} ->
          render_authoring(conn, RecordAccess.hidden_result(entity_type), :ok, MapSet.new())
      end
    else
      :not_authoring -> Response.not_found(conn)
      other -> render_authoring_input_error(conn, other)
    end
  end

  defp handle_authoring_delete(conn, entity_type, raw_record_id) do
    prefix = prefix!(conn)
    actor_id = conn.assigns.auth_context.user_id

    with access when access != :not_authoring <- Authoring.access(actor_id, entity_type, prefix),
         {:ok, record_id} <- cast_uuid(raw_record_id),
         conn = fetch_query_params(conn),
         {:ok, expected} <-
           parse_expected_seq(Map.get(conn.query_params, "expected_last_event_global_seq")) do
      command_attrs = %{
        entity_type: entity_type,
        record_id: record_id,
        actor_id: actor_id,
        idempotency_key: Ecto.UUID.generate(),
        expected_last_event_global_seq: expected
      }

      case access do
        {:open, restricted} ->
          render_authoring(conn, Authoring.delete(command_attrs, prefix), :ok, restricted)

        :hidden ->
          render_authoring(conn, RecordAccess.hidden_result(entity_type), :ok, MapSet.new())
      end
    else
      :not_authoring ->
        Response.not_found(conn)

      :error ->
        Response.not_found(conn)

      {:error, :invalid_expected_seq} ->
        Response.bad_request(conn, "invalid expected_last_event_global_seq")
    end
  end

  defp authoring_write_point(:hidden, _field_values), do: {:refuse, :hidden}

  defp authoring_write_point({:open, restricted}, field_values) do
    if RecordAccess.names_restricted?(field_values, restricted),
      do: {:refuse, :restricted_field},
      else: {:run, restricted}
  end

  defp render_authoring(conn, result, status, restricted),
    do: RecordWrites.render_record_command(conn, result, status, restricted)

  # A malformed record id is the same zero-detail 404 as an absent or cross-tenant one (INV-5).
  defp render_authoring_input_error(conn, :error), do: Response.not_found(conn)

  defp render_authoring_input_error(conn, {:error, :malformed_json}),
    do: Response.bad_request(conn, "request body must be a JSON object")

  defp render_authoring_input_error(conn, {:errors, field_errors}),
    do: Response.send_problem(conn, Validation.problem(field_errors))

  defp render_authoring_input_error(conn, {:error, :idempotency_key_too_long}),
    do: Response.send_problem(conn, Validation.problem([Idempotency.too_long_error(:body)]))

  defp render_authoring_input_error(conn, {:error, :idempotency_key_invalid}),
    do: Response.send_problem(conn, Validation.problem([Idempotency.invalid_error(:body)]))

  # Absent -> {:ok, nil}; a fully consumed non-negative integer within int8 -> {:ok, n}; anything
  # else is `:invalid_expected_seq` (as the generic DELETE route).
  defp parse_expected_seq(nil), do: {:ok, nil}

  defp parse_expected_seq(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 and n <= @max_int8 -> {:ok, n}
      _other -> {:error, :invalid_expected_seq}
    end
  end

  defp parse_expected_seq(_other), do: {:error, :invalid_expected_seq}

  # ══ JSON shaping (hand-selected fields only -- see this module's own
  # moduledoc redaction section) ══════════════════════════════════════════

  defp certificate_json(%{
         id: id,
         session_id: session_id,
         issued_at: issued_at,
         candidate_name: candidate_name,
         exam_title: exam_title,
         score_pct: score_pct,
         branding_snapshot: branding_snapshot
       }) do
    %{
      "id" => id,
      "session_id" => session_id,
      "issued_at" => DateTime.to_iso8601(issued_at),
      "candidate_name" => candidate_name,
      "exam_title" => exam_title,
      "score_pct" => score_pct,
      "branding_snapshot" => branding_snapshot
    }
  end

  defp session_view_json(%{
         id: id,
         exam_id: exam_id,
         candidate_id: candidate_id,
         status: status,
         seed: seed,
         started_at: started_at,
         expires_at: expires_at,
         score_pct: score_pct,
         passed: passed
       }) do
    %{
      "id" => id,
      "exam_id" => exam_id,
      "candidate_id" => candidate_id,
      "status" => Atom.to_string(status),
      "seed" => seed,
      "started_at" => DateTime.to_iso8601(started_at),
      "expires_at" => DateTime.to_iso8601(expires_at),
      "score_pct" => score_pct,
      "passed" => passed
    }
  end

  defp session_state_json(%{
         session: session,
         remaining_seconds: remaining_seconds,
         questions: questions,
         answers: answers
       }) do
    %{
      "session" => session_view_json(session),
      "remaining_seconds" => remaining_seconds,
      "questions" => Enum.map(questions, &question_state_json/1),
      "answers" =>
        Map.new(answers, fn {question_id, answer} -> {question_id, answer_json(answer)} end)
    }
  end

  # ⛔ Only id/sort_order/type/stem/options -- NEVER a question's
  # `explanation`/`difficulty`/`category_id`/`status`/`version` field.
  defp question_state_json(%{
         question_id: question_id,
         sort_order: sort_order,
         type: type,
         stem: stem,
         options: options
       }) do
    %{
      "question_id" => question_id,
      "sort_order" => sort_order,
      "type" => Atom.to_string(type),
      "stem" => stem,
      "options" =>
        Enum.map(options, fn %{id: id, text: text} -> %{"id" => id, "text" => text} end)
    }
  end

  defp answer_json(%{
         selected_option_ids: selected_option_ids,
         text_answer: text_answer,
         time_spent_seconds: time_spent_seconds,
         saved_at: saved_at
       }) do
    %{
      "selected_option_ids" => selected_option_ids,
      "text_answer" => text_answer,
      "time_spent_seconds" => time_spent_seconds,
      "saved_at" => saved_at
    }
  end

  defp submission_outcome_json(%{
         status: status,
         total_score: total_score,
         total_max_score: total_max_score,
         percentage: percentage,
         passed: passed
       }) do
    %{
      "status" => Atom.to_string(status),
      "total_score" => total_score,
      "total_max_score" => total_max_score,
      "percentage" => percentage,
      "passed" => passed
    }
  end

  defp signal_outcome_json(%{
         action_taken: action_taken,
         event_count: event_count,
         warning: warning,
         submission: submission
       }) do
    %{
      "action_taken" => Atom.to_string(action_taken),
      "event_count" => event_count,
      "warning" => warning,
      "submission" => if(submission, do: submission_outcome_json(submission), else: nil)
    }
  end

  # Structurally identical to Letflow.Routers.Entities' own
  # query_item_map/1's two non-join clauses (entities.ex:2327-2330) --
  # duplicated rather than imported cross-router (design §1.3 OQ-2,
  # matching this file's own established convention that each router owns
  # its JSON shaping). `Letflow.Entities.Query.Compiler.compile_plain/5`
  # returns either an unpromoted `%Letflow.Entities.Record.Latest{}` struct
  # or a promoted plain-map `entity_row()`, depending on whether "exam" has
  # a per-type table today -- both clauses are needed for that reason, not
  # for defensiveness.
  defp exam_row_json(%Latest{} = record, specs) do
    %{
      "record_id" => record.record_id,
      "field_values" => Decimals.render_field_values(record.field_values, specs),
      "deleted" => record.deleted,
      "entity_def_version" => encode_entity_def_version(record.entity_def_version),
      "last_event_global_seq" => record.last_event_global_seq
    }
  end

  defp exam_row_json(%{field_values: _field_values} = entity_row, specs) do
    %{
      "record_id" => entity_row.record_id,
      "field_values" => Decimals.render_field_values(entity_row.field_values, specs),
      "deleted" => entity_row.deleted,
      "entity_def_version" => encode_entity_def_version(entity_row.entity_def_version),
      "last_event_global_seq" => entity_row.last_event_global_seq
    }
  end

  defp encode_entity_def_version(nil), do: nil

  defp encode_entity_def_version(version) when is_binary(version),
    do: Base.encode16(version, case: :lower)

  # ══ Shared plumbing ═══════════════════════════════════════════════════

  @spec prefix!(Plug.Conn.t()) :: String.t()
  defp prefix!(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  defp object_body(conn) do
    case conn.body_params do
      %{"_json" => _non_object} -> {:error, :malformed_json}
      body when is_map(body) -> {:ok, body}
      _other -> {:error, :malformed_json}
    end
  end

  defp validate_schema(schema, body) do
    case Validation.validate(schema, body) do
      {:ok, attrs} -> {:ok, attrs}
      {:errors, field_errors} -> {:errors, field_errors}
    end
  end

  # A malformed session id can never own anything -- fold it into the SAME
  # not-found path :session_not_found/:not_owner already take (INV-5),
  # before ever handing Ecto a value that would raise Ecto.Query.CastError
  # against Letflow.Entities.Record.Latest's UUID-typed record_id column.
  defp cast_session_id(raw_session_id) do
    case cast_uuid(raw_session_id) do
      {:ok, session_id} -> {:ok, session_id}
      :error -> :not_found
    end
  end

  @spec cast_uuid(String.t()) :: {:ok, String.t()} | :error
  defp cast_uuid(raw), do: Ecto.UUID.cast(raw)
end
