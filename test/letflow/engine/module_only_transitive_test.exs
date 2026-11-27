defmodule Letflow.Engine.ModuleOnlyTransitiveTest do
  @moduledoc """
  T-3094 (pilot gaps G-SUB-1 and G-SUB-2 of the PILOT-SUB lane; the design record
  `docs/design/pilot-sub-receive-with-inspection.md` section 3): a SUB_PROCESS child inherits the
  parent's variables, so the parent's own fences have to see the children.

  G-SUB-1 (start side): a definition is module-only when its OWN graph carries `module_writes` OR
  when any of its TRANSITIVE children does. A public start of such a parent answers as for an
  unknown definition (404 `definition_not_found`, INV-5); only module code (`module_start: true`)
  starts it. The children are read the way `gate_start_permission/2` reads them (the active
  version of each named child, transitively).

  G-SUB-2 (completion side): the refused set of a graph includes the write-read keys of its
  transitive children, so the completer of a human task of the parent cannot forge the key the
  child reads as a write target. The answer is the retryable 422 `output_refused` and nothing is
  written. The node's OWN `completer_inputs` stay the exception: a child's node of the same id
  never lifts a refusal in the parent.

  Tests: GSUB-1a the public start of a parent with a module-only child is refused and the module
  start passes; GSUB-1b a parent whose child is NOT module-only still starts publicly (the
  negative control); GSUB-1c the module-only child is found through a GRANDchild (the set is
  transitive); GSUB-1d the public start of such a parent is the 404 of an unknown definition at
  the ROUTE (the acceptance wording of the design record); GSUB-2a the completion body carrying
  the child's write key is refused and nothing is merged, and the body with the node's own
  declared key is accepted; GSUB-2b the exception is the node's own declared list.

  `async: false`: the fixture installs a module and provisions a tenant (the install writes the
  global tables).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Engine
  alias Letflow.Engine.Task
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.ModuleWritesFixture, as: Mw

  @route_opts Letflow.Routers.Instances.init([])

  setup do
    base = Mw.tenant!("mot")
    child = Mw.activate_installed!(base.schema, base.user, "fxl_svc_child")
    Map.merge(base, %{child: child})
  end

  # START -> SUB_PROCESS (`child_name`) -> END.
  defp sub_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "sub"},
        %{"id" => "p1", "source" => "sub", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK `ht` -> SUB_PROCESS (`child_name`) -> END: the human task comes FIRST,
  # so what the completer writes is what the child inherits when it starts.
  defp human_graph(child_name, ht_attributes) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => ht_attributes},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "ht"},
        %{"id" => "p1", "source" => "ht", "target" => "sub"},
        %{"id" => "p2", "source" => "sub", "target" => "end"}
      ]
    }
  end

  defp start_attrs(definition, key, variables \\ %{}) do
    %{
      definition_id: definition.id,
      initial_variables: variables,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Fx.unique(key)
    }
  end

  defp instance_count(schema), do: Repo.aggregate(InstanceProjection, :count, prefix: schema)

  # The instances of the tenant that are not a SUB_PROCESS child.
  defp top_level_count(schema) do
    Repo.aggregate(
      from(p in InstanceProjection, where: is_nil(p.parent_instance_id)),
      :count,
      prefix: schema
    )
  end

  test "GSUB-1a a public start of a parent whose SUB_PROCESS child is module-only is refused; the module start passes",
       ctx do
    parent = Mw.stamped_parent!(ctx, ctx.child, sub_graph("fxl_svc_child"))

    assert {:error, :definition_not_found} =
             Engine.create(start_attrs(parent, "mot-1a-public"), prefix: ctx.schema)

    # nothing was started
    assert instance_count(ctx.schema) == 0

    assert {:ok, %{instance_id: _}} =
             Engine.create(start_attrs(parent, "mot-1a-module"),
               prefix: ctx.schema,
               module_start: true
             )

    assert top_level_count(ctx.schema) == 1
  end

  test "GSUB-1b a parent whose child is NOT module-only still starts publicly", ctx do
    plain = Mw.activate_installed!(ctx.schema, ctx.user, "fxl_task_plain")
    parent = Mw.stamped_parent!(ctx, plain, sub_graph("fxl_task_plain"))

    assert {:ok, %{instance_id: _}} =
             Engine.create(start_attrs(parent, "mot-1b"), prefix: ctx.schema)

    assert top_level_count(ctx.schema) == 1
  end

  test "GSUB-1c the module-only child is found through a GRANDchild", ctx do
    middle = Mw.stamped_parent!(ctx, ctx.child, sub_graph("fxl_svc_child"))
    parent = Mw.stamped_parent!(ctx, ctx.child, sub_graph(middle.name))

    assert {:error, :definition_not_found} =
             Engine.create(start_attrs(parent, "mot-1c-public"), prefix: ctx.schema)

    assert instance_count(ctx.schema) == 0

    assert {:ok, %{instance_id: _}} =
             Engine.create(start_attrs(parent, "mot-1c-module"),
               prefix: ctx.schema,
               module_start: true
             )

    assert top_level_count(ctx.schema) == 1
  end

  test "GSUB-1d the public start of such a parent is the 404 of an unknown definition at the route",
       ctx do
    parent = Mw.stamped_parent!(ctx, ctx.child, sub_graph("fxl_svc_child"))

    conn =
      conn("POST", "/")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", Fx.unique("mot-1d"))
      |> assign(:auth_context, %{
        user_id: ctx.user.id,
        tenant_id: ctx.tenant.tenant_id,
        roles: ["PROCESS_OPERATOR"]
      })
      |> assign(:trace_id, "t3094-gsub-1d")

    conn = %{
      conn
      | body_params: %{"definition_id" => parent.id, "initial_variables" => %{}}
    }

    conn = Letflow.Routers.Instances.call(conn, @route_opts)

    assert conn.status == 404, "body: #{inspect(conn.resp_body)}"

    # nothing was started: neither the parent nor the child
    assert instance_count(ctx.schema) == 0
  end

  test "GSUB-2a the completion body carrying the child's write key is refused and nothing is merged",
       ctx do
    parent =
      Mw.stamped_parent!(
        ctx,
        ctx.child,
        human_graph("fxl_svc_child", %{
          "role" => "REVIEWER",
          "completer_inputs" => ["damaged_qty"]
        })
      )

    {:ok, %{instance_id: instance_id}} =
      Engine.create(start_attrs(parent, "mot-2a"),
        prefix: ctx.schema,
        module_start: true
      )

    task = Fx.pending_task!(ctx.schema, instance_id)

    # `label` is the key the CHILD's service node reads as its write target
    assert {:error, {:output_refused, %{missing_keys: [], rejected_keys: ["label"]}}} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{"label" => "forged"},
                 actor_id: ctx.user.id,
                 idempotency_key: Fx.unique("mot-2a-refused")
               },
               prefix: ctx.schema
             )

    # nothing is written: the task stays open and the key never reached the instance
    assert %{status: :pending} = Repo.get!(Task, task.id, prefix: ctx.schema)

    variables = Repo.get!(InstanceProjection, instance_id, prefix: ctx.schema).variables
    refute Map.has_key?(variables, "label")

    # the node's OWN declared key is accepted: the refusal is about the child's key
    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{"damaged_qty" => 3},
                 actor_id: ctx.user.id,
                 idempotency_key: Fx.unique("mot-2a-accepted")
               },
               prefix: ctx.schema
             )
  end
end
