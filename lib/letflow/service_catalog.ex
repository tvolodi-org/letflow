defmodule Letflow.ServiceCatalog do
  @moduledoc """
  Context module for the `service_catalog` table's core lifecycle:
  `register/1`, `get_for_tenant/2`, `list_for_tenant/2`, `update_scope/2`,
  `delete/1`. See `lib/letflow/design/req191-service-catalog-core.md` for the
  full design this module implements. Plain Ecto context module, no
  process — same shape as `Letflow.Dlq`/`Letflow.Identity`.

  Ports R-Co `migrations/049_repository_service_catalog.sql` plus
  `GBL-117_svc01_service_catalog_scope.sql` (SVC-01), and supplies the real
  implementation seam three already-shipped modules (SVC-03's
  `Letflow.Definitions.ServiceScopeValidator`, PIN-01's `PinResolver`, and
  `Letflow.Definitions.SolutionPack`'s `service_catalog_entries` handling)
  already anticipate but cannot yet use.

  **Scope boundary, restated from the design (§0):** schema/migration, this
  context module's five functions, the two referential guards, a `Lookup`
  implementation for `ServiceScopeValidator`, and the explicit resolution of
  `SolutionPack`'s `service_catalog_entries` hard-fail. No route, no
  controller — that is REQ-192. No `service_scope_validator.ex` change — its
  algorithm and injectable-`Lookup` shape are frozen; this module supplies an
  implementation of that shape only. No `pin_resolver.ex` change.

  ## GLOBAL table — divergence from decision 0003 Decision B, flagged for
  ## REVIEWER sign-off

  `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B makes
  schema-per-tenant (Ecto `:prefix`-scoped tables, `tenant_id` retained
  intra-schema) the general rule for business tables. `service_catalog`
  deliberately does **not** follow that rule — it is a single table in the
  default/public schema, with no `:prefix` option on its migration and no
  registration in `Letflow.TenantProvisioning.tenant_scoped_migrations/0`.

  **R-Co-grounded reason, structural not incidental:** a `scope = :global`
  service-catalog entry is by definition referenceable by every tenant, and
  `service_id` is unique across all tenants regardless of scope (R-Co's
  SVC-01 rule, `GBL-117_svc01_service_catalog_scope.sql`). Neither property
  can be expressed by a per-tenant-schema copy: a per-tenant copy could not
  enforce global `service_id` uniqueness across schemas without a
  cross-schema mechanism Decision B doesn't provide, and a `scope = :global`
  row would need to exist identically in every tenant's schema
  simultaneously, which is not what schema-per-tenant means. This is exactly
  the same shape as REQ-041's `solution_pack_installs`/
  `solution_pack_artefact_bases`/`pack_update_resolutions`
  (`priv/repo/migrations/20260817083801_create_solution_pack_installs.exs`'s
  own moduledoc: "install records are cross-tenant infrastructure") — this
  module follows that already-accepted precedent rather than inventing a new
  one.

  No `tenant_id` column exists on this table at all — Decision B's "retain
  `tenant_id` intra-schema" clause only applies to tables that live inside a
  tenant's own schema; this table doesn't, and `owner_tenant_id` already
  carries the one tenant association this table needs.

  **REVIEWER sign-off: AGREE, 2026-08-30 (WF02-REQ191-20260830 Step 2d).**
  Full reasoning recorded in
  `lib/letflow/design/req191-service-catalog-core.md` §0 — this is a real
  architectural decision (a global table is a different security/scaling
  surface than schema-per-tenant), signed off on independent structural
  grounds, not on the `solution_pack_installs` precedent alone.

  ## No `opts[:prefix]` on any function

  Unlike every other S6 context module, this one's backing table is global,
  so there is no tenant schema to scope queries into. Every function instead
  takes an explicit `tenant_id :: Ecto.UUID.t()` argument where visibility
  needs to be resolved (`get_for_tenant/2`, `list_for_tenant/2`), or a
  registered-tenant lookup where existence needs confirming (`register/1`).

  ## Function arity — a deliberate deviation from the design's provisional
  ## `register/2`/`delete/2` naming (design §7 OQ-1)

  The design doc's own §7 OQ-1 leaves `register/2`'s exact arity open,
  noting only that a documented reason may justify diverging from the
  requirement text's provisional "register/2"/"delete/2" naming. This module
  implements `register/1` and `delete/1`: both functions' second "argument"
  in the design's own prose was either an injectable tenant-existence-check
  function (resolved here instead via a direct `Letflow.Identity.Tenant`
  query, per the design's own permitted alternative) or an `opts` slot this
  module has nothing to put in it (no `:prefix` — see above). Adding an
  unused `opts \\\\ []` parameter to either function purely to preserve a
  surface-level arity match would be exactly the kind of unneeded
  abstraction `CLAUDE.md`'s "match effort to the active stage" rule
  forbids. `get_for_tenant/2`, `list_for_tenant/2`, and `update_scope/2` keep
  their full two real-argument arity because both arguments in each case are
  genuine business inputs, not a stand-in for a slot this module doesn't use.

  ## SVC-04 permissions (REQ-069) — not wired here, and not contradicted

  `:ServicesRead`, `:AdminServicesRead`, `:AdminServicesManage`
  (`Letflow.Api.Authorization`) are the already-shipped permission names for
  this catalog's future HTTP surface. This requirement has no route layer,
  so no permission is enforced here — REQ-192 wires the route/permission
  pairing. This moduledoc names them only so a future reader of this module
  doesn't independently invent a different name for the same concept.

  ## REQ-373 — version/status lifecycle: THE SCHEMA DECISION (design
  ## `lib/letflow/design/req373-service-catalog-version-lifecycle.md` §1)

  **Decision: in-place `version`/`version_id`/`status`/`published_at`/
  `retired_at` columns on `service_catalog` (representing the single CURRENT
  version) plus a new sibling table `service_catalog_versions`
  (`Letflow.ServiceCatalog.Version`) archiving every version a `publish/3` or
  `retire/1` supersedes.** Not composite-key-versioned-table.

  **Reasoning:**

    1. The START-time consuming contract never asks for a specific version —
       `Letflow.Engine.PinResolver.Lookup.catalog_lookup/1` takes
       `service_id` alone, "give me the currently resolvable version of X,"
       never "give me version N of X." (SERVICE_TASK dispatch does ask for a
       specific pinned version, via `resolve_pinned_version/3`, ISS-0917.) Composite-keying `service_catalog`
       buys nothing at the one call site this whole requirement exists to
       wire up (`Letflow.ServiceCatalog.PinLookup.catalog_lookup/2`): under
       either schema shape, resolving a fresh reference means "find the row
       for this `service_id` whose status is ACTIVE."
    2. Blast radius on `service_id`-as-sole-key is severe and needless:
       `service_id` is used as a bare `String.t()` identifier by this
       module's own five pre-existing functions, `scope_validator_lookup/1`,
       the `§4` referential guard (a `SERVICE_TASK` node's `service_id`
       attribute — a **version-less** reference at the graph layer), and
       `web/src/api/services.ts`'s wire contract. Composite-keying would
       force every one of those to gain a version parameter it structurally
       cannot supply — REQ-373's SCOPE FENCE forbids touching the graph
       layer, so this path is a non-starter.
    3. Every existing public function keeps its exact current signature,
       arity, and error contract — `register/1`, `get_for_tenant/2`,
       `list_for_tenant/2`, `update_scope/2`, `delete/1`, `list_all/1`,
       `scope_validator_lookup/1` are all untouched except `register/1`'s
       own insert body gaining four additional stamped fields (a new
       service always starts life at `version: "1"`, `status: :ACTIVE`,
       exactly as `created_at`/`updated_at` are already stamped rather than
       caller-supplied).
    4. Existing-row migration is a pure additive backfill (DB-level column
       defaults for the `ALTER`, `published_at` backfilled from
       `created_at`) — no primary key change, no data copy, no FK rewrite.

  **Identity/visibility fields (`service_id`, `scope`, `owner_tenant_id`)
  are unversioned, untouched by `publish/3`/`retire/1`.** Version-specific
  technical fields (`endpoint_url`, `request_schema`, `response_schema`,
  `required_auth`, `timeout_ms`, `retry_policy`, plus the four lifecycle
  columns) are replaced wholesale by `publish/3`, frozen in place by
  `retire/1`. `get_for_tenant/2`/`list_for_tenant/2`/`list_all/1` apply no
  `status` filtering — a RETIRED entry remains as visible as an ACTIVE one
  (not asked for by any acceptance criterion; see the design doc §9 OQ-2).

  ## REQ-373 — PLC-01/`module_ref` catalog versioning stays out of scope

  This requirement versions `catalog_entry` (`service_catalog`) references
  only. `Letflow.Engine.PinResolver`'s own moduledoc "SCOPE GAP —
  service_catalog (S6) and PLC-01 (unscoped) are not built" section names
  `module_ref` resolution against PLC-01 as unscoped to any stage; PLC-01
  does not exist in this codebase and this requirement does not build it —
  `Letflow.ServiceCatalog.PinLookup.build/1`'s `module_lookup` stays a
  permanent `{:error, :not_found}` stub, copied verbatim from
  `PinResolver.default_lookup/0`.
  """

  import Ecto.Query

  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.ServiceScopeValidator.Lookup
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version
  alias Letflow.TenantProvisioning
  alias Letflow.Api.Pagination

  @list_cursor_prefix "SC:"
  @list_all_cursor_prefix "SCA:"

  # ===========================================================================
  # register/1 (design §3.1)
  # ===========================================================================

  @typedoc "Keyed by `Letflow.ServiceCatalog.Entry`'s own field names, minus `created_at`/`updated_at`."
  @type register_attrs :: %{
          required(:service_id) => String.t(),
          required(:endpoint_url) => String.t(),
          optional(:request_schema) => String.t() | nil,
          optional(:response_schema) => String.t() | nil,
          optional(:required_auth) => atom() | String.t(),
          required(:timeout_ms) => integer(),
          optional(:retry_policy) => String.t() | nil,
          optional(:scope) => atom() | String.t(),
          optional(:owner_tenant_id) => Ecto.UUID.t() | nil
        }

  @doc """
  Inserts a new `service_catalog` row.

  When `attrs.scope` is `:tenant` (or `"tenant"`) and `attrs.owner_tenant_id`
  is a syntactically-valid UUID, confirms the named tenant exists via a
  direct `Letflow.Identity.Tenant` lookup **before** any insert is
  attempted — a miss returns `{:error, :tenant_not_found}` with no row
  created (design §3.1 step 2). When `attrs.scope` is `:global`, no tenant
  lookup is performed.

  `created_at`/`updated_at` are stamped here (`DateTime.utc_now/0`, truncated
  to microsecond), never caller-settable.

  `service_id` is globally unique by virtue of being the table's primary
  key — a conflicting insert surfaces as `{:error, :duplicate_service_id}`,
  a typed atom distinguishable from an ordinary validation failure
  (mirrors `Letflow.Dlq`/`Letflow.Definitions.SolutionPack`'s own
  typed-error-atom convention), never a silent overwrite.

  `endpoint_url` must pass `Letflow.ServiceCatalog.Entry.check_endpoint_url/1`
  (ISS-0950: https, no private/loopback/link-local IP-literal host, no template
  placeholder before the path); otherwise the changeset carries an
  `:endpoint_url` error. Advisory fast feedback -- the dispatch-time INV-9 gate
  remains binding.

  An `endpoint_url` that references the reserved engine variable namespace
  (`{{variables._sys}}`, `{{variables._sys.<anything>}}`) is refused with an
  `:endpoint_url` error carrying `validation: :endpoint_url_reserved_variable`
  (GH #2623); nothing is inserted.
  """
  @spec register(register_attrs()) ::
          {:ok, Entry.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :tenant_not_found}
          | {:error, :duplicate_service_id}
  def register(attrs) when is_map(attrs) do
    with :ok <- check_tenant_exists(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      # `created_at`/`updated_at` are set on the base struct, not cast from
      # `attrs` -- `Entry.insert_changeset/2` deliberately never casts either
      # field (its own moduledoc), so they must be present on the struct
      # `cast/3` starts from rather than passed through `attrs`.
      #
      # `version_id`/`published_at` are stamped here too (REQ-373 design §1
      # point 3, "four additional stamped fields"), for the same reason --
      # `Ecto.Repo.insert/2` sends every schema field's current struct value
      # explicitly (never relying on a DB-level column default for a field
      # the schema itself declares), so leaving these two `nil` on the base
      # struct would insert an explicit `NULL`, not fall back to the
      # migration's `gen_random_uuid()`/backfill default. `version`/`status`
      # need no such stamping here -- `Entry`'s own `field/3` declarations
      # already default them to `"1"`/`:ACTIVE`, which `%Entry{}` picks up
      # without help.
      %Entry{
        created_at: now,
        updated_at: now,
        version_id: Ecto.UUID.generate(),
        published_at: now
      }
      |> Entry.insert_changeset(attrs)
      |> Repo.insert()
      |> map_insert_result()
    end
  end

  defp check_tenant_exists(%{scope: scope} = attrs) when scope in [:tenant, "tenant"] do
    case Map.get(attrs, :owner_tenant_id) do
      owner_tenant_id when is_binary(owner_tenant_id) ->
        case Ecto.UUID.cast(owner_tenant_id) do
          {:ok, uuid} -> tenant_exists?(uuid)
          # Not a well-formed UUID at all -- let the changeset/DB surface an
          # ordinary validation error rather than this function guessing.
          :error -> :ok
        end

      _missing_or_nil ->
        :ok
    end
  end

  defp check_tenant_exists(_attrs), do: :ok

  defp tenant_exists?(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      nil -> {:error, :tenant_not_found}
      %Tenant{} -> :ok
    end
  end

  defp map_insert_result({:ok, entry}), do: {:ok, entry}

  defp map_insert_result({:error, %Ecto.Changeset{} = changeset}) do
    if duplicate_service_id_error?(changeset) do
      {:error, :duplicate_service_id}
    else
      {:error, changeset}
    end
  end

  defp duplicate_service_id_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:service_id, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  # ===========================================================================
  # publish/3 (REQ-373 design §3.1)
  # ===========================================================================

  @typedoc "Version-specific technical fields only — never service_id/scope/owner_tenant_id."
  @type publish_attrs :: %{
          required(:endpoint_url) => String.t(),
          optional(:request_schema) => String.t() | nil,
          optional(:response_schema) => String.t() | nil,
          optional(:required_auth) => atom() | String.t(),
          required(:timeout_ms) => integer(),
          optional(:retry_policy) => String.t() | nil
        }

  @doc """
  Publishes a new version of an existing `service_catalog` entry.

  Runs inside one `Repo.transaction/1`: fetches the current row (not found
  -> `{:error, :not_found}`), rejects a `version` equal to the current row's
  own or to any version already archived in `service_catalog_versions` for
  this `service_id` (-> `{:error, :duplicate_version}` — version strings are
  opaque, no numeric-ordering assumption), archives a full snapshot of the
  **current** row's version-specific fields into `service_catalog_versions`
  (unconditionally — a publish following a bare retire archives the retired
  row exactly as a publish following an active one archives that one), then
  updates the `service_catalog` row in place: a freshly generated
  `version_id`, the caller-supplied `version`, `status: :ACTIVE`,
  `published_at: now`, `retired_at: nil`, plus the version-specific fields
  from `attrs`.

  **Explicit invariant:** `publish/3` touches **only** `service_catalog` and
  `service_catalog_versions` rows. It performs zero writes to
  `Letflow.EventStore`, zero reads/writes of any `INSTANCE_STARTED`/
  `INSTANCE_PINS_REBOUND` event payload, and zero calls into
  `Letflow.Engine`/`Letflow.Engine.PinResolver`. A pin is frozen into an
  `INSTANCE_STARTED` event's payload at case-start time and is never
  re-read live (`pin_resolver.ex`'s own "No fallback, ever" section) —
  `publish/3` cannot disturb an already-recorded pin because there is no
  code path connecting the two subsystems at all, not because `publish/3`
  takes special care to avoid one.

  The effective `endpoint_url` (including an inherited stored value when the key
  is omitted) must pass `Letflow.ServiceCatalog.Entry.check_endpoint_url/1`
  (ISS-0950); a failure returns `{:error, %Ecto.Changeset{}}` and rolls back the
  archive insert. Advisory -- the dispatch-time INV-9 gate remains binding.

  An effective `endpoint_url` (supplied or inherited) that references the reserved engine
  variable namespace is refused with `validation: :endpoint_url_reserved_variable` on
  `:endpoint_url` (GH #2623) and rolls back the archive insert; publishing a clean
  `endpoint_url` is the repair path.
  """
  @spec publish(service_id :: String.t(), version :: String.t(), publish_attrs()) ::
          {:ok, Entry.t()}
          | {:error, :not_found}
          | {:error, :duplicate_version}
          | {:error, Ecto.Changeset.t()}
  def publish(service_id, version, attrs)
      when is_binary(service_id) and is_binary(version) and is_map(attrs) do
    Repo.transaction(fn -> do_publish(service_id, version, attrs) end)
  end

  defp do_publish(service_id, version, attrs) do
    with %Entry{} = current <- Repo.get(Entry, service_id) || {:error, :not_found},
         :ok <- check_publishable_version(current, version),
         {:ok, _archived} <- archive_current_version(current),
         {:ok, updated} <- apply_publish(current, version, attrs) do
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp check_publishable_version(
         %Entry{service_id: service_id, version: current_version},
         version
       ) do
    duplicate? =
      version == current_version or
        Repo.exists?(
          from(v in Version, where: v.service_id == ^service_id and v.version == ^version)
        )

    if duplicate?, do: {:error, :duplicate_version}, else: :ok
  end

  defp archive_current_version(%Entry{} = current) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      version_id: current.version_id,
      service_id: current.service_id,
      version: current.version,
      endpoint_url: current.endpoint_url,
      request_schema: current.request_schema,
      response_schema: current.response_schema,
      required_auth: current.required_auth,
      timeout_ms: current.timeout_ms,
      retry_policy: current.retry_policy,
      published_at: current.published_at,
      retired_at: now
    }

    attrs
    |> Version.archive_changeset()
    |> Repo.insert()
  end

  defp apply_publish(%Entry{} = current, version, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    publish_attrs =
      attrs
      |> Map.take([
        :endpoint_url,
        :request_schema,
        :response_schema,
        :required_auth,
        :timeout_ms,
        :retry_policy
      ])
      |> Map.merge(%{
        version_id: Ecto.UUID.generate(),
        version: version,
        status: :ACTIVE,
        published_at: now,
        retired_at: nil,
        updated_at: now
      })

    current
    |> Entry.publish_changeset(publish_attrs)
    |> Repo.update()
  end

  # ===========================================================================
  # retire/1 (REQ-373 design §3.2)
  # ===========================================================================

  @doc """
  Retires a `service_catalog` entry's current version.

  Since this schema keeps exactly one live (current) version per
  `service_id` at a time, `retire/1` always targets *the* row — no separate
  version argument is needed or accepted. Not found -> `{:error, :not_found}`.
  Already `status: :RETIRED` -> `{:error, :already_retired}` (an explicit
  error, not a silent idempotent `:ok` — matches this codebase's existing
  "no silent no-op" discipline). Otherwise updates the row in place:
  `status: :RETIRED`, `retired_at: now`, `updated_at: now`. No
  `service_catalog_versions` insert here — the row's full technical data
  stays in place on `service_catalog` itself (still fetchable, just
  `status: :RETIRED`); it only gets archived into the sibling table later,
  if and when a subsequent `publish/3` supersedes it.

  **Explicit AC4 decision — retire FAILS OUTRIGHT, never falls through:** a
  fresh `Letflow.Engine.PinResolver.resolve/4` call against a `service_id`
  with no ACTIVE row (because its only row was just retired and nothing has
  published since) gets `{:error, :not_found}` from
  `Letflow.ServiceCatalog.PinLookup.catalog_lookup/2`, which `resolve/4`
  turns into `{:error, {:unresolved_catalog_ref, ref}}` — the **existing**
  error variant, no new one added. This schema enforces "at most one ACTIVE
  row per `service_id`" as a structural invariant — there is only ever one
  live row at all, so there is no second, older-but-still-ACTIVE row to
  "fall through to" by definition. Silently reactivating the
  most-recently-archived version instead would also contradict
  `pin_resolver.ex`'s own "No fallback, ever" philosophy: an admin who
  explicitly retired a service intended it to stop resolving, full stop,
  until a human explicitly republishes.

  **Why `Letflow.Engine.PinResolver.pin_for/3` reads against an
  already-pinned instance are entirely unaffected by retire:** `pin_for/3`
  takes a pin list **already obtained** from an `INSTANCE_STARTED` event
  payload and performs a pure `Enum.find/2` over that in-memory list — it
  accepts no `Lookup.t()`, calls no `Letflow.ServiceCatalog` function, and
  issues no `Repo` query of any kind. `retire/1` changes rows in
  `service_catalog`/`service_catalog_versions`; `pin_for/3` never reads
  either table, at any point, for any instance, retired-version or not. The
  two functions are connected by zero shared code — the same "by
  construction, not by care taken" argument as `publish/3`'s own invariant.
  """
  @spec retire(service_id :: String.t()) ::
          {:ok, Entry.t()} | {:error, :not_found} | {:error, :already_retired}
  def retire(service_id) when is_binary(service_id) do
    case Repo.get(Entry, service_id) do
      nil ->
        {:error, :not_found}

      %Entry{status: :RETIRED} ->
        {:error, :already_retired}

      %Entry{} = entry ->
        entry
        |> Entry.retire_changeset()
        |> Repo.update()
    end
  end

  # ===========================================================================
  # get_for_tenant/2 (design §3.2)
  # ===========================================================================

  @doc """
  Fetches a single `service_catalog` row and applies SVC-01's three-way
  visibility rule, in a single query plus a pure in-memory check (never a
  second, differently-shaped query depending on the outcome — this is what
  makes the "genuinely missing" and "real but invisible" cases structurally
  indistinguishable, not merely coincidentally same-shaped):

    * no row at all -> `{:error, :not_found}`
    * `scope: :global` -> `{:ok, entry}`, for any `tenant_id`
    * `scope: :tenant, owner_tenant_id: tenant_id` -> `{:ok, entry}`
    * `scope: :tenant` owned by a *different* tenant -> `{:error, :not_found}`
      — the identical atom the genuinely-missing case returns, never a
      `:forbidden`/`:unauthorized` variant (SVC-01's non-disclosure rule).
  """
  @spec get_for_tenant(service_id :: String.t(), tenant_id :: Ecto.UUID.t()) ::
          {:ok, Entry.t()} | {:error, :not_found}
  def get_for_tenant(service_id, tenant_id) when is_binary(service_id) and is_binary(tenant_id) do
    Entry
    |> Repo.get(service_id)
    |> visible_to_tenant(tenant_id)
  end

  # The one SVC-01 three-way visibility predicate, shared by get_for_tenant/2
  # and resolve_pinned_version/3 so the two cannot drift. Invisible and
  # missing are the identical `{:error, :not_found}`.
  @spec visible_to_tenant(Entry.t() | nil, Ecto.UUID.t()) ::
          {:ok, Entry.t()} | {:error, :not_found}
  defp visible_to_tenant(nil, _tenant_id), do: {:error, :not_found}
  defp visible_to_tenant(%Entry{scope: :global} = entry, _tenant_id), do: {:ok, entry}

  defp visible_to_tenant(%Entry{scope: :tenant, owner_tenant_id: owner} = entry, tenant_id)
       when owner == tenant_id,
       do: {:ok, entry}

  defp visible_to_tenant(%Entry{scope: :tenant}, _tenant_id), do: {:error, :not_found}

  # ===========================================================================
  # resolve_pinned_version/3 (ISS-0917 design D1)
  # ===========================================================================

  @typedoc """
  The technical fields of ONE specific catalog version, as a plain map (not
  an Ecto struct) so the engine never holds a schema struct from two
  different tables. `source` is `:live` when the pinned version is still the
  `service_catalog` row's current one (ACTIVE or RETIRED), `:archived` when
  it was read from `service_catalog_versions`.
  """
  @type resolved_service_version :: %{
          service_id: String.t(),
          version_id: Ecto.UUID.t(),
          version: String.t(),
          endpoint_url: String.t(),
          timeout_ms: pos_integer(),
          retry_policy: String.t() | nil,
          required_auth: :NONE | :API_KEY | :OAUTH2 | :MUTUAL_TLS,
          source: :live | :archived
        }

  @doc """
  Resolves the exact catalog version an instance pinned -- by the pin's
  `version_id` or, for a rebound pin that carries no `resolved_id`, by
  `(service_id, version)` -- regardless of whether that version is still the
  current ACTIVE one. A RETIRED current version and an archived version both
  resolve (the REQ-373/432 case). Unlike `Letflow.ServiceCatalog.PinLookup`
  (a START-time "what is ACTIVE now" question) this applies no `status`
  filter.

  Visibility is decided by the live row of the same `service_id` via the
  same three-way rule as `get_for_tenant/2` (archive rows carry no
  scope/owner). Returns exactly one error atom, `:not_found`, for a missing
  service, an invisible service, an unknown version, a version belonging to
  a different service, or a malformed `version_id` -- never a reason that
  distinguishes them (INV-5). Read-only; the arguments must only ever come
  from the instance's own event-sourced pins, never from request input.
  """
  @spec resolve_pinned_version(
          service_id :: String.t(),
          pin_identity :: {:version_id, Ecto.UUID.t()} | {:version, String.t()},
          tenant_id :: Ecto.UUID.t()
        ) :: {:ok, resolved_service_version()} | {:error, :not_found}
  def resolve_pinned_version(service_id, pin_identity, tenant_id)
      when is_binary(service_id) and is_binary(tenant_id) do
    with {:ok, %Entry{} = entry} <- get_for_tenant(service_id, tenant_id) do
      locate_pinned_version(entry, pin_identity)
    end
  end

  defp locate_pinned_version(%Entry{} = entry, {:version_id, version_id})
       when is_binary(version_id) do
    with {:ok, uuid} <- cast_uuid(version_id) do
      if entry.version_id == uuid do
        {:ok, resolved_from_entry(entry)}
      else
        case Repo.get(Version, uuid) do
          %Version{service_id: sid} = archived when sid == entry.service_id ->
            {:ok, resolved_from_archive(archived)}

          _missing_or_other_service ->
            {:error, :not_found}
        end
      end
    end
  end

  defp locate_pinned_version(%Entry{} = entry, {:version, version}) when is_binary(version) do
    if entry.version == version do
      {:ok, resolved_from_entry(entry)}
    else
      query =
        from(v in Version, where: v.service_id == ^entry.service_id and v.version == ^version)

      case Repo.one(query) do
        %Version{} = archived -> {:ok, resolved_from_archive(archived)}
        nil -> {:error, :not_found}
      end
    end
  end

  defp locate_pinned_version(_entry, _other_identity), do: {:error, :not_found}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp resolved_from_entry(%Entry{} = entry) do
    %{
      service_id: entry.service_id,
      version_id: entry.version_id,
      version: entry.version,
      endpoint_url: entry.endpoint_url,
      timeout_ms: entry.timeout_ms,
      retry_policy: entry.retry_policy,
      required_auth: entry.required_auth,
      source: :live
    }
  end

  defp resolved_from_archive(%Version{} = version) do
    %{
      service_id: version.service_id,
      version_id: version.version_id,
      version: version.version,
      endpoint_url: version.endpoint_url,
      timeout_ms: version.timeout_ms,
      retry_policy: version.retry_policy,
      required_auth: version.required_auth,
      source: :archived
    }
  end

  # ===========================================================================
  # list_for_tenant/2 (design §3.3)
  # ===========================================================================

  @typedoc "Mirrors `Letflow.Dlq.list/2`'s own `list_params()` cursor shape."
  @type list_params :: %{
          optional(:cursor) => String.t() | nil,
          page_size: pos_integer()
        }

  @doc """
  Cursor-paginated listing of every `service_catalog` row visible to
  `tenant_id` — every `scope: :global` row plus every `scope: :tenant` row
  this tenant owns. Ordered `(created_at DESC, service_id DESC)`, using
  `service_id` (the primary key) as the keyset tiebreaker since this table
  has no other unique column to break ties on. Reuses
  `Letflow.Api.Pagination`'s cursor-encode/decode module and
  `Letflow.Dlq.list/2`'s own `page_size + 1`-fetch/drop-the-extra-row idiom
  exactly — no new cursor format invented.
  """
  @spec list_for_tenant(list_params(), tenant_id :: Ecto.UUID.t()) ::
          {:ok, %{items: [Entry.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  def list_for_tenant(params, tenant_id) when is_map(params) and is_binary(tenant_id) do
    page_size = Map.fetch!(params, :page_size)

    with {:ok, cursor_seek} <- decode_list_cursor(Map.get(params, :cursor)) do
      query =
        Entry
        |> where([e], e.scope == :global or e.owner_tenant_id == ^tenant_id)
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([e], desc: e.created_at, desc: e.service_id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query)
      {page, next_cursor} = split_list_page(rows, page_size, @list_cursor_prefix)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  defp filter_by_list_cursor(query, nil), do: query

  defp filter_by_list_cursor(query, {ts, service_id}) do
    from(e in query, where: {e.created_at, e.service_id} < {^ts, ^service_id})
  end

  @spec decode_list_cursor(String.t() | nil) ::
          {:ok, {DateTime.t(), String.t()} | nil}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @list_cursor_prefix, byte_size(@list_cursor_prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} -> decode_seek(cursor, @list_cursor_prefix)
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  defp decode_seek(%Pagination.Cursor{inner: inner}, prefix) do
    case Pagination.decode_seek_parts(inner, prefix, [:datetime_us, :string]) do
      {:ok, [created_at, service_id]} -> {:ok, {created_at, service_id}}
      {:error, :invalid_cursor} = error -> error
    end
  end

  # `prefix` is threaded through here (rather than each caller building its
  # own cursor after the fact) so `list_for_tenant/2` and `list_all/1` can
  # genuinely share this function's body verbatim while still minting a
  # cursor tagged with the calling function's own endpoint prefix (INV-9) --
  # a shared helper that silently hardcoded one prefix would mis-tag the
  # other endpoint's cursors.
  defp split_list_page(rows, page_size, prefix) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_next_cursor(List.last(page), prefix)}
  end

  defp split_list_page(rows, _page_size, _prefix), do: {rows, nil}

  defp build_list_next_cursor(%Entry{service_id: service_id, created_at: created_at}, prefix) do
    created_at_us = DateTime.to_unix(created_at, :microsecond)

    prefix
    |> Pagination.build_raw_cursor(created_at_us, service_id)
    |> Pagination.encode_cursor()
  end

  # ===========================================================================
  # list_all/1 (design req192-service-catalog-routes.md §5, rework iteration 2)
  # ===========================================================================

  @doc """
  Cursor-paginated listing of **every** `service_catalog` row, with **no**
  tenant or scope filtering whatsoever — unlike `list_for_tenant/2`, this
  function performs no visibility check at all. It exists solely to back
  `Letflow.Routers.AdminServices`'s `GET /admin/services` handler, a
  `PLATFORM_ADMIN`-only route (`Letflow.Api.Authorization`'s
  `:AdminServicesRead`/`:UsersGroupsRolesManage` mapping); this module has
  never enforced authorization (per this moduledoc's "SVC-04 permissions"
  section) and does not start here — **the caller is entirely responsible
  for ensuring only an authorized admin path ever calls this function.**

  Added as a deliberate, REVIEWER-flagged scope expansion beyond REQ-192's
  original "no context-module change" note — see
  `lib/letflow/design/req192-service-catalog-routes.md` §5 for the full
  reasoning (a hard conflict between that note and `INV-RT-1`, REQ-078's
  "no `Repo.` call under `lib/letflow/routers/`" invariant).

  Otherwise identical in shape to `list_for_tenant/2`: same `list_params()`
  input, same result shape, same ordering
  (`(created_at DESC, service_id DESC)`), same `page_size + 1`-fetch/
  drop-the-extra-row idiom, and reuses `filter_by_list_cursor/2`/
  `split_list_page/2` verbatim (both are already tenant-agnostic). Uses its
  own cursor prefix, `"SCA:"`, distinct from `list_for_tenant/2`'s `"SC:"` —
  a cursor minted by one is rejected with `{:error, :wrong_endpoint}` if
  replayed against the other (INV-9 cross-endpoint cursor isolation,
  `Letflow.Api.Pagination.decode_cursor/3`'s `check_prefix/2`).

  `list_for_tenant/2` itself is entirely unchanged by this addition — same
  name, arity, body, and `where` clause.
  """
  @spec list_all(list_params()) ::
          {:ok, %{items: [Entry.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  def list_all(params) when is_map(params) do
    page_size = Map.fetch!(params, :page_size)

    with {:ok, cursor_seek} <- decode_list_all_cursor(Map.get(params, :cursor)) do
      query =
        Entry
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([e], desc: e.created_at, desc: e.service_id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query)
      {page, next_cursor} = split_list_page(rows, page_size, @list_all_cursor_prefix)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  @spec decode_list_all_cursor(String.t() | nil) ::
          {:ok, {DateTime.t(), String.t()} | nil}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  defp decode_list_all_cursor(nil), do: {:ok, nil}

  defp decode_list_all_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(
           raw,
           @list_all_cursor_prefix,
           byte_size(@list_all_cursor_prefix)
         ) do
      {:ok, %Pagination.Cursor{} = cursor} -> decode_seek(cursor, @list_all_cursor_prefix)
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # ===========================================================================
  # update_scope/2 (design §3.4)
  # ===========================================================================

  @typedoc "Cast by `Entry.update_scope_changeset/2`."
  @type update_scope_attrs :: %{
          required(:scope) => :global | :tenant,
          optional(:owner_tenant_id) => Ecto.UUID.t() | nil
        }

  @typedoc "One tenant's conflicting ACTIVE-definition references, per design §4 step 3."
  @type reference_conflict :: %{tenant_id: Ecto.UUID.t(), definition_ids: [String.t()]}

  @doc """
  Updates a `service_catalog` row's `scope`/`owner_tenant_id`.

  **Narrowing** (`:global -> :tenant`) runs the referential guard (§4 below)
  against every tenant *other than* `new_attrs.owner_tenant_id` — the tenant
  the service is being assigned to is allowed to already reference it; only
  *other* tenants' references block the narrow. A non-empty guard result is
  `{:error, {:referenced_by_active_definitions, conflicts}}`, naming the
  conflicting tenant ids, and no write happens.

  **Widening** (`:tenant -> :global`) always proceeds, skipping the guard
  entirely, per the acceptance criterion's explicit "widening... is always
  allowed". A global-to-global or tenant-to-tenant no-op scope change also
  skips the guard (neither narrows visibility).
  """
  @spec update_scope(service_id :: String.t(), update_scope_attrs()) ::
          {:ok, Entry.t()}
          | {:error, :not_found}
          | {:error, {:referenced_by_active_definitions, [reference_conflict()]}}
          | {:error, Ecto.Changeset.t()}
  def update_scope(service_id, new_attrs) when is_binary(service_id) and is_map(new_attrs) do
    case Repo.get(Entry, service_id) do
      nil ->
        {:error, :not_found}

      %Entry{} = entry ->
        if narrowing?(entry, new_attrs) do
          case referencing_active_definitions(service_id, Map.get(new_attrs, :owner_tenant_id)) do
            [] -> apply_update_scope(entry, new_attrs)
            conflicts -> {:error, {:referenced_by_active_definitions, conflicts}}
          end
        else
          apply_update_scope(entry, new_attrs)
        end
    end
  end

  defp narrowing?(%Entry{scope: :global}, %{scope: scope}) when scope in [:tenant, "tenant"],
    do: true

  defp narrowing?(_entry, _new_attrs), do: false

  defp apply_update_scope(entry, new_attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entry
    |> Entry.update_scope_changeset(new_attrs)
    |> Ecto.Changeset.put_change(:updated_at, now)
    |> Repo.update()
  end

  # ===========================================================================
  # delete/1 (design §3.5)
  # ===========================================================================

  @typedoc """
  Non-terminal instances pinned to a service (ISS-0923): at most
  `@max_reported_instance_ids` opaque instance ids in ascending order, plus a
  flag saying more exist. Carries no tenant identity, status, or counts.
  """
  @type instance_refs :: %{instance_ids: [Ecto.UUID.t()], truncated: boolean()}

  # Cap on the instance ids reported by `delete/1`'s instance guard (ISS-0923 design D-B).
  @max_reported_instance_ids 50

  @doc """
  Deletes a `service_catalog` row, together with the service's archived
  `service_catalog_versions` rows (one transaction: versions first, entry second).

  Refused, in this order (only the first failing guard is reported; a caller who
  clears the definition conflict and retries may then see the instance conflict):

  1. when any tenant's ACTIVE `process_definitions` graph still references the
     service (§4 below) — delete has no "assigned tenant" exemption the way
     `update_scope/2`'s narrow does; every tenant is checked. The error names
     every referencing definition id.
  2. when any tenant has a NON-TERMINAL instance (`:active` or `:error`, i.e.
     not `Letflow.EventStore.InstanceProjection.terminal?/1`) whose frozen
     definition snapshot has a SERVICE_TASK referencing the service, because
     deleting the live row would make those instances' pinned catalog
     resolution fail (ISS-0923). The error carries at most 50 instance ids
     (the globally smallest, ascending) and a `truncated` flag, and no tenant
     identity. Cancel or complete the listed instances, or retire the entry
     instead of deleting it.

  The instance check is best-effort against instances whose start overlaps the
  delete: `Engine.create/2` reads the live catalog row at start through
  `PinLookup.catalog_lookup/1` (plain read, no lock) and commits its snapshot and
  projection later, so a start already past that read can commit after the check
  and its instance would then fail pinned resolution (ERROR); conversely a start
  whose read happens after the delete commits is rejected at start with no
  instance. Retiring the entry first closes the window for every start that begins
  after the retire commits (`PinLookup` refuses RETIRED entries at start, while
  pinned resolution of existing instances keeps working); only a start already in
  flight at retire time can still slip through. Retire, then delete in a separate
  later request.
  """
  @spec delete(service_id :: String.t()) ::
          :ok
          | {:error, :not_found}
          | {:error, {:referenced_by_active_definitions, [String.t()]}}
          | {:error, {:referenced_by_active_instances, instance_refs()}}
  def delete(service_id) when is_binary(service_id) do
    case Repo.get(Entry, service_id) do
      nil ->
        {:error, :not_found}

      %Entry{} = entry ->
        case referencing_active_definitions(service_id, nil) do
          [] ->
            delete_unless_instances_pinned(entry)

          conflicts ->
            definition_ids = Enum.flat_map(conflicts, & &1.definition_ids)
            {:error, {:referenced_by_active_definitions, definition_ids}}
        end
    end
  end

  defp delete_unless_instances_pinned(%Entry{service_id: service_id} = entry) do
    case referencing_non_terminal_instances(service_id) do
      %{instance_ids: []} -> delete_entry(entry)
      refs -> {:error, {:referenced_by_active_instances, refs}}
    end
  end

  # `entry` was fetched at the top of `delete/1`, but the guards run sequential
  # per-tenant-schema query loops in between -- a real window in which a
  # concurrent caller can delete the same row first. `Entry` carries no optimistic-lock
  # field, so `Repo.delete/1` matches on primary key alone: if the row is already gone,
  # it raises `Ecto.StaleEntryError` rather than returning `{:error, changeset}`. Treat
  # that race as a benign not-found (consistent with `get_for_tenant/2`'s own not-found
  # handling) instead of letting it crash the caller. The rescue wraps the transaction,
  # so the raise rolls the archive-row deletion back with it.
  #
  # `service_catalog_versions` has no FK to `service_catalog` (migration
  # 20260921000004), so the archive rows are deleted explicitly, first, in the same
  # transaction: a failure never leaves a live entry without its archive rows.
  defp delete_entry(%Entry{service_id: service_id} = entry) do
    Repo.transaction(fn ->
      Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))

      case Repo.delete(entry) do
        {:ok, _deleted} -> :ok
        {:error, _changeset} -> Repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  # ===========================================================================
  # §4 — the referential guard, structural (not `LIKE`-on-serialized-JSON)
  # ===========================================================================
  #
  # R-Co's `bpm_active_defs_for_service` runs
  # `WHERE graph_json LIKE '%' || service_id || '%'` against the serialized
  # definition-graph text -- over-matching any occurrence of the service_id
  # substring anywhere in the JSON, even inside an unrelated string value.
  # This guard instead walks the graph's actual node structure: it matches
  # only a SERVICE_TASK node's own "service_id" attribute, the same
  # (node_type, attribute_key) pairing Letflow.Definitions.Graph's own
  # node_type filtering already establishes (graph.ex's
  # `Enum.filter(&(&1.node_type == :SERVICE_TASK))` idiom), reused here at
  # the SQL layer via a `jsonb_array_elements`/`EXISTS` correlated subquery
  # instead of after full deserialization, since this must run cross-schema.
  #
  # `process_definitions` is a per-tenant-schema table (Decision B) -- a
  # service's ACTIVE referencing definitions can live in *any* tenant's own
  # schema, so this guard iterates every provisioned tenant schema
  # (`Letflow.TenantProvisioning.list_registrations/0`) rather than running
  # as a single same-schema `Ecto.Query`. Stated cost, not solved here
  # (design §7 OQ-2): no caching/indexing/async mechanism is proposed.
  #
  # ISS-0923: `delete/1` adds a second, instance-level guard
  # (`referencing_non_terminal_instances/1`) that shares this fragment and the same
  # every-registration tenant loop.

  @spec referencing_active_definitions(
          service_id :: String.t(),
          exclude_tenant_id :: Ecto.UUID.t() | nil
        ) :: [reference_conflict()]
  defp referencing_active_definitions(service_id, exclude_tenant_id) do
    TenantProvisioning.list_registrations()
    |> Enum.reject(fn registration -> registration.tenant_id == exclude_tenant_id end)
    |> Enum.map(fn registration ->
      %{
        tenant_id: registration.tenant_id,
        definition_ids: query_referencing_definitions(service_id, registration.schema_name)
      }
    end)
    |> Enum.reject(fn %{definition_ids: ids} -> ids == [] end)
  end

  @service_task_reference_fragment """
  EXISTS (
    SELECT 1 FROM jsonb_array_elements(?->'nodes') AS node
    WHERE node->>'node_type' = 'SERVICE_TASK'
      AND node->'attributes'->>'service_id' = ?
  )
  """

  defp query_referencing_definitions(service_id, schema_name) do
    query =
      from(p in ProcessDefinition,
        where: p.status == :active,
        where: fragment(@service_task_reference_fragment, p.graph, ^service_id),
        select: p.id
      )

    Repo.all(query, prefix: schema_name)
  end

  # ISS-0923: a second, instance-level guard sharing `@service_task_reference_fragment`
  # (pointed at the frozen snapshot graph) and the same every-registration tenant loop.
  # No early exit across tenants: each tenant contributes its own smallest `cap + 1`
  # ids, the combined list is sorted, then cut to `cap`, so the result is the globally
  # smallest `cap` ids regardless of the (unspecified) registration order.
  @spec referencing_non_terminal_instances(service_id :: String.t()) :: instance_refs()
  defp referencing_non_terminal_instances(service_id) do
    all_ids =
      TenantProvisioning.list_registrations()
      |> Enum.flat_map(fn registration ->
        query_referencing_instances(service_id, registration.schema_name)
      end)
      |> Enum.sort()

    %{
      instance_ids: Enum.take(all_ids, @max_reported_instance_ids),
      truncated: length(all_ids) > @max_reported_instance_ids
    }
  end

  defp query_referencing_instances(service_id, schema_name) do
    query =
      from(p in InstanceProjection,
        join: s in InstanceDefinitionSnapshot,
        on: s.instance_id == p.instance_id,
        where: p.status in ^non_terminal_statuses(),
        where: fragment(@service_task_reference_fragment, s.graph, ^service_id),
        order_by: [asc: p.instance_id],
        limit: ^(@max_reported_instance_ids + 1),
        select: p.instance_id
      )

    Repo.all(query, prefix: schema_name)
  end

  # One authoritative definition of terminality: `InstanceProjection.terminal?/1`.
  defp non_terminal_statuses do
    InstanceProjection
    |> Ecto.Enum.values(:status)
    |> Enum.reject(&InstanceProjection.terminal?/1)
  end

  # ===========================================================================
  # §5 — `Lookup` implementation for `ServiceScopeValidator`
  # ===========================================================================

  @doc """
  Builds a `Letflow.Definitions.ServiceScopeValidator.Lookup.t()` backed by
  this catalog — without any edit to `service_scope_validator.ex`.

  `service_lookup` is a direct `service_id -> service_lookup_result()`
  field mapping (`Repo.get(Entry, service_id)`, no `tenant_id` filtering):
  `ServiceScopeValidator`'s own branch table already performs the
  global/tenant-match/mismatch comparison against the activating
  `tenant_id` on the caller side (`validate/3`'s own second argument) — this
  `Lookup` only needs to report what is registered, not decide visibility a
  second time (design §5). `tenant_id` is still accepted here (this function
  is constructed per-activation, `scope_validator_lookup(tenant_id)`,
  mirroring `ServiceScopeValidator.build/1`'s own per-activation closure
  pattern) even though the current implementation's `service_lookup` body
  does not read it, for exactly the reason just stated.

  `plugin_lookup` is a stub that always returns `{:error, :not_registered}`
  — `PluginRegistry` is stage S3, out of scope for REQ-191
  (`service_scope_validator.ex`'s own moduledoc names this gap; INV-SSV-5
  already makes "not registered" a pass on the plugin side, so this never
  blocks activation).
  """
  @spec scope_validator_lookup(tenant_id :: Ecto.UUID.t()) :: Lookup.t()
  def scope_validator_lookup(_tenant_id) do
    %Lookup{
      service_lookup: &lookup_service/1,
      plugin_lookup: fn _plugin_handler, _tenant_id -> {:error, :not_registered} end
    }
  end

  defp lookup_service(service_id) do
    case Repo.get(Entry, service_id) do
      nil ->
        {:error, :not_registered}

      %Entry{scope: scope, owner_tenant_id: owner_tenant_id} ->
        {:ok, %{scope: scope, owner_tenant_id: owner_tenant_id}}
    end
  end
end
