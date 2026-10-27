defmodule Letflow.TenantProvisioner.RealmRequestTest do
  use ExUnit.Case, async: true

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
