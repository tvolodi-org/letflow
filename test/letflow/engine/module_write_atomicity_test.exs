defmodule Letflow.Engine.ModuleWriteAtomicityTest do
  @moduledoc """
  GH #2725 gap 2 / REQ-501 design section 11 row "No I/O, no nested transaction" (`25P02`): the
  RUN-TIME half of the guard that `handler_writes_callers_test.exs` (scans H1-H5) and
  `module_write_owner_path_test.exs` (S2: a step with a live repo is `:handler_shape`) cover
  statically.

  A failure inside the completion transaction, whether the handler's own (a raise, a smuggled
  step with a live repo) or the database's (a unique violation of the step idempotency key), must
  leave the transaction and the connection usable: no `in_failed_sql_transaction` (SQLSTATE
  `25P02`) reaches the caller, a log line or the next statement, nothing is committed and the
  task stays `pending`. Under the Ecto sandbox the completion runs in a savepoint of the test
  transaction, so a poisoned (swallowed-error) transaction would make the very next query of the
  test fail with `25P02`.

  `async: false`: the module installs run DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  defp assert_connection_usable(ctx) do
    assert %{rows: [[1]]} = Repo.query!("SELECT 1")
    assert Fx.all_records(ctx.schema) == []
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
  end

  defp refute_poisoned(log) do
    refute log =~ "25P02"
    refute log =~ "in_failed_sql_transaction"
  end

  test "a database error inside the step Multi is a mapped refusal, not a poisoned transaction" do
    ctx = Mw.case!("gh2725-atomicity-db", :module)
    started = hd(Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_STARTED"))
    key = "sys:step:#{ctx.task.id}:0:1"

    Repo.insert_all(
      "event_idempotency",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          idempotency_key: key,
          event_id: Ecto.UUID.dump!(started.event_id),
          event_created_at: started.created_at,
          inserted_at: DateTime.utc_now()
        }
      ],
      prefix: ctx.schema
    )

    log =
      capture_log(fn ->
        assert {:error, {:entity_write_refused, 0, :idempotency_conflict}} =
                 Fx.complete(ctx, %{"label" => "L1"})
      end)

    refute_poisoned(log)
    assert_connection_usable(ctx)

    # the same transaction keeps working: with the conflicting key gone, the retry commits
    Repo.delete_all(from(i in "event_idempotency", where: i.idempotency_key == ^key),
      prefix: ctx.schema
    )

    assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
    assert [_] = Fx.records(ctx.schema, "fxl_ledger")
    assert [_] = Fx.records(ctx.schema, "fxl_balance")
  end

  for handler <- ["raises", "run_after_create"] do
    test "rogue handler #{handler}: no 25P02, the connection stays usable, nothing committed" do
      ctx = Mw.rogue_case!("gh2725-atomicity-#{unquote(handler)}", unquote(handler))

      log =
        capture_log(fn ->
          assert {:error, {:entity_write_failed, 0, :handler}} = Fx.complete(ctx, %{})
        end)

      refute_poisoned(log)
      assert_connection_usable(ctx)
      assert Fx.step_idempotency_count(ctx.schema) == 0
      assert Fx.entity_events(ctx.schema) == []
    end
  end
end
