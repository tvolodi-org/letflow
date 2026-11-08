defmodule Letflow.Entities.StepSourceRecordIdTest do
  @moduledoc """
  REQ-760 (S1, S2): `StepSource.record_id/1` is a valid uuid derived only from the platform-set
  origin, line index and ordinal; `HandlerWrites.next_record_id/1` refuses a call outside a handler
  call and a forged context. (That the id equals the id of the following create is proven end to end
  in `kind_change_posting_test.exs` P1: the asset legs name the created cards.) Pure, `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Entities.HandlerContext
  alias Letflow.Entities.HandlerWrites
  alias Letflow.Entities.StepSource

  @attrs %{
    kind: "process_step",
    instance_id: "11111111-1111-4111-8111-111111111111",
    task_id: "22222222-2222-4222-8222-222222222222",
    node_id: "post",
    definition_id: "44444444-4444-4444-8444-444444444444",
    definition_version: "1.0.0",
    line_index: 0,
    activator_id: "55555555-5555-4555-8555-555555555555"
  }

  defp source(overrides \\ %{}, ordinal \\ 2) do
    handler = %{module_id: "assets", name: "post_kind_change", ordinal: ordinal}
    {:ok, source} = StepSource.new(Map.merge(@attrs, Map.put(overrides, :handler, handler)))
    source
  end

  test "S1 the id is a valid uuid, equal for equal sources, different per ordinal, line and origin" do
    id = StepSource.record_id(source())
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert id == StepSource.record_id(source())
    assert StepSource.record_id(source(%{}, 3)) != id
    assert StepSource.record_id(source(%{line_index: 1})) != id
    assert StepSource.record_id(source(%{task_id: "66666666-6666-4666-8666-666666666666"})) != id
    # the declarative line of the same origin and index gets its own id too
    {:ok, plain} = StepSource.new(@attrs)
    assert StepSource.record_id(plain) not in [id]

    assert StepSource.record_id(plain) ==
             StepSource.record_id_for_key(StepSource.idempotency_key(plain))
  end

  test "S2 next_record_id/1 refuses a call outside a handler call and a forged context" do
    ctx = %HandlerContext{
      prefix: "tenant_x",
      instance_id: @attrs.instance_id,
      node_id: "post",
      definition_id: @attrs.definition_id,
      definition_version: "1.0.0",
      actor_id: @attrs.activator_id,
      subject_id: @attrs.activator_id,
      activator_id: @attrs.activator_id,
      origin: {:task, "22222222-2222-4222-8222-222222222222"},
      line_index: 0,
      handler: %{module_id: "assets", name: "post_kind_change", targets: ["assets_card"]}
    }

    assert HandlerWrites.next_record_id(ctx) == {:error, :invalid_write_command}
    assert HandlerWrites.next_record_id(%{}) == {:error, :invalid_write_command}
    assert HandlerWrites.next_record_id(nil) == {:error, :invalid_write_command}
  end
end
