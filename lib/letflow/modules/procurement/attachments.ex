defmodule Letflow.Modules.Procurement.Attachments do
  @moduledoc """
  Files on a purchase request (GH #3503, REQ-626 part A): `attach/4`, `replace/5`, `list/4` and
  `download/5`. The bytes live in the content-addressed store (`repository_artifacts`, one row per
  hash); `procurement_attachments` holds one link row per file per version. The module is the one
  writer of that table, insert only (a trigger refuses update and delete).

  Part A works on the requester's **open draft**. A request that has been submitted has no open
  draft, so attach and replace answer `{:error, :not_draft}`; the new-version transaction is part B.

  Every function takes `prefix` first (the caller's tenant schema, INV-1) and the authenticated user
  as `actor`. Permissions are NOT checked here: the router owns them. Visibility is (INV-5): a
  document that is absent, malformed, of another type or of another tenant is `{:error, :not_found}`;
  so is a mutation by anyone but the requester, and a read by anyone who is neither the requester
  nor a decider (`decider?: true`, computed by the router from `ProcurementRequestDecide`).

  `attach/4` order: load and requester check, open draft, shape, content type, size (25 MiB, the
  same limit as `Letflow.Repository.Attachments`), virus scan (outside the transaction, no lock held),
  then one transaction: lock the document row (the row `Documents.issue/2` locks), re-read the open
  draft, store the bytes, insert the link row, insert the audit entry. A refusal writes nothing, not
  even the byte row, and is counted on `[:letflow, :procurement, :refused]` (decision 0056 D9).

  Slots: the first row of a slot has `slot_id == id`; a replacement has the same `slot_id`, the same
  `version_no` and `replaces_id` set to the row it replaces, so a slot is a linear chain whose head is
  the current file. Two partial unique indexes keep it linear (see the migration header for why this
  is not one unique index on `(document_id, version_no, slot_id)`).

  The content hash never leaves this module. Procurement attachments are not counted in
  `get_storage_usage/1` and not refused by the storage allowance (open question of the requirement).
  """

  import Ecto.Query

  require Logger

  alias Ecto.Adapters.SQL
  alias Letflow.Audit
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Modules.Procurement.Attachment
  alias Letflow.Modules.Procurement.Decisions
  alias Letflow.Repo
  alias Letflow.Repository
  alias Letflow.Repository.Artifact
  alias Letflow.TenantProvisioning

  @type_key "purchase_request"
  # Must equal @max_upload_bytes of Letflow.Repository.Attachments (a test pins the two together).
  @max_bytes 26_214_400
  @max_name 255

  @doc "Attaches a file to the requester's open draft; see the moduledoc for the error terms."
  def attach(prefix, actor, document_id, params),
    do: mutate(:attach, prefix, actor, document_id, nil, params)

  @doc "Replaces the current file of `slot_id` in the open draft with a new file."
  def replace(prefix, actor, document_id, slot_id, params),
    do: mutate(:replace, prefix, actor, document_id, slot_id, params)

  @doc """
  The files of one version, replaced rows left out. `opts`: `decider?` (boolean) and `version_no`
  (nil for the open draft, else the current issued version).
  """
  def list(prefix, actor, document_id, opts \\ []) when is_binary(prefix) do
    result =
      with {:ok, document} <- visible(prefix, actor, document_id, opts),
           {:ok, version_no} <- version_to_list(prefix, document, Keyword.get(opts, :version_no)) do
        entries =
          prefix
          |> heads_query(document.id, version_no)
          |> Repo.all(prefix: prefix)
          |> Enum.map(&public/1)

        {:ok, %{document_id: document.id, version_no: version_no, attachments: entries}}
      end

    Decisions.count_refusal(result, :list_attachments, prefix)
  end

  @doc "The bytes of one attachment of the request, with the stored file name and content type."
  def download(prefix, actor, document_id, attachment_id, opts \\ []) when is_binary(prefix) do
    result =
      with {:ok, document} <- visible(prefix, actor, document_id, opts),
           {:ok, id} <- cast_uuid(attachment_id),
           {%Attachment{} = row, content} <- stored(prefix, document.id, id) do
        {:ok, %{file_name: row.file_name, content_type: row.content_type, content: content}}
      else
        {:error, _reason} = error -> error
        _other -> {:error, :not_found}
      end

    Decisions.count_refusal(result, :download_attachment, prefix)
  end

  # -- attach and replace -----------------------------------------------------------------------

  defp mutate(kind, prefix, actor, document_id, slot_id, params) when is_binary(prefix) do
    result =
      with {:ok, document} <- requester_document(prefix, actor, document_id),
           {:ok, slot} <- slot_for(kind, slot_id),
           {:ok, _draft} <- open_draft(prefix, document.id),
           {:ok, file} <- shape(params),
           :ok <- scan(file) do
        transact(kind, prefix, actor, document.id, slot, file)
      end

    Decisions.count_refusal(result, count_action(kind), prefix)
  end

  defp count_action(:attach), do: :attach_attachment
  defp count_action(:replace), do: :replace_attachment

  defp slot_for(:attach, _slot_id), do: {:ok, nil}

  defp slot_for(:replace, slot_id) do
    case cast_uuid(slot_id) do
      {:ok, slot} -> {:ok, slot}
      _error -> {:error, :not_found}
    end
  end

  defp shape(params) when is_map(params) do
    get = fn key -> Map.get(params, key, Map.get(params, Atom.to_string(key))) end
    name = get.(:file_name)
    type = get.(:content_type)
    bytes = get.(:bytes)

    name_ok? =
      is_binary(name) and String.valid?(name) and String.trim(name) != "" and
        String.length(name) <= @max_name

    cond do
      not name_ok? ->
        {:error, {:validation, [%{field: "file_name", code: "invalid"}]}}

      not is_binary(bytes) ->
        {:error, {:validation, [%{field: "content_base64", code: "invalid"}]}}

      not is_binary(type) or
          not MapSet.member?(Repository.Attachments.allowed_content_types(), type) ->
        {:error, :content_type_not_allowed}

      byte_size(bytes) > @max_bytes ->
        {:error, :file_too_large}

      true ->
        {:ok, %{file_name: name, content_type: type, bytes: bytes}}
    end
  end

  defp shape(_params), do: {:error, {:validation, [%{field: "file_name", code: "invalid"}]}}

  defp scan(%{bytes: bytes, content_type: type}) do
    case Repository.Attachments.scan_content(bytes, type) do
      {:ok, :clean} -> :ok
      # the verdict string is dropped on purpose: not in the response, not in a log with the name
      {:ok, :infected, _verdict} -> {:error, :infected}
      {:error, _reason} -> {:error, :scan_unavailable}
    end
  end

  defp transact(kind, prefix, actor, document_id, slot, file) do
    case Repo.transaction(fn -> write(kind, prefix, actor, document_id, slot, file) end) do
      {:ok, view} -> {:ok, view}
      {:error, {:audit_failed, _reason}} -> {:error, :audit_failed}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :lock_not_available} ->
          {:error, :busy}

        %{code: :query_canceled} ->
          {:error, :busy}

        %{code: :unique_violation} ->
          {:error, :slot_conflict}

        # Audit.insert_entry/3 and the byte upsert raise on a database failure; the transaction is
        # already rolled back, nothing was written (INV-8).
        other ->
          Logger.error("procurement attachment failed: #{inspect(Map.get(other, :code))}")
          {:error, :audit_failed}
      end
  end

  defp write(kind, prefix, actor, document_id, slot, file) do
    # constant SQL, no table: the same bounds as Decisions.record/3, scoped to this transaction
    SQL.query!(Repo, "SET LOCAL lock_timeout = '2s'")
    SQL.query!(Repo, "SET LOCAL statement_timeout = '15s'")

    lock_document(prefix, document_id)

    with {:ok, draft} <- open_draft(prefix, document_id),
         {:ok, head} <- head_for(kind, prefix, document_id, draft.version_no, slot),
         {:ok, tenant_id} <- tenant(prefix) do
      hash = :crypto.hash(:sha256, file.bytes)
      size = byte_size(file.bytes)

      case Repository.upsert_content(prefix, tenant_id, hash, file.content_type, size, file.bytes) do
        {:ok, _artifact} -> :ok
        {:error, _changeset} -> Repo.rollback(:audit_failed)
      end

      id = Ecto.UUID.generate()

      attrs = %{
        id: id,
        document_id: document_id,
        version_no: draft.version_no,
        slot_id: if(head, do: head.slot_id, else: id),
        content_hash: hash,
        file_name: file.file_name,
        content_type: file.content_type,
        byte_size: size,
        uploaded_by: actor,
        uploaded_at: DateTime.utc_now(),
        replaces_id: if(head, do: head.id)
      }

      row =
        case attrs |> Attachment.insert_changeset() |> Repo.insert(prefix: prefix) do
          {:ok, row} -> row
          {:error, _changeset} -> Repo.rollback(:slot_conflict)
        end

      audit(kind, prefix, actor, row)
      public(row)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_document(prefix, document_id) do
    Repo.one(from(d in Document, where: d.id == ^document_id, lock: "FOR UPDATE"),
      prefix: prefix
    )
  end

  defp head_for(:attach, _prefix, _document_id, _version_no, _slot), do: {:ok, nil}

  defp head_for(:replace, prefix, document_id, version_no, slot) do
    query =
      from(a in heads_query(prefix, document_id, version_no), where: a.slot_id == ^slot)

    case Repo.one(query, prefix: prefix) do
      nil -> {:error, :not_found}
      head -> {:ok, head}
    end
  end

  defp audit(kind, prefix, actor, row) do
    {action, extra} =
      case kind do
        :attach -> {"procurement.attachment_added", %{}}
        :replace -> {"procurement.attachment_replaced", %{"replaces_id" => row.replaces_id}}
      end

    entry = %{
      actor_id: actor,
      action: action,
      resource_type: "purchase_request",
      resource_id: row.document_id,
      before_state: nil,
      after_state:
        Map.merge(
          %{
            "attachment_id" => row.id,
            "slot_id" => row.slot_id,
            "version_no" => row.version_no,
            "byte_size" => row.byte_size
          },
          extra
        )
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  # -- reads --------------------------------------------------------------------------------------

  # The newest row of each slot of one version: a row that no other row replaces.
  defp heads_query(_prefix, document_id, version_no) do
    from(a in Attachment,
      as: :a,
      where: a.document_id == ^document_id and a.version_no == ^version_no,
      where:
        not exists(from(r in Attachment, where: r.replaces_id == parent_as(:a).id, select: 1)),
      order_by: [asc: a.uploaded_at, asc: a.id]
    )
  end

  defp stored(prefix, document_id, attachment_id) do
    Repo.one(
      from(a in Attachment,
        join: art in Artifact,
        on: art.content_hash == a.content_hash,
        where: a.id == ^attachment_id and a.document_id == ^document_id,
        select: {a, art.content}
      ),
      prefix: prefix
    )
  end

  defp open_draft(prefix, document_id) do
    query =
      from(v in DocumentVersion,
        where: v.document_id == ^document_id and v.status == :draft,
        limit: 1
      )

    case Repo.one(query, prefix: prefix) do
      nil -> {:error, :not_draft}
      draft -> {:ok, draft}
    end
  end

  defp version_to_list(prefix, document, nil) do
    case open_draft(prefix, document.id) do
      {:ok, draft} ->
        {:ok, draft.version_no}

      {:error, :not_draft} ->
        current_version_no(prefix, document)
    end
  end

  defp version_to_list(prefix, document, requested) do
    with {:ok, no} <- parse_version(requested) do
      query =
        from(v in DocumentVersion,
          where: v.document_id == ^document.id and v.version_no == ^no and v.status != :discarded
        )

      if Repo.exists?(query, prefix: prefix), do: {:ok, no}, else: {:error, :not_found}
    end
  end

  defp current_version_no(_prefix, %Document{current_version: nil}), do: {:error, :not_found}

  defp current_version_no(prefix, %Document{current_version: version_id}) do
    query = from(v in DocumentVersion, where: v.id == ^version_id and v.status != :discarded)

    case Repo.one(query, prefix: prefix) do
      %DocumentVersion{version_no: no} -> {:ok, no}
      nil -> {:error, :not_found}
    end
  end

  defp parse_version(no) when is_integer(no) and no > 0, do: {:ok, no}

  defp parse_version(text) when is_binary(text) do
    case Integer.parse(text) do
      {no, ""} when no > 0 -> {:ok, no}
      _other -> {:error, {:validation, [%{field: "version_no", code: "invalid"}]}}
    end
  end

  defp parse_version(_other),
    do: {:error, {:validation, [%{field: "version_no", code: "invalid"}]}}

  # -- ownership ------------------------------------------------------------------------------------

  defp requester_document(prefix, actor, document_id) do
    with {:ok, document} <- load(prefix, document_id),
         true <- Decisions.requester_of(prefix, document.id) == actor do
      {:ok, document}
    else
      _other -> {:error, :not_found}
    end
  end

  defp visible(prefix, actor, document_id, opts) do
    with {:ok, document} <- load(prefix, document_id),
         true <-
           Decisions.requester_of(prefix, document.id) == actor or
             Keyword.get(opts, :decider?, false) == true do
      {:ok, document}
    else
      _other -> {:error, :not_found}
    end
  end

  defp load(prefix, document_id) do
    with {:ok, id} <- cast_uuid(document_id),
         {:ok, _tenant_id} <- tenant(prefix),
         %Document{type_key: @type_key} = document <- Repo.get(Document, id, prefix: prefix) do
      {:ok, document}
    else
      _other -> {:error, :not_found}
    end
  end

  defp tenant(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, tenant_id} -> {:ok, tenant_id}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_value), do: :error

  # The only shape that leaves the module: no content hash.
  defp public(%Attachment{} = row) do
    %{
      attachment_id: row.id,
      slot_id: row.slot_id,
      version_no: row.version_no,
      file_name: row.file_name,
      content_type: row.content_type,
      byte_size: row.byte_size,
      uploaded_by: row.uploaded_by,
      uploaded_at: row.uploaded_at,
      replaces_id: row.replaces_id
    }
  end
end
