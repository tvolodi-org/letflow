Code.require_file("procurement_fixture.exs", __DIR__)

defmodule Letflow.Modules.Procurement.RouteIndependenceTest do
  @moduledoc """
  GH #3162 / REQ-544 part 2, criterion 6 (spec: state/tasks/T-0746/design.md, test R1): two process
  definitions with different approval routes (one approval task; two in sequence) call the same
  `Decisions.record/3` operations and both instances complete, with the module's manifest and
  files unchanged.

  Limitation, stated on purpose: no engine-to-module dispatch exists (a service task is HTTP-config
  based and criterion 11 forbids an engine change), so the test drives the operation when each
  approval task completes, which is what a process's service task calls through the router.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Modules.Procurement
  alias Letflow.Modules.Procurement.Decision
  alias Letflow.Modules.Procurement.Decisions
  alias Letflow.ProcurementFixture, as: Fixture
  alias Letflow.Repo

  setup do
    ctx = Fixture.tenant!("gh3162ri")
    requester = Ecto.UUID.generate()
    Map.merge(ctx, %{requester: requester})
  end

  defp graph(roles) do
    ids = Enum.with_index(roles, 1) |> Enum.map(fn {role, i} -> {"task#{i}", role} end)

    nodes =
      [%{"id" => "start", "node_type" => "START"}] ++
        Enum.map(ids, fn {id, role} ->
          %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => %{"role" => role}}
        end) ++ [%{"id" => "end", "node_type" => "END"}]

    chain = ["start"] ++ Enum.map(ids, &elem(&1, 0)) ++ ["end"]

    edges =
      chain
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index(1)
      |> Enum.map(fn {[from, to], i} ->
        %{"id" => "e#{i}", "source" => from, "target" => to}
      end)

    %{"nodes" => nodes, "edges" => edges}
  end

  defp start!(ctx, roles) do
    attrs = %{
      name: "gh3162-route-#{System.unique_integer([:positive])}",
      version: "1.0.0",
      graph: graph(roles),
      created_by: Ecto.UUID.generate()
    }

    {:ok, definition} = Definitions.create(attrs, prefix: ctx.schema)
    {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: ctx.schema)

    {:ok, result} =
      Engine.create(
        %{
          definition_id: active.id,
          initial_variables: %{},
          actor_id: ctx.requester,
          idempotency_key: "start-#{System.unique_integer([:positive])}"
        },
        prefix: ctx.schema
      )

    result.instance_id
  end

  defp pending(ctx, instance_id) do
    Repo.all(EngineTask, prefix: ctx.schema)
    |> Enum.filter(&(&1.status == :pending and &1.instance_id == instance_id))
  end

  # Completes every approval task of the instance in turn; after each, the same module operation
  # records the approval for that step.
  defp run_route!(ctx, instance_id, request, steps) do
    for step <- 1..steps do
      assert [task] = pending(ctx, instance_id)

      assert {:ok, _} =
               Engine.complete_task(
                 task.id,
                 %{
                   output_variables: %{"decision" => "approved"},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: "complete-#{instance_id}-#{step}"
                 },
                 prefix: ctx.schema
               )

      assert {:ok, _} =
               Decisions.record(ctx.schema, Ecto.UUID.generate(), %{
                 document_id: request.id,
                 version_no: request.version_no,
                 content_hash: request.hash,
                 decision: "approve",
                 idempotency_key: "route-#{instance_id}-#{step}"
               })
    end

    Repo.get!(InstanceProjection, instance_id, prefix: ctx.schema)
  end

  test "R1: one-step and two-step approval routes use the same operations unchanged", ctx do
    manifest = Procurement.manifest()

    sources =
      Path.wildcard("lib/letflow/modules/procurement/*.ex") |> Map.new(&{&1, File.read!(&1)})

    one = Fixture.issued!(ctx, ctx.requester)
    two = Fixture.issued!(ctx, ctx.requester)

    short = start!(ctx, ["approver"])
    long = start!(ctx, ["approver", "director"])

    assert run_route!(ctx, short, one, 1).status == :completed
    assert run_route!(ctx, long, two, 2).status == :completed

    assert Decisions.approved?(ctx.schema, one.id, one.version_no)
    assert Decisions.approved?(ctx.schema, two.id, two.version_no)
    assert Repo.aggregate(Decision, :count, prefix: ctx.schema) == 3

    assert Procurement.manifest() == manifest

    assert Path.wildcard("lib/letflow/modules/procurement/*.ex") |> Map.new(&{&1, File.read!(&1)}) ==
             sources
  end
end
