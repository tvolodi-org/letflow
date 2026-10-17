defmodule Letflow.Modules.Exam.SnapshotLateTest do
  @moduledoc """
  GH #2682 / REQ-511 PR b, design `lib/letflow/design/req511-exam-content-snapshot.md` sections 9,
  12.3, 17.2, 17.4, 17.6, 18.5 and 18.6 (spec `test/specs/GH2682-exam-snapshot-pr-b.md`): the lazy
  LATE snapshot of a session that started before the snapshot code shipped, the cutover rule that
  bounds it, and the audit entry that reports it, against a real provisioned tenant (DIRECTIVE T-1).

    * T-21 / T-22 / T-23 / T-60: an `in_progress` session whose RECORD was inserted before the
      cutover gets a `late` snapshot at its first touch (state read, autosave, submit, deadline
      auto-submit), once, with exactly one `exam.session_snapshot_late` audit entry in the same
      transaction (T-58); an audit failure rolls the whole touch back.
    * T-24: concurrent touches produce exactly one write (invariant I-2).
    * T-25: a tenant that is not rolled out fails closed (503-class), nothing graded or written, and
      the same call succeeds after the rollout.
    * T-48 .. T-51: a late build whose live rows are broken is a typed grading error that writes
      nothing.
    * GH #2734 (spec `test/specs/GH-2734.md`): a SOFT-deleted exam, question or key-bearing option
      is the same typed refusal; other soft-deleted options and session_questions are excluded; an
      existing snapshot is never rebuilt.
    * T-52 / T-63: ownership comes before every prerequisite probe (R6): a non-owner writes nothing
      and costs exactly as many queries as a nonexistent session.
    * T-59: `Snapshot.ensure_locked/2` builds only (returns `session_after`), the submit persists it
      in its ONE session update and calls `record_late/4` last.
    * T-61 / T-61b: a record inserted at or after the cutover that lost its snapshot is
      `:snapshot_missing`, whatever its writable `started_at` says; a corrupt snapshot is never
      replaced; terminal sessions are never given a snapshot (I-3).
    * T-62 / T-63b: the cutover of a fresh-install tenant and the `Snapshot.cutover/1` unit.
    * `Snapshot.late_origin_counts/1`.

  Every legacy session is built by ONE helper, `Letflow.ExamFixtures.legacy_session!/2` (design
  18.5): the fixtures carry `exam_snapshot` from install, so a plain session is after the cutover.

  Runs against Postgres outside the sandbox transaction (`Letflow.ExamFixtures` switches the
  sandbox to `:auto`): `async: false`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.Event
  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.ExamStampFixtures, as: StampFx
  alias Letflow.Modules.Exam.Scoring
  alias Letflow.Modules.Exam.Session
  alias Letflow.Modules.Exam.Snapshot
  alias Letflow.Modules.Exam.Snapshot.Rollout
  alias Letflow.Modules.Installs
  alias Letflow.Repository.ActivationHistory

  @late_action "exam.session_snapshot_late"

  # ── fixtures ───────────────────────────────────────────────────────────────────────────────

  defp tenant(slug), do: Fx.provisioned_tenant_with_exam_definitions(slug)

  defp create_exam!(schema, attrs) do
    defaults = %{
      "title" => %{"en" => "Late Snapshot Exam"},
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 10,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => true
    }

    Fx.create_record!(schema, "exam", Map.merge(defaults, attrs))
  end

  defp create_question!(schema, category_id, attrs) do
    defaults = %{
      "category_id" => category_id,
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => "active",
      "version" => 1,
      "stem" => %{"en" => "Stem?"}
    }

    Fx.create_record!(schema, "question", Map.merge(defaults, attrs))
  end

  defp create_option!(schema, question_id, sort_order, is_correct, attrs) do
    defaults = %{
      "question_id" => question_id,
      "sort_order" => sort_order,
      "is_correct" => is_correct,
      "text" => %{"en" => "Option #{sort_order}"}
    }

    Fx.create_record!(schema, "answer_option", Map.merge(defaults, attrs))
  end

  defp single_spec, do: {"single", [{true, %{}}, {false, %{}}]}

  defp likert_spec do
    {"likert",
     [
       {false, %{"likert_weight" => 1.0, "likert_polarity" => "positive"}},
       {false, %{"likert_weight" => 3.0, "likert_polarity" => "positive"}}
     ]}
  end

  # One exam, one random rule drawing every question of one category. Returns the exam and per
  # question `%{id, option_ids}` (option ids in sort order).
  defp build_exam!(schema, specs, exam_attrs) do
    category_id = Ecto.UUID.generate()
    exam = create_exam!(schema, exam_attrs)

    questions =
      for {type, option_specs} <- specs do
        question = create_question!(schema, category_id, %{"type" => type})

        option_ids =
          option_specs
          |> Enum.with_index()
          |> Enum.map(fn {{is_correct, attrs}, index} ->
            create_option!(schema, question.record_id, index, is_correct, attrs).record_id
          end)

        %{id: question.record_id, option_ids: option_ids}
      end

    Fx.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => length(specs),
      "sort_order" => 0
    })

    %{exam: exam, questions: questions}
  end

  defp start!(schema, exam_id) do
    candidate = Ecto.UUID.generate()
    assert {:ok, view} = Session.create(candidate, exam_id, schema)
    {candidate, view.id}
  end

  # A fresh tenant, one exam, one started session (with its start snapshot).
  defp scenario!(slug, specs, exam_attrs) do
    %{schema_name: schema} = tenant(slug)
    %{exam: exam, questions: questions} = build_exam!(schema, specs, exam_attrs)
    {candidate, session_id} = start!(schema, exam.record_id)

    %{
      schema: schema,
      exam: exam,
      questions: questions,
      q: hd(questions),
      candidate: candidate,
      session_id: session_id
    }
  end

  defp answer!(ctx, option_ids) do
    assert {:ok, _} =
             Session.autosave_answer(
               ctx.session_id,
               ctx.candidate,
               %{
                 question_id: ctx.q.id,
                 selected_option_ids: option_ids,
                 time_spent_seconds: 0
               },
               ctx.schema
             )

    :ok
  end

  # A single-choice session answered CORRECTLY, then made a legacy (pre-cutover, snapshotless) one.
  defp legacy_scenario!(slug) do
    ctx = scenario!(slug, [single_spec()], %{})
    answer!(ctx, [hd(ctx.q.option_ids)])
    :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
    ctx
  end

  # Another session of the same exam by a new candidate, answered correctly.
  defp second_session!(ctx) do
    {candidate, session_id} = start!(ctx.schema, ctx.exam.record_id)
    other = %{ctx | candidate: candidate, session_id: session_id}
    answer!(other, [hd(ctx.q.option_ids)])
    other
  end

  defp session_fv(schema, session_id) do
    assert {:ok, row} = Latest.get(session_id, "session", schema)
    row.field_values
  end

  defp record_inserted_at(schema, session_id) do
    assert {:ok, row} = Latest.get(session_id, "session", schema)
    row.inserted_at
  end

  defp set_inserted_at!(schema, session_id, %DateTime{} = inserted_at) do
    assert {1, _} =
             Repo.update_all(
               from(l in Latest,
                 where: l.entity_type == "session" and l.record_id == ^session_id
               ),
               [set: [inserted_at: inserted_at]],
               prefix: schema
             )

    :ok
  end

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp score_rows(schema, session_id) do
    Repo.aggregate(
      from(l in Latest,
        where:
          l.entity_type == "session_question_score" and
            fragment("?->>?", l.field_values, "session_id") == ^session_id
      ),
      :count,
      prefix: schema
    )
  end

  # The `exam.session_snapshot_late` entries of the tenant, decoded.
  defp late_audit(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT actor_id::text, resource_type, resource_id::text, after_state::text | <>
          ~s|FROM "#{schema}".audit_entries WHERE action = $1 ORDER BY timestamp|,
        [@late_action]
      )

    for [actor_id, resource_type, resource_id, after_state] <- rows do
      %{
        actor_id: actor_id,
        resource_type: resource_type,
        resource_id: resource_id,
        after_state: Jason.decode!(after_state)
      }
    end
  end

  defp grading(reason), do: {:error, {:grading_error, reason}}

  # Every owner-side touch of a session, as `{name, fun}`.
  defp owner_touches(ctx) do
    answer = %{question_id: ctx.q.id, selected_option_ids: [], time_spent_seconds: 0}

    [
      ensure: fn -> Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema) end,
      autosave: fn ->
        Session.autosave_answer(ctx.session_id, ctx.candidate, answer, ctx.schema)
      end,
      state: fn ->
        Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)
      end,
      submit: fn -> Session.submit(ctx.session_id, ctx.candidate, ctx.schema) end,
      finalize: fn -> Session.finalize_expired(ctx.session_id, DateTime.utc_now(), ctx.schema) end
    ]
  end

  # The session row, the event log and the audit log are exactly as `before` says.
  defp snapshot_of_state(ctx) do
    %{
      fv: session_fv(ctx.schema, ctx.session_id),
      events: event_count(ctx.schema),
      audit: length(late_audit(ctx.schema)),
      scores: score_rows(ctx.schema, ctx.session_id)
    }
  end

  # Repo queries issued by THIS test process while `fun` runs.
  defp count_queries(fun) do
    counter = :counters.new(1, [])
    handler = "gh2682-b-parity-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:letflow, :repo, :query],
        fn _event, _measurements, _meta, _config ->
          if self() == test_pid, do: :counters.add(counter, 1, 1)
        end,
        nil
      )

    try do
      result = fun.()
      {result, :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end

  # True when `fun` raises a database constraint error (an audit insert failing at the database
  # raises through the transaction, which is rolled back as a whole). Any other exception is a
  # test failure.
  defp raises_constraint?(fun) do
    fun.()
    false
  rescue
    _error in [Ecto.ConstraintError, Postgrex.Error] -> true
  end

  # Removes the row itself (the soft delete of `Records.delete_record/2` leaves it readable by
  # `Latest.get/3`): a direct test-support write.
  defp hard_delete!(schema, entity_type, record_id) do
    assert {1, _} =
             Repo.delete_all(
               from(l in Latest,
                 where: l.entity_type == ^entity_type and l.record_id == ^record_id
               ),
               prefix: schema
             )

    :ok
  end

  defp block_late_audit!(schema) do
    Repo.query!(
      ~s|ALTER TABLE "#{schema}".audit_entries ADD CONSTRAINT gh2682_block_late_audit | <>
        ~s|CHECK (action <> '#{@late_action}')|
    )

    :ok
  end

  # ── the fixture itself ─────────────────────────────────────────────────────────────────────

  describe "legacy_session!/2 (the one legacy fixture, design 18.5)" do
    test "a plain session is AFTER the cutover; the helper makes it a pre-cutover, snapshotless one with a future deadline" do
      ctx = scenario!("gh2682-b-fixture", [single_spec()], %{})
      assert {:ok, cutover} = Snapshot.cutover(ctx.schema)

      assert DateTime.compare(record_inserted_at(ctx.schema, ctx.session_id), cutover) != :lt
      assert %{"origin" => "start"} = Fx.session_snapshot(ctx.schema, ctx.session_id)

      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)

      assert DateTime.compare(record_inserted_at(ctx.schema, ctx.session_id), cutover) == :lt
      fv = session_fv(ctx.schema, ctx.session_id)
      refute Map.has_key?(fv, "exam_snapshot")
      assert {:ok, started_at, _} = DateTime.from_iso8601(fv["started_at"])
      assert DateTime.compare(started_at, cutover) == :lt
      assert {:ok, expires_at, _} = DateTime.from_iso8601(fv["expires_at"])
      assert DateTime.compare(expires_at, DateTime.utc_now()) == :gt
      assert fv["status"] == "in_progress"
    end
  end

  # ── T-21 / T-22 / T-23 / T-60: the first touch ─────────────────────────────────────────────

  describe "T-21 / T-60 the first touch of a pre-cutover session takes a late snapshot" do
    test "autosave: the snapshot is written (origin late, taken_at set, digest verifies), equals what the start would have taken, and a later authoring edit does not change the score" do
      ctx = scenario!("gh2682-b-t21", [single_spec()], %{})
      [correct, wrong] = ctx.q.option_ids
      start_snapshot = Fx.session_snapshot(ctx.schema, ctx.session_id)
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)

      assert {:ok, %{remaining_seconds: remaining}} =
               Session.autosave_answer(
                 ctx.session_id,
                 ctx.candidate,
                 %{question_id: ctx.q.id, selected_option_ids: [correct], time_spent_seconds: 0},
                 ctx.schema
               )

      assert remaining > 0

      snapshot = Fx.session_snapshot(ctx.schema, ctx.session_id)
      assert %{"origin" => "late", "taken_at" => taken_at, "v" => 1} = snapshot
      assert {:ok, _taken_at, _offset} = DateTime.from_iso8601(taken_at)
      assert {:ok, _verified} = Snapshot.fetch_verified(session_fv(ctx.schema, ctx.session_id))
      assert snapshot["exam"]["passing_score_pct"] == "60"
      assert snapshot["questions"][ctx.q.id]["correct_option_ids"] == [correct]

      # A late snapshot is the start snapshot of the same rows, modulo its provenance fields.
      provenance = ["origin", "taken_at", "nonce", "digest"]
      assert Map.drop(snapshot, provenance) == Map.drop(start_snapshot, provenance)

      assert [%{resource_id: resource_id}] = late_audit(ctx.schema)
      assert resource_id == ctx.session_id

      # an edit after the first touch changes neither the stored key nor the score
      Fx.update_record!(ctx.schema, "answer_option", correct, %{"is_correct" => false})
      Fx.update_record!(ctx.schema, "answer_option", wrong, %{"is_correct" => true})
      Fx.update_record!(ctx.schema, "exam", ctx.exam.record_id, %{"passing_score_pct" => 100.0})

      assert {:ok, %{status: :submitted, passed: true, percentage: 100.0}} =
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert length(late_audit(ctx.schema)) == 1
    end

    test "state read: an in-progress pre-cutover session is snapshotted by its first read, once, and a second read writes nothing" do
      ctx = legacy_scenario!("gh2682-b-t21-state")
      events = event_count(ctx.schema)

      assert {:ok, %{questions: [question]}} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert question.type == :single
      assert %{"origin" => "late"} = Fx.session_snapshot(ctx.schema, ctx.session_id)
      assert event_count(ctx.schema) == events + 1
      assert length(late_audit(ctx.schema)) == 1

      assert {:ok, _state} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert event_count(ctx.schema) == events + 1
      assert length(late_audit(ctx.schema)) == 1
    end

    test "the state read shows the type the late snapshot froze, not a later live edit" do
      ctx = legacy_scenario!("gh2682-b-t21-type")

      assert {:ok, _state} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      Fx.update_record!(ctx.schema, "question", ctx.q.id, %{"type" => "multiple"})

      assert {:ok, %{questions: [question]}} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert question.type == :single
    end
  end

  describe "T-22 / T-59 submit of a pre-cutover session with no earlier touch" do
    test "the late snapshot is taken under the row lock, the session is scored from it, and the snapshot survives the submit's own write" do
      ctx = legacy_scenario!("gh2682-b-t22")
      [correct, wrong] = ctx.q.option_ids

      # an authoring edit BEFORE the first touch is part of the late snapshot (documented residual)
      Fx.update_record!(ctx.schema, "exam", ctx.exam.record_id, %{"passing_score_pct" => 50.0})
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == nil

      assert {:ok, %{status: :submitted, passed: true, percentage: 100.0}} =
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      fv = session_fv(ctx.schema, ctx.session_id)
      assert fv["status"] == "submitted"
      assert %{"origin" => "late", "taken_at" => _} = fv["exam_snapshot"]
      assert fv["exam_snapshot"]["exam"]["passing_score_pct"] == "50"
      assert fv["exam_snapshot"]["questions"][ctx.q.id]["correct_option_ids"] == [correct]
      refute wrong in fv["exam_snapshot"]["questions"][ctx.q.id]["correct_option_ids"]
      assert {:ok, _verified} = Snapshot.fetch_verified(fv)

      assert [%{resource_id: resource_id, actor_id: actor_id}] = late_audit(ctx.schema)
      assert resource_id == ctx.session_id
      assert actor_id == ctx.candidate
    end

    test "T-59 the late submit writes exactly as many events as a plain submit: ONE session update carries the snapshot and the outcome" do
      ctx = scenario!("gh2682-b-t59-events", [single_spec()], %{})
      plain = second_session!(ctx)
      legacy = second_session!(ctx)
      :ok = Fx.legacy_session!(ctx.schema, legacy.session_id)

      before_plain = event_count(ctx.schema)

      assert {:ok, %{status: :submitted}} =
               Session.submit(plain.session_id, plain.candidate, plain.schema)

      plain_delta = event_count(ctx.schema) - before_plain

      before_late = event_count(ctx.schema)

      assert {:ok, %{status: :submitted}} =
               Session.submit(legacy.session_id, legacy.candidate, legacy.schema)

      late_delta = event_count(ctx.schema) - before_late

      assert plain_delta > 0
      assert late_delta == plain_delta
      assert %{"origin" => "late"} = Fx.session_snapshot(ctx.schema, legacy.session_id)
      assert %{"origin" => "start"} = Fx.session_snapshot(ctx.schema, plain.session_id)
    end

    test "T-59 ensure_locked/2 only BUILDS: it returns session_after with the snapshot merged and writes nothing; with a snapshot it returns :existing" do
      ctx = legacy_scenario!("gh2682-b-t59-build")
      assert {:ok, row} = Latest.get(ctx.session_id, "session", ctx.schema)
      before = snapshot_of_state(ctx)

      assert {:ok, snapshot, session_after, :late} = Snapshot.ensure_locked(row, ctx.schema)

      assert snapshot["origin"] == "late"
      assert session_after.field_values["exam_snapshot"] == snapshot

      assert Map.delete(session_after.field_values, "exam_snapshot") ==
               Map.delete(row.field_values, "exam_snapshot")

      assert snapshot_of_state(ctx) == before
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == nil
      assert late_audit(ctx.schema) == []

      # the caller's half of the contract: persist session_after, then record_late/4 last
      assert :ok = Snapshot.record_late(row, snapshot, ctx.candidate, ctx.schema)
      assert [%{after_state: %{"origin" => "late"}}] = late_audit(ctx.schema)

      # an existing snapshot is returned as is, tagged :existing
      plain = scenario!("gh2682-b-t59-existing", [single_spec()], %{})
      assert {:ok, plain_row} = Latest.get(plain.session_id, "session", plain.schema)

      assert {:ok, existing, ^plain_row, :existing} =
               Snapshot.ensure_locked(plain_row, plain.schema)

      assert existing == plain_row.field_values["exam_snapshot"]
      assert late_audit(plain.schema) == []
    end
  end

  describe "T-23 deadline auto-submit of a pre-cutover session" do
    test "finalize_expired takes the late snapshot, auto-submits, and records the audit entry with no actor" do
      ctx = legacy_scenario!("gh2682-b-t23")

      assert {:ok, %{status: :auto_submitted, passed: true}} =
               Session.finalize_expired(ctx.session_id, DateTime.utc_now(), ctx.schema)

      fv = session_fv(ctx.schema, ctx.session_id)
      assert fv["status"] == "auto_submitted"
      assert %{"origin" => "late"} = fv["exam_snapshot"]
      assert {:ok, _verified} = Snapshot.fetch_verified(fv)

      assert [%{actor_id: nil, resource_id: resource_id, resource_type: "session"}] =
               late_audit(ctx.schema)

      assert resource_id == ctx.session_id

      # a replay neither snapshots nor audits again
      events = event_count(ctx.schema)

      assert {:ok, %{status: :auto_submitted}} =
               Session.finalize_expired(ctx.session_id, DateTime.utc_now(), ctx.schema)

      assert event_count(ctx.schema) == events
      assert length(late_audit(ctx.schema)) == 1
    end
  end

  # ── T-58: the audit entry ──────────────────────────────────────────────────────────────────

  describe "T-58 the audit entry of a late snapshot" do
    test "exactly one hash-chained entry with ids, names and timestamps only, written with the snapshot" do
      ctx = legacy_scenario!("gh2682-b-t58")
      started_at = session_fv(ctx.schema, ctx.session_id)["started_at"]

      assert {:ok, snapshot} = Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)

      assert [entry] = late_audit(ctx.schema)

      assert %{
               actor_id: actor_id,
               resource_type: "session",
               resource_id: resource_id,
               after_state: after_state
             } = entry

      assert actor_id == ctx.candidate
      assert resource_id == ctx.session_id
      assert Enum.sort(Map.keys(after_state)) == ~w(exam_id origin started_at taken_at)
      assert after_state["origin"] == "late"
      assert after_state["exam_id"] == ctx.exam.record_id
      assert after_state["started_at"] == started_at
      assert after_state["taken_at"] == snapshot["taken_at"]

      flat = inspect(entry, limit: :infinity)

      for secret <- ["correct_option_ids", "nonce", "sha256", "is_correct", "likert"] do
        refute {secret, flat =~ secret} == {secret, true}
      end

      # the second touch finds the snapshot: no second entry
      assert {:ok, ^snapshot} = Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)
      assert length(late_audit(ctx.schema)) == 1
    end

    test "a failing audit insert rolls the whole touch back: ensure leaves no snapshot, no event, no entry" do
      ctx = legacy_scenario!("gh2682-b-t58-rollback-ensure")
      :ok = block_late_audit!(ctx.schema)
      before = snapshot_of_state(ctx)

      assert raises_constraint?(fn ->
               Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)
             end)

      assert snapshot_of_state(ctx) == before
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == nil
    end

    test "a failing audit insert rolls a late SUBMIT back: scores, status and snapshot together; the session stays in progress" do
      ctx = legacy_scenario!("gh2682-b-t58-rollback-submit")
      :ok = block_late_audit!(ctx.schema)
      before = snapshot_of_state(ctx)

      assert raises_constraint?(fn ->
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)
             end)

      after_state = snapshot_of_state(ctx)
      assert after_state == before
      assert after_state.fv["status"] == "in_progress"
      assert after_state.scores == 0
      refute Map.has_key?(after_state.fv, "exam_snapshot")
    end

    test "record_late/4 maps an audit failure to {:snapshot_error, :audit_failed} and logs a tag, never snapshot content" do
      ctx = scenario!("gh2682-b-t58-typed", [single_spec()], %{})
      assert {:ok, row} = Latest.get(ctx.session_id, "session", ctx.schema)
      snapshot = row.field_values["exam_snapshot"]
      missing_prefix = "no_such_schema"

      log =
        capture_log(fn ->
          assert {:error, {:snapshot_error, :audit_failed}} ==
                   Snapshot.record_late(row, snapshot, ctx.candidate, missing_prefix)
        end)

      assert log =~ "audit entry failed"
      refute log =~ snapshot["digest"]
      refute log =~ snapshot["nonce"]
      assert late_audit(ctx.schema) == []
    end
  end

  # ── T-24: concurrency ──────────────────────────────────────────────────────────────────────

  describe "T-24 concurrent touches" do
    @tag timeout: 120_000
    test "four concurrent touches of one pre-cutover session produce exactly one snapshot write and one audit entry" do
      ctx = legacy_scenario!("gh2682-b-t24")
      events = event_count(ctx.schema)

      tasks =
        for _ <- 1..4 do
          Task.async(fn -> Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema) end)
        end

      results = Task.await_many(tasks, 60_000)

      assert [{:ok, first} | rest] = results
      assert Enum.all?(rest, &(&1 == {:ok, first}))
      assert first["origin"] == "late"
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == first

      # the one update event adds the snapshot; nobody else wrote
      assert event_count(ctx.schema) == events + 1
      assert length(late_audit(ctx.schema)) == 1
    end

    @tag timeout: 120_000
    test "a state read racing a submit of the same pre-cutover session ends with one snapshot and one audit entry" do
      ctx = legacy_scenario!("gh2682-b-t24-mixed")

      tasks = [
        Task.async(fn ->
          Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)
        end),
        Task.async(fn -> Session.submit(ctx.session_id, ctx.candidate, ctx.schema) end),
        Task.async(fn -> Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema) end)
      ]

      [state, submit, ensure] = Task.await_many(tasks, 60_000)

      # whichever won the row lock first took the snapshot; the others either read it or, after the
      # submit committed, were refused for the session no longer being in progress
      assert {:ok, %{status: :submitted}} = submit
      assert match?({:ok, _}, state) or match?({:error, _}, state)
      assert match?({:ok, _}, ensure) or match?({:error, _}, ensure)

      fv = session_fv(ctx.schema, ctx.session_id)
      assert fv["status"] == "submitted"
      assert %{"origin" => "late"} = fv["exam_snapshot"]
      assert {:ok, _verified} = Snapshot.fetch_verified(fv)
      assert length(late_audit(ctx.schema)) == 1
    end
  end

  # ── T-25: the tenant is not rolled out ─────────────────────────────────────────────────────

  describe "T-25 prerequisites of a late snapshot" do
    test "a tenant whose active session definition lacks exam_snapshot fails closed on every touch, writes nothing, and works after the rollout" do
      ctx = legacy_scenario!("gh2682-b-t25-def")
      Fx.downgrade_session_definition!(ctx.schema)
      before = snapshot_of_state(ctx)

      for {name, touch} <- owner_touches(ctx) do
        assert {name, touch.()} == {name, {:error, {:snapshot_error, :definition_missing}}}
        assert {name, snapshot_of_state(ctx)} == {name, before}
      end

      assert before.fv["status"] == "in_progress"
      assert before.scores == 0

      assert %{status: :upgraded, definition: :added} = Rollout.run_tenant(ctx.schema, [])

      assert {:ok, %{"origin" => "late"}} =
               Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)

      assert {:ok, %{status: :submitted, passed: true}} =
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)
    end

    test "a tenant without the snapshot restriction row fails closed the same way" do
      ctx = legacy_scenario!("gh2682-b-t25-restriction")
      assert Fx.delete_answer_key_restrictions!(ctx.schema) == 5
      before = snapshot_of_state(ctx)

      for {name, touch} <- owner_touches(ctx) do
        assert {name, touch.()} == {name, {:error, {:snapshot_error, :restrictions_missing}}}
        assert {name, snapshot_of_state(ctx)} == {name, before}
      end
    end
  end

  # ── T-48 .. T-51: a late build with broken live rows ───────────────────────────────────────

  describe "T-48 .. T-51 a late build whose live rows are broken is a typed grading error that writes nothing" do
    defp assert_late_build_fails!(ctx, expected) do
      before = snapshot_of_state(ctx)

      assert Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema) == {:error, expected}
      assert snapshot_of_state(ctx) == before

      assert Session.submit(ctx.session_id, ctx.candidate, ctx.schema) == {:error, expected}
      assert snapshot_of_state(ctx) == before
      assert before.fv["status"] == "in_progress"
      assert before.scores == 0
    end

    test "T-48 the live exam threshold is nil: :threshold_missing" do
      ctx = legacy_scenario!("gh2682-b-t48")
      Fx.force_field!(ctx.schema, "exam", ctx.exam.record_id, "passing_score_pct", {:put, nil})
      assert_late_build_fails!(ctx, {:grading_error, :threshold_missing})
    end

    test "T-49 the live exam row is gone: :exam_section_missing" do
      ctx = legacy_scenario!("gh2682-b-t49")
      :ok = hard_delete!(ctx.schema, "exam", ctx.exam.record_id)
      assert_late_build_fails!(ctx, {:grading_error, :exam_section_missing})
    end

    test "T-50 a session_question's question row is gone: {:question_item_missing, id}" do
      ctx = legacy_scenario!("gh2682-b-t50")
      :ok = hard_delete!(ctx.schema, "question", ctx.q.id)
      assert_late_build_fails!(ctx, {:grading_error, {:question_item_missing, ctx.q.id}})
    end

    test "T-51 a single-choice question with no correct option: {:key_missing, id}" do
      ctx = legacy_scenario!("gh2682-b-t51-single")

      for option_id <- ctx.q.option_ids,
          do: Fx.update_record!(ctx.schema, "answer_option", option_id, %{"is_correct" => false})

      assert_late_build_fails!(ctx, {:grading_error, {:key_missing, ctx.q.id}})
    end

    test "T-51 a likert question with an option lacking its weight, or its polarity: {:key_missing, id}" do
      for {slug, key} <- [
            {"gh2682-b-t51-weight", "likert_weight"},
            {"gh2682-b-t51-polarity", "likert_polarity"}
          ] do
        ctx = scenario!(slug, [likert_spec()], %{})
        answer!(ctx, [hd(ctx.q.option_ids)])
        :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)

        Fx.force_field!(ctx.schema, "answer_option", hd(ctx.q.option_ids), key, {:put, nil})
        assert_late_build_fails!(ctx, {:grading_error, {:key_missing, ctx.q.id}})
      end
    end
  end

  # ── GH #2734: a late build never reads soft-deleted content ────────────────────────────────

  describe "GH #2734 a late build refuses a soft-deleted exam, question or key-bearing option, and excludes the rest" do
    # A started session whose START snapshot is kept for comparison, then made a legacy one.
    defp legacy_ctx!(slug, specs) do
      ctx = scenario!(slug, specs, %{})
      start_snapshot = Fx.session_snapshot(ctx.schema, ctx.session_id)
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
      Map.put(ctx, :start_snapshot, start_snapshot)
    end

    defp soft_delete_option!(ctx, index) do
      :ok = Fx.delete_record!(ctx.schema, "answer_option", Enum.at(ctx.q.option_ids, index))
    end

    defp key_missing(ctx), do: {:grading_error, {:key_missing, ctx.q.id}}

    # The late snapshot is built and its item for the first question equals the start item.
    defp assert_late_item_equals_start!(ctx) do
      assert {:ok, snapshot} = Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)
      assert %{"origin" => "late"} = snapshot
      assert snapshot["questions"][ctx.q.id] == ctx.start_snapshot["questions"][ctx.q.id]
      snapshot
    end

    defp multiple_spec, do: {"multiple", [{true, %{}}, {true, %{}}, {false, %{}}]}

    defp truefalse_spec, do: {"truefalse", [{true, %{}}, {false, %{}}]}

    defp three_option_single_spec, do: {"single", [{true, %{}}, {false, %{}}, {false, %{}}]}

    defp likert_option_attrs(weight),
      do: %{"likert_weight" => weight, "likert_polarity" => "positive"}

    defp session_question_ids(schema, session_id) do
      Repo.all(
        from(l in Latest,
          where:
            l.entity_type == "session_question" and
              fragment("?->>?", l.field_values, "session_id") == ^session_id,
          select: {l.record_id, fragment("?->>?", l.field_values, "question_id")}
        ),
        prefix: schema
      )
    end

    test "T-49b the live exam is SOFT-deleted: :exam_section_missing on ensure and submit, nothing written, session in progress" do
      ctx = legacy_scenario!("gh2734-t49b")
      :ok = Fx.delete_record!(ctx.schema, "exam", ctx.exam.record_id)
      assert_late_build_fails!(ctx, {:grading_error, :exam_section_missing})
    end

    test "T-49d a soft-deleted exam and a hard-deleted exam give the identical error value" do
      soft = legacy_scenario!("gh2734-t49d-soft")
      :ok = Fx.delete_record!(soft.schema, "exam", soft.exam.record_id)

      hard = legacy_scenario!("gh2734-t49d-hard")
      :ok = hard_delete!(hard.schema, "exam", hard.exam.record_id)

      soft_result = Snapshot.ensure(soft.session_id, soft.candidate, soft.schema)
      hard_result = Snapshot.ensure(hard.session_id, hard.candidate, hard.schema)

      assert soft_result == {:error, {:grading_error, :exam_section_missing}}
      assert soft_result == hard_result
    end

    test "T-49c a submitted legacy session whose exam is soft-deleted cannot get certificate facts: :exam_section_missing, no write, no audit entry (fail closed)" do
      ctx = terminal_legacy!("gh2734-t49c", :submitted)
      :ok = Fx.delete_record!(ctx.schema, "exam", ctx.exam.record_id)
      before = snapshot_of_state(ctx)

      assert grading(:exam_section_missing) ==
               Snapshot.ensure_certificate_facts(ctx.session_id, ctx.candidate, ctx.schema)

      assert snapshot_of_state(ctx) == before
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == nil
      assert late_audit(ctx.schema) == []
    end

    test "T-50b a session_question's question is SOFT-deleted: {:question_item_missing, id}, nothing written" do
      ctx = legacy_scenario!("gh2734-t50b")
      :ok = Fx.delete_record!(ctx.schema, "question", ctx.q.id)
      assert_late_build_fails!(ctx, {:grading_error, {:question_item_missing, ctx.q.id}})
    end

    test "T-50c GUARD single-choice: a soft-deleted INCORRECT option leaves the built item identical to the start item" do
      ctx = legacy_ctx!("gh2734-t50c", [three_option_single_spec()])
      soft_delete_option!(ctx, 1)
      assert_late_item_equals_start!(ctx)
    end

    test "T-50c2 single-choice: a soft-deleted CORRECT option refuses {:key_missing, id} although other live options remain" do
      ctx = legacy_ctx!("gh2734-t50c2", [three_option_single_spec()])
      soft_delete_option!(ctx, 0)
      assert_late_build_fails!(ctx, key_missing(ctx))
    end

    test "T-50c2b truefalse: a soft-deleted CORRECT option refuses {:key_missing, id}; GUARD leg: a soft-deleted INCORRECT option is built with the correct set unchanged" do
      refused = legacy_ctx!("gh2734-t50c2b-correct", [truefalse_spec()])
      soft_delete_option!(refused, 0)
      assert_late_build_fails!(refused, key_missing(refused))

      guard = legacy_ctx!("gh2734-t50c2b-incorrect", [truefalse_spec()])
      soft_delete_option!(guard, 1)
      assert_late_item_equals_start!(guard)
    end

    test "T-50c3 multiple-choice: a soft-deleted CORRECT option refuses {:key_missing, id} even while another correct option stays live" do
      ctx = legacy_ctx!("gh2734-t50c3", [multiple_spec()])
      soft_delete_option!(ctx, 0)
      assert_late_build_fails!(ctx, key_missing(ctx))
    end

    test "T-50c4 GUARD multiple-choice: a soft-deleted INCORRECT option leaves the built item identical to the start item" do
      ctx = legacy_ctx!("gh2734-t50c4", [multiple_spec()])
      soft_delete_option!(ctx, 2)
      assert_late_item_equals_start!(ctx)
    end

    test "T-50c5 likert: a soft-deleted weighted option refuses {:key_missing, id}" do
      ctx = legacy_ctx!("gh2734-t50c5-weighted", [likert_spec()])
      soft_delete_option!(ctx, 1)
      assert_late_build_fails!(ctx, key_missing(ctx))
    end

    test "T-50c5 likert: a soft-deleted option with a nil weight and no is_correct is excluded, the late snapshot is built from the live options" do
      spec = {"likert", elem(likert_spec(), 1) ++ [{false, likert_option_attrs(2.0)}]}
      ctx = scenario!("gh2734-t50c5-unweighted", [spec], %{})
      [live_a, live_b, extra] = ctx.q.option_ids
      Fx.force_field!(ctx.schema, "answer_option", extra, "likert_weight", {:put, nil})
      Fx.force_field!(ctx.schema, "answer_option", extra, "likert_polarity", {:put, nil})
      :ok = Fx.delete_record!(ctx.schema, "answer_option", extra)
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)

      assert {:ok, snapshot} = Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)
      assert %{"origin" => "late"} = snapshot

      assert snapshot["questions"][ctx.q.id]["likert_options"] |> Map.keys() |> Enum.sort() ==
               Enum.sort([live_a, live_b])
    end

    test "T-50c5 likert: a soft-deleted option with a nil weight and is_correct true is key-bearing and refuses {:key_missing, id}" do
      spec = {"likert", elem(likert_spec(), 1) ++ [{true, likert_option_attrs(2.0)}]}
      ctx = scenario!("gh2734-t50c5-correct", [spec], %{})
      extra = List.last(ctx.q.option_ids)
      Fx.force_field!(ctx.schema, "answer_option", extra, "likert_weight", {:put, nil})
      Fx.force_field!(ctx.schema, "answer_option", extra, "likert_polarity", {:put, nil})
      :ok = Fx.delete_record!(ctx.schema, "answer_option", extra)
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)

      assert_late_build_fails!(ctx, key_missing(ctx))
    end

    test "T-50c7 GUARD shorttext: a soft-deleted option is excluded, the late snapshot is built and holds no deleted id" do
      ctx = scenario!("gh2734-t50c7", [{"shorttext", []}], %{})
      option = create_option!(ctx.schema, ctx.q.id, 0, false, %{})
      :ok = Fx.delete_record!(ctx.schema, "answer_option", option.record_id)
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)

      assert {:ok, snapshot} = Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)
      assert %{"origin" => "late"} = snapshot
      assert snapshot["questions"][ctx.q.id]["correct_option_ids"] == []
      refute inspect(snapshot) =~ option.record_id
    end

    test "T-50c6 a refusal caused by a soft-deleted key-bearing option leaves the session in progress with no snapshot, no score and no audit entry" do
      ctx = legacy_ctx!("gh2734-t50c6", [multiple_spec()])
      soft_delete_option!(ctx, 1)
      before = snapshot_of_state(ctx)

      assert_late_build_fails!(ctx, key_missing(ctx))

      assert snapshot_of_state(ctx) == before
      assert before.fv["status"] == "in_progress"
      refute Map.has_key?(before.fv, "exam_snapshot")
      assert before.scores == 0
      assert late_audit(ctx.schema) == []
    end

    test "T-50d a soft-deleted session_question is excluded from the late snapshot's order and questions" do
      ctx = legacy_ctx!("gh2734-t50d", [single_spec(), single_spec()])
      [first, second] = ctx.questions

      assert Enum.sort([first.id, second.id]) ==
               Enum.sort(Map.keys(ctx.start_snapshot["questions"]))

      assert {removed_record_id, _} =
               ctx.schema
               |> session_question_ids(ctx.session_id)
               |> Enum.find(fn {_record_id, question_id} -> question_id == second.id end)

      :ok = Fx.delete_record!(ctx.schema, "session_question", removed_record_id)

      assert {:ok, snapshot} = Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)
      assert snapshot["order"] == [first.id]
      assert Map.keys(snapshot["questions"]) == [first.id]
    end

    test "R1 GUARD replay: a session that already has a late snapshot keeps it untouched when its exam and question are soft-deleted afterwards" do
      ctx = legacy_scenario!("gh2734-r1")
      assert {:ok, snapshot} = Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)
      :ok = Fx.delete_record!(ctx.schema, "exam", ctx.exam.record_id)
      :ok = Fx.delete_record!(ctx.schema, "question", ctx.q.id)
      audits = length(late_audit(ctx.schema))
      assert audits == 1

      assert {:ok, ^snapshot} = Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)

      assert {:ok, %{questions: [_]}} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == snapshot

      assert {:ok, %{status: :submitted}} =
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == snapshot
      assert length(late_audit(ctx.schema)) == audits
    end

    # TRIPWIRE for `key_bearing?/2` in snapshot.ex: `shorttext` options are exempt from the
    # deleted-key-bearing refusal ONLY because a short_text question is never auto-graded.
    test "short_text is never auto-graded" do
      question = %{
        question_id: "q-short",
        type: :short_text,
        correct_option_ids: ["opt-correct"]
      }

      answer = %{selected_option_ids: ["opt-correct"], text_answer: "opt-correct"}

      msg =
        "shorttext key_bearing? exemption (snapshot.ex TRIPWIRE) no longer holds; " <>
          "flip key_bearing?/2 to refuse for shorttext"

      assert {:ok, %{grading_status: :pending_manual, score: score, max_score: 1.0}} =
               Scoring.score_question(question, answer),
             msg

      assert score == 0.0, msg

      assert {:ok, %{per_question: [per_q], outcome: outcome}} =
               Scoring.score_session([question], %{"q-short" => answer}, 0.0)

      assert per_q.grading_status == :pending_manual, msg
      assert per_q.score == 0.0, msg
      assert outcome.status == :grading_pending, msg
      assert outcome.passed == nil, msg
    end
  end

  # ── T-52 / T-63: ownership before every probe ──────────────────────────────────────────────

  describe "T-52 a non-owner never causes a write" do
    test "autosave, state read, submit, ensure and ensure_certificate_facts by another user are :not_owner and change nothing; an unknown id is :session_not_found" do
      ctx = legacy_scenario!("gh2682-b-t52")
      stranger = Ecto.UUID.generate()
      before = snapshot_of_state(ctx)

      answer = %{question_id: ctx.q.id, selected_option_ids: [], time_spent_seconds: 0}

      assert {:error, :not_owner} ==
               Session.autosave_answer(ctx.session_id, stranger, answer, ctx.schema)

      assert {:error, :not_owner} ==
               Session.get_session_state_for_user(ctx.session_id, stranger, ctx.schema)

      assert {:error, :not_owner} == Session.submit(ctx.session_id, stranger, ctx.schema)
      assert {:error, :not_owner} == Snapshot.ensure(ctx.session_id, stranger, ctx.schema)

      assert {:error, :not_owner} ==
               Snapshot.ensure_certificate_facts(ctx.session_id, stranger, ctx.schema)

      assert snapshot_of_state(ctx) == before
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == nil

      missing = Ecto.UUID.generate()
      assert {:error, :session_not_found} == Snapshot.ensure(missing, stranger, ctx.schema)

      assert {:error, :session_not_found} ==
               Snapshot.ensure_certificate_facts(missing, stranger, ctx.schema)
    end
  end

  describe "T-63 / R6 ownership before prerequisites, and query-count parity" do
    test "in a tenant that is not rolled out a non-owner and a nonexistent id get the not-found pair at the same cost; the owner gets the 503-class error" do
      ctx = legacy_scenario!("gh2682-b-t63")
      Fx.downgrade_session_definition!(ctx.schema)

      stranger = Ecto.UUID.generate()
      missing = Ecto.UUID.generate()
      schema = ctx.schema
      answer = %{question_id: ctx.q.id, selected_option_ids: [], time_spent_seconds: 0}

      calls = [
        {:ensure, fn id -> Snapshot.ensure(id, stranger, schema) end},
        {:certificate_facts,
         fn id -> Snapshot.ensure_certificate_facts(id, stranger, schema) end},
        {:autosave, fn id -> Session.autosave_answer(id, stranger, answer, schema) end},
        {:state, fn id -> Session.get_session_state_for_user(id, stranger, schema) end}
      ]

      for {name, call} <- calls do
        {real, real_queries} = count_queries(fn -> call.(ctx.session_id) end)
        {none, none_queries} = count_queries(fn -> call.(missing) end)

        assert {name, real} == {name, {:error, :not_owner}}
        assert {name, none} == {name, {:error, :session_not_found}}
        assert {name, real_queries} == {name, none_queries}
        assert {name, real_queries > 0} == {name, true}
      end

      assert {:error, {:snapshot_error, :definition_missing}} ==
               Snapshot.ensure(ctx.session_id, ctx.candidate, schema)
    end
  end

  # ── T-61 / T-61b: the cutover rule ─────────────────────────────────────────────────────────

  describe "T-61 a record inserted after the cutover that lost its snapshot is NOT healed" do
    test "every touch is :snapshot_missing, nothing is written, no audit entry (also for a nil value)" do
      for {slug, change} <- [
            {"gh2682-b-t61-delete", :delete},
            {"gh2682-b-t61-nil", {:put, nil}}
          ] do
        ctx = scenario!(slug, [single_spec()], %{})
        Fx.force_field!(ctx.schema, "session", ctx.session_id, "exam_snapshot", change)
        before = snapshot_of_state(ctx)

        for {name, touch} <- owner_touches(ctx) do
          assert {{slug, name}, touch.()} == {{slug, name}, grading(:snapshot_missing)}
          assert {{slug, name}, snapshot_of_state(ctx)} == {{slug, name}, before}
        end

        assert late_audit(ctx.schema) == []
      end
    end

    test "T-61b rewriting started_at far into the past while dropping the snapshot does not reopen the live heal" do
      ctx = scenario!("gh2682-b-t61b", [single_spec()], %{})
      assert {:ok, cutover} = Snapshot.cutover(ctx.schema)
      long_ago = cutover |> DateTime.add(-30 * 86_400, :second) |> DateTime.to_iso8601()

      Fx.force_field!(ctx.schema, "session", ctx.session_id, "exam_snapshot", :delete)
      Fx.force_field!(ctx.schema, "session", ctx.session_id, "started_at", {:put, long_ago})

      assert session_fv(ctx.schema, ctx.session_id)["started_at"] == long_ago
      before = snapshot_of_state(ctx)

      for {name, touch} <- owner_touches(ctx) do
        assert {name, touch.()} == {name, grading(:snapshot_missing)}
        assert {name, snapshot_of_state(ctx)} == {name, before}
      end

      assert late_audit(ctx.schema) == []
    end

    test "the boundary is strict: a record inserted AT the cutover instant is refused, one microsecond earlier is healed" do
      ctx = legacy_scenario!("gh2682-b-boundary")
      assert {:ok, cutover} = Snapshot.cutover(ctx.schema)

      :ok = set_inserted_at!(ctx.schema, ctx.session_id, cutover)
      before = snapshot_of_state(ctx)

      assert grading(:snapshot_missing) ==
               Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)

      assert snapshot_of_state(ctx) == before

      :ok =
        set_inserted_at!(ctx.schema, ctx.session_id, DateTime.add(cutover, -1, :microsecond))

      assert {:ok, %{"origin" => "late"}} =
               Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)

      assert length(late_audit(ctx.schema)) == 1
    end
  end

  describe "a snapshot that is present is never replaced" do
    test "T-18b a corrupt snapshot on a pre-cutover record: every touch is :snapshot_corrupt, the value stays, nothing is audited" do
      ctx = legacy_scenario!("gh2682-b-t18b")

      for garbage <- ["garbage", 5, ["x"]] do
        Fx.update_record!(ctx.schema, "session", ctx.session_id, %{"exam_snapshot" => garbage})
        before = snapshot_of_state(ctx)

        for {name, touch} <- owner_touches(ctx) do
          assert {{garbage, name}, touch.()} == {{garbage, name}, grading(:snapshot_corrupt)}
          assert {{garbage, name}, snapshot_of_state(ctx)} == {{garbage, name}, before}
        end

        assert Fx.session_snapshot(ctx.schema, ctx.session_id) == garbage
        assert late_audit(ctx.schema) == []
      end
    end

    test "T-18b a snapshot with a stale digest on a pre-cutover record is :snapshot_corrupt on ensure and submit, and is not replaced" do
      ctx = scenario!("gh2682-b-t18b-stale", [single_spec()], %{})
      answer!(ctx, [hd(ctx.q.option_ids)])

      tampered =
        put_in(
          Fx.session_snapshot(ctx.schema, ctx.session_id),
          ["questions", ctx.q.id, "correct_option_ids"],
          [List.last(ctx.q.option_ids)]
        )

      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
      Fx.update_record!(ctx.schema, "session", ctx.session_id, %{"exam_snapshot" => tampered})
      before = snapshot_of_state(ctx)

      assert grading(:snapshot_corrupt) ==
               Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)

      assert grading(:snapshot_corrupt) ==
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert snapshot_of_state(ctx) == before
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == tampered
      assert late_audit(ctx.schema) == []
    end

    test "T-24 / M4 a valid snapshot on a pre-cutover record is returned as is: no rebuild, no write, no audit entry" do
      ctx = scenario!("gh2682-b-existing", [single_spec()], %{})
      answer!(ctx, [hd(ctx.q.option_ids)])
      pristine = Fx.session_snapshot(ctx.schema, ctx.session_id)

      # the record is old enough for a late snapshot, but it already has a real one
      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
      Fx.update_record!(ctx.schema, "session", ctx.session_id, %{"exam_snapshot" => pristine})
      before = snapshot_of_state(ctx)

      assert {:ok, ^pristine} = Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)

      assert {:ok, %{questions: [_]}} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert snapshot_of_state(ctx) == before
      assert Fx.session_snapshot(ctx.schema, ctx.session_id) == pristine
      assert late_audit(ctx.schema) == []

      assert {:ok, %{status: :submitted}} =
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert %{"origin" => "start", "nonce" => nonce} =
               Fx.session_snapshot(ctx.schema, ctx.session_id)

      assert nonce == pristine["nonce"]
      assert late_audit(ctx.schema) == []
    end
  end

  # ── terminal sessions (I-3), legacy variants of T-43 / T-46 ────────────────────────────────

  describe "terminal pre-cutover sessions are never given a snapshot by a touch (I-3)" do
    defp terminal_legacy!(slug, status) do
      specs = if status == :grading_pending, do: [{"shorttext", []}], else: [single_spec()]
      ctx = scenario!(slug, specs, %{})

      case status do
        :auto_submitted ->
          assert {:ok, %{status: :auto_submitted}} =
                   Session.finalize_expired(ctx.session_id, DateTime.utc_now(), ctx.schema)

        _submit ->
          assert {:ok, %{status: ^status}} =
                   Session.submit(ctx.session_id, ctx.candidate, ctx.schema)
      end

      :ok = Fx.legacy_session!(ctx.schema, ctx.session_id)
      ctx
    end

    test "T-43 / T-46 state read, ensure, autosave, submit replay and finalize replay write nothing for submitted, auto_submitted and grading_pending" do
      for status <- [:submitted, :auto_submitted, :grading_pending] do
        ctx = terminal_legacy!("gh2682-b-term-#{status}", status)
        before = snapshot_of_state(ctx)

        assert {:ok, %{questions: [_]}} =
                 Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)

        assert {status, grading(:snapshot_missing)} ==
                 {status, Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)}

        assert {status, {:error, :session_not_in_progress}} ==
                 {status,
                  Session.autosave_answer(
                    ctx.session_id,
                    ctx.candidate,
                    %{question_id: ctx.q.id, selected_option_ids: [], time_spent_seconds: 0},
                    ctx.schema
                  )}

        assert {:ok, %{status: ^status}} =
                 Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

        assert {:ok, %{status: ^status}} =
                 Session.finalize_expired(ctx.session_id, DateTime.utc_now(), ctx.schema)

        assert {status, snapshot_of_state(ctx)} == {status, before}
        assert Fx.session_snapshot(ctx.schema, ctx.session_id) == nil
      end
    end

    test "only a SUBMITTED session may be given certificate facts: auto_submitted and grading_pending are :snapshot_missing with no write" do
      for status <- [:auto_submitted, :grading_pending] do
        ctx = terminal_legacy!("gh2682-b-term-cert-#{status}", status)
        before = snapshot_of_state(ctx)

        assert {status, grading(:snapshot_missing)} ==
                 {status,
                  Snapshot.ensure_certificate_facts(ctx.session_id, ctx.candidate, ctx.schema)}

        assert {status, grading(:snapshot_missing)} ==
                 {status,
                  Session.get_snapshot_for_user(ctx.session_id, ctx.candidate, ctx.schema)}

        assert {status, snapshot_of_state(ctx)} == {status, before}
      end
    end

    test "an in-progress session is not a certificate session: ensure_certificate_facts is :snapshot_missing with no write" do
      ctx = legacy_scenario!("gh2682-b-term-inprogress")
      before = snapshot_of_state(ctx)

      assert grading(:snapshot_missing) ==
               Snapshot.ensure_certificate_facts(ctx.session_id, ctx.candidate, ctx.schema)

      assert snapshot_of_state(ctx) == before
    end

    test "T-44 a late_certificate session reads fine (live type, no write) as a terminal session, and is corrupt as an in-progress one" do
      ctx = terminal_legacy!("gh2682-b-t44", :submitted)

      assert {:ok, %{"origin" => "late_certificate"}} =
               Snapshot.ensure_certificate_facts(ctx.session_id, ctx.candidate, ctx.schema)

      Fx.update_record!(ctx.schema, "question", ctx.q.id, %{"type" => "multiple"})
      events = event_count(ctx.schema)

      assert {:ok, %{questions: [question]}} =
               Session.get_session_state_for_user(ctx.session_id, ctx.candidate, ctx.schema)

      assert question.type == :multiple
      assert event_count(ctx.schema) == events

      # the same facts on a session that is still in progress cannot be scored or autosaved
      snapshot = Fx.session_snapshot(ctx.schema, ctx.session_id)
      live = legacy_scenario!("gh2682-b-t44-live")
      Fx.update_record!(live.schema, "session", live.session_id, %{"exam_snapshot" => snapshot})

      assert grading(:snapshot_corrupt) ==
               Session.get_session_state_for_user(live.session_id, live.candidate, live.schema)
    end
  end

  # ── T-62 / T-63b: the cutover ──────────────────────────────────────────────────────────────

  defp activated_at(schema, version_id) do
    Repo.one(
      from(h in ActivationHistory,
        where: h.new_version_id == ^version_id and h.artifact_name == "session",
        select: min(h.activated_at)
      ),
      prefix: schema
    )
  end

  defp without_snapshot_field(definition) do
    Map.update!(definition, :fields, fn fields ->
      Enum.reject(fields, &(&1.name == "exam_snapshot"))
    end)
  end

  describe "T-62 the cutover of a fresh-install tenant" do
    # The pack install creates every definition INACTIVE (`SolutionPack.install` never calls
    # `activate_definition/4`, decision 0026 section 2), so a freshly installed tenant has no
    # activation row, and no active `session` definition to start a session with, until it goes
    # live. The cutover of a fresh-install tenant is therefore its go-live activation of the pack's
    # `session` definition, which already declares `exam_snapshot`.
    test "it is the go-live activation of the installed session definition that declares exam_snapshot; until then there is none" do
      %{schema_name: schema} = StampFx.bare_tenant!("gh2682-b-t62", false)

      assert {:error, :definition_missing} = Snapshot.cutover(schema)

      assert {:ok, _tenant_module} =
               Installs.install("exam", Ecto.UUID.generate(),
                 prefix: schema,
                 rationale: "GH #2682 PR b test: fresh install"
               )

      # installed, not live: no activation row yet
      assert {:error, :definition_missing} = Snapshot.cutover(schema)

      assert {:ok, _activated} =
               Definitions.activate_definition("session", Ecto.UUID.generate(), "go-live", schema)

      assert {:ok, cutover} = Snapshot.cutover(schema)
      assert {:ok, active} = Definitions.get_active_definition_by_name("session", schema)
      assert Enum.any?(active.definition_json["fields"], &(&1["name"] == "exam_snapshot"))
      assert DateTime.compare(cutover, activated_at(schema, active.artifact_version_id)) == :eq
      assert DateTime.compare(cutover, DateTime.utc_now()) != :gt
    end

    test "a fixture tenant's cutover is its first activation of the session definition" do
      %{schema_name: schema} = tenant("gh2682-b-t62-fixture")
      assert {:ok, active} = Definitions.get_active_definition_by_name("session", schema)
      assert {:ok, cutover} = Snapshot.cutover(schema)
      assert DateTime.compare(cutover, activated_at(schema, active.artifact_version_id)) == :eq
    end
  end

  describe "T-63b Snapshot.cutover/1" do
    test "is the MINIMUM activation of a version that declares exam_snapshot; versions without it are ignored; none is :definition_missing" do
      %{schema_name: schema} = StampFx.stamp_ready_tenant!("gh2682-b-t63b")

      # v1: a legacy session definition WITHOUT the field, activated first
      v1 =
        StampFx.create_definition!(
          schema,
          "session"
          |> StampFx.legacy_definition()
          |> without_snapshot_field()
          |> Map.put(:constraints, [])
        )

      :ok = StampFx.activate!(schema, "session")
      assert {:error, :definition_missing} = Snapshot.cutover(schema)

      # v2: the rollout adds the field and activates it
      assert %{status: :upgraded} = Rollout.run_tenant(schema, [])
      assert {:ok, v2} = Definitions.get_active_definition_by_name("session", schema)
      assert {:ok, cutover} = Snapshot.cutover(schema)

      v1_at = activated_at(schema, v1.artifact_version_id)
      v2_at = activated_at(schema, v2.artifact_version_id)
      assert DateTime.compare(v1_at, v2_at) == :lt
      assert DateTime.compare(cutover, v2_at) == :eq

      # v3: another version with the field, activated later: the minimum does not move
      v3_definition =
        "session"
        |> StampFx.legacy_definition()
        |> Map.update!(:fields, &(&1 ++ [StampFx.field("zz_probe", :string)]))
        |> Map.put(:constraints, [])

      v3 = StampFx.create_definition!(schema, v3_definition)
      :ok = StampFx.activate!(schema, "session")
      v3_at = activated_at(schema, v3.artifact_version_id)

      assert DateTime.compare(v3_at, v2_at) == :gt
      assert {:ok, ^cutover} = Snapshot.cutover(schema)
    end

    test "an active definition that declares the field but has no activation history row fails closed: {:snapshot_error, :definition_missing}, nothing written (no other cutover source)" do
      ctx = legacy_scenario!("gh2682-b-t63b-nohistory")

      Repo.query!(
        ~s|DELETE FROM "#{ctx.schema}".artifact_activation_history WHERE artifact_name = 'session'|
      )

      assert {:error, :definition_missing} = Snapshot.cutover(ctx.schema)
      before = snapshot_of_state(ctx)

      assert {:error, {:snapshot_error, :definition_missing}} ==
               Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)

      assert {:error, {:snapshot_error, :definition_missing}} ==
               Session.submit(ctx.session_id, ctx.candidate, ctx.schema)

      assert snapshot_of_state(ctx) == before
    end

    test "a schema that is not a registered tenant is :invalid_schema_name" do
      assert {:error, :invalid_schema_name} = Snapshot.cutover("no_such_schema")
    end
  end

  # ── late_origin_counts/1 ───────────────────────────────────────────────────────────────────

  describe "Snapshot.late_origin_counts/1" do
    test "counts the tenant's sessions by snapshot origin (late, late_certificate); start snapshots are not counted; a bad prefix is an error" do
      %{schema_name: empty} = tenant("gh2682-b-counts-empty")
      assert {:ok, %{late: 0, late_certificate: 0}} = Snapshot.late_origin_counts(empty)

      ctx = legacy_scenario!("gh2682-b-counts")
      assert {:ok, %{late: 0, late_certificate: 0}} = Snapshot.late_origin_counts(ctx.schema)

      # two late snapshots
      assert {:ok, _} = Snapshot.ensure(ctx.session_id, ctx.candidate, ctx.schema)
      second = second_session!(ctx)
      :ok = Fx.legacy_session!(ctx.schema, second.session_id)
      assert {:ok, _} = Snapshot.ensure(second.session_id, second.candidate, ctx.schema)

      # one late_certificate snapshot
      third = second_session!(ctx)

      assert {:ok, %{status: :submitted}} =
               Session.submit(third.session_id, third.candidate, ctx.schema)

      :ok = Fx.legacy_session!(ctx.schema, third.session_id)

      assert {:ok, %{"origin" => "late_certificate"}} =
               Snapshot.ensure_certificate_facts(third.session_id, third.candidate, ctx.schema)

      # a plain session with a start snapshot is not counted
      _plain = second_session!(ctx)

      assert {:ok, %{late: 2, late_certificate: 1}} = Snapshot.late_origin_counts(ctx.schema)

      assert {:error, :invalid_schema_name} = Snapshot.late_origin_counts("no_such_schema")
    end
  end
end
