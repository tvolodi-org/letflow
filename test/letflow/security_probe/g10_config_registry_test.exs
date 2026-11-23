defmodule Letflow.SecurityProbe.G10ConfigRegistryTest do
  @moduledoc """
  G-10: the config/env/flag registry (team coverage map, `docs/security-coverage.md`, gap G-10).

  The registry `priv/config_registry.txt` says which environment variable, application
  environment key, flag, secret and URL the product has, who owns it, why it exists, how it is
  read and whether its absence must fail closed. This probe derives the other half from the
  tree -- every environment variable and every application environment key the sources read,
  with the form of each read -- and fails until the two agree. A new setting therefore cannot
  be added without a registered reason, a feature flag cannot be switched on by default, a
  fail-closed setting cannot be read with a default that takes effect, and a secret cannot
  come with a literal.

  The derivation is `Letflow.Support.ConfigRegistryScan` (test/support): it parses the sources
  with `Code.string_to_quoted!/2` and starts nothing. The seeded failing variants live in
  `test/fixtures/security_probes/g10/broken_tree`: a tree that breaks one rule per setting, so
  the probe is proved to catch each of them.

  Pure: no database, no network, no clock, no model.
  """

  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :security_probe
  @moduletag probe_cost_s: 13
  @moduletag timeout: 300_000

  alias Letflow.Secrets.LogFilter
  alias Letflow.Support.ConfigRegistryScan, as: Scan
  alias Letflow.Webhooks.UrlValidator

  @root Path.expand("../../..", __DIR__)
  @broken_tree Path.join([@root, "test", "fixtures", "security_probes", "g10", "broken_tree"])

  setup_all do
    {:ok, inventory: Scan.inventory(@root), findings: Scan.findings(@root)}
  end

  test "G10: every setting the product reads is in the config/env/flag registry" do
    findings = Scan.findings(@root)

    assert findings == [],
           "the config/env/flag registry does not match the tree:\n" <> Scan.summarize(findings)
  end

  describe "M1 the derivation reads something" do
    test "the inventory of the tree is not empty", %{inventory: inventory} do
      assert inventory.files > 0, "the scan read no source"
      assert inventory.env != [], "the scan found no environment variable"
      assert inventory.app_env != [], "the scan found no application environment key"
      assert inventory.unparsable == [], "a source could not be parsed"
    end

    test "the same tree yields the same inventory twice" do
      first = Scan.inventory(@broken_tree)
      second = Scan.inventory(@broken_tree)

      assert Enum.map(first.env, &{&1.name, &1.file, &1.line}) ==
               Enum.map(second.env, &{&1.name, &1.file, &1.line})

      assert Enum.map(first.app_env, &{&1.name, &1.file, &1.line}) ==
               Enum.map(second.app_env, &{&1.name, &1.file, &1.line})
    end
  end

  describe "M2 the registry and the tree agree" do
    test "the registry of the product covers every setting the tree reads", %{findings: findings} do
      assert findings == [],
             "the config/env/flag registry does not match the tree:\n" <> Scan.summarize(findings)
    end
  end

  describe "N1 the seeded failing variants are caught" do
    test "every deliberate defect of the fixture tree is reported" do
      findings = Scan.findings(@broken_tree)

      reported = Enum.map(findings, &{&1.code, &1.name})

      assert {:unregistered_env, "env:G10_UNREGISTERED_SETTING"} in reported
      assert {:unregistered_env, "env:G10_LIST_SETTING"} in reported
      assert {:unregistered_env, "env:G10_ATTRIBUTE_SETTING"} in reported
      assert {:unregistered_env, "env:G10_LOCAL_SETTING"} in reported
      assert {:unregistered_env, "env:G10_ATTRIBUTE_LIST_SETTING"} in reported
      assert {:unregistered_env, "env:G10_HEAD_DEFAULT_SETTING"} in reported
      assert {:unregistered_env, "env:G10_ENV_MAP_SETTING"} in reported
      assert {:flag_not_off, "app_env::letflow:g10_flag_enabled"} in reported
      assert {:flag_not_off, "app_env::letflow:g10_release_flag"} in reported
      assert {:flag_not_off, "app_env::letflow:g10_keyword_flag"} in reported
      assert {:secret_literal_default, "app_env::letflow:g10_secret"} in reported
      assert {:fail_closed_permissive, "app_env::letflow:g10_secret"} in reported
      assert {:read_mode_mismatch, "the registry"} in reported
      assert {:stale_entry, "app_env::letflow:g10_stale"} in reported
      assert {:url_without_validator, "app_env::letflow:g10_url"} in reported
      assert {:url_without_validator, "app_env::letflow:g10_startup_url"} in reported
      assert {:guard_not_on, "app_env::letflow:g10_guard"} in reported
      assert Enum.any?(reported, &match?({:malformed_entry, _name}, &1))
    end

    test "each form a variable can be named in is found by that form" do
      inventory = Scan.inventory(@broken_tree)

      forms =
        inventory.env
        |> Enum.map(fn site -> {site.name, site.form, site.file} end)
        |> Enum.filter(fn {name, _form, _file} -> String.starts_with?(name, "G10_") end)
        |> Enum.sort()

      assert forms == [
               {"G10_ATTRIBUTE_LIST_SETTING", :literal, "lib/g10_broken.ex"},
               {"G10_ATTRIBUTE_SETTING", :get_env, "lib/g10_broken.ex"},
               {"G10_ENV_MAP_SETTING", :literal, "lib/g10_env_map.ex"},
               {"G10_HEAD_DEFAULT_SETTING", :get_env, "lib/g10_broken.ex"},
               {"G10_LIST_SETTING", :literal, "lib/g10_broken.ex"},
               {"G10_LOCAL_SETTING", :get_env, "lib/g10_broken.ex"},
               {"G10_UNREGISTERED_SETTING", :get_env, "lib/g10_broken.ex"}
             ]
    end

    test "a list of something else is not a list of variables" do
      inventory = Scan.inventory(@broken_tree)

      names = Enum.map(inventory.env, & &1.name)

      refute "G10_STATUS_PENDING" in names,
             "a list of statuses whose consumer does not read the environment was taken for variables"

      refute "G10_STATUS_DONE" in names,
             "a list of statuses whose consumer does not read the environment was taken for variables"
    end

    test "the fixture tree is broken on purpose and the real tree is not" do
      assert Scan.findings(@broken_tree) != []
      assert Scan.findings(@root) == []
    end
  end

  describe "P1 the shared address validator fails closed" do
    @hostile [
      {"the empty address", ""},
      {"an address that is not an address", "not a url"},
      {"a plain http address", "http://example.test/x"},
      {"an ftp address", "ftp://example.test/x"},
      {"an address without a host", "https:///x"},
      {"a loopback address", "https://127.0.0.1/x"},
      {"a link local address", "https://169.254.169.254/latest/meta-data"},
      {"a private address", "https://10.0.0.5/"},
      {"a loopback address of the sixth version", "https://[::1]/x"},
      {"a unique local address", "https://[fd00::1]/x"},
      {"a mapped loopback address", "https://[::ffff:127.0.0.1]/x"},
      {"a userinfo that hides a loopback address", "https://good.example@127.0.0.1/x"}
    ]

    test "every hostile address is refused" do
      for {label, url} <- @hostile do
        assert refuses?(fn -> UrlValidator.validate_syntactic(url) end),
               "the validator accepted #{label} (#{url})"
      end
    end

    test "an address of the wrong type is refused and does not answer :ok" do
      assert refuses?(fn -> apply(UrlValidator, :validate_syntactic, [123]) end)
    end

    test "an address that resolves to a private address is refused" do
      resolver = fn _host -> {:ok, [{:inet, {127, 0, 0, 1}, []}]} end

      assert {:error, :target_url_not_allowed} ==
               UrlValidator.validate("https://internal.example/x", resolver)
    end

    test "an address whose host does not resolve is refused" do
      resolver = fn _host -> {:error, :nxdomain} end

      assert {:error, :target_url_not_allowed} ==
               UrlValidator.validate("https://example.test/x", resolver)
    end
  end

  describe "P2 a secret reaches no log line" do
    test "a canary under a secret key is redacted out of the log metadata" do
      canary = "g10-canary-secret-value"

      event = %{level: :error, msg: "boom", meta: %{api_token: canary, request_id: "r-1"}}

      filtered = LogFilter.filter(event, nil)

      assert filtered.meta.api_token == "[REDACTED]"
      assert filtered.meta.request_id == "r-1"
      refute filtered.meta.api_token == canary
    end

    test "the message of a log event is not redacted, which is the known limit of the product" do
      canary = "g10-canary-secret-value"

      event = %{level: :error, msg: "token #{canary}", meta: %{request_id: "r-1"}}

      filtered = LogFilter.filter(event, nil)

      assert filtered.msg == "token #{canary}"
    end
  end

  # A refusal is anything that is not :ok: an error tuple and a raise both refuse. The
  # validator is called with a hostile value, so a crash is a refusal and not a pass.
  defp refuses?(fun) do
    fun.() != :ok
  rescue
    _error -> true
  end
end
