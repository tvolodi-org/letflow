defmodule Letflow.Modules.Exam.ScoringTest do
  @moduledoc """
  REQ-332 -- pure unit tests for `Letflow.Modules.Exam.Scoring`. No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Exam.Scoring

  describe "single / true_false" do
    test "single correct scores 1.0" do
      question = %{question_id: "q1", type: :single, correct_option_ids: ["a"]}
      answer = %{selected_option_ids: ["a"]}

      assert {:ok, %{score: 1.0, max_score: 1.0, grading_status: :graded}} =
               Scoring.score_question(question, answer)
    end

    test "single incorrect scores 0.0" do
      question = %{question_id: "q1", type: :single, correct_option_ids: ["a"]}
      answer = %{selected_option_ids: ["b"]}
      assert {:ok, %{score: score}} = Scoring.score_question(question, answer)
      assert score == 0.0
    end

    test "true_false correct scores 1.0" do
      question = %{question_id: "q2", type: :true_false, correct_option_ids: ["true_opt"]}
      answer = %{selected_option_ids: ["true_opt"]}
      assert {:ok, %{score: 1.0}} = Scoring.score_question(question, answer)
    end
  end

  describe "multiple-choice partial credit" do
    test "strictly between 0 and 1: two correct, one incorrect, of three total correct" do
      question = %{question_id: "q3", type: :multiple, correct_option_ids: ["a", "b", "c"]}
      # correct_selected=2, incorrect_selected=1 -> max(0, 2-1)/3 = 1/3
      answer = %{selected_option_ids: ["a", "b", "x"]}
      assert {:ok, %{score: score}} = Scoring.score_question(question, answer)
      assert_in_delta score, 1 / 3, 0.0001
      assert score > 0.0 and score < 1.0
    end

    test "clamped at 0 when incorrect selections exceed correct ones" do
      question = %{question_id: "q4", type: :multiple, correct_option_ids: ["a", "b"]}
      answer = %{selected_option_ids: ["x", "y", "z"]}
      assert {:ok, %{score: score}} = Scoring.score_question(question, answer)
      assert score == 0.0
    end

    test "all correct selected scores 1.0" do
      question = %{question_id: "q5", type: :multiple, correct_option_ids: ["a", "b"]}
      answer = %{selected_option_ids: ["a", "b"]}
      assert {:ok, %{score: 1.0}} = Scoring.score_question(question, answer)
    end
  end

  describe "likert -- both polarities" do
    test "positive polarity: higher raw weight normalises higher" do
      question = %{
        question_id: "q6",
        type: :likert,
        likert_options: %{
          "low" => %{weight: 1.0, polarity: :positive},
          "high" => %{weight: 5.0, polarity: :positive}
        }
      }

      assert {:ok, %{score: 1.0}} =
               Scoring.score_question(question, %{selected_option_ids: ["high"]})

      assert {:ok, %{score: low_score}} =
               Scoring.score_question(question, %{selected_option_ids: ["low"]})

      assert low_score == 0.0
    end

    test "negative polarity: lower raw weight normalises higher (inverted)" do
      question = %{
        question_id: "q7",
        type: :likert,
        likert_options: %{
          "low" => %{weight: 1.0, polarity: :negative},
          "high" => %{weight: 5.0, polarity: :negative}
        }
      }

      assert {:ok, %{score: 1.0}} =
               Scoring.score_question(question, %{selected_option_ids: ["low"]})

      assert {:ok, %{score: high_score}} =
               Scoring.score_question(question, %{selected_option_ids: ["high"]})

      assert high_score == 0.0
    end
  end

  describe "short_text" do
    test "always scores 0 with pending_manual, regardless of answer" do
      question = %{question_id: "q8", type: :short_text}

      assert {:ok, %{score: score1, max_score: 1.0, grading_status: :pending_manual}} =
               Scoring.score_question(question, %{selected_option_ids: []})

      assert score1 == 0.0

      assert {:ok, %{score: score2, grading_status: :pending_manual}} =
               Scoring.score_question(question, nil)

      assert score2 == 0.0
    end

    # ISS-0650: before this fix, `Letflow.Modules.Exam.Session.upsert_answer/6`
    # never wrote `text_answer` anywhere, so no caller of
    # `score_question/2` could ever observe anything but a hardcoded `nil`
    # for it -- there was nothing for a human grader to grade. This proves
    # the candidate's actual submitted text now flows all the way into the
    # `:pending_manual` result, not just that scoring numerically ignores
    # it.
    test "the candidate's actual text_answer is carried into the pending_manual result, not a hardcoded nil" do
      question = %{question_id: "q8", type: :short_text}

      assert {:ok, %{grading_status: :pending_manual, text_answer: "Paris is the capital."}} =
               Scoring.score_question(question, %{
                 selected_option_ids: [],
                 text_answer: "Paris is the capital."
               })
    end

    test "an unanswered short_text question carries text_answer: nil, not a crash" do
      question = %{question_id: "q8", type: :short_text}

      assert {:ok, %{grading_status: :pending_manual, text_answer: nil}} =
               Scoring.score_question(question, nil)

      assert {:ok, %{grading_status: :pending_manual, text_answer: nil}} =
               Scoring.score_question(question, %{selected_option_ids: []})
    end

    test "score_session/3 threads text_answer through for a short_text question inside a full session" do
      question = %{question_id: "q1", type: :short_text}
      answers = %{"q1" => %{selected_option_ids: [], text_answer: "my real answer"}}

      assert {:ok, %{per_question: [scored]}} = Scoring.score_session([question], answers, 60.0)
      assert scored.text_answer == "my real answer"
      assert scored.grading_status == :pending_manual
    end
  end

  describe "unanswered = wrong, not skipped" do
    test "a nil answer to a single-choice question scores 0, not an error and not omitted" do
      question = %{question_id: "q9", type: :single, correct_option_ids: ["a"]}

      assert {:ok, %{score: score, grading_status: :graded}} =
               Scoring.score_question(question, nil)

      assert score == 0.0

      # This is the Elixir-side equivalent of grading.go's LEFT JOIN against
      # the answers table: an absent answer becomes an empty selection, not
      # a skipped question -- score_session/3 below proves the same holds
      # end-to-end through the full-outer-join answers map.
      {:ok, %{per_question: [scored], outcome: outcome}} =
        Scoring.score_session([question], %{}, 60.0)

      assert scored.score == 0.0
      assert outcome.total_score == 0.0
      assert outcome.total_max_score == 1.0
    end
  end

  describe "no correct option is an error, not a zero (grading.go AC-10)" do
    test "single/true_false/multiple with empty correct_option_ids raises an error, never a zero" do
      for type <- [:single, :true_false, :multiple] do
        question = %{question_id: "qerr", type: type, correct_option_ids: []}

        assert {:error, :question_without_correct_option} =
                 Scoring.score_question(question, %{selected_option_ids: ["whatever"]})
      end
    end

    test "score_session/3 propagates the error for the whole session, not a per-question zero" do
      bad_question = %{question_id: "qbad", type: :single, correct_option_ids: []}

      assert {:error, :question_without_correct_option} =
               Scoring.score_session([bad_question], %{}, 60.0)
    end
  end

  describe "session totals and grading_pending" do
    test "any short_text question lands the session in grading_pending, not submitted" do
      q1 = %{question_id: "q1", type: :single, correct_option_ids: ["a"]}
      q2 = %{question_id: "q2", type: :short_text}

      answers = %{"q1" => %{selected_option_ids: ["a"]}}

      assert {:ok, %{outcome: outcome}} = Scoring.score_session([q1, q2], answers, 60.0)
      assert outcome.status == :grading_pending
      assert outcome.passed == nil
    end

    test "an all-objective session is submitted, with passed derived from the passing threshold" do
      q1 = %{question_id: "q1", type: :single, correct_option_ids: ["a"]}
      q2 = %{question_id: "q2", type: :single, correct_option_ids: ["b"]}

      passing_answers = %{
        "q1" => %{selected_option_ids: ["a"]},
        "q2" => %{selected_option_ids: ["b"]}
      }

      assert {:ok, %{outcome: outcome}} = Scoring.score_session([q1, q2], passing_answers, 60.0)
      assert outcome.status == :submitted
      assert outcome.percentage == 100.0
      assert outcome.passed == true

      failing_answers = %{"q1" => %{selected_option_ids: ["x"]}}

      assert {:ok, %{outcome: failing_outcome}} =
               Scoring.score_session([q1, q2], failing_answers, 60.0)

      assert failing_outcome.percentage == 0.0
      assert failing_outcome.passed == false
    end
  end
end
