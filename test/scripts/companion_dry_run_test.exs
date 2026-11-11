defmodule Letflow.Scripts.CompanionDryRunTest do
  @moduledoc """
  T-1674 (T-1599 stage 1 preparation): `scripts/companion/dry_run.sh` classifies every tracked path with
  `scripts/companion/move_list.tsv` and changes nothing. The real-tree test is the guard that a new
  top-level path (or any new tracked file) cannot land without a class. The other tests run the script
  on a throw-away git repository in `tmp_dir`.

  Needs bash, git and awk.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/companion/dry_run.sh")
  @list Path.join(@root, "scripts/companion/move_list.tsv")

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
    String.trim(out)
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

  defp run(args), do: System.cmd("bash", [@script | args], stderr_to_stdout: true)

  defp write_list(dir, rows) do
    path = Path.join(dir, "list.tsv")
    File.write!(path, Enum.map_join(rows, "\n", &Enum.join(&1, "\t")) <> "\n")
    path
  end

  defp snapshot(dir) do
    {out, 0} =
      System.cmd("find", [
        dir,
        "-type",
        "f",
        "-not",
        "-path",
        "*/.git/*",
        "-exec",
        "sha256sum",
        "{}",
        "+"
      ])

    out |> String.split("\n", trim: true) |> Enum.sort()
  end

  @tag timeout: 120_000
  test "C1 every tracked path of this repository is classified", _ctx do
    {out, code} = run([])
    assert code == 0, out
    assert out =~ "RESULT: OK, every tracked path is classified"
    refute out =~ "ERROR"
  end

  test "C2 every move list row has a known class and a reason" do
    rows =
      @list
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
      |> Enum.map(&String.split(&1, "\t"))

    assert rows != []

    for row <- rows do
      assert [path, class, reason] = row
      assert path != "" and reason != ""
      assert class in ~w(source companion stays drop), "bad class for #{path}"
    end

    paths = Enum.map(rows, &hd/1)
    assert paths == Enum.uniq(paths)
  end

  test "C3 the real list classes the paths T-1599 names", _ctx do
    {companion, 0} = run(["--paths", "companion"])
    companion = String.split(companion, "\n", trim: true)
    assert "CLAUDE.md" in companion
    assert Enum.any?(companion, &String.starts_with?(&1, "handoffs/"))
    assert Enum.any?(companion, &String.starts_with?(&1, "lib/letflow/design/"))

    refute Enum.any?(
             companion,
             &(String.starts_with?(&1, "lib/") and
                 not String.starts_with?(&1, "lib/letflow/design/"))
           )

    {source, 0} = run(["--paths", "source"])
    assert "mix.exs" in String.split(source, "\n", trim: true)
  end

  test "C4 an unclassified tracked path is an error and is named", %{tmp_dir: dir} do
    repo(dir, [{"lib/a.ex", "x"}, {"newtop/file.txt", "y"}])
    list = write_list(dir, [["lib/", "source", "code"]])
    {out, code} = run(["--root", dir, "--list", list])
    assert code == 1
    assert out =~ "match no rule"
    assert out =~ "newtop/file.txt"
    assert out =~ "RESULT: FAIL"
  end

  test "C5 the longest matching path wins", %{tmp_dir: dir} do
    repo(dir, [
      {"lib/a.ex", "x"},
      {"lib/design/d.md", "doc"},
      {"scripts/seed_one.sh", "s"},
      {"scripts/build.sh", "b"}
    ])

    list =
      write_list(dir, [
        ["lib/", "source", "code"],
        ["lib/design/", "companion", "doc"],
        ["scripts/", "source", "build"],
        ["scripts/seed_*", "companion", "seed"]
      ])

    {companion, 0} = run(["--root", dir, "--list", list, "--paths", "companion"])

    assert String.split(companion, "\n", trim: true) |> Enum.sort() == [
             "lib/design/d.md",
             "scripts/seed_one.sh"
           ]

    {source, 0} = run(["--root", dir, "--list", list, "--paths", "source"])

    assert String.split(source, "\n", trim: true) |> Enum.sort() == [
             "lib/a.ex",
             "scripts/build.sh"
           ]
  end

  test "C6 counts and bytes per class are reported", %{tmp_dir: dir} do
    repo(dir, [{"a/x", String.duplicate("a", 2_097_152)}, {"b/y", "yy"}])

    list =
      write_list(dir, [
        ["a/", "source", "r1"],
        ["b/", "companion", "r2"],
        ["c/", "stays", "unused row"]
      ])

    {out, 0} = run(["--root", dir, "--list", list])
    assert out =~ ~r/source\s+1 files\s+2\.0 MB/
    assert out =~ ~r/companion\s+1 files\s+0\.0 MB/
    assert out =~ "(unused)"
  end

  test "C7 an unknown class or a short row is an error", %{tmp_dir: dir} do
    repo(dir, [{"a/x", "1"}])
    list = write_list(dir, [["a/", "bogus", "r"]])
    {out, code} = run(["--root", dir, "--list", list])
    assert code == 1
    assert out =~ "unknown class"

    list = write_list(dir, [["a/", "source"]])
    {out, code} = run(["--root", dir, "--list", list])
    assert code == 1
    assert out =~ "bad move list row"
  end

  test "C8 the run changes nothing in the tree or the repository", %{tmp_dir: dir} do
    repo(dir, [{"a/x", "1"}, {"b/y", "2"}])
    list = write_list(dir, [["a/", "source", "r1"], ["b/", "companion", "r2"]])
    before_files = snapshot(dir)
    before_head = git(dir, ["rev-parse", "HEAD"])
    before_status = git(dir, ["status", "--porcelain"])
    {_, 0} = run(["--root", dir, "--list", list])
    {_, 0} = run(["--root", dir, "--list", list, "--paths", "companion"])
    {_, 0} = run(["--recipe"])
    assert snapshot(dir) == before_files
    assert git(dir, ["rev-parse", "HEAD"]) == before_head
    assert git(dir, ["status", "--porcelain"]) == before_status
  end

  test "C9 the script has no network, history rewrite or delete command" do
    body = File.read!(@script)

    code =
      body
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.join("\n")

    refute code =~
             ~r/\b(curl|wget|rm|mv|cp|git\s+(-C\s+\S+\s+)?(push|fetch|clone|filter|commit|reset|checkout|rm|mv))\b/
  end

  test "C10 the recipe prints the diff -r proof for stage 1" do
    {out, 0} = run(["--recipe"])
    assert out =~ "diff -r"
    assert out =~ "--paths companion"
  end
end
