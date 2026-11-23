defmodule Letflow.Test.FileTimeoutMarkerTest do
  @moduledoc """
  T-2652: `Letflow.Test.FileTimeoutMarker` publishes the test file that is currently
  running, so `scripts/test_parallel.sh` can enforce a per-test-file timeout and name
  the file that stalled (push CI run 45010058431, shard 3/8, hung for its whole job
  budget with nothing in the log to say what was running).

  The marker is off unless `TEST_PARALLEL_FILE_MARKER_DIR` is set, so a plain
  `mix test` pays nothing and publishes nothing.
  """

  use ExUnit.Case, async: false
  @moduletag :unit
  @moduletag :tmp_dir

  alias Letflow.Test.FileTimeoutMarker

  setup do
    saved = %{
      dir: System.get_env("TEST_PARALLEL_FILE_MARKER_DIR"),
      partition: System.get_env("MIX_TEST_PARTITION")
    }

    on_exit(fn ->
      restore("TEST_PARALLEL_FILE_MARKER_DIR", saved.dir)
      restore("MIX_TEST_PARTITION", saved.partition)
    end)

    :ok
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  defp marker_fields(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  test "the marker is off unless its directory is set" do
    System.delete_env("TEST_PARALLEL_FILE_MARKER_DIR")

    refute FileTimeoutMarker.enabled?()
    assert FileTimeoutMarker.marker_path() == nil
    assert FileTimeoutMarker.formatters() == [ExUnit.CLIFormatter]
  end

  test "the marker file belongs to this partition" do
    System.put_env("TEST_PARALLEL_FILE_MARKER_DIR", "/tmp/markers")
    System.put_env("MIX_TEST_PARTITION", "9")

    assert FileTimeoutMarker.enabled?()
    assert FileTimeoutMarker.marker_path() == "/tmp/markers/current-9.txt"
    assert FileTimeoutMarker.formatters() == [FileTimeoutMarker, ExUnit.CLIFormatter]
  end

  test "the marker publishes the running file, its module and the last started tests", %{
    tmp_dir: tmp
  } do
    System.put_env("TEST_PARALLEL_FILE_MARKER_DIR", tmp)
    System.put_env("MIX_TEST_PARTITION", "1")

    {:ok, pid} = GenServer.start_link(FileTimeoutMarker, [])

    GenServer.cast(pid, {
      :module_started,
      %ExUnit.TestModule{file: "test/letflow/foo_test.exs", name: Letflow.FooTest}
    })

    GenServer.cast(pid, {
      :test_started,
      %ExUnit.Test{
        module: Letflow.FooTest,
        name: :"test one",
        tags: %{file: "test/letflow/foo_test.exs", line: 12}
      }
    })

    # :sys.get_state/1 is a synchronous system message: it returns only after the
    # casts above have been processed, so the marker on disk is the one they wrote.
    :sys.get_state(pid)

    fields = marker_fields(FileTimeoutMarker.marker_path())

    assert fields["file"] == "test/letflow/foo_test.exs"
    assert fields["module"] == "Letflow.FooTest"
    assert fields["tests"] =~ "Letflow.FooTest.test one"
    assert is_integer(String.to_integer(fields["progress"]))
  end

  test "the most stalled file is the one reported", %{tmp_dir: tmp} do
    System.put_env("TEST_PARALLEL_FILE_MARKER_DIR", tmp)
    System.put_env("MIX_TEST_PARTITION", "1")

    {:ok, pid} = GenServer.start_link(FileTimeoutMarker, [])

    GenServer.cast(pid, {
      :module_started,
      %ExUnit.TestModule{file: "test/letflow/fresh_test.exs", name: Letflow.FreshTest}
    })

    # A second module starts; the first one has not progressed for a second, so it
    # is the one a stalled file would be blamed on.
    Process.sleep(1_100)

    GenServer.cast(pid, {
      :test_started,
      %ExUnit.Test{
        module: Letflow.FreshTest,
        name: :"test two",
        tags: %{file: "test/letflow/fresh_test.exs"}
      }
    })

    :sys.get_state(pid)

    fields = marker_fields(FileTimeoutMarker.marker_path())

    assert fields["file"] == "test/letflow/fresh_test.exs"
    assert fields["tests"] =~ "Letflow.FreshTest.test two"
  end

  test "a finished module leaves no running file behind", %{tmp_dir: tmp} do
    System.put_env("TEST_PARALLEL_FILE_MARKER_DIR", tmp)
    System.put_env("MIX_TEST_PARTITION", "1")

    {:ok, pid} = GenServer.start_link(FileTimeoutMarker, [])

    module = %ExUnit.TestModule{file: "test/letflow/foo_test.exs", name: Letflow.FooTest}
    GenServer.cast(pid, {:module_started, module})
    GenServer.cast(pid, {:module_finished, module})
    :sys.get_state(pid)

    assert File.read!(FileTimeoutMarker.marker_path()) =~ "idle=1"
  end
end
