defmodule Letflow.PlatformFunctions.Impl.TenantProvisionRealmAndInviteTest do
  @moduledoc """
  The body of `tenant.provision_realm_and_invite` (T-3153, owner item 11 / D-195, slice G1; design
  `docs/design/provision-realm-and-invite-paths.md` rows P1..P3 and A3), against the provisioner stub
  (Bandit on a loopback port, real `:httpc`) and the notifier double.

    * PR1 -- P1 success: the realm id is the output, ONE mail carries the one-time password, the
      provisioner got the bearer and the tenant id as its key;
    * PR2 -- P2 realm create fails (500, timeout): nothing mailed, a code; the retry asks the provisioner
      again with the SAME key and succeeds;
    * PR3 -- P3 invite fails after the realm exists: a code; the retry is a replay (no second realm, no
      password) and repeats the invite as the "Forgot password" hint;
    * PR4 -- replay of a finished step: provisioner replay, a hint mail, same realm id;
    * PR5 -- masked logs: no password, address, realm, hostname or token in any log line, error or output;
    * PR6 -- configuration absent (URL, token, hostname domain): refused before any call, no POST;
    * PR7 -- bad inputs refused before any call (SF-01), language fallback and the three languages;
    * PR8 -- the body is registered, its codes are codes of the dispatch row.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Letflow.Test.SignupHelpers, only: [enable!: 1]

  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.PlatformFunctions.Impl.TenantProvisionRealmAndInvite, as: Body
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.Signup.RealmProvisioner
  alias Letflow.Test.ProvisionerStub, as: Stub

  @token "tok-SECRET-caller-token"
  @password "Tmp-Pa55-ONE-time"

  setup do
    System.put_env(RealmProvisioner.token_env(), @token)
    on_exit(fn -> System.delete_env(RealmProvisioner.token_env()) end)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, tenant_id: Ecto.UUID.generate()}
  end

  defp configure!(stub, overrides \\ []) do
    enable!(
      Keyword.merge(
        [
          provisioner_url: stub.url,
          hostname_domain: "qa.example.test",
          http_timeout_ms: 500,
          connect_timeout_ms: 500
        ],
        overrides
      )
    )
  end

  defp context(tenant_id, overrides \\ %{}) do
    %{
      inputs:
        Map.merge(
          %{
            "tenant_id" => tenant_id,
            "admin_email" => "owner@example.test",
            "name" => "Acme Ltd",
            "slug" => "acme",
            "language" => "en"
          },
          overrides
        ),
      dispatch: %{instance_id: Ecto.UUID.generate()}
    }
  end

  defp mails do
    receive do
      {:deliver_message, m} -> [m | mails()]
    after
      100 -> []
    end
  end

  defp replay(tenant_id), do: Stub.created(tenant_id, %{"first_admin" => nil})

  test "PR1 success: realm id out, one mail with the password, key and bearer to the provisioner",
       %{tenant_id: tenant_id} do
    stub = Stub.start!([{201, Stub.created(tenant_id)}])
    configure!(stub)
    label = RealmProvisioner.label(tenant_id)

    assert {:ok, outputs} = Body.run(context(tenant_id))
    assert outputs == %{"realm_id" => label}
    refute inspect(outputs) =~ @password

    assert [%{to: "owner@example.test", body: body}] = mails()
    assert body =~ @password

    assert [post] = Stub.posts(stub)
    assert post.auth == "Bearer " <> @token
    assert post.body["tenant_id"] == tenant_id
    assert post.body["owner_email"] == "owner@example.test"
    assert post.body["hostname"] == "acme.qa.example.test"
  end

  test "PR2 realm create fails: nothing mailed; the retry uses the same key", %{
    tenant_id: tenant_id
  } do
    stub = Stub.start!([{500, %{}}, {201, Stub.created(tenant_id)}])
    configure!(stub)

    assert {:error, :platform_call_realm_create_failed} = Body.run(context(tenant_id))
    assert mails() == []

    assert {:ok, %{"realm_id" => _}} = Body.run(context(tenant_id))
    assert length(mails()) == 1

    keys = stub |> Stub.posts() |> Enum.map(& &1.body["tenant_id"])
    assert keys == [tenant_id, tenant_id]
  end

  test "PR2 a provisioner timeout is the same code, nothing mailed", %{tenant_id: tenant_id} do
    stub = Stub.start!([{200, {:sleep, 1500}}])
    configure!(stub, http_timeout_ms: 100)

    assert {:error, :platform_call_realm_create_failed} = Body.run(context(tenant_id))
    assert mails() == []
  end

  test "PR3 invite fails after the realm exists: the retry is a replay and repeats the invite", %{
    tenant_id: tenant_id
  } do
    stub = Stub.start!([{201, Stub.created(tenant_id)}, {200, replay(tenant_id)}])
    configure!(stub)

    Double.set_behaviour(:error)
    assert {:error, :platform_call_invite_failed} = Body.run(context(tenant_id))

    # The double reports the attempt even when it fails: that first (failed) message holds the password.
    assert [%{body: failed_body}] = mails()
    assert failed_body =~ @password

    Double.set_behaviour(:ok)
    assert {:ok, %{"realm_id" => realm}} = Body.run(context(tenant_id))
    assert realm == RealmProvisioner.label(tenant_id)

    sent = mails()
    assert length(sent) == 1
    refute hd(sent).body =~ @password
    assert [_, _] = Stub.posts(stub)
  end

  test "PR4 a replay of a finished step sends the hint, never a password", %{
    tenant_id: tenant_id
  } do
    stub = Stub.start!([{200, replay(tenant_id)}])
    configure!(stub)

    assert {:ok, %{"realm_id" => _}} = Body.run(context(tenant_id))
    assert {:ok, %{"realm_id" => _}} = Body.run(context(tenant_id))
    assert Enum.all?(mails(), &(not (&1.body =~ @password)))
  end

  test "PR5 no password, address, realm, hostname or token in any log line or result", %{
    tenant_id: tenant_id
  } do
    stub = Stub.start!([{201, Stub.created(tenant_id)}, {500, %{}}])
    configure!(stub)

    log =
      capture_log([level: :debug], fn ->
        send(self(), {:first, Body.run(context(tenant_id))})
        send(self(), {:second, Body.run(context(Ecto.UUID.generate()))})
      end)

    assert_received {:first, {:ok, out}}
    assert_received {:second, {:error, code}}
    seen = log <> inspect(out) <> inspect(code)

    for secret <- [@password, @token, "owner@example.test", "acme.qa.example.test"] do
      refute seen =~ secret
    end

    refute log =~ RealmProvisioner.label(tenant_id)
  end

  test "PR6 configuration absent: refused before any call, nothing half-created", %{
    tenant_id: tenant_id
  } do
    stub = Stub.start!([{201, Stub.created(tenant_id)}])

    configure!(stub, provisioner_url: nil)
    assert {:error, :platform_call_provisioner_not_configured} = Body.run(context(tenant_id))

    configure!(stub, hostname_domain: nil)
    assert {:error, :platform_call_provisioner_not_configured} = Body.run(context(tenant_id))

    configure!(stub)
    System.delete_env(RealmProvisioner.token_env())
    assert {:error, :platform_call_provisioner_not_configured} = Body.run(context(tenant_id))

    configure!(stub, provisioner_url: "http://example.com:80")
    System.put_env(RealmProvisioner.token_env(), @token)
    assert {:error, :platform_call_provisioner_not_configured} = Body.run(context(tenant_id))

    assert Stub.posts(stub) == []
    assert mails() == []
  end

  test "PR7 bad inputs are refused before any call; the language falls back", %{
    tenant_id: tenant_id
  } do
    stub = Stub.start!([{201, Stub.created(tenant_id)}])
    configure!(stub)

    assert {:error, :platform_call_arg_invalid} = Body.run(context("nope"))
    assert {:error, :platform_call_arg_invalid} = Body.run(%{inputs: :x})

    for bad <- [nil, 5, "no-at-sign", String.duplicate("a", 250) <> "@x.test"] do
      assert {:error, :platform_call_invalid_email} =
               Body.run(context(tenant_id, %{"admin_email" => bad}))
    end

    for bad <- [nil, "", "A B", "-x", String.duplicate("a", 64)] do
      assert {:error, :platform_call_invalid_slug} =
               Body.run(context(tenant_id, %{"slug" => bad}))
    end

    assert {:error, :platform_call_arg_invalid} =
             Body.run(context(tenant_id, %{"name" => String.duplicate("n", 201)}))

    assert Stub.posts(stub) == []

    for lang <- ["ru", "kk", "en", "xx", nil] do
      id = Ecto.UUID.generate()
      stub2 = Stub.start!([{201, Stub.created(id)}])
      configure!(stub2)
      assert {:ok, _} = Body.run(context(id, %{"language" => lang}))
      assert [_] = mails()
    end
  end

  test "PR8 the body is registered; its codes are codes of the dispatch row" do
    assert {:ok, {Body, :run, 1}} = Registry.fetch("tenant.provision_realm_and_invite")

    source = File.read!("lib/letflow/platform_functions/dispatcher.ex")

    for code <- ~w(platform_call_realm_create_failed platform_call_invite_failed
                   platform_call_provisioner_not_configured platform_call_invalid_slug) do
      assert source =~ code
    end

    entry = Letflow.PlatformFunctions.Catalog.fetch("tenant.provision_realm_and_invite")
    assert {:ok, %{outputs: [%{name: "realm_id"}], idempotency_key: ["tenant_id"]}} = entry
  end
end
