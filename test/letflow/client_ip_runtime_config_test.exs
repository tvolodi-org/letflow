defmodule Letflow.ClientIpRuntimeConfigTest do
  @moduledoc """
  REQ-439 AC5/AC6 -- `LETFLOW_TRUSTED_PROXIES` and `LETFLOW_LOGIN_DISCOVERY_ENABLED`
  parsing, defaults, and the `:prod` boot refusal in `config/runtime.exs`. Design:
  `lib/letflow/design/req439-trusted-proxy-client-ip.md` s4-s5; spec:
  `test/specs/REQ-439.md`.

  Modelled on `test/letflow/secrets_runtime_config_test.exs`: `config/runtime.exs`
  is evaluated once per BEAM boot, so each case spawns a fresh
  `mix run --no-start -e ...` child process (no Repo, no database) and inspects its
  exit status and output. Every case passes `MIX_TEST_PARTITION`/`MIX_BUILD_PATH`
  as nil (`System.cmd/3` merges `env:` onto the inherited environment, and
  `config/dev.exs` refuses a set `MIX_TEST_PARTITION`) and supplies the committed,
  non-secret test master key because `MIX_ENV=prod` has no fallback.

  The `MIX_ENV=dev` cases are no longer subprocesses: they live in
  `Letflow.ClientIpRuntimeConfigTest.Dev` at the end of this file and evaluate the real
  `config/runtime.exs` in-process with `Config.Reader` and `env: :dev` (GH #2611), so this
  file never builds `_build/dev`.

  The `MIX_ENV=prod` cases additionally carry `@tag :prod_build` (they need a
  prod-compiled build, slow and possibly absent in a lean CI). The same decision
  table is covered in-process, without any subprocess, by the `boot_check/3` and
  `parse_enabled/2` tests in `test/letflow/plugs/client_ip_test.exs`.

  Sentinel values used for "must not be echoed" assertions are deliberately
  distinctive and are not secrets.
  """

  use ExUnit.Case, async: true

  @moduletag :slow
  # GH #2611: the remaining `mix run` subprocess smoke tests boot a child VM on the already
  # compiled build; 180 s is a backstop well above the measured child boot, never a
  # cold-compile allowance (no test here compiles _build/dev any more).
  @moduletag timeout: 180_000

  # Same fix as test/letflow/admission_runtime_config_test.exs (ISS-0908 follow-up): the first
  # MIX_ENV=prod child boot otherwise absorbs a full _build/prod compile, which on a loaded
  # runner can exceed ExUnit's 60s per-test timeout -- whichever prod case happens to run first
  # (or alongside the admission module's own compile) times out, so a different test failed on
  # each CI run (REQ-439 tests, seen on #2201: :227, then "blank trust list"). setup_all has no
  # per-test timeout; afterwards each child only loads the compiled .beam files.
  setup_all do
    env = [{"MIX_ENV", "prod"}, {"MIX_TEST_PARTITION", nil}, {"MIX_BUILD_PATH", nil}]

    {output, exit_status} =
      System.cmd("mix", ["compile"], env: env, stderr_to_stdout: true, cd: File.cwd!())

    if exit_status != 0 do
      raise "precompiling _build/prod under MIX_ENV=prod failed (exit #{exit_status}):
