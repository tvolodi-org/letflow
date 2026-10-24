defmodule Letflow.RiskTierTest do
  # Pure classify/path_allowed?/parse_raw tests: no git, no Repo.
  use ExUnit.Case, async: true

  alias Letflow.RiskTier

  # Paths of tracked files that BACKEND_PATHS_RE does not match are built with
  # Path.join, so the CiBackendPathFilterTest literal scan does not read them as inputs.
  defp orchestrator, do: Path.join(["docs", "agents", "ORCHESTRATOR.md"])
  defp git_merge, do: Path.join(["docs", "agents", "protocols", "GIT_MERGE.md"])
  defp merge_queue, do: Path.join(["docs", "merge-queue.md"])

  defp added(path), do: %{path: path, status: "A", old_mode: "000000", new_mode: "100644"}
  defp modified(path), do: %{path: path, status: "M", old_mode: "100644", new_mode: "100644"}

  defp short?(entries), do: RiskTier.classify(entries) == :short
  defp not_short?(entries), do: match?({:not_short, _}, RiskTier.classify(entries))

  describe "AL-1 allowed classes" do
    for path <- [
          "test/letflow/foo_test.exs",
          "test/specs/GH-1.md",
          "test/reports/r.yaml",
          "docs/x.md",
          "docs/frontend/y.md"
        ] do
      test "#{path} is short" do
        assert short?([added(unquote(path))])
      end
    end
  end

  describe "AL-2 non-allowed classes" do
    for path <- [
          "lib/letflow/a.ex",
          "priv/repo/migrations/1.exs",
          "config/a.exs",
          "scripts/a.sh",
          ".github/workflows/ci.yml",
          "web/a.ts",
          "apps/mobile/a.dart",
          "README.md",
          "CLAUDE.md",
          "docs/CLAUDE.md",
          ".claude/agents/x.md",
          "docs/agents/x.md",
          "docs/migration/decisions/0001-x.md",
          "docs/migration/x.md",
          "docs/runbooks/x.md",
          "docs/guides/x.md",
          "docs/roles.md",
          "docs/anti-patterns.md",
          "docs/frontend/x-ui-widget-vocabulary.md",
          "docs/requirements.yaml",
          "docs/issues/ISS-1.yaml",
          "docs/status/requirement_status.yaml",
          "test/fixtures/qa/a.yaml",
          "test/fixtures/uat/actors.yaml",
          "test/support/a.ex",
          "test/test_helper.exs",
          "test/shard_manifest.txt",
          "test/letflow/routers/identity_roles_guard_test.exs",
          "test/letflow/foo_leak_test.exs"
        ] do
      test "#{path} is not short" do
        refute RiskTier.path_allowed?(unquote(path))
        assert not_short?([added(unquote(path))])
      end
    end

    test "docs/merge-queue.md is not short" do
      refute RiskTier.path_allowed?(merge_queue())
    end
  end

  describe "AL-3 mixed and empty" do
    test "one allowed and one not allowed path" do
      assert not_short?([added("docs/x.md"), added("lib/a.ex")])
    end

    test "empty list" do
      assert {:not_short, "empty diff"} = RiskTier.classify([])
    end

    test "malformed input" do
      assert {:not_short, _} = RiskTier.classify(:nope)
      assert {:not_short, _} = RiskTier.classify([%{path: "docs/x.md"}])
    end
  end

  describe "AL-4 status and mode" do
    test "statuses other than A and M" do
      for status <- ~w(D R C T U X Q) do
        entry = %{path: "docs/x.md", status: status, old_mode: "100644", new_mode: "100644"}
        assert not_short?([entry]), "status #{status}"
      end
    end

    test "mode change, executable, symlink, submodule" do
      for {old, new, status} <- [
            {"100644", "100755", "M"},
            {"000000", "100755", "A"},
            {"000000", "120000", "A"},
            {"000000", "160000", "A"},
            {"100755", "100755", "M"}
          ] do
        entry = %{path: "docs/x.md", status: status, old_mode: old, new_mode: new}
        assert not_short?([entry]), "#{old} #{new} #{status}"
      end
    end
  end

  describe "AL-5 test files" do
    test "M of an existing test file is not short, A is" do
      assert not_short?([modified("test/letflow/foo_test.exs")])
      assert short?([added("test/letflow/foo_test.exs")])
    end

    test "M of a doc is short" do
      assert short?([modified("docs/x.md")])
    end
  end

  describe "AL-6 never allow-listed" do
    test "helper paths, governing files, stray copies" do
      for path <- [
            "lib/letflow/risk_tier.ex",
            "lib/mix/tasks/letflow.risk_tier.ex",
            "test/letflow/risk_tier/x_test.exs",
            "test/letflow/risk_tier/risk_tier_test.exs",
            "test/letflow/risk_tier_test.exs",
            orchestrator(),
            git_merge(),
            "mix.exs",
            "docs/ORCHESTRATOR.md",
            "docs/GIT_MERGE.md",
            "docs/x/Risk_Tier.md"
          ] do
        refute RiskTier.path_allowed?(path), path
        assert not_short?([added(path)]), path
      end
    end
  end

  describe "AL-7 odd characters" do
    test "space, quote, backslash, non-ASCII, dot segments, leading dash" do
      for path <- [
            "docs/a b.md",
            "docs/a\"b.md",
            "docs/a\\b.md",
            "docs/é.md",
            "docs/../lib/a.md",
            "docs//a.md",
            "docs/./a.md",
            "-docs/a.md"
          ] do
        refute RiskTier.path_allowed?(path), path
      end
    end
  end

  describe "D-1 drift against BACKEND_PATHS_RE" do
    test "docs entries of the CI backend regex are pinned and never short" do
      line =
        "scripts/ci_changed_paths.sh"
        |> File.read!()
        |> String.split(["\r\n", "\n"])
        |> Enum.find(&String.starts_with?(&1, "BACKEND_PATHS_RE="))

      docs =
        ~r{docs/[^|)]*}
        |> Regex.scan(line)
        |> List.flatten()
        |> Enum.map(&String.replace(&1, ["\\", "$"], ""))
        |> Enum.sort()

      assert docs == [
               "docs/agents/shared/HANDOFF_PROTOCOL.md",
               "docs/frontend/x-ui-widget-vocabulary.md",
               "docs/issues/[^/]+.yaml",
               "docs/migration/stage-7-simulation-uat-parity.md",
               "docs/requirements.yaml",
               "docs/roles.md",
               "docs/runbooks/",
               "docs/status/requirement_status[^/]*.yaml",
               "docs/status/work_board_cutover.yaml"
             ],
             "BACKEND_PATHS_RE gained a docs/ entry: decide whether the SHORT allow-list excludes it"

      for path <- [
            "docs/agents/shared/HANDOFF_PROTOCOL.md",
            "docs/frontend/x-ui-widget-vocabulary.md",
            "docs/issues/ISS-1.yaml",
            "docs/migration/stage-7-simulation-uat-parity.md",
            "docs/requirements.yaml",
            "docs/roles.md",
            "docs/runbooks/x.md",
            "docs/status/requirement_status.yaml",
            "docs/status/work_board_cutover.yaml"
          ] do
        refute RiskTier.path_allowed?(path), path
      end
    end
  end

  describe "P-1 parse_raw" do
    @sha String.duplicate("a", 40)
    @zero String.duplicate("0", 40)

    test "well-formed" do
      raw =
        ":000000 100644 #{@zero} #{@sha} A\0docs/x.md\0:100644 100644 #{@sha} #{@sha} M\0docs/y.md\0"

      assert {:ok, [%{path: "docs/x.md", status: "A"}, %{path: "docs/y.md", status: "M"}]} =
               RiskTier.parse_raw(raw)

      assert {:ok, []} = RiskTier.parse_raw("")
    end

    test "truncated, odd, bad meta and non-UTF-8 are errors" do
      assert :error = RiskTier.parse_raw(":000000 100644 #{@zero} #{@sha} A\0")
      assert :error = RiskTier.parse_raw(":000000 100644 #{@zero} #{@sha} A")
      assert :error = RiskTier.parse_raw("garbage\0docs/x.md\0")
      assert :error = RiskTier.parse_raw(":000000 100644 #{@zero} #{@sha} A\0docs/\xff.md\0")
      assert :error = RiskTier.parse_raw(nil)
    end
  end

  describe "git_env" do
    test "pins and unsets by name and by prefix" do
      env =
        RiskTier.git_env(%{
          "MIX_ENV" => "test",
          "ERL_FLAGS" => "x",
          "ELIXIR_ERL_OPTIONS" => "x",
          "HEX_HOME" => "x",
          "GIT_CONFIG_KEY_0" => "diff.renames",
          "GIT_CONFIG_VALUE_0" => "true",
          "PATH" => "/bin"
        })
        |> Map.new()

      assert env["GIT_NO_REPLACE_OBJECTS"] == "1"
      assert env["GIT_CONFIG_NOSYSTEM"] == "1"
      assert env["GIT_CONFIG_GLOBAL"] == "/dev/null"

      for name <-
            ~w(MIX_ENV ERL_FLAGS ELIXIR_ERL_OPTIONS HEX_HOME GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
               GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_EXTERNAL_DIFF GIT_DIFF_OPTS) do
        assert Map.fetch!(env, name) == nil, name
      end

      refute Map.has_key?(env, "PATH")
    end
  end

  describe "G-5 injected runner" do
    @sha40 String.duplicate("b", 40)

    defp runner(diff_result) do
      fn args, _env, _cd ->
        if "rev-parse" in args, do: {@sha40 <> "\n", 0}, else: diff_result
      end
    end

    test "garbage, non-zero exit, and a good diff" do
      assert {:not_short, "unreadable output"} = RiskTier.tier("a", "b", runner: runner({"x", 0}))
      assert {:not_short, _} = RiskTier.tier("a", "b", runner: runner({"", 1}))
      assert {:not_short, "empty diff"} = RiskTier.tier("a", "b", runner: runner({"", 0}))

      good = ":000000 100644 #{@zero} #{@sha} A\0docs/x.md\0"
      assert :short = RiskTier.tier("a", "b", runner: runner({good, 0}))
    end

    test "a raising runner is NOT-SHORT" do
      boom = fn _args, _env, _cd -> raise "boom" end
      assert {:not_short, "helper error: boom"} = RiskTier.tier("a", "b", runner: boom)
    end

    test "bad refs never reach git" do
      boom = fn _args, _env, _cd -> flunk("git must not run") end
      assert {:not_short, _} = RiskTier.tier("-x", "b", runner: boom)
      assert {:not_short, _} = RiskTier.tier("a", "b c", runner: boom)
      assert {:not_short, _} = RiskTier.tier("", "b", runner: boom)
    end
  end

  describe "U-1 and U-2 documentation" do
    test "moduledoc carries the usage note and says advisory" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Mix.Tasks.Letflow.RiskTier)

      for needle <-
            ~w(GIT_NO_REPLACE_OBJECTS=1 MIX ERL ELIXIR HEX advisory) ++ ["base (origin/main)"] do
        assert doc =~ needle, needle
      end

      refute doc =~ ~r/^\s*TIER: (HIGH|DIRECT)/m
    end

    test "REQ-522 and REQ-523 carry the R11 text and keep status and gh" do
      yaml = "docs/requirements.yaml" |> File.read!() |> String.replace("\r\n", "\n")

      for id <- ["REQ-522", "REQ-523"] do
        [_, rest] = String.split(yaml, "  - id: #{id}\n", parts: 2)
        [entry | _] = String.split(rest, ~r/\n  - id: /, parts: 2)

        assert entry =~ "R11"
        assert entry =~ "NOT-SHORT"
        assert entry =~ "status: pending"
        assert entry =~ "gh: 2875"
        refute entry =~ "TIER: DIRECT"
        refute entry =~ "FAILED CHECK"
      end
    end
  end
