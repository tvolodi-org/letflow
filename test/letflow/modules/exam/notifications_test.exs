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
end
