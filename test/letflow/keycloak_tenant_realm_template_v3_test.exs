defmodule Letflow.KeycloakTenantRealmTemplateV3Test do
  @moduledoc """
  Drift test for the tenant realm template `priv/keycloak/provisioner/v3/tenant-realm.json`
  (T-2207). File-only. v3 is v2 plus the `letflow-mobile` client, copied from the dev seed
  `priv/keycloak/realms/bpm-default.json`, with the PWA address as placeholders.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @dir Path.expand("../../priv/keycloak/provisioner/v3", __DIR__)
  @template Path.join(@dir, "tenant-realm.json")
  @readme Path.join(@dir, "README.md")
  @v2 Path.expand("../../priv/keycloak/provisioner/v2/tenant-realm.json", __DIR__)
  @seed Path.expand("../../priv/keycloak/realms/bpm-default.json", __DIR__)

  defp load(path), do: path |> File.read!() |> Jason.decode!()
  defp client(realm, id), do: Enum.find(realm["clients"], &(&1["clientId"] == id))

  test "V3-version the directory is v3 and the version is 3" do
    assert Path.basename(@dir) == "v3"
    assert get_in(load(@template), ["attributes", "templateVersion"]) == "3"
    assert File.regular?(@readme)
  end

  test "V3-same v3 is v2 plus the mobile client and the version" do
    v3 = load(@template)
    assert Enum.map(v3["clients"], & &1["clientId"]) == ["letflow-web", "letflow-mobile"]

    stripped =
      v3
      |> Map.update!("clients", &Enum.take(&1, 1))
      |> put_in(["attributes", "templateVersion"], "2")

    assert stripped == load(@v2)
  end

  test "V3-mobile the mobile client matches the seed except for the PWA placeholders" do
    mobile = client(load(@template), "letflow-mobile")
    seed = client(load(@seed), "letflow-mobile")

    assert mobile["redirectUris"] == ["com.bizdala.letflow:/oauth2redirect", "__PWA_URI__"]
    assert mobile["webOrigins"] == ["__PWA_ORIGIN__"]
    assert mobile["publicClient"] == true
    assert mobile["standardFlowEnabled"] == true
    assert mobile["directAccessGrantsEnabled"] == false
    assert mobile["implicitFlowEnabled"] == false
    assert mobile["attributes"]["pkce.code.challenge.method"] == "S256"

    same = &Map.drop(&1, ["redirectUris", "webOrigins", "attributes"])
    assert same.(mobile) == same.(seed)
    assert mobile["attributes"]["pkce.code.challenge.method"] == "S256"
    refute Enum.any?(mobile["redirectUris"], &String.contains?(&1, "*"))
  end

  test "V3-placeholders the placeholder set is the v2 set plus the two PWA ones" do
    placeholders =
      ~r/__[A-Z_]+__/ |> Regex.scan(File.read!(@template)) |> List.flatten() |> Enum.uniq()

    assert Enum.sort(placeholders) ==
             [
               "__PWA_ORIGIN__",
               "__PWA_URI__",
               "__REALM_ID__",
               "__TENANT_HOST__",
               "__TENANT_SLUG__"
             ]
  end

  test "V3-readme names the mobile client rules" do
    readme = File.read!(@readme)

    for s <- ~w(letflow-mobile __PWA_URI__ __PWA_ORIGIN__ ensure_mobile_client),
        do: assert(readme =~ s)
  end
end