end

defmodule Letflow.RiskTierGitTest do
  # Real git in throwaway repos; hostile config set through the VM environment, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Letflow.RiskTier

  @moduletag :tmp_dir

  @identity ~w(-c user.name=t -c user.email=t@t.example -c commit.gpgsign=false)

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp commit_all(dir, msg) do
    git!(dir, ["add", "-A"])
    git!(dir, @identity ++ ["commit", "-q", "--allow-empty", "-m", msg])
  end

  defp put(dir, rel, content \\ "x\n") do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  # A repo with branch main (base files) and branch feature checked out.
  defp repo(tmp_dir) do
    dir = Path.join(tmp_dir, "r")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    put(dir, "base.txt")
    put(dir, "docs/old.md", "one\ntwo\n")
    put(dir, "docs/gone.md", "bye\n")
    put(dir, "test/letflow/old_test.exs", "assert true\nassert 1\n")
    put(dir, "lib/a.ex", "a\n")
    commit_all(dir, "base")
    git!(dir, ["checkout", "-q", "-b", "feature"])
    dir
  end

  defp run_task(dir, extra \\ []) do
    base = ["--base", "main", "--head", "feature", "--cd", dir] ++ extra

    capture_both(base)
  end

  defp capture_both(args) do
    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> Mix.Tasks.Letflow.RiskTier.run(args) end)
        send(self(), {:stdout, out})
      end)

    assert_received {:stdout, out}
    {out, err}
  end

  defp stdout(dir, extra \\ []), do: dir |> run_task(extra) |> elem(0)

  describe "G-1 / G-2 output line" do
    test "docs-only add is SHORT", %{tmp_dir: tmp} do
      dir = repo(tmp)
      put(dir, "docs/x.md")
      commit_all(dir, "c")
      assert :short = RiskTier.tier("main", "feature", cd: dir)
      assert {"TIER: SHORT\n", ""} = run_task(dir)
    end

    test "lib change is NOT-SHORT; stdout is one anchored line", %{tmp_dir: tmp} do
      dir = repo(tmp)
      put(dir, "lib/a.ex", "b\n")
      commit_all(dir, "c")
      {out, err} = run_task(dir)
      assert out =~ ~r/\A(TIER: (SHORT|NOT-SHORT))\n\z/
      assert out == "TIER: NOT-SHORT\n"
      assert err =~ "risk_tier:"

      for text <- [out, stdout(dir, ["--bogus"]), stdout(dir, ["stray"])] do
        refute text =~ "HIGH"
        refute text =~ "DIRECT"
      end
    end
  end

  describe "G-3 removals and modes" do
    test "delete of a doc", %{tmp_dir: tmp} do
      dir = repo(tmp)
      File.rm!(Path.join(dir, "docs/gone.md"))
      put(dir, "docs/x.md")
      commit_all(dir, "c")
      assert "TIER: NOT-SHORT\n" = stdout(dir)
    end

    test "rename of a doc", %{tmp_dir: tmp} do
      dir = repo(tmp)
      File.rename!(Path.join(dir, "docs/old.md"), Path.join(dir, "docs/new.md"))
      commit_all(dir, "c")
      assert "TIER: NOT-SHORT\n" = stdout(dir)
    end

    test "executable bit", %{tmp_dir: tmp} do
      dir = repo(tmp)
      git!(dir, ["update-index", "--chmod=+x", "docs/old.md"])
      commit_all(dir, "c")
      assert "TIER: NOT-SHORT\n" = stdout(dir)
    end

    test "symlink and submodule entries", %{tmp_dir: tmp} do
      dir = repo(tmp)
      sha = dir |> git!(["hash-object", "-w", "--no-filters", "base.txt"]) |> String.trim()
      git!(dir, ["update-index", "--add", "--cacheinfo", "120000,#{sha},docs/link.md"])
      commit_all(dir, "link")
      assert "TIER: NOT-SHORT\n" = stdout(dir)

      git!(dir, ["checkout", "-q", "-B", "feature", "main"])
      git!(dir, ["update-index", "--add", "--cacheinfo", "160000,#{sha},docs/sub"])
      commit_all(dir, "sub")
      assert "TIER: NOT-SHORT\n" = stdout(dir)
    end
  end

  describe "G-4 helper errors" do
    test "unknown ref, dash ref, unknown flag", %{tmp_dir: tmp} do
      dir = repo(tmp)
      put(dir, "docs/x.md")
      commit_all(dir, "c")

      assert "TIER: NOT-SHORT\n" = stdout_args(dir, ["--base", "nosuchref"])
      assert "TIER: NOT-SHORT\n" = stdout_args(dir, ["--base", "-x"])
      assert "TIER: NOT-SHORT\n" = stdout_args(dir, ["--nope"])
    end
  end

  defp stdout_args(dir, args) do
    args |> Kernel.++(["--cd", dir]) |> capture_both() |> elem(0)
  end

  describe "G-6 existing test files" do
    test "an added skip tag is NOT-SHORT", %{tmp_dir: tmp} do
      dir = repo(tmp)
      put(dir, "test/letflow/old_test.exs", "@tag :skip\nassert true\nassert 1\n")
      commit_all(dir, "c")
      assert "TIER: NOT-SHORT\n" = stdout(dir)
    end

    test "a deleted assertion is NOT-SHORT", %{tmp_dir: tmp} do
      dir = repo(tmp)
      put(dir, "test/letflow/old_test.exs", "assert true\n")
      commit_all(dir, "c")
      assert "TIER: NOT-SHORT\n" = stdout(dir)
    end

    test "a new test file is SHORT", %{tmp_dir: tmp} do
      dir = repo(tmp)
      put(dir, "test/letflow/new_test.exs")
      commit_all(dir, "c")
      assert "TIER: SHORT\n" = stdout(dir)
    end
  end

  describe "C-1 config" do
    @hostile [
      {"diff.renames", "true"},
      {"diff.ignoreSubmodules", "all"},
      {"submodule.sub.ignore", "all"},
      {"diff.external", "/nonexistent"},
      {"core.quotepath", "true"},
      {"diff.relative", "true"},
      {"diff.noprefix", "true"},
      {"color.diff", "always"},
      {"diff.orderfile", "/nonexistent"},
      {"core.fsmonitor", "/nonexistent"},
      {"diff.algorithm", "histogram"}
    ]

    defp hostile_env do
      [
        {"GIT_CONFIG_COUNT", "1"},
        {"GIT_CONFIG_KEY_0", "diff.renames"},
        {"GIT_CONFIG_VALUE_0", "true"},
        {"GIT_CONFIG_PARAMETERS", "'diff.algorithm'='patience'"}
      ]
    end

    defp make_hostile(dir, tmp) do
      for {k, v} <- @hostile, do: git!(dir, ["config", k, v])
      attrs = Path.join(tmp, "attrs")
      File.write!(attrs, "*.md binary\n")
      git!(dir, ["config", "core.attributesFile", attrs])
      File.mkdir_p!(Path.join(dir, ".git/info"))
      File.write!(Path.join(dir, ".git/info/attributes"), "*.md -diff\n")
      File.write!(Path.join(dir, ".gitattributes"), "*.md diff=evil\n")
      git!(dir, ["config", "diff.evil.textconv", "/nonexistent"])
    end

    defp with_env(pairs, fun) do
      old = for {k, _} <- pairs, do: {k, System.get_env(k)}
      Enum.each(pairs, fn {k, v} -> System.put_env(k, v) end)

      try do
        fun.()
      after
        Enum.each(old, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end
    end

    test "same output with hostile config", %{tmp_dir: tmp} do
      docs = repo(Path.join(tmp, "a") |> tap(&File.mkdir_p!/1))
      put(docs, "docs/x.md", "many\nlines\n")
      File.write!(Path.join(docs, "docs/old.md"), "one\ntwo\nthree\n")
      commit_all(docs, "c")

      renamed = repo(Path.join(tmp, "b") |> tap(&File.mkdir_p!/1))
      File.rename!(Path.join(renamed, "docs/old.md"), Path.join(renamed, "docs/new.md"))
      commit_all(renamed, "c")

      plain = for d <- [docs, renamed], do: run_task(d)
      assert [{"TIER: SHORT\n", ""}, {"TIER: NOT-SHORT\n", _}] = plain

      for d <- [docs, renamed], do: make_hostile(d, tmp)

      hostile = with_env(hostile_env(), fn -> for d <- [docs, renamed], do: run_task(d) end)
      assert hostile == plain
    end

    test "submodule under ignoreSubmodules", %{tmp_dir: tmp} do
      dir = repo(tmp)
      {sha, 0} = System.cmd("git", ["hash-object", "-w", "--no-filters", "base.txt"], cd: dir)
      git!(dir, ["update-index", "--add", "--cacheinfo", "160000,#{String.trim(sha)},sub"])
      commit_all(dir, "sub")
      make_hostile(dir, tmp)
      assert {"TIER: NOT-SHORT\n", _} = run_task(dir)
    end
  end

  describe "C-2 replace refs" do
    test "a replaced commit does not change the verdict", %{tmp_dir: tmp} do
      dir = repo(tmp)
      put(dir, "lib/a.ex", "changed\n")
      commit_all(dir, "lib change")
      real = git!(dir, ["rev-parse", "HEAD"]) |> String.trim()

      git!(dir, ["checkout", "-q", "-B", "other", "main"])
      put(dir, "docs/x.md")
      commit_all(dir, "docs only")
      fake = git!(dir, ["rev-parse", "HEAD"]) |> String.trim()
      git!(dir, ["replace", real, fake])
      git!(dir, ["checkout", "-q", "feature"])

      assert {:not_short, _} = RiskTier.tier("main", real, cd: dir)
    end
  end
end
