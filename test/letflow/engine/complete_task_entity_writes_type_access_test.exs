defmodule Letflow.Engine.CompleteTaskEntityWritesTypeAccessTest do
  @moduledoc """
  GH #2808 (task note sections 3.4 and 5, T-E1..T-E3, T-E6): TypeAccess on the engine's entity
  writes. The restriction subject (the completer on the human path, the activator on the service
  path and at activation) is denied a restricted type exactly as a type that is not writable by
  process: same result, same tenant-audit detail, nothing written.

  Real Postgres through `Letflow.Engine.complete_task/3`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Entities.StepWrites
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  defp lines, do: [Fx.line("stock_move", %{"label" => %{"var" => "label"}})]

  defp restrict_type!(schema, type) do
    Repo.insert_all(
      "entity_type_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: type,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp grant_type!(schema, user_id, type) do
    Repo.insert_all(
      "user_entity_type_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: type,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp restrict_field!(schema, type, field) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: type,
          field_name: field,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  describe "human completion" do
    test "a completer denied the type is refused like a non-writable type; nothing is written" do
      denied = Fx.case!("gh2808-e2a", lines())
      restrict_type!(denied.schema, "stock_move")

      absent = Fx.case!("gh2808-e2b", lines())
      Fx.define_type!(absent.schema, "stock_move", %{writable_by_process: false})

      denied_result = Fx.complete(denied, %{"label" => "L1"})
      absent_result = Fx.complete(absent, %{"label" => "L1"})

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} = denied_result
      assert denied_result == absent_result

      assert [d] = Fx.audit_rows(denied.schema, "entity_write.refused")
      assert [a] = Fx.audit_rows(absent.schema, "entity_write.refused")
      assert d.after_state["detail"] == "not_writable"
      assert d.after_state["detail"] == a.after_state["detail"]
      assert Fx.all_records(denied.schema) == []
      assert Fx.entity_events(denied.schema) == []
    end

    test "the type check comes first: a restricted field does not change the answer (T-E6)" do
      ctx = Fx.case!("gh2808-e6", lines())
      restrict_type!(ctx.schema, "stock_move")
      restrict_field!(ctx.schema, "stock_move", "label")

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
               Fx.complete(ctx, %{"label" => "L1"})

      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "not_writable"
    end

    test "a granted completer writes unchanged; an unrelated restricted type changes nothing (T-E3)" do
      ctx = Fx.case!("gh2808-e3", lines())
      restrict_type!(ctx.schema, "stock_move")
      grant_type!(ctx.schema, ctx.user.id, "stock_move")
      restrict_type!(ctx.schema, "stock_note")

      assert {:ok, _result} = Fx.complete(ctx, %{"label" => "L1"})
      assert [_record] = Fx.all_records(ctx.schema)
    end
  end

  describe "StepWrites.check_type_access/2 and activation validation" do
    test "check_type_access follows the subject, falling back to the actor" do
      base = Fx.tenant_case!("gh2808-e4")
      other = Fx.user!(base.schema, "other")
      restrict_type!(base.schema, "gated")
      grant_type!(base.schema, other.id, "gated")

      ctx = %{prefix: base.schema, actor_id: base.user.id, subject_id: base.user.id}
      assert StepWrites.check_type_access("gated", ctx) == {:error, :type_denied}
      assert StepWrites.check_type_access("free", ctx) == :ok
      assert StepWrites.check_type_access("gated", %{ctx | subject_id: other.id}) == :ok

      assert StepWrites.check_type_access(
               "gated",
               Map.delete(%{ctx | actor_id: other.id}, :subject_id)
             ) == :ok

      assert StepWrites.check_type_access("gated", %{ctx | prefix: "no_such_schema"}) ==
               {:error, :type_denied}
    end

    test "a type denied to the activator validates exactly like an absent type (T-E1)" do
      base = Fx.tenant_case!("gh2808-e1")
      Fx.define_type!(base.schema, "stock_move", %{})
      Fx.define_type!(base.schema, "hidden_t", %{})
      restrict_type!(base.schema, "hidden_t")
      line = fn type -> [Fx.line(type, %{"label" => %{"const" => "x"}})] end
      ctx = %{prefix: base.schema, activator_user_id: base.user.id}

      assert {:error, [%{index: 0, code: :entity_type_not_found}]} =
               StepWrites.validate_lines(line.("never_defined"), ctx)

      assert StepWrites.validate_lines(line.("hidden_t"), ctx) ==
               StepWrites.validate_lines(line.("never_defined"), ctx)

      # without an activator id (pure callers) and for an unrelated type nothing changes
      assert match?(
               {:error, [%{code: code}]} when code != :entity_type_not_found,
               StepWrites.validate_lines(line.("hidden_t"), %{prefix: base.schema})
             ) or StepWrites.validate_lines(line.("hidden_t"), %{prefix: base.schema}) == :ok

      assert StepWrites.validate_lines(line.("stock_move"), ctx) ==
               StepWrites.validate_lines(line.("stock_move"), %{prefix: base.schema})

      grant_type!(base.schema, base.user.id, "hidden_t")

      assert StepWrites.validate_lines(line.("hidden_t"), ctx) ==
               StepWrites.validate_lines(line.("hidden_t"), %{prefix: base.schema})
    end
  end

  describe "SERVICE_TASK path (the activator is the subject, T-E4)" do
    defp service_case(slug), do: Fx.service_case!(slug, Fx.service_graph(lines()))

    defp assert_service_refused(ctx) do
      assert {:ok, :error_set} = Fx.apply_http(ctx, %{"label" => "L1"})
      assert [entry] = Fx.dlq_entries(ctx.schema)
      assert entry.error_detail["code"] == "write_not_permitted"
      assert entry.error_detail["line_index"] == 0
      assert [refused] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert Fx.all_records(ctx.schema) == []
      assert Fx.entity_events(ctx.schema) == []
      assert Fx.step_idempotency_count(ctx.schema) == 0
      {entry.error_detail, refused.after_state["detail"]}
    end

    test "an ungranted activator is refused like a non-writable type; nothing is written" do
      denied = service_case("gh2808-e4a")
      restrict_type!(denied.schema, "stock_move")
      # somebody else's grant does not help: the subject is the activator
      grant_type!(denied.schema, Fx.user!(denied.schema, "someone-else").id, "stock_move")

      base = Fx.tenant_case!("gh2808-e4b")
      Fx.define_type!(base.schema, "stock_move", %{writable_by_process: false})
      Fx.define_type!(base.schema, "stock_note", %{})
      absent = Fx.attach_service!(base, Fx.service_graph(lines()))

      {denied_dlq, denied_detail} = assert_service_refused(denied)
      {absent_dlq, absent_detail} = assert_service_refused(absent)

      assert denied_detail == "not_writable"
      assert denied_detail == absent_detail
      assert Map.delete(denied_dlq, "dispatch_id") == Map.delete(absent_dlq, "dispatch_id")
    end

    test "a granted activator writes unchanged, with the platform sentinel as event actor" do
      ctx = service_case("gh2808-e4c")
      restrict_type!(ctx.schema, "stock_move")
      grant_type!(ctx.schema, ctx.user.id, "stock_move")

      assert {:ok, :advanced} = Fx.apply_http(ctx, %{"label" => "L1"})
      assert [_record] = Fx.all_records(ctx.schema)
      assert [event] = Fx.entity_events(ctx.schema)
      assert event.actor_id == Letflow.EventStore.platform_actor_id()
    end
  end

  describe "module handler writes (HandlerWrites.create/3, T-E5)" do
    defp restrict_ledger!(ctx), do: restrict_type!(ctx.schema, "fxl_ledger")

    test "a completer denied the handler's type is refused; nothing is written" do
      ctx = Mw.case!("gh2808-e5a", :module)
      restrict_ledger!(ctx)

      assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
               Fx.complete(ctx, %{"label" => "L1"})

      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "not_writable"
      assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
      assert Fx.all_records(ctx.schema) == []
      assert Fx.entity_events(ctx.schema) == []
    end

    test "a granted completer writes the handler's records unchanged" do
      ctx = Mw.case!("gh2808-e5b", :module)
      restrict_ledger!(ctx)
      grant_type!(ctx.schema, ctx.user.id, "fxl_ledger")

      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
      assert [_ledger, _balance] = Fx.entity_events(ctx.schema)
    end

    test "on the SERVICE path an ungranted activator is refused (ERROR + DLQ), a granted one writes" do
      denied = Mw.service_case!("gh2808-e5c", :svc_module)
      restrict_ledger!(denied)

      assert {:ok, :error_set} = Fx.apply_http(denied, %{"label" => "L1"})
      assert [entry] = Fx.dlq_entries(denied.schema)
      assert entry.error_detail["code"] == "write_not_permitted"
      assert [refused] = Fx.audit_rows(denied.schema, "entity_write.refused")
      assert refused.after_state["detail"] == "not_writable"
      assert Fx.all_records(denied.schema) == []
      assert Fx.entity_events(denied.schema) == []

      granted = Mw.service_case!("gh2808-e5d", :svc_module)
      restrict_ledger!(granted)
      grant_type!(granted.schema, granted.user.id, "fxl_ledger")

      assert {:ok, :advanced} = Fx.apply_http(granted, %{"label" => "L1"})
      assert [_] = Fx.records(granted.schema, "fxl_ledger")
    end
  end

  describe "activation through Definitions.activate/2 (T-E1, end to end)" do
    defp activation_result(base, type) do
      {:ok, definition} =
        Definitions.create(
          %{
            name: Fx.unique("gh2808-act"),
            version: "1.0.0",
            graph: Fx.graph([Fx.line(type, %{"label" => %{"const" => "x"}})]),
            created_by: base.user.id
          },
          prefix: base.schema
        )

      activator =
        Activator.from_auth_context(%{user_id: base.user.id, roles: ["TENANT_ADMIN"]}, false)

      Definitions.activate(definition.id, prefix: base.schema, activator: activator)
    end

    test "a type denied to the activator is reported exactly like an absent type" do
      base = Fx.tenant_case!("gh2808-e1e2e")
      Fx.define_type!(base.schema, "stock_move", %{})
      Fx.define_type!(base.schema, "hidden_t", %{})
      restrict_type!(base.schema, "hidden_t")

      assert {:error,
              {:entity_writes_invalid, [%{index: 0, code: :entity_type_not_found} = absent]}} =
               activation_result(base, "never_defined")

      assert {:error, {:entity_writes_invalid, [denied]}} = activation_result(base, "hidden_t")
      assert denied == absent

      # an unrelated type is unchanged, and so is a granted activator
      assert {:ok, _} = activation_result(base, "stock_move")
      grant_type!(base.schema, base.user.id, "hidden_t")
      assert {:ok, _} = activation_result(base, "hidden_t")
    end
  end
end
