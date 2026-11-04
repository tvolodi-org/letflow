defmodule Letflow.Engine.CompleteTaskEntityWritesWritePermissionTest do
  @moduledoc """
  REQ-577 / GH #3261 (W8): the write restriction on the engine's entity writes. The subject (the
  completer on the human path, the activator on the service path) without a write grant is
  refused like a type that is not writable by process; a granted subject writes unchanged.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.StepWrites
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  defp lines, do: [Fx.line("stock_move", %{"label" => %{"var" => "label"}})]

  defp write_restrict!(schema, type) do
    Repo.insert_all(
      "entity_type_write_restrictions",
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

  defp write_grant!(schema, user_id, type) do
    Repo.insert_all(
      "user_entity_type_write_grants",
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

  test "W8a human path: a completer without a write grant is refused; with one it writes" do
    denied = Fx.case!("req577-e1", lines())
    write_restrict!(denied.schema, "stock_move")

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(denied, %{"label" => "L1"})

    assert [entry] = Fx.audit_rows(denied.schema, "entity_write.refused")
    assert entry.after_state["detail"] == "not_writable"
    assert Fx.all_records(denied.schema) == []
    assert Fx.entity_events(denied.schema) == []

    granted = Fx.case!("req577-e2", lines())
    write_restrict!(granted.schema, "stock_move")
    write_grant!(granted.schema, granted.user.id, "stock_move")
    assert {:ok, _} = Fx.complete(granted, %{"label" => "L1"})
    assert [_record] = Fx.all_records(granted.schema)
  end

  test "W8b service path: the activator is the subject" do
    denied = Fx.service_case!("req577-e3", Fx.service_graph(lines()))
    write_restrict!(denied.schema, "stock_move")
    assert {:ok, :error_set} = Fx.apply_http(denied, %{"label" => "L1"})
    assert [entry] = Fx.dlq_entries(denied.schema)
    assert entry.error_detail["code"] == "write_not_permitted"
    assert Fx.all_records(denied.schema) == []

    granted = Fx.service_case!("req577-e4", Fx.service_graph(lines()))
    write_restrict!(granted.schema, "stock_move")
    write_grant!(granted.schema, granted.user.id, "stock_move")
    assert {:ok, :advanced} = Fx.apply_http(granted, %{"label" => "L1"})
    assert [_record] = Fx.all_records(granted.schema)
  end

  test "W8c handler write: refused without a grant, written with one" do
    denied = Mw.case!("req577-e5", :module)
    write_restrict!(denied.schema, "fxl_ledger")

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(denied, %{"label" => "L1"})

    assert Fx.entity_events(denied.schema) == []

    granted = Mw.case!("req577-e6", :module)
    write_restrict!(granted.schema, "fxl_ledger")
    write_grant!(granted.schema, granted.user.id, "fxl_ledger")
    assert {:ok, _} = Fx.complete(granted, %{"label" => "L1"})
    assert [_ledger, _balance] = Fx.entity_events(granted.schema)
  end

  test "check_type_access/2 follows the subject and fails closed on a bad schema" do
    base = Fx.tenant_case!("req577-e7")
    other = Fx.user!(base.schema, "other")
    write_restrict!(base.schema, "gated")
    write_grant!(base.schema, other.id, "gated")

    ctx = %{prefix: base.schema, actor_id: base.user.id, subject_id: base.user.id}
    assert StepWrites.check_type_access("gated", ctx) == {:error, :type_denied}
    assert StepWrites.check_type_access("free", ctx) == :ok
    assert StepWrites.check_type_access("gated", %{ctx | subject_id: other.id}) == :ok
  end
end
