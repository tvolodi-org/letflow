defmodule Letflow.EventStoreAppendCensusTest do
  @moduledoc """
  GH #2707 / PR-2 (design `lib/letflow/design/gh2707-timer-fire-and-cold-appenders-lock-order.md`
  sections 7 and 8.3, case A2; decision 0061 "Amended (GH #2707, PR-2)", invariant I-S): the
  CENSUS of every flow that appends through `Letflow.EventStore.append/2`.

  For each flow the statements of the whole flow are captured (every process, in arrival order) and,
  for each instance whose stream the flow appends to:

    * the instance's projection row `P_x` (a `FOR (NO KEY) UPDATE` read, an UPDATE or the INSERT
      that created it) is taken BEFORE the instance's `instance_sequence` row `S_x`;
    * and every statement that takes the tenant-wide audit chain row `A` or ANOTHER sequence row (an
      entity-type row `E`) before `S_x` comes AFTER `P_x`.

  The test FAILS (it does not pass quietly) when a caller holds `A` or an `E` row without `P_x`
  first. It also checks that the flow reached the call site it claims to cover (the event type is
  among the bound parameters), and a static guard pins the number of `EventStore.append(` call
  sites per file, so a new caller fails here until it is classified.

  Standard (shared) sandbox mode: only the statement ORDER is asserted here; the forced overlaps
  live in `event_store_cold_append_lock_order_test.exs`.

  | call site | flow of this file |
  |---|---|
  | `engine.ex` `append_instance_started_event` | create |
  | `engine.ex` `append_task_completed_event` | complete |
  | `engine.ex` `append_entity_writes_applied_event` | complete with entity writes |
  | `engine.ex` `append_instance_cancelled_event` | cancel |
  | `engine.ex` `append_service_task_completed_event`, `service_entity_tail_events` | service apply (with lines) |
  | `engine.ex` `append_script_run_record_step` | script task run |
  | `engine.ex` `append_sys_variables_event` | NOT reachable without `_sys.*` outputs (see the note in the test) |
  | `execution_error.ex` | landing (`set_instance_error/2`) |
  | `pin_rebind.ex` | rebind |
  | `sub_process.ex` (child start, `709`) | create of a parent with a SUB_PROCESS node |
  | `sub_process.ex` (parent completion, `1504`) | completion of the child's last task |
  | `scheduler.ex` TIMER_FIRED | timer fire |
  | `repository/attachments.ex` (both) | the cold generic append (same `append/2` entry) |
  | `engine/lua/platform.ex` `emit_event` | a Lua script's `emit_event` |
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine
  alias Letflow.Engine.PinRebind
  alias Letflow.Engine.PinResolver.Lookup
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScriptTaskFixture, as: ScriptFx

  # ---- the static guard: `EventStore.append(` call sites in lib/ ----------------------------------

  @expected_call_sites %{
    "lib/letflow/engine.ex" => 8,
    "lib/letflow/engine/execution_error.ex" => 1,
    "lib/letflow/engine/lua/platform.ex" => 1,
    "lib/letflow/engine/pin_rebind.ex" => 1,
    "lib/letflow/engine/sub_process.ex" => 2,
    "lib/letflow/repository/attachments.ex" => 2,
    "lib/letflow/scheduler.ex" => 1
  }

  # Counts REAL call sites: comment lines and the contents of `"""` heredocs (the docs) are
  # ignored, and three forms count: `EventStore.append(`, a capture `EventStore.append/2` and
  # `apply(EventStore, :append, ...)`. An aliased module (`alias Letflow.EventStore, as: ES`) or a
  # dynamic module name is NOT detected; no such form exists in lib/ (the aliases are
  # `alias Letflow.EventStore`).
  @call_form ~r/EventStore\.append(\(|\/2)|EventStore,\s*:append\b/

  def call_site_count(source) do
    source
    |> String.split("\n")
    |> Enum.reduce({false, 0}, fn line, {in_heredoc?, count} ->
      toggles? = rem(length(String.split(line, ~s(""\"))) - 1, 2) == 1
      trimmed = String.trim_leading(line)

      cond do
        in_heredoc? -> {not toggles?, count}
        String.starts_with?(trimmed, "#") -> {false, count}
        toggles? -> {true, count}
        true -> {false, count + length(Regex.scan(@call_form, line))}
      end
    end)
    |> elem(1)
  end

  test "the call-site counter ignores comments and docs and sees the three call forms" do
    tq = ~s(""\")

    source =
      Enum.join(
        [
          "defmodule Fixture do",
          "  @moduledoc " <> tq,
          "  mentions EventStore.append( and EventStore.append/2 in prose",
          "  " <> tq,
          "  # EventStore.append(commented, out)",
          ~s|  def a, do: EventStore.append(%{}, prefix: "p")|,
          "  def b, do: Enum.map([], &EventStore.append/2)",
          "  def c, do: apply(EventStore, :append, [%{}, []])",
          "end"
        ],
        "\n"
      )

    assert call_site_count(source) == 3
  end

  test "the set of EventStore.append/2 call sites is the classified one" do
    actual =
      for path <- Path.wildcard("lib/**/*.ex"),
          not String.starts_with?(path, "lib/letflow/design/"),
          count = path |> File.read!() |> call_site_count(),
          count > 0,
          into: %{},
          do: {path, count}

    assert actual == @expected_call_sites,
           "a new or removed EventStore.append/2 caller: classify its flow in this census"
  end

  # ---- self-test of the order assertion ------------------------------------------------------------
  # The census must FAIL (not pass quietly) when a caller holds the audit chain row A or an
  # entity-type row E without P_x first.

  describe "assert_p_first!/3 self-test" do
    @x "11111111-1111-1111-1111-111111111111"
    @e "22222222-2222-2222-2222-222222222222"

    defp stmt(sql, id), do: %{query: sql, params: [Ecto.UUID.dump!(id)]}

    defp p_lock(id),
      do:
        stmt(
          ~s|SELECT i0."instance_id" FROM "t"."instance_projections" AS i0 WHERE (i0."instance_id" = $1) FOR NO KEY UPDATE|,
          id
        )

    defp s_row(id),
      do:
        stmt(
          ~s|INSERT INTO "t"."instance_sequence" ("instance_id","next_seq") VALUES ($1,$2)|,
          id
        )

    defp audit_lock,
      do: %{
        query: ~s|SELECT a0."tenant_id" FROM "t"."audit_chain_locks" AS a0 FOR UPDATE|,
        params: []
      }

    test "accepts P_x, then A and E rows, then S_x" do
      assert :ok = assert_p_first!([p_lock(@x), audit_lock(), s_row(@e), s_row(@x)], @x, "good")
    end

    test "raises when S_x comes before P_x" do
      assert_raise ExUnit.AssertionError, ~r/S_x .* taken before P_x/s, fn ->
        assert_p_first!([s_row(@x), p_lock(@x)], @x, "s-first")
      end
    end

    test "raises when the audit chain row precedes P_x" do
      assert_raise ExUnit.AssertionError, ~r/audit chain row or another sequence row/, fn ->
        assert_p_first!([audit_lock(), p_lock(@x), s_row(@x)], @x, "audit-first")
      end
    end

    test "raises when an entity-type sequence row precedes P_x" do
      assert_raise ExUnit.AssertionError, ~r/audit chain row or another sequence row/, fn ->
        assert_p_first!([s_row(@e), p_lock(@x), s_row(@x)], @x, "e-first")
      end
    end

    test "raises when P_x is never taken" do
      assert_raise ExUnit.AssertionError, ~r/P_x never taken/, fn ->
        assert_p_first!([s_row(@x)], @x, "no-p")
      end
    end
  end

  # ---- statement classification ---------------------------------------------------------------

  # Dumped UUID parameters are 16 raw bytes; a printable 16-byte string such as the event type
  # `INSTANCE_STARTED` is NOT one (LockOrderHelpers.normalize/1 would mangle it).
  defp params(q) do
    q
    |> Map.get(:params, [])
    |> List.flatten()
    |> Enum.map(fn
      p when is_binary(p) and byte_size(p) == 16 ->
        if String.printable?(p), do: p, else: Ecto.UUID.load!(p)

      p ->
        p
    end)
  end

  # Like `PlatformTenantFixture.capture_repo_queries/1` but for EVERY process (the Lua script body
  # runs in a Task process, on its own connection).
  @doc false
  def forward_query(_event, _measurements, metadata, {test_pid, ref}),
    do: send(test_pid, {:census_query, ref, metadata})

  defp capture_all(fun) do
    ref = make_ref()
    id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(id, [:letflow, :repo, :query], &__MODULE__.forward_query/4, {self(), ref})

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(ref, acc) do
    receive do
      {:census_query, ^ref, metadata} -> drain(ref, [metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp table?(q, name), do: q.query =~ ~s("#{name}")
  defp locking?(q), do: q.query =~ ~r/FOR (NO KEY )?UPDATE/
  defp writing?(q), do: q.query =~ ~r/\A(UPDATE|INSERT INTO) /

  defp p_taken?(q, x),
    do: table?(q, "instance_projections") and (locking?(q) or writing?(q)) and x in params(q)

  defp s_touched?(q, x),
    do: table?(q, "instance_sequence") and (locking?(q) or writing?(q)) and x in params(q)

  # The audit chain row `A`, or a sequence row of ANOTHER stream that is not a workflow instance
  # the transaction already holds the projection of (an entity-type row `E`: its synthetic
  # projection is only touched AFTER its sequence row, rule 5). The parent's own sequence row,
  # taken after the parent's `P_p`, is neither.
  defp other_row_before_s?(queries, i, q, x) do
    audit_chain? = table?(q, "audit_chain_locks") and locking?(q)

    entity_type_row? =
      table?(q, "instance_sequence") and (locking?(q) or writing?(q)) and x not in params(q) and
        not Enum.any?(Enum.take(queries, i), fn earlier ->
          Enum.any?(params(q), &p_taken?(earlier, &1))
        end)

    audit_chain? or entity_type_row?
  end

  defp assert_p_first!(queries, x, label) do
    statements = queries |> Enum.with_index() |> Enum.map(fn {q, i} -> "#{i}: #{q.query}" end)
    p = Enum.find_index(queries, &p_taken?(&1, x))
    s = Enum.find_index(queries, &s_touched?(&1, x))

    assert is_integer(s),
           "#{label}: no sequence row of #{x} touched\n" <> Enum.join(statements, "\n")

    assert is_integer(p),
           "#{label}: P_x never taken before the append\n" <> Enum.join(statements, "\n")

    assert p < s,
           "#{label}: S_x (#{s}) taken before P_x (#{p})\n" <> Enum.join(statements, "\n")

    for {q, i} <- Enum.with_index(queries), i < s, other_row_before_s?(queries, i, q, x) do
      assert p < i,
             "#{label}: the audit chain row or another sequence row (#{i}) is held before P_x " <>
               "(#{p}) while S_x (#{s}) is wanted\n" <> Enum.join(statements, "\n")
    end

    :ok
  end

  # Runs `fun` under statement capture; asserts the order for each `xs` and that the flow reached
  # the call site (`event_type` among the bound parameters of some statement).
  defp census!(
         label,
         xs,
         event_type,
         fun,
         capture \\ &PlatformTenantFixture.capture_repo_queries/1
       ) do
    {result, queries} = capture.(fun)

    assert Enum.any?(queries, &(event_type in params(&1))),
           "#{label}: the flow did not append #{event_type}\n" <>
             inspect(Enum.map(queries, & &1.query), limit: :infinity)

    Enum.each(xs, &assert_p_first!(queries, &1, label))
    result
  end

  # ---- fixtures ---------------------------------------------------------------------------------

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp human_graph(extra \\ %{}) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "h",
          "node_type" => "HUMAN_TASK",
          "attributes" => Map.merge(%{"role" => "REVIEWER"}, extra)
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "h"), edge("e2", "h", "end")]
    }
  end

  defp timer_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "tmr",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "PT1H"}
        },
        %{"id" => "h1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "tmr"), edge("e2", "tmr", "h1"), edge("e3", "h1", "end")]
    }
  end

  defp parent_graph(child_def) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_def.name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("p1", "start", "sp"), edge("p2", "sp", "end")]
    }
  end

  defp tenant(_context), do: %{base: Fx.tenant_case!("gh2707-census")}

  defp create_attrs(base, definition) do
    %{
      definition_id: definition.id,
      initial_variables: %{},
      actor_id: base.user.id,
      idempotency_key: Fx.unique("census-start")
    }
  end

  defp create!(base, definition) do
    {:ok, %{instance_id: id}} =
      Engine.create(create_attrs(base, definition), prefix: base.schema)

    id
  end

  defp activate!(base, graph), do: Fx.legacy_activate!(base.schema, base.user, graph, [])
  defp instance!(base, graph), do: create!(base, activate!(base, graph))

  defp pending_task!(base, instance_id, node_id) do
    Repo.one!(
      from(t in EngineTask,
        where: t.instance_id == ^instance_id and t.node_id == ^node_id and t.status == :pending
      ),
      prefix: base.schema
    )
  end

  defp complete_fn(base, task_id) do
    fn ->
      Engine.complete_task(
        task_id,
        %{
          output_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("census-complete")
        },
        prefix: base.schema
      )
    end
  end

  # ---- the flows --------------------------------------------------------------------------------

  describe "engine flows" do
    setup :tenant

    test "create (INSTANCE_STARTED)", %{base: base} do
      definition = activate!(base, human_graph())

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Engine.create(create_attrs(base, definition), prefix: base.schema)
        end)

      assert {:ok, %{instance_id: x}} = result
      assert Enum.any?(queries, &("INSTANCE_STARTED" in params(&1)))
      assert_p_first!(queries, x, "create")
    end

    test "complete (TASK_COMPLETED)", %{base: base} do
      x = instance!(base, human_graph())
      task = pending_task!(base, x, "h")
      assert {:ok, _} = census!("complete", [x], "TASK_COMPLETED", complete_fn(base, task.id))
    end

    test "cancel (INSTANCE_CANCELLED)", %{base: base} do
      x = instance!(base, human_graph())

      assert {:ok, _} =
               census!("cancel", [x], "INSTANCE_CANCELLED", fn ->
                 Engine.cancel_instance(
                   x,
                   %{actor_id: base.user.id, idempotency_key: Fx.unique("census-cancel")},
                   prefix: base.schema
                 )
               end)
    end

    test "landing (EXECUTION_ERROR)", %{base: base} do
      x = instance!(base, human_graph())

      census!("landing", [x], "EXECUTION_ERROR", fn ->
        Engine.set_instance_error(
          %{
            instance_id: x,
            error_type: :variable_schema_rejected,
            affected: {:field, "approved"},
            reason: "rejected",
            variables: %{},
            details: %{},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("census-set")
          },
          prefix: base.schema
        )
      end)
    end

    test "timer fire (TIMER_FIRED)", %{base: base} do
      x = instance!(base, timer_graph())
      [timer] = Repo.all(from(t in Timer, where: t.instance_id == ^x), prefix: base.schema)

      assert {:ok, :fired} =
               census!("timer fire", [x], "TIMER_FIRED", fn ->
                 Scheduler.fire_timer(timer.id, base.schema)
               end)
    end

    test "rebind (INSTANCE_PINS_REBOUND)", %{base: base} do
      definition = activate!(base, human_graph())

      lookup = %Lookup{
        catalog_lookup: fn _ref -> {:error, :not_found} end,
        module_lookup: fn _ref -> {:error, :not_found} end,
        variable_schema_lookup: fn _tenant_id, _process_key ->
          {:ok, %{version: "v1", json_schema: nil}}
        end
      }

      {:ok, %{instance_id: x}} =
        Engine.create(
          Map.merge(create_attrs(base, definition), %{
            pin_lookup: lookup,
            pin_overrides: [%{kind: :variable_schema, ref: definition.name, version: "v1"}]
          }),
          prefix: base.schema
        )

      assert {:ok, _} =
               census!("rebind", [x], "INSTANCE_PINS_REBOUND", fn ->
                 PinRebind.rebind_pins(
                   x,
                   %{
                     entries: [%{kind: :variable_schema, ref: definition.name, version: "v2"}],
                     reason: "census",
                     actor_id: base.user.id,
                     idempotency_key: Fx.unique("census-rebind")
                   },
                   prefix: base.schema
                 )
               end)
    end

    test "sub-process: the child start (709) and the parent's completion on the cascade (1504)",
         %{base: base} do
      child = activate!(base, human_graph())
      parent = activate!(base, parent_graph(child))

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Engine.create(create_attrs(base, parent), prefix: base.schema)
        end)

      assert {:ok, %{instance_id: parent_id}} = result

      child_id =
        Repo.one!(
          from(p in InstanceProjection,
            where: p.parent_instance_id == ^parent_id,
            select: p.instance_id
          ),
          prefix: base.schema
        )

      assert Enum.any?(queries, &("INSTANCE_STARTED" in params(&1) and child_id in params(&1)))
      assert_p_first!(queries, parent_id, "sub-process start (parent)")
      assert_p_first!(queries, child_id, "sub-process start (child, call site 709)")

      task = pending_task!(base, child_id, "h")

      assert {:ok, _} =
               census!(
                 "sub-process completion (call site 1504)",
                 [child_id, parent_id],
                 "SUB_PROCESS_COMPLETED",
                 complete_fn(base, task.id)
               )
    end
  end

  describe "entity-writes and service flows" do
    test "complete with entity writes (the applied event)" do
      ctx =
        Fx.case!("gh2707-census-ew", [Fx.line("stock_move", %{"label" => %{"const" => "a"}})])

      census!(
        "complete with entity writes",
        [ctx.instance_id],
        Letflow.Engine.EntityPort.applied_event_type(),
        fn ->
          Fx.complete(ctx, %{})
        end
      )
    end

    test "service apply with lines (SERVICE_TASK_COMPLETED and the entity tail)" do
      base = Fx.tenant_case!("gh2707-census-svc")
      Fx.define_type!(base.schema, "stock_move", %{})
      Fx.define_type!(base.schema, "stock_note", %{})

      ctx =
        Fx.attach_service!(
          base,
          Fx.service_graph([
            Fx.line("stock_note", %{"label" => %{"const" => "n"}}),
            Fx.line("stock_move", %{"label" => %{"const" => "m"}})
          ])
        )

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> Fx.apply_http(ctx, %{}) end)

      assert {:ok, :advanced} = result
      assert Enum.any?(queries, &(Letflow.Engine.EntityPort.applied_event_type() in params(&1)))
      assert_p_first!(queries, ctx.instance_id, "service apply")
    end

    test "script task run (SCRIPT_RUN_RECORDED)" do
      t = ScriptFx.tenant!("gh2707-census-script")

      b =
        ScriptFx.bound!(t, ScriptFx.doubling_source(), ScriptFx.closed_manifest(), %{
          "amount" => 2
        })

      census!("script run record", [b.instance_id], "SCRIPT_RUN_RECORDED", fn ->
        ScriptFx.run_next!(t.schema_name)
      end)
    end
  end

  describe "cold generic append and Lua emit_event" do
    setup :tenant

    defp attach_payload do
      Jason.encode!(%{
        attachment_id: Ecto.UUID.generate(),
        file_name: "a.txt",
        content_type: "text/plain",
        byte_size: 1
      })
    end

    test "the attachment-event append (ATTACHMENT_ATTACHED), unbounded and bounded", %{base: base} do
      x = instance!(base, human_graph())

      for {label, opts} <- [
            {"cold append", [prefix: base.schema]},
            {"cold append, lock_timeout_ms",
             [
               prefix: base.schema,
               lock_timeout_ms: 2_000
             ]}
          ] do
        assert {:ok, _} =
                 census!(label, [x], "ATTACHMENT_ATTACHED", fn ->
                   EventStore.append(
                     %{
                       instance_id: x,
                       event_type: "ATTACHMENT_ATTACHED",
                       payload: attach_payload(),
                       actor_id: base.user.id,
                       idempotency_key: Fx.unique("census-attach")
                     },
                     opts
                   )
                 end)
      end
    end

    test "Attachments.upload/2 and delete/3 (call sites 375 and 413)", %{base: base} do
      alias Letflow.Repository.Attachments
      x = instance!(base, human_graph())

      assert {:ok, attachment} =
               census!("attachments upload", [x], "ATTACHMENT_ATTACHED", fn ->
                 Attachments.upload(
                   %{
                     instance_id: x,
                     raw_bytes: "hello",
                     file_name: "n.txt",
                     content_type: "text/plain",
                     uploaded_by: base.user.id,
                     description: nil
                   },
                   prefix: base.schema
                 )
               end)

      assert {:ok, _} =
               census!("attachments delete", [x], "ATTACHMENT_REMOVED", fn ->
                 Attachments.delete(attachment.id, base.user.id, prefix: base.schema)
               end)
    end

    test "Lua emit_event, run in a Task process like the executor's script body", %{base: base} do
      x = instance!(base, human_graph())

      script = """
      return platform.emit_event('ATTACHMENT_ATTACHED', {attachment_id = 'a1', file_name = 'f', content_type = 't', byte_size = 1}, 'census-key')
      """

      assert {[true], _lua} =
               census!(
                 "lua emit_event",
                 [x],
                 "ATTACHMENT_ATTACHED",
                 fn ->
                   task =
                     Task.Supervisor.async_nolink(Letflow.Engine.Lua.TaskSupervisor, fn ->
                       lua =
                         Letflow.Engine.Lua.Platform.install(
                           Letflow.Engine.Lua.Sandbox.new(),
                           Letflow.Engine.Lua.Capabilities.new(["event:emit"]),
                           Map.merge(Letflow.Engine.Lua.Platform.empty_execution_context(), %{
                             instance_id: x,
                             prefix: base.schema,
                             actor_id: base.user.id
                           })
                         )

                       Lua.eval!(lua, script)
                     end)

                   Task.await(task, 10_000)
                 end,
                 &capture_all/1
               )
    end
  end
end
