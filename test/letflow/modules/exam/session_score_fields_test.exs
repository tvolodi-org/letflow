defmodule Letflow.Modules.Exam.SessionScoreFieldsTest do
  @moduledoc """
  REQ-594 part B (GH #3350, T-0750), test A-write-5: a tenant whose ACTIVE `session_question_score`
  definition is the previous shape (no `exam_id`, no `correct`) can still submit, and its score rows
  keep today's shape. Records are validated against the active definition with
  additionalProperties: false, so writing the new keys there would reject every score row.

  `async: false`: `Fx.legacy_tenant!/1` switches the sandbox to `:auto` (definitions are swapped
  outside a transaction), which session_test.exs's sandbox mode does not host.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Record.Latest
  alias Letflow.ExamFixtures
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Modules.Exam.Session

  defp previous_score_definition do
    "session_question_score"
    |> Fx.legacy_definition()
    |> Map.update!(:fields, fn fields ->
      Enum.reject(fields, &(&1.name in ["exam_id", "correct"]))
    end)
  end

  test "A-write-5: a previous-shape tenant submits and its score rows carry neither new key" do
    %{schema_name: schema} = Fx.legacy_tenant!("req594-oldshape")
    %{exam: exam, question_id: question_id, correct_id: correct_id} = Fx.build_exam!(schema)
    candidate = Fx.insert_user!(schema)

    # REQ-582: the start check is enforced, so the exam is assigned to everyone.
    ExamFixtures.ensure_assignment_definition_active!(schema)
    ExamFixtures.assign_all!(schema, exam.record_id)

    Fx.create_definition!(schema, previous_score_definition())
    :ok = Fx.activate!(schema, "session_question_score")

    # Precondition: the swap took effect, otherwise the test would check nothing.
    assert {:ok, %{definition_json: %{"fields" => fields}}} =
             Definitions.get_active_definition_by_name("session_question_score", schema)

    names = Enum.map(fields, & &1["name"])
    refute "exam_id" in names
    refute "correct" in names

    assert {:ok, view} = Session.create(candidate.id, exam.record_id, schema)

    assert {:ok, _} =
             Session.autosave_answer(
               view.id,
               candidate.id,
               %{
                 question_id: question_id,
                 selected_option_ids: [correct_id],
                 time_spent_seconds: 1
               },
               schema
             )

    assert {:ok, %{status: :submitted}} = Session.submit(view.id, candidate.id, schema)

    rows =
      Repo.all(
        from(r in Latest,
          where:
            r.entity_type == "session_question_score" and
              fragment("?->>?", r.field_values, "session_id") == ^view.id
        ),
        prefix: schema
      )

    assert [%{field_values: fv}] = rows
    assert fv["grading_status"] == "graded"
    refute Map.has_key?(fv, "exam_id")
    refute Map.has_key?(fv, "correct")
  end
end
