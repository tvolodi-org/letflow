defmodule Letflow.RealmUsersRuntimeConfigTest do
  @moduledoc """
  T-1730 (REQ-807): the `LETFLOW_REALM_USERS_*` settings in `config/runtime.exs`, evaluated in-process with
  `Letflow.Test.RuntimeConfigEval` (C1..C4). Default OFF; exactly "true" enables; no value is echoed.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Test.RuntimeConfigEval, as: R

  setup do
    R.isolate_env()
    :ok
  end

  @url "http://127.0.0.1:9100"

  defp eval(vars) do
    {result, _stderr} = R.evaluate(Map.merge(R.valid_base(), Map.new(vars)), :test)
    result
  end

  defp config!(vars) do
    {:ok, config} = eval(vars)
    config |> Keyword.fetch!(:letflow) |> Keyword.fetch!(Letflow.Signup.RealmUsers) |> Map.new()
  end

  test "C4 default is off with no URL" do
    assert config!([]) == %{enabled: false, provisioner_url: nil}
    assert config!([{"LETFLOW_REALM_USERS_ENABLED", ""}]).enabled == false
  end

  test "C1 anything but true raises without echoing the value, false included" do
    for value <- ["yes", "1", "TRUE", "false", "sneaky-value"] do
      assert {:raised, message, formatted} = eval([{"LETFLOW_REALM_USERS_ENABLED", value}])
      assert message =~ "LETFLOW_REALM_USERS_ENABLED"
      refute message =~ value
      refute formatted =~ "sneaky"
    end
  end

  test "C2 true needs both URL and token" do
    full = [
      {"LETFLOW_REALM_USERS_ENABLED", "true"},
      {"LETFLOW_REALM_USERS_PROVISIONER_URL", @url},
      {"LETFLOW_REALM_USERS_PROVISIONER_TOKEN", "tok-secret-9"}
    ]

    assert config!(full) == %{enabled: true, provisioner_url: @url}

    for drop <- ["LETFLOW_REALM_USERS_PROVISIONER_URL", "LETFLOW_REALM_USERS_PROVISIONER_TOKEN"] do
      assert {:raised, message, formatted} = eval(Enum.reject(full, &(elem(&1, 0) == drop)))
      assert message =~ "must be set together"
      refute formatted =~ "tok-secret-9"
    end
  end

  test "C3 URL or token without the flag raises; a bad URL raises without echo" do
    assert {:raised, _, _} = eval([{"LETFLOW_REALM_USERS_PROVISIONER_URL", @url}])
    assert {:raised, _, _} = eval([{"LETFLOW_REALM_USERS_PROVISIONER_TOKEN", "tok-secret-9"}])

    assert {:raised, message, formatted} =
             eval([
               {"LETFLOW_REALM_USERS_ENABLED", "true"},
               {"LETFLOW_REALM_USERS_PROVISIONER_URL", "http://evil.example.com:80"},
               {"LETFLOW_REALM_USERS_PROVISIONER_TOKEN", "tok-secret-9"}
             ])

    assert message =~ "PROVISIONER_URL"
    refute formatted =~ "evil.example.com"
  end
end
