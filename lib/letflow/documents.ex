defmodule Letflow.Documents do
  @moduledoc """
  The versioned-documents service, part 1 (REQ-542, GH #3164, decision 0056 D1, D3, D8, D9):
  type registration, drafts and a new draft from the current issued version. Issuing, numbering,
  supersede and cancel are REQ-543.

  Every function takes the tenant schema name as `prefix` first (INV-1): the tenant comes from
  the prefix, never from a caller-supplied id, and every `Repo` call carries `prefix:`. A document
  id that is absent, malformed or belongs to another tenant gives the same `{:error, :not_found}`.

  Like `Letflow.Documents.Retention` and `Letflow.Documents.Hold`, these functions check no
  permission and no caller scope (for instance that the caller may use `issuing_org_unit_id`).
  The first caller (the documents route, or REQ-544) owns both and must stay their only caller.

  `register_type/3` is meant to be called from a module's `on_install/3`, which runs inside the
  install transaction: a refusal there rolls the whole install back (decision 0056 D1). No
  function accepts a content hash; hashes are made by `Letflow.Documents.Canonical` at issue time.
  A refusal writes no audit entry; a database trigger refusal is rescued and returned, never raised.

  `declared_fields` of a type is `%{entity_type => [field_name]}` (fields the template prints from
  that source entity type), plus the reserved key `"_free"` for fields of a document that has no
  source entity: given as a list in the input, each field marked `"public"` in `attrs.sensitivity`,
  and stored as the map `%{field_name => "public"}`. REQ-543 re-checks both forms at issue time.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Documents.Canonical
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentType
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Documents.OrgResolver
  alias Letflow.Modules.Catalog
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @key_re ~r/^[a-z][a-z0-9_.]{0,63}$/
  @free "_free"
  @type_columns [
    :owner_module,
    :numbering_scope,
    :number_prefix,
    :number_pad,
    :legal_entity_required,
    :declared_fields,
    :template_ref
  ]

  @type error :: {:error, term()}

  # ---------------------------------------------------------------------------------------
  # register_type/3
  # ---------------------------------------------------------------------------------------

  @doc """
  Registers (or re-registers) a document type. `attrs` (atom keys): `key`, `owner_module`,
  `numbering_scope` (`:year | :none`), `number_prefix`, `number_pad`, `legal_entity_required`,
  `declared_fields`, optional `template_ref` and `sensitivity` (see the moduledoc). `ctx` is the
  `on_install/3` context (any map with `actor_id`).

  A restricted field (a row of `entity_field_restrictions`, or a free field that is not marked
  public) gives `{:error, {:restricted_field, entity_type, field}}`. A type that requires a legal
  entity gives `{:error, :legal_entity_resolver_unavailable}` while the default resolver is
  active. Registering an equal type again is a no-op. A changed registration of a key that has
  documents gives `{:error, :document_type_frozen}`; another `owner_module` gives
  `{:error, :type_owned_by_other_module}`.
  """
  @spec register_type(String.t(), map(), map()) :: {:ok, %DocumentType{}} | error()
  def register_type(prefix, attrs, ctx)
      when is_binary(prefix) and is_map(attrs) and is_map(ctx) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         :ok <- no_hash(attrs),
         {:ok, actor_id} <- actor(Map.get(ctx, :actor_id)),
         {:ok, type} <- validate_type(attrs),
         {:ok, resolver} <- Catalog.document_org_resolver(),
         :ok <- resolver_available(type.legal_entity_required, resolver),
         :ok <- check_restricted(prefix, type.declared_fields, Map.get(attrs, :sensitivity)) do
      transact(fn -> upsert_type(prefix, tenant_id, actor_id, type) end)
    end
  end

  defp validate_type(attrs) do
    with {:ok, key} <-
           check(
             is_binary(attrs[:key]) and Regex.match?(@key_re, attrs[:key]),
             :invalid_key,
             attrs[:key]
           ),
         :ok <-
           check(
             is_binary(attrs[:owner_module]) and attrs[:owner_module] != "",
             :invalid_owner_module
           ),
         :ok <- check(attrs[:numbering_scope] in [:year, :none], :invalid_numbering_scope),
         :ok <- check(is_binary(attrs[:number_prefix]), :invalid_number_prefix),
         :ok <-
           check(is_integer(attrs[:number_pad]) and attrs[:number_pad] >= 0, :invalid_number_pad),
         :ok <- check(is_boolean(attrs[:legal_entity_required]), :invalid_legal_entity_required),
         :ok <-
           check(
             is_nil(attrs[:template_ref]) or is_binary(attrs[:template_ref]),
             :invalid_template_ref
           ),
         {:ok, fields} <- declared_fields(attrs[:declared_fields]) do
      {:ok,
       %{
         key: key,
         owner_module: attrs.owner_module,
         numbering_scope: attrs.numbering_scope,
         number_prefix: attrs.number_prefix,
         number_pad: attrs.number_pad,
         legal_entity_required: attrs.legal_entity_required,
         declared_fields: fields,
         template_ref: attrs[:template_ref]
       }}
    end
  end

  defp check(true, _reason), do: :ok
  defp check(_false, reason), do: {:error, {:unprocessable, reason}}
  defp check(true, _reason, value), do: {:ok, value}
  defp check(_false, reason, _value), do: {:error, {:unprocessable, reason}}

  # Input form: %{entity_type => [field]} (and "_free" => [field]). Stored form of "_free" is
  # decided after the restricted check, which needs the sensitivity marks.
  defp declared_fields(fields) when is_map(fields) and not is_struct(fields) do
    valid? =
      Enum.all?(fields, fn {type, names} ->
        is_binary(type) and type != "" and is_list(names) and
          Enum.all?(names, &(is_binary(&1) and &1 != ""))
      end)

    if valid?, do: {:ok, fields}, else: {:error, {:unprocessable, :invalid_declared_fields}}
  end

  defp declared_fields(_other), do: {:error, {:unprocessable, :invalid_declared_fields}}

  defp resolver_available(true, OrgResolver.Default),
    do: {:error, :legal_entity_resolver_unavailable}

  defp resolver_available(_required, _resolver), do: :ok

  # D8: a template may print no restricted field. Entity-sourced fields are looked up in the
  # tenant's `entity_field_restrictions`; free fields must be marked public.
  defp check_restricted(prefix, fields, sensitivity) do
    sensitivity = if is_map(sensitivity), do: sensitivity, else: %{}

    with :ok <- check_free(Map.get(fields, @free, []), sensitivity) do
      fields
      |> Map.delete(@free)
      |> Enum.sort()
      |> Enum.find_value(:ok, fn {entity_type, names} ->
        hit =
          from(r in "entity_field_restrictions",
            where: r.entity_type == ^entity_type and r.field_name in ^names,
            order_by: r.field_name,
            limit: 1,
            select: r.field_name
          )
          |> Repo.one(prefix: prefix)

        if hit, do: {:error, {:restricted_field, entity_type, hit}}
      end)
    end
  end

  defp check_free(names, sensitivity) do
    Enum.find_value(names, :ok, fn name ->
      if public?(Map.get(sensitivity, name)),
        do: nil,
        else: {:error, {:restricted_field, @free, name}}
    end)
  end

  defp public?(value), do: value in [:public, "public"]

  defp stored_fields(fields) do
    case Map.fetch(fields, @free) do
      {:ok, names} -> Map.put(fields, @free, Map.new(names, &{&1, "public"}))
      :error -> fields
    end
  end

  defp upsert_type(prefix, tenant_id, actor_id, type) do
    type = %{type | declared_fields: stored_fields(type.declared_fields)}

    {inserted, _} =
      Repo.insert_all(
        DocumentType,
        [
          type
          |> Map.put(:tenant_id, tenant_id)
          |> Map.put(:restricted_fields_allowed, false)
          |> Map.put(:inserted_at, now())
        ],
        prefix: prefix,
        on_conflict: :nothing,
        conflict_target: [:key]
      )

    row =
      Repo.one!(from(t in DocumentType, where: t.key == ^type.key, lock: "FOR UPDATE"),
        prefix: prefix
      )

    cond do
      inserted == 1 ->
        audit!(
          prefix,
          actor_id,
          "document.type_registered",
          "document_type",
          type.key,
          nil,
          type_state(type)
        )

        row

      row.owner_module != type.owner_module ->
        Repo.rollback(:type_owned_by_other_module)

      Map.take(row, @type_columns) == Map.take(type, @type_columns) ->
        row

      true ->
        changed = Map.take(type, @type_columns)

        from(t in DocumentType, where: t.key == ^type.key)
        |> Repo.update_all([set: Map.to_list(changed)], prefix: prefix)

        audit!(
          prefix,
          actor_id,
          "document.type_registered",
          "document_type",
          type.key,
          type_state(row),
          type_state(type)
        )

        Repo.one!(from(t in DocumentType, where: t.key == ^type.key), prefix: prefix)
    end
  end

  defp type_state(type) do
    %{
      "key" => type.key,
      "owner_module" => type.owner_module,
      "numbering_scope" => to_string(type.numbering_scope),
      "number_prefix" => type.number_prefix,
      "number_pad" => type.number_pad,
      "legal_entity_required" => type.legal_entity_required,
      "declared_field_count" =>
        type.declared_fields |> Map.values() |> Enum.map(&Enum.count/1) |> Enum.sum()
    }
  end

  # ---------------------------------------------------------------------------------------
  # create_draft/3
  # ---------------------------------------------------------------------------------------

  @doc """
  Creates a document with its version 1 as a draft. `attrs`: `type_key`, `issuing_org_unit_id`,
  `content` (a map that passes `Letflow.Documents.Canonical.canonicalize/1`), optional
  `source_ref` (map). The org unit must be active for the resolver; a legal-entity-bound type
  gets the entity from the resolver, any other type stores none. The document gets no number.
  """
  @spec create_draft(String.t(), map(), String.t()) ::
          {:ok, %{document: %Document{}, version: %DocumentVersion{}}} | error()
  def create_draft(prefix, attrs, actor_id) when is_binary(prefix) and is_map(attrs) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         :ok <- no_hash(attrs),
         {:ok, actor_id} <- actor(actor_id),
         {:ok, content} <- content(Map.get(attrs, :content)),
         :ok <- source_ref(Map.get(attrs, :source_ref)),
         {:ok, unit} <- org_unit(Map.get(attrs, :issuing_org_unit_id)),
         {:ok, type} <- fetch_type(prefix, Map.get(attrs, :type_key)),
         {:ok, resolver} <- Catalog.document_org_resolver(),
         :ok <- unit_active(resolver, prefix, unit),
         {:ok, entity} <- legal_entity(resolver, type, prefix, unit) do
      transact(fn ->
        document =
          Repo.insert!(
            %Document{
              id: Ecto.UUID.generate(),
              tenant_id: tenant_id,
              type_key: type.key,
              legal_entity_id: entity,
              issuing_org_unit_id: unit,
              source_ref: Map.get(attrs, :source_ref),
              inserted_at: now()
            },
            prefix: prefix
          )

        version = insert_draft!(prefix, tenant_id, document.id, 1, content)

        audit!(
          prefix,
          actor_id,
          "document.draft_created",
          "document",
          document.id,
          nil,
          draft_state(type.key, 1, unit)
        )

        %{document: document, version: version}
      end)
    end
  end

  defp source_ref(nil), do: :ok
  defp source_ref(ref) when is_map(ref) and not is_struct(ref), do: :ok
  defp source_ref(_other), do: {:error, {:unprocessable, :invalid_source_ref}}

  defp org_unit(nil), do: {:error, :org_unit_required}

  defp org_unit(unit) when is_binary(unit) do
    if String.trim(unit) == "" do
      {:error, :org_unit_required}
    else
      case Ecto.UUID.cast(unit) do
        {:ok, uuid} -> {:ok, uuid}
        :error -> {:error, :org_unit_not_found}
      end
    end
  end

  defp org_unit(_other), do: {:error, :org_unit_not_found}

  defp fetch_type(prefix, key) when is_binary(key) do
    case Repo.get(DocumentType, key, prefix: prefix) do
      nil -> {:error, :type_not_found}
      type -> {:ok, type}
    end
  end

  defp fetch_type(_prefix, _key), do: {:error, :type_not_found}

  defp unit_active(resolver, prefix, unit) do
    if resolver.unit_exists?(prefix, unit), do: :ok, else: {:error, :org_unit_not_found}
  end

  defp legal_entity(_resolver, %{legal_entity_required: false}, _prefix, _unit), do: {:ok, nil}

  defp legal_entity(OrgResolver.Default, %{legal_entity_required: true}, _prefix, _unit),
    do: {:error, :legal_entity_resolver_unavailable}

  defp legal_entity(resolver, %{legal_entity_required: true}, prefix, unit) do
    case resolver.legal_entity_of(prefix, unit) do
      {:ok, id} -> entity_uuid(id)
      {:error, :unit_not_found} -> {:error, :org_unit_not_found}
      _other -> {:error, :no_legal_entity}
    end
  end

  defp entity_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :no_legal_entity}
    end
  end

  defp entity_uuid(_other), do: {:error, :no_legal_entity}

  defp draft_state(type_key, version_no, unit),
    do: %{"type_key" => type_key, "version_no" => version_no, "issuing_org_unit_id" => unit}

  # ---------------------------------------------------------------------------------------
  # edit_draft/4, discard_draft/3
  # ---------------------------------------------------------------------------------------

  @doc "Replaces the content of the document's open draft. Writes no audit entry (0056 D9)."
  @spec edit_draft(String.t(), String.t(), map(), String.t()) ::
          {:ok, %DocumentVersion{}} | error()
  def edit_draft(prefix, document_id, content, actor_id) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, document_id} <- document_id(document_id),
         {:ok, _actor} <- actor(actor_id),
         {:ok, content} <- content(content) do
      transact(fn ->
        _document = lock_document!(prefix, document_id)
        draft = draft_of!(prefix, document_id)

        from(v in DocumentVersion, where: v.id == ^draft.id)
        |> Repo.update_all([set: [content: content]], prefix: prefix)

        Repo.get!(DocumentVersion, draft.id, prefix: prefix)
      end)
    end
  end

  @doc "Discards the document's open draft and audits it. The document never gets a number."
  @spec discard_draft(String.t(), String.t(), String.t()) :: {:ok, %DocumentVersion{}} | error()
  def discard_draft(prefix, document_id, actor_id) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, document_id} <- document_id(document_id),
         {:ok, actor_id} <- actor(actor_id) do
      transact(fn ->
        document = lock_document!(prefix, document_id)
        draft = draft_of!(prefix, document_id)

        from(v in DocumentVersion, where: v.id == ^draft.id)
        |> Repo.update_all(
          [set: [status: :discarded, discarded_at: now(), discarded_by: actor_id]],
          prefix: prefix
        )

        audit!(prefix, actor_id, "document.draft_discarded", "document", document_id, nil, %{
          "type_key" => document.type_key,
          "version_no" => draft.version_no
        })

        Repo.get!(DocumentVersion, draft.id, prefix: prefix)
      end)
    end
  end

  # ---------------------------------------------------------------------------------------
  # new_version_from_current/2
  # ---------------------------------------------------------------------------------------

  @doc """
  Starts the next draft of a document from its current issued version: `%{document_id:, actor_id:}`.
  The new draft copies the content, has no number and no hash; the issued version is not touched.
  `{:error, :no_issued_version}` when there is no issued current version, `{:error, :draft_exists}`
  when a draft is already open. The version number is `max(version_no) + 1`, so a discarded draft
  keeps its number and the next draft skips it.
  """
  @spec new_version_from_current(String.t(), map()) :: {:ok, %DocumentVersion{}} | error()
  def new_version_from_current(prefix, %{} = args) when is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, document_id} <- document_id(Map.get(args, :document_id)),
         {:ok, actor_id} <- actor(Map.get(args, :actor_id)) do
      transact(fn ->
        document = lock_document!(prefix, document_id)
        current = current_issued!(prefix, document)

        if Repo.exists?(draft_query(document_id), prefix: prefix),
          do: Repo.rollback(:draft_exists)

        next =
          Repo.one!(
            from(v in DocumentVersion,
              where: v.document_id == ^document_id,
              select: max(v.version_no)
            ),
            prefix: prefix
          ) + 1

        case Canonical.canonicalize(current.content) do
          {:ok, _bytes} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        version = insert_draft!(prefix, tenant_id, document_id, next, current.content)

        audit!(prefix, actor_id, "document.draft_created", "document", document_id, nil, %{
          "type_key" => document.type_key,
          "version_no" => next,
          "issuing_org_unit_id" => document.issuing_org_unit_id
        })

        version
      end)
    end
  end

  defp current_issued!(prefix, %{current_version: id}) when is_binary(id) do
    case Repo.get(DocumentVersion, id, prefix: prefix) do
      %{status: :issued} = version -> version
      _other -> Repo.rollback(:no_issued_version)
    end
  end

  defp current_issued!(_prefix, _document), do: Repo.rollback(:no_issued_version)

  # ---------------------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------------------

  # One transaction; a function body may `Repo.rollback/1` an error. A trigger refusal
  # (restrict_violation) and the unique version number are returned, never raised (INV-8).
  defp transact(fun) do
    Repo.transaction(fn ->
      try do
        fun.()
      rescue
        error in Postgrex.Error ->
          case error.postgres do
            %{code: :restrict_violation} -> Repo.rollback(:document_type_frozen)
            %{code: :unique_violation} -> Repo.rollback(:version_conflict)
            _other -> reraise error, __STACKTRACE__
          end
      end
    end)
  end

  defp lock_document!(prefix, document_id) do
    case Repo.one(from(d in Document, where: d.id == ^document_id, lock: "FOR UPDATE"),
           prefix: prefix
         ) do
      nil -> Repo.rollback(:not_found)
      document -> document
    end
  end

  defp draft_query(document_id),
    do: from(v in DocumentVersion, where: v.document_id == ^document_id and v.status == :draft)

  defp draft_of!(prefix, document_id) do
    case Repo.one(draft_query(document_id), prefix: prefix) do
      nil -> Repo.rollback(:no_draft)
      draft -> draft
    end
  end

  defp insert_draft!(prefix, tenant_id, document_id, version_no, content) do
    Repo.insert!(
      %DocumentVersion{
        id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        document_id: document_id,
        version_no: version_no,
        status: :draft,
        content: content,
        inserted_at: now()
      },
      prefix: prefix
    )
  end

  defp audit!(prefix, actor_id, action, resource_type, resource_id, before_state, after_state) do
    entry = %{
      actor_id: actor_id,
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      before_state: before_state,
      after_state: after_state
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  defp content(content) when is_map(content) and not is_struct(content) do
    if hash_key?(content) do
      {:error, {:unprocessable, :content_hash_not_accepted}}
    else
      case Canonical.canonicalize(content) do
        {:ok, _bytes} -> {:ok, content}
        {:error, reason} -> {:error, {:unprocessable, reason}}
      end
    end
  end

  defp content(_other), do: {:error, {:unprocessable, :invalid_content}}

  defp no_hash(attrs) do
    if hash_key?(attrs), do: {:error, {:unprocessable, :content_hash_not_accepted}}, else: :ok
  end

  defp hash_key?(map), do: Map.has_key?(map, :content_hash) or Map.has_key?(map, "content_hash")

  defp document_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp document_id(_other), do: {:error, :not_found}

  defp actor(actor) when is_binary(actor) do
    case Ecto.UUID.cast(actor) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:unprocessable, :invalid_actor}}
    end
  end

  defp actor(_other), do: {:error, {:unprocessable, :invalid_actor}}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
