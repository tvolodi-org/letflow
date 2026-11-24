defmodule Letflow.Engine.PlatformStepRunner.Poller do
  @moduledoc """
  Supervised ticker of `Letflow.Engine.PlatformStepRunner` (T-2703): one cycle of the platform
  tenant's platform steps every `:poll_interval_ms` (config `:platform_step_runner`, default 2 s).

  Gated by its own key, `:start_platform_step_runner` (false in `config/test.exs`: the same
  zero-delay-first-tick `DBConnection.OwnershipError` hazard as the other pollers). Tests call
  `PlatformStepRunner.run_due/2` directly. Without a pinned platform tenant a tick does nothing.
  """

  use GenServer

  alias Letflow.Engine.PlatformStepRunner

  @default_poll_interval_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    Process.send_after(self(), :tick, 0)
    {:ok, :ok}
  end

  @impl true
  def handle_info(:tick, state) do
    # A cycle that fails is counted by the runner and tried again on the next tick.
    _ = PlatformStepRunner.run_tick()
    Process.send_after(self(), :tick, poll_interval_ms())
    {:noreply, state}
  rescue
    _exception ->
      Process.send_after(self(), :tick, poll_interval_ms())
      {:noreply, state}
  end

  defp poll_interval_ms do
    :letflow
    |> Application.get_env(:platform_step_runner, [])
    |> Keyword.get(:poll_interval_ms, @default_poll_interval_ms)
  end
end
