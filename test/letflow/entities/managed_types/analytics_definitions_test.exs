defmodule Letflow.Entities.ManagedTypes.AnalyticsDefinitionsTest do
  @moduledoc """
  REQ-594 part A (criterion 10, tests R-ensure-1..11): `Letflow.Entities.ManagedTypes.AnalyticsDefinitions`
  and its release wrapper `Letflow.Release.ManagedTypes.ensure_exam_analytics_definitions/1`, against
  real provisioned tenants whose `session` and `session_question_score` definitions are the PREVIOUS
  shape (`previous_definition/1`: the committed definition with the analytics changes taken out, foreign
  keys and constraints stripped as `Fx.legacy_definition/1` strips them).

  Runs OUTSIDE the Ecto sandbox transaction, like `AssignmentDefinitionTest`: `async: false`, the tenant
  fixtures switch the sandbox to `:auto`. `run/1` sweeps EVERY registered tenant of the test database;
  assertions pick this test's own tenants by schema name.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.ManagedTypes.AnalyticsDefinitions
  alias Letflow.Entities.ManagedTypes.Stamp
  alias Letflow.Entities.ManagedTypes.TamperInventory
  alias Letflow.Entities.Query.Compiler
  alias Letflow.ExamFixtures
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Release.ManagedTypes, as: ReleaseManagedTypes
  alias Letflow.Repo

  @types ["session", "session_question_score"]

  defp report_for(report, schema), do: Enum.find(report.tenants, &(&1.schema_name == schema))

  defp audit_count(schema) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".audit_entries|)
    n
  end

  defp promotion_count(schema) do
    {:ok, tenant_id} = Letflow.TenantProvisioning.tenant_id_for_schema_name(schema)

    Repo.aggregate(
      from(p in Letflow.TenantProvisioning.ColumnPromotion, where: p.tenant_id == ^tenant_id),
      :count
    )
  end

  defp previous_definition("session") do
    "session"
    |> Fx.legacy_definition()
    |> Map.update!(:fields, fn fields ->
      Enum.map(fields, fn
        %{name: name} = field when name in ["score_pct", "passed"] -> %{field | queried: false}
        field -> field
      end)
    end)
  end

  defp previous_definition("session_question_score") do
    "session_question_score"
    |> Fx.legacy_definition()
    |> Map.update!(:fields, fn fields ->
      Enum.reject(fields, &(&1.name in ["exam_id", "correct"]))
    end)
  end

  # An active previous-shape tenant (unstamped, owner :tenant); `stamped?` adds a module-stamped
  # copy of each row, the state `ManagedTypes.owner_of/2` reads as owned by `exam`.
  defp previous_tenant!(slug, opts \\ []) do
    tenant = Fx.bare_tenant!(slug, true)
    schema = tenant.schema_name

    for type <- @types do
      definition =
        type
        |> previous_definition()
        |> then(&Keyword.get(opts, :transform, fn _t, d -> d end).(type, &1))

      Fx.create_definition!(schema, definition)
      :ok = Fx.activate!(schema, type)
    end

    tenant
  end

  # What `Stamp` does to a stampable row: set `managed_by` in place under its exception setting.
  defp stamp_rows!(schema) do
    {:ok, _result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('letflow.managed_by_stamp', 'exam', true)")

        Repo.update_all(
          from(d in Letflow.Entities.EntityDefinition, where: d.name in ^@types),
          [set: [managed_by: "exam"]],
          prefix: schema
        )
      end)

    :ok
  end

  # A second, inactive version of `type` stamped by another module (the active row stays addressable).
  defp insert_other_module_copy!(schema, type) do
    other =
      Fx.create_definition!(
        schema,
        Map.update!(
          previous_definition(type),
          :fields,
          &(&1 ++ [Fx.field("tenant_other", :string)])
        )
      )

    Fx.insert_stamped_copy!(schema, other, "other_module")
  end

  defp seed_session!(schema, score) do
    ExamFixtures.create_record!(schema, "session", %{
      "exam_id" => "exam-1",
      "user_id" => "user-1",
      "status" => "submitted",
      "seed" => 1,
      "started_at" => "2026-10-01T10:00:00",
      "expires_at" => "2026-10-01T11:00:00",
      "submitted_at" => "2026-10-01T10:30:00",
      "score_pct" => score,
      "passed" => true
    })
  end

  defp seed_score!(schema) do
    ExamFixtures.create_record!(schema, "session_question_score", %{
      "session_id" => "s-1",
      "question_id" => "q-1",
      "score" => 1,
      "max_score" => 1,
      "grading_status" => "graded"
    })
  end

  defp aggregate(schema, request) do
    Compiler.run_aggregate(request, schema, :all)
  end

  defp active_json(schema, type) do
    {:ok, row} = Definitions.get_active_definition_by_name(type, schema)
    row.definition_json
  end

  defp field(json, name), do: Enum.find(json["fields"], &(&1["name"] == name))

  describe "R-ensure-1/2 a stamped previous-shape tenant" do
    test "R-ensure-1 creates both versions stamped, promotes nothing, and report 1 counts the old session" do
      %{schema_name: schema} = previous_tenant!("req594-r1")
      seed_session!(schema, 80)
      stamp_rows!(schema)
      promotions = promotion_count(schema)

      refute match?({:ok, _rows}, aggregate(schema, report_1(true)))

      assert {:ok, report} = ReleaseManagedTypes.ensure_exam_analytics_definitions([])
      assert %{status: :created, error: nil, types: @types} = report_for(report, schema)

      for type <- @types do
        {:ok, active} = Definitions.get_active_definition_by_name(type, schema)
        assert active.managed_by == "exam"
      end

      assert field(active_json(schema, "session"), "score_pct")["queried"] == true
      assert field(active_json(schema, "session"), "passed")["queried"] == true
      assert field(active_json(schema, "session_question_score"), "exam_id")["type"] == "string"
      assert field(active_json(schema, "session_question_score"), "correct")["type"] == "boolean"

      assert promotion_count(schema) == promotions

      assert {:ok, [%{} = attempts]} = aggregate(schema, report_1(nil))
      assert {:ok, [%{} = passed]} = aggregate(schema, report_1(true))
      assert {:ok, [%{} = average]} = aggregate(schema, report_avg())
      assert Enum.map(Map.values(attempts), &num/1) == [1]
      assert Enum.map(Map.values(passed), &num/1) == [1]
      assert Enum.map(Map.values(average), &num/1) == [80]
    end

    test "R-ensure-1b a tenant's extra field survives and the stripped shape stays stripped" do
      extra = Fx.field("tenant_extra", :string)

      %{schema_name: schema} =
        previous_tenant!("req594-r1b",
          transform: fn
            "session_question_score", d -> Map.update!(d, :fields, &(&1 ++ [extra]))
            _type, d -> d
          end
        )

      stamp_rows!(schema)
      assert %{status: :created} = AnalyticsDefinitions.run_tenant(schema, [])

      json = active_json(schema, "session_question_score")
      assert field(json, "tenant_extra")
      assert json["constraints"] == []
      assert json["foreign_keys"] == []
    end

    test "R-ensure-2 a score row written before the step is not counted by report 3" do
      %{schema_name: schema} = previous_tenant!("req594-r2")
      seed_score!(schema)
      stamp_rows!(schema)
      assert %{status: :created} = AnalyticsDefinitions.run_tenant(schema, [])

      assert {:ok, rows} =
               aggregate(schema, %{
                 entity_type: "session_question_score",
                 aggregates: [%{fn: :count}],
                 group_by: [%{field: "question_id"}],
                 filters: [%{field: "exam_id", op: :eq, value: "exam-1"}]
               })

      assert rows == []
    end

    test "R-ensure-3 the tamper inventory has no new finding" do
      %{schema_name: schema} = previous_tenant!("req594-r3")
      stamp_rows!(schema)
      before_findings = findings(schema)

      assert %{status: :created} = AnalyticsDefinitions.run_tenant(schema, [])
      assert findings(schema) == before_findings
    end

    test "R-ensure-4 a second run changes nothing and writes no audit entry" do
      %{schema_name: schema} = previous_tenant!("req594-r4")
      stamp_rows!(schema)
      assert %{status: :created} = AnalyticsDefinitions.run_tenant(schema, [])

      rows = Fx.dump(schema, @types)
      audits = audit_count(schema)

      assert %{status: :nothing_to_do, error: nil} = AnalyticsDefinitions.run_tenant(schema, [])
      assert {:ok, report} = AnalyticsDefinitions.run()
      assert %{status: :nothing_to_do} = report_for(report, schema)

      assert Fx.dump(schema, @types) == rows
      assert audit_count(schema) == audits
    end
  end

  describe "tenants outside the plain path" do
    test "R-ensure-5 a tenant without the exam module gets no definition" do
      %{schema_name: schema} = Fx.bare_tenant!("req594-r5", false)

      assert %{status: :exam_not_installed} = AnalyticsDefinitions.run_tenant(schema, [])
      assert Fx.dump(schema, @types) == []
    end

    test "R-ensure-6 one failing tenant is reported and the sweep continues" do
      %{schema_name: failing} = previous_tenant!("req594-r6f")

      # The previous-shape sqs of F declares writable_by_process in its stored JSON: the derived
      # document keeps the key and the pack install refuses it (`ProcessWritable.pack_refusal/0`).
      Repo.query!(
        ~s[UPDATE "#{failing}".entity_definitions ] <>
          ~s[SET definition_json = jsonb_set(definition_json, '{writable_by_process}', 'true') ] <>
          ~s[WHERE name = 'session_question_score']
      )

      %{schema_name: good} = previous_tenant!("req594-r6g")
      before_rows = Fx.dump(failing, @types)

      assert {:ok, report} = AnalyticsDefinitions.run()

      assert %{status: :failed, error: {:ensure_failed, :validation}} =
               report_for(report, failing)

      assert %{status: :created} = report_for(report, good)
      assert report.failed_total >= 1
      assert Fx.dump(failing, @types) == before_rows
    end

    test "R-ensure-7 an unstamped previous-shape tenant is upgraded as :tenant and then stampable" do
      %{schema_name: schema} = previous_tenant!("req594-r7")
      assert %{status: :created} = AnalyticsDefinitions.run_tenant(schema, [])

      for type <- @types do
        {:ok, active} = Definitions.get_active_definition_by_name(type, schema)
        assert active.managed_by == nil
      end

      assert {:ok, _added} = Letflow.Modules.Exam.ensure_answer_key_restrictions(schema)
      assert %{status: status} = Stamp.run_tenant(schema, dry_run: true)
      refute status == :shape_not_compatible
      refute ManagedTypes.owner_of("session_question_score", schema) == {:ok, "other"}
    end

    test "R-ensure-8 only the old type gets a new version" do
      %{schema_name: schema} =
        previous_tenant!("req594-r8",
          transform: fn
            "session", _d -> Fx.legacy_definition("session")
            _type, d -> d
          end
        )

      stamp_rows!(schema)
      session_rows = Fx.dump(schema, ["session"])

      assert %{status: :created, types: ["session_question_score"]} =
               AnalyticsDefinitions.run_tenant(schema, [])

      assert Fx.dump(schema, ["session"]) == session_rows
    end

    test "R-ensure-9 a conflicting field type is a conflict and nothing is written" do
      %{schema_name: schema} =
        previous_tenant!("req594-r9",
          transform: fn
            "session_question_score", d ->
              Map.update!(d, :fields, &(&1 ++ [Fx.field("exam_id", :integer)]))

            _type, d ->
              d
          end
        )

      stamp_rows!(schema)
      rows = Fx.dump(schema, @types)

      assert %{status: :conflict, error: {:conflict, "session_question_score", :field_type}} =
               AnalyticsDefinitions.run_tenant(schema, [])

      assert Fx.dump(schema, @types) == rows
    end

    test "R-ensure-11 a type managed by another module is a conflict and nothing is written" do
      %{schema_name: schema} = previous_tenant!("req594-r11")
      insert_other_module_copy!(schema, "session")
      rows = Fx.dump(schema, @types)

      assert %{status: :conflict, error: {:conflict, "session", :managed_by_other}} =
               AnalyticsDefinitions.run_tenant(schema, [])

      assert Fx.dump(schema, @types) == rows
    end
  end

  describe "R-ensure-10 result mapping" do
    test "a bare rollback maps to a tagged failure, never a CaseClauseError" do
      assert AnalyticsDefinitions.map_result({:ok, :ok}) == :created

      assert AnalyticsDefinitions.map_result({:error, {:ensure_failed, :x}}) ==
               {:failed, {:ensure_failed, :x}}

      assert AnalyticsDefinitions.map_result({:error, :rollback}) ==
               {:failed, {:ensure_failed, :rolled_back}}
    end
  end

  defp report_1(passed) do
    filters = [%{field: "exam_id", op: :eq, value: "exam-1"}]
    filters = if passed, do: filters ++ [%{field: "passed", op: :eq, value: true}], else: filters
    %{entity_type: "session", aggregates: [%{fn: :count}], filters: filters}
  end

  defp report_avg do
    %{
      entity_type: "session",
      aggregates: [%{fn: :avg, field: "score_pct"}],
      filters: [%{field: "exam_id", op: :eq, value: "exam-1"}]
    }
  end

  defp num(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
  defp num(n) when is_integer(n), do: n
  defp num(n) when is_float(n), do: round(n)

  defp findings(schema) do
    %{findings: findings} = TamperInventory.run_tenant(schema, [])
    findings
  end
end
