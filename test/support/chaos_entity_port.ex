defmodule Letflow.Support.ChaosEntityPort do
  @moduledoc """
  GH #2587 PR C2 test double of `Letflow.Engine.EntityPort`: delegates EVERYTHING to the real
  `Letflow.Entities.EntityPortImpl` and, when armed, appends one extra Multi step to `multi/3`
  that raises a database error (a contention class or not) the first `n` times it runs.

  Used to drive the SERVICE_TASK apply's contention classification and bounded re-apply with
  the real transaction machinery. Not a mock of the write path: the lines themselves are the
  real ones and are rolled back by the real transaction.

  Test usage (the test module is `async: false`; the port is application env):

      counter = ChaosEntityPort.arm!(:lock_not_available, 1)
      ...
      on_exit(&ChaosEntityPort.disarm!/0)   # also restores the previous port

  `record!/0` installs the port without arming anything and reports every port call to the
  calling test as `{:port_call, name, arg}` (the `multi/3` context included), which is how a test
  observes `guard_budget_ms` reaching the port or asserts that a replay makes no port call.
  """

  @behaviour Letflow.Engine.EntityPort

  alias Ecto.Multi
  alias Letflow.Entities.EntityPortImpl

  @key {__MODULE__, :chaos}

  @doc """
  Installs this module as the entity port and arms the raise: the first `n` runs of the chaos
  step raise a `Postgrex.Error` with `code` (`n = :infinity` raises every time). Returns the
  `:counters` ref counting the runs.
  """
  @spec arm!(atom(), pos_integer() | :infinity) :: :counters.counters_ref()
  def arm!(code, n) do
    arm_exception!(
      %Postgrex.Error{postgres: %{code: code, message: "chaos", severity: "ERROR"}},
      n
    )
  end

  @doc "Like `arm!/2` with an arbitrary exception struct (for example a `DBConnection.ConnectionError`)."
  @spec arm_exception!(Exception.t(), pos_integer() | :infinity) :: :counters.counters_ref()
  def arm_exception!(exception, n) do
    counter = :counters.new(1, [])
    :persistent_term.put(@key, {n, exception, counter})
    install!()
    counter
  end

  @doc "Installs the port and reports every call to the calling test (see the moduledoc)."
  @spec record!() :: :ok
  def record! do
    :persistent_term.put({__MODULE__, :recorder}, self())
    install!()
    :ok
  end

  defp install! do
    if :persistent_term.get({__MODULE__, :previous}, :none) == :none do
      :persistent_term.put({__MODULE__, :previous}, Application.fetch_env(:letflow, :entity_port))
    end

    Application.put_env(:letflow, :entity_port, __MODULE__)
  end

  @doc "Disarms and restores the entity port that was configured before the first install."
  @spec disarm!() :: :ok
  def disarm! do
    :persistent_term.erase(@key)
    :persistent_term.erase({__MODULE__, :recorder})

    case :persistent_term.get({__MODULE__, :previous}, :none) do
      {:ok, value} -> Application.put_env(:letflow, :entity_port, value)
      :error -> Application.delete_env(:letflow, :entity_port)
      :none -> :ok
    end

    :persistent_term.erase({__MODULE__, :previous})
    :ok
  end

  defp report(name, arg) do
    case :persistent_term.get({__MODULE__, :recorder}, nil) do
      pid when is_pid(pid) -> send(pid, {:port_call, name, arg})
      _none -> :ok
    end

    :ok
  end

  @impl true
  def authorize_module_writes(lines, ctx), do: EntityPortImpl.authorize_module_writes(lines, ctx)

  @impl true
  def prefetch(prefix, reads, vars), do: EntityPortImpl.prefetch(prefix, reads, vars)

  @impl true
  def prepare(lines, ctx) do
    report(:prepare, lines)
    EntityPortImpl.prepare(lines, ctx)
  end

  @impl true
  def validate_lines(lines, ctx) do
    report(:validate_lines, lines)
    EntityPortImpl.validate_lines(lines, ctx)
  end

  @impl true
  def multi(multi, lines, ctx) do
    report(:multi, ctx)
    base = EntityPortImpl.multi(multi, lines, ctx)

    case :persistent_term.get(@key, nil) do
      {n, exception, counter} ->
        Multi.run(base, :chaos, fn _repo, _changes ->
          :counters.add(counter, 1, 1)

          if n == :infinity or :counters.get(counter, 1) <= n,
            do: raise(exception),
            else: {:ok, :fine}
        end)

      nil ->
        base
    end
  end

  @impl true
  def interpret_failure(step, reason) do
    report(:interpret_failure, step)
    EntityPortImpl.interpret_failure(step, reason)
  end
end
