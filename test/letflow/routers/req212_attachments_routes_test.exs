defmodule Letflow.Routers.Req212AttachmentsRoutesTest do
  @moduledoc """
  Basic sanity tests for REQ-212's four instance-attachment routes
  (`POST`/`GET /instances/:id/attachments`,
  `GET`/`DELETE /instances/:id/attachments/:attachment_id`), written by
  ELIXIR-DEV at Step 2a to exercise the implementation against a real
  Postgres tenant schema and a real `Letflow.Plugs.ApiPipeline` multipart
  parse. Not full 9-AC coverage -- TEST-DESIGNER writes that later in this
  pipeline (WF-02 Step 2d+). See
  `lib/letflow/design/req212-instance-attachments-routes.md` for the design
  these tests spot-check.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  `async: false` for the same reason every other tenant-fixture-using test
  file in this codebase sets it.

  The upload route is exercised through the REAL `Plug.Parsers` plug
  instance this requirement configured in `Letflow.Plugs.ApiPipeline`
  (`parsers: [:json, {:multipart, length: 26_214_400}]`), invoked directly
  (not the full `ApiPipeline` forward chain, since `Letflow.Plugs.AuthPipeline`
  performs real bearer-token verification that would overwrite
  `conn.assigns[:auth_context]` regardless of what a test presets -- every
  other router test file in this codebase bypasses `AuthPipeline` the same
  way), so this file proves the actual multipart parse mechanism -- not just
  the router's own handler logic against a hand-built `%Plug.Upload{}`.
  Every route is then dispatched directly against
  `Letflow.Routers.Instances.call/2`, matching this router's own existing
  test idiom (`test/letflow/routers/instances_test.exs`).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Repository.Attachments
  alias Letflow.TenantFixture

  import Letflow.TestSupport.InstanceFixture, only: [real_instance!: 1]

  @opts Letflow.Routers.Instances.init([])

  # The exact Plug.Parsers configuration REQ-212 added to
  # Letflow.Plugs.ApiPipeline (lib/letflow/plugs/api_pipeline.ex) --
  # invoked directly rather than through the full pipeline forward chain,
  # see moduledoc.
  @parsers_opts Plug.Parsers.init(
                  parsers: [:json, {:multipart, length: 26_214_400}],
                  json_decoder: Jason,
                  length: 2_097_152
                )

  # ── Dispatch helpers ───────────────────────────────────────────────────

  defp build_conn(method, path, tenant, fields) do
    roles = Keyword.get(fields, :roles, [])
    user_id = Keyword.get(fields, :user_id, Ecto.UUID.generate())

    conn(method, path)
    |> assign(:auth_context, %{user_id: user_id, tenant_id: tenant.tenant_id, roles: roles})
    |> assign(:trace_id, "fixed-test-trace-id")
    |> assign(:scoped_opts, prefix: tenant.schema_name)
  end

  defp dispatch(conn), do: Letflow.Routers.Instances.call(conn, @opts)

  # Drives the request through the REAL Plug.Parsers instance (multipart
  # parse genuinely exercised, including its own :length ceiling), then
  # dispatches to the router directly -- see moduledoc for why the full
  # ApiPipeline forward chain (which includes real bearer-token auth) isn't
  # used here.
  defp dispatch_multipart(method, path, tenant, roles, multipart_body, boundary) do
    conn(method, path, multipart_body)
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    |> Plug.Parsers.call(@parsers_opts)
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
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

  # ── Fixture helpers ────────────────────────────────────────────────────

  defp provisioned_tenant(slug_prefix) do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-212 Attachments Router Test Tenant"
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
  # AC1 -- POST accepts multipart, 2xx with the documented minimum field set
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: POST /instances/:id/attachments" do
    test "accepts a real multipart upload and returns 201 with the documented shape, no content_hash" do
      tenant = provisioned_tenant("req212-upload")
      instance_id = real_instance!(tenant)
      boundary = "req212boundary1"

      body =
        multipart_body(
          boundary,
          "delivery-note.pdf",
          "application/pdf",
          "PDF-BYTES-HERE",
          "a note"
        )

      conn =
        dispatch_multipart(
          :post,
          "/#{instance_id}/attachments",
          tenant,
          ["PROCESS_OPERATOR"],
          body,
          boundary
        )

      assert conn.status == 201
      resp = Jason.decode!(conn.resp_body)

      assert is_binary(resp["id"])
      assert resp["instance_id"] == instance_id
      assert resp["file_name"] == "delivery-note.pdf"
      assert resp["content_type"] == "application/pdf"
      assert resp["byte_size"] == byte_size("PDF-BYTES-HERE")
      assert is_binary(resp["created_at"])
      assert resp["description"] == "a note"
      refute Map.has_key?(resp, "content_hash")

      # Persisted for real, in the tenant's own schema.
      {:ok, stored} = Attachments.get(resp["id"], prefix: tenant.schema_name)
      assert stored.file_name == "delivery-note.pdf"
    end

    test "a multipart request with no file part returns 422, not 500" do
      tenant = provisioned_tenant("req212-nofile")
      instance_id = Ecto.UUID.generate()
      boundary = "req212boundary2"

      body = "--#{boundary}--\r\n"

      conn =
        dispatch_multipart(
          :post,
          "/#{instance_id}/attachments",
          tenant,
          ["PROCESS_OPERATOR"],
          body,
          boundary
        )

      assert conn.status == 422
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4 -- every route requires AttachmentsManage/AttachmentsRead, 403 test
  # per route
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: permission gating -- 403 for a caller with no relevant permission" do
    test "POST -- TASK_WORKER (no AttachmentsManage) gets 403" do
      tenant = provisioned_tenant("req212-403-post")
      instance_id = Ecto.UUID.generate()
      boundary = "req212boundary3"
      body = multipart_body(boundary, "f.txt", "text/plain", "bytes")

      conn =
        dispatch_multipart(
          :post,
          "/#{instance_id}/attachments",
          tenant,
          ["TASK_WORKER"],
          body,
          boundary
        )

      assert conn.status == 403
    end

    test "GET list -- AGENT_RUNNER (holds nothing) gets 403" do
      tenant = provisioned_tenant("req212-403-list")
      instance_id = Ecto.UUID.generate()

      conn =
        build_conn(:get, "/#{instance_id}/attachments", tenant, roles: ["AGENT_RUNNER"])
        |> dispatch()

      assert conn.status == 403
    end

    test "GET content -- AGENT_RUNNER gets 403" do
      tenant = provisioned_tenant("req212-403-get")
      instance_id = Ecto.UUID.generate()
      attachment = upload!(tenant, instance_id)

      conn =
        build_conn(
          :get,
          "/#{instance_id}/attachments/#{attachment.id}",
          tenant,
          roles: ["AGENT_RUNNER"]
        )
        |> dispatch()

      assert conn.status == 403
    end

    test "DELETE -- PROCESS_DESIGNER (AttachmentsRead only, not Manage) gets 403" do
      tenant = provisioned_tenant("req212-403-delete")
      instance_id = Ecto.UUID.generate()
      attachment = upload!(tenant, instance_id)

      conn =
        build_conn(
          :delete,
          "/#{instance_id}/attachments/#{attachment.id}",
          tenant,
          roles: ["PROCESS_DESIGNER"]
        )
        |> dispatch()

      assert conn.status == 403

      # No state change on 403.
      assert {:ok, _still_there} = Attachments.get(attachment.id, prefix: tenant.schema_name)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2 -- GET list: {items, next_cursor} shape, instance-scoped
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2: GET /instances/:id/attachments" do
    test "returns {items, next_cursor} and honors instance-scoping" do
      tenant = provisioned_tenant("req212-list")
      instance_x = real_instance!(tenant)
      instance_y = Ecto.UUID.generate()

      attachment_x = upload!(tenant, instance_x, file_name: "x.txt")
      _attachment_y = upload!(tenant, instance_y, file_name: "y.txt")

      conn =
        build_conn(:get, "/#{instance_x}/attachments", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert Map.keys(body) |> Enum.sort() == ["items", "next_cursor"]
      assert [item] = body["items"]
      assert item["id"] == attachment_x.id
      assert item["file_name"] == "x.txt"
      refute Map.has_key?(item, "content_hash")
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3 -- GET .../:attachment_id returns raw bytes, correct headers
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3: GET /instances/:id/attachments/:attachment_id returns raw bytes" do
    test "byte-for-byte identical body, correct Content-Type and Content-Disposition" do
      tenant = provisioned_tenant("req212-content")
      instance_id = real_instance!(tenant)

      attachment =
        upload!(tenant, instance_id,
          raw_bytes: "exact original bytes",
          file_name: "report.csv",
          content_type: "text/csv"
        )

      conn =
        build_conn(
          :get,
          "/#{instance_id}/attachments/#{attachment.id}",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert conn.status == 200
      assert conn.resp_body == "exact original bytes"

      # put_resp_content_type/2 appends "; charset=utf-8" -- matches
      # Letflow.Api.Response's own documented Content-Type behavior
      # (moduledoc "Content-Type — a deliberate divergence from R-Co").
      assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

      assert get_resp_header(conn, "content-disposition") == [
               "attachment; filename=\"report.csv\""
             ]
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5 -- cross-tenant real instance/attachment id -> 404, never 403
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5: cross-tenant -> 404, never 403" do
    test "an attachment belonging to another tenant is 404 for GET content, DELETE, and absent from list" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req212-cross-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req212-cross-b")

      instance_id = real_instance!(tenant_a)
      tenant_b_attachment = upload!(tenant_b, instance_id)

      get_conn =
        build_conn(
          :get,
          "/#{instance_id}/attachments/#{tenant_b_attachment.id}",
          tenant_a,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      delete_conn =
        build_conn(
          :delete,
          "/#{instance_id}/attachments/#{tenant_b_attachment.id}",
          tenant_a,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert get_conn.status == 404
      assert delete_conn.status == 404

      # Identical bytes to a genuinely nonexistent id (INV-5).
      never_existed_conn =
        build_conn(
          :get,
          "/#{instance_id}/attachments/#{Ecto.UUID.generate()}",
          tenant_a,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert never_existed_conn.status == 404
      assert never_existed_conn.resp_body == get_conn.resp_body

      # Tenant B's row is untouched.
      assert {:ok, _still_there} =
               Attachments.get(tenant_b_attachment.id, prefix: tenant_b.schema_name)
    end

    test "a real instance id belonging to another tenant returns an empty list, never another tenant's rows" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req212-cross-list-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req212-cross-list-b")

      instance_id = real_instance!(tenant_a)
      _tenant_b_attachment = upload!(tenant_b, instance_id)

      conn =
        build_conn(:get, "/#{instance_id}/attachments", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["items"] == []

      # GH #2718: an instance id that is real only in ANOTHER tenant is not
      # visible to tenant A at all -- the Instances 404, not an empty page.
      other_tenant_instance = real_instance!(tenant_b)

      foreign_conn =
        build_conn(:get, "/#{other_tenant_instance}/attachments", tenant_a,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert foreign_conn.status == 404
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC6 -- cross-instance-same-tenant -> 404
  # ══════════════════════════════════════════════════════════════════════

  describe "AC6: cross-instance, same tenant -> 404" do
    test "an attachment real and tenant-correct but belonging to a different instance is 404" do
      tenant = provisioned_tenant("req212-cross-instance")
      instance_x = real_instance!(tenant)
      instance_y = real_instance!(tenant)

      attachment = upload!(tenant, instance_x)

      get_conn =
        build_conn(
          :get,
          "/#{instance_y}/attachments/#{attachment.id}",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      delete_conn =
        build_conn(
          :delete,
          "/#{instance_y}/attachments/#{attachment.id}",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert get_conn.status == 404
      assert delete_conn.status == 404

      # Untouched -- DELETE against the wrong instance_id must not delete it.
      assert {:ok, _still_there} = Attachments.get(attachment.id, prefix: tenant.schema_name)

      # But fetching it via its REAL instance_id still works.
      real_conn =
        build_conn(
          :get,
          "/#{instance_x}/attachments/#{attachment.id}",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert real_conn.status == 200
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC7 -- DELETE against already-deleted/nonexistent -> 404, not duplicate
  # success
  # ══════════════════════════════════════════════════════════════════════

  describe "AC7: DELETE against an already-deleted or nonexistent attachment_id" do
    test "returns 404 rather than a duplicate success" do
      tenant = provisioned_tenant("req212-delete")
      instance_id = Ecto.UUID.generate()
      attachment = upload!(tenant, instance_id)

      first_conn =
        build_conn(
          :delete,
          "/#{instance_id}/attachments/#{attachment.id}",
          tenant,
          roles: ["PROCESS_OPERATOR"]
        )
        |> dispatch()

      assert first_conn.status == 204
      assert first_conn.resp_body == ""

      second_conn =
        build_conn(
          :delete,
          "/#{instance_id}/attachments/#{attachment.id}",
          tenant,
          roles: ["PROCESS_OPERATOR"]
        )
        |> dispatch()

      assert second_conn.status == 404
    end

    test "a genuinely nonexistent attachment_id returns 404" do
      tenant = provisioned_tenant("req212-delete-404")
      instance_id = Ecto.UUID.generate()

      conn =
        build_conn(
          :delete,
          "/#{instance_id}/attachments/#{Ecto.UUID.generate()}",
          tenant,
          roles: ["PROCESS_OPERATOR"]
        )
        |> dispatch()

      assert conn.status == 404
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC8 -- moduledoc states the required content
  # ══════════════════════════════════════════════════════════════════════

  describe "AC8: moduledoc states no existing consumer contract, defines shapes, states content-vs-metadata distinction" do
    test "moduledoc mentions the REQ-212 required statements" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _} =
        Code.fetch_docs(Letflow.Routers.Instances)

      assert moduledoc =~ "No existing `web/` SPA consumer and no R-Co route contract"
      assert moduledoc =~ "Content-vs-metadata distinction"
      assert moduledoc =~ "content_hash` is **never** surfaced"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Size-ceiling rejection at the route level (multipart-specific -- distinct
  # from REQ-211's own upload/2 in-memory check, since Plug.Parsers rejects
  # BEFORE upload/2 is ever called for a body exceeding its own :length)
  # ══════════════════════════════════════════════════════════════════════

  describe "multipart size ceiling" do
    test "a multipart body exceeding Plug.Parsers's configured :length is rejected before upload/2 runs" do
      tenant = provisioned_tenant("req212-oversized")
      instance_id = Ecto.UUID.generate()
      boundary = "req212boundaryoversized"

      # One byte over the 26_214_400 configured ceiling.
      oversized_bytes = :binary.copy("a", 26_214_401)
      body = multipart_body(boundary, "big.bin", "application/octet-stream", oversized_bytes)

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        dispatch_multipart(
          :post,
          "/#{instance_id}/attachments",
          tenant,
          ["PROCESS_OPERATOR"],
          body,
          boundary
        )
      end

      # No attachment was created.
      {:ok, %{items: items}} =
        Attachments.list(%{instance_id: instance_id, cursor: nil, page_size: 10},
          prefix: tenant.schema_name
        )

      assert items == []
    end

    # Mutation-testing finding (TEST-DESIGNER, WF-02 Step 3 gap-check): the
    # test above only proves Plug.Parsers's OWN :length ceiling rejects an
    # oversized multipart body -- it never calls into
    # Letflow.Repository.Attachments.upload/2's own @max_upload_bytes check
    # at all, because Plug.Parsers always intercepts first for a request
    # built through this file's real multipart-parse helper. That leaves
    # upload/2's own size check -- REQ-211's documented, authoritative
    # ceiling and the one this design's own moduledoc calls "defense in
    # depth" for exactly the case where the Plug.Parsers ceiling is ever
    # misconfigured or bypassed -- completely untested from this route
    # layer: a mutation that deleted upload/2's own size guard (or moved it
    # to run after the row was persisted) survived the full suite with 15/15
    # still green. This test closes that gap by constructing a conn whose
    # body_params the router will read directly (bypassing Plug.Parsers
    # entirely, the same way a malformed/atypical multipart encoding or a
    # future parser change could) with an oversized %Plug.Upload{} payload,
    # so the ONLY thing that can still reject it is upload/2's own check --
    # proving that check is genuinely reachable through this route and maps
    # to the documented 413, not merely present in the context module.
    test "an oversized upload that reaches upload/2 directly (Plug.Parsers bypassed) is still rejected via upload/2's own @max_upload_bytes check, 413" do
      tenant = provisioned_tenant("req212-oversized-direct")
      instance_id = real_instance!(tenant)

      oversized_path =
        Path.join(System.tmp_dir!(), "req212_oversized_#{System.unique_integer([:positive])}.bin")

      File.write!(oversized_path, :binary.copy("a", 26_214_401))

      on_exit(fn -> File.rm(oversized_path) end)

      conn =
        build_conn(:post, "/#{instance_id}/attachments", tenant, roles: ["PROCESS_OPERATOR"])
        |> Map.put(:body_params, %{
          "file" => %Plug.Upload{
            path: oversized_path,
            filename: "big.bin",
            content_type: "application/octet-stream"
          }
        })
        |> dispatch()

      assert conn.status == 413

      {:ok, %{items: items}} =
        Attachments.list(%{instance_id: instance_id, cursor: nil, page_size: 10},
          prefix: tenant.schema_name
        )

      assert items == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-389 -- content-type allowlist enforcement, route-level rendering
  # (design §3.3): {:error, :content_type_not_allowed} -> 415, naming the
  # rejected content_type and the allowed set, distinct in both status code
  # and body text from :file_too_large (413) and :infected (422).
  # ══════════════════════════════════════════════════════════════════════

  describe "REQ-389: POST upload with a disallowed content_type" do
    test "returns 415 naming the rejected type and the allowed set, distinct from file_too_large (413) and infected (422) bodies" do
      tenant = provisioned_tenant("req389-disallowed")
      instance_id = real_instance!(tenant)
      boundary = "req389boundary1"

      body = multipart_body(boundary, "clip.mp4", "video/mp4", "not-really-a-video")

      conn =
        dispatch_multipart(
          :post,
          "/#{instance_id}/attachments",
          tenant,
          ["PROCESS_OPERATOR"],
          body,
          boundary
        )

      assert conn.status == 415
      resp = Jason.decode!(conn.resp_body)

      assert resp["detail"] =~ "video/mp4"
      assert resp["detail"] =~ "application/pdf"
      assert resp["type"] =~ "unsupported-media-type"

      # Nothing persisted.
      {:ok, %{items: items}} =
        Attachments.list(%{instance_id: instance_id, cursor: nil, page_size: 10},
          prefix: tenant.schema_name
        )

      assert items == []

      # Distinct from the existing :file_too_large (413) response, both in
      # status code and in body text -- driven down the SAME route with a
      # request that independently triggers the size ceiling instead, to
      # compare actual response shapes rather than assuming distinctness
      # from having read the source. Bypasses Plug.Parsers entirely (its
      # own :length ceiling would otherwise raise RequestTooLargeError
      # before upload/2's own @max_upload_bytes check is ever reached --
      # same technique this file's own "an oversized upload that reaches
      # upload/2 directly" test above uses).
      oversized_path =
        Path.join(
          System.tmp_dir!(),
          "req389_oversized_#{System.unique_integer([:positive])}.bin"
        )

      File.write!(oversized_path, :binary.copy("a", 26_214_401))
      on_exit(fn -> File.rm(oversized_path) end)

      too_large_conn =
        build_conn(:post, "/#{instance_id}/attachments", tenant, roles: ["PROCESS_OPERATOR"])
        |> Map.put(:body_params, %{
          "file" => %Plug.Upload{
            path: oversized_path,
            filename: "big.bin",
            content_type: "application/pdf"
          }
        })
        |> dispatch()

      assert too_large_conn.status == 413
      too_large_resp = Jason.decode!(too_large_conn.resp_body)
      refute too_large_resp["detail"] == resp["detail"]
      refute too_large_resp["type"] == resp["type"]

      # Distinct from the existing :infected (422) response, both in status
      # code and body text.
      previous_scanner = Application.get_env(:letflow, :attachment_scanner)

      Application.put_env(
        :letflow,
        :attachment_scanner,
        Letflow.Routers.Req212AttachmentsRoutesTest.AlwaysInfectedScanner
      )

      on_exit(fn ->
        if previous_scanner do
          Application.put_env(:letflow, :attachment_scanner, previous_scanner)
        else
          Application.delete_env(:letflow, :attachment_scanner)
        end
      end)

      infected_body = multipart_body("req389boundary3", "note.txt", "text/plain", "bytes")

      infected_conn =
        dispatch_multipart(
          :post,
          "/#{instance_id}/attachments",
          tenant,
          ["PROCESS_OPERATOR"],
          infected_body,
          "req389boundary3"
        )

      assert infected_conn.status == 422
      infected_resp = Jason.decode!(infected_conn.resp_body)
      refute infected_resp["detail"] == resp["detail"]
      refute infected_resp["type"] == resp["type"]
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # ISS-0399 -- content-scanning pipeline, route-level error mapping (design
  # §7 OQ-4): {:error, :infected, _} -> 422, {:error, :scan_unavailable} ->
  # 503, {:error, :not_available} (get_content) -> 409.
  # ══════════════════════════════════════════════════════════════════════

  # NOTE: this test deliberately does NOT put literal EICAR bytes through a
  # real `Plug.Parsers` multipart temp-file round-trip. On a dev/CI machine
  # with a live antivirus product (observed here: Windows Defender), an
  # actual EICAR-content temp file gets quarantined/deleted by the AV
  # engine itself between Plug writing it and this route reading it back --
  # a real-world false positive unrelated to this code's correctness, which
  # made this test flake with a `File.Error: I/O error` reading the
  # already-vanished temp file. The real EICAR-detection behavior itself
  # (SignatureHeuristic actually flagging the byte pattern) is already
  # covered at the context-module level
  # (test/letflow/repository/attachments_test.exs's "ISS-0399:
  # EICAR-signature upload is rejected" describe block) and at the unit
  # level (signature_heuristic_test.exs). This test's own job is narrower
  # and doesn't need real EICAR bytes to prove it: verify the ROUTE's
  # {:error, :infected, _} -> 422 status mapping (design §7 OQ-4) --
  # orthogonal to which scanner produced the infected verdict. A fixture
  # scanner that always reports :infected isolates that mapping cleanly,
  # the same way the 503 test below isolates the scan_unavailable mapping.
  describe "ISS-0399: POST upload rejected by the scanner -> 422, nothing persisted" do
    defmodule AlwaysInfectedScanner do
      @moduledoc false
      @behaviour Letflow.Repository.AttachmentScanner

      @impl true
      def scan(_raw_bytes, _content_type), do: {:ok, :infected, "fixture-verdict"}
    end

    test "an infected verdict returns 422 naming the verdict, and persists nothing" do
      previous = Application.get_env(:letflow, :attachment_scanner)
      Application.put_env(:letflow, :attachment_scanner, AlwaysInfectedScanner)

      on_exit(fn ->
        if previous do
          Application.put_env(:letflow, :attachment_scanner, previous)
        else
          Application.delete_env(:letflow, :attachment_scanner)
        end
      end)

      tenant = provisioned_tenant("iss0399-upload-infected")
      instance_id = real_instance!(tenant)
      boundary = "iss0399boundary1"

      body = multipart_body(boundary, "note.txt", "text/plain", "harmless-looking bytes")

      conn =
        dispatch_multipart(
          :post,
          "/#{instance_id}/attachments",
          tenant,
          ["PROCESS_OPERATOR"],
          body,
          boundary
        )

      assert conn.status == 422
      resp = Jason.decode!(conn.resp_body)
      assert resp["detail"] =~ "content scan"
      assert resp["detail"] =~ "fixture-verdict"

      {:ok, %{items: items}} =
        Attachments.list(%{instance_id: instance_id, cursor: nil, page_size: 10},
          prefix: tenant.schema_name
        )

      assert items == []
    end
  end

  describe "ISS-0399: POST upload when the scanner adapter is unavailable -> 503, nothing persisted" do
    defmodule UnavailableScanner do
      @moduledoc false
      @behaviour Letflow.Repository.AttachmentScanner

      @impl true
      def scan(_raw_bytes, _content_type), do: {:error, :simulated_unavailable}
    end

    test "a scanner returning {:error, _} maps to 503" do
      previous = Application.get_env(:letflow, :attachment_scanner)
      Application.put_env(:letflow, :attachment_scanner, UnavailableScanner)

      on_exit(fn ->
        if previous do
          Application.put_env(:letflow, :attachment_scanner, previous)
        else
          Application.delete_env(:letflow, :attachment_scanner)
        end
      end)

      tenant = provisioned_tenant("iss0399-upload-unavail")
      instance_id = real_instance!(tenant)
      boundary = "iss0399boundary2"
      body = multipart_body(boundary, "note.txt", "text/plain", "harmless bytes")

      conn =
        dispatch_multipart(
          :post,
          "/#{instance_id}/attachments",
          tenant,
          ["PROCESS_OPERATOR"],
          body,
          boundary
        )

      assert conn.status == 503

      {:ok, %{items: items}} =
        Attachments.list(%{instance_id: instance_id, cursor: nil, page_size: 10},
          prefix: tenant.schema_name
        )

      assert items == []
    end
  end

  describe "ISS-0399: GET content for a non-:clean attachment -> 409" do
    test "a :pending row's byte content cannot be fetched -- 409, distinct from the 404/500 cases" do
      tenant = provisioned_tenant("iss0399-get-pending")
      instance_id = real_instance!(tenant)

      tenant_id = tenant.tenant_id
      content_hash = :crypto.hash(:sha256, "pending route-level content")

      {:ok, _artifact} =
        Letflow.Repository.upsert_content(
          tenant.schema_name,
          tenant_id,
          content_hash,
          "text/plain",
          byte_size("pending route-level content"),
          "pending route-level content"
        )

      pending_attrs = %{
        tenant_id: tenant_id,
        instance_id: instance_id,
        content_hash: content_hash,
        file_name: "pending.txt",
        content_type: "text/plain",
        byte_size: byte_size("pending route-level content"),
        uploaded_by: Ecto.UUID.generate(),
        scan_status: :pending
      }

      {:ok, pending_attachment} =
        %Letflow.Repository.Attachment{}
        |> Letflow.Repository.Attachment.changeset(pending_attrs)
        |> Letflow.Repo.insert(prefix: tenant.schema_name)

      conn =
        build_conn(
          :get,
          "/#{instance_id}/attachments/#{pending_attachment.id}",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert conn.status == 409
    end
  end
end
