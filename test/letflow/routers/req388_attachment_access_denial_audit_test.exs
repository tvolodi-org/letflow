defmodule Letflow.Routers.Req388AttachmentAccessDenialAuditTest do
  @moduledoc """
  Tests for REQ-388 -- the `Letflow.Audit` entry written on a denied
  instance-attachment content fetch (cross-tenant/never-issued, fused, and
  cross-instance-same-tenant), added to
  `Letflow.Routers.Instances.fetch_scoped_attachment_content/4`. See
  `lib/letflow/design/req388-attachment-access-denial-audit.md` for the
  full design.

  Dispatches the denied `GET /instances/:id/attachments/:attachment_id`
  request through `Letflow.Routers.Instances.call/2` directly, then reads
  the resulting audit entry back through a real `GET /audit` dispatch to
  `Letflow.Routers.Audit.call/2` -- matching
  `test/letflow/routers/tenant_settings_test.exs`'s own REQ-382 AC4
  precedent (`get_audit/2`) -- rather than calling `Letflow.Audit.list_entries/1`
  or `Letflow.Repo` directly, per this requirement's own AC1 wording ("a
  test asserts the entry's presence and content over real HTTP, not by
  calling a context function directly").

  Uses `Letflow.DataCase` (real Postgres) and `Letflow.TenantFixture`,
  `async: false`, matching `req212_attachments_routes_test.exs`'s own
  established convention for this fixture.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Repository.Attachments
  alias Letflow.TenantFixture

  import Letflow.TestSupport.InstanceFixture, only: [real_instance!: 1]

  @instances_opts Letflow.Routers.Instances.init([])
  @audit_opts Letflow.Routers.Audit.init([])

  # ── Dispatch helpers (mirrors req212_attachments_routes_test.exs) ───────

  defp build_conn(method, path, tenant, fields) do
    roles = Keyword.get(fields, :roles, ["TENANT_ADMIN"])
    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())

    conn(method, path)
    |> assign(:auth_context, %{user_id: user_id, tenant_id: tenant.tenant_id, roles: roles})
    |> assign(:trace_id, "req388-test-trace-id")
    |> assign(:scoped_opts, prefix: tenant.schema_name)
  end

  defp dispatch(conn), do: Letflow.Routers.Instances.call(conn, @instances_opts)

  defp get_audit(tenant, query_string) do
    conn(:get, "/?" <> query_string)
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, "req388-audit-trace-id")
    |> Letflow.Routers.Audit.call(@audit_opts)
  end

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-388 Attachment Audit Test Tenant"
    )
  end

  defp upload!(tenant, instance_id, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          instance_id: instance_id,
          raw_bytes: "hello attachment bytes",
          file_name: "note.txt",
          content_type: "text/plain",
          uploaded_by: Ecto.UUID.generate(),
          description: nil
        },
        Map.new(overrides)
      )

    {:ok, attachment} = Attachments.upload(attrs, prefix: tenant.schema_name)
    attachment
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1 -- cross-tenant/never-issued (fused) denial writes one audit entry
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: cross-tenant/never-issued fused denial" do
    test "a cross-tenant attachment id writes exactly one attachment.access_denied entry naming the actor and attempted id" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req388-cross-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req388-cross-b")

      instance_id = real_instance!(tenant_a)
      tenant_b_attachment = upload!(tenant_b, instance_id)
      actor_id = Ecto.UUID.generate()

      resp =
        build_conn(
          :get,
          "/#{instance_id}/attachments/#{tenant_b_attachment.id}",
          tenant_a,
          roles: ["TENANT_ADMIN"],
          user_id: actor_id
        )
        |> dispatch()

      assert resp.status == 404

      audit_resp = get_audit(tenant_a, "resource_type=attachment")
      assert audit_resp.status == 200
      audit_body = Jason.decode!(audit_resp.resp_body)

      assert audit_body["count"] == 1
      assert [item] = audit_body["items"]

      assert item["action"] == "attachment.access_denied"
      assert item["resource_type"] == "attachment"
      assert item["resource_id"] == tenant_b_attachment.id
      assert item["actor_id"] == actor_id
      assert item["after_state"]["instance_id"] == instance_id
      assert item["after_state"]["reason"] == "cross_tenant_or_not_found"
      refute is_nil(item["timestamp"])

      # Tenant B's own audit trail is untouched.
      tenant_b_audit_resp = get_audit(tenant_b, "resource_type=attachment")
      assert Jason.decode!(tenant_b_audit_resp.resp_body)["count"] == 0
    end

    test "a genuinely never-issued attachment id writes the same shape of entry" do
      tenant = provisioned_tenant("req388-never-issued")
      instance_id = real_instance!(tenant)
      never_issued_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      resp =
        build_conn(
          :get,
          "/#{instance_id}/attachments/#{never_issued_id}",
          tenant,
          roles: ["TENANT_ADMIN"],
          user_id: actor_id
        )
        |> dispatch()

      assert resp.status == 404

      audit_resp = get_audit(tenant, "resource_type=attachment")
      audit_body = Jason.decode!(audit_resp.resp_body)

      assert audit_body["count"] == 1
      assert [item] = audit_body["items"]
      assert item["action"] == "attachment.access_denied"
      assert item["resource_id"] == never_issued_id
      assert item["actor_id"] == actor_id
      assert item["after_state"]["reason"] == "cross_tenant_or_not_found"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1 -- cross-instance-same-tenant denial writes one audit entry
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: cross-instance-same-tenant denial" do
    test "an attachment real and tenant-correct but belonging to a different instance writes one entry" do
      tenant = provisioned_tenant("req388-cross-instance")
      instance_x = real_instance!(tenant)
      instance_y = real_instance!(tenant)
      actor_id = Ecto.UUID.generate()

      attachment = upload!(tenant, instance_x)

      resp =
        build_conn(
          :get,
          "/#{instance_y}/attachments/#{attachment.id}",
          tenant,
          roles: ["TENANT_ADMIN"],
          user_id: actor_id
        )
        |> dispatch()

      assert resp.status == 404

      audit_resp = get_audit(tenant, "resource_type=attachment")
      audit_body = Jason.decode!(audit_resp.resp_body)

      assert audit_body["count"] == 1
      assert [item] = audit_body["items"]

      assert item["action"] == "attachment.access_denied"
      assert item["resource_type"] == "attachment"
      assert item["resource_id"] == attachment.id
      assert item["actor_id"] == actor_id
      assert item["after_state"]["instance_id"] == instance_y
      assert item["after_state"]["reason"] == "cross_instance"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1 -- no audit entry on a successful fetch
  # ══════════════════════════════════════════════════════════════════════

  describe "no audit entry on a successful fetch" do
    test "a real, same-tenant, same-instance fetch writes zero attachment.access_denied entries" do
      tenant = provisioned_tenant("req388-success")
      instance_id = real_instance!(tenant)
      attachment = upload!(tenant, instance_id)

      resp =
        build_conn(
          :get,
          "/#{instance_id}/attachments/#{attachment.id}",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert resp.status == 200

      audit_resp = get_audit(tenant, "resource_type=attachment")
      assert Jason.decode!(audit_resp.resp_body)["count"] == 0
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # ISS-0980 -- record_attachment_access_denied_audit/5 is rescue-hardened,
  # never raises
  # ══════════════════════════════════════════════════════════════════════

  describe "ISS-0980: record_attachment_access_denied_audit/5 is rescue-hardened, never raises" do
    test "a genuine Postgres-level audit-insert failure during a denied attachment fetch is logged and swallowed -- the response is still 404, not 500" do
      tenant = provisioned_tenant("iss0980-ia")
      instance_id = real_instance!(tenant)
      never_issued_id = Ecto.UUID.generate()

      Repo.query!(~s(DROP TABLE "#{tenant.schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{tenant.schema_name}".audit_entries (
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

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          resp =
            build_conn(
              :get,
              "/#{instance_id}/attachments/#{never_issued_id}",
              tenant,
              roles: ["TENANT_ADMIN"]
            )
            |> dispatch()

          assert resp.status == 404
        end)

      assert log =~ "attachment.access_denied audit write raised"
      assert log =~ instance_id
      assert log =~ "Postgrex.Error"
    end
  end
end
