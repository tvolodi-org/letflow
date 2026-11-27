defmodule Letflow.Engine.ModuleStartTest do
  @moduledoc """
  T-2444 (T-2443 review of T-2430): a definition whose nodes carry `module_writes` is started only by
  its module's own code (`Engine.create/2` with `module_start: true`). The public route is proved in
  `modules/stock/module_start_route_test.exs` and `modules/assets/module_start_route_test.exs`; this
  file proves the engine rule itself and the two other start paths of the route map T-2445:
  a SUB_PROCESS child of a tenant parent (S2) and a scheduled job (S3).
  Tests: ES-1 `create/2` by name and by id, ES-2 a module definition without write lines is unchanged,
  ES-3 a sub-process child of a tenant parent is refused, ES-4 a scheduled job is refused and the job
  fails closed with `definition_not_found`, ES-5 only the three start sites in `lib/` set the option, ES-6 (T-3101, G-SUB-1) a parent with no
  write lines whose transitive child has them is module-only too, ES-7 (T-3101, G-SUB-2) the refused
  completion keys include the children's.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Engine.WriteTargets
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Repo
  alias Letflow.Scheduler.ScheduledJobSweep
  alias Letflow.TestSupport.ScheduledJobFixture, as: Sj

  @now ~U[2026-06-01 12:30:00.000000Z]
  @due ~U[2026-06-01 12:00:00.000000Z]

  setup do
    base = Mw.tenant!("ms-eng")
    writes = Mw.activate_installed!(base.schema, base.user, "fxl_post_module")
    plain = Mw.activate_installed!(base.schema, base.user, "fxl_task_plain")
    Map.merge(base, %{writes: writes, plain: plain})
  end

  defp attrs(ref, vars \\ %{"label" => "x"}) do
    Map.merge(ref, %{
      initial_variables: vars,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: "ms-#{System.unique_integer([:positive])}"
    })
  end

  defp count(schema), do: Repo.aggregate(InstanceProjection, :count, prefix: schema)

  test "ES-1 create/2 refuses a module_writes definition by name and by id; module_start starts it",
       ctx do
    assert {:error, :definition_not_found} =
             Engine.create(attrs(%{definition_name: ctx.writes.name}), prefix: ctx.schema)

    assert {:error, :definition_not_found} =
             Engine.create(attrs(%{definition_id: ctx.writes.id}), prefix: ctx.schema)

    # the flag is a literal `true`: nothing else opens the door
    for value <- [false, nil, "true", 1] do
      assert {:error, :definition_not_found} =
               Engine.create(attrs(%{definition_id: ctx.writes.id}),
                 prefix: ctx.schema,
                 module_start: value
               )
    end

    assert count(ctx.schema) == 0

    assert {:ok, %{instance_id: id}} =
             Engine.create(attrs(%{definition_name: ctx.writes.name}),
               prefix: ctx.schema,
               module_start: true
             )

    assert count(ctx.schema) == 1
    assert is_binary(id)
  end

  test "ES-2 a stamped definition without module_writes starts as before", ctx do
    assert {:ok, %{instance_id: _}} =
             Engine.create(attrs(%{definition_name: ctx.plain.name}, %{}), prefix: ctx.schema)
  end

  test "ES-3 a tenant parent cannot start a module_writes definition as its SUB_PROCESS child",
       ctx do
    parent_graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => ctx.writes.name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "p0", "source" => "start", "target" => "sub"},
        %{"id" => "p1", "source" => "sub", "target" => "end"}
      ]
    }

    {:ok, row} =
      Definitions.create(
        %{
          name: "ms-parent-#{System.unique_integer([:positive])}",
          version: "1.0",
          graph: parent_graph,
          created_by: ctx.user.id
        },
        prefix: ctx.schema
      )

    {:ok, %{definition: parent}} = Definitions.activate(row.id, prefix: ctx.schema)

    result =
      Engine.create(attrs(%{definition_id: parent.id}, %{"label" => "x", "posting" => %{}}),
        prefix: ctx.schema
      )

    refute match?({:ok, %{status: :active}}, result), inspect(result)

    children =
      Repo.aggregate(
        from(p in InstanceProjection, where: not is_nil(p.parent_instance_id)),
        :count,
        prefix: ctx.schema
      )

    assert children == 0
  end

  test "ES-4 a scheduled job of a module_writes definition fails closed, nothing is started",
       ctx do
    actor = Sj.actor!(ctx.schema)
    job = Sj.job!(ctx.schema, actor.id, ctx.writes.name, %{variables: %{"label" => "x"}}, @due)

    assert :ok = ScheduledJobSweep.run(ctx.schema, @now)

    row = Repo.get!(Letflow.ScheduledJobs.Job, job.id, prefix: ctx.schema)
    assert row.last_outcome == "definition_not_found"
    assert row.consecutive_failures == 1
    assert count(ctx.schema) == 0
  end

  defp parent_of!(ctx, child_name) do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "A"}},
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

    {:ok, row} =
      Definitions.create(
        %{
          name: "ms-tparent-#{System.unique_integer([:positive])}",
          version: "1.0",
          graph: graph,
          created_by: ctx.user.id
        },
        prefix: ctx.schema
      )

    {:ok, %{definition: parent}} = Definitions.activate(row.id, prefix: ctx.schema)
    parent
  end

  test "ES-6 a parent whose transitive child has module_writes is module-only: public start 404",
       ctx do
    parent = parent_of!(ctx, ctx.writes.name)

    for ref <- [%{definition_id: parent.id}, %{definition_name: parent.name}] do
      assert {:error, :definition_not_found} = Engine.create(attrs(ref), prefix: ctx.schema)
    end

    assert count(ctx.schema) == 0

    assert {:ok, %{instance_id: _}} =
             Engine.create(attrs(%{definition_id: parent.id}),
               prefix: ctx.schema,
               module_start: true
             )

    # a parent of a plain child still starts publicly
    plain_parent = parent_of!(ctx, ctx.plain.name)

    assert {:ok, %{instance_id: _}} =
             Engine.create(attrs(%{definition_id: plain_parent.id}, %{}), prefix: ctx.schema)
  end

  test "ES-7 completion keys read by a transitive child's module_writes are refused", ctx do
    parent = parent_of!(ctx, ctx.writes.name)
    {:ok, graph} = Engine.build_graph(parent.graph)
    out = %{"label" => "forged", "note" => "ok"}

    # without the tenant prefix the parent graph alone reads nothing (the old behaviour)
    assert WriteTargets.refused_keys(graph, "ht", out) == []
    assert WriteTargets.refused_keys(graph, "ht", out, ctx.schema) == ["label"]
    assert WriteTargets.write_read_keys(graph, ctx.schema) == MapSet.new(["label"])

    # the node's own declared input still passes
    declared =
      update_in(graph.nodes, fn nodes ->
        Enum.map(nodes, fn
          %{id: "ht"} = n ->
            %{n | attributes: Map.put(n.attributes, "completer_inputs", ["label"])}

          n ->
            n
        end)
      end)

    assert WriteTargets.refused_keys(declared, "ht", out, ctx.schema) == []
    assert WriteTargets.refused_keys(graph, "ht", out, "no_such_schema") == []
  end

  test "ES-5 only the stock, assets and maintenance start sites set module_start in lib/" do
    hits =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        File.read!(path) |> String.split("\n") |> Enum.any?(&code_sets_option?/1)
      end)
      |> Enum.sort()

    assert hits == [
             "lib/letflow/modules/assets/documents/posting.ex",
             "lib/letflow/modules/maintenance/orders.ex",
             "lib/letflow/modules/stock/documents/posting.ex"
           ]
  end

  # a code line (not a comment or a doc line) that passes `module_start: true`
  defp code_sets_option?(line) do
    trimmed = String.trim_leading(line)

    String.contains?(line, "module_start: true") and not String.starts_with?(trimmed, "#") and
      not String.starts_with?(trimmed, "`") and not String.contains?(trimmed, "`module_start")
  end
end
