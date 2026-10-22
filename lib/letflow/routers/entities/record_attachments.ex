defmodule Letflow.Routers.Entities.RecordAttachments do
  @moduledoc """
  Record attachment handlers (REQ-317, GH #2784 TypeAccess), mounted by Letflow.Routers.Entities.

  Extracted from `Letflow.Routers.Entities` (GH #2833). The route table stays there;
  each route's handler delegates here with the arguments it had as a local function,
  so behaviour, the INV-1 prefix handling and every response are unchanged.
  """

  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.ScopeGate
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.RecordAccess
  alias Letflow.Entities.ScopedLookup
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.EntityAttachment
  alias Letflow.Repository.EntityAttachments

  import Letflow.Routers.Entities.Support

  import Plug.Conn,
    only: [fetch_query_params: 1, put_resp_content_type: 2, put_resp_header: 3, send_resp: 3]

  # ── GH #2784 (PR B): TypeAccess on the four record-attachment routes ─────
  #
  # `RecordAccess.attachment/3` (one TypeAccess read) is computed at the top of each handler,
  # before the record id is cast, and APPLIED by substitution: for a `:hidden` type the handler
  # runs the SAME code with a freshly generated UUID in place of `record_id` (and, for content
  # GET and delete, of `attachment_id`). No such row can exist, so a denied type takes exactly the
  # absent path (upload: FK failure -> 404 after the same 413/422/503 pre-checks; list: the empty
  # page; content GET and delete: `:not_found` -> 404 with no artifact bytes loaded). Substitution
  # happens AFTER `cast_record_id/1`, so a malformed id is still the same 404 as for an absent
  # type. The write routes also refuse a managed type (GH #2582); no field
  # restriction (an attachment is not a `field_values` document).
  @spec record_attachment_access(Plug.Conn.t(), String.t()) :: RecordAccess.attachment_decision()
  defp record_attachment_access(conn, entity_type),
    do: RecordAccess.attachment(conn.assigns.auth_context.user_id, entity_type, prefix!(conn))

  # GH #2582: the WRITE routes (upload, delete) add the managed stamp; `:managed` is the same
  # constant 403 as the record routes, decided before the record id is read.
  @spec record_attachment_write_access(Plug.Conn.t(), String.t()) ::
          RecordAccess.attachment_write_decision()
  defp record_attachment_write_access(conn, entity_type),
    do:
      RecordAccess.attachment_write(conn.assigns.auth_context.user_id, entity_type, prefix!(conn))

  defp hide_if_denied(:open, id), do: id
  defp hide_if_denied(:hidden, _id), do: Ecto.UUID.generate()

  # REQ-518 (2c-ii, AC 11): the PARENT gate of the four attachment routes. An `:all` caller is
  # always visible (no statement; `hide_if_denied/2` still applies). A scoped caller's parent is
  # visible only through `ScopedLookup` (a hidden type never is). An invisible parent takes the
  # branch a NONEXISTENT parent takes today: the handlers re-enter the same code with freshly
  # generated ids (list, content, delete) or answer the same 404 (create), so the two cases are
  # one answer and one statement shape (INV-5). Counted, not audited.
  @spec parent_visible?(
          Types.scope_set(),
          RecordAccess.attachment_decision(),
          String.t(),
          Ecto.UUID.t(),
          String.t(),
          atom()
        ) :: boolean()
  defp parent_visible?(:all, _access, _entity_type, _record_id, _prefix, _policy), do: true

  defp parent_visible?(_scoped, :hidden, _entity_type, _record_id, _prefix, policy) do
    ScopedLookup.emit_not_found(policy, :attachment_parent)
    false
  end

  defp parent_visible?(scope, :open, entity_type, record_id, prefix, policy) do
    match?(
      {:ok, _declaration},
      ScopedLookup.fetch_in_scope(
        entity_type,
        record_id,
        scope,
        prefix,
        {policy, :attachment_parent}
      )
    )
  end

  defp visible_or_fresh_id(true, access, id), do: hide_if_denied(access, id)
  defp visible_or_fresh_id(false, _access, _id), do: Ecto.UUID.generate()

  # ══ POST /entities/records/:entity_type/:record_id/attachments (REQ-317) ══
  #
  # Multipart upload, same shape as Letflow.Routers.Instances' own
  # POST /instances/:id/attachments (REQ-212 design §5.4): the file arrives
  # as a %Plug.Upload{} body part named "file". `uploaded_by` is the
  # authenticated caller (conn.assigns.auth_context.user_id), never a body
  # field (design §5 INV-1). `entity_type`/`record_id` come from the path.

  @doc false
  def handle_create_record_attachment(conn, entity_type, raw_record_id) do
    {conn, scope} = ScopeGate.scope_set(conn, :EntitiesAttachmentsManage)
    opts = conn.assigns.scoped_opts

    case record_attachment_write_access(conn, entity_type) do
      :managed ->
        Response.send_problem(conn, Error.entity_type_managed())

      access ->
        create_record_attachment_with_access(
          conn,
          entity_type,
          raw_record_id,
          access,
          scope,
          opts
        )
    end
  end

  defp create_record_attachment_with_access(conn, entity_type, raw_record_id, access, scope, opts) do
    # REQ-518 (2c-ii): for a scoped caller the parent gate runs BEFORE the multipart part is read,
    # so an out-of-scope and a nonexistent parent both answer 404 without examining the upload.
    with {:ok, record_id} <- cast_record_id(raw_record_id),
         :ok <- attachment_parent_gate(scope, access, entity_type, record_id, prefix!(conn)),
         record_id = hide_if_denied(access, record_id),
         {:ok, attrs} <- record_attachment_upload_attrs_from_conn(conn, entity_type, record_id) do
      render_create_record_attachment(conn, EntityAttachments.upload(attrs, opts))
    else
      # INV-5: a malformed record id folds to the same zero-detail 404 as an
      # absent (or cross-tenant) one -- matching cast_record_id/1's existing
      # use on the record-command routes above.
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :parent_out_of_scope} ->
        Response.not_found(conn)

      {:error, :missing_file} ->
        Response.unprocessable(conn, "a file part named \"file\" is required")
    end
  end

  defp attachment_parent_gate(scope, access, entity_type, record_id, prefix) do
    if parent_visible?(
         scope,
         access,
         entity_type,
         record_id,
         prefix,
         :EntitiesAttachmentsManage
       ),
       do: :ok,
       else: {:error, :parent_out_of_scope}
  end

  @spec record_attachment_upload_attrs_from_conn(Plug.Conn.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, EntityAttachments.upload_attrs()} | {:error, :missing_file}
  defp record_attachment_upload_attrs_from_conn(conn, entity_type, record_id) do
    case conn.body_params["file"] do
      %Plug.Upload{path: path, filename: filename, content_type: content_type} ->
        attrs = %{
          entity_type: entity_type,
          record_id: record_id,
          raw_bytes: File.read!(path),
          file_name: filename,
          content_type: content_type,
          uploaded_by: conn.assigns.auth_context.user_id,
          description: record_attachment_description(conn.body_params["description"])
        }

        {:ok, attrs}

      _missing_or_not_a_file ->
        {:error, :missing_file}
    end
  end

  defp record_attachment_description(value) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp record_attachment_description(_absent_or_empty), do: nil

  defp render_create_record_attachment(conn, {:ok, attachment}) do
    Response.created(conn, record_attachment_json(attachment))
  end

  defp render_create_record_attachment(conn, {:error, :file_too_large}) do
    Response.payload_too_large(conn, "uploaded file exceeds the maximum allowed size")
  end

  defp render_create_record_attachment(conn, {:error, :infected, verdict}) do
    Response.unprocessable(conn, "uploaded file failed a content scan (#{verdict})")
  end

  defp render_create_record_attachment(conn, {:error, :scan_unavailable}) do
    Response.service_unavailable(conn, "content scan is temporarily unavailable, please retry")
  end

  # AC5 (design §7 OQ-1, closed): an (entity_type, record_id) pair with no
  # matching entity_record_latest row surfaces here as an ordinary
  # Ecto.Changeset error (EntityAttachment.changeset/2's
  # foreign_key_constraint/3 clause on :record_id) -- mapped to 404, never a
  # raised, unhandled Postgres error and never a 422. Any OTHER changeset
  # error (e.g. file_name over 255 characters) is a genuine validation
  # failure and stays 422.
  defp render_create_record_attachment(conn, {:error, %Ecto.Changeset{} = changeset}) do
    if Keyword.has_key?(changeset.errors, :record_id) do
      Response.not_found(conn)
    else
      Response.unprocessable(conn, "request failed validation")
    end
  end

  # ══ GET /entities/records/:entity_type/:record_id/attachments (REQ-317) ══
  #
  # Cursor-paginated JSON metadata list, same page-size/cursor contract as
  # Letflow.Routers.Instances' own GET /instances/:id/attachments (REQ-212
  # design §5.2). No existence check against entity_record_latest -- a
  # nonexistent (or cross-tenant) (entity_type, record_id) pair returns an
  # EMPTY 200 page, matching design §2/§5's own stated INV-5 behavior. A
  # malformed record id still folds to 404, matching this router's own
  # cast_record_id/1 convention for the record-command routes.

  @doc false
  def handle_list_record_attachments(conn, entity_type, raw_record_id) do
    {conn, scope} = ScopeGate.scope_set(conn, :EntitiesAttachmentsRead)
    opts = conn.assigns.scoped_opts
    access = record_attachment_access(conn, entity_type)
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, record_id} <- cast_record_id(raw_record_id),
         visible? =
           parent_visible?(
             scope,
             access,
             entity_type,
             record_id,
             prefix!(conn),
             :EntitiesAttachmentsRead
           ),
         record_id = visible_or_fresh_id(visible?, access, record_id),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      params = %{
        entity_type: entity_type,
        record_id: record_id,
        cursor: Map.get(query, "cursor"),
        page_size: page_size
      }

      render_list_record_attachments(conn, EntityAttachments.list(params, opts))
    else
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  # Deliberately NOT render_page_result/3 -- that shared helper adds a
  # "count" key this route's own {items, next_cursor} shape (matching
  # Letflow.Routers.Instances' own list-attachments precedent) must not
  # carry.
  defp render_list_record_attachments(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &record_attachment_json/1),
      "next_cursor" => next_cursor
    })
  end

  defp render_list_record_attachments(conn, {:error, reason})
       when reason in [:invalid_cursor, :wrong_endpoint],
       do: Response.unprocessable(conn, "cursor is not valid for this endpoint")

  defp render_list_record_attachments(conn, {:error, :expired}),
    do: Response.send_problem(conn, Error.cursor_expired())

  defp render_list_record_attachments(conn, {:error, :page_size_too_large}),
    do: Response.bad_request(conn, "page_size out of range")

  # ══ GET /entities/records/:entity_type/:record_id/attachments/:attachment_id
  # ══ (REQ-317) ══════════════════════════════════════════════════════════
  #
  # Raw-bytes response, same INV-RT-1 discipline as Letflow.Routers.Instances'
  # own GET /instances/:id/attachments/:attachment_id (REQ-212 design §4/§5.3):
  # neither the byte-content lookup nor this handler's own cross-record 404
  # check ever issues a direct Ecto Repo call -- both are delegated to (or
  # folded through) Letflow.Repository.EntityAttachments. Both the
  # cross-tenant check (structural, via opts[:prefix]) and the
  # cross-record-same-tenant check (explicit, in-handler, mirroring
  # Letflow.Routers.Instances' own cross-instance check) fold to the same
  # {:error, :not_found} -- design §5 INV-5. `Content-Type` is set from the
  # stored (caller-declared, untrusted per design §6 INV-a) content_type
  # field -- no MIME-sniffing.

  @doc false
  def handle_get_record_attachment_content(conn, entity_type, raw_record_id, raw_attachment_id) do
    {conn, scope} = ScopeGate.scope_set(conn, :EntitiesAttachmentsRead)
    opts = conn.assigns.scoped_opts
    access = record_attachment_access(conn, entity_type)

    with {:ok, record_id} <- cast_record_id(raw_record_id),
         visible? =
           parent_visible?(
             scope,
             access,
             entity_type,
             record_id,
             prefix!(conn),
             :EntitiesAttachmentsRead
           ),
         record_id = visible_or_fresh_id(visible?, access, record_id),
         attachment_id = visible_or_fresh_id(visible?, access, raw_attachment_id),
         {:ok, attachment, artifact} <-
           fetch_scoped_record_attachment_content(attachment_id, entity_type, record_id, opts) do
      send_record_attachment_content(conn, attachment, artifact)
    else
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :content_missing} ->
        Response.internal_error(conn)

      {:error, :not_available} ->
        Response.conflict(conn, "attachment content is not currently available")
    end
  end

  @spec fetch_scoped_record_attachment_content(String.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, EntityAttachment.t(), Artifact.t()}
          | {:error, :not_found | :content_missing | :not_available}
  defp fetch_scoped_record_attachment_content(raw_attachment_id, entity_type, record_id, opts) do
    case EntityAttachments.get_content(raw_attachment_id, opts) do
      {:ok, %EntityAttachment{entity_type: ^entity_type, record_id: ^record_id} = attachment,
       artifact} ->
        {:ok, attachment, artifact}

      {:ok, %EntityAttachment{}, _artifact} ->
        {:error, :not_found}

      {:error, :invalid_id} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :content_missing} ->
        {:error, :content_missing}

      {:error, :not_available} ->
        {:error, :not_available}
    end
  end

  defp send_record_attachment_content(
         conn,
         %EntityAttachment{} = attachment,
         %Artifact{} = artifact
       ) do
    conn
    |> put_resp_content_type(attachment.content_type)
    |> put_resp_header(
      "content-disposition",
      record_attachment_content_disposition(attachment.file_name)
    )
    |> send_resp(200, artifact.content)
  end

  # Escapes literal `"` and `\` (Content-Disposition's own quoting rules) and
  # strips CR/LF/other C0 control characters before interpolating a
  # caller-supplied file_name into a raw HTTP header value, matching
  # Letflow.Routers.Instances' own content_disposition/1 precedent -- this
  # never affects the stored/returned file_name value itself, only this
  # one header's rendering.
  @spec record_attachment_content_disposition(String.t()) :: String.t()
  defp record_attachment_content_disposition(file_name) do
    sanitized =
      file_name
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> strip_record_attachment_control_characters()

    "attachment; filename=\"#{sanitized}\""
  end

  defp strip_record_attachment_control_characters(value) do
    String.replace(value, ~r/[\x00-\x1F\x7F]/, "")
  end

  # ══ DELETE /entities/records/:entity_type/:record_id/attachments/:attachment_id
  # ══ (REQ-317) ══════════════════════════════════════════════════════════

  @doc false
  def handle_delete_record_attachment(conn, entity_type, raw_record_id, raw_attachment_id) do
    {conn, scope} = ScopeGate.scope_set(conn, :EntitiesAttachmentsManage)
    opts = conn.assigns.scoped_opts

    case record_attachment_write_access(conn, entity_type) do
      :managed ->
        Response.send_problem(conn, Error.entity_type_managed())

      access ->
        delete_record_attachment_with_access(
          conn,
          {entity_type, raw_record_id, raw_attachment_id},
          access,
          scope,
          opts
        )
    end
  end

  defp delete_record_attachment_with_access(
         conn,
         {entity_type, raw_record_id, raw_attachment_id},
         access,
         scope,
         opts
       ) do
    with {:ok, record_id} <- cast_record_id(raw_record_id),
         visible? =
           parent_visible?(
             scope,
             access,
             entity_type,
             record_id,
             prefix!(conn),
             :EntitiesAttachmentsManage
           ),
         record_id = visible_or_fresh_id(visible?, access, record_id),
         attachment_id = visible_or_fresh_id(visible?, access, raw_attachment_id),
         {:ok, _attachment} <-
           fetch_scoped_record_attachment_metadata(
             attachment_id,
             entity_type,
             record_id,
             opts
           ),
         {:ok, _deleted} <- EntityAttachments.delete(attachment_id, opts) do
      Response.no_content(conn)
    else
      {:error, :invalid_record_id} -> Response.not_found(conn)
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  # Metadata-only sibling of fetch_scoped_record_attachment_content/4, for
  # DELETE -- same cross-record/cross-tenant 404 checks, no
  # repository_artifacts lookup (DELETE never needs the byte content).
  @spec fetch_scoped_record_attachment_metadata(String.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, EntityAttachment.t()} | {:error, :not_found}
  defp fetch_scoped_record_attachment_metadata(raw_attachment_id, entity_type, record_id, opts) do
    case EntityAttachments.get(raw_attachment_id, opts) do
      {:ok, %EntityAttachment{entity_type: ^entity_type, record_id: ^record_id} = attachment} ->
        {:ok, attachment}

      {:ok, %EntityAttachment{}} ->
        {:error, :not_found}

      {:error, :invalid_id} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # ── Response allowlist (INV-2) — shared by create/list (REQ-317) ────────
  #
  # Hand-built allowlist, matching Letflow.Routers.Instances' own
  # attachment_json/1 precedent -- never a raw Jason.Encoder derivation over
  # %EntityAttachment{}, which would leak __meta__/tenant_id/content_hash.
  # No FieldGrants redaction step (design §5 INV-2) -- this is a fixed,
  # code-defined column set, not a tenant-authored field_values document.
  @spec record_attachment_json(EntityAttachment.t()) :: map()
  defp record_attachment_json(%EntityAttachment{} = attachment) do
    %{
      "id" => attachment.id,
      "entity_type" => attachment.entity_type,
      "record_id" => attachment.record_id,
      "file_name" => attachment.file_name,
      "content_type" => attachment.content_type,
      "byte_size" => attachment.byte_size,
      "uploaded_by" => attachment.uploaded_by,
      "description" => attachment.description,
      "created_at" => DateTime.to_iso8601(attachment.created_at)
    }
  end
end
