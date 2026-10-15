defmodule Letflow.Gh2622CdQaTipRuleTest do
  @moduledoc """
  GH #2622, T4 (design `lib/letflow/design/gh2622-ci-push-concurrency-and-cd-tip.md` §3, §5,
  §6): static checks on `.github/workflows/cd.yml`, which PR CI never runs (it only fires on a
  completed CI run on `main`), so a broken shape would silently stop CD.

    * `deploy` job `if:` has exactly the three clauses (success, push, same repository: the
      fork-branch-`main` hole, R5); `skip-log`'s `if:` is exactly `${{ !(` + that + `) }}`;
    * `cd-qa` concurrency on the job, never cancelling in progress; read-only permissions;
      `skip-log` has `permissions: {}`, no secrets, no concurrency, no checkout;
    * checkout of `main` with `persist-credentials: false`; step order; the decide step runs
      `scripts/cd_qa_decide.sh` and the deploy is gated on its output;
    * SSH step inputs byte-identical to before (same three secrets, same script);
    * no `${{ }}` inside any `run:`; no artifact download; no fork-controlled event field read;
    * the verify step fetches before it resolves the deployed sha and before its ancestry check;
    * the runbook exists and starts with the verbatim supersession line.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @cd_yml Path.join(@root, ".github/workflows/cd.yml")
  @runbook Path.join(@root, "docs/runbooks/qa-lag.md")

  @deploy_if "github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push' && github.event.workflow_run.head_repository.full_name == github.repository"

  defp src, do: @cd_yml |> File.read!() |> String.replace("\r\n", "\n")
  defp cd, do: YamlElixir.read_from_file!(@cd_yml)
  defp job(name), do: get_in(cd(), ["jobs", name])
  defp steps(name), do: job(name)["steps"]
  defp step(job, id), do: Enum.find(steps(job), &(&1["id"] == id))

  defp step_named(job, prefix),
    do: Enum.find(steps(job), &String.starts_with?(&1["name"] || "", prefix))

  test "trigger is unchanged: workflow_run of CI on main, completed" do
    assert cd()["on"] == %{
             "workflow_run" => %{
               "workflows" => ["CI"],
               "branches" => ["main"],
               "types" => ["completed"]
             }
           }

    assert Map.keys(cd()["jobs"]) |> Enum.sort() == ["deploy", "skip-log"]
    refute Map.has_key?(cd(), "concurrency")
  end

  test "deploy job if has the three clauses; skip-log if is its exact negation in ${{ }}" do
    assert job("deploy")["if"] == @deploy_if
    assert job("deploy")["name"] == "Deploy to QA"
    assert job("skip-log")["if"] == "${{ !(" <> @deploy_if <> ") }}"
    # The raw text too: a bare `!` would be a YAML tag, so the wrapper must be in the file.
    assert src() =~ "    if: ${{ !(" <> @deploy_if <> ") }}\n"
  end

  test "deploy: cd-qa concurrency on the job, read-only permissions, env via expressions" do
    d = job("deploy")
    assert d["concurrency"] == %{"group" => "cd-qa", "cancel-in-progress" => false}
    assert d["permissions"] == %{"contents" => "read", "actions" => "read"}

    assert d["env"] == %{
             "QA_URL" => "https://qa.bizdala.com",
             "RUN_SHA" => "${{ github.event.workflow_run.head_sha }}"
           }

    # GH_TOKEN is scoped to the one step that calls the GitHub API (least privilege:
    # the third-party SSH action must not receive it).
    steps = d["steps"]
    inputs = Enum.find(steps, &(&1["id"] == "inputs"))
    assert inputs["env"] == %{"GH_TOKEN" => "${{ github.token }}"}

    for step <- steps, step["id"] != "inputs" do
      refute Map.has_key?(step["env"] || %{}, "GH_TOKEN"), "GH_TOKEN leaked into #{step["name"]}"
    end
  end

  test "skip-log: no permissions, no secrets, no concurrency, no checkout, HEAD_REPO not printed" do
    s = job("skip-log")
    assert s["permissions"] == %{}
    refute Map.has_key?(s, "concurrency")

    assert s["env"] == %{
             "CONCLUSION" => "${{ github.event.workflow_run.conclusion }}",
             "EVENT" => "${{ github.event.workflow_run.event }}",
             "HEAD_REPO" => "${{ github.event.workflow_run.head_repository.full_name }}"
           }

    assert Enum.all?(s["steps"], &(not Map.has_key?(&1, "uses")))
    [%{"run" => run}] = s["steps"]
    refute inspect(s) =~ "secrets."
    assert run =~ ~s|if [ "$HEAD_REPO" = "$GITHUB_REPOSITORY" ]; then same_repo=true; fi|

    assert run =~
             ~s|printf '%s\\n' "cd-qa: skipped (conclusion=$CONCLUSION, event=$EVENT, same-repo=$same_repo)"|

    refute run =~ ~r/printf[^\n]*HEAD_REPO/
    refute run =~ ~r/echo[^\n]*HEAD_REPO/
  end

  test "deploy steps: checkout main without credentials, inputs, decide, SSH, verify, in order" do
    [checkout, inputs, decide, ssh, verify] = steps("deploy")

    assert checkout["uses"] == "actions/checkout@v4"

    assert checkout["with"] == %{
             "ref" => "main",
             "fetch-depth" => 0,
             "persist-credentials" => false
           }

    assert inputs["id"] == "inputs"
    assert decide["id"] == "decide"
    assert ssh["name"] == "Deploy to QA (ubuntu-16gb-nbg1-1)"
    assert verify["name"] =~ "Verify"

    assert ssh["if"] == "steps.decide.outputs.deploy == 'true'"
    assert verify["if"] == "steps.decide.outputs.deploy == 'true'"
  end

  test "inputs step: API tip, then fetch, then git tip, re-read once; health body to a file" do
    run = step("deploy", "inputs")["run"]
    {api, _} = :binary.match(run, ~s|gh api "repos/$GITHUB_REPOSITORY/commits/main" --jq .sha|)
    {fetch, _} = :binary.match(run, "git fetch --no-tags --quiet origin main")
    {git, _} = :binary.match(run, "git rev-parse --verify --quiet origin/main")
    assert api < fetch and fetch < git
    assert run =~ ~s|if [ "$TIP" != "$TIP_GIT" ]; then|

    assert run =~
             ~s|actions/workflows/ci.yml/runs?head_sha=$TIP&event=push&branch=main|

    assert run =~ "TIP_RUN=error"
    assert run =~ ~s|curl -sf -m 10 --max-filesize 65536 "$QA_URL/health" -o "$body"|
    # Only sanitised tokens reach $GITHUB_OUTPUT; the /health body never does.
    refute run =~ ~r/body[^\n]*GITHUB_OUTPUT/
    assert run =~ "safe() { if [[ $1 =~ ^[A-Za-z0-9_]{0,64}$ ]]"
  end

  test "decide step runs the script with env inputs and fails closed on bad output" do
    d = step("deploy", "decide")

    assert d["env"] == %{
             "TIP" => "${{ steps.inputs.outputs.tip }}",
             "TIP_GIT" => "${{ steps.inputs.outputs.tip_git }}",
             "TIP_RUN" => "${{ steps.inputs.outputs.tip_run }}"
           }

    run = d["run"]
    assert run =~ ~s|OUT=$(bash scripts/cd_qa_decide.sh) \|\| rc=$?|
    assert run =~ ~s|echo "cd-qa: decide error"|
    assert run =~ ~S{[[ ! $line1 =~ ^deploy=(true|false)$ ]]}
    assert run =~ ~s|printf '%s\\n' "$line1" >> "$GITHUB_OUTPUT"|
    # The red exit (3) is reported and fails the step before anything reaches $GITHUB_OUTPUT.
    {red, _} = :binary.match(run, ~s|if [ "$rc" -eq 3 ]; then|)
    {out, _} = :binary.match(run, ~s|"$line1" >> "$GITHUB_OUTPUT"|)
    assert red < out
  end

  test "SSH deploy inputs are byte-identical to before (same 3 secrets, same forced script)" do
    ssh = step_named("deploy", "Deploy to QA (")
    assert ssh["uses"] == "appleboy/ssh-action@v1"

    assert ssh["with"] == %{
             "host" => "${{ secrets.QA_DEPLOY_HOST }}",
             "username" => "${{ secrets.QA_DEPLOY_USER }}",
             "key" => "${{ secrets.QA_DEPLOY_SSH_KEY }}",
             "script" => "bash /opt/apps/letflow-qa/deploy/redeploy-qa.sh"
           }

    assert length(Regex.scan(~r/secrets\./, src())) == 3
  end

  test "verify step: fetch, then rev-parse of the deployed sha, then is-ancestor TIP Q" do
    v = step_named("deploy", "Verify")
    assert v["env"] == %{"TIP" => "${{ steps.inputs.outputs.tip }}"}
    run = v["run"]
    {fetch, _} = :binary.match(run, "git fetch --no-tags --quiet origin main")
    {resolve, _} = :binary.match(run, ~s|git rev-parse --verify --quiet "${q}^{commit}"|)
    {ancestor, _} = :binary.match(run, ~s|git merge-base --is-ancestor "$TIP" "$full"|)
    # The deployed sha must also be on main (a same-repo non-main branch descending from
    # TIP is refused): SECURITY-REVIEWER nit N2.
    {on_main, _} = :binary.match(run, ~s|git merge-base --is-ancestor "$full" origin/main|)
    assert fetch < resolve and resolve < ancestor and ancestor < on_main
    assert run =~ ~s|echo "cd-qa: verify failed, deployed sha $q is not on main"|
    assert run =~ ~s|echo "cd-qa: deployed $q"|
    assert run =~ ~s|echo "cd-qa: main moved during deploy (verified $TIP, deployed $q)"|
  end

  test "no ${{ }} inside any run:, no artifact download, no fork-controlled field read" do
    for {name, j} <- cd()["jobs"], s <- j["steps"], is_binary(s["run"]) do
      refute s["run"] =~ "${{", "#{name} / #{s["name"]}: expression inside run:"
    end

    text = src()
    refute text =~ "download-artifact"
    refute text =~ "path-filter-outputs.txt"
    refute text =~ "source "

    for field <- ~w(head_branch display_title head_commit) do
      refute text =~ "workflow_run.#{field}", "cd.yml reads workflow_run.#{field}"
    end
  end

  # ---------------------------------------------------------------------------------------
  # Executed steps (REVIEWER finding 1, R6): the `run:` of the verify step and of the decide
  # step are cut out of cd.yml and run with bash in a throwaway directory under
  # System.tmp_dir!/0. `curl`, `sleep` and (for decide) `scripts/cd_qa_decide.sh` are fakes;
  # `git` and `jq` are real. Paths reach bash through a driver script that builds them from
  # $PWD: Windows argv and env paths do not survive msys bash intact. The driver always sets
  # GITHUB_OUTPUT and GITHUB_STEP_SUMMARY to temp files, so a run on a real Actions runner
  # never writes the runner's own files.
  # ---------------------------------------------------------------------------------------

  @git_env [
    {"GIT_AUTHOR_NAME", "t"},
    {"GIT_AUTHOR_EMAIL", "t@example.invalid"},
    {"GIT_COMMITTER_NAME", "t"},
    {"GIT_COMMITTER_EMAIL", "t@example.invalid"},
    {"GIT_AUTHOR_DATE", "1700000000 +0000"},
    {"GIT_COMMITTER_DATE", "1700000000 +0000"},
    {"GIT_CONFIG_NOSYSTEM", "1"}
  ]

  @driver """
  set -u
  root=$PWD
  export PATH="$root/bin:$PATH"
  export GITHUB_OUTPUT="$root/github_output"
  export GITHUB_STEP_SUMMARY="$root/step_summary"
  export RUNNER_TEMP="$root"
  export FAKE_HEALTH="$root/health.json"
  export FAKE_CALLS="$root/calls.log"
  export FAKE_DECIDE_OUT="$root/decide.out"
  : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"; : > "$FAKE_CALLS"
  cd "$root/$1"
  bash "$root/step.sh"
  """

  # Fake curl: prints $FAKE_HEALTH when present, else fails like an unreachable host (7).
  @fake_curl """
  #!/bin/sh
  echo curl >> "$FAKE_CALLS"
  [ -f "$FAKE_HEALTH" ] || exit 7
  cat "$FAKE_HEALTH"
  """

  @fake_sleep """
  #!/bin/sh
  echo "sleep $*" >> "$FAKE_CALLS"
  """

  # Fake decide script: prints a canned output and exits with a canned status.
  @fake_decide """
  #!/bin/sh
  cat "$FAKE_DECIDE_OUT"
  exit "$FAKE_DECIDE_RC"
  """

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, env: @git_env, stderr_to_stdout: true)
    String.trim(out)
  end

  defp scratch_dir do
    dir = Path.join(System.tmp_dir!(), "gh2622-cd-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "bin"))
    on_exit(fn -> File.rm_rf(dir) end)
    File.write!(Path.join(dir, "driver.sh"), @driver)
    File.write!(Path.join(dir, "bin/curl"), @fake_curl)
    File.write!(Path.join(dir, "bin/sleep"), @fake_sleep)
    for f <- ~w(curl sleep), do: File.chmod!(Path.join(dir, "bin/#{f}"), 0o755)
    dir
  end

  # origin.git (bare): main A-B-C. repo: clone-like work repo, origin -> ../origin.git, local
  # main at C, plus a side commit D (child of B) that is not on main. TIP is B.
  defp verify_fixture do
    dir = scratch_dir()
    origin = Path.join(dir, "origin.git")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(origin)
    File.mkdir_p!(repo)
    git!(origin, ["init", "--quiet", "--bare", "--initial-branch=main"])
    git!(repo, ["init", "--quiet", "--initial-branch=main"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    git!(repo, ["remote", "add", "origin", "../origin.git"])

    shas =
      for name <- ~w(A B C), into: %{} do
        git!(repo, ["commit", "--quiet", "--allow-empty", "-m", name])
        {name, git!(repo, ["rev-parse", "HEAD"])}
      end

    git!(repo, ["push", "--quiet", "origin", "main"])
    git!(repo, ["checkout", "--quiet", "-b", "side", shas["B"]])
    git!(repo, ["commit", "--quiet", "--allow-empty", "-m", "D"])
    d = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", "--quiet", "main"])

    # Fixture preconditions: B is the tip being verified, C and D descend from it, only C is
    # on origin's main, A is a proper ancestor of B.
    assert git!(origin, ["rev-parse", "main"]) == shas["C"]
    refute d in [shas["A"], shas["B"], shas["C"]]

    File.write!(Path.join(dir, "step.sh"), step_named("deploy", "Verify")["run"])
    Map.merge(shas, %{"D" => d, "dir" => dir})
  end

  defp run_step(dir, subdir, env) do
    {out, status} =
      System.cmd("bash", ["driver.sh", subdir],
        cd: dir,
        env: @git_env ++ env,
        stderr_to_stdout: true
      )

    %{
      out: out,
      status: status,
      output: File.read!(Path.join(dir, "github_output")),
      summary: File.read!(Path.join(dir, "step_summary")),
      calls: dir |> Path.join("calls.log") |> File.read!() |> String.split("\n", trim: true)
    }
  end

  defp verify(f, health) do
    case health do
      nil -> File.rm_rf!(Path.join(f["dir"], "health.json"))
      body -> File.write!(Path.join(f["dir"], "health.json"), body)
    end

    run_step(f["dir"], "repo", [{"TIP", f["B"]}, {"QA_URL", "https://qa.example.invalid"}])
  end

  defp health(sha), do: ~s|{"status":"ok","sha":#{Jason.encode!(sha)}}|

  describe "verify step, executed" do
    setup do
      assert System.find_executable("bash"), "bash is required"
      assert System.find_executable("jq"), "jq is required (the verify step parses /health)"
      {:ok, f: verify_fixture()}
    end

    test "QA on the tip: green, logs cd-qa: deployed, no main-moved line", %{f: f} do
      for q <- [f["B"], binary_part(f["B"], 0, 7)] do
        r = verify(f, health(q))
        assert r.status == 0, r.out
        assert r.out =~ "cd-qa: deployed #{q}\n"
        assert r.summary =~ "cd-qa: deployed #{q}\n"
        refute r.out =~ "main moved"
        refute r.out =~ "verify failed"
        # First /health read succeeded: no retry, no sleep.
        assert r.calls == ["curl"]
      end
    end

    test "QA on a descendant of the tip that is on main: green, logs main moved", %{f: f} do
      r = verify(f, health(f["C"]))
      assert r.status == 0, r.out
      assert r.out =~ "cd-qa: deployed #{f["C"]}\n"
      assert r.out =~ "cd-qa: main moved during deploy (verified #{f["B"]}, deployed #{f["C"]})"
      assert r.summary =~ "cd-qa: main moved during deploy"
    end

    test "QA unreachable or with an empty/invalid sha: red after 10 attempts and 10 sleeps", %{
      f: f
    } do
      for body <- [nil, health(""), "not json", ~s|{"sha":null}|, health("XYZ"), "[1]"] do
        r = verify(f, body)
        assert r.status == 1, "body #{inspect(body)}: #{r.out}"
        assert r.out =~ "cd-qa: verify failed, QA /health sha unreadable after the deploy"
        refute r.out =~ "cd-qa: deployed"
        assert Enum.count(r.calls, &(&1 == "curl")) == 10, inspect(r.calls)
        assert Enum.count(r.calls, &String.starts_with?(&1, "sleep")) == 10
        assert Enum.all?(Enum.reject(r.calls, &(&1 == "curl")), &(&1 == "sleep 6"))
      end
    end

    test "QA on a hex sha the repo does not know: red, unresolvable", %{f: f} do
      r = verify(f, health("0000000deadbeef"))
      assert r.status == 1
      assert r.out =~ "cd-qa: verify failed, deployed sha 0000000deadbeef unresolvable"
      refute r.out =~ "cd-qa: deployed"
    end

    test "QA on a non-descendant of the tip (an ancestor): red", %{f: f} do
      r = verify(f, health(f["A"]))
      assert r.status == 1

      assert r.out =~
               "cd-qa: verify failed, deployed sha #{f["A"]} is not tip #{f["B"]} or a descendant"

      refute r.out =~ "cd-qa: deployed"
      assert r.summary == ""
    end

    test "QA on a descendant of the tip that is not on main: red", %{f: f} do
      r = verify(f, health(f["D"]))
      assert r.status == 1, r.out
      assert r.out =~ "cd-qa: verify failed, deployed sha #{f["D"]} is not on main"
      refute r.out =~ "cd-qa: deployed"
      assert r.summary == ""
    end

    test "git fetch origin main failing: red", %{f: f} do
      git!(Path.join(f["dir"], "repo"), ["remote", "set-url", "origin", "../missing.git"])
      r = verify(f, health(f["B"]))
      assert r.status == 1
      assert r.out =~ "cd-qa: verify failed, git fetch origin main failed"
    end
  end

  defp decide_fixture do
    dir = scratch_dir()
    work = Path.join(dir, "work")
    File.mkdir_p!(Path.join(work, "scripts"))
    File.write!(Path.join(work, "scripts/cd_qa_decide.sh"), @fake_decide)
    File.write!(Path.join(dir, "step.sh"), step("deploy", "decide")["run"])
    dir
  end

  defp decide(dir, out, rc) do
    File.write!(Path.join(dir, "decide.out"), out)
    run_step(dir, "work", [{"FAKE_DECIDE_RC", Integer.to_string(rc)}])
  end

  describe "decide step wrapper, executed" do
    setup do
      assert System.find_executable("bash"), "bash is required"
      {:ok, dir: decide_fixture()}
    end

    test "exit 0 with two valid lines: reason logged, deploy= written to GITHUB_OUTPUT", %{
      dir: dir
    } do
      for deploy <- ~w(true false) do
        r = decide(dir, "deploy=#{deploy}\nreason=cd-qa: QA sha #{deploy} behind tip abc\n", 0)
        assert r.status == 0, r.out
        assert r.out == "cd-qa: QA sha #{deploy} behind tip abc\n"
        assert r.summary == "cd-qa: QA sha #{deploy} behind tip abc\n"
        assert r.output == "deploy=#{deploy}\n"
      end
    end

    test "exit 3 with deploy=false: red, reason logged, nothing written to GITHUB_OUTPUT", %{
      dir: dir
    } do
      r = decide(dir, "deploy=false\nreason=cd-qa: tip unreadable\n", 3)
      assert r.status == 1
      assert r.out == "cd-qa: tip unreadable\n"
      assert r.summary == "cd-qa: tip unreadable\n"
      assert r.output == ""
    end

    test "exit 3 with deploy=true fails closed: decide error, nothing written", %{dir: dir} do
      r = decide(dir, "deploy=true\nreason=cd-qa: tip unreadable\n", 3)
      assert r.status == 1
      assert r.out == "cd-qa: decide error\n"
      assert r.summary == "cd-qa: decide error\n"
      assert r.output == ""
    end

    test "malformed output or an unexpected exit: decide error, red, nothing written", %{
      dir: dir
    } do
      good = "deploy=true\nreason=cd-qa: behind tip\n"

      cases = [
        {"", 0},
        {"deploy=true\n", 0},
        {"deploy=yes\nreason=cd-qa: behind tip\n", 0},
        {"deploy=true\nreason=behind tip\n", 0},
        {"deploy=true\nreason=cd-qa: \n", 0},
        {"deploy=true\nreason=cd-qa: behind\ttip\n", 0},
        {"reason=cd-qa: behind tip\ndeploy=true\n", 0},
        {good <> "deploy=true\n", 0},
        {" deploy=true\nreason=cd-qa: behind tip\n", 0},
        {good, 1},
        {good, 2}
      ]

      for {out, rc} <- cases do
        r = decide(dir, out, rc)
        assert r.status == 1, "accepted #{inspect(out)} rc #{rc}: #{r.out}"
        assert r.out == "cd-qa: decide error\n", "#{inspect(out)} rc #{rc}: #{inspect(r.out)}"
        assert r.output == "", "#{inspect(out)} rc #{rc} wrote #{inspect(r.output)}"
      end
    end
  end

  test "runbook exists and starts with the verbatim supersession line" do
    text = File.read!(@runbook) |> String.replace("\r\n", "\n")
    [first | _] = String.split(text, "\n")

    assert first ==
             "REQ-367's CD path gate is superseded: CD deploys the tested main tip whenever QA differs"

    assert text =~ "# QA lag: cancel vs failure"
    assert text =~ "exceeded the maximum execution time"
    assert text =~ "conclusion is `cancelled`"
    assert text =~ "gh run list --workflow CI --event merge_group"
    assert text =~ "OQ-1"

    # R6 ruling: the main-moved line is a normal race, green; red only if unreachable or not a
    # descendant. Whitespace is normalised because the sentence wraps across lines.
    flat = String.replace(text, ~r/\s+/, " ")
    assert flat =~ "`cd-qa: main moved during deploy (verified Y, deployed Z)`"
    assert flat =~ "That line is a normal race, not a failure"
    assert flat =~ "the step stays green"

    assert flat =~
             "it goes red only if QA is unreachable or NOT on a descendant of the checked tip"
  end

  # Nit: the `inputs` step's tip-run jq mapping, executed with real jq over canned run lists.
  test "inputs step: the tip-run jq filter maps a run list to one word" do
    assert System.find_executable("jq"), "jq is required"
    run = step("deploy", "inputs")["run"]
    [_, filter] = Regex.run(~r/ci\.yml\/runs\?[^\n]*\n\s*--jq '([^']+)'/, run)
    dir = scratch_dir()
    File.write!(Path.join(dir, "filter.jq"), filter)

    map = fn runs ->
      File.write!(Path.join(dir, "runs.json"), Jason.encode!(%{"workflow_runs" => runs}))

      {out, 0} =
        System.cmd("jq", ["-r", "-f", "filter.jq", "runs.json"], cd: dir, stderr_to_stdout: true)

      String.trim_trailing(out)
    end

    run_of = fn status, conclusion, at ->
      %{"status" => status, "conclusion" => conclusion, "created_at" => at}
    end

    t1 = "2026-10-15T10:00:00Z"
    t2 = "2026-10-15T11:00:00Z"

    assert map.([]) == "none"
    assert map.([run_of.("completed", "success", t1)]) == "success"
    assert map.([run_of.("completed", "cancelled", t1)]) == "cancelled"
    assert map.([run_of.("completed", "failure", t1)]) == "failure"
    assert map.([run_of.("completed", nil, t1)]) == "none"
    assert map.([run_of.("in_progress", nil, t1)]) == "in_progress"
    # The latest run (by created_at) wins, whatever the list order.
    assert map.([run_of.("completed", "success", t2), run_of.("completed", "failure", t1)]) ==
             "success"

    assert map.([run_of.("queued", nil, t2), run_of.("completed", "success", t1)]) == "queued"
  end
end
