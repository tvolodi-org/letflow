defmodule Letflow.Modules.Exam.AntiCheatTest do
  @moduledoc """
  REQ-333 -- integration tests for `Letflow.Modules.Exam.AntiCheat` against a real
  provisioned tenant (DIRECTIVE T-1: no mocked database). Self-contained via
  `Letflow.ExamFixtures` (DIRECTIVE T-4), mirroring
  `test/letflow/exam/session_test.exs`'s own hand-rolled tenant-fixture
  pattern.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Exam.AntiCheat
  alias Letflow.Modules.Exam.Session
  alias Letflow.ExamFixtures
  alias Letflow.Repo

  import Ecto.Query, only: [from: 2]

  # ---------------------------------------------------------------------
  # Shared fixture helpers
  # ---------------------------------------------------------------------

  defp tenant(slug), do: ExamFixtures.provisioned_tenant_with_exam_definitions(slug)

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp create_exam!(schema, attrs) do
    defaults = %{
      "title" => %{"en" => "Exam"},
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 5,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => false
    }

    ExamFixtures.create_record!(schema, "exam", Map.merge(defaults, attrs))
  end

  # A directly-materialized session (bypassing Session.create/3) -- gives
  # each test explicit control over status/expires_at/user_id without
  # needing a real question pool, matching this suite's own guard/debounce
  # tests. The "submit" policy-branch test below uses the real
  # `Session.create/3` pipeline instead, since it needs a real, gradeable
  # question set for `Session.submit/3` to score.
  defp create_session!(schema, exam_id, user_id, attrs \\ %{}) do
    now = DateTime.utc_now()

    defaults = %{
      "exam_id" => exam_id,
      "user_id" => user_id,
      "status" => "in_progress",
      "seed" => 1,
      "started_at" => iso(now),
      "expires_at" => iso(DateTime.add(now, 3600, :second)),
      "passed" => false,
      # GH #2682 / REQ-511: scoring reads only the session's own snapshot, so a hand-built session
      # that the "submit" policy auto-submits carries a valid (empty) one.
      "exam_snapshot" => ExamFixtures.empty_snapshot!(exam_id)
    }

    ExamFixtures.create_record!(schema, "session", Map.merge(defaults, attrs))
  end

  defp create_session_event!(schema, session_id, occurred_at, event_type, action_taken) do
    ExamFixtures.create_record!(schema, "session_event", %{
      "session_id" => session_id,
      "occurred_at" => iso(occurred_at),
      "event_type" => event_type,
      "action_taken" => action_taken
    })
  end

  defp session_events_for(schema, session_id) do
    Repo.all(
      from(r in Latest,
        where:
          r.entity_type == "session_event" and
            fragment("?->>?", r.field_values, "session_id") == ^session_id
      ),
      prefix: schema
    )
  end

  defp session_status(schema, session_id) do
    {:ok, %Latest{field_values: field_values}} = Latest.get(session_id, "session", schema)
    Map.fetch!(field_values, "status")
  end

  defp with_debounce_seconds(seconds, fun) do
    previous = Application.get_env(:letflow, :anti_cheat_debounce_seconds)
    Application.put_env(:letflow, :anti_cheat_debounce_seconds, seconds)

    try do
      fun.()
    after
      case previous do
        nil -> Application.delete_env(:letflow, :anti_cheat_debounce_seconds)
        value -> Application.put_env(:letflow, :anti_cheat_debounce_seconds, value)
      end
    end
  end

  # Builds a minimal, fully-gradeable exam (one single-choice question,
  # taken once) via the real `Session.create/3` pipeline -- needed only by
  # the "submit" policy-branch test, which asserts on real post-submit
  # session status.
  defp build_gradeable_session!(schema, exam_attrs) do
    category_id = Ecto.UUID.generate()
    exam = create_exam!(schema, exam_attrs)

    question =
      ExamFixtures.create_record!(schema, "question", %{
        "category_id" => category_id,
        "difficulty" => "easy",
        "type" => "single",
        "default_locale" => "en",
        "status" => "active",
        "version" => 1,
        "stem" => %{"en" => "Stem?"}
      })

    ExamFixtures.create_record!(schema, "answer_option", %{
      "question_id" => question.record_id,
      "sort_order" => 0,
      "is_correct" => true,
      "text" => %{"en" => "Correct"}
    })

    ExamFixtures.create_record!(schema, "answer_option", %{
      "question_id" => question.record_id,
      "sort_order" => 1,
      "is_correct" => false,
      "text" => %{"en" => "Wrong"}
    })

    ExamFixtures.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 1,
      "sort_order" => 0
    })

    candidate_id = Ecto.UUID.generate()

    # FINDING (flagged for REVIEWER/ORCH, not fixed here -- out of REQ-333's
    # authorized scope, which is `Letflow.Modules.Exam.AntiCheat` only):
    # `Letflow.Modules.Exam.Session.session_view/1` calls
    # `String.to_existing_atom(fv(session, "status"))`, and `:in_progress` is
    # the ONE status value that appears nowhere else in `lib/letflow/` as a
    # literal atom (unlike `:submitted`/`:auto_submitted`/`:grading_pending`,
    # which session.ex's own `maybe_override_status/2`/`outcome_from_session/1`
    # already reference literally). In an isolated process that has never
    # otherwise referenced `:in_progress` as a literal -- observed in
    # practice under `mix letflow.check.test`'s parallel partitioning, where
    # this test can land in a partition that never loads
    # `Mix.Tasks.Letflow.CheckDeferralStaleness` or any other module with
    # that literal -- `Session.create/3` raises `ArgumentError` here, before
    # `AntiCheat.record_signal/4` is ever reached. This line interns the atom
    # so THIS test is deterministic regardless of partition; it does not fix
    # the underlying fragility in already-merged `Letflow.Modules.Exam.Session`
    # (REQ-332), which should get its own literal-atom-bearing status mapper
    # (the same `question_type_atom/1`-style idiom `Letflow.Modules.Exam.Session`
    # already uses for question types) as a follow-up.
    _ = String.to_atom("in_progress")

    {:ok, session_view} = Session.create(candidate_id, exam.record_id, schema)
    %{exam: exam, candidate_id: candidate_id, session_id: session_view.id}
  end

  # ---------------------------------------------------------------------
  # Signal-type validation (service.go:523 validEventTypes / :530)
  # ---------------------------------------------------------------------

  describe "signal-type validation" do
    test "accepts exactly the three signal types service.go's validEventTypes admits" do
      %{schema_name: schema} = tenant("req333-sigtype-ok")
      exam = create_exam!(schema, %{})
      candidate_id = Ecto.UUID.generate()
      session = create_session!(schema, exam.record_id, candidate_id)

      for signal_type <- [:tab_switch, :blur, :fullscreen_exit] do
        assert {:ok, %{action_taken: :log}} =
                 AntiCheat.record_signal(session.record_id, candidate_id, signal_type, schema)
      end
    end

    test "a fourth value is rejected with a distinct error, distinct from every guard error" do
      %{schema_name: schema} = tenant("req333-sigtype-bad")
      exam = create_exam!(schema, %{})
      candidate_id = Ecto.UUID.generate()
      session = create_session!(schema, exam.record_id, candidate_id)

      assert {:error, :invalid_signal_type} =
               AntiCheat.record_signal(session.record_id, candidate_id, :mouse_leave, schema)

      # No row was written for the rejected signal.
      assert session_events_for(schema, session.record_id) == []
    end
  end

  # ---------------------------------------------------------------------
  # AC-10 -- action_taken is derived from config, never caller-suppliable
  # ---------------------------------------------------------------------

  describe "action_taken cannot be caller-supplied (service.go AC-10)" do
    test "record_signal/4 has no action_taken parameter -- structurally impossible to supply one" do
      Code.ensure_loaded!(AntiCheat)
      assert function_exported?(AntiCheat, :record_signal, 4)
      refute function_exported?(AntiCheat, :record_signal, 5)
    end

    test "recorded action_taken always equals the exam's on_tab_switch config, for every policy value" do
      for policy <- ["log", "warn", "submit"] do
        %{schema_name: schema} = tenant("req333-ac10-#{policy}")
        exam = create_exam!(schema, %{"on_tab_switch" => policy})
        candidate_id = Ecto.UUID.generate()
        session = create_session!(schema, exam.record_id, candidate_id)

        assert {:ok, %{action_taken: recorded_action}} =
                 AntiCheat.record_signal(session.record_id, candidate_id, :tab_switch, schema)

        assert Atom.to_string(recorded_action) == policy

        [event] = session_events_for(schema, session.record_id)
        assert event.field_values["action_taken"] == policy
      end
    end

    test "a session configured 'log' never records 'submit', proving the config -- not any caller intent -- decides" do
      %{schema_name: schema} = tenant("req333-ac10-contradiction")
      exam = create_exam!(schema, %{"on_tab_switch" => "log"})
      candidate_id = Ecto.UUID.generate()
      session = create_session!(schema, exam.record_id, candidate_id)

      assert {:ok, %{action_taken: :log, submission: nil}} =
               AntiCheat.record_signal(session.record_id, candidate_id, :blur, schema)

      [event] = session_events_for(schema, session.record_id)
      assert event.field_values["action_taken"] == "log"
      # The session was NOT auto-submitted, even though a caller hoping to
      # force a "submit" outcome has no field anywhere in this call to try.
      assert session_status(schema, session.record_id) == "in_progress"
    end
  end

  # ---------------------------------------------------------------------
  # Policy branches, end to end
  # ---------------------------------------------------------------------

  describe "on_tab_switch policy branches" do
    test "'log' records the signal and returns the running count, no warning" do
      %{schema_name: schema} = tenant("req333-policy-log")
      exam = create_exam!(schema, %{"on_tab_switch" => "log"})
      candidate_id = Ecto.UUID.generate()
      session = create_session!(schema, exam.record_id, candidate_id)

      assert {:ok, %{action_taken: :log, event_count: 1, warning: false, submission: nil}} =
               AntiCheat.record_signal(session.record_id, candidate_id, :tab_switch, schema)
    end

    test "'warn' returns the warning flag plus the running count" do
      %{schema_name: schema} = tenant("req333-policy-warn")
      exam = create_exam!(schema, %{"on_tab_switch" => "warn"})
      candidate_id = Ecto.UUID.generate()
      session = create_session!(schema, exam.record_id, candidate_id)

      assert {:ok, %{action_taken: :warn, event_count: 1, warning: true, submission: nil}} =
               AntiCheat.record_signal(session.record_id, candidate_id, :blur, schema)
    end

    test "'submit' records the signal, auto-submits AND SCORES, and the session's real stored status transitions" do
      %{schema_name: schema} = tenant("req333-policy-submit")

      %{candidate_id: candidate_id, session_id: session_id} =
        build_gradeable_session!(schema, %{"on_tab_switch" => "submit"})

      assert session_status(schema, session_id) == "in_progress"

      assert {:ok,
              %{
                action_taken: :submit,
                event_count: 1,
                warning: false,
                submission: %{status: status, percentage: _percentage}
              }} =
               AntiCheat.record_signal(session_id, candidate_id, :fullscreen_exit, schema)

      assert status in [:submitted, :grading_pending]

      # Real post-call session state, not just the return value.
      assert session_status(schema, session_id) == Atom.to_string(status)
      assert session_status(schema, session_id) != "in_progress"

      [event] = session_events_for(schema, session_id)
      assert event.field_values["action_taken"] == "submit"
    end
  end

  # ---------------------------------------------------------------------
  # Server-side guards, three distinct errors
  # ---------------------------------------------------------------------

  describe "server-side guards" do
    test "a signal on another candidate's session is rejected with :not_owner" do
      %{schema_name: schema} = tenant("req333-guard-owner")
      exam = create_exam!(schema, %{})
      owner_id = Ecto.UUID.generate()
      other_id = Ecto.UUID.generate()
      session = create_session!(schema, exam.record_id, owner_id)

      assert {:error, :not_owner} =
               AntiCheat.record_signal(session.record_id, other_id, :tab_switch, schema)
    end

    test "a signal on a session that is not in progress is rejected with :session_not_in_progress" do
      %{schema_name: schema} = tenant("req333-guard-status")
      exam = create_exam!(schema, %{})
      candidate_id = Ecto.UUID.generate()

      session =
        create_session!(schema, exam.record_id, candidate_id, %{"status" => "submitted"})

      assert {:error, :session_not_in_progress} =
               AntiCheat.record_signal(session.record_id, candidate_id, :tab_switch, schema)
    end

    test "a signal on a session past its deadline is rejected with :deadline_passed" do
      %{schema_name: schema} = tenant("req333-guard-deadline")
      exam = create_exam!(schema, %{})
      candidate_id = Ecto.UUID.generate()
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)

      session =
        create_session!(schema, exam.record_id, candidate_id, %{"expires_at" => iso(past)})

      assert {:error, :deadline_passed} =
               AntiCheat.record_signal(session.record_id, candidate_id, :tab_switch, schema)
    end
  end

  # ---------------------------------------------------------------------
  # Write-amplification mitigation -- REQ-330's debounce, PROVEN under
  # repeated signals from one session (not just one signal recorded)
  # ---------------------------------------------------------------------

  describe "write-amplification mitigation (debounce)" do
    test "repeated rapid signals from one session collapse to a single new write inside the debounce window" do
      %{schema_name: schema} = tenant("req333-debounce")
      exam = create_exam!(schema, %{"on_tab_switch" => "log"})
      candidate_id = Ecto.UUID.generate()
      session = create_session!(schema, exam.record_id, candidate_id)

      with_debounce_seconds(60, fn ->
        # A pre-existing event, far outside the debounce window, so the
        # first live call below is NOT debounced.
        stale_at = DateTime.add(DateTime.utc_now(), -3600, :second)
        create_session_event!(schema, session.record_id, stale_at, "tab_switch", "log")

        assert length(session_events_for(schema, session.record_id)) == 1

        # First live signal: outside the window relative to the stale
        # pre-existing event -> written, count becomes 2.
        assert {:ok, %{event_count: 2}} =
                 AntiCheat.record_signal(session.record_id, candidate_id, :tab_switch, schema)

        assert length(session_events_for(schema, session.record_id)) == 2

        # Two more signals fired immediately afterward, well inside the
        # 60-second window relative to the write that just happened -- both
        # must be absorbed without a new row, and the returned count must
        # NOT climb past what was actually recorded.
        assert {:ok, %{event_count: 2}} =
                 AntiCheat.record_signal(session.record_id, candidate_id, :blur, schema)

        assert {:ok, %{event_count: 2}} =
                 AntiCheat.record_signal(
                   session.record_id,
                   candidate_id,
                   :fullscreen_exit,
                   schema
                 )

        # Repeated firing produced exactly one new row, not three.
        assert length(session_events_for(schema, session.record_id)) == 2
      end)
    end

    test "a signal arriving after the debounce window elapses IS recorded" do
      %{schema_name: schema} = tenant("req333-debounce-elapsed")
      exam = create_exam!(schema, %{"on_tab_switch" => "log"})
      candidate_id = Ecto.UUID.generate()
      session = create_session!(schema, exam.record_id, candidate_id)

      with_debounce_seconds(1, fn ->
        stale_at = DateTime.add(DateTime.utc_now(), -60, :second)
        create_session_event!(schema, session.record_id, stale_at, "tab_switch", "log")

        assert {:ok, %{event_count: 2}} =
                 AntiCheat.record_signal(session.record_id, candidate_id, :tab_switch, schema)

        assert length(session_events_for(schema, session.record_id)) == 2
      end)
    end
  end

  # ---------------------------------------------------------------------
  # INV-1 -- tenant data isolation
  # ---------------------------------------------------------------------

  describe "INV-1 tenant isolation" do
    test "a signal recorded in one tenant is invisible in another tenant's schema" do
      %{schema_name: schema_a} = tenant("req333-inv1-a")
      %{schema_name: schema_b} = tenant("req333-inv1-b")

      exam_a = create_exam!(schema_a, %{})
      candidate_id = Ecto.UUID.generate()
      session_a = create_session!(schema_a, exam_a.record_id, candidate_id)

      assert {:ok, %{action_taken: :log}} =
               AntiCheat.record_signal(session_a.record_id, candidate_id, :tab_switch, schema_a)

      assert length(session_events_for(schema_a, session_a.record_id)) == 1
      # Same session_id looked up under tenant B's schema: the session
      # itself does not exist there, so the call is rejected -- proving the
      # read path is prefix-scoped, not a global lookup.
      assert {:error, :session_not_found} =
               AntiCheat.record_signal(session_a.record_id, candidate_id, :tab_switch, schema_b)

      assert session_events_for(schema_b, session_a.record_id) == []
    end
  end
end
