defmodule Mix.Tasks.Letflow.Seed.ExamFixturesTest do
  @moduledoc """
  REQ-345 -- coverage for `Mix.Tasks.Letflow.Seed.ExamFixtures`
  (`lib/mix/tasks/letflow.seed.exam_fixtures.ex`), the mix task that seeds two
  published bpm-default exam fixtures and one submitted candidate session for
  e2e (REQ-346/REQ-349) consumption.

  Spec: `test/specs/REQ-345.md` -- full acceptance-criteria coverage map and
  the reasoning behind each assertion below. No mutation-testing report is
  attached: this is a WF-02 test for brand-new code, not a WF-03 regression
  test, per this run's own TEST-DESIGNER task instructions.

  ## Why real Postgres, `:auto` sandbox mode, not a sandboxed transaction

  `ExamFixtures.run/1` calls `Mix.Task.run("letflow.seed")`, which provisions
  a real tenant schema and replays its migrations (real DDL, committed
  outside any transaction) -- the exact same reason
  `test/mix/tasks/letflow.seed_test.exs` sets `Sandbox.mode(Letflow.Repo,
  :auto)` and does its own manual `on_exit/1` cleanup rather than relying on
  `Letflow.DataCase`'s usual per-test rollback. This file follows that same
  established convention (and its `cleanup_bpm_default/0` helper, adapted
  here to the same tenant realm) rather than inventing a second one.

  ## Why `ExamFixtures.run/1` is called directly, not via `Mix.Task.run/1`

  Same reasoning as `letflow.seed_test.exs`'s own moduledoc:
  `Mix.Task.run/1` caches "already ran" per task name for the life of the
  BEAM process, so a second `Mix.Task.run("letflow.seed.exam_fixtures")`
  call within the idempotency test would silently no-op instead of
  re-invoking the task's real logic. `ExamFixtures.run/1` is a plain
  function, not task-run-once-gated, so calling it directly is what actually
  exercises a second real run.

  ## Reading seeded content back

  Entity-record content (`exam`/`category`/`question`/`exam_question_rule`/
  `session`) is read back via `Letflow.Entities.Record.Latest` directly --
  the same `entity_record_latest` table `Letflow.Entities.Records.create_record/2`
  itself writes to -- rather than through the compiled `POST /entities/query`
  route surface, since that route requires a second authenticated HTTP round
  trip this file has no other reason to set up. `Letflow.Modules.Exam.Session.submit/3`
  IS called directly for the session-outcome assertions (see AC4 in the spec)
  because the claim under test -- "status grading_pending, passed nil" -- is a
  property of `submit/3`'s own return value, not of the raw persisted row (the
  persisted `field_values["passed"]` is `false`, never `nil` --
  `lib/letflow/modules/exam/session.ex:1068` -- so asserting on the raw row would not
  actually prove the claim REQ-345 makes).

  ## IMPLEMENTATION FINDING (flagged, not fixed here -- see handoff)

  `mix letflow.seed` (`lib/mix/tasks/letflow.seed.ex`) provisions the
  `bpm-default` tenant schema and replays its migrations ONLY -- it installs
  zero entity definitions (its own `@moduledoc` says so). Empirically, a
  bare `Mix.Tasks.Letflow.Seed.ExamFixtures.run([])` against a schema with
  no entity definitions activated fails immediately with
  `Mix.Error: ... create_record/2(category, ...): {:definition_not_found,
  "category"}` -- proven while writing this test file. Nothing in
  `Mix.Tasks.Letflow.Seed.ExamFixtures` itself, nor in `mix letflow.seed`,
  installs/activates the bilimbaga entity definitions this task's every
  write depends on. This test's `setup` therefore does that activation step
  itself, via the real `priv/packs/bilimbaga/entity_definitions/*.json`
  documents (`Letflow.ExamFixtures.activate_exam_definitions!/1`, added to
  `test/support/exam_fixtures.ex` alongside this file, reusing that
  module's existing `create_active_definition!/2`/`load_definition!/1`
  helpers rather than duplicating them) -- but a REAL e2e/CI setup script
  invoking only `mix letflow.seed.exam_fixtures` on a genuinely fresh
  database would hit the exact same `:definition_not_found` failure this
  test worked around. See this run's TEST-DESIGNER handoff for the full
  finding; not fixed here per TEST-DESIGNER's own scope (tests only, not
  implementation).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Exam.Session
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.Registration
  alias Mix.Tasks.Letflow.Seed.ExamFixtures

  @tenant_realm "bpm-default"

  @candidate_username "req345-e2e-candidate"

  @mixed_exam_title "REQ-345 E2E Mixed Exam"
  @scoreable_exam_title "REQ-345 E2E Scoreable Exam"
  @mixed_category_title "REQ-345 Mixed Exam Bank"
  @scoreable_category_title "REQ-345 Scoreable Exam Bank"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
    cleanup_bpm_default()
    on_exit(fn -> cleanup_bpm_default() end)

    # `mix letflow.seed` provisions the tenant schema/migrations only -- see
    # this file's moduledoc "IMPLEMENTATION FINDING" section. Called
    # directly (`Mix.Tasks.Letflow.Seed.run/1`, not `Mix.Task.run/1`) so it
    # genuinely re-executes even if some other test in this suite run
    # already exhausted `Mix.Task.run/1`'s per-task-name cache --
    # `letflow.seed_test.exs`'s own moduledoc documents this same reasoning.
    assert :ok = Mix.Tasks.Letflow.Seed.run([])

    schema = schema_name!()
    assert {:ok, _seed_result} = EventTypes.seed!(schema)

    # GH #2596: the six runtime types are managed by the exam module, so the exam module is
    # installed FIRST (its pack inserts them stamped `managed_by = 'exam'`, inactive) and the
    # fixture then activates the authoring definitions and the pack's own stamped runtime rows.
    # The previous order (activate tenant-owned `session` etc., let the task install the module
    # later) now fails inside the task with `{:pack_install_failed, {:managed_name_taken,
    # "session"}}`: a tenant that already defines a managed name cannot install the module. The
    # task's own install step then takes its documented `:already_installed` path.
    assert {:ok, _tenant_module} =
             Letflow.Modules.Installs.install("exam", Ecto.UUID.generate(),
               prefix: schema,
               rationale: "GH #2596 test: install before seeding"
             )

    :ok = Letflow.ExamFixtures.activate_exam_definitions_after_pack_install!(schema)

    :ok
  end

  defp cleanup_bpm_default do
    case Repo.get_by(Tenant, idp_realm_id: @tenant_realm) do
      nil ->
        :ok

      %Tenant{id: tenant_id} ->
        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
          {:error, :invalid_tenant_id} -> :ok
        end

        # ISS-0839: REQ-410/REQ-411 changed the exam seed to call
        # Installs.install("exam", ...) which writes GLOBAL tables:
        # solution_pack_installs (FK -> tenants) and solution_pack_artefact_bases
        # (FK -> tenants, written by SolutionPack.install/3 step 6b). Delete these
        # before deleting the tenants row or the FK raises. Same pattern as
        # solution_pack_test.exs's cleanup_solution_pack_installs!/1.
        Repo.delete_all(from(s in SolutionPackInstall, where: s.tenant_id == ^tenant_id))
        Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))

        # `category`/`question`/`exam_question_rule`/`session_question` (etc)
        # each declare a `constraints` entry, so activating them
        # auto-registers a `ColumnPromotion` row -- a GLOBAL table with an FK
        # to `tenants` (same cleanup gap `Letflow.ExamFixtures`'s own
        # `provisioned_tenant_with_exam_definitions/1` on_exit already guards
        # against). Without this, deleting the `tenants` row below raises a
        # `foreign_key_violation` in `setup`/`on_exit`.
        Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end
  end

  defp schema_name! do
    {:ok, tenant} = Identity.resolve_tenant_by_realm(@tenant_realm)
    {:ok, schema} = TenantProvisioning.schema_name_for_tenant(tenant.id)
    schema
  end

  defp records(schema, entity_type) do
    Repo.all(
      from(r in Latest, where: r.entity_type == ^entity_type and r.deleted == false),
      prefix: schema
    )
  end

  defp field(%Latest{field_values: field_values}, path),
    do: get_in(field_values, List.wrap(path))

  defp numeric(value) when is_float(value), do: value
  defp numeric(value) when is_integer(value), do: value * 1.0
  defp numeric(%Decimal{} = value), do: Decimal.to_float(value)

  defp assert_exactly_one(list, pred) do
    case Enum.filter(list, pred) do
      [one] -> one
      other -> flunk("expected exactly one match, got #{length(other)}: #{inspect(other)}")
    end
  end

  # ---------------------------------------------------------------------
  # AC1 -- idempotency
  # ---------------------------------------------------------------------

  describe "idempotency -- running the task twice" do
    test "leaves exactly one exam per title, one category per exam, one rule per exam, one session" do
      assert :ok = ExamFixtures.run([])
      assert :ok = ExamFixtures.run([])

      schema = schema_name!()

      exams = records(schema, "exam")
      mixed_exam = assert_exactly_one(exams, &(field(&1, ["title", "en"]) == @mixed_exam_title))

      scoreable_exam =
        assert_exactly_one(exams, &(field(&1, ["title", "en"]) == @scoreable_exam_title))

      categories = records(schema, "category")

      mixed_cat =
        assert_exactly_one(categories, &(field(&1, ["name", "en"]) == @mixed_category_title))

      scoreable_cat =
        assert_exactly_one(categories, &(field(&1, ["name", "en"]) == @scoreable_category_title))

      questions = records(schema, "question")
      mixed_qs = Enum.filter(questions, &(field(&1, "category_id") == mixed_cat.record_id))

      scoreable_qs =
        Enum.filter(questions, &(field(&1, "category_id") == scoreable_cat.record_id))

      assert length(mixed_qs) == 5
      assert length(scoreable_qs) == 3

      rules = records(schema, "exam_question_rule")
      mixed_rules = Enum.filter(rules, &(field(&1, "exam_id") == mixed_exam.record_id))
      scoreable_rules = Enum.filter(rules, &(field(&1, "exam_id") == scoreable_exam.record_id))

      assert length(mixed_rules) == 1
      assert length(scoreable_rules) == 1

      sessions = records(schema, "session")
      sessions_for_mixed = Enum.filter(sessions, &(field(&1, "exam_id") == mixed_exam.record_id))

      assert length(sessions_for_mixed) == 1
    end
  end

  # ---------------------------------------------------------------------
  # AC2/AC3 -- content correctness
  # ---------------------------------------------------------------------

  describe "content correctness" do
    test "the mixed exam has exactly 5 questions, one per type" do
      assert :ok = ExamFixtures.run([])

      schema = schema_name!()

      mixed_cat =
        assert_exactly_one(
          records(schema, "category"),
          &(field(&1, ["name", "en"]) == @mixed_category_title)
        )

      mixed_qs =
        records(schema, "question")
        |> Enum.filter(&(field(&1, "category_id") == mixed_cat.record_id))

      assert length(mixed_qs) == 5

      types = mixed_qs |> Enum.map(&field(&1, "type")) |> Enum.sort()
      assert types == Enum.sort(~w(single multiple truefalse likert shorttext))
    end

    test "the scoreable exam has exactly 3 questions, none shorttext, and passing_score_pct 60.0" do
      assert :ok = ExamFixtures.run([])

      schema = schema_name!()

      scoreable_exam =
        assert_exactly_one(
          records(schema, "exam"),
          &(field(&1, ["title", "en"]) == @scoreable_exam_title)
        )

      assert numeric(field(scoreable_exam, "passing_score_pct")) == 60.0

      scoreable_cat =
        assert_exactly_one(
          records(schema, "category"),
          &(field(&1, ["name", "en"]) == @scoreable_category_title)
        )

      scoreable_qs =
        records(schema, "question")
        |> Enum.filter(&(field(&1, "category_id") == scoreable_cat.record_id))

      assert length(scoreable_qs) == 3
      refute "shorttext" in Enum.map(scoreable_qs, &field(&1, "type"))
    end
  end

  # ---------------------------------------------------------------------
  # AC4 -- session outcome
  # ---------------------------------------------------------------------

  describe "session outcome" do
    test "the seeded session's submit outcome is status grading_pending, passed nil" do
      assert :ok = ExamFixtures.run([])

      schema = schema_name!()

      mixed_exam =
        assert_exactly_one(
          records(schema, "exam"),
          &(field(&1, ["title", "en"]) == @mixed_exam_title)
        )

      candidate = Repo.get_by(User, [username: @candidate_username], prefix: schema)
      assert %User{} = candidate

      session =
        assert_exactly_one(
          records(schema, "session"),
          &(field(&1, "exam_id") == mixed_exam.record_id)
        )

      # submit/3 is documented idempotent -- calling it again here (a third
      # call overall, after the two the task itself already made across its
      # own single run) exercises the real outcome_from_session/1 mapping
      # without needing to parse the task's captured stdout.
      assert {:ok, outcome} = Session.submit(session.record_id, candidate.id, schema)
      assert outcome.status == :grading_pending
      assert outcome.passed == nil
    end
  end

  # ---------------------------------------------------------------------
  # REQ-582 part B -- exam_assignment (supersedes REQ-345 AC11 "no exam_assignment")
  # ---------------------------------------------------------------------

  describe "exam_assignment (REQ-582)" do
    defp assignments(schema) do
      import Ecto.Query, only: [from: 2]

      Repo.all(
        from(l in Latest, where: l.entity_type == "exam_assignment" and l.deleted == false),
        prefix: schema
      )
    end

    test "the definition is active and each fixture exam has exactly one active all assignment" do
      assert :ok = ExamFixtures.run([])
      schema = schema_name!()

      assert {:ok, _} = Definitions.get_active_definition_by_name("exam_assignment", schema)

      rows = assignments(schema)
      assert length(rows) == 2
      assert length(Enum.uniq(Enum.map(rows, & &1.field_values["exam_id"]))) == 2

      for row <- rows do
        assert row.field_values["assignee_type"] == "all"
        assert row.field_values["active"] == true
      end
    end

    test "a second run adds no assignment" do
      assert :ok = ExamFixtures.run([])
      schema = schema_name!()
      before_ids = schema |> assignments() |> Enum.map(& &1.record_id) |> Enum.sort()

      assert :ok = ExamFixtures.run([])

      assert schema |> assignments() |> Enum.map(& &1.record_id) |> Enum.sort() == before_ids
    end

    test "an inactive exam_assignment definition (pack row) is activated by the seed" do
      assert :ok = ExamFixtures.run([])
      schema = schema_name!()

      {1, _} =
        Repo.delete_all(
          from(a in Letflow.Repository.Activation,
            where: a.artifact_kind == :entity and a.artifact_name == "exam_assignment"
          ),
          prefix: schema
        )

      assert {:error, :not_found} =
               Definitions.get_active_definition_by_name("exam_assignment", schema)

      assert :ok = ExamFixtures.run([])

      assert {:ok, _} = Definitions.get_active_definition_by_name("exam_assignment", schema)
      rows = assignments(schema)
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.field_values["assignee_type"] == "all"))
      assert Enum.all?(rows, &(&1.field_values["active"] == true))
    end
  end
end
