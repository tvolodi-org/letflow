defmodule Letflow.RecordTriggers.ContentionTest do
  @moduledoc """
  REQ-628 slice T-4 part B / GH #3507 (decision 0067 D7, criterion 10): C2b forces the
  `entity_write_contention` retry deterministically. `Apply.write/5` (update_self) reads the
  record's `record_latest` row with a plain read inside the result transaction and passes that
  read's `last_event_global_seq`; `Records.check_record_version` then re-reads it `FOR UPDATE`. A bump
  made BEFORE `apply_result` is therefore already seen, so P1 holds the Latest row, P2 (the result
  worker) reads it and blocks on the lock, and P1 bumps the sequence and commits: the compare fails.
  Real parallel connections (tenant provisioning switches the sandbox to `:auto`), hence
  `async: false`; waits are the bounded polls of `LockOrderHelpers`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.RecordTriggers.Apply
  alias Letflow.RecordTriggers.OutboxRow
  alias Letflow.RecordTriggers.Worker
  alias Letflow.RecordTriggerRunFixture, as: R

  setup do
    H.attach_error_handler(__MODULE__)
    on_exit(fn -> Application.delete_env(:letflow, :record_trigger_worker) end)
    :ok
  end

  test "C2b a version conflict while applying retries with the backoff and counts to the cap" do
    s = R.tenant!("r628c2b")
    id = R.record!(s, R.type_a(), %{"label" => "L1", "note" => "N1", "cid" => "c1"})
    rule = R.publish!(s)
    row = R.claimed_row!(s, rule, id)
    events = R.event_count(s)
    parent = self()

    line = %{
      index: 0,
      entity_type: R.type_a(),
      mode: "update_self",
      fields: %{"note" => "N2"},
      external_ref: nil
    }

    latest = fn ->
      from(l in Latest, where: l.entity_type == ^R.type_a() and l.record_id == ^id)
    end

    # P1: holds the Latest row FOR UPDATE, then bumps its sequence (update_all, not Records:
    # that would need the sequence lock P2 holds) and commits.
    {p1, p1_backend} =
      H.start_worker(fn ->
        Repo.transaction(fn ->
          Repo.one!(from(l in latest.(), lock: "FOR UPDATE", select: l.id), prefix: s)
          send(parent, :p1_holds_latest)

          receive do
            :bump -> :ok
          after
            H.await_ms() -> :ok
          end

          Repo.update_all(latest.(), [inc: [last_event_global_seq: 1]], prefix: s)
        end)
      end)

    assert_receive :p1_holds_latest, 10_000

    {p2, p2_backend} = H.start_worker(fn -> Apply.apply_result(row, [line], s) end)
    H.await_blocked_by(p2_backend, [p1_backend])

    send(p1.pid, :bump)
    assert {{:ok, _}, _} = Task.await(p1, H.await_ms())
    assert {{:retry, "entity_write_contention"} = failure, _} = Task.await(p2, H.await_ms())
    refute_received {:deadlock_detected, _}

    # the whole transaction rolled back: no event, the row is still this claim
    assert R.event_count(s) == events
    assert R.fields(s, R.type_a(), id)["note"] == "N1"
    assert R.fetch(s, row.id).status == :running

    # the terminal transaction: pending with the backoff window
    before = DateTime.utc_now()
    assert Apply.finish(row, s, failure) == :retry
    stored = R.fetch(s, row.id)
    assert stored.status == :pending and stored.last_code == "entity_write_contention"
    wait = DateTime.diff(stored.next_attempt_at, before, :millisecond)
    assert wait >= Worker.backoff_ms(1) - 1_000 and wait <= Worker.backoff_ms(1) + 5_000

    # contention counts toward the cap: at max_attempts the next retry ends dead
    Application.put_env(:letflow, :record_trigger_worker, max_attempts: 2)

    {1, _} =
      Repo.update_all(
        from(r in OutboxRow, where: r.id == ^row.id),
        [set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -60, :second)]],
        prefix: s
      )

    assert {:ok, %OutboxRow{attempt: 2} = second} = Worker.claim_next(s)
    assert Apply.finish(second, s, failure) == :dead
    final = R.fetch(s, row.id)
    assert final.status == :dead and final.last_code == "retries_exhausted"
  end
end
