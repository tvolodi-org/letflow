defmodule Letflow.Engine.SetInstanceErrorContentionTest do
  @moduledoc """
  GH #2706 / PR-3 (design `lib/letflow/design/gh2706-cancel-snapshot-and-lock-timeouts.md`
  sections 4 and 6; decision 0061): the ExecutionError landing of `Letflow.Engine.set_instance_error/2`
  on a sub-process child takes the parent group lock (`FOR KEY SHARE`); a lock timeout (55P03) or
  deadlock victim (40P01) there used to RAISE out of the dispatcher's give-up path and leave the
  instance active with no trace.

    * E1: a REAL 55P03 (barrier on the parent's projection row, the worker lowers the timeout to
      300 ms through the process-local override, test-seam builds only): three attempts, the typed
      `{:error, {:execution_error_contention, :lock_not_available}}`, the child unchanged, and
      exactly one standalone `dlq_entries` row marked `{"landing": "contention"}` that carries no
      variables, no reason text and no details;
    * E2: with `dlq_landed_externally: true` no row is added;
    * E3: the call succeeds when the holder goes away within the retry window (second attempt);
    * E4: `ExecutionError.append_multi/3` itself still raises on the contention class (the
      contract its moduledoc documents; the typed result is `set_instance_error/2`'s);
    * E5: nested in a caller's transaction there is no retry and no row: the typed error at once.

  Forced-overlap method: `Letflow.LockOrderHelpers`. Sandbox `:auto`, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Multi
  alias Letflow.Engine
  alias Letflow.Engine.ExecutionError
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  @override_ms 300
  @secret_variable "S3CR3T-VARIABLE-VALUE"
  @secret_reason "S3CR3T-REASON-TEXT"
  @secret_detail "S3CR3T-DETAIL-VALUE"

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    H.attach_error_handler(__MODULE__)

    base = Fx.committed_tenant_case!("gh2706-pr3")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)

    {parent_id, child_id} = pair!(base)
    %{base: base, parent_id: parent_id, child_id: child_id}
  end

  # ---- fixtures ---------------------------------------------------------------------------------

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp child_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "h1", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("e1", "start", "h1"), edge("e2", "h1", "end")]
    }
  end

  defp parent_graph(child_def) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_def.name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [edge("p1", "start", "sp"), edge("p2", "sp", "end")]
    }
  end

  defp pair!(base) do
    c_def = Fx.legacy_activate!(base.schema, base.user, child_graph(), [])
    parent = Fx.legacy_activate!(base.schema, base.user, parent_graph(c_def), [])

    {:ok, %{instance_id: parent_id}} =
      Engine.create(
        %{
          definition_id: parent.id,
          initial_variables: %{},
          actor_id: base.user.id,
          idempotency_key: Fx.unique("gh2706-pr3-start")
        },
        prefix: base.schema
      )

    child_id =
      Repo.one!(
        from(p in InstanceProjection,
          where: p.parent_instance_id == ^parent_id and p.definition_id == ^c_def.id,
          select: p.instance_id
        ),
        prefix: base.schema
      )

    {parent_id, child_id}
  end

  defp attrs(base, child_id) do
    %{
      instance_id: child_id,
      error_type: :variable_schema_rejected,
      affected: {:field, "approved"},
      reason: @secret_reason,
      variables: %{"secret" => @secret_variable},
      details: %{"note" => @secret_detail},
      actor_id: base.user.id,
      idempotency_key: Fx.unique("gh2706-pr3-set")
    }
  end

  # Runs in the worker's own process: lowers the lock timeout to 300 ms (test-seam builds only).
  defp with_override(fun) do
    fn ->
      Process.put(:contention_lock_timeout_ms_override, @override_ms)
      fun.()
    end
  end

  defp traced(fun), do: fn -> PlatformTenantFixture.capture_repo_queries(fun) end

  defp await_within!(task, ms) do
    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      other -> flunk("the worker did not finish within #{ms} ms (#{inspect(other)})")
    end
  end

  defp assert_child_untouched!(base, child_id) do
    assert Fx.projection!(base.schema, child_id).status == :active
    assert Fx.instance_events(base.schema, child_id, "EXECUTION_ERROR") == []
  end

  defp assert_55p03_reported! do
    assert_receive {:deadlock_detected, %Postgrex.Error{postgres: %{code: :lock_not_available}}},
                   1_000
  end

  # ---- E1 ---------------------------------------------------------------------------------------

  describe "E1: a real lock timeout on the parent group" do
    test "three attempts, the typed error, the child untouched, one marked DLQ row without tenant data",
         %{base: base, parent_id: parent_id, child_id: child_id} do
      {holder, _} = H.hold_row(base.schema, {:projection, parent_id})

      call = fn -> Engine.set_instance_error(attrs(base, child_id), prefix: base.schema) end

      log =
        capture_log([level: :warning], fn ->
          {worker, pid} = H.start_worker(with_override(traced(call)))
          H.wait_for_blocked([pid], 1)
          send(self(), {:done, await_within!(worker, 5_000)})
        end)

      assert_received {:done, {{result, queries}, _done_at}}

      assert result == {:error, {:execution_error_contention, :lock_not_available}}
      assert_55p03_reported!()
      assert_55p03_reported!()
      assert_55p03_reported!()
      refute_receive {:deadlock_detected, _}, 100

      # exactly three attempts: three transactions each starting with the lock-timeout step
      assert Enum.count(queries, &(&1.query =~ "lock_timeout")) == 3

      assert_child_untouched!(base, child_id)

      # the log carries the instance id and the classified tag, never tenant data
      assert log =~ "instance_id=#{child_id}"
      assert log =~ "lock_not_available after attempt 3"
      refute log =~ @secret_variable
      refute log =~ @secret_reason
      refute log =~ @secret_detail

      assert [row] = Fx.dlq_entries(base.schema)
      assert row.tenant_id == base.tenant.tenant_id
      assert row.status == :pending
      assert row.entry_type == "event"
      assert row.instance_id == child_id
      assert row.context_json == %{"landing" => "contention"}

      assert row.error_detail == %{
               "error_type" => "variable_schema_rejected",
               "affected" => %{"field" => "approved"},
               "contention" => "lock_not_available",
               "attempts" => 3
             }

      dump = inspect(row)
      refute dump =~ @secret_variable
      refute dump =~ @secret_reason
      refute dump =~ @secret_detail

      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, H.await_ms())

      # nothing stays wedged: the same call succeeds once the holder is gone
      assert {:ok, %{status: :error}} =
               Engine.set_instance_error(attrs(base, child_id), prefix: base.schema)
    end
  end

  # ---- E2 ---------------------------------------------------------------------------------------

  describe "E2: the caller already landed a DLQ row" do
    test "dlq_landed_externally: true adds no row", %{
      base: base,
      parent_id: parent_id,
      child_id: child_id
    } do
      {holder, _} = H.hold_row(base.schema, {:projection, parent_id})

      call = fn ->
        Engine.set_instance_error(attrs(base, child_id),
          prefix: base.schema,
          dlq_landed_externally: true
        )
      end

      {worker, pid} = H.start_worker(with_override(traced(call)))
      H.wait_for_blocked([pid], 1)
      {{result, queries}, _} = await_within!(worker, 5_000)

      assert result == {:error, {:execution_error_contention, :lock_not_available}}
      # all three attempts ran, only the extra row is skipped
      assert Enum.count(queries, &(&1.query =~ "lock_timeout")) == 3
      assert_child_untouched!(base, child_id)
      assert Fx.dlq_entries(base.schema) == []

      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, H.await_ms())
    end
  end

  # ---- E3 ---------------------------------------------------------------------------------------

  describe "E3: success after a retry" do
    test "the second attempt lands once the holder is released", %{
      base: base,
      parent_id: parent_id,
      child_id: child_id
    } do
      {holder, _} = H.hold_row(base.schema, {:projection, parent_id})

      call = fn -> Engine.set_instance_error(attrs(base, child_id), prefix: base.schema) end
      {worker, pid} = H.start_worker(with_override(call))
      H.wait_for_blocked([pid], 1)

      # the first attempt times out; the second starts at once (no backoff under test seams) and
      # waits again, so the release below lands inside its 300 ms window
      assert_55p03_reported!()
      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, H.await_ms())

      {result, _} = await_within!(worker, 5_000)
      assert {:ok, %{instance_id: ^child_id, status: :error}} = result
      # exactly one timeout was reported: the second attempt succeeded
      refute_receive {:deadlock_detected, _}, 100

      assert Fx.projection!(base.schema, child_id).status == :error
      assert [_one] = Fx.instance_events(base.schema, child_id, "EXECUTION_ERROR")
      # the regular landing wrote its own row, the contention path none
      assert [row] = Fx.dlq_entries(base.schema)
      refute row.context_json == %{"landing" => "contention"}
    end
  end

  # ---- E4 ---------------------------------------------------------------------------------------

  describe "E4: the ExecutionError contract" do
    test "append_multi/3 raises on the contention class, it does not return an error tuple", %{
      base: base,
      parent_id: parent_id,
      child_id: child_id
    } do
      {holder, _} = H.hold_row(base.schema, {:projection, parent_id})

      call = fn ->
        Multi.new()
        |> Multi.run(:lock_timeout, fn repo, _ ->
          repo.query!("SET LOCAL lock_timeout = '300ms'")
          {:ok, nil}
        end)
        |> ExecutionError.append_multi(
          %{
            instance_id: child_id,
            error_type: :variable_schema_rejected,
            affected: {:field, "approved"},
            reason: "r",
            variables: %{},
            details: %{},
            actor_id: base.user.id,
            idempotency_key: Fx.unique("gh2706-pr3-e4")
          },
          prefix: base.schema
        )
        |> Repo.transaction()
      end

      guarded = fn ->
        try do
          call.()
        rescue
          e in Postgrex.Error -> {:raised, e.postgres.code}
        end
      end

      {worker, pid} = H.start_worker(guarded)
      H.wait_for_blocked([pid], 1)
      {result, _} = await_within!(worker, 5_000)

      assert result == {:raised, :lock_not_available}

      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, H.await_ms())
    end
  end

  # ---- E5 ---------------------------------------------------------------------------------------

  describe "E5: nested in the caller's transaction" do
    test "no retry and no extra row: the typed error at once", %{
      base: base,
      parent_id: parent_id,
      child_id: child_id
    } do
      {holder, _} = H.hold_row(base.schema, {:projection, parent_id})

      # a nested call sets no timeout of its own, the caller sets one
      call = fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '300ms'")
          result = Engine.set_instance_error(attrs(base, child_id), prefix: base.schema)
          Repo.rollback(result)
        end)
      end

      log =
        capture_log([level: :warning], fn ->
          {worker, pid} = H.start_worker(call)
          H.wait_for_blocked([pid], 1)
          {result, _} = await_within!(worker, 5_000)

          assert result == {:error, {:error, {:execution_error_contention, :lock_not_available}}}
        end)

      assert log =~ "set_instance_error contention: lock_not_available after attempt 1"
      assert log =~ "instance_id=#{child_id}"
      # skipped by the nested guard, not attempted and rescued
      refute log =~ "DLQ row not written"
      refute log =~ @secret_variable
      refute log =~ @secret_reason
      refute log =~ @secret_detail
      assert_55p03_reported!()
      refute_receive {:deadlock_detected, _}, 100
      assert_child_untouched!(base, child_id)
      assert Fx.dlq_entries(base.schema) == []

      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, H.await_ms())
    end
  end
end
