defmodule Letflow.Engine.ServiceTaskDispatcherTest do
  @moduledoc """
  Basic sanity tests for REQ-214 -- `Letflow.Engine.ServiceTaskDispatcher`
  (context module) and `Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch`
  (schema): the poll-claim-decide loop this Step 2a handoff builds. See
  `lib/letflow/design/service_task_dispatcher.md` for the design authority.

  This is ELIXIR-DEV's own basic sanity coverage proving the implementation
  works, NOT TEST-DESIGNER-grade acceptance-criterion coverage -- that gap
  check happens at WF-02 Step 3, after SECURITY-REVIEWER/REVIEWER pass this
  handoff.

  Uses `Letflow.DataCase` (real Postgres), matching `test/letflow/scheduler_test.exs`'s
  own established pattern for the structurally identical `timers`/`Scheduler`
  precedent. `async: false` for the same reason every tenant-fixture-using
  test file in this codebase sets it.

  ## TEST-DESIGNER defect-fix coverage (queue task 415)

  Two describe blocks below close the two real gaps TEST-DESIGNER found:

  - "route_kind: :catalog_service is dispatched from its frozen
    rendered_url" (ISS-0917, replacing the retired lookup-stub tests) --
    proves a `:catalog_service` row goes through the same transport and SSRF
    gate as an inline row, and that a row without a usable `rendered_url`
    never issues a real HTTP request (a live local
    `Letflow.WebhookTestServer` listener would receive it).
  - "genuine :advance and genuine retriable outcomes via the
    :service_task_ssrf_validation_enabled test seam" -- uses the same
    seam `Letflow.Webhooks` established (`:webhook_ssrf_validation_enabled`)
    to reach a real 2xx response and a real connection-refused failure
    through a real local `Letflow.WebhookTestServer`, closing AC1/AC4's
    previously-zero real coverage.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Engine.ServiceTask
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture
  alias Letflow.WebhookTestServer

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req214-dispatcher") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-214 ServiceTaskDispatcher Test Tenant"
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp past(seconds_ago \\ 60), do: DateTime.add(now(), -seconds_ago, :second)

  # Inserts a real, minimal `instance_projections` row directly -- the
  # claim query's join target -- without going through the full
  # Letflow.Engine.create/2 machinery (this module's own scope never calls
  # Letflow.Engine, so its tests don't need a real running instance either,
  # only a real projection row with the right `status`).
  defp insert_instance_projection!(schema_name, status) do
    instance_id = Ecto.UUID.generate()

    %InstanceProjection{}
    |> Ecto.Changeset.change(%{
      instance_id: instance_id,
      status: status,
      definition_id: Ecto.UUID.generate(),
      last_event_seq: 0
    })
    |> Repo.insert!(prefix: schema_name)

    instance_id
  end

  defp config_snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        "route_kind" => "inline_url",
        "url_template" => "https://127.0.0.1/hook",
        "rendered_url" => "https://127.0.0.1/hook",
        "method" => "POST",
        "body_template" => nil,
        "headers" => %{},
        "timeout_ms" => 5_000,
        "retry_limit" => 3
      },
      overrides
    )
  end

  defp insert_dispatch!(schema_name, instance_id, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          tenant_id: Ecto.UUID.generate(),
          instance_id: instance_id,
          token_id: Ecto.UUID.generate(),
          node_id: "service-task-node",
          config_snapshot: config_snapshot(),
          next_attempt_at: past(),
          created_at: now()
        },
        overrides
      )

    assert {:ok, dispatch} =
             %ServiceTaskDispatch{}
             |> ServiceTaskDispatch.arm_changeset(attrs)
             |> Repo.insert(prefix: schema_name)

    dispatch
  end

  defp reload!(schema_name, dispatch_id) do
    ServiceTaskDispatch
    |> where([d], d.id == ^dispatch_id)
    |> Repo.one!(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # Migration / schema sanity
  # ---------------------------------------------------------------------------------

  describe "migration: service_task_dispatches table" do
    test "the table exists in the tenant's own schema with the expected columns, absent from public" do
      %{schema_name: schema_name} = provisioned_tenant()

      %{rows: tenant_columns} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'service_task_dispatches'",
          [schema_name]
        )

      column_names = Enum.map(tenant_columns, fn [name] -> name end)
      assert "tenant_id" in column_names
      assert "instance_id" in column_names
      assert "token_id" in column_names
      assert "config_snapshot" in column_names
      assert "next_attempt_at" in column_names
      assert "status" in column_names

      %{rows: public_rows} =
        Repo.query!(
          "SELECT 1 FROM information_schema.tables " <>
            "WHERE table_schema = 'public' AND table_name = 'service_task_dispatches'"
        )

      assert public_rows == []
    end

    test "status CHECK constraint rejects a value outside pending/advanced/given_up" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      attrs = %{
        id: Ecto.UUID.generate(),
        tenant_id: Ecto.UUID.generate(),
        instance_id: instance_id,
        token_id: Ecto.UUID.generate(),
        node_id: "n1",
        config_snapshot: config_snapshot(),
        next_attempt_at: past(),
        status: "bogus",
        created_at: now()
      }

      columns = Map.keys(attrs)
      col_list = Enum.map_join(columns, ", ", &to_string/1)

      placeholders =
        columns |> Enum.with_index(1) |> Enum.map_join(", ", fn {_c, i} -> "$#{i}" end)

      params =
        Enum.map(columns, fn
          :id -> Ecto.UUID.dump!(attrs.id)
          :tenant_id -> Ecto.UUID.dump!(attrs.tenant_id)
          :instance_id -> Ecto.UUID.dump!(attrs.instance_id)
          :token_id -> Ecto.UUID.dump!(attrs.token_id)
          :config_snapshot -> Jason.encode!(attrs.config_snapshot)
          :next_attempt_at -> DateTime.to_naive(attrs.next_attempt_at)
          :created_at -> DateTime.to_naive(attrs.created_at)
          other -> Map.fetch!(attrs, other)
        end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO \"#{schema_name}\".service_task_dispatches (#{col_list}) VALUES (#{placeholders})",
                 params
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # route_kind: :catalog_service is snapshot-driven (ISS-0917). The catalog is
  # resolved at activation by Letflow.Engine; the dispatcher only ever sees the
  # frozen config_snapshot["rendered_url"] and runs the same transport + SSRF
  # gate as an inline row.
  # ---------------------------------------------------------------------------------

  describe "route_kind: :catalog_service is dispatched from its frozen rendered_url" do
    defp catalog_snapshot(rendered_url) do
      config_snapshot(%{
        "route_kind" => "catalog_service",
        "service_id" => "some-catalog-service",
        "url_template" => nil,
        "rendered_url" => rendered_url
      })
    end

    test "goes through the SSRF gate: a blocked URL gives up as request_build_error with zero requests" do
      # Gate ON (default): a real local listener at 127.0.0.1 is a blocked
      # range, so nothing may ever connect to it.
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: catalog_snapshot(server_url)
        })

      assert {:ok, {:give_up, error_attrs}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert error_attrs.details.last_failure_kind == :request_build_error
      refute ServiceTask.is_retriable_failure(:request_build_error)

      reloaded = reload!(schema_name, dispatch.id)
      assert reloaded.status == :given_up
      assert reloaded.attempt_index == 0

      refute_receive {:webhook_test_server_request, _request}, 200
    end

    test "a cloud-metadata (link-local) URL is rejected before any transport call" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: catalog_snapshot("https://169.254.169.254/latest/meta-data")
        })

      assert {:ok, {:give_up, error_attrs}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert error_attrs.details.last_failure_kind == :request_build_error
      assert reload!(schema_name, dispatch.id).status == :given_up
    end

    test "gate bypassed by the test seam: a real 2xx JSON response advances the row" do
      Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
      on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)

      %{url: server_url} = WebhookTestServer.start(200, ~s({"result":"ok"}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: catalog_snapshot(server_url)
        })

      assert {:ok, {:advance, %{"result" => "ok"}}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert reload!(schema_name, dispatch.id).status == :advanced
      assert_receive {:webhook_test_server_request, _request}, 1_000
    end

    for {label, unusable} <- [{"nil", nil}, {"empty", ""}, {"non-binary", 42}] do
      test "a #{label} rendered_url gives up as request_build_error with zero requests" do
        Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
        on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)

        # Live listener nothing may ever connect to (gate bypassed, so a
        # request would genuinely arrive if one were attempted).
        %{url: _server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

        %{schema_name: schema_name} = provisioned_tenant()
        instance_id = insert_instance_projection!(schema_name, :active)

        dispatch =
          insert_dispatch!(schema_name, instance_id, %{
            config_snapshot: catalog_snapshot(unquote(Macro.escape(unusable)))
          })

        assert {:ok, {:give_up, error_attrs}} =
                 ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

        assert error_attrs.details.last_failure_kind == :request_build_error
        assert reload!(schema_name, dispatch.id).status == :given_up
        refute_receive {:webhook_test_server_request, _request}, 200
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Defect 2 fix (TEST-DESIGNER finding, queue task 415): the
  # :service_task_ssrf_validation_enabled test seam, mirroring
  # Letflow.Webhooks' own :webhook_ssrf_validation_enabled precedent, makes a
  # genuine :advance outcome and genuine retriable failure kinds reachable
  # through this module for the first time.
  # ---------------------------------------------------------------------------------

  describe "genuine :advance and genuine retriable outcomes via the :service_task_ssrf_validation_enabled test seam" do
    setup do
      Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
      on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)
      :ok
    end

    test "a real 2xx JSON response from a real local server advances the row to status advanced" do
      %{url: server_url} = WebhookTestServer.start(200, ~s({"result":"ok"}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: config_snapshot(%{"rendered_url" => server_url})
        })

      assert {:ok, {:advance, decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert decoded_body == %{"result" => "ok"}

      reloaded = reload!(schema_name, dispatch.id)
      assert reloaded.status == :advanced
      assert reloaded.dispatched_at != nil
    end

    test "a connection-refused failure reschedules with next_attempt_at advanced via real backoff, attempt_index incremented" do
      refused_url = WebhookTestServer.refused_url()

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      before_attempt = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: config_snapshot(%{"rendered_url" => refused_url, "retry_limit" => 3})
        })

      assert {:ok, :retry_scheduled} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      reloaded = reload!(schema_name, dispatch.id)
      assert reloaded.status == :pending
      assert reloaded.attempt_index == 1
      assert reloaded.last_failure_kind == "network"

      expected_delay_ms =
        ServiceTask.compute_service_task_backoff_ms(
          0,
          ServiceTaskDispatcher.default_backoff_base_ms(),
          ServiceTaskDispatcher.default_backoff_cap_ms()
        )

      expected_next_attempt_at = DateTime.add(before_attempt, expected_delay_ms, :millisecond)

      # Allow a generous scheduling-jitter tolerance (the real clock read
      # inside handle_retry/2 happens strictly after before_attempt, and
      # this host runs under real Postgres/tenant-provisioning I/O between
      # the two clock reads, per this run's own documented ISS-0219/ISS-0222
      # contention class) rather than asserting exact equality against a
      # value computed slightly earlier in this test.
      assert DateTime.diff(reloaded.next_attempt_at, expected_next_attempt_at, :millisecond)
             |> abs() < 10_000

      assert DateTime.compare(reloaded.next_attempt_at, before_attempt) == :gt
    end

    test "retry_limit exhausted after repeated connection-refused failures gives up with last_failure_kind network" do
      refused_url = WebhookTestServer.refused_url()

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: config_snapshot(%{"rendered_url" => refused_url, "retry_limit" => 0})
        })

      assert {:ok, {:give_up, error_attrs}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert error_attrs.details.last_failure_kind == :network
      assert error_attrs.details.retry_limit == 0

      reloaded = reload!(schema_name, dispatch.id)
      assert reloaded.status == :given_up
      assert reloaded.last_failure_kind == "network"
    end
  end

  # ---------------------------------------------------------------------------------
  # http_transport/3 -- the SSRF gate, INV-9
  # ---------------------------------------------------------------------------------

  describe "http_transport/3 -- SSRF gate" do
    test "a blocked IP-literal URL (127.0.0.1) is rejected before any HTTP call, classified as request_build_error" do
      config = %Letflow.Engine.ServiceTask.Config{
        node_id: "n1",
        route_kind: :inline_url,
        method: :POST,
        timeout_ms: 1_000,
        retry_limit: 3
      }

      assert {:request_build_error, :target_url_not_allowed} =
               ServiceTaskDispatcher.http_transport(config, "https://127.0.0.1/hook", nil)
    end

    test "a blocked cloud-metadata URL (169.254.169.254) is rejected before any HTTP call" do
      config = %Letflow.Engine.ServiceTask.Config{
        node_id: "n1",
        route_kind: :inline_url,
        method: :POST,
        timeout_ms: 1_000,
        retry_limit: 3
      }

      assert {:request_build_error, :target_url_not_allowed} =
               ServiceTaskDispatcher.http_transport(config, "https://169.254.169.254/hook", nil)
    end

    test "a non-https URL is rejected before any HTTP call" do
      config = %Letflow.Engine.ServiceTask.Config{
        node_id: "n1",
        route_kind: :inline_url,
        method: :POST,
        timeout_ms: 1_000,
        retry_limit: 3
      }

      assert {:request_build_error, :target_url_not_allowed} =
               ServiceTaskDispatcher.http_transport(config, "http://example.com/hook", nil)
    end

    test "classify_failure_kind/1 maps the SSRF block to :request_build_error (non-retriable)" do
      config = %Letflow.Engine.ServiceTask.Config{
        node_id: "n1",
        route_kind: :inline_url,
        method: :POST,
        timeout_ms: 1_000,
        retry_limit: 3
      }

      raw = ServiceTaskDispatcher.http_transport(config, "https://127.0.0.1/hook", nil)
      assert Letflow.Engine.ServiceTask.classify_failure_kind(raw) == :request_build_error
      refute Letflow.Engine.ServiceTask.is_retriable_failure(:request_build_error)
    end
  end

  # ---------------------------------------------------------------------------------
  # http_transport/4 -- DNS-rebinding coverage via an injected dns_resolver,
  # mirroring test/letflow/webhooks/url_validator_test.exs's own "hostname
  # resolving to 169.254.169.254 at validation time is rejected (DNS
  # rebinding)" case (queue task 415, REQ-214 AC2). http_transport/4's own
  # moduledoc (lib/letflow/engine/service_task_dispatcher.ex:319-326) states
  # it exists specifically "used directly only by
  # test/letflow/engine/service_task_dispatcher_test.exs for DNS-rebinding-
  # style coverage" -- this describe block is that coverage.
  # ---------------------------------------------------------------------------------

  describe "http_transport/4 -- DNS rebinding" do
    test "hostname resolving to 169.254.169.254 at dispatch time is rejected before any HTTP call (DNS rebinding)" do
      # The injected resolver simulates a hostname that looked fine (e.g. a
      # public IP) at url_template render/validation time but now resolves
      # to the cloud-metadata address at actual dispatch time -- a naive
      # static string/IP-literal check on the hostname "example.com" alone
      # would never catch this; only re-resolving at call time (what
      # UrlValidator.validate/2 does via check_host/2) does.
      rebinding_resolver = fn _host -> {:ok, [{:inet, {169, 254, 169, 254}, []}]} end

      config = %Letflow.Engine.ServiceTask.Config{
        node_id: "n1",
        route_kind: :inline_url,
        method: :POST,
        timeout_ms: 1_000,
        retry_limit: 3
      }

      assert {:request_build_error, :target_url_not_allowed} =
               ServiceTaskDispatcher.http_transport(
                 config,
                 "https://example.com/hook",
                 nil,
                 rebinding_resolver
               )
    end

    test "hostname reachable via the real resolver is still rejected once the injected resolver reports 169.254.169.254 (listener never connects)" do
      # Structural proof, same technique the :catalog_service-routing block
      # above uses: a real local Letflow.WebhookTestServer bound to
      # 127.0.0.1 receives a request only if :httpc.request/4 is ever
      # actually issued. This test deliberately uses "localhost" as the
      # dispatch hostname -- the OS's own real resolver (what :gen_tcp/
      # :httpc would use if the SSRF gate were ever bypassed) resolves
      # "localhost" to 127.0.0.1, the server's real address, so a genuine
      # connection WOULD succeed here if http_transport/4 ever fell through
      # to do_http_transport/3. But the *injected* dns_resolver passed to
      # UrlValidator.validate/2 is what this function actually consults for
      # a non-IP-literal host, and it reports 169.254.169.254 instead --
      # simulating a hostname that resolved safely at some earlier point
      # but rebinds to the metadata address by the time of this dispatch
      # attempt. The listener's silence proves the rejection came from the
      # injected resolver's (rebound) answer, not from the host being
      # genuinely unreachable.
      rebinding_resolver = fn _host -> {:ok, [{:inet, {169, 254, 169, 254}, []}]} end

      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))
      %{port: server_port} = URI.parse(server_url)

      config = %Letflow.Engine.ServiceTask.Config{
        node_id: "n1",
        route_kind: :inline_url,
        method: :POST,
        timeout_ms: 1_000,
        retry_limit: 3
      }

      assert {:request_build_error, :target_url_not_allowed} =
               ServiceTaskDispatcher.http_transport(
                 config,
                 "https://localhost:#{server_port}/hook",
                 nil,
                 rebinding_resolver
               )

      refute_receive {:webhook_test_server_request, _request}, 200
    end
  end

  # ---------------------------------------------------------------------------------
  # claim_due_dispatch_ids/2 -- design §5.4
  # ---------------------------------------------------------------------------------

  describe "claim_due_dispatch_ids/2" do
    test "claims a due, pending row belonging to an ACTIVE instance" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)
      dispatch = insert_dispatch!(schema_name, instance_id)

      assert [claimed_id] = ServiceTaskDispatcher.claim_due_dispatch_ids(schema_name, 64)
      assert claimed_id == dispatch.id
    end

    test "skips a row belonging to a CANCELLED instance -- never claimed" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :cancelled)
      insert_dispatch!(schema_name, instance_id)

      assert [] = ServiceTaskDispatcher.claim_due_dispatch_ids(schema_name, 64)
    end

    test "skips a row belonging to a COMPLETED instance -- never claimed" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :completed)
      insert_dispatch!(schema_name, instance_id)

      assert [] = ServiceTaskDispatcher.claim_due_dispatch_ids(schema_name, 64)
    end

    test "skips a row belonging to an ERROR instance -- never claimed" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :error)
      insert_dispatch!(schema_name, instance_id)

      assert [] = ServiceTaskDispatcher.claim_due_dispatch_ids(schema_name, 64)
    end

    test "does not claim a row whose next_attempt_at is in the future" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      insert_dispatch!(schema_name, instance_id, %{
        next_attempt_at: DateTime.add(now(), 3600, :second)
      })

      assert [] = ServiceTaskDispatcher.claim_due_dispatch_ids(schema_name, 64)
    end

    test "does not claim a row that is not status pending" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)
      dispatch = insert_dispatch!(schema_name, instance_id)

      dispatch
      |> ServiceTaskDispatch.terminal_changeset(%{status: :advanced, dispatched_at: now()})
      |> Repo.update!(prefix: schema_name)

      assert [] = ServiceTaskDispatcher.claim_due_dispatch_ids(schema_name, 64)
    end

    test "cross-tenant isolation: a due, pending row in tenant B's schema is never claimed when polling tenant A's schema" do
      # Postgres schema-per-tenant is the isolation boundary (design §0, §3.2
      # -- "no index on tenant_id alone, the Postgres schema IS the
      # boundary"). claim_due_dispatch_ids/2 takes tenant_schema as an
      # explicit Repo.all(prefix: ...) argument, never a tenant_id WHERE
      # clause -- this test proves that boundary actually holds for two
      # REAL, independently-provisioned tenant schemas (not just that the
      # query has the right shape on paper), each with its OWN due, pending,
      # ACTIVE-instance dispatch row.
      %{schema_name: schema_name_a} = provisioned_tenant("req214-tenant-a")
      %{schema_name: schema_name_b} = provisioned_tenant("req214-tenant-b")

      instance_id_a = insert_instance_projection!(schema_name_a, :active)
      dispatch_a = insert_dispatch!(schema_name_a, instance_id_a)

      instance_id_b = insert_instance_projection!(schema_name_b, :active)
      dispatch_b = insert_dispatch!(schema_name_b, instance_id_b)

      claimed_in_a = ServiceTaskDispatcher.claim_due_dispatch_ids(schema_name_a, 64)
      assert claimed_in_a == [dispatch_a.id]
      refute dispatch_b.id in claimed_in_a

      claimed_in_b = ServiceTaskDispatcher.claim_due_dispatch_ids(schema_name_b, 64)
      assert claimed_in_b == [dispatch_b.id]
      refute dispatch_a.id in claimed_in_b
    end
  end

  # ---------------------------------------------------------------------------------
  # attempt_dispatch/2 -- design §5.6: SSRF-block give-up path, frozen URL on
  # retry, retry/backoff bookkeeping in the same transaction.
  # ---------------------------------------------------------------------------------

  describe "attempt_dispatch/2 -- SSRF-blocked URL gives up immediately, never retries" do
    test "a dispatch row with a blocked rendered_url produces a :give_up outcome carrying build_service_task_give_up_error_attrs/1's shape" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{
              "url_template" => "https://127.0.0.1/hook",
              "rendered_url" => "https://127.0.0.1/hook"
            })
        })

      assert {:ok, {:give_up, error_attrs}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert error_attrs.instance_id == instance_id
      assert error_attrs.error_type == :service_task_retries_exhausted
      assert error_attrs.affected == {:node, "service-task-node"}
      assert is_binary(error_attrs.idempotency_key)
      assert error_attrs.variables == %{}
      assert error_attrs.details.last_failure_kind == :request_build_error

      reloaded = reload!(schema_name, dispatch.id)
      assert reloaded.status == :given_up
      assert reloaded.last_failure_kind == "request_build_error"
      assert reloaded.dispatched_at != nil
    end

    test "this module never calls Letflow.Engine.set_instance_error/2 (confirmed by grep, INV-STD-2)" do
      dispatcher_source =
        File.read!(Path.join(File.cwd!(), "lib/letflow/engine/service_task_dispatcher.ex"))

      poller_source =
        File.read!(Path.join(File.cwd!(), "lib/letflow/engine/service_task_dispatcher/poller.ex"))

      # Checks for actual CALL syntax (a literal "(" immediately after the
      # function name), not mere prose mentions -- this module's own
      # moduledoc/doc comments deliberately document THAT it never calls
      # set_instance_error/2, which would otherwise false-positive a naive
      # substring match.
      refute dispatcher_source =~ "set_instance_error("
      refute dispatcher_source =~ "ExecutionError.append_multi("
      refute poller_source =~ "set_instance_error("
    end

    test "the frozen rendered_url is re-read unchanged across repeated attempts -- never re-rendered" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      frozen_url = "https://127.0.0.1/frozen-hook"

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{
              "url_template" => frozen_url,
              "rendered_url" => frozen_url,
              # non-retriable outcome (SSRF block) so this row gives up on
              # attempt 0 -- re-insert a fresh "pending" row to simulate a
              # second, independent attempt against the SAME frozen url,
              # proving no re-render occurs between attempts (this module
              # never has template-rendering machinery to invoke at all).
              "retry_limit" => 3
            })
        })

      assert {:ok, {:give_up, _attrs1}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      reloaded = reload!(schema_name, dispatch.id)
      assert reloaded.config_snapshot["rendered_url"] == frozen_url

      # A second, independent row (simulating a retry-driven re-claim) reads
      # the identical frozen url and is blocked identically -- no function in
      # this module ever mutates config_snapshot["rendered_url"].
      dispatch2 =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{"url_template" => frozen_url, "rendered_url" => frozen_url})
        })

      assert {:ok, {:give_up, _attrs2}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch2.id, schema_name)

      reloaded2 = reload!(schema_name, dispatch2.id)
      assert reloaded2.config_snapshot["rendered_url"] == frozen_url
    end

    test "already-final (non-pending) row is a no-op :already_final, not re-attempted" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)
      dispatch = insert_dispatch!(schema_name, instance_id)

      dispatch
      |> ServiceTaskDispatch.terminal_changeset(%{status: :advanced, dispatched_at: now()})
      |> Repo.update!(prefix: schema_name)

      assert {:ok, :already_final} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)
    end

    test "a nonexistent dispatch id is a no-op :already_final" do
      %{schema_name: schema_name} = provisioned_tenant()

      assert {:ok, :already_final} =
               ServiceTaskDispatcher.attempt_dispatch(Ecto.UUID.generate(), schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # attempt_dispatch/2 -- BLOCKER fix (SECURITY-REVIEWER, queue task 415):
  # a malformed config_snapshot must fold into a typed :give_up outcome, not
  # raise and crash the shared Poller (poll_and_dispatch/1's own "never
  # raises" contract, design §5.5, INV-STD-5).
  # ---------------------------------------------------------------------------------

  describe "attempt_dispatch/2 -- malformed config_snapshot never raises" do
    test "an unrecognized route_kind string gives up cleanly instead of raising" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: config_snapshot(%{"route_kind" => "not_a_real_route_kind"})
        })

      assert {:ok, {:give_up, error_attrs}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert error_attrs.details.last_failure_kind == :request_build_error

      reloaded = reload!(schema_name, dispatch.id)
      assert reloaded.status == :given_up
      assert reloaded.last_failure_kind == "request_build_error"
    end

    test "an unrecognized method string is caught by config_from_snapshot/1's own error path, proven with an SSRF-ALLOWED url so the gate cannot mask it" do
      # Every other malformed-config test in this describe block (including
      # this one's neighbor immediately below) uses the shared
      # config_snapshot/0 helper's default rendered_url,
      # "https://127.0.0.1/hook" -- which http_transport/3's SSRF gate
      # (design §5.2) rejects BEFORE do_http_transport/3 ever reads
      # config.method. That means those tests prove "gives up cleanly, does
      # not raise" is TRUE, but not that it is true BECAUSE
      # config_from_snapshot/1's own {:error, :invalid_method} branch caught
      # the malformed method -- they would pass identically even if
      # config_from_snapshot/1 silently defaulted a malformed method to
      # `nil` and let it flow into a %ServiceTask.Config{}, since
      # method_atom(config.method) (do_http_transport/3, private, the only
      # place config.method is ever read) is never reached for a
      # SSRF-blocked row either way -- confirmed by mutation testing this
      # run: swapping config_from_snapshot/1's `with`-chain for a version
      # that defaults unparseable fields to `nil` instead of returning
      # {:error, _} left every existing test in this describe block
      # (including the sibling test below) still green.
      #
      # This test closes that gap: a real public, SSRF-ALLOWED IP
      # (93.184.216.34 -- deliberately unreachable from this test host,
      # matching test/letflow/webhooks_test.exs's own established
      # "literal public IP so SSRF validation passes without a DNS
      # round-trip" convention) paired with a malformed method. If
      # config_from_snapshot/1's error path is genuinely what stops this
      # row (not the SSRF gate, which passes this URL), the outcome must
      # still be a clean :give_up. If a future regression silently let a
      # malformed method flow through as `nil`, method_atom(nil) has no
      # matching clause (lib/letflow/engine/service_task_dispatcher.ex's
      # own closed 5-clause mapping) -- a FunctionClauseError, which this
      # test's own assertion on {:ok, {:give_up, _}} (not {:error, _})
      # would catch.
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{
              "method" => "not_a_real_http_method_xyz123",
              "url_template" => "https://93.184.216.34/hook",
              "rendered_url" => "https://93.184.216.34/hook"
            })
        })

      assert {:ok, {:give_up, error_attrs}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert error_attrs.details.last_failure_kind == :request_build_error

      reloaded = reload!(schema_name, dispatch.id)
      assert reloaded.status == :given_up
      assert reloaded.last_failure_kind == "request_build_error"
    end

    test "an unrecognized method string gives up cleanly instead of raising (no unbounded to_existing_atom)" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      # A string that was (almost certainly) never interned as an atom
      # anywhere in this BEAM instance -- the exact hazard
      # String.to_existing_atom/1 exposed: whether this raises used to
      # depend on incidental atom-table history, not on this module's own
      # logic.
      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: config_snapshot(%{"method" => "not_a_real_http_method_xyz123"})
        })

      assert {:ok, {:give_up, error_attrs}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert error_attrs.details.last_failure_kind == :request_build_error

      reloaded = reload!(schema_name, dispatch.id)
      assert reloaded.status == :given_up
      assert reloaded.last_failure_kind == "request_build_error"
    end

    test "poll_and_dispatch/1 never raises on a malformed row and still processes every other tenant's due rows in the same batch" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      malformed =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: config_snapshot(%{"route_kind" => "bogus_kind"})
        })

      # A second, well-formed row for a DIFFERENT instance in the SAME
      # tenant schema/poll batch -- proves the malformed row does not take
      # the whole batch down with it.
      other_instance_id = insert_instance_projection!(schema_name, :active)
      insert_dispatch!(schema_name, other_instance_id)

      result = ServiceTaskDispatcher.poll_and_dispatch(schema_name)

      assert result.claimed == 2
      assert result.given_up == 2
      assert result.advanced == 0
      assert result.retried == 0

      reloaded_malformed = reload!(schema_name, malformed.id)
      assert reloaded_malformed.status == :given_up
      assert reloaded_malformed.last_failure_kind == "request_build_error"
    end

    test "poll_and_dispatch/1 never raises on a malformed-METHOD row and still processes every other tenant's due rows in the same batch" do
      # Distinct from the malformed-route_kind neighbor-survival test above:
      # that test's own "well-formed" second row uses the default
      # config_snapshot/0 helper (a SYNTACTICALLY valid route_kind/method,
      # only SSRF-blocked). It never puts a malformed-METHOD row in the same
      # batch as another row, so config_from_snapshot/1's method_from_snapshot/1
      # error path (the second of the two BLOCKER-fix branches, guarding
      # against unbounded String.to_existing_atom/1) has only ever been
      # proven not to raise in ISOLATION (single-row attempt_dispatch/2
      # call), never proven not to take a shared poll_and_dispatch/1 batch
      # down with it -- the exact same distinction the route_kind case
      # already covers, now closed for the method case too.
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      malformed_method =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: config_snapshot(%{"method" => "not_a_real_http_method_xyz123"})
        })

      other_instance_id = insert_instance_projection!(schema_name, :active)
      insert_dispatch!(schema_name, other_instance_id)

      result = ServiceTaskDispatcher.poll_and_dispatch(schema_name)

      assert result.claimed == 2
      assert result.given_up == 2
      assert result.advanced == 0
      assert result.retried == 0

      reloaded = reload!(schema_name, malformed_method.id)
      assert reloaded.status == :given_up
      assert reloaded.last_failure_kind == "request_build_error"
    end

    test "poll_and_dispatch/1 never raises when a malformed-route_kind row and a malformed-method row are BOTH claimed in the same batch" do
      # The strongest version of the neighbor-survival property: two
      # DIFFERENT malformed-config shapes, each hitting a different branch
      # of config_from_snapshot/1's with-chain (route_kind_atom/1 fails
      # first for one row, method_from_snapshot/1 fails for the other),
      # claimed and processed in the SAME poll_and_dispatch/1 call. Proves
      # neither malformed row's failure handling interferes with the
      # other's, and both still fold cleanly into the same summary map
      # poll_and_dispatch/1 returns.
      %{schema_name: schema_name} = provisioned_tenant()

      route_kind_instance = insert_instance_projection!(schema_name, :active)

      malformed_route_kind =
        insert_dispatch!(schema_name, route_kind_instance, %{
          config_snapshot: config_snapshot(%{"route_kind" => "bogus_kind"})
        })

      method_instance = insert_instance_projection!(schema_name, :active)

      malformed_method =
        insert_dispatch!(schema_name, method_instance, %{
          config_snapshot: config_snapshot(%{"method" => "not_a_real_http_method_xyz123"})
        })

      result = ServiceTaskDispatcher.poll_and_dispatch(schema_name)

      assert result.claimed == 2
      assert result.given_up == 2
      assert result.advanced == 0
      assert result.retried == 0

      reloaded_route_kind = reload!(schema_name, malformed_route_kind.id)
      assert reloaded_route_kind.status == :given_up
      assert reloaded_route_kind.last_failure_kind == "request_build_error"

      reloaded_method = reload!(schema_name, malformed_method.id)
      assert reloaded_method.status == :given_up
      assert reloaded_method.last_failure_kind == "request_build_error"
    end
  end

  # ---------------------------------------------------------------------------------
  # poll_and_dispatch/1 -- design §5.5
  # ---------------------------------------------------------------------------------

  describe "poll_and_dispatch/1" do
    test "polls, claims, and folds an SSRF-blocked row's outcome into given_up count" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)
      insert_dispatch!(schema_name, instance_id)

      result = ServiceTaskDispatcher.poll_and_dispatch(schema_name)

      assert result.tenant_schema == schema_name
      assert result.claimed == 1
      assert result.given_up == 1
      assert result.advanced == 0
      assert result.retried == 0
    end

    test "never raises, returns zeroed counts when nothing is due" do
      %{schema_name: schema_name} = provisioned_tenant()

      result = ServiceTaskDispatcher.poll_and_dispatch(schema_name)

      assert result == %{
               tenant_schema: schema_name,
               claimed: 0,
               advanced: 0,
               retried: 0,
               given_up: 0
             }
    end
  end

  # ---------------------------------------------------------------------------------
  # Config accessors -- design §5.1
  # ---------------------------------------------------------------------------------

  describe "config accessors" do
    test "defaults apply when :service_task_dispatcher config is absent" do
      original = Application.get_env(:letflow, :service_task_dispatcher)
      Application.delete_env(:letflow, :service_task_dispatcher)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:letflow, :service_task_dispatcher)
          val -> Application.put_env(:letflow, :service_task_dispatcher, val)
        end
      end)

      assert ServiceTaskDispatcher.poll_interval_ms() == 5_000
      assert ServiceTaskDispatcher.jitter_ms() == 0
      assert ServiceTaskDispatcher.max_dispatches_per_cycle() == 64
      assert ServiceTaskDispatcher.default_backoff_base_ms() == 1_000
      assert ServiceTaskDispatcher.default_backoff_cap_ms() == 60_000
    end

    test "a runtime override is honored" do
      original = Application.get_env(:letflow, :service_task_dispatcher)
      Application.put_env(:letflow, :service_task_dispatcher, poll_interval_ms: 111)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:letflow, :service_task_dispatcher)
          val -> Application.put_env(:letflow, :service_task_dispatcher, val)
        end
      end)

      assert ServiceTaskDispatcher.poll_interval_ms() == 111
    end
  end

  # ---------------------------------------------------------------------------------
  # Boot gating -- design §8, INV-STD-7
  # ---------------------------------------------------------------------------------

  describe "boot gating" do
    test "config/test.exs sets start_service_task_dispatcher: false" do
      assert Application.get_env(:letflow, :start_service_task_dispatcher) == false
    end

    test "Letflow.Engine.ServiceTaskDispatcher.Poller is not running under the ordinary test supervision tree" do
      assert Process.whereis(Letflow.Engine.ServiceTaskDispatcher.Poller) == nil
    end

    # The two tests above only prove the gate suppresses the Poller under
    # TEST config (start_service_task_dispatcher: false) -- neither proves
    # the child spec structurally EXISTS in application.ex's children list
    # for a real (non-test) environment, nor that it is a genuinely
    # distinct entry from scheduler_children()'s own Letflow.Scheduler.Poller
    # entry (AC6's own wording: "both present in the supervisor's child
    # list, confirmed by reading application.ex"). Closed below by (a)
    # reading config/dev.exs and config/prod.exs directly via Config.Reader,
    # independent of MIX_ENV, mirroring test/letflow/application_test.exs's
    # own established "config/prod.exs's :oidc config" test exactly, and
    # (b) a source-structure check that service_task_dispatcher_children/0
    # is actually appended to the children list as its own, separate call
    # from scheduler_children/0 -- not folded into it or dropped.
    test "config/prod.exs does not override start_service_task_dispatcher to false -- the real-environment default (true) holds, so the Poller child spec is genuinely reachable outside test config" do
      # config/prod.exs carries no MIX_TEST_PARTITION guard (unlike dev.exs
      # below), so Config.Reader.read!/1 -- which actually executes the
      # file -- is safe here, mirroring test/letflow/application_test.exs's
      # own established "config/prod.exs's :oidc config" test exactly.
      config_path = Path.expand("../../../config/prod.exs", __DIR__)
      config = Config.Reader.read!(config_path)

      letflow_config = Keyword.get(config, :letflow, [])

      refute Keyword.get(letflow_config, :start_service_task_dispatcher) == false,
             "config/prod.exs must not override start_service_task_dispatcher to false -- " <>
               "doing so would silently disable SERVICE_TASK dispatch in that environment " <>
               "(lib/letflow/application.ex's service_task_dispatcher_children/0 default is " <>
               "true; only config/test.exs is meant to override it)"
    end

    test "config/dev.exs does not override start_service_task_dispatcher to false -- the real-environment default (true) holds" do
      # config/dev.exs cannot be safely loaded via Config.Reader.read!/1
      # under scripts/test_parallel.sh: it carries a deliberate ISS-0015
      # (GH#71) guard that raises whenever MIX_TEST_PARTITION is set, to
      # stop dev config from silently loading under partitioned test runs.
      # Reading the raw source text instead (matching the source-structure
      # check technique this same describe block already uses below for
      # application.ex) proves the same fact -- no
      # `start_service_task_dispatcher: false` override exists in this
      # file -- without ever executing the guarded config.
      source = File.read!(Path.join(File.cwd!(), "config/dev.exs"))

      refute source =~ ~r/start_service_task_dispatcher:\s*false/,
             "config/dev.exs must not override start_service_task_dispatcher to false -- " <>
               "doing so would silently disable SERVICE_TASK dispatch in that environment " <>
               "(lib/letflow/application.ex's service_task_dispatcher_children/0 default is " <>
               "true; only config/test.exs is meant to override it)"
    end

    test "Letflow.Supervisor.Pollers appends service_task_dispatcher_children() as its own call, alongside and distinct from scheduler_children()" do
      # REQ-219 (design req219-supervision-layering.md §1.2/§2) relocated
      # both scheduler_children/0 and service_task_dispatcher_children/0,
      # along with their call site, out of lib/letflow/application.ex (now
      # just a 3-child list of the new layer supervisors) into
      # lib/letflow/supervisor/pollers.ex -- this test's own source-text
      # assertions move with them.
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/supervisor/pollers.ex"))

      # Both entries present, and NEITHER folded into the other -- i.e. this
      # is not a single combined helper silently returning both children
      # (which would defeat the independent-boot-gate acceptance criterion:
      # a host could no longer disable one poller without the other).
      assert source =~ "scheduler_children()"
      assert source =~ "service_task_dispatcher_children()"

      # The two calls appear in the SAME children-list expression (the
      # `++` chain), not in two unrelated, disconnected places -- confirms
      # they are siblings in one list, matching AC6's "both present in the
      # supervisor's child list" wording.
      assert source =~ ~r/scheduler_children\(\)\s*\+\+\s*service_task_dispatcher_children\(\)/

      # service_task_dispatcher_children/0's own body returns the Poller
      # module as its child spec when enabled -- confirms the function this
      # requirement adds actually names Letflow.Engine.ServiceTaskDispatcher.Poller,
      # not a copy-paste of Letflow.Scheduler.Poller.
      assert source =~ "Letflow.Engine.ServiceTaskDispatcher.Poller"
      assert source =~ ":start_service_task_dispatcher"
    end

    test "service_task_dispatcher_children/0's child spec is independently startable as a real GenServer under a throwaway supervisor (proves it is a valid, distinct child spec, not just source text)" do
      # Does NOT start it under Letflow.Supervisor itself (that would hit
      # this design's own documented zero-delay-first-tick hazard against
      # the sandboxed Repo connection this test process owns). Instead,
      # starts the exact same {Letflow.Engine.ServiceTaskDispatcher.Poller, []}
      # child spec application.ex uses under ExUnit's own per-test supervisor
      # (via start_supervised!/1), proving the child spec is valid and
      # produces a real, live, uniquely-named process (Letflow.Scheduler.Poller
      # is not this process, confirmed by name), without touching the shared
      # application supervision tree or its Repo-sandbox ownership. Teardown
      # is entirely ExUnit's own responsibility (monitor-and-wait, no
      # check-then-act) -- no on_exit callback of any kind is needed here.
      {:ok, sup} = ExUnit.fetch_test_supervisor()
      pid = start_supervised!({Letflow.Engine.ServiceTaskDispatcher.Poller, []})

      children = Supervisor.which_children(sup)

      assert [{Letflow.Engine.ServiceTaskDispatcher.Poller, ^pid, :worker, _modules}] = children
      assert is_pid(pid)
      assert Process.alive?(pid)
      assert pid != Process.whereis(Letflow.Scheduler.Poller)
    end

    test "ExUnit.fetch_test_supervisor/0 + start_supervised!/1 (this suite's own throwaway-supervisor fixture idiom) tears down cleanly even when the child's shutdown is slow" do
      # ISS-0446 BACKGROUND (this is not a regression guard for that fix --
      # see the corrected scope note below): the test directly above this one
      # used to start its throwaway supervisor via a bare
      # `Supervisor.start_link/2` and guard teardown with
      # `on_exit(fn -> if Process.alive?(sup_pid), do: Supervisor.stop(sup_pid) end)`.
      # That guard was a CHECK-THEN-ACT race across a process boundary: the
      # ExUnit on_exit callback runs in its own, unrelated process (see
      # ExUnit.OnExitHandler.exec_callback/1), with no ordering guarantee at
      # all relative to the link-exit signal that the test process's own exit
      # sends to the supervisor -- Process.alive?/1 could observe `true` and
      # the supervisor could still die mid-flight before Supervisor.stop/1's
      # monitored call completed, making Supervisor.stop/1 exit
      # `{:shutdown, ...}` instead of returning `:ok`. That crashed on_exit
      # itself, with no assertion in the test body ever failing -- the shape
      # that reddened PR #866's CI run (ISS-0446.yaml) while passing cleanly
      # every time locally. That deleted shape is not re-enacted here (that
      # would test ExUnit's/OTP's own on_exit and link-teardown behaviour, not
      # anything Letflow owns, and the deleted shape no longer exists anywhere
      # in this file for such a test to regress against).
      #
      # WHAT THIS TEST ACTUALLY VERIFIES, narrowed after measurement
      # (TEST-DESIGNER rework 2 of 3; see test/specs/ISS-0446.md's second
      # REVISION NOTE for the full correction): this suite's own fixture
      # idiom for a throwaway per-test supervisor --
      # `ExUnit.fetch_test_supervisor/0` + `start_supervised!/1`, with NO
      # `on_exit` callback of any kind -- tears down cleanly even under a
      # DELIBERATELY WIDENED shutdown window. That is all it verifies. It
      # does NOT verify, and must not be read as verifying, that nobody can
      # reintroduce a check-then-act `on_exit` guard at the actual fix site
      # (the test directly above this one) -- an earlier version of this
      # comment claimed exactly that, and TEST-DESIGN-VALIDATOR measured it
      # false: reintroducing the deleted pattern at the fix site itself, with
      # this test left untouched, was caught by the full file's own run in
      # only 2 of 15 attempts (~13%), because this test exercises a wholly
      # separate synthetic fixture (`SlowTrapChild`, below) and never touches
      # the fix site's own code path. A reintroduction there is NOT reliably
      # caught by this test, or by any other test in this suite -- see
      # test/specs/ISS-0446.md for that residual gap stated plainly.
      #
      # `SlowTrapChild` traps exits and sleeps 5ms in `terminate/2` specifically
      # to widen that window on demand -- deliberately, not incidentally. This
      # is necessary: the real `Poller` neither traps exits nor does any slow
      # work in `terminate/2`, so it would not exercise this window at all (this
      # is exactly why the test above uses the real Poller for its own
      # `which_children/1` proof, and this test uses a synthetic child for its
      # different, timing-shaped proof -- the two tests are not redundant).
      # Trapping exits is what makes the widened window -- and therefore this
      # test's discriminating power over ITS OWN fixture -- deterministic
      # rather than merely likely: verified locally, 10/10 runs, that the OLD
      # deleted on_exit-guarded shape crashes on EVERY run under this exact
      # harness (not just some runs), and 10/10 runs that today's shipped
      # fixture idiom stays clean. That asymmetry is what makes this a
      # reliable test of the idiom itself -- a probabilistic version of this
      # same test would be worse than no test at all in a suite that already
      # carries two documented CI-flake sources (ISS-0352, ISS-0426).
      {:ok, sup} = ExUnit.fetch_test_supervisor()
      pid = start_supervised!({Iss0446RegressionGuard.SlowTrapChild, []})

      children = Supervisor.which_children(sup)

      assert [{Iss0446RegressionGuard.SlowTrapChild, ^pid, :worker, _modules}] = children
      assert is_pid(pid)
      assert Process.alive?(pid)
      # No on_exit callback here either, on purpose -- see the test's own
      # comment above. If teardown ever crashes, ExUnit attributes the
      # failure to THIS test -- which discriminates a regression in THIS
      # FIXTURE IDIOM ITSELF (see the scope note above for what that does
      # and does not cover).
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0946 -- SERVICE_TASK outbound-request audit (design
  # lib/letflow/design/iss0946-service-task-audit-decision.md §3.6). One
  # Letflow.Audit entry (action "service_task.outbound_request_sent") per
  # genuine outbound attempt, written strictly after attempt_dispatch/2's own
  # Repo.transaction/1 has returned.
  # ---------------------------------------------------------------------------------

  describe "ISS-0946 -- service_task.outbound_request_sent audit" do
    defp audit_rows_for(schema_name, action) do
      Entry
      |> where([e], e.action == ^action)
      |> order_by([e], asc: e.timestamp)
      |> Repo.all(prefix: schema_name)
    end

    setup do
      Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
      on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)
      :ok
    end

    test "1. happy path emits exactly one audit row per attempt" do
      %{url: server_url} = WebhookTestServer.start(200, ~s({"result":"ok"}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      rendered_body = ~s({"reason":"sla_breach_30_days","review_id":"rev-1"})

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{"rendered_url" => server_url, "rendered_body" => rendered_body})
        })

      assert {:ok, {:advance, _decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert [entry] = audit_rows_for(schema_name, "service_task.outbound_request_sent")
      assert entry.resource_type == "instance"
      assert entry.resource_id == instance_id
      assert entry.after_state["dispatch_id"] == dispatch.id
      assert entry.after_state["node_id"] == dispatch.node_id
      assert entry.after_state["attempt_index"] == 0
      assert entry.after_state["route_kind"] == "inline_url"
      assert entry.after_state["method"] == "POST"
      assert entry.after_state["rendered_url"] == server_url
      assert entry.after_state["request_body_preview"] =~ "sla_breach_30_days"
    end

    test "2. :request_build_error writes no audit row (SSRF-blocked and malformed-snapshot both)" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      # Gate back ON for this sub-case, deliberately -- the SSRF block itself
      # is what must produce :request_build_error here, not the test seam.
      Application.delete_env(:letflow, :service_task_ssrf_validation_enabled)

      blocked_dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{"rendered_url" => "https://169.254.169.254/latest/meta-data"})
        })

      assert {:ok, {:give_up, _error_attrs}} =
               ServiceTaskDispatcher.attempt_dispatch(blocked_dispatch.id, schema_name)

      malformed_dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: config_snapshot(%{"route_kind" => "bogus_route_kind"})
        })

      assert {:ok, {:give_up, _error_attrs}} =
               ServiceTaskDispatcher.attempt_dispatch(malformed_dispatch.id, schema_name)

      assert audit_rows_for(schema_name, "service_task.outbound_request_sent") == []
    end

    test "3. headers never appear in any audit row" do
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{
              "rendered_url" => server_url,
              "headers" => %{"Authorization" => "Bearer test-secret-value"}
            })
        })

      assert {:ok, {:advance, _decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert [entry] = audit_rows_for(schema_name, "service_task.outbound_request_sent")
      serialized = Jason.encode!(entry.after_state)
      refute serialized =~ "test-secret-value"
      refute serialized =~ "Authorization"
    end

    test "4. top-level JSON-key redaction replaces secret-shaped values, leaves others legible" do
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      rendered_body = ~s({"reason":"sla_breach_30_days","api_key":"super-secret-123"})

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{"rendered_url" => server_url, "rendered_body" => rendered_body})
        })

      assert {:ok, {:advance, _decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert [entry] = audit_rows_for(schema_name, "service_task.outbound_request_sent")
      preview = entry.after_state["request_body_preview"]
      assert preview =~ "[REDACTED]"
      assert preview =~ "sla_breach_30_days"
      refute preview =~ "super-secret-123"
    end

    test "4b. SECURITY-REVIEWER OQ-1 -- nested JSON secret is redacted, not just top-level" do
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      rendered_body = Jason.encode!(%{"data" => %{"api_key" => "sk-super-secret-123"}})

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{"rendered_url" => server_url, "rendered_body" => rendered_body})
        })

      assert {:ok, {:advance, _decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert [entry] = audit_rows_for(schema_name, "service_task.outbound_request_sent")
      preview = entry.after_state["request_body_preview"]
      assert preview =~ "[REDACTED]"
      refute preview =~ "sk-super-secret-123"
    end

    test "4c. SECURITY-REVIEWER OQ-2 -- non-JSON body with embedded credential is not persisted" do
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      rendered_body = "password=hunter2&client_id=svc-42"

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{"rendered_url" => server_url, "rendered_body" => rendered_body})
        })

      assert {:ok, {:advance, _decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert [entry] = audit_rows_for(schema_name, "service_task.outbound_request_sent")
      assert entry.after_state["request_body_preview"] == nil
      assert entry.after_state["request_body_present"] == true
      assert entry.after_state["request_body_byte_size"] == byte_size(rendered_body)
    end

    test "5. body preview is capped at 2000 codepoints, byte_size records the true original size" do
      %{url: server_url} = WebhookTestServer.start(200, ~s({"ok":true}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      rendered_body = Jason.encode!(%{"data" => String.duplicate("a", 2500)})

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot:
            config_snapshot(%{"rendered_url" => server_url, "rendered_body" => rendered_body})
        })

      assert {:ok, {:advance, _decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert [entry] = audit_rows_for(schema_name, "service_task.outbound_request_sent")
      assert entry.after_state["request_body_truncated"] == true
      assert String.length(entry.after_state["request_body_preview"]) == 2000
      assert entry.after_state["request_body_byte_size"] == byte_size(rendered_body)
    end

    test "6. retries each get their own audit row, one per attempt_index" do
      refused_url = WebhookTestServer.refused_url()
      %{url: server_url} = WebhookTestServer.start(200, ~s({"result":"ok"}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: config_snapshot(%{"rendered_url" => refused_url, "retry_limit" => 3})
        })

      assert {:ok, :retry_scheduled} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      # Swap the frozen rendered_url for the next attempt directly -- a real
      # activation-time caller (REQ-215) would never do this (the whole
      # point of freeze-at-INSERT is that it never changes), but this test
      # only needs attempt 2 to be a genuine, distinct outbound call that
      # succeeds, to prove each attempt gets its own audit row.
      ServiceTaskDispatch
      |> where([d], d.id == ^dispatch.id)
      |> Repo.update_all(
        [set: [config_snapshot: config_snapshot(%{"rendered_url" => server_url})]],
        prefix: schema_name
      )

      assert {:ok, {:advance, _decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      entries = audit_rows_for(schema_name, "service_task.outbound_request_sent")
      assert length(entries) == 2
      assert Enum.map(entries, & &1.after_state["attempt_index"]) |> Enum.sort() == [0, 1]
    end

    test "7a. a changeset-validation failure inside audit_outbound_request/2 is swallowed, never raises" do
      %{schema_name: schema_name} = provisioned_tenant()

      # Deliberately incomplete outbound_audit_context()-shaped map -- nil
      # instance_id becomes a nil resource_id, which Letflow.Audit.Entry's
      # own @required_fields rejects at the Ecto-changeset level, without
      # ever reaching Postgres. This class is not reachable through a real
      # dispatch row (every field do_attempt_dispatch/2 supplies is always
      # present and well-typed), so it is exercised directly here.
      context = %{
        dispatch_id: Ecto.UUID.generate(),
        instance_id: nil,
        node_id: "n1",
        attempt_index: 0,
        route_kind: :inline_url,
        method: :POST,
        rendered_url: "https://example.test/notice",
        rendered_body: nil
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = ServiceTaskDispatcher.audit_outbound_request(context, schema_name)
        end)

      assert log =~ "service_task.outbound_request_sent"
      assert audit_rows_for(schema_name, "service_task.outbound_request_sent") == []
    end

    test "7b. a genuine Postgres-level audit-insert failure never blocks the dispatch" do
      %{url: server_url} = WebhookTestServer.start(200, ~s({"result":"ok"}))

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = insert_instance_projection!(schema_name, :active)

      dispatch =
        insert_dispatch!(schema_name, instance_id, %{
          config_snapshot: config_snapshot(%{"rendered_url" => server_url})
        })

      Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {:advance, _decoded_body}} =
                   ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)
        end)

      assert log =~ "service_task.outbound_request_sent"

      reloaded = reload!(schema_name, dispatch.id)
      assert reloaded.status == :advanced
      assert reloaded.dispatched_at != nil
    end
  end
end

defmodule Iss0446RegressionGuard.SlowTrapChild do
  @moduledoc """
  Deliberately slow-to-terminate GenServer used only by the fixture-idiom
  teardown test above (originally added for ISS-0446), to widen the teardown
  window that a check-then-act `on_exit` guard would race against. Traps
  exits so that widening is deterministic (see that test's own comment for
  why) rather than merely probable.

  Module name kept as `Iss0446RegressionGuard` for historical/traceability
  reasons (this is where the module was first added), but per that test's
  own corrected scope note, it does not guard against a reintroduction of
  the check-then-act pattern at the ISS-0446 fix site itself -- only against
  a teardown regression in this suite's `fetch_test_supervisor/0` +
  `start_supervised!/1` fixture idiom in the abstract.

  Not a fixture for any other test -- kept file-local intentionally.
  """
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    Process.sleep(5)
    :ok
  end
end
