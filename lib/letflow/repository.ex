defmodule Letflow.Repository do
  @moduledoc """
  Content-addressed artifact store and version history (REQ-202,
  REPO-01/02/03/04). See `lib/letflow/design/req202-artifact-repository.md`
  for the full design this module implements: §4 (`create/2`'s dedup and
  version-sequencing algorithm) and §6 (`list_versions/4`'s REQ-067 cursor
  contract).

  Tenant scoping follows the same convention every other context module in
  this codebase uses (`Letflow.Audit`, `Letflow.Definitions`): every public
  function takes an explicit `prefix :: String.t()` argument -- the Postgres
  schema name REQ-072's request-context machinery already resolved for the
  caller -- and derives `tenant_id` from it via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`. No function in
  this module accepts a separately-trusted, caller-supplied `tenant_id`.

  ## REQ-041 name-collision disambiguation (AC12)

  `solution_pack_artefact_bases` (REQ-041, done, S2) is a GLOBAL,
  install-tracking table recording which artefact a given solution-pack
  install started from, for three-way-diff computation during pack updates.
  It is **not** a content-addressed artifact store, has no
  `content_hash`-keyed dedup mechanism, and this module neither reads nor
  writes it. `Letflow.Repository.Artifact`/`Letflow.Repository.ArtifactVersion`
  (this module) and `solution_pack_artefact_bases` (REQ-041) are two
  unrelated tables that happen to share the English word "artifact"/
  "artefact" -- they must not be conflated or unified on the strength of the
  shared vocabulary.

  ## Functions deliberately not built (scope discipline, design §8)

  There is no `update/2` on either schema (REPO-02 -- no update path exists
  at all, structurally; "changing" content means calling `create/2` again).
  There is no `delete/1` on `Letflow.Repository.Artifact` (a content-addressed
  store; nothing in this module's scope ever removes a content row, and the
  DB trigger installed by this table's migration blocks it regardless). No
  route or controller is added by this requirement -- see the design doc §8
  and REQ-202's own text for why the `/repository/artifacts` HTTP surface is
  out of scope for this batch.

  ## REQ-211 cross-module change -- `upsert_content/6` is now public

  Was `defp upsert_content/5`; REQ-211 (`lib/letflow/design/req211-instance-attachments-core.md`
  §2A/§4.1 step 3, option (a)) changed it to a public, documented
  `upsert_content/6` (added a required `content :: binary()` parameter,
  writing it into the `content` column REQ-211's own migration addendum adds
  to `repository_artifacts`) so `Letflow.Repository.Attachments.upload/2` can
  share this exact upsert-by-hash path rather than duplicating it against
  `Letflow.Repository.Artifact.changeset/2` directly. This is a REQ-211
  requirement reaching into REQ-202's existing module -- flagged explicitly
  for REVIEWER sign-off per the design doc, not a REQ-202-internal change.
  `create/2`'s own external `@spec`/behavior is unchanged by this addition.
  """

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Repo
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.ArtifactVersion
  alias Letflow.Repository.Canonicaliser
  alias Letflow.TenantProvisioning

  @max_create_retries 5

  @list_versions_cursor_prefix "RV:"

  @type artifact_kind :: Letflow.Repository.ArtifactKind.t()

  @doc """
  The shared `artifact_kind` value list (OQ-B, `req203-artifact-activation.md`
  §9) -- delegates to `Letflow.Repository.ArtifactKind`, which carries no
  compile-time dependency on this module (see that module's moduledoc for
  why the value list cannot live here without deadlocking the compiler).
  """
  @spec artifact_kinds() :: [artifact_kind()]
  def artifact_kinds, do: Letflow.Repository.ArtifactKind.values()

  @type create_attrs :: %{
          required(:artifact_kind) => artifact_kind(),
          required(:artifact_name) => String.t(),
          required(:content_type) => String.t(),
          required(:content) => binary(),
          required(:created_by) => Ecto.UUID.t(),
          optional(:parent_version_id) => Ecto.UUID.t() | nil,
          optional(:description) => String.t() | nil
        }

  @typedoc "REQ-067's opts shape for `list_versions/4` -- see design §6."
  @type list_versions_opts :: [cursor: String.t() | nil, page_size: pos_integer() | nil]

  @doc """
  Creates a new artifact version (REPO-01/02/03/04), scoped to the tenant
  schema named by `prefix`.

  Steps (design §4.2):

    1. Canonicalise `attrs.content` per `Letflow.Repository.Canonicaliser`
       (byte-identity for non-JSON content) -- `{:error, :invalid_json}` if
       `content_type` is `"application/json"` and `content` fails to decode.
    2. Compute the SHA-256 `content_hash` over the canonical form.
    3. Upsert the `repository_artifacts` row keyed by `content_hash`
       (`on_conflict: :nothing`) -- identical content submitted before means
       no new row is written (REPO-01's dedup, AC1).
    4. Resolve (or, for a `(artifact_kind, artifact_name)` pair seen for the
       first time in this tenant's schema, mint) `artifact_id`, and compute
       the next `version_number` for that pair (design §4.4) -- locked via
       `SELECT ... FOR UPDATE` against the existing latest row when one
       exists, with the `(artifact_kind, artifact_name, version_number)`
       unique index as the concurrency backstop for the first-version race a
       row-lock cannot cover. A losing concurrent writer retries, up to
       #{@max_create_retries} attempts.
    5. Inserts the `artifact_versions` row.

  Returns the inserted `Letflow.Repository.ArtifactVersion.t()`, whose own
  `content_hash` field carries the descriptor REQ-202's text asks for.
  """
  @spec create(create_attrs(), prefix :: String.t()) ::
          {:ok, ArtifactVersion.t()}
          | {:error, :invalid_json}
          | {:error, :invalid_schema_name}
          | {:error, :version_number_conflict}
          | {:error, Ecto.Changeset.t()}
  def create(attrs, prefix) when is_map(attrs) and is_binary(prefix) do
    content_type = Map.fetch!(attrs, :content_type)
    content = Map.fetch!(attrs, :content)

    with {:ok, canonical} <- Canonicaliser.canonicalize_content(content_type, content),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      hash = Canonicaliser.content_hash(canonical)
      byte_size = byte_size(canonical)

      create_with_retries(
        attrs,
        prefix,
        tenant_id,
        content_type,
        hash,
        byte_size,
        canonical,
        @max_create_retries
      )
    end
  end

  defp create_with_retries(
         _attrs,
         _prefix,
         _tenant_id,
         _content_type,
         _hash,
         _byte_size,
         _canonical,
         0
       ) do
    {:error, :version_number_conflict}
  end

  defp create_with_retries(
         attrs,
         prefix,
         tenant_id,
         content_type,
         hash,
         byte_size,
         canonical,
         retries_left
       ) do
    artifact_kind = Map.fetch!(attrs, :artifact_kind)
    artifact_name = Map.fetch!(attrs, :artifact_name)

    result =
      Repo.transaction(fn ->
        upsert_content(prefix, tenant_id, hash, content_type, byte_size, canonical)

        {artifact_id, version_number} =
          next_version(prefix, artifact_kind, artifact_name)

        version_attrs = %{
          tenant_id: tenant_id,
          artifact_id: artifact_id,
          artifact_kind: artifact_kind,
          artifact_name: artifact_name,
          version_number: version_number,
          content_hash: hash,
          parent_version_id: Map.get(attrs, :parent_version_id),
          created_by: Map.fetch!(attrs, :created_by),
          description: Map.get(attrs, :description)
        }

        %ArtifactVersion{}
        |> ArtifactVersion.changeset(version_attrs)
        |> Repo.insert(prefix: prefix)
        |> case do
          {:ok, version} -> version
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, version} ->
        {:ok, version}

      {:error, %Ecto.Changeset{} = changeset} ->
        if retries_left > 1 and unique_version_conflict?(changeset) do
          create_with_retries(
            attrs,
            prefix,
            tenant_id,
            content_type,
            hash,
            byte_size,
            canonical,
            retries_left - 1
          )
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  Upserts a `repository_artifacts` row keyed by `content_hash`
  (`on_conflict: :nothing, conflict_target: :content_hash`) -- identical
  content already present in this tenant's schema means no new row is
  written (REPO-01's dedup, AC1). Shared between `create/2` (this module's
  own `artifact_versions` write path) and `Letflow.Repository.Attachments.upload/2`
  (REQ-211), per that requirement's design doc §4.1 step 3, option (a):
  a single shared upsert path avoids two independently-maintained copies of
  "how to upsert a `repository_artifacts` row" ever drifting apart.

  `content` is the actual raw bytes stored into the `content :bytea` column
  REQ-211's migration addendum added (`lib/letflow/design/req211-instance-attachments-core.md`
  §2A) -- for `create/2`'s own callers this is the canonicalised form; for
  `Letflow.Repository.Attachments.upload/2` it is the raw uploaded bytes
  (attachments are never canonicalised, per that module's own moduledoc).

  On a `content_hash` collision, this does NOT re-validate or overwrite the
  existing row's `content_type`/`byte_size`/`content` -- "a hash collision
  implies identical content by construction, so there is nothing to
  reconcile" (design §4.2 step 3's own reasoning, carried over unchanged).
  """
  @spec upsert_content(
          prefix :: String.t(),
          tenant_id :: Ecto.UUID.t(),
          hash :: binary(),
          content_type :: String.t(),
          byte_size :: non_neg_integer(),
          content :: binary()
        ) :: {:ok, Artifact.t()} | {:error, Ecto.Changeset.t()}
  def upsert_content(prefix, tenant_id, hash, content_type, byte_size, content) do
    attrs = %{
      content_hash: hash,
      tenant_id: tenant_id,
      content_type: content_type,
      byte_size: byte_size,
      content: content
    }

    %Artifact{}
    |> Artifact.changeset(attrs)
    |> Repo.insert(prefix: prefix, on_conflict: :nothing, conflict_target: :content_hash)
  end

  defp next_version(prefix, artifact_kind, artifact_name) do
    query =
      ArtifactVersion
      |> where([v], v.artifact_kind == ^artifact_kind and v.artifact_name == ^artifact_name)
      |> order_by(desc: :version_number)
      |> limit(1)
      |> lock("FOR UPDATE")

    case Repo.one(query, prefix: prefix) do
      nil ->
        {Ecto.UUID.generate(), 1}

      %ArtifactVersion{artifact_id: artifact_id, version_number: version_number} ->
        {artifact_id, version_number + 1}
    end
  end

  defp unique_version_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
    end)
  end

  @doc """
  Ordered, paginated version history for `(artifact_kind, artifact_name)`,
  scoped to the tenant schema named by `prefix` (REPO-03, REQ-067's cursor
  contract -- design §6). Newest version first
  (`version_number desc, version_id desc`).

  `opts[:cursor]` is an encoded cursor string minted by a previous call to
  this same function, or `nil` for the first page. `opts[:page_size]` is
  validated via `Letflow.Api.Pagination.validate_page_size/1` -- rejected
  (not clamped) when out of range, matching every other list endpoint in
  this codebase.

  The decoded cursor carries no `tenant_id`/schema/prefix field (REQ-067's
  INV-1) -- tenant scoping comes exclusively from `prefix`, and because each
  tenant's `artifact_versions` table is a physically separate schema, a
  query scoped to one tenant's `prefix` structurally cannot return another
  tenant's rows regardless of what a replayed cursor decodes to.
  """
  @spec list_versions(
          artifact_kind :: artifact_kind(),
          artifact_name :: String.t(),
          prefix :: String.t(),
          opts :: list_versions_opts()
        ) ::
          {:ok, Pagination.Page.t(ArtifactVersion.t())}
          | {:error, :invalid_schema_name}
          | {:error, :page_size_too_large}
          | {:error, :wrong_endpoint}
          | {:error, :expired}
          | {:error, :invalid_cursor}
  def list_versions(artifact_kind, artifact_name, prefix, opts \\ [])
      when is_binary(artifact_name) and is_binary(prefix) and is_list(opts) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, page_size} <- Pagination.validate_page_size(Keyword.get(opts, :page_size)),
         {:ok, cursor_seek} <- decode_list_versions_cursor(Keyword.get(opts, :cursor)) do
      rows =
        ArtifactVersion
        |> where([v], v.artifact_kind == ^artifact_kind and v.artifact_name == ^artifact_name)
        |> filter_by_list_versions_cursor(cursor_seek)
        |> order_by([v], desc: v.version_number, desc: v.version_id)
        |> limit(^(page_size + 1))
        |> Repo.all(prefix: prefix)

      {page, next_cursor} = split_list_versions_page(rows, page_size)

      {:ok, Pagination.page_response(page, next_cursor)}
    end
  end

  defp filter_by_list_versions_cursor(query, nil), do: query

  defp filter_by_list_versions_cursor(query, {version_number, version_id}) do
    from(v in query,
      where: {v.version_number, v.version_id} < {^version_number, ^version_id}
    )
  end

  defp decode_list_versions_cursor(nil), do: {:ok, nil}

  defp decode_list_versions_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(
           raw,
           @list_versions_cursor_prefix,
           byte_size(@list_versions_cursor_prefix)
         ) do
      {:ok, %Pagination.Cursor{} = cursor} -> decode_list_versions_seek(cursor)
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # `inner` is `"RV:<mint_time_us>:<version_id>:<version_number>"` -- the
  # first slot after the prefix is always the mint-time timestamp
  # decode_cursor/4's expiry check reads, never a domain value (same idiom
  # `Letflow.Definitions`' cursor helpers use).
  defp decode_list_versions_seek(%Pagination.Cursor{inner: inner}) do
    case Pagination.decode_seek_parts(inner, @list_versions_cursor_prefix, [:skip, :uuid, :int]) do
      {:ok, [version_id, version_number]} -> {:ok, {version_number, version_id}}
      {:error, :invalid_cursor} = error -> error
    end
  end

  defp split_list_versions_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_versions_next_cursor(List.last(page))}
  end

  defp split_list_versions_page(rows, _page_size), do: {rows, nil}

  defp build_list_versions_next_cursor(%ArtifactVersion{
         version_id: version_id,
         version_number: version_number
       }) do
    mint_time_us = System.system_time(:microsecond)

    @list_versions_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(mint_time_us, version_id, version_number)
    |> Pagination.encode_cursor()
  end
end
