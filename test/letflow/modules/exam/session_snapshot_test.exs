defmodule Letflow.Modules.Exam.SessionSnapshotTest do
  @moduledoc """
  GH #2682 / REQ-511 PR a, design `lib/letflow/design/req511-exam-content-snapshot.md` sections 4.3,
  5, 7, 12.1, 12.2 and 17.1 (spec `test/specs/GH2682-exam-snapshot-pr-a.md`): the session-level
  behaviour of the exam content snapshot against a real provisioned tenant (DIRECTIVE T-1).

    * AC1 (one test per field class, scoring/autosave/state): T-01 `is_correct`, T-02
      `likert_weight`, T-03 `likert_polarity`, T-04 `passing_score_pct` (plus the carry-forward of
      the snapshot through the submit write), T-05 `question.type` (scoring), T-06 (autosave
      shape), T-07 (state), T-08 exam row archived or deleted, T-12 display-only class, T-13
      option added or deleted, T-14 start-time-only inputs.
    * AC2: T-15..T-19 and T-42: a missing threshold, a missing key item, a tampered snapshot is a
      typed grading error that rolls back and leaves the session `in_progress`, never `60.0`.
    * Prerequisites: T-35 and T-53 (the restriction row or the `session.exam_snapshot` field is
      absent: the start fails closed with a typed 503-class error).
    * Terminal sessions never need a snapshot to be read: T-43, T-45, T-46, T-47.

  The certificate path is PR b; the late (in-flight) snapshot is PR b. In PR a a snapshotless
  `in_progress` session fails closed (`:snapshot_missing`) and is never written.

  Runs against Postgres outside the sandbox transaction (`Letflow.ExamFixtures` switches the
  sandbox to `:auto`): `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.Event
  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.Modules.Exam.Session
  alias Letflow.Modules.Exam.Snapshot

  # ── fixtures ───────────────────────────────────────────────────────────────────────────────

  defp tenant(slug), do: Fx.provisioned_tenant_with_exam_definitions(slug)

  defp create_exam!(schema, attrs) do
    defaults = %{
      "title" => %{"en" => "Snapshot Exam"},
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 10,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => false
    }

    Fx.create_record!(schema, "exam", Map.merge(defaults, attrs))
  end

  defp create_question!(schema, category_id, attrs) do
    defaults = %{
      "category_id" => category_id,
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => "active",
      "version" => 1,
      "stem" => %{"en" => "Stem?"}
    }

    Fx.create_record!(schema, "question", Map.merge(defaults, attrs))
  end

  defp create_option!(schema, question_id, sort_order, is_correct, attrs) do
    defaults = %{
      "question_id" => question_id,
      "sort_order" => sort_order,
      "is_correct" => is_correct,
      "text" => %{"en" => "Option #{sort_order}"}
    }

    Fx.create_record!(schema, "answer_option", Map.merge(defaults, attrs))
  end

  defp create_rule!(schema, exam_id, category_id, count, sort_order, mode) do
    Fx.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam_id,
      "mode" => mode,
      "category_id" => category_id,
      "count" => count,
      "sort_order" => sort_order
    })
  end

  # A question spec is `{type, [{is_correct, option_attrs}]}`.
  defp single_spec, do: {"single", [{true, %{}}, {false, %{}}]}

  defp likert_spec(weights, polarity) do
    {"likert",
     Enum.map(weights, fn weight ->
       {false, %{"likert_weight" => weight, "likert_polarity" => polarity}}
     end)}
  end

  # One exam, one random rule drawing every question of one category. Returns the exam, the
  # category, and per question `%{id, option_ids}` in creation order (option ids in sort order).
  defp build_exam!(schema, specs, exam_attrs) do
    category_id = Ecto.UUID.generate()
    exam = create_exam!(schema, exam_attrs)

    questions =
      for {type, option_specs} <- specs do
        question = create_question!(schema, category_id, %{"type" => type})

        option_ids =
          option_specs
          |> Enum.with_index()
          |> Enum.map(fn {{is_correct, attrs}, index} ->
            create_option!(schema, question.record_id, index, is_correct, attrs).record_id
          end)

        %{id: question.record_id, option_ids: option_ids}
      end

    create_rule!(schema, exam.record_id, category_id, length(specs), 0, "random")
    %{exam: exam, category_id: category_id, questions: questions}
  end

  defp start!(schema, exam_id) do
    candidate = Ecto.UUID.generate()
    assert {:ok, view} = Session.create(candidate, exam_id, schema)
    {candidate, view.id}
  end

  defp answer!(schema, session_id, candidate, question_id, option_ids) do
    assert {:ok, _} =
             Session.autosave_answer(
               session_id,
               candidate,
               %{
                 question_id: question_id,
                 selected_option_ids: option_ids,
                 time_spent_seconds: 0
               },
               schema
             )

    :ok
  end

  defp session_fv(schema, session_id) do
    assert {:ok, row} = Latest.get(session_id, "session", schema)
    row.field_values
  end

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp count(schema, entity_type) do
    Repo.aggregate(from(l in Latest, where: l.entity_type == ^entity_type), :count,
      prefix: schema
    )
  end

  defp score_rows(schema, session_id) do
    Repo.aggregate(
      from(l in Latest,
        where:
          l.entity_type == "session_question_score" and
            fragment("?->>?", l.field_values, "session_id") == ^session_id
      ),
      :count,
      prefix: schema
    )
  end

  # A grading error rolled the whole submit back: nothing scored, still in progress.
  defp assert_not_scored!(schema, session_id) do
    fv = session_fv(schema, session_id)
    assert fv["status"] == "in_progress"
    assert fv["passed"] == false
    refute Map.has_key?(fv, "score_pct")
    refute Map.has_key?(fv, "submitted_at")
    assert score_rows(schema, session_id) == 0
  end

  defp first_state_question(schema, session_id, candidate) do
    assert {:ok, %{questions: [question | _]}} =
             Session.get_session_state_for_user(session_id, candidate, schema)

    question
  end

  defp grading(reason), do: {:error, {:grading_error, reason}}

  # ── the snapshot written at start (design 4.1, 4.3) ────────────────────────────────────────

  describe "start writes the snapshot atomically with the session" do
    test "the stored snapshot carries the exam facts, the resolved order, every type and key, and a digest that verifies" do
      %{schema_name: schema} = tenant("gh2682-start-shape")

      %{exam: exam, questions: [q1, q2]} =
        build_exam!(schema, [single_spec(), likert_spec([1.0, 3.0, 5.0], "positive")], %{
          "passing_score_pct" => 72.5,
          "certificate_enabled" => true,
          "title" => %{"en" => "Keep me"}
        })

      {_candidate, session_id} = start!(schema, exam.record_id)
      fv = session_fv(schema, session_id)
      snapshot = fv["exam_snapshot"]

      assert {:ok, ^snapshot} = Snapshot.fetch_verified(fv)

      assert %{"v" => 1, "origin" => "start"} = snapshot
      assert snapshot["nonce"] =~ ~r/\A[0-9a-f]{32}\z/

      assert {:ok, taken_at, 0} = DateTime.from_iso8601(snapshot["taken_at"])
      assert {:ok, started_at, 0} = DateTime.from_iso8601(fv["started_at"])
      assert abs(DateTime.diff(taken_at, started_at, :second)) <= 1

      assert snapshot["exam"]["exam_id"] == exam.record_id
      assert snapshot["exam"]["passing_score_pct"] == "72.5"
      assert snapshot["exam"]["certificate_enabled"] == true
      assert snapshot["exam"]["title"] == %{"en" => "Keep me"}
      assert snapshot["exam"]["time_limit_minutes"] == 30

      # order == the session_question rows' sort order
      rows =
        Repo.all(
          from(l in Latest,
            where:
              l.entity_type == "session_question" and
                fragment("?->>?", l.field_values, "session_id") == ^session_id
          ),
          prefix: schema
        )
        |> Enum.sort_by(& &1.field_values["sort_order"])
        |> Enum.map(& &1.field_values["question_id"])

      assert snapshot["order"] == rows
      assert Enum.sort(snapshot["order"]) == Enum.sort([q1.id, q2.id])

      single = snapshot["questions"][q1.id]
      assert single["type"] == "single"
      assert single["correct_option_ids"] == [hd(q1.option_ids)]
      assert single["likert_options"] == %{}

      likert = snapshot["questions"][q2.id]
      assert likert["type"] == "likert"
      assert likert["correct_option_ids"] == []

      assert likert["likert_options"] |> Map.values() |> Enum.map(& &1["weight"]) |> Enum.sort() ==
               ["1", "3", "5"]
    end

    test "a manually pinned question is snapshotted too (type from its live row, key from its options)" do
      %{schema_name: schema} = tenant("gh2682-start-pin")
      exam = create_exam!(schema, %{})
      category_id = Ecto.UUID.generate()
      rule = create_rule!(schema, exam.record_id, category_id, 1, 0, "manual")

      pinned = create_question!(schema, Ecto.UUID.generate(), %{"type" => "multiple"})
      a = create_option!(schema, pinned.record_id, 0, true, %{})
      b = create_option!(schema, pinned.record_id, 1, true, %{})
      _c = create_option!(schema, pinned.record_id, 2, false, %{})

      Fx.create_record!(schema, "exam_manual_question", %{
        "rule_id" => rule.record_id,
        "question_id" => pinned.record_id,
        "sort_order" => 0
      })

      {_candidate, session_id} = start!(schema, exam.record_id)
      snapshot = session_fv(schema, session_id)["exam_snapshot"]

      assert snapshot["order"] == [pinned.record_id]

      assert snapshot["questions"][pinned.record_id] == %{
               "type" => "multiple",
               "correct_option_ids" => Enum.sort([a.record_id, b.record_id]),
               "likert_options" => %{}
             }
    end

    test "no candidate-facing return value carries the snapshot, its nonce, its digest or an answer key" do
      %{schema_name: schema} = tenant("gh2682-start-redaction")
      %{exam: exam} = build_exam!(schema, [single_spec()], %{})
      candidate = Ecto.UUID.generate()

      assert {:ok, view} = Session.create(candidate, exam.record_id, schema)
      snapshot = session_fv(schema, view.id)["exam_snapshot"]

      assert {:ok, again} = Session.get_session_for_user(view.id, candidate, schema)
      assert {:ok, state} = Session.get_session_state_for_user(view.id, candidate, schema)

      for value <- [view, again, state] do
        text = inspect(value, limit: :infinity)
        refute text =~ "exam_snapshot"
        refute text =~ snapshot["nonce"]
        refute text =~ snapshot["digest"]
        refute text =~ "correct_option_ids"
      end
    end
  end

  # ── AC1: one test per field class ──────────────────────────────────────────────────────────

  describe "AC1 edits after start" do
    test "T-01 answer_option.is_correct flipped after start: both candidates are scored as at start" do
      %{schema_name: schema} = tenant("gh2682-t01")
      %{exam: exam, questions: [q]} = build_exam!(schema, [single_spec()], %{})
      [correct, wrong] = q.option_ids

      {right_candidate, right_session} = start!(schema, exam.record_id)
      {wrong_candidate, wrong_session} = start!(schema, exam.record_id)
      answer!(schema, right_session, right_candidate, q.id, [correct])
      answer!(schema, wrong_session, wrong_candidate, q.id, [wrong])

      Fx.update_record!(schema, "answer_option", correct, %{"is_correct" => false})
      Fx.update_record!(schema, "answer_option", wrong, %{"is_correct" => true})

      assert {:ok, %{percentage: 100.0, passed: true}} =
               Session.submit(right_session, right_candidate, schema)

      assert {:ok, wrong_outcome} = Session.submit(wrong_session, wrong_candidate, schema)
      assert {wrong_outcome.percentage, wrong_outcome.passed} == {0.0, false}

      assert session_fv(schema, right_session)["score_pct"] == 100.0
      assert session_fv(schema, wrong_session)["score_pct"] == 0.0
    end

    test "T-02 answer_option.likert_weight edited after start: a likert score is as at start" do
      %{schema_name: schema} = tenant("gh2682-t02")

      %{exam: exam, questions: [q]} =
        build_exam!(schema, [likert_spec([1.0, 3.0, 5.0], "positive")], %{})

      [low, mid, high] = q.option_ids

      {top_candidate, top_session} = start!(schema, exam.record_id)
      {bottom_candidate, bottom_session} = start!(schema, exam.record_id)
      answer!(schema, top_session, top_candidate, q.id, [high])
      answer!(schema, bottom_session, bottom_candidate, q.id, [low])

      # reverse the whole scale
      Fx.update_record!(schema, "answer_option", low, %{"likert_weight" => 5.0})
      Fx.update_record!(schema, "answer_option", mid, %{"likert_weight" => 3.0})
      Fx.update_record!(schema, "answer_option", high, %{"likert_weight" => 1.0})

      assert {:ok, %{percentage: 100.0, passed: true}} =
               Session.submit(top_session, top_candidate, schema)

      assert {:ok, bottom} = Session.submit(bottom_session, bottom_candidate, schema)
      assert {bottom.percentage, bottom.passed} == {0.0, false}
    end

    test "T-03 answer_option.likert_polarity flipped after start: a likert score is as at start" do
      %{schema_name: schema} = tenant("gh2682-t03")

      %{exam: exam, questions: [q]} =
        build_exam!(schema, [likert_spec([1.0, 3.0, 5.0], "positive")], %{})

      [low, _mid, high] = q.option_ids

      {top_candidate, top_session} = start!(schema, exam.record_id)
      {bottom_candidate, bottom_session} = start!(schema, exam.record_id)
      answer!(schema, top_session, top_candidate, q.id, [high])
      answer!(schema, bottom_session, bottom_candidate, q.id, [low])

      for option_id <- q.option_ids do
        Fx.update_record!(schema, "answer_option", option_id, %{"likert_polarity" => "negative"})
      end

      assert {:ok, %{percentage: 100.0, passed: true}} =
               Session.submit(top_session, top_candidate, schema)

      assert {:ok, bottom} = Session.submit(bottom_session, bottom_candidate, schema)
      assert {bottom.percentage, bottom.passed} == {0.0, false}
    end

    test "T-04 exam.passing_score_pct edited after start: passed is as at start, and the snapshot survives the submit write byte for byte" do
      %{schema_name: schema} = tenant("gh2682-t04")

      # 50 percent either way (one of two questions answered correctly).
      run = fn start_threshold, edited_threshold ->
        %{exam: exam, questions: [q1, _q2]} =
          build_exam!(schema, [single_spec(), single_spec()], %{
            "passing_score_pct" => start_threshold
          })

        {candidate, session_id} = start!(schema, exam.record_id)
        answer!(schema, session_id, candidate, q1.id, [hd(q1.option_ids)])
        before = session_fv(schema, session_id)["exam_snapshot"]

        Fx.update_record!(schema, "exam", exam.record_id, %{
          "passing_score_pct" => edited_threshold
        })

        assert {:ok, outcome} = Session.submit(session_id, candidate, schema)

        after_fv = session_fv(schema, session_id)
        assert after_fv["status"] == "submitted"
        assert after_fv["score_pct"] == 50.0

        # invariant I-1: the snapshot is carried forward unchanged and still verifies
        assert after_fv["exam_snapshot"] == before
        assert {:ok, ^before} = Snapshot.fetch_verified(after_fv)

        outcome
      end

      # passes at 40, threshold raised to 90 afterwards: still passed
      assert %{percentage: 50.0, passed: true} = run.(40.0, 90.0)
      # fails at 60, threshold lowered to 10 afterwards: still failed
      assert %{percentage: 50.0, passed: false} = run.(60.0, 10.0)
    end

    test "T-05 question.type edited after start: scoring uses the type at start" do
      %{schema_name: schema} = tenant("gh2682-t05")

      %{exam: exam, questions: [q]} =
        build_exam!(schema, [{"multiple", [{true, %{}}, {true, %{}}, {false, %{}}]}], %{})

      {candidate, session_id} = start!(schema, exam.record_id)
      answer!(schema, session_id, candidate, q.id, [hd(q.option_ids)])

      # as a multiple-choice question one of two correct options is 50 percent; live "single"
      # would give 100 percent
      Fx.update_record!(schema, "question", q.id, %{"type" => "single"})

      assert {:ok, %{percentage: 50.0, passed: false}} =
               Session.submit(session_id, candidate, schema)
    end

    test "T-06 question.type edited after start: the autosave shape check still uses the snapshot type" do
      %{schema_name: schema} = tenant("gh2682-t06")
      %{exam: exam, questions: [q]} = build_exam!(schema, [single_spec()], %{})
      {candidate, session_id} = start!(schema, exam.record_id)
      [correct, wrong] = q.option_ids

      Fx.update_record!(schema, "question", q.id, %{"type" => "multiple"})

      # two options for a snapshot-"single" question stays rejected (live "multiple" would accept)
      assert {:error, :answer_shape_invalid} =
               Session.autosave_answer(
                 session_id,
                 candidate,
                 %{
                   question_id: q.id,
                   selected_option_ids: [correct, wrong],
                   time_spent_seconds: 0
                 },
                 schema
               )

      assert {:ok, _} =
               Session.autosave_answer(
                 session_id,
                 candidate,
                 %{question_id: q.id, selected_option_ids: [correct], time_spent_seconds: 0},
                 schema
               )
    end

    test "T-07 question.type edited after start: the state read shows the snapshot type" do
      %{schema_name: schema} = tenant("gh2682-t07")
      %{exam: exam, questions: [q]} = build_exam!(schema, [single_spec()], %{})
      {candidate, session_id} = start!(schema, exam.record_id)

      Fx.update_record!(schema, "question", q.id, %{"type" => "shorttext"})

      question_state = first_state_question(schema, session_id, candidate)
      assert question_state.type == :single
      # a live shorttext type would render no options at all
      assert length(question_state.options) == 2
    end

    test "T-08 the exam row edited and archived, then deleted, after start: scoring still uses the snapshot threshold" do
      %{schema_name: schema} = tenant("gh2682-t08")

      # 50 percent against a threshold of 40 at start: passes. After start the live threshold is
      # raised to 99, which would FAIL this candidate if the live row were read.
      %{exam: exam, questions: [q1, _q2]} =
        build_exam!(schema, [single_spec(), single_spec()], %{"passing_score_pct" => 40.0})

      {first_candidate, first_session} = start!(schema, exam.record_id)
      {second_candidate, second_session} = start!(schema, exam.record_id)
      answer!(schema, first_session, first_candidate, q1.id, [hd(q1.option_ids)])
      answer!(schema, second_session, second_candidate, q1.id, [hd(q1.option_ids)])

      Fx.update_record!(schema, "exam", exam.record_id, %{
        "status" => "archived",
        "passing_score_pct" => 99.0
      })

      assert {:ok, %{status: :submitted, percentage: 50.0, passed: true}} =
               Session.submit(first_session, first_candidate, schema)

      Fx.delete_record!(schema, "exam", exam.record_id)

      assert {:ok, %{status: :submitted, percentage: 50.0, passed: true}} =
               Session.submit(second_session, second_candidate, schema)
    end

    test "T-12 display-only class: a stem and an option text edit are visible live in the state read, the score is unchanged" do
      %{schema_name: schema} = tenant("gh2682-t12")
      %{exam: exam, questions: [q]} = build_exam!(schema, [single_spec()], %{})
      {candidate, session_id} = start!(schema, exam.record_id)
      [correct, _wrong] = q.option_ids
      answer!(schema, session_id, candidate, q.id, [correct])

      Fx.update_record!(schema, "question", q.id, %{"stem" => %{"en" => "Corrected stem"}})

      Fx.update_record!(schema, "answer_option", correct, %{"text" => %{"en" => "Corrected text"}})

      question_state = first_state_question(schema, session_id, candidate)
      assert question_state.stem == %{"en" => "Corrected stem"}

      assert %{text: %{"en" => "Corrected text"}} =
               Enum.find(question_state.options, &(&1.id == correct))

      assert {:ok, %{percentage: 100.0, passed: true}} =
               Session.submit(session_id, candidate, schema)
    end

    test "T-13 an option added after start is ignored by the score; a deleted one changes nothing and nothing crashes" do
      %{schema_name: schema} = tenant("gh2682-t13")

      # ADDED: a multiple-choice question with one correct option. A new correct option added
      # after start would raise the live denominator to two (50 percent for the same answer).
      %{exam: multi_exam, questions: [multi_q]} =
        build_exam!(schema, [{"multiple", [{true, %{}}, {false, %{}}]}], %{})

      {multi_candidate, multi_session} = start!(schema, multi_exam.record_id)
      answer!(schema, multi_session, multi_candidate, multi_q.id, [hd(multi_q.option_ids)])
      added = create_option!(schema, multi_q.id, 9, true, %{})

      question_state = first_state_question(schema, multi_session, multi_candidate)
      refute added.record_id in Enum.map(question_state.options, & &1.id)

      assert {:ok, %{percentage: 100.0, passed: true}} =
               Session.submit(multi_session, multi_candidate, schema)

      # DELETED: the (only) correct option of a single-choice question is deleted after start.
      # (Soft deletion: the live read still sees the row, so this part is a no-crash control that
      # passes on the old code too; the ADDED part above is the discriminating one.)
      %{exam: exam, questions: [q]} = build_exam!(schema, [single_spec()], %{})
      [correct, _wrong] = q.option_ids
      {candidate, session_id} = start!(schema, exam.record_id)
      answer!(schema, session_id, candidate, q.id, [correct])
      Fx.delete_record!(schema, "answer_option", correct)

      assert {:ok, %{percentage: 100.0, passed: true}} =
               Session.submit(session_id, candidate, schema)
    end

    test "T-14 start-time-only inputs edited after start change neither the question set nor the score" do
      %{schema_name: schema} = tenant("gh2682-t14")

      %{exam: exam, category_id: category_id, questions: [q]} =
        build_exam!(schema, [single_spec()], %{})

      {candidate, session_id} = start!(schema, exam.record_id)
      answer!(schema, session_id, candidate, q.id, [hd(q.option_ids)])
      expires_at = session_fv(schema, session_id)["expires_at"]
      snapshot_before = session_fv(schema, session_id)["exam_snapshot"]

      Fx.update_record!(schema, "exam", exam.record_id, %{
        "shuffle_questions" => true,
        "shuffle_options" => true,
        "max_attempts" => 1,
        "time_limit_minutes" => 5,
        "available_until" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -3600, :second))
      })

      extra = create_question!(schema, category_id, %{"type" => "single"})
      create_option!(schema, extra.record_id, 0, true, %{})
      create_option!(schema, extra.record_id, 1, false, %{})

      assert {:ok, %{percentage: 100.0, passed: true}} =
               Session.submit(session_id, candidate, schema)

      fv = session_fv(schema, session_id)
      assert fv["expires_at"] == expires_at
      assert fv["exam_snapshot"] == snapshot_before
      assert score_rows(schema, session_id) == 1
      assert count(schema, "session_question") == 1
    end
  end

  # ── AC2: typed grading errors, never 60.0 ──────────────────────────────────────────────────

  describe "AC2 broken snapshot" do
    setup do
      %{schema_name: schema} = tenant("gh2682-ac2-#{System.unique_integer([:positive])}")
      %{exam: exam, questions: [q]} = build_exam!(schema, [single_spec()], %{})
      {candidate, session_id} = start!(schema, exam.record_id)
      answer!(schema, session_id, candidate, q.id, [hd(q.option_ids)])

      %{schema: schema, exam: exam, q: q, candidate: candidate, session_id: session_id}
    end

    test "T-15 a snapshot whose threshold is absent, or nil, is :threshold_missing (not 60.0, not a crash)",
         ctx do
      for forge <- [
            &update_in(&1, ["exam"], fn exam -> Map.delete(exam, "passing_score_pct") end),
            &put_in(&1, ["exam", "passing_score_pct"], nil)
          ] do
        before = Fx.rewrite_snapshot!(ctx.schema, ctx.session_id, forge)

        assert grading(:threshold_missing) ==
                 Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

        assert grading(:threshold_missing) ==
                 Session.finalize_expired(ctx.session_id, DateTime.utc_now(), ctx.schema)

        assert_not_scored!(ctx.schema, ctx.session_id)
        assert Fx.session_snapshot(ctx.schema, ctx.session_id) == before
      end
    end

    test "T-15 a threshold that is not a valid number in range is :threshold_invalid", ctx do
      for stored <- ["abc", "-1", "101", 60] do
        Fx.rewrite_snapshot!(
          ctx.schema,
          ctx.session_id,
          &put_in(&1, ["exam", "passing_score_pct"], stored)
        )

        assert grading(:threshold_invalid) ==
                 Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

        assert_not_scored!(ctx.schema, ctx.session_id)
      end
    end

    test "T-16 a snapshot with no exam object is :exam_section_missing", ctx do
      Fx.rewrite_snapshot!(ctx.schema, ctx.session_id, &Map.delete(&1, "exam"))

      assert grading(:exam_section_missing) ==
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert_not_scored!(ctx.schema, ctx.session_id)
    end

    test "T-17 an ordered question with no item, an empty key, or a bad type is a typed error naming the question id only",
         ctx do
      unknown = Ecto.UUID.generate()

      Fx.rewrite_snapshot!(
        ctx.schema,
        ctx.session_id,
        &Map.update!(&1, "order", fn o -> o ++ [unknown] end)
      )

      assert grading({:question_item_missing, unknown}) ==
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert_not_scored!(ctx.schema, ctx.session_id)

      Fx.rewrite_snapshot!(
        ctx.schema,
        ctx.session_id,
        &Map.update!(&1, "order", fn o -> Enum.take(o, 1) end)
      )

      Fx.rewrite_snapshot!(
        ctx.schema,
        ctx.session_id,
        &put_in(&1, ["questions", ctx.q.id, "correct_option_ids"], [])
      )

      assert grading({:key_missing, ctx.q.id}) ==
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert_not_scored!(ctx.schema, ctx.session_id)

      Fx.rewrite_snapshot!(
        ctx.schema,
        ctx.session_id,
        &put_in(&1, ["questions", ctx.q.id, "type"], "essay")
      )

      assert grading({:question_type_invalid, ctx.q.id}) ==
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert_not_scored!(ctx.schema, ctx.session_id)
    end

    test "T-18 a content change that leaves the stored digest stale is :snapshot_corrupt; the field is neither repaired nor replaced",
         ctx do
      tampered =
        ctx.schema
        |> Fx.session_snapshot(ctx.session_id)
        |> put_in(["questions", ctx.q.id, "correct_option_ids"], [List.last(ctx.q.option_ids)])

      Fx.update_record!(ctx.schema, "session", ctx.session_id, %{"exam_snapshot" => tampered})

      assert grading(:snapshot_corrupt) ==
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert_not_scored!(ctx.schema, ctx.session_id)
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == tampered
    end

    test "T-18 a snapshot that is not an object is :snapshot_corrupt", ctx do
      for garbage <- ["garbage", 5, ["x"]] do
        Fx.update_record!(ctx.schema, "session", ctx.session_id, %{"exam_snapshot" => garbage})

        assert grading(:snapshot_corrupt) ==
                 Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

        assert_not_scored!(ctx.schema, ctx.session_id)
        assert Fx.session_snapshot(ctx.schema, ctx.session_id) == garbage
      end
    end

    test "an in-progress session with NO snapshot fails closed on submit, autosave and the state read, and nothing is written (PR a has no late path)",
         ctx do
      Fx.force_field!(ctx.schema, "session", ctx.session_id, "exam_snapshot", :delete)
      events = event_count(ctx.schema)

      assert grading(:snapshot_missing) ==
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert grading(:snapshot_missing) ==
               Session.finalize_expired(ctx.session_id, DateTime.utc_now(), ctx.schema)

      assert grading(:snapshot_missing) ==
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate,
                 %{question_id: ctx.q.id, selected_option_ids: [], time_spent_seconds: 0},
                 ctx.schema
               )

      assert grading(:snapshot_missing) ==
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert_not_scored!(ctx.schema, ctx.session_id)
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == nil
      assert event_count(ctx.schema) == events
    end

    test "an autosave or state read against a snapshot whose item for the question is gone is {:question_item_missing, id}, never :question_not_in_session",
         ctx do
      Fx.rewrite_snapshot!(ctx.schema, ctx.session_id, fn snapshot ->
        Map.update!(snapshot, "questions", &Map.delete(&1, ctx.q.id))
      end)

      assert grading({:question_item_missing, ctx.q.id}) ==
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate,
                 %{question_id: ctx.q.id, selected_option_ids: [], time_spent_seconds: 0},
                 ctx.schema
               )

      assert grading({:question_item_missing, ctx.q.id}) ==
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)
    end

    test "ownership comes BEFORE any snapshot read (R6): a non-owner of a snapshotless session gets :not_owner, never a grading error",
         ctx do
      Fx.force_field!(ctx.schema, "session", ctx.session_id, "exam_snapshot", :delete)
      stranger = Ecto.UUID.generate()

      assert {:error, :not_owner} ==
               Session.autosave_answer(
                 ctx.session_id,
                 stranger,
                 %{question_id: ctx.q.id, selected_option_ids: [], time_spent_seconds: 0},
                 ctx.schema
               )

      assert {:error, :not_owner} ==
               Session.get_session_state_for_user(ctx.session_id, stranger, ctx.schema)

      assert {:error, :not_owner} == Session.submit(ctx.session_id, stranger, ctx.schema)
    end
  end

  describe "R6 query-count parity" do
    # Repo queries issued by THIS test process while `fun` runs.
    defp count_queries(fun) do
      counter = :counters.new(1, [])
      handler = "gh2682-parity-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler,
          [:letflow, :repo, :query],
          fn _event, _measurements, _meta, _config ->
            if self() == test_pid, do: :counters.add(counter, 1, 1)
          end,
          nil
        )

      try do
        result = fun.()
        {result, :counters.get(counter, 1)}
      after
        :telemetry.detach(handler)
      end
    end

    test "a non-owner of a snapshotless session costs exactly as many queries as a nonexistent session (autosave, state read, submit)" do
      %{schema_name: schema} = tenant("gh2682-r6-parity")
      %{exam: exam, questions: [q]} = build_exam!(schema, [single_spec()], %{})
      {_owner, session_id} = start!(schema, exam.record_id)
      Fx.force_field!(schema, "session", session_id, "exam_snapshot", :delete)

      stranger = Ecto.UUID.generate()
      missing = Ecto.UUID.generate()
      answer = %{question_id: q.id, selected_option_ids: [], time_spent_seconds: 0}

      calls = [
        {:autosave, fn id -> Session.autosave_answer(id, stranger, answer, schema) end},
        {:state, fn id -> Session.get_session_state_for_user(id, stranger, schema) end},
        {:submit, fn id -> Session.submit(id, stranger, schema) end}
      ]

      for {name, call} <- calls do
        {real_result, real_queries} = count_queries(fn -> call.(session_id) end)
        {missing_result, missing_queries} = count_queries(fn -> call.(missing) end)

        # both are plain not-found-class errors (no grading error, no 503), at the same cost
        assert {name, real_result} == {name, {:error, :not_owner}}
        assert {name, missing_result} == {name, {:error, :session_not_found}}
        assert {name, real_queries} == {name, missing_queries}
        assert {name, real_queries > 0} == {name, true}
      end
    end
  end

  describe "T-19 the old fallback is gone" do
    test "session.ex has no 60.0 literal, no passing_threshold_for, and no live scoring-input builder" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/modules/exam/session.ex"))

      refute source =~ "60.0"
      refute source =~ "passing_threshold_for"
      refute source =~ "build_scoring_inputs"
      refute source =~ "build_question_row"
      refute source =~ "fetch_question_for_autosave"
    end
  end

  # ── T-42: a broken authoring row fails the START ───────────────────────────────────────────

  describe "T-42 broken authoring row" do
    defp assert_nothing_created!(schema) do
      assert count(schema, "session") == 0
      assert count(schema, "session_question") == 0
    end

    test "a live exam threshold that is nil, missing, out of range or not a number" do
      %{schema_name: schema} = tenant("gh2682-t42-threshold")

      for {change, reason} <- [
            {{:put, nil}, :threshold_missing},
            {:delete, :threshold_missing},
            {{:put, 150}, :threshold_invalid},
            {{:put, -5}, :threshold_invalid},
            {{:put, "abc"}, :threshold_invalid}
          ] do
        %{exam: exam} = build_exam!(schema, [single_spec()], %{})
        Fx.force_field!(schema, "exam", exam.record_id, "passing_score_pct", change)

        assert {change, Session.create(Ecto.UUID.generate(), exam.record_id, schema)} ==
                 {change, grading(reason)}

        assert_nothing_created!(schema)
      end
    end

    test "a question with no correct option, a likert option without a weight, and a question type outside the five" do
      %{schema_name: schema} = tenant("gh2682-t42-items")

      %{exam: single_exam, questions: [single_q]} =
        build_exam!(schema, [{"single", [{false, %{}}, {false, %{}}]}], %{})

      assert grading({:key_missing, single_q.id}) ==
               Session.create(Ecto.UUID.generate(), single_exam.record_id, schema)

      assert_nothing_created!(schema)

      %{exam: likert_exam, questions: [likert_q]} =
        build_exam!(schema, [likert_spec([1, 2], "positive")], %{})

      Fx.force_field!(schema, "answer_option", hd(likert_q.option_ids), "likert_weight", :delete)

      assert grading({:key_missing, likert_q.id}) ==
               Session.create(Ecto.UUID.generate(), likert_exam.record_id, schema)

      assert_nothing_created!(schema)

      %{exam: typed_exam, questions: [typed_q]} = build_exam!(schema, [single_spec()], %{})
      Fx.force_field!(schema, "question", typed_q.id, "type", {:put, "essay"})

      assert grading({:question_type_invalid, typed_q.id}) ==
               Session.create(Ecto.UUID.generate(), typed_exam.record_id, schema)

      assert_nothing_created!(schema)
    end

    test "a likert question with a complete scale and no correct option, and a shorttext question with no options, still start" do
      %{schema_name: schema} = tenant("gh2682-t42-valid")

      %{exam: exam} =
        build_exam!(schema, [likert_spec([1.0, 3.0, 5.0], "positive"), {"shorttext", []}], %{})

      {_candidate, session_id} = start!(schema, exam.record_id)
      assert %{"origin" => "start"} = session_fv(schema, session_id)["exam_snapshot"]
    end

    test "a manual pin whose question is missing, not active, or not a UUID fails the start with {:question_not_found, id}" do
      %{schema_name: schema} = tenant("gh2682-t42-pins")

      archived = create_question!(schema, Ecto.UUID.generate(), %{"status" => "archived"})
      create_option!(schema, archived.record_id, 0, true, %{})

      draft = create_question!(schema, Ecto.UUID.generate(), %{"status" => "draft"})
      create_option!(schema, draft.record_id, 0, true, %{})

      for pinned_id <- [
            Ecto.UUID.generate(),
            archived.record_id,
            draft.record_id,
            "not-a-uuid"
          ] do
        exam = create_exam!(schema, %{})
        rule = create_rule!(schema, exam.record_id, Ecto.UUID.generate(), 1, 0, "manual")

        Fx.create_record!(schema, "exam_manual_question", %{
          "rule_id" => rule.record_id,
          "question_id" => pinned_id,
          "sort_order" => 0
        })

        assert {pinned_id, Session.create(Ecto.UUID.generate(), exam.record_id, schema)} ==
                 {pinned_id, {:error, {:question_not_found, pinned_id}}}

        assert_nothing_created!(schema)
      end
    end
  end

  # ── prerequisites: T-35, T-53 ──────────────────────────────────────────────────────────────

  describe "start fails closed when the tenant is not rolled out" do
    test "T-53 the active session definition lacks exam_snapshot: {:snapshot_error, :definition_missing}, no rows" do
      %{schema_name: schema} = tenant("gh2682-t53")
      %{exam: exam} = build_exam!(schema, [single_spec()], %{})
      Fx.downgrade_session_definition!(schema)

      assert {:error, {:snapshot_error, :definition_missing}} ==
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      assert_nothing_created!(schema)
    end

    test "T-35 the session.exam_snapshot restriction row is absent: {:snapshot_error, :restrictions_missing}, no rows" do
      %{schema_name: schema} = tenant("gh2682-t35")
      %{exam: exam} = build_exam!(schema, [single_spec()], %{})

      {deleted, _} =
        Repo.delete_all(
          from(r in "entity_field_restrictions",
            where: r.entity_type == "session" and r.field_name == "exam_snapshot"
          ),
          prefix: schema
        )

      assert deleted == 1

      assert {:error, {:snapshot_error, :restrictions_missing}} ==
               Session.create(Ecto.UUID.generate(), exam.record_id, schema)

      assert_nothing_created!(schema)
    end
  end

  # ── terminal sessions never need a snapshot (design 17.1): T-43, T-45, T-46, T-47 ─────────

  describe "terminal sessions" do
    # A real session driven to `status`, returned with the question it holds.
    defp terminal_session!(schema, status) do
      {specs, exam_attrs} =
        case status do
          :grading_pending -> {[{"shorttext", []}], %{}}
          _other -> {[single_spec()], %{}}
        end

      %{exam: exam, questions: [q]} = build_exam!(schema, specs, exam_attrs)
      {candidate, session_id} = start!(schema, exam.record_id)

      case status do
        :auto_submitted ->
          assert {:ok, %{status: :auto_submitted}} =
                   Session.finalize_expired(session_id, DateTime.utc_now(), schema)

        _submit ->
          assert {:ok, %{status: ^status}} = Session.submit(session_id, candidate, schema)
      end

      %{candidate: candidate, session_id: session_id, q: q}
    end

    test "T-43 a legacy terminal session without a snapshot: the state read succeeds with the LIVE type, writes nothing" do
      for status <- [:submitted, :auto_submitted, :grading_pending] do
        %{schema_name: schema} = tenant("gh2682-t43-#{status}")
        %{candidate: candidate, session_id: session_id, q: q} = terminal_session!(schema, status)
        Fx.force_field!(schema, "session", session_id, "exam_snapshot", :delete)

        # an edit that only a LIVE read can show
        live_type = if status == :grading_pending, do: "single", else: "multiple"
        Fx.update_record!(schema, "question", q.id, %{"type" => live_type})
        events = event_count(schema)

        expected = if status == :grading_pending, do: :single, else: :multiple
        assert first_state_question(schema, session_id, candidate).type == expected

        assert event_count(schema) == events
        assert Fx.session_snapshot(schema, session_id) == nil
      end
    end

    test "T-45 a terminal session with a corrupt snapshot: the state read succeeds with the live type" do
      %{schema_name: schema} = tenant("gh2682-t45")

      %{candidate: candidate, session_id: session_id, q: q} =
        terminal_session!(schema, :submitted)

      Fx.update_record!(schema, "session", session_id, %{"exam_snapshot" => "garbage"})
      Fx.update_record!(schema, "question", q.id, %{"type" => "multiple"})

      assert first_state_question(schema, session_id, candidate).type == :multiple
      assert Fx.session_snapshot(schema, session_id) == "garbage"
    end

    test "T-46 a terminal snapshotless session is never snapshotted: not by a state read, an autosave attempt, a submit replay or a finalize replay" do
      %{schema_name: schema} = tenant("gh2682-t46")

      %{candidate: candidate, session_id: session_id, q: q} =
        terminal_session!(schema, :submitted)

      Fx.force_field!(schema, "session", session_id, "exam_snapshot", :delete)
      recorded = session_fv(schema, session_id)
      events = event_count(schema)

      assert {:ok, _state} = Session.get_session_state_for_user(session_id, candidate, schema)

      assert {:error, :session_not_in_progress} ==
               Session.autosave_answer(
                 session_id,
                 candidate,
                 %{question_id: q.id, selected_option_ids: [], time_spent_seconds: 0},
                 schema
               )

      assert {:ok, %{status: :submitted, percentage: percentage}} =
               Session.submit(session_id, candidate, schema)

      assert percentage == recorded["score_pct"]

      assert {:ok, %{status: :submitted}} =
               Session.finalize_expired(session_id, DateTime.utc_now(), schema)

      assert Fx.session_snapshot(schema, session_id) == nil
      assert session_fv(schema, session_id) == recorded
      assert event_count(schema) == events
    end

    test "T-47 a terminal session WITH a snapshot shows the snapshot type after a live type edit" do
      %{schema_name: schema} = tenant("gh2682-t47")

      %{candidate: candidate, session_id: session_id, q: q} =
        terminal_session!(schema, :submitted)

      Fx.update_record!(schema, "question", q.id, %{"type" => "multiple"})

      assert first_state_question(schema, session_id, candidate).type == :single
    end
  end
end
