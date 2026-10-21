defmodule Letflow.Routers.Req469TenantTypeTest do
  @moduledoc """
  REQ-469 (GH #2476): `tenants.tenant_type` through `POST /tenants` and `PATCH /tenants/:slug`
  (creation, PLATFORM_ADMIN-only change, audit shape, combined PATCH with `login_disclosure_mode`).

  Dispatch is direct `Letflow.Routers.Tenants.call/2` with a hand-assigned `auth_context`, as
  `req442_tenants_mode_test.exs` does. `async: false` (platform-tenant pin, `Sandbox.mode(:auto)`).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Tenants.init([])

  setup do
    platform_fixture()
    :ok
  end

  defp platform_fixture do
    case Process.get(:req469_platform_fixture) do
      nil ->
        fixture = TenantFixture.provisioned_tenant!(slug_prefix: "req469-platform")
        Process.put(:req469_platform_fixture, fixture)
        fixture

      fixture ->
        fixture
    end
  end

  defp conn_for(method, path, auth_context, body) do
    conn(method, path)
    |> Map.put(:body_params, body || %{})
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, auth_context)
    |> assign(:trace_id, "req469-trace-id")
  end

  defp operator_ctx(user_id \\ Ecto.UUID.generate()),
    do:
      PlatformTenantFixture.operator_auth_context(user_id, platform_fixture().tenant_id, [
        "PLATFORM_ADMIN"
      ])

  defp dispatch(conn), do: Letflow.Routers.Tenants.call(conn, @opts)

  defp admin_patch(slug, body, user_id \\ Ecto.UUID.generate()),
    do: :patch |> conn_for("/#{slug}", operator_ctx(user_id), body) |> dispatch()

  defp stored_type(tenant_id), do: Repo.get!(Tenant, tenant_id).tenant_type

  defp tenant_entries(schema_name, tenant_id) do
    Repo.all(
      from(e in Entry,
        where: e.resource_id == ^tenant_id and e.action == "tenant.platform_setting.updated"
      ),
      prefix: schema_name
    )
  end

  defp platform_entries(tenant_id) do
    Repo.all(
      from(e in Entry,
        where:
          e.resource_id == ^tenant_id and e.action == "platform.tenant_platform_setting.updated"
      ),
      prefix: platform_fixture().schema_name
    )
  end

  defp all_audit_count(schema_name), do: Repo.aggregate(Entry, :count, prefix: schema_name)

  defp create_body(extra) do
    Map.merge(
      %{
        "slug" => Letflow.TenantSlugFixture.unique_slug("req469-new"),
        "display_name" => "REQ-469 New"
      },
      extra
    )
  end

  describe "creation" do
    test "tenant_type production is accepted and echoed" do
      body = create_body(%{"tenant_type" => "production"})
      resp = :post |> conn_for("/", operator_ctx(), body) |> dispatch()

      assert resp.status == 201
      assert Jason.decode!(resp.resp_body)["tenant_type"] == "production"
      assert Repo.get_by!(Tenant, slug: body["slug"]).tenant_type == "production"
    end

    test "tenant_type absent defaults to test" do
      body = create_body(%{})
      resp = :post |> conn_for("/", operator_ctx(), body) |> dispatch()

      assert resp.status == 201
      assert Jason.decode!(resp.resp_body)["tenant_type"] == "test"
      assert Repo.get_by!(Tenant, slug: body["slug"]).tenant_type == "test"
    end

    test "an invalid tenant_type is 422 and writes nothing" do
      body = create_body(%{"tenant_type" => "staging"})
      resp = :post |> conn_for("/", operator_ctx(), body) |> dispatch()

      assert resp.status == 422
      assert Repo.get_by(Tenant, slug: body["slug"]) == nil
    end
  end

  describe "change authorization" do
    test "PLATFORM_ADMIN of the platform tenant changes the type and it persists" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-set")
      resp = admin_patch(t.tenant.slug, %{"tenant_type" => "production"})

      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["tenant_type"] == "production"
      assert stored_type(t.tenant_id) == "production"
    end

    test "TENANT_ADMIN of the tenant, PLATFORM_ADMIN of another tenant and a task worker get the fixed 403; row unchanged" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-authz")
      other = TenantFixture.provisioned_tenant!(slug_prefix: "req469-authz-other")
      before = Repo.get!(Tenant, t.tenant_id)

      contexts = [
        %{user_id: Ecto.UUID.generate(), tenant_id: t.tenant_id, roles: ["TENANT_ADMIN"]},
        %{user_id: Ecto.UUID.generate(), tenant_id: other.tenant_id, roles: ["PLATFORM_ADMIN"]},
        %{user_id: Ecto.UUID.generate(), tenant_id: t.tenant_id, roles: ["TASK_WORKER"]}
      ]

      for ctx <- contexts do
        resp =
          :patch
          |> conn_for("/#{t.tenant.slug}", ctx, %{"tenant_type" => "production"})
          |> dispatch()

        assert resp.status == 403, "context #{inspect(ctx.roles)} got #{resp.status}"

        assert Jason.decode!(resp.resp_body) == %{
                 "type" => "https://bpm.example.com/problems/forbidden",
                 "title" => "Forbidden",
                 "status" => 403,
                 "detail" => "insufficient permissions",
                 "trace_id" => "req469-trace-id"
               }
      end

      assert Repo.get!(Tenant, t.tenant_id) == before
      assert all_audit_count(t.schema_name) == 0
    end

    test "a tenant_type key sent to the tenant-settings route does not change the column" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-settings")

      for body <- [
            %{"tenant_type" => "production"},
            %{"settings" => %{"tenant_type" => "production"}}
          ] do
        resp =
          conn(:patch, "/")
          |> Map.put(:body_params, body)
          |> put_req_header("content-type", "application/json")
          |> assign(:auth_context, %{
            user_id: Ecto.UUID.generate(),
            tenant_id: t.tenant_id,
            roles: ["TENANT_ADMIN"]
          })
          |> assign(:trace_id, "req469-settings-trace")
          |> Letflow.Routers.TenantSettings.call(Letflow.Routers.TenantSettings.init([]))

        assert resp.status in [200, 422]
        assert stored_type(t.tenant_id) == "test"
      end

      Identity.update_tenant_settings(t.tenant.slug, %{
        "settings" => %{"tenant_type" => "production"}
      })

      assert stored_type(t.tenant_id) == "test"
    end

    test "an invalid or null tenant_type on PATCH is 422 and the row is unchanged" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-bad")

      for value <- ["staging", nil] do
        resp = admin_patch(t.tenant.slug, %{"tenant_type" => value})
        assert resp.status == 422, "value #{inspect(value)} got #{resp.status}"
      end

      assert stored_type(t.tenant_id) == "test"
    end

    test "a PATCH that leaves tenant_type out keeps the stored value" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-omit")
      assert admin_patch(t.tenant.slug, %{"tenant_type" => "production"}).status == 200
      assert admin_patch(t.tenant.slug, %{"display_name" => "Renamed"}).status == 200
      assert stored_type(t.tenant_id) == "production"
    end
  end

  describe "audit" do
    test "a change writes one constant tenant-chain entry and one platform-chain entry naming actor and tenant" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-audit")
      actor = Ecto.UUID.generate()

      assert admin_patch(t.tenant.slug, %{"tenant_type" => "production"}, actor).status == 200

      assert [entry] = tenant_entries(t.schema_name, t.tenant_id)
      assert entry.actor_id == nil
      assert entry.trace_id == nil
      assert entry.before_state == nil
      assert entry.after_state == %{"changed" => true, "actor_class" => "platform_operator"}
      assert all_audit_count(t.schema_name) == 1

      dumped = inspect(Map.from_struct(entry))
      refute dumped =~ "production"
      refute dumped =~ "tenant_type"

      assert [platform_entry] = platform_entries(t.tenant_id)
      assert platform_entry.actor_id == actor
      assert platform_entry.resource_id == t.tenant_id
      assert platform_entry.before_state == %{"tenant_type" => "test"}

      assert platform_entry.after_state ==
               %{"tenant_id" => t.tenant_id, "changed" => true, "tenant_type" => "production"}
    end

    test "a PATCH to the same value writes neither entry" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-same")

      resp = admin_patch(t.tenant.slug, %{"tenant_type" => "test"})

      assert resp.status == 200
      assert tenant_entries(t.schema_name, t.tenant_id) == []
      assert platform_entries(t.tenant_id) == []
    end

    test "a forced audit failure is 500 and leaves the column unchanged" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-auditfail")
      Repo.query!(~s(DROP TABLE "#{t.schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE IF NOT EXISTS "#{t.schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        resp = admin_patch(t.tenant.slug, %{"tenant_type" => "production"})
        assert resp.status == 500
        refute resp.resp_body =~ "audit_entries"
      end)

      assert stored_type(t.tenant_id) == "test"
    end

    test "no actor id is :audit_failed and the column is unchanged" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-noactor")

      assert {:error, :audit_failed} =
               Identity.patch_tenant(t.tenant.slug, %{"tenant_type" => "production"},
                 actor_id: nil,
                 platform_prefix: platform_fixture().schema_name
               )

      assert stored_type(t.tenant_id) == "test"
    end
  end

  describe "combined PATCH" do
    test "mode and type together write one entry per chain, with neither mode value in a payload" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-combined")

      resp =
        admin_patch(t.tenant.slug, %{
          "login_disclosure_mode" => "uniform_plus_email",
          "tenant_type" => "production"
        })

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["tenant_type"] == "production"
      assert body["login_disclosure_mode"] == "uniform_plus_email"

      assert [entry] = tenant_entries(t.schema_name, t.tenant_id)
      assert all_audit_count(t.schema_name) == 1
      assert [platform_entry] = platform_entries(t.tenant_id)

      for e <- [entry, platform_entry] do
        dumped = inspect(Map.from_struct(e))
        refute dumped =~ "uniform_plus_email"
        refute dumped =~ "login_disclosure_mode"
      end
    end
  end

  describe "tenant_map/1 allowlist" do
    test "exactly eight keys including tenant_type, on get and patch" do
      t = TenantFixture.provisioned_tenant!(slug_prefix: "req469-keys")

      expected =
        Enum.sort([
          "id",
          "slug",
          "display_name",
          "status",
          "login_disclosure_mode",
          "tenant_type",
          "inserted_at",
          "updated_at"
        ])

      get = :get |> conn_for("/#{t.tenant.slug}", operator_ctx(), nil) |> dispatch()
      assert Map.keys(Jason.decode!(get.resp_body)) |> Enum.sort() == expected

      patch = admin_patch(t.tenant.slug, %{"display_name" => "Keys"})
      assert Map.keys(Jason.decode!(patch.resp_body)) |> Enum.sort() == expected
    end
  end
end
