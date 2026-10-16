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
    counter = :counters.new(1, [])
    exception = %Postgrex.Error{postgres: %{code: code, message: "chaos", severity: "ERROR"}}
    :persistent_term.put(@key, {n, exception, counter})
    previous = Application.fetch_env(:letflow, :entity_port)
    :persistent_term.put({__MODULE__, :previous}, previous)
    Application.put_env(:letflow, :entity_port, __MODULE__)
    counter
  end

  @doc "Disarms and restores the entity port that was configured before `arm!/2`."
  @spec disarm!() :: :ok
  def disarm! do
    :persistent_term.erase(@key)

    case :persistent_term.get({__MODULE__, :previous}, :none) do
      {:ok, value} -> Application.put_env(:letflow, :entity_port, value)
      :error -> Application.delete_env(:letflow, :entity_port)
      :none -> :ok
    end

    :persistent_term.erase({__MODULE__, :previous})
    :ok
  end

  @impl true
  def authorize_module_writes(lines, ctx), do: EntityPortImpl.authorize_module_writes(lines, ctx)

  @impl true
  def prefetch(prefix, reads, vars), do: EntityPortImpl.prefetch(prefix, reads, vars)

  @impl true
  def prepare(lines, ctx), do: EntityPortImpl.prepare(lines, ctx)

  @impl true
  def validate_lines(lines, ctx), do: EntityPortImpl.validate_lines(lines, ctx)

  @impl true
  def multi(multi, lines, ctx) do
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
  def interpret_failure(step, reason), do: EntityPortImpl.interpret_failure(step, reason)
end
