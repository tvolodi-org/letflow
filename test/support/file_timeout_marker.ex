defmodule Letflow.Test.FileTimeoutMarker do
  @moduledoc """
  T-2652: publishes the test file that is currently running to a marker file, so
  `scripts/test_parallel.sh` can enforce a per-test-file timeout and NAME the file
  that stalled instead of letting the whole shard run into the CI job limit.

  Why a marker file and not a log line: the runner needs the answer to "which file
  is running right now?" while the suite is still running. The suite's own stdout
  (the partition log) only shows a dot per finished test, so a hung file leaves no
  trace of its identity there. The marker file is rewritten on every ExUnit event
  that changes the answer (module started/finished, test started/finished), so the
  runner's poll always sees the freshest known state.

  The marker is published only when `TEST_PARALLEL_FILE_MARKER_DIR` is set, which
  `scripts/test_parallel.sh` exports for its own partitions. A plain `mix test`
  (local dev, a nested `mix test` subprocess) publishes nothing and pays nothing.

  T-2692: the isolated `:wasm_hang`/`:lua_wallclock_race` tails publish it too.
  `mix letflow.check.test` hands each watched tail subprocess a marker
  directory of its OWN and reads it back when the subprocess goes silent, so a
  hang inside a GROUP of tests -- the `:lua_wallclock_race` tail runs eleven of
  them in one subprocess, whose output carries dots and no names -- can be
  reported by the test that was running. The marker dir is per subprocess, so
  the tails' markers never collide with a partition's.

  Marker file format (one `key=value` per line, rewritten in place):

      file=<absolute path of the running test file>
      module=<the test module of that file>
      started=<unix seconds when that module started>
      progress=<unix seconds of the last test start/finish in that module>
      tests=<last started test names, newest first, separated by " | ">

  `progress` is what the runner compares against the limit: a file that keeps
  starting and finishing tests is progressing, a file whose current test never
  returns is not. `idle=1` is written instead when no test module is in flight.

  The module doubles as the ExUnit formatter that receives the events; it is
  installed through `ExUnit.start/1` in `test/test_helper.exs`.
  """

  use GenServer

  @marker_dir_env "TEST_PARALLEL_FILE_MARKER_DIR"
  # How many started test names the marker keeps (newest first).
  @last_tests 5

  @doc """
  The directory this run publishes its marker to, or `nil` when the marker is off.
  """
  @spec marker_dir() :: String.t() | nil
  def marker_dir do
    case System.get_env(@marker_dir_env) do
      nil -> nil
      "" -> nil
      dir -> dir
    end
  end

  @doc "True when this run publishes a marker file."
  @spec enabled?() :: boolean()
  def enabled?(), do: not is_nil(marker_dir())

  @doc """
  The marker file this run writes, or `nil` when the marker is off.

  The file name carries the partition index (`MIX_TEST_PARTITION`), because every
  partition of a `scripts/test_parallel.sh` run is its own OS process with its own
  marker.
  """
  @spec marker_path() :: String.t() | nil
  def marker_path do
    case marker_dir() do
      nil -> nil
      dir -> Path.join(dir, "current-#{System.get_env("MIX_TEST_PARTITION") || "0"}.txt")
    end
  end

  @doc """
  The formatter list to hand to `ExUnit.start/1`: the marker plus the CLI
  formatter, or just the CLI formatter when the marker is off.
  """
  @spec formatters() :: [module()]
  def formatters do
    if enabled?(), do: [__MODULE__, ExUnit.CLIFormatter], else: [ExUnit.CLIFormatter]
  end

  # --- GenServer (the ExUnit formatter) ---------------------------------------

  @impl GenServer
  def init(_opts) do
    {:ok, publish(%{modules: %{}, tests: []})}
  end

  @impl GenServer
  def handle_cast({:module_started, module}, state) do
    entry = %{
      file: file_of(module),
      module: module_name(module),
      started: now(),
      progress: now()
    }

    {:noreply, publish(%{state | modules: Map.put(state.modules, key_of(module), entry)})}
  end

  def handle_cast({:module_finished, module}, state) do
    {:noreply, publish(%{state | modules: Map.delete(state.modules, key_of(module))})}
  end

  def handle_cast({:test_started, test}, state) do
    entry =
      Map.get(state.modules, key_of(test)) ||
        %{
          file: file_of(test),
          module: module_name(test),
          started: now(),
          progress: now()
        }

    state = %{
      state
      | modules: Map.put(state.modules, key_of(test), %{entry | progress: now()}),
        tests: Enum.take([test_name(test) | state.tests], @last_tests)
    }

    {:noreply, publish(state)}
  end

  def handle_cast({:test_finished, _test}, state) do
    # A test START already reset its module's progress clock, and a test that
    # never finishes is exactly what the runner must catch -- so the finish
    # event buys nothing here and would double the marker's write volume.
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  # --- internals --------------------------------------------------------------

  # Writes the marker (the most stalled in-flight module wins) and returns the
  # state. Every event rewrites it: the marker is a few hundred bytes, the write
  # costs far less than the second the runner's poll waits between two reads, and
  # "the last thing that happened" must never be stale -- a stale marker would
  # name a module that has already finished.
  defp publish(state) do
    if enabled?() do
      write_marker(state)
    end

    state
  end

  defp write_marker(state) do
    path = marker_path()

    content =
      case Enum.min_by(Map.values(state.modules), & &1.progress, fn -> nil end) do
        nil ->
          "idle=1\n"

        entry ->
          [
            "file=#{entry.file}\n",
            "module=#{entry.module}\n",
            "started=#{entry.started}\n",
            "progress=#{entry.progress}\n",
            "tests=#{Enum.join(state.tests, " | ")}\n"
          ]
          |> IO.iodata_to_binary()
      end

    # Write-then-rename: the runner reads this file concurrently, and a rename is
    # atomic on POSIX, so it never sees a half-written marker.
    tmp = path <> ".tmp"
    File.write!(tmp, content)
    File.rename!(tmp, path)
  rescue
    # A marker that cannot be written must never fail the suite: the runner
    # simply keeps no marker and enforces nothing.
    _ -> :ok
  end

  defp key_of(%{module: module}), do: module
  defp key_of(%{name: name}), do: name
  defp key_of(other), do: other

  defp file_of(%{file: file}) when is_binary(file), do: file
  defp file_of(%{tags: tags}) when is_map(tags), do: Map.get(tags, :file) || ""
  defp file_of(_other), do: ""

  defp module_name(%{module: module}), do: inspect(module)
  defp module_name(%{name: name}), do: inspect(name)
  defp module_name(_other), do: ""

  defp test_name(%{module: module, name: name}), do: "#{inspect(module)}.#{name}"
  defp test_name(%{name: name}), do: to_string(name)
  defp test_name(_other), do: ""

  defp now, do: System.system_time(:second)
end
