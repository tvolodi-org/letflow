defmodule Letflow.Routers.TenantLogoTest do
  @moduledoc """
  REQ-590 / GH #3338 part 1 -- `PUT` / `DELETE /api/v1/tenant/logo`, the `tenant_logos` table,
  the feature flag and the body parser. Test IDs L1..L11 and P1 follow the task design.

  Requests go through the real `Letflow.Router` with a real API token. `async: false`: the flag
  and the scanner are application env, and `TenantFixture` flips the SQL sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Identity.TenantLogo
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR", 1, 2, 3, 4>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 2, 3>>
  @webp <<"RIFF", 12, 0, 0, 0, "WEBP", "VP8 ", 1, 2, 3, 4>>
  @eicar "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

  defmodule RaisingScanner do
    def scan(_bytes, _type), do: raise("scanner down")
  end

  defmodule ErrorScanner do
    def scan(bytes, type) do
      send(Application.fetch_env!(:letflow, :logo_test_pid), {:scanned, byte_size(bytes), type})
      {:error, :unreachable}
    end
  end

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t0723-logo")
    old = Application.get_env(:letflow, :tenant_logo_upload_enabled)
    Application.put_env(:letflow, :tenant_logo_upload_enabled, true)

    on_exit(fn ->
      if is_nil(old),
        do: Application.delete_env(:letflow, :tenant_logo_upload_enabled),
        else: Application.put_env(:letflow, :tenant_logo_upload_enabled, old)
    end)

    %{tenant: tenant, token: Fixture.mint_token!(tenant, ["TENANT_ADMIN"])}
  end

  defp request(method, tenant, token, content_type, body) do
    conn = conn(method, "/api/v1/tenant/logo", body)
    conn = if content_type, do: put_req_header(conn, "content-type", content_type), else: conn
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn
    |> put_req_header("x-tenant-slug", tenant.tenant.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp put_logo(ctx, type, body), do: request(:put, ctx.tenant, ctx.token, type, body)
  defp delete_logo(ctx), do: request(:delete, ctx.tenant, ctx.token, nil, nil)

  defp rows(tenant) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT content_type, byte_size, content_hash, data, updated_by FROM "#{tenant.schema_name}".tenant_logos|
      )

    rows
  end

  defp audit_actions(tenant) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT action, before_state, after_state FROM "#{tenant.schema_name}".audit_entries WHERE action LIKE 'tenant_logo.%' ORDER BY action DESC|
      )

    rows
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  describe "L1 flag" do
    test "off: PUT and DELETE answer the ordinary 404 and write nothing", ctx do
      assert {:ok, _} =
               TenantLogo.put(
                 ctx.tenant.schema_name,
                 ctx.tenant.tenant_id,
                 nil,
                 "image/png",
                 @png,
                 nil
               )

      Application.put_env(:letflow, :tenant_logo_upload_enabled, false)

      put = put_logo(ctx, "image/jpeg", @jpeg)
      assert put.status == 404
      delete = delete_logo(ctx)
      assert delete.status == 404
      assert Jason.decode!(put.resp_body)["detail"] == Jason.decode!(delete.resp_body)["detail"]

      assert [["image/png", _, _, _, _]] = rows(ctx.tenant)
    end

    test "default is off and config.exs says false" do
      Application.delete_env(:letflow, :tenant_logo_upload_enabled)
      refute TenantLogo.enabled?()
      assert File.read!("config/config.exs") =~ ~r/:tenant_logo_upload_enabled,\s*false/
    end
  end

  describe "L2 storage" do
    test "singleton table without tenant_id; manifest lists the migration", ctx do
      %{rows: cols} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'tenant_logos'",
          [ctx.tenant.schema_name]
        )

      names = Enum.map(cols, &hd/1)
      refute "tenant_id" in names
      assert "data" in names

      assert {:error, %Postgrex.Error{postgres: %{constraint: "tenant_logos_singleton"}}} =
               Repo.query(
                 ~s|INSERT INTO "#{ctx.tenant.schema_name}".tenant_logos (id, content_type, byte_size, content_hash, data, updated_at) VALUES (2, 'image/png', 1, 'h', 'x', now())|
               )

      assert {20_261_027_500_001, Letflow.Repo.Migrations.CreateTenantLogos} in Letflow.TenantProvisioning.tenant_scoped_migrations()
    end
  end

  describe "L3 valid upload" do
    test "stores type, measured size, sha256 and the actor; a second PUT replaces", ctx do
      conn = put_logo(ctx, "image/png", @png)
      assert conn.status == 200, conn.resp_body
      body = Jason.decode!(conn.resp_body)
      assert body["byte_size"] == byte_size(@png)
      assert body["content_hash"] == sha(@png)
      refute conn.resp_body =~ "IHDR"

      assert [["image/png", size, hash, data, updated_by]] = rows(ctx.tenant)
      assert size == byte_size(@png)
      assert hash == sha(@png)
      assert data == @png
      assert is_binary(updated_by)

      assert put_logo(ctx, "image/jpeg; charset=binary", @jpeg).status == 200
      assert [["image/jpeg", _, _, _, _]] = rows(ctx.tenant)
    end
  end

  describe "L4 type and signature" do
    for {name, type, body} <- [
          {"svg", "image/svg+xml", "<svg xmlns='x'/>"},
          {"gif", "image/gif", "GIF89a1234"},
          {"pdf", "application/pdf", "%PDF-1.4"},
          {"html", "text/html", "<html></html>"},
          {"json", "application/json", "{}"},
          {"none", nil, "abc"}
        ] do
      test "L4a #{name} is refused with the allowed types", ctx do
        conn = put_logo(ctx, unquote(type), unquote(body))
        assert conn.status == 415, conn.resp_body
        assert conn.resp_body =~ "image/png, image/jpeg, image/webp"
        assert rows(ctx.tenant) == []
      end
    end

    test "L4e declared type must match the bytes", ctx do
      for {type, bytes} <- [
            {"image/png", @jpeg},
            {"image/png", "<svg xmlns='x'/>"},
            {"image/jpeg", @png},
            {"image/webp", @png},
            {"image/png", ""}
          ] do
        conn = put_logo(ctx, type, bytes)
        assert conn.status == 422, conn.resp_body
        assert conn.resp_body =~ "do not match"
      end

      assert rows(ctx.tenant) == []
    end

    test "L4f each type passes with its own signature", ctx do
      for {type, bytes} <- [{"image/png", @png}, {"image/jpeg", @jpeg}, {"image/webp", @webp}] do
        assert put_logo(ctx, type, bytes).status == 200, type
      end
    end
  end

  describe "L5 size" do
    test "524289 bytes refused, 524288 accepted", ctx do
      pad = fn n -> @png <> :binary.copy(<<0>>, n - byte_size(@png)) end

      over = put_logo(ctx, "image/png", pad.(524_289))
      assert over.status == 413
      assert over.resp_body =~ "524288"
      assert rows(ctx.tenant) == []

      ok = put_logo(ctx, "image/png", pad.(524_288))
      assert ok.status == 200, ok.resp_body
      assert [[_, 524_288, _, _, _]] = rows(ctx.tenant)
    end

    test "a far larger body is cut off by the parser (413 error)", ctx do
      error =
        assert_raise Plug.Conn.WrapperError, fn ->
          put_logo(ctx, "image/png", @png <> :binary.copy(<<0>>, 1_000_000))
        end

      assert %Plug.Parsers.RequestTooLargeError{} = error.reason
      assert Plug.Exception.status(error.reason) == 413
      assert rows(ctx.tenant) == []
    end
  end

  describe "L6 scanner" do
    test "EICAR behind a valid PNG signature is refused with the scanner reason", ctx do
      conn = put_logo(ctx, "image/png", @png <> @eicar)
      assert conn.status == 422
      assert conn.resp_body =~ "content scanner"
      refute conn.resp_body =~ "do not match"
      assert rows(ctx.tenant) == []
    end

    test "a scanner that raises or errors gives a 4xx, not a 500, and stores nothing", ctx do
      old = Application.get_env(:letflow, :attachment_scanner)
      Application.put_env(:letflow, :logo_test_pid, self())

      on_exit(fn ->
        if is_nil(old),
          do: Application.delete_env(:letflow, :attachment_scanner),
          else: Application.put_env(:letflow, :attachment_scanner, old)

        Application.delete_env(:letflow, :logo_test_pid)
      end)

      Application.put_env(:letflow, :attachment_scanner, RaisingScanner)
      raised = put_logo(ctx, "image/png", @png)
      assert raised.status == 422
      assert raised.resp_body =~ "could not be scanned"

      Application.put_env(:letflow, :attachment_scanner, ErrorScanner)
      errored = put_logo(ctx, "image/png", @png)
      assert errored.status == 422
      assert_received {:scanned, size, "image/png"}
      assert size == byte_size(@png)
      assert rows(ctx.tenant) == []
    end
  end

  describe "L7 authorisation" do
    test "no token is 401, a role without the permission is 403", ctx do
      assert request(:put, ctx.tenant, nil, "image/png", @png).status == 401
      assert request(:delete, ctx.tenant, nil, nil, nil).status == 401

      weak = Fixture.mint_token!(ctx.tenant, ["TENANT_AUDITOR"])
      assert request(:put, ctx.tenant, weak, "image/png", @png).status == 403
      assert request(:delete, ctx.tenant, weak, nil, nil).status == 403
      assert rows(ctx.tenant) == []
    end
  end

  describe "L8 isolation" do
    test "one tenant's PUT and DELETE never touch another tenant's logo", ctx do
      other = TenantFixture.provisioned_tenant!(slug_prefix: "t0723-other")
      other_ctx = %{tenant: other, token: Fixture.mint_token!(other, ["TENANT_ADMIN"])}

      assert put_logo(other_ctx, "image/jpeg", @jpeg).status == 200
      assert put_logo(ctx, "image/png", @png).status == 200
      assert [["image/jpeg", _, hash, _, _]] = rows(other)
      assert hash == sha(@jpeg)

      assert delete_logo(ctx).status == 200
      assert rows(ctx.tenant) == []
      assert [["image/jpeg", _, ^hash, _, _]] = rows(other)
    end

    test "every Repo call in the module carries the prefix" do
      source = File.read!("lib/letflow/identity/tenant_logo.ex")

      lines =
        source
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/Repo\.(one|all|get|insert|update|delete)/))

      assert lines != []
      assert Enum.all?(lines, &(&1 =~ "prefix")), inspect(lines)
    end
  end

  describe "L9 delete" do
    test "removes the logo, then 404, and PUT works again", ctx do
      assert put_logo(ctx, "image/png", @png).status == 200
      assert delete_logo(ctx).status == 200
      assert delete_logo(ctx).status == 404
      assert put_logo(ctx, "image/png", @png).status == 200
    end
  end

  describe "L10 audit and logo_url" do
    test "upload and delete are audited with type, size and hash, never the bytes", ctx do
      assert put_logo(ctx, "image/png", @png).status == 200
      assert delete_logo(ctx).status == 200

      assert [["tenant_logo.upload", _, after_state], ["tenant_logo.delete", before_state, _]] =
               audit_actions(ctx.tenant)

      assert after_state["content_hash"] == sha(@png)
      assert after_state["byte_size"] == byte_size(@png)
      assert before_state["content_type"] == "image/png"
      refute Jason.encode!(after_state) =~ Base.encode64(@png)
      refute Jason.encode!(after_state) =~ "IHDR"
    end

    test "a failing audit write is a 500, the row is unchanged", ctx do
      assert put_logo(ctx, "image/png", @png).status == 200
      Repo.query!(~s|DROP TABLE "#{ctx.tenant.schema_name}".audit_entries|)

      assert put_logo(ctx, "image/jpeg", @jpeg).status == 500
      assert delete_logo(ctx).status == 500
      assert [["image/png", _, _, _, _]] = rows(ctx.tenant)
    end

    test "PATCH /tenant/settings still validates logo_url", ctx do
      conn =
        conn(:patch, "/api/v1/tenant/settings", Jason.encode!(%{"logo_url" => "javascript:x"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> ctx.token)
        |> put_req_header("x-tenant-slug", ctx.tenant.tenant.slug)
        |> Letflow.Router.call(Letflow.Router.init([]))

      assert conn.status == 422
    end
  end

  describe "P1 parser" do
    alias Letflow.Plugs.LogoBodyParser

    test "claims only PUT /tenant/logo" do
      for {method, path} <- [
            {:put, ["tenant", "settings"]},
            {:post, ["tenant", "logo"]},
            {:delete, ["tenant", "logo"]}
          ] do
        c = %{conn(method, "/") | path_info: path}
        assert {:next, _} = LogoBodyParser.parse(c, "image", "png", %{}, [])
      end
    end

    test "flag off does not read the body", _ctx do
      Application.put_env(:letflow, :tenant_logo_upload_enabled, false)
      c = %{conn(:put, "/", @png) | path_info: ["tenant", "logo"]}
      assert {:ok, %{}, c2} = LogoBodyParser.parse(c, "image", "png", %{}, length: 524_289)
      assert c2.adapter == c.adapter
    end

    test "over the limit is too_large; within it the bytes are kept" do
      c = %{conn(:put, "/", @png) | path_info: ["tenant", "logo"]}

      assert {:ok, %{"_logo" => @png}, _} =
               LogoBodyParser.parse(c, "image", "png", %{}, length: 100)

      assert {:error, :too_large, _} = LogoBodyParser.parse(c, "image", "png", %{}, length: 5)
    end
  end
end
