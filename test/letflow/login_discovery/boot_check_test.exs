defmodule Letflow.LoginDiscovery.BootCheckTest do
  # Pure decision-table test for REQ-444's email-first enablement gate.
  # No DB, no subprocess, no config reads.
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.LoginDiscovery.BootCheck

  @smtp Letflow.LoginDiscovery.Notifier.Smtp
  @noop Letflow.LoginDiscovery.Notifier.Noop
  @double Letflow.LoginDiscoveryNotifierDouble

  @exempt_envs [:dev, :test]
  @gated_envs [:prod, :staging, :qa_ish, :"prod-eu", :anything_else]

  # The rule is the TRIMMED CHARACTER count (String.length(String.trim(marker)) >= 8),
  # not the byte size. "ééééé" is 5 characters (10 bytes), so it is invalid.
  @valid_markers [
    {"exactly 8 chars", "abcdefgh"},
    {"long", "legal-confirmed-by-counsel-2026"},
    {"8 chars with surrounding whitespace", "  abcdefgh \n"},
    {"8 multi-byte characters", "éééééééé"}
  ]

  @invalid_markers [
    {"nil", nil},
    {"empty", ""},
    {"blank", "   "},
    {"7 chars", "abcdefg"},
    {"8 chars that trim below 8", "  abc    "},
    {"integer", 123},
    {"atom", :atom},
    {"list", ["abcdefgh"]},
    {"5 characters, 10 bytes", "ééééé"}
  ]

  @non_delivering [
    {"nil", nil},
    {"Noop", @noop},
    {"test double", @double},
    {"unknown atom", Some.Unknown.Adapter},
    {"string", "Elixir.Letflow.LoginDiscovery.Notifier.Smtp"},
    {"integer", 42}
  ]

  describe "dev/test exemption (keys on the env atom only)" do
    test "always :ok in :dev/:test regardless of enabled?, marker, adapter" do
      for env <- @exempt_envs,
          enabled? <- [true, false],
          {_, marker} <- @valid_markers ++ @invalid_markers,
          {_, adapter} <- [{"smtp", @smtp} | @non_delivering] do
        assert BootCheck.check(env, enabled?, marker, adapter) == :ok
      end
    end
  end

  describe "feature disabled" do
    test "always :ok in any env when enabled? is false" do
      for env <- @exempt_envs ++ @gated_envs,
          {_, marker} <- @valid_markers ++ @invalid_markers,
          {_, adapter} <- [{"smtp", @smtp} | @non_delivering] do
        assert BootCheck.check(env, false, marker, adapter) == :ok
      end
    end
  end

  describe "enabled outside dev/test" do
    test "missing/short/non-binary marker -> :missing_confirmation, reported before the adapter" do
      for env <- @gated_envs,
          {label, marker} <- @invalid_markers,
          {_, adapter} <- [{"smtp", @smtp} | @non_delivering] do
        assert BootCheck.check(env, true, marker, adapter) == {:error, :missing_confirmation},
               "env=#{env} marker=#{label}"
      end
    end

    test "valid marker + non-delivering adapter -> :adapter_not_delivering" do
      for env <- @gated_envs,
          {mlabel, marker} <- @valid_markers,
          {alabel, adapter} <- @non_delivering do
        assert BootCheck.check(env, true, marker, adapter) == {:error, :adapter_not_delivering},
               "env=#{env} marker=#{mlabel} adapter=#{alabel}"
      end
    end

    test "valid marker + Smtp -> :ok" do
      for env <- @gated_envs, {label, marker} <- @valid_markers do
        assert BootCheck.check(env, true, marker, @smtp) == :ok, "env=#{env} marker=#{label}"
      end
    end

    test "the exemption is by env atom: string env names are not exempt" do
      assert BootCheck.check("dev", true, nil, nil) == {:error, :missing_confirmation}
    end
  end

  describe "constants" do
    test "delivering_adapters/0 is the explicit fail-closed allowlist" do
      # Adding an adapter here is a gate change and needs SECURITY-REVIEWER sign-off.
      assert BootCheck.delivering_adapters() == [Letflow.LoginDiscovery.Notifier.Smtp]
      refute @noop in BootCheck.delivering_adapters()
      refute @double in BootCheck.delivering_adapters()
    end

    test "min_marker_length/0 is 8" do
      assert BootCheck.min_marker_length() == 8
    end
  end

  describe "message/1" do
    test "names the env vars and is identical across calls" do
      m1 = BootCheck.message(:missing_confirmation)
      assert m1 =~ "LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION"
      assert m1 == BootCheck.message(:missing_confirmation)

      m2 = BootCheck.message(:adapter_not_delivering)
      assert m2 =~ "LETFLOW_MAIL_ADAPTER"
      assert m2 == BootCheck.message(:adapter_not_delivering)
    end

    test "never contains a supplied marker or adapter value" do
      marker = "zz-marker-70011"
      adapter = ZzAdapter70011

      {:error, reason} = BootCheck.check(:prod, true, marker, adapter)
      assert reason == :adapter_not_delivering
      msg = BootCheck.message(reason)
      refute msg =~ marker
      refute msg =~ "ZzAdapter70011"

      {:error, reason2} = BootCheck.check(:prod, true, "zz-shrt", adapter)
      assert reason2 == :missing_confirmation
      refute BootCheck.message(reason2) =~ "zz-shrt"
      refute BootCheck.message(reason2) =~ "ZzAdapter70011"
    end

    test "generic fallback for an unknown reason names both variables" do
      msg = BootCheck.message(:something_else)
      assert msg =~ "LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION"
      assert msg =~ "LETFLOW_MAIL_ADAPTER"
      refute msg =~ "something_else"
    end
  end

  describe "robustness" do
    test "check/4 never raises for odd inputs" do
      odd = [nil, 123, :atom, "str", 1.5, [], %{}, {:a, :b}]

      for env <- [:prod, :dev], enabled? <- [true, false], marker <- odd, adapter <- odd do
        assert BootCheck.check(env, enabled?, marker, adapter) in [
                 :ok,
                 {:error, :missing_confirmation},
                 {:error, :adapter_not_delivering}
               ]
      end
    end
  end
end
