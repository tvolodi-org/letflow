defmodule Letflow.Entities.ManagedTypes.StampTest do
  @moduledoc """
  GH #2596, design `lib/letflow/design/gh2596-exam-managed-types.md` sections 6 and 7 and tests
  T-14..T-19 (spec `test/specs/GH2596-exam-managed.md`): `Letflow.Entities.ManagedTypes.Stamp`, its
  release wrapper and the Mix task, against real provisioned tenants.

  Runs OUTSIDE the Ecto sandbox transaction (SECURITY F-1): `async: false`; the tenant fixtures
  switch `Ecto.Adapters.SQL.Sandbox` to `:auto`, so `Stamp` really begins and commits its own
  transaction (inside an outer one it would refuse with `:nested_transaction`). Teardown drops the
  tenant schemas (`on_exit`).

  The four migration cases (design section 7):

    * (a) fresh install: `Installs.install("exam", ...)` stamps the six at insert, the stamp adds 0;
    * (b) installed before the change, in three builds of the six rows: b1 FK-stripped legacy, b2
      pack-shaped, b3 hand-posted (extra tenant field, no indexes); plus b4, `certificate` absent;
    * (c) a same-named non-exam type: a named conflict, never stamped, the sweep continues;
    * (d) no exam: untouched.

  `Stamp.run/1` sweeps EVERY registered tenant of the test database; assertions on a sweep pick the
  reports of this test's own tenants by schema name.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.ManagedTypes.Stamp
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.ExamFixtures
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Modules.Installs
  alias Mix.Tasks.Letflow.StampManagedTypes

  import ExUnit.CaptureIO

  @six Fx.runtime_types()
  @ten Fx.authoring_types()

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp run!(schema, opts \\ []), do: Stamp.run_tenant(schema, opts)

  # Legacy (FK-stripped) definitions for the given runtime names, created inactive as `:tenant`.
  defp legacy_defs!(schema, names), do: for(name <- names, do: legacy_def!(schema, name))

  defp legacy_def!(schema, name, transform \\ & &1) do
    Fx.create_definition!(schema, transform.(Fx.legacy_definition(name)))
  end

  defp with_extra_field(definition),
    do: Map.update!(definition, :fields, &(&1 ++ [Fx.field("tenant_extra", :string)]))

  defp without_field(definition, name),
    do: Map.update!(definition, :fields, fn fields -> Enum.reject(fields, &(&1.name == name)) end)

  defp retyped(definition, name, type) do
    Map.update!(definition, :fields, fn fields ->
      Enum.map(fields, fn
        %{name: ^name} = field ->
          %{field | type: type, decimal_precision: nil, decimal_scale: nil}

        field ->
          field
      end)
    end)
  end

  defp unrelated_certificate do
    %{
      name: "certificate",
      display_name: "Tenant certificate",
      fields: [Fx.field("foo", :string), Fx.field("bar", :integer)]
    }
  end

  # A tenant with the exam row, the 5 legacy runtime types other than certificate, and a
  # certificate definition built by `certificate_fun` (given the schema).
  defp tenant_with_certificate!(slug, certificate_fun) do
    tenant = Fx.bare_tenant!(slug, true)
    legacy_defs!(tenant.schema_name, @six -- ["certificate"])
    certificate_fun.(tenant.schema_name)
    tenant
  end

  defp stamped_by_name(schema), do: schema |> Fx.managed_by_map() |> Map.take(@six)

  defp assert_all_stamped!(schema) do
    for {name, values} <- stamped_by_name(schema), do: assert(values == ["exam"], name)
  end

  defp audit_entries(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT actor_id, resource_type, resource_id::text, after_state::text | <>
          ~s|FROM "#{schema}".audit_entries WHERE action = 'entity_type.managed_by_stamped'|
      )

    rows
  end

  defp session_values(exam_id, user_id) do
    now = DateTime.utc_now()

    %{
      "exam_id" => exam_id,
      "user_id" => user_id,
      "status" => "in_progress",
      "seed" => 1,
      "started_at" => DateTime.to_iso8601(now),
      "expires_at" => DateTime.to_iso8601(DateTime.add(now, 3600, :second)),
      "passed" => false
    }
  end

  defp report_for(report, schema), do: Enum.find(report.tenants, &(&1.schema_name == schema))

  # ── (a) T-15 ────────────────────────────────────────────────────────────────────────────────

  describe "T-15 (AC4a): fresh install" do
    test "install stamps exactly the six at insert; the ten stay NULL; the stamp adds 0" do
      %{schema_name: schema} = Fx.bare_tenant!("gh2596-fresh", false)

      assert {:ok, _tenant_module} =
               Installs.install("exam", Ecto.UUID.generate(),
                 prefix: schema,
                 rationale: "GH #2596 test: fresh install"
               )

      map = Fx.managed_by_map(schema)
      assert Enum.sort(Map.keys(map)) == Enum.sort(@six ++ @ten)
      for name <- @six, do: assert(map[name] == ["exam"], name)
      for name <- @ten, do: assert(map[name] == [nil], name)

      for name <- @six, do: assert(ManagedTypes.owner_of(name, schema) == {:ok, "exam"}, name)
      for name <- @ten, do: assert(ManagedTypes.owner_of(name, schema) == :unmanaged, name)

      before = Fx.dump(schema, @six ++ @ten)

      assert %{
               status: :nothing_to_stamp,
               rows_stamped: 0,
               rows_already_stamped: 6,
               types_stamped: [],
               types_absent: [],
               conflicts: [],
               error: nil
             } = run!(schema)

      assert Fx.dump(schema, @six ++ @ten) == before
      assert Fx.stamp_audit_count(schema) == 0
    end
  end

  # ── (b) T-14 ────────────────────────────────────────────────────────────────────────────────

  describe "T-14 (AC4b): installed before the change" do
    test "b1 FK-stripped legacy rows: all six stamped, the authoring rows byte-identical, a re-run adds nothing" do
      %{tenant_id: tenant_id, schema_name: schema} = Fx.legacy_tenant!("gh2596-b1")

      # Content of the runtime types written BEFORE the stamp, as :tenant.
      session =
        ExamFixtures.create_record!(
          schema,
          "session",
          session_values(Ecto.UUID.generate(), Ecto.UUID.generate())
        )

      {:ok, record_before} = Latest.get(session.record_id, "session", schema)
      ten_before = Fx.dump(schema, @ten)
      assert Enum.all?(Map.values(stamped_by_name(schema)), &(&1 == [nil]))

      report = run!(schema)

      assert %{
               status: :stamped,
               tenant_id: ^tenant_id,
               schema_name: ^schema,
               rows_stamped: 6,
               rows_already_stamped: 0,
               types_absent: [],
               conflicts: [],
               exam_named_types_present: [],
               error: nil
             } = report

      assert Enum.sort(report.types_stamped) == Enum.sort(@six)
      assert_all_stamped!(schema)
      assert Fx.dump(schema, @ten) == ten_before
      assert Fx.stamp_audit_count(schema) == 1

      # Records written before the stamp are untouched.
      assert {:ok, ^record_before} = Latest.get(session.record_id, "session", schema)

      # A tenant write of a now-managed type is refused.
      assert {:error, :entity_type_managed} =
               Records.create_record(
                 %{
                   entity_type: "session",
                   field_values: session_values(Ecto.UUID.generate(), Ecto.UUID.generate()),
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 schema
               )

      # Second run: 0, no new audit entry, definitions byte-identical.
      six_after_first = Fx.dump(schema, @six)

      assert %{status: :nothing_to_stamp, rows_stamped: 0, rows_already_stamped: 6, error: nil} =
               run!(schema)

      assert Fx.stamp_audit_count(schema) == 1
      assert Fx.dump(schema, @six) == six_after_first
    end

    test "b2 pack-shaped rows (full foreign keys, installed as :tenant): all six stamped; the ten stay NULL" do
      %{schema_name: schema} = Fx.bare_tenant!("gh2596-b2", true)
      :ok = Fx.install_pack!(schema)

      map = Fx.managed_by_map(schema)
      assert Enum.sort(Map.keys(map)) == Enum.sort(@six ++ @ten)
      assert Enum.all?(Map.values(map), &(&1 == [nil]))
      ten_before = Fx.dump(schema, @ten)

      assert %{status: :stamped, rows_stamped: 6, conflicts: [], error: nil} = run!(schema)

      assert_all_stamped!(schema)
      assert Fx.dump(schema, @ten) == ten_before
      for name <- @ten, do: assert(Fx.managed_by_map(schema)[name] == [nil], name)

      assert %{status: :nothing_to_stamp, rows_stamped: 0} = run!(schema)
      assert Fx.stamp_audit_count(schema) == 1
    end

    test "b3 hand-posted rows (an extra tenant field, no indexes): stamped, with the extra field listed in differences by NAME only" do
      %{schema_name: schema} = Fx.bare_tenant!("gh2596-b3", true)

      for name <- @six do
        Fx.create_definition!(
          schema,
          name |> Fx.legacy_definition() |> with_extra_field() |> Map.put(:indexes, [])
        )
      end

      dry = run!(schema, dry_run: true)
      assert dry.rows_stamped == 6
      assert Enum.all?(Map.values(stamped_by_name(schema)), &(&1 == [nil]))

      for name <- @six do
        assert %{extra_fields: ["tenant_extra"], differing: differing} =
                 Enum.find(dry.differences, &(&1.type == name))

        # The pack defines indexes for these four (the other two define unique constraints).
        if name in ~w(certificate session session_event session_question_score),
          do: assert(:indexes in differing, name),
          else: assert(:constraints in differing, name)
      end

      assert %{status: :stamped, rows_stamped: 6, error: nil} = run!(schema)
      assert_all_stamped!(schema)
    end

    test "b4 certificate absent (the expected QA/BilimBaga state): reported in types_absent, nothing created, the other five stamped" do
      %{schema_name: schema} = Fx.bare_tenant!("gh2596-b4", true)
      legacy_defs!(schema, @six -- ["certificate"])

      report = run!(schema)

      assert %{status: :stamped, rows_stamped: 5, types_absent: ["certificate"], error: nil} =
               report

      assert Enum.sort(report.types_stamped) == Enum.sort(@six -- ["certificate"])
      refute Map.has_key?(Fx.managed_by_map(schema), "certificate")
      assert Fx.dump(schema, ["certificate"]) == []
    end
  end

  # ── (c) T-16 ────────────────────────────────────────────────────────────────────────────────

  describe "T-16 (AC4c): a same-named non-exam type" do
    test "an unrelated shape: named conflict with the tenant id and type, row untouched, the other five stamped" do
      %{tenant_id: tenant_id, schema_name: schema} =
        tenant_with_certificate!(
          "gh2596-c-unrelated",
          &Fx.create_definition!(&1, unrelated_certificate())
        )

      cert_before = Fx.dump(schema, ["certificate"])

      report = run!(schema)

      assert %{
               status: :stamped,
               tenant_id: ^tenant_id,
               rows_stamped: 5,
               conflicts: [%{type: "certificate", reason: :shape_not_compatible, rows: 1}]
             } = report

      assert Fx.dump(schema, ["certificate"]) == cert_before
      assert Fx.managed_by_map(schema)["certificate"] == [nil]

      for name <- @six -- ["certificate"],
          do: assert(Fx.managed_by_map(schema)[name] == ["exam"], name)
    end

    test "a pack field with the wrong TYPE, and a missing pack field, are conflicts; a superset is not" do
      wrong_type =
        tenant_with_certificate!("gh2596-c-wrongtype", fn schema ->
          legacy_def!(schema, "certificate", &retyped(&1, "score_pct", :string))
        end)

      missing =
        tenant_with_certificate!("gh2596-c-missing", fn schema ->
          legacy_def!(schema, "certificate", &without_field(&1, "branding_snapshot"))
        end)

      superset =
        tenant_with_certificate!("gh2596-c-superset", fn schema ->
          legacy_def!(schema, "certificate", &with_extra_field/1)
        end)

      for %{schema_name: schema} <- [wrong_type, missing] do
        assert %{status: :stamped, rows_stamped: 5, conflicts: [conflict]} = run!(schema)
        assert %{type: "certificate", reason: :shape_not_compatible} = conflict
        assert Fx.managed_by_map(schema)["certificate"] == [nil]
      end

      assert %{status: :stamped, rows_stamped: 6, conflicts: []} = run!(superset.schema_name)
      assert Fx.managed_by_map(superset.schema_name)["certificate"] == ["exam"]
    end

    test "required/enum/constraint differences are NOT conflicts but are listed in differences (names only)" do
      %{schema_name: schema} =
        tenant_with_certificate!("gh2596-c-diff", fn schema ->
          legacy_def!(schema, "certificate", fn definition ->
            Map.update!(definition, :fields, fn fields ->
              Enum.map(fields, fn
                %{name: "session_id"} = field -> %{field | required: false}
                field -> field
              end)
            end)
          end)
        end)

      dry = run!(schema, dry_run: true)
      assert dry.conflicts == []

      assert %{extra_fields: [], differing: differing} =
               Enum.find(dry.differences, &(&1.type == "certificate"))

      assert :required in differing
    end

    test "OLDER-VERSION variants (SECURITY F-3): the whole name conflicts if ANY version is incompatible; all compatible -> all rows stamped" do
      hostile_then_good =
        tenant_with_certificate!("gh2596-c-v1bad", fn schema ->
          Fx.create_definition!(schema, unrelated_certificate())
          legacy_def!(schema, "certificate")
        end)

      good_then_hostile =
        tenant_with_certificate!("gh2596-c-v2bad", fn schema ->
          legacy_def!(schema, "certificate")
          Fx.create_definition!(schema, unrelated_certificate())
        end)

      all_good =
        tenant_with_certificate!("gh2596-c-allgood", fn schema ->
          legacy_def!(schema, "certificate")
          legacy_def!(schema, "certificate", &with_extra_field/1)
        end)

      for %{schema_name: schema} <- [hostile_then_good, good_then_hostile] do
        assert length(Fx.dump(schema, ["certificate"])) == 2
        before = Fx.dump(schema, ["certificate"])

        assert %{status: :stamped, rows_stamped: 5, conflicts: [conflict]} = run!(schema)
        assert %{type: "certificate", reason: :shape_not_compatible, rows: 1} = conflict

        # NEITHER row of the name is stamped (premise: every row of a managed name carries one stamp).
        assert Fx.dump(schema, ["certificate"]) == before
        assert Fx.managed_by_map(schema)["certificate"] == [nil]
      end

      assert %{status: :stamped, rows_stamped: 7, conflicts: []} = run!(all_good.schema_name)
      assert Fx.managed_by_map(all_good.schema_name)["certificate"] == ["exam"]
      assert length(Fx.dump(all_good.schema_name, ["certificate"])) == 2
    end

    test "a runtime-named row already stamped by another module is :stamped_by_other_module, untouched" do
      %{schema_name: schema} =
        tenant_with_certificate!("gh2596-c-other", fn schema ->
          row = legacy_def!(schema, "certificate")
          Fx.insert_stamped_copy!(schema, row, "other_module")
        end)

      assert %{status: :stamped, rows_stamped: 5, conflicts: [conflict]} = run!(schema)
      assert %{type: "certificate", reason: :stamped_by_other_module, rows: 1} = conflict
      assert Fx.managed_by_map(schema)["certificate"] == [nil, "other_module"]
    end

    test "a tenant-created authoring-named type (tag) is untouched and NOT reported" do
      %{schema_name: schema} = Fx.bare_tenant!("gh2596-c-tag", true)
      legacy_defs!(schema, @six)

      Fx.create_definition!(schema, %{
        name: "tag",
        display_name: "My tag",
        fields: [Fx.field("whatever", :string)]
      })

      tag_before = Fx.dump(schema, ["tag"])
      report = run!(schema)

      assert %{status: :stamped, rows_stamped: 6, conflicts: [], types_absent: []} = report
      assert Fx.dump(schema, ["tag"]) == tag_before
      refute "tag" in report.types_stamped
    end

    test "a sweep continues past a conflicted tenant: the conflict tenant and a clean legacy tenant both get their reports" do
      conflict_tenant =
        tenant_with_certificate!(
          "gh2596-c-sweep-a",
          &Fx.create_definition!(&1, unrelated_certificate())
        )

      clean_tenant = Fx.legacy_tenant!("gh2596-c-sweep-b")

      assert {:ok, report} = Stamp.run([])

      conflicted = report_for(report, conflict_tenant.schema_name)
      clean = report_for(report, clean_tenant.schema_name)

      assert %{status: :stamped, rows_stamped: 5, conflicts: [%{type: "certificate"}]} =
               conflicted

      assert %{status: :stamped, rows_stamped: 6, conflicts: []} = clean
      assert report.conflict_total >= 1
      assert report.rows_stamped_total >= 11
      assert_all_stamped!(clean_tenant.schema_name)
    end

    @tag timeout: 120_000
    test "RACE (SECURITY F-4): an incompatible NEW version created after the advisory pre-pass is classified under the locks" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2596-c-race")

      hook = fn hook_schema ->
        if hook_schema == schema do
          Fx.create_definition!(schema, unrelated_certificate())
        end

        :ok
      end

      report = run!(schema, after_precheck: hook)

      # The advisory pass saw `certificate` compatible; the locked re-classification saw the new
      # incompatible version and refused the whole name.
      assert %{status: :stamped, rows_stamped: 5, error: nil} = report
      assert [%{type: "certificate", reason: :shape_not_compatible}] = report.conflicts
      assert Fx.managed_by_map(schema)["certificate"] == [nil]

      for name <- @six -- ["certificate"],
          do: assert(Fx.managed_by_map(schema)[name] == ["exam"], name)
    end

    @tag timeout: 120_000
    test "RACE variant: a second connection creating an incompatible version blocks on the name lock while the stamp holds it, then is refused as managed" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2596-c-race2")
      parent = self()

      %{rows: [[session_event_id]]} =
        Repo.query!(
          ~s|SELECT id::text FROM "#{schema}".entity_definitions WHERE name = 'session_event'|
        )

      # Connection A holds a row lock on the session_event row, so the stamp (which has already
      # taken the 496_001 name locks for all six names) waits at its FOR UPDATE.
      holder =
        Task.async(fn ->
          Repo.transaction(
            fn ->
              Repo.query!(
                ~s|SELECT 1 FROM "#{schema}".entity_definitions WHERE id = $1 FOR UPDATE|,
                [Ecto.UUID.dump!(session_event_id)]
              )

              send(parent, :holder_locked)

              receive do
                :release -> :ok
              end
            end,
            timeout: :infinity
          )
        end)

      assert_receive :holder_locked, 30_000

      stamp_task = Task.async(fn -> Stamp.run_tenant(schema, lock_timeout_ms: 60_000) end)
      wait_until_blocked(1)

      # Connection C: an incompatible NEW version of a stampable name takes the same name lock.
      creator =
        Task.async(fn ->
          Definitions.create_definition(
            %{definition: unrelated_certificate(), created_by: Ecto.UUID.generate()},
            schema
          )
        end)

      # It is blocked behind the stamp's name locks (two backends now wait on a lock): it cannot
      # have finished.
      wait_until_blocked(2)
      assert Task.yield(creator, 0) == nil

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 30_000)
      assert %{status: :stamped, rows_stamped: 6, error: nil} = Task.await(stamp_task, 60_000)

      # After the commit the name is managed: the creator is refused.
      assert {:error, :entity_type_managed} = Task.await(creator, 60_000)
      assert Fx.managed_by_map(schema)["certificate"] == ["exam"]
      assert length(Fx.dump(schema, ["certificate"])) == 1
    end
  end

  # Polls pg_stat_activity (this test database only: pg_locks is cluster-wide, so a backend waiting in
  # another parallel test partition's database counted too and made the wait return early) until
  # `count` sessions are waiting on a lock (the stamp on a row lock, the
  # creator on an advisory lock). Bounded; no sleeping beyond the poll interval.
  defp wait_until_blocked(count, attempts \\ 300) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()"
      )

    cond do
      waiting >= count -> :ok
      attempts == 0 -> flunk("expected #{count} backend(s) waiting on a lock, saw #{waiting}")
      true -> Process.sleep(50) && wait_until_blocked(count, attempts - 1)
    end
  end

  # ── (d) T-17 ────────────────────────────────────────────────────────────────────────────────

  describe "T-17 (AC4d): no exam" do
    test "a tenant without the exam module is untouched, whether or not it holds an unrelated session" do
      %{schema_name: with_session} = Fx.bare_tenant!("gh2596-d-session", false)
      legacy_def!(with_session, "session")
      %{schema_name: empty} = Fx.bare_tenant!("gh2596-d-empty", false)

      before = Fx.dump(with_session, ["session"])
      assert [%{managed_by: nil}] = before

      assert %{
               status: :exam_not_installed,
               rows_stamped: 0,
               exam_named_types_present: ["session"],
               conflicts: [],
               error: nil
             } = run!(with_session)

      assert %{status: :exam_not_installed, rows_stamped: 0, exam_named_types_present: []} =
               run!(empty)

      assert Fx.dump(with_session, ["session"]) == before
      assert Fx.stamp_audit_count(with_session) == 0
    end

    test ":exception_not_installed: a tenant whose schema_migrations lacks the exception version is reported, not touched; restoring it lets the stamp proceed" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2596-d-noexception")
      :ok = Fx.forget_exception_migration!(schema)
      before = Fx.dump(schema, @six)

      assert %{status: :exception_not_installed, rows_stamped: 0, error: nil} = run!(schema)
      assert %{status: :exception_not_installed} = run!(schema, dry_run: true)
      assert Fx.dump(schema, @six) == before

      :ok = Fx.remember_exception_migration!(schema)
      assert %{status: :stamped, rows_stamped: 6} = run!(schema)
    end
  end

  # ── T-18 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-18 (AC3): dry run, unsupported module, the audit entry" do
    test "a dry run writes nothing and reports the rows it would stamp plus differences (names only)" do
      %{schema_name: schema} =
        tenant_with_certificate!("gh2596-dry", fn schema ->
          legacy_def!(schema, "certificate", fn definition ->
            definition
            |> with_extra_field()
            |> Map.update!(:fields, fn fields ->
              Enum.map(fields, fn
                %{name: "session_id"} = field -> %{field | required: false}
                field -> field
              end)
            end)
          end)
        end)

      before = Fx.dump(schema, @six)

      dry = run!(schema, dry_run: true)

      assert %{status: :stamped, rows_stamped: 6, conflicts: [], error: nil} = dry
      assert Fx.dump(schema, @six) == before
      assert Fx.stamp_audit_count(schema) == 0
      assert Enum.all?(Map.values(stamped_by_name(schema)), &(&1 == [nil]))

      assert %{extra_fields: ["tenant_extra"], differing: differing} =
               Enum.find(dry.differences, &(&1.type == "certificate"))

      assert :required in differing

      # Names and attribute keys only: no definition body or field value anywhere in the report.
      flat = inspect(dry, limit: :infinity)
      refute flat =~ "definition_json"
      refute Map.has_key?(dry, :definition_json)
    end

    test "run(module: \"other\") -> {:error, :unsupported_module}" do
      assert {:error, :unsupported_module} = Stamp.run(module: "other")
      assert {:error, :unsupported_module} = Stamp.run(module: "other", dry_run: true)
      assert {:error, :unsupported_module} = Letflow.Release.ManagedTypes.stamp(module: "other")
    end

    test "the audit entry carries the action, names and counts only; the ten authoring rows are byte-identical" do
      %{tenant_id: tenant_id, schema_name: schema} = Fx.legacy_tenant!("gh2596-audit")
      ten_present = Fx.dump(schema, @ten)
      assert ten_present != []

      assert %{status: :stamped, rows_stamped: 6} = run!(schema)

      assert [[actor_id, "entity_definitions", resource_id, after_state]] = audit_entries(schema)
      assert actor_id == nil
      assert resource_id == tenant_id

      decoded = Jason.decode!(after_state)

      assert Enum.sort(Map.keys(decoded)) ==
               ~w(conflicts module rows_stamped source types_stamped)

      assert %{"module" => "exam", "rows_stamped" => 6, "source" => "release_stamp"} = decoded
      assert Enum.sort(decoded["types_stamped"]) == Enum.sort(@six)
      refute after_state =~ "definition_json"
      refute after_state =~ "fields"

      assert Fx.dump(schema, @ten) == ten_present
    end
  end

  # ── T-19 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-19 (AC3, INV-8): failure isolation, the wrapper, the Mix task" do
    @tag timeout: 120_000
    test "a row lock held by a second connection fails THAT tenant with :lock_timeout, nothing stamped; other tenants stamped; a re-run after release completes" do
      locked = Fx.legacy_tenant!("gh2596-lock-a")
      free = Fx.legacy_tenant!("gh2596-lock-b")
      parent = self()

      %{rows: [[row_id]]} =
        Repo.query!(
          ~s|SELECT id::text FROM "#{locked.schema_name}".entity_definitions WHERE name = 'session'|
        )

      holder =
        Task.async(fn ->
          Repo.transaction(
            fn ->
              Repo.query!(
                ~s|SELECT 1 FROM "#{locked.schema_name}".entity_definitions WHERE id = $1 FOR UPDATE|,
                [Ecto.UUID.dump!(row_id)]
              )

              send(parent, :holder_locked)

              receive do
                :release -> :ok
              end
            end,
            timeout: :infinity
          )
        end)

      assert_receive :holder_locked, 30_000

      assert {:ok, report} = Stamp.run(lock_timeout_ms: 200)

      failed = report_for(report, locked.schema_name)
      ok = report_for(report, free.schema_name)

      assert %{status: :failed, error: :lock_timeout, rows_stamped: 0} = failed
      assert Enum.all?(Map.values(stamped_by_name(locked.schema_name)), &(&1 == [nil]))
      assert %{status: :stamped, rows_stamped: 6, error: nil} = ok
      assert report.failed_total >= 1

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 30_000)

      assert %{status: :stamped, rows_stamped: 6, error: nil} = run!(locked.schema_name)
      assert_all_stamped!(locked.schema_name)
    end

    test "the release wrapper forwards only :module and :dry_run (the after_precheck seam and lock tuning are dropped)" do
      %{schema_name: schema} = Fx.legacy_tenant!("gh2596-wrapper")

      seam = fn hook_schema ->
        if hook_schema == schema,
          do: raise("the test-only seam must not be reachable from the wrapper")

        :ok
      end

      assert {:ok, report} =
               Letflow.Release.ManagedTypes.stamp(
                 module: "exam",
                 after_precheck: seam,
                 lock_timeout_ms: 1
               )

      assert %{status: :stamped, rows_stamped: 6, error: nil} = report_for(report, schema)
    end

    test "the Mix task: --dry-run prints a summary and a conflict line and stamps nothing; bad arguments raise the usage" do
      conflicted =
        tenant_with_certificate!(
          "gh2596-mix",
          &Fx.create_definition!(&1, unrelated_certificate())
        )

      before = Fx.dump(conflicted.schema_name, @six)

      output = capture_io(fn -> StampManagedTypes.run(["--dry-run"]) end)

      assert output =~ "managed-type stamp complete (dry run)"
      assert output =~ "conflict: certificate (shape_not_compatible, 1 row(s))"
      assert output =~ "tenant #{conflicted.tenant_id}:"
      assert Fx.dump(conflicted.schema_name, @six) == before

      for argv <- [["--bogus"], ["extra-positional"], ["--module"]] do
        assert_raise Mix.Error, ~r/usage: mix letflow.stamp_managed_types/, fn ->
          StampManagedTypes.run(argv)
        end
      end

      assert_raise Mix.Error, ~r/unsupported module/, fn ->
        StampManagedTypes.run(["--module", "other"])
      end
    end
  end
end
