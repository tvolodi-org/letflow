defmodule Mix.Tasks.Letflow.Seed.ExamFixtures do
  @shortdoc "Seeds two published exams + one submitted session for e2e runs (REQ-345)"

  @moduledoc """
  mix letflow.seed.exam_fixtures — REQ-345

  Seeds, in the bpm-default tenant, via Letflow.Entities.Records (never direct SQL):

    * category "REQ-345 Mixed Exam Bank" (track: nil) — houses exactly the 5
      questions below, used by NO other exam.
    * category "REQ-345 Scoreable Exam Bank" (track: nil) — houses exactly the 3
      questions below, used by NO other exam.

    * Exam 1 — "REQ-345 E2E Mixed Exam" (status: active), one question per
      question.json's full 5-member type enum:
        Q1 single    "REQ-345 Mixed Q1 (single)"    — 2 options, option A correct
        Q2 multiple  "REQ-345 Mixed Q2 (multiple)"  — 3 options, options A+B correct
        Q3 truefalse "REQ-345 Mixed Q3 (truefalse)" — 2 options, "True" correct
        Q4 likert    "REQ-345 Mixed Q4 (likert)"    — 2 options, weights 1.0/5.0, positive
        Q5 shorttext "REQ-345 Mixed Q5 (shorttext)" — 0 options (free text, ungraded)
      Because Q5's type is shorttext, lib/letflow/exam/scoring.ex:255's
      `Enum.any?(questions, &(&1.type == :short_text))` is true for EVERY session
      of this exam, so build_outcome/3 (scoring.ex:255/:257) can only ever
      produce status: :grading_pending and passed: nil for this exam — never a
      score. This is a property of the fixture, not a defect.

    * Exam 2 — "REQ-345 E2E Scoreable Exam" (status: active), passing_score_pct:
      60.00, 3 questions, NONE shorttext:
        R1 single    "REQ-345 Scoreable R1 (single)"    — 2 options, option A correct
        R2 truefalse "REQ-345 Scoreable R2 (truefalse)" — 2 options, "True" correct
        R3 multiple  "REQ-345 Scoreable R3 (multiple)"  — 3 options, options A+B correct
      Worked arithmetic (lib/letflow/exam/scoring.ex score_question/2, all three
      questions max_score 1.0 each, total_max_score 3.0):
        PASSING combination — R1 correct (1.0), R2 correct (1.0), R3 both
          correct options selected, no incorrect ((2-0)/2 = 1.0 clamped to
          [0,1]) — total_score 3.0/3.0 = 100.00% >= 60.00 => passed: true.
        FAILING combination — R1 incorrect (0.0), R2 incorrect (0.0), R3
          unanswered (unanswered = wrong per scoring.ex's own rule, 0.0) —
          total_score 0.0/3.0 = 0.00% < 60.00 => passed: false.
      Both Passed and Failed are therefore reachable against this exam.

    * One session against Exam 1 (the mixed exam), created via
      POST /modules/exam/exam-sessions and finished via POST /modules/exam/exam-sessions/:id/submit —
      Letflow.Modules.Exam.Router, REQ-335's real route table — dispatched
      in-process through Letflow.Router.call/2 (the exact same full Plug
      pipeline test/letflow/routers/exam_sessions_test.exs itself dispatches
      through), authenticated as a dedicated seed candidate user
      ("req345.candidate@example.com" / username "req345-e2e-candidate") minted
      a CANDIDATE-role token via Letflow.Identity.create_token/3 (ISS-0646
      moved ExamSession* permissions off TASK_WORKER onto this dedicated
      role -- a TASK_WORKER token can no longer drive an exam session). No answers
      are autosaved before submit — unanswered questions score 0 per
      scoring.ex's "unanswered = wrong, not skipped" rule, which changes
      nothing about this session's outcome (it is grading_pending regardless,
      because of Q5). Persisted/returned outcome: status "grading_pending",
      score_pct 0.0, passed nil.

    NOT SEEDED, DELIBERATELY: no exam_assignment record — none exists in this
    tenant's schema (open question, see lib/letflow/exam/session.ex:595's
    documented check_assigned/3 no-op) — every candidate is already treated as
    assigned. Seeding a workaround record would misrepresent a gap as solved.

    ASSERTABLE ONLY OVER RAW HTTP. The seeded session can be asserted via
    GET /modules/exam/exam-sessions/:id only. web/src/pages/exam/ExamSessionPage.tsx:112-127's
    mount effect calls examApi.startSession(examId) UNCONDITIONALLY (guarded
    only by a startedRef ref, not by "does a session already exist") — there is
    no branch in that component, or anywhere in web/src/router.tsx's exam
    routes, that loads an existing session by id. Navigating a browser to the
    session route starts a NEW session instead of reading this one. Do not
    treat this fixture as backing any rendered result screen.

    IDEMPOTENT. Re-running this task converges: a second run creates zero new
    exam/category/question/answer_option/exam_question_rule records (each
    create_record/2 call carries a fixed, content-derived idempotency_key, and
    Letflow.Entities.Records.create_record/2 returns the ORIGINAL record for a
    repeated key — design doc req228, AC3; GH #2543: only when the request is
    the same, so editing seed content between runs in one tenant makes the task
    raise with :idempotency_key_reuse instead of keeping the old content) and
    creates zero new sessions (the
    task queries for an existing session against Exam 1 for the seed candidate
    before calling POST /modules/exam/exam-sessions at all, and skips straight to reporting
    its already-persisted outcome if one is found).

    QUESTION TYPE ENUM, VERIFIED: priv/modules/exam/entity_definitions/
    question.json's `type` field enum is
    ["single","multiple","truefalse","likert","shorttext"] — all five of
    BilimBaga's original five question types carry over unchanged; NONE of the
    five lacks a Letflow counterpart. ("shorttext", no underscore, is the pack
    enum's own spelling; lib/letflow/exam/session.ex:1174's
    question_type_atom/1 maps it to the :short_text atom, which is what
    scoring.ex:255 tests against — this task asserts on the pack's "shorttext"
    spelling when WRITING question records, and on the :short_text atom only
    when reading back Letflow.Modules.Exam.Session/Scoring's own in-memory shapes —
    never on a fabricated ":shorttext" atom.)

  ## Task-shape decision

  A new sibling task, not a flag on `mix letflow.seed` — see
  `lib/letflow/design/req345-exam-e2e-seed-fixture.md` §0 for the full
  reasoning. This task runs `Mix.Task.run("letflow.seed")` as its own first
  step so a bare `mix letflow.seed.exam_fixtures` on a fresh database is
  self-sufficient for e2e setup scripts.

  ## Deviation from the design doc's literal §7a/§7e field-value maps: optional
  ## fields with no value are OMITTED, never written as an explicit `nil`

  The design doc's `field_values` maps write absent optional fields as
  `"track" => nil` / `"section_id" => nil` / `"difficulty" => nil`. Verified
  against a real run: `Letflow.Entities.Record.Validator.field_subschema/1`
  emits plain JSON-Schema `{"type" => "string"}` for a `:string` field with no
  `"nullable"`/type-union relaxation, so a literal `nil` value fails schema
  validation with `field_path: "/track", constraint: "type", actual: nil`
  even though `track` is not in the schema's `"required"` list. This task
  therefore omits `track`/`section_id`/`difficulty` from every `field_values`
  map entirely rather than passing `nil` — confirmed working end to end
  against a real database (see close-out). Flagged here rather than silently
  fixed, since the design doc's literal maps would not have run.

  ## Usage

      LETFLOW_DEV_DB_CONFIRMED=1 mix letflow.seed.exam_fixtures
  """

  use Mix.Task

  # Decision 0052 D3 (GH 2531): an internal, non-HTTP install caller passes a FIXED,
  # code-reviewed rationale naming its cause (never a synthesised or user-facing default).
  @install_rationale "seed: exam fixtures (mix letflow.seed.exam_fixtures)"

  @doc false
  def install_rationale, do: @install_rationale

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Query.Compiler
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @tenant_realm "bpm-default"

  @candidate_username "req345-e2e-candidate"
  @candidate_email "req345.candidate@example.com"
  @candidate_display_name "REQ-345 E2E Seed Candidate"

  @mixed_exam_title "REQ-345 E2E Mixed Exam"
  @scoreable_exam_title "REQ-345 E2E Scoreable Exam"
  @scoreable_passing_score_pct 60.0

  @mixed_category_title "REQ-345 Mixed Exam Bank"
  @scoreable_category_title "REQ-345 Scoreable Exam Bank"

  @impl Mix.Task
  @spec run(args :: [String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.start")
    Mix.Task.run("letflow.seed")

    # `Letflow.Entities.Records.field_document/1` decodes a persisted
    # definition's field `"type"` string via `String.to_existing_atom/1`,
    # relying on `Letflow.Entities.Record.Validator` (and
    # `Letflow.Entities.Definition.Validator`) already having been loaded
    # somewhere so every field-type atom (`:localized_text` among them) is
    # already registered -- true by construction under `mix test` (the
    # whole app is compiled and heavily cross-referenced before any test
    # runs) but NOT guaranteed for a bare `mix` task in a freshly booted
    # VM, where BEAM modules load lazily on first call. Force both modules
    # loaded here, defensively, rather than let a fresh-VM run crash on
    # `:erlang.binary_to_existing_atom/1` for a category's `:localized_text`
    # "name" field -- the first field-typed write this task makes.
    Code.ensure_loaded!(Letflow.Entities.Definition.Validator)
    Code.ensure_loaded!(Letflow.Entities.Record.Validator)

    {tenant_id, prefix} = resolve_tenant!()
    candidate = resolve_candidate_user!(tenant_id, prefix)

    {:ok, %{plaintext: token_plaintext}} =
      Identity.create_token(candidate.id, %{roles: ["CANDIDATE"], expires_at: nil},
        prefix: prefix
      )

    {mixed_exam_id, mixed_questions} = seed_mixed_exam!(prefix, candidate.id)
    {scoreable_exam_id, scoreable_questions} = seed_scoreable_exam!(prefix, candidate.id)

    # REQ-410: ensure the exam module is installed for the bpm-default tenant
    # so the D5 gate in Letflow.Routers.Modules passes /modules/exam/exam-sessions
    # requests. Idempotent: already_installed is silently accepted.
    case Installs.install("exam", candidate.id, prefix: prefix, rationale: @install_rationale) do
      {:ok, _} ->
        Mix.shell().info("exam module installed for tenant #{prefix}")

      {:error, :already_installed} ->
        Mix.shell().info("exam module already installed for tenant #{prefix}")

      {:error, reason} ->
        Mix.raise(
          "mix letflow.seed.exam_fixtures: FAILED -- install exam module: #{inspect(reason)}"
        )
    end

    {session_id, submit_body} =
      seed_session!(prefix, candidate.id, mixed_exam_id, token_plaintext)

    report!(%{
      mixed_exam_id: mixed_exam_id,
      mixed_questions: mixed_questions,
      scoreable_exam_id: scoreable_exam_id,
      scoreable_questions: scoreable_questions,
      session_id: session_id,
      submit_body: submit_body
    })

    :ok
  end

  # ---------------------------------------------------------------------
  # Tenant / candidate resolution
  # ---------------------------------------------------------------------

  defp resolve_tenant! do
    case Identity.resolve_tenant_by_realm(@tenant_realm) do
      {:ok, tenant} ->
        case TenantProvisioning.schema_name_for_tenant(tenant.id) do
          {:ok, prefix} ->
            {tenant.id, prefix}

          {:error, reason} ->
            Mix.raise(
              "mix letflow.seed.exam_fixtures: FAILED -- schema_name_for_tenant/1: #{inspect(reason)}"
            )
        end

      {:error, :not_found} ->
        Mix.raise(
          "mix letflow.seed.exam_fixtures: FAILED -- tenant \"#{@tenant_realm}\" does not " <>
            "resolve after running mix letflow.seed. This should not happen."
        )
    end
  end

  # §4b -- Letflow.Identity.create_user/2 has no idempotency_key mechanism;
  # follow mix letflow.seed's own create-or-resolve pattern.
  defp resolve_candidate_user!(tenant_id, prefix) do
    case Identity.create_user(
           %{
             "username" => @candidate_username,
             "display_name" => @candidate_display_name,
             "email" => @candidate_email
           },
           prefix: prefix,
           tenant_id: tenant_id
         ) do
      {:ok, user} ->
        user

      {:error, :duplicate_username} ->
        # Deliberate direct Repo read, flagged per the design doc §4b: no
        # Letflow.Identity.get_user_by_username/2 exists today (only
        # get_user/2 by id), and this is a plain read against an ordinary
        # Ecto-schema table the identity subsystem already owns.
        case Repo.get_by(User, [username: @candidate_username], prefix: prefix) do
          %User{} = user ->
            user

          nil ->
            Mix.raise(
              "mix letflow.seed.exam_fixtures: FAILED -- duplicate_username reported but no matching user row found"
            )
        end

      {:error, reason} ->
        Mix.raise("mix letflow.seed.exam_fixtures: FAILED -- create_user/2: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------
  # §4a -- entity-record writes, all via create_record/2 with fixed,
  # content-derived idempotency keys.
  # ---------------------------------------------------------------------

  defp seed_mixed_exam!(prefix, actor_id) do
    category_id =
      create_record!(prefix, actor_id, "category", "req345-seed-category-mixed", %{
        "name" => %{"en" => @mixed_category_title},
        "sort_order" => 0
      })

    q1 =
      seed_question!(
        prefix,
        actor_id,
        category_id,
        "mixed-q1-single",
        "single",
        "REQ-345 Mixed Q1 (single)"
      )

    seed_two_options!(prefix, actor_id, q1, "mixed-q1", {"A", true}, {"B", false})

    q2 =
      seed_question!(
        prefix,
        actor_id,
        category_id,
        "mixed-q2-multiple",
        "multiple",
        "REQ-345 Mixed Q2 (multiple)"
      )

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-mixed-q2-a", %{
      "question_id" => q2,
      "sort_order" => 0,
      "is_correct" => true,
      "text" => %{"en" => "A"}
    })

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-mixed-q2-b", %{
      "question_id" => q2,
      "sort_order" => 1,
      "is_correct" => true,
      "text" => %{"en" => "B"}
    })

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-mixed-q2-c", %{
      "question_id" => q2,
      "sort_order" => 2,
      "is_correct" => false,
      "text" => %{"en" => "C"}
    })

    q3 =
      seed_question!(
        prefix,
        actor_id,
        category_id,
        "mixed-q3-truefalse",
        "truefalse",
        "REQ-345 Mixed Q3 (truefalse)"
      )

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-mixed-q3-true", %{
      "question_id" => q3,
      "sort_order" => 0,
      "is_correct" => true,
      "text" => %{"en" => "True"}
    })

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-mixed-q3-false", %{
      "question_id" => q3,
      "sort_order" => 1,
      "is_correct" => false,
      "text" => %{"en" => "False"}
    })

    q4 =
      seed_question!(
        prefix,
        actor_id,
        category_id,
        "mixed-q4-likert",
        "likert",
        "REQ-345 Mixed Q4 (likert)"
      )

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-mixed-q4-low", %{
      "question_id" => q4,
      "sort_order" => 0,
      "is_correct" => false,
      "likert_weight" => 1.0,
      "likert_polarity" => "positive",
      "text" => %{"en" => "Strongly disagree"}
    })

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-mixed-q4-high", %{
      "question_id" => q4,
      "sort_order" => 1,
      "is_correct" => false,
      "likert_weight" => 5.0,
      "likert_polarity" => "positive",
      "text" => %{"en" => "Strongly agree"}
    })

    q5 =
      seed_question!(
        prefix,
        actor_id,
        category_id,
        "mixed-q5-shorttext",
        "shorttext",
        "REQ-345 Mixed Q5 (shorttext)"
      )

    # Q5 (shorttext) has NO answer_option records -- see moduledoc.

    exam_id =
      create_record!(prefix, actor_id, "exam", "req345-seed-exam-mixed", %{
        "title" => %{"en" => @mixed_exam_title},
        "status" => "active",
        "time_limit_minutes" => 30,
        "passing_score_pct" => 60.0,
        "max_attempts" => 5,
        "shuffle_questions" => false,
        "shuffle_options" => false,
        "show_answers" => "never",
        "on_tab_switch" => "log",
        "certificate_enabled" => false
      })

    create_record!(prefix, actor_id, "exam_question_rule", "req345-seed-rule-mixed", %{
      "exam_id" => exam_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 5,
      "sort_order" => 0
    })

    {exam_id,
     [
       {q1, "single"},
       {q2, "multiple"},
       {q3, "truefalse"},
       {q4, "likert"},
       {q5, "shorttext"}
     ]}
  end

  defp seed_scoreable_exam!(prefix, actor_id) do
    category_id =
      create_record!(prefix, actor_id, "category", "req345-seed-category-scoreable", %{
        "name" => %{"en" => @scoreable_category_title},
        "sort_order" => 0
      })

    r1 =
      seed_question!(
        prefix,
        actor_id,
        category_id,
        "scoreable-r1-single",
        "single",
        "REQ-345 Scoreable R1 (single)"
      )

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-scoreable-r1-a", %{
      "question_id" => r1,
      "sort_order" => 0,
      "is_correct" => true,
      "text" => %{"en" => "A"}
    })

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-scoreable-r1-b", %{
      "question_id" => r1,
      "sort_order" => 1,
      "is_correct" => false,
      "text" => %{"en" => "B"}
    })

    r2 =
      seed_question!(
        prefix,
        actor_id,
        category_id,
        "scoreable-r2-truefalse",
        "truefalse",
        "REQ-345 Scoreable R2 (truefalse)"
      )

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-scoreable-r2-true", %{
      "question_id" => r2,
      "sort_order" => 0,
      "is_correct" => true,
      "text" => %{"en" => "True"}
    })

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-scoreable-r2-false", %{
      "question_id" => r2,
      "sort_order" => 1,
      "is_correct" => false,
      "text" => %{"en" => "False"}
    })

    r3 =
      seed_question!(
        prefix,
        actor_id,
        category_id,
        "scoreable-r3-multiple",
        "multiple",
        "REQ-345 Scoreable R3 (multiple)"
      )

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-scoreable-r3-a", %{
      "question_id" => r3,
      "sort_order" => 0,
      "is_correct" => true,
      "text" => %{"en" => "A"}
    })

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-scoreable-r3-b", %{
      "question_id" => r3,
      "sort_order" => 1,
      "is_correct" => true,
      "text" => %{"en" => "B"}
    })

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-scoreable-r3-c", %{
      "question_id" => r3,
      "sort_order" => 2,
      "is_correct" => false,
      "text" => %{"en" => "C"}
    })

    exam_id =
      create_record!(prefix, actor_id, "exam", "req345-seed-exam-scoreable", %{
        "title" => %{"en" => @scoreable_exam_title},
        "status" => "active",
        "time_limit_minutes" => 30,
        "passing_score_pct" => @scoreable_passing_score_pct,
        "max_attempts" => 5,
        "shuffle_questions" => false,
        "shuffle_options" => false,
        "show_answers" => "never",
        "on_tab_switch" => "log",
        "certificate_enabled" => false
      })

    create_record!(prefix, actor_id, "exam_question_rule", "req345-seed-rule-scoreable", %{
      "exam_id" => exam_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 3,
      "sort_order" => 0
    })

    {exam_id, [{r1, "single"}, {r2, "truefalse"}, {r3, "multiple"}]}
  end

  defp seed_question!(prefix, actor_id, category_id, key_suffix, type, stem) do
    create_record!(prefix, actor_id, "question", "req345-seed-question-#{key_suffix}", %{
      "category_id" => category_id,
      "difficulty" => "easy",
      "type" => type,
      "default_locale" => "en",
      "status" => "active",
      "version" => 1,
      "stem" => %{"en" => stem}
    })
  end

  defp seed_two_options!(
         prefix,
         actor_id,
         question_id,
         key_prefix,
         {a_text, a_correct},
         {b_text, b_correct}
       ) do
    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-#{key_prefix}-a", %{
      "question_id" => question_id,
      "sort_order" => 0,
      "is_correct" => a_correct,
      "text" => %{"en" => a_text}
    })

    create_record!(prefix, actor_id, "answer_option", "req345-seed-option-#{key_prefix}-b", %{
      "question_id" => question_id,
      "sort_order" => 1,
      "is_correct" => b_correct,
      "text" => %{"en" => b_text}
    })
  end

  defp create_record!(prefix, actor_id, entity_type, idempotency_key, field_values) do
    case Letflow.Entities.Records.create_record(
           %{
             entity_type: entity_type,
             field_values: field_values,
             actor_id: actor_id,
             idempotency_key: idempotency_key
           },
           prefix
         ) do
      {:ok, %{record: record}} ->
        record.record_id

      {:error, reason} ->
        Mix.raise(
          "mix letflow.seed.exam_fixtures: FAILED -- create_record/2(#{entity_type}, #{idempotency_key}): #{inspect(reason)}"
        )
    end
  end

  # ---------------------------------------------------------------------
  # §4c/§6 -- session query-before-create, then real HTTP dispatch.
  # ---------------------------------------------------------------------

  defp seed_session!(prefix, candidate_id, mixed_exam_id, token_plaintext) do
    case existing_sessions(prefix, mixed_exam_id, candidate_id) do
      [] ->
        session_id = start_session_via_http!(prefix, mixed_exam_id, token_plaintext)
        {session_id, submit_session_via_http!(prefix, session_id, token_plaintext)}

      [session] ->
        {session.record_id, submit_session_via_http!(prefix, session.record_id, token_plaintext)}

      many ->
        Mix.raise(
          "mix letflow.seed.exam_fixtures: FAILED -- #{length(many)} existing sessions found " <>
            "for (exam_id=#{mixed_exam_id}, user_id=#{candidate_id}); this should be structurally impossible"
        )
    end
  end

  defp existing_sessions(prefix, exam_id, candidate_id) do
    {:ok, query} =
      Compiler.compile(
        %{
          entity_type: "session",
          filters: [
            %{field: "exam_id", op: :eq, value: exam_id},
            %{field: "user_id", op: :eq, value: candidate_id}
          ]
        },
        prefix
      )

    Repo.all(query, prefix: prefix)
  end

  defp start_session_via_http!(prefix, exam_id, token_plaintext) do
    conn =
      conn(:post, "/api/v1/modules/exam/exam-sessions", Jason.encode!(%{"exam_id" => exam_id}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token_plaintext)
      |> put_req_header("x-tenant-slug", @tenant_realm)
      |> dispatch()

    unless conn.status == 201 do
      Mix.raise(
        "mix letflow.seed.exam_fixtures: FAILED -- POST /modules/exam/exam-sessions returned " <>
          "#{conn.status}: #{conn.resp_body}"
      )
    end

    Mix.shell().info(
      "POST /api/v1/modules/exam/exam-sessions (tenant #{prefix}) -> 201: #{conn.resp_body}"
    )

    %{"session" => %{"id" => session_id}} = Jason.decode!(conn.resp_body)
    session_id
  end

  defp submit_session_via_http!(_prefix, session_id, token_plaintext) do
    conn =
      conn(:post, "/api/v1/modules/exam/exam-sessions/#{session_id}/submit")
      |> put_req_header("authorization", "Bearer " <> token_plaintext)
      |> put_req_header("x-tenant-slug", @tenant_realm)
      |> dispatch()

    unless conn.status == 200 do
      Mix.raise(
        "mix letflow.seed.exam_fixtures: FAILED -- POST /modules/exam/exam-sessions/#{session_id}/submit " <>
          "returned #{conn.status}: #{conn.resp_body}"
      )
    end

    Mix.shell().info(
      "POST /api/v1/modules/exam/exam-sessions/#{session_id}/submit -> 200: #{conn.resp_body}"
    )

    conn.resp_body
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  # ---------------------------------------------------------------------
  # Output
  # ---------------------------------------------------------------------

  defp report!(%{
         mixed_exam_id: mixed_exam_id,
         mixed_questions: mixed_questions,
         scoreable_exam_id: scoreable_exam_id,
         scoreable_questions: scoreable_questions,
         session_id: session_id,
         submit_body: submit_body
       }) do
    outcome = Jason.decode!(submit_body)

    Mix.shell().info("""
    mix letflow.seed.exam_fixtures: OK

    Exam 1 (mixed):     #{@mixed_exam_title} (id #{mixed_exam_id})
      questions: #{Enum.map_join(mixed_questions, ", ", fn {id, type} -> "#{id} (#{type})" end)}

    Exam 2 (scoreable): #{@scoreable_exam_title} (id #{scoreable_exam_id}), passing_score_pct #{@scoreable_passing_score_pct}
      questions: #{Enum.map_join(scoreable_questions, ", ", fn {id, type} -> "#{id} (#{type})" end)}

    Session (against exam 1): #{session_id}
      status=#{outcome["status"]} total_score=#{outcome["total_score"]}/#{outcome["total_max_score"]} percentage=#{outcome["percentage"]} passed=#{inspect(outcome["passed"])}
    """)
  end
end
