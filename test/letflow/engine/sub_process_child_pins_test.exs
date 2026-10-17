defmodule Letflow.Engine.SubProcessChildPinsTest do
  @moduledoc """
  GH #2694: a sub-process child's `INSTANCE_STARTED` carries `pinned_versions`, resolved FRESH
  for the child's own definition with the same lookup `create/2` uses (design
  `lib/letflow/design/gh2694-subprocess-child-pins.md`).

    * the recorded pins equal what a top-level instance of the same definition records, and
      `PinResolver.reconstruct_effective_pins/2` reads them back (no reconstruction gap);
    * parent and child pins are independent (same script key, different versions);
    * a child definition whose pin cannot be resolved is refused: nothing is written, on the
      `create/2` path (aborted) and on the `complete_task/3` path (parent to ERROR).

  The end-to-end completion of a script / catalog SERVICE_TASK inside a child is pinned in
  `service_task_subprocess_cascade_test.exs`. Real Postgres, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.PinResolver
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version
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

  defp manifest do
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

  defp publish!(schema, key), do: F.published!(schema, key, "return { total = 7 }", manifest())

  defp sub_node(child_name) do
    %{
      "id" => "sub",
      "node_type" => "SUB_PROCESS",
      "attributes" => %{"definition_name" => child_name}
    }
  end

  defp end_node, do: %{"id" => "end", "node_type" => "END"}

  # START -> SUB_PROCESS -> END
  defp parent_graph(child_name) do
    %{
      "nodes" => [%{"id" => "start", "node_type" => "START"}, sub_node(child_name), end_node()],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "sub"},
        %{"id" => "p1", "source" => "sub", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK "gate" -> SUB_PROCESS -> END
  defp gated_parent_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gate", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-x"}},
        sub_node(child_name),
        end_node()
      ],
      "edges" => [
        %{"id" => "g0", "source" => "start", "target" => "gate"},
        %{"id" => "g1", "source" => "gate", "target" => "sub"},
        %{"id" => "g2", "source" => "sub", "target" => "end"}
      ]
    }
  end

  # START -> SUB_PROCESS -> SERVICE_TASK (script key@version) -> END
  defp parent_with_script_graph(child_name, key, version) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        sub_node(child_name),
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"script_key" => key, "script_version" => version}
        },
        end_node()
      ],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "sub"},
        %{"id" => "p1", "source" => "sub", "target" => "svc"},
        %{"id" => "p2", "source" => "svc", "target" => "end"}
      ]
    }
  end

  defp start_attrs(definition) do
    %{
      definition_id: definition.id,
      initial_variables: %{},
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique("c2694-start")
    }
  end

  defp start_instance!(schema, definition) do
    assert {:ok, %{instance_id: instance_id}} =
             Engine.create(start_attrs(definition), prefix: schema)

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

  defp started_payload!(schema, instance_id) do
    {:ok, events} = Reconstruction.read_full_log(instance_id, schema, 1)
    started = Enum.find(events, &(&1.event_type == "INSTANCE_STARTED"))
    if is_binary(started.payload), do: Jason.decode!(started.payload), else: started.payload
  end

  defp effective_pins!(schema, instance_id) do
    assert {:ok, pins} = PinResolver.reconstruct_effective_pins(instance_id, prefix: schema)
    pins
  end

  defp count(schema, source),
    do: Repo.aggregate(from(r in source), :count, prefix: schema)

  defp projection_count(schema),
    do: Repo.aggregate(InstanceProjection, :count, :instance_id, prefix: schema)

  defp identity(pins), do: Enum.map(pins, &{&1.kind, &1.ref, &1.resolved_id, &1.version})

  describe "the child's INSTANCE_STARTED carries the pins resolved for the child's definition" do
    test "equal to a top-level instance of the same definition; reconstruction reads them back" do
      t = F.tenant!("gh2694-pins")
      schema = t.schema_name
      rule = publish!(schema, "k#{System.unique_integer([:positive])}")

      child_name = unique("c2694-child")
      child_graph = F.human_then_script_graph(rule.key, rule.version)
      child_def = create_active!(schema, child_name, child_graph)
      parent = create_active!(schema, unique("c2694-parent"), parent_graph(child_name))

      child_id = child_of!(schema, start_instance!(schema, parent))
      donor_id = start_instance!(schema, child_def)

      payload = started_payload!(schema, child_id)
      assert [_ | _] = payload["pinned_versions"]
      assert payload["pin_conflicts"] == []

      child_pins = effective_pins!(schema, child_id)

      assert {:ok, %{resolved_id: resolved, version: version}} =
               PinResolver.pin_for(child_pins, :script, rule.key)

      assert resolved == rule.id
      assert version == Integer.to_string(rule.version)

      # reconstruction of the child stream == what a top-level instance of the definition pins
      assert identity(child_pins) == identity(effective_pins!(schema, donor_id))
      assert payload["pinned_versions"] == started_payload!(schema, donor_id)["pinned_versions"]
    end

    test "parent and child pins are independent: same script key, different versions" do
      t = F.tenant!("gh2694-indep")
      schema = t.schema_name
      key = "k#{System.unique_integer([:positive])}"
      v1 = publish!(schema, key)
      v2 = publish!(schema, key)
      assert {v1.version, v2.version} == {1, 2}

      child_name = unique("c2694-child")
      create_active!(schema, child_name, F.human_then_script_graph(key, 2))

      parent =
        create_active!(
          schema,
          unique("c2694-parent"),
          parent_with_script_graph(child_name, key, 1)
        )

      parent_id = start_instance!(schema, parent)
      child_id = child_of!(schema, parent_id)

      assert {:ok, %{version: "1", resolved_id: parent_rule}} =
               PinResolver.pin_for(effective_pins!(schema, parent_id), :script, key)

      assert {:ok, %{version: "2", resolved_id: child_rule}} =
               PinResolver.pin_for(effective_pins!(schema, child_id), :script, key)

      assert parent_rule == v1.id
      assert child_rule == v2.id
    end
  end

  describe "a child definition with an unresolvable pin is refused" do
    test "create/2 path: the parent is not created, nothing is written" do
      t = F.tenant!("gh2694-fail-create")
      schema = t.schema_name
      rule = publish!(schema, "k#{System.unique_integer([:positive])}")

      child_name = unique("c2694-child")

      child_def =
        create_active!(schema, child_name, F.human_then_script_graph(rule.key, rule.version))

      parent = create_active!(schema, unique("c2694-parent"), parent_graph(child_name))

      F.retire_raw!(schema, rule)
      before_count = projection_count(schema)
      events_before = count(schema, "events")
      snapshots_before = count(schema, "instance_definition_snapshots")

      assert {:error,
              {:activation_failed,
               {:subprocess_interface_violation, {:pin_resolution_failed, _reason}}}} =
               Engine.create(start_attrs(parent), prefix: schema)

      assert projection_count(schema) == before_count
      assert count(schema, "events") == events_before
      # create/2 snapshots the PARENT's definition before child preparation (pre-existing: an
      # orphan snapshot is left by any later activation refusal); the refused child adds none.
      snaps =
        Repo.all(from(r in "instance_definition_snapshots", select: r.definition_id),
          prefix: schema
        )

      assert length(snaps) - snapshots_before <= 1
      assert Enum.all?(snaps, &(Ecto.UUID.load!(&1) != child_def.id))
    end

    test "a retired catalog entry in the child definition refuses the child (catalog pin)" do
      t = F.tenant!("gh2694-fail-catalog")
      schema = t.schema_name
      service_id = unique("c2694-svc")

      on_exit(fn ->
        Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))
        Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
      end)

      assert {:ok, _} =
               ServiceCatalog.register(%{
                 service_id: service_id,
                 endpoint_url: "https://example.test/c2694",
                 required_auth: :NONE,
                 timeout_ms: 5_000,
                 scope: :global
               })

      child_name = unique("c2694-child")

      child_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "ct", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "role-x"}},
          %{
            "id" => "svc",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"service_id" => service_id, "timeout_ms" => 5_000}
          },
          end_node()
        ],
        "edges" => [
          %{"id" => "c0", "source" => "start", "target" => "ct"},
          %{"id" => "c1", "source" => "ct", "target" => "svc"},
          %{"id" => "c2", "source" => "svc", "target" => "end"}
        ]
      }

      create_active!(schema, child_name, child_graph)
      parent = create_active!(schema, unique("c2694-parent"), parent_graph(child_name))

      assert {:ok, _} = ServiceCatalog.retire(service_id)
      before_count = projection_count(schema)

      assert {:error,
              {:activation_failed,
               {:subprocess_interface_violation, {:pin_resolution_failed, _reason}}}} =
               Engine.create(start_attrs(parent), prefix: schema)

      assert projection_count(schema) == before_count
    end

    test "complete_task/3 path: the parent goes to ERROR, no child is created, the gate task stays pending" do
      t = F.tenant!("gh2694-fail-complete")
      schema = t.schema_name
      rule = publish!(schema, "k#{System.unique_integer([:positive])}")

      child_name = unique("c2694-child")
      create_active!(schema, child_name, F.human_then_script_graph(rule.key, rule.version))
      parent = create_active!(schema, unique("c2694-parent"), gated_parent_graph(child_name))
      parent_id = start_instance!(schema, parent)

      assert [gate] =
               EngineTask
               |> where([t], t.instance_id == ^parent_id and t.status == :pending)
               |> Repo.all(prefix: schema)

      F.retire_raw!(schema, rule)
      before_count = projection_count(schema)

      assert {:error,
              {:instance_execution_error, :subprocess_interface_violation,
               {:field, "definition_name"}}} =
               Engine.complete_task(
                 gate.id,
                 %{
                   output_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique("c2694-complete")
                 },
                 prefix: schema
               )

      projection = Repo.get!(InstanceProjection, parent_id, prefix: schema)
      assert projection.status == :error
      assert projection.error_detail["details"]["code"] == "SUB_PROCESS_PIN_UNRESOLVED"
      assert projection_count(schema) == before_count
      assert Repo.get!(EngineTask, gate.id, prefix: schema).status == :pending
    end
  end
end
