defmodule Letflow.Routers.GH2718AttachmentInstanceCheckTest do
  @moduledoc """
  GH #2718: the six `/instances/:id/attachments...` routes answer an unknown or synthetic
  entity-type instance id with the Instances 404 (`Response.not_found/1`), never create
  anything for it, and leave real instances (active or terminal) untouched.

  Spec: `test/specs/GH-2718.md`; design: `lib/letflow/design/gh2718-attachment-routes-instance-check.md`
  section 6 (A1-A14). A15/A16 live in `test/letflow/gh2718_instance_visible_test.exs`, A17 in
  `test/letflow/repository/gh2718_attachments_delete_event_test.exs`.

  Real HTTP through `Letflow.Router` (bearer token + `x-tenant-slug`) for every equality test;
  the query-count and temp-path tests dispatch to `Letflow.Routers.Instances` directly with
  assigns (no token-touch noise in the statement counts). Comparisons are on status, body and the
  FULL response headers (only `x-request-id` and `date` masked; the trace id is pinned). Failure
  messages never print a response body.

  Each test is labelled in its name: [RED] fails on main (the behaviour the fix introduces),
  [GUARD] already passes on main and must keep passing.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query
  import Letflow.TestSupport.InstanceFixture, only: [real_instance!: 1]

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.Attachment
  alias Letflow.Repository.AttachmentLinks
  alias Letflow.Repository.Attachments
  alias Letflow.Secrets.Secret
  alias Letflow.TenantFixture

  @fixed_trace "00000000-0000-4000-8000-0000000000bb"
  @masked_headers ["x-request-id", "date"]
  @removed_type "ATTACHMENT_REMOVED"
  @attached_type "ATTACHMENT_ATTACHED"
  @boundary "gh2718b"

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2718-#{Ecto.UUID.generate()}",
      display_name: "GH2718 Test User",
      email: "gh2718-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp token!(user, tenant, role) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: [role], expires_at: nil},
        prefix: tenant.schema_name
      )

    plaintext
  end

  # One tenant, bearer tokens per role, one real active instance, one real instance that is
  # then cancelled, and one synthetic entity-type instance (registered in entity_type_instances).
  defp ctx! do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2718-att",
        display_name: "GH2718 Attachment Instance Check Tenant"
      )

    {:ok, _} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant)

    tokens =
      for role <- ["TENANT_ADMIN", "TASK_WORKER", "TENANT_AUDITOR", "AGENT_RUNNER", "CANDIDATE"],
          into: %{} do
        {role, token!(user, tenant, role)}
      end

    {:ok, synthetic_id} = EntityTypeInstance.get_or_create("widget", tenant.schema_name)

    %{
      tenant_id: tenant.tenant_id,
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      user_id: user.id,
      tokens: tokens,
      synthetic_id: synthetic_id,
      real_id: real_instance!(tenant)
    }
  end

  defp cancelled_instance!(ctx) do
    id = real_instance!(ctx)
    conn = request(ctx, "TENANT_ADMIN", "POST", "/api/v1/instances/#{id}/cancel")
    200 = conn.status
    id
  end

  # An attachment row whose parent is whatever `instance_id` names, inserted through the context
  # (the context still accepts any id; only the router is guarded).
  defp orphan!(ctx, instance_id, label) do
    attrs = %{
      instance_id: instance_id,
      raw_bytes: "gh2718 orphan bytes " <> label,
      file_name: "orphan-" <> label <> ".txt",
      content_type: "text/plain",
      uploaded_by: ctx.user_id,
      description: nil
    }

    {:ok, attachment} = Attachments.upload(attrs, prefix: ctx.schema_name)
    attachment
  end

  # ── HTTP helpers ────────────────────────────────────────────────────────────

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

  defp list_req(ctx, role, id, query \\ ""),
    do: request(ctx, role, "GET", base(id) <> "/attachments" <> query)

  defp download_req(ctx, role, id, att_id),
    do: request(ctx, role, "GET", base(id) <> "/attachments/" <> att_id)

  defp delete_req(ctx, role, id, att_id),
    do: request(ctx, role, "DELETE", base(id) <> "/attachments/" <> att_id)

  defp link_req(ctx, role, id, att_id),
    do: request(ctx, role, "POST", base(id) <> "/attachments/#{att_id}/link", body: "{}")

  defp link_content_req(ctx, role, id, att_id, token),
    do:
      request(
        ctx,
        role,
        "GET",
        base(id) <>
          "/attachments/#{att_id}/link-content?link_token=" <> URI.encode_www_form(token)
      )

  defp instance_get_req(ctx, role, id), do: request(ctx, role, "GET", base(id))

  # status + body + FULL headers; only request id / date masked.
  defp normalised(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {k, _} -> k in @masked_headers end)
      |> Enum.sort()

    {conn.status, conn.resp_body, headers}
  end

  # Boolean probe: a mismatch names the label and never prints a body.
  defp assert_same!(label, a, b),
    do: assert({label, normalised(a) == normalised(b)} == {label, true})

  defp assert_status!(label, conn, status), do: assert({label, conn.status} == {label, status})

  # ── direct-router helpers (no pipeline: statement counts are exact) ─────────

  @router_opts Letflow.Routers.Instances.init([])

  defp direct(ctx, method, path, roles) do
    conn(method, path)
    |> assign(:auth_context, %{user_id: ctx.user_id, tenant_id: ctx.tenant_id, roles: roles})
    |> assign(:trace_id, "gh2718-direct-trace")
    |> assign(:scoped_opts, prefix: ctx.schema_name)
  end

  defp dispatch(conn), do: Letflow.Routers.Instances.call(conn, @router_opts)

  # Runs fun, returns {result, [sql text of every Repo statement issued by this process]}.
  defp capture_statements(fun) do
    handler = "gh2718-capture-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:letflow, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test_pid, do: send(test_pid, {:gh2718_stmt, Map.get(meta, :query, "")})
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_statements([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_statements(acc) do
    receive do
      {:gh2718_stmt, sql} -> drain_statements([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp write_statement?(sql) do
    String.match?(sql, ~r/^\s*(INSERT|UPDATE|DELETE)\b/i)
  end

  # ── state probes ────────────────────────────────────────────────────────────

  defp attachment_rows(ctx), do: Repo.aggregate(Attachment, :count, prefix: ctx.schema_name)
  defp artifact_rows(ctx), do: Repo.aggregate(Artifact, :count, prefix: ctx.schema_name)
  defp storage_used(ctx), do: elem(Attachments.get_storage_usage(prefix: ctx.schema_name), 1)

  defp secret_rows(ctx),
    do: Repo.aggregate(from(s in Secret, where: s.tenant_id == ^ctx.tenant_id), :count)

  defp event_count(ctx, instance_id),
    do:
      Repo.aggregate(from(e in Event, where: e.instance_id == ^instance_id), :count,
        prefix: ctx.schema_name
      )

  defp typed_event_count(ctx, instance_id, type),
    do:
      Repo.aggregate(
        from(e in Event, where: e.instance_id == ^instance_id and e.event_type == ^type),
        :count,
        prefix: ctx.schema_name
      )

  defp events_of_type(ctx, type),
    do:
      Repo.aggregate(from(e in Event, where: e.event_type == ^type), :count,
        prefix: ctx.schema_name
      )

  defp events_with_key(ctx, key),
    do: Repo.all(from(e in Event, where: e.idempotency_key == ^key), prefix: ctx.schema_name)

  defp idempotency_rows(ctx),
    do: Repo.aggregate(IdempotencyRecord, :count, prefix: ctx.schema_name)

  defp sequence_row(ctx, id), do: Repo.get(InstanceSequence, id, prefix: ctx.schema_name)
  defp projection(ctx, id), do: Repo.get!(InstanceProjection, id, prefix: ctx.schema_name)

  # ── A1 / A2 / A3 / A3b: upload ──────────────────────────────────────────────

  describe "R1 upload" do
    test "[RED] A1 upload to a nonexistent instance id is the Instances 404, equal to GET /instances/<random>" do
      ctx = ctx!()
      random = Ecto.UUID.generate()

      resp = upload_req(ctx, "TENANT_ADMIN", random)
      reference = instance_get_req(ctx, "TENANT_ADMIN", Ecto.UUID.generate())

      assert_status!("A1 status", resp, 404)
      assert_same!("A1 vs GET /instances/<random>", resp, reference)
    end

    test "[RED] A2 upload to a synthetic instance id equals the nonexistent-id answer" do
      ctx = ctx!()

      synthetic = upload_req(ctx, "TENANT_ADMIN", ctx.synthetic_id)
      nonexistent = upload_req(ctx, "TENANT_ADMIN", Ecto.UUID.generate())

      assert_status!("A2 status", synthetic, 404)
      assert_same!("A2 synthetic vs nonexistent", synthetic, nonexistent)
    end

    test "[RED] A3 upload to an unknown or synthetic id writes nothing (no rows, no event, no quota)" do
      ctx = ctx!()

      before_state = {attachment_rows(ctx), artifact_rows(ctx), storage_used(ctx)}
      before_events = event_count(ctx, ctx.synthetic_id)

      for id <- [Ecto.UUID.generate(), ctx.synthetic_id] do
        assert_status!("A3 status", upload_req(ctx, "TENANT_ADMIN", id), 404)
      end

      assert {attachment_rows(ctx), artifact_rows(ctx), storage_used(ctx)} == before_state
      assert event_count(ctx, ctx.synthetic_id) == before_events
      assert typed_event_count(ctx, ctx.synthetic_id, @attached_type) == 0
    end

    test "[RED] A3b the visible-instance check runs before the temp file is read (M7b)" do
      ctx = ctx!()

      missing_path =
        Path.join(System.tmp_dir!(), "gh2718_missing_#{System.unique_integer([:positive])}.bin")

      refute File.exists?(missing_path)

      upload_conn = fn id ->
        direct(ctx, :post, "/#{id}/attachments", ["TENANT_ADMIN"])
        |> Map.put(:body_params, %{
          "file" => %Plug.Upload{
            path: missing_path,
            filename: "x.txt",
            content_type: "text/plain"
          }
        })
      end

      for id <- [Ecto.UUID.generate(), ctx.synthetic_id] do
        assert_status!("A3b unknown/synthetic", dispatch(upload_conn.(id)), 404)
      end

      # control: a REAL instance reaches the file read and hits the unreadable path
      error =
        try do
          dispatch(upload_conn.(ctx.real_id))
          :no_raise
        rescue
          e -> e
        end

      error =
        case error do
          %Plug.Conn.WrapperError{reason: reason} -> reason
          other -> other
        end

      assert %File.Error{} = error
    end
  end

  # ── A4 / A5 / A6: list ──────────────────────────────────────────────────────

  describe "R2 list" do
    test "[RED] A4 list on a nonexistent instance id is the Instances 404" do
      ctx = ctx!()
      resp = list_req(ctx, "TENANT_ADMIN", Ecto.UUID.generate())

      assert_status!("A4 status", resp, 404)

      assert_same!(
        "A4 vs GET /instances/<random>",
        resp,
        instance_get_req(ctx, "TENANT_ADMIN", Ecto.UUID.generate())
      )
    end

    test "[RED] A5 list on a synthetic instance id equals the nonexistent-id answer" do
      ctx = ctx!()
      synthetic = list_req(ctx, "TENANT_ADMIN", ctx.synthetic_id)
      nonexistent = list_req(ctx, "TENANT_ADMIN", Ecto.UUID.generate())

      assert_status!("A5 status", synthetic, 404)
      assert_same!("A5 synthetic vs nonexistent", synthetic, nonexistent)
    end

    test "[RED] A6 a pre-existing orphan row under an unknown or synthetic id is not disclosed" do
      ctx = ctx!()
      unknown = Ecto.UUID.generate()
      orphan!(ctx, unknown, "a6-unknown")
      orphan!(ctx, ctx.synthetic_id, "a6-synthetic")

      for id <- [unknown, ctx.synthetic_id] do
        resp = list_req(ctx, "TENANT_ADMIN", id)
        assert_status!("A6 status", resp, 404)
        refute resp.resp_body =~ "orphan-a6"
      end
    end
  end

  # ── A7: DELETE oracle matrix (supervisor ruling O2, D6 option 2) ─────────────

  describe "R4 delete" do
    test "[GUARD] A7a/A7b/A7c missing attachment: unknown, synthetic and real instance answer the identical 404" do
      ctx = ctx!()
      missing = Ecto.UUID.generate()
      reference = instance_get_req(ctx, "TENANT_ADMIN", Ecto.UUID.generate())

      unknown = delete_req(ctx, "TENANT_ADMIN", Ecto.UUID.generate(), missing)
      synthetic = delete_req(ctx, "TENANT_ADMIN", ctx.synthetic_id, missing)
      real = delete_req(ctx, "TENANT_ADMIN", ctx.real_id, missing)

      assert_status!("A7a status", unknown, 404)
      assert_same!("A7a unknown vs GET /instances/<random>", unknown, reference)
      assert_same!("A7b synthetic vs unknown", synthetic, unknown)
      assert_same!("A7c real vs unknown (no instance oracle on delete)", real, unknown)
    end

    test "[GUARD] A7d a legacy orphan under an UNKNOWN instance id is deletable; quota released; repeat is 404" do
      ctx = ctx!()
      unknown = Ecto.UUID.generate()
      orphan = orphan!(ctx, unknown, "a7d")
      used = storage_used(ctx)
      missing_reference = delete_req(ctx, "TENANT_ADMIN", unknown, Ecto.UUID.generate())

      resp = delete_req(ctx, "TENANT_ADMIN", unknown, orphan.id)

      assert_status!("A7d first", resp, 204)
      assert Attachments.get(orphan.id, prefix: ctx.schema_name) == {:error, :not_found}
      assert storage_used(ctx) == used - orphan.byte_size

      assert_same!(
        "A7d repeat",
        delete_req(ctx, "TENANT_ADMIN", unknown, orphan.id),
        missing_reference
      )
    end

    test "[GUARD] A7e a legacy orphan under a SYNTHETIC instance id is deletable; quota released; repeat is 404" do
      ctx = ctx!()
      orphan = orphan!(ctx, ctx.synthetic_id, "a7e")
      used = storage_used(ctx)
      missing_reference = delete_req(ctx, "TENANT_ADMIN", ctx.synthetic_id, Ecto.UUID.generate())

      resp = delete_req(ctx, "TENANT_ADMIN", ctx.synthetic_id, orphan.id)

      assert_status!("A7e first", resp, 204)
      assert Attachments.get(orphan.id, prefix: ctx.schema_name) == {:error, :not_found}
      assert storage_used(ctx) == used - orphan.byte_size

      assert_same!(
        "A7e repeat",
        delete_req(ctx, "TENANT_ADMIN", ctx.synthetic_id, orphan.id),
        missing_reference
      )
    end

    test "[GUARD] A7f cross-parent probe: a row of real X named under unknown Y or synthetic S is 404 and survives" do
      ctx = ctx!()
      attachment = orphan!(ctx, ctx.real_id, "a7f")
      reference = delete_req(ctx, "TENANT_ADMIN", Ecto.UUID.generate(), Ecto.UUID.generate())

      for wrong_parent <- [Ecto.UUID.generate(), ctx.synthetic_id] do
        resp = delete_req(ctx, "TENANT_ADMIN", wrong_parent, attachment.id)
        assert_status!("A7f status", resp, 404)
        assert_same!("A7f vs plain missing", resp, reference)
      end

      assert {:ok, _} = Attachments.get(attachment.id, prefix: ctx.schema_name)
    end

    test "[GUARD] A7g query count is equal across unknown+missing, synthetic+missing and real+missing" do
      ctx = ctx!()

      run = fn id ->
        direct(ctx, :delete, "/#{id}/attachments/#{Ecto.UUID.generate()}", ["TENANT_ADMIN"])
        |> dispatch()
      end

      # warm-up so first-use caches do not skew the first measured request
      for id <- [Ecto.UUID.generate(), ctx.synthetic_id, ctx.real_id], do: run.(id)

      counts =
        for id <- [Ecto.UUID.generate(), ctx.synthetic_id, ctx.real_id] do
          {conn, statements} = capture_statements(fn -> run.(id) end)
          assert conn.status == 404
          length(statements)
        end

      assert [count, count, count] = counts
      assert count == 1
    end

    test "[GUARD] A7h S+orphan, U+orphan and V+orphan delete answers are byte-identical 204s" do
      ctx = ctx!()

      responses =
        for {parent, label} <- [
              {Ecto.UUID.generate(), "u"},
              {ctx.synthetic_id, "s"},
              {ctx.real_id, "v"}
            ] do
          orphan = orphan!(ctx, parent, "a7h-" <> label)
          delete_req(ctx, "TENANT_ADMIN", parent, orphan.id)
        end

      [u, s, v] = responses
      assert_status!("A7h status", u, 204)
      assert u.resp_body == ""
      assert_same!("A7h synthetic vs unknown", s, u)
      assert_same!("A7h real vs unknown", v, u)
    end

    test "[RED] A7i deleting an orphan of a synthetic instance appends nothing to the synthetic instance" do
      ctx = ctx!()
      orphan = orphan!(ctx, ctx.synthetic_id, "a7i")

      before_events = event_count(ctx, ctx.synthetic_id)
      before_sequence = sequence_row(ctx, ctx.synthetic_id)
      before_projection = projection(ctx, ctx.synthetic_id)
      before_idempotency = idempotency_rows(ctx)

      assert_status!(
        "A7i delete",
        delete_req(ctx, "TENANT_ADMIN", ctx.synthetic_id, orphan.id),
        204
      )

      assert event_count(ctx, ctx.synthetic_id) == before_events
      assert typed_event_count(ctx, ctx.synthetic_id, @removed_type) == 0
      assert events_with_key(ctx, "attachment_removed:" <> orphan.id) == []
      assert sequence_row(ctx, ctx.synthetic_id) == before_sequence
      assert projection(ctx, ctx.synthetic_id) == before_projection

      assert {projection(ctx, ctx.synthetic_id).status,
              projection(ctx, ctx.synthetic_id).cancelled_at} == {:active, nil}

      assert idempotency_rows(ctx) == before_idempotency
    end

    test "[GUARD] A7j deleting an attachment of a real instance emits exactly one removal event; an unknown parent emits none" do
      ctx = ctx!()
      real_attachment = orphan!(ctx, ctx.real_id, "a7j-real")
      key = "attachment_removed:" <> real_attachment.id
      before_real = typed_event_count(ctx, ctx.real_id, @removed_type)

      assert_status!(
        "A7j real",
        delete_req(ctx, "TENANT_ADMIN", ctx.real_id, real_attachment.id),
        204
      )

      assert typed_event_count(ctx, ctx.real_id, @removed_type) == before_real + 1
      assert [%Event{event_type: @removed_type}] = events_with_key(ctx, key)

      unknown = Ecto.UUID.generate()
      unknown_attachment = orphan!(ctx, unknown, "a7j-unknown")
      before_total = events_of_type(ctx, @removed_type)

      assert_status!(
        "A7j unknown",
        delete_req(ctx, "TENANT_ADMIN", unknown, unknown_attachment.id),
        204
      )

      assert events_of_type(ctx, @removed_type) == before_total
      assert event_count(ctx, unknown) == 0
    end
  end

  # ── A8 / A9: download, link-content, link issue on orphans ──────────────────

  describe "R3 / R6 / R5 on an orphan under an unknown or synthetic instance id" do
    test "[RED] A8 download and link-content are the Instances 404 for an orphan attachment, valid and invalid tokens alike" do
      ctx = ctx!()
      unknown = Ecto.UUID.generate()
      other = orphan!(ctx, ctx.real_id, "a8-other")
      reference = instance_get_req(ctx, "TENANT_ADMIN", Ecto.UUID.generate())

      for {parent, label} <- [{unknown, "u"}, {ctx.synthetic_id, "s"}] do
        orphan = orphan!(ctx, parent, "a8-" <> label)

        download = download_req(ctx, "TENANT_ADMIN", parent, orphan.id)
        assert_status!("A8 download " <> label, download, 404)
        assert_same!("A8 download vs GET /instances/<random> " <> label, download, reference)
        refute download.resp_body =~ "orphan bytes"

        {:ok, %{token: valid}} = AttachmentLinks.issue(orphan.id, ctx.tenant_id)
        {:ok, %{token: other_token}} = AttachmentLinks.issue(other.id, ctx.tenant_id)

        for {token, token_label} <- [
              {valid, "valid"},
              {"not-a-token", "garbage"},
              {other_token, "other-attachment"}
            ] do
          resp = link_content_req(ctx, "TENANT_ADMIN", parent, orphan.id, token)
          assert_status!("A8 link-content #{label}/#{token_label}", resp, 404)
          assert_same!("A8 link-content #{label}/#{token_label}", resp, reference)
          refute resp.resp_body =~ "orphan bytes"
        end
      end
    end

    test "[RED] A9 link issue is the Instances 404, mints no token and writes no signing key" do
      ctx = ctx!()
      unknown = Ecto.UUID.generate()
      reference = instance_get_req(ctx, "TENANT_ADMIN", Ecto.UUID.generate())
      secrets_before = secret_rows(ctx)

      for {parent, label} <- [{unknown, "u"}, {ctx.synthetic_id, "s"}] do
        orphan = orphan!(ctx, parent, "a9-" <> label)
        resp = link_req(ctx, "TENANT_ADMIN", parent, orphan.id)

        assert_status!("A9 " <> label, resp, 404)
        assert_same!("A9 vs GET /instances/<random> " <> label, resp, reference)
        refute resp.resp_body =~ "token"
      end

      assert secret_rows(ctx) == secrets_before
    end
  end

  # ── A10: validation order (existence-independent answers) ───────────────────

  describe "A10 validation order" do
    # NOTE (finding, not fixed here): DELETE with a malformed instance id is NOT in this list. On main and
    # on this branch handle_delete_attachment/3 has no :invalid_instance_id else-clause, so it raises
    # WithClauseError (500) instead of the 422 the other five routes give. Out of scope for #2718 (D6
    # leaves the handler unchanged); reported to the supervisor.
    test "[GUARD] a malformed instance id is 422 on the five checked routes, ahead of existence" do
      ctx = ctx!()
      att = Ecto.UUID.generate()

      for {label, resp} <- [
            {"upload", upload_req(ctx, "TENANT_ADMIN", "not-a-uuid")},
            {"list", list_req(ctx, "TENANT_ADMIN", "not-a-uuid")},
            {"download", download_req(ctx, "TENANT_ADMIN", "not-a-uuid", att)},
            {"link", link_req(ctx, "TENANT_ADMIN", "not-a-uuid", att)},
            {"link-content", link_content_req(ctx, "TENANT_ADMIN", "not-a-uuid", att, "t")}
          ] do
        assert_status!("A10 malformed " <> label, resp, 422)
      end
    end

    test "[GUARD] a bad page_size is the same 400 for a real, unknown and synthetic id" do
      ctx = ctx!()

      [real, unknown, synthetic] =
        for id <- [ctx.real_id, Ecto.UUID.generate(), ctx.synthetic_id],
            do: list_req(ctx, "TENANT_ADMIN", id, "?page_size=0")

      assert_status!("A10 page_size real", real, 400)
      assert_same!("A10 page_size unknown", unknown, real)
      assert_same!("A10 page_size synthetic", synthetic, real)
    end

    test "[GUARD] an upload without a file part is the same 422 for a real, unknown and synthetic id" do
      ctx = ctx!()
      empty = "--#{@boundary}--\r\n"

      [real, unknown, synthetic] =
        for id <- [ctx.real_id, Ecto.UUID.generate(), ctx.synthetic_id] do
          request(ctx, "TENANT_ADMIN", "POST", base(id) <> "/attachments",
            body: empty,
            content_type: "multipart/form-data; boundary=#{@boundary}"
          )
        end

      assert_status!("A10 missing file real", real, 422)
      assert_same!("A10 missing file unknown", unknown, real)
      assert_same!("A10 missing file synthetic", synthetic, real)
    end
  end

  # ── A11: equality matrix ────────────────────────────────────────────────────

  describe "A11 equality matrix" do
    test "[RED] for R1, R2, R3, R5, R6 and each role holding the permission: synthetic == nonexistent == GET /instances/<random>" do
      ctx = ctx!()
      unknown = Ecto.UUID.generate()
      orphan_u = orphan!(ctx, unknown, "a11-u")
      orphan_s = orphan!(ctx, ctx.synthetic_id, "a11-s")
      {:ok, %{token: valid_s}} = AttachmentLinks.issue(orphan_s.id, ctx.tenant_id)
      {:ok, %{token: valid_u}} = AttachmentLinks.issue(orphan_u.id, ctx.tenant_id)

      # {label, roles, fun(role, parent, orphan_for_parent, valid_token_for_parent)}
      routes = [
        {"R1 upload", ["TENANT_ADMIN"], fn role, id, _o, _t -> upload_req(ctx, role, id) end},
        {"R2 list", ["TENANT_ADMIN", "TASK_WORKER", "TENANT_AUDITOR"],
         fn role, id, _o, _t -> list_req(ctx, role, id) end},
        {"R3 download", ["TENANT_ADMIN", "TASK_WORKER", "TENANT_AUDITOR"],
         fn role, id, o, _t -> download_req(ctx, role, id, o.id) end},
        {"R5 link", ["TENANT_ADMIN"], fn role, id, o, _t -> link_req(ctx, role, id, o.id) end},
        {"R6 link-content valid", ["TENANT_ADMIN", "TASK_WORKER", "TENANT_AUDITOR"],
         fn role, id, o, t -> link_content_req(ctx, role, id, o.id, t) end},
        {"R6 link-content invalid", ["TENANT_ADMIN", "TASK_WORKER", "TENANT_AUDITOR"],
         fn role, id, o, _t -> link_content_req(ctx, role, id, o.id, "not-a-token") end}
      ]

      for {label, roles, fun} <- routes, role <- roles do
        reference = instance_get_req(ctx, role, Ecto.UUID.generate())
        assert_status!("A11 reference #{label}/#{role}", reference, 404)

        synthetic = fun.(role, ctx.synthetic_id, orphan_s, valid_s)
        nonexistent = fun.(role, unknown, orphan_u, valid_u)
        random = fun.(role, Ecto.UUID.generate(), orphan_u, valid_u)

        assert_status!("A11 #{label}/#{role} synthetic", synthetic, 404)
        assert_same!("A11 #{label}/#{role} synthetic vs GET", synthetic, reference)
        assert_same!("A11 #{label}/#{role} nonexistent vs GET", nonexistent, reference)
        assert_same!("A11 #{label}/#{role} random vs GET", random, reference)
      end
    end
  end

  # ── A12: permission precedes existence ──────────────────────────────────────

  describe "A12 permission precedes existence" do
    test "[GUARD] a caller lacking the permission gets the same 403 for a real, unknown and synthetic id" do
      ctx = ctx!()
      att = Ecto.UUID.generate()

      manage_routes = [
        {"upload", fn role, id -> upload_req(ctx, role, id) end},
        {"delete", fn role, id -> delete_req(ctx, role, id, att) end},
        {"link", fn role, id -> link_req(ctx, role, id, att) end}
      ]

      read_routes = [
        {"list", fn role, id -> list_req(ctx, role, id) end},
        {"download", fn role, id -> download_req(ctx, role, id, att) end},
        {"link-content", fn role, id -> link_content_req(ctx, role, id, att, "t") end}
      ]

      cases =
        for role <- ["AGENT_RUNNER", "CANDIDATE", "TENANT_AUDITOR"],
            {label, fun} <- manage_routes,
            do: {role, label, fun}

      cases = cases ++ for {label, fun} <- read_routes, do: {"AGENT_RUNNER", label, fun}

      for {role, label, fun} <- cases do
        [real, unknown, synthetic] =
          for id <- [ctx.real_id, Ecto.UUID.generate(), ctx.synthetic_id], do: fun.(role, id)

        assert_status!("A12 #{role}/#{label}", real, 403)
        assert_same!("A12 #{role}/#{label} unknown", unknown, real)
        assert_same!("A12 #{role}/#{label} synthetic", synthetic, real)
      end
    end
  end

  # ── A13: DB path ────────────────────────────────────────────────────────────

  describe "A13 DB path" do
    test "[RED] unknown and synthetic ids issue the same statements and no write on R1, R2, R3, R5, R6" do
      ctx = ctx!()
      unknown = Ecto.UUID.generate()
      orphan_u = orphan!(ctx, unknown, "a13-u")
      orphan_s = orphan!(ctx, ctx.synthetic_id, "a13-s")
      {:ok, %{token: token_u}} = AttachmentLinks.issue(orphan_u.id, ctx.tenant_id)
      {:ok, %{token: token_s}} = AttachmentLinks.issue(orphan_s.id, ctx.tenant_id)

      upload_path =
        Path.join(System.tmp_dir!(), "gh2718_a13_#{System.unique_integer([:positive])}.txt")

      File.write!(upload_path, "a13 bytes")
      on_exit(fn -> File.rm(upload_path) end)

      upload_params = %{
        "file" => %Plug.Upload{path: upload_path, filename: "a13.txt", content_type: "text/plain"}
      }

      routes = [
        {"R1",
         fn id, _o, _t ->
           direct(ctx, :post, "/#{id}/attachments", ["TENANT_ADMIN"])
           |> Map.put(:body_params, upload_params)
         end},
        {"R2", fn id, _o, _t -> direct(ctx, :get, "/#{id}/attachments", ["TENANT_ADMIN"]) end},
        {"R3",
         fn id, o, _t ->
           direct(ctx, :get, "/#{id}/attachments/#{o.id}", ["TENANT_ADMIN"])
         end},
        {"R5",
         fn id, o, _t ->
           direct(ctx, :post, "/#{id}/attachments/#{o.id}/link", ["TENANT_ADMIN"])
         end},
        {"R6",
         fn id, o, t ->
           direct(
             ctx,
             :get,
             "/#{id}/attachments/#{o.id}/link-content?link_token=#{URI.encode_www_form(t)}",
             ["TENANT_ADMIN"]
           )
         end}
      ]

      for {label, build} <- routes do
        run = fn id, o, t -> capture_statements(fn -> dispatch(build.(id, o, t)) end) end

        # warm-up
        run.(unknown, orphan_u, token_u)
        run.(ctx.synthetic_id, orphan_s, token_s)

        {conn_u, statements_u} = run.(unknown, orphan_u, token_u)
        {conn_s, statements_s} = run.(ctx.synthetic_id, orphan_s, token_s)

        assert {label, conn_u.status, conn_s.status} == {label, 404, 404}
        assert {label, length(statements_s)} == {label, length(statements_u)}

        assert {label, Enum.filter(statements_u ++ statements_s, &write_statement?/1)} ==
                 {label, []}
      end
    end
  end

  # ── A14: control, real instances ────────────────────────────────────────────

  describe "A14 control: real instances still work" do
    test "[GUARD] an ACTIVE and a CANCELLED instance: upload 201, list 200, download 200, link 200, delete 204" do
      ctx = ctx!()

      for {id, label} <- [{ctx.real_id, "active"}, {cancelled_instance!(ctx), "cancelled"}] do
        upload = upload_req(ctx, "TENANT_ADMIN", id)
        assert_status!("A14 upload #{label}", upload, 201)
        body = Jason.decode!(upload.resp_body)
        assert {label, body["instance_id"], body["file_name"]} == {label, id, "doc.txt"}
        att_id = body["id"]

        list = list_req(ctx, "TENANT_ADMIN", id)
        assert_status!("A14 list #{label}", list, 200)
        assert att_id in Enum.map(Jason.decode!(list.resp_body)["items"], & &1["id"])

        download = download_req(ctx, "TENANT_ADMIN", id, att_id)
        assert_status!("A14 download #{label}", download, 200)
        assert download.resp_body == "hello"

        link = link_req(ctx, "TENANT_ADMIN", id, att_id)
        assert_status!("A14 link #{label}", link, 200)
        token = Jason.decode!(link.resp_body)["token"]

        assert_status!(
          "A14 link-content #{label}",
          link_content_req(ctx, "TENANT_ADMIN", id, att_id, token),
          200
        )

        assert_status!("A14 delete #{label}", delete_req(ctx, "TENANT_ADMIN", id, att_id), 204)
      end
    end
  end
end
