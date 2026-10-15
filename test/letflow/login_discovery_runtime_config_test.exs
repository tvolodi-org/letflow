defmodule Letflow.LoginDiscoveryRuntimeConfigTest do
  @moduledoc """
  REQ-437 (spec `test/specs/REQ-437.md`), design s7 and s15.3: the optional
  `LETFLOW_LOGIN_DISCOVERY_MODE` in `config/runtime.exs`, observed by a
  controlled-environment child `mix run --no-start` (config is evaluated, no
  application or database is started) -- the same technique, and for the same
  reason, as `login_directory_runtime_config_test.exs` and
  `client_ip_runtime_config_test.exs`: `config/runtime.exs` runs once, at boot,
  so a boot-time `raise` is only observable from a child process.

  `System.cmd/3`'s `env:` MERGES onto this VM's environment, so every variable
  under test is explicitly set or explicitly `nil`-ed in every case (never left to
  inherit; an empty string is indistinguishable from unset on this host, so
  "blank" is whitespace-only). `MIX_TEST_PARTITION` and `MIX_BUILD_PATH` are
  `nil`-ed. Cases run as `MIX_ENV=test` (warm build) and are this file's real
  boot-path checks; ONE case needs `config_env() == :dev` because `config/test.exs`
  replaces the notifier adapter with the test double and the shipped default
  (`Noop`) is only visible outside it.

  That dev case is evaluated in-process (GH #2611), not as a `MIX_ENV=dev` child,
  which paid a cold `_build/dev` compile inside ExUnit's per-test timeout: the real
  `config/runtime.exs` is read with `Config.Reader` and `env: :dev` through
  `Letflow.Test.RuntimeConfigEval` (the pattern of `secrets_runtime_config_test.exs`,
  GH #2609) and merged over `config/config.exs` (`env: :dev`, so `config/dev.exs`)
  exactly as Mix applies them, which is what the old child's probe printed. Every
  variable `runtime.exs` reads is set explicitly for it (a valid master key and pepper
  pair, the rest deleted) and restored in `on_exit`.

  Asserts, per case: exit status, the evaluated `Letflow.LoginDiscovery` env, that
  `Letflow.Routers.LoginDiscovery` is still exactly `[enabled: boolean]` (REQ-439's
  shape), and for a rejected value that the message names the variable and does
  NOT echo the value (INV-4).

  `@moduletag :slow` (run with `--include slow`), `async: false`.
  """

  use ExUnit.Case, async: false

  @moduletag :slow

  alias Letflow.Test.RuntimeConfigEval, as: R

  @var "LETFLOW_LOGIN_DISCOVERY_MODE"
  @enabled_var "LETFLOW_LOGIN_DISCOVERY_ENABLED"
  @master "LETFLOW_SECRETS_MASTER_KEY"
  # built at compile time, not a 64-hex literal (the no-secret guard scans tracked files)
  @master_key String.duplicate("3f1c9a2e7b4d6081", 4)

  @probe ~S|IO.puts("RESULT " <> inspect({Enum.sort(Application.get_env(:letflow, Letflow.LoginDiscovery)), Application.get_env(:letflow, Letflow.Routers.LoginDiscovery), Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier)[:adapter]}))|

  # mode / enabled: a string or nil (unset). Returns {output, exit_status}. MIX_ENV=test
  # only: the one dev case is evaluated in-process (see the moduledoc).
  defp boot("test" = mix_env, mode, enabled) do
    env = [
      {"MIX_ENV", mix_env},
      {"MIX_TEST_PARTITION", nil},
      {"MIX_BUILD_PATH", nil},
      {@master, @master_key},
      {@var, mode},
      {@enabled_var, enabled},
      {"LETFLOW_TRUSTED_PROXIES", nil},
      {"DATABASE_URL", "ecto://dummy:dummy@localhost/dummy"}
    ]

    System.cmd("mix", ["run", "--no-start", "-e", @probe],
      env: env,
      stderr_to_stdout: true,
      cd: File.cwd!()
    )
  end

  defp assert_boots(output, status) do
    assert status == 0, "expected exit 0, got #{status} with output:\n#{output}"
  end

  defp assert_refused(output, status, value) do
    refute status == 0, "expected non-zero exit, got 0 with output:\n#{output}"
    refute output =~ "RESULT", "boot must not reach the probe:\n#{output}"
    assert output =~ @var, "the message must name #{@var}:\n#{output}"
    assert output =~ "uniform_plus_email", "the message must list the accepted values:\n#{output}"

    refute output =~ String.trim(value), "output must not echo the supplied value:\n#{output}"
  end

  describe "unset / blank: no override, the config/config.exs default stands" do
    for {label, value} <- [unset: nil, whitespace_only: "   ", tab: "\t"] do
      test "#{label} boots with mode :redirect_single, max_body_bytes 2048 and the mount env exactly [enabled: true]" do
        {output, status} = boot("test", unquote(value), nil)
        assert_boots(output, status)

        assert output =~
                 "RESULT {[max_body_bytes: 2048, mode: :redirect_single], [enabled: true],"
      end
    end
  end

  describe "a valid value overrides the mode" do
    test "uniform_plus_email" do
      {output, status} = boot("test", "uniform_plus_email", nil)
      assert_boots(output, status)

      assert output =~
               "RESULT {[max_body_bytes: 2048, mode: :uniform_plus_email], [enabled: true],"
    end

    test "redirect_single" do
      {output, status} = boot("test", "redirect_single", nil)
      assert_boots(output, status)
      assert output =~ "RESULT {[max_body_bytes: 2048, mode: :redirect_single], [enabled: true],"
    end

    test "surrounding whitespace is trimmed" do
      {output, status} = boot("test", "  uniform_plus_email  ", nil)
      assert_boots(output, status)
      assert output =~ "mode: :uniform_plus_email"
    end

    test "the mode variable never touches the mount switch's env shape: with ENABLED=false it is exactly [enabled: false]" do
      {output, status} = boot("test", "uniform_plus_email", "false")
      assert_boots(output, status)
      assert output =~ "mode: :uniform_plus_email"
      assert output =~ "[enabled: false],"
    end
  end

  describe "an unknown value stops boot without echoing it" do
    for {label, value} <- [
          sentinel: "leaky-mode-value-7731",
          wrong_case: "Redirect_Single",
          partial: "uniformish",
          list: "uniform_plus_email,redirect_single",
          picker: "picker_unauth"
        ] do
      test "#{label}" do
        {output, status} = boot("test", unquote(value), nil)
        assert_refused(output, status, unquote(value))
      end
    end
  end

  describe "shipped default outside the test config" do
    # In-process (GH #2611): the real config/runtime.exs under config_env() == :dev, merged
    # over config/config.exs as the application would see it; see the moduledoc.
    setup do
      R.isolate_env()
    end

    test "MIX_ENV=dev, nothing set: boots, mode :redirect_single, notifier adapter Letflow.LoginDiscovery.Notifier.Noop" do
      vars = Map.merge(R.valid_base(), %{@var => nil, @enabled_var => nil})
      {result, _stderr} = R.evaluate(vars, :dev)

      assert {:ok, config} = result,
             "expected config/runtime.exs to evaluate, got: #{inspect(result)}"

      app = config |> R.merged(:dev) |> Keyword.fetch!(:letflow)

      assert {Enum.sort(app[Letflow.LoginDiscovery]), app[Letflow.Routers.LoginDiscovery],
              app[Letflow.LoginDiscovery.Notifier][:adapter]} ==
               {[max_body_bytes: 2048, mode: :redirect_single], [enabled: true],
                Letflow.LoginDiscovery.Notifier.Noop}
    end
  end
end
