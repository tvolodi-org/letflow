defmodule Letflow.Routers.SysVariablesResponseTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B3 (decision 0054 CO-1, INV-2): engine-written `_sys.*` values never
  reach a client through an instance read, a reconstruct, a task-completion response, the
  instance history or the timeline. A STRIP, not a permission gate.

  CO-2 (PR B2): the `_sys` values are produced by the REAL writer, a HUMAN_TASK completion whose
  node declares `entity_writes` (`Letflow.EntityWritesFixture`, `Engine.complete_task/3`): the
  engine itself appends the `INSTANCE_SYS_VARIABLES_SET` and `TASK_ENTITY_WRITES_APPLIED` events
  and holds the values on the projection. Nothing here hand-writes a `_sys` map or a projection
  column. The few fabricated EVENTS below (an `EXECUTION_ERROR`, an `INSTANCE_STARTED` carrying
  a reserved key, an `APPLIED` event with empty lines) are defensive-stripping cases for payload
  shapes no engine path produces today.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [where: 3]

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.VariableMerge
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User

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

  defp writing_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{
            "role" => "approver",
            "entity_writes" => [
              %{
                "op" => "create",
                "entity_type" => "order_line",
                "fields" => %{"label" => %{"const" => "L"}},
                "output_record_id_var" => "_sys.line_0"
              }
            ]
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp start_writing!(base, definition) do
    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{"customer" => "acme", "amount" => 7},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Fx.unique("gh2587-b3-start")
               },
               prefix: base.schema
             )

    result.instance_id
  end

  # The real writer: the completion mints the `_sys` values, events and projection state.
  defp complete_writing!(base, instance_id) do
    task = Fx.pending_task!(base.schema, instance_id)

    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{},
                 actor_id: base.user.id,
                 idempotency_key: Fx.unique("gh2587-b3-complete")
               },
               prefix: base.schema
             )

    variables = Repo.get!(InstanceProjection, instance_id, prefix: base.schema).variables
    values = Map.take(variables, @sys_keys)
    assert Map.keys(values) |> Enum.sort() == @sys_keys
    %{record_id: values["_sys.line_0"], values: values}
  end

  defp refute_sys_anywhere(json_body, record_id) do
    refute json_body =~ "_sys"
    refute json_body =~ record_id
  end

  setup do
    base = Fx.tenant_case!("gh2587-b3")
    Fx.define_type!(base.schema, "order_line", %{})
    definition = Fx.activate!(base.schema, base.user, writing_graph())
    instance_id = start_writing!(base, definition)
    seeded = complete_writing!(base, instance_id)

    %{
      tenant: base.tenant,
      base: base,
      definition: definition,
      instance_id: instance_id,
      seeded: seeded
    }
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
    base: base,
    definition: definition,
    seeded: seeded
  } do
    # a fresh instance: this very completion is the one that mints the `_sys` values
    id = start_writing!(base, definition)
    task = Fx.pending_task!(base.schema, id)

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

    # non-vacuity: the engine really held `_sys` values for THIS completion
    stored = Repo.get!(InstanceProjection, id, prefix: tenant.schema_name).variables
    assert Map.keys(Map.take(stored, @sys_keys)) |> Enum.sort() == @sys_keys
    refute conn.resp_body =~ stored["_sys.line_0"]
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
    assert applied["payload"]["lines_hash"] =~ ~r/\A[0-9a-f]{64}\z/
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

  test "history strips reserved keys from initial_variables and output_variables payloads",
       %{tenant: tenant} do
    id = start_instance!(tenant)
    leaked = Ecto.UUID.generate()

    append!(tenant.schema_name, id, "INSTANCE_STARTED", %{
      "definition_id" => Ecto.UUID.generate(),
      "initial_variables" => %{"customer" => "acme", "_sys.line_0" => leaked}
    })

    append!(tenant.schema_name, id, "TASK_COMPLETED", %{
      "task_id" => Ecto.UUID.generate(),
      "node_id" => "task",
      "output_variables" => %{"decision" => "ok", "_sys.line_0.seq" => 9},
      "activated_nodes" => []
    })

    conn = instances(:get, "/#{id}/history", tenant)
    assert conn.status == 200
    items = body(conn)["items"]

    started =
      items |> Enum.filter(&(&1["event_type"] == "INSTANCE_STARTED")) |> List.last()

    completed = Enum.find(items, &(&1["event_type"] == "TASK_COMPLETED"))
    assert started["payload"]["initial_variables"] == %{"customer" => "acme"}
    assert completed["payload"]["output_variables"] == %{"decision" => "ok"}
    refute conn.resp_body =~ "_sys"
    refute conn.resp_body =~ leaked
  end

  test "an APPLIED event with empty lines keeps no record id or sequence", %{tenant: tenant} do
    id = start_instance!(tenant)

    append!(tenant.schema_name, id, "TASK_ENTITY_WRITES_APPLIED", %{
      "node_id" => "task",
      "task_id" => nil,
      "dispatch_id" => Ecto.UUID.generate(),
      "lines_hash" => String.duplicate("b", 64),
      "lines" => []
    })

    conn = instances(:get, "/#{id}/history", tenant)
    item = Enum.find(body(conn)["items"], &(&1["event_type"] == "TASK_ENTITY_WRITES_APPLIED"))
    assert item["payload"]["lines"] == []
    refute inspect(item["payload"]) =~ "record_id"
    refute inspect(item["payload"]) =~ "event_global_seq"
  end

  test "public_event_payload/2 tolerates a missing or malformed lines value" do
    for payload <- [
          %{"node_id" => "n", "record_id" => "x", "event_global_seq" => 1},
          %{"node_id" => "n", "lines" => "nope", "record_id" => "x"},
          %{"node_id" => "n", "lines" => [1, %{"line_index" => 0, "record_id" => "x"}]}
        ] do
      shaped =
        Letflow.Api.Response.public_event_payload("TASK_ENTITY_WRITES_APPLIED", payload)

      refute inspect(shaped) =~ "record_id"
      refute inspect(shaped) =~ "event_global_seq"
      assert is_list(shaped["lines"])
    end
  end

  test "timeline page_size=1 walk shows each visible event once and the APPLIED row has no ids",
       %{tenant: tenant, instance_id: id, seeded: seeded} do
    full = body(instances(:get, "/#{id}/timeline", tenant))["items"]
    types = Enum.map(full, & &1["event_type"])

    walked = walk_timeline(tenant, id, nil, [])
    assert Enum.map(walked, & &1["event_type"]) == types
    assert Enum.map(walked, & &1["event_id"]) == Enum.map(full, & &1["event_id"])
    refute VariableMerge.sys_event_type() in types

    applied = Enum.find(walked, &(&1["event_type"] == "TASK_ENTITY_WRITES_APPLIED"))
    assert applied
    refute inspect(applied["description"]) =~ seeded.record_id
    refute inspect(applied["metadata"]) =~ seeded.record_id
    refute inspect(applied) =~ "event_global_seq"
  end

  defp walk_timeline(tenant, id, cursor, acc) do
    qs =
      if cursor, do: "?page_size=1&cursor=#{URI.encode_www_form(cursor)}", else: "?page_size=1"

    conn = instances(:get, "/#{id}/timeline#{qs}", tenant)
    assert conn.status == 200
    b = body(conn)
    acc = acc ++ b["items"]

    case b["next_cursor"] do
      nil -> acc
      next -> walk_timeline(tenant, id, next, acc)
    end
  end
end
