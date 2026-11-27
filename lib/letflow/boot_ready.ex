defmodule Letflow.BootReady do
  @moduledoc """
  T-2950: has the node finished its boot work? One `:persistent_term` flag.

  `begin/0` is called first thing in `Letflow.Application.start/2` and marks the node as booting;
  the one-shot boot Task (`Letflow.PlatformProcesses.BootSeed`) calls `mark_done/0` when it ends,
  whatever its result. `done?/0` is true when the flag was never begun (a bare test or script
  that does not start the application tree).

  Two readers:

    * `GET /ready` (`Letflow.Readiness`, part `"boot"`) answers 503 until the flag is done, so a
      deploy script, `uat_smoke.sh` and the UAT runner can wait for 200 instead of meeting 503s
      from the user-request admission gate. `GET /health` stays liveness and is unchanged.
    * `Letflow.Scheduler.Poller` postpones its sweeps while the node is booting: its sweeps take
      units of the user-request gate (`Letflow.Admission.try_acquire(:global)`), and a first tick at
      0 ms across every tenant used to exhaust that gate while users were already being served.

  The capacity defaults of `Letflow.Admission` are not touched.
  """

  @key {__MODULE__, :state}

  @doc "Marks the node as booting."
  @spec begin() :: :ok
  def begin do
    :persistent_term.put(@key, :booting)
    :ok
  end

  @doc "Marks the boot work as finished."
  @spec mark_done() :: :ok
  def mark_done do
    :persistent_term.put(@key, :done)
    :ok
  end

  @doc "True when the boot work is finished (or was never begun)."
  @spec done?() :: boolean()
  def done?, do: :persistent_term.get(@key, :done) == :done

  @doc "Runs the boot seed, then marks the boot done even when the seed crashed or raised."
  @spec run_boot_work() :: :ok
  def run_boot_work do
    try do
      Letflow.PlatformProcesses.BootSeed.run()
    after
      mark_done()
    end

    :ok
  end
end
