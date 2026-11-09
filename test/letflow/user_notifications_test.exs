defmodule Letflow.UserNotificationsTest do
  @moduledoc """
  T-1561: the `Letflow.UserNotifications` context: the closed kind list, best effort, the
  per-user cap, and the bell row being independent of the mail path. `async: false`
  (tenant provisioning, committed writes).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Repo
  alias Letflow.Support.TaskScopeFixture, as: T
  alias Letflow.TenantFixture
  alias Letflow.Tasks
  alias Letflow.UserNotifications

  setup do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "t1561-un")
    {:ok, fx: fx, prefix: fx.schema_name, tid: fx.tenant_id}
  end

  defp count(prefix) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{prefix}".user_notifications|)
    n
  end

  test "N2 stores task_assigned; unknown kind and bad uuid write nothing", %{prefix: p, tid: tid} do
    u = Ecto.UUID.generate()
    assert UserNotifications.kinds() == ["task_assigned"]
    assert :ok = UserNotifications.notify(p, tid, u, "task_assigned", Ecto.UUID.generate(), "T")

    capture_log(fn ->
      assert :ok = UserNotifications.notify(p, tid, u, "document_returned", nil, "T")
      assert :ok = UserNotifications.notify(p, tid, "not-a-uuid", "task_assigned", nil, "T")
      assert :ok = UserNotifications.notify(p, tid, u, "task_assigned", "bad", "T")
    end)

    assert count(p) == 1

    assert %{items: [%{"kind" => "task_assigned"}], unread_count: 1} =
             UserNotifications.list(p, u)
  end

  test "title is truncated to 200 and nil becomes empty", %{prefix: p, tid: tid} do
    u = Ecto.UUID.generate()
    UserNotifications.notify(p, tid, u, "task_assigned", nil, String.duplicate("x", 300))
    UserNotifications.notify(p, tid, u, "task_assigned", nil, nil)
    titles = UserNotifications.list(p, u).items |> Enum.map(& &1["title"]) |> Enum.sort()
    assert titles == ["", String.duplicate("x", 200)]
  end

  test "N2b assign_task writes the bell row with the mail adapter Noop; a failing insert keeps the result",
       %{fx: fx, prefix: p} do
    user = Letflow.Support.RoleScopeGrantsFixture.user!(p)

    mk = fn ->
      T.insert_task!(%{schema_name: p}, nil, %{assignee_type: nil, assignee_ref: nil})
    end

    assert {:ok, _} = Tasks.assign_task(mk.().id, %{user_id: user.id}, prefix: p)
    assert %{items: [%{"kind" => "task_assigned"}]} = UserNotifications.list(p, user.id)

    Repo.query!(~s|DROP TABLE "#{p}".user_notifications|)

    capture_log(fn ->
      assert {:ok, _} = Tasks.assign_task(mk.().id, %{user_id: user.id}, prefix: p)
      assert :ok = UserNotifications.notify(p, fx.tenant_id, user.id, "task_assigned", nil, "x")
    end)
  end

  test "N8 the newest 200 rows per user are kept", %{prefix: p, tid: tid} do
    u = Ecto.UUID.generate()
    other = Ecto.UUID.generate()
    UserNotifications.notify(p, tid, other, "task_assigned", nil, "other")
    for i <- 1..205, do: UserNotifications.notify(p, tid, u, "task_assigned", nil, "n#{i}")

    assert count(p) == 201
    %{items: items} = UserNotifications.list(p, u, 100)
    assert hd(items)["title"] == "n205"

    assert %{rows: [[200]]} =
             Repo.query!(
               ~s|SELECT count(*) FROM "#{p}".user_notifications WHERE user_id = $1|,
               [Ecto.UUID.dump!(u)]
             )
  end

  test "list clamps limit; mark_read refuses invalid input", %{prefix: p, tid: tid} do
    u = Ecto.UUID.generate()
    for i <- 1..3, do: UserNotifications.notify(p, tid, u, "task_assigned", nil, "n#{i}")
    assert length(UserNotifications.list(p, u, 0).items) == 1
    assert length(UserNotifications.list(p, u, "abc").items) == 3
    assert length(UserNotifications.list(p, u, nil).items) == 3
    assert {:error, :invalid_ids} = UserNotifications.mark_read(p, u, ["x"])
    assert {:error, :invalid_ids} = UserNotifications.mark_read(p, u, [])
    assert {:error, :invalid_ids} = UserNotifications.mark_read(p, u, "x")
  end
end
