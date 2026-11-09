defmodule Letflow.NotificationsTest do
  @moduledoc """
  REQ-584 part 1 (GH #3310): the `task_assigned` mail after `assign_task/3` / `reassign_task/3`
  and the `notification_deliveries` log. Test ids N1..N19 follow the T-0752 design.

  `async: false`: committed tenant writes, application env, OS env and the delivery tasks.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.LoginDiscovery.Notifier.Noop
  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.NotificationTemplates
  alias Letflow.Notifications
  alias Letflow.Notifications.Delivery
  alias Letflow.Repo
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TaskScopeFixture, as: T
  alias Letflow.Tasks
  alias Letflow.Test.SmtpHelpers, as: S

  @notifier Letflow.LoginDiscovery.Notifier

  setup do
    fx = T.provision!("r584-notif")
    S.put_app_env!(@notifier, adapter: Double, timeout_ms: 100, max_concurrent: 5)
    Double.set_owner(self())
    on_exit(&Double.reset/0)

    # T-1571: the assignment mail is the tenant's opt-in e-mail copy; the REQ-584 tests run with it on.
    :ok = set_settings!(fx, %{})
    {:ok, fx: fx, opts: [prefix: fx.schema_name]}
  end

  defp unassigned_task(fx, attrs \\ %{}),
    do: T.insert_task!(fx, nil, Map.merge(%{assignee_type: nil, assignee_ref: nil}, attrs))

  defp assigned_task(fx, user),
    do: T.insert_task!(fx, nil, %{assignee_type: "USER", assignee_ref: user.id})

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

  defp set_settings!(fx, settings, copy \\ true) do
    settings = if copy, do: Map.put(settings, "notifications.email_copy", true), else: settings

    {:ok, _} =
      Repo.query("UPDATE tenants SET settings = $1::jsonb WHERE id = $2", [
        settings,
        Ecto.UUID.dump!(fx.tenant_id)
      ])

    :ok
  end

  defp assign!(fx, task, user),
    do: Tasks.assign_task(task.id, %{user_id: user.id}, prefix: fx.schema_name)

  describe "send path (criteria 2, 4)" do
    test "N1 stored locale template is rendered with values", %{fx: fx} do
      :ok = set_settings!(fx, %{"default_locale" => "fr"})
      user = RSG.user!(fx.schema_name)

      {:ok, _, _} =
        NotificationTemplates.put(
          fx.schema_name,
          fx.tenant_id,
          nil,
          "task_assigned",
          "fr",
          "Tache {task_name}",
          "Bonjour {assignee_name}"
        )

      task = unassigned_task(fx)
      assert {:ok, %EngineTask{}} = assign!(fx, task, user)

      assert_receive {:deliver_message, msg}, 2000
      assert msg.to == user.email
      assert msg.subject == "Tache Review"
      assert msg.body == "Bonjour #{user.display_name}"
      assert [%{locale: "fr", status: "sent"}] = await_rows(fx.schema_name)
    end

    test "N2 fr without a stored row uses the platform default text", %{fx: fx} do
      :ok = set_settings!(fx, %{"default_locale" => "fr"})
      user = RSG.user!(fx.schema_name)
      assert {:ok, _} = assign!(fx, unassigned_task(fx), user)
      assert_receive {:deliver_message, msg}, 2000
      assert msg.subject == "Task assigned: Review"
      assert [%{locale: "fr"}] = await_rows(fx.schema_name)
    end

    test "N3 unset default_locale falls back to en", %{fx: fx} do
      user = RSG.user!(fx.schema_name)
      assert {:ok, _} = assign!(fx, unassigned_task(fx), user)
      assert_receive {:deliver_message, _msg}, 2000
      assert [%{locale: "en", status: "sent", reason: nil}] = await_rows(fx.schema_name)
    end

    test "N4 values reach the message", %{fx: fx} do
      user = RSG.user!(fx.schema_name)
      task = T.start_task!(fx, nil)

      {:ok, _} =
        Repo.query(
          ~s|UPDATE "#{fx.schema_name}".tasks SET assignee_type = NULL, assignee_ref = NULL WHERE id = $1|,
          [Ecto.UUID.dump!(task.id)]
        )

      snapshot = Repo.get!(InstanceDefinitionSnapshot, task.instance_id, prefix: fx.schema_name)
      assert {:ok, _} = assign!(fx, task, user)
      assert_receive {:deliver_message, msg}, 2000
      assert msg.body =~ task.node_name
      assert msg.body =~ snapshot.definition_name
      assert msg.body =~ user.display_name
      assert msg.body =~ "Due: ."
      tenant = Repo.get!(Letflow.Identity.Tenant, fx.tenant_id)
      assert tenant.display_name not in [nil, ""]
      assert msg.body =~ tenant.display_name
    end

    test "N5 empty names still send one row, username replaces the name", %{fx: fx} do
      user = RSG.user!(fx.schema_name)

      {:ok, _} =
        Repo.query(~s|UPDATE "#{fx.schema_name}".users SET display_name = '' WHERE id = $1|, [
          Ecto.UUID.dump!(user.id)
        ])

      task = unassigned_task(fx)

      {:ok, _} =
        Repo.query(~s|UPDATE "#{fx.schema_name}".tasks SET node_name = '' WHERE id = $1|, [
          Ecto.UUID.dump!(task.id)
        ])

      assert {:ok, _} = assign!(fx, task, user)
      assert_receive {:deliver_message, msg}, 2000
      assert msg.body =~ "Hello #{user.username},"
      assert msg.body =~ "the task  of the process  is assigned"
      assert String.trim(msg.subject) == "Task assigned:"
      assert msg.body =~ "Due: ."
      assert [%{status: "sent"}] = await_rows(fx.schema_name)
    end

    test "N11/N14 a sent row carries key, locale, recipient and trigger", %{fx: fx} do
      user = RSG.user!(fx.schema_name)
      task = unassigned_task(fx)
      assert {:ok, _} = assign!(fx, task, user)

      assert [row] = await_rows(fx.schema_name)
      assert row.status == "sent" and row.reason == nil
      assert row.template_key == "task_assigned" and row.locale == "en"
      assert row.recipient_user_id == user.id and row.trigger_ref == task.id
      assert row.tenant_id == fx.tenant_id
    end

    test "N12 an empty email is skipped/no_email without an adapter call", %{fx: fx} do
      user = RSG.user!(fx.schema_name)

      {:ok, _} =
        Repo.query(~s|UPDATE "#{fx.schema_name}".users SET email = '' WHERE id = $1|, [
          Ecto.UUID.dump!(user.id)
        ])

      assert {:ok, _} = assign!(fx, unassigned_task(fx), user)
      assert [%{status: "skipped", reason: "no_email"}] = await_rows(fx.schema_name)
      refute_received {:deliver_message, _}
    end

    test "N13 the Noop adapter is skipped/adapter_noop", %{fx: fx} do
      S.put_app_env!(@notifier, adapter: Noop)
      user = RSG.user!(fx.schema_name)
      assert {:ok, _} = assign!(fx, unassigned_task(fx), user)
      assert [%{status: "skipped", reason: "adapter_noop"}] = await_rows(fx.schema_name)
      refute_received {:deliver_message, _}
    end

    test "N17 an assignee with no user row is skipped/no_email", %{fx: fx} do
      task = unassigned_task(fx)
      ghost = %{id: Ecto.UUID.generate()}
      assert {:ok, _} = assign!(fx, task, ghost)

      assert [%{status: "skipped", reason: "no_email", recipient_user_id: id}] =
               await_rows(fx.schema_name)

      assert id == ghost.id
    end
  end

  describe "assignment is unaffected (criterion 3)" do
    for {name, behaviour} <- [
          {"N6 error", :error},
          {"N7 raise", :raise},
          {"N8 exit", :exit},
          {"N9 timeout", {:sleep, 10_000}}
        ] do
      test "#{name}: assign and reassign results stay, one failed row each", %{fx: fx} do
        Double.set_behaviour(unquote(Macro.escape(behaviour)))
        user = RSG.user!(fx.schema_name)
        other = RSG.user!(fx.schema_name)

        capture_log(fn ->
          task = unassigned_task(fx)
          {micros, result} = :timer.tc(fn -> assign!(fx, task, user) end)
          assert {:ok, %EngineTask{assignee_ref: ref}} = result
          assert ref == user.id
          # the request path never waits for the adapter (double sleeps 10 s, timeout 100 ms)
          assert micros < 5_000_000
          assert [%{status: "failed", reason: "adapter_error"}] = await_rows(fx.schema_name)

          assert {:ok, %EngineTask{assignee_ref: ref2}} =
                   Tasks.reassign_task(task.id, %{user_id: other.id}, prefix: fx.schema_name)

          assert ref2 == other.id
          assert [_, _] = await_rows(fx.schema_name, 2)

          assert Enum.all?(
                   rows(fx.schema_name),
                   &(&1.status == "failed" and &1.reason == "adapter_error")
                 )
        end)
      end
    end

    test "N10 a bad prefix does not raise or write", %{fx: fx} do
      task = assigned_task(fx, RSG.user!(fx.schema_name))
      assert :ok = Notifications.after_assignment(task, task.assignee_ref, "not_a_tenant")
      assert :ok = Notifications.after_assignment(:not_a_task, "x", "y")
      assert rows(fx.schema_name) == []
    end
  end

  describe "closed sets (criterion 5)" do
    for reason <- [:not_configured, :invalid_recipient, :invalid_message, :failed] do
      test "N15 Smtp reason #{reason} is failed/adapter_error", %{fx: fx} do
        Double.set_behaviour({:error, unquote(reason)})
        user = RSG.user!(fx.schema_name)
        assert {:ok, _} = assign!(fx, unassigned_task(fx), user)
        assert [%{status: "failed", reason: "adapter_error"}] = await_rows(fx.schema_name)
      end
    end

    test "N16 an invalid default_locale writes failed/adapter_error, no adapter call", %{fx: fx} do
      :ok = set_settings!(fx, %{"default_locale" => "not a locale!"})
      user = RSG.user!(fx.schema_name)
      assert {:ok, _} = assign!(fx, unassigned_task(fx), user)

      assert [%{status: "failed", reason: "adapter_error", locale: "not a locale!"}] =
               await_rows(fx.schema_name)

      refute_received {:deliver_message, _}
    end

    test "N16b a non-string default_locale still writes one row", %{fx: fx} do
      :ok = set_settings!(fx, %{"default_locale" => 5})
      user = RSG.user!(fx.schema_name)
      assert {:ok, _} = assign!(fx, unassigned_task(fx), user)

      assert [%{status: "failed", reason: "adapter_error", locale: "en"}] =
               await_rows(fx.schema_name)

      refute_received {:deliver_message, _}
    end
  end

  describe "no secrets or content in the log (criterion 6, first half)" do
    test "N18 a failed delivery leaks neither address, template text nor credentials", %{fx: fx} do
      S.put_os_env!(S.user_var(), S.user())
      S.put_os_env!(S.pass_var(), S.pass())
      Double.set_behaviour(:raise)
      user = RSG.user!(fx.schema_name)

      {:ok, _, _} =
        NotificationTemplates.put(
          fx.schema_name,
          fx.tenant_id,
          nil,
          "task_assigned",
          "en",
          "SecretSubjectWording {task_name}",
          "SecretBodyWording {assignee_name}"
        )

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, _} = assign!(fx, unassigned_task(fx), user)
          assert [row] = await_rows(fx.schema_name)
          send(self(), {:row, inspect(row)})
          Process.sleep(100)
        end)

      assert_received {:row, row_text}

      for text <- [log, row_text],
          secret <- [user.email, "SecretSubjectWording", "SecretBodyWording", S.pass(), S.user()] do
        refute text =~ secret
      end
    end
  end

  describe "per-tenant scoping (criterion 7, first clause)" do
    test "N19 a row lands in tenant A only", %{fx: fx} do
      other = T.provision!("r584-other")
      user = RSG.user!(fx.schema_name)
      assert {:ok, _} = assign!(fx, unassigned_task(fx), user)
      assert [_] = await_rows(fx.schema_name)
      assert rows(other.schema_name) == []
    end
  end

  describe "e-mail copy of the bell (T-1571)" do
    defp user_settings!(fx, user, prefs) do
      {:ok, _} = Letflow.UserPreferences.put(fx.schema_name, user.id, prefs)
      :ok
    end

    defp insert_delivery!(prefix, user_id, age_seconds) do
      at = DateTime.add(DateTime.utc_now(), -age_seconds, :second)

      Repo.insert!(
        %Delivery{
          tenant_id: Ecto.UUID.generate(),
          template_key: "task_assigned",
          locale: "en",
          recipient_user_id: user_id,
          status: "sent",
          trigger_ref: Ecto.UUID.generate(),
          inserted_at: at
        },
        prefix: prefix
      )
    end

    defp assign_new!(fx, user), do: {:ok, _} = assign!(fx, unassigned_task(fx), user)

    test "E1 default OFF: no mail, no row; bell row still written (E17)", %{fx: fx} do
      :ok = set_settings!(fx, %{}, false)
      user = RSG.user!(fx.schema_name)
      assign_new!(fx, user)
      refute_receive {:deliver_message, _}, 300
      assert rows(fx.schema_name) == []
      assert %{items: [_]} = Letflow.UserNotifications.list(fx.schema_name, user.id)
    end

    test "E2 switch on: one mail, one sent row", %{fx: fx} do
      user = RSG.user!(fx.schema_name)
      assign_new!(fx, user)
      assert_receive {:deliver_message, %{to: to}}, 2000
      assert to == user.email
      assert [%{status: "sent"}] = await_rows(fx.schema_name)
    end

    test "E5/E6 user opt-out and reset; E17 bell stays", %{fx: fx} do
      user = RSG.user!(fx.schema_name)
      :ok = user_settings!(fx, user, %{"notifications.email" => "off"})
      assign_new!(fx, user)
      refute_receive {:deliver_message, _}, 300
      assert rows(fx.schema_name) == []
      assert %{items: [_]} = Letflow.UserNotifications.list(fx.schema_name, user.id)

      :ok = user_settings!(fx, user, %{"notifications.email" => nil})
      assign_new!(fx, user)
      assert_receive {:deliver_message, _}, 2000
    end

    test "E9 no address or subject in the log", %{fx: fx} do
      user = RSG.user!(fx.schema_name)
      :ok = user_settings!(fx, user, %{"notifications.email" => "off"})
      Double.set_behaviour(:raise)
      other = RSG.user!(fx.schema_name)

      log =
        capture_log(fn ->
          assign_new!(fx, user)
          assign_new!(fx, other)
          await_rows(fx.schema_name)
          Process.sleep(100)
        end)

      refute log =~ user.email
      refute log =~ other.email
      refute log =~ "Task assigned"
    end

    test "E10/E11 rate limit per user, old rows do not count", %{fx: fx} do
      user = RSG.user!(fx.schema_name)
      v = RSG.user!(fx.schema_name)
      for _ <- 1..20, do: insert_delivery!(fx.schema_name, user.id, 60)
      assign_new!(fx, user)
      refute_receive {:deliver_message, _}, 300
      assert length(rows(fx.schema_name)) == 20

      assign_new!(fx, v)
      assert_receive {:deliver_message, %{to: to}}, 2000
      assert to == v.email

      w = RSG.user!(fx.schema_name)
      for _ <- 1..20, do: insert_delivery!(fx.schema_name, w.id, 7200)
      assign_new!(fx, w)
      assert_receive {:deliver_message, %{to: to2}}, 2000
      assert to2 == w.email
    end

    test "E12 retried: fails twice then sent, one row", %{fx: fx} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      :persistent_term.put({__MODULE__, :counter}, counter)
      S.put_app_env!(@notifier, adapter: __MODULE__.Flaky, timeout_ms: 500, max_concurrent: 5)
      on_exit(fn -> :persistent_term.erase({__MODULE__, :counter}) end)
      Agent.update(counter, fn _ -> 2 end)
      user = RSG.user!(fx.schema_name)
      assign_new!(fx, user)
      assert [%{status: "sent", reason: nil}] = await_rows(fx.schema_name)
      assert Agent.get(counter, & &1) == -1
    end

    test "E13 fails three times: one failed row", %{fx: fx} do
      Double.set_behaviour(:error)
      user = RSG.user!(fx.schema_name)
      assign_new!(fx, user)
      assert [%{status: "failed", reason: "adapter_error"}] = await_rows(fx.schema_name)
      assert_receive {:deliver_message, _}, 500
      assert_receive {:deliver_message, _}, 500
      assert_receive {:deliver_message, _}, 500
      refute_receive {:deliver_message, _}, 100
    end

    test "E14 deliver/6 (exam/assets path) does not retry", %{fx: fx} do
      Double.set_behaviour(:error)
      user = RSG.user!(fx.schema_name)

      assert :ok =
               Notifications.deliver(
                 "task_assigned",
                 user.id,
                 Ecto.UUID.generate(),
                 fn _u, _p, _t -> %{} end,
                 fx.schema_name,
                 fx.tenant_id
               )

      assert_receive {:deliver_message, _}, 500
      refute_receive {:deliver_message, _}, 100
    end

    test "E15/E16 tenant isolation of switch and rate rows", %{fx: fx} do
      other = T.provision!("r584-iso")
      :ok = set_settings!(other, %{}, false)
      ouser = RSG.user!(other.schema_name)
      assign_new!(other, ouser)
      refute_receive {:deliver_message, _}, 300
      assert rows(other.schema_name) == []

      user = RSG.user!(fx.schema_name)
      for _ <- 1..20, do: insert_delivery!(other.schema_name, user.id, 60)
      assign_new!(fx, user)
      assert_receive {:deliver_message, %{to: to}}, 2000
      assert to == user.email
    end
  end
end

defmodule Letflow.NotificationsTest.Flaky do
  @moduledoc false
  @behaviour Letflow.LoginDiscovery.Notifier

  @impl true
  def deliver_tenant_list(_to, _tenants), do: :ok

  @impl true
  def deliver_message(_message) do
    counter = :persistent_term.get({Letflow.NotificationsTest, :counter})

    # counter > 0: fail and count down; at 0 succeed once and mark -1.
    Agent.get_and_update(counter, fn
      n when n > 0 -> {{:error, :boom}, n - 1}
      _n -> {:ok, -1}
    end)
  end
end
