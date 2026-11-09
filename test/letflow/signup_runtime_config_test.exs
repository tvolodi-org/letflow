defmodule Letflow.SignupRuntimeConfigTest do
  @moduledoc """
  T-1579 (F2, F3): the sign-up flag and settings in `config/runtime.exs`, evaluated in-process with
  `Letflow.Test.RuntimeConfigEval`. Default OFF; strict boolean; positive-integer settings; an enabled
  flag outside dev/test needs trusted proxies and an https base URL. No value is echoed (INV-4).
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Test.RuntimeConfigEval, as: R

  setup do
    R.isolate_env()
    :ok
  end

  defp signup(vars, env \\ :test) do
    {result, _stderr} = R.evaluate(Map.merge(R.valid_base(), Map.new(vars)), env)
    result
  end

  defp config!(vars) do
    {:ok, config} = signup(vars)
    config |> Keyword.fetch!(:letflow) |> Keyword.fetch!(Letflow.Signup) |> Map.new()
  end

  test "F2 default is off, with the shipped starting values" do
    cfg = config!([])
    assert cfg.enabled == false
    assert cfg.pending_cap == 50
    assert cfg.ip_hourly_cap == 5
    assert cfg.resend_interval_seconds == 60
    assert cfg.token_ttl_hours == 24
    assert cfg.abandon_days == 7
  end

  test "F2 true and false are accepted, anything else raises without echoing the value" do
    assert config!([{"LETFLOW_SIGNUP_ENABLED", "true"}]).enabled == true
    assert config!([{"LETFLOW_SIGNUP_ENABLED", "false"}]).enabled == false

    assert {:raised, message, formatted} = signup([{"LETFLOW_SIGNUP_ENABLED", "yes-sneaky"}])
    assert message =~ "LETFLOW_SIGNUP_ENABLED"
    refute message =~ "sneaky"
    refute formatted =~ "sneaky"
  end

  test "F3 each setting changes its value, a bad one raises" do
    cfg =
      config!([
        {"LETFLOW_SIGNUP_BASE_URL", "https://qa.example.test"},
        {"LETFLOW_SIGNUP_PENDING_CAP", "7"},
        {"LETFLOW_SIGNUP_IP_HOURLY_CAP", "2"},
        {"LETFLOW_SIGNUP_RESEND_INTERVAL_SECONDS", "5"},
        {"LETFLOW_SIGNUP_TOKEN_TTL_HOURS", "3"},
        {"LETFLOW_SIGNUP_ABANDON_DAYS", "9"}
      ])

    assert {cfg.base_url, cfg.pending_cap, cfg.ip_hourly_cap, cfg.resend_interval_seconds,
            cfg.token_ttl_hours, cfg.abandon_days} ==
             {"https://qa.example.test", 7, 2, 5, 3, 9}

    for var <- ~w(LETFLOW_SIGNUP_PENDING_CAP LETFLOW_SIGNUP_IP_HOURLY_CAP
                  LETFLOW_SIGNUP_RESEND_INTERVAL_SECONDS LETFLOW_SIGNUP_TOKEN_TTL_HOURS
                  LETFLOW_SIGNUP_ABANDON_DAYS) do
      assert {:raised, message, _} = signup([{var, "0x9"}])
      assert message =~ var
      refute message =~ "0x9"
    end
  end

  test "F2 enabled in prod needs trusted proxies and an https base URL" do
    prod = [
      {"DATABASE_URL", "ecto://dummy:dummy@localhost/dummy"},
      {"LETFLOW_SIGNUP_ENABLED", "true"}
    ]

    assert {:raised, message, _} =
             signup(prod ++ [{"LETFLOW_SIGNUP_BASE_URL", "https://x.test"}], :prod)

    assert message =~ "LETFLOW_TRUSTED_PROXIES"

    proxied = prod ++ [{"LETFLOW_TRUSTED_PROXIES", "10.0.0.0/8"}]

    assert {:raised, message, _} =
             signup(proxied ++ [{"LETFLOW_SIGNUP_BASE_URL", "http://x.test"}], :prod)

    assert message =~ "LETFLOW_SIGNUP_BASE_URL"
    assert {:raised, message, _} = signup(proxied, :prod)
    assert message =~ "LETFLOW_SIGNUP_BASE_URL"
  end
end
