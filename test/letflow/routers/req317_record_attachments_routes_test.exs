defmodule Letflow.Routers.Req317RecordAttachmentsRoutesTest do
  @moduledoc """
  Tests for REQ-317's four record-attachment routes appended to
  `Letflow.Routers.Entities`
  (`POST`/`GET /entities/records/:entity_type/:record_id/attachments`,
  `GET`/`DELETE /entities/records/:entity_type/:record_id/attachments/:attachment_id`),
  written by ELIXIR-DEV at Step 2a against a real Postgres tenant schema and
  the REAL `Letflow.Plugs.ApiPipeline` stack (real bearer-token auth, real
  multipart parse) -- matching `test/letflow/routers/entities_test.exs`'s own
  full-pipeline dispatch convention for this router, and
  `test/letflow/routers/req212_attachments_routes_test.exs`'s own multipart
  helpers for the upload mechanics. See
  `lib/letflow/design/req313-entity-record-attachments.md` for the design
  these tests exercise, and REQ-317's acceptance criteria in
  `docs/requirements.yaml` for the full checklist.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  `async: false` because `TenantFixture.provisioned_tenant!/1` switches the
  sandbox to global `:auto` mode.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Repository.EntityAttachments
  alias Letflow.TenantFixture

  # ── Full-pipeline dispatch, matching entities_test.exs's own convention ──

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  # The full ApiPipeline plug chain (Letflow.Router.call/2) already includes
  # the real Plug.Parsers multipart configuration (lib/letflow/plugs/api_pipeline.ex)
  # -- unlike req212_attachments_routes_test.exs (which dispatches the router
  # in isolation and so must invoke Plug.Parsers by hand), this file's
  # dispatch/1 runs the whole pipeline, so the multipart parse happens for
  # free on the way through.
  defp dispatch_multipart(method, path, ctx, multipart_body, boundary) do
    conn(method, path, multipart_body)
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp multipart_body(boundary, file_name, content_type, file_bytes, description \\ nil) do
    description_part =
      if description do
        "--#{boundary}\r\n" <>
          "Content-Disposition: form-data; name=\"description\"\r\n\r\n" <>
          "#{description}\r\n"
      else
        ""
      end

    "--#{boundary}\r\n" <>
      "Content-Disposition: form-data; name=\"file\"; filename=\"#{file_name}\"\r\n" <>
      "Content-Type: #{content_type}\r\n\r\n" <>
      file_bytes <>
      "\r\n" <>
      description_part <>
      "--#{boundary}--\r\n"
  end

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req317-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-317 Record Attachments Router Test User",
      email: "req317-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp tenant_ctx(slug_prefix, roles \\ ["TENANT_ADMIN"]) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "REQ-317 Record Attachments Router Test Tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      tenant_id: tenant.tenant_id,
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp mint_token!(ctx, roles) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(ctx.user_id, %{roles: roles, expires_at: nil},
        prefix: ctx.schema_name
      )

    plaintext
  end

  defp seed_active_widget_definition!(ctx, name \\ "widget") do
    document = %{
      name: name,
      display_name: String.capitalize(name),
      fields: [%{name: "title", type: :string, required: true}]
    }

    {:ok, _definition} =
      Definitions.create_definition(
        %{definition: document, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, _activated} =
      Definitions.activate_definition(name, ctx.user_id, "test go-live", ctx.schema_name)

    :ok
  end

  defp seed_record!(ctx, entity_type \\ "widget", field_values \\ %{"title" => "seeded"}) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: entity_type,
          field_values: field_values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  defp upload!(ctx, entity_type, record_id, overrides \\ []) do
    attrs =
      Map.merge(
        %{
          entity_type: entity_type,
          record_id: record_id,
          raw_bytes: "hello record attachment bytes",
          file_name: "note.txt",
          content_type: "text/plain",
          uploaded_by: ctx.user_id,
          description: nil
        },
        Map.new(overrides)
      )

    {:ok, attachment} = EntityAttachments.upload(attrs, prefix: ctx.schema_name)
    attachment
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  # A problem document minus the one member that is legitimately per-REQUEST
  # rather than per-resource (`trace_id`), matching entities_test.exs's own
  # normalise_problem/1 convention.
  defp normalise_problem(conn), do: conn |> body_of() |> Map.delete("trace_id")

  defp attachments_path(entity_type, record_id),
    do: "/api/v1/entities/records/#{entity_type}/#{record_id}/attachments"

  defp attachment_path(entity_type, record_id, attachment_id),
    do: "/api/v1/entities/records/#{entity_type}/#{record_id}/attachments/#{attachment_id}"

  # ══════════════════════════════════════════════════════════════════════
  # Success statuses -- 201 / 200 (list) / 200 (get-content) / 204
  # ══════════════════════════════════════════════════════════════════════

  describe "success statuses through the full pipeline" do
    test "POST returns 201 with the documented shape, no content_hash" do
      ctx = tenant_ctx("req317-create")
      seed_active_widget_definition!(ctx)
      record = seed_record!(ctx)
      boundary = "req317boundary1"

      body =
        multipart_body(boundary, "spec.pdf", "application/pdf", "PDF-BYTES-HERE", "a note")

      conn =
        dispatch_multipart(
          :post,
          attachments_path("widget", record.record_id),
          ctx,
          body,
          boundary
        )

      assert conn.status == 201, "expected 201, got #{conn.status}: #{conn.resp_body}"
      resp = body_of(conn)

      assert is_binary(resp["id"])
      assert resp["entity_type"] == "widget"
      assert resp["record_id"] == record.record_id
      assert resp["file_name"] == "spec.pdf"
      assert resp["content_type"] == "application/pdf"
      assert resp["byte_size"] == byte_size("PDF-BYTES-HERE")
      assert resp["uploaded_by"] == ctx.user_id
      assert resp["description"] == "a note"
      assert is_binary(resp["created_at"])
      refute Map.has_key?(resp, "content_hash")

      {:ok, stored} = EntityAttachments.get(resp["id"], prefix: ctx.schema_name)
      assert stored.file_name == "spec.pdf"
    end

    test "GET list returns {items, next_cursor} scoped to (entity_type, record_id)" do
      ctx = tenant_ctx("req317-list")
      seed_active_widget_definition!(ctx)
      record_x = seed_record!(ctx, "widget", %{"title" => "x"})
      record_y = seed_record!(ctx, "widget", %{"title" => "y"})

      attachment_x = upload!(ctx, "widget", record_x.record_id, file_name: "x.txt")
      _attachment_y = upload!(ctx, "widget", record_y.record_id, file_name: "y.txt")

      conn = request(:get, attachments_path("widget", record_x.record_id), ctx)

      assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
      body = body_of(conn)

      assert Map.keys(body) |> Enum.sort() == ["items", "next_cursor"]
      assert [item] = body["items"]
      assert item["id"] == attachment_x.id
      assert item["file_name"] == "x.txt"
      refute Map.has_key?(item, "content_hash")
    end

    test "GET .../:attachment_id returns raw bytes with the correct Content-Type" do
      ctx = tenant_ctx("req317-content")
      seed_active_widget_definition!(ctx)
      record = seed_record!(ctx)

      attachment =
        upload!(ctx, "widget", record.record_id,
          raw_bytes: "exact original bytes",
          file_name: "report.csv",
          content_type: "text/csv"
        )

      conn = request(:get, attachment_path("widget", record.record_id, attachment.id), ctx)

      assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
      assert conn.resp_body == "exact original bytes"

      assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

      assert get_resp_header(conn, "content-disposition") == [
               "attachment; filename=\"report.csv\""
             ]
    end

    test "DELETE returns 204 and the row is really gone" do
      ctx = tenant_ctx("req317-delete")
      seed_active_widget_definition!(ctx)
      record = seed_record!(ctx)
      attachment = upload!(ctx, "widget", record.record_id)

      conn = request(:delete, attachment_path("widget", record.record_id, attachment.id), ctx)

      assert conn.status == 204, "expected 204, got #{conn.status}: #{conn.resp_body}"
      assert conn.resp_body == ""

      assert {:error, :not_found} =
               EntityAttachments.get(attachment.id, prefix: ctx.schema_name)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Error branches -- 404 (FK) and 422 (content scan)
  # ══════════════════════════════════════════════════════════════════════

  describe "create error branches" do
    test "POST against an (entity_type, record_id) pair that never existed returns 404" do
      ctx = tenant_ctx("req317-fk-404")
      boundary = "req317boundary2"

      body = multipart_body(boundary, "note.txt", "text/plain", "bytes")

      conn =
        dispatch_multipart(
          :post,
          attachments_path("widget", Ecto.UUID.generate()),
          ctx,
          body,
          boundary
        )

      assert conn.status == 404, "expected 404, got #{conn.status}: #{conn.resp_body}"
    end

    # AC5's {:infected, verdict} branch. Deliberately NOT the real EICAR test
    # string here: writing it to a real temp file via a genuine multipart
    # upload (the only way to reach this router's handler) gets that temp
    # file quarantined mid-request by this host's own antivirus (confirmed
    # directly: File.read/1 on the written temp file returns :eio) -- an
    # environment interference specific to on-disk EICAR content, not a gap
    # in this route's own error mapping (the EICAR signature itself is
    # already exercised, entirely in-memory, by
    # Letflow.Repository.EntityAttachments's own REQ-316 scan-gate tests).
    # A swapped-in scanner double (same technique
    # test/letflow/repository/attachments_test.exs's RaisingScanner uses for
    # the sibling :scan_unavailable branch) flags plain, benign content as
    # infected instead, proving this router's own {:error, :infected, verdict}
    # -> 422 mapping without ever writing the real signature to disk.
    defmodule AlwaysInfectedScanner do
      @moduledoc false
      @behaviour Letflow.Repository.AttachmentScanner

      @impl true
      def scan(_raw_bytes, _content_type), do: {:ok, :infected, "req317-test-verdict"}
    end

    defp put_attachment_scanner!(module) do
      previous = Application.get_env(:letflow, :attachment_scanner)
      Application.put_env(:letflow, :attachment_scanner, module)

      on_exit(fn ->
        if previous do
          Application.put_env(:letflow, :attachment_scanner, previous)
        else
          Application.delete_env(:letflow, :attachment_scanner)
        end
      end)

      :ok
    end

    test "POST flagged as infected by the scanner returns 422, not 500" do
      ctx = tenant_ctx("req317-infected")
      seed_active_widget_definition!(ctx)
      record = seed_record!(ctx)
      boundary = "req317boundary3"
      put_attachment_scanner!(AlwaysInfectedScanner)

      body = multipart_body(boundary, "note.txt", "text/plain", "perfectly ordinary bytes")

      conn =
        dispatch_multipart(
          :post,
          attachments_path("widget", record.record_id),
          ctx,
          body,
          boundary
        )

      assert conn.status == 422, "expected 422, got #{conn.status}: #{conn.resp_body}"
      assert body_of(conn)["detail"] =~ "req317-test-verdict"

      # Never persisted.
      {:ok, %{items: items}} =
        EntityAttachments.list(
          %{entity_type: "widget", record_id: record.record_id, page_size: 10},
          prefix: ctx.schema_name
        )

      assert items == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Permission gating -- one 403 per distinct permission atom, plus a
  # non-403 case for a caller who holds it.
  # ══════════════════════════════════════════════════════════════════════

  describe "permission gating (:EntitiesAttachmentsManage / :EntitiesAttachmentsRead)" do
    test "create (Manage) -- TASK_WORKER (Read only) is denied, PROCESS_OPERATOR (Manage) is not" do
      ctx = tenant_ctx("req317-authz-manage", ["TENANT_ADMIN"])
      seed_active_widget_definition!(ctx)
      record = seed_record!(ctx)
      boundary = "req317boundary4"
      body = multipart_body(boundary, "note.txt", "text/plain", "bytes")

      denied_ctx = %{ctx | plaintext: mint_token!(ctx, ["TASK_WORKER"])}
      allowed_ctx = %{ctx | plaintext: mint_token!(ctx, ["PROCESS_OPERATOR"])}

      denied =
        dispatch_multipart(
          :post,
          attachments_path("widget", record.record_id),
          denied_ctx,
          body,
          boundary
        )

      assert denied.status == 403

      allowed =
        dispatch_multipart(
          :post,
          attachments_path("widget", record.record_id),
          allowed_ctx,
          body,
          boundary
        )

      refute allowed.status == 403
    end

    test "delete (Manage) -- AGENT_RUNNER (neither) is denied, TENANT_ADMIN (both) is not" do
      ctx = tenant_ctx("req317-authz-delete", ["TENANT_ADMIN"])
      seed_active_widget_definition!(ctx)
      record = seed_record!(ctx)
      attachment = upload!(ctx, "widget", record.record_id)

      denied_ctx = %{ctx | plaintext: mint_token!(ctx, ["AGENT_RUNNER"])}

      denied =
        request(:delete, attachment_path("widget", record.record_id, attachment.id), denied_ctx)

      assert denied.status == 403

      allowed = request(:delete, attachment_path("widget", record.record_id, attachment.id), ctx)
      refute allowed.status == 403
    end

    test "list (Read) -- AGENT_RUNNER (neither) is denied, TASK_WORKER (Read only) is not" do
      ctx = tenant_ctx("req317-authz-list", ["TENANT_ADMIN"])
      seed_active_widget_definition!(ctx)
      record = seed_record!(ctx)
      _attachment = upload!(ctx, "widget", record.record_id)

      denied_ctx = %{ctx | plaintext: mint_token!(ctx, ["AGENT_RUNNER"])}
      allowed_ctx = %{ctx | plaintext: mint_token!(ctx, ["TASK_WORKER"])}

      denied = request(:get, attachments_path("widget", record.record_id), denied_ctx)
      assert denied.status == 403

      allowed = request(:get, attachments_path("widget", record.record_id), allowed_ctx)
      refute allowed.status == 403
    end

    test "get-content (Read) -- AGENT_RUNNER (neither) is denied, PROCESS_DESIGNER (Read only) is not" do
      ctx = tenant_ctx("req317-authz-content", ["TENANT_ADMIN"])
      seed_active_widget_definition!(ctx)
      record = seed_record!(ctx)
      attachment = upload!(ctx, "widget", record.record_id)

      denied_ctx = %{ctx | plaintext: mint_token!(ctx, ["AGENT_RUNNER"])}
      allowed_ctx = %{ctx | plaintext: mint_token!(ctx, ["PROCESS_DESIGNER"])}

      denied =
        request(:get, attachment_path("widget", record.record_id, attachment.id), denied_ctx)

      assert denied.status == 403

      allowed =
        request(:get, attachment_path("widget", record.record_id, attachment.id), allowed_ctx)

      refute allowed.status == 403
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # INV-5 -- not-found/cross-tenant/cross-record indistinguishability
  # ══════════════════════════════════════════════════════════════════════

  describe "INV-5: not-found and cross-tenant/cross-record are the same bytes" do
    test "get-content: cross-tenant attachment id is byte-identical to a genuinely absent one" do
      tenant_a = tenant_ctx("req317-cross-a")
      tenant_b = tenant_ctx("req317-cross-b")

      seed_active_widget_definition!(tenant_a)
      seed_active_widget_definition!(tenant_b)
      record_a = seed_record!(tenant_a)
      record_b = seed_record!(tenant_b)

      tenant_b_attachment = upload!(tenant_b, "widget", record_b.record_id)

      cross_tenant_conn =
        request(
          :get,
          attachment_path("widget", record_a.record_id, tenant_b_attachment.id),
          tenant_a
        )

      never_existed_conn =
        request(
          :get,
          attachment_path("widget", record_a.record_id, Ecto.UUID.generate()),
          tenant_a
        )

      assert cross_tenant_conn.status == 404
      assert never_existed_conn.status == 404
      # trace_id is per-REQUEST correlation data, not per-resource
      # information (matching entities_test.exs's own normalise_problem/1
      # convention) -- every other field must still be byte-identical.
      assert normalise_problem(cross_tenant_conn) == normalise_problem(never_existed_conn)

      # Tenant B's row is untouched.
      assert {:ok, _still_there} =
               EntityAttachments.get(tenant_b_attachment.id, prefix: tenant_b.schema_name)
    end

    test "delete: cross-tenant attachment id returns the same 404, no state change" do
      tenant_a = tenant_ctx("req317-cross-del-a")
      tenant_b = tenant_ctx("req317-cross-del-b")

      seed_active_widget_definition!(tenant_a)
      seed_active_widget_definition!(tenant_b)
      record_a = seed_record!(tenant_a)
      record_b = seed_record!(tenant_b)

      tenant_b_attachment = upload!(tenant_b, "widget", record_b.record_id)

      conn =
        request(
          :delete,
          attachment_path("widget", record_a.record_id, tenant_b_attachment.id),
          tenant_a
        )

      assert conn.status == 404

      assert {:ok, _still_there} =
               EntityAttachments.get(tenant_b_attachment.id, prefix: tenant_b.schema_name)
    end

    test "list: a cross-tenant (entity_type, record_id) pair returns an EMPTY 200 page, never 404" do
      tenant_a = tenant_ctx("req317-cross-list-a")
      tenant_b = tenant_ctx("req317-cross-list-b")

      seed_active_widget_definition!(tenant_b)
      record_b = seed_record!(tenant_b)
      _attachment = upload!(tenant_b, "widget", record_b.record_id)

      conn = request(:get, attachments_path("widget", record_b.record_id), tenant_a)

      assert conn.status == 200
      assert body_of(conn)["items"] == []
    end

    test "get-content: a real attachment fetched via a DIFFERENT (same-tenant) record path is 404" do
      ctx = tenant_ctx("req317-cross-record")
      seed_active_widget_definition!(ctx)
      record_x = seed_record!(ctx, "widget", %{"title" => "x"})
      record_y = seed_record!(ctx, "widget", %{"title" => "y"})

      attachment = upload!(ctx, "widget", record_x.record_id)

      conn = request(:get, attachment_path("widget", record_y.record_id, attachment.id), ctx)

      assert conn.status == 404
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # INV-1 -- tenant scoping is server-resolved only
  # ══════════════════════════════════════════════════════════════════════

  describe "INV-1: caller-supplied tenant_id/schema/slug fields are ignored" do
    test "create: a request with tenant_id/schema/slug body fields behaves identically to one without" do
      ctx = tenant_ctx("req317-inv1-create")
      seed_active_widget_definition!(ctx)
      record = seed_record!(ctx)
      boundary = "req317boundary5"

      other_tenant = tenant_ctx("req317-inv1-other")

      plain_body = multipart_body(boundary, "note.txt", "text/plain", "bytes")

      plain_conn =
        dispatch_multipart(
          :post,
          attachments_path("widget", record.record_id),
          ctx,
          plain_body,
          boundary
        )

      # A second, otherwise-identical multipart request, but the query string
      # ALSO carries tenant_id/schema/slug fields (a multipart body has no
      # natural extra-field slot the router reads for these -- the query
      # string is the injection surface an attacker actually controls on this
      # route).
      path_with_spoofed_query =
        attachments_path("widget", record.record_id) <>
          "?tenant_id=#{other_tenant.tenant_id}&schema=#{other_tenant.schema_name}&slug=#{other_tenant.slug}"

      spoofed_conn =
        dispatch_multipart(:post, path_with_spoofed_query, ctx, plain_body, boundary)

      assert plain_conn.status == 201
      assert spoofed_conn.status == 201

      plain_resp = body_of(plain_conn)
      spoofed_resp = body_of(spoofed_conn)

      # Both persisted in the CALLER's own tenant schema (ctx), never
      # other_tenant's -- proven by both being independently fetchable there.
      assert {:ok, _} = EntityAttachments.get(plain_resp["id"], prefix: ctx.schema_name)
      assert {:ok, _} = EntityAttachments.get(spoofed_resp["id"], prefix: ctx.schema_name)

      assert {:error, :not_found} =
               EntityAttachments.get(spoofed_resp["id"], prefix: other_tenant.schema_name)
    end

    test "list: tenant_id/schema/slug query params are ignored -- same items either way" do
      ctx = tenant_ctx("req317-inv1-list")
      seed_active_widget_definition!(ctx)
      record = seed_record!(ctx)
      _attachment = upload!(ctx, "widget", record.record_id)

      other_tenant = tenant_ctx("req317-inv1-list-other")

      plain_conn = request(:get, attachments_path("widget", record.record_id), ctx)

      spoofed_path =
        attachments_path("widget", record.record_id) <>
          "?tenant_id=#{other_tenant.tenant_id}&schema=#{other_tenant.schema_name}&slug=#{other_tenant.slug}"

      spoofed_conn = request(:get, spoofed_path, ctx)

      assert plain_conn.status == 200
      assert spoofed_conn.status == 200
      assert body_of(plain_conn)["items"] == body_of(spoofed_conn)["items"]
    end

    test "grep: no new direct Repo call was added to the Entities router or its handler modules" do
      {output, _exit} =
        System.cmd(
          "grep",
          ["-rn", "Repo\\.", "lib/letflow/routers/entities.ex", "lib/letflow/routers/entities"],
          cd: File.cwd!(),
          stderr_to_stdout: true
        )

      # The Entities router and its handler modules (record_attachments.ex,
      # record_writes.ex, record_import.ex, support.ex) have NEVER issued a
      # Repo.* call (INV-1 moduledoc section) -- REQ-317 delegates exclusively
      # to Letflow.Repository.EntityAttachments, so this grep is expected to
      # return nothing at all, same as before this requirement's change.
      assert output == "",
             "expected zero 'Repo.' matches in the Entities router and its handler modules, got:\n#{output}"
    end

    test "grep: no FieldGrants code call was added to the record-attachment handlers" do
      # Comments may still mention FieldGrants (the design explains why the
      # attachment path does not redact); only code lines count.
      code_lines =
        "lib/letflow/routers/entities/record_attachments.ex"
        |> File.read!()
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
        |> Enum.filter(&String.contains?(&1, "FieldGrants"))

      assert code_lines == [],
             "expected no FieldGrants code call in record_attachments.ex, got:\n#{Enum.join(code_lines, "\n")}"
    end
  end
end
