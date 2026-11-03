defmodule Letflow.LoginDiscovery.EnablementGateTest do
  @moduledoc """
  REQ-444 (spec `test/specs/REQ-444.md`): shipped defaults and source-order guards.
  Everything here is in-process (no subprocess): `Config.Reader` over `config/`, and
  scans of committed files. The boot refusal itself is exercised in
  `enablement_gate_runtime_test.exs`; the pure decision table in `boot_check_test.exs`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @mount Letflow.Routers.LoginDiscovery

  # `Config.Reader` of config/dev.exs raises while MIX_TEST_PARTITION is set (CI exports
  # it): clear and restore it, as test/letflow/login_discovery_test.exs read_config/1 does.
  # Not async-safe against another test touching the same variable, hence the lock.
  defp read_config(env) do
    :global.trans({__MODULE__, self()}, fn ->
      saved = System.get_env("MIX_TEST_PARTITION")
      System.delete_env("MIX_TEST_PARTITION")

      try do
        Config.Reader.read!("config/config.exs", env: env, target: :host)
      after
        if saved, do: System.put_env("MIX_TEST_PARTITION", saved)
      end
    end)
  end

  defp strip_comments(source) do
    source
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
    |> Enum.join("\n")
  end

  # Every right-hand side written for the LoginDiscovery MOUNT key (not any other
  # `enabled:` in the file, e.g. oidc_jit_provisioning in config/prod.exs).
  @mount_enabled ~r/Letflow\.Routers\.LoginDiscovery,\s*\[?\s*enabled:\s*([^\n,\]]+)/

  defp mount_enabled_values(source) do
    @mount_enabled
    |> Regex.scan(strip_comments(source))
    |> Enum.map(fn [_, rhs] -> String.trim(rhs) end)
  end

  describe "criterion 1: shipped defaults (Config.Reader)" do
    test "for :prod the mount is exactly [enabled: false]" do
      assert get_in(read_config(:prod), [:letflow, @mount]) == [enabled: false]
    end

    test "for :dev and :test the mount may be true (and is)" do
      assert get_in(read_config(:dev), [:letflow, @mount]) == [enabled: true]
      assert get_in(read_config(:test), [:letflow, @mount]) == [enabled: true]
    end

    test "prod.exs's own unrelated `enabled: true` does not leak into the mount key" do
      prod = read_config(:prod)
      assert get_in(prod, [:letflow, @mount]) == [enabled: false]
      # the unrelated key really is a different one (scope sanity for the grep guard below)
      assert File.read!("config/prod.exs") =~ ~r/enabled:\s*true/
    end
  end

  describe "criterion 1: no committed config sets the mount true for :prod (scoped grep)" do
    test "the scan can fail: a seeded mount `enabled: true` is flagged, an unrelated one is not" do
      assert mount_enabled_values(
               "config :letflow, Letflow.Routers.LoginDiscovery, enabled: true"
             ) ==
               ["true"]

      assert mount_enabled_values(
               "config :letflow, Letflow.Routers.LoginDiscovery,\n  enabled: true"
             ) ==
               ["true"]

      assert mount_enabled_values("config :letflow, :oidc_jit_provisioning, enabled: true") == []

      assert mount_enabled_values(
               "# config :letflow, Letflow.Routers.LoginDiscovery, enabled: true"
             ) ==
               []
    end

    test "config.exs, prod.exs and runtime.exs never write a literal true for the mount" do
      for path <- ["config/config.exs", "config/prod.exs", "config/runtime.exs"] do
        values = path |> File.read!() |> mount_enabled_values()
        refute "true" in values, "#{path} sets the LoginDiscovery mount to a literal true"
      end
    end

    test "the only mount default is `config_env() != :prod` in config.exs, and runtime.exs defers to the parser" do
      assert "config.exs" |> then(&File.read!("config/" <> &1)) |> mount_enabled_values() ==
               ["config_env() != :prod"]

      runtime = File.read!("config/runtime.exs") |> strip_comments()
      assert mount_enabled_values(runtime) == ["login_discovery_enabled"]

      # the runtime default argument is "enabled iff not :prod", not a literal
      assert runtime =~
               ~r/parse_enabled\(\s*System\.get_env\("LETFLOW_LOGIN_DISCOVERY_ENABLED"\),\s*config_env\(\) != :prod\s*\)/
    end

    test "no other file under config/ sets it true for :prod (dev/test only)" do
      offenders =
        for path <- Path.wildcard("config/**/*.exs"),
            Path.basename(path) not in ["dev.exs", "test.exs"],
            "true" in mount_enabled_values(File.read!(path)),
            do: path

      assert offenders == []
    end
  end

  describe "criterion 1: no committed non-dev env/build file turns the SPA or server flag on" do
    @files ["web/.env.example", ".env.example", "deploy/.env.example", "deploy/Dockerfile"] ++
             Path.wildcard("web/.env*") ++
             Path.wildcard("deploy/docker-compose*.yml") ++
             Path.wildcard(".github/workflows/*.yml") ++ ["web/vite.config.ts"]

    defp active_lines(path) do
      path
      |> File.read!()
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
    end

    test "the scan can fail: a seeded true is flagged in env, ARG and build-arg forms" do
      re = ~r/VITE_EMAIL_FIRST_LOGIN\s*[=:]\s*["']?true/
      assert "VITE_EMAIL_FIRST_LOGIN=true" =~ re
      assert "ARG VITE_EMAIL_FIRST_LOGIN=true" =~ re
      assert "--build-arg VITE_EMAIL_FIRST_LOGIN=\"true\"" =~ re
      refute "VITE_EMAIL_FIRST_LOGIN=false" =~ re
    end

    test "web/.env.example ships VITE_EMAIL_FIRST_LOGIN=false (and the guarded file set is not empty)" do
      assert Enum.any?(active_lines("web/.env.example"), &(&1 == "VITE_EMAIL_FIRST_LOGIN=false"))
      assert length(Enum.filter(@files, &File.regular?/1)) >= 6
    end

    test "no committed env, Docker, compose, workflow or vite file sets VITE_EMAIL_FIRST_LOGIN true" do
      for path <- Enum.uniq(@files), File.regular?(path) do
        for line <- active_lines(path) do
          refute line =~ ~r/VITE_EMAIL_FIRST_LOGIN\s*[=:]\s*["']?true/i,
                 "#{path} enables VITE_EMAIL_FIRST_LOGIN: #{line}"
        end
      end
    end

    test "no committed deploy/CI file sets LETFLOW_LOGIN_DISCOVERY_ENABLED true, and the example files leave the marker blank" do
      for path <- Enum.uniq(@files), File.regular?(path), line <- active_lines(path) do
        refute line =~ ~r/LETFLOW_LOGIN_DISCOVERY_ENABLED\s*[=:]\s*["']?true/i,
               "#{path} enables the server flag: #{line}"
      end

      for path <- [".env.example", "deploy/.env.example"] do
        lines = active_lines(path)

        assert Enum.any?(lines, &(&1 == "LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION=")),
               "#{path}: marker must be present and blank"
      end
    end
  end

  describe "criterion: REQ-439's boot_check is unchanged in lib/letflow/plugs/client_ip.ex" do
    # The literal `git diff origin/main -- lib/letflow/plugs/client_ip.ex` is run by hand at
    # handoff (a permanent test of it would break any later legitimate edit of that file).
    # Permanent part: client_ip.ex has no knowledge of the new gate.
    test "client_ip.ex keeps boot_check/3 and does not reference the REQ-444 gate" do
      src = File.read!("lib/letflow/plugs/client_ip.ex")
      assert src =~ "def boot_check("
      refute src =~ "BootCheck"
      refute src =~ "LEGAL_CONFIRMATION"
      refute src =~ "MAIL_ADAPTER"
    end
  end

  describe "criterion 2/4: call-site guards in config/runtime.exs" do
    setup do
      {:ok, runtime: "config/runtime.exs" |> File.read!() |> strip_comments()}
    end

    defp pos!(source, needle) do
      case :binary.match(source, needle) do
        {pos, _} -> pos
        :nomatch -> flunk("runtime.exs does not contain #{inspect(needle)}")
      end
    end

    test "BootCheck runs after REQ-439's check and REQ-441's mail block, before the prod block",
         %{
           runtime: runtime
         } do
      client_ip = pos!(runtime, "Letflow.Plugs.ClientIp.boot_check(")
      mail = pos!(runtime, "Letflow.LoginDiscovery.Notifier.Smtp.Config.parse(")
      gate = pos!(runtime, "Letflow.LoginDiscovery.BootCheck.check(")
      prod = pos!(runtime, "if config_env() == :prod do")

      assert client_ip < mail
      assert mail < gate
      assert gate < prod
      # called exactly once
      assert length(String.split(runtime, "BootCheck.check(")) == 2
    end

    test "the gate is evaluated in every environment: not nested in the prod block", %{
      runtime: runtime
    } do
      assert pos!(runtime, "BootCheck.check(") < pos!(runtime, "if config_env() == :prod do")
    end

    test "the call passes config_env() as the env and the resolved mail adapter variable", %{
      runtime: runtime
    } do
      assert runtime =~
               ~r/BootCheck\.check\(\s*config_env\(\),\s*login_discovery_enabled,\s*\w+,\s*mail_adapter\s*\)/
    end

    test "the dev/test exemption reads no environment variable: BootCheck is pure and keyed on the env atom" do
      src = "lib/letflow/login_discovery/boot_check.ex" |> File.read!() |> strip_comments()

      # moduledoc/doc text is inside heredocs and may legally name variables; strip them
      code = Regex.replace(~r/@(module)?doc """.*?"""/s, src, "")

      for forbidden <- [
            "System.get_env",
            "System.fetch_env",
            "System.get_env!",
            "Application.get_env",
            "Application.fetch_env",
            "Mix.env",
            "System.put_env"
          ] do
        refute code =~ forbidden, "BootCheck must not call #{forbidden}"
      end

      assert code =~
               "def check(env, _enabled?, _marker, _adapter) when env in [:dev, :test], do: :ok"
    end
  end
end
