defmodule Letflow.Routers.AdminV1Test do
  @moduledoc """
  REQ-572 / GH #3252 / decision 0072 (QA only): the `/admin/v1` provisioner routes through the real
  `Letflow.Router`, against real Postgres and real tenant schemas. Design test IDs in the test names:
  A (credential), R (read-only), N (narrowness), C (create), GT (get), T (transitions), L (rate
  limit), D (DELETE), BR (body reading).

  The realm probe is the deterministic `Letflow.Oidc.RealmProbeDouble` (`config/test.exs`).
  `async: false`: provisioning flips the SQL sandbox to `:auto`, and the platform-tenant pin, the
  credential hashes and the rate limiter are VM-global. Every tenant the tests create is removed in
  `on_exit` (lifecycle row before the tenant row: FK `on_delete: :restrict`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit.Entry
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.Tenant
  alias Letflow.Plugs.ProvisionerAuth.RateLimiter
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @write_token "write-credential-for-tests-0123456789abcdef0123456789abcdef"
  @read_token "read-credential-for-tests-0123456789abcdef0123456789abcdef"
  @server_url "https://letflow.qa.example"
  @get_keys ~w(created_at expires_at purged_at status tenant_id tier)

  setup do
    platform = TenantFixture.provisioned_tenant!(slug_prefix: "req572-plat")
    Fixture.pin!(platform.tenant_id)

    previous = %{
      auth: Application.get_env(:letflow, Letflow.Plugs.ProvisionerAuth),
      prov: Application.get_env(:letflow, Letflow.TenantProvisioner),
      url: Application.get_env(:letflow, :provisioner_public_base_url)
    }

    Application.put_env(:letflow, Letflow.Plugs.ProvisionerAuth,
      write_sha256: hash(@write_token),
      read_sha256: hash(@read_token)
    )

    Application.put_env(:letflow, Letflow.TenantProvisioner,
      allowed_hostname_suffixes: ["qa.example"],
      demo_lifetime_days: 14
    )

    Application.put_env(:letflow, :provisioner_public_base_url, @server_url)
    RateLimiter.reset()

    on_exit(fn ->
      restore(Letflow.Plugs.ProvisionerAuth, previous.auth)
      restore(Letflow.TenantProvisioner, previous.prov)
      restore(:provisioner_public_base_url, previous.url)
      RateLimiter.reset()
    end)

    %{platform: platform}
  end

  # --- helpers ---------------------------------------------------------------

  defp restore(key, nil), do: Application.delete_env(:letflow, key)
  defp restore(key, value), do: Application.put_env(:letflow, key, value)

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp call(method, path, token, body \\ nil) do
    payload = if is_nil(body), do: nil, else: Jason.encode!(body)

    conn(method, path, payload)
    |> put_req_header("content-type", "application/json")
    |> maybe_auth(token)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp maybe_auth(conn, nil), do: conn
  defp maybe_auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp realm_for(id), do: "t-" <> String.slice(String.replace(id, "-", ""), 0, 20)

  defp create_body(overrides \\ %{}) do
    id = Ecto.UUID.generate()

    Map.merge(
      %{
        "tenant_id" => id,
        "name" => "REQ-572 Demo",
        "language" => "en",
        "tier" => "demo",
        "owner_email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "hostname" => "h#{String.slice(String.replace(id, "-", ""), 0, 12)}.qa.example",
        "idp_realm_id" => realm_for(id)
      },
      overrides
    )
  end

  # POST /tenants that must succeed (201); the tenant is removed at the end of the test.
  defp create!(overrides \\ %{}) do
    body = create_body(overrides)
    track(body["tenant_id"])
    conn = call(:post, "/admin/v1/tenants", @write_token, body)
    assert conn.status == 201, conn.resp_body
    {body, json(conn)}
  end

  defp track(tenant_id), do: on_exit(fn -> drop_tenant!(tenant_id) end)

  defp drop_tenant!(tenant_id) do
    Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
      _invalid -> :ok
    end

    Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^tenant_id))
    Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant_id))
    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
  end

  defp counts do
    %{
      tenants: Repo.aggregate(Tenant, :count),
      lifecycles: Repo.aggregate(Lifecycle, :count),
      onboarding: Repo.aggregate(OnboardingRecord, :count)
    }
  end

  defp schema_of(id) do
    {:ok, schema} = TenantProvisioning.schema_name_for_tenant(id)
    schema
  end

  defp grants(id), do: Repo.all(PendingAdminGrant, prefix: schema_of(id))

  defp platform_entries(ctx, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: ctx.platform.schema_name)

  # --- A: credential ---------------------------------------------------------

  describe "A1 no credential configured" do
    test "every route answers the body of an unmatched path, and writes nothing" do
      Application.delete_env(:letflow, Letflow.Plugs.ProvisionerAuth)
      nope = call(:get, "/nope", nil)
      before = counts()

      for {method, path} <- [
            {:post, "/admin/v1/tenants"},
            {:get, "/admin/v1/tenants/#{Ecto.UUID.generate()}"},
            {:post, "/admin/v1/tenants/#{Ecto.UUID.generate()}/suspend"},
            {:post, "/admin/v1/tenants/#{Ecto.UUID.generate()}/resume"},
            {:post, "/admin/v1/tenants/#{Ecto.UUID.generate()}/expire"},
            {:delete, "/admin/v1/tenants/#{Ecto.UUID.generate()}"},
            {:get, "/admin/v1/other"}
          ],
          token <- [nil, @write_token] do
        conn = call(method, path, token, if(method == :post, do: create_body()))
        assert conn.status == 404
        assert conn.resp_body == nope.resp_body
      end

      assert counts() == before
    end
  end

  describe "A2 bad credentials" do
    test "missing, malformed, wrong and an OIDC-style token all answer the same 401", ctx do
      admin = Fixture.mint_token!(ctx.platform, ["PLATFORM_ADMIN"])
      before = counts()

      bodies =
        for header <- [nil, "Basic abc", "Bearer ", "Bearer wrong-token", "Bearer " <> admin] do
          conn =
            conn(:post, "/admin/v1/tenants", Jason.encode!(create_body()))
            |> put_req_header("content-type", "application/json")
            |> then(fn c ->
              if header, do: put_req_header(c, "authorization", header), else: c
            end)
            |> Letflow.Router.call(Letflow.Router.init([]))

          assert conn.status == 401
          conn.resp_body
        end

      assert [only] = Enum.uniq(bodies)

      assert Jason.decode!(only) == %{
               "error" => "unauthorized",
               "message" => "invalid or missing credential"
             }

      assert counts() == before
    end

    test "A3 the plug compares digests with Plug.Crypto.secure_compare" do
      source = File.read!("lib/letflow/plugs/provisioner_auth.ex")
      assert source =~ "Plug.Crypto.secure_compare"
      assert source =~ ":crypto.hash(:sha256"
    end
  end

  describe "A4 only the read credential configured" do
    test "GET works with it, POST routes answer 403, the write token is unknown" do
      {body, _answer} = create!()
      Application.put_env(:letflow, Letflow.Plugs.ProvisionerAuth, read_sha256: hash(@read_token))

      assert call(:get, "/admin/v1/tenants/#{body["tenant_id"]}", @read_token).status == 200
      assert call(:post, "/admin/v1/tenants", @read_token, create_body()).status == 403
      assert call(:get, "/admin/v1/tenants/#{body["tenant_id"]}", @write_token).status == 401
    end
  end

  # --- R: read-only ----------------------------------------------------------

  describe "R1 read-only credential" do
    test "reads one tenant, and nothing else is reachable" do
      {body, _answer} = create!()
      id = body["tenant_id"]

      get = call(:get, "/admin/v1/tenants/#{id}", @read_token)
      assert get.status == 200
      assert get |> json() |> Map.keys() |> Enum.sort() == @get_keys

      before = counts()
      grants_before = grants(id)

      for {method, path, payload} <- [
            {:post, "/admin/v1/tenants", "{not json"},
            {:post, "/admin/v1/tenants/#{id}/suspend", nil},
            {:post, "/admin/v1/tenants/#{id}/resume", nil},
            {:post, "/admin/v1/tenants/#{id}/expire", nil},
            {:get, "/admin/v1/tenants", nil},
            {:delete, "/admin/v1/tenants/#{id}", nil}
          ] do
        conn =
          conn(method, path, payload)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> @read_token)
          |> Letflow.Router.call(Letflow.Router.init([]))

        assert conn.status == 403, "#{method} #{path}: #{conn.resp_body}"
        assert json(conn)["error"] == "unauthorized"
      end

      assert counts() == before
      assert grants(id) == grants_before
      assert Repo.get!(Lifecycle, id).lifecycle == "active"
    end
  end

  # --- C / GT: create and get ------------------------------------------------

  describe "C1 create" do
    test "happy path writes the tenant, lifecycle, onboarding record, grant and realm", ctx do
      {body, answer} = create!()
      id = body["tenant_id"]

      assert answer == %{
               "tenant_id" => id,
               "status" => "active",
               "server_url" => @server_url,
               "handover" => %{"login_url" => "https://" <> body["hostname"]}
             }

      tenant = Repo.get!(Tenant, id)
      assert tenant.slug == "t-" <> String.replace(id, "-", "")
      assert tenant.display_name == body["name"]
      assert tenant.tenant_type == "test"
      assert tenant.status == :active
      assert tenant.idp_realm_id == body["idp_realm_id"]

      lifecycle = Repo.get!(Lifecycle, id)
      assert lifecycle.lifecycle == "active"
      assert lifecycle.tier == "demo"
      assert lifecycle.language == "en"
      assert lifecycle.owner_grant_stored
      assert lifecycle.purged_at == nil
      assert DateTime.diff(lifecycle.expires_at, DateTime.utc_now(), :day) in 13..14

      assert %OnboardingRecord{hostname: hostname} = Repo.get_by(OnboardingRecord, tenant_id: id)
      assert hostname == body["hostname"]

      assert [grant] = grants(id)
      assert grant.created_via == "provisioning"
      assert grant.role_name == "TENANT_ADMIN"

      created = platform_entries(ctx, "platform.tenant_admin_grant.created")
      assert Enum.any?(created, &(&1.resource_id == grant.id and is_nil(&1.actor_id)))
      refute inspect(created) =~ body["owner_email"]

      bound = platform_entries(ctx, "platform.tenant_idp_realm.bound")
      assert Enum.any?(bound, &(&1.after_state["tenant_id"] == id and is_nil(&1.actor_id)))
    end

    test "the grant CHECK accepts both creators and refuses a third" do
      {body, _answer} = create!()
      schema = schema_of(body["tenant_id"])

      assert_raise Postgrex.Error, ~r/created_via_chk/, fn ->
        Repo.query!(
          ~s|INSERT INTO "#{schema}".pending_tenant_admin_grants (id, email_key, created_via, inserted_at) VALUES (gen_random_uuid(), 'x@example.com', 'other', now())|
        )
      end

      Repo.query!(
        ~s|INSERT INTO "#{schema}".pending_tenant_admin_grants (id, email_key, created_via, inserted_at) VALUES (gen_random_uuid(), 'y@example.com', 'onboarding', now())|
      )
    end
  end

  describe "C2 replay" do
    test "a second POST answers 200 with the same body and writes nothing", ctx do
      {body, first} = create!()
      id = body["tenant_id"]
      lifecycle = Repo.get!(Lifecycle, id)
      tenant = Repo.get!(Tenant, id)
      before = counts()
      created = length(platform_entries(ctx, "platform.tenant_admin_grant.created"))

      changed =
        Map.merge(body, %{
          "name" => "Other name",
          "owner_email" => "someone-else@example.com",
          "hostname" => "other-host.qa.example"
        })

      conn = call(:post, "/admin/v1/tenants", @write_token, changed)
      assert conn.status == 200
      assert json(conn) == first

      assert counts() == before
      assert Repo.get!(Lifecycle, id).updated_at == lifecycle.updated_at
      assert Repo.get!(Tenant, id).updated_at == tenant.updated_at
      assert length(grants(id)) == 1
      assert length(platform_entries(ctx, "platform.tenant_admin_grant.created")) == created
    end
  end

  # The platform audit table is renamed for the span of `fun`: the grant and bind steps of create
  # append audit entries there, so they fail after the tenant row is committed. The sandbox runs
  # each query in a savepoint, so the failed statement does not poison the test transaction.
  defp with_audit_down(ctx, fun) do
    table = ~s("#{ctx.platform.schema_name}".audit_entries)
    Repo.query!("ALTER TABLE #{table} RENAME TO audit_entries_off")

    try do
      fun.()
    after
      Repo.query!(
        ~s(ALTER TABLE "#{ctx.platform.schema_name}".audit_entries_off RENAME TO audit_entries)
      )
    end
  end

  defp assert_completed(id, body) do
    assert [grant] = grants(id)
    assert grant.role_name == "TENANT_ADMIN"
    assert Repo.get!(Lifecycle, id).owner_grant_stored
    assert Repo.get!(Tenant, id).idp_realm_id == body["idp_realm_id"]
  end

  describe "C3 completion after a failure" do
    test "a create that fails after the tenant commit answers 500; the repeat completes it",
         ctx do
      body = create_body()
      id = body["tenant_id"]
      track(id)

      conn = with_audit_down(ctx, fn -> call(:post, "/admin/v1/tenants", @write_token, body) end)
      assert conn.status == 500
      assert Repo.get!(Tenant, id)
      refute Repo.get!(Lifecycle, id).owner_grant_stored

      conn = call(:post, "/admin/v1/tenants", @write_token, body)
      assert conn.status == 200, conn.resp_body
      assert json(conn)["tenant_id"] == id
      assert_completed(id, body)

      assert call(:post, "/admin/v1/tenants", @write_token, body).status == 200
      assert length(grants(id)) == 1
    end

    test "a complete tenant whose grant flag and realm were lost is completed by a repeat" do
      {body, _answer} = create!()
      id = body["tenant_id"]
      schema = schema_of(id)
      Repo.query!(~s(DELETE FROM "#{schema}".pending_tenant_admin_grants))

      Repo.update_all(from(l in Lifecycle, where: l.tenant_id == ^id),
        set: [owner_grant_stored: false]
      )

      conn = call(:post, "/admin/v1/tenants", @write_token, body)
      assert conn.status == 200, conn.resp_body
      assert_completed(id, body)
    end
  end

  describe "C10 failure body" do
    test "an audit failure answers 500 internal_error with no stack or SQL", ctx do
      body = create_body()
      track(body["tenant_id"])

      conn = with_audit_down(ctx, fn -> call(:post, "/admin/v1/tenants", @write_token, body) end)
      assert conn.status == 500
      assert json(conn)["error"] == "internal_error"

      for leak <- ["audit_entries", "relation", "** (", "Postgrex", "SELECT", "lib/letflow"] do
        refute conn.resp_body =~ leak
      end
    end
  end

  describe "C12 replay on a suspended tenant" do
    test "an unfinished create answers 409 and writes nothing; after resume a repeat completes",
         ctx do
      body = create_body()
      id = body["tenant_id"]
      track(id)

      assert with_audit_down(ctx, fn -> call(:post, "/admin/v1/tenants", @write_token, body) end).status ==
               500

      assert call(:post, "/admin/v1/tenants/#{id}/suspend", @write_token).status == 200
      before = counts()

      conn = call(:post, "/admin/v1/tenants", @write_token, body)
      assert conn.status == 409
      assert counts() == before
      assert grants(id) == []

      assert call(:post, "/admin/v1/tenants/#{id}/resume", @write_token).status == 200
      assert call(:post, "/admin/v1/tenants", @write_token, body).status == 200
      assert_completed(id, body)
    end
  end

  describe "C5 validation" do
    test "a bad field answers 400 invalid_request and writes nothing" do
      before = counts()

      for overrides <- [
            %{"tenant_id" => "x'; drop schema public; --"},
            %{"name" => ""},
            %{"language" => "de"},
            %{"tier" => "production"},
            %{"owner_email" => "not-an-email"},
            %{"hostname" => "https://a.qa.example"},
            %{"hostname" => "a.b.qa.example"},
            %{"idp_realm_id" => "bpm-default"},
            %{"expires_at" => "2001-01-01T00:00:00Z"},
            %{"unknown_key" => 1}
          ] do
        body = create_body(overrides)
        conn = call(:post, "/admin/v1/tenants", @write_token, body)
        assert conn.status == 400, "#{inspect(overrides)}: #{conn.resp_body}"
        assert conn |> json() |> Map.keys() |> Enum.sort() == ["error", "message"]
        assert json(conn)["error"] == "invalid_request"
        refute conn.resp_body =~ "drop schema"
      end

      assert counts() == before
    end
  end

  describe "C6 conflicts" do
    test "a hostname or a realm owned by another tenant, or an id owned by a non-provisioned tenant, is 409",
         ctx do
      {first, _answer} = create!()
      before = counts()

      same_host = create_body(%{"hostname" => first["hostname"]})
      track(same_host["tenant_id"])
      assert call(:post, "/admin/v1/tenants", @write_token, same_host).status == 409

      platform_id = ctx.platform.tenant_id

      conflict =
        create_body(%{"tenant_id" => platform_id, "idp_realm_id" => realm_for(platform_id)})

      conn = call(:post, "/admin/v1/tenants", @write_token, conflict)
      assert conn.status == 409
      assert json(conn)["error"] == "conflict"
      assert counts() == before
    end
  end

  describe "C7 realm probe" do
    test "not found is 400, unreachable is 500, and neither writes" do
      before = counts()

      Letflow.Oidc.RealmProbeDouble.put_override({:error, :not_found})
      conn = call(:post, "/admin/v1/tenants", @write_token, create_body())
      assert conn.status == 400
      assert json(conn)["message"] =~ "idp_realm_id"

      Letflow.Oidc.RealmProbeDouble.put_override({:error, :unreachable})
      conn = call(:post, "/admin/v1/tenants", @write_token, create_body())
      assert conn.status == 500
      assert json(conn)["error"] == "internal_error"
      assert counts() == before
    end
  end

  describe "C11 server_url" do
    test "unset: create answers 500 before any write; get still works" do
      {body, _answer} = create!()
      Application.delete_env(:letflow, :provisioner_public_base_url)
      before = counts()

      conn = call(:post, "/admin/v1/tenants", @write_token, create_body())
      assert conn.status == 500
      assert counts() == before
      assert call(:get, "/admin/v1/tenants/#{body["tenant_id"]}", @write_token).status == 200
    end
  end

  describe "GT get" do
    test "GT1 exactly six keys, null purged_at, stable" do
      {body, _answer} = create!()
      conn = call(:get, "/admin/v1/tenants/#{body["tenant_id"]}", @write_token)
      assert conn.status == 200
      answer = json(conn)
      assert answer |> Map.keys() |> Enum.sort() == @get_keys
      assert answer["status"] == "active" and answer["tier"] == "demo"
      assert answer["purged_at"] == nil
      assert {:ok, _at, 0} = DateTime.from_iso8601(answer["expires_at"])

      assert call(:get, "/admin/v1/tenants/#{body["tenant_id"]}", @write_token).resp_body ==
               conn.resp_body
    end

    test "GT2 a purged tenant still answers with status and purged_at; transitions are 409" do
      {body, _answer} = create!()
      id = body["tenant_id"]
      now = DateTime.utc_now()

      Repo.update_all(from(l in Lifecycle, where: l.tenant_id == ^id),
        set: [purged_at: now, lifecycle: "deleted"]
      )

      conn = call(:get, "/admin/v1/tenants/#{id}", @read_token)
      assert conn.status == 200
      assert %{"status" => "deleted", "purged_at" => purged} = json(conn)
      assert is_binary(purged)

      for action <- ~w(suspend resume expire) do
        assert call(:post, "/admin/v1/tenants/#{id}/#{action}", @write_token).status == 409
      end
    end

    test "GT3 unknown, non-uuid, no lifecycle row and the platform tenant are one 404", ctx do
      bare =
        Repo.insert!(%Tenant{
          id: Ecto.UUID.generate(),
          slug: "bare-#{System.unique_integer([:positive])}",
          display_name: "bare"
        })

      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
        Repo.delete_all(from(t in Tenant, where: t.id == ^bare.id))
      end)

      bodies =
        for id <- [Ecto.UUID.generate(), "not-a-uuid", bare.id, ctx.platform.tenant_id] do
          conn = call(:get, "/admin/v1/tenants/#{id}", @read_token)
          assert conn.status == 404
          conn.resp_body
        end

      assert [_only] = Enum.uniq(bodies)
    end
  end

  # --- T: transitions --------------------------------------------------------

  describe "T1 transitions" do
    test "the state table, every cell" do
      {body, _answer} = create!()
      id = body["tenant_id"]
      path = fn action -> "/admin/v1/tenants/#{id}/#{action}" end
      step = fn action -> call(:post, path.(action), @write_token) end
      status = fn -> Repo.get!(Lifecycle, id).lifecycle end
      tenant_status = fn -> Repo.get!(Tenant, id).status end

      assert step.("resume").status == 200 and status.() == "active"
      assert json(step.("suspend")) == %{"tenant_id" => id, "status" => "suspended"}
      assert tenant_status.() == :inactive
      assert step.("suspend").status == 200 and status.() == "suspended"
      assert json(step.("resume")) == %{"tenant_id" => id, "status" => "active"}
      assert tenant_status.() == :active

      assert step.("expire").status == 200 and status.() == "expired"
      assert tenant_status.() == :inactive
      assert step.("expire").status == 200 and status.() == "expired"
      assert step.("suspend").status == 409
      assert step.("resume").status == 409
      assert status.() == "expired"

      {other, _} = create!()
      other_id = other["tenant_id"]
      assert call(:post, "/admin/v1/tenants/#{other_id}/suspend", @write_token).status == 200
      assert call(:post, "/admin/v1/tenants/#{other_id}/expire", @write_token).status == 200
      assert Repo.get!(Lifecycle, other_id).lifecycle == "expired"
    end

    test "the tenant schema is untouched by expire" do
      {body, _answer} = create!()
      id = body["tenant_id"]
      before = grants(id)
      assert call(:post, "/admin/v1/tenants/#{id}/expire", @write_token).status == 200
      assert grants(id) == before
    end

    test "an unknown id is 404 for every action" do
      for action <- ~w(suspend resume expire) do
        conn = call(:post, "/admin/v1/tenants/#{Ecto.UUID.generate()}/#{action}", @write_token)
        assert conn.status == 404
        assert json(conn)["error"] == "not_found"
      end
    end

    test "a transition is audited on the platform chain with a nil actor", ctx do
      {body, _answer} = create!()
      id = body["tenant_id"]
      call(:post, "/admin/v1/tenants/#{id}/suspend", @write_token)

      assert Enum.any?(
               platform_entries(ctx, "platform.tenant_lifecycle.changed"),
               &(&1.resource_id == id and is_nil(&1.actor_id) and
                   &1.after_state == %{"tenant_id" => id, "from" => "active", "to" => "suspended"})
             )
    end
  end

  describe "T2 platform tenant" do
    test "a lifecycle row for the platform tenant cannot be suspended or expired", ctx do
      id = ctx.platform.tenant_id

      Repo.insert!(%Lifecycle{tenant_id: id, lifecycle: "active", tier: "demo", language: "en"})

      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
        Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^id))
      end)

      for action <- ~w(suspend expire) do
        assert call(:post, "/admin/v1/tenants/#{id}/#{action}", @write_token).status == 409
      end

      assert Repo.get!(Tenant, id).status == :active
    end
  end

  describe "T3 release_runtime" do
    test "both deactivating paths go through the one function" do
      assert File.read!("lib/letflow/tenant_provisioner.ex") =~ "TenantLifecycle.release_runtime"
      assert File.read!("lib/letflow/routers/tenants.ex") =~ "TenantLifecycle.release_runtime"
      refute File.read!("lib/letflow/routers/tenants.ex") =~ "stop_realm_provider"
    end

    test "release_runtime returns :ok for a provisioned tenant" do
      {body, _answer} = create!()
      assert :ok = Letflow.TenantLifecycle.release_runtime(%{id: body["tenant_id"]})
    end
  end

  # --- N: narrowness ---------------------------------------------------------

  describe "N narrowness" do
    test "N1 the write credential reaches no other route" do
      for {method, path} <- [
            {:post, "/api/v1/onboarding"},
            {:post, "/api/v1/tenants"},
            {:get, "/api/v1/tenants"},
            {:get, "/api/v1/identity/users"},
            {:get, "/api/v1/me"},
            {:post, "/api/v1/api-tokens"}
          ] do
        conn = call(method, path, @write_token, if(method == :post, do: %{}))
        assert conn.status in [401, 403, 404], "#{path}: #{conn.status}"
      end
    end

    test "N1b both credentials reach no router of the api pipeline, even with a tenant header",
         ctx do
      source = File.read!("lib/letflow/plugs/api_pipeline.ex")
      mounts = Regex.scan(~r/^  forward\("([^"]+)"/m, source) |> Enum.map(&List.last/1)
      assert length(mounts) > 25

      slug = Repo.get!(Tenant, ctx.platform.tenant_id).slug

      for token <- [@write_token, @read_token], mount <- mounts, method <- [:get, :post] do
        conn =
          conn(method, "/api/v1" <> mount, if(method == :post, do: "{}"))
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-tenant-slug", slug)
          |> put_req_header("authorization", "Bearer " <> token)
          |> Letflow.Router.call(Letflow.Router.init([]))

        refute conn.status in 200..299, "#{method} #{mount}: #{conn.status}"
      end
    end

    test "N2 the router declares exactly the six routes and no credential, user or list route" do
      source = File.read!("lib/letflow/routers/admin_v1.ex")
      routes = Regex.scan(~r/^  (get|post|put|patch|delete) "([^"]+)"/m, source)

      assert Enum.sort(Enum.map(routes, fn [_, verb, path] -> {verb, path} end)) ==
               Enum.sort([
                 {"get", "/tenants/:id"},
                 {"post", "/tenants"},
                 {"post", "/tenants/:id/suspend"},
                 {"post", "/tenants/:id/resume"},
                 {"post", "/tenants/:id/expire"},
                 {"delete", "/tenants/:id"}
               ])
    end

    test "N3 a PLATFORM_ADMIN of another tenant is refused on /admin/v1 and on the admin plane",
         ctx do
      other = TenantFixture.provisioned_tenant!(slug_prefix: "req572-other")
      admin = Fixture.mint_token!(other, ["PLATFORM_ADMIN"])

      assert call(:post, "/admin/v1/tenants", admin, create_body()).status == 401

      for {method, path, payload} <- [
            {:post, "/api/v1/tenants",
             %{"slug" => "x-#{System.unique_integer([:positive])}", "display_name" => "x"}},
            {:post, "/api/v1/onboarding", %{}}
          ] do
        conn =
          Fixture.api_conn(method, path, admin, other.tenant.slug, payload)
          |> Fixture.dispatch_api()

        assert conn.status in [401, 403], "#{path}: #{conn.status}"
      end

      assert ctx.platform.tenant_id != other.tenant_id
    end

    test "N4 acting on tenant A leaves tenant B untouched" do
      {a, _} = create!()
      {b, _} = create!()
      b_lifecycle = Repo.get!(Lifecycle, b["tenant_id"])
      b_tenant = Repo.get!(Tenant, b["tenant_id"])
      b_grants = grants(b["tenant_id"])

      for action <- ~w(suspend resume expire) do
        conn = call(:post, "/admin/v1/tenants/#{a["tenant_id"]}/#{action}", @write_token)
        refute conn.resp_body =~ b["tenant_id"]
        refute conn.resp_body =~ b["hostname"]
      end

      assert Repo.get!(Lifecycle, b["tenant_id"]) == b_lifecycle
      assert Repo.get!(Tenant, b["tenant_id"]) == b_tenant
      assert grants(b["tenant_id"]) == b_grants
    end

    test "N5 responses hold only the allowlisted keys and no slug, realm or e-mail" do
      {body, answer} = create!()
      assert answer |> Map.keys() |> Enum.sort() == ~w(handover server_url status tenant_id)
      raw = Jason.encode!(answer)
      refute raw =~ body["owner_email"]
      refute raw =~ body["idp_realm_id"]
      refute raw =~ "t-" <> String.replace(body["tenant_id"], "-", "")

      transition = call(:post, "/admin/v1/tenants/#{body["tenant_id"]}/suspend", @write_token)
      assert transition |> json() |> Map.keys() |> Enum.sort() == ["status", "tenant_id"]
    end
  end

  # --- L: rate limit ---------------------------------------------------------

  describe "L rate limit" do
    setup do
      previous = Application.get_env(:letflow, Letflow.Plugs.ProvisionerAuth)
      clock = :counters.new(1, [])
      :counters.put(clock, 1, 1_000_020)

      Application.put_env(
        :letflow,
        Letflow.Plugs.ProvisionerAuth,
        Keyword.merge(previous,
          limit: 3,
          window_seconds: 60,
          clock: fn -> :counters.get(clock, 1) end
        )
      )

      %{clock: clock}
    end

    test "L1 the request over the limit is 429 with retry-after; the next window admits; classes are separate",
         %{clock: clock} do
      id = Ecto.UUID.generate()
      get = fn token -> call(:get, "/admin/v1/tenants/#{id}", token) end

      for _ <- 1..3, do: assert(get.(@write_token).status == 404)
      conn = get.(@write_token)
      assert conn.status == 429
      assert json(conn)["error"] == "rate_limited"
      [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) in 1..60

      assert get.(@read_token).status == 404

      :counters.put(clock, 1, 1_000_020 + 60)
      assert get.(@write_token).status == 404
    end

    test "L2 bad credentials do not consume the budget" do
      id = Ecto.UUID.generate()
      for _ <- 1..10, do: assert(call(:get, "/admin/v1/tenants/#{id}", "bad").status == 401)
      for _ <- 1..3, do: assert(call(:get, "/admin/v1/tenants/#{id}", @write_token).status == 404)
    end
  end

  # --- D / BR ----------------------------------------------------------------

  # REQ-580: DELETE records the request and purges once the retention has run out.
  describe "D DELETE" do
    defp retention!(days) do
      prov = Application.get_env(:letflow, Letflow.TenantProvisioner, [])

      Application.put_env(
        :letflow,
        Letflow.TenantProvisioner,
        Keyword.put(prov, :retention_days, days)
      )
    end

    defp lifecycle!(id), do: Repo.get!(Lifecycle, id)

    defp delete!(id, token \\ @write_token), do: call(:delete, "/admin/v1/tenants/#{id}", token)

    test "D1 an active tenant is deactivated and the request is audited; nothing is purged",
         ctx do
      {body, _answer} = create!()
      id = body["tenant_id"]
      retention!(30)

      conn = delete!(id)
      assert conn.status == 202
      assert json(conn) == %{"tenant_id" => id, "status" => "suspended"}

      assert Repo.get!(Tenant, id).status == :inactive
      assert %Lifecycle{deletion_requested_at: %DateTime{}, purged_at: nil} = lifecycle!(id)

      assert [_one] =
               Enum.filter(
                 platform_entries(ctx, "platform.tenant_lifecycle.changed"),
                 &(&1.resource_id == id)
               )

      assert [entry] =
               Enum.filter(
                 platform_entries(ctx, "platform.tenant.deletion_requested"),
                 &(&1.resource_id == id)
               )

      assert Enum.sort(Map.keys(entry.after_state)) == ["deletion_requested_at", "tenant_id"]
    end

    test "D2/D4 inside retention a repeat changes and audits nothing more", ctx do
      {body, _answer} = create!()
      id = body["tenant_id"]
      retention!(30)
      assert delete!(id).status == 202
      requested = lifecycle!(id)

      conn = delete!(id)
      assert conn.status == 202
      assert json(conn) == %{"tenant_id" => id, "status" => "suspended"}
      assert lifecycle!(id) == requested

      assert [_one] =
               Enum.filter(
                 platform_entries(ctx, "platform.tenant.deletion_requested"),
                 &(&1.resource_id == id)
               )

      assert platform_entries(ctx, "platform.tenant.purged")
             |> Enum.filter(&(&1.resource_id == id)) == []
    end

    test "D3/D4 past the retention the tenant is purged; a repeat answers the same and writes nothing",
         ctx do
      {body, _answer} = create!()
      id = body["tenant_id"]
      retention!(0)

      assert call(:post, "/admin/v1/tenants/#{id}/suspend", @write_token).status == 200
      conn = delete!(id)
      assert conn.status == 200
      assert json(conn) == %{"tenant_id" => id, "status" => "deleted"}

      {:ok, schema} = TenantProvisioning.schema_name_for_tenant(id)

      assert Repo.query!("SELECT 1 FROM information_schema.schemata WHERE schema_name = $1", [
               schema
             ]).rows == []

      assert %Lifecycle{lifecycle: "deleted", purged_at: %DateTime{}} = purged = lifecycle!(id)

      entries = fn ->
        for action <- ~w(platform.tenant.purged platform.tenant.deletion_requested),
            e <- platform_entries(ctx, action),
            e.resource_id == id,
            do: e.id
      end

      before = entries.()
      assert length(before) == 2

      assert delete!(id).resp_body == conn.resp_body
      assert lifecycle!(id) == purged
      assert entries.() == before
    end

    test "D5 an expired tenant counts its retention from expires_at" do
      {body, _answer} = create!()
      id = body["tenant_id"]
      retention!(30)
      assert call(:post, "/admin/v1/tenants/#{id}/expire", @write_token).status == 200
      past = DateTime.add(DateTime.utc_now(), -31 * 86_400, :second)
      Repo.update_all(from(l in Lifecycle, where: l.tenant_id == ^id), set: [expires_at: past])

      conn = delete!(id)
      assert conn.status == 200 and json(conn)["status"] == "deleted"
    end

    test "D6 unknown, non-uuid and non-provisioned ids are one 404, nothing written" do
      bare =
        Repo.insert!(%Tenant{
          id: Ecto.UUID.generate(),
          slug: "bare-#{System.unique_integer([:positive])}",
          display_name: "bare"
        })

      track(bare.id)
      before = counts()
      bodies = for id <- [Ecto.UUID.generate(), "not-a-uuid", bare.id], do: delete!(id)
      assert Enum.all?(bodies, &(&1.status == 404))
      assert bodies |> Enum.map(& &1.resp_body) |> Enum.uniq() |> length() == 1
      assert counts() == before
    end

    test "D7 the read credential is 403 and changes nothing" do
      {body, _answer} = create!()
      conn = delete!(body["tenant_id"], @read_token)
      assert conn.status == 403
      assert lifecycle!(body["tenant_id"]).lifecycle == "active"
      assert delete!(body["tenant_id"], "wrong-token").status == 401
    end

    test "D8/D10 a production tenant is 409 and is not deactivated" do
      {body, _answer} = create!()
      id = body["tenant_id"]
      Repo.update_all(from(l in Lifecycle, where: l.tenant_id == ^id), set: [tier: "production"])

      conn = delete!(id)
      assert conn.status == 409 and json(conn)["error"] == "conflict"
      assert Repo.get!(Tenant, id).status == :active
      assert %Lifecycle{lifecycle: "active", deletion_requested_at: nil} = lifecycle!(id)
    end

    test "D10 the platform tenant with a lifecycle row is 409 and stays active", ctx do
      id = ctx.platform.tenant_id
      Repo.insert!(%Lifecycle{tenant_id: id, lifecycle: "active", tier: "demo", language: "en"})

      on_exit(fn ->
        Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
        Repo.delete_all(from(l in Lifecycle, where: l.tenant_id == ^id))
      end)

      assert delete!(id).status == 409
      assert Repo.get!(Tenant, id).status == :active
      assert lifecycle!(id).deletion_requested_at == nil
    end

    test "D9 a suspended row without deletion_requested_at gets it from a repeat DELETE", ctx do
      {body, _answer} = create!()
      id = body["tenant_id"]
      retention!(30)
      assert call(:post, "/admin/v1/tenants/#{id}/suspend", @write_token).status == 200
      assert lifecycle!(id).deletion_requested_at == nil

      assert delete!(id).status == 202
      assert lifecycle!(id).deletion_requested_at != nil

      assert [_one] =
               Enum.filter(
                 platform_entries(ctx, "platform.tenant.deletion_requested"),
                 &(&1.resource_id == id)
               )
    end

    test "RS2 resume after a DELETE is 409 and changes nothing" do
      {body, _answer} = create!()
      id = body["tenant_id"]
      retention!(30)
      assert delete!(id).status == 202
      before = lifecycle!(id)

      assert call(:post, "/admin/v1/tenants/#{id}/resume", @write_token).status == 409
      assert lifecycle!(id) == before
      assert Repo.get!(Tenant, id).status == :inactive
    end

    test "E8 expire of a deletion-requested tenant is allowed; retention counts from expires_at" do
      {body, _answer} = create!()
      id = body["tenant_id"]
      retention!(30)
      assert delete!(id).status == 202
      assert call(:post, "/admin/v1/tenants/#{id}/expire", @write_token).status == 200

      # expires_at is 14 days ahead: not yet eligible.
      assert json(delete!(id))["status"] == "expired"
      past = DateTime.add(DateTime.utc_now(), -31 * 86_400, :second)
      Repo.update_all(from(l in Lifecycle, where: l.tenant_id == ^id), set: [expires_at: past])
      assert json(delete!(id))["status"] == "deleted"
    end

    test "GP1 a purged tenant answers GET with status deleted and purged_at, never 404" do
      {body, _answer} = create!()
      id = body["tenant_id"]
      before = json(call(:get, "/admin/v1/tenants/#{id}", @write_token))
      assert before["purged_at"] == nil

      retention!(0)
      assert call(:post, "/admin/v1/tenants/#{id}/suspend", @write_token).status == 200
      assert delete!(id).status == 200

      for token <- [@write_token, @read_token] do
        conn = call(:get, "/admin/v1/tenants/#{id}", token)
        assert conn.status == 200
        answer = json(conn)
        assert Enum.sort(Map.keys(answer)) == @get_keys
        assert answer["status"] == "deleted"
        assert {:ok, _at, 0} = DateTime.from_iso8601(answer["purged_at"])
        refute conn.resp_body =~ "REQ-572 Demo"
      end
    end

    test "RS1 resume of a purged tenant is 409" do
      {body, _answer} = create!()
      id = body["tenant_id"]
      retention!(0)
      assert call(:post, "/admin/v1/tenants/#{id}/suspend", @write_token).status == 200
      assert delete!(id).status == 200
      assert call(:post, "/admin/v1/tenants/#{id}/resume", @write_token).status == 409
      assert Repo.get!(Tenant, id).status == :inactive
    end

    test "S2 the retention variable is read by runtime.exs and listed in .env.example" do
      runtime = File.read!("config/runtime.exs")
      [_, list] = Regex.run(~r/provisioner_env =\s*~w\((.*?)\)/s, runtime)
      assert list =~ "LETFLOW_PROVISIONER_RETENTION_DAYS"
      assert File.read!("deploy/.env.example") =~ "LETFLOW_PROVISIONER_RETENTION_DAYS"
    end
  end

  describe "BR body reading" do
    defp raw_post(payload, content_type) do
      conn(:post, "/admin/v1/tenants", payload)
      |> put_req_header("content-type", content_type)
      |> put_req_header("authorization", "Bearer " <> @write_token)
      |> Letflow.Router.call(Letflow.Router.init([]))
    end

    test "BR1 a body over 16384 bytes is 400" do
      big = Jason.encode!(create_body(%{"name" => String.duplicate("x", 17_000)}))
      assert raw_post(big, "application/json").status == 400
    end

    test "BR2 a non-JSON content type is 400" do
      assert raw_post(Jason.encode!(create_body()), "text/plain").status == 400
    end

    test "BR3 invalid JSON is 400" do
      assert raw_post("{nope", "application/json").status == 400
    end

    test "BR4 an array or null body is 400" do
      assert raw_post("[1]", "application/json").status == 400
      assert raw_post("null", "application/json").status == 400
    end

    test "BR5 the router declares no Plug.Parsers" do
      refute File.read!("lib/letflow/routers/admin_v1.ex") =~ "plug(Plug.Parsers"
      refute File.read!("lib/letflow/routers/admin_v1.ex") =~ "plug Plug.Parsers"
    end

    test "BR6 the router reads no tenant or slug key and has no tenant path parameter" do
      source = File.read!("lib/letflow/routers/admin_v1.ex")
      refute source =~ ~r/params\[\s*"[^"]*(tenant|slug)/i
      refute source =~ ~r/:(tenant|slug)[a-z_]*/i
    end
  end
end
