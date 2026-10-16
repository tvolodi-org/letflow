defmodule Letflow.EventStore.LockInstanceSequenceTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4a (design `gh2590-req501-module-write-handlers.md` 4.4): the
  lock-only primitive `Letflow.EventStore.lock_instance_sequence/3`. It performs sub-steps
  (i) insert-if-absent and (ii) `FOR UPDATE` of `assign_sequence/3` WITHOUT the increment:
  it creates the sequence row when absent, locks it for the rest of the transaction, never
  moves `next_seq`, and is idempotent. The step is also what `HandlerWrites.lock_types/3`
  runs per type, ascending.
  """

  use Letflow.DataCase, async: false

  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.TenantFixture

  setup do
    %{schema_name: schema} = TenantFixture.provisioned_tenant!(slug_prefix: "gh2590-lock")
    %{schema: schema}
  end

  defp next_seq(schema, instance_id),
    do: Repo.get_by!(InstanceSequence, [instance_id: instance_id], prefix: schema).next_seq

  # xmax of a row the transaction has locked FOR UPDATE is the locker's transaction id
  defp xmax(schema, instance_id) do
    %{rows: [[value]]} =
      Repo.query!(
        ~s(SELECT xmax::text FROM "#{schema}".instance_sequence WHERE instance_id = $1),
        [Ecto.UUID.dump!(instance_id)]
      )

    value
  end

  test "creates the missing row, locks it, and does NOT assign a sequence number", %{
    schema: schema
  } do
    instance_id = Ecto.UUID.generate()

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert {:ok, :locked} =
                        EventStore.lock_instance_sequence(Repo, instance_id, schema)

               assert next_seq(schema, instance_id) == 1
               assert xmax(schema, instance_id) != "0"
               :ok
             end)

    # idempotent: a second call (row now present) is again :locked and still assigns nothing
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert {:ok, :locked} =
                        EventStore.lock_instance_sequence(Repo, instance_id, schema)

               assert {:ok, :locked} =
                        EventStore.lock_instance_sequence(Repo, instance_id, schema)

               assert next_seq(schema, instance_id) == 1
               :ok
             end)
  end

  test "an existing row keeps its next_seq", %{schema: schema} do
    instance_id = Ecto.UUID.generate()

    Repo.insert!(%InstanceSequence{instance_id: instance_id, next_seq: 7}, prefix: schema)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert {:ok, :locked} =
                        EventStore.lock_instance_sequence(Repo, instance_id, schema)

               :ok
             end)

    assert next_seq(schema, instance_id) == 7
  end

  test "only a UUID instance id and a binary prefix are accepted" do
    assert_raise FunctionClauseError, fn ->
      apply(EventStore, :lock_instance_sequence, [Repo, nil, "x"])
    end

    assert_raise FunctionClauseError, fn ->
      apply(EventStore, :lock_instance_sequence, [Repo, "x", nil])
    end
  end
end
