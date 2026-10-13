defmodule Letflow.Test.TestParallelCapture do
  @moduledoc """
  Q-1053 / GH #2399 / ISS-1080: failure-time capture for the tests that drive the real
  `scripts/test_parallel.sh` with stub `mix`/`psql`.

  The script preserves its own tmp dir on every nonzero exit, but a CI job log only shows
  the assertion message, and the stub run's directory is gone as soon as the ExUnit
  `tmp_dir` is cleaned up. The first occurrence of the shard flake therefore left no
  evidence of WHY `partition-N.log` was missing. `with_context/3` appends to every
  assertion failure raised inside it:

    * a listing of every file under the test's `tmp_dir` (so a missing nested
      `letflow_test_parallel.*` directory is visible as such),
    * the content (capped at 200 lines each) of every `partition-*.log`, `create-*.log`
      and of the stub bookkeeping files (`calls.log`, `ready.log`, `db.log`, `build.log`),
    * the elapsed milliseconds when the caller knows them.

  It never raises on a missing directory, and it deliberately does NOT set
  `TEST_PARALLEL_KEEP_LOGS`: that knob would skip the very `rm -rf` the regression tests
  exist to expose (ISS-1080 RC-A).
  """

  @max_lines 200
  @max_listing 400
  @bookkeeping ~w(calls.log ready.log db.log build.log)

  @doc """
  Runs `fun`; if it raises an `ExUnit.AssertionError`, re-raises it with the capture
  appended. `out` is the script output (a binary or a zero-arity function returning one,
  for callers that only have it after the run).
  """
  @spec with_context(Path.t(), String.t() | (-> String.t()), (-> result)) :: result
        when result: var
  def with_context(tmp, out, fun) when is_function(fun, 0) do
    fun.()
  rescue
    e in ExUnit.AssertionError ->
      base =
        case e.message do
          m when is_binary(m) -> m
          _ -> "assertion failed: " <> inspect(Map.take(e, [:expr, :left, :right]))
        end

      reraise ExUnit.AssertionError.exception(
                message: base <> "\n" <> failure_context(tmp, resolve(out)),
                expr: e.expr,
                left: e.left,
                right: e.right
              ),
              __STACKTRACE__
  end

  @doc "The capture text for `tmp` and the script output `out` (never raises)."
  @spec failure_context(Path.t(), String.t(), non_neg_integer() | nil) :: String.t()
  def failure_context(tmp, out, elapsed_ms \\ nil) do
    files = list_files(tmp)

    nested =
      case Enum.filter(files, &(&1 =~ ~r{/letflow_test_parallel\.[^/]+$})) do
        [] -> "(nested letflow_test_parallel.* tmp dir missing -- removed or never created)"
        dirs -> "nested tmp dir(s): " <> Enum.join(dirs, ", ")
      end

    listing =
      files
      |> Enum.take(@max_listing)
      |> Enum.map_join("\n", &"  #{&1}")

    contents =
      files
      |> Enum.filter(&capture_file?/1)
      |> Enum.map_join("\n", fn rel ->
        "---- #{rel} ----\n" <> read_capped(Path.join(tmp, rel))
      end)

    [
      "==== test_parallel failure context (ISS-1080) ====",
      if(elapsed_ms, do: "elapsed_ms=#{elapsed_ms}", else: "elapsed_ms=unknown"),
      nested,
      "---- script output ----",
      out,
      "---- files under #{tmp} ----",
      listing,
      contents,
      "==== end failure context ===="
    ]
    |> Enum.join("\n")
  end

  defp resolve(out) when is_function(out, 0), do: out.()
  defp resolve(out) when is_binary(out), do: out

  defp capture_file?(rel) do
    base = Path.basename(rel)

    (String.starts_with?(base, "partition-") and String.ends_with?(base, ".log")) or
      (String.starts_with?(base, "create-") and String.ends_with?(base, ".log")) or
      base in @bookkeeping
  end

  defp list_files(root) do
    case File.ls(root) do
      {:ok, _} -> walk(root, "")
      {:error, _} -> []
    end
  end

  defp walk(root, rel) do
    dir = Path.join(root, rel)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          child = if rel == "", do: name, else: Path.join(rel, name)

          cond do
            String.starts_with?(child, "work/_build") -> []
            File.dir?(Path.join(root, child)) -> [child | walk(root, child)]
            true -> [child]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp read_capped(path) do
    case File.read(path) do
      {:ok, bin} ->
        lines = String.split(bin, "\n")

        if length(lines) > @max_lines do
          Enum.join(Enum.take(lines, @max_lines), "\n") <>
            "\n... (#{length(lines) - @max_lines} more lines)"
        else
          bin
        end

      {:error, reason} ->
        "(unreadable: #{inspect(reason)})"
    end
  end
end
