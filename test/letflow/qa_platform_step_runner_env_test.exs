defmodule Letflow.QaPlatformStepRunnerEnvTest do
  @moduledoc """
  T-2707: the QA deploy gate for the platform step runner (T-2703).

  The platform step runner -- the worker that runs a `platform_call` step of a process
  definition -- is off in every release unless `LETFLOW_START_PLATFORM_STEP_RUNNER` is
  exactly `true` (`config/runtime.exs`). With the runner off, a pilot instance of a
  platform step STARTS and NEVER RUNS: the dispatch row stays `pending` and the instance
  waits at the node with no error and no DLQ entry.

  This file pins the in-repo half of the QA deployment:

    * T1 the gate refuses a missing file, a missing key and every value but exactly
      `true`, and its message names BOTH host files and the variable;
    * T2 the gate passes when both files carry exactly `true`;
    * T3 the gate's verdict agrees with `Letflow.Supervisor.Pollers.parse_platform_step_runner/1`
      for every value it is given -- a deploy that passes the gate and a container that
      boots from the file agree;
    * T4 `deploy/redeploy-qa.sh` runs the gate BEFORE it builds the image and BEFORE it
      recreates the app container;
    * T5 the variable name is one and the same in the gate, in `config/runtime.exs`, in
      the deploy script, in the compose file, in the QA runbook, in `docs/platform-steps.md`
      and in the settings table of `docs/runbooks/production-readiness.md`;
    * T6 both shell scripts parse.

  The gate is run against a fixture tree (no host, no docker, no network).
  No database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Supervisor.Pollers

  @root Path.expand("../..", __DIR__)
  @gate Path.join(@root, "deploy/lib/check_platform_step_runner.sh")
  @redeploy Path.join(@root, "deploy/redeploy-qa.sh")
  @runtime Path.join(@root, "config/runtime.exs")
  @compose Path.join(@root, "deploy/docker-compose.qa.yml")
  @env_example Path.join(@root, "deploy/.env.example")
  @qa_runbook Path.join(@root, "docs/runbooks/qa-platform-step-runner.md")
  @platform_steps Path.join(@root, "docs/platform-steps.md")
  @settings_runbook Path.join(@root, "docs/runbooks/production-readiness.md")

  @var "LETFLOW_START_PLATFORM_STEP_RUNNER"

  @moduletag :tmp_dir

  # The values a host env file can carry for the variable. The runtime parser (T-2703,
  # `Letflow.Supervisor.Pollers.parse_platform_step_runner/1`) turns the runner on for
  # the exact string "true" and for nothing else; the deploy gate must agree with it.
  @values ["true", "TRUE", "True", "1", "yes", "on", "false", "", " true", "true ", "\"true\""]

  defp read(path), do: path |> File.read!() |> String.replace("\r\n", "\n")

  # A fixture tree that mirrors the QA host: qa.env (sourced by the deploy script) and
  # deploy/.env (the compose env_file the app container boots with).
  defp fixture(dir, qa_value, compose_value) do
    File.mkdir_p!(Path.join(dir, "deploy"))
    write_env(Path.join(dir, "qa.env"), qa_value)
    write_env(Path.join(dir, "deploy/.env"), compose_value)
    dir
  end

  defp write_env(path, value) do
    body =
      if value == :missing,
        do: "# the variable is not in this file\n",
        else: "#{@var}=#{value}\n"

    File.write!(path, body)
  end

  defp gate(dir) do
    System.cmd("bash", [@gate, dir], stderr_to_stdout: true)
  end

  defp gate_variable_name do
    [_, name] = Regex.run(~r/^VAR=([A-Z0-9_]+)$/m, read(@gate))
    name
  end

  describe "the gate" do
    test "T1 it refuses a missing file, a missing key and every value but exactly 'true'", %{
      tmp_dir: tmp
    } do
      # a tree that does not exist at all
      assert {out, 1} = gate(Path.join(tmp, "no-such-tree"))
      assert out =~ "is missing or unreadable"
      assert out =~ @var
      assert out =~ "qa.env"
      assert out =~ "deploy/.env"

      # a file that does not carry the key
      dir = fixture(Path.join(tmp, "missing-key"), :missing, "true")
      assert {out, 1} = gate(dir)
      assert out =~ "#{@var} is not set in"
      assert out =~ "qa.env"

      # a wrong value in the compose file alone
      dir = fixture(Path.join(tmp, "bad-compose"), "true", "false")
      assert {out, 1} = gate(dir)
      assert out =~ "#{@var} in #{Path.join(dir, "deploy/.env")} is not exactly 'true'"
      assert out =~ "qa.env"

      # a wrong value in qa.env alone
      dir = fixture(Path.join(tmp, "bad-qa-env"), "1", "true")
      assert {out, 1} = gate(dir)
      assert out =~ "#{@var} in #{Path.join(dir, "qa.env")} is not exactly 'true'"
      assert out =~ "deploy/.env"

      # the message says that BOTH files are needed, and why
      dir = fixture(Path.join(tmp, "both-named"), "true", "false")
      assert {out, 1} = gate(dir)
      assert out =~ "must be exactly 'true' in BOTH"
      assert out =~ "qa.env alone does not reach the container"
      assert out =~ "STARTS and NEVER RUNS"
    end

    test "T2 it passes when both files carry exactly 'true'", %{tmp_dir: tmp} do
      dir = fixture(Path.join(tmp, "ok"), "true", "true")
      assert {out, 0} = gate(dir)
      assert out == ""
    end

    test "T3 its verdict agrees with the runtime parser for every value", %{tmp_dir: tmp} do
      for {value, index} <- Enum.with_index(@values) do
        dir = fixture(Path.join(tmp, "value-#{index}"), value, value)
        {out, status} = gate(dir)

        runtime = Pollers.parse_platform_step_runner(value)

        assert status == if(runtime, do: 0, else: 1),
               "#{inspect(value)}: the gate said #{status}, the runtime parser says #{runtime}"

        if status == 1 do
          assert out =~ @var
        end
      end
    end

    test "T3b it refuses every near miss the runtime parser refuses", %{tmp_dir: tmp} do
      # the exact string the runtime turns on
      dir = fixture(Path.join(tmp, "on"), "true", "true")
      assert {_, 0} = gate(dir)

      for {value, index} <-
            Enum.with_index(["TRUE", "True", "1", "yes", "on", "false", " true", "true "]) do
        dir = fixture(Path.join(tmp, "near-miss-#{index}"), value, "true")
        assert {_, 1} = gate(dir), "#{inspect(value)} passed the gate"
        refute Pollers.parse_platform_step_runner(value)
      end
    end
  end

  describe "the deploy script" do
    test "T4 it runs the gate before it builds the image and before it recreates the app container" do
      src = read(@redeploy)

      assert src =~ ~s|bash "$GATE" "$APP_DIR"|
      assert src =~ ~s|GATE="$APP_DIR/deploy/lib/check_platform_step_runner.sh"|

      {gate_at, _} = :binary.match(src, ~s|bash "$GATE" "$APP_DIR"|)
      {build_at, _} = :binary.match(src, "docker build -f deploy/Dockerfile")
      {app_at, _} = :binary.match(src, "$COMPOSE up -d --force-recreate app")

      assert gate_at < build_at, "the gate runs after the build"
      assert gate_at < app_at, "the gate runs after the app container is recreated"

      # the gate's own failure stops the deploy
      assert src =~ ~s|if ! bash "$GATE" "$APP_DIR"; then|
      assert src =~ "the platform step runner would be off on QA"
    end

    test "T6 both shell scripts parse" do
      assert {_out, 0} = System.cmd("bash", ["-n", @redeploy])
      assert {_out, 0} = System.cmd("bash", ["-n", @gate])
    end
  end

  describe "the names agree" do
    test "T5 the variable name is one and the same in the gate, the runtime, the deploy script, the compose file and the docs" do
      name = gate_variable_name()
      assert name == @var

      # the runtime reads the very same name
      assert read(@runtime) =~ ~s|System.get_env("#{name}")|

      # the deploy script and the compose file carry it into the container
      assert read(@redeploy) =~ name
      assert read(@compose) =~ "env_file: .env"
      assert read(@gate) =~ "$APP_DIR/qa.env"
      assert read(@gate) =~ "$APP_DIR/deploy/.env"

      # the env template names it with no value (the default stays off)
      assert read(@env_example) =~ ~r/^#{name}=$/m

      # the docs
      assert read(@qa_runbook) =~ name
      assert read(@platform_steps) =~ name

      settings =
        read(@settings_runbook)
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "| `#{name}` |"))

      assert settings != [], "the settings table has no row for #{name}"
    end

    test "T5b the QA runbook names both host files and the trap" do
      runbook = read(@qa_runbook)

      assert runbook =~ "qa.env"
      assert runbook =~ "deploy/.env"
      assert runbook =~ "STARTS and NEVER RUNS"
      assert runbook =~ "exactly `true`"
    end

    test "T5c the settings row says what an unset variable does" do
      row =
        read(@settings_runbook)
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "| `#{@var}` |"))

      assert row =~ "default false"
      assert row =~ "STARTS and NEVER RUNS"
      assert row =~ "config/runtime.exs"
    end
  end
end
