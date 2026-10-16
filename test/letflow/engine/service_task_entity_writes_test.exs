defmodule Letflow.Engine.ServiceTaskEntityWritesTest do
  @moduledoc """
  GH #2587 / REQ-499 PR C2 (design `gh2587-req499-pr-c-service-task-writes.md`, tests C-2, C-3,
  C-4, C-6, C-8, C-9, C-10, C-11, C-12, C-13, C-15): an HTTP SERVICE_TASK apply composes the
  node's declared entity writes into the ONE apply transaction.

  Real Postgres through the real `Engine.advance_after_service_task_outcome/4`. The activation
  fence (C1) now accepts `entity_writes` on a SERVICE_TASK node; most cases still start from an
  ACTIVE row inserted with the recorded activator and no activation validation
  (`Fx.service_case!/2`, so they can tamper with the row), and the "C1" case runs the real path.
  `async: false`: the port test double is application env.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Letflow.Api.Response
  alias Letflow.Audit
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Entities.StepWrites
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Support.ChaosEntityPort

  setup do
    on_exit(&ChaosEntityPort.disarm!/0)
    :ok
  end

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

  defp case!(lines \\ two_lines()),
    do: Fx.service_case!("gh2587c-svc", Fx.service_graph(lines))

  defp event_types(ctx), do: Fx.instance_event_types(ctx.schema, ctx.instance_id)

  defp payload(%{payload: payload}) when is_map(payload), do: payload
  defp payload(%{payload: payload}) when is_binary(payload), do: Jason.decode!(payload)

  defp assert_nothing_written(ctx) do
    assert Fx.all_records(ctx.schema) == []
    assert Fx.step_idempotency_count(ctx.schema) == 0
    assert Fx.audit_rows(ctx.schema, "entity_write.process_step") == []
    refute "SERVICE_TASK_COMPLETED" in event_types(ctx)
    assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == "advanced"
  end

  describe "C-2: success composes everything in one transaction" do
    test "records, instance events, audit, projection and the completed event commit together" do
      ctx = case!()

      assert {:ok, :advanced} =
               Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1", "extra" => "x"})

      assert [move] = Fx.records(ctx.schema, "stock_move")
      assert [note] = Fx.records(ctx.schema, "stock_note")
      assert move.field_values["label"] == "L1"
      assert note.field_values == %{"label" => "fixed", "note" => "N1"}

      projection = Fx.projection!(ctx.schema, ctx.instance_id)
      assert projection.status == :completed
      assert projection.variables["_sys.move"] == move.record_id
      assert projection.variables["_sys.move.seq"] == move.last_event_global_seq
      # a body key no line names is merged but never written
      assert projection.variables["extra"] == "x"

      # the engine-only values and the events, in replay order: SYS < APPLIED < COMPLETED
      assert [sys] = Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_SYS_VARIABLES_SET")

      assert [applied] =
               Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")

      assert [completed] =
               Fx.instance_events(ctx.schema, ctx.instance_id, "SERVICE_TASK_COMPLETED")

      assert sys.sequence_number < applied.sequence_number
      assert applied.sequence_number < completed.sequence_number

      sentinel = EventStore.platform_actor_id()
      assert Enum.all?([sys, applied, completed], &(&1.actor_id == sentinel))

      applied_payload = payload(applied)
      assert applied_payload["dispatch_id"] == ctx.dispatch.id
      assert applied_payload["task_id"] == nil
      assert applied_payload["node_id"] == "svc"
      assert length(applied_payload["lines"]) == 2

      assert applied_payload["lines_hash"] == StepWrites.lines_hash(two_lines())

      # C-12: the entity events carry the sentinel actor, the dispatch origin and the activator
      events = Fx.entity_events(ctx.schema)
      assert length(events) == 2
      assert Enum.all?(events, &(&1.actor_id == sentinel))

      for {event, index} <- Enum.with_index(events) do
        assert event.idempotency_key == "sys:step:#{ctx.dispatch.id}:#{index}"
        assert event.metadata["source.dispatch_id"] == ctx.dispatch.id
        assert event.metadata["source.activator_id"] == ctx.user.id
        assert event.metadata["source.node_id"] == "svc"
        refute Map.has_key?(event.metadata, "source.task_id")
      end

      # one audit row per line, actor = sentinel, the activator recorded, no field value
      audits = Fx.audit_rows(ctx.schema, "entity_write.process_step")
      assert length(audits) == 2

      for audit <- audits do
        assert audit.actor_id == sentinel
        assert audit.after_state["activator_id"] == ctx.user.id
        assert audit.after_state["dispatch_id"] == ctx.dispatch.id
        refute Map.has_key?(audit.after_state, "field_values")
      end

      assert {:ok, :valid} = Audit.verify_chain(ctx.schema)

      # the dispatch row is untouched by the apply ("advanced" was written before it)
      assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == "advanced"
    end

    test "a node without lines applies exactly as before: no entity step, no entity event" do
      ctx = case!([])

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1"})

      assert Fx.all_records(ctx.schema) == []
      refute "TASK_ENTITY_WRITES_APPLIED" in event_types(ctx)
      refute "INSTANCE_SYS_VARIABLES_SET" in event_types(ctx)
      assert "SERVICE_TASK_COMPLETED" in event_types(ctx)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :completed
    end

    test "C-11: the rebuilt state equals the live state, including the engine-only values" do
      ctx = case!()
      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      live = Fx.projection!(ctx.schema, ctx.instance_id)

      assert {:ok, %{instance_state: state}} =
               Reconstruction.reconstruct_instance(ctx.instance_id, prefix: ctx.schema)

      assert state.variables == live.variables
      assert state.status == live.status
      assert Map.has_key?(state.variables, "_sys.move")
    end

    # GH #2587 PR C1 (fence-open condition 1, design C-11 last clause): a stored pre-#2621 "wide"
    # INSTANCE_SYS_VARIABLES_SET (values that are not UUID / int64, which the strict append guard
    # now refuses) sitting BEFORE a service completed event still replays byte-identically.
    test "C-11: a wide-tier stored SYS event before a service completed event replays unchanged" do
      ctx = case!()
      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      # The apply wrote its own SYS event before SERVICE_TASK_COMPLETED. Rewrite that stored
      # event's values to the pre-#2621 "wide" tier (strings and ints the strict append guard now
      # refuses) the way an old row would look; the sequence numbers and the rest of the stream
      # are untouched.
      types = event_types(ctx)
      sys_index = Enum.find_index(types, &(&1 == "INSTANCE_SYS_VARIABLES_SET"))
      assert sys_index < Enum.find_index(types, &(&1 == "SERVICE_TASK_COMPLETED"))

      [sys_event] = Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_SYS_VARIABLES_SET")
      original = payload(sys_event)

      wide = %{"_sys.legacy.id" => "any string, not a uuid", "_sys.legacy.seq" => 3}
      wide_payload = Map.put(original, "values", wide)

      assert {1, _} =
               Repo.update_all(
                 from(e in Letflow.EventStore.Event, where: e.event_id == ^sys_event.event_id),
                 [set: [payload: wide_payload]],
                 prefix: ctx.schema
               )

      live = Fx.projection!(ctx.schema, ctx.instance_id)
      stored_before = Fx.all_instance_event_count(ctx.schema, ctx.instance_id)

      assert {:ok, %{instance_state: state}} =
               Reconstruction.reconstruct_instance(ctx.instance_id, prefix: ctx.schema)

      # the wide values arrive byte-identically; every other variable equals the live projection
      assert state.variables["_sys.legacy.id"] == "any string, not a uuid"
      assert state.variables["_sys.legacy.seq"] == 3

      assert Map.drop(state.variables, Map.keys(wide)) ==
               Map.drop(live.variables, Map.keys(original["values"]))

      assert state.status == live.status

      # a second rebuild is identical; replay appended, repaired and rewrote nothing
      assert {:ok, %{instance_state: again}} =
               Reconstruction.reconstruct_instance(ctx.instance_id, prefix: ctx.schema)

      assert again.variables == state.variables
      assert Fx.all_instance_event_count(ctx.schema, ctx.instance_id) == stored_before

      [after_replay] =
        Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_SYS_VARIABLES_SET")

      assert payload(after_replay) == wide_payload
    end
  end

  describe "C1: a definition activated through the real activation path runs end to end" do
    test "activate (fence lifted) -> start -> apply writes the records with the recorded authority" do
      base = Fx.tenant_case!("gh2587c1-e2e")
      Fx.define_type!(base.schema, "stock_move", %{})
      Fx.define_type!(base.schema, "stock_note", %{})

      definition = Fx.activate!(base.schema, base.user, Fx.service_graph(two_lines()))

      user_id = base.user.id

      assert %{
               "user_id" => ^user_id,
               "authorized" => [
                 %{"entity_type" => "stock_move", "op" => "create"},
                 %{"entity_type" => "stock_note", "op" => "create"}
               ]
             } = definition.activated_by

      pending = Fx.start_service_instance!(base, definition)

      dispatch =
        pending.dispatch
        |> Ecto.Changeset.change(%{status: "advanced"})
        |> Repo.update!(prefix: base.schema)

      ctx = %{pending | dispatch: dispatch}

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      assert [_] = Fx.records(ctx.schema, "stock_move")
      assert [_] = Fx.records(ctx.schema, "stock_note")
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :completed
    end
  end

  describe "C-2 / C-8: a refusal rolls everything back and lands the instance in ERROR" do
    # line 1 lacks the type's required `label`
    defp refusing_lines do
      [
        Fx.line("stock_move", %{"label" => %{"var" => "label"}}),
        Fx.line("stock_note", %{"note" => %{"var" => "note"}})
      ]
    end

    test "zero records, ERROR + one value-free DLQ entry, the dispatch row still advanced" do
      ctx = case!(refusing_lines())

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      assert_nothing_written(ctx)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error

      assert [entry] = Fx.dlq_entries(ctx.schema)

      assert entry.error_detail == %{
               "line_index" => 1,
               "code" => "validation_failed",
               "dispatch_id" => ctx.dispatch.id
             }

      assert [error_event] = Fx.instance_events(ctx.schema, ctx.instance_id, "EXECUTION_ERROR")
      error_payload = payload(error_event)
      assert error_payload["error_type"] == "entity_write_refused"
      assert error_payload["affected"] == %{"kind" => "node", "node_id" => "svc"}
      # the PRE-merge variables: the response body is never copied into an error event
      refute Map.has_key?(error_payload["variables"], "label")
      refute Map.has_key?(error_payload["variables"], "note")
      refute inspect(entry) =~ "L1"

      # the best-effort refusal audit entry exists AFTER the rollback: ids and atoms only
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.actor_id == EventStore.platform_actor_id()
      assert refused.after_state["code"] == "validation_failed"
      assert refused.after_state["line_index"] == 1
      assert refused.after_state["dispatch_id"] == ctx.dispatch.id
      refute inspect(refused.after_state) =~ "L1"

      # a second apply of the same dispatch is a duplicate, never a second incident
      assert {:ok, :already_final} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})
      assert length(Fx.dlq_entries(ctx.schema)) == 1
    end

    test "a hop-chain failure writes no record (no matching edge keeps today's landing)" do
      graph = Fx.service_graph(two_lines())

      gateway_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          hd(Enum.filter(graph["nodes"], &(&1["id"] == "svc"))),
          %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "svc"},
          %{"id" => "e2", "source" => "svc", "target" => "gw"},
          %{
            "id" => "e3",
            "source" => "gw",
            "target" => "end",
            "condition" => "variables.never == true"
          }
        ]
      }

      ctx = Fx.service_case!("gh2587c-svc-gw", gateway_graph)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      assert_nothing_written(ctx)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
      refute "SERVICE_TASK_COMPLETED" in event_types(ctx)
      refute "TASK_ENTITY_WRITES_APPLIED" in event_types(ctx)
    end

    test "the S4 guard: lines but no plan lands ERROR entity_write_failed and writes nothing" do
      ctx = case!()

      assert {:ok, :error_set} =
               Engine.__http_apply_with_unreadable_plan__(
                 ctx.dispatch.id,
                 %{"label" => "L1", "note" => "N1"},
                 ctx.schema
               )

      assert_nothing_written(ctx)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "entity_write_failed"
    end

    test "the same unreadable-plan condition for a node WITHOUT lines applies exactly as today" do
      ctx = case!([])

      assert {:ok, :advanced} =
               Engine.__http_apply_with_unreadable_plan__(ctx.dispatch.id, %{}, ctx.schema)

      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :completed
    end

    test "a type that stopped being append-only after activation is refused as write_not_permitted" do
      ctx = case!()
      Fx.define_type!(ctx.schema, "stock_move", %{append_only: false})

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "write_not_permitted"
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "not_append_only"
      assert_nothing_written(ctx)
    end

    test "C-6: a scoped type is refused in :process_policy like on the human path" do
      ctx = case!([Fx.line("stock_move", %{"label" => %{"var" => "label"}})])

      Repo.query!(~s(ALTER TABLE "#{ctx.schema}".entity_definitions DISABLE TRIGGER USER))

      Repo.query!(
        ~s(UPDATE "#{ctx.schema}".entity_definitions SET definition_json = definition_json || '{"scoped": true}'::jsonb WHERE name = 'stock_move')
      )

      previous = Application.get_env(:letflow, :entity_writes_scope_keys)
      Application.put_env(:letflow, :entity_writes_scope_keys, ["scoped"])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:letflow, :entity_writes_scope_keys, previous),
          else: Application.delete_env(:letflow, :entity_writes_scope_keys)
      end)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1"})

      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "write_not_permitted"
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "scoped"
      assert_nothing_written(ctx)
    end

    test "a `module_writes` attribute on a SERVICE node is refused fail-closed" do
      graph = Fx.service_graph(two_lines(), %{"module_writes" => [%{"module" => "m"}]})
      ctx = Fx.service_case!("gh2587c-svc-mw", graph)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "write_not_permitted"
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "module_writes"
      assert_nothing_written(ctx)
    end

    test "more than 20 lines are refused at run time on the pinned snapshot" do
      lines =
        for _ <- 1..21, do: Fx.line("stock_note", %{"label" => %{"const" => "x"}})

      ctx = case!(lines)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{})

      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "validation_failed"
      assert_nothing_written(ctx)
    end
  end

  describe "C-9: the recorded activator authority is untrusted data at run time" do
    defp set_activated_by!(ctx, activated_by) do
      {1, _} =
        from(d in ProcessDefinition, where: d.id == ^ctx.definition.id)
        |> Repo.update_all([set: [activated_by: activated_by]], prefix: ctx.schema)

      :ok
    end

    defp activated_by(user_id, permissions) do
      %{
        "user_id" => user_id,
        "roles" => ["TENANT_ADMIN"],
        "permissions" => permissions,
        "authorized" => [
          %{"entity_type" => "stock_move", "op" => "create"},
          %{"entity_type" => "stock_note", "op" => "create"}
        ],
        "activated_at" => DateTime.to_iso8601(DateTime.utc_now())
      }
    end

    defp assert_needs_reactivation(ctx) do
      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "entity_write_needs_reactivation"
      assert_nothing_written(ctx)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
    end

    test "no recorded activator (NULL)" do
      ctx = case!()
      set_activated_by!(ctx, nil)
      assert_needs_reactivation(ctx)
    end

    test "the EntitiesRecordsWrite permission is not recorded" do
      ctx = case!()
      set_activated_by!(ctx, activated_by(ctx.user.id, ["DefinitionsActivate"]))
      assert_needs_reactivation(ctx)
    end

    test "a non-UUID user id" do
      ctx = case!()
      set_activated_by!(ctx, activated_by("not-a-uuid", ["EntitiesRecordsWrite"]))
      assert_needs_reactivation(ctx)
    end

    test "a deactivated activator" do
      ctx = case!()

      {1, _} =
        from(u in User, where: u.id == ^ctx.user.id)
        |> Repo.update_all([set: [status: :inactive]], prefix: ctx.schema)

      assert_needs_reactivation(ctx)
    end

    test "a pair absent from the recorded authorization (hand-edited) is write_not_permitted" do
      ctx = case!()

      set_activated_by!(
        ctx,
        Map.put(activated_by(ctx.user.id, ["EntitiesRecordsWrite"]), "authorized", [
          %{"entity_type" => "stock_note", "op" => "create"}
        ])
      )

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "write_not_permitted"
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "not_authorized"
    end

    test "the field restriction subject is the ACTIVATOR; a grant for the activator allows it" do
      ctx = case!([Fx.line("stock_move", %{"label" => %{"var" => "label"}})])

      Repo.insert_all(
        "entity_field_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: "stock_move",
            field_name: "label",
            inserted_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )

      # a grant for somebody else matters not: there is no completer
      Repo.insert_all(
        "user_entity_grants",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            user_id: Ecto.UUID.dump!(Fx.user!(ctx.schema, "someone-else").id),
            entity_type: "stock_move",
            field_name: "label",
            inserted_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1"})
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "field_restricted"
      assert_nothing_written(ctx)
    end

    test "with a grant for the ACTIVATOR the same apply commits" do
      ctx = case!([Fx.line("stock_move", %{"label" => %{"var" => "label"}})])

      Repo.insert_all(
        "entity_field_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: "stock_move",
            field_name: "label",
            inserted_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )

      Repo.insert_all(
        "user_entity_grants",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            user_id: Ecto.UUID.dump!(ctx.user.id),
            entity_type: "stock_move",
            field_name: "label",
            inserted_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1"})
      assert [_record] = Fx.records(ctx.schema, "stock_move")
    end
  end

  describe "C-10: values" do
    test "a wrongly typed or missing value is the type's own validation_failed" do
      ctx = case!([Fx.line("stock_move", %{"label" => %{"var" => "label"}})])

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => 12})
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "validation_failed"
      assert_nothing_written(ctx)
    end

    test "a 70 KiB value is refused with validation_failed and no field name" do
      ctx = case!([Fx.line("stock_move", %{"label" => %{"var" => "label"}})])

      log =
        capture_log(fn ->
          assert {:ok, :error_set} =
                   Fx.apply_http(ctx, %{"label" => String.duplicate("x", 70_000)})
        end)

      # I-C9: no value and no field name in the log either
      refute log =~ "xxxxxxxxxx"
      refute log =~ "label"

      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "validation_failed"
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "value_too_large"
      refute inspect(entry) =~ "label"
      assert_nothing_written(ctx)
    end

    test "values just under the per-value cap commit" do
      ctx = case!([Fx.line("stock_move", %{"label" => %{"var" => "label"}})])

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => String.duplicate("x", 60_000)})
      assert [_record] = Fx.records(ctx.schema, "stock_move")
    end

    test "a line over the 256 KiB aggregate cap is refused even when every value is under 64 KiB" do
      ctx = wide_case!()

      body = Map.new(1..5, fn n -> {"f#{n}", String.duplicate("x", 60_000)} end)
      assert {:ok, :error_set} = Fx.apply_http(ctx, body)

      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "validation_failed"
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "value_too_large"
      assert_nothing_written(ctx)
    end

    test "control: four 60 KB values (a 240 KB line, under the 256 KiB cap) commit" do
      ctx = wide_case!()

      body =
        Map.new(1..4, fn n -> {"f" <> Integer.to_string(n), String.duplicate("x", 60_000)} end)

      assert {:ok, :advanced} = Fx.apply_http(ctx, body)
      assert [_record] = Fx.records(ctx.schema, "wide_rec")
    end

    test "the two size caps are pinned named constants (a change is a reviewed diff)" do
      assert StepWrites.service_size_caps() == %{value_max_bytes: 65_536, line_max_bytes: 262_144}
    end

    test "a `var` naming the reserved namespace is omitted: the required field is then missing" do
      ctx = case!([Fx.line("stock_move", %{"label" => %{"var" => "_sys.move"}})])

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1"})
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "validation_failed"
      assert_nothing_written(ctx)
    end

    defp wide_case!() do
      base = Fx.tenant_case!("gh2587c-wide")

      fields =
        for n <- 1..5, do: %{name: "f#{n}", type: :string}

      Fx.define_type!(base.schema, "wide_rec", %{fields: fields})

      line =
        Fx.line("wide_rec", Map.new(1..5, fn n -> {"f#{n}", %{"var" => "f#{n}"}} end))

      definition =
        Fx.legacy_activate!(base.schema, base.user, Fx.service_graph([line]), [
          {"wide_rec", "create"}
        ])

      {:ok, created} =
        Engine.create(
          %{
            definition_id: definition.id,
            initial_variables: %{},
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Fx.unique("wide-start")
          },
          prefix: base.schema
        )

      [row] =
        Repo.all(
          from(d in Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch,
            where: d.instance_id == ^created.instance_id
          ),
          prefix: base.schema
        )

      dispatch =
        row |> Ecto.Changeset.change(%{status: "advanced"}) |> Repo.update!(prefix: base.schema)

      Map.merge(base, %{
        definition: definition,
        instance_id: created.instance_id,
        dispatch: dispatch
      })
    end
  end

  describe "C-4: duplicate apply and the completion key" do
    test "a second apply answers already_final in every state, writes nothing, raises no incident" do
      # token moved on (waiting at the human task), instance active
      active = Fx.service_case!("gh2587c-dup1", Fx.service_then_human_graph(two_lines()))
      body = %{"label" => "L1", "note" => "N1"}
      assert {:ok, :advanced} = Fx.apply_http(active, body)
      assert Fx.projection!(active.schema, active.instance_id).status == :active
      records = length(Fx.all_records(active.schema))
      # the duplicate apply raises no error log line (scoped to this call)
      log = capture_log(fn -> assert {:ok, :already_final} = Fx.apply_http(active, body) end)
      refute log =~ "[error]"
      refute log =~ "[warning]"
      assert length(Fx.all_records(active.schema)) == records
      assert Fx.dlq_entries(active.schema) == []

      # instance COMPLETED by the first apply
      done = case!()
      assert {:ok, :advanced} = Fx.apply_http(done, body)
      assert Fx.projection!(done.schema, done.instance_id).status == :completed
      assert {:ok, :already_final} = Fx.apply_http(done, body)
      assert length(Fx.all_records(done.schema)) == 2
      assert Fx.dlq_entries(done.schema) == []

      # instance CANCELLED after the apply
      cancelled = Fx.service_case!("gh2587c-dup3", Fx.service_then_human_graph(two_lines()))
      assert {:ok, :advanced} = Fx.apply_http(cancelled, body)

      assert {:ok, _} =
               Engine.cancel_instance(
                 cancelled.instance_id,
                 %{actor_id: Ecto.UUID.generate(), idempotency_key: Fx.unique("cancel")},
                 prefix: cancelled.schema
               )

      assert {:ok, :already_final} = Fx.apply_http(cancelled, body)
      assert Fx.audit_rows(cancelled.schema, "service_task.advance_failed") == []
    end

    test "ambiguous commit: the re-apply after a committed first apply (activator deactivated meanwhile) answers already_final" do
      ctx = Fx.service_case!("gh2587c-dup4", Fx.service_then_human_graph(two_lines()))
      body = %{"label" => "L1", "note" => "N1"}
      assert {:ok, :advanced} = Fx.apply_http(ctx, body)

      {1, _} =
        from(u in User, where: u.id == ^ctx.user.id)
        |> Repo.update_all([set: [status: :inactive]], prefix: ctx.schema)

      assert {:ok, :already_final} = Fx.apply_http(ctx, body)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
      assert Fx.dlq_entries(ctx.schema) == []
    end

    test "the landing driven against an EXISTING completion key leaves the instance untouched" do
      ctx = Fx.service_case!("gh2587c-land", Fx.service_then_human_graph(two_lines()))
      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      before = Fx.projection!(ctx.schema, ctx.instance_id)
      events_before = length(event_types(ctx))

      assert {:ok, :already_final} =
               Engine.__land_http_entity_write_failure__(
                 ctx.dispatch.id,
                 :validation_failed,
                 0,
                 ctx.schema
               )

      after_landing = Fx.projection!(ctx.schema, ctx.instance_id)
      assert after_landing.status == :active
      assert after_landing.variables == before.variables
      assert length(event_types(ctx)) == events_before
      refute "EXECUTION_ERROR" in event_types(ctx)
      assert Fx.dlq_entries(ctx.schema) == []
    end

    test "the landing of a still-open dispatch lands ERROR once; a second landing is already_final" do
      ctx = case!()

      assert {:ok, :error_set} =
               Engine.__land_http_entity_write_failure__(
                 ctx.dispatch.id,
                 :entity_write_failed,
                 3,
                 ctx.schema
               )

      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["line_index"] == 3

      assert {:ok, :already_final} =
               Engine.__land_http_entity_write_failure__(
                 ctx.dispatch.id,
                 :entity_write_failed,
                 3,
                 ctx.schema
               )

      assert length(Fx.dlq_entries(ctx.schema)) == 1
    end

    test "a pre-existing sys:step: key is treated as a prior commit (already_final), never ERROR" do
      ctx = case!()

      started = hd(Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_STARTED"))

      Repo.insert_all(
        "event_idempotency",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            idempotency_key: "sys:step:#{ctx.dispatch.id}:0",
            event_id: Ecto.UUID.dump!(started.event_id),
            event_created_at: started.created_at,
            inserted_at: DateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )

      assert {:ok, :already_final} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})
      assert Fx.dlq_entries(ctx.schema) == []
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
      assert Fx.all_records(ctx.schema) == []
    end

    test "a cancelled instance (no completion key) answers today's instance_not_active" do
      ctx = Fx.service_case!("gh2587c-dup5", Fx.service_then_human_graph(two_lines()))

      assert {:ok, _} =
               Engine.cancel_instance(
                 ctx.instance_id,
                 %{actor_id: Ecto.UUID.generate(), idempotency_key: Fx.unique("cancel")},
                 prefix: ctx.schema
               )

      assert {:error, {:instance_not_active, :cancelled}} =
               Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      assert_nothing_written(ctx)
    end
  end

  describe "C-3: contention is re-applied by the engine, bounded, then lands as ERROR" do
    test "one contention failure is re-applied and the apply then commits exactly once" do
      ctx = case!()
      counter = ChaosEntityPort.arm!(:lock_not_available, 1)

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      # the first attempt was rolled back entirely; the second committed one record per line
      assert :counters.get(counter, 1) == 2
      assert length(Fx.records(ctx.schema, "stock_move")) == 1
      assert length(Fx.records(ctx.schema, "stock_note")) == 1
      assert Fx.dlq_entries(ctx.schema) == []
      assert Fx.step_idempotency_count(ctx.schema) == 2
    end

    test "exhaustion after three attempts lands ERROR + DLQ with entity_write_contention" do
      ctx = case!()
      counter = ChaosEntityPort.arm!(:lock_not_available, :infinity)

      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      assert :counters.get(counter, 1) == 3
      assert_nothing_written(ctx)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :error
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "entity_write_contention"
      assert Fx.dispatch!(ctx.schema, ctx.dispatch.id).status == "advanced"
    end

    test "a non-contention database error is not retried and is not an entity-write class" do
      ctx = case!()
      counter = ChaosEntityPort.arm!(:unique_violation, :infinity)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      assert :counters.get(counter, 1) == 1
      assert_nothing_written(ctx)
      assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
    end
  end

  describe "C-13: no value, field name or entity type reaches the operator surfaces" do
    test "the existing history shaping covers the service-origin events (no new surface)" do
      ctx = case!()
      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      [applied] = Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")
      [sys] = Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_SYS_VARIABLES_SET")

      shaped = Response.public_event_payload(applied.event_type, payload(applied))

      assert Map.keys(shaped) |> Enum.sort() == [
               "dispatch_id",
               "lines",
               "lines_hash",
               "node_id",
               "task_id"
             ]

      assert shaped["dispatch_id"] == ctx.dispatch.id

      assert Enum.all?(
               shaped["lines"],
               &(Map.keys(&1) |> Enum.sort() == ["entity_type", "line_index"])
             )

      assert Response.public_event_payload(sys.event_type, payload(sys)) == %{}

      projection = Fx.projection!(ctx.schema, ctx.instance_id)
      assert Map.has_key?(projection.variables, "_sys.move")

      refute Enum.any?(
               Map.keys(Response.public_variables(projection.variables)),
               &String.starts_with?(&1, "_sys")
             )
    end

    test "the DLQ entry and the instance read carry only the closed key set" do
      ctx = case!(refusing_lines())
      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "SECRET-L1", "note" => "N1"})

      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert Map.keys(entry.error_detail) |> Enum.sort() == ["code", "dispatch_id", "line_index"]
      refute inspect(entry) =~ "SECRET-L1"
      refute inspect(entry) =~ "stock_note"
      refute inspect(entry) =~ "stock_move"

      projection = Repo.get!(InstanceProjection, ctx.instance_id, prefix: ctx.schema)
      refute inspect(projection.error_detail) =~ "SECRET-L1"
      refute Enum.any?(Map.keys(projection.variables), &String.starts_with?(&1, "_sys."))
    end
  end

  describe "C-3 / T4: every contention class is re-applied; the guard budget reaches the port" do
    test "57014, 40P01 and a lost connection are contention, each re-applied once" do
      for {slug, arm} <- [
            {"c57014", fn -> ChaosEntityPort.arm!(:query_canceled, 1) end},
            {"c40p01", fn -> ChaosEntityPort.arm!(:deadlock_detected, 1) end},
            {"cconn",
             fn ->
               ChaosEntityPort.arm_exception!(
                 %DBConnection.ConnectionError{message: "chaos", severity: :error},
                 1
               )
             end}
          ] do
        ctx = Fx.service_case!("gh2587c-" <> slug, Fx.service_graph(two_lines()))
        counter = arm.()

        assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"}), slug
        assert :counters.get(counter, 1) == 2, slug
        assert length(Fx.all_records(ctx.schema)) == 2, slug
        assert Fx.dlq_entries(ctx.schema) == [], slug
        ChaosEntityPort.disarm!()
      end
    end

    test "the port context carries the dispatch origin, the sentinel actor, the activator subject and a guard budget of at most 10 s" do
      ctx = case!()
      ChaosEntityPort.record!()

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      assert_received {:port_call, :multi, port_ctx}
      assert port_ctx.origin == {:dispatch, ctx.dispatch.id}
      assert port_ctx.actor_id == EventStore.platform_actor_id()
      assert port_ctx.subject_id == ctx.user.id
      assert port_ctx.activator_id == ctx.user.id
      # HTTP: min(10 s, 20 s budget - elapsed - 8 s pre-guard bound) = 10 s at the first attempt
      assert port_ctx.guard_budget_ms == 10_000
    end

    test "I-C10: rebuilding the instance makes no port call" do
      ctx = case!()
      ChaosEntityPort.record!()
      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1", "note" => "N1"})

      # drain the calls of the apply itself, then replay
      for _ <- 1..20 do
        receive do
          {:port_call, _name, _arg} -> :ok
        after
          0 -> :ok
        end
      end

      assert {:ok, %{instance_state: _state}} =
               Reconstruction.reconstruct_instance(ctx.instance_id, prefix: ctx.schema)

      refute_received {:port_call, _name, _arg}
    end
  end
end
