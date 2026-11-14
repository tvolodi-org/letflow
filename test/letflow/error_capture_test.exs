defmodule Letflow.ErrorCaptureTest do
  @moduledoc """
  T-1951 EC-2..EC-11, EC-14, EC-16: server error capture through the real `Letflow.Router`, the buffer's
  flush into the platform company's `error_groups`, the throttle, the alerts. `async: false`: VM-global
  config, named ETS tables and the platform pin. Every test flushes explicitly (the test config sets a
  1 h timer interval), no sleeps.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Plug.Test

  alias Letflow.ErrorCapture
  alias Letflow.ErrorCapture.Buffer
  alias Letflow.ErrorCapture.Group
  alias Letflow.Obs.Alerts
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.WebhookTestServer

  setup do
    %{p: p, a: a} = Fixture.three_tenants!()
    Fixture.pin!(p.tenant_id)

    previous = Application.get_env(:letflow, :error_capture, [])
    previous_hooks = Application.get_env(:letflow, :alert_hooks)
    set_config(enabled: true)
    clear_ets()

    on_exit(fn ->
      Application.put_env(:letflow, :error_capture, previous)

      case previous_hooks do
        nil -> Application.delete_env(:letflow, :alert_hooks)
        v -> Application.put_env(:letflow, :alert_hooks, v)
      end

      clear_ets()

      try do
        Repo.delete_all(Group, prefix: p.schema_name)
      rescue
        _ -> :ok
      end
    end)

    {:ok, p: p, a: a}
  end

  defp set_config(overrides) do
    Application.put_env(
      :letflow,
      :error_capture,
      Keyword.merge(Application.get_env(:letflow, :error_capture, []), overrides)
    )
  end

  defp clear_ets do
    for t <- [ErrorCapture.main_table(), ErrorCapture.samples_table()],
        do: :ets.delete_all_objects(t)
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        source: "server",
        kind: "exception",
        method: "GET",
        route: "/api/v1/x/:id",
        error_type: "KeyError",
        top_frame: "Letflow.Foo.bar/1",
        status: 500,
        tenant_id: nil,
        trace_id: nil
      },
      overrides
    )
  end

  defp groups(p), do: Repo.all(from_group(), prefix: p.schema_name)
  defp from_group, do: from(g in Group, order_by: [asc: g.seq])

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp crash!(a, token) do
    conn =
      Fixture.api_conn(
        :get,
        "/api/v1/identity/groups/#{Ecto.UUID.generate()}/members",
        token,
        a.tenant.slug,
        nil
      )

    assert_raise Plug.Conn.WrapperError, fn -> dispatch(conn) end
  end

  describe "EC-2/3/9: a real raise under /api/v1" do
    test "becomes one group without values, in the platform schema only", %{p: p, a: a} do
      token = Fixture.mint_token!(a, ["TENANT_ADMIN"])
      Repo.query!(~s|DROP TABLE "#{a.schema_name}".groups CASCADE|)

      crash!(a, token)
      crash!(a, token)
      assert :ok = Buffer.flush()

      assert [g] = groups(p)
      assert g.kind == "exception"
      assert g.source == "server"
      assert g.error_type == "Postgrex.Error"
      assert g.route =~ "/groups/:id/members"
      refute g.route =~ "-"
      assert g.count == 2
      assert g.tenant_ids == [a.tenant_id]
      assert length(g.last_trace_ids) == 2
      assert g.message == nil
      assert g.tenant_id == p.tenant_id

      # EC-3: nothing of the request or the Postgres message is stored
      stored = inspect(Map.from_struct(g))
      refute stored =~ "relation"
      refute stored =~ a.tenant.slug
      refute stored =~ "undefined_table"

      # EC-9: the customer company's own table stays empty
      assert [] = Repo.all(Group, prefix: a.schema_name)
    end

    test "EC-9 without a platform company a flush writes nothing and empties the buffer", %{
      p: p,
      a: a
    } do
      ErrorCapture.record(entry(%{tenant_id: a.tenant_id, trace_id: "t1"}))
      Fixture.unpin!()
      assert :ok = Buffer.flush()
      assert [] = Repo.all(Group, prefix: p.schema_name)
      assert [] = Repo.all(Group, prefix: a.schema_name)
      assert :ets.info(ErrorCapture.main_table(), :size) == 0
    end
  end

  describe "EC-4/5: sent answers" do
    defp send_status(status) do
      conn(:get, "/api/v1/nothing")
      |> Plug.Conn.put_private(:plug_route, {"/api/v1/nothing", fn -> :ok end})
      |> Letflow.Plugs.ErrorCapture.call([])
      |> Plug.Conn.send_resp(status, "x")
    end

    test "EC-4 a sent 500 is one http_status group", %{p: p} do
      send_status(500)
      assert :ok = Buffer.flush()
      assert [g] = groups(p)
      assert g.kind == "http_status"
      assert g.error_type == "http_500"
      assert g.status == 500
      assert g.top_frame == ""
    end

    test "EC-5 503 and 404 answers are not recorded, 502 is", %{p: p} do
      send_status(503)
      send_status(404)
      assert :ok = Buffer.flush()
      assert [] = groups(p)
      send_status(502)
      assert :ok = Buffer.flush()
      assert [%{status: 502}] = groups(p)
    end

    test "EC-5 a raise that Plug maps to 4xx is not recorded", %{p: p, a: a} do
      token = Fixture.mint_token!(a, ["TENANT_ADMIN"])

      conn =
        conn(:post, "/api/v1/identity/groups", "{not json")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Plug.Conn.put_req_header("x-tenant-slug", a.tenant.slug)

      try do
        dispatch(conn)
      rescue
        _ -> :ok
      end

      assert :ok = Buffer.flush()
      assert [] = groups(p)
    end

    test "a crash already recorded is not counted again by the response path", %{p: p, a: a} do
      token = Fixture.mint_token!(a, ["TENANT_ADMIN"])
      Repo.query!(~s|DROP TABLE "#{a.schema_name}".groups CASCADE|)
      crash!(a, token)
      assert :ok = Buffer.flush()
      assert [%{kind: "exception"}] = groups(p)
    end
  end

  describe "EC-6/7: grouping and throttle" do
    test "EC-6 counts, last 5 trace ids newest first, merge across windows", %{p: p} do
      for i <- 1..30, do: ErrorCapture.record(entry(%{trace_id: "t" <> pad(i)}))
      for _ <- 1..3, do: ErrorCapture.record(entry(%{route: "/other"}))
      assert :ok = Buffer.flush()

      assert [_, _] = groups(p)
      by_route = Map.new(groups(p), &{&1.route, &1})
      g1 = by_route["/api/v1/x/:id"]
      assert {g1.count, by_route["/other"].count} == {30, 3}
      assert g1.last_trace_ids == ["t30", "t29", "t28", "t27", "t26"]

      # second flush without hits: nothing written
      updated = g1.updated_at
      assert :ok = Buffer.flush()
      assert %{updated_at: ^updated} = Map.new(groups(p), &{&1.route, &1})["/api/v1/x/:id"]

      ErrorCapture.record(entry(%{trace_id: "t31"}))
      ErrorCapture.record(entry(%{trace_id: "t32"}))
      assert :ok = Buffer.flush()
      g1 = Map.new(groups(p), &{&1.route, &1})["/api/v1/x/:id"]
      assert g1.count == 32
      assert g1.last_trace_ids == ["t32", "t31", "t30", "t29", "t28"]
    end

    test "EC-6b the company set is capped at 100 and the window counters reset", %{p: p} do
      for _ <- 1..105, do: ErrorCapture.record(entry(%{tenant_id: Ecto.UUID.generate()}))
      assert :ok = Buffer.flush()
      assert [g] = groups(p)
      assert length(g.tenant_ids) == 100
      assert g.count == 105

      assert [{_sig, 0, _seq, 0, _meta}] = :ets.tab2list(ErrorCapture.main_table())
    end

    test "EC-6c more signatures than max_signatures are counted as overflow", %{p: p} do
      set_config(max_signatures: 2)

      log =
        capture_log(fn ->
          for r <- ["/a", "/b", "/c"], do: ErrorCapture.record(entry(%{route: r}))
          assert :ok = Buffer.flush()
        end)

      assert length(groups(p)) == 2
      assert log =~ "error_capture_overflow count=1"
    end

    test "EC-7 one row per signature, the counter carries every occurrence", %{p: p} do
      for _ <- 1..30, do: ErrorCapture.record(entry())
      assert :ok = Buffer.flush()
      for _ <- 1..10, do: ErrorCapture.record(entry())
      assert :ok = Buffer.flush()
      assert [%{count: 40}] = groups(p)
    end

    test "a nil company and nil trace id are stored as empty arrays", %{p: p} do
      ErrorCapture.record(entry())
      assert :ok = Buffer.flush()
      assert [%{tenant_ids: [], last_trace_ids: []}] = groups(p)
      ErrorCapture.record(entry())
      assert :ok = Buffer.flush()
      assert [%{tenant_ids: [], last_trace_ids: [], count: 2}] = groups(p)
    end
  end

  describe "EC-8/8b/11: alerts" do
    test "EC-8 new alerts once, growth once per hour, both branches", %{p: p} do
      set_config(growth_alert_per_hour: 3)

      log =
        capture_log(fn ->
          for _ <- 1..2, do: ErrorCapture.record(entry())
          assert :ok = Buffer.flush()
        end)

      assert log =~ "error group alert reason=new"
      refute log =~ "reason=growth"

      again = capture_log(fn -> ErrorCapture.record(entry()) && Buffer.flush() end)
      refute again =~ "error group alert"

      growth =
        capture_log(fn ->
          for _ <- 1..3, do: ErrorCapture.record(entry())
          assert :ok = Buffer.flush()
        end)

      assert growth =~ "error group alert reason=growth"
      assert [g] = groups(p)
      assert g.growth_alerted_hour == g.hour_bucket

      more =
        capture_log(fn ->
          for _ <- 1..4, do: ErrorCapture.record(entry())
          assert :ok = Buffer.flush()
        end)

      refute more =~ "error group alert"
    end

    test "EC-8b a flush with alerts: false writes the row and stays silent; the next one alerts",
         %{
           p: p
         } do
      log =
        capture_log(fn ->
          ErrorCapture.record(entry())
          assert :ok = Buffer.flush(alerts: false)
        end)

      refute log =~ "error group alert"
      assert [%{alerted_new_at: nil}] = groups(p)

      next =
        capture_log(fn ->
          ErrorCapture.record(entry())
          assert :ok = Buffer.flush()
        end)

      assert next =~ "error group alert reason=new"
      assert [%{alerted_new_at: %DateTime{}}] = groups(p)
    end

    test "EC-10/11 the hook gets the payload; one group's new, growth and next-hour growth all deliver",
         %{p: p} do
      server = WebhookTestServer.start(200, "ok")

      Application.put_env(:letflow, :alert_hooks,
        enabled: true,
        hooks: [
          [
            hook_id: "eg-hook",
            enabled: true,
            destination_url: server.url,
            timeout_ms: 5_000,
            auth_secret_ref: nil,
            retry_policy: [
              max_attempts: 1,
              base_backoff_ms: 1,
              max_backoff_ms: 1,
              multiplier: 2.0
            ]
          ]
        ]
      )

      schema = p.schema_name
      gid = Ecto.UUID.generate()

      payload = fn reason, hour ->
        %{
          "trigger" => "error_group_alert",
          "reason" => reason,
          "group" => "EG-1",
          "group_id" => gid,
          "hour" => hour,
          "tenants_affected" => 3,
          "count" => 5
        }
      end

      Alerts.notify_error_group(schema, payload.("new", "2026-11-14T10:00:00Z"))
      body = Jason.decode!(receive_request().body)
      assert body["trigger"] == "error_group_alert"
      assert is_integer(body["tenants_affected"])
      refute Map.has_key?(body, "tenant_ids")
      refute Map.has_key?(body, "last_trace_ids")

      Alerts.notify_error_group(schema, payload.("growth", "2026-11-14T10:00:00Z"))
      assert Jason.decode!(receive_request().body)["reason"] == "growth"

      # same group, reason and hour twice delivers once
      Alerts.notify_error_group(schema, payload.("growth", "2026-11-14T10:00:00Z"))
      refute_receive {:webhook_test_server_request, _}, 300

      Alerts.notify_error_group(schema, payload.("growth", "2026-11-14T11:00:00Z"))
      assert Jason.decode!(receive_request().body)["hour"] == "2026-11-14T11:00:00Z"
    end

    test "EC-11 the flush's alert payload carries a count of companies and no uuid list", %{a: a} do
      server = WebhookTestServer.start(200, "ok")

      Application.put_env(:letflow, :alert_hooks,
        enabled: true,
        hooks: [
          [
            hook_id: "eg-hook2",
            enabled: true,
            destination_url: server.url,
            timeout_ms: 5_000,
            auth_secret_ref: nil,
            retry_policy: [
              max_attempts: 1,
              base_backoff_ms: 1,
              max_backoff_ms: 1,
              multiplier: 2.0
            ]
          ]
        ]
      )

      ErrorCapture.record(entry(%{tenant_id: a.tenant_id, trace_id: "tr-1"}))

      capture_log(fn -> assert :ok = Buffer.flush() end)
      req = receive_request()
      body = Jason.decode!(req.body)
      assert body["tenants_affected"] == 1
      refute req.body =~ a.tenant_id
      refute req.body =~ "tr-1"
    end
  end

  describe "EC-14/16" do
    test "EC-14 flag off: nothing is buffered or written", %{p: p} do
      set_config(enabled: false)
      ErrorCapture.record(entry())
      assert :ets.info(ErrorCapture.main_table(), :size) == 0
      assert :ok = Buffer.flush()
      assert [] = groups(p)
    end

    test "EC-14 the shipped default is off" do
      config = File.read!("config/config.exs")
      assert config =~ ~r/config :letflow, :error_capture,\s+enabled: false/
    end

    test "EC-16 retention clears ids after 90 days and keeps counts", %{p: p, a: a} do
      ErrorCapture.record(entry(%{tenant_id: a.tenant_id, trace_id: "old"}))
      ErrorCapture.record(entry(%{route: "/young", tenant_id: a.tenant_id, trace_id: "new"}))
      assert :ok = Buffer.flush()
      old = DateTime.add(DateTime.utc_now(), -91 * 86_400, :second)

      Repo.query!(
        ~s|UPDATE "#{p.schema_name}".error_groups SET last_seen_at = $1 WHERE route = $2|,
        [old, "/api/v1/x/:id"]
      )

      assert {:ok, 1} = Buffer.prune_now()
      by_route = Map.new(groups(p), &{&1.route, &1})
      assert %{tenant_ids: [], last_trace_ids: [], count: 1} = by_route["/api/v1/x/:id"]
      assert %{tenant_ids: [_], last_trace_ids: ["new"]} = by_route["/young"]
    end
  end

  defp pad(i), do: i |> Integer.to_string() |> String.pad_leading(2, "0")

  defp receive_request(timeout \\ 2_000) do
    receive do
      {:webhook_test_server_request, req} -> req
    after
      timeout -> flunk("no HTTP request received within #{timeout}ms")
    end
  end
end
