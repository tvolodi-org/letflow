defmodule Letflow.QaComposeProvisionerNetworkTest do
  @moduledoc """
  T-2780: the QA app joins the provisioner's external docker network through the tracked compose
  file (a join made by hand is dropped by the next CD deploy), and the provisioner's address passes
  the INV-9 base-URL check while public addresses do not.
  """
  use ExUnit.Case, async: true

  alias Letflow.Signup.RealmProvisioner

  @compose Path.expand("../../deploy/docker-compose.qa.yml", __DIR__)

  setup_all do
    {:ok, doc} = YamlElixir.read_from_file(@compose)
    %{doc: doc}
  end

  test "C1 app is on default and provisioner_callers", %{doc: doc} do
    assert doc["services"]["app"]["networks"] |> Enum.sort() == ["default", "provisioner_callers"]
  end

  test "C2 the network is external with infra's name", %{doc: doc} do
    assert doc["networks"]["provisioner_callers"] == %{
             "external" => true,
             "name" => "tenant-provisioner-qa_callers"
           }
  end

  test "C3 no host network and no new published port", %{doc: doc} do
    refute Enum.any?(doc["services"], fn {_, s} -> Map.get(s, "network_mode") == "host" end)
    assert doc["services"]["app"]["ports"] == ["127.0.0.1:3201:4000"]
    assert doc["services"]["db"]["ports"] == ["127.0.0.1:3202:5432"]
  end

  test "C4 sign-up is not enabled in the compose file" do
    refute File.read!(@compose) =~ "LETFLOW_SIGNUP_ENABLED"
  end

  test "U4 the provisioner address is accepted, public ones are refused" do
    assert RealmProvisioner.valid_base_url?("http://10.203.118.2:8080")

    for url <- [
          "http://8.8.8.8:8080",
          "http://provisioner.example.com:8080",
          "https://10.203.118.2:8080",
          "http://user@10.203.118.2:8080",
          "http://10.203.118.2:8080/v1"
        ] do
      refute RealmProvisioner.valid_base_url?(url), url
    end
  end
end
