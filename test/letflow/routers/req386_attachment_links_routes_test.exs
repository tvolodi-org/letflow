defmodule Letflow.Routers.Req386AttachmentLinksRoutesTest do
  @moduledoc """
  Route-level tests for REQ-386's two new attachment-link routes:
  `POST /instances/:id/attachments/:attachment_id/link` and
  `GET /instances/:id/attachments/:attachment_id/link-content`, written by
  TEST-DESIGNER at WF-02 Step 3. A new, separate REQ-numbered file rather than
  additions to `req212_attachments_routes_test.exs` -- following this codebase's own
  precedent (`test/letflow/routers/req317_record_attachments_routes_test.exs` exists as
  its own file for a later attachment-related requirement rather than being folded into
  REQ-212's file), and per this run's explicit instruction not to touch
  `req212_attachments_routes_test.exs` at all (AC5's whole point is that it stays
  byte-for-byte unmodified).

  Uses `Letflow.DataCase` (real Postgres, DIRECTIVE T-1) and the same dispatch idiom as
  `req212_attachments_routes_test.exs`: `Letflow.Routers.Instances.call/2` invoked
  directly, with `conn.assigns[:auth_context]`/`:scoped_opts`/`:trace_id` preset (this
  router's tests bypass `Letflow.Plugs.AuthPipeline`'s real bearer-token verification,
  matching every other router test file in this codebase).

  ## No real sleep for expiry (AC2)

  The route handlers (`handle_issue_attachment_link/3`,
  `handle_get_attachment_link_content/3`) call
  `Letflow.Repository.AttachmentLinks.issue/2` and `verify/2` with **no** `now` option of
  their own -- the design's injectable clock is a Step-3-test-only affordance at the
  `AttachmentLinks` module boundary, not threaded through the HTTP layer. So instead of
  injecting a fake "now" through the route, these tests mint an **already-expired**
  token directly via `AttachmentLinks.issue/3`'s own `now:` option (e.g. `now: fn ->
  DateTime.add(DateTime.utc_now(), -301, :second) end`), and then present that
  already-expired token to the route through a completely normal HTTP-shaped GET. The
  route's own `AttachmentLinks.verify/2` call always uses the real, current wall-clock
  time, and since the token's own `expires_at` was minted in the past relative to any
  real "now", it is deterministically expired the instant it is presented -- no
  `Process.sleep`, no timing race, no wall-clock dependency in the test's own assertions.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Repository.AttachmentLinks
  alias Letflow.Repository.Attachments
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Instances.init([])

  # ── Dispatch helpers (matches req212_attachments_routes_test.exs's own idiom) ──

  defp build_conn(method, path, tenant, fields) do
    roles = Keyword.get(fields, :roles, [])
    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())

    conn(method, path)
    |> assign(:auth_context, %{user_id: user_id, tenant_id: tenant.tenant_id, roles: roles})
    |> assign(:trace_id, "fixed-test-trace-id")
    |> assign(:scoped_opts, prefix: tenant.schema_name)
  end

  defp dispatch(conn), do: Letflow.Routers.Instances.call(conn, @opts)

  # ── Fixture helpers ────────────────────────────────────────────────────

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-386 Attachment Links Router Test Tenant"
    )
  end

  defp upload!(tenant, instance_id, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          instance_id: instance_id,
          raw_bytes: "signed-link content bytes",
          file_name: "linked-doc.txt",
          content_type: "text/plain",
          uploaded_by: Ecto.UUID.generate(),
          description: nil
        },
        Map.new(overrides)
      )

    {:ok, attachment} = Attachments.upload(attrs, prefix: tenant.schema_name)
    attachment
  end

  # A token minted directly via the context module (not through the POST route),
  # with an already-past expiry -- see moduledoc for why this is how AC2 is
  # exercised without a real sleep.
  defp expired_token_for(attachment_id, tenant) do
    already_past = DateTime.add(DateTime.utc_now(), -301, :second)

    {:ok, %{token: token}} =
      AttachmentLinks.issue(attachment_id, tenant.tenant_id, now: fn -> already_past end)

    token
  end

  defp issue_link_conn(tenant, instance_id, attachment_id, roles) do
    build_conn(
      :post,
      "/#{instance_id}/attachments/#{attachment_id}/link",
      tenant,
      roles: roles
    )
    |> dispatch()
  end

  defp get_link_content_conn(tenant, instance_id, attachment_id, link_token, roles) do
    encoded_token = URI.encode_www_form(link_token)

    build_conn(
      :get,
      "/#{instance_id}/attachments/#{attachment_id}/link-content?link_token=#{encoded_token}",
      tenant,
      roles: roles
    )
    |> dispatch()
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1 -- issue a signed link with a stated, bounded expiry; usable before
  # expiry to fetch the document's bytes
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: POST /instances/:id/attachments/:attachment_id/link" do
    test "returns 200 with attachment_id/token/url/expires_at/expires_in_seconds" do
      tenant = provisioned_tenant("req386-issue")
      instance_id = Ecto.UUID.generate()
      attachment = upload!(tenant, instance_id)

      conn = issue_link_conn(tenant, instance_id, attachment.id, ["TENANT_ADMIN"])

      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)

      assert resp["attachment_id"] == attachment.id
      assert is_binary(resp["token"])
      assert is_binary(resp["url"])
      assert resp["url"] =~ "/instances/#{instance_id}/attachments/#{attachment.id}/link-content"
      assert resp["url"] =~ "link_token="
      assert is_binary(resp["expires_at"])
      assert resp["expires_in_seconds"] == 300

      # The stated expiry is genuinely bounded and in the future.
      {:ok, expires_at, _offset} = DateTime.from_iso8601(resp["expires_at"])
      assert DateTime.compare(expires_at, DateTime.utc_now()) == :gt
    end

    test "the issued link is usable to fetch the document's bytes before expiry" do
      tenant = provisioned_tenant("req386-issue-then-use")
      instance_id = Ecto.UUID.generate()

      attachment =
        upload!(tenant, instance_id,
          raw_bytes: "before-expiry bytes",
          file_name: "before-expiry.txt",
          content_type: "text/plain"
        )

      issue_conn = issue_link_conn(tenant, instance_id, attachment.id, ["TENANT_ADMIN"])
      assert issue_conn.status == 200
      token = Jason.decode!(issue_conn.resp_body)["token"]

      content_conn =
        get_link_content_conn(tenant, instance_id, attachment.id, token, ["TENANT_ADMIN"])

      assert content_conn.status == 200
      assert content_conn.resp_body == "before-expiry bytes"
      assert get_resp_header(content_conn, "content-type") == ["text/plain; charset=utf-8"]

      assert get_resp_header(content_conn, "content-disposition") == [
               "attachment; filename=\"before-expiry.txt\""
             ]
    end

    test "404s the same way the existing not-found precedent does for an attachment_id that doesn't exist" do
      tenant = provisioned_tenant("req386-issue-404")
      instance_id = Ecto.UUID.generate()

      conn = issue_link_conn(tenant, instance_id, Ecto.UUID.generate(), ["TENANT_ADMIN"])

      assert conn.status == 404
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 -- an expired link is refused with a plain-language message, no
  # document bytes, no real sleep (see moduledoc)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2: GET /instances/:id/attachments/:attachment_id/link-content -- expired token" do
    test "returns 410 with the fixed plain-language detail and no document bytes" do
      tenant = provisioned_tenant("req386-expired-route")
      instance_id = Ecto.UUID.generate()
      attachment = upload!(tenant, instance_id, raw_bytes: "must never be returned")

      token = expired_token_for(attachment.id, tenant)

      conn = get_link_content_conn(tenant, instance_id, attachment.id, token, ["TENANT_ADMIN"])

      assert conn.status == 410
      assert get_resp_header(conn, "content-type") == ["application/problem+json; charset=utf-8"]

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 410
      assert body["title"] == "Attachment Link Expired"

      assert body["detail"] ==
               "This link has expired or is no longer valid. Request a new link and try again."

      # Absolutely no document bytes anywhere in the body.
      refute conn.resp_body =~ "must never be returned"
      refute Map.has_key?(body, "content")
    end

    test "a syntactically malformed link_token gets the exact same 410, not a 4xx of a different shape" do
      tenant = provisioned_tenant("req386-malformed-route")
      instance_id = Ecto.UUID.generate()
      attachment = upload!(tenant, instance_id)

      conn =
        get_link_content_conn(tenant, instance_id, attachment.id, "not-a-real-token", [
          "TENANT_ADMIN"
        ])

      assert conn.status == 410
    end

    test "a missing link_token query param also gets 410, not a 500 or a different 4xx" do
      tenant = provisioned_tenant("req386-missing-token-route")
      instance_id = Ecto.UUID.generate()
      attachment = upload!(tenant, instance_id)

      conn =
        build_conn(
          :get,
          "/#{instance_id}/attachments/#{attachment.id}/link-content",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert conn.status == 410
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3 -- a fresh link for the same attachment_id after a prior one expired
  # succeeds and serves the document normally
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3: fresh link after a prior one expired" do
    test "expired attempt fails (410), then a newly issued link for the SAME attachment_id succeeds (200)" do
      tenant = provisioned_tenant("req386-fresh-after-expired")
      instance_id = Ecto.UUID.generate()

      attachment =
        upload!(tenant, instance_id,
          raw_bytes: "fresh link content",
          file_name: "fresh.txt",
          content_type: "text/plain"
        )

      # 1. The expired attempt.
      stale_token = expired_token_for(attachment.id, tenant)

      stale_conn =
        get_link_content_conn(tenant, instance_id, attachment.id, stale_token, [
          "TENANT_ADMIN"
        ])

      assert stale_conn.status == 410

      # 2. A fresh link, issued now (real POST route, real time) for the SAME
      # attachment_id.
      fresh_issue_conn = issue_link_conn(tenant, instance_id, attachment.id, ["TENANT_ADMIN"])
      assert fresh_issue_conn.status == 200
      fresh_token = Jason.decode!(fresh_issue_conn.resp_body)["token"]
      assert fresh_token != stale_token

      # 3. The fresh link works and serves the document normally.
      fresh_content_conn =
        get_link_content_conn(tenant, instance_id, attachment.id, fresh_token, [
          "TENANT_ADMIN"
        ])

      assert fresh_content_conn.status == 200
      assert fresh_content_conn.resp_body == "fresh link content"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4 -- expired-or-invalid response for a cross-tenant-presented token is
  # byte-identical (status, headers, body) to the same for a token naming an
  # attachment id that was never issued at all
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: cross-tenant-presented token vs. never-issued attachment id -- byte-identical" do
    test "identical status/headers/body regardless of which attachment_id the (equally invalid) token is presented against" do
      tenant_1 = provisioned_tenant("req386-ac4-tenant1")
      tenant_2 = provisioned_tenant("req386-ac4-tenant2")

      instance_id = Ecto.UUID.generate()

      # tenant 1's real, existing attachment -- the token below is validly
      # issued and unexpired FOR TENANT 1.
      tenant_1_attachment = upload!(tenant_1, instance_id, file_name: "tenant1-doc.txt")

      {:ok, %{token: tenant_1_token}} =
        AttachmentLinks.issue(tenant_1_attachment.id, tenant_1.tenant_id)

      # tenant 2's own real, different attachment -- used only as the URL's
      # :attachment_id segment for the "cross-tenant" framing below. tenant 2
      # never issued a link for tenant_1_token at all.
      tenant_2_attachment = upload!(tenant_2, instance_id, file_name: "tenant2-doc.txt")

      # Response A: tenant 2's caller presents tenant 1's token against
      # tenant 2's OWN real attachment_id in the URL.
      cross_tenant_conn =
        get_link_content_conn(
          tenant_2,
          instance_id,
          tenant_2_attachment.id,
          tenant_1_token,
          ["TENANT_ADMIN"]
        )

      # Response B: the exact same tenant-1-issued token, presented by the
      # same tenant 2 caller, against a fabricated attachment_id that was
      # never issued a link (or uploaded) by anyone at all.
      never_issued_conn =
        get_link_content_conn(
          tenant_2,
          instance_id,
          Ecto.UUID.generate(),
          tenant_1_token,
          ["TENANT_ADMIN"]
        )

      # Both fail verification identically: AttachmentLinks.verify/2 resolves
      # the signing key under the REQUESTER's own tenant (tenant 2), which
      # never matches the key tenant_1_token was signed with -- this failure
      # happens before either request's URL attachment_id is ever inspected
      # (check_attachment_id_matches/2 and fetch_scoped_attachment_content/3
      # are both unreached), so the URL's attachment_id cannot influence the
      # response either way.
      assert cross_tenant_conn.status == 410
      assert never_issued_conn.status == 410

      assert get_resp_header(cross_tenant_conn, "content-type") ==
               get_resp_header(never_issued_conn, "content-type")

      # Same fixed trace_id on both conns (both built via build_conn/4's
      # constant "fixed-test-trace-id"), so no normalization is needed before
      # comparing bodies byte-for-byte -- matches
      # req212_attachments_routes_test.exs's own established technique for
      # this exact kind of "prove indistinguishability" assertion.
      assert cross_tenant_conn.resp_body == never_issued_conn.resp_body

      # Sanity: neither tenant's real attachment content ever leaked.
      refute cross_tenant_conn.resp_body =~ "tenant1-doc"
      refute cross_tenant_conn.resp_body =~ "tenant2-doc"
    end

    test "also byte-identical to the response for a garbage token that was never issued at all" do
      tenant = provisioned_tenant("req386-ac4-garbage")
      instance_id = Ecto.UUID.generate()
      attachment = upload!(tenant, instance_id)

      expired_token = expired_token_for(attachment.id, tenant)

      expired_conn =
        get_link_content_conn(tenant, instance_id, attachment.id, expired_token, [
          "TENANT_ADMIN"
        ])

      garbage_conn =
        get_link_content_conn(tenant, instance_id, Ecto.UUID.generate(), "totally-fabricated", [
          "TENANT_ADMIN"
        ])

      assert expired_conn.status == 410
      assert garbage_conn.status == 410
      assert expired_conn.resp_body == garbage_conn.resp_body
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Permission enforcement -- a caller without :AttachmentLinksIssue (REQ-448,
  # was :AttachmentsRead) is denied on POST .../link, and one without
  # :AttachmentsRead on GET .../link-content, matching req212's own
  # enforcement test pattern
  # ══════════════════════════════════════════════════════════════════════

  describe "permission enforcement: 403 for a caller with no AttachmentLinksIssue / AttachmentsRead" do
    test "POST .../link -- AGENT_RUNNER (holds neither AttachmentLinksIssue nor AttachmentsRead) gets 403" do
      tenant = provisioned_tenant("req386-403-post")
      instance_id = Ecto.UUID.generate()
      attachment = upload!(tenant, instance_id)

      conn = issue_link_conn(tenant, instance_id, attachment.id, ["AGENT_RUNNER"])

      assert conn.status == 403
    end

    test "GET .../link-content -- AGENT_RUNNER gets 403" do
      tenant = provisioned_tenant("req386-403-get")
      instance_id = Ecto.UUID.generate()
      attachment = upload!(tenant, instance_id)

      {:ok, %{token: token}} = AttachmentLinks.issue(attachment.id, tenant.tenant_id)

      conn =
        get_link_content_conn(tenant, instance_id, attachment.id, token, ["AGENT_RUNNER"])

      assert conn.status == 403
    end
  end
end
