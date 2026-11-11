defmodule Letflow.Routers.IdentitySignInTest do
  @moduledoc """
  T-1730 (REQ-807, decision 0072 section 8b): `POST /api/v1/identity/users/:id/sign-in`. Ids S1..S10
  follow the design. S1, S2, S4*, S5, S6, S7, S9, S10 send a minted token through the real
  `Letflow.Router`; S8 calls `Identity.create_sign_in/2` directly (the lock re-check branch is not
  reachable through the router). The provisioner is `Letflow.Test.ProvisionerStub` (real `:httpc`).
  `async: false`: committed tenants, application env and OS env.
  """

  use Letflow.DataCase, async: false
  @moduletag :unit

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Signup.RealmProvisioner
  alias Letflow.Signup.RealmUsers
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Test.ProvisionerStub, as: Stub

  @token "tok-SECRET-users-token"
  @password "Tmp-Pa55-ONE-time-S"
  @action "user.sign_in_created"

  setup do
    tenants = Fixture.two_tenants!()
    Fixture.unpin!()
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

    bind_realm!(tenants.a)
    bind_realm!(tenants.b)
    Map.put(tenants, :admin_token, Fixture.mint_token!(tenants.a, ["TENANT_ADMIN"]))
  end

  defp bind_realm!(fixture) do
    label = RealmProvisioner.label(fixture.tenant_id)

    Repo.update_all(from(t in Tenant, where: t.id == ^fixture.tenant_id),
      set: [idp_realm_id: label]
    )
  end

  defp enable!(stub, enabled \\ true),
    do: Application.put_env(:letflow, RealmUsers, enabled: enabled, provisioner_url: stub.url)

  defp created(password, overrides \\ %{}) do
    Map.merge(%{"user_id" => Ecto.UUID.generate(), "temporary_password" => password}, overrides)
  end

  defp stub_for(tenant, status, overrides \\ %{}) do
    body =
      Map.put(created(@password, overrides), "realm", RealmProvisioner.label(tenant.tenant_id))

    stub = Stub.start!([{status, body}])
    enable!(stub)
    stub
  end

  defp user!(tenant, attrs \\ %{}) do
    default = %{
      username: "u-#{Ecto.UUID.generate()}",
      display_name: "Sign In Person",
      email: "si-#{System.unique_integer([:positive])}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, attrs))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp post_sign_in(tenant, token, id, body \\ nil) do
    :post
    |> Fixture.api_conn("/api/v1/identity/users/#{id}/sign-in", token, tenant.tenant.slug, body)
    |> Fixture.dispatch_api()
  end

  defp reload(tenant, user), do: Repo.get!(User, user.id, prefix: tenant.schema_name)

  defp audits(tenant),
    do: Repo.all(Entry, prefix: tenant.schema_name) |> Enum.filter(&(&1.action == @action))

  defp assert_unchanged(tenant, user) do
    row = reload(tenant, user)
    assert row.auth_source == :internal
    assert row.external_id == nil
    assert row.external_realm == nil
    assert audits(tenant) == []
  end

  test "S1 flag off: 409 sign_in_creation_off, stub never called, row internal", %{
    a: a,
    admin_token: token
  } do
    stub = stub_for(a, 201)
    enable!(stub, false)
    user = user!(a)
    conn = post_sign_in(a, token, user.id)
    assert conn.status == 409
    assert conn.resp_body =~ "sign_in_creation_off"
    assert Stub.calls(stub) == []
    assert_unchanged(a, user)
  end

  test "S2 success: 201, exact keys, no-store, bound row, one audit, no password in audit", %{
    a: a,
    admin_token: token
  } do
    stub = stub_for(a, 201)
    user = user!(a)
    conn = post_sign_in(a, token, user.id)
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert Map.keys(body) |> Enum.sort() == ["temporary_password", "user"]
    assert body["temporary_password"] == @password
    assert body["user"]["auth_source"] == "oidc"
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]

    row = reload(a, user)
    assert row.auth_source == :oidc
    assert row.external_realm == RealmProvisioner.label(a.tenant_id)
    assert is_binary(row.external_id)
    assert row.username == user.username and row.email == user.email

    assert [entry] = audits(a)
    assert entry.resource_id == user.id
    refute inspect(entry) =~ @password
    assert [%{method: "POST", auth: "Bearer " <> @token}] = Stub.calls(stub)
  end

  test "S3 the next OIDC sign-in finds the same row", %{a: a, admin_token: token} do
    stub_for(a, 201)
    user = user!(a)
    assert post_sign_in(a, token, user.id).status == 201
    row = reload(a, user)

    ctx = %Letflow.Oidc.IdentityContext{
      external_user_id: row.external_id,
      tenant_id: nil,
      realm: row.external_realm,
      roles: [],
      email: row.email,
      preferred_username: row.username,
      display_name: row.display_name
    }

    jit = %Letflow.Oidc.JitProvisioningConfig{
      realm: "unused",
      enabled: true,
      default_status: :active,
      default_roles: []
    }

    assert {:ok, %{user: %User{id: id}, created: false}} =
             Identity.provision_oidc_user(ctx, a.tenant_id, jit, prefix: a.schema_name)

    assert id == user.id
    assert Repo.aggregate(User, :count, :id, prefix: a.schema_name) == 2
  end

  describe "S4 refusals leave the row unchanged and write no audit" do
    test "S4a a body is 422 body_not_accepted", %{a: a, admin_token: token} do
      stub = stub_for(a, 201)
      user = user!(a)
      conn = post_sign_in(a, token, user.id, %{"username" => "x"})
      assert conn.status == 422
      assert conn.resp_body =~ "body_not_accepted"
      assert Stub.calls(stub) == []
      assert_unchanged(a, user)
    end

    test "S4b unknown id is 404", %{a: a, admin_token: token} do
      stub = stub_for(a, 201)
      assert post_sign_in(a, token, Ecto.UUID.generate()).status == 404
      assert Stub.calls(stub) == []
    end

    test "S4c inactive user", %{a: a, admin_token: token} do
      stub = stub_for(a, 201)
      user = user!(a, %{status: :inactive})
      conn = post_sign_in(a, token, user.id)
      assert conn.status == 409 and conn.resp_body =~ "user_inactive"
      assert Stub.calls(stub) == []
      assert_unchanged(a, user)
    end

    test "S4d already signed in", %{a: a, admin_token: token} do
      stub = stub_for(a, 201)

      user =
        user!(a, %{auth_source: :oidc, external_id: "ext-1", external_realm: "r-1"})

      conn = post_sign_in(a, token, user.id)
      assert conn.status == 409 and conn.resp_body =~ "sign_in_exists"
      assert Stub.calls(stub) == []
      assert audits(a) == []
    end

    test "S4e no email", %{a: a, admin_token: token} do
      stub = stub_for(a, 201)
      user = user!(a, %{email: ""})
      conn = post_sign_in(a, token, user.id)
      assert conn.status == 409 and conn.resp_body =~ "no_email"
      assert Stub.calls(stub) == []
      assert_unchanged(a, user)
    end

    test "S4f the tenant's realm differs from its label", %{a: a, admin_token: token} do
      stub = stub_for(a, 201)

      Repo.update_all(from(t in Tenant, where: t.id == ^a.tenant_id),
        set: [idp_realm_id: "someone-elses-realm"]
      )

      user = user!(a)
      conn = post_sign_in(a, token, user.id)
      assert conn.status == 409 and conn.resp_body =~ "realm_not_provisioned"
      assert Stub.calls(stub) == []
      assert_unchanged(a, user)
    end

    test "S4g provisioner 409 is login_exists_in_realm", %{a: a, admin_token: token} do
      stub_for(a, 409)
      user = user!(a)
      conn = post_sign_in(a, token, user.id)
      assert conn.status == 409 and conn.resp_body =~ "login_exists_in_realm"
      assert_unchanged(a, user)
    end

    test "S4h provisioner 503 and 429 are provisioner_unavailable", %{a: a, admin_token: token} do
      for status <- [503, 429] do
        stub_for(a, status)
        user = user!(a)
        conn = post_sign_in(a, token, user.id)
        assert conn.status == 409 and conn.resp_body =~ "provisioner_unavailable"
        assert_unchanged(a, user)
      end
    end

    test "S4i provisioner 401 is provisioner_refused", %{a: a, admin_token: token} do
      stub_for(a, 401)
      user = user!(a)
      conn = post_sign_in(a, token, user.id)
      assert conn.status == 409 and conn.resp_body =~ "provisioner_refused"
      assert_unchanged(a, user)
    end

    test "S4k provisioner 404 is provisioner_refused, not realm_not_provisioned", %{
      a: a,
      admin_token: token
    } do
      stub_for(a, 404)
      user = user!(a)
      conn = post_sign_in(a, token, user.id)
      assert conn.status == 409 and conn.resp_body =~ "provisioner_refused"
      refute conn.resp_body =~ "realm_not_provisioned"
      assert_unchanged(a, user)
    end

    test "S4j a platform-admin group member is 403 for a customer-tenant admin", %{
      a: a,
      admin_token: token
    } do
      stub = stub_for(a, 201)

      group =
        %Group{}
        |> Ecto.Changeset.change(%{name: "g-#{Ecto.UUID.generate()}", display_name: "G"})
        |> Repo.insert!(prefix: a.schema_name)

      Fixture.pin!(a.tenant_id)

      {:ok, _role} =
        RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, group.id,
          prefix: a.schema_name
        )

      member = user!(a)

      %GroupMember{}
      |> Ecto.Changeset.change(%{group_id: group.id, user_id: member.id})
      |> Repo.insert!(prefix: a.schema_name)

      Fixture.unpin!()
      Fixture.pin!(Ecto.UUID.generate())
      conn = post_sign_in(a, token, member.id)
      assert conn.status == 403
      assert Stub.calls(stub) == []
      assert_unchanged(a, member)
    end
  end

  test "S5 cross-tenant: A's admin on B's user id is the same 404 as a random id", %{
    a: a,
    b: b,
    admin_token: token
  } do
    stub = stub_for(a, 201)
    other = user!(b)
    cross = post_sign_in(a, token, other.id)
    random = post_sign_in(a, token, Ecto.UUID.generate())
    assert cross.status == 404 and random.status == 404

    assert Map.delete(Jason.decode!(cross.resp_body), "trace_id") ==
             Map.delete(Jason.decode!(random.resp_body), "trace_id")

    assert Stub.calls(stub) == []
    assert_unchanged(b, other)
  end

  test "S6 a caller without UsersManage is 403 and the stub is not called", %{a: a} do
    stub = stub_for(a, 201)
    auditor = Fixture.mint_token!(a, ["TENANT_AUDITOR"])
    user = user!(a)
    assert post_sign_in(a, auditor, user.id).status == 403
    assert Stub.calls(stub) == []
    assert_unchanged(a, user)
  end

  test "S7 neither the password nor the bearer token reaches the log or a refusal", %{
    a: a,
    admin_token: token
  } do
    stub_for(a, 201)
    ok_user = user!(a)
    inactive = user!(a, %{status: :inactive})

    log =
      capture_log([level: :debug], fn ->
        send(self(), {:ok_conn, post_sign_in(a, token, ok_user.id)})
        send(self(), {:refused, post_sign_in(a, token, inactive.id)})
      end)

    assert_received {:ok_conn, %{status: 201}}
    assert_received {:refused, refused}
    refute log =~ @password
    refute log =~ @token
    refute refused.resp_body =~ @password
    refute refused.resp_body =~ @token
  end

  test "S8 a row already bound between the check and the lock is refused", %{a: a} do
    stub = stub_for(a, 201)
    user = user!(a, %{auth_source: :oidc, external_id: "e", external_realm: "r"})

    opts = [prefix: a.schema_name, tenant_id: a.tenant_id]
    assert {:error, :sign_in_exists} = Identity.create_sign_in(user.id, opts)
    assert Stub.calls(stub) == []
    assert {:error, :not_found} = Identity.create_sign_in(Ecto.UUID.generate(), opts)
  end

  test "S9 an audit failure after the provisioner answered: fixed 500, nothing bound", %{
    a: a,
    admin_token: token
  } do
    stub_for(a, 201)
    name = "si_fault_#{System.unique_integer([:positive])}"
    schema = a.schema_name

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN IF NEW.action = '#{@action}' THEN | <>
        ~s|RAISE EXCEPTION 'injected fault (REQ-807 test)'; END IF; RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE INSERT ON "#{schema}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )

    on_exit(fn ->
      Repo.query!(~s|DROP TRIGGER IF EXISTS #{name} ON "#{schema}".audit_entries|)
      Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".#{name}()|)
    end)

    user = user!(a)

    {conn, log} =
      with_log(fn -> post_sign_in(a, token, user.id) end)

    assert conn.status == 500
    refute conn.resp_body =~ @password
    refute log =~ @password
    assert_unchanged(a, user)
  end

  test "S10 flag on but the token unset: 409 sign_in_creation_off, stub not called", %{
    a: a,
    admin_token: token
  } do
    stub = stub_for(a, 201)
    System.delete_env(RealmUsers.token_env())
    user = user!(a)
    conn = post_sign_in(a, token, user.id)
    assert conn.status == 409 and conn.resp_body =~ "sign_in_creation_off"
    assert Stub.calls(stub) == []
    assert_unchanged(a, user)
  end
end
