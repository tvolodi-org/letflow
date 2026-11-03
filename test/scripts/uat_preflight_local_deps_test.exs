defmodule Letflow.Scripts.UatPreflightLocalDepsTest do
  @moduledoc """
  ISS-0915 regression: `scripts/uat_preflight.sh`'s `local_deps` check must not report a
  false GAP when a spec file merely mentions "docker compose"/"docker exec"/"psql" as
  PROSE inside a quoted string literal (e.g. a `console.log(...)` message or an assertion
  string) -- that is not an executable invocation. ISS-0909(b) already fixed the sibling
  case of a prose mention inside a `/* */` or `//` comment; this covers the string-literal
  case RELEASE-VALIDATOR found while re-verifying that fix (PR #2051).

  The check must still GAP on a genuine invocation: either the literal keyword appearing
  in bare executable code (not inside a comment or string), or a call to db-exec.ts's
  `runSqlAgainstDevPostgres(...)` helper, which is call-expression syntax (never string
  content) and is therefore unaffected by the string-stripping fix.

  Shells out to the real script (no re-implementation of the regex), same harness shape as
  test/scripts/uat_preflight_bare_jwt_test.exs. Needs a real `bash`; on Windows set
  `UAT_PF_BASH` to git-bash.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @moduletag :tmp_dir

  @actor "actor-swiftroute-lena"
  @dead_url "http://127.0.0.1:9"

  defp launcher, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

  # Writes `spec_body` as the scenario's pipeline_test spec (absolute path, so it does not
  # need to live under the real repo tree), runs the real script against a no-op
  # qa-uat-env credential source (NO_PASSWORD; credentials are irrelevant to local_deps),
  # and returns the combined stdout/stderr.
  defp run_local_deps(tmp, scenario_id, spec_body) do
    scen_dir = Path.join(tmp, "scenarios/swiftroute")
    File.mkdir_p!(scen_dir)

    spec_path = Path.join(tmp, "#{scenario_id}.spec.ts")
    File.write!(spec_path, spec_body)

    File.write!(Path.join(scen_dir, "#{scenario_id}.yaml"), """
    id: #{scenario_id}
    company_id: swiftroute
    pipeline_test: #{spec_path}
    actors:
      dispatcher: #{@actor}
    """)

    cred = Path.join(tmp, "cred.sh")

    File.write!(cred, """
    #!/bin/bash
    if [ "$1" = "token" ]; then
      :
    fi
    """)

    out_json = Path.join(tmp, "out.json")

    args = [
      "scripts/uat_preflight.sh",
      "--base-url",
      @dead_url,
      "--environment",
      "qa",
      "--credential-source",
      cred,
      "--credential-protocol",
      "qa-uat-env",
      "--scenarios",
      Path.join(tmp, "scenarios"),
      "--sha",
      "deadbeef",
      "--idp-url",
      @dead_url,
      "--out",
      out_json
    ]

    {out, _status} = System.cmd(launcher(), args, stderr_to_stdout: true)

    assert out =~ "UAT PREFLIGHT  environment=qa",
           "preflight script did not reach its report (launcher=#{inspect(launcher())}). " <>
             "First 500 chars of output: #{String.slice(out, 0, 500)}. " <>
             "Set UAT_PF_BASH to a real bash (git-bash on Windows)."

    out
  end

  test "T1: a string literal mentioning 'docker compose' as prose does not GAP",
       %{tmp_dir: tmp} do
    out =
      run_local_deps(tmp, "prose-docker-compose", """
      test('does a thing', () => {
        console.log("this check runs without docker compose or psql, over HTTP only");
        expect(1).toBe(1);
      });
      """)

    refute out =~ "prose-docker-compose/local_deps"
  end

  test "T2: a string literal mentioning 'psql' as prose does not GAP", %{tmp_dir: tmp} do
    out =
      run_local_deps(tmp, "prose-psql", """
      test('does a thing', () => {
        throw new Error("fell back to psql manually during an earlier investigation");
      });
      """)

    refute out =~ "prose-psql/local_deps"
  end

  test "T3: a genuine runSqlAgainstDevPostgres(...) call still GAPs", %{tmp_dir: tmp} do
    out =
      run_local_deps(tmp, "genuine-helper-call", """
      import { runSqlAgainstDevPostgres } from '../db-exec';
      test('does a thing', async () => {
        await runSqlAgainstDevPostgres("update foo set bar = 1");
      });
      """)

    assert out =~ "[GAP] genuine-helper-call/local_deps:"
  end

  test "T4: a bare (unquoted, uncommented) literal mention still GAPs", %{tmp_dir: tmp} do
    out =
      run_local_deps(tmp, "genuine-bare-literal", """
      const cmd = docker compose;
      """)

    assert out =~ "[GAP] genuine-bare-literal/local_deps:"
  end

  test "T5: a header-comment prose mention still does not GAP (ISS-0909(b) regression guard)",
       %{tmp_dir: tmp} do
    out =
      run_local_deps(tmp, "prose-comment", """
      // verified manually against docker compose during local dev; runs over HTTP only
      test('does a thing', () => {
        expect(1).toBe(1);
      });
      """)

    refute out =~ "prose-comment/local_deps"
  end

  test "T6: a direct execSync(`psql ...`) template-literal invocation still GAPs " <>
         "(REVIEWER-found false negative in the first ISS-0915 attempt, which blanked " <>
         "ALL string/template-literal contents including the command actually executed)",
       %{tmp_dir: tmp} do
    out =
      run_local_deps(tmp, "genuine-execsync-psql-template", """
      import { execSync } from 'child_process'
      test('does a thing', () => {
        const dbUrl = process.env.BPM_TEST_DB_URL
        const id = '00000000-0000-0000-0000-000000000000'
        const sql = `INSERT INTO foo (a) VALUES ('${id}')`
        execSync(`psql "${dbUrl}" -c "${sql}"`, { stdio: 'pipe' })
      });
      """)

    assert out =~ "[GAP] genuine-execsync-psql-template/local_deps:"
  end

  test "T7: web/tests/e2e/env04.e2e.spec.ts's real execSync(`psql ...`) fixture helpers " <>
         "still GAP when run through local_deps directly against that file's actual content",
       %{tmp_dir: tmp} do
    real_spec =
      Path.join([File.cwd!(), "web/tests/e2e/env04.e2e.spec.ts"])

    body = File.read!(real_spec)

    out = run_local_deps(tmp, "real-env04-spec", body)

    assert out =~ "[GAP] real-env04-spec/local_deps:"
  end
end
