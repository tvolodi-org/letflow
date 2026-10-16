defmodule Letflow.Engine.CompleteTaskEntityWritesTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B2 (design `gh2587-req499-pr-b-human-task-writes.md`, tests B-2, B-5,
  B-6, B-10, B-11 (instance and audit half), B-13 (run-time half), B-14, B-15, CO-6 and the
  CDV/SEC carry-overs): a HUMAN_TASK completion composes its declared entity writes into the
  ONE completion transaction.

  Real Postgres through the real `Letflow.Engine.complete_task/3`. The `_sys` values are
  produced by the real writer (CO-2): `EntityWritesFixture.complete_with_lines!/2`.
  `async: false`: the port test double is application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.VariableMerge
  alias Letflow.Entities.EntityPortImpl
  alias Letflow.Entities.StepWrites
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture

  defmodule TestPort do
    @moduledoc false
    @behaviour Letflow.Engine.EntityPort

    defp report(call) do
      case :persistent_term.get({__MODULE__, :pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:port_call, call})
        _ -> :ok
      end
    end

    @impl true
    def authorize_module_writes(lines, ctx),
      do: EntityPortImpl.authorize_module_writes(lines, ctx)

    @impl true
    def prefetch(prefix, reads, vars), do: EntityPortImpl.prefetch(prefix, reads, vars)

    @impl true
    def prepare(lines, ctx) do
      report(:prepare)
      EntityPortImpl.prepare(lines, ctx)
    end

    @impl true
    def validate_lines(lines, ctx) do
      report(:validate_lines)
      EntityPortImpl.validate_lines(lines, ctx)
    end

    @impl true
    def multi(multi, lines, ctx) do
      report(:multi)
      base = EntityPortImpl.multi(multi, lines, ctx)

      case :persistent_term.get({__MODULE__, :chaos}, nil) do
        {:raise, exception} ->
          Multi.run(base, :chaos, fn _repo, _changes -> raise exception end)

        :sleep ->
          Multi.run(base, :chaos, fn repo, _changes ->
            repo.query!("SELECT pg_sleep(7)")
            {:ok, :slept}
          end)

        nil ->
          base
      end
    end

    @impl true
    def interpret_failure(step, reason) do
      report(:interpret_failure)
      EntityPortImpl.interpret_failure(step, reason)
    end
  end

  setup do
    previous = Application.fetch_env(:letflow, :entity_port)
    :persistent_term.put({TestPort, :pid}, self())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :entity_port, value)
        :error -> Application.delete_env(:letflow, :entity_port)
      end

      :persistent_term.erase({TestPort, :pid})
      :persistent_term.erase({TestPort, :chaos})
    end)

    :ok
  end

  defp use_test_port, do: Application.put_env(:letflow, :entity_port, TestPort)

  defp two_lines do
    [
      Map.put(
        Fx.line("stock_move", %{"label" => %{"var" => "label"}}),
        "output_record_id_var",
        "_sys.move"
      ),
      Fx.line("stock_note", %{
        "label" => %{"const" => "fixed"},
        "note" => %{"var" => "note"}
      })
    ]
  end

  defp case!(lines \\ two_lines()), do: Fx.case!("gh2587-b2", lines)

  defp graph_case!(graph) do
    base = Fx.tenant_case!("gh2587-b2g")
    Fx.define_type!(base.schema, "stock_move", %{})
    Fx.define_type!(base.schema, "stock_note", %{})

    definition =
      Fx.legacy_activate!(base.schema, base.user, graph, [
        {"stock_move", "create"},
        {"stock_note", "create"}
      ])

    {instance_id, task} = Fx.start!(base.schema, definition)
    Map.merge(base, %{definition: definition, instance_id: instance_id, task: task})
  end

  defp event_count(ctx), do: Fx.all_instance_event_count(ctx.schema, ctx.instance_id)

  defp assert_nothing_written(ctx, events_before) do
    assert Fx.all_records(ctx.schema) == []
    assert Fx.step_idempotency_count(ctx.schema) == 0
    assert Fx.audit_rows(ctx.schema, "entity_write.process_step") == []
    assert event_count(ctx) == events_before
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
  end

  defp edit_pinned_lines!(ctx, fun) do
    snapshot = Repo.get!(InstanceDefinitionSnapshot, ctx.instance_id, prefix: ctx.schema)

    nodes =
      Enum.map(snapshot.graph["nodes"], fn
        %{"id" => "ht", "attributes" => attrs} = node ->
          %{node | "attributes" => Map.update!(attrs, "entity_writes", fun)}

        node ->
          node
      end)

    {1, _} =
      from(s in InstanceDefinitionSnapshot, where: s.instance_id == ^ctx.instance_id)
      |> Repo.update_all([set: [graph: %{snapshot.graph | "nodes" => nodes}]], prefix: ctx.schema)

    :ok
  end

  defp set_activated_by!(ctx, activated_by) do
    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^ctx.definition.id)
      |> Repo.update_all([set: [activated_by: activated_by]], prefix: ctx.schema)

    :ok
  end

  describe "B-2: success composes everything in one transaction" do
    test "records, instance events, audit, projection and the task commit together" do
      ctx = case!()

      result = Fx.complete_with_lines!(ctx, %{"label" => "L1", "note" => "N1"})

      assert [move] = Fx.records(ctx.schema, "stock_move")
      assert [note] = Fx.records(ctx.schema, "stock_note")
      assert move.field_values["label"] == "L1"
      assert note.field_values == %{"label" => "fixed", "note" => "N1"}

      # the engine-only values reach the result and the projection through the real writer
      assert result.variables["_sys.move"] == move.record_id
      assert result.variables["_sys.move.seq"] == move.last_event_global_seq

      projection = Fx.projection!(ctx.schema, ctx.instance_id)
      assert projection.variables["_sys.move"] == move.record_id
      assert projection.variables["_sys.move.seq"] == move.last_event_global_seq

      assert [sys] = Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_SYS_VARIABLES_SET")

      assert [applied] =
               Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")

      assert [completed] = Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_COMPLETED")
      assert sys.sequence_number < completed.sequence_number
      assert applied.sequence_number < completed.sequence_number

      assert Fx.task!(ctx.schema, ctx.task.id).status == :completed
      assert Fx.step_idempotency_count(ctx.schema) == 2

      # one audit entry per applied line, and the chain verifies
      assert [_, _] = Fx.audit_rows(ctx.schema, "entity_write.process_step")
      assert {:ok, :valid} = Audit.verify_chain(ctx.schema)
    end

    test "the SYS event and the APPLIED event carry ids and sequences only, no metadata" do
      ctx = case!()
      Fx.complete_with_lines!(ctx, %{"label" => "secret-value-1", "note" => "secret-value-2"})

      for type <- ["INSTANCE_SYS_VARIABLES_SET", "TASK_ENTITY_WRITES_APPLIED"],
          event <- Fx.instance_events(ctx.schema, ctx.instance_id, type) do
        refute inspect(event.payload) =~ "secret-value"
        # B3 SEC F3: nothing `_sys`-derived in instance-event metadata
        assert event.metadata in [nil, %{}]
      end

      assert [applied] =
               Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")

      payload = decode(applied.payload)
      assert payload["lines_hash"] == StepWrites.lines_hash(two_lines())
      assert [%{"line_index" => 0}, %{"line_index" => 1}] = payload["lines"]
    end

    test "a retry of a committed completion is task_not_pending and writes nothing more" do
      ctx = case!()
      Fx.complete_with_lines!(ctx, %{"label" => "L1", "note" => "N1"})

      assert {:error, {:task_not_pending, :completed}} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

      assert length(Fx.all_records(ctx.schema)) == 2
    end

    test "replay never re-executes a write and rebuilds the same variables (B-14, F-3)" do
      ctx = case!()
      Fx.complete_with_lines!(ctx, %{"label" => "L1", "note" => "N1"})
      use_test_port()
      flush_port_calls()

      assert {:ok, %{instance_state: state}} =
               Reconstruction.reconstruct_instance(ctx.instance_id, prefix: ctx.schema)

      projection = Fx.projection!(ctx.schema, ctx.instance_id)
      assert state.variables == projection.variables
      assert Map.has_key?(state.variables, "_sys.move")
      assert port_calls() == []
    end
  end

  describe "B-2: failures write nothing" do
    test "a refused second line rolls back the first" do
      lines = [
        Fx.line("stock_move", %{"label" => %{"var" => "label"}}),
        # `label` is required; the variable is absent, so line 1 fails validation
        Fx.line("stock_note", %{"label" => %{"var" => "absent"}})
      ]

      ctx = case!(lines)
      before = event_count(ctx)

      assert {:error, {:entity_write_refused, 1, :validation_failed}} =
               Fx.complete(ctx, %{"label" => "L1"})

      assert_nothing_written(ctx, before)

      # the best-effort refusal audit carries the closed detail atom and no field name
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["line_index"] == 1
      assert entry.after_state["code"] == "validation_failed"
      refute inspect(entry.after_state) =~ "label"

      # a retry after the rollback reuses the same step keys and succeeds once fixed
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1", "absent" => "now"})
      assert length(Fx.all_records(ctx.schema)) == 2
    end

    test "a :transition execution error (no matching edge) writes nothing (F-2)" do
      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "ht",
            "node_type" => "HUMAN_TASK",
            "attributes" => %{
              "role" => "REVIEWER",
              "entity_writes" => [Fx.line("stock_move", %{"label" => %{"var" => "label"}})]
            }
          },
          %{"id" => "xg", "node_type" => "EXCLUSIVE_GATEWAY"},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "ht"},
          %{"id" => "e2", "source" => "ht", "target" => "xg"},
          %{
            "id" => "e3",
            "source" => "xg",
            "target" => "end",
            "condition" => "variables.approved == true"
          }
        ]
      }

      ctx = graph_case!(graph)

      assert {:error, {:instance_execution_error, _type, _affected}} =
               Fx.complete(ctx, %{"label" => "L1", "approved" => false})

      assert Fx.all_records(ctx.schema) == []
      assert Fx.step_idempotency_count(ctx.schema) == 0
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
      assert Fx.task!(ctx.schema, ctx.task.id).status == :pending

      assert {:error, {:instance_not_active, :error}} =
               Fx.complete(ctx, %{"label" => "L1", "approved" => true})
    end

    test "a :merge execution error writes nothing" do
      ctx = case!()
      before = event_count(ctx)

      result = Fx.complete(ctx, %{"label" => "L1", "_sys.forged" => "x"})
      refute match?({:ok, _}, result)
      assert Fx.all_records(ctx.schema) == []
      assert Fx.step_idempotency_count(ctx.schema) == 0
      assert Fx.audit_rows(ctx.schema, "entity_write.process_step") == []
      assert event_count(ctx) >= before
    end

    test "required outputs missing is refused before any write" do
      graph = Fx.graph(two_lines())

      graph =
        update_in(graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "ht"} = node ->
              put_in(node, ["attributes", "required_outputs"], ["must_have"])

            node ->
              node
          end)
        end)

      ctx = graph_case!(graph)
      assert {:error, {:output_refused, _}} = Fx.complete(ctx, %{"label" => "L1"})
      assert Fx.all_records(ctx.schema) == []
      assert Fx.step_idempotency_count(ctx.schema) == 0
    end
  end

  describe "CDV M1: a node with lines and no plan fails closed in :completion_guards" do
    test "an unreadable plan (definition row gone) is refused, nothing committed, task pending" do
      ctx = case!()
      before = event_count(ctx)

      # P0 returns :none when the definition row cannot be read; the guard must refuse.
      Repo.query!("SET session_replication_role = replica")

      try do
        {1, _} =
          from(d in ProcessDefinition, where: d.id == ^ctx.definition.id)
          |> Repo.delete_all(prefix: ctx.schema)
      after
        Repo.query!("SET session_replication_role = DEFAULT")
      end

      assert {:error, {:entity_write_failed, 0, :not_planned}} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

      assert_nothing_written(ctx, before)
    end

    test "the existing refusals keep their order: required outputs before the guard" do
      graph = Fx.graph(two_lines())

      graph =
        update_in(graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "ht"} = node ->
              put_in(node, ["attributes", "required_outputs"], ["must_have"])

            node ->
              node
          end)
        end)

      ctx = graph_case!(graph)

      Repo.query!("SET session_replication_role = replica")

      try do
        from(d in ProcessDefinition, where: d.id == ^ctx.definition.id)
        |> Repo.delete_all(prefix: ctx.schema)
      after
        Repo.query!("SET session_replication_role = DEFAULT")
      end

      assert {:error, {:output_refused, _}} = Fx.complete(ctx, %{})
    end
  end

  describe "B-15: a completion without lines is today's Multi" do
    test "the step names are exactly the pre-B2 names" do
      base = Fx.tenant_case!("gh2587-b2names")
      plain = Fx.attach!(base, [])

      assert {:ok, names} =
               Engine.__complete_task_multi_step_names__(
                 plain.task.id,
                 plain.user.id,
                 plain.schema
               )

      assert names == [
               :task,
               :instance_projection,
               :snapshot_and_state,
               :completion_guards,
               :form_expression_reevaluation,
               :merge,
               :transition,
               :__merge__
             ]
    end

    test "a completion with lines adds only the timeouts step first and one merge" do
      ctx = case!()

      assert {:ok, [:entity_write_timeouts | rest]} =
               Engine.__complete_task_multi_step_names__(ctx.task.id, ctx.user.id, ctx.schema)

      assert rest == [
               :task,
               :instance_projection,
               :snapshot_and_state,
               :completion_guards,
               :form_expression_reevaluation,
               :merge,
               :transition,
               :__merge__,
               :__merge__
             ]
    end
  end

  describe "B-5 / CO-4: SET LOCAL timeouts only when lines exist" do
    test "a lines-completion issues the 5 s statement timeout before the first row lock" do
      ctx = case!()
      Fx.reset_local_timeouts!()

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})
        end)

      assert {:ok, _} = result
      sql = Enum.map(queries, & &1.query)

      statement_timeouts = Enum.filter(sql, &(&1 =~ "SET LOCAL statement_timeout = '5s'"))
      assert length(statement_timeouts) == 1

      first_timeout = Enum.find_index(sql, &(&1 =~ "SET LOCAL statement_timeout = '5s'"))
      first_task_lock = Enum.find_index(sql, &(&1 =~ "FOR UPDATE" and &1 =~ "\"tasks\""))
      assert first_timeout < first_task_lock
    end

    test "a completion without lines issues no SET LOCAL" do
      base = Fx.tenant_case!("gh2587-b2n")
      ctx = Fx.attach!(base, [])
      Fx.reset_local_timeouts!()

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> Fx.complete(ctx, %{}) end)

      assert {:ok, _} = result
      refute Enum.any?(queries, &(&1.query =~ "SET LOCAL"))
    end

    test "SET LOCAL really bounds the transaction: a 7 s statement is cancelled (57014)" do
      ctx = case!()
      use_test_port()
      :persistent_term.put({TestPort, :chaos}, :sleep)
      before = event_count(ctx)

      assert {:error, {:entity_write_refused, :contention, :entity_write_contention}} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

      assert_nothing_written(ctx, before)
    end
  end

  describe "CO-4: prepare/2 leaves no SET LOCAL behind under the SQL sandbox" do
    test "the session's lock_timeout and statement_timeout are unchanged after prepare" do
      ctx = case!()
      Fx.reset_local_timeouts!()

      assert :ok = StepWrites.prepare(two_lines(), %{prefix: ctx.schema})

      assert %{rows: [["0", "0"]]} =
               Repo.query!(
                 "SELECT current_setting('lock_timeout'), current_setting('statement_timeout')"
               )
    end
  end

  describe "B-4: contention mapping (injected codes, real transaction)" do
    for {label, exception} <- [
          {"lock_not_available (55P03)",
           quote(do: %Postgrex.Error{postgres: %{code: :lock_not_available, message: "x"}})},
          {"deadlock_detected (40P01)",
           quote(do: %Postgrex.Error{postgres: %{code: :deadlock_detected, message: "x"}})},
          {"query_canceled (57014)",
           quote(do: %Postgrex.Error{postgres: %{code: :query_canceled, message: "x"}})},
          {"connection error", quote(do: DBConnection.ConnectionError.exception("checkout"))}
        ] do
      test "#{label} maps to entity_write_contention and nothing is committed" do
        ctx = case!()
        use_test_port()
        :persistent_term.put({TestPort, :chaos}, {:raise, unquote(exception)})
        before = event_count(ctx)

        assert {:error, {:entity_write_refused, :contention, :entity_write_contention}} =
                 Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

        assert_nothing_written(ctx, before)
      end
    end

    test "a non-contention Postgres error is not mapped to contention" do
      ctx = case!()
      use_test_port()

      :persistent_term.put(
        {TestPort, :chaos},
        {:raise, %Postgrex.Error{postgres: %{code: :unique_violation, message: "x"}}}
      )

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})
    end

    test "the 10 s wall-clock guard trips as contention with audit detail :deadline (unit)" do
      ctx = case!()
      lines = two_lines()
      assert :ok = StepWrites.prepare(lines, %{prefix: ctx.schema})
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      now_fun = fn -> Agent.get_and_update(calls, fn n -> {n * 11_000, n + 1} end) end

      step_ctx = %{
        prefix: ctx.schema,
        task_id: ctx.task.id,
        instance_id: ctx.instance_id,
        node_id: "ht",
        definition_id: ctx.definition.id,
        definition_version: "1.0.0",
        actor_id: ctx.user.id,
        activator_id: ctx.user.id,
        authorized: [{"stock_move", "create"}, {"stock_note", "create"}],
        variables: fn _changes -> %{"label" => "L", "note" => "N"} end,
        skip?: fn _changes -> false end,
        now_fun: now_fun
      }

      assert {:error, {:line, index, :deadline} = step, :deadline_exceeded, _changes} =
               Repo.transaction(StepWrites.multi(Multi.new(), lines, step_ctx))

      assert is_integer(index)

      assert {:refused, ^index, :entity_write_contention, :deadline} =
               StepWrites.interpret_failure(step, :deadline_exceeded)

      assert Fx.all_records(ctx.schema) == []
    end
  end

  describe "B-6: a bad pinned `expected` never crashes" do
    for {label, value} <- [
          {"string", "x"},
          {"float", 1.5},
          {"negative", -1},
          {"map", %{}},
          {"valid integer on a create line", 5}
        ] do
      test "expected #{label} is validation_failed and writes nothing" do
        ctx = case!()
        value = unquote(Macro.escape(value))

        edit_pinned_lines!(ctx, fn lines ->
          [Map.put(hd(lines), "expected", value) | tl(lines)]
        end)

        before = event_count(ctx)

        assert {:error, {:entity_write_refused, 0, :validation_failed}} =
                 Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

        assert_nothing_written(ctx, before)
      end
    end

    test "an update op in a pinned line is entity_append_only (D7/D8)" do
      ctx = case!()

      edit_pinned_lines!(ctx, fn lines ->
        [Map.put(hd(lines), "op", "update") | tl(lines)]
      end)

      assert {:error, {:entity_write_refused, 0, :entity_append_only}} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})
    end
  end

  describe "D-B.17 / INV-5: every cause of write_not_permitted is one result, detail only in audit" do
    test "a pair missing from the recorded authorization (hand-edited activated_by)" do
      ctx = case!()
      set_activated_by!(ctx, activated(ctx, [%{"entity_type" => "stock_note", "op" => "create"}]))

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "not_authorized"
    end

    test "a type that lost the process-writable flag after activation" do
      ctx = case!()
      Fx.define_type!(ctx.schema, "stock_move", %{writable_by_process: false})

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "not_writable"
      assert Fx.all_records(ctx.schema) == []
    end

    test "a type that stopped being append-only after activation" do
      ctx = case!()
      Fx.define_type!(ctx.schema, "stock_move", %{append_only: false})

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "not_append_only"
    end

    test "a restricted field the completer holds no grant for (B-9)" do
      ctx = case!()
      insert_restriction!(ctx.schema, "stock_move", "label")

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "field_restricted"

      # with a grant the same completion applies
      insert_grant!(ctx.schema, ctx.user.id, "stock_move", "label")
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})
    end
  end

  describe "B-10: idempotency" do
    test "a pre-existing step key is idempotency_conflict, never success; retry after fix works" do
      ctx = case!()

      started = hd(Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_STARTED"))

      Repo.insert_all(
        "event_idempotency",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            idempotency_key: "sys:step:#{ctx.task.id}:0",
            event_id: Ecto.UUID.dump!(started.event_id),
            event_created_at: started.created_at,
            inserted_at: DateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )

      assert {:error, {:entity_write_refused, 0, :idempotency_conflict}} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

      assert Fx.all_records(ctx.schema) == []
    end
  end

  describe "B-13 run-time half and SEC INFO-1: activated_by is untrusted data at run time" do
    test "a deactivated activator is the refusal stub; the task stays pending; cancel recovers (F5)" do
      ctx = case!()
      before = event_count(ctx)

      {1, _} =
        from(u in User, where: u.id == ^ctx.user.id)
        |> Repo.update_all([set: [status: :inactive]], prefix: ctx.schema)

      assert {:error, :entity_write_needs_reactivation} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})

      assert_nothing_written(ctx, before)
      assert Fx.step_idempotency_count(ctx.schema) == 0

      # recovery: the pending task can be cancelled with its instance
      assert {:ok, _} =
               Engine.cancel_instance(
                 ctx.instance_id,
                 %{actor_id: Ecto.UUID.generate(), idempotency_key: Fx.unique("ew-cancel")},
                 prefix: ctx.schema
               )

      assert Fx.task!(ctx.schema, ctx.task.id).status == :cancelled
    end

    test "an absent activator row fails closed the same way" do
      ctx = case!()
      other = Fx.user!(ctx.schema, "ghost")

      activated =
        Map.put(activated(ctx, [pair("stock_move"), pair("stock_note")]), "user_id", other.id)

      set_activated_by!(ctx, activated)
      {1, _} = Repo.delete_all(from(u in User, where: u.id == ^other.id), prefix: ctx.schema)

      assert {:error, :entity_write_needs_reactivation} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})
    end

    test "recorded permissions without EntitiesRecordsWrite are refused" do
      ctx = case!()

      tampered =
        Map.put(activated(ctx, [pair("stock_move"), pair("stock_note")]), "permissions", [
          "DefinitionsActivate"
        ])

      set_activated_by!(ctx, tampered)

      assert {:error, :entity_write_needs_reactivation} =
               Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})
    end

    test "recorded permissions that OMIT DefinitionsActivate still run (not assumed)" do
      ctx = case!()

      only =
        Map.put(activated(ctx, [pair("stock_move"), pair("stock_note")]), "permissions", [
          "EntitiesRecordsWrite"
        ])

      set_activated_by!(ctx, only)

      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})
    end

    test "a malformed or missing activated_by is refused (fail closed)" do
      for bad <- [nil, %{}, %{"user_id" => "nope", "permissions" => [], "authorized" => []}] do
        ctx = case!()
        set_activated_by!(ctx, bad)

        assert {:error, :entity_write_needs_reactivation} =
                 Fx.complete(ctx, %{"label" => "L1", "note" => "N1"})
      end
    end
  end

  describe "B-11: audit keeps the full trail the history drops (OQ-B4)" do
    test "per-line audit: actor is the completer; record id and definition version are kept" do
      ctx = case!()
      Fx.complete_with_lines!(ctx, %{"label" => "L1", "note" => "N1"})

      entries = Fx.audit_rows(ctx.schema, "entity_write.process_step")
      assert length(entries) == 2
      records = Fx.all_records(ctx.schema) |> Map.new(&{&1.entity_type, &1.record_id})

      for entry <- entries do
        assert entry.actor_id == ctx.user.id
        assert entry.resource_type == "entity_record"
        assert entry.after_state["definition_version"] == "1.0.0"
        assert entry.after_state["definition_id"] == ctx.definition.id
        assert entry.after_state["record_id"] == records[entry.after_state["entity_type"]]
        assert entry.after_state["lines_hash"] == StepWrites.lines_hash(two_lines())
        refute inspect(entry.after_state) =~ "L1"
      end
    end
  end

  describe "CO-6: the longest accepted output name passes the strict writer" do
    test "a 151-byte name: id key and .seq key are both accepted" do
      name = String.duplicate("a", 146)
      key = "_sys." <> name
      assert byte_size(name) + 5 == 151
      id = Ecto.UUID.generate()

      assert {:ok, vars} = VariableMerge.put_sys(%{}, key, id)
      assert {:ok, _} = VariableMerge.put_sys(vars, key <> ".seq", 3)
    end
  end

  describe "CO-2: projection state is written by the engine, not hand-seeded" do
    test "the projection holds _sys only after a real completion" do
      ctx = case!()

      refute Enum.any?(
               Map.keys(Fx.projection!(ctx.schema, ctx.instance_id).variables),
               &VariableMerge.reserved_key?/1
             )

      Fx.complete_with_lines!(ctx, %{"label" => "L1", "note" => "N1"})

      assert %InstanceProjection{variables: variables} =
               Fx.projection!(ctx.schema, ctx.instance_id)

      assert VariableMerge.reserved_keys(variables) == ["_sys.move", "_sys.move.seq"]
    end
  end

  # -- helpers --------------------------------------------------------------------------

  defp pair(type), do: %{"entity_type" => type, "op" => "create"}

  defp activated(ctx, authorized) do
    %{
      "user_id" => ctx.user.id,
      "roles" => ["TENANT_ADMIN"],
      "permissions" => ["DefinitionsActivate", "EntitiesRecordsWrite"],
      "authorized" => authorized,
      "activated_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp decode(payload) when is_binary(payload), do: Jason.decode!(payload)
  defp decode(payload) when is_map(payload), do: payload

  defp insert_restriction!(schema, entity_type, field_name) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp insert_grant!(schema, user_id, entity_type, field_name) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp flush_port_calls do
    receive do
      {:port_call, _} -> flush_port_calls()
    after
      0 -> :ok
    end
  end

  defp port_calls, do: collect([])

  defp collect(acc) do
    receive do
      {:port_call, call} -> collect([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
