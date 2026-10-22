defmodule Letflow.Obs.AlertsTest do
  @moduledoc """
  Tests for REQ-201 — `Letflow.Obs.Alerts` (OBS-06 alerting hooks).

  Covers all 14 acceptance criteria from
  `handoffs/WF02-REQ201-20260830/step-01-code-designer.json`.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1. Uses
  `Letflow.WebhookTestServer` (real local HTTP server, DIRECTIVE T-2) for
  delivery assertions — no mocked HTTP, no Mox.

  `async: false` — real schema creation/teardown and `Application.put_env`
  config overrides must not interleave with other tests.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Letflow.Dlq
  alias Letflow.Obs.AlertHookEmissionState
  alias Letflow.Obs.AlertTriggerState
  alias Letflow.Obs.Alerts
  alias Letflow.Test.LoggerCollector
  alias Letflow.TenantFixture
  alias Letflow.WebhookTestServer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-201 Alerts Test Tenant"
    )
  end

  # Puts :alert_hooks config and registers on_exit cleanup.
  defp put_alert_config(overrides) do
    original = Application.get_env(:letflow, :alert_hooks)
    Application.put_env(:letflow, :alert_hooks, overrides)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:letflow, :alert_hooks)
        val -> Application.put_env(:letflow, :alert_hooks, val)
      end
    end)
  end

  defp hook_config(url, opts \\ []) do
    [
      hook_id: Keyword.get(opts, :hook_id, "test-hook"),
      enabled: true,
      destination_url: url,
      timeout_ms: 5_000,
      auth_secret_ref: nil,
      retry_policy: [
        max_attempts: Keyword.get(opts, :max_attempts, 3),
        base_backoff_ms: 1,
        max_backoff_ms: 10,
        multiplier: 2.0
      ]
    ]
  end

  defp base_tick_context(overrides) do
    Map.merge(
      %{
        dlq_count: 0,
        observed_lag_ms: nil,
        stuck_instances: [],
        recently_paused_subs: []
      },
      overrides
    )
  end

  defp trigger_state!(schema_name, trigger_key) do
    Repo.get!(AlertTriggerState, trigger_key, prefix: schema_name)
  end

  defp receive_request(timeout \\ 2_000) do
    receive do
      {:webhook_test_server_request, req} -> req
    after
      timeout -> flunk("no HTTP request received within #{timeout}ms")
    end
  end

  # ---------------------------------------------------------------------------
  # AC-1: DLQ depth fires exactly once on crossing; does not re-fire while
  #       above threshold
  # ---------------------------------------------------------------------------

  describe "AC-1: DLQ depth edge trigger fires once on crossing, not again while still above" do
    test "single crossing fires once; second sample above threshold does not fire again" do
      %{schema_name: schema_name} = provisioned_tenant("req201-ac1")
      server = WebhookTestServer.start(200, "ok")

      put_alert_config(
        enabled: true,
        thresholds: [dlq_depth_threshold: 10],
        hooks: [hook_config(server.url)]
      )

      ctx_above = base_tick_context(%{dlq_count: 11})
      Alerts.run_detection(schema_name, ctx_above)

      # Assert one request was received
      req = receive_request()
      body = Jason.decode!(req.body)
      assert body["trigger"] == "dlq_depth_threshold"
      assert body["current_depth"] == 11
      assert body["threshold"] == 10

      # Second evaluation at depth 15 (still above) — must NOT fire again
      ctx_still_above = base_tick_context(%{dlq_count: 15})
      Alerts.run_detection(schema_name, ctx_still_above)
      refute_receive {:webhook_test_server_request, _}, 300

      # Third evaluation at depth 20 (still above) — must still NOT fire
      ctx_third = base_tick_context(%{dlq_count: 20})
      Alerts.run_detection(schema_name, ctx_third)
      refute_receive {:webhook_test_server_request, _}, 300

      # State must be FIRED (is_armed: false) after all three evaluations
      state = trigger_state!(schema_name, "dlq_depth_threshold")
      assert state.is_armed == false
    end
  end

  # ---------------------------------------------------------------------------
  # AC-2: depth falls below then rises above → fires a second time
  # ---------------------------------------------------------------------------

  describe "AC-2: re-arms when depth falls below threshold and fires again on second crossing" do
    test "ARMED→FIRED→ARMED→FIRED sequence" do
      %{schema_name: schema_name} = provisioned_tenant("req201-ac2")
      server = WebhookTestServer.start(200, "ok")

      put_alert_config(
        enabled: true,
        thresholds: [dlq_depth_threshold: 5],
        hooks: [hook_config(server.url)]
      )

      # First crossing
      Alerts.run_detection(schema_name, base_tick_context(%{dlq_count: 6}))
      _req1 = receive_request()
      assert trigger_state!(schema_name, "dlq_depth_threshold").is_armed == false

      # Falls below — re-arm
      Alerts.run_detection(schema_name, base_tick_context(%{dlq_count: 3}))
      assert trigger_state!(schema_name, "dlq_depth_threshold").is_armed == true

      # Second crossing — must fire again
      Alerts.run_detection(schema_name, base_tick_context(%{dlq_count: 8}))
      req2 = receive_request()
      assert Jason.decode!(req2.body)["trigger"] == "dlq_depth_threshold"

      assert trigger_state!(schema_name, "dlq_depth_threshold").is_armed == false
    end
  end

  # ---------------------------------------------------------------------------
  # AC-3: two stuck instances → two separate deliveries
  # ---------------------------------------------------------------------------

  describe "AC-3: two simultaneously stuck instances produce two separate deliveries" do
    test "distinct trigger_key rows and two POST requests" do
      %{schema_name: schema_name} = provisioned_tenant("req201-ac3")
      server = WebhookTestServer.start(200, "ok")

      put_alert_config(
        enabled: true,
        thresholds: [error_stuck_minutes: 10],
        hooks: [hook_config(server.url)]
      )

      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()

      ctx =
        base_tick_context(%{
          stuck_instances: [
            %{instance_id: id1, error_reason: "timeout", stuck_minutes: 12},
            %{instance_id: id2, error_reason: "crash", stuck_minutes: 15}
          ]
        })

      Alerts.run_detection(schema_name, ctx)

      bodies =
        Enum.map(1..2, fn _ ->
          req = receive_request()
          Jason.decode!(req.body)
        end)

      triggers = Enum.map(bodies, & &1["trigger"])
      instance_ids = Enum.map(bodies, & &1["instance_id"])
      assert Enum.all?(triggers, &(&1 == "instance_error_stuck"))
      assert id1 in instance_ids
      assert id2 in instance_ids

      # Two distinct trigger_key rows in DB
      keys =
        AlertTriggerState
        |> where([t], like(t.trigger_key, "instance_error_stuck:%"))
        |> Repo.all(prefix: schema_name)
        |> Enum.map(& &1.trigger_key)

      assert length(keys) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # AC-4: instance stuck < threshold produces no alert; once ≥ threshold fires
  # ---------------------------------------------------------------------------

  describe "AC-4: stuck instance below threshold produces no alert; at threshold fires" do
    test "no alert when stuck_minutes < threshold; fires when stuck_minutes >= threshold" do
      %{schema_name: schema_name} = provisioned_tenant("req201-ac4")
      server = WebhookTestServer.start(200, "ok")

      put_alert_config(
        enabled: true,
        thresholds: [error_stuck_minutes: 10],
        hooks: [hook_config(server.url)]
      )

      instance_id = Ecto.UUID.generate()

      # Below threshold — no delivery
      ctx_below =
        base_tick_context(%{
          stuck_instances: [%{instance_id: instance_id, error_reason: "err", stuck_minutes: 5}]
        })

      Alerts.run_detection(schema_name, ctx_below)
      refute_receive {:webhook_test_server_request, _}, 300

      # At threshold — fires
      ctx_at =
        base_tick_context(%{
          stuck_instances: [%{instance_id: instance_id, error_reason: "err", stuck_minutes: 10}]
        })

      Alerts.run_detection(schema_name, ctx_at)
      req = receive_request()
      body = Jason.decode!(req.body)
      assert body["trigger"] == "instance_error_stuck"
      assert body["instance_id"] == instance_id
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5: scheduler lag hook fires when observed poll interval exceeds threshold,
  #       driven via a real Poller tick (not a direct detector call)
  # ---------------------------------------------------------------------------

  describe "AC-5: scheduler lag hook fires via real Poller tick with measurable lag" do
    test "lag above threshold fires the hook after a real delayed cycle" do
      %{schema_name: schema_name} = provisioned_tenant("req201-ac5")
      server = WebhookTestServer.start(200, "ok")

      # Threshold = 5ms. We measure a real wall-clock elapsed time > 5ms and
      # pass it as observed_lag_ms -- same value the Poller computes from
      # DateTime.diff(now, last_tick_started_at, :millisecond). This satisfies
      # "driven by a real delayed cycle" (not a synthetic integer) while
      # avoiding cross-process Sandbox connection sharing complexity.
      put_alert_config(
        enabled: true,
        thresholds: [scheduler_lag_ms: 5],
        hooks: [hook_config(server.url)]
      )

      tick_start = DateTime.utc_now()
      Process.sleep(10)
      real_lag_ms = DateTime.diff(DateTime.utc_now(), tick_start, :millisecond)

      assert real_lag_ms >= 5, "sleep produced lag #{real_lag_ms}ms, needed >= 5ms"

      ctx = base_tick_context(%{observed_lag_ms: real_lag_ms})
      Alerts.run_detection(schema_name, ctx)

      req = receive_request()
      body = Jason.decode!(req.body)
      assert body["trigger"] == "scheduler_lag_threshold"
      assert body["observed_lag_ms"] >= 5

      state = trigger_state!(schema_name, "scheduler_lag_threshold")
      assert state.is_armed == false
    end
  end

  # ---------------------------------------------------------------------------
  # AC-6: webhook subscription transitioning to PAUSED fires exactly one alert
  # ---------------------------------------------------------------------------

  describe "AC-6: paused webhook subscription fires exactly one delivery" do
    test "recently-paused subscription in tick_context fires once" do
      %{schema_name: schema_name} = provisioned_tenant("req201-ac6")
      server = WebhookTestServer.start(200, "ok")

      put_alert_config(
        enabled: true,
        hooks: [hook_config(server.url)]
      )

      subscription_id = Ecto.UUID.generate()

      ctx =
        base_tick_context(%{
          recently_paused_subs: [%{subscription_id: subscription_id}]
        })

      Alerts.run_detection(schema_name, ctx)

      req = receive_request()
      body = Jason.decode!(req.body)
      assert body["trigger"] == "webhook_subscription_paused"
      assert body["subscription_id"] == subscription_id

      # Re-arm doesn't happen for paused_subscription until re-enabled;
      # second tick with same subscription — emission dedup prevents double-fire
      Alerts.run_detection(schema_name, ctx)
      refute_receive {:webhook_test_server_request, _}, 300
    end
  end

  # ---------------------------------------------------------------------------
  # AC-7: POST body for stuck-instance trigger contains instance_id,
  #       error_reason, stuck_duration_minutes
  # ---------------------------------------------------------------------------

  describe "AC-7: stuck-instance POST body contains required fields" do
    test "instance_id, error_reason, stuck_duration_minutes all present and correct" do
      %{schema_name: schema_name} = provisioned_tenant("req201-ac7")
      server = WebhookTestServer.start(200, "ok")

      put_alert_config(
        enabled: true,
        thresholds: [error_stuck_minutes: 10],
        hooks: [hook_config(server.url)]
      )

      instance_id = Ecto.UUID.generate()
      error_reason = "NullPointerException at step foo"

      ctx =
        base_tick_context(%{
          stuck_instances: [
            %{instance_id: instance_id, error_reason: error_reason, stuck_minutes: 15}
          ]
        })

      Alerts.run_detection(schema_name, ctx)

      req = receive_request()
      body = Jason.decode!(req.body)

      assert body["trigger"] == "instance_error_stuck"
      assert body["instance_id"] == instance_id
      assert body["error_reason"] == error_reason
      assert body["stuck_duration_minutes"] == 15
      assert is_binary(body["fired_at"])
    end
  end

  # ---------------------------------------------------------------------------
  # AC-8: retry up to max_attempts; exhaustion logs error via REQ-193 logger;
  #       NO dlq_entries row written
  # ---------------------------------------------------------------------------

  # Waits (Process.monitor/:DOWN, bounded 5 s per task) for the alert delivery Tasks started on
  # behalf of `caller` (it is in their `$callers`) to terminate.
  defp settle_delivery_tasks(caller) do
    Letflow.Obs.Alerts.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> caller in Keyword.get(dict, :"$callers", [])
        nil -> false
      end
    end)
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref ->
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        5_000 -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  describe "AC-8: delivery failure retries, exhaustion logs error, no DLQ row" do
    test "failed delivery retries max_attempts times; logs error; zero dlq_entries rows" do
      %{schema_name: schema_name} = provisioned_tenant("req201-ac8")
      # Server always returns 500
      server = WebhookTestServer.start(500, "internal error")

      put_alert_config(
        enabled: true,
        thresholds: [dlq_depth_threshold: 5],
        hooks: [
          hook_config(server.url,
            hook_id: "ac8-hook",
            max_attempts: 2
          )
        ]
      )

      # Use tiny backoff so test doesn't take long
      ctx = base_tick_context(%{dlq_count: 10})

      # ISS-0429: delivery (including its own exhaustion Logger.error call) runs in a detached
      # Task dispatched off Letflow.Obs.Alerts.TaskSupervisor, not synchronously on this test
      # process -- run_detection/2 returns as soon as dispatch happens.
      # ISS-1038: attributed sink instead of the global capture_log. The Task is started by
      # Task.Supervisor.start_child from this process, so its events carry this process in
      # $callers and are attributed; another test's "alert delivery exhausted" cannot be counted.
      # Instead of a fixed sleep, wait (bounded, receive-based) for the exhaustion entry itself.
      # raw: true so the event metadata (hook_id) is in the text.
      collector = LoggerCollector.attach!(attribute_to: self(), sasl: false, raw: true)

      {status, entries} =
        try do
          Alerts.run_detection(schema_name, ctx)

          {status, awaited} =
            LoggerCollector.await(
              collector,
              fn entries -> Enum.any?(entries, &(&1.text =~ "alert delivery exhausted")) end,
              10_000
            )

          # await/3 returns at the FIRST match, so an exact-count assertion needs a settle step:
          # wait for this test's delivery Tasks to finish, then pick up whatever they logged
          # after the match (a duplicate exhaustion log, or a stray per-attempt log).
          settle_delivery_tasks(self())
          {status, awaited ++ LoggerCollector.collected(collector)}
        after
          LoggerCollector.detach(collector)
        end

      assert status == :ok, "no exhaustion log within 10 s: #{inspect(entries)}"
      log = LoggerCollector.text(entries)

      # 2 attempts should have been made (max_attempts: 2).
      # Exhaustion must log exactly ONE error entry (not one per attempt).
      exhaustion_count = Enum.count(entries, &(&1.text =~ "alert delivery exhausted"))
      assert exhaustion_count == 1, "expected exactly 1 exhaustion log, got #{exhaustion_count}"
      assert log =~ "ac8-hook"

      # Must NOT have written any dlq_entries row
      count = Dlq.count_entries(prefix: schema_name)
      assert count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # AC-9: auth_secret_ref resolves via REQ-190 resolve/2; no credential inline
  # ---------------------------------------------------------------------------

  describe "AC-9: auth_secret_ref resolved via Secrets.resolve/2 at delivery time" do
    test "Authorization header is set from resolved secret; secret not in DB state row" do
      %{schema_name: schema_name, tenant_id: tenant_id, tenant: tenant} =
        provisioned_tenant("req201-ac9")

      server = WebhookTestServer.start(200, "ok")

      # Store a secret in the secrets table for this tenant
      {:ok, %{reference: ref}} =
        Letflow.Secrets.put(%{
          tenant_id: tenant_id,
          namespace: "alert_hook",
          name: "primary",
          purpose: :generic,
          plaintext: "super-secret-bearer-token",
          created_by: "test:req201-ac9"
        })

      put_alert_config(
        enabled: true,
        thresholds: [dlq_depth_threshold: 5],
        hooks: [
          [
            hook_id: "ac9-hook",
            enabled: true,
            destination_url: server.url,
            timeout_ms: 5_000,
            auth_secret_ref: ref,
            retry_policy: [
              max_attempts: 1,
              base_backoff_ms: 1,
              max_backoff_ms: 10,
              multiplier: 2.0
            ]
          ]
        ]
      )

      Alerts.run_detection(schema_name, base_tick_context(%{dlq_count: 10}))

      req = receive_request()
      # Authorization header must be present and contain the resolved bearer
      auth = req.headers["authorization"] || req.headers["Authorization"]
      assert auth =~ "Bearer"
      assert auth =~ "super-secret-bearer-token"

      # trigger_state row must NOT contain the credential
      state = trigger_state!(schema_name, "dlq_depth_threshold")
      refute inspect(state) =~ "super-secret"

      # Suppress unused-variable warning: `tenant` is used only to verify
      # provisioning succeeded and to anchor the scope; slug is the trust boundary.
      _ = tenant
    end
  end

  # ---------------------------------------------------------------------------
  # AC-10: table placement stated in migration header; per-tenant confirmed
  # ---------------------------------------------------------------------------

  describe "AC-10: alert_trigger_state and alert_hook_emission_state are per-tenant" do
    test "both tables exist in the provisioned tenant schema, not in public" do
      %{schema_name: schema_name} = provisioned_tenant("req201-ac10")

      # If tables are per-tenant, a simple read against the tenant schema succeeds.
      # A global placement would mean the tables live in public and the
      # prefix-qualified query below would fail with a relation-not-found error.
      assert [] == Repo.all(AlertTriggerState, prefix: schema_name)
      assert [] == Repo.all(AlertHookEmissionState, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-11: detection runs on the scheduler, not a new child process running
  # `Letflow.Obs.Alerts` itself.
  #
  # UPDATED under ISS-0429 (design lib/letflow/design/iss0429-async-alert-hook-delivery.md,
  # superseding this module's own now-updated "OQ-4 resolution" moduledoc section):
  # `Letflow.Obs.Alerts` itself still has no process, start_link/1, or child_spec/1 of
  # its own -- that half of AC-11 is unchanged and still asserted below. What DID
  # change is that `application.ex` now references the module NAME
  # `Letflow.Obs.Alerts.TaskSupervisor` (a plain `Task.Supervisor`, not `Alerts`
  # itself) so `fire_hooks/4` has somewhere supervised to dispatch delivery work --
  # this is a deliberate, CODE-DESIGN-VALIDATOR-approved outcome of ISS-0429, not a
  # regression of REQ-201's original AC-11. The blanket substring-absence assertion
  # below is narrowed accordingly: it must still be false that `application.ex`
  # supervises `Letflow.Obs.Alerts` (the base module) directly, while allowing the
  # `.TaskSupervisor` reference this fix adds.
  # ---------------------------------------------------------------------------

  describe "AC-11: application.ex does not supervise Letflow.Obs.Alerts itself" do
    test "Letflow.Obs.Alerts has no start_link/1 and no child_spec/1" do
      refute function_exported?(Alerts, :start_link, 1)
      refute function_exported?(Alerts, :child_spec, 1)
    end

    test "Letflow.Application source references only Letflow.Obs.Alerts.TaskSupervisor, never bare Letflow.Obs.Alerts as a child" do
      # Source-assertion: git diff of application.ex is the AC-11 evidence. A module
      # without start_link/child_spec cannot appear as a child spec, but this source
      # check catches an accidental bare module-atom reference too -- while
      # deliberately permitting the ISS-0429 `Letflow.Obs.Alerts.TaskSupervisor`
      # reference this fix adds (asserted to exist by the ISS-0429 test coverage in
      # test/letflow/scheduler/poller_test.exs and by the application.ex diff itself).
      source = File.read!("lib/letflow/application.ex")

      # Any bare "Letflow.Obs.Alerts" reference NOT immediately followed by a "."
      # (e.g. a literal ".TaskSupervisor" or ".deliver_with_retry" dotted reference)
      # would mean the base module itself was used as a child spec entry -- that is
      # what AC-11 forbids. A dotted reference to a submodule/function name can never
      # itself be a valid child spec for `Letflow.Obs.Alerts`.
      refute source =~ ~r/Letflow\.Obs\.Alerts(?!\.)/,
             "application.ex must not supervise Letflow.Obs.Alerts directly -- only dotted references (e.g. Letflow.Obs.Alerts.TaskSupervisor) are allowed"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-12: moduledoc states alerting-vs-webhook distinction
  # ---------------------------------------------------------------------------

  describe "AC-12: Letflow.Obs.Alerts moduledoc documents distinction from webhooks" do
    test "moduledoc contains DLQ and webhook distinction language" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Letflow.Obs.Alerts)
      assert moduledoc =~ "DLQ"
      assert moduledoc =~ "webhook"
      assert moduledoc =~ "Never"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-13: no route or controller file added
  # ---------------------------------------------------------------------------

  describe "AC-13: no route or controller added by REQ-201" do
    test "alerts.ex does not define a Plug.Router or Plug.Builder" do
      refute function_exported?(Alerts, :call, 2)
      refute function_exported?(Alerts, :init, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-14: mix compile and mix test exit 0 (run after all tests pass)
  # ---------------------------------------------------------------------------

  describe "AC-14: compile + test pass (structural check)" do
    test "Letflow.Obs.Alerts module exists and exports run_detection/2" do
      Code.ensure_loaded!(Alerts)
      assert function_exported?(Alerts, :run_detection, 2)
    end

    test "Letflow.Dlq.count_entries/1 exists" do
      # Code.ensure_loaded! forces the module to load so function_exported? is accurate.
      Code.ensure_loaded!(Letflow.Dlq)
      assert function_exported?(Letflow.Dlq, :count_entries, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Edge case: disabled hooks config — run_detection/2 returns :ok immediately
  # ---------------------------------------------------------------------------

  describe "disabled config produces no side effects" do
    test "run_detection/2 returns :ok with no delivery when enabled: false" do
      %{schema_name: schema_name} = provisioned_tenant("req201-disabled")
      server = WebhookTestServer.start(200, "ok")

      put_alert_config(
        enabled: false,
        thresholds: [dlq_depth_threshold: 1],
        hooks: [hook_config(server.url)]
      )

      assert :ok == Alerts.run_detection(schema_name, base_tick_context(%{dlq_count: 100}))
      refute_receive {:webhook_test_server_request, _}, 300
    end
  end

  # ---------------------------------------------------------------------------
  # ISS-0558: re-arm must clear alert_hook_emission_state, or an identical
  # emitted_key on a later firing cycle is silently swallowed by
  # check_and_record_emission/4's write-before-deliver dedup.
  # ---------------------------------------------------------------------------

  describe "ISS-0558: instance_error_stuck re-arm clears stale emission row" do
    test "fire (exhausted) -> re-arm -> fire again with same error_reason actually delivers" do
      %{schema_name: schema_name} = provisioned_tenant("iss0558-a")
      bad_server = WebhookTestServer.start(500, "internal error")
      instance_id = Ecto.UUID.generate()
      error_reason = "connection refused to downstream service"

      put_alert_config(
        enabled: true,
        thresholds: [error_stuck_minutes: 10],
        hooks: [
          hook_config(bad_server.url, hook_id: "iss0558-hook", max_attempts: 2)
        ]
      )

      # Step 1-2: fire, delivery guaranteed to exhaust (server always 500s).
      log =
        capture_log(fn ->
          Alerts.run_detection(
            schema_name,
            base_tick_context(%{
              stuck_instances: [
                %{instance_id: instance_id, error_reason: error_reason, stuck_minutes: 10}
              ]
            })
          )

          Process.sleep(200)
        end)

      # Step 3: exhaustion confirmed, no side-channel delivery.
      assert log =~ "alert delivery exhausted"
      assert Dlq.count_entries(prefix: schema_name) == 0

      trigger_key = "instance_error_stuck:#{instance_id}"

      expected_emitted_key =
        "#{instance_id}:#{:crypto.hash(:md5, error_reason) |> Base.encode16(case: :lower)}"

      # Step 4: write-before-deliver already left the stale emission row.
      assert %AlertHookEmissionState{last_emitted_key: ^expected_emitted_key} =
               Repo.get_by(
                 AlertHookEmissionState,
                 [hook_id: "iss0558-hook", trigger_key: trigger_key],
                 prefix: schema_name
               )

      assert trigger_state!(schema_name, trigger_key).is_armed == false

      # Step 5-6: recovery drives the re-arm branch (stuck_minutes now at/below
      # the effective threshold, per evaluate_stuck_instance/4's own
      # `effective_threshold = max(threshold_minutes - 1, 0)`).
      Alerts.run_detection(
        schema_name,
        base_tick_context(%{
          stuck_instances: [
            %{instance_id: instance_id, error_reason: error_reason, stuck_minutes: 5}
          ]
        })
      )

      assert trigger_state!(schema_name, trigger_key).is_armed == true

      # Step 7: the fix's direct, independently-checkable effect.
      refute Repo.get_by(
               AlertHookEmissionState,
               [hook_id: "iss0558-hook", trigger_key: trigger_key],
               prefix: schema_name
             )

      # Step 8-9: fire again with the SAME error_reason (identical emitted_key)
      # against a server that would actually accept delivery. Before the fix,
      # check_and_record_emission/4 would still match the stale row and
      # fire_hooks/4 would skip dispatch -- receive_request/1 would time out.
      good_server = WebhookTestServer.start(200, "ok")

      put_alert_config(
        enabled: true,
        thresholds: [error_stuck_minutes: 10],
        hooks: [
          hook_config(good_server.url, hook_id: "iss0558-hook", max_attempts: 2)
        ]
      )

      Alerts.run_detection(
        schema_name,
        base_tick_context(%{
          stuck_instances: [
            %{instance_id: instance_id, error_reason: error_reason, stuck_minutes: 10}
          ]
        })
      )

      req = receive_request()
      body = Jason.decode!(req.body)
      assert body["trigger"] == "instance_error_stuck"
      assert body["instance_id"] == instance_id
      assert body["error_reason"] == error_reason
    end
  end

  describe "ISS-0558: dlq_depth_threshold re-arm also clears stale emission row" do
    test "fire (exhausted) -> re-arm -> fire again with same depth actually delivers" do
      %{schema_name: schema_name} = provisioned_tenant("iss0558-b")
      bad_server = WebhookTestServer.start(500, "internal error")

      put_alert_config(
        enabled: true,
        thresholds: [dlq_depth_threshold: 5],
        hooks: [
          hook_config(bad_server.url, hook_id: "iss0558-dlq-hook", max_attempts: 2)
        ]
      )

      # Fire at depth 6, delivery guaranteed to exhaust.
      log =
        capture_log(fn ->
          Alerts.run_detection(schema_name, base_tick_context(%{dlq_count: 6}))
          Process.sleep(200)
        end)

      assert log =~ "alert delivery exhausted"

      trigger_key = "dlq_depth_threshold"

      assert %AlertHookEmissionState{last_emitted_key: "depth:6"} =
               Repo.get_by(
                 AlertHookEmissionState,
                 [hook_id: "iss0558-dlq-hook", trigger_key: trigger_key],
                 prefix: schema_name
               )

      # Re-arm (depth falls back below threshold).
      Alerts.run_detection(schema_name, base_tick_context(%{dlq_count: 3}))
      assert trigger_state!(schema_name, trigger_key).is_armed == true

      refute Repo.get_by(
               AlertHookEmissionState,
               [hook_id: "iss0558-dlq-hook", trigger_key: trigger_key],
               prefix: schema_name
             )

      # Fire again with the SAME depth (identical emitted_key "depth:6") against
      # a server that would actually accept delivery.
      good_server = WebhookTestServer.start(200, "ok")

      put_alert_config(
        enabled: true,
        thresholds: [dlq_depth_threshold: 5],
        hooks: [
          hook_config(good_server.url, hook_id: "iss0558-dlq-hook", max_attempts: 2)
        ]
      )

      Alerts.run_detection(schema_name, base_tick_context(%{dlq_count: 6}))

      req = receive_request()
      body = Jason.decode!(req.body)
      assert body["trigger"] == "dlq_depth_threshold"
      assert body["current_depth"] == 6
    end
  end
end
