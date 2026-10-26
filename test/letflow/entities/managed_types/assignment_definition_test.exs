defmodule Letflow.Entities.ManagedTypes.AssignmentDefinitionTest do
  @moduledoc """
  REQ-582 part A (criterion 11, test E-existing): `Letflow.Entities.ManagedTypes.AssignmentDefinition`
  and its release wrapper `Letflow.Release.ManagedTypes.ensure_assignment_definition/1`, against real
  provisioned tenants built the way the exam pack was installed BEFORE `exam_assignment` joined it
  (`Fx.bare_tenant!(slug, true)`: the exam `tenant_modules` row, no definitions).

  Runs OUTSIDE the Ecto sandbox transaction, like `StampTest`: `async: false`, the tenant fixtures
  switch the sandbox to `:auto`, so the step really begins and commits its own transaction (inside
  an outer one it refuses with `:nested_transaction`, E5). `run/1` sweeps EVERY registered tenant
  of the test database; assertions on a sweep pick this test's own tenants by schema name.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.ManagedTypes.AssignmentDefinition
  alias Letflow.Entities.ManagedTypes.Stamp
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Release.ManagedTypes, as: ReleaseManagedTypes
  alias Letflow.Repo

  defp report_for(report, schema), do: Enum.find(report.tenants, &(&1.schema_name == schema))

  defp audit_count(schema) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".audit_entries|)
    n
  end

  defp assignment_rows(schema), do: Fx.dump(schema, ["exam_assignment"])

  defp packed_fields do
    Fx.pack_document()["entity_definitions"]
    |> Enum.find(&(&1["name"] == "exam_assignment"))
    |> get_in(["definition_json", "fields"])
    |> Enum.map(&{&1["name"], &1["type"]})
  end

  describe "E1/E2 (criterion 11): a tenant installed before the change" do
    test "E1 the wrapper creates and activates the owner-stamped definition with the pack's fields" do
      %{schema_name: schema} = Fx.bare_tenant!("req582-e1", true)
      assert assignment_rows(schema) == []

      assert {:ok, report} = ReleaseManagedTypes.ensure_assignment_definition([])
      assert %{status: :created, error: nil} = report_for(report, schema)

      assert [row] = assignment_rows(schema)
      assert row.managed_by == "exam"
      assert row.status == "active"

      assert {:ok, definition} = Definitions.get_definition_by_name("exam_assignment", schema)
      assert definition.status == :active

      row_fields = Enum.map(definition.definition_json["fields"], &{&1["name"], &1["type"]})
      assert row_fields == packed_fields()
      assert ManagedTypes.owner_of("exam_assignment", schema) == {:ok, "exam"}
      assert audit_count(schema) >= 1
    end

    test "E2 a second run changes nothing and writes no audit entry" do
      %{schema_name: schema} = Fx.bare_tenant!("req582-e2", true)
      assert %{status: :created} = AssignmentDefinition.run_tenant(schema, [])

      rows = assignment_rows(schema)
      audits = audit_count(schema)

      assert %{status: :nothing_to_do, error: nil} = AssignmentDefinition.run_tenant(schema, [])
      assert {:ok, report} = AssignmentDefinition.run()
      assert %{status: :nothing_to_do} = report_for(report, schema)

      assert assignment_rows(schema) == rows
      assert audit_count(schema) == audits
    end

    test "E2b a hand-made exam_assignment definition of the tenant is never touched" do
      %{schema_name: schema} = Fx.bare_tenant!("req582-e2b", true)
      Fx.create_definition!(schema, Fx.legacy_definition("exam_assignment"))
      rows = assignment_rows(schema)
      audits = audit_count(schema)

      assert %{status: :nothing_to_do} = AssignmentDefinition.run_tenant(schema, [])
      assert assignment_rows(schema) == rows
      assert audit_count(schema) == audits
      assert [%{managed_by: nil, status: "inactive"}] = rows
    end
  end

  describe "E3 (criterion 11): no exam module" do
    test "a tenant without the exam module is left untouched" do
      %{schema_name: schema} = Fx.bare_tenant!("req582-e3", false)
      audits = audit_count(schema)

      assert {:ok, report} = ReleaseManagedTypes.ensure_assignment_definition([])
      assert %{status: :exam_not_installed, error: nil} = report_for(report, schema)

      assert assignment_rows(schema) == []
      assert audit_count(schema) == audits
    end
  end

  describe "E4 (criterion 11): a failure in one tenant does not stop the others" do
    test "the failing tenant is reported :failed with a tag; the other tenant is created" do
      %{schema_name: broken} = Fx.bare_tenant!("req582-e4a", true)
      %{schema_name: good} = Fx.bare_tenant!("req582-e4b", true)

      Repo.query!(
        ~s|CREATE FUNCTION "#{broken}".req582_inject() RETURNS trigger LANGUAGE plpgsql | <>
          ~s|AS $$ BEGIN RAISE EXCEPTION 'req582 injected'; END $$|
      )

      Repo.query!(
        ~s|CREATE TRIGGER req582_inject BEFORE INSERT ON "#{broken}".entity_definitions | <>
          ~s|FOR EACH ROW EXECUTE FUNCTION "#{broken}".req582_inject()|
      )

      assert {:ok, report} = AssignmentDefinition.run()

      assert %{status: :failed, error: {:unexpected_exception, Postgrex.Error}} =
               report_for(report, broken)

      assert %{status: :created} = report_for(report, good)
      assert report.failed_total >= 1
      assert report.created_total >= 1

      assert assignment_rows(broken) == []
      assert [%{managed_by: "exam", status: "active"}] = assignment_rows(good)
    end

    test "an unknown schema is :skipped_schema_missing and writes nothing" do
      assert %{status: :skipped_schema_missing, tenant_id: nil} =
               AssignmentDefinition.run_tenant("req582_no_such_schema", [])
    end
  end

  describe "E5: the entry guard" do
    test "called inside a transaction it fails with :nested_transaction and writes nothing" do
      %{schema_name: schema} = Fx.bare_tenant!("req582-e5", true)

      assert {:ok, %{status: :failed, error: :nested_transaction}} =
               Repo.transaction(fn -> AssignmentDefinition.run_tenant(schema, []) end)

      assert assignment_rows(schema) == []
    end
  end

  describe "E6 (INV-1/INV-6): tenants are independent" do
    test "B (without the definition) is created, A (with it) is left as it was; one row each" do
      %{schema_name: a} = Fx.bare_tenant!("req582-e6a", true)
      %{schema_name: b} = Fx.bare_tenant!("req582-e6b", true)
      assert %{status: :created} = AssignmentDefinition.run_tenant(a, [])
      a_rows = assignment_rows(a)
      a_audits = audit_count(a)

      assert {:ok, report} = AssignmentDefinition.run()
      assert %{status: :nothing_to_do} = report_for(report, a)
      assert %{status: :created} = report_for(report, b)

      assert assignment_rows(a) == a_rows
      assert audit_count(a) == a_audits
      assert [%{managed_by: "exam"}] = assignment_rows(b)
    end
  end

  describe "E7: not a stamp type" do
    test "exam_assignment is not in Stamp.stamp_names/0 and the stamp ignores it" do
      refute "exam_assignment" in Stamp.stamp_names()
      assert length(Stamp.stamp_names()) == 16

      %{schema_name: schema} = Fx.bare_tenant!("req582-e7", true)
      assert %{status: :created} = AssignmentDefinition.run_tenant(schema, [])

      report = Stamp.run_tenant(schema, dry_run: true)
      assert report.rows_stamped == 0
      refute "exam_assignment" in report.types_stamped
      refute "exam_assignment" in report.types_absent
    end
  end

  describe "E8: the wrapper forwards no option" do
    test "dry_run and schemas keys do not narrow or disable the sweep" do
      %{schema_name: schema} = Fx.bare_tenant!("req582-e8", true)

      assert {:ok, report} =
               ReleaseManagedTypes.ensure_assignment_definition(dry_run: true, schemas: [])

      assert %{status: :created} = report_for(report, schema)
      assert [%{managed_by: "exam"}] = assignment_rows(schema)
    end
  end
end
