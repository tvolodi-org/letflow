defmodule Letflow.Routers.SysVariablesResponseTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B3 (decision 0054 CO-1, INV-2): engine-written `_sys.*` values never
  reach a client through an instance read, a reconstruct, a task-completion response, the
  instance history or the timeline. A STRIP, not a permission gate.

  CO-2: the `_sys` values are produced by the REAL writer `VariableMerge.put_sys/3` (strict),
  appended as the real `INSTANCE_SYS_VARIABLES_SET` event through `EventStore.append/2` (so
  `Registry.validate_payload/3` runs), and held on the projection the way the engine will.
  Nothing here hand-writes a `_sys` map. Until B2 lands no engine path writes them, so this
  helper is the only seeding path; B2 replaces it with a real completion (design CO-1/CO-2).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [where: 3]

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @sys_keys ["_sys.line_0", "_sys.line_0.seq"]

  defp conn_for(router, method, path, tenant, fields) do
    conn = conn(method, path)

    conn =
      case Keyword.get(fields, :body) do
        nil -> conn
        body -> %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      end

    conn
    |> assign(:auth_context, %{
      user_id: Keyword.get(fields, :user_id, Ecto.UUID.generate()),
      tenant_id: tenant.tenant_id,
      roles: Keyword.get(fields, :roles, ["TENANT_ADMIN"])
    })
    |> assign(:trace_id, "fixed-test-trace-id")
    |> router.call(router.init([]))
  end

  defp instances(method, path, tenant, fields \\ []),
    do: conn_for(Letflow.Routers.Instances, method, path, tenant, fields)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp start_instance!(tenant) do
    graph = %{
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

    n = System.unique_integer([:positive])

    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: "gh2587-b3-def-#{n}",
                 version: "1.0.0",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: tenant.schema_name
             )

    assert {:ok, %{definition: active}} =
             Definitions.activate(definition.id, prefix: tenant.schema_name)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: active.id,
                 initial_variables: %{"customer" => "acme", "amount" => 7},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: "gh2587-b3-start-#{n}"
               },
               prefix: tenant.schema_name
             )

    result.instance_id
  end

  defp append!(schema, instance_id, type, payload) do
    assert {:ok, %{event: event}} =
             EventStore.append(
               %{
                 instance_id: instance_id,
                 event_type: type,
                 payload: Jason.encode!(payload),
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: "gh2587-b3-#{System.unique_integer([:positive])}"
               },
               prefix: schema
             )

    event
  end

  # The real writer: strict put_sys/3 builds the values, the SYS event goes through
  # EventStore.append/2 (registry guard), the projection holds them as the engine will.
  defp seed_sys!(schema, instance_id) do
    record_id = Ecto.UUID.generate()
    {:ok, vars} = VariableMerge.put_sys(%{}, "_sys.line_0", record_id)
    {:ok, vars} = VariableMerge.put_sys(vars, "_sys.line_0.seq", 41)
    assert Map.keys(vars) |> Enum.sort() == @sys_keys

    append!(schema, instance_id, VariableMerge.sys_event_type(), %{
      "node_id" => "task",
      "cause" => "entity_writes",
      "values" => vars
    })

    append!(schema, instance_id, "TASK_ENTITY_WRITES_APPLIED", %{
      "node_id" => "task",
      "task_id" => Ecto.UUID.generate(),
      "dispatch_id" => nil,
      "lines_hash" => String.duplicate("a", 64),
      "lines" => [
        %{
          "line_index" => 0,
          "entity_type" => "order_line",
          "record_id" => record_id,
          "event_global_seq" => 41
        }
      ]
    })

    current = Repo.get!(InstanceProjection, instance_id, prefix: schema).variables

    {1, _} =
      InstanceProjection
      |> where([p], p.instance_id == ^instance_id)
      |> Repo.update_all([set: [variables: Map.merge(current, vars)]], prefix: schema)

    %{record_id: record_id, values: vars}
  end

  defp refute_sys_anywhere(json_body, record_id) do
    refute json_body =~ "_sys"
    refute json_body =~ record_id
  end

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-b3")
    instance_id = start_instance!(tenant)
    seeded = seed_sys!(tenant.schema_name, instance_id)
    %{tenant: tenant, instance_id: instance_id, seeded: seeded}
  end

  test "seeded projection really holds the _sys values (non-vacuity of every case below)",
       %{tenant: tenant, instance_id: id, seeded: seeded} do
    stored = Repo.get!(InstanceProjection, id, prefix: tenant.schema_name).variables
    assert Map.take(stored, @sys_keys) == seeded.values
    assert stored["customer"] == "acme"

    assert {:ok, %{instance_state: state}} =
             Reconstruction.reconstruct_instance(id, prefix: tenant.schema_name)

    assert Map.take(state.variables, @sys_keys) == seeded.values
  end

  test "GET /instances/:id strips _sys, keeps the rest, and stores nothing different",
       %{tenant: tenant, instance_id: id, seeded: seeded} do
    conn = instances(:get, "/#{id}", tenant)
    assert conn.status == 200
    assert body(conn)["variables"] == %{"customer" => "acme", "amount" => 7}
    refute_sys_anywhere(conn.resp_body, seeded.record_id)

    stored = Repo.get!(InstanceProjection, id, prefix: tenant.schema_name).variables
    assert Map.take(stored, @sys_keys) == seeded.values
  end

  test "POST /instances/:id/reconstruct strips _sys from the response, keeps it written back",
       %{tenant: tenant, instance_id: id, seeded: seeded} do
    conn = instances(:post, "/#{id}/reconstruct", tenant)
    assert conn.status == 200
    assert body(conn)["variables"] == %{"customer" => "acme", "amount" => 7}
    refute_sys_anywhere(conn.resp_body, seeded.record_id)

    stored = Repo.get!(InstanceProjection, id, prefix: tenant.schema_name).variables
    assert Map.take(stored, @sys_keys) == seeded.values
  end

  test "POST /tasks/:id/complete response strips _sys", %{
    tenant: tenant,
    instance_id: id,
    seeded: seeded
  } do
    [task] =
      Letflow.Engine.Task
      |> where([t], t.instance_id == ^id and t.status == :pending)
      |> Repo.all(prefix: tenant.schema_name)

    # an assignee: a user in a group bound to the task's routing role "approver"
    prefix = tenant.schema_name

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2587-b3-#{Ecto.UUID.generate()}",
        display_name: "Approver",
        email: "gh2587-b3-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: prefix)

    group =
      %Group{}
      |> Ecto.Changeset.change(%{name: "gh2587-b3-g-#{Ecto.UUID.generate()}", display_name: "G"})
      |> Repo.insert!(prefix: prefix)

    %GroupMember{}
    |> Ecto.Changeset.change(%{group_id: group.id, user_id: user.id})
    |> Repo.insert!(prefix: prefix)

    %TenantRole{}
    |> Ecto.Changeset.change(%{name: "approver", kind: :process_routing_role, group_id: group.id})
    |> Repo.insert!(prefix: prefix)

    conn =
      conn_for(Letflow.Routers.Tasks, :post, "/#{task.id}/complete", tenant,
        body: %{},
        user_id: user.id
      )

    assert conn.status == 200
    resp = body(conn)
    assert resp["variables"]["customer"] == "acme"
    refute_sys_anywhere(conn.resp_body, seeded.record_id)
  end

  test "GET /instances/:id/history hides the SYS event, reduces APPLIED, keeps paging exact",
       %{tenant: tenant, instance_id: id, seeded: seeded} do
    all_types =
      Event
      |> where([e], e.instance_id == ^id)
      |> Repo.all(prefix: tenant.schema_name)
      |> Enum.map(& &1.event_type)

    assert VariableMerge.sys_event_type() in all_types

    conn = instances(:get, "/#{id}/history", tenant)
    assert conn.status == 200
    items = body(conn)["items"]
    types = Enum.map(items, & &1["event_type"])

    refute VariableMerge.sys_event_type() in types
    assert length(items) == length(all_types) - 1
    refute_sys_anywhere(conn.resp_body, seeded.record_id)

    applied = Enum.find(items, &(&1["event_type"] == "TASK_ENTITY_WRITES_APPLIED"))

    assert applied["payload"]["lines"] == [%{"line_index" => 0, "entity_type" => "order_line"}]
    assert applied["payload"]["lines_hash"] == String.duplicate("a", 64)
    refute inspect(applied["payload"]) =~ "event_global_seq"

    # page_size 1: the cursor walks every visible event exactly once, none of them the SYS one
    assert walk_history(tenant, id, nil, []) == types

    # an explicit event_type filter for the hidden type is empty, not a leak
    conn = instances(:get, "/#{id}/history?event_type=#{VariableMerge.sys_event_type()}", tenant)
    assert body(conn)["items"] == []
  end

  defp walk_history(tenant, id, cursor, acc) do
    qs =
      if cursor, do: "?page_size=1&cursor=#{URI.encode_www_form(cursor)}", else: "?page_size=1"

    conn = instances(:get, "/#{id}/history#{qs}", tenant)
    assert conn.status == 200
    b = body(conn)
    acc = acc ++ Enum.map(b["items"], & &1["event_type"])

    case b["next_cursor"] do
      nil -> acc
      next -> walk_history(tenant, id, next, acc)
    end
  end

  test "GET /instances/:id/timeline hides the SYS event", %{
    tenant: tenant,
    instance_id: id,
    seeded: seeded
  } do
    conn = instances(:get, "/#{id}/timeline", tenant)
    assert conn.status == 200
    types = body(conn)["items"] |> Enum.map(& &1["event_type"])
    refute VariableMerge.sys_event_type() in types
    assert "INSTANCE_STARTED" in types
    refute_sys_anywhere(conn.resp_body, seeded.record_id)
  end

  test "history EXECUTION_ERROR payload variables are stripped (F-6)", %{tenant: tenant} do
    id = start_instance!(tenant)

    append!(tenant.schema_name, id, "EXECUTION_ERROR", %{
      "error_type" => "no_matching_edge",
      "affected" => %{"kind" => "node", "node_id" => "task"},
      "reason" => "no edge",
      "variables" => %{"customer" => "acme", "_sys.line_0" => Ecto.UUID.generate()},
      "details" => %{}
    })

    conn = instances(:get, "/#{id}/history", tenant)
    assert conn.status == 200
    item = Enum.find(body(conn)["items"], &(&1["event_type"] == "EXECUTION_ERROR"))
    assert item["payload"]["variables"] == %{"customer" => "acme"}
    assert item["payload"]["reason"] == "no edge"
    refute conn.resp_body =~ "_sys"
  end
end
