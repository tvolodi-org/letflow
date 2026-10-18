defmodule Letflow.Routers.AttachmentLinkScopeTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2b, AC 21, T15 (design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.6; spec
  `test/specs/REQ-517-2b.md`, T-K3..T-K6 and the SEC advisories T-4 and T-6): attachment links in a
  tenant stored `on`.

    * T-K3 `POST /instances/:id/attachments/:attachment_id/link`: a scoped-only holder of a role
      with `AttachmentLinksIssue` is refused 403 under `on` (no token in the body, no audit row), a
      tenant-wide holder issues (TTL 300 s, ONE attachment);
    * T-K4 revoke-then-serve: a link issued by a tenant-wide user is presented by a principal that
      has since become scoped-only (or lost the role): `GET .../link-content` is refused 403
      IMMEDIATELY under `on` (the route re-runs the whole pipeline before it verifies the token),
      while under `off` the very same link is still served (control), and a tenant-wide presenter
      is served under `on`; the same revoke-then-serve through the FULL router, the tenant column
      flipped with the test helper;
    * T-K5 / T-4 the audit entry `attachment_link.issued`: written in the issue request with exactly
      `issuer`, `instance_id`, `attachment_id`, `scope_node` (null), `trace_id`; never the token,
      the url or the expiry; a forced audit failure answers a detail-free 500 with NO token in the
      body and leaves no row;
    * T-K6 the audit is written in `off`, `shadow` and `on`;
    * T-6 INV-5 under `on`: a scoped-only caller gets the SAME 403 bytes for an existing and a
      nonexistent instance/attachment pair (the deny is route-level, no existence oracle), while
      the tenant-wide control sees the 200 versus 404 difference.

  `async: false`: committed writes, DDL (the audit fault trigger) and the VM-global `:oidc` config
  swap for the full-router case.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Letflow.TestSupport.InstanceFixture, only: [real_instance!: 1]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Repository.Attachments
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @router Letflow.Routers.Instances
  @role "TENANT_ADMIN"
  @issued_keys ~w(attachment_id instance_id issuer scope_node trace_id)

  # --- helpers ---------------------------------------------------------------------------------

  defp upload!(fx, instance_id, bytes) do
    {:ok, attachment} =
      Attachments.upload(
        %{
          instance_id: instance_id,
          raw_bytes: bytes,
          file_name: "linked-doc.txt",
          content_type: "text/plain",
          uploaded_by: Ecto.UUID.generate(),
          description: nil
        },
        prefix: fx.schema_name
      )

    attachment
  end

  defp issue(fx, instance_id, attachment_id, user_id, mode) do
    On.call(
      @router,
      :post,
      "/#{instance_id}/attachments/#{attachment_id}/link",
      fx,
      user_id,
      [@role],
      mode,
      nil
    )
  end

  defp serve(fx, instance_id, attachment_id, token, user_id, roles, mode) do
    path =
      "/#{instance_id}/attachments/#{attachment_id}/link-content?link_token=" <>
        URI.encode_www_form(token)

    On.call(@router, :get, path, fx, user_id, roles, mode, nil)
  end

  defp token_of(conn), do: Jason.decode!(conn.resp_body)["token"]

  defp issued_entries(fx), do: S.entries(fx, "attachment_link.issued")

  defp oidc_request(fx, method, path) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer realm-token:" <> fx.realm)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  # A tenant with a tenant-wide TENANT_ADMIN, a scoped-only one, and one attachment.
  defp world!(slug_prefix) do
    fx = S.tenant!(slug_prefix)
    instance_id = real_instance!(fx)

    %{
      fx: fx,
      instance_id: instance_id,
      attachment: upload!(fx, instance_id, "linked bytes"),
      wide: TokenMintFixture.role_holder!(fx.schema_name, [@role]),
      scoped: On.scoped_holder!(fx, @role)
    }
  end

  # ===========================================================================================
  describe "T-K3 issuing under on" do
    test "a scoped-only holder is refused 403 (no token, no audit row); a tenant-wide holder issues for ONE attachment with a 300 s TTL" do
      %{fx: fx, instance_id: iid, attachment: attachment, wide: wide, scoped: scoped} =
        world!("r517-k3")

      refused = issue(fx, iid, attachment.id, scoped.id, :on)

      assert refused.status == 403
      assert refused.halted
      assert Jason.decode!(refused.resp_body)["detail"] == "insufficient permissions"
      refute refused.resp_body =~ "token"
      assert issued_entries(fx) == []

      issued = issue(fx, iid, attachment.id, wide.id, :on)

      assert issued.status == 200
      body = Jason.decode!(issued.resp_body)
      assert body["attachment_id"] == attachment.id
      assert body["expires_in_seconds"] == 300
      assert is_binary(body["token"])
      assert [_one] = issued_entries(fx)
    end

    test "under off the same scoped-only holder still issues (the scope rule is not applied)" do
      %{fx: fx, instance_id: iid, attachment: attachment, scoped: scoped} = world!("r517-k3off")

      assert issue(fx, iid, attachment.id, scoped.id, :off).status == 200
      assert issue(fx, iid, attachment.id, scoped.id, :shadow).status == 200
    end

    test "a caller with no AttachmentLinksIssue role at all keeps the unchanged coarse 403" do
      %{fx: fx, instance_id: iid, attachment: attachment} = world!("r517-k3coarse")

      conn =
        On.call(
          @router,
          :post,
          "/#{iid}/attachments/#{attachment.id}/link",
          fx,
          Ecto.UUID.generate(),
          [],
          :on,
          nil
        )

      assert conn.status == 403
      assert issued_entries(fx) == []
    end
  end

  # ===========================================================================================
  describe "T-K4 revoke-then-serve" do
    test "a link issued by a tenant-wide user is refused 403 at once for a presenter who is scoped-only under on, and still served under off (control)" do
      %{fx: fx, instance_id: iid, attachment: attachment, wide: wide, scoped: scoped} =
        world!("r517-k4")

      issued = issue(fx, iid, attachment.id, wide.id, :on)
      assert issued.status == 200
      token = token_of(issued)

      # the tenant-wide presenter is served under on (the link itself is valid)
      ok = serve(fx, iid, attachment.id, token, wide.id, [@role], :on)
      assert ok.status == 200
      assert ok.resp_body == "linked bytes"

      # the presenter is scoped-only: refused immediately under on, with the VALID token
      refused = serve(fx, iid, attachment.id, token, scoped.id, [@role], :on)
      assert refused.status == 403
      assert Jason.decode!(refused.resp_body)["detail"] == "insufficient permissions"
      refute refused.resp_body =~ "linked bytes"

      # control: under off and shadow the same link is still served until it expires
      for mode <- [:off, :shadow] do
        served = serve(fx, iid, attachment.id, token, scoped.id, [@role], mode)
        assert served.status == 200, "under #{mode}"
        assert served.resp_body == "linked bytes"
      end
    end

    test "a presenter who lost the role is refused 403 by the unchanged coarse deny, in every mode" do
      %{fx: fx, instance_id: iid, attachment: attachment, wide: wide} = world!("r517-k4role")
      token = fx |> issue(iid, attachment.id, wide.id, :on) |> token_of()

      for mode <- [:off, :shadow, :on] do
        conn = serve(fx, iid, attachment.id, token, wide.id, [], mode)
        assert conn.status == 403, "under #{mode}"
      end
    end

    test "a presenter with no principal at all is refused under on" do
      %{fx: fx, instance_id: iid, attachment: attachment, wide: wide} = world!("r517-k4nopr")
      token = fx |> issue(iid, attachment.id, wide.id, :on) |> token_of()

      path =
        "/#{iid}/attachments/#{attachment.id}/link-content?link_token=" <>
          URI.encode_www_form(token)

      auth_context = fx |> On.ctx(wide.id, [@role], :on) |> Map.delete(:credential)
      conn = S.call(@router, :get, path, fx, auth_context, nil)

      assert conn.status == 403
      refute conn.resp_body =~ "linked bytes"
    end
  end

  # ===========================================================================================
  describe "T-K5 / T-4 the attachment_link.issued audit entry" do
    test "one entry per issue with exactly the five keys, never the token, the url or the expiry" do
      %{fx: fx, instance_id: iid, attachment: attachment, wide: wide} = world!("r517-k5")

      conn = issue(fx, iid, attachment.id, wide.id, :off)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert [entry] = issued_entries(fx)
      assert entry.action == "attachment_link.issued"
      assert entry.resource_type == "attachment"
      assert entry.resource_id == attachment.id
      assert entry.actor_id == wide.id
      assert entry.before_state == nil

      assert entry.after_state |> Map.keys() |> Enum.sort() == @issued_keys

      assert entry.after_state == %{
               "issuer" => wide.id,
               "instance_id" => iid,
               "attachment_id" => attachment.id,
               "scope_node" => nil,
               "trace_id" => S.trace()
             }

      stored = Jason.encode!(entry.after_state) <> inspect(entry)

      for secret <- [body["token"], body["url"], body["expires_at"]] do
        refute String.contains?(stored, secret), "the audit entry leaks #{inspect(secret)}"
      end

      refute stored =~ "expires"
    end

    test "a failing audit write answers a detail-free 500 with NO token in the body and leaves no entry (N8)" do
      %{fx: fx, instance_id: iid, attachment: attachment, wide: wide} = world!("r517-k5fail")

      {conn, log} =
        with_log(fn ->
          S.with_audit_fault(fx, "attachment_link.issued", fn ->
            issue(fx, iid, attachment.id, wide.id, :on)
          end)
        end)

      assert conn.status == 500
      assert Jason.decode!(conn.resp_body)["detail"] == "an unexpected error occurred"
      refute conn.resp_body =~ "token"
      refute conn.resp_body =~ "link_token"
      refute conn.resp_body =~ "url"
      assert issued_entries(fx) == []

      # the constant line only: the fault trigger's DDL and the failed INSERT are also logged by
      # Ecto and carry the action text and the actor id
      lines =
        log
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "attachment_link.issued audit write failed"))

      assert [line] = lines
      refute String.contains?(line, wide.id)
      refute String.contains?(line, attachment.id)
      refute String.contains?(line, fx.schema_name)
    end
  end

  # ===========================================================================================
  describe "T-K6 the audit is written in every mode" do
    test "off, shadow and on each leave one entry for a tenant-wide issuer" do
      %{fx: fx, instance_id: iid, attachment: attachment, wide: wide} = world!("r517-k6")

      for {mode, expected} <- [off: 1, shadow: 2, on: 3] do
        assert issue(fx, iid, attachment.id, wide.id, mode).status == 200, "#{mode}"
        assert length(issued_entries(fx)) == expected, "after #{mode}"
      end

      assert fx |> issued_entries() |> Enum.map(& &1.resource_id) |> Enum.uniq() == [
               attachment.id
             ]
    end

    test "a refused or failed issue (unknown attachment, scoped-only under on) writes nothing" do
      %{fx: fx, instance_id: iid, attachment: attachment, wide: wide, scoped: scoped} =
        world!("r517-k6none")

      assert issue(fx, iid, Ecto.UUID.generate(), wide.id, :on).status == 404
      assert issue(fx, Ecto.UUID.generate(), attachment.id, wide.id, :on).status == 404
      assert issue(fx, iid, attachment.id, scoped.id, :on).status == 403
      assert issued_entries(fx) == []
    end
  end

  # ===========================================================================================
  describe "T-6 INV-5 under on: the deny is route-level, no existence oracle" do
    test "a scoped-only caller gets identical 403 bytes for an existing and a nonexistent instance/attachment pair on issue and link-content; the tenant-wide control sees 200 versus 404" do
      %{fx: fx, instance_id: iid, attachment: attachment, wide: wide, scoped: scoped} =
        world!("r517-t6")

      ghost_instance = Ecto.UUID.generate()
      ghost_attachment = Ecto.UUID.generate()

      existing = issue(fx, iid, attachment.id, scoped.id, :on)
      nonexistent = issue(fx, ghost_instance, ghost_attachment, scoped.id, :on)
      wrong_pair = issue(fx, ghost_instance, attachment.id, scoped.id, :on)

      assert existing.status == 403
      assert nonexistent.resp_body == existing.resp_body
      assert wrong_pair.resp_body == existing.resp_body

      # control: the guard is what hides the difference
      assert issue(fx, iid, attachment.id, wide.id, :on).status == 200
      assert issue(fx, ghost_instance, ghost_attachment, wide.id, :on).status == 404

      token = fx |> issue(iid, attachment.id, wide.id, :on) |> token_of()

      served_existing = serve(fx, iid, attachment.id, token, scoped.id, [@role], :on)

      served_ghost =
        serve(fx, ghost_instance, ghost_attachment, "not-a-token", scoped.id, [@role], :on)

      assert served_existing.status == 403
      assert served_ghost.resp_body == served_existing.resp_body
    end

    test "GET /instances/:id: a scoped-only caller gets the same 403 for any id, a malformed id included" do
      %{fx: fx, scoped: scoped} = world!("r517-t6i")

      bodies =
        for id <- [Ecto.UUID.generate(), Ecto.UUID.generate(), "not-a-uuid"] do
          conn = On.call(@router, :get, "/#{id}", fx, scoped.id, [@role], :on, nil)
          assert conn.status == 403
          conn.resp_body
        end

      assert bodies |> Enum.uniq() |> length() == 1
    end
  end

  # ===========================================================================================
  describe "T-K4 end to end through the full Letflow.Router (the stored column, a real pipeline)" do
    setup do
      original_oidc_config = Application.fetch_env!(:letflow, :oidc)

      Application.put_env(
        :letflow,
        :oidc,
        Keyword.put(original_oidc_config, :token_verifier, ConfigurableTokenVerifierDouble)
      )

      on_exit(fn -> Application.put_env(:letflow, :oidc, original_oidc_config) end)
      Fixture.unpin!()
      :ok
    end

    test "issue as a tenant-wide OIDC user; make the user scoped-only; the next link-content is 403 under on, served under off" do
      realm = Letflow.TenantSlugFixture.unique_realm("r517-k4e2e")

      fx =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "r517-k4e2e",
          oidc_mode: :enabled,
          idp_realm_id: realm
        )

      fx = Map.put(fx, :realm, realm)
      s = fx.schema_name

      # the first request JIT-provisions the user; then it holds the role by group membership
      first = oidc_request(fx, :get, "/api/v1/instances")
      assert first.status in [200, 403]
      user_id = first.assigns.auth_context.user_id
      TokenMintFixture.grant_roles!(s, user_id, [@role])

      iid = real_instance!(fx)
      attachment = upload!(fx, iid, "end to end bytes")
      base = "/api/v1/instances/#{iid}/attachments/#{attachment.id}"

      ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)

      issued = oidc_request(fx, :post, base <> "/link")
      assert issued.status == 200, issued.resp_body
      token = token_of(issued)
      link = base <> "/link-content?link_token=" <> URI.encode_www_form(token)

      # tenant-wide + on: served
      assert (served = oidc_request(fx, :get, link)).status == 200
      assert served.resp_body == "end to end bytes"
      assert [_one] = issued_entries(fx)

      # revoke: the user's role group now holds the role only at one node
      _node = RSG.make_group_scoped_only!(s, RSG.group_of!(s, @role), @role)

      refused = oidc_request(fx, :get, link)
      assert refused.status == 403
      refute refused.resp_body =~ "end to end bytes"

      # control: the very same link under off is still served (no restart, the column is read per request)
      ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :off)
      assert oidc_request(fx, :get, link).status == 200

      # and back to on: refused again immediately
      ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)
      assert oidc_request(fx, :get, link).status == 403
    end
  end
end
