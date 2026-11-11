defmodule Letflow.Routers.IdentityUsersImportSignInTest do
  @moduledoc """
  T-1731 (REQ-808): the sign-in step of the xlsx user import (`POST /users/import`), behind
  `LETFLOW_REALM_USERS_ENABLED`. Ids I1..I6 follow the design. Direct
  `Letflow.Routers.Identity.call/2` with an `auth_context`, as `identity_users_import_test.exs`;
  the provisioner is `Letflow.Test.ProvisionerStub`. `async: false`: committed tenants and env.
  """

  use Letflow.DataCase, async: false
  @moduletag :unit

  import Ecto.Query
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Elixlsx.{Sheet, Workbook}
  alias Letflow.Audit.Entry
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Signup.RealmProvisioner
  alias Letflow.Signup.RealmUsers
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Test.ProvisionerStub, as: Stub

  @opts Letflow.Routers.Identity.init([])
  @header ["username", "display_name", "email"]
  @token "tok-SECRET-import-token"
  @password "Tmp-Pa55-IMPORT-one-time"

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

    a = tenants.a

    Repo.update_all(from(t in Tenant, where: t.id == ^a.tenant_id),
      set: [idp_realm_id: RealmProvisioner.label(a.tenant_id)]
    )

    %{a: a}
  end

  defp stub!(a, script) do
    label = RealmProvisioner.label(a.tenant_id)

    script =
      Enum.map(script, fn
        {201, uid} when is_binary(uid) ->
          {201, %{"user_id" => uid, "temporary_password" => @password, "realm" => label}}

        other ->
          other
      end)

    stub = Stub.start!(script)
    Application.put_env(:letflow, RealmUsers, enabled: true, provisioner_url: stub.url)
    stub
  end

  defp xlsx(rows) do
    {:ok, {_name, bin}} =
      Elixlsx.write_to_memory(%Workbook{sheets: [%Sheet{name: "users", rows: rows}]}, "u.xlsx")

    bin
  end

  defp rows(n), do: for(i <- 1..n, do: ["imp-#{i}", "Person #{i}", "imp-#{i}@example.test"])

  defp import!(a, rows, query \\ "") do
    conn =
      conn(:post, "/users/import" <> query)
      |> Map.put(:body_params, %{"_xlsx" => xlsx([@header | rows])})
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: a.tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "t1731-trace")
      |> Letflow.Routers.Identity.call(@opts)

    {conn, Jason.decode!(conn.resp_body)}
  end

  defp user(a, username),
    do: Repo.get_by(User, [username: username], prefix: a.schema_name)

  defp user_count(a), do: Repo.aggregate(User, :count, :id, prefix: a.schema_name)

  test "I1 flag on: each created row gets a sign_in with a password, rows bound, no-store", %{
    a: a
  } do
    ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    stub = stub!(a, Enum.map(ids, &{201, &1}))
    {conn, body} = import!(a, rows(2))

    assert body["applied"] == true

    assert Enum.all?(body["results"], fn r ->
             r["sign_in"] == %{"created" => true, "temporary_password" => @password}
           end)

    assert [id1, id2] = Enum.map(1..2, &user(a, "imp-#{&1}"))
    assert id1.auth_source == :oidc and id1.external_id == Enum.at(ids, 0)
    assert id2.auth_source == :oidc and id2.external_id == Enum.at(ids, 1)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert length(Stub.posts(stub)) == 2
  end

  test "I2 one login exists in the realm: user kept, internal, reason shown", %{a: a} do
    stub!(a, [{201, Ecto.UUID.generate()}, {409, %{}}])
    {_conn, body} = import!(a, rows(2))

    assert body["applied"] == true
    [r1, r2] = body["results"]
    assert r1["sign_in"]["created"] == true
    assert r2["sign_in"] == %{"created" => false, "reason" => "login_exists_in_realm"}
    assert user(a, "imp-1").auth_source == :oidc
    assert user(a, "imp-2").auth_source == :internal
  end

  test "I3 provisioner unavailable: first row says so, the rest are not_attempted", %{a: a} do
    stub = stub!(a, [{503, %{}}])
    {_conn, body} = import!(a, rows(3))

    assert [s1, s2, s3] = Enum.map(body["results"], & &1["sign_in"])
    assert s1 == %{"created" => false, "reason" => "provisioner_unavailable"}
    assert s2 == %{"created" => false, "reason" => "not_attempted"}
    assert s3 == %{"created" => false, "reason" => "not_attempted"}
    assert length(Stub.posts(stub)) == 1
    assert user_count(a) == 3
    assert Enum.all?(1..3, &(user(a, "imp-#{&1}").auth_source == :internal))
  end

  test "I4a flag off: no sign_in key, provisioner not called", %{a: a} do
    stub = stub!(a, [{201, Ecto.UUID.generate()}])
    Application.put_env(:letflow, RealmUsers, enabled: false, provisioner_url: stub.url)
    {_conn, body} = import!(a, rows(2))

    assert body["applied"] == true
    refute Enum.any?(body["results"], &Map.has_key?(&1, "sign_in"))
    assert Map.keys(body) |> Enum.sort() == ["applied", "results"]
    assert Stub.calls(stub) == []
    assert user_count(a) == 2
  end

  test "I4b flag on, dry run: no sign_in key, no provisioner call, nothing written", %{a: a} do
    stub = stub!(a, [{201, Ecto.UUID.generate()}])
    {_conn, body} = import!(a, rows(2), "?dry_run=true")

    assert body["dry_run"] == true
    refute Enum.any?(body["results"], &Map.has_key?(&1, "sign_in"))
    assert Stub.calls(stub) == []
    assert user_count(a) == 0
  end

  test "I4c flag on, a refused row: applied false, no sign_in, no call, no users", %{a: a} do
    stub = stub!(a, [{201, Ecto.UUID.generate()}])
    {_conn, body} = import!(a, rows(1) ++ [["", "No Name", "x@example.test"]])

    assert body["applied"] == false
    refute Enum.any?(body["results"], &Map.has_key?(&1, "sign_in"))
    assert Stub.calls(stub) == []
    assert user_count(a) == 0
  end

  test "I5 neither password nor bearer token reaches the log or the audit rows", %{a: a} do
    stub!(a, [{201, Ecto.UUID.generate()}])

    {{_conn, body}, log} =
      with_log([level: :debug], fn -> import!(a, rows(2)) end)

    assert body["applied"] == true
    refute log =~ @password
    refute log =~ @token

    entries = Repo.all(Entry, prefix: a.schema_name)
    assert entries != []
    refute inspect(entries) =~ @password
  end

  test "I6 the provisioner call goes to the authenticated tenant's realm path", %{a: a} do
    stub = stub!(a, [{201, Ecto.UUID.generate()}])
    import!(a, rows(1))

    assert [post] = Stub.posts(stub)
    assert post.auth == "Bearer " <> @token
    assert post.path == "/v1/realms/#{a.tenant_id}/users"
  end
end
