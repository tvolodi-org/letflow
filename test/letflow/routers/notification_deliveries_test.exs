defmodule Letflow.Routers.NotificationDeliveriesTest do
  @moduledoc """
  REQ-584 part 2 / GH #3310 -- `GET /notification-deliveries` through the router's own `call/2`
  (real Authorize plug) over provisioned tenant schemas, plus one real-token request through
  `Letflow.Router`. IDs follow the T-0753 design: R read, F uniform 403, X cross-tenant,
  N no secrets.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.NotificationTemplates
  alias Letflow.Notifications.Delivery
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TaskScopeFixture, as: T
  alias Letflow.Tasks
  alias Letflow.Test.SmtpHelpers, as: S

  @opts Letflow.Routers.NotificationDeliveries.init([])
  @notifier Letflow.LoginDiscovery.Notifier
  @keys ~w(id inserted_at locale reason recipient_user_id status template_key trigger_ref)

  setup do
    tenants = Fixture.three_tenants!()
    {:ok, a: tenants.a, b: tenants.b, p: tenants.p}
  end

  defp insert!(t, status, at, opts \\ []) do
    reason =
      case status do
        "sent" -> nil
        "failed" -> "adapter_error"
        "skipped" -> "no_email"
      end

    row =
      %Delivery{
        tenant_id: t.tenant_id,
        template_key: "task_assigned",
        locale: "en",
        recipient_user_id: Ecto.UUID.generate(),
        status: status,
        reason: reason,
        trigger_ref: Ecto.UUID.generate(),
        inserted_at: at
      }

    row = if id = opts[:id], do: %{row | id: id}, else: row
    Repo.insert!(row, prefix: t.schema_name)
  end

  defp at(n), do: DateTime.add(~U[2026-01-01 00:00:00.000000Z], n, :second)

  defp get(t, query \\ "", roles \\ ["TENANT_ADMIN"]) do
    Fixture.router_conn(:get, "/" <> query, t, roles, nil)
    |> Letflow.Routers.NotificationDeliveries.call(@opts)
  end

  defp ok_rows(conn) do
    assert conn.status == 200
    Jason.decode!(conn.resp_body)["deliveries"]
  end

  describe "read (criterion 8)" do
    test "R1 newest first with an id tie-break", %{a: a} do
      old = insert!(a, "sent", at(1))
      mid_x = insert!(a, "sent", at(2))
      mid_y = insert!(a, "failed", at(2))
      new = insert!(a, "skipped", at(3))

      ids = a |> get() |> ok_rows() |> Enum.map(& &1["id"])
      tie = [mid_x.id, mid_y.id] |> Enum.sort() |> Enum.reverse()
      assert ids == [new.id] ++ tie ++ [old.id]
    end

    test "R2 at most 100 rows, the newest", %{a: a} do
      now = at(0)

      entries =
        for n <- 1..105 do
          %{
            id: Ecto.UUID.generate(),
            tenant_id: a.tenant_id,
            template_key: "task_assigned",
            locale: "en",
            recipient_user_id: nil,
            status: "sent",
            reason: nil,
            trigger_ref: Ecto.UUID.generate(),
            inserted_at: DateTime.add(now, n, :second)
          }
        end

      {105, _} = Repo.insert_all(Delivery, entries, prefix: a.schema_name)

      rows = a |> get() |> ok_rows()
      assert length(rows) == 100
      newest = DateTime.add(now, 105, :second) |> DateTime.to_iso8601()
      assert hd(rows)["inserted_at"] == newest
    end

    test "R3 the status filter", %{a: a} do
      insert!(a, "sent", at(1))
      insert!(a, "failed", at(2))
      insert!(a, "skipped", at(3))

      assert a |> get() |> ok_rows() |> length() == 3
      assert a |> get("?status=failed") |> ok_rows() |> Enum.map(& &1["status"]) == ["failed"]
      assert a |> get("?status=sent") |> ok_rows() |> Enum.map(& &1["status"]) == ["sent"]
    end

    test "R4 an unknown status is 422 with a fixed text", %{a: a} do
      insert!(a, "failed", at(1))

      for q <- ["?status=bogus", "?status=", "?status[]=failed", "?status=FAILED"] do
        conn = get(a, q)
        assert conn.status == 422, q
        refute conn.resp_body =~ "bogus"
        refute conn.resp_body =~ "FAILED"
      end
    end

    test "R5 a row has exactly the eight keys", %{a: a} do
      insert!(a, "sent", at(1))
      assert [row] = a |> get() |> ok_rows()
      assert row |> Map.keys() |> Enum.sort() == @keys
    end
  end

  describe "uniform 403 (INV-5) and tokens" do
    test "F1 identical refusal with and without rows", %{a: a, b: b} do
      insert!(a, "sent", at(1))

      for roles <- [["TASK_WORKER"], ["PROCESS_DESIGNER"], ["TENANT_AUDITOR"]] do
        with_rows = get(a, "", roles)
        without = get(b, "", roles)
        assert with_rows.status == 403, inspect(roles)
        assert without.status == 403
        assert with_rows.resp_body == without.resp_body

        assert get_resp_header(with_rows, "content-type") ==
                 get_resp_header(without, "content-type")
      end
    end

    test "F2 no token is 401", %{a: a} do
      conn =
        Plug.Test.conn(:get, "/api/v1/notification-deliveries")
        |> Plug.Conn.put_req_header("x-tenant-slug", a.tenant.slug)
        |> Fixture.dispatch_api()

      assert conn.status == 401
    end

    test "F3 a real TENANT_ADMIN token reads the tenant's rows", %{a: a, p: p} do
      Fixture.pin!(p.tenant_id)
      row = insert!(a, "failed", at(1))
      token = Fixture.mint_token!(a, ["TENANT_ADMIN"])

      conn =
        Fixture.api_conn(:get, "/api/v1/notification-deliveries", token, a.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert [%{"id" => id}] = ok_rows(conn)
      assert id == row.id
    end
  end

  describe "tenant scoping (criterion 7)" do
    test "X1 tenant B cannot read, filter to or count A's rows", %{a: a, b: b} do
      a_rows = for n <- 1..3, do: insert!(a, "failed", at(n))

      assert b |> get() |> ok_rows() == []
      assert b |> get("?status=failed") |> ok_rows() == []
      assert a |> get() |> ok_rows() |> length() == length(a_rows)
      refute get(b).resp_body =~ hd(a_rows).id
    end

    test "X2 no tenant parameter is read", %{a: a, b: b} do
      insert!(a, "failed", at(1))

      assert b |> get("?tenant_id=#{a.tenant_id}") |> ok_rows() == []
      assert b |> get("?tenant_id=#{a.tenant_id}&status=failed") |> ok_rows() == []

      source = File.read!("lib/letflow/routers/notification_deliveries.ex")
      refute source =~ ~s|"tenant_id"|
      refute source =~ "conn.params"
      assert source =~ ~s|query_params["status"]|
    end

    test "X3 a PLATFORM_ADMIN of the platform tenant gets only its own rows", %{a: a, p: p} do
      Fixture.pin!(p.tenant_id)
      a_row = insert!(a, "sent", at(1))
      p_row = insert!(p, "sent", at(2))

      assert [%{"id" => id}] = p |> get("", ["PLATFORM_ADMIN"]) |> ok_rows()
      assert id == p_row.id
      refute id == a_row.id
    end
  end

  describe "no secrets (criterion 6, second half)" do
    test "N1 the GET carries neither address, template text nor credentials" do
      fx = T.provision!("r584-get")
      S.put_app_env!(@notifier, adapter: Double, timeout_ms: 100, max_concurrent: 5)
      Double.set_owner(self())
      on_exit(&Double.reset/0)
      S.put_os_env!(S.user_var(), S.user())
      S.put_os_env!(S.pass_var(), S.pass())
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

      for behaviour <- [:raise, :ok] do
        Double.set_behaviour(behaviour)
        task = T.insert_task!(fx, nil, %{assignee_type: nil, assignee_ref: nil})
        assert {:ok, _} = Tasks.assign_task(task.id, %{user_id: user.id}, prefix: fx.schema_name)
      end

      rows = await(fx, 2)
      assert length(rows) == 2

      body = fx |> get() |> Map.fetch!(:resp_body)

      for secret <- [user.email, "SecretSubjectWording", "SecretBodyWording", S.pass(), S.user()] do
        refute body =~ secret
      end
    end
  end

  defp await(fx, count) do
    Enum.reduce_while(1..100, [], fn _i, _acc ->
      found = Repo.all(Delivery, prefix: fx.schema_name)

      if length(found) >= count do
        {:halt, found}
      else
        Process.sleep(20)
        {:cont, found}
      end
    end)
  end
end
