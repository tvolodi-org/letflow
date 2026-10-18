defmodule Letflow.LockOrderHelpers do
  @moduledoc """
  GH #2704 (design `lib/letflow/design/gh2704-lock-order-family.md`, section 4, "Common test
  infrastructure"; decision 0061 rule 5): the forced-overlap harness for engine row-lock order
  tests, shared by the lock-order test files.

  Determinism without sleep-coupled timing: a third connection `Z` holds ONE row (a barrier),
  the workers run on their own pinned connections (`Repo.checkout/1`, each reporting
  `pg_backend_pid()`), and the test polls (every 10 ms, to a 700 ms monotonic deadline per phase) until the number of DISTINCT
  blocked backends among the workers' pids reaches the expected count. Only then is `Z` released.
  Postgres grants the waiters of one row in arrival order, so "start worker 1, wait until it is
  blocked, start worker 2, wait until both are blocked, release `Z`" fixes who gets the contended
  row first.

  A deadlock victim of the service path is silently re-applied by the engine and the HUMAN side
  maps it to `entity_write_contention`, so a result alone is no evidence: `attach_error_handler/1`
  attaches a telemetry handler on the Repo query event that reports every `deadlock_detected`
  (`40P01`) and `lock_not_available` (`55P03`) query error, from any process, retried or not, as
  `{:deadlock_detected, error}` to the test process.

  Every helper must run in a test that is in Sandbox `:auto` mode (real commits, real
  connections), hence `async: false`.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Letflow.Repo

  # entity-write fixtures run under a 2 s lock_timeout, so each wait for parked workers is bounded
  # by a monotonic DEADLINE (wall clock, not a step count: a query round trip is not free) that
  # stays far below it
  @poll_deadline_ms 700
  @poll_ms 10
  @await_ms 15_000

  # the 2 s `lock_timeout` the forced-overlap margins are measured against
  @lock_timeout_ms 2_000

  @doc "The lock timeout (ms) the green cases' margins are measured against."
  @spec lock_timeout_ms() :: pos_integer()
  def lock_timeout_ms, do: @lock_timeout_ms

  @doc "The bound the test files use for `Task.await/2` of workers and holders."
  @spec await_ms() :: pos_integer()
  def await_ms, do: @await_ms

  @doc """
  Attaches the deadlock / lock-timeout reporter for the calling test process and detaches it
  when the test exits.
  """
  @spec attach_error_handler(term()) :: :ok
  def attach_error_handler(tag) do
    handler_id = {__MODULE__, tag, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        &__MODULE__.handle_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  @doc false
  def handle_query(_event, _measurements, %{result: {:error, error}}, test_pid) do
    # 40P01 (deadlock) and 55P03 (lock timeout) both mean the lock order was wrong or a wait
    # was unbounded; either is a failure even when the engine would retry it.
    if match?(
         %Postgrex.Error{postgres: %{code: code}}
         when code in [:deadlock_detected, :lock_not_available],
         error
       ),
       do: send(test_pid, {:deadlock_detected, error})

    :ok
  end

  def handle_query(_event, _measurements, _metadata, _test_pid), do: :ok

  @doc """
  Holds one row `FOR UPDATE` on a third connection until `:release` is sent to the holder;
  returns `{task, backend_pid}`. `spec` is `{:sequence, instance_id}`,
  `{:projection, instance_id}`, `{:task, task_id}` (GH #2706: one `tasks` row) or `:audit_chain` (the
  tenant's one `audit_chain_locks` row).
  """
  @spec hold_row(
          String.t(),
          {:sequence, Ecto.UUID.t()}
          | {:projection, Ecto.UUID.t()}
          | {:task, Ecto.UUID.t()}
          | :audit_chain
        ) ::
          {Task.t(), pos_integer()}
  def hold_row(schema, {:sequence, instance_id}),
    do:
      hold(
        ~s(SELECT 1 FROM "#{schema}"."instance_sequence" WHERE instance_id = $1 FOR UPDATE),
        [Ecto.UUID.dump!(instance_id)]
      )

  def hold_row(schema, {:projection, instance_id}),
    do:
      hold(
        ~s(SELECT 1 FROM "#{schema}"."instance_projections" WHERE instance_id = $1 FOR UPDATE),
        [Ecto.UUID.dump!(instance_id)]
      )

  def hold_row(schema, {:task, task_id}),
    do:
      hold(
        ~s(SELECT 1 FROM "#{schema}"."tasks" WHERE id = $1 FOR UPDATE),
        [Ecto.UUID.dump!(task_id)]
      )

  def hold_row(schema, :audit_chain),
    do: hold(~s(SELECT 1 FROM "#{schema}"."audit_chain_locks" FOR UPDATE), [])

  defp hold(sql, params) do
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          %{num_rows: rows} = Repo.query!(sql, params)
          send(test_pid, {:held, rows})
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(test_pid, {:held_backend, backend})

          receive do
            :release -> :ok
          after
            @await_ms -> :ok
          end
        end)
      end)

    on_exit(fn -> send(holder.pid, :release) end)
    assert_receive {:held, rows}, 10_000
    assert rows == 1, "the barrier row must exist (#{rows} row(s) matched)"
    assert_receive {:held_backend, backend}, 10_000
    {holder, backend}
  end

  @doc "A worker on its own pinned connection; returns `{task, backend_pid}`."
  @spec start_worker((-> term())) :: {Task.t(), pos_integer()}
  def start_worker(fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, self(), pid})
          result = fun.()
          {result, System.monotonic_time(:millisecond)}
        end)
      end)

    task_pid = task.pid
    assert_receive {:backend, ^task_pid, backend_pid}, 10_000
    {task, backend_pid}
  end

  @doc """
  Waits until `n` DISTINCT workers among `pids` are blocked on a lock; bounded by a monotonic
  deadline of `#{@poll_deadline_ms}` ms per phase (polled every `#{@poll_ms}` ms), so a phase never
  eats the 2 s `lock_timeout` of the workers. Returns the monotonic millisecond at which the
  count was reached. A miss is a SLOW START of the workers (host load), not a deadlock: deadlocks
  are reported by the telemetry handler.
  """
  @spec wait_for_blocked([pos_integer()], pos_integer()) :: integer()
  def wait_for_blocked(pids, n) do
    sql = """
    SELECT count(DISTINCT a.pid)
    FROM pg_stat_activity a
    JOIN pg_locks l ON l.pid = a.pid AND NOT l.granted
    WHERE a.pid = ANY($1) AND a.wait_event_type = 'Lock'
    """

    deadline = System.monotonic_time(:millisecond) + @poll_deadline_ms
    blocked = poll_blocked(sql, pids, n, deadline)

    assert blocked >= n,
           "slow start, not a deadlock: expected #{n} distinct blocked worker backend(s) within " <>
             "#{@poll_deadline_ms} ms, saw #{blocked}"

    System.monotonic_time(:millisecond)
  end

  defp poll_blocked(sql, pids, n, deadline) do
    %{rows: [[count]]} = Repo.query!(sql, [pids])

    cond do
      count >= n ->
        count

      System.monotonic_time(:millisecond) >= deadline ->
        count

      true ->
        Process.sleep(@poll_ms)
        poll_blocked(sql, pids, n, deadline)
    end
  end

  @doc "The backend pids blocking `pid`."
  @spec blockers(pos_integer()) :: [pos_integer()]
  def blockers(pid) do
    %{rows: [[pids]]} = Repo.query!("SELECT pg_blocking_pids($1)", [pid])
    pids
  end

  @doc """
  The forced AB-BA overlap. `barrier` is a `hold_row/2` spec; `first` and `second` are
  zero-arity workers. Holds the barrier, starts `first`, waits until it is blocked, starts
  `second`, waits until both are blocked, releases the barrier and awaits both.

  Returns `%{first: result, second: result, timing: timing}` where `timing` carries the
  millisecond figures behind the 2 s `lock_timeout` margin of the green cases
  (`window_first`: first worker blocked until release; `window_second`; `done_first` and
  `done_second`: release until that worker returned). Asserts no deadlock / lock timeout
  reached the telemetry handler (`attach_error_handler/1` must have run) and that no result
  mentions one.
  """
  @spec forced_overlap(String.t(), term(), (-> term()), (-> term())) :: map()
  def forced_overlap(schema, barrier, first, second) do
    {holder, barrier_pid} = hold_row(schema, barrier)

    {t1, pid1} = start_worker(first)
    blocked1_at = wait_for_blocked([pid1], 1)
    # the first worker is parked on the barrier connection, nothing else
    assert barrier_pid in blockers(pid1)

    {t2, pid2} = start_worker(second)
    blocked2_at = wait_for_blocked([pid1, pid2], 2)
    # the second worker is parked behind the barrier or behind the first worker
    assert Enum.any?(blockers(pid2), &(&1 in [barrier_pid, pid1]))

    released_at = System.monotonic_time(:millisecond)
    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, @await_ms)

    {r1, done1_at} = Task.await(t1, @await_ms)
    {r2, done2_at} = Task.await(t2, @await_ms)

    timing = %{
      window_first: released_at - blocked1_at,
      window_second: released_at - blocked2_at,
      done_first: done1_at - released_at,
      done_second: done2_at - released_at
    }

    refute_receive {:deadlock_detected, _error}, 0
    refute inspect([r1, r2]) =~ "40P01"
    refute inspect([r1, r2]) =~ "deadlock"

    %{first: r1, second: r2, timing: timing}
  end

  @doc """
  The measured `lock_timeout` margin of a green forced-overlap case, in milliseconds, against the
  2 s constant. Conservative: the second worker is charged its whole time from parking to
  returning although it waits on several locks in turn.
  """
  @spec margin_ms(map()) :: integer()
  def margin_ms(%{window_first: w1, window_second: w2, done_first: d1, done_second: d2}),
    do: @lock_timeout_ms - Enum.max([w1 + d1, w2 + d2])

  @doc """
  The order in which Postgres fires the two foreign-key checks of an UPDATE of a sub-process
  child's projection row (`parent_instance_id` and `parent_token_id`): constraint triggers of one
  event fire by trigger name (`RI_ConstraintTrigger_c_<oid>`, a string comparison), so it differs
  between freshly provisioned tenant schemas. Returns the referenced tables in firing order.
  """
  @spec fk_firing_order(String.t()) :: [String.t()]
  def fk_firing_order(schema) do
    check_schema!(schema)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT (SELECT relname FROM pg_class WHERE oid = c.confrelid)
        FROM pg_trigger t
        JOIN pg_constraint c ON c.oid = t.tgconstraint
        WHERE t.tgrelid = $1::text::regclass AND t.tgisinternal AND c.contype = 'f'
          AND (SELECT proname FROM pg_proc WHERE oid = t.tgfoid) = 'RI_FKey_check_upd'
          AND c.confrelid IN ($2::text::regclass, $3::text::regclass)
        ORDER BY t.tgname
        """,
        [
          ~s("#{schema}".instance_projections),
          ~s("#{schema}".tokens),
          ~s("#{schema}".instance_projections)
        ]
      )

    List.flatten(rows)
  end

  @doc """
  Re-creates the two parent foreign keys of `instance_projections` so that the check against
  `first` (`"tokens"` or `"instance_projections"`) fires first, then asserts it (the red and the
  green of the lock-order files depend on it, so the order is a precondition, not an assumption).
  """
  @spec set_fk_order!(String.t(), String.t()) :: :ok
  def set_fk_order!(schema, first) do
    check_schema!(schema)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.conname, pg_get_constraintdef(c.oid),
               (SELECT relname FROM pg_class WHERE oid = c.confrelid)
        FROM pg_constraint c
        WHERE c.conrelid = $1::text::regclass AND c.contype = 'f'
          AND c.confrelid IN ($2::text::regclass, $3::text::regclass)
        """,
        [
          ~s("#{schema}".instance_projections),
          ~s("#{schema}".tokens),
          ~s("#{schema}".instance_projections)
        ]
      )

    assert length(rows) == 2

    ordered =
      Enum.sort_by(rows, fn [_name, _definition, target] -> if target == first, do: 0, else: 1 end)

    for [name, _definition, _target] <- ordered do
      Repo.query!(~s(ALTER TABLE "#{schema}".instance_projections DROP CONSTRAINT "#{name}"))
    end

    for [name, definition, _target] <- ordered do
      Repo.query!(
        ~s(ALTER TABLE "#{schema}".instance_projections ADD CONSTRAINT "#{name}" #{definition})
      )
    end

    assert List.first(fk_firing_order(schema)) == first,
           "precondition: the FK check against #{first} must fire first, got " <>
             inspect(fk_firing_order(schema))

    :ok
  end

  # these helpers run DDL on a tenant schema: only the schema of a fixture-built tenant
  # (`tenant_<32 hex>`) is accepted
  defp check_schema!(schema) do
    unless is_binary(schema) and Regex.match?(~r/\Atenant_[0-9a-f]{32}\z/, schema) do
      raise ArgumentError,
            "expected a committed-tenant schema name (tenant_<32 hex>), got: #{inspect(schema)}"
    end

    :ok
  end

  @doc "Normalizes a dumped 16-byte UUID query parameter."
  @spec normalize(term()) :: term()
  def normalize(param) when is_binary(param) and byte_size(param) == 16,
    do: Ecto.UUID.load!(param)

  def normalize(param), do: param
end
