defmodule Letflow.Engine.PinResolverValidationScriptTest do
  @moduledoc """
  REQ-569 / GH #3246 AC6, AC7, AC8 (decision 0067 D9, slice F-1): the HUMAN_TASK
  `validation_script_key`/`validation_script_version` pair is collected and pinned as a `:script`
  pin, with the kind of the node checked against the kind of the row. Pure cases use a fake
  `script_lookup`; the started-instance cases go through the real `Runtime.pin_lookup/1`.
  `async: false` (tenant provisioning, application env).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine.PinResolver
  alias Letflow.Scripts.Runtime
  alias Letflow.Support.ScriptTaskFixture, as: F

  defp svc(id, key, version),
    do: %Node{
      id: id,
      node_type: :SERVICE_TASK,
      attributes: %{"script_key" => key, "script_version" => version}
    }

  defp human(id, key, version),
    do: %Node{
      id: id,
      node_type: :HUMAN_TASK,
      attributes: %{
        "role" => "REVIEWER",
        "validation_script_key" => key,
        "validation_script_version" => version
      }
    }

  defp resolve(nodes, lookup_fun) do
    lookup = %{PinResolver.default_lookup() | script_lookup: lookup_fun}

    PinResolver.resolve(
      %Graph{nodes: nodes, edges: []},
      %ProcessDefinition{name: "p569"},
      lookup,
      []
    )
  end

  # A fake registry: a key resolves at every version, with the given kind per key.
  defp fake(kinds) do
    fn key, version ->
      case Map.fetch(kinds, key) do
        {:ok, kind} ->
          {:ok,
           %{
             resolved_id: "id-#{key}",
             version: "#{version}",
             sha256: "sha-#{key}",
             hook_kind: kind
           }}

        :error ->
          {:error, :not_found}
      end
    end
  end

  defp script_pins(pins), do: Enum.filter(pins, &(&1.kind == :script))

  test "P1 a HUMAN_TASK pair is one :script pin and adds no other pin kind" do
    assert {:ok, pins, _schema} =
             resolve(
               [human("h", "check_amount", 1)],
               fake(%{"check_amount" => "form_validation"})
             )

    assert [
             %{
               kind: :script,
               ref: "check_amount",
               resolved_id: "id-check_amount",
               version: "1",
               sha256: "sha-check_amount",
               source: :resolved
             }
           ] = script_pins(pins)

    assert pins |> Enum.map(& &1.kind) |> Enum.sort() == [:script, :variable_schema]
  end

  test "P2 a key the lookup cannot resolve is unresolved_script_ref" do
    assert {:error, {:unresolved_script_ref, "nope"}} =
             resolve([human("h", "nope", 1)], fake(%{}))
  end

  test "P3 a row of the wrong kind is unresolved_script_ref, both directions" do
    assert {:error, {:unresolved_script_ref, "k"}} =
             resolve([human("h", "k", 1)], fake(%{"k" => "service_task"}))

    assert {:error, {:unresolved_script_ref, "k"}} =
             resolve([svc("s", "k", 1)], fake(%{"k" => "form_validation"}))
  end

  test "P4 different versions of one key conflict for any node types; the first in order wins" do
    lookup = fake(%{"a" => "service_task", "b" => "form_validation"})

    assert {:error, {:script_version_conflict, "a"}} =
             resolve([svc("s", "a", 1), human("h", "a", 2)], lookup)

    assert {:error, {:script_version_conflict, "b"}} =
             resolve([human("h1", "b", 1), human("h2", "b", 2)], lookup)

    assert {:error, {:script_version_conflict, "b"}} =
             resolve(
               [human("h1", "b", 1), svc("s", "a", 1), human("h2", "b", 2), svc("s2", "a", 2)],
               lookup
             )
  end

  test "P4a the same version on two HUMAN_TASK nodes is accepted as one pin" do
    assert {:ok, pins, _} =
             resolve(
               [human("h1", "b", 1), human("h2", "b", 1)],
               fake(%{"b" => "form_validation"})
             )

    assert [%{ref: "b"}] = script_pins(pins)
  end

  test "P4b the same key and version on both node types is refused (a row has one kind)" do
    for kind <- ["service_task", "form_validation"] do
      assert {:error, {:unresolved_script_ref, "k"}} =
               resolve([svc("s", "k", 1), human("h", "k", 1)], fake(%{"k" => kind}))
    end
  end

  test "P5 a SERVICE_TASK-only graph pins as before, also from a lookup without hook_kind" do
    lookup = fn "k", 1 -> {:ok, %{resolved_id: "r", version: "1", sha256: "s"}} end

    assert {:ok, pins, _} = resolve([svc("s", "k", 1)], lookup)
    assert [%{ref: "k", resolved_id: "r", sha256: "s"}] = script_pins(pins)
  end

  describe "against a tenant" do
    setup do
      previous = Application.fetch_env(:letflow, :form_validation_hook_enabled)
      Application.put_env(:letflow, :form_validation_hook_enabled, true)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:letflow, :form_validation_hook_enabled, old)
          :error -> Application.delete_env(:letflow, :form_validation_hook_enabled)
        end
      end)

      %{t: F.tenant_without_hmac!("r569-pin")}
    end

    defp human_graph(key, version) do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "review",
            "node_type" => "HUMAN_TASK",
            "attributes" => %{
              "role" => "REVIEWER",
              "validation_script_key" => key,
              "validation_script_version" => version
            }
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "review"},
          %{"id" => "e2", "source" => "review", "target" => "end"}
        ]
      }
    end

    defp started_pins(t, instance_id) do
      [started] = F.payloads(t.schema_name, instance_id, "INSTANCE_STARTED")
      started["pinned_versions"]
    end

    test "E1 an instance of an activated definition stores the :script pin with its sha256", %{
      t: t
    } do
      rule =
        F.published!(t.schema_name, "check_amount", F.doubling_source(), F.closed_manifest(),
          hook_kind: "form_validation"
        )

      definition = F.definition!(t.schema_name, human_graph("check_amount", rule.version), [])
      instance_id = F.start!(t.schema_name, definition, %{}, Ecto.UUID.generate())

      assert %{"ref" => "check_amount", "sha256" => sha, "resolved_id" => id, "version" => "1"} =
               Enum.find(started_pins(t, instance_id), &(&1["kind"] == "script"))

      assert {sha, id} == {rule.sha256, rule.id}
    end

    test "E2 a definition without the attributes starts with no script pin", %{t: t} do
      graph = human_graph("x", 1)
      graph = put_in(graph, ["nodes", Access.at(1), "attributes"], %{"role" => "REVIEWER"})
      definition = F.definition!(t.schema_name, graph, [])
      instance_id = F.start!(t.schema_name, definition, %{}, Ecto.UUID.generate())

      assert Enum.filter(started_pins(t, instance_id), &(&1["kind"] == "script")) == []
    end

    defp pending_task!(t, instance_id) do
      import Ecto.Query
      alias Letflow.Engine.Task, as: EngineTask

      Repo.one!(
        from(k in EngineTask, where: k.instance_id == ^instance_id and k.status == :pending),
        prefix: t.schema_name
      )
    end

    defp complete!(t, task_id) do
      Letflow.Engine.complete_task(
        task_id,
        %{
          output_variables: %{"amount" => 5},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: "r569-e3-#{System.unique_integer([:positive])}"
        },
        prefix: t.schema_name
      )
    end

    test "E3 completing the task of a definition with the pair behaves as without it", %{t: t} do
      rule =
        F.published!(t.schema_name, "check_amount", F.doubling_source(), F.closed_manifest(),
          hook_kind: "form_validation"
        )

      with_pair = F.definition!(t.schema_name, human_graph("check_amount", rule.version), [])

      plain_graph =
        put_in(human_graph("x", 1), ["nodes", Access.at(1), "attributes"], %{"role" => "REVIEWER"})

      without = F.definition!(t.schema_name, plain_graph, [])

      results =
        for d <- [with_pair, without] do
          instance_id = F.start!(t.schema_name, d, %{}, Ecto.UUID.generate())
          task = pending_task!(t, instance_id)
          assert {:ok, result} = complete!(t, task.id)
          Map.drop(result, [:task_id, :instance_id, :completed_at])
        end

      assert [same, same] = results
      assert same.instance_status == :completed
      assert same.variables == %{"amount" => 5}
    end

    test "E5 the real lookup refuses the cross-kind graph that activation refuses", %{t: t} do
      rule = F.published!(t.schema_name, "kk", F.doubling_source(), F.closed_manifest())
      lookup = %{PinResolver.default_lookup() | script_lookup: Runtime.pin_lookup(t.schema_name)}

      assert {:error, {:unresolved_script_ref, "kk"}} =
               PinResolver.resolve(
                 %Graph{
                   nodes: [svc("s", "kk", rule.version), human("h", "kk", rule.version)],
                   edges: []
                 },
                 %ProcessDefinition{name: "p569"},
                 lookup,
                 []
               )
    end
  end
end
