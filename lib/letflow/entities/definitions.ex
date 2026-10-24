defmodule Letflow.Entities.Definitions do
  @moduledoc """
  Tenant-scoped CRUD context module for `entity_definitions` (REQ-226). See
  `lib/letflow/design/req226-entity-definitions-persistence-crud.md` §3 for
  the full design this module implements: §3.3 (`create_definition/2`'s
  exact ordering guarantee and `list_definitions/3`'s REQ-067 cursor
  contract) and §3.4 (`activate_definition/4`'s thin wrapper over REQ-203's
  existing activation machinery).

  This is the **context-module** third of the document/schema/context
  three-way split named in the design's §3.1:
  `Letflow.Entities.Definition` (REQ-225) is the plain document `@type`;
  `Letflow.Entities.EntityDefinition` (REQ-226) is the persisted-row
  `Ecto.Schema`; this module is the tenant-scoped CRUD context module that
  depends on both, plus `Letflow.Entities.Definition.Validator`,
  `Letflow.Entities.Definition.Shape`, and `Letflow.Repository`/
  `Letflow.Repository.Activation` (REQ-202/REQ-203's existing pipelines) --
  never the reverse.

  Tenant scoping follows the same convention every other context module in
  this codebase uses (`Letflow.Repository`, `Letflow.Repository.Activation`,
  `Letflow.Audit`): every public function takes an explicit
  `prefix :: String.t()` argument and derives `tenant_id` from it via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`. No function in
  this module accepts a separately-trusted, caller-supplied `tenant_id`.

  ## `create_definition/2` reuses `Letflow.Repository.create/2` unmodified
  (design §3.3, §4)

  No independent canonicalisation, hashing, or dedup logic lives in this
  module -- REQ-202's `create/2` pipeline is called, not reimplemented, per
  REQ-226's own text. REQ-226 accepted a cost of this reuse (design §6 OQ-1):
  a same-name/same-shape resubmission minted a redundant `artifact_versions`
  row before being rejected at the `entity_definitions` layer by the
  `(tenant_id, name, logical_shape_version)` UNIQUE constraint (design §4
  Scenario B). Since REQ-496 (Revision 2) that cost is gone: the whole create
  runs in one transaction and every error branch rolls it back, so the
  rejected attempt's `artifact_versions` row is rolled back with it. This
  applies to EVERY error, `{:repository, _}` and `{:validation, _}` included,
  not only `{:persistence, _}`; the returned `{:error, reason}` terms are
  unchanged.

  ## `managed_by` (REQ-496, decision 0050 D7)

  `create_definition/3` takes the caller's `Letflow.Entities.ManagedTypes.owner()`
  (`create_definition/2` means `:tenant`). Inside the create transaction it
  first takes the per-(tenant, name) advisory lock, then asks
  `ManagedTypes.check_create/3` whether this owner may create the name and
  whether the new row is stamped; see
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §2.5.

  ## Activation reuses REQ-203's existing machinery -- no new mechanism
  (design §3.4)

  `activate_definition/4` calls `Letflow.Repository.Activation.activate_group/5`
  unchanged with `artifact_kind: :entity`, then -- only on that call's own
  success -- updates the matching `entity_definitions` row's `status` to
  `:active` via a plain `Ecto.Changeset`/`Repo.update`, not itself wrapped in
  `activate_group/5`'s transaction. No new activation table, pointer, or
  history mechanism is added by this requirement.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Entities.Definition
  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definition.Shape
  alias Letflow.Entities.Definition.Validator
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.ProcessWritable
  alias Letflow.Entities.TypeAccess
  alias Letflow.Entities.Record.Decimals
  alias Letflow.Entities.Record.Latest
  alias Letflow.Api.Pagination
  alias Letflow.EventStore
  alias Letflow.Repo
  alias Letflow.Repository
  alias Letflow.Repository.Activation
  alias Letflow.TenantProvisioning

  @list_definitions_cursor_prefix "ED:"

  @type create_attrs :: %{
          required(:definition) => Definition.t(),
          required(:created_by) => Ecto.UUID.t()
        }

  @type create_error ::
          {:error, {:validation, [Validator.violation()]}}
          | {:error, {:repository, term()}}
          | {:error, {:persistence, Ecto.Changeset.t()}}
          | {:error, :invalid_schema_name}
          | {:error, :entity_type_managed}
          | {:error, {:managed_name_taken, String.t()}}

  @typedoc "REQ-067's opts shape for `list_definitions/3` -- see design §3.3."
  @type list_definitions_filters :: %{
          optional(:cursor) => String.t() | nil,
          optional(:page_size) => pos_integer() | nil
        }

  @doc """
  Creates a new `entity_definitions` row (design §3.3), scoped to the tenant
  schema named by `prefix`, as the tenant: `create_definition(attrs, prefix,
  :tenant)`. See `create_definition/3`.
  """
  @spec create_definition(create_attrs(), prefix :: String.t()) ::
          {:ok, EntityDefinition.t()} | create_error()
  def create_definition(attrs, prefix), do: create_definition(attrs, prefix, :tenant)

  @doc """
  Creates a new `entity_definitions` row (design §3.3) on behalf of `owner`,
  scoped to the tenant schema named by `prefix`. Steps 0a-4 run inside one
  `Repo.transaction/1` (joining the caller's transaction when there is one),
  and every error branch rolls it back with the unchanged error term (REQ-496
  design §2.5, Revision 2):

    0a. When the definition's `:name` is in the managed-name format, takes the
        per-(tenant, name) advisory lock (`ManagedTypes.lock_names/2`).
    0. `ManagedTypes.check_create/3` -- on an error, returns it immediately:
       no Validator call, no write.
    1. `Letflow.Entities.Definition.Validator.validate/1` -- on
       `{:error, violations}`, returns `{:error, {:validation, violations}}`.
    1a. `Letflow.Entities.ProcessWritable.check_settable/3` (GH #2587, GH #2618)
        -- the write class of the type is resolved first (`write_class_for/4`:
        a new version inherits the class of its type's rows; a fresh type is
        `managed` when module-stamped, else `ordinary`). A definition declaring
        `writable_by_process: true` on a module-managed type or on a class other
        than `ordinary` returns `{:error, {:validation, [violation]}}` (rule
        `:writable_by_process_not_permitted`); no write.
    2. On `:ok`, computes `content_hash`/`logical_shape_version` via
       `Letflow.Entities.Definition.Shape`.
    3. Calls `Letflow.Repository.create/2` with `artifact_kind: :entity` --
       REQ-202's existing canonicalise-hash-dedup-version pipeline, not
       reimplemented. A `{:error, reason}` here is returned as
       `{:error, {:repository, reason}}`.
    4. Inserts one `entity_definitions` row referencing the returned
       `artifact_version_id`, `status: :inactive`, stamped with `managed_by`
       when step 0 returned a module id. A UNIQUE-constraint failure here is
       returned as `{:error, {:persistence, changeset}}`, and step 3's
       `repository_artifacts`/`artifact_versions` writes roll back with it.
    5. On success, returns `{:ok, %Letflow.Entities.EntityDefinition{}}`.
  """
  @spec create_definition(create_attrs(), prefix :: String.t(), ManagedTypes.owner()) ::
          {:ok, EntityDefinition.t()} | create_error()
  def create_definition(%{definition: definition, created_by: created_by}, prefix, owner)
      when is_binary(prefix) do
    Repo.transaction(fn ->
      case do_create_definition(definition, created_by, prefix, owner) do
        {:ok, entity_definition} -> entity_definition
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp do_create_definition(definition, created_by, prefix, owner) do
    name = Map.get(definition, :name)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         :ok <- ManagedTypes.lock_names([name], prefix),
         {:ok, stamp} <- ManagedTypes.check_create(name, owner, prefix),
         :ok <- validate_definition(definition),
         write_class = write_class_for(name, stamp, prefix, tenant_id),
         :ok <- ProcessWritable.check_settable(definition, stamp, write_class) do
      content_hash = Shape.content_hash(definition)
      logical_shape_version = Shape.logical_shape_of(definition)

      repository_attrs = %{
        artifact_kind: :entity,
        artifact_name: Map.fetch!(definition, :name),
        content_type: "application/json",
        content: Jason.encode!(definition),
        created_by: created_by
      }

      case Repository.create(repository_attrs, prefix) do
        {:error, reason} ->
          {:error, {:repository, reason}}

        {:ok, %Repository.ArtifactVersion{version_id: artifact_version_id}} ->
          insert_entity_definition(
            tenant_id,
            definition,
            content_hash,
            logical_shape_version,
            artifact_version_id,
            stamp,
            write_class,
            prefix
          )
      end
    end
  end

  # GH #2618 (decision 0054 D4a.2 amendment, items 3 and 8): the write class of the new row, read under
  # the name's advisory lock. `managed` when a row of the name carries `managed_by` or the new version is
  # module-stamped with no earlier row; otherwise the class of the name's existing rows (a version bump
  # cannot change it). Mixed classes under one name cannot arise (classes are set per name), and fall back
  # to `managed`, which refuses the flag: fail closed. A fresh tenant type is `ordinary`.
  defp write_class_for(name, stamp, prefix, tenant_id) do
    rows =
      from(e in EntityDefinition,
        where: e.tenant_id == ^tenant_id and e.name == ^name,
        select: {e.write_class, e.managed_by}
      )
      |> Repo.all(prefix: prefix)

    classes = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    cond do
      Enum.any?(rows, fn {_class, managed_by} -> not is_nil(managed_by) end) -> "managed"
      rows == [] and is_binary(stamp) -> "managed"
      rows == [] -> "ordinary"
      match?([_one], classes) -> hd(classes)
      true -> "managed"
    end
  end

  defp validate_definition(definition) do
    case Validator.validate(definition) do
      :ok -> :ok
      {:error, violations} -> {:error, {:validation, violations}}
    end
  end

  defp insert_entity_definition(
         tenant_id,
         definition,
         content_hash,
         logical_shape_version,
         artifact_version_id,
         stamp,
         write_class,
         prefix
       ) do
    attrs = %{
      tenant_id: tenant_id,
      name: Map.fetch!(definition, :name),
      display_name: Map.fetch!(definition, :display_name),
      definition_json: definition,
      content_hash: content_hash,
      logical_shape_version: logical_shape_version,
      artifact_version_id: artifact_version_id,
      status: :inactive
    }

    %EntityDefinition{}
    |> EntityDefinition.changeset(attrs)
    |> maybe_put_managed_by(stamp)
    |> EntityDefinition.put_write_class(write_class)
    |> Repo.insert(prefix: prefix)
    |> case do
      {:ok, entity_definition} -> {:ok, entity_definition}
      {:error, changeset} -> {:error, {:persistence, changeset}}
    end
  end

  defp maybe_put_managed_by(changeset, nil), do: changeset

  defp maybe_put_managed_by(changeset, module_id) when is_binary(module_id),
    do: EntityDefinition.put_managed_by(changeset, module_id)

  @doc """
  Fetches one `entity_definitions` row by `id`, scoped to the tenant schema
  named by `prefix` (design §3.3). Never raises `Ecto.NoResultsError` --
  `nil` becomes `{:error, :not_found}`, matching this codebase's established
  tagged-tuple-for-a-caller-triggerable-not-found convention
  (`Letflow.Repository.Activation.resolve/3`'s own `{:error, :not_found}`-shaped
  return, adapted, is the direct precedent).
  """
  @spec get_definition(id :: Ecto.UUID.t(), prefix :: String.t()) ::
          {:ok, EntityDefinition.t()}
          | {:error, :not_found}
          | {:error, :invalid_schema_name}
  def get_definition(id, prefix) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      case Repo.get(EntityDefinition, id, prefix: prefix) do
        nil -> {:error, :not_found}
        %EntityDefinition{} = entity_definition -> {:ok, entity_definition}
      end
    end
  end

  @doc """
  Fetches one `entity_definitions` row by `name`, scoped to the tenant
  schema named by `prefix` (design §3.3). Same not-found semantics as
  `get_definition/2`.

  This finds the **newest row by this name, regardless of status** --
  NOT "the active" row (see `get_active_definition_by_name/2` for that).
  `name` alone is not unique in `entity_definitions` -- REQ-225/226's own
  versioning model allows 2+ rows to share one `name` under distinct
  `logical_shape_version`s -- so the query is ordered `inserted_at desc, id
  desc` (the same "latest by name" ordering idiom `list_definitions/3`
  already uses) and limited to 1, resolving deterministically to the newest
  row instead of raising `Ecto.MultipleResultsError` once 2+ rows exist
  (ISS-0519 fix, `lib/letflow/design/iss0519-entity-definition-versioning-fix.md`
  §3).
  """
  @spec get_definition_by_name(name :: String.t(), prefix :: String.t()) ::
          {:ok, EntityDefinition.t()}
          | {:error, :not_found}
          | {:error, :invalid_schema_name}
  def get_definition_by_name(name, prefix) when is_binary(name) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query =
        from(e in EntityDefinition,
          where: e.name == ^name,
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: 1
        )

      case Repo.one(query, prefix: prefix) do
        nil -> {:error, :not_found}
        %EntityDefinition{} = entity_definition -> {:ok, entity_definition}
      end
    end
  end

  @typedoc "ISS-0519 fix design §4.1 -- `get_active_definition_by_name/2`'s error shape."
  @type get_active_definition_error ::
          {:error, :not_found}
          | {:error, :invalid_schema_name}

  @doc """
  Fetches the `entity_definitions` row that corresponds to `name`'s
  **currently activated** `artifact_version_id`, scoped to the tenant schema
  named by `prefix` -- ISS-0519 fix (B),
  `lib/letflow/design/iss0519-entity-definition-versioning-fix.md` §4.

  Unlike `get_definition_by_name/2` (newest row by `inserted_at`),  this
  resolves via REQ-203's authoritative activation pointer
  (`Letflow.Repository.Activation.resolve/3`), not via this table's own
  `status` column or row recency -- the two can disagree (an older version
  explicitly re-activated after a newer one was created), and this function
  is the one that must not get that wrong.

  Never raises on a data-integrity edge case a caller cannot prevent (e.g. an
  `artifact_activations` pointer referencing a version this module never
  wrote) -- returns `{:error, :not_found}` instead of a `Repo.get!`-style
  raise.
  """
  @spec get_active_definition_by_name(name :: String.t(), prefix :: String.t()) ::
          {:ok, EntityDefinition.t()} | get_active_definition_error()
  def get_active_definition_by_name(name, prefix)
      when is_binary(name) and is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      case Activation.resolve(:entity, name, prefix) do
        {:error, :not_activated} ->
          {:error, :not_found}

        {:error, :invalid_schema_name} = error ->
          error

        {:ok, %Repository.ArtifactVersion{version_id: version_id}} ->
          query =
            from(e in EntityDefinition,
              where: e.tenant_id == ^tenant_id and e.artifact_version_id == ^version_id
            )

          case Repo.one(query, prefix: prefix) do
            nil -> {:error, :not_found}
            %EntityDefinition{} = entity_definition -> {:ok, entity_definition}
          end
      end
    end
  end

  @doc """
  The `decimal_strict` field specs of the active version of `entity_type`
  (decision 0060), as `Decimals.render_field_values/2` consumes them.

  `%{}` when the type has no active definition or declares no strict field,
  which makes `render_field_values/2` a no-op. Shared by every router that
  returns a stored `field_values` map to a caller (entities router, exam
  list route), so they render a strict field identically.
  """
  @spec strict_specs(entity_type :: String.t(), prefix :: String.t()) :: Decimals.specs()
  def strict_specs(entity_type, prefix) when is_binary(entity_type) and is_binary(prefix) do
    case get_active_definition_by_name(entity_type, prefix) do
      {:ok, %{definition_json: definition_json}} ->
        Decimals.specs_from_definition_json(definition_json)

      _no_active_definition ->
        %{}
    end
  end

  @doc """
  Ordered, paginated listing of `entity_definitions` rows (design §3.3,
  REQ-067's cursor contract), scoped to the tenant schema named by `prefix`.
  Newest first (`inserted_at desc, id desc`).

  Tenant scoping (AC5) is structural here exactly the way
  `Letflow.Repository.list_versions/4`'s moduledoc states it: because
  `entity_definitions` lives in a per-tenant Postgres schema, a query scoped
  to `prefix` cannot return another tenant's rows regardless of what a
  cursor decodes to -- the `tenant_id` WHERE clause below is the same
  belt-and-suspenders discipline every Decision-B table carries, not the
  sole isolation mechanism.

  Per-type authorization (GH #2739, INV-2/INV-5): rows whose `name` is denied to
  `user_id` by `Letflow.Entities.TypeAccess` are excluded INSIDE the one
  statement (`TypeAccess.visible_to/2`), ANDed into the WHERE with `tenant_id`
  and the keyset predicate before `ORDER BY`/`LIMIT`, so pages and
  `next_cursor` are computed over visible rows only. Any future filter must
  compose with AND after that predicate, never before or instead of it. There is
  no unscoped sibling: the viewer is a required argument.
  """
  @spec list_definitions(
          user_id :: String.t(),
          list_definitions_filters(),
          prefix :: String.t()
        ) ::
          {:ok, Pagination.Page.t(EntityDefinition.t())}
          | {:error, :invalid_schema_name}
          | {:error, :page_size_too_large}
          | {:error, :wrong_endpoint}
          | {:error, :expired}
          | {:error, :invalid_cursor}
  def list_definitions(user_id, filters, prefix)
      when is_binary(user_id) and is_map(filters) and is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, page_size} <- Pagination.validate_page_size(Map.get(filters, :page_size)),
         {:ok, cursor_seek} <- decode_list_definitions_cursor(Map.get(filters, :cursor)) do
      rows =
        from(e in EntityDefinition, as: :def)
        |> where([e], e.tenant_id == ^tenant_id)
        |> filter_by_list_definitions_cursor(cursor_seek)
        |> where(^TypeAccess.visible_to(user_id, :def))
        |> order_by([e], desc: e.inserted_at, desc: e.id)
        |> limit(^(page_size + 1))
        |> Repo.all(prefix: prefix)

      {page, next_cursor} = split_list_definitions_page(rows, page_size)

      {:ok, Pagination.page_response(page, next_cursor)}
    end
  end

  defp filter_by_list_definitions_cursor(query, nil), do: query

  defp filter_by_list_definitions_cursor(query, {inserted_at, id}) do
    from(e in query, where: {e.inserted_at, e.id} < {^inserted_at, ^id})
  end

  defp decode_list_definitions_cursor(nil), do: {:ok, nil}

  defp decode_list_definitions_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(
           raw,
           @list_definitions_cursor_prefix,
           byte_size(@list_definitions_cursor_prefix)
         ) do
      {:ok, %Pagination.Cursor{} = cursor} -> decode_list_definitions_seek(cursor)
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # `inner` is `"ED:<mint_time_us>:<id>:<inserted_at_us>"` -- the first slot
  # after the prefix is always the mint-time timestamp decode_cursor/4's
  # expiry check reads, never a domain value (same idiom
  # `Letflow.Repository.Activation.list_history/4`'s cursor helpers use).
  @spec decode_list_definitions_seek(Pagination.Cursor.t()) ::
          {:ok, {DateTime.t(), Ecto.UUID.t()}} | {:error, :invalid_cursor}
  defp decode_list_definitions_seek(%Pagination.Cursor{inner: inner}) do
    case Pagination.decode_seek_parts(inner, @list_definitions_cursor_prefix, [
           :skip,
           :uuid,
           :datetime_us
         ]) do
      {:ok, [id, inserted_at]} -> {:ok, {inserted_at, id}}
      {:error, :invalid_cursor} = error -> error
    end
  end

  defp split_list_definitions_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_definitions_next_cursor(List.last(page))}
  end

  defp split_list_definitions_page(rows, _page_size), do: {rows, nil}

  defp build_list_definitions_next_cursor(%EntityDefinition{id: id, inserted_at: inserted_at}) do
    mint_time_us = System.system_time(:microsecond)
    inserted_at_us = DateTime.to_unix(inserted_at, :microsecond)

    @list_definitions_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(mint_time_us, id, inserted_at_us)
    |> Pagination.encode_cursor()
  end

  @doc """
  Activates `name`'s current `artifact_version_id` (design §3.4) -- a thin
  wrapper around `Letflow.Repository.Activation.activate_group/5`, unchanged,
  with `artifact_kind: :entity`. On that call's own success, promotes the
  matching `entity_definitions` row's `status` to `:active`. Adds no new
  activation table, pointer, or history mechanism.

  ISS-0519 fix (C),
  `lib/letflow/design/iss0519-entity-definition-versioning-fix.md` §5.1: the
  `entity_definitions`-side effect is now internally transactional (a
  separate transaction from `activate_group/5`'s own, unchanged from before)
  and demotes every OTHER row under the same `(tenant_id, name)` back to
  `:inactive` BEFORE promoting the target row to `:active`. This ordering is
  load-bearing, not stylistic: newly inserted rows default to `status:
  :inactive` (`insert_entity_definition/7`), so at most one sibling can be
  `:active` before this function runs; demoting that sibling first drops the
  active count for `(tenant_id, name)` to 0 before promote-self raises it
  back to exactly 1, so the partial unique index
  `entity_definitions_tenant_name_active_idx` (added by this fix) is never
  even transiently violated at any statement boundary. Reversing the order
  (promote before demote) would create a real transient two-`:active`-rows
  window and fail that constraint.

  ## `decimal_strict` immutability gate (GH #2654, decision 0060)

  The `decimal_strict` flag of a `:decimal` field cannot change while its entity
  type has any record (any row of `entity_record_latest`, soft-deleted included):
  a legacy number could otherwise sit under a strict flag. EVERY activation runs in
  ONE outer transaction that first takes a per-(tenant, type) advisory lock (so
  activations of one type serialize and the next decision is made from a read under
  it, not from a stale pre-read). When a `decimal_strict` key is on the target or the
  currently active definition, it then takes the type's `instance_sequences` row lock
  (the lock every record writer takes; the type's instance row is created if absent,
  as the first write would), re-reads the active definition under it, compares the
  SET of strict decimal field names (a strict field removed or retyped is a
  difference; a non-strict decimal added, removed or retyped is not) and refuses with
  `{:error, {:decimal_strict_change, field_names}}` (rolling everything back, no
  activation pointer written) when they differ and the type has a record. It then
  runs `activate_group/5` and `promote_and_demote_siblings/2` in that same
  transaction. A first activation and an empty type are never refused.
  `ensure_column_promotions/2` stays AFTER the transaction commits (ISS-0648). With
  no `decimal_strict` key on either side there is no sequence lock and no instance
  row. Neither lock has a `lock_timeout`: an activation waits behind a long handler
  transaction on the same type, like any writer.
  """
  @spec activate_definition(
          name :: String.t(),
          activator_user_id :: Ecto.UUID.t(),
          rationale :: String.t(),
          prefix :: String.t()
        ) ::
          {:ok, EntityDefinition.t()}
          | {:error, :not_found}
          | {:error, :empty_group}
          | {:error, :duplicate_artifact_in_group}
          | {:error, :invalid_schema_name}
          | {:error, {:group, Ecto.Changeset.t()}}
          | {:error, {:persistence, Ecto.Changeset.t()}}
          | {:error, {atom(), Ecto.Changeset.t()}}
          | {:error, {:transaction_failed, Exception.t()}}
          | {:error, {:decimal_strict_change, [String.t()]}}
  def activate_definition(name, activator_user_id, rationale, prefix)
      when is_binary(name) and is_binary(prefix) do
    with {:ok, entity_definition} <- get_definition_by_name(name, prefix),
         {:ok, promoted} <-
           gated_activation(entity_definition, activator_user_id, rationale, prefix) do
      ensure_column_promotions(promoted, prefix)
      {:ok, promoted}
    end
  end

  defp activate_row(%EntityDefinition{} = entity_definition, user_id, rationale, prefix) do
    with {:ok, _result} <-
           Activation.activate_group(
             [
               %{
                 artifact_kind: :entity,
                 artifact_name: entity_definition.name,
                 version_id: entity_definition.artifact_version_id
               }
             ],
             user_id,
             rationale,
             prefix
           ) do
      promote_and_demote_siblings(entity_definition, prefix)
    end
  end

  # GH #2654 section 5. ONE outer transaction for every entity-definition activation:
  #
  #   1. a per-(tenant, type) advisory lock (S1): activations of one type serialize, so the
  #      "is a decimal_strict key in play" decision below is made from a read taken UNDER
  #      it, never from a pre-read outside any lock (a concurrent strict activation could
  #      otherwise commit between the read and the flip);
  #   2. only when a decimal_strict key is on the target or the CURRENT active definition:
  #      the type's instance row (created if absent, as the first write would) and its
  #      sequence-row lock, the lock every record writer takes -- then the strictness
  #      comparison and the records check. With no key on either side there is nothing to
  #      protect: no sequence lock, no instance row (the process-write prepare contract
  #      "an unprepared type has no instance row" is untouched);
  #   3. activate_group + promote_and_demote_siblings in the same transaction.
  #
  # Every error branch is Repo.rollback/1 with no further query in between (a failed inner
  # Multi marks this transaction rollback-only). Neither lock has a lock_timeout (S4): an
  # activation waits behind a long handler transaction on the same type, as every writer
  # does. ensure_column_promotions/2 stays after the commit (ISS-0648).
  defp gated_activation(
         %EntityDefinition{name: name} = entity_definition,
         user_id,
         rationale,
         prefix
       ) do
    Repo.transaction(fn ->
      with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
           :ok <- lock_activation(tenant_id, name),
           {:ok, in_play?} <- decimal_strict_in_play?(entity_definition, prefix),
           :ok <- lock_and_check_strictness(in_play?, entity_definition, prefix),
           {:ok, promoted} <- activate_row(entity_definition, user_id, rationale, prefix) do
        promoted
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Transaction-scoped; own namespace (ManagedTypes' create lock is 496_001). The key text
  # is a bound parameter (INV-7).
  @activation_lock_namespace 265_401

  defp lock_activation(tenant_id, name) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock($1::int, hashtext($2))",
      [@activation_lock_namespace, "#{tenant_id}:#{name}"]
    )

    :ok
  end

  defp decimal_strict_in_play?(%EntityDefinition{name: name} = target, prefix) do
    if has_strict_key?(target) do
      {:ok, true}
    else
      case get_active_definition_by_name(name, prefix) do
        {:ok, %EntityDefinition{} = current} -> {:ok, has_strict_key?(current)}
        {:error, :not_found} -> {:ok, false}
        {:error, :invalid_schema_name} = error -> error
      end
    end
  end

  defp has_strict_key?(%EntityDefinition{definition_json: json}) do
    json
    |> Map.get("fields", [])
    |> Enum.any?(&(is_map(&1) and Map.has_key?(&1, "decimal_strict")))
  end

  defp lock_and_check_strictness(false, _entity_definition, _prefix), do: :ok

  defp lock_and_check_strictness(true, %EntityDefinition{name: name} = entity_definition, prefix) do
    with {:ok, instance_id} <- EntityTypeInstance.get_or_create(name, prefix),
         {:ok, :locked} <- EventStore.lock_instance_sequence(Repo, instance_id, prefix) do
      ensure_strictness_unchanged(entity_definition, prefix)
    end
  end

  # Under the type's sequence lock: the CURRENT active version is re-read here (the
  # pointer may have moved since the cheap pre-read), its strict decimal field set is
  # compared with the target's, and a difference is refused when any record exists.
  defp ensure_strictness_unchanged(%EntityDefinition{name: name} = target, prefix) do
    case get_active_definition_by_name(name, prefix) do
      {:error, :not_found} ->
        :ok

      {:error, :invalid_schema_name} = error ->
        error

      {:ok, %EntityDefinition{} = current} ->
        case strict_difference(current, target) do
          [] -> :ok
          fields -> refuse_if_records(fields, name, prefix)
        end
    end
  end

  defp refuse_if_records(fields, entity_type, prefix) do
    if Repo.exists?(from(l in Latest, where: l.entity_type == ^entity_type), prefix: prefix),
      do: {:error, {:decimal_strict_change, fields}},
      else: :ok
  end

  defp strict_difference(%EntityDefinition{} = current, %EntityDefinition{} = target) do
    current_set = strict_decimal_names(current)
    target_set = strict_decimal_names(target)

    current_set
    |> MapSet.symmetric_difference(target_set)
    |> Enum.sort()
  end

  defp strict_decimal_names(%EntityDefinition{definition_json: json}) do
    json
    |> Map.get("fields", [])
    |> Enum.filter(
      &(is_map(&1) and Map.get(&1, "type") == "decimal" and Map.get(&1, "decimal_strict") == true)
    )
    |> MapSet.new(&Map.get(&1, "name"))
  end

  # ISS-0519 fix (C), design §5.1 steps 3-4: demote every OTHER
  # entity_definitions row under this (tenant_id, name) to :inactive via a
  # set-based Repo.update_all/3 (no per-row changeset needed for a
  # single-field status flip), THEN promote the target row to :active --
  # both inside one Ecto.Multi/Repo.transaction/1, demote-before-promote, per
  # the ordering rationale in this function's own moduledoc above.
  defp promote_and_demote_siblings(%EntityDefinition{} = entity_definition, prefix) do
    demote_siblings_query =
      from(e in EntityDefinition,
        where:
          e.tenant_id == ^entity_definition.tenant_id and
            e.name == ^entity_definition.name and
            e.id != ^entity_definition.id and
            e.status == :active
      )

    promote_changeset = EntityDefinition.changeset(entity_definition, %{status: :active})

    Ecto.Multi.new()
    |> Ecto.Multi.update_all(:demote_siblings, demote_siblings_query, [set: [status: :inactive]],
      prefix: prefix
    )
    |> Ecto.Multi.update(:promote, promote_changeset, prefix: prefix)
    |> Repo.transaction()
    |> case do
      {:ok, %{promote: promoted}} -> {:ok, promoted}
      {:error, :promote, changeset, _changes} -> {:error, {:persistence, changeset}}
    end
  end

  # ISS-0648 fix (lib/letflow/design/iss0648-pack-install-column-promotion-trigger.md
  # §2): triggers column promotion, AFTER `activate_definition/4`'s own
  # activation transaction has already committed (never nested inside it --
  # §2.1's own retry-boundary reasoning), for every attribute that appears
  # in at least one of `promoted`'s declared `constraint_def.fields` entries
  # -- closing the gap where a `constraints: [{type: unique, ...}]` entry
  # compiled into real DDL (REQ-298) but nothing ever ran that DDL, so the
  # constraint it documents was never actually enforced (ISS-0648's own
  # empirical repro).
  #
  # Always returns `:ok` -- this function's own result NEVER changes
  # `activate_definition/4`'s `{:ok, promoted}` into an error. This is
  # deliberate, not an oversight (design §2.3): a promotion stuck at
  # "pending"/"ddl_failed" is a named, expected, retryable state (0024 §2),
  # and failing activation over it would make an entity type permanently
  # unwritable (only `:active` definitions accept writes) over a condition
  # 0024 already treats as normal degraded operation. Every failure is
  # still logged loudly (`Logger.error/2`) so it is discoverable via the
  # `entity_column_promotions` table's own `status`/`last_error` columns.
  @spec ensure_column_promotions(promoted :: EntityDefinition.t(), prefix :: String.t()) :: :ok
  defp ensure_column_promotions(%EntityDefinition{} = promoted, prefix) do
    document = TenantProvisioning.document_from_persisted(promoted)

    case Map.get(document, :constraints, []) do
      [] ->
        :ok

      constraints ->
        trigger_column_promotions_for_constraints(promoted, document, constraints, prefix)
    end
  end

  defp trigger_column_promotions_for_constraints(promoted, document, constraints, prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:error, :invalid_schema_name} ->
        # Realistically unreachable -- `prefix` already resolved successfully
        # one line above in `activate_definition/4` -- but this function's
        # own contract (§2.3) is "never raise, always :ok," so this is
        # handled as a loud no-op rather than assumed impossible.
        Logger.error(
          "ensure_column_promotions/2: invalid_schema_name resolving tenant_id " <>
            "for prefix=#{inspect(prefix)} entity_type=#{inspect(promoted.name)} -- " <>
            "constraint enforcement was not (re-)triggered by this activation"
        )

        :ok

      {:ok, tenant_id} ->
        constrained_field_names =
          constraints |> Enum.flat_map(&Map.get(&1, :fields, [])) |> MapSet.new()

        document
        |> DDL.promoted_columns()
        |> Enum.filter(&MapSet.member?(constrained_field_names, Map.get(&1, :name)))
        |> Enum.each(&ensure_one_column_promotion(promoted.name, &1, tenant_id))

        :ok
    end
  end

  # Per-attribute (design §2.2): `register_column_promotion/4` is keyed by
  # `(tenant_id, entity_type, attribute)`, not by constraint, so each
  # constrained column is registered independently. Idempotent (design
  # §2.4): if a `ColumnPromotion` row already exists for this exact key
  # (a re-activation of the same entity type/version, or of a later
  # version that still declares the same constrained field), this skips
  # straight to `:ok` rather than attempting a second
  # `register_column_promotion/4` insert, which would otherwise hit the
  # `entity_column_promotions` unique index.
  defp ensure_one_column_promotion(entity_type, column, tenant_id) do
    attribute = Map.get(column, :name)

    if TenantProvisioning.column_promotion_registered?(tenant_id, entity_type, attribute) do
      :ok
    else
      register_and_run_column_promotion(entity_type, attribute, column, tenant_id)
    end
  end

  defp register_and_run_column_promotion(entity_type, attribute, column, tenant_id) do
    column_spec = %{
      pg_type: Map.fetch!(column, :pg_type),
      nullable: true,
      references_entity: Map.get(column, :references_entity),
      generated_as: Map.get(column, :generated_as)
    }

    case TenantProvisioning.register_column_promotion(entity_type, attribute, column_spec, [
           tenant_id
         ]) do
      {:ok, [row]} ->
        run_registered_column_promotion(row, entity_type, attribute, tenant_id)

      {:error, reason} ->
        Logger.error(
          "ensure_column_promotions/2: register_column_promotion/4 failed " <>
            "entity_type=#{inspect(entity_type)} attribute=#{inspect(attribute)} " <>
            "tenant_id=#{inspect(tenant_id)} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  # Design §2.2 step 7 / §2.2's own "why `run_column_promotion/1` only"
  # reasoning: never `backfill_column_promotion/1`/`activate_column_promotion/1`.
  # `run_column_promotion/1` alone (CREATE TABLE + first-population backfill,
  # landing at "ddl_applied") is already sufficient for every future
  # create/update to be checked against the real Postgres UNIQUE constraint
  # via `Records.dual_write_promoted_columns/3` -- see design §2.2 for why
  # driving further, to "active", would be strictly worse for this fix's
  # purpose (ISS-0649).
  defp run_registered_column_promotion(row, entity_type, attribute, tenant_id) do
    case TenantProvisioning.run_column_promotion(row.id) do
      {:ok, %TenantProvisioning.ColumnPromotion{}} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "ensure_column_promotions/2: run_column_promotion/1 failed " <>
            "entity_type=#{inspect(entity_type)} attribute=#{inspect(attribute)} " <>
            "tenant_id=#{inspect(tenant_id)} promotion_id=#{inspect(row.id)} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end
end
