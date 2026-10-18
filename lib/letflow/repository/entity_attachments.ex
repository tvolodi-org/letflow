defmodule Letflow.Repository.EntityAttachments do
  @moduledoc """
  Context module for the `entity_record_attachments` table's core lifecycle:
  `upload/2`, `list/2`, `get/2`, `get_content/2`, `delete/2`. See
  `lib/letflow/design/req313-entity-record-attachments.md` for the full
  design this module implements. Plain Ecto context module, no process --
  same shape as `Letflow.Repository.Attachments`, this module's own sibling
  and the module every function below mirrors 1:1 with one substitution
  throughout: `instance_id` becomes `entity_type` + `record_id` (design §2).

  **Scope boundary (REQ-316):** this module covers only the
  `entity_record_attachments` schema/migration and these five functions. No
  route, no permission atom, no router change -- that is REQ-317.

  ## Tenant scoping (INV-1, design §5)

  Every function below takes `opts :: [prefix: String.t()]`, `prefix` always
  supplied by the caller -- this module never itself decides tenant scope,
  matching `Letflow.Repository.Attachments`' own precedent.
  `tenant_id` is never accepted from caller-supplied attrs -- it is always
  derived from `opts[:prefix]`, explicitly, via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` (§2's own
  substitution rule and the SECURITY-REVIEWER non-blocking note recorded in
  design §10's INV-1 section -- stated here explicitly, not left to be
  inferred from "mirrored 1:1" phrasing).

  ## The composite FK to `entity_record_latest` (design §1)

  `upload/2`'s insert changeset declares
  `foreign_key_constraint(:record_id, name: :entity_record_attachments_record_fkey)`
  (`EntityAttachment.changeset/2`) -- an `(entity_type, record_id)` pair with
  no matching `entity_record_latest` row surfaces as an ordinary
  `{:error, %Ecto.Changeset{}}`, never a raised, unhandled Postgres error.
  The underlying migration adds that FK `DEFERRABLE INITIALLY DEFERRED`
  (design §1) so that the promotion-backfill path's delete-then-reinsert of
  `entity_record_latest` rows, inside one transaction, does not raise
  mid-transaction -- this module's own `upload/2` transaction is unaffected
  by that deferral (its own insert either violates the constraint against a
  genuinely nonexistent pair, surfaced at this transaction's own commit, or
  succeeds).

  ## INV-a -- `content_type` is caller-supplied metadata, never a validated
  ## fact

  Inherited verbatim from `Letflow.Repository.Attachments` (design §6):
  nothing in this module treats the stored `content_type` value as verified
  against the actual byte content -- no magic-byte/MIME-sniffing check is
  performed anywhere here.

  ## INV-b -- `byte_size` is independently measured, never caller-trusted

  Inherited verbatim from `Letflow.Repository.Attachments` (design §6):
  `upload/2` computes `byte_size` via `byte_size/1` over the actual
  `raw_bytes` binary parameter -- `upload_attrs()` has no parameter for a
  caller-declared size at all.

  ## Shared `repository_artifacts` dedup (design §2)

  `repository_artifacts` is a general-purpose, per-tenant-schema-scoped
  content-addressed byte store (REQ-202), already shared across multiple
  consumers -- `Letflow.Repository.Attachments`, `Letflow.Definitions.ExportImport`'s
  artifact versions, and now this module. `upload/2` calls
  `Letflow.Repository.upsert_content/6` exactly as
  `Letflow.Repository.Attachments.upload/2` already does -- uploading
  byte-identical content once as an instance attachment and once as an
  entity-record attachment reuses the SAME `repository_artifacts` row within
  one tenant's schema, never a second, separate content store.

  ## Content scanning

  `upload/2` runs the same synchronous, reject-before-persist content scan
  `Letflow.Repository.Attachments.upload/2` runs, via the SAME
  `Letflow.Repository.AttachmentScanner` adapter and the SAME
  `Application.get_env(:letflow, :attachment_scanner, ...)` config key --
  not a second, independently-configured scan gate. An infected or
  scan-failed upload is never persisted at all.

  ## `delete/2`'s metadata-only-delete rationale

  `delete/2` removes the `entity_record_attachments` row only; the
  underlying `repository_artifacts` content row is never deleted by this
  module, for the same reasons `Letflow.Repository.Attachments.delete/2`
  never deletes it (REQ-202's own immutability rule, the `ON DELETE
  RESTRICT` FK, and the possibility that another row shares the same
  `content_hash`).

  ## `list/2`'s no-existence-check behavior (design §2/§5, INV-5)

  `list/2` performs NO existence check against `entity_record_latest` before
  querying -- an empty page for a nonexistent (or cross-tenant) `(entity_type,
  record_id)` pair is indistinguishable from an existing record with zero
  attachments, matching `Letflow.Repository.Attachments.list/2`'s own
  behavior for a nonexistent `instance_id` and avoiding the exact
  "exists but forbidden" timing signal INV-5 forbids.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Api.Pagination
  alias Letflow.Repo
  alias Letflow.Repository
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.EntityAttachment
  alias Letflow.TenantProvisioning

  @typedoc "Threaded into every `Repo` call below -- `:prefix` derived by the caller from `Letflow.Api.Context.scoped_repo_opts/1`, never from request data."
  @type opts :: [prefix: String.t()]

  @list_cursor_prefix "ERA:"

  # Shared with Letflow.Repository.Attachments -- the same judgement-based
  # number (design §6 OQ-3, inherited not re-derived), not a second,
  # independently-chosen ceiling.
  @max_upload_bytes 26_214_400

  @default_attachment_scanner Letflow.Repository.AttachmentScanner.SignatureHeuristic

  # ===========================================================================
  # upload/2 (design §2)
  # ===========================================================================

  @type upload_attrs :: %{
          required(:entity_type) => String.t(),
          required(:record_id) => Ecto.UUID.t(),
          required(:raw_bytes) => binary(),
          required(:file_name) => String.t(),
          required(:content_type) => String.t(),
          required(:uploaded_by) => Ecto.UUID.t(),
          optional(:description) => String.t() | nil
        }

  @doc """
  Uploads an entity-record attachment: hashes `raw_bytes` independently
  (byte-identity only), runs a synchronous content scan, then upserts a
  `repository_artifacts` row keyed by that hash (creating or reusing it),
  and inserts one `entity_record_attachments` row referencing it.

  Steps (mirrors `Letflow.Repository.Attachments.upload/2` exactly):

    1. Computes `byte_size = byte_size(raw_bytes)` -- never a caller-supplied
       field. If it exceeds `#{@max_upload_bytes}` bytes, returns
       `{:error, :file_too_large}` immediately, before any hashing,
       scanning, upsert, or insert is attempted.
    2. Computes `content_hash = :crypto.hash(:sha256, raw_bytes)`.
    3. Calls the configured `Letflow.Repository.AttachmentScanner` adapter
       synchronously, before any persistence. An infected or unavailable
       scan result fails closed: no `repository_artifacts` row, no
       `entity_record_attachments` row is created.
    4. Upserts the `repository_artifacts` row via
       `Letflow.Repository.upsert_content/6`, in the same tenant's schema
       (shared with `Letflow.Repository.Attachments`, design §2).
    5. Derives `tenant_id` explicitly from `opts[:prefix]` via
       `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` -- never
       accepted from caller-supplied attrs.
    6. Inserts the `entity_record_attachments` row with `scan_status: :clean`
       inside the same `Repo.transaction/1` as the upsert. A genuinely
       nonexistent `(entity_type, record_id)` pair surfaces here as
       `{:error, %Ecto.Changeset{}}` via `EntityAttachment.changeset/2`'s
       `foreign_key_constraint/3` clause (the migration's deferred composite
       FK), not a raised, unhandled Postgres error.
  """
  @spec upload(upload_attrs(), opts()) ::
          {:ok, EntityAttachment.t()}
          | {:error, :file_too_large}
          | {:error, :infected, verdict :: String.t()}
          | {:error, :scan_unavailable}
          | {:error, Ecto.Changeset.t()}
  def upload(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    raw_bytes = Map.fetch!(attrs, :raw_bytes)
    measured_byte_size = byte_size(raw_bytes)

    if measured_byte_size > @max_upload_bytes do
      {:error, :file_too_large}
    else
      content_hash = :crypto.hash(:sha256, raw_bytes)
      content_type = Map.fetch!(attrs, :content_type)

      case run_attachment_scan(raw_bytes, content_type) do
        {:ok, :clean} ->
          do_upload_after_scan(
            attrs,
            prefix,
            raw_bytes,
            content_hash,
            content_type,
            measured_byte_size
          )

        {:ok, :infected, verdict} ->
          log_infected_upload_attempt(attrs, prefix, content_hash)
          {:error, :infected, verdict}

        {:error, _reason} ->
          {:error, :scan_unavailable}
      end
    end
  end

  @spec run_attachment_scan(binary(), String.t()) ::
          {:ok, :clean} | {:ok, :infected, String.t()} | {:error, term()}
  defp run_attachment_scan(raw_bytes, content_type) do
    scanner = Application.get_env(:letflow, :attachment_scanner, @default_attachment_scanner)
    scanner.scan(raw_bytes, content_type)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  # The migration's composite FK is DEFERRABLE INITIALLY DEFERRED (design §1)
  # -- Postgres only evaluates it at transaction COMMIT, not at the INSERT
  # statement itself. That means a violation is NOT visible to Repo.insert/2's
  # own return value at all (Repo.insert/2 returns {:ok, attachment} inside
  # the fn below, since nothing failed synchronously yet) -- it surfaces only
  # when Repo.transaction/1 issues the implicit COMMIT after the fn returns,
  # which is past the point Ecto's ordinary changeset-constraint translation
  # (`Repo.insert/2` catching a Postgrex.Error and mapping it via the
  # changeset's own declared `foreign_key_constraint/3`) can intercept it --
  # that translation only wraps the `INSERT` statement's own execution, not a
  # later, separate `COMMIT`. So this raises as a bare, unhandled
  # `Postgrex.Error` straight out of `Repo.transaction/1` unless caught here
  # explicitly, matching this constraint's own name
  # (`@record_fk_constraint_name`) and converting it into the same
  # `{:error, %Ecto.Changeset{}}` shape `EntityAttachment.changeset/2`'s
  # `foreign_key_constraint/3` clause already declares (AC5 -- a genuinely
  # nonexistent `(entity_type, record_id)` pair must never crash `upload/2`).
  @record_fk_constraint_name "entity_record_attachments_record_fkey"

  defp do_upload_after_scan(
         attrs,
         prefix,
         raw_bytes,
         content_hash,
         content_type,
         measured_byte_size
       ) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      insert_attrs = %{
        # tenant_id is derived exclusively from opts[:prefix] above -- never
        # accepted from caller-supplied attrs (design §10's non-blocking
        # INV-1 note, acted on explicitly here).
        tenant_id: tenant_id,
        entity_type: Map.fetch!(attrs, :entity_type),
        record_id: Map.fetch!(attrs, :record_id),
        content_hash: content_hash,
        file_name: Map.fetch!(attrs, :file_name),
        content_type: content_type,
        byte_size: measured_byte_size,
        uploaded_by: Map.fetch!(attrs, :uploaded_by),
        description: Map.get(attrs, :description),
        scan_status: :clean
      }

      changeset = EntityAttachment.changeset(%EntityAttachment{}, insert_attrs)

      try do
        Repo.transaction(fn ->
          Repository.upsert_content(
            prefix,
            tenant_id,
            content_hash,
            content_type,
            measured_byte_size,
            raw_bytes
          )

          case Repo.insert(changeset, prefix: prefix) do
            {:ok, attachment} -> attachment
            {:error, failed_changeset} -> Repo.rollback(failed_changeset)
          end
        end)
        |> case do
          {:ok, attachment} -> {:ok, attachment}
          {:error, %Ecto.Changeset{} = failed_changeset} -> {:error, failed_changeset}
        end
      rescue
        exception in Postgrex.Error ->
          if deferred_record_fk_violation?(exception) do
            {:error, add_record_fk_error(changeset)}
          else
            reraise exception, __STACKTRACE__
          end
      end
    end
  end

  @spec deferred_record_fk_violation?(Postgrex.Error.t()) :: boolean()
  defp deferred_record_fk_violation?(%Postgrex.Error{
         postgres: %{code: :foreign_key_violation} = pg
       }) do
    Map.get(pg, :constraint) == @record_fk_constraint_name
  end

  defp deferred_record_fk_violation?(%Postgrex.Error{}), do: false

  @spec add_record_fk_error(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp add_record_fk_error(changeset) do
    Ecto.Changeset.add_error(changeset, :record_id, "does not exist",
      constraint: :foreign,
      constraint_name: @record_fk_constraint_name
    )
  end

  defp log_infected_upload_attempt(attrs, prefix, content_hash) do
    tenant_id =
      case TenantProvisioning.tenant_id_for_schema_name(prefix) do
        {:ok, tenant_id} -> tenant_id
        {:error, _reason} -> nil
      end

    Logger.warning(
      "entity-record attachment upload rejected: infected content",
      tenant_id: tenant_id,
      entity_type: Map.get(attrs, :entity_type),
      record_id: Map.get(attrs, :record_id),
      uploaded_by: Map.get(attrs, :uploaded_by),
      content_hash: Base.encode16(content_hash, case: :lower)
    )
  end

  # ===========================================================================
  # list/2 (design §2)
  # ===========================================================================

  @type list_params :: %{
          required(:entity_type) => String.t(),
          required(:record_id) => Ecto.UUID.t(),
          cursor: String.t() | nil,
          page_size: pos_integer()
        }

  @doc """
  Cursor-paginated listing of `entity_record_attachments`, tenant-scoped
  (`opts[:prefix]`) and filtered by `(entity_type, record_id)` (both
  required). Ordered `(created_at desc, id desc)`, matching the migration's
  own composite index shape, `page_size + 1` fetch-and-drop-extra per
  REQ-067's cursor contract.

  **No existence check against `entity_record_latest`** -- a `(entity_type,
  record_id)` pair with no matching parent row returns an EMPTY page (design
  §2/§5), not an error, identical to
  `Letflow.Repository.Attachments.list/2`'s own behavior for a nonexistent
  `instance_id`.
  """
  @spec list(list_params(), opts()) ::
          {:ok, %{items: [EntityAttachment.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired | :page_size_too_large}
  def list(params, opts) when is_map(params) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    entity_type = Map.fetch!(params, :entity_type)
    record_id = Map.fetch!(params, :record_id)

    with {:ok, page_size} <- Pagination.validate_page_size(Map.get(params, :page_size)),
         {:ok, cursor_seek} <- decode_list_cursor(Map.get(params, :cursor)) do
      rows =
        EntityAttachment
        |> where([a], a.entity_type == ^entity_type and a.record_id == ^record_id)
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([a], desc: a.created_at, desc: a.id)
        |> limit(^(page_size + 1))
        |> Repo.all(prefix: prefix)

      {page, next_cursor} = split_list_page(rows, page_size)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  # ===========================================================================
  # get/2 (design §2)
  # ===========================================================================

  @doc """
  Tenant-scoped fetch of one attachment's metadata (not byte content),
  mirroring `Letflow.Repository.Attachments.get/2`'s shape exactly:
  `Ecto.UUID.cast/1` first (`{:error, :invalid_id}`, no DB round-trip), then
  a prefix-scoped fetch (`{:error, :not_found}` for both "does not exist" and
  "exists in another tenant's schema").
  """
  @spec get(id :: String.t(), opts()) ::
          {:ok, EntityAttachment.t()} | {:error, :invalid_id | :not_found}
  def get(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :invalid_id}

      {:ok, id} ->
        case Repo.get(EntityAttachment, id, prefix: prefix) do
          nil -> {:error, :not_found}
          %EntityAttachment{} = attachment -> {:ok, attachment}
        end
    end
  end

  # ===========================================================================
  # get_content/2 (design §2, INV-RT-1)
  # ===========================================================================

  @doc """
  Tenant-scoped fetch of one attachment's metadata AND its raw byte content
  in one call -- same two-lookup mechanism as
  `Letflow.Repository.Attachments.get_content/2`: metadata via `get/2`'s own
  query, then a second, separate lookup against `repository_artifacts` keyed
  by the metadata row's own `content_hash`.

  Exists as its own function (rather than two separate calls made by a
  future route handler) for the same `INV-RT-1` reason
  `Letflow.Repository.Attachments.get_content/2` does: router-layer modules
  must never issue a `Repo.*` call directly.

  A `nil` second-lookup result is a structural-invariant violation, not a
  normal caller-facing error -- `entity_record_attachments.content_hash` has
  a `null: false, references(:repository_artifacts, ..., on_delete: :restrict)`
  FK, so a row returned by the first lookup is guaranteed by the database
  itself to have a matching `repository_artifacts` row in the same tenant
  schema. Surfaced as `{:error, :content_missing}`.

  Before bytes are returned, `attachment.scan_status` must be `:clean` -- any
  other value returns `{:error, :not_available}` instead, defense-in-depth
  for a pre-existing row (defaults to `:pending`) that has never actually
  been scanned. `list/2` and `get/2` are unaffected by this gate.
  """
  @spec get_content(id :: String.t(), opts()) ::
          {:ok, EntityAttachment.t(), Artifact.t()}
          | {:error, :invalid_id | :not_found | :content_missing | :not_available}
  def get_content(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, attachment} <- get(id, opts),
         :ok <- check_scan_status_clean(attachment) do
      case Repo.get(Artifact, attachment.content_hash, prefix: prefix) do
        %Artifact{} = artifact -> {:ok, attachment, artifact}
        nil -> {:error, :content_missing}
      end
    end
  end

  defp check_scan_status_clean(%EntityAttachment{scan_status: :clean}), do: :ok
  defp check_scan_status_clean(%EntityAttachment{}), do: {:error, :not_available}

  # ===========================================================================
  # delete/2 (design §2)
  # ===========================================================================

  @doc """
  Tenant-scoped hard delete of the `entity_record_attachments` row **only**
  -- mirrors `Letflow.Repository.Attachments.delete/2`'s shape exactly:
  reuses `get/2` for id-validation/tenant-scoped-existence, then
  `Repo.delete/2` on the fetched struct. The underlying `repository_artifacts`
  row referenced by `content_hash` is never deleted by this function.
  """
  @spec delete(id :: String.t(), opts()) ::
          {:ok, EntityAttachment.t()} | {:error, :invalid_id | :not_found}
  def delete(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, attachment} <- get(id, opts) do
      Repo.delete(attachment, prefix: prefix)
    end
  end

  # ── list/2 private helpers ──────────────────────────────────────────────

  defp filter_by_list_cursor(query, nil), do: query

  defp filter_by_list_cursor(query, {ts, id}) do
    from(a in query, where: {a.created_at, a.id} < {^ts, ^id})
  end

  @spec decode_list_cursor(String.t() | nil) ::
          {:ok, {DateTime.t(), Ecto.UUID.t()} | nil}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @list_cursor_prefix, byte_size(@list_cursor_prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} -> decode_seek(cursor)
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  defp decode_seek(%Pagination.Cursor{inner: inner}) do
    case Pagination.decode_seek_parts(inner, @list_cursor_prefix, [:datetime_us, :uuid]) do
      {:ok, [created_at, id]} -> {:ok, {created_at, id}}
      {:error, :invalid_cursor} = error -> error
    end
  end

  defp split_list_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_next_cursor(List.last(page))}
  end

  defp split_list_page(rows, _page_size), do: {rows, nil}

  defp build_list_next_cursor(%EntityAttachment{id: id, created_at: created_at}) do
    created_at_us = DateTime.to_unix(created_at, :microsecond)

    @list_cursor_prefix
    |> Pagination.build_raw_cursor(created_at_us, id)
    |> Pagination.encode_cursor()
  end
end
