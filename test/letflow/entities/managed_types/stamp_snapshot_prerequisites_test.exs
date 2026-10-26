defmodule Letflow.Entities.ManagedTypes.StampSnapshotPrerequisitesTest do
  @moduledoc """
  GH #2682 / REQ-511 PR b, design `lib/letflow/design/req511-exam-content-snapshot.md` sections 10.1,
  10.2, 12.5 (T-38, T-39, T-40, T-57b) and 17.2 (spec `test/specs/GH2682-exam-snapshot-pr-b.md`):
  with the flag `:exam_snapshot_complete` open (PR b flips it to `true`), a REAL `Stamp` run stamps
  a tenant only if the tenant went through the exam snapshot rollout:

    * its ACTIVE `session` definition declares the json field `exam_snapshot`, and
    * every `Exam.answer_key_fields/0` pair has an `entity_field_restrictions` row.

  Otherwise the tenant report is `status: :snapshot_prerequisite_missing` with
  `prerequisites_missing` in the fixed order `[:session_definition, :answer_key_restrictions]`,
  nothing of it is stamped, no audit entry is written, and the sweep goes on; such a tenant is
  counted in `gate_blocked_total` (so the Mix task exits 1). The check runs only while the tenant
  still has an unstamped row, is repeated from the rows locked by the real run, and is never part of
  a dry run. The conflict rule judges the ACTIVE version of a name (none active: the newest), so a
  tenant whose rollout left the old `session` version behind is stampable (T-40).

  The Mix task's `System.halt(1)` cannot run in-process: its exit rule is asserted on the report it
  receives and by a source guard (the same method as the PR a gate tests).

  Runs outside the sandbox transaction (`Stamp` refuses to run inside one): `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureIO

  alias Letflow.Entities.ManagedTypes.Stamp
  alias Letflow.ExamFixtures
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.Snapshot.Rollout
  alias Letflow.Release.ManagedTypes
  alias Mix.Tasks.Letflow.StampManagedTypes

  @six Fx.runtime_types()
  # The ten STAMPED authoring types (REQ-582 `exam_assignment` is managed but not in `stamp_names`).
  @ten Fx.stamp_types() -- Fx.runtime_types()

  @statuses [
    :stamped,
    :nothing_to_stamp,
    :exam_not_installed,
    :exception_not_installed,
    :snapshot_not_complete,
    :snapshot_prerequisite_missing,
    :skipped_schema_missing,
    :failed
  ]

  # ── helpers ────────────────────────────────────────────────────────────────────────────────

  defp run!(schema, opts), do: Stamp.run_tenant(schema, opts)

  defp report_for(report, schema), do: Enum.find(report.tenants, &(&1.schema_name == schema))

  # A rolled-out exam tenant (field and all five restriction rows) with the six runtime types, all
  # unstamped: the state `Letflow.ExamStampFixtures.legacy_tenant!/1` provides.
  defp ready_tenant!(slug), do: Fx.legacy_tenant!(slug)

  # A tenant installed BEFORE the snapshot change: the active session definition lacks the field.
  defp not_rolled_out_tenant!(slug) do
    tenant = ready_tenant!(slug)
    ExamFixtures.downgrade_session_definition!(tenant.schema_name)
    tenant
  end

  defp assert_nothing_stamped!(schema) do
    for {name, values} <- Map.take(Fx.managed_by_map(schema), @six) do
      assert {name, values} == {name, [nil]}
    end

    assert Fx.stamp_audit_count(schema) == 0
  end

  defp restriction_pairs(schema) do
    from(r in "entity_field_restrictions", select: {r.entity_type, r.field_name})
    |> Repo.all(prefix: schema)
    |> Enum.sort()
  end

  defp delete_snapshot_restriction!(schema) do
    assert {1, _} =
             Repo.delete_all(
               from(r in "entity_field_restrictions",
                 where: r.entity_type == "session" and r.field_name == "exam_snapshot"
               ),
               prefix: schema
             )

    :ok
  end

  defp with_flag(value, fun) do
    previous = Application.fetch_env(:letflow, :exam_snapshot_complete)
    Application.put_env(:letflow, :exam_snapshot_complete, value)

    try do
      fun.()
    after
      case previous do
        {:ok, original} -> Application.put_env(:letflow, :exam_snapshot_complete, original)
        :error -> Application.delete_env(:letflow, :exam_snapshot_complete)
      end
    end
  end

  defp legacy_def!(schema, name, transform) do
    Fx.create_definition!(
      schema,
      name |> Fx.legacy_definition() |> transform.() |> Map.put(:constraints, [])
    )
  end

  defp without_snapshot_field(definition) do
    Map.update!(definition, :fields, fn fields ->
      Enum.reject(fields, &(&1.name == "exam_snapshot"))
    end)
  end

  # ── T-38: the session definition ───────────────────────────────────────────────────────────

  describe "T-38 a tenant whose active session definition lacks exam_snapshot" do
    test "is :snapshot_prerequisite_missing [:session_definition]: nothing stamped, no audit entry; after the rollout it stamps" do
      %{schema_name: schema, tenant_id: tenant_id} = not_rolled_out_tenant!("gh2682-b-t38")

      report = run!(schema, [])

      assert %{
               status: :snapshot_prerequisite_missing,
               prerequisites_missing: [:session_definition],
               rows_stamped: 0,
               rows_already_stamped: 0,
               types_stamped: [],
               error: nil,
               schema_name: ^schema,
               tenant_id: ^tenant_id
             } = report

      assert_nothing_stamped!(schema)

      # rollout first, then stamp
      assert %{status: :upgraded} = Rollout.run_tenant(schema, [])
      assert %{status: :stamped, rows_stamped: 14, prerequisites_missing: []} = run!(schema, [])

      for {name, values} <- Map.take(Fx.managed_by_map(schema), @six) do
        assert {name, values} == {name, ["exam"]}
      end

      assert Fx.stamp_audit_count(schema) == 1
    end

    test "a tenant with no session definition at all (the other runtime types present) is blocked the same way" do
      %{schema_name: schema} = Fx.stamp_ready_tenant!("gh2682-b-t38-nosession")

      for name <- @six -- ["session"],
          do: legacy_def!(schema, name, & &1)

      assert %{
               status: :snapshot_prerequisite_missing,
               prerequisites_missing: [:session_definition]
             } =
               run!(schema, [])

      assert Fx.stamp_audit_count(schema) == 0
    end

    test "dry run is NEVER blocked: it reports the tenant and writes nothing, whatever is missing" do
      %{schema_name: schema} = not_rolled_out_tenant!("gh2682-b-t38-dry")
      assert ExamFixtures.delete_answer_key_restrictions!(schema) == 5

      report = run!(schema, dry_run: true)

      refute report.status in [:snapshot_prerequisite_missing, :snapshot_not_complete]
      assert report.prerequisites_missing == []
      assert_nothing_stamped!(schema)

      assert {:ok, sweep} = Stamp.run(dry_run: true)
      assert sweep.gate_blocked_total == 0
      assert sweep |> report_for(schema) |> Map.fetch!(:prerequisites_missing) == []
    end
  end

  # ── T-39: the restriction rows ─────────────────────────────────────────────────────────────

  describe "T-39 a tenant lacking an answer-key restriction row" do
    test "no rows at all: [:answer_key_restrictions], nothing stamped; once reconciled it stamps" do
      %{schema_name: schema} = ready_tenant!("gh2682-b-t39")
      assert ExamFixtures.delete_answer_key_restrictions!(schema) == 5

      assert %{
               status: :snapshot_prerequisite_missing,
               prerequisites_missing: [:answer_key_restrictions],
               rows_stamped: 0
             } = run!(schema, [])

      assert_nothing_stamped!(schema)

      assert {:ok, 5} = Exam.ensure_answer_key_restrictions(schema)
      assert %{status: :stamped, rows_stamped: 12, prerequisites_missing: []} = run!(schema, [])
    end

    test "ONE missing pair is enough, and it is the snapshot pair that matters most" do
      %{schema_name: schema} = ready_tenant!("gh2682-b-t39-one")
      assert restriction_pairs(schema) == Enum.sort(Exam.answer_key_fields())
      :ok = delete_snapshot_restriction!(schema)

      assert %{
               status: :snapshot_prerequisite_missing,
               prerequisites_missing: [:answer_key_restrictions]
             } = run!(schema, [])

      assert_nothing_stamped!(schema)
    end

    test "both prerequisites missing are reported in the fixed order [:session_definition, :answer_key_restrictions]" do
      %{schema_name: schema} = not_rolled_out_tenant!("gh2682-b-t38-both")
      assert ExamFixtures.delete_answer_key_restrictions!(schema) == 5

      assert %{
               status: :snapshot_prerequisite_missing,
               prerequisites_missing: [:session_definition, :answer_key_restrictions]
             } = run!(schema, [])

      assert_nothing_stamped!(schema)
    end
  end

  # ── T-40: the ACTIVE row is judged ─────────────────────────────────────────────────────────

  describe "T-40 compatibility is judged on the ACTIVE row" do
    test "an old inactive session version without the field plus the new active one with it is stampable, and EVERY row of the name is stamped" do
      %{schema_name: schema} = Fx.full_tenant!("gh2682-b-t40")

      # the QA/BilimBaga history: v1 (with the field), then a version without it, then the rollout
      ExamFixtures.downgrade_session_definition!(schema)
      assert %{status: :upgraded} = Rollout.run_tenant(schema, [])
      assert length(Fx.dump(schema, ["session"])) == 3

      report = run!(schema, [])

      assert %{
               status: :stamped,
               rows_stamped: 18,
               conflicts: [],
               prerequisites_missing: [],
               error: nil
             } = report

      assert report.types_stamped |> Enum.uniq() |> Enum.sort() == Enum.sort(@six ++ @ten)
      assert Fx.managed_by_map(schema)["session"] == ["exam"]
      assert Enum.all?(Fx.dump(schema, ["session"]), &(&1.managed_by == "exam"))
      assert length(Fx.dump(schema, ["session"])) == 3

      assert %{status: :nothing_to_stamp, rows_stamped: 0, rows_already_stamped: 18} =
               run!(schema, [])
    end

    test "an ACTIVE row that is incompatible still conflicts (the judged row decides), and a hostile INACTIVE one next to a good active row does not" do
      %{schema_name: hostile_active} = Fx.full_tenant!("gh2682-b-t40-hostile")

      Fx.create_definition!(hostile_active, %{
        name: "certificate",
        display_name: "Tenant certificate",
        fields: [Fx.field("foo", :string)]
      })

      Fx.activate!(hostile_active, "certificate")

      assert %{status: :stamped, rows_stamped: 15, conflicts: [conflict]} =
               run!(hostile_active, [])

      assert %{type: "certificate", reason: :shape_not_compatible} = conflict
      assert Fx.managed_by_map(hostile_active)["certificate"] == [nil]

      %{schema_name: hostile_inactive} = Fx.full_tenant!("gh2682-b-t40-inactive")

      Fx.create_definition!(hostile_inactive, %{
        name: "certificate",
        display_name: "Tenant certificate",
        fields: [Fx.field("foo", :string)]
      })

      assert %{status: :stamped, rows_stamped: 17, conflicts: []} = run!(hostile_inactive, [])
      assert Fx.managed_by_map(hostile_inactive)["certificate"] == ["exam"]
    end

    test "N1 (SECURITY-REVIEWER, accepted MINOR) with no ACTIVE session version the newest one is judged: a newest version with the field passes the prerequisite, one without blocks" do
      %{schema_name: newest_has} = Fx.stamp_ready_tenant!("gh2682-b-n1-has")
      legacy_def!(newest_has, "session", &without_snapshot_field/1)
      legacy_def!(newest_has, "session", & &1)

      assert %{status: :stamped, rows_stamped: 2, prerequisites_missing: []} =
               run!(newest_has, [])

      %{schema_name: newest_lacks} = Fx.stamp_ready_tenant!("gh2682-b-n1-lacks")
      legacy_def!(newest_lacks, "session", & &1)
      legacy_def!(newest_lacks, "session", &without_snapshot_field/1)

      assert %{
               status: :snapshot_prerequisite_missing,
               prerequisites_missing: [:session_definition]
             } = run!(newest_lacks, [])

      assert Fx.stamp_audit_count(newest_lacks) == 0
    end
  end

  # ── the check runs only while there is something to stamp, and again under the locks ───────

  describe "when the prerequisites are judged" do
    test "a fully stamped tenant stays :nothing_to_stamp even if a restriction row disappears later" do
      %{schema_name: schema} = ready_tenant!("gh2682-b-stamped")
      assert %{status: :stamped, rows_stamped: 12} = run!(schema, [])
      assert ExamFixtures.delete_answer_key_restrictions!(schema) == 5

      assert %{
               status: :nothing_to_stamp,
               rows_already_stamped: 12,
               prerequisites_missing: [],
               rows_stamped: 0
             } = run!(schema, [])
    end

    test "RACE: a restriction row removed after the advisory pre-pass is caught under the row locks; nothing is stamped" do
      %{schema_name: schema} = ready_tenant!("gh2682-b-race-restriction")

      hook = fn hook_schema ->
        if hook_schema == schema, do: ExamFixtures.delete_answer_key_restrictions!(schema)
        :ok
      end

      report = run!(schema, after_precheck: hook)

      assert %{
               status: :snapshot_prerequisite_missing,
               prerequisites_missing: [:answer_key_restrictions],
               rows_stamped: 0,
               error: nil
             } = report

      assert_nothing_stamped!(schema)
    end

    test "RACE: a session version without the field activated after the advisory pre-pass is caught under the row locks" do
      %{schema_name: schema} = ready_tenant!("gh2682-b-race-definition")

      hook = fn hook_schema ->
        if hook_schema == schema, do: ExamFixtures.downgrade_session_definition!(schema)
        :ok
      end

      report = run!(schema, after_precheck: hook)

      assert %{
               status: :snapshot_prerequisite_missing,
               prerequisites_missing: [:session_definition],
               rows_stamped: 0
             } = report

      assert_nothing_stamped!(schema)
    end

    test "the closed flag wins: with the flag false a not-rolled-out tenant is :snapshot_not_complete, not a prerequisite report" do
      %{schema_name: schema} = not_rolled_out_tenant!("gh2682-b-flag-first")

      assert %{status: :snapshot_not_complete, prerequisites_missing: []} =
               with_flag(false, fn -> run!(schema, []) end)

      assert %{status: :snapshot_prerequisite_missing} = run!(schema, [])
    end
  end

  # ── T-57b: the report fields ───────────────────────────────────────────────────────────────

  describe "T-57b the report fields and the sweep" do
    test "a sweep counts a blocked tenant in gate_blocked_total, continues past it, and stamps a rolled-out tenant" do
      blocked = not_rolled_out_tenant!("gh2682-b-t57-blocked")
      ready = ready_tenant!("gh2682-b-t57-ready")

      assert {:ok, report} = Stamp.run([])

      blocked_report = report_for(report, blocked.schema_name)
      ready_report = report_for(report, ready.schema_name)

      assert %{
               status: :snapshot_prerequisite_missing,
               prerequisites_missing: [:session_definition]
             } =
               blocked_report

      assert %{status: :stamped, rows_stamped: 12, prerequisites_missing: []} = ready_report
      assert report.gate_blocked_total >= 1

      assert report.gate_blocked_total ==
               Enum.count(report.tenants, &(&1.status == :snapshot_prerequisite_missing))

      assert Enum.all?(report.tenants, &(&1.status in @statuses))
      assert_nothing_stamped!(blocked.schema_name)
    end

    test "Letflow.Release.ManagedTypes.stamp/1 returns the same report; its gate_blocked_total is what makes the Mix task exit 1" do
      blocked = not_rolled_out_tenant!("gh2682-b-t57-release")

      assert {:ok, report} = ManagedTypes.stamp(module: "exam")
      assert %{status: :snapshot_prerequisite_missing} = report_for(report, blocked.schema_name)

      # the exact condition lib/mix/tasks/letflow.stamp_managed_types.ex halts on
      assert report.failed_total > 0 or report.gate_blocked_total > 0

      assert {:ok, dry} = ManagedTypes.stamp(dry_run: true)
      assert dry.gate_blocked_total == 0
    end

    test "the Mix task prints the missing prerequisites and exits non-zero for a blocked tenant (source guard: System.halt(1) cannot run in-process); a dry run prints 0 gate-blocked" do
      source = File.read!(Path.join(File.cwd!(), "lib/mix/tasks/letflow.stamp_managed_types.ex"))

      assert source =~ "if tenant.prerequisites_missing != [] do"
      assert source =~ "snapshot prerequisites missing: "
      assert source =~ "Enum.join(tenant.prerequisites_missing, \", \")"
      assert source =~ "if report.failed_total > 0 or report.gate_blocked_total > 0,"
      assert source =~ "System.halt(1)"

      blocked = not_rolled_out_tenant!("gh2682-b-t57-task")

      # The task halts the VM when ANY tenant of this database failed; only run it in-process when
      # the sweep is clean.
      {:ok, probe} = Stamp.run(dry_run: true)

      if probe.failed_total == 0 do
        output = capture_io(fn -> StampManagedTypes.run(["--dry-run"]) end)
        assert output =~ "managed-type stamp complete (dry run)"
        assert output =~ "0 gate-blocked"
        refute output =~ "snapshot prerequisites missing"
      end

      assert_nothing_stamped!(blocked.schema_name)
    end

    test "the report types: every tenant status is one of the typed set and prerequisites_missing only holds the two typed items" do
      blocked = not_rolled_out_tenant!("gh2682-b-t57-types")
      assert ExamFixtures.delete_answer_key_restrictions!(blocked.schema_name) == 5

      report = run!(blocked.schema_name, [])
      assert report.status in @statuses

      assert Enum.all?(
               report.prerequisites_missing,
               &(&1 in [:session_definition, :answer_key_restrictions])
             )

      assert Enum.sort(Map.keys(report)) ==
               Enum.sort(Map.keys(run!(blocked.schema_name, dry_run: true)))
    end
  end
end
