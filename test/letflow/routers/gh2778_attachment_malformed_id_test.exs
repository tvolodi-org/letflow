defmodule Letflow.Routers.GH2778AttachmentMalformedIdTest do
  @moduledoc """
  GH #2778: every `/instances/:id/attachments...` handler answers a malformed instance id with
  the 422 `instance_id is not a valid UUID` response. Spec: `test/specs/GH-2778.md`.

  Real HTTP through `Letflow.Router` (bearer token + `x-tenant-slug`). Each test is labelled:
  [RED] fails on main (DELETE has no `:invalid_instance_id` clause), [GUARD] already passes on
  main and must keep passing. The trace id is pinned so bodies compare byte for byte. Failure messages never print a response body.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @boundary "gh2778b"
  @malformed "not-a-uuid"
  @fixed_trace "00000000-0000-4000-8000-0000000000cc"

  defp ctx! do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2778-att",
        display_name: "GH2778 Attachment Malformed Id Tenant"
      )

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2778-#{Ecto.UUID.generate()}",
        display_name: "GH2778 Test User",
        email: "gh2778-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    tokens =
      for role <- ["TENANT_ADMIN", "AGENT_RUNNER"], into: %{} do
        {:ok, %{plaintext: plaintext}} =
          Identity.create_token(user.id, %{roles: [role], expires_at: nil},
            prefix: tenant.schema_name
          )

        {role, plaintext}
      end

    %{slug: tenant.tenant.slug, tokens: tokens}
  end

  defp multipart_body do
    "--#{@boundary}\r\n" <>
      "Content-Disposition: form-data; name=\"file\"; filename=\"doc.txt\"\r\n" <>
      "Content-Type: text/plain\r\n\r\nhello\r\n--#{@boundary}--\r\n"
  end

  defp request(ctx, role, method, path, opts \\ []) do
    payload = Keyword.get(opts, :body)
    content_type = Keyword.get(opts, :content_type, "application/json")
    base = if payload, do: conn(method, path, payload), else: conn(method, path)

    base
    |> then(fn c -> if payload, do: put_req_header(c, "content-type", content_type), else: c end)
    |> put_req_header("authorization", "Bearer " <> Map.fetch!(ctx.tokens, role))
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", @fixed_trace)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp base(id), do: "/api/v1/instances/" <> id

  defp upload_req(ctx, role, id),
    do:
      request(ctx, role, "POST", base(id) <> "/attachments",
        body: multipart_body(),
        content_type: "multipart/form-data; boundary=#{@boundary}"
      )

  defp list_req(ctx, role, id), do: request(ctx, role, "GET", base(id) <> "/attachments")

  defp download_req(ctx, role, id, att),
    do: request(ctx, role, "GET", base(id) <> "/attachments/" <> att)

  defp delete_req(ctx, role, id, att),
    do: request(ctx, role, "DELETE", base(id) <> "/attachments/" <> att)

  defp link_req(ctx, role, id, att),
    do: request(ctx, role, "POST", base(id) <> "/attachments/#{att}/link", body: "{}")

  defp link_content_req(ctx, role, id, att),
    do: request(ctx, role, "GET", base(id) <> "/attachments/#{att}/link-content?link_token=t")

  defp assert_status!(label, conn, status), do: assert({label, conn.status} == {label, status})

  defp assert_same_body!(label, a, b),
    do: assert({label, a.resp_body == b.resp_body} == {label, true})

  defp message(conn), do: conn.resp_body |> Jason.decode!() |> inspect()

  defp assert_constant!(conn, label) do
    assert_status!(label, conn, 422)
    assert message(conn) =~ "instance_id is not a valid UUID"
  end

  describe "GH #2778 malformed instance id" do
    test "[RED] DELETE answers 422 with the byte-identical body of the sibling routes" do
      ctx = ctx!()
      att = Ecto.UUID.generate()

      delete = delete_req(ctx, "TENANT_ADMIN", @malformed, att)
      sibling = download_req(ctx, "TENANT_ADMIN", @malformed, att)

      assert_status!("delete", delete, 422)
      assert_status!("sibling", sibling, 422)
      assert_same_body!("delete vs sibling body", delete, sibling)
      assert message(delete) =~ "instance_id is not a valid UUID"
    end

    test "[RED] DELETE: the 422 is independent of the attachment id" do
      ctx = ctx!()

      a = delete_req(ctx, "TENANT_ADMIN", @malformed, Ecto.UUID.generate())
      b = delete_req(ctx, "TENANT_ADMIN", @malformed, Ecto.UUID.generate())

      assert_status!("delete a", a, 422)
      assert_same_body!("delete a vs b", a, b)
    end

    test "[GUARD] upload POST answers 422 with the constant body" do
      ctx = ctx!()
      assert_constant!(upload_req(ctx, "TENANT_ADMIN", @malformed), "upload")
    end

    test "[GUARD] list GET answers 422 with the constant body" do
      ctx = ctx!()
      assert_constant!(list_req(ctx, "TENANT_ADMIN", @malformed), "list")
    end

    test "[GUARD] content download GET answers 422 with the constant body" do
      ctx = ctx!()
      conn = download_req(ctx, "TENANT_ADMIN", @malformed, Ecto.UUID.generate())
      assert_constant!(conn, "download")
    end

    test "[GUARD] issue link POST answers 422 with the constant body" do
      ctx = ctx!()
      conn = link_req(ctx, "TENANT_ADMIN", @malformed, Ecto.UUID.generate())
      assert_constant!(conn, "link")
    end

    test "[GUARD] link-content GET answers 422 with the constant body" do
      ctx = ctx!()
      conn = link_content_req(ctx, "TENANT_ADMIN", @malformed, Ecto.UUID.generate())
      assert_constant!(conn, "link-content")
    end

    test "[RED] all six handlers return the identical 422 body" do
      ctx = ctx!()
      att = Ecto.UUID.generate()

      answers =
        for conn <- [
              upload_req(ctx, "TENANT_ADMIN", @malformed),
              list_req(ctx, "TENANT_ADMIN", @malformed),
              download_req(ctx, "TENANT_ADMIN", @malformed, att),
              link_req(ctx, "TENANT_ADMIN", @malformed, att),
              link_content_req(ctx, "TENANT_ADMIN", @malformed, att),
              delete_req(ctx, "TENANT_ADMIN", @malformed, att)
            ] do
          {conn.status, conn.resp_body}
        end

      assert [{422, _}] = Enum.uniq(answers)
    end

    test "[GUARD] a caller without the permission gets the plug 403 for a malformed id, same as for a valid-shaped id (no oracle)" do
      ctx = ctx!()
      att = Ecto.UUID.generate()
      valid = Ecto.UUID.generate()

      routes = [
        {"upload", fn id -> upload_req(ctx, "AGENT_RUNNER", id) end},
        {"list", fn id -> list_req(ctx, "AGENT_RUNNER", id) end},
        {"download", fn id -> download_req(ctx, "AGENT_RUNNER", id, att) end},
        {"link", fn id -> link_req(ctx, "AGENT_RUNNER", id, att) end},
        {"link-content", fn id -> link_content_req(ctx, "AGENT_RUNNER", id, att) end},
        {"delete", fn id -> delete_req(ctx, "AGENT_RUNNER", id, att) end}
      ]

      for {label, fun} <- routes do
        malformed = fun.(@malformed)
        valid_shaped = fun.(valid)

        assert_status!("403 " <> label, malformed, 403)
        assert_same_body!("403 body " <> label, malformed, valid_shaped)
      end
    end
  end
end
