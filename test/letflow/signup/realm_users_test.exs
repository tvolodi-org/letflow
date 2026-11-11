defmodule Letflow.Signup.RealmUsersTest do
  @moduledoc """
  T-1730 (REQ-807): the provisioner client for one realm login (U1..U8) against the loopback stub.
  `async: false`: application and OS env.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Signup.RealmProvisioner
  alias Letflow.Signup.RealmUsers
  alias Letflow.Test.ProvisionerStub, as: Stub

  @token "tok-SECRET-users-unit"
  @tenant_id "11111111-2222-3333-4444-555555555555"
  @attrs %{username: "jane", email: "jane@example.com", display_name: "Jane"}

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    original = Application.fetch_env(:letflow, RealmUsers)
    System.put_env(RealmUsers.token_env(), @token)

    on_exit(fn ->
      System.delete_env(RealmUsers.token_env())

      case original do
        {:ok, value} -> Application.put_env(:letflow, RealmUsers, value)
        :error -> Application.delete_env(:letflow, RealmUsers)
      end
    end)

    :ok
  end

  defp good(overrides \\ %{}) do
    Map.merge(
      %{
        "realm" => RealmProvisioner.label(@tenant_id),
        "user_id" => Ecto.UUID.generate(),
        "temporary_password" => "Tmp-Pa55"
      },
      overrides
    )
  end

  defp stub!(script) do
    stub = Stub.start!(script)
    Application.put_env(:letflow, RealmUsers, enabled: true, provisioner_url: stub.url)
    stub
  end

  test "U0 success returns the user id and password; request path, bearer and body" do
    stub = stub!([{201, good()}])

    assert {:ok, %{user_id: id, temporary_password: "Tmp-Pa55"}} =
             RealmUsers.create_login(@tenant_id, @attrs)

    assert {:ok, _} = Ecto.UUID.cast(id)

    assert [call] = Stub.calls(stub)
    assert call.path == "/v1/realms/#{@tenant_id}/users"
    assert call.auth == "Bearer " <> @token

    assert call.body == %{
             "username" => "jane",
             "email" => "jane@example.com",
             "display_name" => "Jane"
           }
  end

  test "U1 a bad base URL makes no request" do
    stub = Stub.start!([{201, good()}])

    Application.put_env(:letflow, RealmUsers,
      enabled: true,
      provisioner_url: "http://example.com:80"
    )

    assert {:error, :bad_url} = RealmUsers.create_login(@tenant_id, @attrs)
    assert Stub.calls(stub) == []
  end

  test "U2 a missing token or URL is not_configured; configured?/0 agrees" do
    stub = stub!([{201, good()}])
    assert RealmUsers.configured?()
    System.delete_env(RealmUsers.token_env())
    refute RealmUsers.configured?()
    assert {:error, :not_configured} = RealmUsers.create_login(@tenant_id, @attrs)
    assert Stub.calls(stub) == []
    Application.put_env(:letflow, RealmUsers, enabled: true, provisioner_url: nil)
    System.put_env(RealmUsers.token_env(), @token)
    refute RealmUsers.configured?()
    Application.put_env(:letflow, RealmUsers, enabled: false, provisioner_url: stub.url)
    refute RealmUsers.configured?()
  end

  test "U3 a response for another realm is bad_response" do
    stub!([{201, good(%{"realm" => "t-00000000000000000000"})}])
    assert {:error, :bad_response} = RealmUsers.create_login(@tenant_id, @attrs)
  end

  test "U4 a body over 64 KiB is bad_response" do
    stub!([{201, good(%{"temporary_password" => String.duplicate("x", 70_000)})}])
    assert {:error, :bad_response} = RealmUsers.create_login(@tenant_id, @attrs)
  end

  test "U5 the status map" do
    for {status, expected} <- [
          {409, :login_exists},
          {404, :realm_not_provisioned},
          {401, :unauthorized},
          {403, :unauthorized},
          {429, :rate_limited},
          {422, :invalid_request},
          {503, :unavailable}
        ] do
      stub!([{status, %{}}])
      assert {:error, ^expected} = RealmUsers.create_login(@tenant_id, @attrs)
    end
  end

  test "U6 a transport failure is unavailable" do
    Application.put_env(:letflow, RealmUsers,
      enabled: true,
      provisioner_url: "http://127.0.0.1:1"
    )

    assert {:error, :unavailable} = RealmUsers.create_login(@tenant_id, @attrs)
  end

  test "U7 an invalid or non-canonical user_id is bad_response" do
    stub!([{201, good(%{"user_id" => "not-a-uuid"})}])
    assert {:error, :bad_response} = RealmUsers.create_login(@tenant_id, @attrs)
    stub!([{201, good(%{"user_id" => String.replace(Ecto.UUID.generate(), "-", "")})}])
    assert {:error, :bad_response} = RealmUsers.create_login(@tenant_id, @attrs)
  end

  test "U8 an empty or over-256-byte password is bad_response" do
    for pw <- ["", String.duplicate("p", 257)] do
      stub!([{201, good(%{"temporary_password" => pw})}])
      assert {:error, :bad_response} = RealmUsers.create_login(@tenant_id, @attrs)
    end
  end
end
