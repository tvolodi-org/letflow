defmodule Letflow.RecordTriggers.LockOrderTest do
  @moduledoc """
  REQ-628 slice T-4 part B / GH #3507 (decision 0061 rule 5, criterion 8): the result transaction
  against a direct `Records.create_record/3` on the same type, with the type's `instance_sequence`
  row held as the barrier. O1: the result worker parks first; O2: the direct writer parks first.
  Both finish, no deadlock (`40P01`) and no lock timeout (`55P03`), the records and the per-type
  event sequence are complete and contiguous. Real parallel connections (tenant provisioning
  switches the sandbox to `:auto`), hence `async: false`. No audit assertion.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Event
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.RecordTriggers.Apply
  alias Letflow.RecordTriggerRunFixture, as: R

  setup do
    H.attach_error_handler(__MODULE__)
    s = R.tenant!("r628lo")
    id = R.record!(s, R.type_a(), %{"label" => "L1", "note" => "N1", "cid" => "c1"})
    # the written type gets its sequence row from the seed record
    R.record!(s, R.type_b(), %{"label" => "seed", "cid" => "s"})
    {:ok, instance_id} = EntityTypeInstance.fetch_instance_id(R.type_b(), s)
    rule = R.publish!(s)
    row = R.claimed_row!(s, rule, id)
    {:ok, schema: s, row: row, instance_id: instance_id}
  end

  defp result_worker(row, s) do
    line = %{
      index: 0,
      entity_type: R.type_b(),
      mode: "create",
      fields: %{"label" => "from-trigger"},
      external_ref: nil
    }

    fn -> Apply.apply_result(row, [line], s) end
  end

  defp direct_create(s) do
    fn ->
      Records.create_record(
        %{
          entity_type: R.type_b(),
          field_values: %{"label" => "direct"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: "r628-direct-" <> Ecto.UUID.generate()
        },
        s,
        :tenant
      )
    end
  end

  defp assert_complete(s, instance_id, %{first: r1, second: r2}) do
    results = [r1, r2]
    assert :done in results
    assert Enum.any?(results, &match?({:ok, %{record: _}}, &1))

    # seed + the two writes: every record exists once, the event sequence has no gap or duplicate
    assert R.count(s, R.type_b()) == 3

    sequence =
      Repo.all(
        from(e in Event,
          where: e.instance_id == ^instance_id,
          order_by: e.sequence_number,
          select: e.sequence_number
        ),
        prefix: s
      )

    assert sequence == Enum.to_list(1..3)
  end

  test "O1 the result worker parks first, the direct writer second", %{
    schema: s,
    row: row,
    instance_id: iid
  } do
    outcome = H.forced_overlap(s, {:sequence, iid}, result_worker(row, s), direct_create(s))
    assert_complete(s, iid, outcome)
    assert R.fetch(s, row.id).status == :done
  end

  test "O2 the direct writer parks first, the result worker second", %{
    schema: s,
    row: row,
    instance_id: iid
  } do
    outcome = H.forced_overlap(s, {:sequence, iid}, direct_create(s), result_worker(row, s))
    assert_complete(s, iid, outcome)
    assert R.fetch(s, row.id).status == :done
  end
end
