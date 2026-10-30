defmodule Letflow.Engine.RecordTriggerBacklogEngineTest do
  @moduledoc """
  REQ-606 / GH #3411 part 2, criterion 9 (decision 0067 D6): a full trigger backlog on the engine's
  entity-write routes. A SERVICE_TASK (HTTP apply) and a script-bound SERVICE_TASK retry the step as
  contention with the existing backoff and land `entity_write_contention` (nothing committed, no
  internal-error log); user-task completion answers the retryable `entity_write_refused` with code
  `trigger_backlog_full` and succeeds after the backlog drains. A `trigger_enqueue_failed` lands as
  `entity_write_failed`.

  Real Postgres through the real engine entry points. `async: false`: application env (flag, cap).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.RecordTriggers.OutboxRow
  alias Letflow.RecordTriggersFixture, as: RF
  alias Letflow.Repo
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    previous = Application.fetch_env(:letflow, :record_triggers_enabled)
    Application.put_env(:letflow, :record_triggers_enabled, true)
    Application.put_env(:letflow, :record_trigger_backlog_cap, 2)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end

      Application.delete_env(:letflow, :record_trigger_backlog_cap)
    end)

    :ok
  end

  defp lines,
    do: [Fx.line("stock_move", %{"label" => %{"var" => "label"}})]

  # Binds a trigger to `type` and fills the backlog to the cap (2) with pending rows.
  defp fill_backlog!(schema, type) do
    binding = RF.bind!(schema, type, "created")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for n <- 1..2 do
      Repo.insert!(
        %OutboxRow{
          id: Ecto.UUID.generate(),
          binding_id: binding.id,
          entity_type: type,
          record_id: Ecto.UUID.generate(),
          event: :created,
          source_seq: n,
          occurred_at: now,
          script_key: binding.script_key,
          script_version: binding.script_version,
          script_sha256: binding.script_sha256,
          depth: 0,
          chain: [],
          status: :pending,
          attempt: 0,
          next_attempt_at: now
        },
        prefix: schema
      )
    end

    binding
  end

  defp drain!(schema),
    do: Repo.update_all(OutboxRow, [set: [status: :done]], prefix: schema)

  defp break_outbox!(schema),
    do: Repo.query!(~s(ALTER TABLE "#{schema}".record_trigger_outbox RENAME TO outbox_moved))

  defp restore_outbox!(schema),
    do: Repo.query!(~s(ALTER TABLE "#{schema}".outbox_moved RENAME TO record_trigger_outbox))

  test "E4 :trigger_backlog_full is not a service refusal code" do
    source = File.read!("lib/letflow/engine.ex")
    [_, attr] = Regex.run(~r/@service_refusal_codes \[(.*?)\]/s, source)
    refute attr =~ "trigger_backlog_full"
    assert attr =~ "entity_write_contention"
  end

  describe "E1 SERVICE_TASK (HTTP apply)" do
    test "a full backlog is retried as contention and lands entity_write_contention" do
      ctx = Fx.service_case!("r606e1", Fx.service_graph(lines()))
      fill_backlog!(ctx.schema, "stock_move")

      log =
        capture_log(fn ->
          send(self(), {:r, Fx.apply_http(ctx, %{"label" => "L1"})})
        end)

      assert_received {:r, {:ok, :error_set}}
      assert Fx.all_records(ctx.schema) == []
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "entity_write_contention"
      refute log =~ "failed internally"
      refute log =~ "[error]"
    end

    test "after the backlog drains the same apply commits" do
      ctx = Fx.service_case!("r606e1d", Fx.service_graph(lines()))
      fill_backlog!(ctx.schema, "stock_move")
      drain!(ctx.schema)
      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1"})
      assert length(Fx.records(ctx.schema, "stock_move")) == 1
    end

    test "E5 a failed outbox insert lands entity_write_failed" do
      ctx = Fx.service_case!("r606e5", Fx.service_graph(lines()))
      RF.bind!(ctx.schema, "stock_move", "created")
      break_outbox!(ctx.schema)

      try do
        capture_log(fn -> send(self(), {:r, Fx.apply_http(ctx, %{"label" => "L1"})}) end)
        assert_received {:r, {:ok, :error_set}}
        assert [entry] = Fx.dlq_entries(ctx.schema)
        assert entry.error_detail["code"] == "entity_write_failed"
      after
        restore_outbox!(ctx.schema)
      end
    end
  end

  describe "E3 user-task completion" do
    test "answers entity_write_refused trigger_backlog_full; a second completion after the drain succeeds" do
      ctx = Fx.case!("r606e3", lines())
      fill_backlog!(ctx.schema, "stock_move")

      assert {:error, {:entity_write_refused, 0, :trigger_backlog_full}} =
               Fx.complete(ctx, %{"label" => "L1"})

      assert Fx.all_records(ctx.schema) == []

      drain!(ctx.schema)
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
      assert length(Fx.records(ctx.schema, "stock_move")) == 1
    end

    test "E5 a failed outbox insert is entity_write_failed" do
      ctx = Fx.case!("r606e3f", lines())
      RF.bind!(ctx.schema, "stock_move", "created")
      break_outbox!(ctx.schema)

      try do
        capture_log(fn -> send(self(), {:r, Fx.complete(ctx, %{"label" => "L1"})}) end)
        assert_received {:r, {:error, {:entity_write_failed, 0, :enqueue_trigger}}}
      after
        restore_outbox!(ctx.schema)
      end
    end
  end

  describe "H6 user-task completion over HTTP" do
    test "answers 503 trigger_backlog_full with Retry-After, never 500; succeeds after the drain" do
      ctx = Fx.case!("r606h6", lines())
      :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.user.id])
      fill_backlog!(ctx.schema, "stock_move")

      complete = fn ->
        Plug.Test.conn(:post, "/#{ctx.task.id}/complete")
        |> Map.put(:body_params, %{"label" => "L1"})
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.assign(:auth_context, %{
          user_id: ctx.user.id,
          tenant_id: ctx.tenant.tenant_id,
          roles: ["TENANT_ADMIN", "REVIEWER"]
        })
        |> Plug.Conn.assign(:trace_id, "r606h6-trace")
        |> then(&Letflow.Routers.Tasks.call(&1, Letflow.Routers.Tasks.init([])))
      end

      conn = complete.()
      assert conn.status == 503, conn.resp_body
      assert Jason.decode!(conn.resp_body)["error"] == "trigger_backlog_full"
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["30"]
      assert Fx.all_records(ctx.schema) == []

      drain!(ctx.schema)
      assert complete.().status == 200
    end
  end

  describe "E2 script-bound SERVICE_TASK" do
    setup do
      t = F.tenant!("r606e2")
      {:ok, _} = EventTypes.seed!(t.schema_name)
      activator = Fx.user!(t.schema_name, "activator")

      Fx.define_type!(t.schema_name, "amount_rec", %{
        fields: [%{name: "total", type: :integer, required: true}]
      })

      %{t: t, activator: activator}
    end

    defp bound!(t, activator) do
      schema = t.schema_name
      b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 2})
      line = Fx.line("amount_rec", %{"total" => %{"var" => "total"}})

      snapshot = Repo.get!(InstanceDefinitionSnapshot, b.instance_id, prefix: schema)

      nodes =
        Enum.map(snapshot.graph["nodes"], fn
          %{"id" => "svc", "attributes" => attrs} = node ->
            %{node | "attributes" => Map.put(attrs, "entity_writes", [line])}

          node ->
            node
        end)

      {1, _} =
        from(s in InstanceDefinitionSnapshot, where: s.instance_id == ^b.instance_id)
        |> Repo.update_all([set: [graph: %{snapshot.graph | "nodes" => nodes}]], prefix: schema)

      record =
        Activator.build_record(
          Activator.from_auth_context(%{user_id: activator.id, roles: ["TENANT_ADMIN"]}, false),
          [{"amount_rec", "create"}],
          DateTime.utc_now()
        )

      row = Repo.get!(ProcessDefinition, b.definition.id, prefix: schema)
      {:ok, record} = Letflow.Definitions.ActivatedBy.sign(record, row, schema)

      {1, _} =
        from(d in ProcessDefinition, where: d.id == ^b.definition.id)
        |> Repo.update_all([set: [activated_by: record]], prefix: schema)

      b
    end

    test "a full backlog lands the row failed with entity_write_contention", %{
      t: t,
      activator: activator
    } do
      schema = t.schema_name
      b = bound!(t, activator)
      fill_backlog!(schema, "amount_rec")

      log = capture_log(fn -> send(self(), {:r, F.run_next!(schema)}) end)

      assert_received {:r, {row, {:ok, :failed}}}
      assert Fx.records(schema, "amount_rec") == []
      assert F.reload(schema, row).outcome_detail == "entity_write_contention"
      assert F.projection(schema, b.instance_id).status == :error
      refute log =~ "failed internally"
    end
  end
end
