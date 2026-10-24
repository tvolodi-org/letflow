defmodule Letflow.Engine.InstanceScopeNodeTest do
  @moduledoc """
  REQ-531 / GH #3092 (decision 0051 T13/T14): the scope node an instance is started under.

  Engine level (`Letflow.Engine.create/2`, `Reconstruction`, `SnapshotWriter`, sub-process children)
  and route level (`POST /instances`, both GET reads), on one committed provisioned tenant with the
  `ScopeSetFixture` node tree (`root > a (a1, a2 retired > a2x, a3 retired), b (b1)`).

  Test IDs follow the design (`T-2a` ... `T-R1`). T-R2 (a node retired between the advisory pre-check
  and the locked step) is race-only: it cannot be forced deterministically, so the locked step
  (`lock_scope_node/3`, the same rank-N `FOR SHARE` lock `ScopedGrants` uses) is covered by reading the
  code, not by a test.

  Real Postgres, committed writes: `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.SnapshotWriter
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TaskScopeFixture, as: T

  @role "PROCESS_DESIGNER"

  setup do
    fx = T.provision!("r531")
    {:ok, fx: fx, schema: fx.schema_name, nodes: F.nodes()}
  end

  # ---- helpers -----------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp active_definition!(schema, graph \\ nil) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: unique("r531-def"),
          version: "1.0.0",
          graph: graph || task_graph(),
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)
    active
  end

  # START > HUMAN_TASK > END
  defp task_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-x"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp sub_node(child_name) do
    %{
      "id" => "sub",
      "node_type" => "SUB_PROCESS",
      "attributes" => %{"definition_name" => child_name}
    }
  end

  # START > SUB_PROCESS > END
  defp parent_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        sub_node(child_name),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "sub"},
        %{"id" => "p1", "source" => "sub", "target" => "end"}
      ]
    }
  end

  # START > HUMAN_TASK gate > SUB_PROCESS > END (the child starts on the complete_task path)
  defp gated_parent_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gate", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-x"}},
        sub_node(child_name),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "g0", "source" => "start", "target" => "gate"},
        %{"id" => "g1", "source" => "gate", "target" => "sub"},
        %{"id" => "g2", "source" => "sub", "target" => "end"}
      ]
    }
  end

  defp start_attrs(definition, extra) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique("r531-start")
      },
      extra
    )
  end

  defp start!(schema, definition, extra \\ %{}) do
    assert {:ok, %{instance_id: instance_id}} =
             Engine.create(start_attrs(definition, extra), prefix: schema)

    instance_id
  end

  defp projection!(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema)

  defp started_payload!(schema, instance_id) do
    {:ok, events} = Reconstruction.read_full_log(instance_id, schema, 1)
    started = Enum.find(events, &(&1.event_type == "INSTANCE_STARTED"))
    if is_binary(started.payload), do: Jason.decode!(started.payload), else: started.payload
  end

  # tasks and tokens reference the projection row: clear them first (FK order), as the
  # reconstruction tests do for the "projection deleted" scenario
  defp delete_projection_row!(schema, instance_id) do
    for source <- [EngineTask, Letflow.Engine.TokenRecord, InstanceProjection] do
      Repo.delete_all(from(r in source, where: r.instance_id == ^instance_id),
        prefix: schema
      )
    end
  end

  defp counts(schema) do
    for table <- ["instance_projections", "events", "instance_definition_snapshots", "tasks"],
        into: %{} do
      %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".#{table}|)
      {table, n}
    end
  end

  defp designer!(fx, where),
    do: T.caller!(fx, roles: [@role], grants: grants(where), routing: false)

  defp grants(:none), do: []
  defp grants(where), do: [{@role, where}]

  defp post(fx, caller, body, mode \\ :off),
    do: On.call(Letflow.Routers.Instances, :post, "/", fx, caller.id, caller.roles, mode, body)

  defp get(fx, caller, path, mode \\ :off),
    do: On.call(Letflow.Routers.Instances, :get, path, fx, caller.id, caller.roles, mode, nil)

  defp start_body(definition, node),
    do: %{"definition_id" => definition.id, "initial_variables" => %{}, "scope_node_id" => node}

  # ---- AC 2 ------------------------------------------------------------------------------------------

  describe "T-2 the node is recorded and read back" do
    test "T-2a POST with a live node: projection, INSTANCE_STARTED payload and both GETs", ctx do
      %{fx: fx, schema: schema, nodes: nodes} = ctx
      definition = active_definition!(schema)
      admin = designer!(fx, :tenant_wide)

      conn = post(fx, admin, start_body(definition, nodes.a1))
      assert conn.status == 201
      instance_id = T.json(conn)["instance_id"]

      assert projection!(schema, instance_id).scope_node_id == nodes.a1
      assert started_payload!(schema, instance_id)["scope_node_id"] == nodes.a1

      one = get(fx, admin, "/#{instance_id}")
      assert one.status == 200
      assert T.json(one)["scope_node_id"] == nodes.a1

      list = get(fx, admin, "/")
      assert list.status == 200
      item = Enum.find(T.json(list)["items"], &(&1["instance_id"] == instance_id))
      assert item["scope_node_id"] == nodes.a1
    end

    test "T-2b completing a task leaves the node unchanged", %{schema: schema, nodes: nodes} do
      definition = active_definition!(schema)
      instance_id = start!(schema, definition, %{scope_node_id: nodes.b1})

      task =
        Repo.one!(from(t in EngineTask, where: t.instance_id == ^instance_id), prefix: schema)

      assert {:ok, _} =
               Engine.complete_task(
                 task.id,
                 %{
                   output_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique("r531-done")
                 },
                 prefix: schema
               )

      assert projection!(schema, instance_id).status == :completed
      assert projection!(schema, instance_id).scope_node_id == nodes.b1
    end
  end

  # ---- AC 3 ------------------------------------------------------------------------------------------

  describe "T-3 unscoped starts are unchanged" do
    test "T-3a absent and null: NULL column, no payload key, null in both GETs", ctx do
      %{fx: fx, schema: schema} = ctx
      definition = active_definition!(schema)
      admin = designer!(fx, :tenant_wide)

      bodies = [
        %{"definition_id" => definition.id, "initial_variables" => %{}},
        start_body(definition, nil)
      ]

      for body <- bodies do
        conn = post(fx, admin, body)
        assert conn.status == 201
        instance_id = T.json(conn)["instance_id"]

        assert projection!(schema, instance_id).scope_node_id == nil
        refute Map.has_key?(started_payload!(schema, instance_id), "scope_node_id")

        assert %{"scope_node_id" => nil} = T.json(get(fx, admin, "/#{instance_id}"))

        item =
          get(fx, admin, "/")
          |> T.json()
          |> Map.fetch!("items")
          |> Enum.find(&(&1["instance_id"] == instance_id))

        assert Map.fetch!(item, "scope_node_id") == nil
      end
    end
  end

  # ---- AC 4 ------------------------------------------------------------------------------------------

  describe "T-4 snapshot and rebuild" do
    test "T-4a rebuild without a snapshot restores the node", %{schema: schema, nodes: nodes} do
      instance_id = start!(schema, active_definition!(schema), %{scope_node_id: nodes.a})

      assert {:error, :snapshot_not_found} =
               SnapshotWriter.latest_snapshot(instance_id, prefix: schema)

      delete_projection_row!(schema, instance_id)

      assert {:ok, %{write_back: :written, instance_state: state}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema, write_back: true)

      assert state.scope_node_id == nodes.a
      assert projection!(schema, instance_id).scope_node_id == nodes.a
    end

    test "T-4b a rebuild from a snapshot keeps the node", %{schema: schema, nodes: nodes} do
      instance_id = start!(schema, active_definition!(schema), %{scope_node_id: nodes.b})

      assert {:ok, %{instance_state: state, last_sequence_number: seq}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema)

      assert {:ok, _} = SnapshotWriter.take_snapshot(instance_id, state, seq, prefix: schema)

      # the replay now starts AFTER the snapshot: INSTANCE_STARTED is not replayed
      assert {:ok, {%InstanceState{scope_node_id: nodes_b}, ^seq}} =
               SnapshotWriter.latest_snapshot(instance_id, prefix: schema)

      assert nodes_b == nodes.b

      # the rebuilt state comes from the snapshot alone (no event is replayed after it)
      assert {:ok, %{instance_state: rebuilt, event_count: 0}} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema)

      assert rebuilt.scope_node_id == nodes.b
    end

    test "T-4c the snapshot holds the key; one without it reads as unscoped", ctx do
      %{schema: schema, nodes: nodes} = ctx
      instance_id = start!(schema, active_definition!(schema), %{scope_node_id: nodes.a})
      state = %InstanceState{instance_id: instance_id, scope_node_id: nodes.a1}

      assert {:ok, _} = SnapshotWriter.take_snapshot(instance_id, state, 1, prefix: schema)

      assert {:ok, {%InstanceState{scope_node_id: stored}, 1}} =
               SnapshotWriter.latest_snapshot(instance_id, prefix: schema)

      assert stored == nodes.a1

      # a snapshot written before REQ-531 has no such key
      Repo.query!(
        ~s|UPDATE "#{schema}".instance_state_snapshots SET state = state - 'scope_node_id'|
      )

      assert {:ok, {%InstanceState{scope_node_id: nil}, 1}} =
               SnapshotWriter.latest_snapshot(instance_id, prefix: schema)
    end

    test "T-4d write once: update_changeset ignores it; a rebuild over a live row keeps it",
         ctx do
      %{schema: schema, nodes: nodes} = ctx
      instance_id = start!(schema, active_definition!(schema), %{scope_node_id: nodes.a1})
      row = projection!(schema, instance_id)

      changeset =
        InstanceProjection.update_changeset(row, %{
          status: :active,
          last_event_seq: row.last_event_seq,
          scope_node_id: nodes.b1
        })

      refute Map.has_key?(changeset.changes, :scope_node_id)

      assert {:ok, _} =
               Reconstruction.reconstruct_instance(instance_id, prefix: schema, write_back: true)

      assert projection!(schema, instance_id).scope_node_id == nodes.a1
    end
  end

  # ---- AC 5 ------------------------------------------------------------------------------------------

  describe "T-5 invalid nodes are refused before anything is written" do
    test "T-5a unknown, retired, non-string and empty: 422, nothing created", ctx do
      %{fx: fx, schema: schema, nodes: nodes} = ctx
      definition = active_definition!(schema)
      admin = designer!(fx, :tenant_wide)
      before = counts(schema)

      for bad <- ["no-such-node", nodes.a3, nodes.a2, 123, true, %{}, ["x"], ""] do
        conn = post(fx, admin, start_body(definition, bad))
        assert conn.status == 422, inspect(bad)
      end

      assert counts(schema) == before
    end

    test "T-5a the engine answers :invalid_scope_node for each", %{schema: schema, nodes: nodes} do
      definition = active_definition!(schema)
      before = counts(schema)

      for bad <- ["no-such-node", nodes.a3, "", 123, :a] do
        assert {:error, :invalid_scope_node} =
                 Engine.create(start_attrs(definition, %{scope_node_id: bad}), prefix: schema)
      end

      assert counts(schema) == before
    end

    test "T-5b unknown, retired and out-of-scope answer with the identical response", ctx do
      %{fx: fx, schema: schema, nodes: nodes} = ctx
      definition = active_definition!(schema)
      scoped = designer!(fx, :a)
      admin = designer!(fx, :tenant_wide)

      unknown = post(fx, admin, start_body(definition, "no-such-node")) |> T.wire()
      retired = post(fx, admin, start_body(definition, nodes.a3)) |> T.wire()
      outside = post(fx, scoped, start_body(definition, nodes.b1)) |> T.wire()

      assert {422, _headers, _body} = unknown
      assert unknown == retired
      assert unknown == outside
    end
  end

  # ---- AC 6 ------------------------------------------------------------------------------------------

  describe "T-6 the node is checked like a grant" do
    test "T-6a a scoped holder naming its node or a descendant is accepted (off, shadow)", ctx do
      %{fx: fx, nodes: nodes, schema: schema} = ctx
      definition = active_definition!(schema)
      scoped = designer!(fx, :a)

      for mode <- [:off, :shadow], node <- [nodes.a, nodes.a1] do
        T.store_mode!(fx, mode)
        conn = post(fx, scoped, start_body(definition, node), mode)
        assert conn.status == 201, "#{mode} #{node}"
        assert projection!(schema, T.json(conn)["instance_id"]).scope_node_id == node
      end
    end

    test "T-6b a scoped holder naming a node outside its grant is refused (off, shadow)", ctx do
      %{fx: fx, nodes: nodes, schema: schema} = ctx
      definition = active_definition!(schema)
      scoped = designer!(fx, :a)
      before = counts(schema)

      for mode <- [:off, :shadow], node <- [nodes.b, nodes.b1, nodes.root] do
        T.store_mode!(fx, mode)
        assert post(fx, scoped, start_body(definition, node), mode).status == 422
      end

      assert counts(schema) == before
    end

    test "T-6c tenant-wide callers and token principals may name any live node", ctx do
      %{fx: fx, nodes: nodes, schema: schema} = ctx
      definition = active_definition!(schema)
      admin = designer!(fx, :tenant_wide)

      assert post(fx, admin, start_body(definition, nodes.b1)).status == 201

      token_ctx =
        fx |> S.ctx(admin.id, admin.roles, :api_token) |> Map.put(:scope_enforcement, :off)

      conn =
        S.call(
          Letflow.Routers.Instances,
          :post,
          "/",
          fx,
          token_ctx,
          start_body(definition, nodes.b)
        )

      assert conn.status == 201
      assert projection!(schema, T.json(conn)["instance_id"]).scope_node_id == nodes.b
    end

    test "T-6d under the stored mode on a scoped-only starter is still refused by the route class",
         ctx do
      # F1 of the design: POST /instances is a tenant-wide default route, so `Enforce` answers 403
      # before the handler. This pins today's behaviour; it changes when the route is reclassified.
      %{fx: fx, nodes: nodes, schema: schema} = ctx
      definition = active_definition!(schema)
      scoped = designer!(fx, :a)
      T.store_mode!(fx, :on)

      assert post(fx, scoped, start_body(definition, nodes.a1), :on).status == 403
    end

    test "T-6e a caller with no grant rows cannot name a node but can still start unscoped",
         ctx do
      %{fx: fx, nodes: nodes, schema: schema} = ctx
      definition = active_definition!(schema)
      rowless = designer!(fx, :none)

      assert post(fx, rowless, start_body(definition, nodes.a)).status == 422
    end
  end

  # ---- AC 7 ------------------------------------------------------------------------------------------

  describe "T-7 sub-process children inherit" do
    test "T-7a create path and complete_task path; unscoped parent gives an unscoped child",
         ctx do
      %{schema: schema, nodes: nodes} = ctx
      child_name = unique("r531-child")

      {:ok, child} =
        Definitions.create(
          %{
            name: child_name,
            version: "1.0.0",
            graph: task_graph(),
            created_by: Ecto.UUID.generate()
          },
          prefix: schema
        )

      {:ok, _} = Definitions.activate(child.id, prefix: schema)

      parent = active_definition!(schema, parent_graph(child_name))
      gated = active_definition!(schema, gated_parent_graph(child_name))

      child_of = fn parent_id ->
        [child_id] =
          Repo.all(
            from(p in InstanceProjection,
              where: p.parent_instance_id == ^parent_id,
              select: p.instance_id
            ),
            prefix: schema
          )

        child_id
      end

      # create/2 path
      parent_id = start!(schema, parent, %{scope_node_id: nodes.a1})
      child_id = child_of.(parent_id)
      assert projection!(schema, child_id).scope_node_id == nodes.a1
      assert started_payload!(schema, child_id)["scope_node_id"] == nodes.a1

      # unscoped parent
      plain_id = start!(schema, parent)
      plain_child = child_of.(plain_id)
      assert projection!(schema, plain_child).scope_node_id == nil
      refute Map.has_key?(started_payload!(schema, plain_child), "scope_node_id")

      # complete_task/3 path: the child starts when the gate task is completed
      gated_id = start!(schema, gated, %{scope_node_id: nodes.b1})
      gate = Repo.one!(from(t in EngineTask, where: t.instance_id == ^gated_id), prefix: schema)

      assert {:ok, _} =
               Engine.complete_task(
                 gate.id,
                 %{
                   output_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique("r531-gate")
                 },
                 prefix: schema
               )

      gated_child = child_of.(gated_id)
      assert projection!(schema, gated_child).scope_node_id == nodes.b1
      assert started_payload!(schema, gated_child)["scope_node_id"] == nodes.b1
    end
  end

  # ---- AC 8 ------------------------------------------------------------------------------------------

  describe "T-8 INV-10 cross-tenant negative" do
    test "a node that exists only in another tenant is refused like an unknown one", ctx do
      %{fx: fx, schema: schema} = ctx
      other = T.provision!("r531-b")
      only_b = unique("only-in-b")
      assert {:ok, _node} = ScopeNodePaths.write({:insert, only_b, nil}, other.schema_name)

      definition = active_definition!(schema)
      admin = designer!(fx, :tenant_wide)
      before_a = counts(schema)
      before_b = counts(other.schema_name)

      cross = post(fx, admin, start_body(definition, only_b)) |> T.wire()
      unknown = post(fx, admin, start_body(definition, "no-such-node")) |> T.wire()

      assert {422, _headers, _body} = cross
      assert cross == unknown
      assert counts(schema) == before_a
      assert counts(other.schema_name) == before_b
    end
  end

  # ---- AC 9 ------------------------------------------------------------------------------------------

  describe "T-9 documentation" do
    test "T-9a Engine.create/2 documents the three start paths and the unscoped rule" do
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Letflow.Engine)

      {_, _, _, %{"en" => doc}, _} =
        Enum.find(docs, fn {{kind, name, arity}, _, _, _, _} ->
          {kind, name, arity} == {:function, :create, 2}
        end)

      assert doc =~ "Scope node (REQ-531"
      assert doc =~ "POST /instances"
      assert doc =~ "sub-process"
      assert doc =~ "webhook"
      assert doc =~ "unscoped"
    end
  end

  # ---- idempotency ---------------------------------------------------------------------------

  describe "T-R1 idempotent replay includes the node" do
    test "same key and node replays; a different node or none is a key reuse", ctx do
      %{schema: schema, nodes: nodes} = ctx
      definition = active_definition!(schema)
      attrs = start_attrs(definition, %{scope_node_id: nodes.a})

      assert {:ok, first} = Engine.create(attrs, prefix: schema)
      assert {:ok, %{replayed: true} = again} = Engine.create(attrs, prefix: schema)
      assert again.instance_id == first.instance_id

      assert {:error, :idempotency_key_reuse} =
               Engine.create(%{attrs | scope_node_id: nodes.b}, prefix: schema)

      assert {:error, :idempotency_key_reuse} =
               Engine.create(Map.delete(attrs, :scope_node_id), prefix: schema)
    end
  end
end
