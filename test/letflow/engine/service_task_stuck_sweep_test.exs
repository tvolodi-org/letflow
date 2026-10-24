defmodule Letflow.Engine.ServiceTaskStuckSweepTest do
  @moduledoc """
  GH #2688 / REQ-513 build B2 (design `gh2688-req513-stuck-advance-sweeper.md`, sections 6 and
  12): `StuckSweep` finds dispatch rows stuck `"advanced"` and lands the in-class ones.

  ST-1 (sweep part), ST-4, ST-5, ST-6, ST-6b (starvation), ST-7 (sweep part), plus the budget and
  batch bounds, the Poller's state/rotation and the index migration registration. ST-2 and ST-3
  live in `service_task_stuck_landing_test.exs` (B1). Real Postgres, Ecto sandbox.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine.ServiceTaskDispatcher.Poller
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.ServiceTaskDispatcher.StuckSweep
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

  defp config!(kv), do: Application.put_env(:letflow, :service_task_dispatcher, kv)

  defp line, do: Fx.line("stock_move", %{"label" => %{"const" => "x"}})

  defp base!, do: Fx.tenant_case!("gh2688-sweep") |> with_types()

  defp with_types(base) do
    Fx.define_type!(base.schema, "stock_move", %{})
    Fx.define_type!(base.schema, "stock_note", %{})
    base
  end

  # one more stuck row in the tenant of `base`, `age_seconds` old
  defp stuck!(base, lines \\ [line()], age_seconds \\ 900) do
    ctx = Fx.attach_service!(base, Fx.service_graph(lines))
    age!(ctx, age_seconds)
  end

  defp age!(ctx, age_seconds) do
    at = DateTime.add(DateTime.utc_now(), -age_seconds, :second)

    {1, _} =
      Repo.update_all(
        from(d in ServiceTaskDispatch, where: d.id == ^ctx.dispatch.id),
        [set: [dispatched_at: at]],
        prefix: ctx.schema
      )

    ctx
  end

  defp sweep(schema, cursor \\ nil, mode \\ :on),
    do: StuckSweep.run(schema, DateTime.utc_now(), cursor, mode)

  defp error_events(ctx), do: Fx.instance_events(ctx.schema, ctx.instance_id, "EXECUTION_ERROR")

  defp audits(ctx) do
    ctx.schema
    |> Fx.audit_rows("service_task.stuck_advance_landed")
    |> Enum.filter(&(&1.resource_id == ctx.instance_id))
  end

  defp status(ctx), do: Fx.projection!(ctx.schema, ctx.instance_id).status

  defp assert_untouched(ctx) do
    assert status(ctx) == :active
    assert error_events(ctx) == []
    assert audits(ctx) == []
    assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == :advanced
  end

  describe "ST-1 exactly once when the sweeper runs twice" do
    test "the second run selects nothing and writes nothing" do
      ctx = base!() |> stuck!()

      assert {%{candidates: 1, landed: 1, scanned: 1}, cursor} = sweep(ctx.schema)
      assert cursor == nil
      assert status(ctx) == :error

      assert {%{candidates: 0, landed: 0, scanned: 0}, nil} = sweep(ctx.schema, cursor)

      assert length(error_events(ctx)) == 1
      assert length(Fx.dlq_entries(ctx.schema)) == 1
      assert length(audits(ctx)) == 1
      assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == :advanced

      assert [event] = error_events(ctx)
      assert event.idempotency_key == "service_task_dispatch:#{ctx.dispatch.id}"
    end

    test "a row whose completion key is present is not a candidate" do
      base = base!()
      ctx = Fx.attach_service!(base, Fx.service_then_human_graph([line()])) |> age!(900)
      assert {:ok, :advanced} = Fx.apply_http(ctx, %{})

      assert {%{candidates: 0, scanned: 0}, nil} = sweep(ctx.schema)
      assert status(ctx) == :active
      assert error_events(ctx) == []
    end
  end

  describe "ST-4 young rows are untouched" do
    test "a row inside the minimum age and one just inside the edge are not selected" do
      base = base!()
      young = stuck!(base, [line()], 60)
      edge = stuck!(base, [line()], 599)

      assert {%{candidates: 0, scanned: 0}, nil} = sweep(base.schema)
      assert_untouched(young)
      assert_untouched(edge)
    end

    test "the 120 s floor beats a smaller configured age" do
      config!(stuck_advance_min_age_seconds: 10)
      base = base!()
      young = stuck!(base, [line()], 60)
      old = stuck!(base, [line()], 130)

      assert {%{candidates: 1, landed: 1, scanned: 1}, nil} = sweep(base.schema)
      assert status(old) == :error
      assert_untouched(young)
    end

    test "a cancelled instance's row is not selected" do
      ctx = base!() |> stuck!()

      {1, _} =
        Repo.update_all(
          from(p in InstanceProjection, where: p.instance_id == ^ctx.instance_id),
          [set: [status: :cancelled]],
          prefix: ctx.schema
        )

      assert {%{candidates: 0, scanned: 0}, nil} = sweep(ctx.schema)
      assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == :advanced
    end
  end

  describe "ST-5 modes" do
    test ":off returns :skipped and issues no read of service_task_dispatches" do
      ctx = base!() |> stuck!()

      {result, sources} = query_sources(fn -> sweep(ctx.schema, nil, :off) end)

      assert result == :skipped
      refute "service_task_dispatches" in sources
      assert_untouched(ctx)
    end

    test "the default mode is :off" do
      config!([])
      assert Letflow.Engine.ServiceTaskDispatcher.stuck_advance_mode() == :off
      config!(stuck_advance_mode: :bogus)
      assert Letflow.Engine.ServiceTaskDispatcher.stuck_advance_mode() == :off
      config!(stuck_advance_mode: :on)
      assert Letflow.Engine.ServiceTaskDispatcher.stuck_advance_mode() == :on
    end

    test ":shadow logs the candidate and writes nothing" do
      ctx = base!() |> stuck!()
      events_before = Fx.all_instance_event_count(ctx.schema, ctx.instance_id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {%{candidates: 1, landed: 0, scanned: 1}, nil} = sweep(ctx.schema, nil, :shadow)
        end)

      assert log =~ "stuck_advance candidate: dispatch_id=#{ctx.dispatch.id}"
      assert_untouched(ctx)
      assert Fx.dlq_entries(ctx.schema) == []
      assert Fx.all_instance_event_count(ctx.schema, ctx.instance_id) == events_before
    end

    test ":shadow advances the cursor within a sweep that stops at the batch size" do
      config!(stuck_advance_batch_size: 1)
      base = base!()
      a = stuck!(base, [line()], 1000)
      _b = stuck!(base, [line()], 900)

      assert {%{candidates: 1}, cursor} = sweep(base.schema, nil, :shadow)
      assert {_at, id} = cursor
      assert id == a.dispatch.id
      assert_untouched(a)
    end
  end

  describe "ST-6 an out-of-class row is never landed" do
    test "no lines: skipped as :other_class, zero writes" do
      ctx = base!() |> stuck!([])

      assert {%{scanned: 1, candidates: 0, landed: 0, skipped: 1, reason_counts: counts}, nil} =
               sweep(ctx.schema)

      assert counts == %{other_class: 1}
      assert_untouched(ctx)
      assert Fx.dlq_entries(ctx.schema) == []
    end

    test "a malformed entity_writes attribute is landed as in class (pins D5)" do
      base = base!()
      ctx = Fx.attach_service!(base, Fx.service_graph("not-a-list")) |> age!(900)

      assert {%{candidates: 1, landed: 1}, nil} = sweep(base.schema)
      assert status(ctx) == :error
    end
  end

  describe "ST-6b starvation: out-of-class rows must not hide an in-class one" do
    test "21 older out-of-class rows, one newer in-class row: landed within 3 sweeps, once" do
      config!(stuck_advance_scan_page_size: 5, stuck_advance_scan_limit: 10)
      base = base!()

      others =
        for n <- 1..21, do: stuck!(base, [], 5000 - n)

      target = stuck!(base, [line()], 900)

      {cursor, sweeps} =
        Enum.reduce_while(1..3, {nil, 0}, fn n, {cursor, _} ->
          {_summary, next} = sweep(base.schema, cursor)
          if status(target) == :error, do: {:halt, {next, n}}, else: {:cont, {next, n}}
        end)

      assert status(target) == :error
      assert sweeps == 3
      assert cursor == nil
      assert length(error_events(target)) == 1
      Enum.each(others, &assert_untouched/1)
    end

    test "with the default page and limit the first sweep lands it" do
      base = base!()
      others = for n <- 1..21, do: stuck!(base, [], 5000 - n)
      target = stuck!(base, [line()], 900)

      assert {%{landed: 1, scanned: 22, skipped: 21}, nil} = sweep(base.schema)
      assert status(target) == :error
      Enum.each(others, &assert_untouched/1)
    end
  end

  describe "bounds" do
    test "the batch size caps in-class attempts per sweep; the next sweep resumes" do
      config!(stuck_advance_batch_size: 2)
      base = base!()
      rows = for n <- 1..3, do: stuck!(base, [line()], 1000 - n)

      assert {%{landed: 2, candidates: 2}, cursor} = sweep(base.schema)
      refute is_nil(cursor)
      assert Enum.count(rows, &(status(&1) == :error)) == 2

      assert {%{landed: 1}, nil} = sweep(base.schema, cursor)
      assert Enum.all?(rows, &(status(&1) == :error))
    end

    test "a spent budget scans nothing and keeps the cursor" do
      config!(stuck_advance_sweep_budget_ms: 0)
      ctx = base!() |> stuck!()

      assert {%{scanned: 0}, nil} = sweep(ctx.schema)
      assert_untouched(ctx)

      cursors = StuckSweep.run_all([ctx.schema], %{ctx.schema => nil}, DateTime.utc_now(), :on)
      assert cursors == %{ctx.schema => nil}
      assert_untouched(ctx)
    end

    test "run_all walks every schema it is given and stores each cursor" do
      a = base!() |> stuck!()
      b = Fx.tenant_case!("gh2688-sweep-b") |> with_types() |> stuck!()

      cursors = StuckSweep.run_all([a.schema, b.schema], %{}, DateTime.utc_now(), :on)

      assert cursors == %{a.schema => nil, b.schema => nil}
      assert status(a) == :error
      assert status(b) == :error
    end

    test "run_all in :off mode returns the cursors untouched" do
      ctx = base!() |> stuck!()

      assert StuckSweep.run_all([ctx.schema], %{"x" => nil}, DateTime.utc_now(), :off) == %{
               "x" => nil
             }

      assert_untouched(ctx)
    end

    test "the accessors read their defaults" do
      config!([])
      alias Letflow.Engine.ServiceTaskDispatcher, as: D
      assert D.stuck_advance_min_age_seconds() == 600
      assert D.stuck_advance_sweep_interval_ms() == 60_000
      assert D.stuck_advance_batch_size() == 20
      assert D.stuck_advance_scan_page_size() == 100
      assert D.stuck_advance_scan_limit() == 1000
      assert D.stuck_advance_sweep_budget_ms() == 1000
    end
  end

  describe "ST-7 tenant isolation (sweep part)" do
    test "a sweep of tenant B touches nothing of tenant A; a sweep of A lands it" do
      a = base!() |> stuck!()
      b = Fx.tenant_case!("gh2688-sweep-other") |> with_types()

      assert {%{candidates: 0, scanned: 0}, nil} = sweep(b.schema)
      assert_untouched(a)
      assert Fx.dlq_entries(a.schema) == []

      assert {%{candidates: 1, landed: 1}, nil} = sweep(a.schema)
      assert status(a) == :error
    end
  end

  describe "Poller state" do
    test "starts with no sweep, no cursors and rotation 0" do
      assert Poller.initial_state() == %{
               last_tick_started_at: nil,
               last_sweep_at: nil,
               stuck_cursors: %{},
               sweep_rotation: 0
             }
    end
  end

  describe "index migration" do
    test "is registered in the tenant-scoped manifest and exists in a provisioned tenant" do
      base = base!()

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = $2",
                 [base.schema, "idx_service_task_dispatches_advanced_dispatched_at"]
               )
    end
  end

  # Source tables of every query the calling process issues while `fun` runs.
  def handle_query(_event, _measurements, metadata, {pid, ref}) do
    send(pid, {:query_source, ref, self(), metadata[:source]})
    :ok
  end

  defp query_sources(fun) do
    ref = make_ref()
    id = {__MODULE__, ref}
    :telemetry.attach(id, [:letflow, :repo, :query], &__MODULE__.handle_query/4, {self(), ref})

    try do
      result = fun.()
      {result, drain(ref, self(), [])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(ref, me, acc) do
    receive do
      {:query_source, ^ref, ^me, source} -> drain(ref, me, [source | acc])
    after
      0 -> acc
    end
  end
end
