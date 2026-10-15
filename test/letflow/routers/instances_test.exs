defmodule Letflow.Routers.InstancesTest do
  @moduledoc """
  Tests for `Letflow.Routers.Instances`'s REQ-079 write routes (create/cancel/
  reconstruct). REQ-078's rebind-pins route is untouched and not retested
  here.

  Uses `Letflow.DataCase` (real Postgres) and `Letflow.TenantFixture`, same
  dispatch mechanism as `test/letflow/routers/tasks_test.exs` (direct
  `Letflow.Routers.Instances.call/2`, `conn.assigns[:auth_context]` set
  directly, bypassing `AuthPipeline`). `async: false` for the whole module --
  tenant provisioning/migration replay needs `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [where: 3, select: 3, from: 2]

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.Registration

  @opts Letflow.Routers.Instances.init([])

  # Same Plug.Parsers config as Letflow.Plugs.ApiPipeline -- needed by the
  # ISS-0788 multipart dispatch helpers below.
  @parsers_opts Plug.Parsers.init(
                  parsers: [:json, {:multipart, length: 26_214_400}],
                  json_decoder: Jason,
                  length: 2_097_152
                )

  defp build_conn(method, path, tenant, fields) do
    roles = Map.get(fields, :roles, [])
    user_id = Map.get(fields, :user_id, Ecto.UUID.generate())
    body = Map.get(fields, :body, nil)

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body}
        |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Instances.call(conn, @opts)

  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp unique_name(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp active_definition!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name("req079-def"),
                 version: "1.0.0",
                 graph: graph_human_task_end(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp start_instance!(schema_name, overrides \\ %{}) do
    definition = active_definition!(schema_name)

    attrs =
      Map.merge(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique_idempotency_key("start")
        },
        overrides
      )

    assert {:ok, result} = Engine.create(attrs, prefix: schema_name)
    {result.instance_id, definition}
  end

  defp instance_status(schema_name, instance_id) do
    Repo.get!(InstanceProjection, instance_id, prefix: schema_name).status
  end

  defp instance_count(schema_name) do
    Repo.aggregate(InstanceProjection, :count, prefix: schema_name)
  end

  # ISS-0389: START -> TIMER -> END -- gives an instance exactly one real,
  # armed, force-fireable pending timer the moment it's created (REQ-187's
  # engine automatically arms a :TIMER node's timer on token arrival), for
  # POST /:id/advance-timer's own router-level tests below. "P1D" keeps it
  # far from its own `fire_at` so nothing but this file's explicit
  # advance-timer calls ever fires it.
  defp graph_timer_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "timer",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P1D"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "timer"},
        %{"id" => "e2", "source" => "timer", "target" => "end"}
      ]
    }
  end

  defp start_instance_with_timer!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name("req-advtimer-def"),
                 version: "1.0.0",
                 graph: graph_timer_end(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: activated.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_idempotency_key("advtimer-start")
               },
               prefix: schema_name
             )

    result.instance_id
  end

  defp pending_timer_ids(schema_name, instance_id) do
    Timer
    |> where([t], t.instance_id == ^instance_id and t.status == "pending")
    |> select([t], t.id)
    |> Repo.all(prefix: schema_name)
  end

  # ── AC1 -- POST /instances creates via Engine, 201 with instance id ───────

  describe "AC1 -- create" do
    test "with definition_id returns 201 with instance_id, row exists" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac1a")
      definition = active_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{"definition_id" => definition.id, "initial_variables" => %{}}
        })
        |> dispatch()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ACTIVE"
      assert {:ok, _} = Ecto.UUID.cast(body["instance_id"])
      assert Repo.get!(InstanceProjection, body["instance_id"], prefix: tenant.schema_name)
    end

    test "with definition_name returns 201" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac1b")
      definition = active_definition!(tenant.schema_name)

      conn =
        build_conn("POST", "/", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{"definition_name" => definition.name, "initial_variables" => %{}}
        })
        |> dispatch()

      assert conn.status == 201
    end

    test "neither definition_id nor definition_name is 422" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac1c")

      conn =
        build_conn("POST", "/", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{"initial_variables" => %{}}
        })
        |> dispatch()

      assert conn.status == 422
    end

    test "unresolvable definition_id is 404" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac1d")

      conn =
        build_conn("POST", "/", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{"definition_id" => Ecto.UUID.generate(), "initial_variables" => %{}}
        })
        |> dispatch()

      assert conn.status == 404
    end
  end

  # ── AC2 -- correlation-key uniqueness (INV-8) ──────────────────────────────

  describe "AC2 -- correlation_key uniqueness" do
    test "duplicate correlation_key in the same tenant is 409, not 500" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac2a")
      definition = active_definition!(tenant.schema_name)
      key = unique_name("corr")

      body = %{
        "definition_id" => definition.id,
        "initial_variables" => %{},
        "correlation_key" => key
      }

      conn1 =
        build_conn("POST", "/", tenant, %{roles: ["PROCESS_OPERATOR"], body: body}) |> dispatch()

      assert conn1.status == 201

      conn2 =
        build_conn("POST", "/", tenant, %{roles: ["PROCESS_OPERATOR"], body: body}) |> dispatch()

      assert conn2.status == 409
    end

    test "the same correlation_key in two different tenants both succeed" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac2b")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac2c")
      definition_a = active_definition!(tenant_a.schema_name)
      definition_b = active_definition!(tenant_b.schema_name)
      key = unique_name("corr-cross-tenant")

      conn_a =
        build_conn("POST", "/", tenant_a, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{
            "definition_id" => definition_a.id,
            "initial_variables" => %{},
            "correlation_key" => key
          }
        })
        |> dispatch()

      conn_b =
        build_conn("POST", "/", tenant_b, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{
            "definition_id" => definition_b.id,
            "initial_variables" => %{},
            "correlation_key" => key
          }
        })
        |> dispatch()

      assert conn_a.status == 201
      assert conn_b.status == 201
    end
  end

  # ── AC3 -- cross-tenant cancel/reconstruct is the SAME 404 as absent ──────

  describe "AC3 -- cross-tenant is the same 404 as nonexistent, state unchanged" do
    test "cancel against another tenant's instance id is 404, target instance unchanged" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac3a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac3b")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      conn_absent =
        build_conn("POST", "/#{Ecto.UUID.generate()}/cancel", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      conn_cross =
        build_conn("POST", "/#{instance_id}/cancel", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn_absent.status == 404
      assert conn_cross.status == 404
      assert conn_absent.resp_body == conn_cross.resp_body
      assert instance_status(tenant_a.schema_name, instance_id) == :active
    end

    test "reconstruct against another tenant's instance id is 404, target instance unchanged" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac3c")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac3d")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      conn_absent =
        build_conn("POST", "/#{Ecto.UUID.generate()}/reconstruct", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      conn_cross =
        build_conn("POST", "/#{instance_id}/reconstruct", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn_absent.status == 404
      assert conn_cross.status == 404
      assert conn_absent.resp_body == conn_cross.resp_body
      assert instance_status(tenant_a.schema_name, instance_id) == :active
    end
  end

  # ── AC4 -- permission denial leaves state unchanged, not just the 403 ─────

  describe "AC4 -- permission gating" do
    test "caller without InstancesStart cannot create, no row inserted" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac4a")
      definition = active_definition!(tenant.schema_name)
      before_count = instance_count(tenant.schema_name)

      conn =
        build_conn("POST", "/", tenant, %{
          roles: ["TASK_WORKER"],
          body: %{"definition_id" => definition.id, "initial_variables" => %{}}
        })
        |> dispatch()

      assert conn.status == 403
      assert instance_count(tenant.schema_name) == before_count
    end

    test "caller without InstancesCancel cannot cancel, instance state unchanged" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac4b")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/cancel", tenant, %{roles: ["PROCESS_DESIGNER"]})
        |> dispatch()

      assert conn.status == 403
      assert instance_status(tenant.schema_name, instance_id) == :active
    end
  end

  # ── AC5 -- no Repo/transition call in REQ-079's own write handlers ─────────

  describe "AC5 -- structural" do
    # Scoped to REQ-079's own handle_create/2, handle_cancel/2,
    # handle_reconstruct/2 (each mutates instance state and must delegate
    # through Letflow.Engine, never touch Repo/Transition directly) rather
    # than the whole file, since REQ-212 (a later, unrelated capability
    # sharing this router module) legitimately added a direct
    # `Repo.get(Letflow.Repository.Artifact, ...)` call in its own
    # byte-content GET handler -- see that handler's own design
    # (lib/letflow/design/req212-instance-attachments-routes.md §4), which
    # requires exactly this second lookup and was reviewed/approved with it.
    # A whole-file grep would now always fail regardless of whether
    # REQ-079's own write-delegation invariant still holds, defeating the
    # point of this check -- narrowed instead of removed, so it still
    # catches a REQ-079 write handler regressing back to a direct Repo call.
    test "REQ-079's create/cancel/reconstruct handlers contain no Repo or Transition call" do
      source = File.read!("lib/letflow/routers/instances.ex")

      write_handlers =
        Regex.run(
          ~r/# ── POST \/instances\/:id\/rebind-pins.*?# ── GET \/instances\/:id \(design/s,
          source
        )
        |> List.first()

      refute write_handlers =~ ~r/\bRepo\./
      refute write_handlers =~ ~r/\bTransition\./
    end
  end

  # ── AC6 -- cancelling a terminal instance ──────────────────────────────────

  describe "AC6 -- cancelling a terminal or error-status instance" do
    test "cancelling an already-CANCELLED instance is 409" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac6a")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn1 =
        build_conn("POST", "/#{instance_id}/cancel", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn1.status == 200

      conn2 =
        build_conn("POST", "/#{instance_id}/cancel", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn2.status == 409
    end

    test "cancelling an already-COMPLETED instance is 409" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac6b")
      definition = active_definition!(tenant.schema_name)

      # A graph with no HUMAN_TASK node completes immediately on create.
      immediate_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
      }

      assert {:ok, immediate_def} =
               Definitions.create(
                 %{
                   name: unique_name("req079-immediate"),
                   version: "1.0.0",
                   graph: immediate_graph,
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: tenant.schema_name
               )

      assert {:ok, %{definition: activated}} =
               Definitions.activate(immediate_def.id, prefix: tenant.schema_name)

      assert {:ok, result} =
               Engine.create(
                 %{
                   definition_id: activated.id,
                   initial_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_idempotency_key("immediate")
                 },
                 prefix: tenant.schema_name
               )

      assert result.status == :completed
      _ = definition

      conn =
        build_conn("POST", "/#{result.instance_id}/cancel", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 409
    end

    test "cancelling an :error-status instance succeeds (not terminal)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-ac6c")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      projection = Repo.get!(InstanceProjection, instance_id, prefix: tenant.schema_name)

      projection
      |> InstanceProjection.update_changeset(%{
        status: :error,
        last_event_seq: projection.last_event_seq
      })
      |> Repo.update!(prefix: tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/cancel", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
    end
  end

  # ── Reconstruct (route-level correctness, not separately ACed) ────────────

  describe "reconstruct" do
    test "reconstructing a real instance returns 200 with matching tokens/variables/status" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-recon-a")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/reconstruct", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["instance_id"] == instance_id
      assert body["status"] == "ACTIVE"
      assert [%{"node_id" => "task", "branch_id" => _}] = body["tokens"]
      assert body["variables"] == %{}
    end

    test "reconstructing a nonexistent instance is 404" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-recon-b")

      conn =
        build_conn("POST", "/#{Ecto.UUID.generate()}/reconstruct", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 404
    end

    # REQ-131 closed this route's previously-wholly-open authorization gap
    # (see this file's own moduledoc/lib/letflow/routers/instances.ex's
    # "Authorization gap" comment on the route declaration) -- it now
    # requires :InstancesCancel, the same permission POST /:id/cancel
    # already requires, reusing an existing endpoint_policy_key() atom
    # directly (not via Authorization.endpoint_policy_key/2, which has no
    # clause for this path -- see test/letflow/api/authorization_enforcement_test.exs's
    # allowlist). This supersedes this test's own former, now-stale name
    # and 200 assertion for a no-roles caller.
    test "reconstruct requires :InstancesCancel -- a caller with no roles is denied 403" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-recon-c")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/reconstruct", tenant, %{roles: []})
        |> dispatch()

      assert conn.status == 403
    end

    test "reconstruct requires :InstancesCancel -- TASK_WORKER (holds neither InstancesCancel-granting role) is denied 403" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req079-recon-d")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/reconstruct", tenant, %{roles: ["TASK_WORKER"]})
        |> dispatch()

      assert conn.status == 403
    end

    # GH #2595: an instance that ran an HTTP SERVICE_TASK to :advance used to fail replay
    # with {:unrecognized_event_type, "SERVICE_TASK_COMPLETED", _}.
    test "reconstructing an instance past an HTTP service task returns 200 with the merged response body" do
      Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
      on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)
      %{url: server_url} = Letflow.WebhookTestServer.start(200, ~s({"approved":true}))

      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2595-recon")
      schema_name = tenant.schema_name

      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "svc",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"endpoint" => server_url, "timeout_ms" => 5_000}
          },
          %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "svc"},
          %{"id" => "e2", "source" => "svc", "target" => "task"},
          %{"id" => "e3", "source" => "task", "target" => "end"}
        ]
      }

      assert {:ok, definition} =
               Definitions.create(
                 %{
                   name: unique_name("gh2595-def"),
                   version: "1.0.0",
                   graph: graph,
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      assert {:ok, %{definition: activated}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert {:ok, %{instance_id: instance_id}} =
               Engine.create(
                 %{
                   definition_id: activated.id,
                   initial_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_idempotency_key("gh2595-start")
                 },
                 prefix: schema_name
               )

      [row] =
        Repo.all(
          from(d in Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch,
            where: d.instance_id == ^instance_id
          ),
          prefix: schema_name
        )

      assert {:ok, {:advance, decoded_body}} =
               Letflow.Engine.ServiceTaskDispatcher.attempt_dispatch(row.id, schema_name)

      assert {:ok, :advanced} =
               Engine.advance_after_service_task_outcome(
                 row.id,
                 {:advance, decoded_body},
                 Repo,
                 schema_name
               )

      conn =
        build_conn("POST", "/#{instance_id}/reconstruct", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["instance_id"] == instance_id
      assert body["status"] == "ACTIVE"
      assert [%{"node_id" => "task"}] = body["tokens"]
      assert body["variables"] == %{"approved" => true}
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # ISS-0389 -- POST /instances/:id/advance-timer
  # (lib/letflow/design/iss0389-advance-timer-endpoint.md, AC5-AC9)
  # ══════════════════════════════════════════════════════════════════════

  describe "advance-timer" do
    # AC5
    test "empty JSON body against an instance with exactly one pending timer returns 200, fires it, and the token moves off the TIMER node" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0389-advt-a")
      instance_id = start_instance_with_timer!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/advance-timer", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{}
        })
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["instance_id"] == instance_id
      assert body["node_id"] == "timer"
      assert body["timer_status"] == "fired"

      # end-to-end proof the timer firing actually drove the token off the
      # TIMER node: START -> TIMER -> END means firing completes the instance.
      assert instance_status(tenant.schema_name, instance_id) == :completed
      assert pending_timer_ids(tenant.schema_name, instance_id) == []
    end

    # AC6
    test "an instance with zero pending timers returns 404" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0389-advt-b")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/advance-timer", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{}
        })
        |> dispatch()

      assert conn.status == 404
    end

    # AC7
    test "no timer_id against an instance with two or more pending timers returns 400" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0389-advt-c")
      instance_id = start_instance_with_timer!(tenant.schema_name)

      assert {:ok, _timer2} =
               Scheduler.create(
                 Repo,
                 %{
                   instance_id: instance_id,
                   timer_type: "deadline",
                   node_id: "extra-timer",
                   fire_at:
                     DateTime.utc_now()
                     |> DateTime.add(3600, :second)
                     |> DateTime.truncate(:microsecond)
                 },
                 prefix: tenant.schema_name
               )

      conn =
        build_conn("POST", "/#{instance_id}/advance-timer", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{}
        })
        |> dispatch()

      assert conn.status == 400
      assert length(pending_timer_ids(tenant.schema_name, instance_id)) == 2
    end

    # AC8
    test "a timer_id naming a real pending timer belonging to a DIFFERENT instance returns 404, not a cross-instance fire" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0389-advt-d")
      instance_a = start_instance_with_timer!(tenant.schema_name)
      instance_b = start_instance_with_timer!(tenant.schema_name)
      [timer_b_id] = pending_timer_ids(tenant.schema_name, instance_b)

      conn =
        build_conn("POST", "/#{instance_a}/advance-timer", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{"timer_id" => timer_b_id}
        })
        |> dispatch()

      assert conn.status == 404
      assert pending_timer_ids(tenant.schema_name, instance_a) != []
      assert pending_timer_ids(tenant.schema_name, instance_b) != []
    end

    # AC9
    test "a syntactically invalid instance_id returns 422" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0389-advt-e")

      conn =
        build_conn("POST", "/not-a-uuid/advance-timer", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{}
        })
        |> dispatch()

      assert conn.status == 422
    end

    # AC9
    test "a syntactically invalid timer_id returns 422" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0389-advt-f")
      instance_id = start_instance_with_timer!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/advance-timer", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: %{"timer_id" => "not-a-uuid"}
        })
        |> dispatch()

      assert conn.status == 422
      assert pending_timer_ids(tenant.schema_name, instance_id) != []
    end

    # design §4's "request body present but not a JSON object" -> 400
    test "a request body that decodes to something other than a JSON object returns 400" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0389-advt-g")
      instance_id = start_instance_with_timer!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/advance-timer", tenant, %{
          roles: ["PROCESS_OPERATOR"],
          body: ["not", "an", "object"]
        })
        |> dispatch()

      assert conn.status == 400
      assert pending_timer_ids(tenant.schema_name, instance_id) != []
    end

    # Authorization wiring (design §5) -- :InstancesAdvanceTimer, not granted
    # to TASK_WORKER. The generic route-walk in
    # test/letflow/api/authorization_enforcement_test.exs already proves the
    # declared policy key resolves correctly (AC4); this proves the router
    # actually enforces it end to end and that a denied caller fires nothing.
    test "a caller without InstancesAdvanceTimer is denied 403, and the timer is not fired" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0389-advt-h")
      instance_id = start_instance_with_timer!(tenant.schema_name)

      conn =
        build_conn("POST", "/#{instance_id}/advance-timer", tenant, %{
          roles: ["TASK_WORKER"],
          body: %{}
        })
        |> dispatch()

      assert conn.status == 403
      assert pending_timer_ids(tenant.schema_name, instance_id) != []
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-080 -- read routes (get_by_id/list/history/timeline/pins)
  # ══════════════════════════════════════════════════════════════════════

  # ── AC1 -- each of the five handlers, end-to-end ───────────────────────

  describe "AC1 -- five read endpoints" do
    test "GET /:id returns the instance shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac1a")
      {instance_id, definition} = start_instance!(tenant.schema_name)

      conn =
        build_conn("GET", "/#{instance_id}", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["instance_id"] == instance_id
      assert body["definition_id"] == definition.id
      assert body["status"] == "ACTIVE"
      assert is_map(body["variables"])
      assert is_binary(body["started_at"])
    end

    test "GET / returns a page envelope" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac1b")
      {_instance_id, _def} = start_instance!(tenant.schema_name)

      conn = build_conn("GET", "/", tenant, %{roles: ["PROCESS_OPERATOR"]}) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["items"])
      assert body["count"] == length(body["items"])
      assert Map.has_key?(body, "next_cursor")
    end

    test "GET /:id/history returns the INSTANCE_STARTED event" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac1c")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("GET", "/#{instance_id}/history", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert [%{"event_type" => "INSTANCE_STARTED"} | _] = body["items"]
      # ISS-0918 M1: actor keys are always present on history items.
      assert Enum.all?(
               body["items"],
               &(Map.has_key?(&1, "actor_id") and Map.has_key?(&1, "actor_display_name"))
             )
    end

    test "GET /:id/timeline returns a lighter per-event projection" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac1d")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      conn =
        build_conn("GET", "/#{instance_id}/timeline", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert [%{"event_type" => "INSTANCE_STARTED", "sequence_num" => _} = item | _] =
               body["items"]

      # REQ-200: actor_display_name/description are now always present and
      # non-blank (design §2/§3) -- see the dedicated REQ-200 describe block
      # below for the full fallback-chain/rendering coverage.
      assert is_binary(item["actor_display_name"])
      refute String.trim(item["actor_display_name"]) == ""
      assert is_binary(item["description"])
      refute String.trim(item["description"]) == ""
    end

    test "GET /:id/pins returns the effective pin set" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac1e")
      {instance_id, definition} = start_instance!(tenant.schema_name)
      definition_name = definition.name

      conn =
        build_conn("GET", "/#{instance_id}/pins", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["instance_id"] == instance_id

      assert [%{"kind" => "variable_schema", "ref" => ^definition_name, "source" => "resolved"}] =
               body["pins"]
    end
  end

  # ── AC2 -- pagination completeness (list/history/timeline) ─────────────

  describe "AC2 -- pagination completeness" do
    test "list: every row exactly once across three pages, no dup, no gap" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac2a")
      ids = for _ <- 1..5, do: elem(start_instance!(tenant.schema_name), 0)

      {page1, cursor1} = fetch_list_page(tenant, "?page_size=2")
      {page2, cursor2} = fetch_list_page(tenant, "?page_size=2&cursor=#{cursor1}")
      {page3, cursor3} = fetch_list_page(tenant, "?page_size=2&cursor=#{cursor2}")

      assert length(page1) == 2
      assert length(page2) == 2
      assert length(page3) == 1
      assert cursor3 == nil

      seen = Enum.map(page1 ++ page2 ++ page3, & &1["instance_id"])
      assert Enum.sort(seen) == Enum.sort(ids)
      assert length(Enum.uniq(seen)) == length(seen)
    end

    test "history: every event exactly once across three pages, no dup, no gap" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac2b")
      {instance_id, _def} = start_instance!(tenant.schema_name)
      cancel_instance!(tenant.schema_name, instance_id)

      all_seqs = fetch_all_history_seqs(tenant, instance_id, 1)

      # At least INSTANCE_STARTED + INSTANCE_CANCELLED -- walked one page at
      # a time (page_size=1) so every page boundary is exercised.
      assert length(all_seqs) >= 2
      assert length(Enum.uniq(all_seqs)) == length(all_seqs)
      assert all_seqs == Enum.sort(all_seqs)
    end

    test "timeline: every event exactly once across three pages, no dup, no gap" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac2c")
      {instance_id, _def} = start_instance!(tenant.schema_name)
      cancel_instance!(tenant.schema_name, instance_id)

      all_seqs = fetch_all_timeline_seqs(tenant, instance_id, 1)

      assert length(all_seqs) >= 2
      assert length(Enum.uniq(all_seqs)) == length(all_seqs)
      assert all_seqs == Enum.sort(all_seqs)
    end
  end

  # ── AC3 -- cross-tenant is the same response as nonexistent (INV-5) ────

  describe "AC3 -- cross-tenant is the same as nonexistent" do
    test "get: cross-tenant id and nonexistent id both 404" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3a1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3a2")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/#{instance_id}", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/#{Ecto.UUID.generate()}", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end

    test "history: cross-tenant id and nonexistent id both 404" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3b1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3b2")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/#{instance_id}/history", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/#{Ecto.UUID.generate()}/history", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end

    test "timeline: cross-tenant id and nonexistent id both 404" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3c1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3c2")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/#{instance_id}/timeline", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/#{Ecto.UUID.generate()}/timeline", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end

    test "pins: cross-tenant id and nonexistent id both 404" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3d1")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac3d2")
      {instance_id, _def} = start_instance!(tenant_a.schema_name)

      cross =
        build_conn("GET", "/#{instance_id}/pins", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      absent =
        build_conn("GET", "/#{Ecto.UUID.generate()}/pins", tenant_b, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert cross.status == 404
      assert absent.status == 404
      assert cross.resp_body == absent.resp_body
    end
  end

  # ── AC4 -- list filter returns only the calling tenant's rows (INV-1) ──

  describe "AC4 -- tenant isolation on filters" do
    test "same correlation_key value seeded in two tenants: each list sees only its own" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac4a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac4b")
      key = unique_name("shared-corr")

      {id_a, _} = start_instance!(tenant_a.schema_name, %{correlation_key: key})
      {id_b, _} = start_instance!(tenant_b.schema_name, %{correlation_key: key})

      {items_a, _} = fetch_list_page(tenant_a, "?correlation_key=#{key}")
      {items_b, _} = fetch_list_page(tenant_b, "?correlation_key=#{key}")

      assert Enum.map(items_a, & &1["instance_id"]) == [id_a]
      assert Enum.map(items_b, & &1["instance_id"]) == [id_b]
    end
  end

  # ── AC5 -- SQL-metacharacter filter is inert (INV-7) ────────────────────

  describe "AC5 -- filter values are literal, not SQL" do
    test "a correlation_key filter containing SQL metacharacters matches zero rows, no crash" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac5a")
      {_instance_id, _def} = start_instance!(tenant.schema_name)

      malicious = URI.encode_www_form("'; DROP TABLE instance_projections; --")

      conn =
        build_conn("GET", "/?correlation_key=#{malicious}", tenant, %{
          roles: ["PROCESS_OPERATOR"]
        })
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["items"] == []
      # table still present -- a second, ordinary list still works
      assert instance_count(tenant.schema_name) == 1
    end

    test "no raw SQL fragment is used anywhere in this requirement's code" do
      refute File.read!("lib/letflow/instances.ex") =~ "fragment("
      refute File.read!("lib/letflow/routers/instances.ex") =~ "fragment("
    end
  end

  # ── AC6 -- 403 without InstancesRead, on all five endpoints ─────────────

  describe "AC6 -- permission required on every read endpoint" do
    test "AGENT_RUNNER (no InstancesRead) gets 403 on all five" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req080-ac6a")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      for path <- [
            "/",
            "/#{instance_id}",
            "/#{instance_id}/history",
            "/#{instance_id}/timeline",
            "/#{instance_id}/pins"
          ] do
        conn = build_conn("GET", path, tenant, %{roles: ["AGENT_RUNNER"]}) |> dispatch()
        assert conn.status == 403, "expected 403 for #{path}, got #{conn.status}"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-399 -- GET /:id/pins issues no new catalog/module reads
  # ══════════════════════════════════════════════════════════════════════

  # ── AC2 -- pure read of the already-computed effective pin set ─────────
  #
  # Design doc (lib/letflow/design/req399-instance-pin-provenance.md §1.4)
  # points at REQ-200's own AC7 telemetry test (below, "REQ-200 -- actor
  # display name and description rendering" describe block,
  # `handle_req200_users_query_telemetry/4`) as the precedent for this exact
  # pattern: a named (not anonymous) `:telemetry.attach/4` handler on
  # `[:letflow, :repo, :query]`, filtered to this test's own process and to
  # the table names under test via `metadata.source`, detached in an
  # `after` block around the dispatch call (this router test module already
  # uses `Letflow.DataCase`'s real-Postgres sandbox, so no separate
  # `on_exit` is needed beyond the `after`/`try` already used by the
  # REQ-200 precedent).
  #
  # `PinResolver.reconstruct_effective_pins/2` accepts no `Lookup.t()`
  # parameter at all (pin_resolver.ex moduledoc, design §0/§1.2) -- it reads
  # only the instance's own event log via `Reconstruction.read_full_log/3`.
  # This test proves that property holds for the route's actual request
  # path, not just by reading the function signature: no `Repo` query
  # fired during this request names `service_catalog`, its version table,
  # or the variable-schema registration table.
  describe "REQ-399 AC2 -- pins route issues no catalog/module reads" do
    test "GET /:id/pins fires no Repo query against service_catalog or module/variable-schema tables" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req399-ac2a")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      test_pid = self()
      handler_id = {:req399_ac2_telemetry, make_ref()}

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        &__MODULE__.handle_req399_pins_query_telemetry/4,
        test_pid
      )

      conn =
        try do
          build_conn("GET", "/#{instance_id}/pins", tenant, %{roles: ["PROCESS_OPERATOR"]})
          |> dispatch()
        after
          :telemetry.detach(handler_id)
        end

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["instance_id"] == instance_id
      assert [%{"kind" => "variable_schema", "source" => "resolved"}] = body["pins"]

      catalog_or_module_sources =
        Stream.repeatedly(fn ->
          receive do
            {:req399_pins_query_source, source} -> {:hit, source}
          after
            0 -> :done
          end
        end)
        |> Enum.take_while(&(&1 != :done))
        |> Enum.map(fn {:hit, source} -> source end)

      assert catalog_or_module_sources == [],
             "expected zero Repo queries against service_catalog/module tables for " <>
               "GET /:id/pins, got queries against: #{inspect(catalog_or_module_sources)}"
    end
  end

  # Named (not anonymous) telemetry handler, matching REQ-200's own
  # `handle_req200_users_query_telemetry/4` precedent immediately below --
  # `[:letflow, :repo, :query]` is a single node-global event name, so the
  # handler filters to this test's own process before forwarding, and
  # further filters to the catalog/module-registry table names this AC
  # asserts are never queried by this route.
  def handle_req399_pins_query_telemetry(_event, _measurements, metadata, test_pid) do
    if self() == test_pid and
         metadata.source in ["service_catalog", "service_catalog_versions", "variable_schemas"] do
      send(test_pid, {:req399_pins_query_source, metadata.source})
    end
  end

  # ── REQ-080 test helpers ─────────────────────────────────────────────

  defp cancel_instance!(schema_name, instance_id) do
    assert {:ok, _} =
             Engine.cancel_instance(
               instance_id,
               %{
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_idempotency_key("cancel")
               },
               prefix: schema_name
             )
  end

  defp fetch_list_page(tenant, query_suffix) do
    conn =
      build_conn("GET", "/#{query_suffix}", tenant, %{roles: ["PROCESS_OPERATOR"]}) |> dispatch()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    {body["items"], body["next_cursor"]}
  end

  defp fetch_all_history_seqs(tenant, instance_id, page_size),
    do: fetch_all_seqs(tenant, "/#{instance_id}/history", page_size, "sequence_number")

  defp fetch_all_timeline_seqs(tenant, instance_id, page_size),
    do: fetch_all_seqs(tenant, "/#{instance_id}/timeline", page_size, "sequence_num")

  defp fetch_all_seqs(tenant, path, page_size, seq_key),
    do: fetch_all_seqs(tenant, path, page_size, seq_key, nil, [])

  defp fetch_all_seqs(tenant, path, page_size, seq_key, cursor, acc) do
    query = "?page_size=#{page_size}" <> if cursor, do: "&cursor=#{cursor}", else: ""

    conn = build_conn("GET", path <> query, tenant, %{roles: ["PROCESS_OPERATOR"]}) |> dispatch()
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    seqs = Enum.map(body["items"], & &1[seq_key])
    acc = acc ++ seqs

    case body["next_cursor"] do
      nil -> acc
      next -> fetch_all_seqs(tenant, path, page_size, seq_key, next, acc)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-200 -- timeline actor display names and event-type descriptions
  # ══════════════════════════════════════════════════════════════════════

  defp insert_raw_event!(schema_name, attrs) do
    defaults = %{
      event_id: Ecto.UUID.generate(),
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      payload: %{},
      metadata: %{},
      idempotency_key: "req200-#{System.unique_integer([:positive, :monotonic])}"
    }

    changeset =
      Letflow.EventStore.Event.insert_changeset(
        %Letflow.EventStore.Event{},
        Map.merge(defaults, attrs)
      )

    assert {:ok, event} = Repo.insert(changeset, prefix: schema_name)
    event
  end

  defp create_named_user!(schema_name, display_name) do
    assert {:ok, user} =
             Letflow.Identity.create_user(
               %{
                 "username" => unique_name("req200-user"),
                 "display_name" => display_name,
                 "email" => "#{unique_name("req200")}@example.test"
               },
               prefix: schema_name,
               login_directory: :skip
             )

    user
  end

  defp fetch_timeline_items(tenant, instance_id, query_suffix \\ "") do
    conn =
      build_conn("GET", "/#{instance_id}/timeline#{query_suffix}", tenant, %{
        roles: ["PROCESS_OPERATOR"]
      })
      |> dispatch()

    assert conn.status == 200
    Jason.decode!(conn.resp_body)["items"]
  end

  describe "REQ-200 -- actor display name and description rendering" do
    test "AC1: every item over a 4+ event-type timeline has a non-blank actor_display_name and description" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req200-ac1")
      {instance_id, _def} = start_instance!(tenant.schema_name)
      cancel_instance!(tenant.schema_name, instance_id)

      insert_raw_event!(tenant.schema_name, %{
        instance_id: instance_id,
        event_type: "INSTANCE_PINS_REBOUND",
        payload: %{"reason" => "test"},
        actor_id: Ecto.UUID.generate(),
        sequence_number: 100
      })

      insert_raw_event!(tenant.schema_name, %{
        instance_id: instance_id,
        event_type: "TIMER_FIRED",
        payload: %{"timer_id" => "t1", "node_id" => "n1", "timer_type" => "duration"},
        actor_id: Letflow.EventStore.platform_actor_id(),
        sequence_number: 101
      })

      items = fetch_timeline_items(tenant, instance_id, "?page_size=50")
      assert length(items) >= 4

      event_types = Enum.map(items, & &1["event_type"]) |> Enum.uniq()
      assert length(event_types) >= 4

      for item <- items do
        assert is_binary(item["actor_display_name"])
        refute String.trim(item["actor_display_name"]) == ""
        assert is_binary(item["description"])
        refute String.trim(item["description"]) == ""
      end
    end

    # AC2 requires the four fallback levels to be "exercised ... by four
    # explicit tests" (docs/requirements.yaml REQ-200 AC2 wording) -- not one
    # combined test proving the chain end-to-end. Each test below isolates
    # exactly one level: it sets up ONLY the inputs relevant to that level
    # (never a higher-priority input that would mask a lower level, and never
    # a lower-priority fallback value that a passing assertion could be
    # coincidentally satisfied by).

    test "AC2 level 1: an event with a resolvable actor_id resolves to that user's display_name" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req200-ac2-l1")
      {instance_id, _def} = start_instance!(tenant.schema_name)
      user = create_named_user!(tenant.schema_name, "Ada Lovelace")

      insert_raw_event!(tenant.schema_name, %{
        instance_id: instance_id,
        event_type: "TASK_COMPLETED",
        payload: %{"task_id" => "task-1", "node_id" => "node-1"},
        actor_id: user.id,
        sequence_number: 10
      })

      items = fetch_timeline_items(tenant, instance_id, "?page_size=50")
      item = Enum.find(items, &(&1["task_id"] == "task-1"))
      assert item["actor_display_name"] == "Ada Lovelace"
    end

    test "AC2 level 2: no actor id, metadata token_description resolves to that" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req200-ac2-l2")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      insert_raw_event!(tenant.schema_name, %{
        instance_id: instance_id,
        event_type: "TASK_COMPLETED",
        payload: %{"task_id" => "task-2", "node_id" => "node-2"},
        actor_id: Ecto.UUID.generate(),
        metadata: %{"token_description" => "CI deploy token"},
        sequence_number: 11
      })

      items = fetch_timeline_items(tenant, instance_id, "?page_size=50")
      item = Enum.find(items, &(&1["task_id"] == "task-2"))
      assert item["actor_display_name"] == "CI deploy token"
    end

    test "AC2 level 3: no actor id and no token_description, metadata actor_label resolves to that" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req200-ac2-l3")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      insert_raw_event!(tenant.schema_name, %{
        instance_id: instance_id,
        event_type: "TASK_COMPLETED",
        payload: %{"task_id" => "task-3", "node_id" => "node-3"},
        actor_id: Ecto.UUID.generate(),
        metadata: %{"actor_label" => "External Webhook"},
        sequence_number: 12
      })

      items = fetch_timeline_items(tenant, instance_id, "?page_size=50")
      item = Enum.find(items, &(&1["task_id"] == "task-3"))
      assert item["actor_display_name"] == "External Webhook"
    end

    test "AC2 level 4: none of actor id, token_description, or actor_label -- falls to the literal \"system\"" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req200-ac2-l4")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      insert_raw_event!(tenant.schema_name, %{
        instance_id: instance_id,
        event_type: "TASK_COMPLETED",
        payload: %{"task_id" => "task-4", "node_id" => "node-4"},
        actor_id: Ecto.UUID.generate(),
        sequence_number: 13
      })

      items = fetch_timeline_items(tenant, instance_id, "?page_size=50")
      item = Enum.find(items, &(&1["task_id"] == "task-4"))
      assert item["actor_display_name"] == "system"
    end

    test "AC3: an event whose actor_id refers to a user row that no longer exists still falls through, never nil/error" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req200-ac3")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      # Genuinely a "row deleted" scenario, distinct from "no actor_id at
      # all" (AC2 level 4 above): deleted_user.id is a real, once-existent
      # user id that no longer has a matching row in `users` by the time the
      # timeline is fetched, exercising fetch_display_names_by_actor_id/2's
      # miss path rather than resolve_actor_display_name/3's nil-actor_id
      # branch.
      deleted_user = create_named_user!(tenant.schema_name, "Soon Deleted")
      Repo.delete!(deleted_user, prefix: tenant.schema_name)

      insert_raw_event!(tenant.schema_name, %{
        instance_id: instance_id,
        event_type: "TASK_COMPLETED",
        payload: %{"task_id" => "task-5", "node_id" => "node-5"},
        actor_id: deleted_user.id,
        sequence_number: 14
      })

      items = fetch_timeline_items(tenant, instance_id, "?page_size=50")
      item = Enum.find(items, &(&1["task_id"] == "task-5"))

      refute is_nil(item["actor_display_name"])
      assert item["actor_display_name"] == "system"
    end

    test "AC4: INSTANCE_STARTED and a task-completion item render different, actor-naming sentences" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req200-ac4")
      user = create_named_user!(tenant.schema_name, "Grace Hopper")
      {instance_id, _def} = start_instance!(tenant.schema_name, %{actor_id: user.id})

      insert_raw_event!(tenant.schema_name, %{
        instance_id: instance_id,
        event_type: "TASK_COMPLETED",
        payload: %{"task_id" => "task-9", "node_id" => "approve"},
        actor_id: user.id,
        sequence_number: 10
      })

      items = fetch_timeline_items(tenant, instance_id, "?page_size=50")
      started = Enum.find(items, &(&1["event_type"] == "INSTANCE_STARTED"))
      completed = Enum.find(items, &(&1["event_type"] == "TASK_COMPLETED"))

      assert started["description"] == "Instance started by Grace Hopper"
      assert completed["description"] == "Task approve completed by Grace Hopper"
      assert started["description"] != completed["description"]
    end

    test "AC5: an event type with no specific rendering gets a non-empty generic description" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req200-ac5")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      insert_raw_event!(tenant.schema_name, %{
        instance_id: instance_id,
        event_type: "TENANT_CUSTOM_LUA_EVENT",
        payload: %{"foo" => "bar"},
        actor_id: Ecto.UUID.generate(),
        metadata: %{"actor_label" => "Lua Script"},
        sequence_number: 10
      })

      items = fetch_timeline_items(tenant, instance_id, "?page_size=50")
      custom = Enum.find(items, &(&1["event_type"] == "TENANT_CUSTOM_LUA_EVENT"))

      assert custom["description"] == "Event TENANT_CUSTOM_LUA_EVENT by Lua Script"
      refute custom["description"] == ""
    end

    test "AC6: response field names match TimelineEntry -- timestamp and sequence_num present" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req200-ac6")
      {instance_id, _def} = start_instance!(tenant.schema_name)

      [item] = fetch_timeline_items(tenant, instance_id)

      expected_keys =
        ~w(event_type timestamp actor_display_name description instance_id event_id sequence_num task_id node_id metadata)

      for key <- expected_keys do
        assert Map.has_key?(item, key), "expected timeline item to have key #{key}"
      end

      refute Map.has_key?(item, "created_at")
      refute Map.has_key?(item, "sequence_number")
    end

    test "AC7: a page whose events share one actor issues at most one user-lookup query" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req200-ac7")
      user = create_named_user!(tenant.schema_name, "Shared Actor")
      {instance_id, _def} = start_instance!(tenant.schema_name, %{actor_id: user.id})

      for n <- 1..5 do
        insert_raw_event!(tenant.schema_name, %{
          instance_id: instance_id,
          event_type: "TASK_COMPLETED",
          payload: %{"task_id" => "task-#{n}", "node_id" => "node-#{n}"},
          actor_id: user.id,
          sequence_number: 10 + n
        })
      end

      test_pid = self()
      handler_id = {:req200_ac7_telemetry, make_ref()}

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        &__MODULE__.handle_req200_users_query_telemetry/4,
        test_pid
      )

      items =
        try do
          fetch_timeline_items(tenant, instance_id, "?page_size=50")
        after
          :telemetry.detach(handler_id)
        end

      # INSTANCE_STARTED + five TASK_COMPLETED, all sharing one actor.
      assert length(items) == 6

      user_query_count =
        Stream.repeatedly(fn ->
          receive do
            :req200_user_query -> :hit
          after
            0 -> :done
          end
        end)
        |> Enum.take_while(&(&1 == :hit))
        |> length()

      # Exactly one, not merely "at most one": with a real actor_id present
      # on every event, fetch_display_names_by_actor_id/2 (design SS4) always
      # issues its single batched query -- asserting == 1 (not <= 1) also
      # rules out a vacuous pass from a broken resolver that silently skips
      # the lookup altogether. A naive per-row implementation would issue 6
      # (one per event), which this assertion also catches.
      assert user_query_count == 1,
             "expected exactly one `users` lookup query for a page sharing one actor, got #{user_query_count}"
    end
  end

  # Named (not anonymous) telemetry handler, matching router_test.exs's own
  # ISS-0031 (GH#90) precedent -- [:letflow, :repo, :query] is a single
  # node-global event name, so the handler filters to this test's own
  # process before forwarding, and further filters to the `users` table so
  # unrelated queries in the same request don't inflate the count.
  def handle_req200_users_query_telemetry(_event, _measurements, metadata, test_pid) do
    if self() == test_pid and metadata.source == "users" do
      send(test_pid, :req200_user_query)
    end
  end

  # ── ISS-0788 regression ──────────────────────────────────────────────────────
  # render_upload_attachment/2 had no clause for {:error, :storage_quota_exceeded}
  # or {:error, :tenant_not_found}, so both crashed to a FunctionClauseError
  # 500 instead of a handled 4xx. These tests drive both paths through
  # POST /instances/:id/attachments end-to-end (real multipart parse, real
  # Plug.Parsers, real Attachments.upload/2), then assert the route returns the
  # correct 4xx rather than a 500.

  defp dispatch_multipart(method, path, tenant, roles, body, boundary) do
    conn(method, path, body)
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    |> Plug.Parsers.call(@parsers_opts)
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
    |> dispatch()
  end

  defp multipart_file_body(boundary, file_name, content_type, file_bytes) do
    "--#{boundary}\r\n" <>
      "Content-Disposition: form-data; name=\"file\"; filename=\"#{file_name}\"\r\n" <>
      "Content-Type: #{content_type}\r\n\r\n" <>
      file_bytes <>
      "\r\n" <>
      "--#{boundary}--\r\n"
  end

  describe "ISS-0788 regression: unhandled upload/2 error atoms must not crash to 500" do
    @tag :iss_0788
    test "over-quota upload returns 409, not FunctionClauseError 500" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0788-quota")

      # Set a 1-byte quota -- any upload will exceed it, triggering
      # Attachments.upload/2 to return {:error, :storage_quota_exceeded}.
      Repo.update_all(
        from(t in Tenant, where: t.id == ^tenant.tenant_id),
        set: [storage_allowance_bytes: 1]
      )

      conn =
        dispatch_multipart(
          :post,
          "/#{Ecto.UUID.generate()}/attachments",
          tenant,
          ["PROCESS_OPERATOR"],
          multipart_file_body("iss0788q", "doc.txt", "text/plain", "hello"),
          "iss0788q"
        )

      assert conn.status == 409
      assert conn.resp_body =~ "quota"
    end

    @tag :iss_0788
    test "upload when tenant row is absent returns 422, not FunctionClauseError 500" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "iss0788-norow")

      # Delete the Tenant row so check_storage_quota's Repo.get(Tenant, id)
      # returns nil, triggering {:error, :tenant_not_found} from upload/2.
      # Registration (tenant_schemas) must go first to satisfy its FK constraint.
      # The physical schema remains (DDL is not rolled back), so get_storage_usage
      # still executes normally before the nil lookup fires.
      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.tenant_id))

      conn =
        dispatch_multipart(
          :post,
          "/#{Ecto.UUID.generate()}/attachments",
          tenant,
          ["PROCESS_OPERATOR"],
          multipart_file_body("iss0788nt", "doc.txt", "text/plain", "hello"),
          "iss0788nt"
        )

      assert conn.status == 422
      assert conn.resp_body =~ "tenant"
    end
  end

  describe "GET /instances/storage-usage (REQ-392 design §1.2)" do
    test "returns 200 {used_bytes, allowance_bytes} for the caller's own tenant" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req392-usage")

      Repo.update_all(
        from(t in Tenant, where: t.id == ^tenant.tenant_id),
        set: [storage_allowance_bytes: 123_456]
      )

      conn =
        build_conn(:get, "/storage-usage", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["used_bytes"] == 0
      assert body["allowance_bytes"] == 123_456
    end

    test "used_bytes reflects a real upload for that tenant, tenant-scoped (not another tenant's usage)" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req392-usage-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req392-usage-b")

      upload_conn =
        dispatch_multipart(
          :post,
          "/#{Ecto.UUID.generate()}/attachments",
          tenant_a,
          ["PROCESS_OPERATOR"],
          multipart_file_body("req392u", "note.txt", "text/plain", "twelve bytes"),
          "req392u"
        )

      assert upload_conn.status == 201

      conn_a =
        build_conn(:get, "/storage-usage", tenant_a, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn_a.status == 200
      body_a = Jason.decode!(conn_a.resp_body)
      assert body_a["used_bytes"] == byte_size("twelve bytes")

      # Tenant B, who uploaded nothing, must see its own (zero) usage --
      # never tenant A's, confirming this route's tenant-scoping (INV-1).
      conn_b =
        build_conn(:get, "/storage-usage", tenant_b, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn_b.status == 200
      body_b = Jason.decode!(conn_b.resp_body)
      assert body_b["used_bytes"] == 0
    end

    test "returns 422 tenant_not_found when the tenant row is absent (same unreachable-but-mapped edge as ISS-0788's upload path)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req392-usage-norow")

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.tenant_id))

      conn =
        build_conn(:get, "/storage-usage", tenant, %{roles: ["PROCESS_OPERATOR"]})
        |> dispatch()

      assert conn.status == 422
      assert conn.resp_body =~ "tenant"
    end
  end
end
