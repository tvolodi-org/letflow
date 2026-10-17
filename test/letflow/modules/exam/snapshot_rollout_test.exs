defmodule Letflow.Modules.Exam.SnapshotRolloutTest do
  @moduledoc """
  GH #2682 / REQ-511 PR a, design `lib/letflow/design/req511-exam-content-snapshot.md` sections
  10.3, 17.2 and 18.4 (spec `test/specs/GH2682-exam-snapshot-pr-a.md`): the rollout that brings an
  exam-installed tenant to the state the snapshot code needs
  (`Letflow.Modules.Exam.Snapshot.Rollout`, `Letflow.Release.ExamSnapshot`,
  `mix letflow.exam_snapshot_rollout`), against real provisioned tenants.

    * T-37: a real run adds `exam_snapshot` as a new active `session` definition version through
      `Definitions.create_definition/3` and `activate_definition/4` ONLY, the new version differs
      from the previous active one by exactly that field, no DDL is issued (also on a tenant whose
      `session` type is column-promoted, design OQ-9), a session can then be started, and a second
      run is `already_current`.
    * T-56: the report shapes of design 17.2, idempotency, dry run writes nothing, conflict and
      failure statuses, `verify/0`, the release wrapper and the Mix task's argument handling.
    * T-34 (rollout half): the restriction reconcile inside the rollout is idempotent.

  Every tenant is built and cleaned by a fixture and every real run targets that one schema through
  `run_tenant/2`: a real `run/1` sweep would upgrade the other tests' tenants, so only the
  read-only `run(dry_run: true)` is used for the sweep shape.

  Runs outside the sandbox transaction (the fixtures switch the sandbox to `:auto`).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureIO
  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.ExamStampFixtures, as: StampFx
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.Session
  alias Letflow.Modules.Exam.Snapshot.Rollout
  alias Letflow.Release.ExamSnapshot, as: Release
  alias Letflow.TenantProvisioning
  alias Mix.Tasks.Letflow.ExamSnapshotRollout, as: RolloutTask

  @tenant_report_keys [
    :definition,
    :error,
    :restrictions_added,
    :schema_name,
    :status,
    :tenant_id
  ]
  @report_keys [
    :conflict_total,
    :dry_run,
    :failed_total,
    :restrictions_added_total,
    :tenants,
    :upgraded_total
  ]

  # ── helpers ────────────────────────────────────────────────────────────────────────────────

  # A tenant installed BEFORE this change: all sixteen definitions, but the active `session` one
  # does not declare exam_snapshot and no restriction row exists.
  defp pre_rollout_tenant!(slug) do
    tenant = StampFx.full_tenant!(slug)
    Fx.downgrade_session_definition_without_nils!(tenant.schema_name)
    assert Fx.delete_answer_key_restrictions!(tenant.schema_name) == 5
    tenant
  end

  # The same tenant, but its active `session` definition is stored the way
  # `Definitions.create_definition/2` stores a document built from `Letflow.Entities.Definition`
  # maps: every optional field key present, with JSON null where there is no value.
  defp pre_rollout_tenant_with_null_keys!(slug) do
    tenant = StampFx.full_tenant!(slug)
    Fx.downgrade_session_definition!(tenant.schema_name)
    assert Fx.delete_answer_key_restrictions!(tenant.schema_name) == 5
    tenant
  end

  defp active_session!(schema) do
    assert {:ok, row} = Definitions.get_active_definition_by_name("session", schema)
    row
  end

  defp session_versions(schema) do
    Repo.all(
      from(d in EntityDefinition, where: d.name == "session", order_by: d.inserted_at),
      prefix: schema
    )
  end

  defp snapshot_field(row) do
    Enum.find(row.definition_json["fields"], &(&1["name"] == "exam_snapshot"))
  end

  defp restriction_pairs(schema) do
    from(r in "entity_field_restrictions", select: {r.entity_type, r.field_name})
    |> Repo.all(prefix: schema)
    |> Enum.sort()
  end

  # Every column of every table of the tenant schema: a DDL change shows up as a difference.
  defp columns(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns " <>
          "WHERE table_schema = $1 ORDER BY table_name, column_name",
        [schema]
      )

    rows
  end

  defp promotion_count(tenant_id) do
    Repo.aggregate(
      from(cp in Letflow.TenantProvisioning.ColumnPromotion, where: cp.tenant_id == ^tenant_id),
      :count
    )
  end

  defp report_for(report, schema), do: Enum.find(report.tenants, &(&1.schema_name == schema))

  defp start_session(schema) do
    %{exam: exam} = StampFx.build_exam!(schema)
    Session.create(Ecto.UUID.generate(), exam.record_id, schema)
  end

  # ── T-37 ───────────────────────────────────────────────────────────────────────────────────

  describe "T-37 real run" do
    test "adds exam_snapshot as a new active version differing by exactly that field, reconciles the rows, and a session can start" do
      %{schema_name: schema} = tenant = pre_rollout_tenant!("gh2682-t37-real")
      previous = active_session!(schema)
      versions_before = length(session_versions(schema))
      refute snapshot_field(previous)

      # before the rollout the start fails closed (T-53)
      assert {:error, {:snapshot_error, :definition_missing}} = start_session(schema)

      report = Rollout.run_tenant(schema, [])

      assert Enum.sort(Map.keys(report)) == @tenant_report_keys

      assert %{
               status: :upgraded,
               definition: :added,
               restrictions_added: 5,
               error: nil,
               schema_name: ^schema
             } = report

      assert report.tenant_id == tenant.tenant_id

      current = active_session!(schema)
      refute current.id == previous.id
      assert length(session_versions(schema)) == versions_before + 1
      assert current.status == :active
      assert Repo.get!(EntityDefinition, previous.id, prefix: schema).status == :inactive

      # the added field, and nothing else changed
      assert %{
               "name" => "exam_snapshot",
               "type" => "json",
               "required" => false,
               "queried" => false
             } =
               snapshot_field(current)

      assert current.definition_json["fields"] ==
               previous.definition_json["fields"] ++ [snapshot_field(current)]

      for key <- ["name", "display_name", "indexes", "foreign_keys", "constraints"] do
        assert {key, current.definition_json[key]} == {key, previous.definition_json[key]}
      end

      assert Map.delete(current.definition_json, "fields") ==
               Map.delete(previous.definition_json, "fields")

      assert restriction_pairs(schema) == Enum.sort(Exam.answer_key_fields())

      # the tenant works now
      assert {:ok, view} = start_session(schema)
      assert %{"origin" => "start"} = Fx.session_snapshot(schema, view.id)
    end

    test "a second run is already_current: no new version, no restriction row, same definition" do
      %{schema_name: schema} = pre_rollout_tenant!("gh2682-t37-idem")
      assert %{status: :upgraded} = Rollout.run_tenant(schema, [])
      after_first = active_session!(schema)
      versions = length(session_versions(schema))

      assert %{
               status: :already_current,
               definition: :already_current,
               restrictions_added: 0,
               error: nil
             } = Rollout.run_tenant(schema, [])

      assert active_session!(schema).id == after_first.id
      assert length(session_versions(schema)) == versions
      assert restriction_pairs(schema) == Enum.sort(Exam.answer_key_fields())
    end

    test "OQ-9: on a tenant whose session type is column-promoted, activating the new version issues no DDL and existing sessions stay readable" do
      %{schema_name: schema, tenant_id: tenant_id} = pre_rollout_tenant!("gh2682-t37-promoted")

      assert {:ok, [promotion]} =
               TenantProvisioning.register_column_promotion(
                 "session",
                 "exam_id",
                 %{pg_type: "text", nullable: true},
                 [tenant_id]
               )

      assert {:ok, %{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(promotion.id)

      # a session written BEFORE the rollout, into the promoted per-type table
      %{exam: exam} = StampFx.build_exam!(schema)
      candidate = Ecto.UUID.generate()
      now = DateTime.utc_now()

      legacy =
        Fx.create_record!(schema, "session", %{
          "exam_id" => exam.record_id,
          "user_id" => candidate,
          "status" => "in_progress",
          "seed" => 1,
          "started_at" => DateTime.to_iso8601(now),
          "expires_at" => DateTime.to_iso8601(DateTime.add(now, 3600, :second)),
          "passed" => false
        })

      columns_before = columns(schema)
      promotions_before = promotion_count(tenant_id)
      assert length(columns_before) > 0

      assert Enum.any?(columns_before, fn [table, column | _] ->
               table == "entity_session" and column == "exam_id"
             end)

      assert %{status: :upgraded, definition: :added, error: nil} = Rollout.run_tenant(schema, [])

      assert columns(schema) == columns_before
      assert promotion_count(tenant_id) == promotions_before

      assert {:ok, %{id: legacy_id}} =
               Session.get_session_for_user(legacy.record_id, candidate, schema)

      assert legacy_id == legacy.record_id

      # and a new session writes the snapshot into the promoted type
      assert {:ok, view} = Session.create(Ecto.UUID.generate(), exam.record_id, schema)
      assert %{"v" => 1} = Fx.session_snapshot(schema, view.id)
    end

    test "a dry run reports what a real run would do and writes nothing (definition, restriction rows, columns)" do
      %{schema_name: schema} = pre_rollout_tenant!("gh2682-t37-dry")
      active_before = active_session!(schema)
      versions_before = length(session_versions(schema))
      columns_before = columns(schema)

      report = Rollout.run_tenant(schema, dry_run: true)

      assert %{status: :upgraded, definition: :added, restrictions_added: 5, error: nil} = report

      assert active_session!(schema).id == active_before.id
      assert length(session_versions(schema)) == versions_before
      assert restriction_pairs(schema) == []
      assert columns(schema) == columns_before
    end

    test "REPRO: a stored definition whose optional field keys are JSON null (search_strategy: null) is upgraded, not refused" do
      %{schema_name: schema} = pre_rollout_tenant_with_null_keys!("gh2682-t37-nulls")
      previous = active_session!(schema)

      # the stored shape this test is about
      assert Enum.any?(previous.definition_json["fields"], &Map.has_key?(&1, "search_strategy"))
      assert Enum.any?(previous.definition_json["fields"], &is_nil(&1["search_strategy"]))

      assert %{status: :upgraded, definition: :added, restrictions_added: 5, error: nil} =
               Rollout.run_tenant(schema, [])

      current = active_session!(schema)
      assert snapshot_field(current)

      # diff vs the previous version: the added field, and the nil keys dropped -- nothing else
      drop_nils = fn fields ->
        Enum.map(fields, fn field -> Map.reject(field, fn {_key, value} -> is_nil(value) end) end)
      end

      assert current.definition_json["fields"] ==
               drop_nils.(previous.definition_json["fields"]) ++ [snapshot_field(current)]

      assert Map.delete(current.definition_json, "fields") ==
               Map.delete(previous.definition_json, "fields")
    end

    test "a stored definition with a key or a value the rollout does not know is refused and nothing is written" do
      cases = [
        {"unknown field key with a value", fn field -> Map.put(field, "bogus_key", "x") end,
         :unsupported_definition_key},
        {"unknown field key with a nil value", fn field -> Map.put(field, "bogus_key", nil) end,
         :unsupported_definition_key},
        {"unsupported non-nil search_strategy",
         fn field -> Map.put(field, "search_strategy", "weird") end,
         :unsupported_definition_value},
        {"unsupported field type", fn field -> Map.put(field, "type", "exotic") end,
         :unsupported_definition_value}
      ]

      for {label, mutate, tag} <- cases do
        %{schema_name: schema} =
          pre_rollout_tenant!("gh2682-t37-refuse-#{System.unique_integer([:positive])}")

        active = active_session!(schema)
        [first | rest] = active.definition_json["fields"]
        document = Map.put(active.definition_json, "fields", [mutate.(first) | rest])

        {1, _} =
          Repo.update_all(
            from(d in EntityDefinition, where: d.id == ^active.id),
            [set: [definition_json: document]],
            prefix: schema
          )

        versions = length(session_versions(schema))

        assert {label,
                %{
                  status: :failed,
                  definition: :skipped,
                  restrictions_added: 0,
                  error: {:definition_write_failed, tag}
                }} ==
                 {label,
                  Map.take(Rollout.run_tenant(schema, []), [
                    :status,
                    :definition,
                    :restrictions_added,
                    :error
                  ])}

        assert length(session_versions(schema)) == versions
        assert active_session!(schema).id == active.id
        assert restriction_pairs(schema) == []
      end
    end

    test "a tenant that already has the field but is missing restriction rows: only the rows are added, no new version" do
      %{schema_name: schema} = StampFx.full_tenant!("gh2682-t37-rows-only")
      assert Fx.delete_answer_key_restrictions!(schema) == 5
      active_before = active_session!(schema)
      assert snapshot_field(active_before)

      assert %{status: :upgraded, definition: :already_current, restrictions_added: 5, error: nil} =
               Rollout.run_tenant(schema, [])

      assert active_session!(schema).id == active_before.id
      assert restriction_pairs(schema) == Enum.sort(Exam.answer_key_fields())

      assert %{status: :already_current, restrictions_added: 0} = Rollout.run_tenant(schema, [])
    end

    test "source guard: the rollout writes definitions only through Definitions.create_definition/3 and activate_definition/4" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/modules/exam/snapshot/rollout.ex"))

      assert source =~ "Definitions.create_definition("
      assert source =~ "Definitions.activate_definition("
      refute source =~ ~r/Repo\.(insert|insert_all|update|update_all|delete|delete_all)\b/
      # the tenant id comes from the schema, never from input
      assert source =~ "tenant_id_for_schema_name"
    end
  end

  # ── T-56: report shapes, statuses, entry points ────────────────────────────────────────────

  describe "T-56: report shapes and statuses" do
    test "run(dry_run: true) returns {:ok, report} with the 17.2 keys and this tenant's entry, and writes nothing" do
      %{schema_name: schema} = pre_rollout_tenant!("gh2682-t56-run")

      assert {:ok, report} = Rollout.run(dry_run: true)
      assert Enum.sort(Map.keys(report)) == @report_keys
      assert report.dry_run == true

      mine = report_for(report, schema)
      assert Enum.sort(Map.keys(mine)) == @tenant_report_keys
      assert %{status: :upgraded, definition: :added, restrictions_added: 5} = mine

      assert report.upgraded_total >= 1
      assert report.restrictions_added_total >= 5
      assert is_integer(report.conflict_total) and is_integer(report.failed_total)

      refute snapshot_field(active_session!(schema))
      assert restriction_pairs(schema) == []
    end

    test "the release wrapper returns the same report shape and reaches the rollout only through the exam module" do
      %{schema_name: schema} = pre_rollout_tenant!("gh2682-t56-release")

      report = Release.rollout(dry_run: true, lock_timeout_ms: 1, bogus: true)

      assert Enum.sort(Map.keys(report)) == @report_keys
      assert report.dry_run == true
      assert %{status: :upgraded} = report_for(report, schema)
      refute snapshot_field(active_session!(schema))

      # the sanctioned route (boundary rule 5): the exam module's delegates, not its internals
      assert {:ok, %{dry_run: true}} = Exam.snapshot_rollout(dry_run: true)
      assert %{ready: ready, tenants: tenants} = Exam.snapshot_verify()
      assert is_boolean(ready) and is_list(tenants)
    end

    test "verify/0 reports per exam-installed tenant whether the definition and the restriction rows are in place, and ready only when all are" do
      %{schema_name: schema} = pre_rollout_tenant!("gh2682-t56-verify")

      before = Rollout.verify()
      assert Enum.sort(Map.keys(before)) == [:ready, :tenants]

      entry = Enum.find(before.tenants, &(&1.schema_name == schema))

      assert entry == %{
               schema_name: schema,
               session_definition: false,
               answer_key_restrictions: false
             }

      assert before.ready == false

      assert %{status: :upgraded} = Rollout.run_tenant(schema, [])

      after_run = Rollout.verify()
      entry = Enum.find(after_run.tenants, &(&1.schema_name == schema))

      assert entry == %{
               schema_name: schema,
               session_definition: true,
               answer_key_restrictions: true
             }

      assert Release.verify() == Rollout.verify()
    end

    test "verify/0 reports a tenant that has the field but a missing restriction row as not ready" do
      %{schema_name: schema} = StampFx.full_tenant!("gh2682-t56-verify-rows")

      {1, _} =
        Repo.delete_all(
          from(r in "entity_field_restrictions",
            where: r.entity_type == "session" and r.field_name == "exam_snapshot"
          ),
          prefix: schema
        )

      entry = Enum.find(Rollout.verify().tenants, &(&1.schema_name == schema))

      assert entry == %{
               schema_name: schema,
               session_definition: true,
               answer_key_restrictions: false
             }

      assert Rollout.verify().ready == false
    end

    test "a tenant with the exam module but no active session definition is a failed report carrying a tag, nothing written" do
      %{schema_name: schema} = StampFx.bare_tenant!("gh2682-t56-nodef", true)

      assert %{
               status: :failed,
               definition: :skipped,
               restrictions_added: 0,
               error: {:definition_write_failed, :no_active_session_definition}
             } = Rollout.run_tenant(schema, [])

      assert restriction_pairs(schema) == []
    end

    test "a tenant without the exam module is :exam_not_installed and untouched" do
      %{schema_name: schema} = Fx.provisioned_tenant_without_module_install("gh2682-t56-noexam")
      versions = length(session_versions(schema))

      assert %{
               status: :exam_not_installed,
               definition: :skipped,
               restrictions_added: 0,
               error: nil
             } =
               Rollout.run_tenant(schema, [])

      assert length(session_versions(schema)) == versions
    end

    test "an unknown schema is :skipped_schema_missing, and a call inside an open transaction is a failed :nested_transaction report" do
      assert %{status: :skipped_schema_missing, tenant_id: nil} =
               Rollout.run_tenant("no_such_schema", [])

      %{schema_name: schema} = pre_rollout_tenant!("gh2682-t56-nested")

      assert {:ok, %{status: :failed, error: :nested_transaction}} =
               Repo.transaction(fn -> Rollout.run_tenant(schema, []) end)

      refute snapshot_field(active_session!(schema))
    end

    test "a session field named exam_snapshot of ANOTHER type is a :conflict and nothing is written" do
      %{schema_name: schema} = StampFx.bare_tenant!("gh2682-t56-conflict", true)

      for name <- StampFx.authoring_types() ++ (StampFx.runtime_types() -- ["session"]) do
        StampFx.create_definition!(
          schema,
          Map.put(StampFx.legacy_definition(name), :constraints, [])
        )

        StampFx.activate!(schema, name)
      end

      conflicting =
        StampFx.legacy_definition("session")
        |> Map.update!(:fields, fn fields ->
          Enum.reject(fields, &(&1.name == "exam_snapshot")) ++
            [StampFx.field("exam_snapshot", :string)]
        end)
        |> Map.put(:constraints, [])

      StampFx.create_definition!(schema, conflicting)
      StampFx.activate!(schema, "session")
      :ok = Exam.on_install(schema, %{})
      versions = length(session_versions(schema))

      assert %{status: :conflict, definition: :conflict, restrictions_added: 0, error: nil} =
               Rollout.run_tenant(schema, [])

      assert length(session_versions(schema)) == versions

      assert {:ok, report} = Rollout.run(dry_run: true)
      assert %{status: :conflict} = report_for(report, schema)
      assert report.conflict_total >= 1
    end
  end

  # ── the Mix task ───────────────────────────────────────────────────────────────────────────

  describe "T-56: mix letflow.exam_snapshot_rollout" do
    test "bad arguments raise the usage; nothing runs" do
      for argv <- [["--bogus"], ["extra-positional"], ["--dry-run", "extra"]] do
        assert_raise Mix.Error, ~r/usage: mix letflow.exam_snapshot_rollout/, fn ->
          RolloutTask.run(argv)
        end
      end
    end

    test "--dry-run prints the summary and this tenant's line, and writes nothing" do
      %{schema_name: schema, tenant_id: tenant_id} = pre_rollout_tenant!("gh2682-t56-task")

      # The task halts the VM (System.halt(1)) when ANY registered tenant of this database failed
      # or conflicted; a dry run is only safe to execute in-process when the sweep is clean.
      {:ok, probe} = Rollout.run(dry_run: true)

      if probe.failed_total == 0 and probe.conflict_total == 0 do
        output = capture_io(fn -> RolloutTask.run(["--dry-run"]) end)

        assert output =~ "exam snapshot rollout complete (dry run)"
        assert output =~ "tenant #{tenant_id}: upgraded, definition added, 5 restriction(s) added"
      end

      refute snapshot_field(active_session!(schema))
      assert restriction_pairs(schema) == []
    end

    test "the task halts non-zero on a failed or conflicting tenant (source guard: System.halt(1) is not callable in-process)" do
      source =
        File.read!(Path.join(File.cwd!(), "lib/mix/tasks/letflow.exam_snapshot_rollout.ex"))

      assert source =~ "report.failed_total > 0 or report.conflict_total > 0"
      assert source =~ "System.halt(1)"
    end
  end
end