#{output}"
    end

    :ok
  end

  @master_key "3f1c9a2e7b4d6081f5a3c8e2b7d4f6091a3c5e7b9d2f4a6c8e1b3d5f7a9c2e4b"
  @probe ~S|IO.puts("RESULT " <> inspect({Application.get_env(:letflow, Letflow.Plugs.ClientIp), Application.get_env(:letflow, Letflow.Routers.LoginDiscovery)}))|

  @trust_warning "LETFLOW_LOGIN_DISCOVERY_ENABLED is true with LETFLOW_TRUSTED_PROXIES empty"
  @zero_warning "LETFLOW_TRUSTED_PROXIES contains a /0 CIDR"

  # mix_env: "test" | "prod"; proxies/enabled: a string or nil (unset).
  defp boot(mix_env, proxies, enabled), do: boot(mix_env, proxies, enabled, [])

  defp boot(mix_env, proxies, enabled, extra_env) do
    env =
      extra_env ++
        [
          {"MIX_ENV", mix_env},
          {"MIX_TEST_PARTITION", nil},
          {"MIX_BUILD_PATH", nil},
          {"LETFLOW_SECRETS_MASTER_KEY", @master_key},
          {"LETFLOW_TRUSTED_PROXIES", proxies},
          {"LETFLOW_LOGIN_DISCOVERY_ENABLED", enabled},
          {"DATABASE_URL", "ecto://dummy:dummy@localhost/dummy"}
        ]

    System.cmd("mix", ["run", "--no-start", "-e", @probe],
      env: env,
      stderr_to_stdout: true,
      cd: File.cwd!()
    )
  end

  defp count(output, needle), do: length(String.split(output, needle)) - 1

  defp assert_boots(output, status) do
    assert status == 0, "expected exit 0, got #{status} with output:\n#{output}"
  end

  defp assert_refused(output, status) do
    refute status == 0, "expected non-zero exit, got 0 with output:\n#{output}"
    refute output =~ "RESULT"
  end

  # --- MIX_ENV=test ---------------------------------------------------------

  describe "LETFLOW_TRUSTED_PROXIES (MIX_ENV=test)" do
    test "unset gives [] (and the default enabled true)" do
      {output, status} = boot("test", nil, nil)
      assert_boots(output, status)
      assert output =~ "RESULT {[trusted_proxies: []], [enabled: true]}"
    end

    test "a valid list parses to cidr tuples, order preserved" do
      {output, status} = boot("test", "10.0.0.0/8, 2001:db8::/32,192.168.1.1", nil)
      assert_boots(output, status)

      assert output =~
               "trusted_proxies: [{{10, 0, 0, 0}, 8}, {{8193, 3512, 0, 0, 0, 0, 0, 0}, 32}, {{192, 168, 1, 1}, 32}]"

      refute output =~ @trust_warning
    end

    test "an invalid entry raises at boot with a fixed message and does not echo the value" do
      sentinel = "zz-secret-cidr-91731"
      {output, status} = boot("test", "10.0.0.0/8," <> sentinel, "true")
      assert_refused(output, status)
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      assert output =~ "invalid CIDR entry"
      refute output =~ sentinel
      refute output =~ "10.0.0.0/8"
    end

    test "an out-of-range prefix is invalid and the value is not echoed" do
      {output, status} = boot("test", "10.77.88.99/33", nil)
      assert_refused(output, status)
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      refute output =~ "10.77.88.99"
    end

    test "a /0 entry boots with the fixed warning exactly once and no value" do
      {output, status} = boot("test", "10.0.0.0/8,0.0.0.0/0", "true")
      assert_boots(output, status)
      assert count(output, @zero_warning) == 1
      refute output =~ @trust_warning
    end

    test "a mapped ::ffff:0:0/96 entry (normalised to 0.0.0.0/0) also warns" do
      {output, status} = boot("test", "::ffff:0:0/96", "true")
      assert_boots(output, status)
      assert count(output, @zero_warning) == 1
    end
  end

  describe "LETFLOW_LOGIN_DISCOVERY_ENABLED (MIX_ENV=test)" do
    test "true is accepted" do
      {output, status} = boot("test", "10.0.0.0/8", "true")
      assert_boots(output, status)
      assert output =~ "[enabled: true]"
    end

    test "false is accepted" do
      {output, status} = boot("test", nil, "false")
      assert_boots(output, status)
      assert output =~ "[enabled: false]"
      refute output =~ @trust_warning
    end

    for bad <- ["yes", "TRUE", "1"] do
      test "#{inspect(bad)} raises with a fixed message and does not echo the value" do
        bad = unquote(bad)
        {output, status} = boot("test", nil, bad)
        assert_refused(output, status)
        assert output =~ "LETFLOW_LOGIN_DISCOVERY_ENABLED"
        assert output =~ "must be exactly true or false"
        refute output =~ "\"#{bad}\""
        refute output =~ "=#{bad}"
      end
    end

    test "a sentinel invalid value is not echoed" do
      sentinel = "zz-secret-flag-55120"
      {output, status} = boot("test", nil, sentinel)
      assert_refused(output, status)
      assert output =~ "LETFLOW_LOGIN_DISCOVERY_ENABLED"
      refute output =~ sentinel
    end
  end

  # --- MIX_ENV=dev: see Letflow.ClientIpRuntimeConfigTest.Dev below (in-process) ---

  # --- MIX_ENV=prod ---------------------------------------------------------

  describe "MIX_ENV=prod boot refusal" do
    @describetag :prod_build

    test "default enabled is false and the node boots with no trust list" do
      {output, status} = boot("prod", nil, nil)
      assert_boots(output, status)
      assert output =~ "RESULT {[trusted_proxies: []], [enabled: false]}"
    end

    test "enabled with an unset trust list is refused, naming both variables, no value" do
      {output, status} = boot("prod", nil, "true")
      assert_refused(output, status)
      assert output =~ "LETFLOW_LOGIN_DISCOVERY_ENABLED"
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      assert output =~ "refusing to boot"
    end

    test "enabled with a blank trust list is refused" do
      {output, status} = boot("prod", "  , ", "true")
      assert_refused(output, status)
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      assert output =~ "refusing to boot"
    end

    test "enabled with a non-empty list boots" do
      # REQ-444: prod + mount enabled now also needs the legal-confirmation marker and a delivering mail adapter (config/runtime.exs enablement gate)
      # names assembled at runtime: the AC6 guard (no_smtp_secret_guard_test) forbids a tracked
      # file assigning a literal value to the SMTP credential variables
      smtp_var = fn suffix -> "LETFLOW_SMTP_" <> suffix end

      gate_env = [
        {"LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION", "placeholder-legal-ref"},
        {"LETFLOW_LOGIN_DIRECTORY_PEPPER",
         Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)},
        {"LETFLOW_LOGIN_DIRECTORY_PEPPER_ID", "cur-1"},
        {"LETFLOW_MAIL_ADAPTER", "smtp"},
        {"LETFLOW_SMTP_HOST", "smtp.example.com"},
        {"LETFLOW_SMTP_PORT", "587"},
        {smtp_var.("USERNAME"), "placeholder-user"},
        {smtp_var.("PASSWORD"), "placeholder-pass"},
        {"LETFLOW_MAIL_FROM", "login@example.com"},
        {"LETFLOW_PUBLIC_BASE_URL", "https://app.example.com"}
      ]

      {output, status} = boot("prod", "172.18.0.1", "true", gate_env)
      assert_boots(output, status)
      assert output =~ "RESULT {[trusted_proxies: [{{172, 18, 0, 1}, 32}]], [enabled: true]}"
      refute output =~ @trust_warning
    end

    test "disabled with an empty list boots" do
      {output, status} = boot("prod", nil, "false")
      assert_boots(output, status)
      assert output =~ "[enabled: false]"
    end

    test "the refusal fires before the DATABASE_URL raise and carries no env value" do
      sentinel = "ecto://dummy:dummy@localhost/dummy"
      {output, status} = boot("prod", nil, "true")
      assert_refused(output, status)
      refute output =~ "DATABASE_URL"
      refute output =~ sentinel
    end

    test "an invalid trust list raises in prod too, without echoing" do
      sentinel = "zz-secret-cidr-70011"
      {output, status} = boot("prod", sentinel, "true")
      assert_refused(output, status)
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      refute output =~ sentinel
    end
  end
