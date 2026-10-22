defmodule Letflow.Scripts.TestShardManifestCoverageTest do
  @moduledoc """
  GH #2380 step 2: the timing manifest `scripts/test_shard_manifest.txt` (read by
  `scripts/test_parallel.sh` when `TEST_PARALLEL_MANIFEST` is set) assigns every
  `test/**/*_test.exs` file to exactly one global partition, and the partitions tile the
  shards of `TEST_PARALLEL_SHARD=K/4` (N=4 partitions each).

  Pure file reads: no timing, no Mix, no CI. A test file added to the tree and not listed
  in the manifest fails CV-1, and the message names the command that lists it.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @manifest Path.join(@repo_root, "scripts/test_shard_manifest.txt")
  @partitions_per_shard 4
  @shards 4
  @total @partitions_per_shard * @shards

  @fix_command "scripts/test_shard_plan.sh --append scripts/test_shard_manifest.txt > new && mv new scripts/test_shard_manifest.txt"

  defp manifest_lines do
    @manifest
    |> File.read!()
    |> String.replace("\r", "")
    |> String.split("\n", trim: true)
  end

  # {partition, repo-relative path} for every non-header line, in file order.
  defp entries do
    for line <- manifest_lines(), not String.starts_with?(line, "#") do
      [part, path, _weight] = String.split(line, " ")
      {String.to_integer(part), path}
    end
  end

  defp header_total do
    manifest_lines()
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^# partitions: (\d+)$/, line) do
        [_, total] -> String.to_integer(total)
        nil -> nil
      end
    end)
  end

  defp disk_files do
    @repo_root
    |> Path.join("test/**/*_test.exs")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.relative_to(@repo_root) |> String.replace("\\", "/")))
    |> Enum.sort()
  end

  # The shard that runs global partition p: shard K runs partitions (K-1)*N+1 .. K*N.
  defp shard_of(p), do: div(p - 1, @partitions_per_shard) + 1

  test "CV-1: every test file on disk is listed in the manifest exactly once" do
    listed = Enum.map(entries(), &elem(&1, 1))
    missing = disk_files() -- listed
    duplicated = listed -- Enum.uniq(listed)

    assert missing == [],
           "test files not in #{@manifest}: #{inspect(missing)}; run: #{@fix_command}"

    assert duplicated == [], "test files listed more than once: #{inspect(duplicated)}"
  end

  test "CV-2: every manifest path exists on disk" do
    stale = for {_p, path} <- entries(), not File.exists?(Path.join(@repo_root, path)), do: path

    assert stale == [],
           "manifest lines for files that do not exist: #{inspect(stale)}; run: #{@fix_command}"
  end

  test "CV-3: the header total is N*M and every partition 1..#{@total} has at least one file" do
    assert header_total() == @total

    populated = entries() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    empty = Enum.reject(1..@total, &MapSet.member?(populated, &1))

    assert empty == [], "partitions with no file: #{inspect(empty)}"
  end

  test "CV-4: each test file is run by exactly one shard, and each shard runs its own 4 partitions" do
    for shard <- 1..@shards do
      partitions = for p <- 1..@total, shard_of(p) == shard, do: p

      assert partitions ==
               Enum.to_list(
                 ((shard - 1) * @partitions_per_shard + 1)..(shard * @partitions_per_shard)//1
               )
    end

    shards_by_file = Enum.group_by(entries(), &elem(&1, 1), &shard_of(elem(&1, 0)))

    Enum.each(shards_by_file, fn {path, shards} ->
      assert length(shards) == 1, "#{path} is listed #{length(shards)} times"
    end)
  end
end
