defmodule Letflow.Engine.ReactivationServiceTest do
  @moduledoc """
  GH #2692 / REQ-515, SERVICE path (RA-S1..S4): a flagged definition refuses a NEW instance
  before any dispatch row exists (so no external call can be made first), an instance already
  running keeps the existing ERROR + DLQ shape, and `reactivate` lets a new instance apply its
  write. RA-S4: a call activity naming a flagged definition does not start the child.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity
  alias Letflow.Repo

  defp lines, do: [Fx.line("stock_move", %{"label" => %{"var" => "label"}})]

  defp case!, do: Fx.service_case!("gh2692-s", Fx.service_graph(lines()))

  defp deactivate!(ctx) do
    assert {:ok, _} =
             Identity.update_user_status(ctx.user.id, :inactive,
               prefix: ctx.schema,
               tenant_id: ctx.tenant.tenant_id,
               login_directory: :skip
             )
  end

  defp reactivate!(ctx) do
    admin = Fx.user!(ctx.schema, "new-activator")
    activator = Activator.from_auth_context(%{user_id: admin.id, roles: ["TENANT_ADMIN"]}, false)

    {:ok, row} =
      Definitions.reactivate(ctx.definition.id, prefix: ctx.schema, activator: activator)

    row
  end

  defp create(ctx, definition_id) do
    Engine.create(
      %{
        definition_id: definition_id,
        initial_variables: %{"seed" => "s"},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Fx.unique("ra-start")
      },
      prefix: ctx.schema
    )
  end

  defp definition!(ctx), do: Repo.get!(ProcessDefinition, ctx.definition_id, prefix: ctx.schema)

  defp with_definition(ctx) do
    row =
      Repo.one!(
        from(d in ProcessDefinition,
          where: d.status == :active,
          order_by: [desc: d.created_at],
          limit: 1
        ),
        prefix: ctx.schema
      )

    Map.put(ctx, :definition_id, row.id)
  end

  defp dispatch_count(ctx),
    do: Repo.aggregate(ServiceTaskDispatch, :count, :id, prefix: ctx.schema)

  test "RA-S1: a flagged definition refuses a new instance, no token, no dispatch row" do
    ctx = case!() |> with_definition()
    before_count = dispatch_count(ctx)
    deactivate!(ctx)
    assert definition!(ctx).needs_reactivation_at != nil

    assert {:error, :definition_needs_reactivation} = create(ctx, ctx.definition_id)
    assert dispatch_count(ctx) == before_count
    assert Repo.aggregate(InstanceProjection, :count, :instance_id, prefix: ctx.schema) == 1
  end

  test "RA-S2: an instance already running reaches ERROR + DLQ (existing shape)" do
    ctx = case!()
    deactivate!(ctx)

    assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1"})
    assert [entry] = Fx.dlq_entries(ctx.schema)
    assert entry.error_detail["code"] == "entity_write_needs_reactivation"
    assert Fx.all_records(ctx.schema) == []
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
  end

  test "RA-S3: after reactivate a new instance applies its write" do
    ctx = case!() |> with_definition()
    deactivate!(ctx)
    assert {:error, :definition_needs_reactivation} = create(ctx, ctx.definition_id)

    row =
      reactivate!(%{ctx | definition: definition!(ctx)} |> Map.put(:definition, definition!(ctx)))

    assert row.needs_reactivation_at == nil

    fresh = Fx.start_service_instance!(ctx, row)

    dispatch =
      fresh.dispatch
      |> Ecto.Changeset.change(%{status: :advanced})
      |> Repo.update!(prefix: ctx.schema)

    assert {:ok, :advanced} = Fx.apply_http(%{fresh | dispatch: dispatch}, %{"label" => "L2"})
    assert [_record] = Fx.records(ctx.schema, "stock_move")
  end

  describe "RA-S4: call activity" do
    defp child_graph do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
      }
    end

    defp parent_graph(child_name, direct?) do
      sp = %{
        "id" => "sp",
        "node_type" => "SUB_PROCESS",
        "attributes" => %{"definition_name" => child_name}
      }

      human = %{
        "id" => "h0",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "REVIEWER"}
      }

      if direct? do
        %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            sp,
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => [
            %{"id" => "p1", "source" => "start", "target" => "sp"},
            %{"id" => "p2", "source" => "sp", "target" => "end"}
          ]
        }
      else
        %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            human,
            sp,
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => [
            %{"id" => "p0", "source" => "start", "target" => "h0"},
            %{"id" => "p1", "source" => "h0", "target" => "sp"},
            %{"id" => "p2", "source" => "sp", "target" => "end"}
          ]
        }
      end
    end

    defp flag!(ctx, definition) do
      {1, _} =
        Repo.update_all(
          from(d in ProcessDefinition, where: d.id == ^definition.id),
          [
            set: [
              needs_reactivation_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
              needs_reactivation_reason: "activator_deactivated"
            ]
          ],
          prefix: ctx.schema
        )
    end

    defp setup_pair(direct?) do
      ctx = Fx.tenant_case!("gh2692-s4")
      child = Fx.legacy_activate!(ctx.schema, ctx.user, child_graph(), [])
      parent = Fx.legacy_activate!(ctx.schema, ctx.user, parent_graph(child.name, direct?), [])
      flag!(ctx, child)
      {ctx, child, parent}
    end

    defp child_projections(ctx, child),
      do:
        Repo.aggregate(
          from(p in InstanceProjection, where: p.definition_id == ^child.id),
          :count,
          :instance_id,
          prefix: ctx.schema
        )

    test "a parent that reaches the call activity mid-run takes the ERROR path; no child exists" do
      {ctx, child, parent} = setup_pair(false)
      :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.user.id])

      {:ok, %{instance_id: parent_id}} = create(ctx, parent.id)
      task = Fx.pending_task!(ctx.schema, parent_id)

      Engine.complete_task(
        task.id,
        %{output_variables: %{}, actor_id: ctx.user.id, idempotency_key: Fx.unique("ra-c")},
        prefix: ctx.schema
      )

      assert Fx.projection!(ctx.schema, parent_id).status == :error
      assert child_projections(ctx, child) == 0
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert inspect(entry.error_detail) =~ "SUB_PROCESS_DEFINITION_NEEDS_REACTIVATION"
    end

    test "a parent whose call activity follows the start event is refused at create" do
      {ctx, child, parent} = setup_pair(true)

      assert {:error,
              {:activation_failed,
               {:subprocess_interface_violation, {:definition_needs_reactivation, _name}}}} =
               create(ctx, parent.id)

      assert child_projections(ctx, child) == 0
    end
  end
end
