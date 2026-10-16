defmodule Letflow.Engine.ModuleWriteActorTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4b (design D-R.13, section 11 row "Actor and scope"): on the HUMAN path
  the COMPLETER is the actor and the subject of the write-side field restrictions; the activator
  is provenance only. A field restricted for the completer refuses the handler's write
  (`write_not_permitted`, audit detail `field_restricted`) even though the activator, who holds
  the grant, could have written it; with the grant the same completion succeeds.

  `async: false`: the module install and tenant provisioning run DDL.
  """

  use Letflow.DataCase, async: false

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  defp restrict!(schema, entity_type, field) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp grant!(schema, user_id, entity_type, field) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          field_name: field,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp case_with_distinct_completer(slug) do
    ctx = Mw.case!(slug, :module)
    completer = Fx.user!(ctx.schema, "completer2")
    Map.merge(ctx, %{activator: ctx.user, user: completer})
  end

  test "a field restricted for the completer refuses the handler write, whatever the activator may" do
    ctx = case_with_distinct_completer("gh2590-r4b-actor-restricted")
    restrict!(ctx.schema, "fxl_ledger", "item")
    # the ACTIVATOR holds the grant; the subject of the check is the completer
    grant!(ctx.schema, ctx.activator.id, "fxl_ledger", "item")

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(ctx, %{"label" => "L1"})

    assert Fx.all_records(ctx.schema) == []
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
    assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
    assert entry.after_state["detail"] == "field_restricted"
    refute inspect(entry.after_state) =~ "item"
  end

  test "with the grant the same completer's completion succeeds, and is the event actor" do
    ctx = case_with_distinct_completer("gh2590-r4b-actor-granted")
    restrict!(ctx.schema, "fxl_ledger", "item")
    grant!(ctx.schema, ctx.user.id, "fxl_ledger", "item")

    assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
    assert [ledger, _balance] = Fx.entity_events(ctx.schema)
    assert ledger.actor_id == ctx.user.id
    assert ledger.metadata["source.activator_id"] == ctx.activator.id
  end
end
