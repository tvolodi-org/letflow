defmodule Letflow.Engine.CompleteTaskEntityWritesTypeAccessTest do
  @moduledoc """
  GH #2808 (task note sections 3.4 and 5, T-E1..T-E3, T-E6): TypeAccess on the engine's entity
  writes. The restriction subject (the completer on the human path, the activator on the service
  path and at activation) is denied a restricted type exactly as a type that is not writable by
  process: same result, same tenant-audit detail, nothing written.

  Real Postgres through `Letflow.Engine.complete_task/3`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.StepWrites
  alias Letflow.EntityWritesFixture, as: Fx

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
end
