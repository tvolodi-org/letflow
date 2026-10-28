defmodule Letflow.Modules.Procurement.PurchaseRequests do
  @moduledoc """
  Operations on a purchase request (GH #3162, REQ-544 parts 1 and 2): `create/3`, `update_draft/4`,
  `submit/3`, `submit_for_bpm/3` and `revise/4`, on top of `Letflow.Documents` (the document type
  `purchase_request`).

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
  (INV-5). Permissions are NOT checked here, like `Documents` itself: the part 2 router
  (`Letflow.Modules.Procurement.Router`) owns `ProcurementRequestWrite` and is this module's only caller.
  `submit_for_bpm/3` (part 2) is the BPM form of submit; the decisions live in
  `Letflow.Modules.Procurement.Decisions`.
  """

  import Ecto.Query

  alias Letflow.Documents
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Org
  alias Letflow.Modules.Procurement.Decisions
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
  The BPM submit operation (GH #3162, REQ-544 part 2): `params` is `%{document_id, version_no,
  content_hash, idempotency_key}`. Own request only (`owned/3`, INV-5). The key is checked for
  shape but not stored: a submit leaves no row of its own, the version state is the record that it
  happened, so a retry is recognised from that state (the issue of one version is unique).

  After the ownership check, in this order:

    1. a missing or cancelled version, or an open draft with a hash, is `:binding_refused`;
    2. the open draft with `content_hash: nil` is issued;
    3. an `:issued` (or later `:superseded`) version with a nil hash or its own stored hash is the
       first result again (`replayed: true`, nothing written); any other hash is `:binding_refused`;
    4. `Documents.issue/2` answering `:no_draft` (a concurrent first submit won the row lock)
       re-reads the version and applies rule 3;
    5. `{:error, :busy}` from `Documents.issue/2` is returned as is, nothing written.

  Replaying a superseded version (the requester revised after submitting) is accepted: only the
  owner reaches that branch and nothing is written. Refusals are counted, never audited (D9).
  """
  def submit_for_bpm(prefix, actor_id, params) when is_binary(prefix) and is_map(params) do
    with :ok <- tenant(prefix),
         {:ok, input} <- submit_shape(params),
         {:ok, document, _version} <- owned(prefix, document_id_of(params), actor_id) do
      submit_version(prefix, actor_id, document, input)
    end
    |> Decisions.count_refusal(:submit, prefix)
  end

  def submit_for_bpm(_prefix, _actor_id, _params), do: {:error, :not_found}

  defp submit_version(prefix, actor_id, document, input) do
    case version_of(prefix, document.id, input.version_no) do
      %DocumentVersion{status: :draft} when is_nil(input.content_hash) ->
        issue_for_bpm(prefix, actor_id, document, input)

      version ->
        replay_submit(prefix, document.id, version, input)
    end
  end

  defp issue_for_bpm(prefix, actor_id, document, input) do
    case Documents.issue(prefix, %{document_id: document.id, actor_id: actor_id}) do
      {:ok, issued} ->
        {:ok, Map.merge(issued_result(issued), %{state: :submitted, replayed: false})}

      {:error, :no_draft} ->
        replay_submit(
          prefix,
          document.id,
          version_of(prefix, document.id, input.version_no),
          input
        )

      {:error, :busy} ->
        {:error, :busy}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_submit(
         prefix,
         document_id,
         %DocumentVersion{status: status, content_hash: stored} = version,
         input
       )
       when status in [:issued, :superseded] and
              (is_nil(input.content_hash) or input.content_hash == stored) do
    document = Repo.get!(Document, document_id, prefix: prefix)

    {:ok,
     Map.merge(issued_result(%{document: document, version: version}), %{
       state: :submitted,
       replayed: true
     })}
  end

  defp replay_submit(_prefix, _document_id, _version, _input), do: {:error, :binding_refused}

  defp document_id_of(params), do: Map.get(params, :document_id, params["document_id"])

  defp version_of(prefix, document_id, version_no) do
    Repo.one(
      from(v in DocumentVersion,
        where: v.document_id == ^document_id and v.version_no == ^version_no
      ),
      prefix: prefix
    )
  end

  defp submit_shape(params) do
    get = fn key -> Map.get(params, key, Map.get(params, Atom.to_string(key))) end
    version_no = get.(:version_no)
    hash = get.(:content_hash)
    key = get.(:idempotency_key)

    errors =
      [
        {"version_no", is_integer(version_no) and version_no > 0},
        {"content_hash", is_nil(hash) or (is_binary(hash) and hash =~ ~r/\A[0-9a-f]{64}\z/)},
        {"idempotency_key", is_binary(key) and key =~ ~r/\A[A-Za-z0-9._:-]{1,128}\z/}
      ]
      |> Enum.reject(fn {_field, ok?} -> ok? end)
      |> Enum.map(fn {field, _ok?} -> %{field: field, code: "invalid"} end)

    if errors == [],
      do: {:ok, %{version_no: version_no, content_hash: hash, idempotency_key: key}},
      else: {:error, {:validation, errors}}
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