end

defmodule Letflow.ClientIpRuntimeConfigTest.Dev do
  @moduledoc """
  REQ-439, the `config_env() == :dev` cases of `Letflow.ClientIpRuntimeConfigTest`,
  evaluated in-process (GH #2611, the pattern of GH #2609 / PR #2610): the real
  `config/runtime.exs` is read with `Config.Reader` and `env: :dev` through
  `Letflow.Test.RuntimeConfigEval`, so these cases no longer spawn a `MIX_ENV=dev`
  `mix run` that paid a cold `_build/dev` compile inside ExUnit's per-test timeout.
  `env: :dev` keeps the dev semantics: `parse_enabled/2` defaults to true outside `:prod`
  and `boot_check/3` warns (not refuses) on an enabled mount with an empty trust list.

  A separate module because the OS environment is process-global: this one is
  `async: false` (every variable `runtime.exs` reads is snapshotted in `setup` and restored
  in `on_exit`; each case sets explicit inputs, with a valid master key and pepper pair so
  an earlier refusal cannot mask the case), while the subprocess cases above stay
  `async: true`. Those subprocess cases (`MIX_ENV=test` and `prod`) remain this file's
  real boot-path checks.
  """

  use ExUnit.Case, async: false

  alias Letflow.Test.RuntimeConfigEval, as: R

  @trust_warning "LETFLOW_LOGIN_DISCOVERY_ENABLED is true with LETFLOW_TRUSTED_PROXIES empty"

  setup do
    R.isolate_env()
  end

  # proxies/enabled: a string or nil (unset). -> {client_ip_env, mount_env, stderr}
  defp boot_dev(proxies, enabled) do
    vars =
      Map.merge(R.valid_base(), %{
        "LETFLOW_TRUSTED_PROXIES" => proxies,
        "LETFLOW_LOGIN_DISCOVERY_ENABLED" => enabled
      })

    {result, stderr} = R.evaluate(vars, :dev)

    assert {:ok, config} = result,
           "expected config/runtime.exs to evaluate, got: #{inspect(result)}"

    {config[:letflow][Letflow.Plugs.ClientIp], config[:letflow][Letflow.Routers.LoginDiscovery],
     stderr}
  end

  defp count(output, needle), do: length(String.split(output, needle)) - 1

  describe "MIX_ENV=dev" do
    test "defaults to enabled true; the empty list only prints the fixed warning, once" do
      {client_ip, mount, stderr} = boot_dev(nil, nil)
      assert {client_ip, mount} == {[trusted_proxies: []], [enabled: true]}
      assert count(stderr, @trust_warning) == 1
    end

    test "explicitly enabled with an empty list also boots with the warning" do
      {_client_ip, mount, stderr} = boot_dev("", "true")
      assert mount == [enabled: true]
      assert count(stderr, @trust_warning) == 1
    end

    test "disabled prints no warning" do
      {_client_ip, mount, stderr} = boot_dev(nil, "false")
      assert mount == [enabled: false]
      refute stderr =~ @trust_warning
    end

    test "enabled with a non-empty list prints no warning" do
      {client_ip, mount, stderr} = boot_dev("172.16.0.0/12", "true")
      assert client_ip == [trusted_proxies: [{{172, 16, 0, 0}, 12}]]
      assert mount == [enabled: true]
      refute stderr =~ @trust_warning
    end
  end
end
