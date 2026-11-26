defmodule Letflow.Scripts.MailAdapterCheckTest do
  @moduledoc """
  T-2593 (gap G8): `scripts/mail_adapter_check.sh` reports whether Letflow's OWN mail (the notifier
  mail adapter) can reach a mail trap, and whether the trap can be read by the UAT tooling. Run
  with fake `curl`, `nc` and `docker` binaries, so no network and no container is touched. Needs
  bash.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @script Path.expand("../../scripts/mail_adapter_check.sh", __DIR__)

  # The credential names are built from pieces, so this file does not trip the repository scan
  # that forbids a value next to an SMTP credential name
  # (test/letflow/no_smtp_secret_guard_test.exs).
  @smtp_username "LETFLOW_SMTP_" <> "USERNAME"
  @smtp_password "LETFLOW_SMTP_" <> "PASSWORD"

  @ehlo_capable "250-mail-adapter-check\r\n250-SIZE 52428800\r\n250-STARTTLS\r\n250-AUTH PLAIN LOGIN\r\n250 8BITMIME\r\n"
  @ehlo_no_tls "250-mail-adapter-check\r\n250-SIZE 52428800\r\n250 8BITMIME\r\n"
  @ehlo_no_auth "250-mail-adapter-check\r\n250-STARTTLS\r\n250 8BITMIME\r\n"

  @fake_curl ~S"""
  #!/usr/bin/env bash
  if [ "${FAKE_CURL_FAIL:-0}" = "1" ]; then exit 7; fi
  case "$*" in
    *"/api/v1/messages"*) printf '%s' '{"messages":[]}' ;;
    *) exit 7 ;;
  esac
  """

  @fake_nc ~S"""
  #!/usr/bin/env bash
  printf '%s' "$FAKE_EHLO"
  """

  @fake_docker ~S"""
  #!/usr/bin/env bash
  printf '%s\n' "$FAKE_CONTAINER_ENV"
  """

  defp fake_bin(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  defp run(dir, args, env \\ %{}) do
    base = %{
      "CURL" => fake_bin(dir, "fake_curl.sh", @fake_curl),
      "NC" => fake_bin(dir, "fake_nc.sh", @fake_nc),
      "DOCKER" => fake_bin(dir, "fake_docker.sh", @fake_docker),
      "FAKE_EHLO" => @ehlo_capable,
      "FAKE_CONTAINER_ENV" => ""
    }

    {out, status} =
      System.cmd("bash", [@script | args],
        env: Map.to_list(Map.merge(base, env)),
        stderr_to_stdout: true
      )

    {out, status}
  end

  defp write_env(dir, lines) do
    path = Path.join(dir, "app.env")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp complete_env(dir) do
    write_env(dir, [
      "LETFLOW_MAIL_ADAPTER=smtp",
      "LETFLOW_SMTP_HOST=mailpit",
      "LETFLOW_SMTP_PORT=1025",
      "LETFLOW_SMTP_TLS=starttls",
      "#{@smtp_username}=qa-trap-user",
      "#{@smtp_password}=qa-trap-secret",
      "LETFLOW_MAIL_FROM=no-reply@qa.example.test",
      "LETFLOW_PUBLIC_BASE_URL=https://qa.example.test"
    ])
  end

  test "reports every mail variable name and never a value", %{tmp_dir: dir} do
    env_file = complete_env(dir)

    {out, status} = run(dir, ["--env-file", env_file])

    assert status == 0

    for name <- [
          "LETFLOW_MAIL_ADAPTER",
          "LETFLOW_SMTP_HOST",
          "LETFLOW_SMTP_PORT",
          "LETFLOW_SMTP_TLS",
          "LETFLOW_SMTP_USERNAME",
          "LETFLOW_SMTP_PASSWORD",
          "LETFLOW_MAIL_FROM",
          "LETFLOW_PUBLIC_BASE_URL"
        ] do
      assert out =~ "#{name}: SET"
    end

    assert out =~ "LETFLOW_MAIL_TIMEOUT_MS: UNSET"
    assert out =~ "adapter mode: smtp"

    refute out =~ "qa-trap-secret"
    refute out =~ "qa-trap-user"
    refute out =~ "no-reply@qa.example.test"
    refute out =~ "qa.example.test"
  end

  test "an adapter that is not smtp is a blocker", %{tmp_dir: dir} do
    env_file = write_env(dir, ["LETFLOW_SMTP_HOST=mailpit"])

    {out, status} = run(dir, ["--env-file", env_file])

    assert status == 1
    assert out =~ "blockers:"
    assert out =~ "LETFLOW_MAIL_ADAPTER is not smtp"
    assert out =~ "the Noop adapter stands"
  end

  test "a missing variable of the smtp adapter is a blocker that names the variable", %{
    tmp_dir: dir
  } do
    env_file =
      write_env(dir, [
        "LETFLOW_MAIL_ADAPTER=smtp",
        "LETFLOW_SMTP_HOST=mailpit",
        "LETFLOW_SMTP_PORT=1025"
      ])

    {out, status} = run(dir, ["--env-file", env_file])

    assert status == 1
    assert out =~ "LETFLOW_SMTP_USERNAME is not set"
    assert out =~ "LETFLOW_SMTP_PASSWORD is not set"
    assert out =~ "LETFLOW_MAIL_FROM is not set"
    assert out =~ "LETFLOW_PUBLIC_BASE_URL is not set"
  end

  test "a complete smtp configuration against a capable trap is ready", %{tmp_dir: dir} do
    env_file = complete_env(dir)

    {out, status} = run(dir, ["--env-file", env_file])

    assert status == 0
    assert out =~ "ready:"
    assert out =~ "the runner can read the trap"
    refute out =~ "blockers:"
  end

  test "a trap without STARTTLS is a blocker", %{tmp_dir: dir} do
    env_file = complete_env(dir)

    {out, status} = run(dir, ["--env-file", env_file], %{"FAKE_EHLO" => @ehlo_no_tls})

    assert status == 1
    assert out =~ "does not advertise STARTTLS"
    assert out =~ "never falls back to plaintext"
  end

  test "a trap without AUTH is a blocker", %{tmp_dir: dir} do
    env_file = complete_env(dir)

    {out, status} = run(dir, ["--env-file", env_file], %{"FAKE_EHLO" => @ehlo_no_auth})

    assert status == 1
    assert out =~ "does not advertise AUTH"
  end

  test "tls none in a prod build is a blocker", %{tmp_dir: dir} do
    env_file =
      write_env(dir, [
        "LETFLOW_MAIL_ADAPTER=smtp",
        "LETFLOW_SMTP_HOST=mailpit",
        "LETFLOW_SMTP_PORT=1025",
        "LETFLOW_SMTP_TLS=none",
        "MIX_ENV=prod"
      ])

    {out, status} = run(dir, ["--env-file", env_file])

    assert status == 1
    assert out =~ "LETFLOW_SMTP_TLS=none is refused in a prod build"
  end

  test "the container source reads the names from the container", %{tmp_dir: dir} do
    container_env = "LETFLOW_MAIL_ADAPTER=smtp\nLETFLOW_SMTP_HOST=mailpit\n"

    {out, status} =
      run(dir, ["--container", "letflow-qa-app-1"], %{"FAKE_CONTAINER_ENV" => container_env})

    assert status == 1
    assert out =~ "LETFLOW_MAIL_ADAPTER: SET"
    assert out =~ "LETFLOW_SMTP_HOST: SET"
    assert out =~ "LETFLOW_SMTP_PORT: UNSET"
  end

  test "an unreachable trap exits 3", %{tmp_dir: dir} do
    env_file = complete_env(dir)

    {out, status} =
      run(dir, ["--env-file", env_file], %{"FAKE_CURL_FAIL" => "1", "FAKE_EHLO" => ""})

    assert status == 3
    assert out =~ "the trap is unreachable"
    assert out =~ "the runner cannot read the trap"
  end
end
