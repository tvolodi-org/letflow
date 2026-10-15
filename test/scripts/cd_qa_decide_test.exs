defmodule Letflow.Scripts.CdQaDecideTest do
  @moduledoc """
  GH #2622, T3 (design `lib/letflow/design/gh2622-ci-push-concurrency-and-cd-tip.md` §3 table):
  `scripts/cd_qa_decide.sh`, the CD (QA) tip-rule decision, run with bash against a throwaway
  git repository (no network, no GitHub, no QA host).

  Fixture repository: a linear `main` A-B-C (tip C), an unrelated root commit R, and two commits
  whose shas share a 7-hex prefix (found by hashing candidates in-process, written with
  `git hash-object`), so a 7-hex QA sha can be genuinely ambiguous.

  Every row 1-9 is asserted on exit status, `deploy=`, and the reason text; rows 1-4 are also
  run with a QA sha that WOULD deploy, proving the tip/run checks win over the health signal.
  A junk `/health` body is never echoed.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/cd_qa_decide.sh")

  @junk "JUNK-<script>alert(1)</script>-MARKER"

  @git_env [
    {"GIT_AUTHOR_NAME", "t"},
    {"GIT_AUTHOR_EMAIL", "t@example.invalid"},
    {"GIT_COMMITTER_NAME", "t"},
    {"GIT_COMMITTER_EMAIL", "t@example.invalid"},
    {"GIT_AUTHOR_DATE", "1700000000 +0000"},
    {"GIT_COMMITTER_DATE", "1700000000 +0000"},
    {"GIT_CONFIG_NOSYSTEM", "1"}
  ]

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, env: @git_env, stderr_to_stdout: true)
    String.trim(out)
  end

  @empty_tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  defp commit_body(n) do
    "tree #{@empty_tree}\nauthor t <t@example.invalid> 1700000000 +0000\n" <>
      "committer t <t@example.invalid> 1700000000 +0000\n\ncollide #{n}\n"
  end

  defp object_sha(body),
    do: :crypto.hash(:sha, "commit #{byte_size(body)}\0" <> body) |> Base.encode16(case: :lower)

  # Two commit bodies whose shas share the first 7 hex digits (birthday search, ~2^14 tries).
  defp colliding_pair do
    Enum.reduce_while(0..5_000_000, %{}, fn n, seen ->
      sha = object_sha(commit_body(n))
      prefix = binary_part(sha, 0, 7)

      case seen do
        %{^prefix => m} -> {:halt, {prefix, m, n}}
        _ -> {:cont, Map.put(seen, prefix, n)}
      end
    end)
  end

  defp setup_repo(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet", "--initial-branch=main"])
    git!(repo, ["config", "commit.gpgsign", "false"])

    shas =
      for name <- ~w(A B C), into: %{} do
        git!(repo, ["commit", "--quiet", "--allow-empty", "-m", name])
        {name, git!(repo, ["rev-parse", "HEAD"])}
      end

    git!(repo, ["checkout", "--quiet", "--orphan", "unrelated"])
    git!(repo, ["commit", "--quiet", "--allow-empty", "-m", "R"])
    r = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", "--quiet", "main"])

    {prefix, m, n} = colliding_pair()

    for k <- [m, n] do
      file = Path.join(dir, "commit-#{k}.txt")
      File.write!(file, commit_body(k))
      written = git!(repo, ["hash-object", "--no-filters", "-t", "commit", "-w", file])
      assert written == object_sha(commit_body(k))
    end

    Map.merge(shas, %{"R" => r, "repo" => repo, "ambiguous" => prefix})
  end

  defp decide(repo, env) do
    base = %{"RUN_SHA" => "", "TIP" => "", "TIP_GIT" => "", "TIP_RUN" => "", "QA_HEALTH" => ""}
    env = base |> Map.merge(Map.new(env, fn {k, v} -> {to_string(k), v} end)) |> Enum.to_list()
    {out, status} = System.cmd("bash", [@script], cd: repo, env: env)
    {out, status}
  end

  defp health(sha), do: ~s|{"status":"ok","sha":#{Jason.encode!(sha)}}|

  defp assert_decision({out, status}, exp_status, exp_deploy, exp_reason) do
    assert status == exp_status, "status #{status}, output #{inspect(out)}"

    assert out == "deploy=#{exp_deploy}\nreason=cd-qa: #{exp_reason}\n",
           "got #{inspect(out)}"

    refute out =~ "JUNK"
  end

  setup %{tmp_dir: dir} do
    assert System.find_executable("bash"), "bash is required"
    assert System.find_executable("jq"), "jq is required (scripts/cd_qa_decide.sh parses /health)"
    {:ok, f: setup_repo(dir)}
  end

  test "the script parses" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "row 1: run sha not 40 lowercase hex -> red, even with a deployable QA sha", %{f: f} do
    for bad <- ["", "abc", String.upcase(f["C"]), f["C"] <> "0", @junk] do
      decide(f["repo"],
        RUN_SHA: bad,
        TIP: f["C"],
        TIP_GIT: f["C"],
        QA_HEALTH: health(f["A"])
      )
      |> assert_decision(3, false, "invalid run sha")
    end
  end

  test "row 2: tip unreadable or unstable -> red", %{f: f} do
    c = f["C"]

    for {tip, tip_git} <- [{"", c}, {"zz", c}, {c, ""}, {@junk, @junk}] do
      decide(f["repo"], RUN_SHA: c, TIP: tip, TIP_GIT: tip_git, QA_HEALTH: health(f["A"]))
      |> assert_decision(3, false, "tip unreadable")
    end

    decide(f["repo"], RUN_SHA: c, TIP: c, TIP_GIT: f["B"], QA_HEALTH: health(f["A"]))
    |> assert_decision(3, false, "tip unstable (api #{c}, git #{f["B"]})")
  end

  test "row 3: run is not the tip and the tip's run is unreadable -> red", %{f: f} do
    decide(f["repo"],
      RUN_SHA: f["B"],
      TIP: f["C"],
      TIP_GIT: f["C"],
      TIP_RUN: "error",
      QA_HEALTH: health(f["A"])
    )
    |> assert_decision(3, false, "tip run unreadable (tip #{f["C"]})")
  end

  # R3: rows 3-4 apply only when the run is NOT the tip. When the run that fired CD IS the tip,
  # its own success is the green signal and TIP_RUN is never looked up (the inputs step leaves
  # it empty), so even TIP_RUN=error (or any non-green word) must not block the deploy.
  test "rows 3-4 do not apply when the run IS the tip: TIP_RUN=error still deploys", %{f: f} do
    c = f["C"]

    for tip_run <- ["error", "", "failure", "in_progress", @junk] do
      decide(f["repo"],
        RUN_SHA: c,
        TIP: c,
        TIP_GIT: c,
        TIP_RUN: tip_run,
        QA_HEALTH: health(f["A"])
      )
      |> assert_decision(0, true, "QA sha #{f["A"]} behind tip #{c}, deploying tip")
    end
  end

  test "row 4: run is not the tip and the tip's run is not green -> skip", %{f: f} do
    for {tip_run, word} <- [
          {"in_progress", "in_progress"},
          {"queued", "queued"},
          {"failure", "failure"},
          {"cancelled", "cancelled"},
          {"timed_out", "timed_out"},
          {"none", "none"},
          {"", "other"},
          {@junk, "other"}
        ] do
      decide(f["repo"],
        RUN_SHA: f["B"],
        TIP: f["C"],
        TIP_GIT: f["C"],
        TIP_RUN: tip_run,
        QA_HEALTH: health(f["A"])
      )
      |> assert_decision(
        0,
        false,
        "not tip (run sha #{f["B"]}, tip #{f["C"]}); tip run #{word}"
      )
    end
  end

  test "row 4 passes through when the tip's own run is green: an older run deploys the tip",
       %{f: f} do
    decide(f["repo"],
      RUN_SHA: f["B"],
      TIP: f["C"],
      TIP_GIT: f["C"],
      TIP_RUN: "success",
      QA_HEALTH: health(f["A"])
    )
    |> assert_decision(0, true, "QA sha #{f["A"]} behind tip #{f["C"]}, deploying tip")
  end

  test "row 5: QA sha unknown -> deploy the tip; junk is never echoed", %{f: f} do
    c = f["C"]

    cases = [
      {"", "unreachable"},
      {@junk, "not-json"},
      {"[]", "not-json"},
      {~s|"#{c}"|, "not-json"},
      {"{} {}", "not-json"},
      {~s|{"status":"ok","sha":null}|, "null"},
      {~s|{"status":"ok"}|, "null"},
      {health(@junk), "not-hex"},
      {health(String.upcase(c)), "not-hex"},
      {health("abc12"), "not-hex"},
      {health(c <> "\n" <> @junk), "not-hex"},
      {~s|{"status":"ok","sha":123}|, "not-hex"}
    ]

    for {body, why} <- cases do
      decide(f["repo"], RUN_SHA: c, TIP: c, TIP_GIT: c, QA_HEALTH: body)
      |> assert_decision(0, true, "QA sha unknown (#{why}), deploying tip #{c}")
    end
  end

  test "row 6: QA sha unknown to the repository, or ambiguous -> deploy the tip", %{f: f} do
    c = f["C"]
    repo = f["repo"]

    # Preconditions: the unknown sha really does not resolve; the ambiguous prefix is ambiguous.
    assert {_, s1} =
             System.cmd("git", ["rev-parse", "--verify", "--quiet", "1234567^{commit}"], cd: repo)

    assert s1 != 0
    amb = f["ambiguous"]

    assert {_, s2} =
             System.cmd("git", ["rev-parse", "--verify", "--quiet", "#{amb}^{commit}"], cd: repo)

    assert s2 != 0

    for q <- ["1234567", String.duplicate("0", 40), amb] do
      decide(repo, RUN_SHA: c, TIP: c, TIP_GIT: c, QA_HEALTH: health(q))
      |> assert_decision(0, true, "QA sha #{q} unresolvable, deploying tip #{c}")
    end
  end

  test "row 7: QA already at the tip (full or short sha) -> skip", %{f: f} do
    c = f["C"]

    for q <- [c, binary_part(c, 0, 7), binary_part(c, 0, 12)] do
      decide(f["repo"], RUN_SHA: c, TIP: c, TIP_GIT: c, QA_HEALTH: health(q))
      |> assert_decision(0, false, "QA already at tip #{c}")
    end
  end

  test "row 8: QA sha not an ancestor of the tip -> deploy the tip", %{f: f} do
    c = f["C"]
    r = f["R"]

    for q <- [r, binary_part(r, 0, 9)] do
      decide(f["repo"], RUN_SHA: c, TIP: c, TIP_GIT: c, QA_HEALTH: health(q))
      |> assert_decision(0, true, "QA sha #{q} not an ancestor of tip #{c}, deploying tip")
    end

    # A QA build AHEAD of the verified tip is not an ancestor either: deploy (main's tip wins).
    decide(f["repo"], RUN_SHA: f["B"], TIP: f["B"], TIP_GIT: f["B"], QA_HEALTH: health(c))
    |> assert_decision(0, true, "QA sha #{c} not an ancestor of tip #{f["B"]}, deploying tip")
  end

  test "row 9: QA behind the tip -> deploy the tip", %{f: f} do
    c = f["C"]

    for q <- [f["A"], f["B"], binary_part(f["A"], 0, 7)] do
      decide(f["repo"], RUN_SHA: c, TIP: c, TIP_GIT: c, QA_HEALTH: health(q))
      |> assert_decision(0, true, "QA sha #{q} behind tip #{c}, deploying tip")
    end
  end

  test "script errors are neither 0 nor 3 (the caller reports `cd-qa: decide error`)", %{f: f} do
    c = f["C"]
    env = [RUN_SHA: c, TIP: c, TIP_GIT: c, QA_HEALTH: health(f["A"])]

    {_out, status} =
      System.cmd("bash", [@script, "unexpected-arg"],
        cd: f["repo"],
        env: Enum.map(env, fn {k, v} -> {Atom.to_string(k), v} end),
        stderr_to_stdout: true
      )

    assert status not in [0, 3]

    {out, status} =
      System.cmd("bash", [@script],
        cd: f["repo"],
        env:
          [{"GIT_DIR", Path.join(f["repo"], "no-such-git-dir")}] ++
            Enum.map(env, fn {k, v} -> {Atom.to_string(k), v} end),
        stderr_to_stdout: true
      )

    assert status not in [0, 3], "outside a repository: #{inspect(out)}"
    refute out =~ "deploy=true"
  end
end
