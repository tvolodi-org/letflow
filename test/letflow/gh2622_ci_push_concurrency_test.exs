defmodule Letflow.Gh2622CiPushConcurrencyTest do
  @moduledoc """
  GH #2622 (design `lib/letflow/design/gh2622-ci-push-concurrency-and-cd-tip.md` §1, §2, §6):

    * T1 single source: CI's path rules live only in `scripts/ci_changed_paths.sh`; `ci.yml` is
      the only file that invokes it; no workflow and not the CD decide script assigns a
      `*_PATHS_RE` or greps a `'^(` path literal; one assignment line per rule;
    * T2 the script itself, run with bash: empty, docs-only, backend, frontend, mobile, itself,
      a > 64 KiB list; always exit 0 and exactly three `key=true|false` lines;
    * T5 static `ci.yml`: the per-sha concurrency group for main pushes (verbatim), the
      unchanged cancel expression, no path-filter-outputs artifact, the caller contract of the
      "Compute changed paths" step, event fields through `env:`, required job names unchanged.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @ci_yml Path.join(@root, ".github/workflows/ci.yml")
  @cd_yml Path.join(@root, ".github/workflows/cd.yml")
  @rules_sh Path.join(@root, "scripts/ci_changed_paths.sh")
  @decide_sh Path.join(@root, "scripts/cd_qa_decide.sh")

  @group_expr "${{ github.workflow }}-${{ github.event.pull_request.number || (github.event_name == 'push' && format('{0}-{1}', github.ref, github.sha)) || github.ref }}"

  defp read(path), do: path |> File.read!() |> String.replace("\r\n", "\n")
  defp ci, do: YamlElixir.read_from_file!(@ci_yml)

  defp filter_step do
    ci()
    |> get_in(["jobs", "changes", "steps"])
    |> Enum.find(&(&1["id"] == "filter"))
  end

  # Runs the rules script with `list` on stdin (via a file, System.cmd has no stdin input),
  # through a driver script: quoted `bash -c` strings do not survive Windows argv intact.
  defp classify(dir, list, extra_args \\ []) do
    input = Path.join(dir, "changed-#{System.unique_integer([:positive])}.txt")
    File.write!(input, list)
    driver = Path.join(dir, "classify.sh")

    File.write!(
      driver,
      ~s|script="$1"; input="$2"; shift 2\nexec bash "$script" "$@" < "$input"\n|
    )

    System.cmd("bash", [driver, @rules_sh, input | extra_args], stderr_to_stdout: true)
  end

  defp lines(out), do: String.split(out, "\n", trim: true)

  # A line that RUNS the rules script: as a command word (line start, `$(`, `run:`) or as the
  # argument of bash/sh/source/exec/`.`. Comment lines are skipped; a plain mention (an echo
  # message, a doc reference) is not an invocation. Returns the matching lines, trimmed.
  @invocation ~r{(?:^\s*|\$\(\s*|\brun:\s+|(?:^|[\s;&|(])(?:bash|sh|source|exec|\.)\s+)(?:\./)?scripts/ci_changed_paths\.sh(?=\s|$|<|\))}

  defp invocations(src) do
    for line <- String.split(src, "\n"),
        not String.starts_with?(String.trim_leading(line), "#"),
        line =~ @invocation,
        do: String.trim(line)
  end

  describe "T1: one source for the path rules" do
    test "only ci.yml invokes scripts/ci_changed_paths.sh" do
      candidates =
        Path.wildcard(Path.join(@root, ".github/workflows/*.yml")) ++
          Path.wildcard(Path.join(@root, "scripts/**/*.sh")) ++
          Path.wildcard(Path.join(@root, "deploy/**/*.sh"))

      callers =
        for f <- candidates,
            f != @rules_sh,
            invocations(read(f)) != [],
            do: Path.relative_to(f, @root)

      assert callers == [".github/workflows/ci.yml"]

      assert invocations(read(@ci_yml)) == [
               ~s|RESULT=$(bash scripts/ci_changed_paths.sh <<<"$CHANGED") \|\| rc=$?|
             ]

      refute read(@cd_yml) =~ "ci_changed_paths"
    end

    test "the invocation matcher: run shapes match, mentions and comments do not" do
      for line <- [
            ~s|RESULT=$(bash scripts/ci_changed_paths.sh <<<"$CHANGED")|,
            "run: bash scripts/ci_changed_paths.sh",
            "  sh ./scripts/ci_changed_paths.sh < list.txt",
            "  scripts/ci_changed_paths.sh < list.txt",
            "  ./scripts/ci_changed_paths.sh",
            "  x=$(scripts/ci_changed_paths.sh <<<\"$y\")",
            "  source scripts/ci_changed_paths.sh",
            "  . scripts/ci_changed_paths.sh",
            "  exec bash scripts/ci_changed_paths.sh"
          ] do
        assert invocations(line) != [], "missed #{inspect(line)}"
      end

      for line <- [
            "  # the rules live in scripts/ci_changed_paths.sh (the one source)",
            ~s|  echo "::error::scripts/ci_changed_paths.sh exited $rc"|,
            ~s|  echo "Path rules (scripts/ci_changed_paths.sh):"|,
            "  - scripts/ci_changed_paths.sh is listed here"
          ] do
        assert invocations(line) == [], "matched #{inspect(line)}"
      end
    end

    test "no workflow and not the decide script defines or greps a path rule" do
      files = Path.wildcard(Path.join(@root, ".github/workflows/*.yml")) ++ [@decide_sh]

      for f <- files do
        src = read(f)
        refute src =~ ~r/_PATHS_RE=/, "#{f} assigns a *_PATHS_RE"
        refute src =~ ~r/grep\s+-[A-Za-z]*E[A-Za-z]*\s+'\^\(/, "#{f} greps a '^( path literal"
      end
    end

    test "the script has exactly one single-quoted assignment line per rule" do
      src = read(@rules_sh)

      for name <- ~w(BACKEND_PATHS_RE FRONTEND_PATHS_RE MOBILE_PATHS_RE) do
        assigns = Regex.scan(~r/^\s*#{name}=.*$/m, src)
        assert length(assigns) == 1, "#{name}: #{length(assigns)} assignment lines"
        assert src =~ ~r/^#{name}='\^\([^']+\)'$/m, "#{name} is not one single-quoted line"
      end

      assert src =~
               ~S{FRONTEND_PATHS_RE='^(web/|\.github/workflows/ci\.yml|scripts/ci_changed_paths\.sh$)'}

      assert src =~
               ~S{MOBILE_PATHS_RE='^(apps/mobile/|\.github/workflows/ci\.yml|scripts/ci_changed_paths\.sh$)'}
    end
  end

  describe "T2: scripts/ci_changed_paths.sh run with bash" do
    test "parses" do
      assert {_, 0} = System.cmd("bash", ["-n", @rules_sh])
    end

    test "classifies each class and always prints exactly three lines", %{tmp_dir: dir} do
      cases = [
        {"", "false", "false", "false"},
        {"README.md\nCLAUDE.md\n", "false", "false", "false"},
        {"lib/x.ex\n", "true", "false", "false"},
        {"web/a.tsx\n", "false", "true", "false"},
        {"apps/mobile/lib/x.dart\n", "false", "false", "true"},
        {"scripts/ci_changed_paths.sh\n", "true", "true", "true"},
        {".github/workflows/ci.yml\n", "true", "true", "true"},
        {"README.md\nlib/x.ex\nweb/a.tsx\n", "true", "true", "false"}
      ]

      for {list, b, f, m} <- cases do
        assert {out, 0} = classify(dir, list)

        assert lines(out) == ["backend=#{b}", "frontend=#{f}", "mobile=#{m}"],
               "input #{inspect(list)}: #{inspect(out)}"
      end
    end

    test "a > 64 KiB list (larger than a pipe buffer) is read in full", %{tmp_dir: dir} do
      filler = for i <- 1..3000, into: "", do: "docs/generated/some/long/path/file-#{i}.md\n"
      list = "lib/a.ex\n" <> filler <> "web/z.tsx\n"
      assert byte_size(list) > 65_536

      assert {out, 0} = classify(dir, list)
      assert lines(out) == ["backend=true", "frontend=true", "mobile=false"]
    end

    test "an argument is an error (non-zero, so the caller falls back to all gates)", %{
      tmp_dir: dir
    } do
      assert {out, status} = classify(dir, "lib/x.ex\n", ["extra"])
      assert status != 0
      assert out =~ "takes no arguments"
      refute out =~ "backend="
    end
  end

  describe "T5: static ci.yml" do
    test "per-sha concurrency group for main pushes; cancel-in-progress still pull_request only" do
      conc = ci()["concurrency"]
      assert conc["group"] == @group_expr
      assert conc["cancel-in-progress"] == "${{ github.event_name == 'pull_request' }}"
      assert read(@ci_yml) =~ "  group: " <> @group_expr <> "\n"
    end

    test "no path-filter-outputs artifact is written or uploaded" do
      src = read(@ci_yml)
      refute src =~ "path-filter-outputs"
      refute src =~ "upload-artifact"

      names = ci() |> get_in(["jobs", "changes", "steps"]) |> Enum.map(& &1["name"])
      refute "Upload path-filter outputs" in names
      refute "Write path-filter outputs for cd.yml" in names
    end

    test "Compute changed paths: event fields via env, output validated before $GITHUB_OUTPUT" do
      step = filter_step()
      assert step["continue-on-error"] == true

      assert step["env"] == %{
               "EVENT_NAME" => "${{ github.event_name }}",
               "PR_BASE_SHA" => "${{ github.event.pull_request.base.sha }}",
               "PR_HEAD_SHA" => "${{ github.event.pull_request.head.sha }}",
               "MG_BASE_SHA" => "${{ github.event.merge_group.base_sha }}",
               "MG_HEAD_SHA" => "${{ github.event.merge_group.head_sha }}"
             }

      run = step["run"]
      refute run =~ "${{"
      refute run =~ "_PATHS_RE"

      for needle <- [
            ~s|RESULT=$(bash scripts/ci_changed_paths.sh <<<"$CHANGED") \|\| rc=$?|,
            ~s|if [ "$rc" -ne 0 ]; then|,
            ~S{if [[ $line =~ ^(backend|frontend|mobile)=(true|false)$ ]]},
            ~s|if [ "$valid" -ne 3 ]; then|,
            ~s|printf '%s\\n' "$RESULT" >> "$GITHUB_OUTPUT"|
          ] do
        assert String.contains?(run, needle), "missing from the filter step: #{needle}"
      end

      # Validation happens before the single write to $GITHUB_OUTPUT of the script's result.
      {validate, _} = :binary.match(run, ~s|if [ "$valid" -ne 3 ]|)
      {write, _} = :binary.match(run, ~s|printf '%s\\n' "$RESULT" >> "$GITHUB_OUTPUT"|)
      assert validate < write

      # Every bad path exits 1 so the fail-safe step runs (continue-on-error above).
      assert length(Regex.scan(~r/^\s+exit 1$/m, run)) >= 3

      fallback =
        ci() |> get_in(["jobs", "changes", "steps"]) |> Enum.find(&(&1["id"] == "fallback"))

      assert fallback["if"] == "steps.filter.outcome != 'success'"
    end

    # The caller contract, executed: the validation block of the step, cut out of ci.yml and
    # run with bash, accepts exactly three well-formed lines with distinct keys.
    test "the step's output validation accepts only three well-formed distinct lines", %{
      tmp_dir: dir
    } do
      run = filter_step()["run"]
      [_, rest] = String.split(run, "# Exactly three lines", parts: 2)
      [block, _] = String.split(rest, ~s|echo "Path rules|, parts: 2)
      snippet = Path.join(dir, "validate.sh")
      File.write!(snippet, "#" <> block <> "echo VALID\n")

      # The value goes through a file and a driver script: multi-line or quoted argv entries
      # do not survive Windows hosts intact.
      driver = Path.join(dir, "driver.sh")
      File.write!(driver, ~s|RESULT=$(cat "$1")\nsource "$2"\n|)

      check = fn result ->
        input = "result-#{System.unique_integer([:positive])}.txt"
        File.write!(Path.join(dir, input), result)

        System.cmd("bash", [Path.basename(driver), input, Path.basename(snippet)],
          cd: dir,
          stderr_to_stdout: true
        )
      end

      assert {"VALID\n", 0} = check.("backend=true\nfrontend=false\nmobile=true")

      for bad <- [
            "",
            "backend=true\nfrontend=false",
            "backend=true\nbackend=false\nmobile=true",
            "backend=true\nfrontend=false\nmobile=true\nextra=1",
            "backend=yes\nfrontend=false\nmobile=true",
            "backend=true\nfrontend=false\nmobile=true\n::set-output",
            " backend=true\nfrontend=false\nmobile=true"
          ] do
        assert {out, 1} = check.(bad), "accepted #{inspect(bad)}"
        refute out =~ "VALID"
      end
    end

    test "job names (required-check contexts) are unchanged" do
      names = ci()["jobs"] |> Map.new(fn {k, v} -> {k, v["name"]} end)

      assert names == %{
               "changes" => "Detect changed paths",
               "backend_static" => "Backend static checks + isolated tails",
               "backend_shard" => "Backend shard ${{ matrix.shard }}/${{ strategy.job-total }}",
               "backend" => "Backend gate (mix letflow.check)",
               "frontend" => "Frontend gate (npm run check)",
               "mobile" => "Mobile gate (flutter analyze + test + build)"
             }
    end
  end
end
