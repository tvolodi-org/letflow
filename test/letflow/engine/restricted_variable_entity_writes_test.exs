defmodule Letflow.Engine.RestrictedVariableEntityWritesTest do
  @moduledoc """
  Decision 0062 R5 (GH #2616 part 3), SR-OPT-9 run-time half: a step's entity write that reads a
  variable carrying restriction labels is refused unless the labels are within the restriction
  set of the target field (the narrow predicate). The labels reach the step only through the
  projection here (a labelled variable set directly; no opted-in script in the graph), which is
  the point of the run-time check: it does not depend on the activation analysis.

  Real Postgres through the real `Letflow.Engine.complete_task/3`. `async: false`: provisioning.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo

  defp case!(lines \\ nil) do
    lines = lines || [Fx.line("stock_move", %{"label" => %{"var" => "label"}})]
    Fx.case!("gh2616-p3-ew", lines)
  end

  # Sets the instance's variable `label` and its labels directly on the projection.
  defp label_variable!(ctx, value, labels) do
    {1, _} =
      from(p in InstanceProjection, where: p.instance_id == ^ctx.instance_id)
      |> Repo.update_all(
        [set: [variables: %{"label" => value}, variable_labels: %{"label" => labels}]],
        prefix: ctx.schema
      )
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

  test "SR-OPT-9(b): a labelled variable into an unrestricted field is refused, nothing written" do
    ctx = case!()
    label_variable!(ctx, "L1", ["customer.salary"])

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(ctx, %{"note" => "N1"})

    assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
    assert entry.after_state["detail"] == "entity_write_restriction_widened"
    assert Fx.all_records(ctx.schema) == []
  end

  test "SR-OPT-9(b): a label that is not the target field is refused even when the target is restricted" do
    ctx = case!()
    insert_restriction!(ctx.schema, "stock_move", "label")
    insert_grant!(ctx.schema, ctx.user.id, "stock_move", "label")
    label_variable!(ctx, "L1", ["customer.salary"])

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(ctx, %{"note" => "N1"})

    assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
    assert entry.after_state["detail"] == "entity_write_restriction_widened"
  end

  test "SR-OPT-9(c): accepted when the target field is the restricted label source" do
    ctx = case!()
    insert_restriction!(ctx.schema, "stock_move", "label")
    insert_grant!(ctx.schema, ctx.user.id, "stock_move", "label")
    label_variable!(ctx, "L1", ["stock_move.label"])

    assert {:ok, _} = Fx.complete(ctx, %{"note" => "N1"})
    assert [_record] = Fx.records(ctx.schema, "stock_move")
  end

  test "SR-OPT-9(c): the source label is not enough when the target is not restricted" do
    ctx = case!()
    label_variable!(ctx, "L1", ["stock_move.label"])

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(ctx, %{"note" => "N1"})

    assert Fx.all_records(ctx.schema) == []
  end

  test "an unlabelled variable is written as before" do
    ctx = case!()
    label_variable!(ctx, "L1", [])
    assert {:ok, _} = Fx.complete(ctx, %{"note" => "N1"})
    assert [_record] = Fx.records(ctx.schema, "stock_move")
  end
end
