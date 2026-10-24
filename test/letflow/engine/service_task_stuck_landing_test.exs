defmodule Letflow.Engine.ServiceTaskStuckLandingTest do
  @moduledoc """
  GH #2688 / REQ-513 build B1 (design `gh2688-req513-stuck-advance-sweeper.md`, sections 6 and
  12): `Engine.land_stuck_service_dispatch/2` lands a dispatch row stuck `"advanced"` as an
  ExecutionError, once.

  ST-1 (landing part), ST-2 (a)/(b)/(c), ST-3, ST-7 (landing return value), plus the class and
  age refusals. Real Postgres, Ecto sandbox. The forced concurrent interleaving of ST-2 is NOT
  attempted: `:engine_test_seams` has no pause point between the dispatch lock and the key read
  (section 8 of the record), so the orders (a), (b), (c) are asserted and the race is argued
  from the lock order (both writers take the dispatch row `FOR UPDATE` first).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo

  setup do
    previous = Application.get_env(:letflow, :service_task_dispatcher)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, :service_task_dispatcher, previous),
        else: Application.delete_env(:letflow, :service_task_dispatcher)
    end)

    :ok
  end

  defp line, do: Fx.line("stock_move", %{"label" => %{"const" => "x"}})

  defp stuck_case!(lines \\ [line()], age_seconds \\ 900) do
    ctx = Fx.service_case!("gh2688-stuck", Fx.service_graph(lines))
    age!(ctx, age_seconds)
  end

  defp age!(ctx, age_seconds) do
    at = DateTime.add(DateTime.utc_now(), -age_seconds, :second)

    {1, _} =
      Repo.update_all(
        from(d in Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch,
          where: d.id == ^ctx.dispatch.id
        ),
        [set: [dispatched_at: at]],
        prefix: ctx.schema
      )

    ctx
  end

  defp land(ctx), do: Engine.land_stuck_service_dispatch(ctx.dispatch.id, ctx.schema)

  defp error_events(ctx), do: Fx.instance_events(ctx.schema, ctx.instance_id, "EXECUTION_ERROR")
  defp audits(ctx), do: Fx.audit_rows(ctx.schema, "service_task.stuck_advance_landed")

  defp assert_nothing_written(ctx) do
    assert error_events(ctx) == []
    assert Fx.dlq_entries(ctx.schema) == []
    assert audits(ctx) == []
    assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == :advanced
  end

  describe "ST-1 landing: exactly once" do
    test "lands once with the fixed contents; a second landing writes nothing" do
      ctx = stuck_case!()
      before_vars = Fx.projection!(ctx.schema, ctx.instance_id).variables

      assert {:ok, :landed} = land(ctx)

      projection = Fx.projection!(ctx.schema, ctx.instance_id)
      assert projection.status == :error
      assert projection.error_detail["error_type"] == "service_task_apply_lost"
      assert projection.error_detail["details"]["code"] == "dispatch_apply_lost"

      assert projection.error_detail["reason"] ==
               "service task dispatch apply lost: result not recorded"

      assert projection.error_detail["affected"] == %{"kind" => "node", "node_id" => "svc"}

      assert [event] = error_events(ctx)
      payload = event.payload
      assert payload["error_type"] == "service_task_apply_lost"

      assert payload["details"] == %{
               "dispatch_id" => ctx.dispatch.id,
               "code" => "dispatch_apply_lost"
             }

      assert payload["variables"] == before_vars
      assert event.idempotency_key == "service_task_dispatch:#{ctx.dispatch.id}"

      assert [dlq] = Fx.dlq_entries(ctx.schema)
      assert dlq.instance_id == ctx.instance_id

      assert [audit] = audits(ctx)
      assert audit.resource_id == ctx.instance_id

      assert audit.after_state == %{
               "node_id" => "svc",
               "dispatch_id" => ctx.dispatch.id,
               "code" => "dispatch_apply_lost"
             }

      # the row's own status is never changed (as D-C.8)
      assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == :advanced

      # second landing: the instance is ERROR now, nothing more is written
      assert {:ok, :instance_moved_on} = land(ctx)
      assert length(error_events(ctx)) == 1
      assert length(Fx.dlq_entries(ctx.schema)) == 1
      assert length(audits(ctx)) == 1
    end
  end

  describe "ST-2 late applier against the landing" do
    test "(a) landing first, then the apply: already_final, no second event" do
      ctx = stuck_case!()
      assert {:ok, :landed} = land(ctx)
      events_before = Fx.all_instance_event_count(ctx.schema, ctx.instance_id)

      assert {:ok, :already_final} = Fx.apply_http(ctx, %{})

      assert Fx.all_instance_event_count(ctx.schema, ctx.instance_id) == events_before
      assert length(error_events(ctx)) == 1
    end

    test "(b) apply first, then the landing: already_final, no ERROR and no DLQ row" do
      # the token waits at a human task afterwards, so the instance stays ACTIVE and only the key says "done"
      ctx =
        Fx.service_case!("gh2688-stuck", Fx.service_then_human_graph([line()])) |> age!(900)

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{})

      assert {:ok, :already_final} = land(ctx)
      assert error_events(ctx) == []
      assert Fx.dlq_entries(ctx.schema) == []
      assert audits(ctx) == []
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
    end

    test "(c) landing first, then the D-C.8 landing: one event, code dispatch_apply_lost" do
      ctx = stuck_case!()
      assert {:ok, :landed} = land(ctx)

      # the rolled-back apply's own landing (the test seam drives it directly)
      assert {:ok, :already_final} =
               Engine.__land_http_entity_write_failure__(
                 ctx.dispatch.id,
                 :entity_write_failed,
                 0,
                 ctx.schema
               )

      assert [event] = error_events(ctx)
      assert event.payload["details"]["code"] == "dispatch_apply_lost"
      assert length(Fx.dlq_entries(ctx.schema)) == 1
    end
  end

  describe "ST-3 the instance moved on" do
    test "a cancelled instance is untouched" do
      ctx = stuck_case!()
      set_status!(ctx, :cancelled)

      assert {:ok, :instance_moved_on} = land(ctx)
      assert_nothing_written(ctx)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :cancelled
    end

    test "an instance already in ERROR is untouched" do
      ctx = stuck_case!()
      set_status!(ctx, :error)

      assert {:ok, :instance_moved_on} = land(ctx)
      assert_nothing_written(ctx)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
    end
  end

  describe "refusals that write nothing" do
    test "a row younger than the minimum age is too_young" do
      ctx = stuck_case!([line()], 60)
      assert {:ok, :too_young} = land(ctx)
      assert_nothing_written(ctx)
    end

    test "the 120 s floor beats a smaller configured age" do
      Application.put_env(:letflow, :service_task_dispatcher, stuck_advance_min_age_seconds: 10)
      ctx = stuck_case!([line()], 60)
      assert {:ok, :too_young} = land(ctx)
      assert_nothing_written(ctx)
    end

    test "a node without lines is not in the class" do
      ctx = stuck_case!([])
      assert {:ok, :not_in_class} = land(ctx)
      assert_nothing_written(ctx)
    end

    test "a malformed entity_writes attribute is in the class (same rule as the plan)" do
      ctx = Fx.service_case!("gh2688-stuck", Fx.service_graph("not-a-list")) |> age!(900)
      assert {:ok, :landed} = land(ctx)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
    end

    test "stuck_entity_write_class?/3: unknown node and unknown instance are unreadable" do
      ctx = stuck_case!()
      assert Engine.stuck_entity_write_class?(ctx.instance_id, "svc", ctx.schema) == :in_class
      assert Engine.stuck_entity_write_class?(ctx.instance_id, "nope", ctx.schema) == :unreadable

      assert Engine.stuck_entity_write_class?(Ecto.UUID.generate(), "svc", ctx.schema) ==
               :unreadable
    end
  end

  describe "ST-7 tenant isolation (landing return value)" do
    test "another tenant's id is :not_found, equal to an unknown id, and nothing is written" do
      a = stuck_case!()
      b = Fx.service_case!("gh2688-other", Fx.service_graph([line()]))

      foreign = Engine.land_stuck_service_dispatch(a.dispatch.id, b.schema)
      unknown = Engine.land_stuck_service_dispatch(Ecto.UUID.generate(), b.schema)

      assert foreign == {:error, :not_found}
      assert foreign == unknown
      assert_nothing_written(a)
      assert Fx.projection!(a.schema, a.instance_id).status == :active
      assert error_events(b) == []

      assert {:ok, :landed} = land(a)
    end
  end

  defp set_status!(ctx, status) do
    {1, _} =
      Repo.update_all(
        from(p in InstanceProjection, where: p.instance_id == ^ctx.instance_id),
        [set: [status: status]],
        prefix: ctx.schema
      )

    :ok
  end
end
