defmodule Letflow.Scripts.TestShardManifestCoverageTest do
  @moduledoc """
  GH #2380 step 2: with `TEST_PARALLEL_MANIFEST` set, `scripts/test_parallel.sh` runs every
  `test/**/*_test.exs` file in exactly one global partition, and the partitions tile the
  shards of `TEST_PARALLEL_SHARD=K/4` (N=4 partitions each).

  The timing manifest `test/shard_manifest.txt` is a balance hint: a file it does not
  list still runs, in the partition `Letflow.Test.TestShardManifest.fallback_partition/2`
  picks, and a line for a file that is gone is skipped. So a test file added or removed on main
  fails none of these tests; the script logs it (`test_parallel: unlisted file ...` and a
  `manifest drift` count) as the signal to run `scripts/test_shard_plan.sh --append` for
  balance. These tests check the effective assignment (manifest plus fallback).

  Pure file reads: no timing, no Mix, no CI.
  """
  use ExUnit.Case, async: true

  alias Letflow.Test.TestShardManifest

  @repo_root Path.expand("../..", __DIR__)
  @manifest Path.join(@repo_root, "test/shard_manifest.txt")
  @partitions_per_shard 4
  @shards 4
  @total @partitions_per_shard * @shards

  @fix_command "scripts/test_shard_plan.sh --append test/shard_manifest.txt > new && mv new test/shard_manifest.txt"

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

  defp effective, do: TestShardManifest.effective(entries(), disk_files(), @total)

  # The shard that runs global partition p: shard K runs partitions (K-1)*N+1 .. K*N.
  defp shard_of(p), do: div(p - 1, @partitions_per_shard) + 1

  test "CV-1: every test file on disk is run by exactly one partition (manifest plus fallback)" do
    assigned = Enum.map(effective(), &elem(&1, 1))

    assert Enum.sort(assigned) == disk_files()
    assert Enum.all?(effective(), fn {p, _path, _kind} -> p in 1..@total end)
  end

  test "CV-2: the manifest lists no path twice" do
    listed = Enum.map(entries(), &elem(&1, 1))
    duplicated = listed -- Enum.uniq(listed)

    assert duplicated == [],
           "test files listed more than once: #{inspect(duplicated)}; run: #{@fix_command}"
  end

  test "CV-3: the header total is N*M and every partition 1..#{@total} gets at least one file" do
    assert header_total() == @total

    populated = effective() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
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

    shards_by_file = Enum.group_by(effective(), &elem(&1, 1), &shard_of(elem(&1, 0)))

    assert map_size(shards_by_file) == length(disk_files())

    Enum.each(shards_by_file, fn {path, shards} ->
      assert length(shards) == 1, "#{path} is assigned #{length(shards)} times"
    end)
  end

  test "CV-5: a file missing from the manifest gets exactly one partition, a stale line none" do
    [{_p, dropped} | _] = entries()
    added = "test/zz_added_on_main_test.exs"
    stale = {3, "test/removed_on_main_test.exs"}

    entries = Enum.reject(entries(), &(elem(&1, 1) == dropped)) ++ [stale]
    disk = Enum.sort([added | disk_files()])
    eff = TestShardManifest.effective(entries, disk, @total)

    assert Enum.sort(Enum.map(eff, &elem(&1, 1))) == disk

    for path <- [dropped, added] do
      assert [{p, ^path, :unlisted}] = Enum.filter(eff, &(elem(&1, 1) == path))
      assert p == TestShardManifest.fallback_partition(path, @total)
      assert p in 1..@total
    end

    refute Enum.any?(eff, &(elem(&1, 1) == elem(stale, 1)))
  end

  test "CV-6: the fallback partition is a fixed function of the path" do
    # The rule of scripts/test_parallel.sh (h = h*31 + code mod 1000003, partition h mod 16 + 1)
    # on short paths by hand, and on a real path the value the script printed for it
    # (`test_parallel: unlisted file test/letflow/webhooks_redaction_test.exs -> partition 4`).
    # test_parallel_shard_test.exs compares the script and this rule on more paths.
    assert TestShardManifest.fallback_partition("a", 16) == rem(97, 16) + 1
    assert TestShardManifest.fallback_partition("ab", 16) == rem(97 * 31 + 98, 16) + 1

    assert TestShardManifest.fallback_partition("test/letflow/webhooks_redaction_test.exs", 16) ==
             4
  end
end
