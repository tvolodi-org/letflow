defmodule Letflow.Test.TestShardManifest do
  @moduledoc """
  GH #2380 step 2: the effective shard assignment `scripts/test_parallel.sh` builds when
  `TEST_PARALLEL_MANIFEST` is set, mirrored in Elixir for the coverage tests.

  The manifest is a balance hint, not the list of what runs. A test file on disk keeps its
  manifest partition; a file the manifest does not list goes to `fallback_partition/2`; a
  manifest line whose file is gone is skipped. So a test file added or removed on main while a
  branch waits to merge neither fails the run nor goes unrun. The rule here and the awk in the
  script must stay in step: `test_parallel_shard_test.exs` runs the real script on unlisted
  files and compares its placement with this module's.
  """

  @doc """
  The partition (1..total) for a test file the manifest does not list:
  `rem(h, total) + 1`, with `h = rem(h * 31 + code, 1_000_003)` over the path's characters,
  where printable ASCII counts by its code and any other character as 0.
  """
  @spec fallback_partition(String.t(), pos_integer()) :: pos_integer()
  def fallback_partition(path, total) do
    h =
      path
      |> String.to_charlist()
      |> Enum.reduce(0, fn c, h ->
        code = if c in 32..126, do: c, else: 0
        rem(h * 31 + code, 1_000_003)
      end)

    rem(h, total) + 1
  end

  @doc """
  `{partition, path, :listed | :unlisted}` for every file in `disk_files`, given the manifest's
  `{partition, path}` entries in file order (the first line for a path wins). Stale manifest
  lines (path not on disk) are left out.
  """
  @spec effective([{pos_integer(), String.t()}], [String.t()], pos_integer()) ::
          [{pos_integer(), String.t(), :listed | :unlisted}]
  def effective(entries, disk_files, total) do
    on_disk = MapSet.new(disk_files)

    listed =
      entries
      |> Enum.uniq_by(&elem(&1, 1))
      |> Enum.filter(fn {_p, path} -> MapSet.member?(on_disk, path) end)

    listed_paths = MapSet.new(listed, &elem(&1, 1))

    unlisted =
      for path <- disk_files, not MapSet.member?(listed_paths, path) do
        {fallback_partition(path, total), path, :unlisted}
      end

    Enum.map(listed, fn {p, path} -> {p, path, :listed} end) ++ unlisted
  end
end
