defmodule Letflow.PlatformTenantRuntimeConfigTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 3 and section 12 item 2 (spec `test/specs/ISS-0993-A1.md`):
  the optional `LETFLOW_PLATFORM_TENANT_ID` in `config/runtime.exs`, observed by a
  controlled-environment child `mix run --no-start` (config is evaluated, no application or
  database is started) -- the same technique, and for the same reason, as
  `login_discovery_runtime_config_test.exs`: `config/runtime.exs` runs once, at boot, so a
  boot-time `raise` is only observable from a child process.

  `System.cmd/3`'s `env:` MERGES onto this VM's environment, so every variable under test is
  explicitly set or explicitly `nil`-ed in every case (never left to inherit; an empty string is
  indistinguishable from unset on this host, so "blank" is whitespace-only). `MIX_TEST_PARTITION`
  and `MIX_BUILD_PATH` are `nil`-ed (CI exports the partition variable, which would send the child
  to a different build directory).

  Cases (what each asserts):

    * unset or blank, `MIX_ENV=test`: boots, `tenant_id: nil`, no warning (the pin is always unset
      under test and a warning there would be noise);
    * unset, `MIX_ENV=dev`: boots, `tenant_id: nil`, and the FIXED A1 warning text is printed;
    * a valid UUID in any letter case: boots, stored canonical lower-case, no warning;
    * a malformed value: boot stops, the message names the variable and states that the value is
      not echoed, the value itself never appears in the output, the probe is never reached.

  The master key is built at compile time, never a 64-hex literal (the no-secret guard scans
  tracked files).

  ## The `MIX_ENV=dev` cases are evaluated in-process (GH #2611)

  The four dev cases no longer spawn a `MIX_ENV=dev` child, which paid a cold `_build/dev`
  compile inside ExUnit's per-test timeout. They evaluate the real `config/runtime.exs` with
  `Config.Reader` and `env: :dev` through `Letflow.Test.RuntimeConfigEval` (the pattern of
  `secrets_runtime_config_test.exs`, GH #2609): a `raise` is an exception from the call, the
  warning is captured from standard error, and the pin is read from `config/config.exs`
  merged with the result, as the application would see it. Each case sets explicit inputs
  (a valid master key and pepper pair, every other variable `runtime.exs` reads deleted) and
  `setup` snapshots and restores all of them. The `MIX_ENV=test` subprocess cases stay as
  this file's real boot-path checks.

  `@moduletag :slow` (run with `--include slow`), `async: false` (the in-process cases
  change the process-global OS environment).
  """

  use ExUnit.Case, async: false

  @moduletag :slow
  # GH #2611: the remaining `mix run` subprocess smoke tests boot a child VM on the already
  # compiled build; 180 s is a backstop well above the measured child boot, never a
  # cold-compile allowance (no test here compiles _build/dev any more).
  @moduletag timeout: 180_000

  alias Letflow.Test.RuntimeConfigEval, as: R

  @var "LETFLOW_PLATFORM_TENANT_ID"
  @master "LETFLOW_SECRETS_MASTER_KEY"
  @master_key String.duplicate("3f1c9a2e7b4d6081", 4)

  @warning "LETFLOW_PLATFORM_TENANT_ID is unset: platform-scope operations are denied for every caller."

  @probe ~S|IO.puts("RESULT " <> inspect(Application.get_env(:letflow, Letflow.PlatformTenant)))|

  # value: a string or nil (unset). Returns {output, exit_status}. MIX_ENV=test only: the
  # dev cases are evaluated in-process (see the moduledoc).
  defp boot("test" = mix_env, value) do
    env = [
      {"MIX_ENV", mix_env},
      {"MIX_TEST_PARTITION", nil},
      {"MIX_BUILD_PATH", nil},
      {@master, @master_key},
      {@var, value},
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
    assert output =~ "UUID", "the message must state the accepted form:\n#{output}"
    assert output =~ "not echoed", "the message must say the value is not echoed:\n#{output}"
    refute output =~ String.trim(value), "output must not echo the supplied value:\n#{output}"
  end

  describe "unset / blank under MIX_ENV=test" do
    for {label, value} <- [unset: nil, whitespace_only: "   ", tab: "\t"] do
      test "#{label} boots with no pin and no warning" do
        {output, status} = boot("test", unquote(value))
        assert_boots(output, status)
        assert output =~ "RESULT [tenant_id: nil]"
        refute output =~ @warning
      end
    end
  end

  describe "unset under a non-test environment" do
    # In-process (GH #2611): the real config/runtime.exs under config_env() == :dev, see the
    # moduledoc. -> {{:ok, config} | {:raised, message, formatted}, stderr}
    setup do
      R.isolate_env()
    end

    defp eval_dev(value) do
      R.evaluate(Map.put(R.valid_base(), @var, value), :dev)
    end

    # What the application sees: config.exs (default tenant_id: nil) merged with runtime.exs.
    defp pin_env!(result) do
      assert {:ok, config} = result,
             "expected config/runtime.exs to evaluate, got: #{inspect(result)}"

      config |> R.merged(:dev) |> get_in([:letflow, Letflow.PlatformTenant])
    end

    test "MIX_ENV=dev, unset: boots, no pin, and the fixed A1 warning is printed" do
      {result, stderr} = eval_dev(nil)
      assert pin_env!(result) == [tenant_id: nil]
      assert stderr =~ @warning
    end

    test "MIX_ENV=dev, whitespace-only: same as unset" do
      {result, stderr} = eval_dev("   ")
      assert pin_env!(result) == [tenant_id: nil]
      assert stderr =~ @warning
    end

    test "MIX_ENV=dev, a valid UUID: boots with the pin set and no warning" do
      uuid = Ecto.UUID.generate()
      {result, stderr} = eval_dev(uuid)
      assert pin_env!(result) == [tenant_id: uuid]
      refute stderr =~ @warning
    end

    test "MIX_ENV=dev, a malformed value stops boot without echoing it" do
      value = "leaky-platform-value-7731"
      {result, stderr} = eval_dev(value)

      assert {:raised, message, formatted} = result,
             "expected config/runtime.exs to raise, it returned: #{inspect(result)}"

      assert message =~ @var, "the message must name #{@var}:\n#{message}"
      assert message =~ "UUID", "the message must state the accepted form:\n#{message}"
      assert message =~ "not echoed", "the message must say the value is not echoed:\n#{message}"

      for text <- [message, formatted, stderr] do
        refute text =~ value, "output must not echo the supplied value:\n#{text}"
      end
    end
  end

  describe "a valid value sets the pin" do
    test "a lower-case UUID is stored as given" do
      uuid = Ecto.UUID.generate()
      {output, status} = boot("test", uuid)
      assert_boots(output, status)
      assert output =~ ~s|RESULT [tenant_id: "#{uuid}"]|
    end

    test "an upper-case UUID is stored canonical lower-case" do
      uuid = Ecto.UUID.generate()
      {output, status} = boot("test", String.upcase(uuid))
      assert_boots(output, status)
      assert output =~ ~s|RESULT [tenant_id: "#{uuid}"]|
    end

    test "surrounding whitespace is trimmed" do
      uuid = Ecto.UUID.generate()
      {output, status} = boot("test", "  " <> uuid <> "  ")
      assert_boots(output, status)
      assert output =~ ~s|RESULT [tenant_id: "#{uuid}"]|
    end
  end

  describe "a malformed value stops boot without echoing it" do
    for {label, value} <- [
          sentinel: "leaky-platform-value-7731",
          braced: "{4f6c1c7a-1b0e-4c0e-9d3a-5a1b2c3d4e5f}",
          no_hyphens: "4f6c1c7a1b0e4c0e9d3a5a1b2c3d4e5f",
          trailing_garbage: "4f6c1c7a-1b0e-4c0e-9d3a-5a1b2c3d4e5f-extra",
          slug: "bpm-default",
          not_hex: "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"
        ] do
      test "#{label}" do
        {output, status} = boot("test", unquote(value))
        assert_refused(output, status, unquote(value))
      end
    end
  end
end
