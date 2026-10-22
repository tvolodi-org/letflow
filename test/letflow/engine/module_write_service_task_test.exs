defmodule Letflow.Engine.ModuleWriteServiceTaskTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R5 (design `gh2590-req501-module-write-handlers.md` D-R.13, D-R.18,
  section 8, section 11 row "SERVICE_TASK path", threat T-10; PR C `gh2587-req499-pr-c-service-
  task-writes.md` D-C.4, D-C.7, D-C.8, D-C.9): the module write handlers of a stamped
  SERVICE_TASK node run in the ONE apply transaction of the service result.

    * T-10: the event actor is the platform sentinel, the field-restriction subject and
      `source.activator_id` are the ACTIVATOR, the SAME `HandlerWrites` path as a HUMAN completion
      (same metadata keys, `source.dispatch_id` instead of `source.task_id`), idempotency keys
      `sys:step:<dispatch_id>:<line_index>:<ordinal>`;
    * a node with declarative AND handler lines composes both (declarative first, then the handler
      calls) and lands the v2 `TASK_ENTITY_WRITES_APPLIED` event;
    * a refusal (rogue handler, hash drift before or inside the transaction, hand-edited snapshot,
      a tenant without event schema v2, a restricted field, an oversize value) rolls the apply
      back and lands the instance in ERROR + one value-free DLQ entry, with the closed detail atom
      only in the tenant audit;
    * a duplicate apply is `already_final`; contention is re-applied by the engine; the
      handler-call deadline guard lives inside the service budget;
    * the script-bound route composes the same way (a script output is never a command: the
      handler is fixed by the stamped definition).

  Real Postgres through the real `Engine.advance_after_service_task_outcome/4` and the real script
  dispatcher. `async: false`: module installs, DDL and the port doubles (application env).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Entities.EntityPortImpl
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.StepWrites
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore
  alias Letflow.Modules.FixtureLedger
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Repo
  alias Letflow.Support.ChaosEntityPort
  alias Letflow.Support.ScriptTaskFixture, as: F

  # a distinctive request value: any leak into a DLQ entry, event or audit row is greppable
  @label "ZQX-7731-LABEL"

  setup do
    on_exit(fn ->
      ChaosEntityPort.disarm!()
      Application.delete_env(:letflow, :flip_hash_target)
      Application.delete_env(:letflow, :tiny_guard_budget)
    end)

    :ok
  end

  defmodule FlipHashPort do
    @moduledoc false
    # Real port, but changes the installed manifest hash AFTER the pre-transaction authorization
    # and `prepare/2` ran (a hash drift inside the window); `multi/3` can also tighten the guard.
    @behaviour Letflow.Engine.EntityPort

    @impl true
    def prefetch(prefix, reads, vars), do: EntityPortImpl.prefetch(prefix, reads, vars)

    @impl true
    def authorize_module_writes(lines, ctx),
      do: EntityPortImpl.authorize_module_writes(lines, ctx)

    @impl true
    def prepare(lines, ctx) do
      result = EntityPortImpl.prepare(lines, ctx)

      case Application.get_env(:letflow, :flip_hash_target) do
        {schema, module_id} ->
          Letflow.ModuleWritesFixture.set_installed_hash!(
            schema,
            module_id,
            String.duplicate("0", 64)
          )

        _none ->
          :ok
      end

      result
    end

    @impl true
    def validate_lines(lines, ctx), do: EntityPortImpl.validate_lines(lines, ctx)

    @impl true
    def multi(multi, lines, ctx) do
      ctx =
        case Application.get_env(:letflow, :tiny_guard_budget) do
          nil -> ctx
          budget -> %{ctx | guard_budget_ms: budget}
        end

      EntityPortImpl.multi(multi, lines, ctx)
    end

    @impl true
    def interpret_failure(step, reason), do: EntityPortImpl.interpret_failure(step, reason)
  end

  defp event_types(ctx), do: Fx.instance_event_types(ctx.schema, ctx.instance_id)

  defp payload(%{payload: payload}) when is_map(payload), do: payload
  defp payload(%{payload: payload}) when is_binary(payload), do: Jason.decode!(payload)

  defp written(ctx) do
    %{
      records: length(Fx.all_records(ctx.schema)),
      entity_events: length(Fx.entity_events(ctx.schema)),
      step_keys: Fx.step_idempotency_count(ctx.schema),
      line_audit: length(Fx.audit_rows(ctx.schema, "entity_write.process_step")),
      applied:
        length(Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED"))
    }
  end

  defp assert_nothing_written(ctx) do
    assert Fx.all_records(ctx.schema) == []
    assert Fx.entity_events(ctx.schema) == []
    assert Fx.step_idempotency_count(ctx.schema) == 0
    assert Fx.audit_rows(ctx.schema, "entity_write.process_step") == []
    refute "SERVICE_TASK_COMPLETED" in event_types(ctx)
    refute "TASK_ENTITY_WRITES_APPLIED" in event_types(ctx)
    assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == :advanced
  end

  # The apply landed in ERROR + ONE value-free DLQ entry with `code` at `index`; the closed
  # `detail` atom is in the tenant audit entry only.
  defp assert_landed(ctx, code, index, detail) do
    assert_nothing_written(ctx)
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error

    assert [entry] = Fx.dlq_entries(ctx.schema)

    assert entry.error_detail == %{
             "line_index" => index,
             "code" => code,
             "dispatch_id" => ctx.dispatch.id
           }

    assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
    assert refused.actor_id == EventStore.platform_actor_id()
    assert refused.after_state["code"] == code
    assert refused.after_state["line_index"] == index
    assert refused.after_state["detail"] == detail
    assert refused.after_state["dispatch_id"] == ctx.dispatch.id
    refute inspect(refused.after_state) =~ ~r/[0-9a-f]{64}/

    # the distinctive request value is in none of the operator surfaces
    refute inspect(entry) =~ @label
    refute inspect(refused) =~ @label

    # and no handler exception text (the `raises` handler's message) is in any of them
    refute inspect(entry) =~ "secret detail"
    refute inspect(refused) =~ "secret detail"

    for event <- Fx.instance_events(ctx.schema, ctx.instance_id, "EXECUTION_ERROR") do
      refute inspect(payload(event)) =~ @label
      refute inspect(payload(event)) =~ "secret detail"
    end
  end

  # The row-lock statements of a captured query log as `{table, id}`; an unparsable one fails
  # the test (never a MatchError).
  defp row_locks(queries) do
    for %{query: sql} = q <- queries, sql =~ "FOR UPDATE" do
      table =
        case Regex.run(~r/FROM "[^"]+"\."([a-z_]+)"/, sql) do
          [_, table] -> table
          nil -> flunk("unparsable lock statement: #{sql}")
        end

      {table, q |> Map.get(:params, []) |> List.first() |> lock_param()}
    end
  end

  defp lock_param(param) when is_binary(param) and byte_size(param) == 16,
    do: Ecto.UUID.load!(param)

  defp lock_param(param), do: param

  # Counts the calls of the fixture handlers (global call counters),
  # so "no second handler run" and "replay runs no handler" are assertions on the real functions.
  @traced [Letflow.Modules.FixtureLedger.Handlers, Letflow.Modules.FixtureLedgerRogue.Handlers]

  # Global call counters (`:call_count`; the test module is `async: false`). `drain_handler_calls/0`
  # returns the number of handler calls since the last drain and resets the counters.
  defp trace_handlers! do
    for mod <- @traced do
      {:module, ^mod} = Code.ensure_loaded(mod)
      :erlang.trace_pattern({mod, :_, :_}, true, [:call_count])
    end

    on_exit(fn ->
      for mod <- @traced, do: :erlang.trace_pattern({mod, :_, :_}, false, [:call_count])
    end)

    :ok
  end

  defp drain_handler_calls do
    total =
      for mod <- @traced,
          {fun, arity} <- mod.module_info(:functions),
          fun != :module_info,
          reduce: 0 do
        acc ->
          case :erlang.trace_info({mod, fun, arity}, :call_count) do
            {:call_count, count} when is_integer(count) -> acc + count
            _other -> acc
          end
      end

    for mod <- @traced, do: :erlang.trace_pattern({mod, :_, :_}, true, [:call_count])
    total
  end

  defp flush_port_calls do
    receive do
      {:port_call, _name, _arg} -> flush_port_calls()
    after
      0 -> :ok
    end
  end

  describe "T-10: success (HTTP route)" do
    test "sentinel actor, activator subject, handler keys, derived idempotency keys, v2 event" do
      ctx = Mw.service_case!("gh2590-r5-ok", :svc_module)
      sentinel = EventStore.platform_actor_id()

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => @label, "extra" => "x"})

      assert [ledger] = Fx.records(ctx.schema, "fxl_ledger")
      assert [balance] = Fx.records(ctx.schema, "fxl_balance")
      assert ledger.field_values == %{"item" => @label, "quantity" => 1}
      assert balance.field_values == %{"item" => @label, "quantity" => 1}

      projection = Fx.projection!(ctx.schema, ctx.instance_id)
      assert projection.status == :completed

      events = Fx.entity_events(ctx.schema)
      assert length(events) == 2
      assert Enum.all?(events, &(&1.actor_id == sentinel))

      for {event, ordinal} <- Enum.with_index(events, 1) do
        # declared line_index 0 (the only line), ordinals 1 and 2 of the one handler call
        assert event.idempotency_key == "sys:step:#{ctx.dispatch.id}:0:#{ordinal}"

        assert event.metadata["source.dispatch_id"] == ctx.dispatch.id
        assert event.metadata["source.activator_id"] == ctx.user.id
        assert event.metadata["source.node_id"] == "svc"
        assert event.metadata["source.line_index"] == "0"
        assert event.metadata["source.handler_module"] == "fixture_ledger"
        assert event.metadata["source.handler_name"] == "post_entry"
        assert event.metadata["source.write_ordinal"] == Integer.to_string(ordinal)
        refute Map.has_key?(event.metadata, "source.task_id")
      end

      assert [applied] =
               Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")

      assert [completed] =
               Fx.instance_events(ctx.schema, ctx.instance_id, "SERVICE_TASK_COMPLETED")

      assert applied.sequence_number < completed.sequence_number
      assert applied.actor_id == sentinel and completed.actor_id == sentinel

      applied_payload = payload(applied)
      assert applied_payload["dispatch_id"] == ctx.dispatch.id
      assert applied_payload["task_id"] == nil
      assert [first, second] = applied_payload["lines"]

      for {line, ordinal} <- [{first, 1}, {second, 2}] do
        assert line["line_index"] == 0
        assert line["handler_module"] == "fixture_ledger"
        assert line["handler_name"] == "post_entry"
        assert line["write_ordinal"] == ordinal
      end

      # the hash is over both attributes (a node WITH module_writes), not the declarative list
      node = ctx.definition.graph["nodes"] |> Enum.find(&(&1["id"] == "svc"))

      assert applied_payload["lines_hash"] ==
               StepWrites.lines_hash(%{
                 "entity_writes" => [],
                 "module_writes" => node["attributes"]["module_writes"]
               })

      # one audit row per write: sentinel actor, activator recorded, handler keys, no field value
      audits = Fx.audit_rows(ctx.schema, "entity_write.process_step")
      assert length(audits) == 2

      for audit <- audits do
        assert audit.actor_id == sentinel
        assert audit.after_state["activator_id"] == ctx.user.id
        assert audit.after_state["dispatch_id"] == ctx.dispatch.id
        assert audit.after_state["handler_module"] == "fixture_ledger"
        assert audit.after_state["handler_name"] == "post_entry"
        refute Map.has_key?(audit.after_state, "field_values")
        refute inspect(audit.after_state) =~ @label
      end

      assert Enum.sort(Enum.map(audits, & &1.after_state["write_ordinal"])) == [1, 2]
      assert {:ok, :valid} = Letflow.Audit.verify_chain(ctx.schema)

      # replay: the rebuilt state equals the live one and runs no handler
      assert {:ok, %{instance_state: state}} =
               Letflow.Engine.Reconstruction.reconstruct_instance(ctx.instance_id,
                 prefix: ctx.schema
               )

      assert state.variables == projection.variables
      assert state.status == projection.status
    end

    test "the port context carries the module_writes, the stamp, the dispatch origin, the sentinel actor and the activator subject" do
      ctx = Mw.service_case!("gh2590-r5-ctx", :svc_module)
      ChaosEntityPort.record!()

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => @label})

      assert_received {:port_call, :multi, port_ctx}
      assert port_ctx.origin == {:dispatch, ctx.dispatch.id}
      assert port_ctx.actor_id == EventStore.platform_actor_id()
      assert port_ctx.subject_id == ctx.user.id
      assert port_ctx.activator_id == ctx.user.id
      assert [%{"module" => "fixture_ledger", "handler" => "post_entry"}] = port_ctx.module_writes
      assert %{module_id: "fixture_ledger"} = port_ctx.owner
      assert port_ctx.entity_write_count == 0
      assert port_ctx.guard_budget_ms > 0 and port_ctx.guard_budget_ms <= 10_000
    end

    test "a MIXED node: declarative line (index 0) first, then the handler call (index 1)" do
      ctx = Mw.service_case!("gh2590-r5-mixed", :svc_mixed)
      sentinel = EventStore.platform_actor_id()

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => @label})

      assert [_] = Fx.records(ctx.schema, "stock_move")
      assert [_] = Fx.records(ctx.schema, "fxl_ledger")
      assert [_] = Fx.records(ctx.schema, "fxl_balance")

      assert [declared, h1, h2] = Fx.entity_events(ctx.schema)
      assert declared.idempotency_key == "sys:step:#{ctx.dispatch.id}:0"
      assert h1.idempotency_key == "sys:step:#{ctx.dispatch.id}:1:1"
      assert h2.idempotency_key == "sys:step:#{ctx.dispatch.id}:1:2"
      assert Enum.all?([declared, h1, h2], &(&1.actor_id == sentinel))

      # declarative bytes are unchanged by REQ-501 (INV-R6): no handler keys
      refute Map.has_key?(declared.metadata, "source.handler_module")
      refute Map.has_key?(declared.metadata, "source.write_ordinal")
      assert h1.metadata["source.line_index"] == "1"

      assert [applied] =
               Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")

      lines = payload(applied)["lines"]
      assert Enum.map(lines, & &1["line_index"]) == [0, 1, 1]
      refute Map.has_key?(hd(lines), "handler_module")
      assert length(Fx.audit_rows(ctx.schema, "entity_write.process_step")) == 3
    end

    test "two handler calls on one node: the second call is line_index 1, ordinals restart" do
      ctx = Mw.service_case!("gh2590-r5-two", :svc_two_handlers)

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => @label})

      keys = Fx.entity_events(ctx.schema) |> Enum.map(& &1.idempotency_key)
      d = ctx.dispatch.id
      assert keys == ["sys:step:#{d}:0:1", "sys:step:#{d}:0:2", "sys:step:#{d}:1:1"]
    end

    test "the lock order: the type rows are taken ascending (declarative aaa_move first), the audit chain row last" do
      ctx = Mw.service_case!("gh2590-r5-lockord", :svc_mixed_first)

      {result, queries} =
        Letflow.Support.PlatformTenantFixture.capture_repo_queries(fn ->
          Fx.apply_http(ctx, %{"label" => @label})
        end)

      assert {:ok, :advanced} = result

      locks = row_locks(queries)

      assert Enum.take(Enum.map(locks, &elem(&1, 0)), 2) ==
               ["service_task_dispatches", "instance_projections"]

      positions =
        type_lock_positions(ctx.schema, locks, ["aaa_move", "fxl_balance", "fxl_ledger"])

      assert positions == Enum.sort(positions)

      audit = locks |> Enum.map(&elem(&1, 0)) |> Enum.find_index(&(&1 == "audit_chain_locks"))
      assert is_integer(audit) and audit > List.last(positions)
      refute Enum.any?(queries, &(&1.query =~ ~r/LOCK TABLE/i))
    end

    # GH #2695 order for a sub-process CHILD whose last node is the handler-calling service node:
    # dispatch row, child projection, then the parent group (parent projection, waiting token),
    # then the handler type rows ascending, then the audit chain row last.
    test "a sub-process CHILD service node: parent group first, then the handler type rows ascending, audit last" do
      ctx = Mw.subprocess_service_case!("gh2590-r5-lockchild")

      {result, queries} =
        Letflow.Support.PlatformTenantFixture.capture_repo_queries(fn ->
          Fx.apply_http(ctx, %{"label" => @label})
        end)

      assert {:ok, :advanced} = result
      assert length(Fx.records(ctx.schema, "fxl_ledger")) == 1

      locks = row_locks(queries)

      position = fn key ->
        idx = Enum.find_index(locks, &(&1 == key))
        assert idx, "no lock #{inspect(key)} in #{inspect(locks)}"
        idx
      end

      dispatch = Enum.find_index(locks, fn {table, _} -> table == "service_task_dispatches" end)
      child_projection = position.({"instance_projections", ctx.instance_id})
      parent_projection = position.({"instance_projections", ctx.parent_id})
      # the cascade's waiting-token lookup is keyed by the waiting CHILD id
      parent_token = position.({"tokens", ctx.instance_id})

      type_positions = type_lock_positions(ctx.schema, locks, ["fxl_balance", "fxl_ledger"])
      audit = Enum.find_index(locks, fn {table, _} -> table == "audit_chain_locks" end)

      assert is_integer(dispatch) and is_integer(audit)
      assert dispatch < child_projection
      assert child_projection < parent_projection
      assert parent_projection < parent_token
      assert parent_token < hd(type_positions)
      assert type_positions == Enum.sort(type_positions)
      assert List.last(type_positions) < audit
      refute Enum.any?(queries, &(&1.query =~ ~r/LOCK TABLE/i))
    end

    defp type_lock_positions(schema, locks, types) do
      ids =
        Letflow.Entities.EntityTypeInstance
        |> Repo.all(prefix: schema)
        |> Map.new(&{&1.entity_type, &1.instance_id})

      positions =
        for type <- types do
          id = Map.fetch!(ids, type)

          Enum.find_index(locks, fn {table, param} ->
            table == "instance_sequence" and param == id
          end)
        end

      assert Enum.all?(positions, &is_integer/1), "type locks missing: #{inspect(positions)}"
      positions
    end
  end

  describe "T-10: the activator is the field-restriction subject" do
    defp restrict_item!(ctx) do
      Repo.insert_all(
        "entity_field_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: "fxl_ledger",
            field_name: "item",
            inserted_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )
    end

    defp grant_item!(ctx, user_id) do
      Repo.insert_all(
        "user_entity_grants",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            user_id: Ecto.UUID.dump!(user_id),
            entity_type: "fxl_ledger",
            field_name: "item",
            inserted_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )
    end

    test "a restricted field without a grant for the ACTIVATOR is refused (ERROR + DLQ)" do
      ctx = Mw.service_case!("gh2590-r5-restr", :svc_module)
      restrict_item!(ctx)
      # somebody else's grant matters not: there is no completer
      grant_item!(ctx, Fx.user!(ctx.schema, "someone-else").id)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})

      assert_landed(ctx, "write_not_permitted", 0, "field_restricted")
    end

    test "with a grant for the ACTIVATOR the same apply commits" do
      ctx = Mw.service_case!("gh2590-r5-grant", :svc_module)
      restrict_item!(ctx)
      grant_item!(ctx, ctx.user.id)

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => @label})
      assert [_] = Fx.records(ctx.schema, "fxl_ledger")
    end
  end

  describe "rogue handlers (HTTP route): ERROR + DLQ, nothing committed" do
    # The closed `handler` detail atom is produced by `StepWrites.interpret_line/4` (`:build` with
    # `:handler_shape` | `:handler_raised` -> `{:failed, index, :handler}`) and reaches the audit
    # entry through the engine's `{:refuse, :entity_write_failed, index, step}` landing.
    for {handler, code, detail} <- [
          {"denies", "write_not_permitted", "handler_not_permitted"},
          {"writes_foreign_type", "write_not_permitted", "handler_not_permitted"},
          {"forge_handler", "write_not_permitted", "handler_not_permitted"},
          {"invalid", "validation_failed", "handler_invalid_arguments"},
          {"raises", "entity_write_failed", "handler"},
          {"throws", "entity_write_failed", "handler"},
          {"exits", "entity_write_failed", "handler"},
          {"bad_return", "entity_write_failed", "handler"},
          {"loose_step", "entity_write_failed", "handler"},
          {"out_of_range_step", "entity_write_failed", "handler"},
          {"run_after_create", "entity_write_failed", "handler"},
          {"drop_policy", "entity_write_failed", "handler"}
        ] do
      test "rogue handler #{handler}: #{code} (detail #{detail})" do
        ctx = Mw.rogue_service_case!("gh2590-r5-rogue-#{unquote(handler)}", unquote(handler))

        log =
          capture_log(fn ->
            assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})
          end)

        assert_landed(ctx, unquote(code), 0, unquote(detail))
        assert Fx.all_records(ctx.schema) == []

        # no exception text, no secret detail and no request value in the log (INV-4)
        refute log =~ "secret detail"
        refute log =~ @label

        if unquote(handler) == "raises" do
          # non-vacuous: the handler DID run and raise, and only its exception module is logged
          assert log =~ "module write handler raised"
          assert log =~ "RuntimeError"
        end
      end
    end
  end

  describe "refusals before the transaction (run-time authorization on the pinned snapshot)" do
    test "a hand-edited pinned snapshot (the body hash) lands ERROR: body_changed" do
      ctx = Mw.service_case!("gh2590-r5-body", :svc_module)

      Mw.tamper_snapshot!(ctx, fn graph ->
        update_in(graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "svc"} = node ->
              put_in(node, ["attributes", "module_writes"], [
                %{
                  "module" => "fixture_ledger",
                  "handler" => "post_entry",
                  "args" => %{"item" => %{"var" => "label"}, "quantity" => %{"const" => 99}}
                }
              ])

            node ->
              node
          end)
        end)
      end)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})
      assert_landed(ctx, "write_not_permitted", 0, "body_changed")
    end

    test "the same edit on a MIXED node reports the DECLARED handler index (1)" do
      ctx = Mw.service_case!("gh2590-r5-body-mixed", :svc_mixed)

      Mw.tamper_snapshot!(ctx, fn graph ->
        update_in(graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "svc"} = node ->
              put_in(node, ["attributes", "entity_writes"], [
                Fx.line("stock_move", %{"label" => %{"const" => "tampered"}})
              ])

            node ->
              node
          end)
        end)
      end)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})
      assert_landed(ctx, "write_not_permitted", 1, "body_changed")
      assert Fx.records(ctx.schema, "stock_move") == []
    end

    test "a definition row with no stamp (a tenant-created copy) lands ERROR: stamp_missing" do
      base = Mw.tenant!("gh2590-r5-nostamp")

      graph =
        Fx.service_graph([], %{
          "module_writes" => [Mw.line() |> put_in(["args", "item"], %{"var" => "label"})]
        })

      definition = Fx.legacy_activate!(base.schema, base.user, graph, [])
      ctx = Fx.start_service_instance!(base, definition)

      dispatch =
        ctx.dispatch
        |> Ecto.Changeset.change(%{status: :advanced})
        |> Repo.update!(prefix: base.schema)

      ctx = %{ctx | dispatch: dispatch}

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})
      assert_landed(ctx, "write_not_permitted", 0, "stamp_missing")
    end

    test "a tampered installed manifest hash lands ERROR: hash_mismatch" do
      ctx = Mw.service_case!("gh2590-r5-hash", :svc_module)
      Mw.set_installed_hash!(ctx.schema, "fixture_ledger", String.duplicate("a", 64))

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})
      assert_landed(ctx, "write_not_permitted", 0, "hash_mismatch")
    end

    test "installed == stamp but != the compiled manifest hash lands ERROR: hash_mismatch" do
      ctx = Mw.service_case!("gh2590-r5-compiled", :svc_module)
      other = String.duplicate("d", 64)

      Mw.set_stamp_hash!(ctx, other)
      Mw.set_installed_hash!(ctx.schema, "fixture_ledger", other)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})
      assert_landed(ctx, "write_not_permitted", 0, "hash_mismatch")
    end

    test "installed == compiled but != the stamp lands ERROR: hash_mismatch" do
      ctx = Mw.service_case!("gh2590-r5-stamp", :svc_module)
      Mw.set_stamp_hash!(ctx, String.duplicate("e", 64))

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})
      assert_landed(ctx, "write_not_permitted", 0, "hash_mismatch")
    end

    test "a module that is no longer installed lands ERROR: module_not_installed" do
      ctx = Mw.service_case!("gh2590-r5-uninstalled", :svc_module)

      {1, _} =
        Repo.delete_all(
          from(m in Letflow.Modules.TenantModule, where: m.module_id == "fixture_ledger"),
          prefix: ctx.schema
        )

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})
      assert_landed(ctx, "write_not_permitted", 0, "module_not_installed")
    end

    test "a tenant not replayed to TASK_ENTITY_WRITES_APPLIED v3 lands ERROR: event_schema_outdated" do
      ctx = Mw.service_case!("gh2590-r5-schema", :svc_module)

      {1, _} =
        Repo.delete_all(
          from(e in "event_type_registry",
            where: e.name == "TASK_ENTITY_WRITES_APPLIED" and e.schema_version == 3
          ),
          prefix: ctx.schema
        )

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})
      assert_landed(ctx, "write_not_permitted", 0, "event_schema_outdated")
    end

    test "the COMBINED line cap is enforced at run time on the pinned snapshot (20 + 1)" do
      ctx = Mw.service_case!("gh2590-r5-cap", :svc_module)

      Mw.tamper_snapshot!(ctx, fn graph ->
        update_in(graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "svc"} = node ->
              put_in(
                node,
                ["attributes", "entity_writes"],
                List.duplicate(Fx.line("stock_move", %{"label" => %{"const" => "v"}}), 20)
              )

            node ->
              node
          end)
        end)
      end)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})
      assert_landed(ctx, "validation_failed", 20, "too_many_lines")
    end
  end

  describe "refusals inside the transaction" do
    test "a hash that drifts AFTER the authorization lands ERROR (owner_recheck): hash_mismatch" do
      ctx = Mw.service_case!("gh2590-r5-toctou", :svc_module)
      F.put_env!(:entity_port, FlipHashPort)
      F.put_env!(:flip_hash_target, {ctx.schema, "fixture_ledger"})

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})

      # the handler was never invoked: no record exists
      assert_landed(ctx, "write_not_permitted", 0, "hash_mismatch")
      assert Fx.records(ctx.schema, "fxl_ledger") == []
    end

    test "a value over the service byte cap is refused with validation_failed and no field name" do
      ctx = Mw.service_case!("gh2590-r5-size", :svc_module)
      big = String.duplicate("a", 70_000)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => big})

      assert_nothing_written(ctx)
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "validation_failed"
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "value_too_large"
      refute inspect(entry) =~ "aaaaaaaa"
      refute inspect(refused.after_state) =~ "aaaaaaaa"
    end

    # D-C.7 boundary: the cap is on the JSON encoding of a value (65_536 bytes), the string quotes
    # included. 65_533 characters encode to 65_535 bytes (one under), 65_534 to 65_536 (exactly the
    # cap: commits), 65_535 to 65_537 (one over: refused).
    test "a value exactly at the service cap (65_534 characters, 65_536 bytes) commits" do
      ctx = Mw.service_case!("gh2590-r5-size-at", :svc_module)
      at = String.duplicate("a", 65_534)

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => at})
      assert [%{field_values: %{"item" => ^at}}] = Fx.records(ctx.schema, "fxl_ledger")
    end

    test "a value one byte under the service cap commits (control for the over-cap refusal)" do
      ctx = Mw.service_case!("gh2590-r5-size-under", :svc_module)
      under = String.duplicate("a", 65_533)

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => under})
      assert [%{field_values: %{"item" => ^under}}] = Fx.records(ctx.schema, "fxl_ledger")
    end

    test "a value one byte over the service cap is refused" do
      ctx = Mw.service_case!("gh2590-r5-size-over", :svc_module)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => String.duplicate("a", 65_535)})
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "value_too_large"
      assert_nothing_written(ctx)
    end

    test "a missing required argument (the response did not carry `label`) is validation_failed" do
      ctx = Mw.service_case!("gh2590-r5-noarg", :svc_module)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{})

      assert_nothing_written(ctx)
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "validation_failed"
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "handler_invalid_arguments"
    end

    test "a MIXED node whose handler fails rolls the declarative record back too" do
      ctx = Mw.service_case!("gh2590-r5-mixedfail", :svc_mixed)

      # `item` must be a string: the handler answers :invalid_arguments for an integer
      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => 5})

      assert_landed(ctx, "validation_failed", 1, "handler_invalid_arguments")
      assert Fx.records(ctx.schema, "stock_move") == []
    end
  end

  describe "duplicate apply, contention and the deadline guard" do
    test "a second apply answers already_final: no second handler run, no port multi, nothing written" do
      ctx = Mw.service_case!("gh2590-r5-dup", :svc_module)
      trace_handlers!()
      ChaosEntityPort.record!()

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => @label})
      # non-vacuous: the first apply DID run the handler once and build the Multi
      assert drain_handler_calls() == 1
      assert_received {:port_call, :multi, _ctx}
      flush_port_calls()
      before = written(ctx)

      log =
        capture_log(fn ->
          assert {:ok, :already_final} = Fx.apply_http(ctx, %{"label" => @label})
        end)

      refute log =~ "[error]"
      assert drain_handler_calls() == 0
      refute_received {:port_call, :multi, _ctx}

      assert written(ctx) == before
      assert Fx.dlq_entries(ctx.schema) == []
    end

    test "a refused apply is repeatable only as already_final: one incident, no second handler run" do
      ctx = Mw.rogue_service_case!("gh2590-r5-dup-refused", "denies")
      trace_handlers!()
      ChaosEntityPort.record!()

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{})
      assert drain_handler_calls() == 1
      flush_port_calls()

      assert {:ok, :already_final} = Fx.apply_http(ctx, %{})
      assert drain_handler_calls() == 0
      refute_received {:port_call, :multi, _ctx}
      assert length(Fx.dlq_entries(ctx.schema)) == 1
    end

    test "one contention failure is re-applied and the apply then commits exactly once" do
      ctx = Mw.service_case!("gh2590-r5-cont1", :svc_module)
      counter = ChaosEntityPort.arm!(:lock_not_available, 1)

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => @label})

      assert :counters.get(counter, 1) == 2
      assert length(Fx.records(ctx.schema, "fxl_ledger")) == 1
      assert length(Fx.records(ctx.schema, "fxl_balance")) == 1
      assert Fx.step_idempotency_count(ctx.schema) == 2
      assert Fx.dlq_entries(ctx.schema) == []
    end

    test "exhaustion after three attempts lands ERROR + DLQ with entity_write_contention" do
      ctx = Mw.service_case!("gh2590-r5-cont3", :svc_module)
      counter = ChaosEntityPort.arm!(:lock_not_available, :infinity)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})

      assert :counters.get(counter, 1) == 3
      assert_landed(ctx, "entity_write_contention", 0, "exhausted")
    end

    test "control: the same port double with no tightened budget commits (the guard is positive)" do
      ctx = Mw.service_case!("gh2590-r5-deadline-ok", :svc_module)
      F.put_env!(:entity_port, FlipHashPort)

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => @label})
      assert [_] = Fx.records(ctx.schema, "fxl_ledger")
    end

    test "the handler-call deadline guard sits inside the service budget: an exhausted budget is contention" do
      ctx = Mw.service_case!("gh2590-r5-deadline", :svc_module)
      F.put_env!(:entity_port, FlipHashPort)
      # a budget no wall clock can meet: the call-level guard `{:line, k0, :deadline}` fails
      F.put_env!(:tiny_guard_budget, -1)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => @label})

      # re-applied (bounded) and landed as contention; the handler never ran
      assert_landed(ctx, "entity_write_contention", 0, "exhausted")
    end

    test "rebuilding the instance makes no port call and runs no handler" do
      ctx = Mw.service_case!("gh2590-r5-replay", :svc_module)
      trace_handlers!()
      ChaosEntityPort.record!()
      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => @label})

      # non-vacuous: the apply itself ran the handler once
      assert drain_handler_calls() == 1
      flush_port_calls()
      before = written(ctx)

      assert {:ok, %{instance_state: _state}} =
               Letflow.Engine.Reconstruction.reconstruct_instance(ctx.instance_id,
                 prefix: ctx.schema
               )

      assert drain_handler_calls() == 0
      refute_received {:port_call, _name, _arg}
      assert written(ctx) == before
    end
  end

  describe "the script-bound route (a script output is never a command)" do
    setup do
      t = F.tenant!("gh2590-r5-script")
      schema = t.schema_name
      {:ok, _} = EventTypes.seed!(schema)
      activator = Fx.user!(schema, "activator")
      Mw.install_ledger!(schema)
      tenant_id = t.tenant_id

      # the module install writes global rows (pack install ledger); remove them before the
      # tenant fixture's own teardown (on_exit runs last-registered first)
      on_exit(fn ->
        Repo.delete_all(
          from(i in Letflow.Definitions.SolutionPackInstall, where: i.tenant_id == ^tenant_id)
        )

        Repo.delete_all(
          from(b in Letflow.Definitions.SolutionPackArtefactBase,
            where: b.tenant_id == ^tenant_id
          )
        )

        Repo.delete_all(
          from(cp in Letflow.TenantProvisioning.ColumnPromotion,
            where: cp.tenant_id == ^tenant_id
          )
        )
      end)

      %{t: t, schema: schema, activator: activator}
    end

    # A stamped, script-bound definition: the stamp is the module's own install stamp (the same
    # owner a pack install would use), the handler line reads `quantity` from the script output.
    defp script_definition!(
           schema,
           activator_user,
           module_lines,
           source \\ F.doubling_source(),
           manifest \\ F.closed_manifest()
         ) do
      key = "k#{System.unique_integer([:positive])}"
      rule = F.published!(schema, key, source, manifest)

      graph =
        update_in(F.script_graph(key, rule.version), ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "svc", "attributes" => attrs} = node ->
              %{node | "attributes" => Map.put(attrs, "module_writes", module_lines)}

            node ->
              node
          end)
        end)

      {:ok, draft} =
        Definitions.create_owned(
          %{
            name: Fx.unique("gh2590-r5-script"),
            version: "1",
            graph: graph,
            created_by: activator_user.id
          },
          [prefix: schema],
          ManagedTypes.module_owner(FixtureLedger)
        )

      auth =
        Activator.from_auth_context(%{user_id: activator_user.id, roles: ["TENANT_ADMIN"]}, false)

      assert {:ok, %{definition: active}} =
               Definitions.activate(draft.id, prefix: schema, activator: auth)

      active
    end

    defp script_lines do
      [
        %{
          "module" => "fixture_ledger",
          "handler" => "post_entry",
          "args" => %{"item" => %{"const" => "widget"}, "quantity" => %{"var" => "total"}}
        }
      ]
    end

    test "activation accepts the stamped script-bound node; the run commits the handler writes",
         %{schema: schema, activator: activator} do
      definition = script_definition!(schema, activator, script_lines())
      assert %{"module_handlers" => ["fixture_ledger/post_entry"]} = definition.activated_by

      instance_id = F.start!(schema, definition, %{"amount" => 2}, Ecto.UUID.generate())

      assert {row, {:ok, :applied}} = F.run_next!(schema)
      assert F.projection(schema, instance_id).status == :completed

      assert [ledger] = Fx.records(schema, "fxl_ledger")
      assert ledger.field_values == %{"item" => "widget", "quantity" => 4}
      assert [_] = Fx.records(schema, "fxl_balance")

      sentinel = EventStore.platform_actor_id()
      events = Fx.entity_events(schema)
      assert length(events) == 2

      for {event, ordinal} <- Enum.with_index(events, 1) do
        assert event.actor_id == sentinel
        assert event.idempotency_key == "sys:step:#{row.id}:0:#{ordinal}"
        assert event.metadata["source.dispatch_id"] == row.id
        assert event.metadata["source.activator_id"] == activator.id
        assert event.metadata["source.handler_module"] == "fixture_ledger"
      end

      assert [_] = Fx.instance_events(schema, instance_id, "TASK_ENTITY_WRITES_APPLIED")
    end

    test "a hash drift before the run lands the script row failed and the instance in ERROR",
         %{schema: schema, activator: activator} do
      definition = script_definition!(schema, activator, script_lines())
      instance_id = F.start!(schema, definition, %{"amount" => 2}, Ecto.UUID.generate())
      Mw.set_installed_hash!(schema, "fixture_ledger", String.duplicate("a", 64))

      assert {row, {:ok, :failed}} = F.run_next!(schema)

      # row failed with the closed outcome detail, ERROR + exactly one DLQ entry, no run twice
      done = F.reload(schema, row)

      assert {done.status, done.outcome, done.outcome_detail} ==
               {:failed, "script_rejected", "entity_write_refused"}

      assert Fx.all_records(schema) == []
      assert Fx.step_idempotency_count(schema) == 0
      assert F.projection(schema, instance_id).status == :error
      assert F.dlq_count(schema) == 1
      refute "TASK_ENTITY_WRITES_APPLIED" in Fx.instance_event_types(schema, instance_id)
      assert [refused] = Fx.audit_rows(schema, "entity_write.refused")
      assert refused.after_state["code"] == "write_not_permitted"
      assert refused.after_state["detail"] == "hash_mismatch"
      assert refused.after_state["dispatch_id"] == row.id
    end

    test "a const over the service byte cap is refused on the script route: value_too_large, ERROR + DLQ",
         %{schema: schema, activator: activator} do
      big = String.duplicate("b", 70_000)

      lines = [
        %{
          "module" => "fixture_ledger",
          "handler" => "post_entry",
          "args" => %{"item" => %{"const" => big}, "quantity" => %{"var" => "total"}}
        }
      ]

      definition = script_definition!(schema, activator, lines)
      instance_id = F.start!(schema, definition, %{"amount" => 2}, Ecto.UUID.generate())

      assert {row, {:ok, :failed}} = F.run_next!(schema)

      assert Fx.all_records(schema) == []
      assert F.projection(schema, instance_id).status == :error
      assert F.dlq_count(schema) == 1
      assert [refused] = Fx.audit_rows(schema, "entity_write.refused")
      assert refused.after_state["code"] == "validation_failed"
      assert refused.after_state["detail"] == "value_too_large"
      assert refused.after_state["dispatch_id"] == row.id
      refute inspect(refused.after_state) =~ "bbbbbbbb"
    end

    # ---- advisor conditions for the script-bound route (D-R.18) ----------------------------

    # Condition 1: a script cannot affect handler selection. The script returns (declared, so they
    # merge into the instance variables) keys NAMED like every field the platform derives; none of
    # them reaches the module, handler, ordinal, line index or idempotency key of the write.
    test "COND 1: script output keys named module/handler/ordinal/... are ignored; the pinned line decides",
         %{schema: schema, activator: activator} do
      decoys = %{
        "module" => "string",
        "handler" => "string",
        "handler_module" => "string",
        "ordinal" => "integer",
        "write_ordinal" => "integer",
        "line_index" => "integer"
      }

      manifest =
        F.closed_manifest()
        |> update_in(["output_schema", "properties"], fn props ->
          Enum.reduce(decoys, props, fn {name, type}, acc ->
            Map.put(acc, name, %{"type" => type})
          end)
        end)
        |> update_in(["output_schema", "required"], &(&1 ++ Map.keys(decoys)))

      source = """
      return { total = ctx.input.amount * 2, module = "fixture_ledger_other",
               handler = "post_balance_only", handler_module = "fixture_ledger_other",
               ordinal = 9, write_ordinal = 9, line_index = 7 }
      """

      definition = script_definition!(schema, activator, script_lines(), source, manifest)
      instance_id = F.start!(schema, definition, %{"amount" => 2}, Ecto.UUID.generate())

      assert {row, {:ok, :applied}} = F.run_next!(schema)

      # non-vacuous: the decoys really are in the instance variables
      variables = F.projection(schema, instance_id).variables
      assert variables["module"] == "fixture_ledger_other"
      assert variables["write_ordinal"] == 9

      # ... and the committed writes are exactly the pinned line's
      events = Fx.entity_events(schema)
      assert length(events) == 2

      for {event, ordinal} <- Enum.with_index(events, 1) do
        assert event.idempotency_key == "sys:step:#{row.id}:0:#{ordinal}"
        assert event.metadata["source.handler_module"] == "fixture_ledger"
        assert event.metadata["source.handler_name"] == "post_entry"
        assert event.metadata["source.write_ordinal"] == Integer.to_string(ordinal)
        assert event.metadata["source.line_index"] == "0"
        assert event.actor_id == EventStore.platform_actor_id()
      end

      assert [_] = Fx.records(schema, "fxl_ledger")
      assert [_] = Fx.records(schema, "fxl_balance")
    end

    # Condition 2: the script output only fills declared `var` arguments and the handler validates
    # them (non-negative integer quantity, string item).
    test "COND 2: a script output violating the handler's validation (negative quantity) is refused, nothing written",
         %{schema: schema, activator: activator} do
      definition = script_definition!(schema, activator, script_lines())
      instance_id = F.start!(schema, definition, %{"amount" => -2}, Ecto.UUID.generate())

      assert {row, {:ok, :failed}} = F.run_next!(schema)

      assert Fx.all_records(schema) == []
      assert Fx.step_idempotency_count(schema) == 0
      assert F.projection(schema, instance_id).status == :error
      assert F.dlq_count(schema) == 1
      assert [refused] = Fx.audit_rows(schema, "entity_write.refused")
      assert refused.after_state["code"] == "validation_failed"
      assert refused.after_state["detail"] == "handler_invalid_arguments"
      assert refused.after_state["dispatch_id"] == row.id
      # value-free: exactly the closed key set, no argument value
      assert Map.keys(refused.after_state) |> Enum.sort() ==
               ~w(code detail dispatch_id instance_id line_index node_id)
    end

    test "COND 2: a script output of the wrong type for the handler (string quantity) is refused",
         %{schema: schema, activator: activator} do
      manifest =
        put_in(F.closed_manifest(), ["output_schema", "properties", "total"], %{
          "type" => "string"
        })

      definition =
        script_definition!(
          schema,
          activator,
          script_lines(),
          ~S|return { total = "many" }|,
          manifest
        )

      instance_id = F.start!(schema, definition, %{"amount" => 2}, Ecto.UUID.generate())

      assert {_row, {:ok, :failed}} = F.run_next!(schema)

      assert Fx.all_records(schema) == []
      assert F.projection(schema, instance_id).status == :error
      assert [refused] = Fx.audit_rows(schema, "entity_write.refused")
      assert refused.after_state["detail"] == "handler_invalid_arguments"
      refute inspect(refused.after_state) =~ "many"
    end

    test "COND 2: undeclared output keys and `_sys` keys never reach a handler: the run is rejected, nothing written",
         %{schema: schema, activator: activator} do
      for {label, source} <- [
            {"undeclared", ~S|return { total = 4, undeclared_extra = 1 }|},
            {"sys", ~S|return { total = 4, ["_sys.forged"] = "x" }|}
          ] do
        definition =
          script_definition!(schema, activator, script_lines(), source, F.closed_manifest())

        instance_id = F.start!(schema, definition, %{"amount" => 2}, Ecto.UUID.generate())

        assert {row, {:ok, :failed}} = F.run_next!(schema), label
        done = F.reload(schema, row)
        assert done.status == :failed, label
        assert done.outcome == "output_invalid", label
        assert F.projection(schema, instance_id).status == :error, label
      end

      assert Fx.all_records(schema) == []
      assert Fx.entity_events(schema) == []
    end
  end
end
