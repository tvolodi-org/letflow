defmodule Letflow.Modules.Exam.CertificateTest do
  @moduledoc """
  REQ-355 -- unit coverage for `Letflow.Modules.Exam.Certificate` against a real
  provisioned tenant (`Letflow.ExamFixtures`), no mocked database, mirroring
  `test/letflow/exam/session_test.exs`'s own fixture conventions. HTTP-level
  route wiring (auth, 404/409 status mapping) lives in
  `test/letflow/routers/exam_sessions_test.exs`'s own "REQ-355" describe
  block -- this file exercises the context module directly so every guard
  and the idempotency/branding-snapshot guarantees are provable without an
  HTTP round trip in the way.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Exam.Certificate
  alias Letflow.Modules.Exam.Session
  alias Letflow.ExamFixtures
  alias Letflow.Identity
  alias Letflow.Identity.Tenant

  defp tenant(slug), do: ExamFixtures.provisioned_tenant_with_exam_definitions(slug)

  defp create_exam!(schema, attrs) do
    defaults = %{
      "title" => %{"en" => "Certificate Exam"},
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 5,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => true
    }

    ExamFixtures.create_record!(schema, "exam", Map.merge(defaults, attrs))
  end

  defp create_question!(schema, category_id, attrs \\ %{}) do
    defaults = %{
      "category_id" => category_id,
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => "active",
      "version" => 1,
      "stem" => %{"en" => "Stem?"}
    }

    ExamFixtures.create_record!(schema, "question", Map.merge(defaults, attrs))
  end

  defp create_option!(schema, question_id, sort_order, is_correct, attrs \\ %{}) do
    defaults = %{
      "question_id" => question_id,
      "sort_order" => sort_order,
      "is_correct" => is_correct,
      "text" => %{"en" => "Option #{sort_order}"}
    }

    ExamFixtures.create_record!(schema, "answer_option", Map.merge(defaults, attrs))
  end

  defp create_rule!(schema, exam_id, category_id, count, sort_order \\ 0) do
    ExamFixtures.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => count,
      "sort_order" => sort_order
    })
  end

  # One exam, one single-choice question with a correct and a wrong option.
  defp build_minimal_exam!(schema, exam_attrs \\ %{}) do
    category_id = Ecto.UUID.generate()
    exam = create_exam!(schema, exam_attrs)
    question = create_question!(schema, category_id)
    correct = create_option!(schema, question.record_id, 0, true)
    wrong = create_option!(schema, question.record_id, 1, false)
    create_rule!(schema, exam.record_id, category_id, 1)

    %{
      exam: exam,
      question_id: question.record_id,
      correct_id: correct.record_id,
      wrong_id: wrong.record_id
    }
  end

  defp insert_candidate!(schema, display_name \\ "REQ-355 Candidate") do
    %Identity.User{}
    |> Ecto.Changeset.change(%{
      username: "req355-user-#{Ecto.UUID.generate()}",
      display_name: display_name,
      email: "req355-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  # Starts a session, answers the single-choice question correctly, submits
  # it, and asserts it landed :submitted/passed: true -- the eligible
  # baseline every guard test below starts from unless it deliberately
  # breaks one precondition.
  defp submitted_passed_session!(schema, candidate_id, exam, question_id, correct_id) do
    assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

    assert {:ok, _} =
             Session.autosave_answer(
               session_view.id,
               candidate_id,
               %{
                 question_id: question_id,
                 selected_option_ids: [correct_id],
                 time_spent_seconds: 5
               },
               schema
             )

    assert {:ok, %{status: :submitted, passed: true}} =
             Session.submit(session_view.id, candidate_id, schema)

    session_view.id
  end

  # ---------------------------------------------------------------------
  # AC: the entity definition installs/activates against a real tenant.
  # ---------------------------------------------------------------------

  describe "certificate entity definition" do
    test "activates successfully against a real provisioned tenant, definition present and active" do
      %{schema_name: schema} = tenant("req355-entity-install")

      assert {:ok, %Letflow.Entities.EntityDefinition{name: "certificate", status: :active}} =
               Letflow.Entities.Definitions.get_active_definition_by_name("certificate", schema)
    end
  end

  # ---------------------------------------------------------------------
  # AC: each guard refuses separately, naming which guard fired.
  # ---------------------------------------------------------------------

  describe "issue_or_get_for_user/3 guards" do
    test "session not submitted (still :in_progress) -> :session_not_submitted" do
      %{schema_name: schema} = tenant("req355-guard-not-submitted")
      %{exam: exam} = build_minimal_exam!(schema)
      candidate_id = Ecto.UUID.generate()
      insert_candidate!(schema)

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:error, :session_not_submitted} =
               Certificate.issue_or_get_for_user(candidate_id, session_view.id, schema)
    end

    test "exam certificate_enabled: false -> :exam_not_certifiable, distinct from :session_not_passed" do
      %{schema_name: schema} = tenant("req355-guard-not-certifiable")

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(schema, %{"certificate_enabled" => false})

      candidate_id = insert_candidate!(schema).id
      session_id = submitted_passed_session!(schema, candidate_id, exam, question_id, correct_id)

      assert {:error, :exam_not_certifiable} =
               Certificate.issue_or_get_for_user(candidate_id, session_id, schema)
    end

    test "session passed: false -> :session_not_passed" do
      %{schema_name: schema} = tenant("req355-guard-not-passed")
      %{exam: exam, question_id: question_id, wrong_id: wrong_id} = build_minimal_exam!(schema)
      candidate_id = insert_candidate!(schema).id

      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:ok, _} =
               Session.autosave_answer(
                 session_view.id,
                 candidate_id,
                 %{
                   question_id: question_id,
                   selected_option_ids: [wrong_id],
                   time_spent_seconds: 5
                 },
                 schema
               )

      assert {:ok, %{status: :submitted, passed: false}} =
               Session.submit(session_view.id, candidate_id, schema)

      assert {:error, :session_not_passed} =
               Certificate.issue_or_get_for_user(candidate_id, session_view.id, schema)
    end

    test "a grading_pending session (short_text question) is refused with an error DISTINCT from :session_not_passed" do
      %{schema_name: schema} = tenant("req355-guard-grading-pending")
      category_id = Ecto.UUID.generate()
      exam = create_exam!(schema, %{})
      short_text_question = create_question!(schema, category_id, %{"type" => "shorttext"})
      create_rule!(schema, exam.record_id, category_id, 1)

      candidate_id = insert_candidate!(schema).id
      assert {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)

      assert {:ok, %{status: :grading_pending, passed: nil}} =
               Session.submit(session_view.id, candidate_id, schema)

      grading_pending_result =
        Certificate.issue_or_get_for_user(candidate_id, session_view.id, schema)

      assert {:error, :grading_pending} = grading_pending_result
      assert grading_pending_result != {:error, :session_not_passed}

      _ = short_text_question
    end

    test "a candidate cannot issue or fetch a certificate for another user's session (:not_owner)" do
      %{schema_name: schema} = tenant("req355-guard-ownership")

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(schema)

      owner_id = insert_candidate!(schema).id
      other_id = insert_candidate!(schema).id

      session_id = submitted_passed_session!(schema, owner_id, exam, question_id, correct_id)

      assert {:error, :not_owner} =
               Certificate.issue_or_get_for_user(other_id, session_id, schema)
    end

    test "a nonexistent session_id -> :session_not_found" do
      %{schema_name: schema} = tenant("req355-guard-not-found")

      assert {:error, :session_not_found} =
               Certificate.issue_or_get_for_user(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 schema
               )
    end
  end

  # ---------------------------------------------------------------------
  # AC: issuing twice yields exactly one record, the same record both times.
  # ---------------------------------------------------------------------

  describe "idempotency" do
    test "issuing twice for the same session yields exactly one certificate record, identical both times" do
      %{schema_name: schema} = tenant("req355-idempotent")

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(schema)

      candidate_id = insert_candidate!(schema).id
      session_id = submitted_passed_session!(schema, candidate_id, exam, question_id, correct_id)

      assert {:ok, first} = Certificate.issue_or_get_for_user(candidate_id, session_id, schema)
      assert {:ok, second} = Certificate.issue_or_get_for_user(candidate_id, session_id, schema)

      # REQ-357: `first_issuance`/`public_read_resource_id` are internal
      # wiring fields that legitimately DIFFER between the create call and
      # the idempotent-replay call (the replay path decodes the original
      # event's payload, which never carried the entity_record_latest row's
      # own primary key -- see Letflow.Entities.Records.duplicate_result/1)
      # -- everything else about the certificate itself must still be
      # byte-identical.
      assert first.first_issuance == true
      assert second.first_issuance == false

      assert Map.drop(first, [:first_issuance, :public_read_resource_id]) ==
               Map.drop(second, [:first_issuance, :public_read_resource_id])

      assert {:ok, records} =
               Letflow.Entities.Query.Compiler.compile(
                 %{
                   entity_type: "certificate",
                   filters: [%{field: "session_id", op: :eq, value: session_id}]
                 },
                 schema,
                 :all
               )
               |> then(fn {:ok, query} -> {:ok, Repo.all(query, prefix: schema)} end)

      assert length(records) == 1
      assert %Latest{record_id: record_id} = hd(records)
      assert record_id == first.id
    end
  end

  # ---------------------------------------------------------------------
  # AC: the branding snapshot is captured at first issuance and never
  # re-derived from live branding afterward.
  # ---------------------------------------------------------------------

  describe "branding snapshot" do
    test "a branding change after issuance does not alter the already-issued certificate" do
      %{tenant_id: tenant_id, schema_name: schema} = tenant("req355-branding-snapshot")

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(schema)

      candidate_id = insert_candidate!(schema).id
      session_id = submitted_passed_session!(schema, candidate_id, exam, question_id, correct_id)

      original_tenant = Repo.get(Tenant, tenant_id)

      assert {:ok, _changed} =
               original_tenant
               |> Tenant.settings_changeset(%{
                 settings: %{
                   "app_name" => "Original Co",
                   "logo_url" => nil,
                   "brand_colors" => %{"primary" => "#111111"}
                 }
               })
               |> Repo.update()

      assert {:ok, issued} = Certificate.issue_or_get_for_user(candidate_id, session_id, schema)
      assert issued.branding_snapshot["app_name"] == "Original Co"

      # Mutate branding AFTER issuance.
      # #ffffff would now fail REQ-382's WCAG AA contrast check against the
      # near-white page/card background -- #1864AB (a dark blue) is used
      # instead so this changeset still succeeds; the test only cares that
      # branding changed to a DIFFERENT value after issuance, not this
      # specific one.
      assert {:ok, _changed_again} =
               Repo.get(Tenant, tenant_id)
               |> Tenant.settings_changeset(%{
                 settings: %{
                   "app_name" => "Rebranded Co",
                   "logo_url" => nil,
                   "brand_colors" => %{"primary" => "#1864AB"}
                 }
               })
               |> Repo.update()

      # Re-fetch the SAME certificate via the idempotent-replay path.
      assert {:ok, reread} = Certificate.issue_or_get_for_user(candidate_id, session_id, schema)

      assert reread.branding_snapshot["app_name"] == "Original Co"

      # REQ-357: see the idempotency test's own note -- `first_issuance`/
      # `public_read_resource_id` legitimately differ between the create
      # call and the idempotent-replay call; everything else must match.
      assert reread.first_issuance == false
      assert issued.first_issuance == true

      assert Map.drop(reread, [:first_issuance, :public_read_resource_id]) ==
               Map.drop(issued, [:first_issuance, :public_read_resource_id])
    end
  end
end
