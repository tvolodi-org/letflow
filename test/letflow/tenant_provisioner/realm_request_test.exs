defmodule Letflow.TenantProvisioner.RealmRequestTest do
  use ExUnit.Case, async: true

  alias Letflow.TenantProvisioner.RealmRequest

  @tid "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  @realm "t-0a1b2c3d4e5f4a6b8c7d"
  @sentinel "SMTP-SENTINEL-9f3a"
  @smtp %{"host" => "smtp.example.test", "user" => "mailer", "password" => @sentinel}

  defp build(overrides \\ []) do
    RealmRequest.build(
      Keyword.get(overrides, :tid, @tid),
      Keyword.get(overrides, :email, "  Owner@Example.COM "),
      Keyword.get(overrides, :host, "acme.demo.example.test"),
      Keyword.get(overrides, :smtp, @smtp)
    )
  end

  test "realm name is t- plus the first 20 hex digits" do
    assert {:ok, body} = build()
    assert body["realm"] == @realm
    assert body["realm"] =~ ~r/\At-[0-9a-f]{20}\z/
  end

  test "a tenant_id that is not a canonical UUID gives invalid_realm_id" do
    for bad <- ["master", String.duplicate("a", 65), String.upcase(@tid), "", nil, 42] do
      assert {:error, :invalid_realm_id} == build(tid: bad)
    end
  end

  test "first administrator is one inline user without admin rights" do
    assert {:ok, %{"users" => [user]} = body} = build()

    assert user == %{
             "username" => "owner@example.com",
             "email" => "owner@example.com",
             "enabled" => true,
             "emailVerified" => true,
             "realmRoles" => ["default-roles-" <> @realm]
           }

    json = Jason.encode!(body)
    refute json =~ "PLATFORM_ADMIN"
    refute json =~ "realm-management"
  end

  test "an invalid owner e-mail is refused" do
    assert {:error, :invalid_owner_email} == build(email: "not-an-email")
  end

  test "placeholders are replaced and no wildcard origin remains" do
    assert {:ok, body} = build()
    refute Jason.encode!(Map.delete(body, "smtpServer")) =~ ~r/__[A-Z_]+__/
    [client] = body["clients"]
    assert client["redirectUris"] == ["https://acme.demo.example.test/*"]
    assert client["webOrigins"] == ["https://acme.demo.example.test"]
    refute "*" in client["webOrigins"]
  end

  test "empty, wildcard or malformed hostnames are refused" do
    for bad <- ["", "*", "*.example.test", "a b", "host/", nil] do
      assert {:error, :invalid_hostname} == build(host: bad)
    end
  end

  test "smtpServer equals the argument and the secret appears nowhere else" do
    assert {:ok, body} = build()
    assert body["smtpServer"] == @smtp
    rest = body |> Map.delete("smtpServer") |> Jason.encode!()
    refute rest =~ @sentinel
    assert {:error, :invalid_smtp} == build(smtp: "x")
  end

  test "error tuples carry no secret" do
    refute inspect(build(tid: "bad")) =~ @sentinel
    refute inspect(build(host: "*")) =~ @sentinel
  end

  test "the template and the builder output hold no secret material" do
    forbidden = ~w(password secret credentials privateKey initial_password clientSecret)
    keys = fn data -> data |> collect_keys() |> Enum.filter(&(&1 in forbidden)) end

    assert {:ok, body} = build()
    assert keys.(RealmRequest.template()) == []
    assert keys.(Map.delete(body, "smtpServer")) == []

    paths = Path.wildcard("priv/keycloak/provisioner/*/tenant-realm.json")
    assert paths != []

    for path <- paths do
      assert keys.(path |> File.read!() |> Jason.decode!()) == []
    end
  end

  defp collect_keys(%{} = map),
    do: Enum.flat_map(map, fn {k, v} -> [k | collect_keys(v)] end)

  defp collect_keys(list) when is_list(list), do: Enum.flat_map(list, &collect_keys/1)
  defp collect_keys(_other), do: []
end
