defmodule Letflow.Scripts.UatSeedEmailVerifiedForGroupTest do
  @moduledoc """
  GH #2503 / T-0206: the acceptance seed step derives the realm:username pairs from the group's
  scenarios and runs `scripts/seed_uat_email_verified.sh` for them. Run for real with a fake
  `curl` (`CURL` env); no network. Needs bash (set `UAT_PF_BASH` to git-bash on Windows).
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @script Path.expand("../../scripts/seed_uat_email_verified_for_group.sh", __DIR__)
  @real_scenarios Path.expand("../fixtures/uat/scenarios/swiftroute", __DIR__)
  @qa_idp "https://auth.qa.bizdala.com"
  @admin_secret "s3cret-admin-value-do-not-print"

  defp launcher, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

  defp fake_curl(dir) do
    path = Path.join(dir, "fake_curl.sh")

    File.write!(path, ~S"""
    #!/usr/bin/env bash
    args="$*"
    echo "$args" >> "$FAKE_LOG"
    if [[ "$args" == *"/protocol/openid-connect/token"* ]]; then
      printf '%s' '{"access_token":"tok-value"}'
    elif [[ "$args" == *"-X PUT"* ]]; then
      printf '%s' 204
    else
      printf '%s' "[{\"id\":\"uid-1\",\"username\":\"candidate-user\",\"enabled\":true,\"emailVerified\":$FAKE_EV}]"
    fi
    """)

    "bash " <> path
  end

  defp scenarios(dir, pair_lines) do
    sdir = Path.join(dir, "scenarios")
    File.mkdir_p!(sdir)

    File.write!(Path.join(sdir, "a.yaml"), """
    description: >
      PRECONDITION: the accounts the seed must verify, as realm:username
      pairs (UAT_EMAIL_VERIFIED_USERS), are exactly:
    #{pair_lines}
      Phase 1 runs with that account UNVERIFIED.
    """)

    sdir
  end

  defp run(dir, sdir, env \\ %{}) do
    log = Path.join(dir, "requests.log")

    base = %{
      "BPM_IDP_BASE_URL" => @qa_idp,
      "UAT_KC_ADMIN_CLIENT_ID" => "uat-seed-admin",
      "UAT_KC_ADMIN_CLIENT_SECRET" => @admin_secret,
      "CURL" => fake_curl(dir),
      "FAKE_LOG" => log,
      "FAKE_EV" => "false"
    }

    {out, status} =
      System.cmd(launcher(), [@script, sdir],
        env: Map.to_list(Map.merge(base, env)),
        stderr_to_stdout: true
      )

    {out, status, if(File.exists?(log), do: File.read!(log), else: "")}
  end

  test "the swiftroute binding scenario names the pair the seed derives" do
    {out, 1} =
      System.cmd(launcher(), [@script, @real_scenarios],
        env: [{"UAT_KC_ADMIN_CLIENT_ID", ""}, {"UAT_KC_ADMIN_CLIENT_SECRET", ""}],
        stderr_to_stdout: true
      )

    # Absent credentials stop the step before the seed, after the pairs were found.
    assert out =~ "UAT_KC_ADMIN_CLIENT_ID and UAT_KC_ADMIN_CLIENT_SECRET"
  end

  test "seeds the pairs named by the scenario and never prints the secret", %{tmp_dir: dir} do
    sdir = scenarios(dir, "    bilimbaga:candidate-user")
    {out, status, requests} = run(dir, sdir)

    assert status == 0, out
    assert out =~ "for: bilimbaga:candidate-user"
    assert out =~ "bilimbaga/candidate-user: emailVerified false -> true"
    refute out =~ @admin_secret
    refute requests =~ @admin_secret
    assert requests =~ "-X PUT"
  end

  test "re-running is safe: an already verified account is not written again", %{tmp_dir: dir} do
    sdir = scenarios(dir, "    bilimbaga:candidate-user")
    {out, status, requests} = run(dir, sdir, %{"FAKE_EV" => "true"})

    assert status == 0, out
    assert out =~ "already emailVerified=true"
    refute requests =~ "-X PUT"
  end

  test "absent credentials fail the preparation with a clear message and no request", %{
    tmp_dir: dir
  } do
    sdir = scenarios(dir, "    bilimbaga:candidate-user")
    {out, status, requests} = run(dir, sdir, %{"UAT_KC_ADMIN_CLIENT_SECRET" => ""})

    assert status == 1
    assert out =~ "UAT_KC_ADMIN_CLIENT_ID and UAT_KC_ADMIN_CLIENT_SECRET"
    assert out =~ "preparation fails"
    assert requests == ""
  end

  test "a scenario naming a non-UAT realm is refused before any request", %{tmp_dir: dir} do
    sdir = scenarios(dir, "    master:admin-user")
    {out, status, requests} = run(dir, sdir)

    assert status != 0
    assert out =~ "not a UAT realm"
    assert requests == ""
  end

  test "a group whose scenarios name no accounts is a no-op", %{tmp_dir: dir} do
    sdir = Path.join(dir, "empty")
    File.mkdir_p!(sdir)
    File.write!(Path.join(sdir, "a.yaml"), "description: nothing here\n")
    {out, status, requests} = run(dir, sdir, %{"UAT_KC_ADMIN_CLIENT_SECRET" => ""})

    assert status == 0, out
    assert out =~ "no email_verified accounts"
    assert requests == ""
  end
end
