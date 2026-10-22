defmodule Letflow.LoginDiscovery.EnablementGateRuntimeTest do
  @moduledoc """
  REQ-444 criterion 2 (spec `test/specs/REQ-444.md`): the boot refusal observed through
  `config/runtime.exs`.

  The cases are evaluated IN-PROCESS (GH #2614, the pattern of GH #2611 / #2609): the real
  `config/runtime.exs` is read with `Config.Reader` under `config_env() == :dev`, `:test`
  or `:prod` through `Letflow.Test.RuntimeConfigEval`, which is the mechanism a booting
  node uses, so the refusal is an exception from the read and a successful boot is the
  returned config. No `MIX_ENV=prod` or `MIX_ENV=dev` child is spawned and no prod or dev
  build is precompiled: a cold `_build/prod` or `_build/dev` compile used to run inside
  ExUnit's per-test timeout on a loaded runner.

  ONE case keeps the real boot path: a `mix run --no-start` child under `MIX_ENV=test`
  (its build is the one this test run already compiled, so there is no precompile), with
  `@tag timeout: 180_000` as a backstop for the child boot itself.

  Every variable `runtime.exs` reads is set explicitly for each case or deleted by the
  helper (never inherited); the sentinel values are distinctive, and the SMTP values are
  placeholders. Refusal output is the exception message and the captured standard error,
  and the non-echo checks (`refute ... =~ @sentinel`) run against it, as they did against
  the child's output.

  `@moduletag :slow`, `async: false` (the OS environment is process-global).
  """

  use ExUnit.Case, async: false

  @moduletag :slow

  alias Letflow.Test.RuntimeConfigEval, as: R

  @marker_var "LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION"
  @sentinel "zz-marker-70011"
  @database_url "ecto://dummy:dummy@localhost/dummy"
  @probe ~S|IO.puts("RESULT " <> inspect({Application.get_env(:letflow, Letflow.Routers.LoginDiscovery), Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier)[:adapter]}))|

  @smtp %{
    "LETFLOW_MAIL_ADAPTER" => "smtp",
    "LETFLOW_SMTP_HOST" => "smtp.example.com",
    "LETFLOW_SMTP_PORT" => "587",
    "LETFLOW_SMTP_USERNAME" => "placeholder-user",
    "LETFLOW_SMTP_PASSWORD" => "placeholder-pass",
    "LETFLOW_MAIL_FROM" => "login@example.com",
    "LETFLOW_PUBLIC_BASE_URL" => "https://app.example.com"
  }

  setup do
    R.isolate_env()
  end

  defp prod_enabled(extra) do
    Map.merge(
      %{"LETFLOW_LOGIN_DISCOVERY_ENABLED" => "true", "LETFLOW_TRUSTED_PROXIES" => "10.0.0.0/8"},
      extra
    )
  end

  # Evaluates config/runtime.exs under config_env() == env with `overrides` (name => value |
  # nil) over a valid key and pepper pair and a dummy DATABASE_URL; every other runtime
  # variable is deleted. Returns {:ok, {router_env, notifier_adapter}, output} when the file
  # evaluates, or {:raised, output} when it refuses; output is the captured standard error
  # plus the exception MESSAGE (not the stack trace: its frames name this test, which can
  # itself contain a value the non-echo checks look for).
  defp evaluate(env, overrides) do
    vars =
      %{"DATABASE_URL" => @database_url}
      |> Map.merge(R.valid_base())
      |> Map.merge(overrides)

    case R.evaluate(vars, env) do
      {{:ok, config}, stderr} ->
        app = config |> R.merged(env) |> Keyword.fetch!(:letflow)

        {:ok,
         {app[Letflow.Routers.LoginDiscovery], app[Letflow.LoginDiscovery.Notifier][:adapter]},
         stderr}

      {{:raised, message, _formatted}, stderr} ->
        {:raised, message <> stderr}
    end
  end

  defp assert_refused(result, variable) do
    assert {:raised, output} = result, "expected a boot refusal, got: #{inspect(result)}"
    assert output =~ variable, "the message must name #{variable}:\n#{output}"
    assert output =~ "email-first login is enabled outside dev/test"
  end

  describe "MIX_ENV=prod, enabled=true, valid trusted proxies: the marker" do
    for {label, marker} <- [
          unset: nil,
          blank: "",
          whitespace_only: "        ",
          seven_chars: "abcdefg",
          seven_plus_padding: "  abcdefg  "
        ] do
      test "#{label} (with a valid SMTP adapter) refuses boot" do
        result = evaluate(:prod, prod_enabled(Map.put(@smtp, @marker_var, unquote(marker))))

        assert_refused(result, @marker_var)
      end
    end

    test "exactly 8 characters (with a valid SMTP adapter) boots" do
      assert {:ok, _probe, _output} =
               evaluate(:prod, prod_enabled(Map.put(@smtp, @marker_var, "abcdefgh")))
    end

    test "a too-short sentinel marker is not echoed" do
      short = "zz-9"
      result = evaluate(:prod, prod_enabled(Map.put(@smtp, @marker_var, short)))
      assert_refused(result, @marker_var)
      {:raised, output} = result
      refute output =~ short
    end
  end

  describe "MIX_ENV=prod, enabled=true, valid marker: the adapter" do
    for {label, adapter} <- [unset: nil, noop: "noop", noop_padded: "  noop  "] do
      test "#{label} refuses boot" do
        result =
          evaluate(
            :prod,
            prod_enabled(%{@marker_var => @sentinel, "LETFLOW_MAIL_ADAPTER" => unquote(adapter)})
          )

        assert_refused(result, "LETFLOW_MAIL_ADAPTER")
        {:raised, output} = result
        refute output =~ @sentinel
        refute output =~ ~r/noop/i, "the adapter value/module must not be echoed:\n#{output}"
      end
    end

    test "smtp with the complete SMTP environment boots, selects the Smtp adapter and keeps the mount true" do
      assert {:ok, probe, output} =
               evaluate(:prod, prod_enabled(Map.put(@smtp, @marker_var, @sentinel)))

      assert probe == {[enabled: true], Letflow.LoginDiscovery.Notifier.Smtp}
      refute output =~ @sentinel
      refute output =~ "placeholder-pass"
    end

    test "smtp with an incomplete SMTP environment is still refused by REQ-441's block, not silently passed" do
      result =
        evaluate(
          :prod,
          prod_enabled(%{
            @marker_var => @sentinel,
            "LETFLOW_MAIL_ADAPTER" => "smtp",
            "LETFLOW_SMTP_HOST" => "smtp.example.com"
          })
        )

      assert {:raised, output} = result
      refute output =~ @sentinel
    end

    test "the marker is checked before the adapter: both missing names the marker" do
      result = evaluate(:prod, prod_enabled(%{}))
      assert_refused(result, @marker_var)
      {:raised, output} = result
      refute output =~ "LETFLOW_MAIL_ADAPTER does not select"
    end
  end

  describe "MIX_ENV=prod: the gate stays out of the way" do
    test "enabled=false boots with no marker and no adapter" do
      assert {:ok, {[enabled: false], _adapter}, _output} =
               evaluate(:prod, %{"LETFLOW_LOGIN_DISCOVERY_ENABLED" => "false"})
    end

    test "enabled unset defaults to false in :prod and boots with no marker and no adapter" do
      assert {:ok, {[enabled: false], _adapter}, _output} = evaluate(:prod, %{})
    end

    test "REQ-439 precedes: enabled=true with an empty trusted-proxy list is still refused for the proxy list" do
      result =
        evaluate(
          :prod,
          Map.merge(@smtp, %{
            "LETFLOW_LOGIN_DISCOVERY_ENABLED" => "true",
            @marker_var => @sentinel
          })
        )

      assert {:raised, output} = result
      assert output =~ "LETFLOW_TRUSTED_PROXIES"
      refute output =~ "email-first login is enabled outside dev/test"
      refute output =~ @sentinel
    end
  end

  describe "dev and test are never refused" do
    for mix_env <- [:dev, :test] do
      test "config_env() == #{mix_env} with enabled=true, no marker and no adapter boots" do
        assert {:ok, {[enabled: true], _adapter}, _output} =
                 evaluate(unquote(mix_env), %{"LETFLOW_LOGIN_DISCOVERY_ENABLED" => "true"})
      end

      test "config_env() == #{mix_env} with enabled=true, a blank marker and adapter=noop boots" do
        assert {:ok, {[enabled: true], _adapter}, _output} =
                 evaluate(unquote(mix_env), %{
                   "LETFLOW_LOGIN_DISCOVERY_ENABLED" => "true",
                   @marker_var => "  ",
                   "LETFLOW_MAIL_ADAPTER" => "noop"
                 })
      end
    end

    test "unset enabled defaults to true in dev (the exemption does not depend on a variable)" do
      assert {:ok, {[enabled: true], Letflow.LoginDiscovery.Notifier.Noop}, _output} =
               evaluate(:dev, %{})
    end
  end

  describe "the real boot path" do
    # The one subprocess case: a `mix run --no-start` child under MIX_ENV=test on the build
    # this run already compiled. Every runtime variable is set or nil (never inherited).
    @tag timeout: 180_000
    test "a MIX_ENV=test child boots with enabled=true and prints the probe" do
      vars =
        R.runtime_vars()
        |> Map.new(&{&1, nil})
        |> Map.merge(R.valid_base())
        |> Map.merge(%{
          "MIX_ENV" => "test",
          "MIX_TEST_PARTITION" => nil,
          "MIX_BUILD_PATH" => nil,
          "DATABASE_URL" => @database_url,
          "LETFLOW_LOGIN_DISCOVERY_ENABLED" => "true"
        })

      {output, status} =
        System.cmd("mix", ["run", "--no-start", "-e", @probe],
          env: Map.to_list(vars),
          stderr_to_stdout: true,
          cd: File.cwd!()
        )

      assert status == 0, "expected exit 0, got #{status} with output:\n#{output}"
      assert output =~ "RESULT {[enabled: true],"
    end
  end
end
