defmodule Letflow.Scripts.PruneWebDistBackupsTest do
  @moduledoc """
  GH 2352: `deploy/lib/prune_web_dist_backups.sh`, the keep-last-N retention that
  `deploy/redeploy-qa.sh` runs after a successful QA deploy, against a stub directory tree
  (no docker, no host, no network).

    * more than N backups: the oldest are removed, the newest N stay;
    * exactly N and fewer than N: nothing is removed;
    * decoys are never touched: `web-dist`, `web-dist-staging-*`,
      `web-dist-backup-keep-me-not`, a malformed stamp, a plain file and a symlink that carry a
      backup-shaped name, and anything outside the app dir;
    * a bad keep value or a missing app dir prunes nothing and returns 0 (never fails a deploy);
    * `redeploy-qa.sh` sources the helper last, tolerates a prune failure, and still parses.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @helper Path.join(@root, "deploy/lib/prune_web_dist_backups.sh")
  @redeploy Path.join(@root, "deploy/redeploy-qa.sh")

  @moduletag :tmp_dir

  defp stamps(n) do
    for i <- 1..n do
      "web-dist-backup-202609#{String.pad_leading(Integer.to_string(i), 2, "0")}-120000"
    end
  end

  defp mk_backups(dir, names) do
    for name <- names do
      path = Path.join(dir, name)
      File.mkdir_p!(path)
      File.write!(Path.join(path, "index.html"), "x")
    end
  end

  defp prune(dir), do: run_prune([dir])
  defp prune(dir, keep), do: run_prune([dir, keep])

  defp run_prune(args) do
    script = ~s|source "#{@helper}"; prune_web_dist_backups "$@"|

    System.cmd("bash", ["-c", script, "prune" | args], stderr_to_stdout: true)
  end

  defp remaining(dir) do
    dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "web-dist-backup-")) |> Enum.sort()
  end

  test "more than N: the oldest are removed and the newest N stay", %{tmp_dir: dir} do
    names = stamps(25)
    mk_backups(dir, names)

    assert {out, 0} = prune(dir, "20")
    assert out =~ "removed 5 of 25, kept the newest 20"
    assert remaining(dir) == Enum.take(names, -20)
  end

  test "the default keep is 20", %{tmp_dir: dir} do
    names = stamps(23)
    mk_backups(dir, names)

    assert {_out, 0} = prune(dir)
    assert remaining(dir) == Enum.take(names, -20)
  end

  test "exactly N and fewer than N: nothing is removed", %{tmp_dir: dir} do
    names = stamps(20)
    mk_backups(dir, names)
    assert {out, 0} = prune(dir, "20")
    assert out =~ "nothing to remove"
    assert remaining(dir) == names

    few = Path.join(dir, "few")
    File.mkdir_p!(few)
    mk_backups(few, stamps(3))
    assert {_out, 0} = prune(few, "20")
    assert remaining(few) == stamps(3)
  end

  test "decoys and the live bundle are never touched", %{tmp_dir: dir} do
    app = Path.join(dir, "app")
    File.mkdir_p!(app)
    mk_backups(app, stamps(4))

    decoys = [
      "web-dist",
      "web-dist-staging-20260101-000000",
      "web-dist-backup-keep-me-not",
      "web-dist-backup-20260101",
      "web-dist-backup-20260101-1200000",
      "web-dist-backup-20260101-120000.old"
    ]

    mk_backups(app, decoys)

    File.write!(
      Path.join(app, "web-dist-backup-20250101-000000"),
      "a plain file named like a backup"
    )

    outside = Path.join(dir, "outside-keep")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "important"), "x")
    link = Path.join(app, "web-dist-backup-20240101-000000")

    symlinked? =
      case File.ln_s(outside, link) do
        :ok -> true
        {:error, _} -> false
      end

    assert {out, 0} = prune(app, "2")
    assert out =~ "removed 2 of 4, kept the newest 2"

    assert Enum.take(stamps(4), -2) -- remaining(app) == []
    for d <- decoys, do: assert(File.exists?(Path.join(app, d)), "decoy removed: #{d}")
    assert File.regular?(Path.join(app, "web-dist-backup-20250101-000000"))
    assert File.exists?(Path.join(outside, "important"))
    if symlinked?, do: assert({:ok, _} = File.read_link(link))
    for gone <- Enum.take(stamps(4), 2), do: refute(File.exists?(Path.join(app, gone)))
  end

  test "a bad keep value or a missing app dir prunes nothing and returns 0", %{tmp_dir: dir} do
    names = stamps(5)
    mk_backups(dir, names)

    for bad <- ["0", "-1", "abc", "2x", "1.5"] do
      assert {out, 0} = prune(dir, bad)
      assert out =~ "WARN", "no warning for keep=#{inspect(bad)}"
      assert remaining(dir) == names
    end

    assert {out, 0} = prune(Path.join(dir, "does-not-exist"), "5")
    assert out =~ "WARN"
    assert {out, 0} = prune("", "5")
    assert out =~ "WARN"
  end

  test "keep=1 leaves exactly the newest backup", %{tmp_dir: dir} do
    names = stamps(6)
    mk_backups(dir, names)
    assert {_out, 0} = prune(dir, "1")
    assert remaining(dir) == [List.last(names)]
  end

  test "redeploy-qa.sh parses and runs the prune last, tolerating failure" do
    assert {_out, 0} = System.cmd("bash", ["-n", @redeploy])
    assert {_out, 0} = System.cmd("bash", ["-n", @helper])

    src = File.read!(@redeploy) |> String.replace("\r\n", "\n")
    assert src =~ ~s|source "$APP_DIR/deploy/lib/prune_web_dist_backups.sh"|

    assert String.contains?(
             src,
             ~s(prune_web_dist_backups "$APP_DIR" "$WEB_DIST_BACKUP_KEEP" || echo)
           )

    assert src =~ ~s|WEB_DIST_BACKUP_KEEP="${WEB_DIST_BACKUP_KEEP:-20}"|

    {health, _} = :binary.match(src, "Frontend health check passed")
    {prune, _} = :binary.match(src, "prune_web_dist_backups \"$APP_DIR\"")
    {done, _} = :binary.match(src, "=== Done. Deployed ref")
    assert health < prune and prune < done
  end
end
