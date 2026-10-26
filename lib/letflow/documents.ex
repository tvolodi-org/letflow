defmodule Letflow.Documents do
  @moduledoc """
  The versioned-documents service, part 1 (REQ-542, GH #3164, decision 0056 D1, D3, D8, D9):
  type registration, drafts and a new draft from the current issued version, plus `issue/2` (REQ-543
  part 2a: gap-free numbering, supersede, hash), `cancel/3` and `verify_binding/4` (part 2b).
  A refused `issue/2`, `cancel/3` or `verify_binding/4` emits the telemetry event
  `[:letflow, :documents, :refused]` (`%{count: 1}`, metadata `action`, `reason`, `prefix`) and
  writes no audit row; `document.refusals_summary` is not built here.

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

  alias Ecto.Adapters.SQL
  alias Letflow.Audit
  alias Letflow.Documents.Canonical
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentSequence
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
  # issue/2
  # ---------------------------------------------------------------------------------------

  @doc """
  Issues the open draft of a document: `%{document_id:, actor_id:}` (REQ-543 part 2a, GH #3163,
  decision 0056 D2, D3, D4, D8). One transaction, lock order document row, sequence row, audit
  chain:

    * the restricted-field check, the org unit check (`unit_exists?`) and the fail-closed legal
      entity check run first, so a refusal allocates no number;
    * the first version takes the next gap-free number of its scope (type, legal entity or the
      sentinel of `Letflow.Documents.Canonical.legal_entity_sentinel/0`, period) under a `FOR
      UPDATE` lock of the `document_sequences` row, which is inserted first if absent; a later
      version keeps the number and period of the document;
    * the previously issued version is superseded, the draft is issued with `issued_at` from the
      server clock and a content hash that has the number as an input, and `current_version`
      moves to it; `document.superseded` and `document.issued` are audited without field values.

  The period year is the calendar year at UTC+5 (decision 0056 open point 11, Asia/Almaty).
  No caller supplies a number, a period, a time or a hash. Nothing here renders or stores bytes.
  A lock or statement timeout gives `{:error, :busy}` and rolls everything back.
  """
  @spec issue(String.t(), map()) ::
          {:ok, %{document: %Document{}, version: %DocumentVersion{}}} | error()
  def issue(prefix, %{} = args) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         :ok <- no_hash(args),
         {:ok, document_id} <- document_id(Map.get(args, :document_id)),
         {:ok, actor_id} <- actor(Map.get(args, :actor_id)),
         {:ok, resolver} <- Catalog.document_org_resolver() do
      transact(fn ->
        # constant SQL, no table: the timeouts of decision 0056 D2 / T11, scoped to this transaction
        SQL.query!(Repo, "SET LOCAL lock_timeout = '2s'")
        SQL.query!(Repo, "SET LOCAL statement_timeout = '15s'")

        document = lock_document!(prefix, document_id)
        draft = draft_of!(prefix, document_id)
        type = type_of!(prefix, document)

        check_issuable!(prefix, resolver, document, type, draft)

        {number, period} = number_of!(prefix, document, type)
        issued_at = now()
        old = superseded_version(prefix, document)
        if old, do: supersede!(prefix, old, draft)

        hash = hash_of!(document, draft, number)

        from(v in DocumentVersion, where: v.id == ^draft.id)
        |> Repo.update_all(
          [set: [status: :issued, issued_at: issued_at, issued_by: actor_id, content_hash: hash]],
          prefix: prefix
        )

        from(d in Document, where: d.id == ^document_id)
        |> Repo.update_all(
          [set: [number: number, period: period, current_version: draft.id]],
          prefix: prefix
        )

        if old do
          audit!(prefix, actor_id, "document.superseded", "document", document_id, nil, %{
            "type_key" => type.key,
            "version_no" => old.version_no,
            "superseded_by_version_no" => draft.version_no
          })
        end

        audit!(prefix, actor_id, "document.issued", "document", document_id, nil, %{
          "type_key" => type.key,
          "version_no" => draft.version_no,
          "number" => number,
          "period" => period,
          "number_label" => number_label(type, number, period),
          "content_hash" => hash
        })

        %{
          document: Repo.get!(Document, document_id, prefix: prefix),
          version: Repo.get!(DocumentVersion, draft.id, prefix: prefix)
        }
      end)
    end
    |> count_refusal(:issue, prefix)
  end

  defp type_of!(prefix, document) do
    case Repo.get(DocumentType, document.type_key, prefix: prefix) do
      nil -> Repo.rollback(:type_not_found)
      type -> type
    end
  end

  # All refusals come before any write to `document_sequences` (decision 0056 D2).
  defp check_issuable!(prefix, resolver, document, type, draft) do
    with :ok <- check_restricted(prefix, declared_input(type.declared_fields), free_marks(type)),
         :ok <- unit_active(resolver, prefix, document.issuing_org_unit_id),
         :ok <- issue_entity(resolver, prefix, document, type),
         {:ok, _bytes} <- canonical(draft.content) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Stored form of "_free" is %{name => mark}; check_restricted/3 wants the names and the marks.
  defp declared_input(fields) do
    case Map.fetch(fields, @free) do
      {:ok, marks} -> Map.put(fields, @free, Map.keys(marks))
      :error -> fields
    end
  end

  defp free_marks(type), do: Map.get(type.declared_fields, @free, %{})

  defp canonical(content) do
    case Canonical.canonicalize(content) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:unprocessable, reason}}
    end
  end

  defp issue_entity(_resolver, _prefix, _document, %{legal_entity_required: false}), do: :ok

  defp issue_entity(OrgResolver.Default, _prefix, _document, %{legal_entity_required: true}),
    do: {:error, :legal_entity_resolver_unavailable}

  defp issue_entity(resolver, prefix, document, %{legal_entity_required: true}) do
    with {:ok, entity} <-
           legal_entity(
             resolver,
             %{legal_entity_required: true},
             prefix,
             document.issuing_org_unit_id
           ) do
      if entity == document.legal_entity_id, do: :ok, else: {:error, :no_legal_entity}
    end
  end

  # Version 1 allocates the next number of its scope; a later version keeps the document's own.
  defp number_of!(_prefix, %{number: number, period: period}, _type) when is_integer(number),
    do: {number, period}

  defp number_of!(prefix, document, type) do
    period = period_of(type.numbering_scope)
    key = document.legal_entity_id || Canonical.legal_entity_sentinel()
    {allocate_number!(prefix, document.tenant_id, type.key, key, period), period}
  end

  # Insert-if-absent, lock the row FOR UPDATE, then read and increment (decision 0056 D2).
  defp allocate_number!(prefix, tenant_id, type_key, key, period) do
    Repo.insert_all(
      DocumentSequence,
      [
        %{
          tenant_id: tenant_id,
          type_key: type_key,
          legal_entity_key: key,
          period: period,
          counter: 0
        }
      ],
      prefix: prefix,
      on_conflict: :nothing,
      conflict_target: [:type_key, :legal_entity_key, :period]
    )

    row =
      Repo.one!(
        from(s in DocumentSequence,
          where: s.type_key == ^type_key and s.legal_entity_key == ^key and s.period == ^period,
          lock: "FOR UPDATE"
        ),
        prefix: prefix
      )

    number = row.counter + 1

    from(s in DocumentSequence,
      where: s.type_key == ^type_key and s.legal_entity_key == ^key and s.period == ^period
    )
    |> Repo.update_all([set: [counter: number]], prefix: prefix)

    number
  end

  defp period_of(:none), do: "none"

  defp period_of(:year),
    do: now() |> DateTime.add(5 * 3600, :second) |> Map.fetch!(:year) |> Integer.to_string()

  defp superseded_version(_prefix, %{current_version: nil}), do: nil

  defp superseded_version(prefix, %{current_version: id}) do
    case Repo.get(DocumentVersion, id, prefix: prefix) do
      %{status: :issued} = version -> version
      _other -> nil
    end
  end

  # Before the new issue: the one-issued-version index allows a single issued row per document.
  defp supersede!(prefix, old, draft) do
    from(v in DocumentVersion, where: v.id == ^old.id)
    |> Repo.update_all([set: [status: :superseded, superseded_by_version: draft.id]],
      prefix: prefix
    )
  end

  defp hash_of!(document, draft, number) do
    {:ok, bytes} = canonical(draft.content) |> ok_or_rollback()

    inputs = %{
      tenant_uuid: document.tenant_id,
      document_id: document.id,
      type_key: document.type_key,
      legal_entity_id: document.legal_entity_id,
      number: number,
      version_no: draft.version_no,
      canonical_content: bytes
    }

    case Canonical.content_hash(inputs) do
      {:ok, hash} -> hash
      {:error, reason} -> Repo.rollback({:unprocessable, reason})
    end
  end

  defp ok_or_rollback({:ok, _} = ok), do: ok
  defp ok_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp number_label(type, number, period) do
    padded = number |> Integer.to_string() |> String.pad_leading(type.number_pad, "0")

    case type.numbering_scope do
      :none -> type.number_prefix <> "-" <> padded
      _year -> type.number_prefix <> "-" <> period <> "-" <> padded
    end
  end

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
            %{code: :lock_not_available} -> Repo.rollback(:busy)
            %{code: :query_canceled} -> Repo.rollback(:busy)
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

  # ---------------------------------------------------------------------------------------
  # cancel/3, verify_binding/4 and the refusals counter (REQ-543 part 2b)
  # ---------------------------------------------------------------------------------------

  @reason_max 500

  @doc """
  Cancels an issued version: `cancel(prefix, %{document_id:, version_no:, reason:}, actor_id)`
  (REQ-543 criterion 3, decision 0056 D4, D9). The reason is mandatory (not blank, at most 500
  characters) and goes into the `document.cancelled` event with no content value. Only an
  `:issued` version can be cancelled; a draft, superseded, discarded or already cancelled version
  gives `{:error, :not_issued}` and nothing changes. A cancelled version stays readable and is
  never issued again (the database trigger refuses every transition out of `cancelled`);
  `documents.current_version` keeps pointing at it, so `new_version_from_current/2` answers
  `{:error, :no_issued_version}`.
  """
  @spec cancel(String.t(), map(), term()) :: {:ok, %DocumentVersion{}} | error()
  def cancel(prefix, %{} = args, actor_id) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, document_id} <- document_id(Map.get(args, :document_id)),
         {:ok, version_no} <- version_no(Map.get(args, :version_no)),
         {:ok, actor_id} <- actor(actor_id),
         {:ok, reason} <- cancel_reason(Map.get(args, :reason)) do
      transact(fn ->
        document = lock_document!(prefix, document_id)
        version = version_for_update!(prefix, document_id, version_no)

        if version.status != :issued, do: Repo.rollback(:not_issued)

        from(v in DocumentVersion, where: v.id == ^version.id)
        |> Repo.update_all(
          [
            set: [
              status: :cancelled,
              cancelled_at: now(),
              cancelled_by: actor_id,
              cancel_reason: reason
            ]
          ],
          prefix: prefix
        )

        audit!(prefix, actor_id, "document.cancelled", "document", document_id, nil, %{
          "type_key" => document.type_key,
          "version_no" => version.version_no,
          "number" => document.number,
          "content_hash" => version.content_hash,
          "reason" => reason
        })

        Repo.get!(DocumentVersion, version.id, prefix: prefix)
      end)
    end
    |> count_refusal(:cancel, prefix)
  end

  defp version_no(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp version_no(_other), do: {:error, :not_found}

  defp cancel_reason(reason) when is_binary(reason) do
    cond do
      String.trim(reason) == "" -> {:error, {:unprocessable, :reason_required}}
      String.length(reason) > @reason_max -> {:error, {:unprocessable, :reason_too_long}}
      true -> {:ok, reason}
    end
  end

  defp cancel_reason(_other), do: {:error, {:unprocessable, :reason_required}}

  defp version_for_update!(prefix, document_id, version_no) do
    query =
      from(v in DocumentVersion,
        where: v.document_id == ^document_id and v.version_no == ^version_no,
        lock: "FOR UPDATE"
      )

    case Repo.one(query, prefix: prefix) do
      nil -> Repo.rollback(:not_found)
      version -> version
    end
  end

  @doc """
  INTERNAL. True only when version `version_no` of the document is `:issued`, its stored hash
  equals `content_hash` and the hash recomputed from the stored content, number, tenant uuid,
  document id, type key, legal entity and version number (decision 0056 D3) equals the stored
  one. Every other case, including a malformed argument, an absent version and another tenant's
  document id, gives the same bare `false` (INV-5); the reason is only in the telemetry metadata.
  Never raises, takes no lock and never calls the org resolver, so a retired org unit does not
  matter (REQ-543 criterion 5b, read half). Like the rest of the module it checks no permission:
  the first caller (REQ-544) owns that.

  When the recomputed hash differs from the stored one, `document.integrity_failed` is audited
  (ids and hashes only, actor nil). Transaction contract: at top level the entry is written in its
  own transaction and a failure to write it still gives `false`. Inside a caller's transaction the
  entry is written in that transaction, so it commits or rolls back with the caller. A caller that
  refuses with `Repo.rollback/1` on `false` loses the entry: verify before opening the
  transaction, or commit the refusal. A database failure while writing then raises to the caller
  (and `audit!/7` rolls the caller's transaction back), the same loud outcome as any other audited
  write in the caller's transaction.
  """
  @spec verify_binding(String.t(), term(), term(), term()) :: boolean()
  def verify_binding(prefix, document_id, version_no, content_hash) do
    outcome = verify(prefix, document_id, version_no, content_hash)
    if outcome != :ok, do: count_refusal({:error, outcome}, :verify_binding, prefix)
    outcome == :ok
  end

  defp verify(prefix, document_id, version_no, content_hash)
       when is_binary(prefix) and is_binary(content_hash) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, id} <- document_id(document_id),
         {:ok, n} <- version_no(version_no) do
      query =
        from(v in DocumentVersion,
          join: d in Document,
          on: d.id == v.document_id,
          where: d.id == ^id and v.version_no == ^n,
          select: {d, v}
        )

      case Repo.one(query, prefix: prefix) do
        nil -> :absent
        {d, v} -> verify_row(prefix, tenant_id, d, v, content_hash)
      end
    else
      _invalid -> :invalid_input
    end
  end

  defp verify(_prefix, _document_id, _version_no, _content_hash), do: :invalid_input

  defp verify_row(_prefix, _tenant_id, _d, %{status: status}, _hash) when status != :issued,
    do: :not_issued

  defp verify_row(prefix, tenant_id, d, v, content_hash) do
    recomputed = recompute_hash(d, v)

    cond do
      d.tenant_id != tenant_id or recomputed != {:ok, v.content_hash} ->
        record_integrity_failure(prefix, d, v, recomputed)

      byte_size(content_hash) == byte_size(v.content_hash) and
          :crypto.hash_equals(content_hash, v.content_hash) ->
        :ok

      true ->
        :hash_mismatch
    end
  end

  defp recompute_hash(d, v) do
    with {:ok, bytes} <- Canonical.canonicalize(v.content) do
      Canonical.content_hash(%{
        tenant_uuid: d.tenant_id,
        document_id: d.id,
        type_key: d.type_key,
        legal_entity_id: d.legal_entity_id,
        number: d.number,
        version_no: v.version_no,
        canonical_content: bytes
      })
    end
  end

  defp record_integrity_failure(prefix, d, v, recomputed) do
    after_state = %{
      "type_key" => d.type_key,
      "version_no" => v.version_no,
      "stored_hash" => v.content_hash,
      "recomputed_hash" => recomputed_hash(recomputed)
    }

    write = fn ->
      audit!(prefix, nil, "document.integrity_failed", "document", d.id, nil, after_state)
    end

    if Repo.in_transaction?() do
      write.()
      :integrity_failed
    else
      try do
        case transact(write) do
          {:ok, _} -> :integrity_failed
          {:error, _} -> :audit_failed
        end
      rescue
        _error -> :audit_failed
      end
    end
  end

  defp recomputed_hash({:ok, hash}), do: hash
  defp recomputed_hash(_error), do: nil

  # Criterion 8: a refusal is a telemetry count, never an audit row. Runs after the transaction
  # returned; metadata has no content, hash or id.
  defp count_refusal({:error, reason} = result, action, prefix) do
    :telemetry.execute([:letflow, :documents, :refused], %{count: 1}, %{
      action: action,
      reason: refusal_reason(reason),
      prefix: prefix
    })

    result
  end

  defp count_refusal(result, _action, _prefix), do: result

  defp refusal_reason(reason) when is_atom(reason), do: reason
  defp refusal_reason({:unprocessable, reason}) when is_atom(reason), do: reason

  defp refusal_reason(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp refusal_reason(_other), do: :other
end
