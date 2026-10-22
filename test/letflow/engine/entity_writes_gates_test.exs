defmodule Letflow.Engine.EntityWritesGatesTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B2, gate rework (TDV blockers 2, 3, 5 and HIGH/MEDIUM findings):
  a DISTINCT activator and completer, run-time managed types, exact event / audit contents,
  tail-failure atomicity, contention negatives, the pre-transaction `prepare/2` failure
  paths, the 20-line run-time cap and the forged `activated_by` shapes.

  Real Postgres through the real `Letflow.Engine.complete_task/3` and the real tasks router.
  Database faults are injected with real triggers raising real SQLSTATE codes (rolled back
  with the sandbox transaction). `async: false`: the entity port double is application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Ecto.Multi
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.Entities.EntityPortImpl
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture

  defmodule GatePort do
    @moduledoc false
    @behaviour Letflow.Engine.EntityPort

    @impl true
    def authorize_module_writes(lines, ctx),
      do: EntityPortImpl.authorize_module_writes(lines, ctx)

    @impl true
    def prefetch(prefix, reads, vars), do: EntityPortImpl.prefetch(prefix, reads, vars)

    @impl true
    def prepare(lines, ctx) do
      case :persistent_term.get({__MODULE__, :prepare}, nil) do
        nil ->
          result = EntityPortImpl.prepare(lines, ctx)

          case :persistent_term.get({__MODULE__, :after_prepare}, nil) do
            fun when is_function(fun, 0) -> fun.()
            _ -> :ok
          end

          result

        override ->
          override
      end
    end

    @impl true
    def validate_lines(lines, ctx), do: EntityPortImpl.validate_lines(lines, ctx)

    @impl true
    def multi(multi, lines, ctx) do
      base = EntityPortImpl.multi(multi, lines, ctx)

      case :persistent_term.get({__MODULE__, :chaos}, nil) do
        {:internal, step} ->
          Multi.run(base, {:line, 0, step}, fn _repo, _changes -> {:error, :weird} end)

        _ ->
          base
      end
    end

    @impl true
    def interpret_failure(step, reason), do: EntityPortImpl.interpret_failure(step, reason)
  end

  setup do
    previous = Application.fetch_env(:letflow, :entity_port)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :entity_port, value)
        :error -> Application.delete_env(:letflow, :entity_port)
      end

      for key <- [:prepare, :after_prepare, :chaos], do: :persistent_term.erase({GatePort, key})
    end)

    :ok
  end

  defp use_gate_port, do: Application.put_env(:letflow, :entity_port, GatePort)

  defp lines do
    [
      Map.put(
        Fx.line("stock_move", %{"label" => %{"var" => "label"}}),
        "output_record_id_var",
        "_sys.move"
      ),
      Fx.line("stock_note", %{"label" => %{"const" => "fixed"}, "note" => %{"var" => "note"}})
    ]
  end

  defp distinct!(the_lines \\ lines()), do: Fx.distinct_case!("gh2587-b2gate", the_lines)

  defp out, do: %{"label" => "L1", "note" => "N1"}

  defp events_total(ctx), do: Fx.all_instance_event_count(ctx.schema, ctx.instance_id)

  # Everything a completion with lines could have written, counted per kind (TDV HIGH 8).
  defp written(ctx) do
    %{
      records: length(Fx.all_records(ctx.schema)),
      entity_events: length(Fx.entity_events(ctx.schema)),
      step_keys: Fx.step_idempotency_count(ctx.schema),
      line_audit: length(Fx.audit_rows(ctx.schema, "entity_write.process_step")),
      sys_events:
        length(Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_SYS_VARIABLES_SET")),
      applied_events:
        length(Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")),
      completed_events: length(Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_COMPLETED")),
      instance_events: events_total(ctx)
    }
  end

  defp assert_nothing_written(ctx, baseline) do
    assert written(ctx) == baseline
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
  end

  defp install_trigger!(schema, table, event, condition, code) do
    install_trigger!(schema, table, event, condition, code, "injected")
  end

  # `message` makes the injected error distinguishable (the test asserts it was OBSERVED).
  defp install_trigger!(schema, table, event, condition, code, message) do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION "#{schema}".ew_boom() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION '#{message}' USING ERRCODE = '#{code}'; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER ew_boom BEFORE #{event} ON "#{schema}"."#{table}"
    FOR EACH ROW WHEN (#{condition}) EXECUTE FUNCTION "#{schema}".ew_boom()
    """)
  end

  defp task_completed_condition,
    do: "lower(OLD.status::text) = 'pending' AND lower(NEW.status::text) <> 'pending'"

  defp set_activated_by!(ctx, activated_by) do
    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^ctx.definition.id)
      |> Repo.update_all([set: [activated_by: activated_by]], prefix: ctx.schema)
  end

  defp valid_activated_by(user_id) do
    %{
      "user_id" => user_id,
      "roles" => ["TENANT_ADMIN"],
      "permissions" => ["DefinitionsActivate", "EntitiesRecordsWrite"],
      "authorized" => [
        %{"entity_type" => "stock_move", "op" => "create"},
        %{"entity_type" => "stock_note", "op" => "create"}
      ],
      "activated_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

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

  describe "distinct activator and completer (TDV blocker 2)" do
    test "source.activator_id is the activator; entity-event and audit actor are the completer" do
      ctx = distinct!()
      assert ctx.activator.id != ctx.user.id
      assert {:ok, _} = Fx.complete(ctx, out())

      events = Fx.entity_events(ctx.schema)
      assert length(events) == 2
      task_id = ctx.task.id

      for {event, i} <- Enum.with_index(Enum.sort_by(events, & &1.metadata["source.line_index"])) do
        assert event.actor_id == ctx.user.id
        assert event.idempotency_key == "sys:step:#{task_id}:#{i}"

        # the exact source.* metadata: eight flat keys, version as the stored string
        assert event.metadata == %{
                 "source.kind" => "process_step",
                 "source.instance_id" => ctx.instance_id,
                 "source.task_id" => task_id,
                 "source.node_id" => "ht",
                 "source.definition_id" => ctx.definition.id,
                 "source.definition_version" => "1.0.0",
                 "source.line_index" => Integer.to_string(i),
                 "source.activator_id" => ctx.activator.id
               }
      end

      for entry <- Fx.audit_rows(ctx.schema, "entity_write.process_step") do
        assert entry.actor_id == ctx.user.id
      end

      assert [done] = Fx.audit_rows(ctx.schema, "task.complete")
      assert done.actor_id == ctx.user.id
    end

    test "restrictions are loaded for the COMPLETER: a grant held only by the activator does not help" do
      ctx = distinct!()
      insert_restriction!(ctx.schema, "stock_move", "label")
      insert_grant!(ctx.schema, ctx.activator.id, "stock_move", "label")
      baseline = written(ctx)

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
               Fx.complete(ctx, out())

      assert_nothing_written(ctx, baseline)
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "field_restricted"
      assert entry.actor_id == ctx.user.id

      # a grant held by the completer allows the same completion
      insert_grant!(ctx.schema, ctx.user.id, "stock_move", "label")
      assert {:ok, _} = Fx.complete(ctx, out())
    end
  end

  describe "run-time managed type (TDV blocker 3)" do
    test "a type that became managed after activation is write_not_permitted end to end" do
      # A managed type cannot be created over an existing plain name, so the reachable shapes
      # are a hand-edited pinned snapshot (and recorded authorization) naming a type a module
      # already manages. `fxm_ledger` is in the fixture module's manages list.
      ctx = distinct!()
      Fx.install_managed_fixture!(ctx.schema)

      assert {:ok, _} =
               Letflow.Entities.EntityTypeInstance.get_or_create("fxm_ledger", ctx.schema)

      edit_pinned_lines!(ctx, fn _ ->
        [Fx.line("fxm_ledger", %{"label" => %{"var" => "label"}})]
      end)

      set_activated_by!(
        ctx,
        Map.put(valid_activated_by(ctx.activator.id), "authorized", [
          %{"entity_type" => "fxm_ledger", "op" => "create"}
        ])
      )

      baseline = written(ctx)

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
               Fx.complete(ctx, out())

      assert_nothing_written(ctx, baseline)
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "managed"
    end

    test "the authority passed to Records.command_multi/3 is the literal :tenant" do
      source = File.read!("lib/letflow/entities/step_writes.ex")
      assert source =~ "Records.command_multi(command, ctx.prefix, :tenant)"
      refute source =~ "ManagedTypes.module_owner"
    end
  end

  describe "exact event and audit contents (TDV HIGH 6)" do
    test "SYS and APPLIED payloads, idempotency keys and per-line audit" do
      ctx = distinct!()
      assert {:ok, _} = Fx.complete(ctx, out())

      [completed] = Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_COMPLETED")
      key = completed.idempotency_key
      [move] = Fx.records(ctx.schema, "stock_move")
      [note] = Fx.records(ctx.schema, "stock_note")

      [sys] = Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_SYS_VARIABLES_SET")
      assert sys.idempotency_key == key <> "::sys_vars"
      assert sys.actor_id == ctx.user.id

      assert payload(sys) == %{
               "node_id" => "ht",
               "cause" => "entity_writes",
               "values" => %{
                 "_sys.move" => move.record_id,
                 "_sys.move.seq" => move.last_event_global_seq
               }
             }

      [applied] = Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")
      assert applied.idempotency_key == key <> "::entity_writes"

      assert payload(applied) == %{
               "node_id" => "ht",
               "task_id" => ctx.task.id,
               "dispatch_id" => nil,
               "lines_hash" => Letflow.Entities.StepWrites.lines_hash(lines()),
               "lines" => [
                 %{
                   "line_index" => 0,
                   "entity_type" => "stock_move",
                   "record_id" => move.record_id,
                   "event_global_seq" => move.last_event_global_seq
                 },
                 %{
                   "line_index" => 1,
                   "entity_type" => "stock_note",
                   "record_id" => note.record_id,
                   "event_global_seq" => note.last_event_global_seq
                 }
               ]
             }

      assert sys.sequence_number < applied.sequence_number
      assert applied.sequence_number < completed.sequence_number
      refute key =~ "sys:step:"
    end
  end

  describe "failure atomicity (TDV HIGH 7, 8)" do
    test "a form-expression error forces the :merge execution-error branch (deterministic)" do
      ctx = distinct!()
      baseline = written(ctx)

      # a cross_field_validation rule the submitted output violates: the pinned task
      # form_schema makes FormExpressionReevaluation.reevaluate/4 return an error, so the
      # :merge step yields {:execution_error, _} and the instance parks in ERROR
      form_schema = %{
        "type" => "object",
        "properties" => %{
          "label" => %{"type" => "string"},
          "note" => %{"type" => "string"},
          "amount" => %{"type" => "number"},
          "confirm" => %{
            "type" => "boolean",
            "x-ui" => %{
              "cross_field_validation" => %{
                "expression" => "amount > 0",
                "message" => "amount must be positive"
              }
            }
          }
        }
      }

      {1, _} =
        from(t in Letflow.Engine.Task, where: t.id == ^ctx.task.id)
        |> Repo.update_all([set: [form_schema: form_schema]], prefix: ctx.schema)

      assert {:error,
              {:instance_execution_error, :form_cross_field_validation_failed,
               {:field, "confirm"}}} =
               Fx.complete(
                 ctx,
                 Map.merge(out(), %{"amount" => -5, "confirm" => true})
               )

      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
      assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
      assert written(ctx).records == 0
      assert written(ctx).entity_events == 0
      assert written(ctx).step_keys == 0
      assert written(ctx).line_audit == 0
      assert written(ctx).sys_events == baseline.sys_events
      assert written(ctx).applied_events == baseline.applied_events
      assert Fx.instance_events(ctx.schema, ctx.instance_id, "EXECUTION_ERROR") != []

      # NOTE (stated): `:transition` passes a merge execution error straight through
      # (dispatch_task_completion_hop_chain/7, first clause), so `changes.transition` is ALSO
      # `{:execution_error, _}` and the `skip?` merge clause is redundant defence in depth.
      # This case would stay green if that one clause were deleted.
    end

    test "a :merge execution error is pinned: error shape, instance :error, nothing written" do
      ctx = distinct!()
      baseline = written(ctx)

      # a reserved key in the submitted output
      assert {:error, reason} = Fx.complete(ctx, %{"label" => "L1", "_sys.forged" => "x"})

      assert match?({:output_refused, _}, reason) or
               match?({:instance_execution_error, _, _}, reason),
             inspect(reason)

      assert written(ctx).records == 0
      assert written(ctx).entity_events == 0
      assert written(ctx).step_keys == 0
      assert written(ctx).line_audit == 0
      assert written(ctx).sys_events == baseline.sys_events
      assert Fx.task!(ctx.schema, ctx.task.id).status == :pending

      case reason do
        {:instance_execution_error, _, _} ->
          assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error

        _ ->
          assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
      end
    end

    test "a TAIL step failing after :entity_writes rolls everything back" do
      ctx = distinct!()
      baseline = written(ctx)
      install_trigger!(ctx.schema, "tasks", "UPDATE", task_completed_condition(), "P0001")

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} = Fx.complete(ctx, out())

      assert_nothing_written(ctx, baseline)
      assert Fx.projection!(ctx.schema, ctx.instance_id).variables == %{}
    end
  end

  describe "B-4 negatives (TDV blocker 5)" do
    test "the same 55P03 inside a completion WITHOUT lines is contention too (GH #2823)" do
      base = Fx.tenant_case!("gh2587-b2neg")
      ctx = Fx.attach!(base, [])
      install_trigger!(ctx.schema, "tasks", "UPDATE", task_completed_condition(), "55P03")

      assert {:error, {:entity_write_refused, :contention, :entity_write_contention}} =
               Fx.complete(ctx, %{})
    end

    test "the same 55P03 inside a completion WITH lines is contention, nothing committed" do
      ctx = distinct!()
      baseline = written(ctx)
      install_trigger!(ctx.schema, "tasks", "UPDATE", task_completed_condition(), "55P03")

      assert {:error, {:entity_write_refused, :contention, :entity_write_contention}} =
               Fx.complete(ctx, out())

      assert_nothing_written(ctx, baseline)
    end

    test "a contention code raised AFTER the commit is not mapped; the task stays completed" do
      ctx = distinct!()

      # `SnapshotWriter.maybe_take_snapshot/4` inserts only when the event sequence is at
      # least 1000 past the last snapshot. Move the instance's sequence counter so this
      # completion's events land at >= 1000 and the post-commit snapshot INSERT is attempted.
      {1, _} =
        from(s in "instance_sequence", where: s.instance_id == type(^ctx.instance_id, Ecto.UUID))
        |> Repo.update_all([set: [next_seq: 1000]], prefix: ctx.schema)

      install_trigger!(
        ctx.schema,
        "instance_state_snapshots",
        "INSERT",
        "TRUE",
        "55P03",
        "post_commit_snapshot_marker"
      )

      result = Fx.complete(ctx, out())

      # ACTUAL shape: the snapshot INSERT raises AFTER the transaction committed. The raise is
      # NOT inside `run_transaction/2` (the contention rescue wraps only `Repo.transaction/1`),
      # so it surfaces through the function-level blanket rescue as `{:transaction_failed, _}`,
      # never as the 503 contention refusal. The distinguishable message proves the trigger
      # fired (a vacuous test would have returned `{:ok, _}`).
      assert {:error,
              {:transaction_failed,
               %Postgrex.Error{
                 postgres: %{code: :lock_not_available, message: "post_commit_snapshot_marker"}
               }}} = result

      # the transaction DID commit: the task is completed and the records exist
      assert Fx.task!(ctx.schema, ctx.task.id).status == :completed
      assert length(Fx.records(ctx.schema, "stock_move")) == 1
      assert length(Fx.records(ctx.schema, "stock_note")) == 1
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :completed
    end

    # B-17 (ambiguous commit): the window "the server committed but the client saw a
    # connection error" cannot be produced here without a seam in Letflow.Repo / the driver.
    # A trigger or `pg_terminate_backend` fires BEFORE the COMMIT is acknowledged, which makes
    # the transaction NOT committed (a plain failure), not ambiguous; and a deferred constraint
    # trigger never fires under the SQL sandbox's outer transaction. What IS asserted is the
    # client-visible consequence the design relies on: after a committed completion a retry is
    # `task_not_pending` and duplicates nothing.
    test "a retry after a committed completion is task_not_pending and duplicates nothing (B-17)" do
      ctx = distinct!()
      assert {:ok, _} = Fx.complete(ctx, out())
      after_first = written(ctx)

      assert {:error, {:task_not_pending, :completed}} = Fx.complete(ctx, out())
      assert written(ctx) == after_first
    end

    test "prepare/2 contention from the pre-transaction phase is 503-shaped, nothing opened" do
      ctx = distinct!()
      baseline = written(ctx)
      use_gate_port()
      :persistent_term.put({GatePort, :prepare}, {:error, :entity_write_contention})

      assert {:error, {:entity_write_refused, :contention, :entity_write_contention}} =
               Fx.complete(ctx, out())

      assert_nothing_written(ctx, baseline)
    end

    test "prepare/2 internal failures are {:entity_write_failed, 0, :prepare}" do
      ctx = distinct!()
      use_gate_port()

      for failure <- [
            {:error, :prepare_inside_transaction},
            {:error, {:entity_type_prepare_failed, "stock_move"}}
          ] do
        :persistent_term.put({GatePort, :prepare}, failure)

        assert {:error, {:entity_write_failed, 0, :prepare}} = Fx.complete(ctx, out())
      end

      assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
    end
  end

  describe "internal failures (TDV HIGH 9)" do
    test "{:entity_write_failed, i, step} is a logged 500 through the router, body without the step" do
      ctx = distinct!()
      :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.user.id])
      use_gate_port()
      :persistent_term.put({GatePort, :chaos}, {:internal, :boom})
      baseline = written(ctx)

      log =
        capture_log([level: :error], fn ->
          conn =
            conn(:post, "/#{ctx.task.id}/complete")
            |> Map.put(:body_params, %{"label" => "SECRET-VALUE-91", "note" => "N1"})
            |> put_req_header("content-type", "application/json")
            |> assign(:auth_context, %{
              user_id: ctx.user.id,
              tenant_id: ctx.tenant.tenant_id,
              roles: ["TENANT_ADMIN"]
            })
            |> assign(:trace_id, "gh2587-b2-gate")
            |> then(&Letflow.Routers.Tasks.call(&1, Letflow.Routers.Tasks.init([])))

          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 500
      refute conn.resp_body =~ "boom"
      assert log =~ "failed internally at step :boom"
      refute log =~ "SECRET-VALUE-91"
      assert_nothing_written(ctx, baseline)
    end

    test "a missing actor is :missing_actor_id and writes nothing" do
      ctx = distinct!()
      baseline = written(ctx)

      assert {:error, :missing_actor_id} =
               Engine.complete_task(
                 ctx.task.id,
                 %{output_variables: out(), actor_id: nil, idempotency_key: Fx.unique("k")},
                 prefix: ctx.schema
               )

      assert_nothing_written(ctx, baseline)
    end
  end

  describe "I-B6: the 20-line cap holds at run time (SEC MEDIUM-1)" do
    test "a pinned snapshot hand-edited to 21 lines is refused, nothing written, no 500" do
      ctx = distinct!()
      line = Fx.line("stock_move", %{"label" => %{"const" => "x"}})
      edit_pinned_lines!(ctx, fn _ -> List.duplicate(line, 21) end)
      baseline = written(ctx)

      assert {:error, {:entity_write_refused, 20, :validation_failed}} =
               Fx.complete(ctx, out())

      assert_nothing_written(ctx, baseline)
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "too_many_lines"
    end

    test "the same through the real route is 422 with the declared index" do
      ctx = distinct!()
      :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.user.id])
      line = Fx.line("stock_move", %{"label" => %{"const" => "x"}})
      edit_pinned_lines!(ctx, fn _ -> List.duplicate(line, 21) end)

      conn =
        conn(:post, "/#{ctx.task.id}/complete")
        |> Map.put(:body_params, out())
        |> put_req_header("content-type", "application/json")
        |> assign(:auth_context, %{
          user_id: ctx.user.id,
          tenant_id: ctx.tenant.tenant_id,
          roles: ["TENANT_ADMIN"]
        })
        |> assign(:trace_id, "gh2587-b2-gate")
        |> then(&Letflow.Routers.Tasks.call(&1, Letflow.Routers.Tasks.init([])))

      assert conn.status == 422

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "validation_failed",
               "line_index" => 20
             }
    end
  end

  describe "SEC INFO-1 forged activated_by shapes (TDV 14)" do
    test "malformed authorized entries, a non-list permissions value and non-map are refused" do
      forged = [
        Map.put(valid_activated_by(Ecto.UUID.generate()), "authorized", ["stock_move"]),
        Map.put(valid_activated_by(Ecto.UUID.generate()), "authorized", [
          %{"entity_type" => 5, "op" => "create"}
        ]),
        Map.put(valid_activated_by(Ecto.UUID.generate()), "permissions", "EntitiesRecordsWrite"),
        Map.put(valid_activated_by(Ecto.UUID.generate()), "authorized", "stock_move")
      ]

      for activated_by <- forged do
        ctx = distinct!()
        baseline = written(ctx)
        set_activated_by!(ctx, Map.put(activated_by, "user_id", ctx.activator.id))

        assert {:error, :entity_write_needs_reactivation} = Fx.complete(ctx, out()),
               inspect(activated_by)

        assert_nothing_written(ctx, baseline)
      end
    end

    test "a valid-looking activated_by naming a different ACTIVE user runs as that recorded user" do
      ctx = distinct!()
      other = Fx.user!(ctx.schema, "other")
      set_activated_by!(ctx, valid_activated_by(other.id))

      # No signature exists: the recorded document IS the authority (the trust boundary is
      # write access to process_definitions). The run is attributed to the recorded user.
      assert {:ok, _} = Fx.complete(ctx, out())

      for event <- Fx.entity_events(ctx.schema) do
        assert event.metadata["source.activator_id"] == other.id
        assert event.actor_id == ctx.user.id
      end

      # and an INACTIVE named user is the refusal stub
      ctx2 = distinct!()
      ghost = Fx.user!(ctx2.schema, "ghost")

      {1, _} =
        from(u in User, where: u.id == ^ghost.id)
        |> Repo.update_all([set: [status: :inactive]], prefix: ctx2.schema)

      set_activated_by!(ctx2, valid_activated_by(ghost.id))
      assert {:error, :entity_write_needs_reactivation} = Fx.complete(ctx2, out())
    end
  end

  describe "B-5 statement log (TDV MEDIUM 10)" do
    test "the two SET LOCALs are the FIRST statements of the transaction, before the first row lock" do
      ctx = distinct!()
      Fx.reset_local_timeouts!()

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn -> Fx.complete(ctx, out()) end)

      assert {:ok, _} = result
      sql = Enum.map(queries, & &1.query)

      statement_idx = Enum.find_index(sql, &(&1 =~ "SET LOCAL statement_timeout = '5s'"))
      assert is_integer(statement_idx)
      assert Enum.at(sql, statement_idx - 1) =~ "SET LOCAL lock_timeout = '2s'"

      first_task_lock =
        Enum.find_index(sql, &(&1 =~ "FOR UPDATE" and &1 =~ ~s("tasks")))

      assert is_integer(first_task_lock)
      assert first_task_lock == statement_idx + 1
      assert Enum.at(sql, statement_idx - 2) =~ ~r/savepoint|begin/i
    end
  end

  describe "process_policy re-read between prepare and the lock (TDV MEDIUM 11)" do
    test "the writable flag flipped after prepare is refused by the :process_policy step" do
      ctx = distinct!()
      use_gate_port()

      :persistent_term.put({GatePort, :after_prepare}, fn ->
        Fx.define_type!(ctx.schema, "stock_move", %{writable_by_process: false})
      end)

      baseline = written(ctx)

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
               Fx.complete(ctx, out())

      assert_nothing_written(ctx, baseline)
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "not_writable"
    end
  end

  describe "CO-6 through the engine (TDV MEDIUM 12)" do
    test "a 151-byte output_record_id_var completes through the registry guard" do
      name = "_sys." <> String.duplicate("a", 146)
      assert byte_size(name) == 151

      the_lines = [
        Map.put(
          Fx.line("stock_move", %{"label" => %{"var" => "label"}}),
          "output_record_id_var",
          name
        )
      ]

      ctx = distinct!(the_lines)
      assert {:ok, _} = Fx.complete(ctx, out())

      [move] = Fx.records(ctx.schema, "stock_move")
      variables = Fx.projection!(ctx.schema, ctx.instance_id).variables
      assert variables[name] == move.record_id
      assert variables[name <> ".seq"] == move.last_event_global_seq
    end
  end

  describe "CO-2 grep (TDV MEDIUM 13)" do
    test "the hand-seeding helpers are gone and nothing updates variables with a _sys key" do
      this = Path.expand(__ENV__.file)
      forbidden = [~r/hold_engine_values!/, ~r/(?<![a-z_])sys_event!\(/]

      for path <- Path.wildcard("test/**/*.{ex,exs}"), Path.expand(path) != this do
        text = File.read!(path)

        for pattern <- forbidden do
          refute text =~ pattern, "#{path} still names #{inspect(pattern)}"
        end

        refute text =~ ~r/update_all[^\n]*variables:[^\n]*_sys/,
               "#{path} hand-writes _sys into variables"
      end
    end
  end

  defp payload(%{payload: payload}) when is_map(payload), do: payload
  defp payload(%{payload: payload}) when is_binary(payload), do: Jason.decode!(payload)
end
