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
    assert run =~ "for attempt in 1 2 3 4 5 6 7 8 9 10; do"
    assert run =~ "sleep 6"
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
  end
end
