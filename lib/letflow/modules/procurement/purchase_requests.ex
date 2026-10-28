defmodule Letflow.Modules.Procurement.PurchaseRequests do
  @moduledoc """
  Operations on a purchase request (GH #3162, REQ-544 part 1): `create/3`, `update_draft/4`,
  `submit/3` and `revise/4`, on top of `Letflow.Documents` (the document type `purchase_request`).

  Every function takes `prefix` first: it comes from the authenticated tenant, never from HTTP
  input (INV-1). Validation (`Letflow.Modules.Procurement.PurchaseRequest.build/3`) runs before any
  write, so a rejected request saves nothing. The requester is the authenticated `actor_id`.

  A request is "submitted" when its draft is issued: one document, one number, one content hash. A
  change after submission is a new version made by `Documents.new_version_from_current/2` and issued
  in the same transaction; the submitted version is never edited (the issue of version N+1 only marks
  version N superseded, its content and hash are untouched). The department is the document's
  issuing org unit and cannot change in a revision.

  Ownership: only the requester may update, submit or revise. A document that is absent, malformed,
  of another type, of another tenant or owned by someone else gives the same `{:error, :not_found}`
  (INV-5). Permissions are NOT checked here, like `Documents` itself: the part 2 router or BPM
  handler owns `ProcurementRequestWrite` and must be this module's only caller.
  """

  import Ecto.Query

  alias Letflow.Documents
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Org
  alias Letflow.Modules.Procurement.PurchaseRequest
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type_key "purchase_request"

  @doc "Validates and saves a new draft request. Nothing is saved when validation fails."
  def create(prefix, actor_id, params) do
    with :ok <- tenant(prefix),
         {:ok, content} <- PurchaseRequest.build(params, actor_id, lookups(prefix)),
         {:ok, %{document: document, version: version}} <-
           Documents.create_draft(
             prefix,
             %{
               type_key: @type_key,
               issuing_org_unit_id: content["department_id"],
               content: content
             },
             actor_id
           ) do
      {:ok,
       %{
         document_id: document.id,
         version_no: version.version_no,
         status: :draft,
         content: content
       }}
    end
  end

  @doc "Replaces the content of the open draft of the requester's own request."
  def update_draft(prefix, actor_id, document_id, params) do
    with :ok <- tenant(prefix),
         {:ok, document, _version} <- owned(prefix, document_id, actor_id),
         {:ok, content} <- build_for(prefix, document, actor_id, params),
         {:ok, version} <- Documents.edit_draft(prefix, document.id, content, actor_id) do
      {:ok,
       %{
         document_id: document.id,
         version_no: version.version_no,
         status: :draft,
         content: content
       }}
    end
  end

  @doc "Submits (issues) the requester's own draft: number and content hash are set by `Documents`."
  def submit(prefix, actor_id, document_id) do
    with :ok <- tenant(prefix),
         {:ok, document, _version} <- owned(prefix, document_id, actor_id),
         {:ok, issued} <- Documents.issue(prefix, %{document_id: document.id, actor_id: actor_id}) do
      {:ok, issued_result(issued)}
    end
  end

  @doc """
  Changes a submitted request: validates the new content, then in one transaction starts the next
  version, sets its content and issues it. Any failure rolls all three back, so no half-made draft
  survives and the submitted version stays current.
  """
  def revise(prefix, actor_id, document_id, params) do
    with :ok <- tenant(prefix),
         {:ok, document, _version} <- owned(prefix, document_id, actor_id),
         {:ok, content} <- build_for(prefix, document, actor_id, params) do
      args = %{document_id: document.id, actor_id: actor_id}

      Repo.transaction(fn ->
        with {:ok, _draft} <- Documents.new_version_from_current(prefix, args),
             {:ok, _draft} <- Documents.edit_draft(prefix, document.id, content, actor_id),
             {:ok, issued} <- Documents.issue(prefix, args) do
          issued_result(issued)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # -- helpers -----------------------------------------------------------------------------

  defp tenant(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, _tenant_id} -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # The department is the document's issuing org unit and cannot change after creation.
  defp build_for(prefix, document, actor_id, params) do
    with {:ok, content} <- PurchaseRequest.build(params, actor_id, lookups(prefix)) do
      if content["department_id"] == document.issuing_org_unit_id,
        do: {:ok, content},
        else: {:error, {:validation, [%{field: "department_id", code: "immutable"}]}}
    end
  end

  defp owned(prefix, document_id, actor_id) do
    with {:ok, id} <- Ecto.UUID.cast(document_id),
         {:ok, actor} <- Ecto.UUID.cast(actor_id),
         %Document{type_key: @type_key} = document <- Repo.get(Document, id, prefix: prefix),
         %DocumentVersion{content: %{"requester" => ^actor}} = version <-
           latest_version(prefix, id) do
      {:ok, document, version}
    else
      _other -> {:error, :not_found}
    end
  end

  # The newest version that was not discarded: the open draft, else the current issued one.
  defp latest_version(prefix, document_id) do
    Repo.one(
      from(v in DocumentVersion,
        where: v.document_id == ^document_id and v.status != :discarded,
        order_by: [desc: v.version_no],
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp issued_result(%{document: document, version: version}) do
    %{
      document_id: document.id,
      version_no: version.version_no,
      content_hash: version.content_hash,
      number: document.number
    }
  end

  defp lookups(prefix) do
    %{
      unit: fn id -> reference(CatalogItems.lookup(prefix, id), "catalog_uom") end,
      department: fn id -> reference(Org.lookup(prefix, id), "org_unit") end
    }
  end

  defp reference({:ok, %{"entity_type" => type, "active" => true, "record_id" => id}}, type),
    do: {:ok, id}

  defp reference({:ok, %{"entity_type" => type}}, type), do: :retired
  defp reference(_other, _type), do: :unknown
end
