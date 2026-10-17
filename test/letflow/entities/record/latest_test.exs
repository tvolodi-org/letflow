defmodule Letflow.Entities.Record.LatestTest do
  @moduledoc """
  GH #2734 (design `lib/letflow/design/gh2734-latest-get-soft-deleted.md`, section 6, spec
  `test/specs/GH-2734.md`): the two single-row reads of `Letflow.Entities.Record.Latest`.

    * G1 `get_live/3`: a live row is returned, a soft-deleted row is `{:error, :not_found}` (the
      same value as an absent row), an unregistered prefix is `{:error, :invalid_schema_name}`,
      and another tenant's schema cannot see the row.
    * G2 `get/3` is the "any row" primitive and still returns the soft-deleted row with
      `deleted: true` (guard: `Records` needs to see it for the 409 and the idempotent delete).

  Real Postgres, real provisioned tenants (DIRECTIVE T-1). Outside the sandbox transaction
  (`Letflow.ExamFixtures` switches the sandbox to `:auto`): `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Record.Latest
  alias Letflow.ExamFixtures, as: Fx

  defp create_exam!(schema) do
    Fx.create_record!(schema, "exam", %{
      "title" => %{"en" => "Latest Test Exam"},
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 10,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => true
    })
  end

  describe "G1 Latest.get_live/3" do
    test "a live row is returned, equal to what get/3 returns" do
      %{schema_name: schema} = Fx.provisioned_tenant_with_exam_definitions("gh2734-g1-live")
      exam = create_exam!(schema)

      assert {:ok, %Latest{deleted: false} = live} =
               Latest.get_live(exam.record_id, "exam", schema)

      assert live.record_id == exam.record_id
      assert {:ok, ^live} = Latest.get(exam.record_id, "exam", schema)
    end

    test "a soft-deleted row is {:error, :not_found}, byte-identical to an absent row" do
      %{schema_name: schema} = Fx.provisioned_tenant_with_exam_definitions("gh2734-g1-deleted")
      exam = create_exam!(schema)
      :ok = Fx.delete_record!(schema, "exam", exam.record_id)

      assert {:error, :not_found} = Latest.get_live(exam.record_id, "exam", schema)

      assert Latest.get_live(exam.record_id, "exam", schema) ==
               Latest.get_live(Ecto.UUID.generate(), "exam", schema)
    end

    test "an absent record id, and a live record read under the wrong entity type, are {:error, :not_found}" do
      %{schema_name: schema} = Fx.provisioned_tenant_with_exam_definitions("gh2734-g1-absent")
      exam = create_exam!(schema)

      assert {:error, :not_found} = Latest.get_live(Ecto.UUID.generate(), "exam", schema)
      assert {:error, :not_found} = Latest.get_live(exam.record_id, "question", schema)
    end

    test "an unregistered prefix is {:error, :invalid_schema_name}" do
      assert {:error, :invalid_schema_name} =
               Latest.get_live(Ecto.UUID.generate(), "exam", "no_such_schema")
    end

    test "another tenant's schema cannot see the row" do
      %{schema_name: schema_a} = Fx.provisioned_tenant_with_exam_definitions("gh2734-g1-tenant-a")
      %{schema_name: schema_b} = Fx.provisioned_tenant_with_exam_definitions("gh2734-g1-tenant-b")
      exam = create_exam!(schema_a)

      assert {:ok, _row} = Latest.get_live(exam.record_id, "exam", schema_a)
      assert {:error, :not_found} = Latest.get_live(exam.record_id, "exam", schema_b)
    end
  end

  describe "G2 Latest.get/3 still returns soft-deleted rows (guard)" do
    test "after Records.delete_record/2 the row is returned with deleted: true and its field values retained" do
      %{schema_name: schema} = Fx.provisioned_tenant_with_exam_definitions("gh2734-g2")
      exam = create_exam!(schema)
      :ok = Fx.delete_record!(schema, "exam", exam.record_id)

      assert {:ok, %Latest{deleted: true} = row} = Latest.get(exam.record_id, "exam", schema)
      assert row.record_id == exam.record_id
      assert row.field_values["passing_score_pct"] == exam.field_values["passing_score_pct"]
    end
  end
end
