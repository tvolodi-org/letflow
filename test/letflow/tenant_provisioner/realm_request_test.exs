defmodule Letflow.TenantProvisioner.RealmRequestTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.TenantProvisioner.RealmRequest

  @tid "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
  @realm "t-0a1b2c3d4e5f4a6b8c7d"
  @sentinel "SMTP-SENTINEL-9f3a"
  @smtp %{
    "host" => "smtp.example.test",
    "user" => "mailer",
    "password" => "${vault.smtp-password}"
  }
  @plain_smtp %{"host" => "smtp.example.test", "password" => @sentinel}

  defp build(overrides \\ []) do
    RealmRequest.build(
      Keyword.get(overrides, :tid, @tid),
      Keyword.get(overrides, :email, "  Owner@Example.COM "),
      Keyword.get(overrides, :host, "acme.demo.example.test"),
      Keyword.get(overrides, :smtp, @smtp),
      Keyword.take(overrides, [:pwa_uri])
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

  test "the realm roles the builder emits equal the closed role list minus PLATFORM_ADMIN" do
    roles = RealmRequest.template() |> get_in(["roles", "realm"]) |> Enum.map(& &1["name"])

    expected =
      Enum.map(Letflow.Api.Authorization.roles(), &Atom.to_string/1) -- ["PLATFORM_ADMIN"]

    assert Enum.sort(roles) == Enum.sort(expected)
    assert "STOREKEEPER" in roles
  end

  test "an invalid owner e-mail is refused" do
    assert {:error, :invalid_owner_email} == build(email: "not-an-email")
  end

  test "placeholders are replaced and no wildcard origin remains" do
    assert {:ok, body} = build()
    refute Jason.encode!(Map.delete(body, "smtpServer")) =~ ~r/__[A-Z_]+__/
    client = Enum.find(body["clients"], &(&1["clientId"] == "letflow-web"))

    assert client["redirectUris"] == [
             "https://acme.demo.example.test/auth/callback",
             "https://acme.demo.example.test/auth/callback?realm=t-0a1b2c3d4e5f4a6b8c7d9e0f1a2b3c4d"
           ]

    assert body["realm"] == @realm
    refute Enum.any?(client["redirectUris"], &String.contains?(&1, "*"))

    refute List.last(client["redirectUris"]) ==
             "https://acme.demo.example.test/auth/callback?realm=" <> @realm

    assert client["webOrigins"] == ["https://acme.demo.example.test"]
    refute "*" in client["webOrigins"]
  end

  test "empty, wildcard or malformed hostnames are refused" do
    for bad <- ["", "*", "*.example.test", "a b", "host/", nil] do
      assert {:error, :invalid_hostname} == build(host: bad)
    end
  end

  test "an SMTP map with a plaintext password is refused without echoing it" do
    for bad <- [
          @plain_smtp,
          %{"secret" => @sentinel},
          %{"auth" => %{"apiToken" => @sentinel}},
          "x"
        ] do
      assert {:error, :invalid_smtp} = r = build(smtp: bad)
      refute inspect(r) =~ @sentinel
    end
  end

  test "an SMTP password given as a vault reference builds and passes the full scan" do
    smtp = %{"host" => "smtp.example.test", "password" => "${vault.smtp-password}"}
    assert {:ok, body} = build(smtp: smtp)
    assert body["smtpServer"] == smtp
    refute Jason.encode!(body) =~ ~r/__[A-Z_]+__/
    assert plain_secret_keys(body) == []
  end

  test "error tuples carry no secret" do
    refute inspect(build(tid: "bad")) =~ @sentinel
    refute inspect(build(host: "*")) =~ @sentinel
  end

  test "the template and the builder output hold no secret material" do
    smtp = %{"host" => "smtp.example.test", "password" => "${vault.smtp-password}"}
    assert {:ok, body} = build(smtp: smtp)
    assert plain_secret_keys(RealmRequest.template()) == []
    assert plain_secret_keys(body) == []
    refute Jason.encode!(body) =~ @sentinel

    paths = Path.wildcard("priv/keycloak/provisioner/*/tenant-realm.json")
    assert paths != []

    for path <- paths do
      assert plain_secret_keys(path |> File.read!() |> Jason.decode!()) == []
    end
  end

  @pwa "https://letflow-qa.example.test/mobile/"

  defp mobile(body), do: Enum.find(body["clients"], &(&1["clientId"] == "letflow-mobile"))

  test "a new realm gets letflow-mobile with the exact native and PWA redirect URIs" do
    assert {:ok, body} = build(pwa_uri: @pwa)
    client = mobile(body)
    assert client["publicClient"] == true
    assert client["standardFlowEnabled"] == true
    assert client["directAccessGrantsEnabled"] == false
    assert client["implicitFlowEnabled"] == false
    assert client["attributes"]["pkce.code.challenge.method"] == "S256"
    assert client["redirectUris"] == ["com.bizdala.letflow:/oauth2redirect", @pwa]
    assert client["webOrigins"] == ["https://letflow-qa.example.test"]

    assert client["attributes"]["post.logout.redirect.uris"] ==
             "com.bizdala.letflow:/oauth2redirect##" <> @pwa

    names = Enum.map(client["protocolMappers"], & &1["name"])
    assert names == ["realm-roles", "letflow-mobile-audience"]
    refute Jason.encode!(Map.delete(body, "smtpServer")) =~ ~r/__[A-Z_]+__/
  end

  test "without a PWA uri the mobile client carries the native redirect only" do
    assert {:ok, body} = build()
    client = mobile(body)
    assert client["redirectUris"] == ["com.bizdala.letflow:/oauth2redirect"]
    assert client["webOrigins"] == []
    refute Jason.encode!(body) =~ ~r/__[A-Z_]+__/
  end

  test "a wildcard or malformed PWA uri is refused" do
    for bad <- [
          "https://*.example.test/mobile/",
          "https://example.test/*",
          "http://example.test/mobile/",
          "https://u@example.test/mobile/",
          "https://example.test/mobile/?a=1",
          "https://example.test/#x",
          "https://example.test:99999/m/",
          "",
          42
        ] do
      assert {:error, :invalid_pwa_uri} == build(pwa_uri: bad)
    end
  end

  test "existing realm: the client is created when missing and never replaced" do
    assert {:ok, [client]} = RealmRequest.ensure_mobile_client(["letflow-web"], @pwa)
    assert client["clientId"] == "letflow-mobile"
    assert client["redirectUris"] == ["com.bizdala.letflow:/oauth2redirect", @pwa]

    assert {:ok, []} = RealmRequest.ensure_mobile_client(["letflow-web", "letflow-mobile"], @pwa)
    assert {:error, :invalid_pwa_uri} = RealmRequest.ensure_mobile_client([], "https://*/")
  end

  # Forbidden keys whose value is not a Keycloak vault reference.
  @forbidden ~w(password secret credentials privateKey initial_password clientSecret)

  defp plain_secret_keys(%{} = map) do
    Enum.flat_map(map, fn {k, v} ->
      if k in @forbidden and not (is_binary(v) and v =~ ~r/\A\$\{vault\.[\w.-]+\}\z/),
        do: [k],
        else: plain_secret_keys(v)
    end)
  end

  defp plain_secret_keys(list) when is_list(list), do: Enum.flat_map(list, &plain_secret_keys/1)
  defp plain_secret_keys(_other), do: []
end
