defmodule Letflow.Scripts.CompanionBootstrapTest do
  @moduledoc """
  T-1683 (T-1599 stage 1 preparation D): `scripts/companion/bootstrap.sh` is dry-run only. It copies the
  'companion' paths into a temp dir, runs `diff -r`, prints a report and deletes the temp dir. It must
  refuse every mode that would create or push a repository. Runs on throw-away git repositories.

  Needs bash, git, tar, diff.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/companion/bootstrap.sh")

  defp git(dir, args) do
    {out, code} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@t.invalid", "-c", "commit.gpgsign=false"] ++
          args,
        cd: dir,
        stderr_to_stdout: true
      )

    assert code == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  defp repo(dir, files) do
    git(dir, ["init", "-q"])

    for {path, body} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end

    git(dir, ["add", "-A"])
    git(dir, ["commit", "-q", "-m", "x"])
  end

  defp list(dir) do
    path = Path.join(dir, "list.tsv")

    File.write!(
      path,
      Enum.join(
        [
          "lib/\tsource\tcode",
          "handoffs/\tcompanion\tnotes",
          "docs/\tcompanion\tdocs",
          "docs/old.md\tdrop\tgone",
          "keep/\tstays\twaits"
        ],
        "\n"
      ) <> "\n"
    )

    path
  end

  defp run(args, tmp) do
    System.cmd("bash", [@script | args], stderr_to_stdout: true, env: [{"TMPDIR", tmp}])
  end

  defp fixture(dir) do
    repo(dir, [
      {"lib/a.ex", "code"},
      {"handoffs/h.md", "h"},
      {"docs/d.md", "d"},
      {"docs/old.md", "old"},
      {"keep/k.txt", "k"}
    ])
  end

  setup %{tmp_dir: dir} do
    src = Path.join(dir, "src")
    scratch = Path.join(dir, "scratch")
    File.mkdir_p!(src)
    File.mkdir_p!(scratch)
    fixture(src)
    %{src: src, scratch: scratch, list: list(dir)}
  end

  test "B1 dry run copies only companion paths, proves diff -r and removes its temp dir", ctx do
    {out, code} = run(["--dry-run", "--root", ctx.src, "--list", ctx.list], ctx.scratch)
    assert code == 0, out
    assert out =~ "Companion paths: 2 (missing on disk: 0)"
    assert out =~ "Files copied:    2"
    assert out =~ "diff -r:         identical"
    assert out =~ "Leaked paths:    0"
    assert out =~ "RESULT: OK"
    assert File.ls!(ctx.scratch) == []
  end

  test "B2 it changes nothing in the source tree and creates no repository or remote", ctx do
    before_status = git(ctx.src, ["status", "--porcelain"])
    before_remotes = git(ctx.src, ["remote", "-v"])
    before_head = git(ctx.src, ["rev-parse", "HEAD"])
    {_, 0} = run(["--root", ctx.src, "--list", ctx.list], ctx.scratch)
    assert git(ctx.src, ["status", "--porcelain"]) == before_status
    assert git(ctx.src, ["remote", "-v"]) == before_remotes
    assert git(ctx.src, ["rev-parse", "HEAD"]) == before_head
    assert File.ls!(ctx.scratch) == []
  end

  test "B3 modes that would create or push are refused", ctx do
    for flag <- ~w(--execute --create --push --remote --repo --init --apply --no-dry-run --keep) do
      {out, code} = run([flag, "x"], ctx.scratch)
      assert code == 2, "#{flag}: #{out}"
      assert out =~ "refused"
    end

    assert File.ls!(ctx.scratch) == []
  end

  test "B4 a companion path missing on disk fails the proof", ctx do
    File.rm!(Path.join(ctx.src, "docs/d.md"))
    {out, code} = run(["--root", ctx.src, "--list", ctx.list], ctx.scratch)
    assert code == 1
    assert out =~ "MISSING on disk: docs/d.md"
    assert out =~ "RESULT: FAIL"
    assert File.ls!(ctx.scratch) == []
  end

  test "B5 an unclassified tracked path fails and the temp dir is still removed", ctx do
    File.mkdir_p!(Path.join(ctx.src, "newtop"))
    File.write!(Path.join(ctx.src, "newtop/x"), "x")
    git(ctx.src, ["add", "-A"])
    {out, code} = run(["--root", ctx.src, "--list", ctx.list], ctx.scratch)
    assert code == 1
    assert out =~ "does not classify every path"
    assert File.ls!(ctx.scratch) == []
  end

  test "B6 the script itself calls no push, remote, init, gh or network tool" do
    code =
      @script
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.join("\n")

    refute code =~ ~r/\bgh\s/
    refute code =~ ~r/\bcurl\b|\bwget\b|\bssh\b/
    refute code =~ ~r/git\s+(-C\s+\S+\s+)?(push|remote|init|clone|commit|fetch)/
  end

  @tag timeout: 120_000
  test "B7 the real tree passes the dry run" do
    {out, code} = System.cmd("bash", [@script], stderr_to_stdout: true)
    assert code == 0, out
    assert out =~ "diff -r:         identical"
    assert out =~ "RESULT: OK"
  end
end
