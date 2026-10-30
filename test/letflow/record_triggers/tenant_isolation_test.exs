defmodule Letflow.RecordTriggers.TenantIsolationTest do
  @moduledoc """
  REQ-628 slice T-4 part B / GH #3507 (criterion 11, INV-1): two tenants, A and B. A type that exists
  only in B is refused in A's result transaction (`write_not_permitted`) and nothing is written in
  either schema; a successful run changes only A's schema and its input never carries B's data; a
  row run or applied against the other tenant's schema finds no script / no row and writes nothing.
  INV-10: no route takes a tenant identifier in this slice (the worker iterates schemas), so there is
  no route negative test. `async: false` (tenant provisioning, application env).
  """

  use Letflow.DataCase, async: false

  alias Letflow.RecordTriggers.Apply
  alias Letflow.RecordTriggers.Runner
  alias Letflow.RecordTriggers.Worker
  alias Letflow.RecordTriggerRunFixture, as: R
  alias Letflow.Support.ScriptPolicyFixture, as: P

  setup do
    a = R.tenant!("r628ia")
    b = R.tenant!("r628ib")
    P.active_definition!(b, "r628_only_b", ["label", "cid"])
    a_id = R.record!(a, R.type_a(), %{"label" => "A-label", "note" => "N1", "cid" => "c1"})
    R.record!(b, R.type_a(), %{"label" => "B-SECRET", "note" => "B-note", "cid" => "c2"})
    R.record!(b, "r628_only_b", %{"label" => "B-only", "cid" => "c3"})
    {:ok, a: a, b: b, a_id: a_id}
  end

  defp snapshot(s),
    do: {R.event_count(s), R.count(s, R.type_a()), R.count(s, R.type_b())}

  test "I1a a type only the other tenant has is refused in A; neither schema changes", %{
    a: a,
    b: b,
    a_id: id
  } do
    manifest =
      R.manifest(%{}, [
        %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => ["note"]},
        %{"entity_type" => "r628_only_b", "mode" => "create", "fields" => ["label"]}
      ])

    R.reply(
      R.ok(%{
        "writes" => [
          %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => %{"note" => "N2"}},
          %{"entity_type" => "r628_only_b", "mode" => "create", "fields" => %{"label" => "x"}}
        ]
      })
    )

    row = R.claimed_row!(a, R.publish!(a, manifest), id)
    R.forward([:letflow, :record_trigger, :write_refused])
    {before_a, before_b} = {snapshot(a), snapshot(b)}
    only_b = R.count(b, "r628_only_b")

    # the Runner accepts it (declared); the refusal is Apply's
    assert {:ok, [_, _]} = Runner.run(row, a)
    assert Worker.run_row(row, a) == :dead
    assert R.fetch(a, row.id).last_code == "trigger_write_refused"

    assert_received {:telemetry, [:letflow, :record_trigger, :write_refused],
                     %{reason: "write_not_permitted"}}

    assert snapshot(a) == before_a
    assert snapshot(b) == before_b
    assert R.count(b, "r628_only_b") == only_b
    assert R.fields(a, R.type_a(), id)["note"] == "N1"
  end

  test "I1b a successful run in A changes only A; the script input never holds B's data", %{
    a: a,
    b: b,
    a_id: id
  } do
    R.reply(
      R.ok(%{
        "writes" => [
          %{"entity_type" => R.type_a(), "mode" => "update_self", "fields" => %{"note" => "N2"}}
        ]
      })
    )

    row = R.claimed_row!(a, R.publish!(a), id)
    before_b = snapshot(b)

    assert Worker.run_row(row, a) == :done
    assert R.fields(a, R.type_a(), id)["note"] == "N2"
    assert snapshot(b) == before_b

    assert_received {:stub_run, _source, input, opts, _in_tx?}
    refute inspect(input) =~ "B-SECRET"
    assert opts[:tenant] == a
  end

  test "I1c a row run or applied against the other tenant's schema finds nothing and writes nothing",
       %{a: a, b: b, a_id: id} do
    R.reply(R.ok(%{"writes" => []}))
    row = R.claimed_row!(a, R.publish!(a), id)
    {before_a, before_b} = {snapshot(a), snapshot(b)}

    assert {:dead, code} = Runner.run(row, b)
    assert code in ["script_unavailable", "pin_mismatch"]
    refute_received {:stub_run, _, _, _, _}

    line = %{
      index: 0,
      entity_type: R.type_b(),
      mode: "create",
      fields: %{"label" => "x"},
      external_ref: nil
    }

    assert Apply.apply_result(row, [line], b) == :stale
    assert Worker.run_row(row, b) in [:dead, :stale]

    assert snapshot(a) == before_a
    assert snapshot(b) == before_b
    assert R.fetch(a, row.id).status == :running
  end
end
