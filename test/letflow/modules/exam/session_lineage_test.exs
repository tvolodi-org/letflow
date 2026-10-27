defmodule Letflow.Modules.Exam.SessionLineageTest do
  @moduledoc """
  REQ-586 part B (GH #3315), criterion 7: a session never draws two versions of one question
  lineage. `Session.fetch_pool_questions/2` (rule pool, `status == "active"`) and
  `Session.fetch_pinned_question_row/2` (manual pin, `status == "active"`) are private, so S1/S2
  go through `Session.create/3`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.ExamFixtures
  alias Letflow.Modules.Exam.Session

  defp question!(schema, category_id, parent_id, version, status) do
    base = %{
      "category_id" => category_id,
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => status,
      "version" => version,
      "stem" => %{"en" => "Stem?"}
    }

    fv = if parent_id, do: Map.put(base, "parent_id", parent_id), else: base
    q = ExamFixtures.create_record!(schema, "question", fv)

    for {order, correct} <- [{0, true}, {1, false}] do
      ExamFixtures.create_record!(schema, "answer_option", %{
        "question_id" => q.record_id,
        "sort_order" => order,
        "is_correct" => correct,
        "text" => %{"en" => "Option #{order}"}
      })
    end

    q.record_id
  end

  defp exam!(schema) do
    exam =
      ExamFixtures.create_record!(schema, "exam", %{
        "title" => %{"en" => "Exam"},
        "status" => "active",
        "time_limit_minutes" => 30,
        "passing_score_pct" => 60.0,
        "max_attempts" => 1,
        "shuffle_questions" => false,
        "shuffle_options" => false,
        "show_answers" => "never",
        "on_tab_switch" => "log",
        "certificate_enabled" => false
      })

    ExamFixtures.assign_all!(schema, exam.record_id)
    exam
  end

  defp rule!(schema, exam_id, category_id, count, mode) do
    ExamFixtures.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam_id,
      "mode" => mode,
      "category_id" => category_id,
      "count" => count,
      "sort_order" => 0
    })
  end

  defp drawn(schema, session_id) do
    Repo.all(
      from(r in Latest,
        where:
          r.entity_type == "session_question" and
            fragment("?->>'session_id'", r.field_values) == ^session_id
      ),
      prefix: schema
    )
    |> Enum.map(& &1.field_values["question_id"])
  end

  defp lineage!(schema, category_id) do
    v1 = question!(schema, category_id, nil, 1, "archived")
    v2 = question!(schema, category_id, v1, 2, "archived")
    v3 = question!(schema, category_id, v2, 3, "active")
    {v1, v2, v3}
  end

  test "S1 a rule pool over a three-version lineage draws only the active version" do
    %{schema_name: schema} = ExamFixtures.provisioned_tenant_with_exam_definitions("gh3315b-s1")
    category_id = Ecto.UUID.generate()
    {_v1, _v2, v3} = lineage!(schema, category_id)
    exam = exam!(schema)
    rule!(schema, exam.record_id, category_id, 1, "random")

    assert {:ok, view} = Session.create(Ecto.UUID.generate(), exam.record_id, schema)
    assert drawn(schema, view.id) == [v3]
  end

  test "S2 a manual pin of an archived version is not drawn, the active one is" do
    %{schema_name: schema} = ExamFixtures.provisioned_tenant_with_exam_definitions("gh3315b-s2")
    category_id = Ecto.UUID.generate()
    {v1, _v2, v3} = lineage!(schema, category_id)

    pinned = fn question_id ->
      exam = exam!(schema)
      rule = rule!(schema, exam.record_id, category_id, 1, "manual")

      ExamFixtures.create_record!(schema, "exam_manual_question", %{
        "rule_id" => rule.record_id,
        "question_id" => question_id,
        "sort_order" => 0
      })

      exam
    end

    assert {:error, {:question_not_found, ^v1}} =
             Session.create(Ecto.UUID.generate(), pinned.(v1).record_id, schema)

    assert {:ok, view} = Session.create(Ecto.UUID.generate(), pinned.(v3).record_id, schema)
    assert drawn(schema, view.id) == [v3]
  end
end
