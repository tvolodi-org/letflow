defmodule Letflow.Engine.ServiceTaskSubprocessCascadeTest do
  @moduledoc """
  GH #2648 (found by the GH #2587 PR C probe, design `gh2587-req499-pr-c-service-task-writes.md`
  F-C10): the sub-process completion cascade on the SERVICE_TASK apply paths.

  A sub-process CHILD whose last node is a SERVICE_TASK (HTTP, applied through
  `Engine.advance_after_service_task_outcome/4`; script, applied through
  `ScriptTaskDispatcher.run_claimed/2` -> `Engine.apply_script_task_result/3`) completes, and the
  parent token waiting at its `SUB_PROCESS` node must wake in the SAME transaction, exactly as it
  does when the child's last node is a HUMAN_TASK. Before the fix the child completed and the
  parent stayed waiting forever (this file's predecessor, the OQ-C8 probe, pinned that).

    * HUMAN, HTTP and script last nodes leave the parent in the same state with the same events;
    * the cascade recurses grandparent-ward;
    * a failure inside the cascade rolls the whole apply back (no half-applied child);
    * a child last SERVICE node with `entity_writes` cascades too (lock order: dispatch row,
      child projection, entity type rows, THEN the parent token and projection);
    * a duplicate apply does not cascade twice;
    * the stream replays to the live parent state.

  Real Postgres, `async: false`. No HTTP: the poller's re-entry (mark `advanced` +
  `advance_after_service_task_outcome/4`) is performed by the test.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    Sandbox.mode(Repo, :auto)
    :ok
  end

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp create_active!(schema, name, graph) do
    assert {:ok, definition} =
             Definitions.create(
               %{name: name, version: "1.0", graph: graph, created_by: Ecto.UUID.generate()},
               prefix: schema
             )

    assert {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)
    active
  end

  @http_attrs %{
    "endpoint" => "https://example.test/child",
    "method" => "POST",
    "timeout_ms" => 300_000
  }

  # START -> HUMAN_TASK "ct" -> <last> -> END. The human task comes first because a child created
  # by a SUB_PROCESS node arms no dispatch row for a SERVICE_TASK directly after START; completing
  # "ct" arms it through the completion hop chain.
  defp child_graph(:human) do
    child_graph_with(%{
      "id" => "last",
      "node_type" => "HUMAN_TASK",
      "attributes" => %{"role" => "role-x"}
    })
  end

  defp child_graph(:http) do
    child_graph_with(%{
      "id" => "last",
      "node_type" => "SERVICE_TASK",
      "attributes" => @http_attrs
    })
  end

  defp child_graph({:script, key, version}) do
    child_graph_with(%{
      "id" => "last",
      "node_type" => "SERVICE_TASK",
      "attributes" => %{"script_key" => key, "script_version" => version}
    })
  end

  defp child_graph_with(last) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ct", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-x"}},
        last,
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "c0", "source" => "start", "target" => "ct"},
        %{"id" => "c1", "source" => "ct", "target" => "last"},
        %{"id" => "c2", "source" => "last", "target" => "end"}
      ]
    }
  end

  # START -> SUB_PROCESS(child) -> HUMAN_TASK "after" -> END
  defp parent_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        %{"id" => "after", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-x"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "sub"},
        %{"id" => "p1", "source" => "sub", "target" => "after"},
        %{"id" => "p2", "source" => "after", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK "mt" -> SUB_PROCESS(child) -> END: completes the moment its child does.
  # (The human task comes first: a child's own initial hop chain spawns no grandchild.)
  defp middle_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "mt", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-x"}},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "m0", "source" => "start", "target" => "mt"},
        %{"id" => "m2", "source" => "mt", "target" => "sub"},
        %{"id" => "m1", "source" => "sub", "target" => "end"}
      ]
    }
  end

  defp start_instance!(schema, definition) do
    assert {:ok, %{instance_id: instance_id}} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("c2648-start")
               },
               prefix: schema
             )

    instance_id
  end

  defp child_of!(schema, parent_id) do
    assert [child_id] =
             InstanceProjection
             |> where([p], p.parent_instance_id == ^parent_id)
             |> select([p], p.instance_id)
             |> Repo.all(prefix: schema)

    child_id
  end

  defp pending_task!(schema, instance_id) do
    assert [task] =
             EngineTask
             |> where([t], t.instance_id == ^instance_id and t.status == :pending)
             |> Repo.all(prefix: schema)

    task
  end

  defp complete!(schema, task) do
    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("c2648-complete")
               },
               prefix: schema
             )
  end

  # The HTTP re-entry the dispatcher performs, without the HTTP call. Returns the apply result.
  defp apply_http(schema, child_id) do
    assert [row] =
             ServiceTaskDispatch
             |> where([d], d.instance_id == ^child_id)
             |> Repo.all(prefix: schema)

    advanced = row |> Ecto.Changeset.change(%{status: "advanced"}) |> Repo.update!(prefix: schema)
    Engine.advance_after_service_task_outcome(advanced.id, {:advance, %{}}, Repo, schema)
  end

  # What a parent shows after its child's last node ran: state, position, events, tasks.
  defp snapshot(schema, instance_id) do
    projection = Repo.get!(InstanceProjection, instance_id, prefix: schema)
    {:ok, events} = Reconstruction.read_full_log(instance_id, schema, 1)

    tasks =
      EngineTask
      |> where([t], t.instance_id == ^instance_id)
      |> order_by([t], asc: t.node_id)
      |> Repo.all(prefix: schema)
      |> Enum.map(&{&1.node_id, &1.status})

    %{
      status: projection.status,
      current_nodes: projection.current_nodes,
      variables: projection.variables,
      event_types: Enum.map(events, & &1.event_type),
      tasks: tasks
    }
  end

  defp script_manifest do
    %{
      "input_schema" => %{"type" => "object", "properties" => %{}},
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"total" => %{"type" => "integer"}},
        "required" => ["total"],
        "additionalProperties" => false
      },
      "fail_codes" => ["too_big"],
      "limits" => %{"instructions" => 200_000, "timeout_ms" => 1_000}
    }
  end

  # A sub-process child's INSTANCE_STARTED carries no `pinned_versions` (separate, pre-existing
  # limitation, reported on the PR: a script/catalog node inside a child fails with
  # `script_task_pin_unresolved`). To reach the child's script apply at all, the child's start
  # event is given the pins a top-level instance of the same definition records. Test-only.
  defp give_child_script_pins!(schema, child_def, child_id) do
    donor_id = start_instance!(schema, child_def)
    {:ok, donor_events} = Reconstruction.read_full_log(donor_id, schema, 1)
    started = Enum.find(donor_events, &(&1.event_type == "INSTANCE_STARTED"))
    pins = started.payload["pinned_versions"] || started.payload[:pinned_versions]
    assert [_ | _] = pins

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")

      Repo.query!(
        """
        UPDATE "#{schema}".events
        SET payload = payload || jsonb_build_object('pinned_versions', $1::jsonb)
        WHERE instance_id = $2 AND event_type = 'INSTANCE_STARTED'
        """,
        [pins, Ecto.UUID.dump!(child_id)]
      )
    end)
  end

  # Builds parent + child (last node `kind`), runs the child's last node, returns the ids.
  defp run_scenario!(t, kind) do
    schema = t.schema_name
    child_name = unique("c2648-child")

    child_kind =
      case kind do
        :script ->
          rule =
            F.published!(
              schema,
              "k#{System.unique_integer([:positive])}",
              "return { total = 7 }",
              script_manifest()
            )

          {:script, rule.key, rule.version}

        other ->
          other
      end

    child_def = create_active!(schema, child_name, child_graph(child_kind))
    parent = create_active!(schema, unique("c2648-parent"), parent_graph(child_name))
    parent_id = start_instance!(schema, parent)
    child_id = child_of!(schema, parent_id)

    if kind == :script, do: give_child_script_pins!(schema, child_def, child_id)

    complete!(schema, pending_task!(schema, child_id))

    case kind do
      :human -> complete!(schema, pending_task!(schema, child_id))
      :http -> assert {:ok, :advanced} = apply_http(schema, child_id)
      :script -> assert {_row, {:ok, :applied}} = F.run_next!(schema)
    end

    %{parent_id: parent_id, child_id: child_id}
  end

  describe "the parent wakes when the child's last node is a service or script task" do
    test "HTTP SERVICE_TASK last node: same parent state and events as the HUMAN path" do
      t = F.tenant!("gh2648-http")
      schema = t.schema_name

      human = run_scenario!(t, :human)
      http = run_scenario!(t, :http)

      assert Repo.get!(InstanceProjection, http.child_id, prefix: schema).status == :completed

      parent = snapshot(schema, http.parent_id)
      assert parent.status == :active
      assert parent.current_nodes == ["after"]
      assert "SUB_PROCESS_COMPLETED" in parent.event_types
      assert [{"after", :pending}] = parent.tasks

      assert parent == snapshot(schema, human.parent_id)
    end

    test "script task last node: same parent state and events as the HUMAN path" do
      t = F.tenant!("gh2648-script")
      schema = t.schema_name

      human = run_scenario!(t, :human)
      script = run_scenario!(t, :script)

      assert Repo.get!(InstanceProjection, script.child_id, prefix: schema).status == :completed

      parent = snapshot(schema, script.parent_id)
      assert parent.status == :active
      assert parent.current_nodes == ["after"]
      assert "SUB_PROCESS_COMPLETED" in parent.event_types
      assert [{"after", :pending}] = parent.tasks

      # the script's declared output reaches the parent through the sub-process merge; every
      # other part of the state and the event set equals the HUMAN path's
      assert parent.variables == %{"total" => 7}

      assert Map.delete(parent, :variables) ==
               Map.delete(snapshot(schema, human.parent_id), :variables)
    end

    test "the cascade recurses: a service-ended grandchild completes the middle and wakes the grandparent" do
      t = F.tenant!("gh2648-gp")
      schema = t.schema_name

      child_name = unique("c2648-gc")
      middle_name = unique("c2648-mid")
      create_active!(schema, child_name, child_graph(:http))
      create_active!(schema, middle_name, middle_graph(child_name))
      grand = create_active!(schema, unique("c2648-gp"), parent_graph(middle_name))

      grand_id = start_instance!(schema, grand)
      middle_id = child_of!(schema, grand_id)
      complete!(schema, pending_task!(schema, middle_id))
      child_id = child_of!(schema, middle_id)

      complete!(schema, pending_task!(schema, child_id))
      assert {:ok, :advanced} = apply_http(schema, child_id)

      assert Repo.get!(InstanceProjection, child_id, prefix: schema).status == :completed
      assert Repo.get!(InstanceProjection, middle_id, prefix: schema).status == :completed

      grandparent = snapshot(schema, grand_id)
      assert grandparent.status == :active
      assert grandparent.current_nodes == ["after"]
      assert "SUB_PROCESS_COMPLETED" in grandparent.event_types
      assert [{"after", :pending}] = grandparent.tasks

      assert "SUB_PROCESS_COMPLETED" in snapshot(schema, middle_id).event_types
    end

    test "a duplicate apply does not cascade twice" do
      t = F.tenant!("gh2648-dup")
      schema = t.schema_name
      %{parent_id: parent_id, child_id: child_id} = run_scenario!(t, :http)

      before = snapshot(schema, parent_id)

      dispatch =
        Repo.one!(from(d in ServiceTaskDispatch, where: d.instance_id == ^child_id),
          prefix: schema
        )

      second =
        Engine.advance_after_service_task_outcome(dispatch.id, {:advance, %{}}, Repo, schema)

      refute match?({:ok, :advanced}, second)

      assert snapshot(schema, parent_id) == before
      assert Enum.count(before.event_types, &(&1 == "SUB_PROCESS_COMPLETED")) == 1
    end

    test "replay: the parent's event stream reconstructs the live parent state" do
      t = F.tenant!("gh2648-replay")
      schema = t.schema_name
      %{parent_id: parent_id} = run_scenario!(t, :http)

      projection = Repo.get!(InstanceProjection, parent_id, prefix: schema)

      assert {:ok, %{instance_state: state}} =
               Reconstruction.reconstruct_instance(parent_id, prefix: schema)

      assert projection.current_nodes == ["after"]
      assert state.status == projection.status
      assert state.variables == projection.variables
      assert Enum.map(state.tokens, & &1.node_id) == projection.current_nodes
    end
  end

  describe "atomicity" do
    test "a failure inside the cascade rolls the service apply back: nothing half-applied" do
      t = F.tenant!("gh2648-atomic")
      schema = t.schema_name
      child_name = unique("c2648-child")
      create_active!(schema, child_name, child_graph(:http))
      parent = create_active!(schema, unique("c2648-parent"), parent_graph(child_name))
      parent_id = start_instance!(schema, parent)
      child_id = child_of!(schema, parent_id)
      complete!(schema, pending_task!(schema, child_id))

      # the cascade appends SUB_PROCESS_COMPLETED to the parent: make that insert fail
      Repo.query!("""
      CREATE FUNCTION "#{schema}".gh2648_refuse() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'gh2648 refused'; END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER gh2648_refuse BEFORE INSERT ON "#{schema}".events
      FOR EACH ROW WHEN (NEW.event_type = 'SUB_PROCESS_COMPLETED')
      EXECUTE FUNCTION "#{schema}".gh2648_refuse()
      """)

      parent_before = snapshot(schema, parent_id)
      child_before = snapshot(schema, child_id)

      assert {:error, _reason} = apply_http(schema, child_id)

      assert snapshot(schema, parent_id) == parent_before
      assert snapshot(schema, child_id) == child_before
      assert Repo.get!(InstanceProjection, child_id, prefix: schema).status == :active
    end
  end

  describe "child last SERVICE node with entity_writes (C2 live path)" do
    test "cascades; the child's locks come before the parent token and projection" do
      base = Fx.tenant_case!("gh2648-ew")
      schema = base.schema
      Fx.define_type!(schema, "stock_move", %{})

      svc_node =
        [Fx.line("stock_move", %{"label" => %{"const" => "x"}})]
        |> Fx.service_graph()
        |> Map.fetch!("nodes")
        |> Enum.find(&(&1["id"] == "svc"))

      child =
        Fx.legacy_activate!(
          schema,
          base.user,
          child_graph_with(%{svc_node | "id" => "last"}),
          [{"stock_move", "create"}]
        )

      parent_def = Fx.legacy_activate!(schema, base.user, parent_graph(child.name), [])

      parent_id = start_instance!(schema, parent_def)
      child_id = child_of!(schema, parent_id)
      complete!(schema, pending_task!(schema, child_id))

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> apply_http(schema, child_id) end)

      assert {:ok, :advanced} = result
      assert length(Fx.records(schema, "stock_move")) == 1

      parent = snapshot(schema, parent_id)
      assert parent.current_nodes == ["after"]
      assert "SUB_PROCESS_COMPLETED" in parent.event_types

      tables =
        for %{query: sql} <- queries, sql =~ "FOR UPDATE" do
          [_, table] = Regex.run(~r/FROM "[^"]+"\."([a-z_]+)"/, sql)
          table
        end

      indexed = Enum.with_index(tables)
      first = fn name -> Enum.find_index(tables, &(&1 == name)) end

      last = fn name ->
        indexed |> Enum.filter(&(elem(&1, 0) == name)) |> List.last() |> elem(1)
      end

      assert first.("service_task_dispatches") < first.("instance_projections")
      assert first.("instance_sequence") < last.("tokens")
      assert first.("instance_projections") < last.("tokens")
      assert last.("tokens") < last.("audit_chain_locks")
    end
  end
end
