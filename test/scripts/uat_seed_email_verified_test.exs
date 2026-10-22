defmodule Letflow.Scripts.UatSeedEmailVerifiedTest do
  @moduledoc """
  GH #2503 / T-0179: `scripts/seed_uat_email_verified.sh` sets `emailVerified` on the seeded UAT
  test accounts through the Keycloak admin REST API, and only there.

  The script is run for real with a fake `curl` (`CURL` env, the same seam `uat_creds.sh` uses),
  so no network is touched. The fake records every request and answers the token and user
  calls from the environment. Needs bash (set `UAT_PF_BASH` to git-bash on Windows).
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/seed_uat_email_verified.sh", __DIR__)
  @qa_idp "https://auth.qa.bizdala.com"
  @admin_secret "s3cret-admin-value-do-not-print"

  defp launcher, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

  defp fake_curl(dir) do
    path = Path.join(dir, "fake_curl.sh")

    File.write!(path, ~S"""
    #!/usr/bin/env bash
    # Records the request (never the config from stdin) and answers from FAKE_* env.
    args="$*"
    echo "$args" >> "$FAKE_LOG"
    if [[ "$args" == *"/protocol/openid-connect/token"* ]]; then
      printf '%s' '{"access_token":"tok-value"}'
    elif [[ "$args" == *"-X PUT"* ]]; then
      cat "$(sed -n 's/.*-d @\([^ ]*\).*/\1/p' <<<"$args")" >> "$FAKE_LOG"
      printf '%s' 204
    else
      printf '%s' "[{\"id\":\"uid-1\",\"username\":\"candidate-user\",\"enabled\":true,\"emailVerified\":$FAKE_EV}]"
    fi
    """)

    "bash " <> path
  end

  defp run(dir, value, env) do
    log = Path.join(dir, "requests.log")

    base = [
      {"BPM_IDP_BASE_URL", @qa_idp},
      {"UAT_KC_ADMIN_CLIENT_ID", "uat-seed-admin"},
      {"UAT_KC_ADMIN_CLIENT_SECRET", @admin_secret},
      {"UAT_EMAIL_VERIFIED_USERS", "bilimbaga:candidate-user"},
      {"CURL", fake_curl(dir)},
      {"FAKE_LOG", log},
      {"FAKE_EV", "false"}
    ]

    env = Map.merge(Map.new(base), Map.new(env))

    {out, status} =
      System.cmd(launcher(), [@script | value], env: Map.to_list(env), stderr_to_stdout: true)

    requests = if File.exists?(log), do: File.read!(log), else: ""
    {out, status, requests}
  end

  @tag :tmp_dir
  test "refuses a realm outside the UAT allowlist before any request", %{tmp_dir: dir} do
    {out, status, requests} = run(dir, [], %{"UAT_EMAIL_VERIFIED_USERS" => "master:admin-user"})

    assert status != 0
    assert out =~ "not a UAT realm"
    assert requests == ""
  end

  test "refuses a non-QA identity provider before any request", %{tmp_dir: dir} do
    {out, status, requests} =
      run(dir, [], %{"BPM_IDP_BASE_URL" => "https://auth.bizdala.com"})

    assert status != 0
    assert out =~ "not the QA identity provider"
    assert requests == ""
  end

  test "refuses to run without the UAT admin client secret", %{tmp_dir: dir} do
    {out, status, requests} = run(dir, [], %{"UAT_KC_ADMIN_CLIENT_SECRET" => nil})

    assert status != 0
    assert out =~ "UAT_KC_ADMIN_CLIENT_SECRET"
    assert requests == ""
  end

  test "refuses an empty account list", %{tmp_dir: dir} do
    {out, status, requests} = run(dir, [], %{"UAT_EMAIL_VERIFIED_USERS" => nil})

    assert status != 0
    assert out =~ "UAT_EMAIL_VERIFIED_USERS"
    assert requests == ""
  end

  test "rejects a mode other than true or false", %{tmp_dir: dir} do
    {out, status, requests} = run(dir, ["maybe"], %{})

    assert status != 0
    assert out =~ "usage"
    assert requests == ""
  end

  test "sets emailVerified to true on the named account and never prints the secret", %{
    tmp_dir: dir
  } do
    {out, status, requests} = run(dir, [], %{"FAKE_EV" => "false"})

    assert status == 0, out
    assert out =~ "bilimbaga/candidate-user: emailVerified false -> true"
    refute out =~ @admin_secret
    refute requests =~ @admin_secret
    refute out =~ "tok-value"
    assert requests =~ "-X PUT"
    assert requests =~ ~s("emailVerified":true)
    assert requests =~ "/admin/realms/bilimbaga/users/uid-1"
  end

  test "is idempotent: an account already at the target value is not written again", %{
    tmp_dir: dir
  } do
    {out, status, requests} = run(dir, [], %{"FAKE_EV" => "true"})

    assert status == 0, out
    assert out =~ "bilimbaga/candidate-user: already emailVerified=true"
    refute requests =~ "-X PUT"
  end

  test "false mode is the rollback: it sets the account back to unverified", %{tmp_dir: dir} do
    {out, status, requests} = run(dir, ["false"], %{"FAKE_EV" => "true"})

    assert status == 0, out
    assert out =~ "bilimbaga/candidate-user: emailVerified true -> false"
    assert requests =~ ~s("emailVerified":false)
  end
end
