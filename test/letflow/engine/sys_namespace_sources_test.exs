defmodule Letflow.Engine.SysNamespaceSourcesTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A1 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  2.2, D-A1.3..D-A1.7, D-A1.11, 8, 11 A1 "every external source"): every external variable
  source refuses (or, where the design says so, strips) a top-level reserved `_sys` key, each
  through its REAL path:

    1. HUMAN_TASK form output -- `Engine.complete_task/3` (retryable 422 refusal, nothing written)
    2. SERVICE_TASK HTTP body -- `ServiceTaskDispatcher` poll + `advance_after_service_task_outcome/4`
    3. sub-process OUTPUT -- (a) no interface: stripped; (b) explicit interface: parent ERROR
    4. sub-process child START -- stripped, with and without an interface
    5. process start -- `Engine.create/2` (nil schema and a resolved schema) and `POST /instances`
    6. script output -- the 7c route (`ScriptTaskDispatcher.run_claimed/2`)
    7. no admin variable-patch route exists (recorded grep of the routers)

  The engine writer of reserved values is PR B, so where a test needs an instance that ALREADY
  holds one (3a, 3b, 4) it writes the projection row directly -- the stand-in for that writer --
  and then drives the real completion / start path. Values are never asserted to appear in an
  error, audit row or log line.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.PinResolver.Lookup
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Registry.ValidationFailure
  alias Letflow.Support.ScriptTaskFixture, as: F
  alias Letflow.TenantFixture
  alias Letflow.WebhookTestServer

  @secret "SYS-SECRET-VALUE-4417"

  # ── fixtures ────────────────────────────────────────────────────────────────────────────────

  defp tenant(prefix), do: TenantFixture.provisioned_tenant!(slug_prefix: prefix)

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp active_definition!(schema, graph) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: uniq("gh2587"),
                 version: "1.0.0",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema
             )

    assert {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema)
    activated
  end

  defp start!(schema, definition, variables) do
    assert {:ok, %{instance_id: id}} =
             Engine.create(start_attrs(definition, variables, %{}), prefix: schema)

    id
  end

  defp start_attrs(definition, variables, extra) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: variables,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: uniq("start")
      },
      extra
    )
  end

  defp complete_attrs(output),
    do: %{output_variables: output, actor_id: Ecto.UUID.generate(), idempotency_key: uniq("c")}

  defp projection(schema, id), do: Repo.get!(InstanceProjection, id, prefix: schema)

  defp events_of_type(schema, id, type) do
    Event
    |> where([e], e.instance_id == ^id and e.event_type == ^type)
    |> Repo.all(prefix: schema)
  end

  defp pending_task!(schema, instance_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id and t.status == :pending)
    |> Repo.one!(prefix: schema)
  end

  defp audit_rows(schema, action) do
    Audit.Entry
    |> where([a], a.action == ^action)
    |> Repo.all(prefix: schema)
  end

  defp child_projection!(schema, parent_id) do
    InstanceProjection
    |> where([p], p.parent_instance_id == ^parent_id)
    |> Repo.one!(prefix: schema)
  end

  # Stand-in for PR B's engine writer: the instance already holds engine-written values.
  defp hold_engine_values!(schema, instance_id, values) do
    current = projection(schema, instance_id).variables

    {1, _} =
      InstanceProjection
      |> where([p], p.instance_id == ^instance_id)
      |> Repo.update_all([set: [variables: Map.merge(current, values)]], prefix: schema)

    :ok
  end

  defp human_task_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "r"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp service_task_graph(endpoint) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => endpoint, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # START -> gate(HUMAN_TASK) -> sp(SUB_PROCESS) -> after(HUMAN_TASK) -> END
  defp parent_graph(child_name, interface) do
    sp_attributes =
      if interface,
        do: %{"definition_name" => child_name, "interface" => interface},
        else: %{"definition_name" => child_name}

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gate", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "g"}},
        %{"id" => "sp", "node_type" => "SUB_PROCESS", "attributes" => sp_attributes},
        %{"id" => "after", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "a"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gate"},
        %{"id" => "e2", "source" => "gate", "target" => "sp"},
        %{"id" => "e3", "source" => "sp", "target" => "after"},
        %{"id" => "e4", "source" => "after", "target" => "end"}
      ]
    }
  end

  # Parent started and its `gate` completed, so the child is running. Returns ids.
  defp running_child!(schema, interface) do
    child_def = active_definition!(schema, human_task_graph())
    parent_def = active_definition!(schema, parent_graph(child_def.name, interface))
    parent_id = start!(schema, parent_def, %{"seed" => 1})
    gate = pending_task!(schema, parent_id)
    assert {:ok, _} = Engine.complete_task(gate.id, complete_attrs(%{}), prefix: schema)
    child = child_projection!(schema, parent_id)
    {parent_id, child.instance_id}
  end

  defp schema_lookup(json_schema) do
    %Lookup{
      catalog_lookup: fn _ref -> {:error, :not_found} end,
      module_lookup: fn _ref -> {:error, :not_found} end,
      variable_schema_lookup: fn _tenant_id, _process_key ->
        {:ok, %{version: "1.0.0", json_schema: json_schema}}
      end
    }
  end

  defp instance_count(schema), do: Repo.aggregate(InstanceProjection, :count, prefix: schema)

  defp sys_manifest do
    F.closed_manifest()
    |> put_in(["output_schema", "properties", "_sys.x"], %{"type" => "integer"})
  end

  defp enable_ssrf_bypass do
    Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
    on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)
  end

  # ── (1) HUMAN_TASK form output ──────────────────────────────────────────────────────────────

  describe "(1) HUMAN_TASK form output via Engine.complete_task/3" do
    test "a reserved key is a retryable output_refused naming the key only; nothing written; one audit row" do
      %{schema_name: schema} = tenant("gh2587-src-form")
      definition = active_definition!(schema, human_task_graph())
      id = start!(schema, definition, %{"seed" => 1})
      task = pending_task!(schema, id)
      before = projection(schema, id)

      result =
        Engine.complete_task(task.id, complete_attrs(%{"_sys.x" => @secret, "ok" => 1}),
          prefix: schema
        )

      assert result == {:error, {:output_refused, %{missing_keys: [], rejected_keys: ["_sys.x"]}}}
      refute inspect(result) =~ @secret

      assert Repo.get!(EngineTask, task.id, prefix: schema).status == :pending
      assert projection(schema, id) == before
      assert projection(schema, id).status == :active
      assert events_of_type(schema, id, "TASK_COMPLETED") == []
      assert events_of_type(schema, id, "EXECUTION_ERROR") == []

      assert [entry] = audit_rows(schema, "task.completion_refused")

      assert entry.after_state == %{
               "rule" => "output_refused",
               "instance_id" => id,
               "node_id" => "task",
               "missing_keys" => [],
               "rejected_keys" => ["_sys.x"]
             }

      refute inspect(entry, limit: :infinity) =~ @secret

      # retryable: the same task completes once the reserved key is gone
      assert {:ok, _} =
               Engine.complete_task(task.id, complete_attrs(%{"ok" => 1}), prefix: schema)

      assert projection(schema, id).variables == %{"seed" => 1, "ok" => 1}
    end

    test "the bare name and an atom key are refused the same way" do
      %{schema_name: schema} = tenant("gh2587-src-form2")
      definition = active_definition!(schema, human_task_graph())
      id = start!(schema, definition, %{})
      task = pending_task!(schema, id)

      assert {:error, {:output_refused, %{rejected_keys: ["_sys"]}}} =
               Engine.complete_task(task.id, complete_attrs(%{"_sys" => %{"r" => 1}}),
                 prefix: schema
               )

      assert {:error, {:output_refused, %{rejected_keys: ["_sys.a", "_sys.b"]}}} =
               Engine.complete_task(task.id, complete_attrs(%{:"_sys.b" => 1, "_sys.a" => 2}),
                 prefix: schema
               )

      # a NESTED reserved key is not reserved
      assert {:ok, _} =
               Engine.complete_task(task.id, complete_attrs(%{"n" => %{"_sys.x" => 1}}),
                 prefix: schema
               )
    end
  end

  # ── (2) SERVICE_TASK HTTP body ─────────────────────────────────────────────────────────────

  describe "(2) SERVICE_TASK HTTP body" do
    test "poll path: advance refused (variable_merge_rejected), one log line and one audit row, no value anywhere" do
      enable_ssrf_bypass()
      %{url: url} = WebhookTestServer.start(200, ~s({"_sys.x":"#{@secret}","y":2}))
      %{schema_name: schema} = tenant("gh2587-src-svc")
      definition = active_definition!(schema, service_task_graph(url))
      id = start!(schema, definition, %{"seed" => 1})

      assert [dispatch] =
               Repo.all(where(ServiceTaskDispatch, [d], d.instance_id == ^id), prefix: schema)

      {_, entries} =
        Letflow.Test.LoggerCollector.capture(
          fn ->
            assert %{claimed: 1, advanced: 0} = ServiceTaskDispatcher.poll_and_dispatch(schema)
          end,
          attribute_to: self()
        )

      log = Letflow.Test.LoggerCollector.text(entries)
      assert log =~ "dispatch_id=#{dispatch.id}"
      assert log =~ "reason=variable_merge_rejected"
      refute log =~ @secret

      assert [entry] = audit_rows(schema, "service_task.advance_failed")
      assert entry.after_state == %{"node_id" => "svc", "reason" => "variable_merge_rejected"}
      refute inspect(entry, limit: :infinity) =~ @secret

      p = projection(schema, id)
      assert p.variables == %{"seed" => 1}
      assert p.status == :active
      assert events_of_type(schema, id, "SERVICE_TASK_COMPLETED") == []

      assert [%TokenRecord{node_id: "svc", status: :active}] =
               Repo.all(where(TokenRecord, [t], t.instance_id == ^id), prefix: schema)
    end

    test "advance_after_service_task_outcome/4 returns {:error, {:variable_merge_rejected, _}} without the value" do
      enable_ssrf_bypass()
      %{url: url} = WebhookTestServer.start(200, ~s({"_sys.x":"#{@secret}"}))
      %{schema_name: schema} = tenant("gh2587-src-svc2")
      definition = active_definition!(schema, service_task_graph(url))
      id = start!(schema, definition, %{})

      assert [dispatch] =
               Repo.all(where(ServiceTaskDispatch, [d], d.instance_id == ^id), prefix: schema)

      assert {:ok, {:advance, body}} = ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema)

      assert {:error, {:variable_merge_rejected, rejection}} =
               Engine.advance_after_service_task_outcome(
                 dispatch.id,
                 {:advance, body},
                 Repo,
                 schema
               )

      assert {:rejected, _, [{:execution_error, "_sys.x", nil, :reserved_variable_key, []}]} =
               rejection

      refute inspect(rejection) =~ @secret
      assert projection(schema, id).variables == %{}
    end
  end

  # ── (3) sub-process OUTPUT ─────────────────────────────────────────────────────────────────

  describe "(3) sub-process output" do
    test "(3a) no interface: the child's reserved values are dropped, the rest merges, no ERROR" do
      %{schema_name: schema} = tenant("gh2587-src-spo")
      {parent_id, child_id} = running_child!(schema, nil)

      hold_engine_values!(schema, child_id, %{"_sys.x" => 5})
      child_task = pending_task!(schema, child_id)

      assert {:ok, %{instance_status: :completed}} =
               Engine.complete_task(child_task.id, complete_attrs(%{"y" => 2}), prefix: schema)

      parent = projection(schema, parent_id)
      assert parent.status == :active
      assert parent.current_nodes == ["after"]
      assert parent.variables == %{"seed" => 1, "y" => 2}
      assert events_of_type(schema, parent_id, "EXECUTION_ERROR") == []

      assert [event] = events_of_type(schema, parent_id, "SUB_PROCESS_COMPLETED")
      refute Map.has_key?(event.payload["output_variables"], "_sys.x")
    end

    test "(3b) an explicit interface output naming a reserved key: parent ERROR reserved_variable_key, no value" do
      %{schema_name: schema} = tenant("gh2587-src-spo2")

      interface = %{
        "outputs" => [
          %{"name" => "_sys.x", "json_schema" => %{"type" => "string"}},
          %{"name" => "y", "json_schema" => %{"type" => "integer"}}
        ]
      }

      {parent_id, child_id} = running_child!(schema, interface)
      hold_engine_values!(schema, child_id, %{"_sys.x" => @secret})
      child_task = pending_task!(schema, child_id)

      assert {:ok, _} =
               Engine.complete_task(child_task.id, complete_attrs(%{"y" => 2}), prefix: schema)

      parent = projection(schema, parent_id)
      assert parent.status == :error
      assert parent.variables == %{"seed" => 1}

      assert [event] = events_of_type(schema, parent_id, "EXECUTION_ERROR")
      assert event.payload["error_type"] == "reserved_variable_key"
      assert event.payload["affected"] == %{"kind" => "field", "key" => "_sys.x"}
      assert event.payload["details"] == %{}
      refute inspect(event.payload, limit: :infinity) =~ @secret
      assert events_of_type(schema, parent_id, "SUB_PROCESS_COMPLETED") == []
    end
  end

  # ── (4) sub-process child START ────────────────────────────────────────────────────────────

  describe "(4) sub-process child start" do
    test "no interface: the child's initial variables lack the parent's reserved values" do
      %{schema_name: schema} = tenant("gh2587-src-sps")
      child_def = active_definition!(schema, human_task_graph())
      parent_def = active_definition!(schema, parent_graph(child_def.name, nil))
      parent_id = start!(schema, parent_def, %{"seed" => 1})
      hold_engine_values!(schema, parent_id, %{"_sys.a" => Ecto.UUID.generate()})

      gate = pending_task!(schema, parent_id)
      assert {:ok, _} = Engine.complete_task(gate.id, complete_attrs(%{}), prefix: schema)

      child = child_projection!(schema, parent_id)
      assert child.variables == %{"seed" => 1}

      [started] = events_of_type(schema, child.instance_id, "INSTANCE_STARTED")
      assert started.payload["initial_variables"] == %{"seed" => 1}
      # the parent keeps its own values
      assert Map.has_key?(projection(schema, parent_id).variables, "_sys.a")
    end

    test "an interface input naming a reserved key: stripped at run time, the parent step succeeds" do
      %{schema_name: schema} = tenant("gh2587-src-sps2")

      interface = %{
        "inputs" => [
          %{"name" => "_sys.a", "json_schema" => %{"type" => "string"}},
          %{"name" => "seed", "json_schema" => %{"type" => "integer"}}
        ]
      }

      child_def = active_definition!(schema, human_task_graph())
      parent_def = active_definition!(schema, parent_graph(child_def.name, interface))
      parent_id = start!(schema, parent_def, %{"seed" => 1})
      hold_engine_values!(schema, parent_id, %{"_sys.a" => Ecto.UUID.generate()})

      gate = pending_task!(schema, parent_id)
      assert {:ok, _} = Engine.complete_task(gate.id, complete_attrs(%{}), prefix: schema)

      assert projection(schema, parent_id).status == :active
      child = child_projection!(schema, parent_id)
      assert child.variables == %{"seed" => 1}
    end
  end

  # ── (5) process start ──────────────────────────────────────────────────────────────────────

  describe "(5) process start" do
    test "Engine.create/2 with nil schema and with a resolved schema: variable_schema_violation, no instance row" do
      %{schema_name: schema} = tenant("gh2587-src-start")
      definition = active_definition!(schema, human_task_graph())
      before = instance_count(schema)

      expected =
        {:error,
         {:variable_schema_violation,
          [
            %ValidationFailure{
              field_path: "/_sys",
              constraint: "reserved_variable_key",
              actual: nil
            }
          ]}}

      assert Engine.create(start_attrs(definition, %{"_sys" => %{}}, %{}), prefix: schema) ==
               expected

      # a schema that would otherwise ACCEPT the map: the reserved check runs first
      permissive = %{"type" => "object"}

      assert Engine.create(
               start_attrs(definition, %{"_sys" => %{}}, %{pin_lookup: schema_lookup(permissive)}),
               prefix: schema
             ) == expected

      # several reserved keys: one failure each, sorted; RFC 6901 escaping of "~" and "/"
      assert {:error, {:variable_schema_violation, failures}} =
               Engine.create(
                 start_attrs(definition, %{"_sys.b" => 1, "_sys.a/~" => 2, "ok" => 1}, %{}),
                 prefix: schema
               )

      assert Enum.map(failures, & &1.field_path) == ["/_sys.a~1~0", "/_sys.b"]
      assert Enum.all?(failures, &(&1.constraint == "reserved_variable_key" and &1.actual == nil))

      assert instance_count(schema) == before
    end

    test "POST /instances with a reserved initial variable is 422" do
      tenant = tenant("gh2587-src-http")
      definition = active_definition!(tenant.schema_name, human_task_graph())
      opts = Letflow.Routers.Instances.init([])

      conn =
        conn("POST", "/")
        |> Map.put(:body_params, %{
          "definition_id" => definition.id,
          "initial_variables" => %{"_sys.r" => @secret}
        })
        |> put_req_header("content-type", "application/json")
        |> assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: tenant.tenant_id,
          roles: ["PROCESS_OPERATOR"]
        })
        |> assign(:trace_id, "gh2587-trace")
        |> Letflow.Routers.Instances.call(opts)

      assert conn.status == 422
      refute conn.resp_body =~ @secret
      assert instance_count(tenant.schema_name) == 0
    end
  end

  # ── (6) script output (7c route) ───────────────────────────────────────────────────────────

  describe "(6) script output via the 7c route" do
    test "a reserved output key: output_invalid run recording reserved_variable_key, variables unchanged" do
      t = F.tenant!("gh2587-src-script")

      b =
        F.bound!(
          t,
          "return { total = ctx.input.amount, [\"_sys.x\"] = 4417 }",
          sys_manifest(),
          %{"amount" => 2}
        )

      {row, {:ok, :failed}} = F.run_next!(t.schema_name)
      done = F.reload(t.schema_name, row)
      assert {done.outcome, done.outcome_detail} == {"output_invalid", "reserved_variable_key"}

      projection = F.projection(t.schema_name, b.instance_id)
      assert projection.variables == %{"amount" => 2}

      [record] = F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")
      assert record["outcome"] == "output_invalid"
      assert record["detail"] == "reserved_variable_key"
      refute 4417 in Map.values(record)
      assert F.payloads(t.schema_name, b.instance_id, "SCRIPT_TASK_COMPLETED") == []
    end

    test "regression: a schema-rejected script output still records variable_schema_rejected" do
      t = F.tenant!("gh2587-src-script2")
      schemas = [%{variable_key: "total", json_schema: %{"type" => "integer", "maximum" => 10}}]

      b =
        F.bound_graph!(
          t,
          F.doubling_source(),
          F.closed_manifest(),
          %{"amount" => 21},
          &F.script_graph/2,
          schemas
        )

      {_row, {:ok, :failed}} = F.run_next!(t.schema_name)
      [record] = F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")
      assert record["outcome"] == "output_invalid"
      assert record["detail"] == "variable_schema_rejected"
    end
  end

  # ── (7) no admin variable-patch route ──────────────────────────────────────────────────────

  test "(7) no router file declares a route path containing \"variable\" or \"vars\"" do
    files =
      Path.wildcard("lib/letflow/routers/**/*.ex") ++ Path.wildcard("lib/letflow/api/**/*.ex")

    assert files != []

    hits =
      for path <- files,
          line <- String.split(File.read!(path), "\n"),
          line =~ ~r/^\s*(get|post|put|patch|delete|match|forward)\s*\(?\s*"[^"]*(variable|vars)/i,
          do: {path, line}

    assert hits == []
  end
end
