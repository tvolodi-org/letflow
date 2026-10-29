defmodule Letflow.Modules.Exam.NotificationsTest do
  @moduledoc """
  REQ-597 / GH #3363 part A: the `exam_result` mail after a scored submit, through the REQ-584
  delivery log. Test ids S1, F1, T1..T3, I1, I2, X1 follow the T-0758 design (R1 lives in
  `registry_test.exs`, G1 is `notifications_test.exs` staying green).

  `async: false`: committed tenant writes, application env and the delivery tasks.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.ExamFixtures
  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.Modules.Exam.Notifications, as: ExamNotifications
  alias Letflow.Modules.Exam.Session
  alias Letflow.Notifications
  alias Letflow.Notifications.Delivery
  alias Letflow.Repo
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Test.SmtpHelpers, as: S

  @notifier Letflow.LoginDiscovery.Notifier

  setup do
    S.put_app_env!(@notifier, adapter: Double, timeout_ms: 200, max_concurrent: 5)
    Double.set_owner(self())
    previous = Application.fetch_env(:letflow, :exam_notifications_enabled)

    on_exit(fn ->
      Double.reset()

      case previous do
        {:ok, value} -> Application.put_env(:letflow, :exam_notifications_enabled, value)
        :error -> Application.delete_env(:letflow, :exam_notifications_enabled)
      end
    end)

    :ok
  end

  defp enable!, do: Application.put_env(:letflow, :exam_notifications_enabled, true)

  defp rows(prefix), do: Repo.all(Delivery, prefix: prefix)

  defp await_rows(prefix, count \\ 1) do
    Enum.reduce_while(1..100, [], fn _i, _acc ->
      found = rows(prefix)

      if length(found) >= count do
        {:halt, found}
      else
        Process.sleep(20)
        {:cont, found}
      end
    end)
  end

  # A tenant with one active exam (one single-choice question, answered correctly) and one
  # candidate (a real user row) who has an open session.
  defp setup_session!(slug, user_attrs \\ %{}) do
    %{schema_name: schema} = fx = ExamFixtures.provisioned_tenant_with_exam_definitions(slug)
    category_id = Ecto.UUID.generate()

    exam =
      ExamFixtures.create_record!(schema, "exam", %{
        "title" => %{"en" => "Safety Basics"},
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

    correct =
      ExamFixtures.create_record!(schema, "answer_option", %{
        "question_id" => question.record_id,
        "sort_order" => 0,
        "is_correct" => true,
        "text" => %{"en" => "Yes"}
      })

    ExamFixtures.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 1,
      "sort_order" => 0
    })

    user = RSG.user!(schema)

    if user_attrs != %{} do
      user |> Ecto.Changeset.change(user_attrs) |> Repo.update!(prefix: schema)
    end

    user = Repo.get!(Letflow.Identity.User, user.id, prefix: schema)
    {:ok, view} = Session.create(user.id, exam.record_id, schema)

    {:ok, _} =
      Session.autosave_answer(
        view.id,
        user.id,
        %{
          question_id: question.record_id,
          selected_option_ids: [correct.record_id],
          time_spent_seconds: 5
        },
        schema
      )

    Map.merge(fx, %{user: user, session_id: view.id, exam: exam})
  end

  describe "S1 no new sender, Bucket C" do
    test "only the SMTP transport touches the mail libraries; the generic module says no exam" do
      hits =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          source = File.read!(path)
          String.contains?(source, ":gen_smtp_client") or String.contains?(source, ":mimemail")
        end)
        |> Enum.map(&String.replace(&1, "\\", "/"))

      assert hits == ["lib/letflow/login_discovery/notifier/smtp/transport.ex"]
      refute File.read!("lib/letflow/notifications.ex") =~ "exam"
    end
  end

  describe "F1 flag" do
    test "defaults off in the shipped config" do
      assert Application.get_env(:letflow, :exam_notifications_enabled) == false
      refute ExamNotifications.enabled?()
    end

    test "off and the string \"true\" send nothing and change nothing" do
      fx = setup_session!("r597-flag")

      Application.put_env(:letflow, :exam_notifications_enabled, "true")
      refute ExamNotifications.enabled?()

      assert {:ok, outcome} = Session.submit(fx.session_id, fx.user.id, fx.schema_name)
      assert outcome.status == :submitted
      Process.sleep(100)
      assert rows(fx.schema_name) == []
      refute_received {:deliver_message, _}
    end
  end

  describe "T1..T3 trigger" do
    test "T1 submit sends one exam_result mail and logs ids only" do
      enable!()
      fx = setup_session!("r597-t1")

      assert {:ok, outcome} = Session.submit(fx.session_id, fx.user.id, fx.schema_name)
      assert outcome.passed == true

      assert_receive {:deliver_message, msg}, 2000
      assert msg.to == fx.user.email
      assert msg.subject =~ "Safety Basics"
      assert msg.body =~ "passed"
      assert msg.body =~ "100.0"

      assert [row] = await_rows(fx.schema_name)
      assert row.template_key == "exam_result"
      assert row.status == "sent"
      assert row.trigger_ref == fx.session_id
      assert row.recipient_user_id == fx.user.id
    end

    test "T2 finalize_expired sends the mail for an auto-submitted session" do
      enable!()
      fx = setup_session!("r597-t2")

      assert {:ok, outcome} =
               Session.finalize_expired(fx.session_id, DateTime.utc_now(), fx.schema_name)

      assert outcome.status == :auto_submitted
      assert_receive {:deliver_message, _msg}, 2000
      assert [%{template_key: "exam_result", trigger_ref: ref}] = await_rows(fx.schema_name)
      assert ref == fx.session_id
    end

    test "T3 a replayed submit and a pending outcome send nothing" do
      enable!()
      fx = setup_session!("r597-t3")

      assert {:ok, first} = Session.submit(fx.session_id, fx.user.id, fx.schema_name)
      assert_receive {:deliver_message, _}, 2000
      assert [_one] = await_rows(fx.schema_name)

      assert {:ok, second} = Session.submit(fx.session_id, fx.user.id, fx.schema_name)

      assert Map.take(second, [:status, :passed, :percentage]) ==
               Map.take(first, [:status, :passed, :percentage])

      Process.sleep(100)
      refute_received {:deliver_message, _}
      assert length(rows(fx.schema_name)) == 1

      ref = %{session_id: fx.session_id, user_id: fx.user.id, exam_id: fx.exam.record_id}
      pending = %{status: :grading_pending, passed: nil, percentage: 0.0}
      assert :ok = ExamNotifications.result(fx.schema_name, ref, pending)
      Process.sleep(100)
      refute_received {:deliver_message, _}
      assert length(rows(fx.schema_name)) == 1
    end
  end

  describe "I1 INV-8" do
    for behaviour <- [{:error, :boom}, :raise, :exit, {:sleep, 1000}] do
      test "adapter #{inspect(behaviour)} never reaches submit; one failed row" do
        enable!()
        fx = setup_session!("r597-i1")
        Double.set_behaviour(unquote(Macro.escape(behaviour)))

        capture_log(fn ->
          assert {:ok, outcome} = Session.submit(fx.session_id, fx.user.id, fx.schema_name)
          assert outcome.status == :submitted
          assert [row] = await_rows(fx.schema_name)
          assert row.status == "failed"
          assert row.reason == "adapter_error"
        end)
      end
    end

    test "an empty address is skipped without an adapter call" do
      enable!()
      fx = setup_session!("r597-i1e", %{email: ""})

      assert {:ok, _} = Session.submit(fx.session_id, fx.user.id, fx.schema_name)
      assert [row] = await_rows(fx.schema_name)
      assert {row.status, row.reason} == {"skipped", "no_email"}
      refute_received {:deliver_message, _}
    end

    test "result/3 never raises on a malformed reference" do
      enable!()
      assert :ok = ExamNotifications.result("nope", %{session_id: 1}, %{})
      assert :ok = ExamNotifications.result(nil, nil, nil)
    end
  end

  describe "I2 INV-4" do
    test "rows and log lines hold none of the personal or template text" do
      enable!()
      fx = setup_session!("r597-i2")

      log =
        capture_log([level: :info], fn ->
          assert {:ok, _} = Session.submit(fx.session_id, fx.user.id, fx.schema_name)
          assert_receive {:deliver_message, _}, 2000
          assert [_row] = await_rows(fx.schema_name)
        end)

      [row] = rows(fx.schema_name)
      dump = inspect(row) <> log

      for secret <- [fx.user.email, fx.user.display_name, "Safety Basics", "100.0", "Hello"] do
        refute dump =~ secret
      end
    end
  end

  describe "X1 INV-1 / INV-10 two tenants" do
    test "tenant B never writes or reads tenant A's log" do
      enable!()
      a = setup_session!("r597-xa")

      b =
        %{schema_name: b_schema} =
        ExamFixtures.provisioned_tenant_with_exam_definitions("r597-xb")

      assert {:ok, _} = Session.submit(a.session_id, a.user.id, a.schema_name)
      assert_receive {:deliver_message, _}, 2000
      assert [_row] = await_rows(a.schema_name)

      assert rows(b_schema) == []
      assert {:ok, []} = Notifications.list_deliveries(b_schema)
      assert {:ok, [_]} = Notifications.list_deliveries(a.schema_name)

      # B's prefix with A's user id: no such user in B, so a skipped row in B only.
      ref = %{session_id: Ecto.UUID.generate(), user_id: a.user.id, exam_id: Ecto.UUID.generate()}
      outcome = %{status: :submitted, passed: true, percentage: 80.0}
      assert :ok = ExamNotifications.result(b.schema_name, ref, outcome)
      assert [row] = await_rows(b_schema)
      assert {row.status, row.reason} == {"skipped", "no_email"}
      assert length(rows(a.schema_name)) == 1
      refute_received {:deliver_message, _}
    end
  end

  # Part B (T-0759): a tenant with an exam and a candidate, no session.
  defp setup_assignee!(slug, user_attrs \\ %{}) do
    %{schema_name: schema} = fx = ExamFixtures.provisioned_tenant_with_exam_definitions(slug)

    exam =
      ExamFixtures.create_record!(schema, "exam", %{
        "title" => %{"en" => "Safety Basics"},
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

    user = RSG.user!(schema)

    if user_attrs != %{} do
      user |> Ecto.Changeset.change(user_attrs) |> Repo.update!(prefix: schema)
    end

    user = Repo.get!(Letflow.Identity.User, user.id, prefix: schema)
    Map.merge(fx, %{user: user, exam: exam})
  end

  defp assign_user!(fx, opts \\ []),
    do: ExamFixtures.assign!(fx.schema_name, fx.exam.record_id, "user", fx.user.id, opts)

  defp iso(dt), do: DateTime.to_iso8601(dt)
  defp now!, do: DateTime.utc_now() |> DateTime.truncate(:second)

  describe "A1..A3 assigned/2" do
    test "A1 an active user assignment sends one mail with the deadline and logs ids only" do
      enable!()
      fx = setup_assignee!("r597-a1")
      assignment = assign_user!(fx, deadline: "2026-11-01T10:00:00Z")

      assert :ok = ExamNotifications.assigned(fx.schema_name, assignment)
      assert_receive {:deliver_message, msg}, 2000
      assert msg.to == fx.user.email
      assert msg.subject =~ "Safety Basics"
      assert msg.body =~ "2026-11-01T10:00:00Z"

      assert [row] = await_rows(fx.schema_name)
      assert row.template_key == "exam_assigned"
      assert row.trigger_ref == assignment.record_id
      assert row.recipient_user_id == fx.user.id
      assert row.status == "sent"
    end

    test "A2 no deadline gives an empty deadline text; an offset is normalised to UTC" do
      enable!()
      fx = setup_assignee!("r597-a2")
      assert :ok = ExamNotifications.assigned(fx.schema_name, assign_user!(fx))
      assert_receive {:deliver_message, msg}, 2000
      assert msg.body =~ "Deadline: ."
      await_rows(fx.schema_name)

      assert :ok =
               ExamNotifications.assigned(
                 fx.schema_name,
                 assign_user!(fx, deadline: "2026-11-01T12:00:00+02:00")
               )

      assert_receive {:deliver_message, msg2}, 2000
      assert msg2.body =~ "2026-11-01T10:00:00Z"
    end

    test "A3 all, group, org_unit and inactive assignments send nothing" do
      enable!()
      fx = setup_assignee!("r597-a3")
      schema = fx.schema_name
      exam_id = fx.exam.record_id

      for assignment <- [
            ExamFixtures.assign!(schema, exam_id, "all"),
            ExamFixtures.assign!(schema, exam_id, "group", Ecto.UUID.generate()),
            ExamFixtures.assign!(schema, exam_id, "org_unit", Ecto.UUID.generate()),
            assign_user!(fx, active: false)
          ] do
        assert :ok = ExamNotifications.assigned(schema, assignment)
      end

      Process.sleep(100)
      refute_received {:deliver_message, _}
      assert rows(schema) == []
    end
  end

  describe "A4 flag off" do
    for value <- [:unset, false, "true"] do
      test "assigned/2 and send_reminders/2 do nothing with the flag #{inspect(value)}" do
        fx = setup_assignee!("r597-a4")
        now = now!()
        assignment = assign_user!(fx, deadline: iso(DateTime.add(now, 23 * 3600)))

        case unquote(value) do
          :unset -> Application.delete_env(:letflow, :exam_notifications_enabled)
          other -> Application.put_env(:letflow, :exam_notifications_enabled, other)
        end

        assert :ok = ExamNotifications.assigned(fx.schema_name, assignment)
        assert :ok = ExamNotifications.send_reminders(fx.schema_name, now)
        Process.sleep(100)
        refute_received {:deliver_message, _}
        assert rows(fx.schema_name) == []
      end
    end
  end

  describe "A5 INV-8 assigned/2" do
    for behaviour <- [{:error, :boom}, :raise, {:sleep, 1000}] do
      test "adapter #{inspect(behaviour)} yields :ok and one failed row" do
        enable!()
        fx = setup_assignee!("r597-a5")
        assignment = assign_user!(fx)
        Double.set_behaviour(unquote(Macro.escape(behaviour)))

        capture_log(fn ->
          assert :ok = ExamNotifications.assigned(fx.schema_name, assignment)
          assert [row] = await_rows(fx.schema_name)
          assert row.status == "failed"
          assert row.reason == "adapter_error"
        end)
      end
    end

    test "an empty address is skipped without an adapter call" do
      enable!()
      fx = setup_assignee!("r597-a5e", %{email: ""})
      assert :ok = ExamNotifications.assigned(fx.schema_name, assign_user!(fx))
      assert [row] = await_rows(fx.schema_name)
      assert {row.status, row.reason} == {"skipped", "no_email"}
      refute_received {:deliver_message, _}
    end

    test "malformed arguments return :ok" do
      enable!()
      assert :ok = ExamNotifications.assigned("nope", nil)
      assert :ok = ExamNotifications.assigned(nil, %{record_id: 1, field_values: %{"x" => 1}})

      assert :ok =
               ExamNotifications.assigned("nope", %{
                 record_id: Ecto.UUID.generate(),
                 field_values: %{"assignee_type" => "user", "active" => true, "assignee_id" => 5}
               })

      assert :ok = ExamNotifications.send_reminders("nope", now!())
      assert :ok = ExamNotifications.send_reminders(nil, nil)
    end
  end

  describe "A6 INV-4 both triggers" do
    test "rows and log lines hold none of the personal or template text" do
      enable!()
      fx = setup_assignee!("r597-a6")
      now = now!()
      deadline = iso(DateTime.add(now, 23 * 3600))
      assignment = assign_user!(fx, deadline: deadline)

      log =
        capture_log([level: :info], fn ->
          assert :ok = ExamNotifications.assigned(fx.schema_name, assignment)
          assert_receive {:deliver_message, _}, 2000
          assert [_] = await_rows(fx.schema_name)
          assert :ok = ExamNotifications.send_reminders(fx.schema_name, now)
          assert_receive {:deliver_message, _}, 2000
          assert [_, _] = await_rows(fx.schema_name, 2)
        end)

      dump = inspect(rows(fx.schema_name)) <> log

      for secret <- [fx.user.email, fx.user.display_name, "Safety Basics", deadline, "Hello"] do
        refute dump =~ secret
      end
    end
  end

  describe "A7 INV-1 / INV-10 two tenants" do
    test "tenant B never sees or logs tenant A's assignment" do
      enable!()
      a = setup_assignee!("r597-a7a")
      b_schema = ExamFixtures.provisioned_tenant_with_exam_definitions("r597-a7b").schema_name
      now = now!()
      assignment = assign_user!(a, deadline: iso(DateTime.add(now, 23 * 3600)))

      assert :ok = ExamNotifications.assigned(a.schema_name, assignment)
      assert_receive {:deliver_message, _}, 2000
      assert [_row] = await_rows(a.schema_name)

      assert rows(b_schema) == []
      assert {:ok, []} = Notifications.list_deliveries(b_schema)
      assert {:ok, [_]} = Notifications.list_deliveries(a.schema_name)

      assert :ok = ExamNotifications.send_reminders(b_schema, now)
      Process.sleep(100)
      refute_received {:deliver_message, _}
      assert rows(b_schema) == []

      # A's record through B's prefix: the user does not exist there, a skipped row in B only.
      assert :ok = ExamNotifications.assigned(b_schema, assignment)
      assert [row] = await_rows(b_schema)
      assert {row.status, row.reason} == {"skipped", "no_email"}
      assert length(rows(a.schema_name)) == 1
      refute_received {:deliver_message, _}
    end
  end

  describe "R1..R4 send_reminders/2" do
    test "R1 only a deadline within the next 24 hours sends" do
      enable!()
      fx = setup_assignee!("r597-r1")
      schema = fx.schema_name
      exam_id = fx.exam.record_id
      now = now!()
      hours = fn h -> iso(DateTime.add(now, round(h * 3600))) end

      for deadline <- [hours.(25), hours.(-1), iso(now), nil] do
        assign_user!(fx, deadline: deadline)
      end

      assign_user!(fx, deadline: hours.(23), active: false)

      for type <- ["all", "group", "org_unit"] do
        ExamFixtures.assign!(schema, exam_id, type, Ecto.UUID.generate(), deadline: hours.(23))
      end

      assert :ok = ExamNotifications.send_reminders(schema, now)
      Process.sleep(150)
      refute_received {:deliver_message, _}
      assert rows(schema) == []

      hit = assign_user!(fx, deadline: hours.(23))
      assert :ok = ExamNotifications.send_reminders(schema, now)
      assert_receive {:deliver_message, msg}, 2000
      assert msg.subject =~ "Safety Basics"
      refute_received {:deliver_message, _}
      assert [row] = await_rows(schema)
      assert row.template_key == "exam_reminder"
      assert row.trigger_ref == hit.record_id

      edge = assign_user!(fx, deadline: hours.(24))
      assert :ok = ExamNotifications.send_reminders(schema, now)
      assert_receive {:deliver_message, _}, 2000
      assert [_, second] = Enum.sort_by(await_rows(schema, 2), & &1.inserted_at)
      assert second.trigger_ref in [edge.record_id, hit.record_id]
    end

    test "R2 a finished session of the exam blocks the reminder, an open one does not" do
      enable!()
      fx = setup_session!("r597-r2")
      schema = fx.schema_name
      now = now!()
      assign_user!(fx, deadline: iso(DateTime.add(now, 23 * 3600)))

      for status <- ["submitted", "auto_submitted", "grading_pending"] do
        ExamFixtures.force_field!(schema, "session", fx.session_id, "status", {:put, status})
        assert :ok = ExamNotifications.send_reminders(schema, now)
      end

      Process.sleep(150)
      refute_received {:deliver_message, _}
      assert rows(schema) == []

      ExamFixtures.force_field!(schema, "session", fx.session_id, "status", {:put, "in_progress"})
      assert :ok = ExamNotifications.send_reminders(schema, now)
      assert_receive {:deliver_message, _}, 2000
      assert [_] = await_rows(schema)
    end

    test "R3 a second call sends nothing, also after a failed first attempt" do
      enable!()
      fx = setup_assignee!("r597-r3")
      schema = fx.schema_name
      now = now!()
      assign_user!(fx, deadline: iso(DateTime.add(now, 23 * 3600)))
      Double.set_behaviour({:error, :boom})

      capture_log(fn ->
        assert :ok = ExamNotifications.send_reminders(schema, now)
        assert [%{status: "failed"}] = await_rows(schema)
        assert_received {:deliver_message, _first_attempt}
        Double.set_behaviour(:ok)
        assert :ok = ExamNotifications.send_reminders(schema, now)
        Process.sleep(150)
      end)

      refute_received {:deliver_message, _}
      assert length(rows(schema)) == 1
    end

    test "R4 one unparseable deadline does not stop the others and nothing raises" do
      enable!()
      fx = setup_assignee!("r597-r4")
      schema = fx.schema_name
      now = now!()
      bad = assign_user!(fx, deadline: iso(DateTime.add(now, 3600)))

      ExamFixtures.force_field!(
        schema,
        "exam_assignment",
        bad.record_id,
        "deadline",
        {:put, "soon"}
      )

      naive = assign_user!(fx, deadline: iso(DateTime.add(now, 3600)))

      ExamFixtures.force_field!(
        schema,
        "exam_assignment",
        naive.record_id,
        "deadline",
        {:put, "2026-11-01T10:00:00"}
      )

      ExamFixtures.force_field!(
        schema,
        "exam_assignment",
        bad.record_id,
        "assignee_id",
        {:put, 7}
      )

      good = assign_user!(fx, deadline: iso(DateTime.add(now, 23 * 3600)))

      assert :ok = ExamNotifications.send_reminders(schema, now)
      assert_receive {:deliver_message, _}, 2000
      assert [row] = await_rows(schema)
      assert row.trigger_ref == good.record_id
      Process.sleep(100)
      refute_received {:deliver_message, _}
    end
  end
end
