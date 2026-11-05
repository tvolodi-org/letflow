defmodule Letflow.Modules.Procurement.Attachments do
  @moduledoc """
  Files on a purchase request (GH #3503, REQ-626 part A): `attach/4`, `replace/5`, `list/4` and
  `download/5`. The bytes live in the content-addressed store (`repository_artifacts`, one row per
  hash); `procurement_attachments` holds one link row per file per version. The module is the one
  writer of that table, insert only (a trigger refuses update and delete).

  On the requester's **open draft** (part A) attach and replace write into that draft. On a
  **submitted** request (part B) they run one transaction under the document row lock: a new
  version N+1 is made from the issued version N (`Documents.new_version_from_current/2`), the files
  of N are copied as new rows of N+1 (same bytes, no byte write), the new or replacing file is
  added, and N+1 is issued (`Documents.issue/2`). Version N, its rows and its hash are never
  touched, so an approver of N still inspects exactly N; an approval of N does not cover N+1.
  A request whose current version is neither a draft nor issued (for example cancelled) answers
  `{:error, :not_draft}`.

  Every function takes `prefix` first (the caller's tenant schema, INV-1) and the authenticated user
  as `actor`. Permissions are NOT checked here: the router owns them. Visibility is (INV-5): a
  document that is absent, malformed, of another type or of another tenant is `{:error, :not_found}`;
  so is a mutation by anyone but the requester, and a read by anyone who is neither the requester
  nor a decider (`decider?: true`, computed by the router from `ProcurementRequestDecide`).

  `attach/4` order: load and requester check, target (draft or issued), shape, content type, size (25 MiB, the
  same limit as `Letflow.Repository.Attachments`), virus scan (outside the transaction, no lock held),
  then one transaction: lock the document row (the row `Documents.issue/2` locks), re-read the
  target, store the bytes, insert the link row, insert the audit entry. A refusal writes nothing, not
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
  alias Letflow.Documents
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

  @doc "Attaches a file to the requester's open draft, or as a new issued version when submitted; see the moduledoc for the error terms."
  def attach(prefix, actor, document_id, params),
    do: mutate(:attach, prefix, actor, document_id, nil, params)

  @doc "Replaces the current file of `slot_id` (in the open draft, or as a new issued version when submitted)."
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
           {:ok, _target} <- target(prefix, document),
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

    document = lock_document(prefix, document_id)

    case open_draft(prefix, document_id) do
      {:ok, draft} ->
        write_in_draft(kind, prefix, actor, document_id, slot, file, draft)

      {:error, :not_draft} ->
        case issued_current(prefix, document) do
          {:ok, current} ->
            write_new_version(kind, prefix, actor, document_id, slot, file, current)

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  # Part A: the open draft takes the row directly.
  defp write_in_draft(kind, prefix, actor, document_id, slot, file, draft) do
    with {:ok, head} <- head_for(kind, prefix, document_id, draft.version_no, slot),
         {:ok, tenant_id} <- tenant(prefix) do
      hash = store_bytes(prefix, tenant_id, file)
      row = insert_row!(prefix, document_id, draft.version_no, head, hash, file, actor)
      audit(kind, prefix, actor, row, %{})
      public(row)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Part B: version N is issued. New version N+1 = copies of N's files + the new or replacing file,
  # issued in the same transaction. Rows go in before `issue` so a refused issue rolls them back.
  defp write_new_version(kind, prefix, actor, document_id, slot, file, current) do
    previous = prefix |> heads_query(document_id, current.version_no) |> Repo.all(prefix: prefix)
    replaced = if kind == :replace, do: Enum.find(previous, &(&1.slot_id == slot))

    if kind == :replace and is_nil(replaced), do: Repo.rollback(:not_found)

    draft =
      case Documents.new_version_from_current(prefix, %{document_id: document_id, actor_id: actor}) do
        {:ok, draft} ->
          draft

        {:error, reason} when reason in [:no_issued_version, :draft_exists] ->
          Repo.rollback(:not_draft)

        {:error, reason} ->
          Repo.rollback(reason)
      end

    tenant_id =
      case tenant(prefix) do
        {:ok, tenant_id} -> tenant_id
        {:error, reason} -> Repo.rollback(reason)
      end

    hash = store_bytes(prefix, tenant_id, file)
    carried = Enum.reject(previous, &(&1 == replaced))

    # copies in the order of N, so the list order (uploaded_at, id) stays stable
    written =
      for old <- previous do
        if old == replaced,
          do: insert_row!(prefix, document_id, draft.version_no, replaced, hash, file, actor),
          else: insert_copy!(prefix, draft.version_no, old)
      end

    row =
      if replaced,
        do: Enum.find(written, &(&1.replaces_id == replaced.id)),
        else: insert_row!(prefix, document_id, draft.version_no, nil, hash, file, actor)

    case Documents.issue(prefix, %{document_id: document_id, actor_id: actor}) do
      {:ok, _issued} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    audit(kind, prefix, actor, row, %{
      "previous_version_no" => current.version_no,
      "carried_count" => length(carried)
    })

    public(row)
  end

  defp store_bytes(prefix, tenant_id, file) do
    hash = :crypto.hash(:sha256, file.bytes)
    size = byte_size(file.bytes)

    case Repository.upsert_content(prefix, tenant_id, hash, file.content_type, size, file.bytes) do
      {:ok, _artifact} -> hash
      {:error, _changeset} -> Repo.rollback(:audit_failed)
    end
  end

  defp insert_row!(prefix, document_id, version_no, head, hash, file, actor) do
    id = Ecto.UUID.generate()

    insert!(prefix, %{
      id: id,
      document_id: document_id,
      version_no: version_no,
      slot_id: if(head, do: head.slot_id, else: id),
      content_hash: hash,
      file_name: file.file_name,
      content_type: file.content_type,
      byte_size: byte_size(file.bytes),
      uploaded_by: actor,
      uploaded_at: DateTime.utc_now(),
      replaces_id: if(head, do: head.id)
    })
  end

  defp insert_copy!(prefix, version_no, %Attachment{} = old) do
    insert!(prefix, %{
      id: Ecto.UUID.generate(),
      document_id: old.document_id,
      version_no: version_no,
      slot_id: old.slot_id,
      content_hash: old.content_hash,
      file_name: old.file_name,
      content_type: old.content_type,
      byte_size: old.byte_size,
      uploaded_by: old.uploaded_by,
      uploaded_at: old.uploaded_at,
      replaces_id: nil
    })
  end

  defp insert!(prefix, attrs) do
    case attrs |> Attachment.insert_changeset() |> Repo.insert(prefix: prefix) do
      {:ok, row} -> row
      {:error, _changeset} -> Repo.rollback(:slot_conflict)
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

  defp audit(kind, prefix, actor, row, submitted_extra) do
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
        %{
          "attachment_id" => row.id,
          "slot_id" => row.slot_id,
          "version_no" => row.version_no,
          "byte_size" => row.byte_size
        }
        |> Map.merge(extra)
        |> Map.merge(submitted_extra)
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  # -- reads --------------------------------------------------------------------------------------

  # The newest row of each slot of one version: a row that no other row of the SAME version replaces
  # (the replacing row of version N+1 points at the row of N and must not hide it from N).
  defp heads_query(_prefix, document_id, version_no) do
    from(a in Attachment,
      as: :a,
      where: a.document_id == ^document_id and a.version_no == ^version_no,
      where:
        not exists(
          from(r in Attachment,
            where: r.replaces_id == parent_as(:a).id and r.version_no == parent_as(:a).version_no,
            select: 1
          )
        ),
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

  # Early refusal, no lock: which branch will apply. Decided again under the lock in write/6.
  defp target(prefix, document) do
    case open_draft(prefix, document.id) do
      {:ok, _draft} ->
        {:ok, :draft}

      {:error, :not_draft} ->
        with {:ok, _current} <- issued_current(prefix, document), do: {:ok, :issued}
    end
  end

  defp issued_current(_prefix, %Document{current_version: nil}), do: {:error, :not_draft}

  defp issued_current(prefix, %Document{current_version: version_id}) do
    case Repo.get(DocumentVersion, version_id, prefix: prefix) do
      %DocumentVersion{status: :issued} = version -> {:ok, version}
      _other -> {:error, :not_draft}
    end
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
