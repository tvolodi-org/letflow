defmodule Letflow.TenantProvisioning do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Context module for schema-per-tenant provisioning — the mechanism
  `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B named but
  explicitly deferred out of REQ-015's scope (see
  `lib/letflow/design/identity-schema.md` section 1's "Follow-up work this
  creates"). Resolves that deferral: a `tenant_schemas` registry
  (`Letflow.TenantProvisioning.Registration`), a schema-provisioning function
  (`provision_tenant_schema/1`, mirroring R-Co's
  `public.bpm_provision_tenant_schema(p_tenant_id UUID)`), and a
  migration-replay mechanism (`replay_migrations/2`, mirroring R-Co's
  `src/db/migrations.zig`'s `runForSchema`).

  Matches this project's established `Letflow.Identity`-style pattern: a
  top-level context module in `lib/letflow/`, backed by schema file(s) in a
  same-named subdirectory (`lib/letflow/tenant_provisioning/registration.ex`).

  `provision_tenant_schema/1` and `replay_migrations/2` are two separate,
  composable primitives — neither calls the other. A future tenant-onboarding
  orchestration requirement sequences them explicitly; that orchestration is
  not built here (see `lib/letflow/design/req022-tenant-schema-provisioning.md`
  §3.2's "No implicit chaining invariant").

  See `lib/letflow/design/req022-tenant-schema-provisioning.md` for the full
  design this module implements.

  ## Open question (REQ-022 acceptance criterion 4 — not resolved here)

  REQ-015's `users`/`groups`/`tenant_role` tables currently live in the public
  default schema (per `lib/letflow/design/identity-schema.md` section 1's
  deferral). This requirement does not retrofit those three tables to live
  under each tenant's own schema — only `tenants` and this module's own
  `tenant_schemas` registry are structurally global (a realm→tenant lookup
  must run before any tenant schema is known, so those two cannot live inside
  a tenant schema by construction). Whether `users`/`groups`/`tenant_role`
  *should* eventually be retrofitted behind `:prefix` (precedent: R-Co's
  identity tables underwent the identical move behind schema-per-tenant,
  at migration-060) is left open for a future requirement to decide
  explicitly — not assumed either way by this module.

  ## `replay_migrations/2` also seeds platform event types (REQ-045 §9 OQ-3a,
  ## extended by ISS-0072/GH#257)

  When `replay_migrations/2` is called with its default `migration_source`
  (i.e. the real `tenant_scoped_migrations/0` manifest, not a caller-supplied
  one), it seeds 6 `event_type_registry` rows — `"INSTANCE_STARTED"`,
  `"TASK_COMPLETED"`, `"INSTANCE_CANCELLED"`, `"INSTANCE_PINS_REBOUND"`,
  `"SUB_PROCESS_COMPLETED"`, and `"EXECUTION_ERROR"` — immediately after
  migrations apply successfully. `Letflow.EventStore.Registry.validate_payload/3`
  otherwise fails closed with `{:error, :unknown_event_type}` for every
  tenant, since no shipped migration seeds these rows -- a 20-built-in-type
  seed was deliberately left out of
  `20260816163103_create_event_type_registry.exs` (that migration's own
  header comment: "nothing yet exists that emits them"). `INSTANCE_STARTED`
  was seeded first, for `Letflow.Engine.create/2` (REQ-045). The other 5 were
  added by ISS-0072/GH#257, which found each already had a real production
  writer (`Letflow.Engine.complete_task/3`, `Letflow.Engine.cancel_instance/3`,
  `Letflow.Engine.PinRebind.rebind_pins/3`, `Letflow.Engine.SubProcess`'s
  sub-process completion path, and
  `Letflow.Engine.ExecutionError.append_execution_error_event/2`
  respectively) with no corresponding registry row — a pre-existing
  operational gap, closed here. Idempotent, and skipped entirely when a
  caller passes an explicit `migration_source` (so
  `test/support/req022_migration_fixture.ex`'s fixture-only replay is
  unaffected). See `replay_migrations/2`'s own private
  `maybe_seed_platform_event_types/2` for the full reasoning.

  ## Secondary open question (surfaced during design, not in REQ-022's
  original list)

  Should `provision_tenant_schema/1` or some other entry point eventually
  validate that a tenant's `Letflow.Identity.Tenant.status` is `:active` (not
  `:migrating`) before provisioning proceeds? REQ-021's
  `Letflow.Plugs.TenantStatus` already gates *mutating requests* on this
  status for existing tenants; `provision_tenant_schema/1` does not check it —
  left for a future tenant-onboarding-orchestration requirement to decide
  explicitly.

  ## No reconciliation path for a half-provisioned tenant (ISS-0230/GH#468 —
  ## OBLIGATION ON WHOEVER BUILDS THE ONBOARDING ORCHESTRATION)

  **Read this before sequencing the two primitives above from any new call
  site.** A caller that runs `Letflow.Identity.create_tenant/1` →
  `provision_tenant_schema/1` → `replay_migrations/2` commits the `tenants` row
  first. If either later step fails, the row stays committed and the tenant is
  left half-provisioned. There is **no** reconciliation, retry, or sweep
  mechanism anywhere in this codebase that will ever notice or repair such a
  tenant — nothing calls these two functions except the caller that just failed.

  A compensating rollback is **deliberately not** the answer and must not be
  added (REVIEWER's finding on ISS-0230): if `provision_tenant_schema/1` already
  succeeded and only `replay_migrations/2` failed, deleting the `tenants` row
  orphans a real Postgres schema plus a `tenant_schemas` row pointing at a
  `tenant_id` no longer present in `tenants` — trading a recoverable partial
  state for an unrecoverable orphan.

  Measured first-hand in run `WF03-ISS0230-20260822` (real Postgres, replay
  forced to fail), so the next implementer does not have to re-derive it:

    * `replay_migrations/2` returns a clean `{:error, {:migration_failed, _}}`;
      it does not raise, so a `with/else` at the call site sees it.
    * The resulting state is: `tenants` row present, `tenant_schemas` row
      present, the Postgres schema created but **empty**, and
      `Registration.migrations_applied_at` `nil`.
    * `migrations_applied_at IS NULL` is therefore already a sufficient,
      shipped **detection** predicate for "provisioned but not migrated" — a
      sweep needs no new column.
    * Re-invoking **both** primitives with the same `tenant_id` fully converges
      the state (`migrations_applied_at` set, tables present, still exactly one
      `tenant_schemas` row). The recovery *capability* exists today; only the
      orchestration that invokes it does not.
    * The tenant's `status` was `:active` throughout — an unmigrated tenant is
      currently advertised as fully live. Whoever builds onboarding should
      decide this together with the secondary open question above: creating the
      tenant `:migrating` and flipping to `:active` only after replay succeeds
      would make the partial state self-describing and would let
      `Letflow.Plugs.TenantStatus` reject *writes* against it with 503.
      **But `:migrating` is not a complete answer, and it is not free.** That
      plug gates write methods only (`@write_methods ~w(POST PUT PATCH
      DELETE)`; its other `call/2` clause returns the conn untouched), so
      `GET`/`HEAD` pass through with no status check and no DB query at all —
      a `:migrating` half-provisioned tenant would still serve *reads* straight
      onto the empty schema, hitting a relation that does not exist. Closing or
      explicitly accepting that read gap is part of the decision, not something
      `:migrating` hands you for free.

  What REQ-076 owes is an **invocable** recovery entry point — a function an
  operator or a test calls with a `tenant_id`. An automatic reconciliation
  sweep is deliberately *not* in scope: it needs a scheduler, there is no
  scheduler subsystem to hang one on, and adding a supervision-tree child for
  it is scope creep. The `migrations_applied_at IS NULL` predicate is recorded
  above so a future sweep requirement need not re-derive it — not as licence to
  build the sweep now.

  This is left unbuilt here on purpose. Adding a function to this module that
  calls both primitives would be exactly the coupling
  `lib/letflow/design/req022-tenant-schema-provisioning.md` §3.2's "No implicit
  chaining invariant" forbids; the orchestration layer is a caller's job, not
  this module's. `REQ-076` (tenant onboarding, S4) owns that layer and carries
  an explicit acceptance criterion for this gap — see its entry in
  `docs/requirements.yaml`. `docs/issues/ISS-0230.yaml` records the full
  reasoning.

  ## REQ-297 — entity column-promotion executor (AC6 moduledoc citation)

  See `docs/migration/decisions/0024-entity-promotion-ddl-execution.md` (the
  decision) and `lib/letflow/design/req297-entity-promotion-executor.md`
  (the design this section of the module implements) for the full detail.
  This module implements all four of 0024's sub-answers:

  1. **The mechanism**: this module (`Letflow.TenantProvisioning`), extended
     — not a second module — issues `ALTER TABLE`/`CREATE TABLE` directly
     against a tenant's own Postgres schema.
  2. **Partial-failure**: per-tenant, tracked one row per
     `(tenant_id, entity_type, attribute)` in `entity_column_promotions`
     (`Letflow.TenantProvisioning.ColumnPromotion`) — no cross-tenant
     atomicity; each tenant's row succeeds or fails on its own, and repair
     (`retry_failed_column_promotion/1`) retries only that one row.
  3. **Backfill**: a replay through
     `Letflow.Entities.Record.Projector.rebuild_projection/2` (never an
     inline `UPDATE`), with dual-write into the per-entity-type table kept
     current for the whole `ddl_applied..backfilled` window.
  4. **Rollback**: `suspend_column_promotion/2` flips `query_eligible` to
     `false` (query-layer exclusion via the future `Allowlist`), leaving
     `status` at `"active"` — never a drop or narrow of the column itself.

  ## REQ-298 — constraint_def unique-index activation and fk_def referential
  ## integrity (AC6 moduledoc citation)

  See `docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md`
  and `lib/letflow/design/req298-constraint-fk-activation.md` for the
  decision and design this section implements. Extends REQ-296's DDL
  generator (`Letflow.Entities.Definition.DDL.generate_table_ddl/3`,
  `unique_constraint_clauses/1`) and REQ-297's promotion executor
  (`execute_add_column/4`, extended from `execute_add_column/3`;
  `execute_create_table/1`, unchanged) — no new per-tenant-DDL-execution
  code path. Adds exactly one new DDL-issuing function,
  `run_constraint_activation/1`, using the identical `Repo.query!/1` +
  `rescue` shape and the identical per-tenant `pg_advisory_xact_lock`
  critical section `run_column_promotion/1` already establishes, so a
  constraint activation and a column promotion against the same tenant
  schema never interleave.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Record.Projector
  alias Letflow.EventStore.Registry
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.ConstraintActivation
  alias Letflow.TenantProvisioning.Registration

  @doc """
  Derives the physical Postgres schema name for a tenant. Pure, no I/O — safe
  to unit-test directly. Returns `{:error, :invalid_tenant_id}` for anything
  `Ecto.UUID.cast/1` rejects.

  **Deliberate divergence from R-Co's `schemaNameForTenant`:** R-Co
  special-cases the all-zero UUID to the literal name `tenant_default`.
  Letflow has no equivalent reserved default-tenant UUID (every tenant,
  including `slug == "bpm-default"`, gets a normal randomly-generated
  `binary_id` — see `lib/letflow/identity/tenant.ex`), so this function
  applies the same `"tenant_" <> hex` derivation uniformly, with no special
  case.
  """
  @spec schema_name_for_tenant(tenant_id :: Ecto.UUID.t()) ::
          {:ok, schema_name :: String.t()} | {:error, :invalid_tenant_id}
  def schema_name_for_tenant(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, canonical} -> {:ok, "tenant_" <> String.replace(canonical, "-", "")}
      :error -> {:error, :invalid_tenant_id}
    end
  end

  @doc """
  GH 2534 7b-2a: the schema of a tenant that IS provisioned (its `tenant_schemas` row), or
  `{:error, :not_found}`. Unlike `schema_name_for_tenant/1`, which only derives the name, this
  reads the registration, so an unprovisioned tenant is not found (route modules may not call
  `Repo` themselves).
  """
  @spec registered_schema(tenant_id :: Ecto.UUID.t()) ::
          {:ok, schema_name :: String.t()} | {:error, :not_found}
  def registered_schema(tenant_id) do
    case Repo.get_by(Registration, tenant_id: tenant_id) do
      %Registration{schema_name: schema_name} -> {:ok, schema_name}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The reverse of `schema_name_for_tenant/1`: derives `tenant_id` back out of an
  already-resolved physical schema name. Pure, no I/O — deliberately does
  **not** confirm the tenant is actually provisioned (no `Registration`
  query); that existence check happens downstream, for free, wherever the
  caller's own flow needs it (e.g. `Letflow.EventStore.Registry.validate_payload/3`'s
  `resolve_schema_name/1`).

  This is the mechanism `docs/migration/decisions/0003-ecto-schema-strategy.md`'s
  2026-08-17 addendum names: a context module about to write a tenant-scoped
  row reverses `schema_name_for_tenant/1`'s encoding to obtain the `tenant_id`
  it stamps on the row, rather than accepting `tenant_id` as an independently
  -trusted caller-supplied field. See `lib/letflow/design/req025-event-append.md`
  §4 for the full design.

  Total and deterministic for any `schema_name` shaped like
  `"tenant_" <> <32 lowercase hex chars>` — `schema_name_for_tenant/1` has no
  special-cased default-tenant UUID, so there is no lossy branch to invert
  incorrectly. Returns `{:error, :invalid_schema_name}` for anything else.
  """
  @spec tenant_id_for_schema_name(schema_name :: String.t()) ::
          {:ok, tenant_id :: Ecto.UUID.t()} | {:error, :invalid_schema_name}
  def tenant_id_for_schema_name(schema_name) when is_binary(schema_name) do
    with "tenant_" <> hex <- schema_name,
         true <- String.match?(hex, ~r/^[0-9a-f]{32}\z/),
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
           e::binary-size(12)>> <- hex,
         canonical = Enum.join([a, b, c, d, e], "-"),
         {:ok, _} <- Ecto.UUID.cast(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_schema_name}
    end
  end

  def tenant_id_for_schema_name(_schema_name), do: {:error, :invalid_schema_name}

  @doc """
  Lists every provisioned tenant's `Registration` row -- a plain
  `Repo.all(Registration)`, no new query logic. Added for REQ-191's
  cross-schema referential guard (`Letflow.ServiceCatalog`'s `delete/2`/
  `update_scope/2`, design `lib/letflow/design/req191-service-catalog-core.md`
  §4 step 1), which must enumerate every tenant schema to check for
  `process_definitions` rows referencing a service, since
  `process_definitions` is a per-tenant-schema table with no global home
  (Decision B) and this module is the sole registry of which schemas exist.

  This is a read-only addition -- no existing function's behavior changes.
  Flagged (per the design doc's OQ-3) as a minimal extension to this
  module's public surface beyond REQ-191's own stated scope, for REVIEWER to
  confirm is acceptable rather than scope creep.
  """
  @spec list_registrations() :: [Registration.t()]
  def list_registrations do
    Repo.all(Registration)
  end

  @doc """
  Idempotently provisions a tenant's physical Postgres schema: derives the
  schema name, serializes concurrent calls for the same tenant via a
  transaction-scoped advisory lock, issues `CREATE SCHEMA IF NOT EXISTS`, and
  records the mapping in `tenant_schemas` — all inside one `Repo.transaction/1`
  so a `tenant_id` that doesn't correspond to an existing tenant rolls back
  the whole operation, including the schema-creation DDL (Postgres DDL is
  transactional).

  Calling this twice for the same `tenant_id` is **not an error** — the
  second call returns `{:ok, %Registration{}}` with the same row the first
  call created: safe to call repeatedly, e.g. from a retried onboarding
  step, without erroring on a tenant that's already provisioned.
  """
  @spec provision_tenant_schema(tenant_id :: Ecto.UUID.t()) ::
          {:ok, Registration.t()}
          | {:error, :invalid_tenant_id}
          | {:error, :tenant_not_found}
          | {:error, term()}
  def provision_tenant_schema(tenant_id) do
    case schema_name_for_tenant(tenant_id) do
      {:error, :invalid_tenant_id} = error ->
        error

      {:ok, schema_name} ->
        Repo.transaction(fn ->
          # Ports R-Co's `PERFORM pg_advisory_xact_lock(hashtext(v_schema_name))` --
          # a normal parameterized query ($1), no identifier interpolation
          # involved at this step, no INV-7 concern here.
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [schema_name])

          # The only raw-SQL identifier interpolation in this module.
          # `schema_name` is never taken directly from an external caller at
          # this point -- it is always the output of schema_name_for_tenant/1
          # above, which only emits strings matching `tenant_[0-9a-f]{32}`
          # (guaranteed by construction: it only proceeds past
          # Ecto.UUID.cast/1, which normalizes to exactly that character
          # set). See this module's design doc §3.1 for the full
          # identifier-injection safety invariant. CREATE SCHEMA cannot be
          # parameterized like a normal SQL value (DDL identifiers aren't
          # bind-param targets), so this interpolation is the only available
          # mechanism -- safety here comes from schema_name's constrained
          # shape, not from parameterization.
          Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{schema_name}"))

          case insert_or_fetch_registration(tenant_id, schema_name) do
            {:ok, %Registration{} = registration} ->
              registration

            {:error, :tenant_not_found} ->
              Repo.rollback(:tenant_not_found)

            {:error, %Ecto.Changeset{} = changeset} ->
              Repo.rollback(changeset)
          end
        end)
    end
  end

  @doc """
  Re-applies `migration_source` (defaults to `tenant_scoped_migrations/0`)
  against a tenant's already-provisioned schema, via `Ecto.Migrator.run/4`'s
  `:prefix` option. Never provisions on the fly — returns
  `{:error, :tenant_not_provisioned}` immediately if no `Registration` row
  exists for `tenant_id`.

  `Ecto.Migrator.run/4` itself returns a bare list on success and *raises* on
  failure (confirmed directly from `deps/ecto_sql/lib/ecto/migrator.ex`); this
  function wraps that call in `try/rescue`, converting any raised exception
  into `{:error, {:migration_failed, exception}}`, to produce this project's
  established `{:ok, _} | {:error, _}` convention
  (`backend_developer_guide.md` §3.5) at this module's public boundary.

  `migration_source` defaults to `nil`, resolved to `tenant_scoped_migrations/0`
  *inside* the `try` below rather than as the parameter's own default
  expression (ISS-0019/GH#75) — an Elixir default argument is evaluated by a
  compiler-generated lower-arity clause that runs *before* the full-arity
  body, so `tenant_scoped_migrations()` used to run outside this function's
  own `try/rescue` and any raise it produced (e.g. `Code.LoadError` from a
  manifest-named migration file missing at deploy time, since
  `tenant_scoped_migrations/0` now does real `Code.require_file` work per
  ISS-0017) escaped as a raw exception instead of the `{:error,
  {:migration_failed, _}}` this `@spec` promises. Resolving the default
  inside the `try` puts it under the same guard as `Ecto.Migrator.run/4`
  itself, so both failure sources produce the identical tagged error.
  """
  @spec replay_migrations(
          tenant_id :: Ecto.UUID.t(),
          migration_source :: [{version :: pos_integer(), module()}] | nil
        ) ::
          {:ok, applied_versions :: [pos_integer()]}
          | {:error, :tenant_not_provisioned}
          | {:error, {:migration_failed, Exception.t()}}
          | {:error, {:event_type_seed_failed, term()}}
  def replay_migrations(tenant_id, migration_source \\ nil) do
    case Repo.get_by(Registration, tenant_id: tenant_id) do
      nil ->
        {:error, :tenant_not_provisioned}

      %Registration{schema_name: schema_name} ->
        try do
          using_default_manifest? = is_nil(migration_source)
          migrations = migration_source || tenant_scoped_migrations()

          applied_versions =
            Ecto.Migrator.run(Repo, migrations, :up,
              all: true,
              prefix: schema_name,
              log: false
            )

          mark_migrations_applied(tenant_id)

          with :ok <- maybe_seed_platform_event_types(using_default_manifest?, tenant_id),
               :ok <- maybe_seed_entity_event_types(using_default_manifest?, schema_name) do
            {:ok, applied_versions}
          end
        rescue
          exception -> {:error, {:migration_failed, exception}}
        end
    end
  end

  @doc """
  Replays tenant-scoped migrations against every provisioned tenant --
  `list_registrations/0` enumerated, `replay_migrations/2` called per tenant
  with the default manifest (`tenant_scoped_migrations/0`). The boot-time
  entry point ISS-0771 closes (see
  `lib/letflow/design/iss0771-tenant-migration-replay-on-deploy.md`): no
  deploy or boot path previously replayed migrations against tenants that
  already existed before a new tenant-scoped migration merged.

  Pure orchestration over two already-existing primitives -- `list_registrations/0`
  and `replay_migrations/2` -- no new query. Never raises: Layer 1 is
  `replay_migrations/2`'s own internal `rescue` (unchanged, already converts
  every exception it can reach into a tagged `{:error, _}`); Layer 2 is the
  `rescue` around each per-tenant call below, independent of Layer 1, so this
  function's exception-safety does not depend on `replay_migrations/2`
  continuing to catch everything forever (design doc §4). A tenant whose call
  raises past Layer 1 is recorded as `{tenant_id, {:unexpected_exception,
  exception}}` -- a reason distinguishable from `replay_migrations/2`'s own
  three tagged reasons.

  Sequential `Enum`, not `Task.async_stream/3` -- deliberate (design doc §4):
  correctness at current tenant counts needs no concurrency, and a shared
  Task-per-tenant shape would reintroduce the same "concurrent process per
  unit-of-work" question REQ-045 already resolved against for running
  instances.

  Idempotent: calling this any number of times against fully-migrated tenants
  is a safe no-op (design doc §3) -- it adds no new idempotency mechanism of
  its own, only composes `replay_migrations/2`'s existing guarantees.

  GH #2727: each tenant's outcome is also persisted on its `tenant_schemas`
  row (`migration_replay_failed_at` / `migration_replay_failure_code`) -- set
  on failure, cleared on success -- and read back by `list_replay_failures/0`.
  """
  @spec replay_all_pending() :: %{
          ok: [tenant_id :: Ecto.UUID.t()],
          error: [{tenant_id :: Ecto.UUID.t(), reason :: term()}]
        }
  def replay_all_pending do
    list_registrations()
    |> Enum.reduce(%{ok: [], error: []}, fn %Registration{tenant_id: tenant_id}, acc ->
      try do
        case replay_migrations(tenant_id) do
          {:ok, _applied_versions} ->
            clear_replay_failure(tenant_id)
            %{acc | ok: [tenant_id | acc.ok]}

          {:error, reason} ->
            record_replay_failure(tenant_id, reason)
            %{acc | error: [{tenant_id, reason} | acc.error]}
        end
      rescue
        exception ->
          reason = {:unexpected_exception, exception}
          record_replay_failure(tenant_id, reason)
          %{acc | error: [{tenant_id, reason} | acc.error]}
      end
    end)
    |> then(fn %{ok: ok, error: error} -> %{ok: Enum.reverse(ok), error: Enum.reverse(error)} end)
  end

  @doc """
  GH #2727: tenants whose most recent `replay_all_pending/0` outcome was a
  failure -- the queryable signal behind the boot-time replay, which itself
  always completes. Value-free: tenant id, a fixed reason code
  (`migration_failed`, `event_type_seed_failed`, `tenant_not_provisioned`,
  `unexpected_exception`, `unknown`) and the time of the failure; never the
  exception or its message. A later successful replay for the tenant clears
  the entry; `[]` means every tenant's last replay succeeded.

  Operator query: `bin/letflow rpc "Letflow.TenantProvisioning.list_replay_failures()"`.
  """
  @spec list_replay_failures() :: [
          %{tenant_id: Ecto.UUID.t(), reason_code: String.t(), failed_at: NaiveDateTime.t()}
        ]
  def list_replay_failures do
    Repo.all(
      from(r in Registration,
        where: not is_nil(r.migration_replay_failed_at),
        order_by: [asc: r.migration_replay_failed_at, asc: r.tenant_id],
        select: %{
          tenant_id: r.tenant_id,
          reason_code: coalesce(r.migration_replay_failure_code, "unknown"),
          failed_at: r.migration_replay_failed_at
        }
      )
    )
  end

  defp record_replay_failure(tenant_id, reason) do
    failed_at = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    write_replay_status(tenant_id,
      migration_replay_failed_at: failed_at,
      migration_replay_failure_code: replay_failure_code(reason)
    )
  end

  defp clear_replay_failure(tenant_id) do
    write_replay_status(tenant_id,
      migration_replay_failed_at: nil,
      migration_replay_failure_code: nil
    )
  end

  # Bookkeeping must never break replay_all_pending/0's never-raises contract
  # (nor boot): a failed status write is logged and swallowed.
  defp write_replay_status(tenant_id, set) do
    from(r in Registration, where: r.tenant_id == ^tenant_id) |> Repo.update_all(set: set)
    :ok
  rescue
    exception ->
      Logger.error(
        "tenant migration replay: could not record replay status",
        tenant_id: tenant_id,
        reason: Exception.format(:error, exception, __STACKTRACE__)
      )

      :ok
  end

  # Fixed strings only: the exception or its message is never stored.
  defp replay_failure_code({:migration_failed, _}), do: "migration_failed"
  defp replay_failure_code({:event_type_seed_failed, _}), do: "event_type_seed_failed"
  defp replay_failure_code(:tenant_not_provisioned), do: "tenant_not_provisioned"
  defp replay_failure_code({:unexpected_exception, _}), do: "unexpected_exception"
  defp replay_failure_code(_), do: "unknown"

  # {version, module, filename} for every tenant-scoped migration, in ascending
  # version order. The third element exists only so tenant_scoped_migrations/0
  # can load the module — see that function's @doc. The version integers MUST
  # equal the filenames' timestamp prefixes.
  #
  # REQ-023's six event-store migrations (lib/letflow/design/req023-event-store-schema.md
  # §4) followed by REQ-024's event_type_registry migration
  # (lib/letflow/design/req024-event-type-registry.md §3), REQ-027's two
  # definition-core migrations (lib/letflow/design/req027-definition-core-schema.md §4),
  # REQ-035's promotion_reviews migration
  # (lib/letflow/design/req035-promotion-reviews-schema.md §4), REQ-040's
  # promotion_assertion_runs migration
  # (lib/letflow/design/req040-promotion-assertion-rerun.md §4), REQ-043's three
  # instance-engine-schema migrations -- the instance_projections engine-columns
  # ALTER TABLE, tokens, and tasks
  # (lib/letflow/design/req043-instance-engine-schema.md §7), REQ-063's three
  # per-tenant identity-table migrations -- groups, tenant_role, users
  # (lib/letflow/design/req063-identity-tables-schema-per-tenant.md §2/§3), and
  # REQ-064's ten Decision-0006-D2 tenant_id-drop migrations -- events,
  # events_archive, instance_projections, process_definitions, tokens, tasks,
  # promotion_reviews, promotion_assertion_runs, users, groups
  # (lib/letflow/design/req064-drop-tenant-id.md §2), REQ-054's
  # instance_state_snapshots migration
  # (lib/letflow/design/req054-instance-state-snapshots.md §3), and REQ-109's
  # variable_schemas migration
  # (lib/letflow/design/req109-variable-schemas.md §2/§2.3) — thirty-one
  # entries in total at that point (later entries, such as ISS-0979's
  # `audit_chain_locks` and ISS-1030's `pending_tenant_admin_grants`, are
  # appended in the list below, which is authoritative). That total also counts two entries this prose does not
  # enumerate by requirement id above: the sub-process parent-columns ALTER
  # (20260819045553) and the lua_script_execution_audit migration
  # (20260820000011); the list below, not this comment, is authoritative.
  # Each of these files carries the §4 guard pattern; registration here
  # is the other mandatory half. REQ-063's own guarded DROP migration
  # (20260819000004_drop_legacy_public_identity_tables.exs) is deliberately NOT
  # listed here -- it is a global-schema migration, not tenant-scoped, per that
  # migration's own header comment.
  @tenant_scoped_migration_manifest [
    {20_260_816_120_001, Letflow.Repo.Migrations.CreateEvents,
     "20260816120001_create_events.exs"},
    {20_260_816_120_002, Letflow.Repo.Migrations.CreateInstanceSequence,
     "20260816120002_create_instance_sequence.exs"},
    {20_260_816_120_003, Letflow.Repo.Migrations.CreateInstanceProjections,
     "20260816120003_create_instance_projections.exs"},
    {20_260_816_120_004, Letflow.Repo.Migrations.CreateEventPayloadStore,
     "20260816120004_create_event_payload_store.exs"},
    {20_260_816_120_005, Letflow.Repo.Migrations.CreateEventsArchive,
     "20260816120005_create_events_archive.exs"},
    {20_260_816_120_006, Letflow.Repo.Migrations.CreateEventIdempotency,
     "20260816120006_create_event_idempotency.exs"},
    {20_260_816_163_103, Letflow.Repo.Migrations.CreateEventTypeRegistry,
     "20260816163103_create_event_type_registry.exs"},
    {20_260_816_193_001, Letflow.Repo.Migrations.CreateProcessDefinitions,
     "20260816193001_create_process_definitions.exs"},
    {20_260_816_193_002, Letflow.Repo.Migrations.CreateInstanceDefinitionSnapshots,
     "20260816193002_create_instance_definition_snapshots.exs"},
    {20_260_816_200_001, Letflow.Repo.Migrations.CreatePromotionReviews,
     "20260816200001_create_promotion_reviews.exs"},
    {20_260_818_090_001, Letflow.Repo.Migrations.CreatePromotionAssertionRuns,
     "20260818090001_create_promotion_assertion_runs.exs"},
    {20_260_818_110_001, Letflow.Repo.Migrations.AlterInstanceProjectionsAddEngineColumns,
     "20260818110001_alter_instance_projections_add_engine_columns.exs"},
    {20_260_818_110_002, Letflow.Repo.Migrations.CreateTokens,
     "20260818110002_create_tokens.exs"},
    {20_260_818_110_003, Letflow.Repo.Migrations.CreateTasks, "20260818110003_create_tasks.exs"},
    {20_260_819_000_001, Letflow.Repo.Migrations.CreateGroupsTenantScoped,
     "20260819000001_create_groups_tenant_scoped.exs"},
    {20_260_819_000_002, Letflow.Repo.Migrations.CreateTenantRoleTenantScoped,
     "20260819000002_create_tenant_role_tenant_scoped.exs"},
    {20_260_819_000_003, Letflow.Repo.Migrations.CreateUsersTenantScoped,
     "20260819000003_create_users_tenant_scoped.exs"},
    {20_260_819_045_553, Letflow.Repo.Migrations.AddSubProcessParentColumns,
     "20260819045553_add_sub_process_parent_columns.exs"},
    {20_260_820_000_001, Letflow.Repo.Migrations.DropTenantIdEvents,
     "20260820000001_drop_tenant_id_events.exs"},
    {20_260_820_000_002, Letflow.Repo.Migrations.DropTenantIdEventsArchive,
     "20260820000002_drop_tenant_id_events_archive.exs"},
    {20_260_820_000_003, Letflow.Repo.Migrations.DropTenantIdInstanceProjections,
     "20260820000003_drop_tenant_id_instance_projections.exs"},
    {20_260_820_000_004, Letflow.Repo.Migrations.DropTenantIdProcessDefinitions,
     "20260820000004_drop_tenant_id_process_definitions.exs"},
    {20_260_820_000_005, Letflow.Repo.Migrations.DropTenantIdTokens,
     "20260820000005_drop_tenant_id_tokens.exs"},
    {20_260_820_000_006, Letflow.Repo.Migrations.DropTenantIdTasks,
     "20260820000006_drop_tenant_id_tasks.exs"},
    {20_260_820_000_007, Letflow.Repo.Migrations.DropTenantIdPromotionReviews,
     "20260820000007_drop_tenant_id_promotion_reviews.exs"},
    {20_260_820_000_008, Letflow.Repo.Migrations.DropTenantIdPromotionAssertionRuns,
     "20260820000008_drop_tenant_id_promotion_assertion_runs.exs"},
    {20_260_820_000_009, Letflow.Repo.Migrations.DropTenantIdUsers,
     "20260820000009_drop_tenant_id_users.exs"},
    {20_260_820_000_010, Letflow.Repo.Migrations.DropTenantIdGroups,
     "20260820000010_drop_tenant_id_groups.exs"},
    {20_260_820_000_011, Letflow.Repo.Migrations.CreateLuaScriptExecutionAudit,
     "20260820000011_create_lua_script_execution_audit.exs"},
    {20_260_821_000_001, Letflow.Repo.Migrations.CreateInstanceStateSnapshots,
     "20260821000001_create_instance_state_snapshots.exs"},
    {20_260_821_000_002, Letflow.Repo.Migrations.CreateVariableSchemas,
     "20260821000002_create_variable_schemas.exs"},
    {20_260_822_000_101, Letflow.Repo.Migrations.AlterGroupsAddDisplayNameDescription,
     "20260822000101_alter_groups_add_display_name_description.exs"},
    {20_260_822_000_102, Letflow.Repo.Migrations.CreateGroupMembersTenantScoped,
     "20260822000102_create_group_members_tenant_scoped.exs"},
    {20_260_823_000_001, Letflow.Repo.Migrations.CreateApiTokensTenantScoped,
     "20260823000001_create_api_tokens_tenant_scoped.exs"},
    {20_260_823_000_003, Letflow.Repo.Migrations.AddSequenceNumberToProcessDefinitions,
     "20260823000003_add_sequence_number_to_process_definitions.exs"},
    {20_260_823_000_004, Letflow.Repo.Migrations.CreateDefinitionSequence,
     "20260823000004_create_definition_sequence.exs"},
    {20_260_829_000_001, Letflow.Repo.Migrations.CreateDlqEntries,
     "20260829000001_create_dlq_entries.exs"},
    {20_260_829_010_001, Letflow.Repo.Migrations.CreateWebhookSubscriptions,
     "20260829010001_create_webhook_subscriptions.exs"},
    {20_260_829_020_001, Letflow.Repo.Migrations.CreateTimers,
     "20260829020001_create_timers.exs"},
    {20_260_830_000_004, Letflow.Repo.Migrations.AddSecretRefToWebhookSubscriptions,
     "20260830000004_add_secret_ref_to_webhook_subscriptions.exs"},
    {20_260_830_010_001, Letflow.Repo.Migrations.CreateWebhookDeliveryAttempts,
     "20260830010001_create_webhook_delivery_attempts.exs"},
    {20_260_830_020_001, Letflow.Repo.Migrations.CreateAuditEntriesTenantScoped,
     "20260830020001_create_audit_entries_tenant_scoped.exs"},
    {20_260_830_030_001, Letflow.Repo.Migrations.CreateRepositoryArtifacts,
     "20260830030001_create_repository_artifacts.exs"},
    {20_260_830_040_001, Letflow.Repo.Migrations.CreateAlertTriggerState,
     "20260830040001_create_alert_trigger_state.exs"},
    {20_260_830_040_002, Letflow.Repo.Migrations.CreateAlertHookEmissionState,
     "20260830040002_create_alert_hook_emission_state.exs"},
    {20_260_831_000_001, Letflow.Repo.Migrations.CreateArtifactActivations,
     "20260831000001_create_artifact_activations.exs"},
    {20_260_831_050_001, Letflow.Repo.Migrations.CreateEffectCompletions,
     "20260831050001_create_effect_completions.exs"},
    {20_260_831_050_002, Letflow.Repo.Migrations.CreateCorrelationCursors,
     "20260831050002_create_correlation_cursors.exs"},
    {20_260_901_000_001, Letflow.Repo.Migrations.AddContentToRepositoryArtifacts,
     "20260901000001_add_content_to_repository_artifacts.exs"},
    {20_260_901_000_002, Letflow.Repo.Migrations.CreateInstanceAttachments,
     "20260901000002_create_instance_attachments.exs"},
    {20_260_901_030_001, Letflow.Repo.Migrations.AddJoinCountersToInstanceProjections,
     "20260901030001_add_join_counters_to_instance_projections.exs"},
    {20_260_902_000_001, Letflow.Repo.Migrations.MakeTokensBranchIdNullable,
     "20260902000001_make_tokens_branch_id_nullable.exs"},
    {20_260_902_010_001, Letflow.Repo.Migrations.CreateServiceTaskDispatches,
     "20260902010001_create_service_task_dispatches.exs"},
    {20_260_906_000_001, Letflow.Repo.Migrations.CreateEntityDefinitions,
     "20260906000001_create_entity_definitions.exs"},
    {20_260_906_010_001, Letflow.Repo.Migrations.CreateEntityRecordLatest,
     "20260906010001_create_entity_record_latest.exs"},
    {20_260_906_010_002, Letflow.Repo.Migrations.CreateEntityTypeInstances,
     "20260906010002_create_entity_type_instances.exs"},
    {20_260_907_000_001, Letflow.Repo.Migrations.AddEntityDefinitionsActivePartialIndex,
     "20260907000001_add_entity_definitions_active_partial_index.exs"},
    {20_260_907_010_001, Letflow.Repo.Migrations.CreateEntityFieldRestrictions,
     "20260907010001_create_entity_field_restrictions.exs"},
    {20_260_907_010_002, Letflow.Repo.Migrations.CreateUserEntityGrants,
     "20260907010002_create_user_entity_grants.exs"},
    {20_260_907_020_001, Letflow.Repo.Migrations.AddScanStatusToInstanceAttachments,
     "20260907020001_add_scan_status_to_instance_attachments.exs"},
    {20_260_911_000_001, Letflow.Repo.Migrations.CreateEntityRecordAttachments,
     "20260911000001_create_entity_record_attachments.exs"},
    {20_260_917_000_001, Letflow.Repo.Migrations.CreateHelpContent,
     "20260917000001_create_help_content.exs"},
    {20_260_921_000_001, Letflow.Repo.Migrations.AddRoleClaimsSyncedAtToUsers,
     "20260921000001_add_role_claims_synced_at_to_users.exs"},
    {20_260_921_000_002, Letflow.Repo.Migrations.AddKindToTenantRole,
     "20260921000002_add_kind_to_tenant_role.exs"},
    {20_260_922_000_001, Letflow.Repo.Migrations.CreateEventsPartitioned,
     "20260922000001_create_events_partitioned.exs"},
    {20_260_922_000_002, Letflow.Repo.Migrations.CreateEventsPInitialPartitions,
     "20260922000002_create_events_p_initial_partitions.exs"},
    {20_260_922_000_003, Letflow.Repo.Migrations.BackfillEventsPartitioned,
     "20260922000003_backfill_events_partitioned.exs"},
    {20_260_922_000_004, Letflow.Repo.Migrations.SwapEventsPartitioned,
     "20260922000004_swap_events_partitioned.exs"},
    {20_260_922_000_005, Letflow.Repo.Migrations.CreateEventsArchivePartitioned,
     "20260922000005_create_events_archive_partitioned.exs"},
    {20_260_922_000_006, Letflow.Repo.Migrations.CreateEventsArchivePInitialPartitions,
     "20260922000006_create_events_archive_p_initial_partitions.exs"},
    {20_260_922_000_007, Letflow.Repo.Migrations.BackfillEventsArchivePartitioned,
     "20260922000007_backfill_events_archive_partitioned.exs"},
    {20_260_922_000_008, Letflow.Repo.Migrations.SwapEventsArchivePartitioned,
     "20260922000008_swap_events_archive_partitioned.exs"},
    {20_260_922_000_009, Letflow.Repo.Migrations.RetargetEventPayloadStoreFkey,
     "20260922000009_retarget_event_payload_store_fkey.exs"},
    {20_260_923_010_001, Letflow.Repo.Migrations.CreateEntityTypeRestrictions,
     "20260923010001_create_entity_type_restrictions.exs"},
    {20_260_923_010_002, Letflow.Repo.Migrations.CreateUserEntityTypeGrants,
     "20260923010002_create_user_entity_type_grants.exs"},
    {20_260_925_000_001, Letflow.Repo.Migrations.CreateTenantModules,
     "20260925000001_create_tenant_modules.exs"},
    {20_260_926_010_001, Letflow.Repo.Migrations.BackfillExamTenantModules,
     "20260926010001_backfill_exam_tenant_modules.exs"},
    {20_261_003_000_001, Letflow.Repo.Migrations.CreateAuditChainLocks,
     "20261003000001_create_audit_chain_locks.exs"},
    {20_261_008_000_001, Letflow.Repo.Migrations.CreatePendingTenantAdminGrants,
     "20261008000001_create_pending_tenant_admin_grants.exs"},
    # GH 2534 PR 7b-1 (decision 0053 D1): tenant-script registry with its guard trigger.
    {20_261_014_000_001, Letflow.Repo.Migrations.CreateScriptRules,
     "20261014000001_create_script_rules.exs"},
    # GH 2534 PR 7b-2a (decision 0053 D5, D7): script policy singleton (kill switch latches)
    # and the interim readable-master flags.
    {20_261_014_000_002, Letflow.Repo.Migrations.CreateScriptPolicy,
     "20261014000002_create_script_policy.exs"},
    # GH 2534 PR 7b-2b (decision 0053 D6): declared sod, the platform solo flag, sod_excluded,
    # the confirmation columns and the replaced script_rules_guard().
    {20_261_014_000_003, Letflow.Repo.Migrations.AddScriptSod,
     "20261014000003_add_script_sod.exs"},
    # REQ-496 / GH #2530 (decision 0050 D7, D8): `entity_definitions.managed_by` with its
    # immutability trigger, and the `scope_node_paths` security index.
    {20_261_014_100_001, Letflow.Repo.Migrations.AddManagedByToEntityDefinitions,
     "20261014100001_add_managed_by_to_entity_definitions.exs"},
    {20_261_014_100_002, Letflow.Repo.Migrations.CreateScopeNodePaths,
     "20261014100002_create_scope_node_paths.exs"},
    # GH 2552 (decision 0051 M2): api_tokens.issuer_user_id, NULL for legacy rows.
    {20_261_015_000_001, Letflow.Repo.Migrations.AddIssuerUserIdToApiTokens,
     "20261015000001_add_issuer_user_id_to_api_tokens.exs"},
    # REQ-497 / GH #2533 PR 1a (decision 0051 D1): role_scope_grants with its backfill and
    # T9 assert.
    {20_261_015_025_331, Letflow.Repo.Migrations.CreateRoleScopeGrants,
     "20261015025331_create_role_scope_grants.exs"},
    # GH 2534 PR 7c-1 (decision 0053 D2, F-E): the script SERVICE_TASK dispatch table, and the
    # read-only trigger retiring lua_script_execution_audit (C17).
    {20_261_015_100_001, Letflow.Repo.Migrations.CreateScriptTaskDispatches,
     "20261015100001_create_script_task_dispatches.exs"},
    {20_261_015_100_002, Letflow.Repo.Migrations.LuaScriptAuditReadOnly,
     "20261015100002_lua_script_audit_read_only.exs"},
    # GH #2587 / REQ-499 PR B1 (decision 0054 D4a): process_definitions.activated_by, the
    # activator authority recorded for a graph with `entity_writes`; NULL otherwise.
    {20_261_015_200_001, Letflow.Repo.Migrations.AddActivatedByToProcessDefinitions,
     "20261015200001_add_activated_by_to_process_definitions.exs"},
    # GH #2590 / REQ-501 PR R2 (decision 0054 D6): the four-column module ownership stamp of
    # a process definition version (all-or-none CHECK + immutability trigger), and the
    # manifest hash recorded on `tenant_modules` at install. Both NULL for every existing row.
    {20_261_016_100_001, Letflow.Repo.Migrations.AddOwnerStampToProcessDefinitions,
     "20261016100001_add_owner_stamp_to_process_definitions.exs"},
    {20_261_016_100_002, Letflow.Repo.Migrations.AddManifestHashToTenantModules,
     "20261016100002_add_manifest_hash_to_tenant_modules.exs"},
    # GH #2596: the single, narrow exception to REQ-496 D3 (NULL -> 'exam' on six frozen names).
    {20_261_016_120_001, Letflow.Repo.Migrations.AllowExamManagedByStamp,
     "20261016120001_allow_exam_managed_by_stamp.exs"},
    # GH #2535 / REQ-517 PR 2a (decision 0051 D1): the FK from role_scope_grants.scope_node_id
    # to scope_node_paths (ON DELETE RESTRICT), and the admin-flagged service principal flag.
    {20_261_018_100_001, Letflow.Repo.Migrations.AddScopeNodeFkeyToRoleScopeGrants,
     "20261018100001_add_scope_node_fkey_to_role_scope_grants.exs"},
    {20_261_018_100_002, Letflow.Repo.Migrations.AddAdminFlaggedServicePrincipalToUsers,
     "20261018100002_add_admin_flagged_service_principal_to_users.exs"},
    # GH #2535 / REQ-517 PR 2b (design section 4.7.1): the persisted shadow-evidence counters.
    # (20261018200001, the public tenants CHECK widening, is deliberately NOT listed.)
    {20_261_018_200_002, Letflow.Repo.Migrations.CreateScopeShadowCounters,
     "20261018200002_create_scope_shadow_counters.exs"},
    # GH #2659 / REQ-505 PR-1 (decision 0057 D1): nullable `external_system`/`external_id` on
    # entity_record_latest + both-or-neither CHECK (a), then the partial unique index (b); two
    # files so each takes its own lock in its own transaction, each with `SET LOCAL lock_timeout`.
    {20_261_019_100_001, Letflow.Repo.Migrations.AddExternalRefColumnsToEntityRecordLatest,
     "20261019100001_add_external_ref_columns_to_entity_record_latest.exs"},
    {20_261_019_100_002, Letflow.Repo.Migrations.AddExternalRefIndexToEntityRecordLatest,
     "20261019100002_add_external_ref_index_to_entity_record_latest.exs"},
    # GH #2535 / REQ-518 PR 2d (design C.1, AC 12): the nullable `tasks.scope_node_id` with its
    # foreign key to scope_node_paths (ON DELETE RESTRICT) and a partial index. No production writer.
    {20_261_019_200_001, Letflow.Repo.Migrations.AddScopeNodeIdToTasks,
     "20261019200001_add_scope_node_id_to_tasks.exs"},
    # GH #2502: drops the partial index pending_tenant_admin_grants_open_idx, redundant with the
    # unique email_key index because the state CHECK makes every non-NULL email_key an open row.
    {20_261_021_000_001, Letflow.Repo.Migrations.DropPendingTenantAdminGrantsOpenIdx,
     "20261021000001_drop_pending_tenant_admin_grants_open_idx.exs"},
    # REQ-500 / GH #2588 (PR A, decision 0056): the versioned-document tables, then their
    # immutability triggers (the triggers need the tables). Both are tenant-scoped.
    {20_261_022_100_001, Letflow.Repo.Migrations.CreateDocumentTables,
     "20261022100001_create_document_tables.exs"},
    {20_261_022_100_002, Letflow.Repo.Migrations.CreateDocumentImmutabilityTriggers,
     "20261022100002_create_document_immutability_triggers.exs"},
    {20_261_022_200_001, Letflow.Repo.Migrations.AddVariableLabelsToInstanceProjections,
     "20261022200001_add_variable_labels_to_instance_projections.exs"},
    # GH #2618 (decision 0054 D4a.2 amendment): the `write_class` column that replaces the interim
    # denied-name list for `writable_by_process`; backfilled from that list, then immutable.
    {20_261_023_100_001, Letflow.Repo.Migrations.AddWriteClassToEntityDefinitions,
     "20261023100001_add_write_class_to_entity_definitions.exs"},
    # GH #3092 (REQ-531, decision 0051 T13): nullable write-once `instance_projections.scope_node_id`.
    {20_261_024_100_001, Letflow.Repo.Migrations.AddScopeNodeIdToInstanceProjections,
     "20261024100001_add_scope_node_id_to_instance_projections.exs"},
    # GH #2692 (REQ-515): the `needs_reactivation_*` flag columns on `process_definitions`.
    {20_261_024_100_002, Letflow.Repo.Migrations.AddNeedsReactivationToProcessDefinitions,
     "20261024100002_add_needs_reactivation_to_process_definitions.exs"},
    # GH #2680 slice 3: the #2596 stamp exception extended to the ten exam authoring names
    # (16 frozen names in all). A NEW reviewed migration, as the #2596 header requires.
    {20_261_024_120_001, Letflow.Repo.Migrations.AllowExamAuthoringManagedByStamp,
     "20261024120001_allow_exam_authoring_managed_by_stamp.exs"},
    # GH #3091 (REQ-532, decision 0051 T13): backfills `tasks.scope_node_id` from each task's own
    # instance; re-runnable (IS NULL guard), a no-op down.
    {20_261_024_200_001, Letflow.Repo.Migrations.BackfillTasksScopeNodeId,
     "20261024200001_backfill_tasks_scope_node_id.exs"},
    # GH #2688 (REQ-513 B2): partial `(dispatched_at, id) WHERE status = 'advanced'` index for the
    # stuck-advance sweep; additive, no data change.
    {20_261_024_300_001, Letflow.Repo.Migrations.AddStuckAdvanceIndex,
     "20261024300001_add_stuck_advance_index.exs"},
    # REQ-508 / GH #2675 (decision 0063 part (a)): retention policy columns on document_types,
    # hold columns on documents, and the column-aware guard_document_types().
    {20_261_025_100_001, Letflow.Repo.Migrations.AddDocumentRetentionAndHold,
     "20261025100001_add_document_retention_and_hold.exs"},
    # REQ-541 / GH #3160: number sequences bound to a record type (definitions, counters, allocation log
    # and the counter-only-grows trigger). Empty tables for existing tenants; no row altered.
    {20_261_025_200_001, Letflow.Repo.Migrations.CreateNumberSequences,
     "20261025200001_create_number_sequences.exs"},
    # REQ-551 / GH #3180: tenant label overrides (message id x locale -> replacement text). Empty table
    # for existing tenants; no row altered.
    {20_261_025_300_001, Letflow.Repo.Migrations.CreateLabelOverrides,
     "20261025300001_create_label_overrides.exs"},
    # REQ-565 / GH #3201: tenant integration mappings (one table, no credential column). Empty for
    # existing tenants; no row altered.
    {20_261_025_400_001, Letflow.Repo.Migrations.CreateIntegrationMappings,
     "20261025400001_create_integration_mappings.exs"},
    # REQ-563 / GH #3199: tenant notification templates (template key x locale -> subject, body). Empty
    # table for existing tenants; no row altered.
    {20_261_025_500_001, Letflow.Repo.Migrations.CreateNotificationTemplates,
     "20261025500001_create_notification_templates.exs"}
  ]

  @doc """
  The designated tenant-scoped subset of `priv/repo/migrations/` —
  `replay_migrations/2`'s default `migration_source`. REQ-022 itself
  contributes zero entries (its own `CreateTenantSchemas` migration is
  global-only, see the migration's header comment); REQ-023 contributes the six
  event-store migrations (`lib/letflow/design/req023-event-store-schema.md` §4),
  REQ-024 the `event_type_registry` migration
  (`lib/letflow/design/req024-event-type-registry.md` §3), REQ-027 the two
  definition-core migrations, `process_definitions` and
  `instance_definition_snapshots`
  (`lib/letflow/design/req027-definition-core-schema.md` §4), REQ-035 the
  `promotion_reviews` migration
  (`lib/letflow/design/req035-promotion-reviews-schema.md` §4), REQ-040 the
  `promotion_assertion_runs` migration
  (`lib/letflow/design/req040-promotion-assertion-rerun.md` §4), REQ-043 three
  more: the `instance_projections` engine-columns `ALTER TABLE`, `tokens`, and
  `tasks` (`lib/letflow/design/req043-instance-engine-schema.md` §7), REQ-063
  three more: `groups`, `tenant_role`, and `users` moved behind schema-per-tenant
  (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md` §2/§3),
  REQ-064 ten more: the `tenant_id`-drop migrations for `events`,
  `events_archive`, `instance_projections`, `process_definitions`, `tokens`,
  `tasks`, `promotion_reviews`, `promotion_assertion_runs`, `users`, and
  `groups` (`lib/letflow/design/req064-drop-tenant-id.md` §2), and REQ-054 one
  more: `instance_state_snapshots`
  (`lib/letflow/design/req054-instance-state-snapshots.md` §3), REQ-176 one
  more: `dlq_entries` (`lib/letflow/design/req176-dlq-core.md` §4), REQ-181
  one more: `webhook_subscriptions`
  (`lib/letflow/design/req181-webhooks-core.md` §1), REQ-186 one more:
  `timers` (`lib/letflow/design/req186-scheduler-core.md` §1), and REQ-183
  one more: `webhook_delivery_attempts`
  (`lib/letflow/design/req183-webhook-delivery-dispatch.md` §1), and REQ-376
  nine more: the `events`/`events_archive` partitioning conversion set
  (`lib/letflow/design/req376-partition-event-retirement.md` §2.1), including
  a post-hoc 9th migration
  (`20260922000009_retarget_event_payload_store_fkey.exs`) that retargets
  `event_payload_store`'s composite FK away from the renamed-aside
  `events_pre_partition_20260922` table -- migration 4's table rename does
  not retarget a pre-existing FK, since Postgres binds FKs by OID, not name
  (decision 0037's third correction has the full incident writeup),
  REQ-402 one more: `tenant_modules`
  (`lib/letflow/design/req402-tenant-modules-install-context.md` §1.2), and
  REQ-409 one more: `backfill_exam_tenant_modules` (the P2 data backfill that
  inserts an exam `tenant_modules` row for any tenant with a
  `bilimbaga-question-bank` pack install), ISS-0979 one more:
  `audit_chain_locks`, and ISS-1030 one more: `pending_tenant_admin_grants`
  (`lib/letflow/design/iss1030-onboarding-administrator.md` §4), and REQ-496
  two more: `entity_definitions.managed_by` and `scope_node_paths`
  (`lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §2.1, §5), and REQ-497
  one more: `role_scope_grants`
  (`lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` §1), and GH #2596
  one more: `AllowExamManagedByStamp`, the single documented exception to REQ-496 D3
  (`lib/letflow/design/gh2596-exam-managed-types.md` §4), and REQ-517 two more: the
  `role_scope_grants.scope_node_id` foreign key and `users.admin_flagged_service_principal`
  (`lib/letflow/design/req517-scoped-grants-admin-plane.md` §3.6), and REQ-517 PR 2b one more:
  `scope_shadow_counters` (same design, §4.7.1), and GH #2659 two more: the
  `entity_record_latest` `external_ref` columns + CHECK and its partial unique index
  (`lib/letflow/design/gh2659-external-ref-idempotent-import.md` §2.1), and REQ-518 PR 2d one
  more: the nullable `tasks.scope_node_id` with its foreign key and partial index
  (`lib/letflow/design/req518-compiler-scope-filter.md` C.1), and GH #2502 one more:
  `DropPendingTenantAdminGrantsOpenIdx`, dropping a redundant partial index —
  entries in total (see `@tenant_scoped_migration_manifest` itself for the
  authoritative, up-to-date count), ordered by version. Every future tenant-scoped migration must append its
  own entry to `@tenant_scoped_migration_manifest`, in addition to following the
  required guard pattern in its own migration file (see this module's design doc
  §4) — a migration file that does one without the other is either inert
  (never selected here) or corrupts `public` on a plain `mix ecto.migrate` run
  (added here without the guard).

  **This function loads each listed migration module before returning it.**
  `Ecto.Migrator` resolves a `{version, module}` source through
  `load_migration!/1`, which requires `Code.ensure_loaded?(module)` to be true
  (`deps/ecto_sql/lib/ecto/migrator.ex`), but `priv/repo/migrations/*.exs` is
  never compiled into the application — `mix.exs` sets `elixirc_paths` to
  `["lib"]` (plus `test/support` under `:test`), so no `.beam` file exists for
  any migration module. Without this loading step `Ecto.Migrator.run/4` raises
  `Ecto.MigrationError: module ... is not an Ecto.Migration`, which
  `replay_migrations/2` surfaces as `{:error, {:migration_failed, exception}}`.

  That failure is state-dependent, which is why REQ-022 never hit it: only
  *pending* migrations reach `load_migration!/1`, and `mix.exs`'s `test:` alias
  runs `ecto.migrate` in the same VM, which defines pending migration modules via
  `Code.compile_file/1`. So the bug is invisible against a freshly-migrated test
  database and appears against an already-migrated one — and always appears in an
  `iex -S mix` session or a release, where `mix ecto.migrate` never ran in-process
  at all.

  `Code.require_file/1` is idempotent, and the `Code.ensure_loaded?/1` guard
  additionally covers the case where such a `mix ecto.migrate` run already
  defined the module in this VM — which `require_file/1` would not know about and
  would otherwise redefine, emitting a "redefining module" warning.

  This function's `@spec` is unchanged from REQ-022's: the return shape is still
  `[{version, module}]`, and the manifest's third element never escapes it.

  REQ-024's `event_type_registry` entry originally shipped in the bare
  `{version, module}` form and carried that same latent failure; routing it
  through the manifest here repairs it too, rather than leaving one entry
  loadable only by accident. Every entry added since — REQ-027's two — uses the
  three-element form for the same reason; reverting any of them to the bare
  `{version, module}` shape would reintroduce the defect.
  """
  @spec tenant_scoped_migrations() :: [{version :: pos_integer(), module()}]
  def tenant_scoped_migrations do
    Enum.map(@tenant_scoped_migration_manifest, fn {version, module, filename} ->
      ensure_migration_module_loaded!(module, filename)
      {version, module}
    end)
  end

  # Application.app_dir/2 resolves through _build, where Mix links (or, on
  # Windows, copies) priv/ on every build — so this path is correct in dev, test
  # and a release alike.
  defp ensure_migration_module_loaded!(module, filename) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      [Application.app_dir(:letflow, "priv"), "repo", "migrations", filename]
      |> Path.join()
      |> Code.require_file()

      :ok
    end
  end

  # Reuses the exact idiom already established and empirically verified in
  # Letflow.Identity's insert_or_fetch/3 + re_select_on_conflict/2 (see
  # lib/letflow/identity.ex): client-generated binary_id PKs make
  # {:ok, struct} indistinguishable between "really inserted" and
  # "suppressed by ON CONFLICT" without an extra existence check.
  defp insert_or_fetch_registration(tenant_id, schema_name) do
    attrs = %{tenant_id: tenant_id, schema_name: schema_name}
    changeset = Registration.changeset(%Registration{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: :tenant_id,
           returning: true
         ) do
      {:ok, %Registration{id: id} = inserted} ->
        if Repo.get(Registration, id) do
          {:ok, inserted}
        else
          re_select_registration(tenant_id)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        if foreign_key_violation?(changeset, :tenant_id) do
          {:error, :tenant_not_found}
        else
          {:error, changeset}
        end
    end
  end

  defp re_select_registration(tenant_id) do
    case Repo.get_by(Registration, tenant_id: tenant_id) do
      %Registration{} = existing -> {:ok, existing}
      nil -> {:error, :tenant_not_found}
    end
  end

  defp foreign_key_violation?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :foreign
      _ -> false
    end)
  end

  defp mark_migrations_applied(tenant_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(r in Registration, where: r.tenant_id == ^tenant_id)
    |> Repo.update_all(set: [migrations_applied_at: now])
  end

  # Seeds 6 event_type_registry rows (REQ-045 §9 OQ-3a, extended by
  # ISS-0072/GH#257) -- only when replay_migrations/2 ran the real, default
  # production manifest (tenant_scoped_migrations/0), never when a caller
  # passed an explicit migration_source. This distinction matters: a
  # caller-supplied migration_source (test/support/req022_migration_fixture.ex's
  # own {1, MigrationFixture} case, exercised by
  # test/letflow/tenant_provisioning_test.exs) may not include
  # event_type_registry's own migration at all, so unconditionally seeding
  # here would attempt an insert against a table that doesn't exist in that
  # schema and turn an otherwise-passing replay into a crash.
  #
  # Why this lives in replay_migrations/2 and not provision_tenant_schema/1
  # (REQ-045's own design doc names both as candidate extension points):
  # event_type_registry is a tenant-scoped table created by a *migration*
  # (priv/repo/migrations/20260816163103_create_event_type_registry.exs),
  # replayed here via Ecto.Migrator.run/4 above -- it does not exist yet at
  # provision_tenant_schema/1's own point in a tenant's onboarding sequence
  # (that function only creates the bare Postgres schema and the
  # tenant_schemas registry row; migration replay is this module's own
  # moduledoc's "two separate, composable primitives" the caller sequences
  # itself). Seeding here, immediately after this same call's own
  # Ecto.Migrator.run/4 succeeds, is the earliest point the table is
  # guaranteed to exist.
  #
  # Idempotent by construction: Letflow.EventStore.Registry.register_type/2's
  # own (name, schema_version) collision -- {:error, :duplicate_event_type_version}
  # -- is treated as success here, for every entry in the list below, so a
  # second replay_migrations/2 call against an already-seeded tenant schema
  # (Ecto.Migrator.run/4 itself is already idempotent on re-applying
  # migrations) is also a no-op on this step for all 6 types, not a hard
  # failure.
  #
  # REQ-045's own OQ-3a was narrowly scoped to "INSTANCE_STARTED" (the one
  # event type EE-01's Letflow.Engine.create/2 actually appends). ISS-0072
  # (GH#257) found 5 additional event types with real production writers and
  # no registry row -- each was silently failing EventStore.append/2 with
  # {:error, :unknown_event_type} -- and they are seeded here too:
  # "TASK_COMPLETED" (Letflow.Engine.complete_task/3), "INSTANCE_CANCELLED"
  # (Letflow.Engine.cancel_instance/3), "INSTANCE_PINS_REBOUND"
  # (Letflow.Engine.PinRebind.rebind_pins/3), "SUB_PROCESS_COMPLETED"
  # (Letflow.Engine.SubProcess's sub-process completion path), and
  # "EXECUTION_ERROR" (Letflow.Engine.ExecutionError.append_execution_error_event/2).
  #
  # "DEFINITION_PROMOTED", "DEFINITION_VERSION_ROLLED_BACK", and
  # "PROMOTION_ASSERTION_TEARDOWN_FAILED" (REQ-140) now have production
  # writers: the three Letflow.EventStore.PlatformEvents adapter functions
  # (append_definition_promoted/2, append_definition_version_rolled_back/2,
  # append_promotion_assertion_teardown_failed/2) built by REQ-140, each
  # satisfying Letflow.Definitions's event_appender_fun/0 contract. Nothing
  # yet calls those functions from a live route -- wiring opts[:event_appender]
  # defaults into REQ-077's ported promotion routes is that requirement's
  # job, not this one's.
  @platform_event_type_seed_attrs [
    %{
      name: "INSTANCE_STARTED",
      schema_version: 2,
      description:
        "Emitted once by Letflow.Engine.create/2 (EE-01) when a new process instance starts. " <>
          "Bumped from schema_version 1 to 2 (decision 0062 R8h-5, GH #2616): the optional " <>
          "\"initial_labels\" (variable name to restriction labels) is declared.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "definition_id" => %{"type" => "string"},
          "correlation_key" => %{"type" => ["string", "null"]},
          "initial_variables" => %{"type" => "object"},
          "initial_labels" => %{"type" => "object"}
        },
        "required" => ["definition_id", "initial_variables"]
      }
    },
    %{
      name: "TASK_COMPLETED",
      schema_version: 4,
      description:
        "Emitted by Letflow.Engine.complete_task/3 (M9, EE-04) when a user task is completed. " <>
          "Bumped from schema_version 1 to 2 (REQ-292): merged_variable_events now also carries " <>
          "the two new FormExpressionReevaluation.reevaluation_event() kinds " <>
          "(\"computed_field_disagreement\", \"visible_when_false_value_discarded\") alongside " <>
          "the original \"variable_overwritten\" -- widened to a single flat item schema (this " <>
          "validator has no oneOf/anyOf support, Letflow.EventStore.Registry.JsonSchema's own " <>
          "moduledoc) whose \"required\" only still names \"event\" (the one key every kind " <>
          "shares); \"key\"/\"field\"/\"old_value\"/\"new_value\"/\"submitted_value\"/" <>
          "\"server_value\"/\"discarded_value\" are all declared but optional, since which ones " <>
          "are present depends on which event kind a given array element is. Bumped from " <>
          "schema_version 2 to 3 (REQ-391): the payload now also carries " <>
          "\"attachments_at_decision\", a snapshot (not a live reference, see " <>
          "lib/letflow/design/req391-attachment-history-approval-attribution.md §4) of every " <>
          "instance_attachments row present on the instance at the moment this task was " <>
          "completed -- attachment_id/file_name/content_type/byte_size/uploaded_by/created_at " <>
          "per entry, mirroring merged_variable_events' own embed-not-reference precedent " <>
          "(INV-EE48-5). Not added to \"required\" for the same forward-compatibility reason " <>
          "merged_variable_events itself isn't required: a pre-bump schema_version 2 row must " <>
          "still validate a TASK_COMPLETED payload appended against it during the rollout " <>
          "window. KNOWN GAP, flagged for REVIEWER, same shape as DEFINITION_PROMOTED's own " <>
          "schema_version 1->2 bump above: this only widens the schema seeded into TENANTS " <>
          "PROVISIONED FROM THIS POINT ON -- a tenant provisioned before this change keeps " <>
          "validating TASK_COMPLETED against an earlier version until something backfills it " <>
          "(see mix letflow.backfill_event_type_versions). " <>
          "Bumped from schema_version 3 to 4 (decision 0062 R8h-5, GH #2616): the optional " <>
          "\"output_labels\" and, on merged_variable_events entries, \"old_labels\"/" <>
          "\"new_labels\"/\"server_labels\"/\"submitted_labels\"/\"discarded_labels\" are " <>
          "declared (restriction labels; names only, never values).",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "output_variables" => %{"type" => "object"},
          "output_labels" => %{"type" => "object"},
          "merged_variable_events" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "event" => %{
                  "type" => "string",
                  "enum" => [
                    "variable_overwritten",
                    "computed_field_disagreement",
                    "visible_when_false_value_discarded"
                  ]
                },
                "key" => %{"type" => "string"},
                "field" => %{"type" => "string"},
                "old_value" => %{},
                "new_value" => %{},
                "submitted_value" => %{},
                "server_value" => %{},
                "discarded_value" => %{},
                "old_labels" => %{"type" => "array", "items" => %{"type" => "string"}},
                "new_labels" => %{"type" => "array", "items" => %{"type" => "string"}},
                "server_labels" => %{"type" => "array", "items" => %{"type" => "string"}},
                "submitted_labels" => %{"type" => "array", "items" => %{"type" => "string"}},
                "discarded_labels" => %{"type" => "array", "items" => %{"type" => "string"}}
              },
              "required" => ["event"]
            }
          },
          "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}},
          "attachments_at_decision" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "attachment_id" => %{"type" => "string"},
                "file_name" => %{"type" => "string"},
                "content_type" => %{"type" => "string"},
                "byte_size" => %{"type" => "integer"},
                "uploaded_by" => %{"type" => "string"},
                "created_at" => %{"type" => "string"}
              },
              "required" => ["attachment_id", "file_name"]
            }
          }
        },
        "required" => ["task_id", "node_id", "output_variables", "activated_nodes"]
      }
    },
    %{
      name: "INSTANCE_CANCELLED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine.cancel_instance/3 (M6) when a running instance is cancelled.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "cancelled_task_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
          "cancelled_token_ids" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["cancelled_task_ids", "cancelled_token_ids"]
      }
    },
    %{
      name: "INSTANCE_PINS_REBOUND",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine.PinRebind.rebind_pins/3 (M6) when a definition/sub-process " <>
          "version pin is rebound.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "entries" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "kind" => %{"type" => "string"},
                "ref" => %{"type" => "string"},
                "prior_version" => %{"type" => "string"},
                "new_version" => %{"type" => "string"}
              },
              "required" => ["kind", "ref", "new_version"]
            }
          },
          "actor" => %{"type" => "string"},
          "reason" => %{"type" => ["string", "null"]}
        },
        "required" => ["entries", "actor"]
      }
    },
    %{
      name: "SUB_PROCESS_COMPLETED",
      schema_version: 2,
      description:
        "Emitted by Letflow.Engine.SubProcess (M-series) on the parent instance's stream when " <>
          "a called sub-process instance completes and its output is merged back. " <>
          "Bumped from schema_version 1 to 2 (decision 0062 R8h-5, GH #2616): the optional " <>
          "\"output_labels\" and the merged entries' \"old_labels\"/\"new_labels\" are declared.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "child_instance_id" => %{"type" => "string"},
          "output_variables" => %{"type" => "object"},
          "output_labels" => %{"type" => "object"},
          "merged_variable_events" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "event" => %{"type" => "string", "enum" => ["variable_overwritten"]},
                "key" => %{"type" => "string"},
                "old_labels" => %{"type" => "array", "items" => %{"type" => "string"}},
                "new_labels" => %{"type" => "array", "items" => %{"type" => "string"}}
              },
              "required" => ["event", "key"]
            }
          },
          "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["child_instance_id", "output_variables", "activated_nodes"]
      }
    },
    %{
      name: "EXECUTION_ERROR",
      schema_version: 2,
      description:
        "Emitted by Letflow.Engine.ExecutionError.append_execution_error_event/2 (EE-10 AC1) " <>
          "when an instance transitions to the :error status. " <>
          "Bumped from schema_version 1 to 2 (decision 0062 R8h-5, GH #2616): the optional " <>
          "\"labels\" (the restriction labels of \"variables\") is declared.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "error_type" => %{"type" => "string"},
          "affected" => %{
            "type" => "object",
            "properties" => %{
              "kind" => %{"type" => "string", "enum" => ["node", "field"]},
              "node_id" => %{"type" => "string"},
              "key" => %{"type" => "string"}
            },
            "required" => ["kind"]
          },
          "reason" => %{"type" => "string"},
          "variables" => %{"type" => "object"},
          "labels" => %{"type" => "object"},
          "details" => %{"type" => "object"}
        },
        "required" => ["error_type", "affected", "reason", "variables"]
      }
    },
    %{
      name: "DEFINITION_PROMOTED",
      schema_version: 2,
      description:
        "Emitted by Letflow.Definitions.Promotion.promote_definition/3 (PRM-01, the " <>
          "review-gated path) AND Letflow.Definitions.Promotion.promote_active_definition/5 " <>
          "(REQ-077 R10/ENV-03, the reviewless test->production path) after a promotion " <>
          "commits, via Letflow.EventStore.PlatformEvents.append_definition_promoted/2. " <>
          "Bumped from schema_version 1 (REQ-140) to 2 (REQ-077 design §9.5): an ENV-03 " <>
          "promotion genuinely has no review, so `review_id` must admit `null` rather than " <>
          "forcing a synthetic id into the audit log. KNOWN GAP, flagged for REVIEWER: this " <>
          "only widens the schema seeded into TENANTS PROVISIONED FROM THIS POINT ON -- " <>
          "Letflow.EventStore.Registry.get_type/2 picks the highest schema_version already " <>
          "registered in a given tenant's own event_type_registry, and nothing here re-runs " <>
          "replay_migrations/2 against an already-provisioned tenant to seed version 2 there. " <>
          "A tenant provisioned before this change keeps validating DEFINITION_PROMOTED " <>
          "against version 1 (review_id required, non-null) until something backfills it -- " <>
          "R10 against such a tenant fails the event-append step (a committed promotion " <>
          "reported as a 500, the exact Severity-1 shape design §F-5.2 describes) until that " <>
          "backfill runs. Same class of gap as Letflow.Routers.Tenants' OQ-5 (operationally " <>
          "recoverable, not silently patched around here).",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "review_id" => %{"type" => ["string", "null"]},
          "source_tenant_id" => %{"type" => "string"},
          "target_tenant_id" => %{"type" => "string"},
          "source_definition_id" => %{"type" => "string"},
          "target_definition_id" => %{"type" => "string"},
          "process_key" => %{"type" => "string"}
        },
        "required" => [
          "review_id",
          "source_tenant_id",
          "target_tenant_id",
          "source_definition_id",
          "target_definition_id",
          "process_key"
        ]
      }
    },
    %{
      name: "DEFINITION_VERSION_ROLLED_BACK",
      schema_version: 1,
      description:
        "Emitted by Letflow.Definitions.rollback_definition_version/4 (PRM-08) after a " <>
          "version pointer swap commits, via Letflow.EventStore.PlatformEvents.append_definition_version_rolled_back/2.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "process_key" => %{"type" => "string"},
          "from_version" => %{"type" => "string"},
          "to_version" => %{"type" => "string"}
        },
        "required" => ["process_key", "from_version", "to_version"]
      }
    },
    %{
      name: "PROMOTION_ASSERTION_TEARDOWN_FAILED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Definitions.apply_promotion_assertion_rerun/6 (PRM-07) when " <>
          "sandbox release fails during assertion rerun, via " <>
          "Letflow.EventStore.PlatformEvents.append_promotion_assertion_teardown_failed/2.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{"type" => "string"},
          "sandbox_id" => %{"type" => "string"},
          "tenant_id" => %{"type" => "string"},
          "error" => %{"type" => "string"}
        },
        "required" => ["run_id", "sandbox_id", "tenant_id", "error"]
      }
    },
    %{
      name: "TIMER_FIRED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Scheduler.fire_timer/2 (SCH-01/05) when a pending timer's " <>
          "poll-and-fire transaction commits.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "timer_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "timer_type" => %{"type" => "string"},
          "fired_late" => %{"type" => "boolean"},
          "scheduled_fire_at" => %{"type" => "string"},
          "actual_fired_at" => %{"type" => "string"}
        },
        "required" => [
          "timer_id",
          "node_id",
          "timer_type",
          "fired_late",
          "scheduled_fire_at",
          "actual_fired_at"
        ]
      }
    },
    %{
      name: "SERVICE_TASK_COMPLETED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine.advance_after_service_task_outcome/4 (REQ-215) when a " <>
          "SERVICE_TASK dispatch's :advance outcome is applied and its VariableMerge.merge/3 " <>
          "output is persisted.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "dispatch_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "decoded_body" => %{"type" => "object"}
        },
        "required" => ["dispatch_id", "node_id", "decoded_body"]
      }
    },
    %{
      name: "effect_applied",
      schema_version: 1,
      description:
        "Emitted by Letflow.Ordering.Consumer.try_apply/2 (REQ-199, ORD-01) when a " <>
          "PENDING effect completion is applied in strict sequence order.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "correlation_id" => %{"type" => "string"},
          "sequence_no" => %{"type" => "integer"},
          "completion_id" => %{"type" => "string"}
        },
        "required" => ["correlation_id", "sequence_no", "completion_id"]
      }
    },
    %{
      name: "ordering_lag_threshold_exceeded",
      schema_version: 1,
      description:
        "Emitted by Letflow.Ordering.Metrics.write_to_registry/2 (REQ-199, ORD-04) " <>
          "when a correlation's lag exceeds the configured :letflow, :ordering, :lag_threshold.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "correlation_id" => %{"type" => "string"},
          "lag" => %{"type" => "integer"},
          "oldest_pending_age_seconds" => %{"type" => ["integer", "null"]}
        },
        "required" => ["correlation_id", "lag", "oldest_pending_age_seconds"]
      }
    },
    %{
      name: "ATTACHMENT_ATTACHED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Repository.Attachments.upload/2 (REQ-391) when an " <>
          "attachment is added to an instance.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "attachment_id" => %{"type" => "string"},
          "file_name" => %{"type" => "string"},
          "content_type" => %{"type" => "string"},
          "byte_size" => %{"type" => "integer"},
          "description" => %{"type" => ["string", "null"]}
        },
        "required" => ["attachment_id", "file_name", "content_type", "byte_size"]
      }
    },
    %{
      name: "ATTACHMENT_REMOVED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Repository.Attachments.delete/2 (REQ-391) when an " <>
          "attachment is removed from an instance.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "attachment_id" => %{"type" => "string"},
          "file_name" => %{"type" => "string"},
          "content_type" => %{"type" => "string"},
          "byte_size" => %{"type" => "integer"}
        },
        "required" => ["attachment_id", "file_name", "content_type", "byte_size"]
      }
    },
    # GH 2534 PR 7c-1 (decision 0053 D5, D9; design gh2534-7c-script-handler.md section 6):
    # the applied output of a tenant-script SERVICE_TASK (the replay source) and the value-free
    # per-run record. Both closed (additionalProperties false, every key required).
    %{
      name: "SCRIPT_TASK_COMPLETED",
      schema_version: 2,
      description:
        "Emitted by Letflow.Engine.apply_script_task_result/3 (GH 2534 7c) when a script " <>
          "SERVICE_TASK's declared output is merged into the instance variables. " <>
          "Bumped from schema_version 1 to 2 (decision 0062 R8h-5, GH #2616): the schema is " <>
          "closed, so the optional \"output_labels\" must be declared to be accepted.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "dispatch_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "attempt" => %{"type" => "integer"},
          "script_key" => %{"type" => "string"},
          "script_version" => %{"type" => "integer"},
          "output" => %{"type" => "object"},
          "output_labels" => %{"type" => "object"}
        },
        "required" => [
          "dispatch_id",
          "node_id",
          "attempt",
          "script_key",
          "script_version",
          "output"
        ],
        "additionalProperties" => false
      }
    },
    %{
      name: "SCRIPT_RUN_RECORDED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine.apply_script_task_result/3 (GH 2534 7c): the value-free " <>
          "per-run record of one terminal script SERVICE_TASK attempt.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "dispatch_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "attempt" => %{"type" => "integer"},
          "script_key" => %{"type" => "string"},
          "script_version" => %{"type" => "integer"},
          "script_sha256" => %{"type" => "string"},
          "phase" => %{"type" => "string", "enum" => ["rejected", "ran", "lease_expired"]},
          "outcome" => %{
            "type" => "string",
            "enum" => [
              "ok",
              "script_error",
              "budget_exceeded",
              "memory_limit_exceeded",
              "output_invalid",
              "timeout",
              "script_failed",
              "script_rejected",
              "script_busy"
            ]
          },
          "detail" => %{"type" => ["string", "null"]},
          "fail_code" => %{"type" => ["string", "null"]},
          "input_hmac" => %{"type" => ["string", "null"]},
          "input_hmac_key_version" => %{"type" => ["integer", "null"]},
          "duration_us" => %{"type" => ["integer", "null"]},
          "instructions_used" => %{"type" => ["integer", "null"]},
          "heap_words" => %{"type" => ["integer", "null"]},
          "input_dropped" => %{"type" => ["integer", "null"]},
          "principal" => %{"type" => "string"},
          "triggering_user_id" => %{"type" => ["string", "null"]}
        },
        "required" => [
          "dispatch_id",
          "node_id",
          "attempt",
          "script_key",
          "script_version",
          "script_sha256",
          "phase",
          "outcome",
          "detail",
          "fail_code",
          "input_hmac",
          "input_hmac_key_version",
          "duration_us",
          "instructions_used",
          "heap_words",
          "input_dropped",
          "principal",
          "triggering_user_id"
        ],
        "additionalProperties" => false
      }
    },
    # GH #2587 (decision 0054 D1, D11; design gh2587-req499-pr-a-prerequisites.md 2.3, 2.4):
    # the engine-only record of reserved values the engine set (applied on replay only
    # through VariableMerge.put_sys/3), and the value-free record of one step's entity
    # writes (changes no state on replay). Registered by PR A; appended from PR B/C. Both
    # closed (additionalProperties false, every key required); the engine constrains the
    # reserved keys and values the registry subset cannot (no propertyNames/pattern).
    %{
      name: "INSTANCE_SYS_VARIABLES_SET",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine (decision 0054, GH #2587) in the same transaction and " <>
          "before the completion event of a step whose entity writes minted record ids: the " <>
          "engine-only reserved variable values (record ids and event_global_seq) it set.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "node_id" => %{"type" => "string"},
          "cause" => %{"type" => "string", "enum" => ["entity_writes"]},
          "values" => %{"type" => "object"}
        },
        "required" => ["node_id", "cause", "values"],
        "additionalProperties" => false
      }
    },
    %{
      name: "TASK_ENTITY_WRITES_APPLIED",
      # v2 (GH #2590 / REQ-501 R4a): bumped IN PLACE (a v1 entry kept beside v2 would fail
      # every replay with :schema_version_not_monotonic for a tenant already at v2).
      # v3 (GH #2671): the handler key is renamed `handler_name` and the three handler keys
      # become all-or-none. A rename is not additive and Registry.register_type refuses an equal
      # version, so a tenant already holding the R4a v2 row only gets it as a new version; v2 is
      # replaced in place in the seed, same as v1 above.
      schema_version: 3,
      description:
        "Emitted by Letflow.Engine (decision 0054, GH #2587) when a HUMAN_TASK or " <>
          "SERVICE_TASK step's declared entity writes commit: ids and sequences only, no " <>
          "field value. Replay changes no state for it and never re-executes a write. " <>
          "Version 3 carries three line-item keys (handler_module, handler_name, write_ordinal; " <>
          "all or none) naming the module handler that produced a line; every v1 payload is " <>
          "also a valid v3 payload.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "node_id" => %{"type" => "string"},
          "task_id" => %{"type" => ["string", "null"]},
          "dispatch_id" => %{"type" => ["string", "null"]},
          "lines_hash" => %{"type" => "string"},
          "lines" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "line_index" => %{"type" => "integer", "minimum" => 0},
                "entity_type" => %{"type" => "string"},
                "record_id" => %{"type" => "string"},
                "event_global_seq" => %{"type" => "integer", "minimum" => 0},
                # v2: present only on a module-handler line (ids and names, never a value).
                "handler_module" => %{"type" => "string"},
                "handler_name" => %{"type" => "string"},
                "write_ordinal" => %{"type" => "integer", "minimum" => 1}
              },
              "required" => ["line_index", "entity_type", "record_id", "event_global_seq"],
              # GH #2671: the three handler keys come together or not at all.
              "dependentRequired" => %{
                "handler_module" => ["handler_name", "write_ordinal"],
                "handler_name" => ["handler_module", "write_ordinal"],
                "write_ordinal" => ["handler_module", "handler_name"]
              },
              "additionalProperties" => false
            }
          }
        },
        "required" => ["node_id", "task_id", "dispatch_id", "lines_hash", "lines"],
        "additionalProperties" => false
      }
    }
  ]

  @doc false
  # Test-support hook: the (name, schema_version) pairs the platform seed registers, so the
  # tenant_template fingerprint changes when a seeded event type is bumped (GH #2671).
  def platform_event_type_seed_versions do
    Enum.map(@platform_event_type_seed_attrs, &{&1.name, &1.schema_version})
  end

  @doc """
  The seeded attrs of the event type `name` (`nil` when the seed has none): the single source
  `mix letflow.backfill_event_type_versions` reads for the types it brings to the current
  seed version, so the backfill never carries a second copy of a schema.
  """
  @spec platform_event_type_seed_attrs(String.t()) :: map() | nil
  def platform_event_type_seed_attrs(name) when is_binary(name) do
    Enum.find(@platform_event_type_seed_attrs, &(&1.name == name))
  end

  defp maybe_seed_platform_event_types(false, _tenant_id), do: :ok

  defp maybe_seed_platform_event_types(true, tenant_id) do
    Enum.reduce_while(@platform_event_type_seed_attrs, :ok, fn attrs, :ok ->
      case Registry.register_type(attrs, tenant_id) do
        {:ok, _event_type} -> {:cont, :ok}
        {:error, :duplicate_event_type_version} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:event_type_seed_failed, reason}}}
      end
    end)
  end

  @spec maybe_seed_entity_event_types(
          using_default_manifest? :: boolean(),
          schema_name :: String.t()
        ) ::
          :ok | {:error, {:event_type_seed_failed, term()}}
  defp maybe_seed_entity_event_types(false, _schema_name), do: :ok

  defp maybe_seed_entity_event_types(true, schema_name) do
    case Letflow.Entities.EventTypes.seed!(schema_name) do
      {:ok, _seed_result} -> :ok
      # Carve-out (design §6): a schema_name that doesn't reverse to a real
      # tenant_id (e.g. test/support/tenant_template.ex's synthetic
      # self-check schema) has no tenant-facing entity-record write path to
      # protect -- skip silently rather than failing replay_migrations/2's
      # with-chain for a schema no real tenant is ever routed to.
      {:error, :invalid_schema_name} -> :ok
      {:error, reason} -> {:error, {:event_type_seed_failed, reason}}
    end
  end

  # =========================================================================
  # REQ-297 -- entity column-promotion executor
  #
  # See lib/letflow/design/req297-entity-promotion-executor.md for the full
  # design this section implements, and
  # docs/migration/decisions/0024-entity-promotion-ddl-execution.md for the
  # decision it's built from. This section implements all four of 0024's
  # sub-answers:
  #
  #   1. THE MECHANISM: this module (Letflow.TenantProvisioning), extended --
  #      not a second module -- issuing `ALTER TABLE`/`CREATE TABLE`
  #      directly against a tenant's own Postgres schema.
  #   2. PARTIAL-FAILURE: per-tenant, tracked one row per
  #      (tenant_id, entity_type, attribute) in `entity_column_promotions`
  #      (Letflow.TenantProvisioning.ColumnPromotion) -- a promotion is NOT
  #      atomic across tenants; each tenant's row succeeds or fails on its
  #      own, and repair is a retry of that one row
  #      (retry_failed_column_promotion/1), never a whole-batch re-run.
  #   3. BACKFILL: a replay through
  #      Letflow.Entities.Record.Projector.rebuild_projection/2 (never an
  #      inline UPDATE), with dual-write into the per-entity-type table kept
  #      current for the whole ddl_applied..backfilled window
  #      (column_promotion_dual_write?/3, wired into
  #      Letflow.Entities.Records's write path below).
  #   4. ROLLBACK: suspend_column_promotion/2 flips `query_eligible` to
  #      `false` (query-layer exclusion) while leaving `status` at `"active"`
  #      -- this executor has no code path that drops or narrows a column;
  #      "rollback" here means "stop querying it," never "undo the DDL."
  # =========================================================================

  @doc """
  Derives the physical per-entity-type table name for `entity_type`, mirroring
  `schema_name_for_tenant/1`'s own `"tenant_" <> hex` shape. The only place a
  physical per-entity-type table name is ever derived -- every function below
  that needs one calls this rather than re-deriving the `"entity_" <>` prefix
  inline.

  Validated against `Letflow.Entities.Definition.DDL.valid_identifier?/1`
  (the same public, independent regex `DDL` already exposes), not by
  importing `Letflow.Entities.Definition.Validator`'s own private
  name-format rule.
  """
  @spec table_name_for_entity_type(entity_type :: String.t()) ::
          {:ok, table_name :: String.t()} | {:error, :invalid_entity_type}
  def table_name_for_entity_type(entity_type) when is_binary(entity_type) do
    if DDL.valid_identifier?(entity_type) do
      {:ok, "entity_" <> entity_type}
    else
      {:error, :invalid_entity_type}
    end
  end

  def table_name_for_entity_type(_entity_type), do: {:error, :invalid_entity_type}

  @doc false
  @spec entity_table_exists?(schema_name :: String.t(), table_name :: String.t()) :: boolean()
  def entity_table_exists?(schema_name, table_name) do
    query = """
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = $1 AND table_name = $2
    """

    case Repo.query!(query, [schema_name, table_name]) do
      %Postgrex.Result{rows: []} -> false
      %Postgrex.Result{rows: [_ | _]} -> true
    end
  end

  @doc """
  Whether `column_name` physically exists on `table_name` in the tenant
  schema named by `schema_name` -- the column-granularity counterpart to
  `entity_table_exists?/2` above, same idiom exactly (parameterised SQL
  against `information_schema.columns`, `Repo.query!/2`, `rows == []` ->
  `false`).

  REQ-300 rework cycle 3 (SECURITY-REVIEWER-reported regression): a
  per-entity-type table can exist while a *specific* declared-but-never-
  promoted column on it does not (0023's additive-declare-then-promote
  rule allows a definition to declare a new `queried: true` field or
  `fk_def` after the table already exists from an earlier promotion).
  Checking only `entity_table_exists?/2` is table-granularity and
  therefore insufficient to decide whether one particular column is safe
  to reference as a real Postgres identifier -- this function is the
  shared, single implementation of the column-granularity check, called
  by both `Letflow.Entities.Query.Allowlist.load/2` (gating `:typed_column`
  classification per candidate promoted column name, so a
  declared-but-unpromoted field falls back to the always-safe
  `:json_field`/JSONB path instead) and
  `Letflow.Entities.Query.Compiler.relation_column_exists?/3` (which
  delegates here rather than duplicating this query, for the join-path's
  own declaring-side check). Colocated with `entity_table_exists?/2`
  rather than in either caller, since both callers already depend on this
  module for table-existence and neither should own physical-schema
  introspection that the other also needs.
  """
  @spec entity_column_exists?(
          schema_name :: String.t(),
          table_name :: String.t(),
          column_name :: String.t()
        ) :: boolean()
  def entity_column_exists?(schema_name, table_name, column_name) do
    query = """
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
    """

    case Repo.query!(query, [schema_name, table_name, column_name]) do
      %Postgrex.Result{rows: []} -> false
      %Postgrex.Result{rows: [_ | _]} -> true
    end
  end

  @doc """
  Creates one `pending` `Letflow.TenantProvisioning.ColumnPromotion` row per
  tenant. `:all` resolves via `list_registrations/0` at call time (this
  module's own tenant-enumeration mechanism, reused rather than a second
  one). `column_spec.pg_type` is supplied by the caller from
  `Letflow.Entities.Definition.DDL.field_type_to_pg_type/1` applied to the
  promoted `field_def()` -- this function does not re-derive the type
  mapping. `column_spec.nullable` is always treated as `true`, per 0023's
  additive-only rule -- there is no caller override. Issues no DDL.

  `column_spec.generated_as` (REQ-301) is optional and defaults to `nil`
  via `Map.get/2` (never `Map.fetch!/2`) -- absent means an ordinary,
  non-generated column, exactly as every existing caller's two-key shape
  already produces. For a `:localized_text` field's locale columns, the
  caller calls this function once per `column_spec()`
  `Letflow.Entities.Definition.DDL.promoted_columns/1` returns for that
  field (once per locale), passing `attribute: column_spec.name` (e.g.
  `"stem_kk"`) and `column_spec.generated_as` set to that entry's
  generation-expression text.
  """
  @spec register_column_promotion(
          entity_type :: String.t(),
          attribute :: String.t(),
          column_spec :: %{
            required(:pg_type) => String.t(),
            required(:nullable) => true,
            optional(:references_entity) => String.t(),
            optional(:generated_as) => String.t() | nil
          },
          tenant_ids :: [Ecto.UUID.t()] | :all
        ) ::
          {:ok, [ColumnPromotion.t()]}
          | {:error, :invalid_entity_type}
          | {:error, :invalid_attribute}
          | {:error, term()}
  def register_column_promotion(entity_type, attribute, column_spec, tenant_ids)
      when is_binary(entity_type) and is_binary(attribute) and is_map(column_spec) do
    cond do
      not DDL.valid_identifier?(entity_type) ->
        {:error, :invalid_entity_type}

      not DDL.valid_identifier?(attribute) ->
        {:error, :invalid_attribute}

      true ->
        do_register_column_promotion(entity_type, attribute, column_spec, tenant_ids)
    end
  end

  defp do_register_column_promotion(entity_type, attribute, column_spec, tenant_ids) do
    tenant_ids = resolve_tenant_ids(tenant_ids)
    pg_type = Map.fetch!(column_spec, :pg_type)
    references_entity = Map.get(column_spec, :references_entity)
    generated_as = Map.get(column_spec, :generated_as)

    Repo.transaction(fn ->
      Enum.map(tenant_ids, fn tenant_id ->
        attrs = %{
          tenant_id: tenant_id,
          entity_type: entity_type,
          attribute: attribute,
          column_name: attribute,
          pg_type: pg_type,
          references_entity: references_entity,
          generated_as: generated_as,
          status: "pending",
          query_eligible: false
        }

        case Repo.insert(ColumnPromotion.changeset(%ColumnPromotion{}, attrs)) do
          {:ok, row} -> row
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  defp resolve_tenant_ids(:all), do: Enum.map(list_registrations(), & &1.tenant_id)
  defp resolve_tenant_ids(tenant_ids) when is_list(tenant_ids), do: tenant_ids

  @doc """
  The one function that issues DDL. Single-tenant, single-promotion, taking
  only `promotion_id` -- `tenant_id` is never a second, independently
  supplied argument (design doc §4 step 1; matches the fix
  SECURITY-REVIEWER's re-check already confirmed for req295 §2's text).

  Steps: load the row, resolve its tenant's schema, take the same per-schema
  advisory lock `provision_tenant_schema/1` already takes, ensure the
  per-entity-type table exists (`ensure_entity_table/2`, private below),
  run the additive-only check against real `information_schema.columns`
  state, then issue `ALTER TABLE ... ADD COLUMN` (or skip it, as an
  idempotent retry, if an identically-typed column is already present).
  """
  @spec run_column_promotion(promotion_id :: Ecto.UUID.t()) ::
          {:ok, ColumnPromotion.t()}
          | {:error,
             :promotion_not_found
             | :tenant_not_provisioned
             | {:column_type_conflict, existing_pg_type :: String.t(),
                requested_pg_type :: String.t()}
             | {:ddl_failed, Exception.t()}}
  def run_column_promotion(promotion_id) do
    with {:ok, promotion} <- fetch_column_promotion(promotion_id),
         {:ok, schema_name} <- resolve_schema_name(promotion.tenant_id) do
      # ISS-0623 finding, flagged for REVIEWER: `do_run_column_promotion/2`
      # returns most of its `{:error, reason}` outcomes as ordinary values
      # (relying on this transaction's eventual COMMIT to persist
      # `mark_ddl_failed_and_return/3`'s own status="ddl_failed" write --
      # by design, that write must survive), but its `mark_ddl_failed_and_return/3`
      # helper now calls `Repo.rollback/1` directly (not an ordinary
      # return) for the one sub-case where the connection is already
      # aborted by a genuine raised Postgres DDL error (see that
      # function's own comment) -- so `Repo.transaction/1` below can
      # legitimately return either `{:ok, outcome}` (the ordinary-return
      # path, `outcome` itself possibly an `{:error, _}` tuple that is
      # still meant to be committed) or `{:error, reason}` (the explicit
      # `Repo.rollback/1` path). Both are handled and normalized to this
      # function's own `@spec` shape.
      case Repo.transaction(fn ->
             Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [schema_name])
             do_run_column_promotion(schema_name, promotion)
           end) do
        {:ok, outcome} -> outcome
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_run_column_promotion(schema_name, promotion) do
    with {:ok, table_name} <- checked_table_name(promotion),
         :ok <- ensure_entity_table(schema_name, promotion.entity_type),
         {:ok, target_table} <- resolve_fk_target_table(promotion) do
      case check_additive_only(schema_name, table_name, promotion) do
        :ok ->
          add_column_and_mark(schema_name, table_name, promotion, target_table)

        :idempotent_skip ->
          mark_ddl_applied(promotion)

        {:error, {:column_type_conflict, existing, requested}} ->
          mark_ddl_failed_and_return(
            promotion,
            "column type conflict: existing #{existing}, requested #{requested}",
            {:column_type_conflict, existing, requested}
          )
      end
    else
      {:error, {:ddl_failed, exception}} ->
        mark_ddl_failed_and_return(
          promotion,
          Exception.message(exception),
          {:ddl_failed, exception}
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # REQ-298 §3.3 -- resolves a ColumnPromotion's optional references_entity
  # (an entity-type string) to a physical target table name, immediately
  # after ensure_entity_table/2 succeeds and before check_additive_only/3.
  # {:ok, nil} for the common, non-FK case -- no behavior change from
  # REQ-297. A {:error, :invalid_entity_type} result is only reachable if a
  # row bypassed register_column_promotion/4's own input (same
  # defence-in-depth posture as checked_table_name/1), remapped here to
  # {:error, :invalid_fk_target_entity_type} and returned directly,
  # short-circuiting before any DDL is attempted -- reachable from
  # realistic (if invalid) stored data, so this is a with-chain addition,
  # not a raise.
  @spec resolve_fk_target_table(ColumnPromotion.t()) ::
          {:ok, target_table :: String.t() | nil} | {:error, :invalid_fk_target_entity_type}
  defp resolve_fk_target_table(%ColumnPromotion{references_entity: nil}), do: {:ok, nil}

  defp resolve_fk_target_table(%ColumnPromotion{references_entity: entity_type}) do
    case table_name_for_entity_type(entity_type) do
      {:ok, target_table} -> {:ok, target_table}
      {:error, :invalid_entity_type} -> {:error, :invalid_fk_target_entity_type}
    end
  end

  defp add_column_and_mark(schema_name, table_name, promotion, target_table) do
    case execute_add_column(schema_name, table_name, promotion, target_table) do
      :ok ->
        mark_ddl_applied(promotion)

      {:error, {:ddl_failed, exception}} ->
        mark_ddl_failed_and_return(
          promotion,
          Exception.message(exception),
          {:ddl_failed, exception}
        )
    end
  end

  # As of ISS-0777, entity_type IS validated before a ColumnPromotion row can
  # exist for it -- at register_column_promotion/4's own entry (this module),
  # for every caller, and additionally at
  # Letflow.Platform.MigrationRollout.start_rollout/3's entry, before that
  # function ever reaches register_column_promotion/4, for the
  # platform-migration-rollout write path specifically. This raise remains
  # reachable only if a ColumnPromotion row was written by some path that
  # bypasses register_column_promotion/4 entirely (e.g. a direct
  # Repo.insert/Repo.insert! against the schema, or a future write path added
  # without reading this comment) -- a genuine internal-invariant violation,
  # not a value this module's own public write surface can currently produce.
  # Re-checked here anyway (defence in depth matching DDL's own posture) and
  # raised as an ArgumentError, never silently proceeded, rather than
  # converted to a tagged {:error, _} -- this is intentionally a loud
  # last-resort assertion, not normal control flow. This is why
  # :invalid_entity_type is not in run_column_promotion/1's own @spec -- it
  # is unreachable via any function on this module's own public surface.
  defp checked_table_name(promotion) do
    case table_name_for_entity_type(promotion.entity_type) do
      {:ok, table_name} ->
        {:ok, table_name}

      {:error, :invalid_entity_type} ->
        raise ArgumentError,
              "ColumnPromotion #{promotion.id} has an invalid entity_type: " <>
                inspect(promotion.entity_type)
    end
  end

  # ---------------------------------------------------------------------
  # Table-lifecycle step (design doc §6) -- resolves the executor's own
  # narrow table-creation-on-first-use gap (design doc §1). Private -- not
  # part of req295 §2's public function list.
  # ---------------------------------------------------------------------

  @spec ensure_entity_table(schema_name :: String.t(), entity_type :: String.t()) ::
          :ok | {:error, {:ddl_failed, Exception.t()}} | {:error, term()}
  defp ensure_entity_table(schema_name, entity_type) do
    with {:ok, table_name} <- table_name_for_entity_type(entity_type) do
      if entity_table_exists?(schema_name, table_name) do
        :ok
      else
        create_and_populate_entity_table(schema_name, entity_type, table_name)
      end
    end
  end

  # Creates the per-entity-type table carrying the entity type's FULL
  # current promoted-column set (not just the one attribute triggering this
  # particular promotion), then immediately populates it via
  # rebuild_projection/2 -- the "first population" design doc §1 names,
  # folded into table creation rather than left as a separately-triggered
  # step (an empty freshly-created table would otherwise silently
  # under-count in the very next backfill_column_promotion/1 verification
  # check).
  #
  # What happens if generate_table_ddl/2 returns {:error, {:invalid_identifier, _}}
  # here (design doc §6's own narration, per CODE-DESIGN-VALIDATOR's nit):
  # realistically unreachable, since `table_name` is this module's own
  # `"entity_" <> entity_type` derivation (already checked via
  # table_name_for_entity_type/1 above) and every promoted column name is a
  # field name that already passed Letflow.Entities.Definition.Validator's
  # identical name-format check at entity-definition-creation time -- stated
  # explicitly here rather than left an unnarrated catch-all. If it were
  # ever reached anyway, generate_table_ddl/2's own {:error, ddl_error()}
  # return flows straight out of this `with` unchanged.
  # ISS-0623: `DDL.index_create_statements/2` + `execute_create_indexes/3`
  # are added here, after the CREATE TABLE step and before
  # Projector.rebuild_projection/2's call, per the approved design
  # (lib/letflow/design/iss0623-entity-index-ddl-emission.md §2). No
  # explicit rollback logic is needed for a mid-way CREATE INDEX failure:
  # this whole chain runs inside run_column_promotion/1's single
  # Repo.transaction/1 (line ~1283), and a raised Postgres-level SQL error
  # aborts that transaction -- execute_create_indexes/3 rescues the
  # exception into an ordinary {:error, {:ddl_failed, _}} return (never a
  # re-raise, never Repo.rollback/1), but Postgres itself still refuses
  # every subsequent statement on that connection and turns the eventual
  # COMMIT into an implicit ROLLBACK once Repo.transaction/1's function
  # returns normally. So a failed CREATE INDEX rolls back the CREATE TABLE
  # too -- all-or-nothing "for free," identical in spirit to
  # execute_create_table/1's own existing failure handling, just extended
  # to cover the statements after it in the same transaction.
  # entity_table_exists?/2 will then correctly see "no table" on any retry.
  defp create_and_populate_entity_table(schema_name, entity_type, table_name) do
    with {:ok, definition} <- Definitions.get_active_definition_by_name(entity_type, schema_name),
         document = document_from_persisted(definition),
         {:ok, fk_target_tables} <- resolve_fk_target_tables(document),
         {:ok, sql} <- DDL.generate_table_ddl(document, table_name, fk_target_tables),
         :ok <-
           execute_create_table(
             qualify_create_table_sql(sql, schema_name, table_name, fk_target_tables)
           ),
         {:ok, index_sqls} <- DDL.index_create_statements(document, table_name),
         :ok <- execute_create_indexes(schema_name, table_name, index_sqls) do
      rebuild_projection_for_new_table(schema_name, entity_type)
    end
  end

  # ISS-0648 companion fix (design doc §6): `Projector.rebuild_projection/2`'s
  # own backfill write issues each row via `Repo.query!/2` (the raising
  # variant), inside its own NESTED `Repo.transaction/1` (this function
  # already runs inside `run_column_promotion/1`'s own outer
  # `Repo.transaction/1`) -- so a raised `Postgrex.Error` (e.g. a genuine
  # unique-violation replaying pre-existing duplicate data, ISS-0648's own
  # empirical trigger) is caught by Ecto's nested-transaction/SAVEPOINT
  # handling (the enclosing connection is not left aborted) and then
  # re-raised out of `Projector.rebuild_projection/2` itself -- never a
  # `Repo.rollback/1`, and never an ordinary `{:error, reason}` return.
  # Rescued here into the same `{:error, {:ddl_failed, exception}}` shape
  # `execute_create_table/1`/`execute_create_indexes/3` immediately above
  # already use, so `do_run_column_promotion/2`'s existing `else` clause
  # (which already calls `mark_ddl_failed_and_return/3` for that shape)
  # covers this failure too, instead of the exception escaping
  # `run_column_promotion/1` (and, transitively, `ensure_column_promotions/2`
  # / `Letflow.Entities.Definitions.activate_definition/4`) unhandled.
  defp rebuild_projection_for_new_table(schema_name, entity_type) do
    case Projector.rebuild_projection(schema_name, entity_type: entity_type) do
      {:ok, _result} ->
        :ok

      # A brand-new entity type with zero records yet has no
      # entity_type_instances row -- nothing to backfill, not a real
      # failure. The freshly-created table is simply left empty.
      {:error, :entity_type_not_found} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  rescue
    exception -> {:error, {:ddl_failed, exception}}
  end

  defp execute_create_table(sql) do
    Repo.query!(sql)
    :ok
  rescue
    exception -> {:error, {:ddl_failed, exception}}
  end

  # ISS-0623: issues each `CREATE INDEX`/`CREATE UNIQUE INDEX` statement
  # DDL.index_create_statements/2 returned, in declared order, against the
  # tenant schema -- mirrors execute_create_table/1's rescue-into-
  # {:ddl_failed, exception} shape exactly, so it composes into
  # create_and_populate_entity_table/3's existing `with`/`else` handling
  # with no new error shape. Deliberately does NOT pre-check for an
  # existing index of the same name before issuing CREATE INDEX (unlike
  # constraint_exists?/3's idempotent-skip) -- per the approved design §4,
  # a name collision against another entity type's already-created table in
  # this schema must surface as a real, unswallowed Postgres "already
  # exists" error via this same {:ddl_failed, exception} path, never a
  # silent rename and never a silently swallowed success.
  @spec execute_create_indexes(schema_name :: String.t(), table_name :: String.t(), [
          String.t()
        ]) :: :ok | {:error, {:ddl_failed, Exception.t()}}
  defp execute_create_indexes(schema_name, table_name, index_sqls) do
    Enum.reduce_while(index_sqls, :ok, fn sql, :ok ->
      qualified_sql = qualify_index_create_sql(sql, schema_name, table_name)

      try do
        Repo.query!(qualified_sql)
        {:cont, :ok}
      rescue
        exception -> {:halt, {:error, {:ddl_failed, exception}}}
      end
    end)
  end

  # DDL.index_create_statements/2 is schema-agnostic and returns
  # `CREATE INDEX "<name>" ON "<table_name>" (...)` unqualified -- same
  # convention generate_table_ddl/3 already uses. The `ON "<table_name>"`
  # substring is unique within a single CREATE INDEX statement, so a
  # substring-replace is unambiguous per-statement (same technique
  # qualify_create_table_sql/4/qualify_fk_references/3 already use).
  @spec qualify_index_create_sql(
          sql :: String.t(),
          schema_name :: String.t(),
          table_name :: String.t()
        ) ::
          String.t()
  defp qualify_index_create_sql(sql, schema_name, table_name) do
    unqualified = ~s|ON "#{table_name}"|
    qualified = ~s|ON "#{schema_name}"."#{table_name}"|
    String.replace(sql, unqualified, qualified)
  end

  # generate_table_ddl/3 is deliberately schema-agnostic (its own moduledoc)
  # and returns `CREATE TABLE "<table_name>" (...)` (with any `REFERENCES
  # "<target_table>"` clauses also unqualified) -- this module is the one
  # that knows the target tenant schema, so it qualifies the statement
  # itself rather than asking DDL to grow schema awareness. REQ-298 extends
  # this to also schema-qualify every REFERENCES target, the same way it
  # already qualifies the leading CREATE TABLE table name.
  defp qualify_create_table_sql(sql, schema_name, table_name, fk_target_tables) do
    unqualified_prefix = "CREATE TABLE \"#{table_name}\" ("
    qualified_prefix = "CREATE TABLE \"#{schema_name}\".\"#{table_name}\" ("

    sql
    |> String.replace_prefix(unqualified_prefix, qualified_prefix)
    |> qualify_fk_references(schema_name, fk_target_tables)
  end

  defp qualify_fk_references(sql, schema_name, fk_target_tables) do
    Enum.reduce(fk_target_tables, sql, fn {_entity_type, target_table}, acc ->
      unqualified = ~s|REFERENCES "#{target_table}"(|
      qualified = ~s|REFERENCES "#{schema_name}"."#{target_table}"(|
      String.replace(acc, unqualified, qualified)
    end)
  end

  # REQ-298 §3.4 -- resolves every distinct references_entity named by
  # document.foreign_keys to its physical table name, via
  # table_name_for_entity_type/1 (a pure function of the entity-type string
  # alone -- no target Definition.t() lookup needed). Built for
  # DDL.generate_table_ddl/3's own fk_target_tables argument.
  @spec resolve_fk_target_tables(Letflow.Entities.Definition.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, {:invalid_entity_type, String.t()}}
  defp resolve_fk_target_tables(document) do
    document
    |> Map.get(:foreign_keys, [])
    |> Enum.map(&Map.get(&1, :references_entity))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn entity_type, {:ok, acc} ->
      case table_name_for_entity_type(entity_type) do
        {:ok, table_name} -> {:cont, {:ok, Map.put(acc, entity_type, table_name)}}
        {:error, :invalid_entity_type} -> {:halt, {:error, {:invalid_entity_type, entity_type}}}
      end
    end)
  end

  # ---------------------------------------------------------------------
  # Additive-only enforcement (design doc §7) -- the concrete mechanism
  # AC4/AC5 require: a real information_schema.columns check, never a
  # heuristic on the definition alone.
  # ---------------------------------------------------------------------

  defp check_additive_only(schema_name, table_name, promotion) do
    case fetch_existing_column(schema_name, table_name, promotion.column_name) do
      nil ->
        :ok

      {existing_data_type, existing_precision, existing_scale} ->
        if pg_types_equivalent?(
             existing_data_type,
             existing_precision,
             existing_scale,
             promotion.pg_type
           ) do
          :idempotent_skip
        else
          existing_repr =
            format_existing_pg_type(existing_data_type, existing_precision, existing_scale)

          {:error, {:column_type_conflict, existing_repr, promotion.pg_type}}
        end
    end
  end

  defp fetch_existing_column(schema_name, table_name, column_name) do
    query = """
    SELECT data_type, numeric_precision, numeric_scale
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
    """

    case Repo.query!(query, [schema_name, table_name, column_name]) do
      %Postgrex.Result{rows: []} -> nil
      %Postgrex.Result{rows: [[data_type, precision, scale]]} -> {data_type, precision, scale}
    end
  end

  # A small, explicit Postgres-type-name equivalence table (design doc §4
  # step 6) -- never a raw string compare against `data_type` alone, since
  # Postgres reports `numeric` precision/scale in separate columns.
  defp pg_types_equivalent?(
         existing_data_type,
         existing_precision,
         existing_scale,
         requested_pg_type
       ) do
    case parse_requested_pg_type(requested_pg_type) do
      {"numeric", requested_precision, requested_scale} ->
        existing_data_type == "numeric" and existing_precision == requested_precision and
          existing_scale == requested_scale

      {normalized_type, _p, _s} ->
        existing_data_type == normalized_type
    end
  end

  defp parse_requested_pg_type("numeric(" <> rest) do
    [precision, scale] =
      rest
      |> String.trim_trailing(")")
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))

    {"numeric", precision, scale}
  end

  defp parse_requested_pg_type("numeric"), do: {"numeric", nil, nil}

  defp parse_requested_pg_type("timestamp(6) without time zone"),
    do: {"timestamp without time zone", nil, nil}

  defp parse_requested_pg_type(other), do: {other, nil, nil}

  defp format_existing_pg_type("numeric", precision, scale)
       when is_integer(precision) and is_integer(scale) do
    "numeric(#{precision}, #{scale})"
  end

  defp format_existing_pg_type(data_type, _precision, _scale), do: data_type

  # The known closed set DDL.field_type_to_pg_type/1 can ever produce --
  # promotion.pg_type is never caller-free-text at this point
  # (register_column_promotion/4 requires the caller to have already called
  # that function), checked again here (defence in depth) before
  # interpolation.
  @known_fixed_pg_types [
    "text",
    "bigint",
    "boolean",
    "date",
    "timestamp(6) without time zone",
    # REQ-298 -- an FK-promoted column's physical type (DDL's
    # fk_column_pg_type/2 override; see that function's own comment for
    # why `text` cannot be used for a REFERENCES-bearing column).
    "uuid",
    "tsvector"
  ]
  @numeric_pg_type_regex ~r/^numeric(\(\d+,\s?\d+\))?\z/

  defp valid_pg_type?(pg_type) do
    pg_type in @known_fixed_pg_types or Regex.match?(@numeric_pg_type_regex, pg_type)
  end

  # Only ever adds a new column -- this executor never removes a column and
  # never narrows an existing column's declared type (design doc §7, AC5).
  # `table_name`/`column_name`/`pg_type`/`generated_as` are all re-validated
  # immediately before interpolation (defence in depth matching DDL's own
  # posture) -- an ArgumentError here means a stored row bypassed
  # register_column_promotion/4, a genuine defect that must not be silently
  # swallowed as a DDL failure.
  # target_table (REQ-298) is the already-resolved physical table an
  # FK-promoted column's REFERENCES clause points at -- `nil` for the
  # common, non-FK case (identical SQL shape REQ-297 already emits).
  defp execute_add_column(schema_name, table_name, promotion, target_table) do
    unless DDL.valid_identifier?(table_name) do
      raise ArgumentError, "invalid table_name for ALTER TABLE: #{inspect(table_name)}"
    end

    unless DDL.valid_identifier?(promotion.column_name) do
      raise ArgumentError,
            "invalid column_name for ALTER TABLE: #{inspect(promotion.column_name)}"
    end

    unless valid_pg_type?(promotion.pg_type) do
      raise ArgumentError, "invalid pg_type for ALTER TABLE: #{inspect(promotion.pg_type)}"
    end

    if target_table != nil and not DDL.valid_identifier?(target_table) do
      raise ArgumentError,
            "invalid target_table for ALTER TABLE REFERENCES: #{inspect(target_table)}"
    end

    # REQ-301: re-validate generated_as the same way as the three fields
    # above -- nil (every ordinary, non-generated promotion) is fine as-is;
    # anything non-nil must match one of the two known SQL-expression
    # shapes DDL.localized_text_column_specs/1 ever produces (SECURITY-REVIEWER's
    # WF02-REQ301-20260910 review note: this function otherwise re-validates
    # every interpolated value at the DDL-execution boundary, and generated_as
    # is itself interpolated below, so it should not be the one exception).
    unless is_nil(promotion.generated_as) or
             DDL.valid_generated_as_expression?(promotion.generated_as) do
      raise ArgumentError,
            "invalid generated_as for ALTER TABLE: #{inspect(promotion.generated_as)}"
    end

    sql = build_add_column_sql(schema_name, table_name, promotion, target_table)

    Repo.query!(sql)
    :ok
  rescue
    exception -> {:error, {:ddl_failed, exception}}
  end

  defp build_add_column_sql(schema_name, table_name, promotion, nil) do
    ~s(ALTER TABLE "#{schema_name}"."#{table_name}" ADD COLUMN "#{promotion.column_name}" #{promotion.pg_type}#{generated_as_suffix(promotion.generated_as)})
  end

  defp build_add_column_sql(schema_name, table_name, promotion, target_table) do
    ~s(ALTER TABLE "#{schema_name}"."#{table_name}" ADD COLUMN "#{promotion.column_name}" #{promotion.pg_type}) <>
      ~s| REFERENCES "#{schema_name}"."#{target_table}"("record_id") ON DELETE RESTRICT|
  end

  # REQ-301: a locale-derived generated column's `ColumnPromotion.generated_as`
  # carries the same `GENERATED ALWAYS AS (...) STORED` expression text
  # `Letflow.Entities.Definition.DDL`'s own `CREATE TABLE` path emits
  # (`column_sql_line/1`) -- kept textually consistent across both halves of
  # table DDL. `nil` (every ordinary promotion) produces no suffix at all.
  defp generated_as_suffix(nil), do: ""
  defp generated_as_suffix(generated_as), do: " GENERATED ALWAYS AS (#{generated_as}) STORED"

  defp mark_ddl_applied(promotion) do
    now = naive_now()

    attrs = %{status: "ddl_applied", ddl_applied_at: now, attempted_at: now, last_error: nil}

    case Repo.update(ColumnPromotion.changeset(promotion, attrs)) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp mark_ddl_failed_and_return(promotion, message, error_reason) do
    now = naive_now()
    attrs = %{status: "ddl_failed", last_error: message, attempted_at: now}

    case Repo.update(ColumnPromotion.changeset(promotion, attrs)) do
      {:ok, _updated} -> {:error, error_reason}
      {:error, changeset} -> {:error, changeset}
    end
  rescue
    # ISS-0623 finding, flagged for REVIEWER: a genuine *raised* Postgres-
    # level DDL error (e.g. a real cross-entity-type index-name collision,
    # design §4) aborts the enclosing run_column_promotion/1's
    # Repo.transaction/1 outright -- Postgres then refuses every
    # subsequent statement on that same connection, including this
    # function's own UPDATE, with `25P02 in_failed_sql_transaction`. This
    # is a pre-existing structural gap in this shared helper (reachable by
    # ANY {:ddl_failed, exception} path whose exception is a genuine
    # raised Postgres error, not only this fix's new index-collision case)
    # -- no prior test exercised a real raised-mid-transaction Postgres
    # exception here, only Elixir-detected conditions
    # (:column_type_conflict) or ArgumentError raises, neither of which
    # abort the Postgres transaction. Swallowing this specific failure and
    # still returning the real underlying `error_reason` is harmless: the
    # UPDATE this rescues was never going to be persisted anyway, since
    # run_column_promotion/1's own Repo.transaction/1 turns its eventual
    # COMMIT on an already-aborted transaction into an implicit ROLLBACK
    # regardless (design §2's own atomicity argument) -- so the
    # ColumnPromotion row is left at its prior status (still "pending"),
    # consistent with "no partial state to reconcile." Calls
    # `Repo.rollback/1` (this module's own established idiom, e.g.
    # `provision_tenant_schema/1` line ~328) rather than returning an
    # ordinary `{:error, error_reason}` value: this function runs nested
    # several calls deep inside `run_column_promotion/1`'s
    # `Repo.transaction/1` fun, and an ordinary return here would let that
    # fun return normally, hitting `Repo.transaction/1`'s own attempted
    # COMMIT on an already-aborted connection -- which Ecto reports as a
    # bare `{:error, :rollback}`, discarding `error_reason` entirely and
    # crashing `run_column_promotion/1`'s own `{:ok, outcome} = ...`
    # match (confirmed empirically while building this fix). Calling
    # `Repo.rollback/1` explicitly instead unwinds straight to
    # `Repo.transaction/1`, which issues a real `ROLLBACK` (valid even on
    # an already-aborted connection) and preserves `error_reason` via
    # `{:error, error_reason}` regardless of the connection's abort state.
    _exception -> Repo.rollback(error_reason)
  end

  @doc """
  Fan-out wrapper: loads every `pending` row for `promotion_ref`, calls
  `run_column_promotion/1` for each, and does **not** abort on the first
  failure (0024 §2 -- per-tenant, not atomic). Does not call
  `list_registrations/0` itself -- fans out over already-created
  `ColumnPromotion` rows only (design doc §5): a tenant provisioned after
  `register_column_promotion/4` ran is simply not part of this batch.
  """
  @spec run_column_promotion_for_all_tenants(
          promotion_ref :: {entity_type :: String.t(), attribute :: String.t()}
        ) :: %{ok: [ColumnPromotion.t()], failed: [ColumnPromotion.t()]}
  def run_column_promotion_for_all_tenants({entity_type, attribute}) do
    query =
      from(cp in ColumnPromotion,
        where:
          cp.entity_type == ^entity_type and cp.attribute == ^attribute and cp.status == "pending"
      )

    Repo.all(query)
    |> Enum.reduce(%{ok: [], failed: []}, fn row, acc ->
      case run_column_promotion(row.id) do
        {:ok, updated} ->
          %{acc | ok: acc.ok ++ [updated]}

        {:error, _reason} ->
          %{acc | failed: acc.failed ++ [Repo.get!(ColumnPromotion, row.id)]}
      end
    end)
  end

  @doc """
  Requires `status == "ddl_failed"` (`{:error, :not_ddl_failed}` otherwise --
  a new, small error atom this design adds since req295 §2's text names the
  precondition but not its own failure atom), then re-invokes
  `run_column_promotion/1` for the same row, clearing `last_error` on
  success. Idempotent to call repeatedly. **Takes only `promotion_id`.**
  """
  @spec retry_failed_column_promotion(promotion_id :: Ecto.UUID.t()) ::
          {:ok, ColumnPromotion.t()} | {:error, :promotion_not_found | :not_ddl_failed | term()}
  def retry_failed_column_promotion(promotion_id) do
    with {:ok, promotion} <- fetch_column_promotion(promotion_id) do
      if promotion.status == "ddl_failed" do
        run_column_promotion(promotion_id)
      else
        {:error, :not_ddl_failed}
      end
    end
  end

  @doc """
  Requires the row to be `ddl_applied` or `backfilling`. Transitions to
  `backfilling`, replays via
  `Letflow.Entities.Record.Projector.rebuild_projection/2` (never an inline
  `UPDATE`), then runs the row-count-parity verification check between the
  per-entity-type table and `entity_record_latest` before transitioning to
  `backfilled`. On a mismatch, the row **stays** `backfilling` and this
  function returns `{:error, {:backfill_incomplete, _}}` -- callers may call
  it again, since replay is idempotent. **Takes only `promotion_id`.**
  """
  @spec backfill_column_promotion(promotion_id :: Ecto.UUID.t()) ::
          {:ok, ColumnPromotion.t()}
          | {:error,
             :promotion_not_found | :not_ddl_applied | {:backfill_incomplete, map()} | term()}
  def backfill_column_promotion(promotion_id) do
    with {:ok, promotion} <- fetch_column_promotion(promotion_id) do
      if promotion.status in ["ddl_applied", "backfilling"] do
        do_backfill(promotion)
      else
        {:error, :not_ddl_applied}
      end
    end
  end

  defp do_backfill(promotion) do
    with {:ok, schema_name} <- resolve_schema_name(promotion.tenant_id),
         {:ok, promotion} <- ensure_backfilling_status(promotion),
         {:ok, table_name} <- table_name_for_entity_type(promotion.entity_type),
         :ok <- run_rebuild_projection(schema_name, promotion.entity_type) do
      verify_and_finalize_backfill(schema_name, table_name, promotion)
    end
  end

  # A brand-new entity type with zero records yet has no
  # entity_type_instances row -- nothing to backfill, not a real failure.
  defp run_rebuild_projection(schema_name, entity_type) do
    case Projector.rebuild_projection(schema_name, entity_type: entity_type) do
      {:ok, _result} -> :ok
      {:error, :entity_type_not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ensure_backfilling_status(%ColumnPromotion{status: "backfilling"} = promotion) do
    {:ok, promotion}
  end

  defp ensure_backfilling_status(promotion) do
    Repo.update(ColumnPromotion.changeset(promotion, %{status: "backfilling"}))
  end

  # design doc §4 step 2's fixed comparison: row-count parity between the
  # per-entity-type table and entity_record_latest for this entity type,
  # both restricted to non-deleted rows.
  defp verify_and_finalize_backfill(schema_name, table_name, promotion) do
    actual = count_entity_table_rows(schema_name, table_name)
    expected = count_latest_rows(schema_name, promotion.entity_type)

    if actual == expected do
      attrs = %{status: "backfilled", backfilled_at: naive_now()}

      case Repo.update(ColumnPromotion.changeset(promotion, attrs)) do
        {:ok, updated} -> {:ok, updated}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, {:backfill_incomplete, %{expected: expected, actual: actual}}}
    end
  end

  defp count_entity_table_rows(schema_name, table_name) do
    unless DDL.valid_identifier?(table_name) do
      raise ArgumentError, "invalid table_name for row-count check: #{inspect(table_name)}"
    end

    query = "SELECT count(*) FROM \"#{schema_name}\".\"#{table_name}\" WHERE deleted = false"
    %Postgrex.Result{rows: [[count]]} = Repo.query!(query)
    count
  end

  defp count_latest_rows(schema_name, entity_type) do
    query = from(r in Latest, where: r.entity_type == ^entity_type and r.deleted == false)
    Repo.aggregate(query, :count, prefix: schema_name)
  end

  @doc """
  Requires `status == "backfilled"`. Sets `status: "active"`,
  `query_eligible: true`, `activated_at: now`. Issues no DDL, touches no
  table. **Takes only `promotion_id`.**
  """
  @spec activate_column_promotion(promotion_id :: Ecto.UUID.t()) ::
          {:ok, ColumnPromotion.t()} | {:error, :promotion_not_found | :not_backfilled}
  def activate_column_promotion(promotion_id) do
    with {:ok, promotion} <- fetch_column_promotion(promotion_id) do
      if promotion.status == "backfilled" do
        attrs = %{status: "active", query_eligible: true, activated_at: naive_now()}

        case Repo.update(ColumnPromotion.changeset(promotion, attrs)) do
          {:ok, updated} -> {:ok, updated}
          {:error, changeset} -> {:error, changeset}
        end
      else
        {:error, :not_backfilled}
      end
    end
  end

  @doc """
  Requires `status == "active"`. Sets `query_eligible: false` only --
  `status` stays `"active"` (0024 §4: deliberate, preserves "reached active
  at least once"). `reason` is stored in the dedicated `suspend_reason`
  field (see `ColumnPromotion`'s moduledoc for why `last_error` is not
  reused). **Takes only `promotion_id`** (plus `reason`, which carries no
  cross-tenant risk).
  """
  @spec suspend_column_promotion(promotion_id :: Ecto.UUID.t(), reason :: String.t()) ::
          {:ok, ColumnPromotion.t()} | {:error, :promotion_not_found | :not_active}
  def suspend_column_promotion(promotion_id, reason) when is_binary(reason) do
    with {:ok, promotion} <- fetch_column_promotion(promotion_id) do
      if promotion.status == "active" do
        attrs = %{query_eligible: false, suspend_reason: reason}

        case Repo.update(ColumnPromotion.changeset(promotion, attrs)) do
          {:ok, updated} -> {:ok, updated}
          {:error, changeset} -> {:error, changeset}
        end
      else
        {:error, :not_active}
      end
    end
  end

  # =========================================================================
  # REQ-298 -- constraint_def unique-index activation (ConstraintActivation)
  #
  # See lib/letflow/design/req298-constraint-fk-activation.md §4 for the
  # full design this section implements. Retrofit-only: a fresh
  # CREATE TABLE already emits every constraint_def's inline
  # UNIQUE(...) clause via DDL.generate_table_ddl/3 -- these two functions
  # exist only for a constraint_def added to an entity type's definition
  # AFTER its per-entity-type table already exists, and whose target
  # columns may not all be promoted for a given tenant yet.
  # =========================================================================

  @doc """
  Creates one `pending` `ConstraintActivation` row per tenant. `:all`
  resolves via `resolve_tenant_ids/1`, the exact same tenant-enumeration
  mechanism `register_column_promotion/4` already uses -- no second
  mechanism. Issues no DDL. Mirrors `register_column_promotion/4` exactly.
  """
  @spec register_constraint_activation(
          entity_type :: String.t(),
          constraint_def :: Letflow.Entities.Definition.constraint_def(),
          tenant_ids :: [Ecto.UUID.t()] | :all
        ) :: {:ok, [ConstraintActivation.t()]} | {:error, term()}
  def register_constraint_activation(entity_type, constraint_def, tenant_ids)
      when is_binary(entity_type) and is_map(constraint_def) do
    tenant_ids = resolve_tenant_ids(tenant_ids)
    constraint_name = Map.fetch!(constraint_def, :name)
    fields = Map.fetch!(constraint_def, :fields)

    Repo.transaction(fn ->
      Enum.map(tenant_ids, fn tenant_id ->
        attrs = %{
          tenant_id: tenant_id,
          entity_type: entity_type,
          constraint_name: constraint_name,
          fields: fields,
          status: "pending"
        }

        case Repo.insert(ConstraintActivation.changeset(%ConstraintActivation{}, attrs)) do
          {:ok, row} -> row
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  @doc """
  Single-tenant, single-activation, taking only `activation_id` -- same
  calling convention as `run_column_promotion/1`. Steps, inside the SAME
  `pg_advisory_xact_lock(hashtext(schema_name))`-guarded transaction
  `run_column_promotion/1` already takes for that tenant (same lock key --
  the tenant schema -- so a concurrent column promotion and constraint
  activation against the same table never interleave):

    1. Load the row; resolve `schema_name`/`table_name`.
    2. Check every one of `activation.fields` already exists as a real
       column, via `information_schema.columns` -- any field absent ->
       `{:error, {:columns_not_ready, missing_fields}}`, marks the row
       `ddl_failed` with that reason (retryable later, once the missing
       column(s)' own promotion(s) land -- not a terminal failure).
    3. If a constraint named `activation.constraint_name` already exists on
       that table (`information_schema.table_constraints`) -> idempotent
       skip, mark `ddl_applied` (mirrors `check_additive_only/3`'s
       `:idempotent_skip` shape).
    4. Otherwise, build the constraint clause via
       `DDL.unique_constraint_clauses/1` applied to a synthetic
       single-constraint `Definition.t()` built from this row's own
       `constraint_name`/`fields` alone (this row is self-sufficient by
       design -- no re-fetch of the live `entity_definitions` row), and
       issue `ALTER TABLE "<schema>"."<table>" ADD <clause>` via
       `Repo.query!/1`, rescued into `{:ddl_failed, exception}` -- the same
       shape `execute_create_table/1`/`execute_add_column/4` already use.
  """
  @spec run_constraint_activation(activation_id :: Ecto.UUID.t()) ::
          {:ok, ConstraintActivation.t()}
          | {:error,
             :activation_not_found
             | :tenant_not_provisioned
             | {:columns_not_ready, missing_fields :: [String.t()]}
             | {:ddl_failed, Exception.t()}}
  def run_constraint_activation(activation_id) do
    with {:ok, activation} <- fetch_constraint_activation(activation_id),
         {:ok, schema_name} <- resolve_schema_name(activation.tenant_id) do
      {:ok, outcome} =
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [schema_name])
          do_run_constraint_activation(schema_name, activation)
        end)

      outcome
    end
  end

  defp do_run_constraint_activation(schema_name, activation) do
    with {:ok, table_name} <- checked_constraint_table_name(activation),
         :ok <- check_columns_ready(schema_name, table_name, activation.fields) do
      if constraint_exists?(schema_name, table_name, activation.constraint_name) do
        mark_constraint_ddl_applied(activation)
      else
        add_constraint_and_mark(schema_name, table_name, activation)
      end
    else
      {:error, {:columns_not_ready, missing_fields}} ->
        mark_constraint_ddl_failed_and_return(
          activation,
          "columns not ready: #{inspect(missing_fields)}",
          {:columns_not_ready, missing_fields}
        )
    end
  end

  # Same defence-in-depth posture as checked_table_name/1 -- unreachable via
  # this module's own public surface (register_constraint_activation/3
  # already validates entity_type via table_name_for_entity_type/1 at
  # insert time... actually it does not re-validate there either, matching
  # register_column_promotion/4's own posture of trusting its caller's
  # entity_type string; this check exists purely as the same last-resort
  # guard checked_table_name/1 already establishes for ColumnPromotion).
  defp checked_constraint_table_name(activation) do
    case table_name_for_entity_type(activation.entity_type) do
      {:ok, table_name} ->
        {:ok, table_name}

      {:error, :invalid_entity_type} ->
        raise ArgumentError,
              "ConstraintActivation #{activation.id} has an invalid entity_type: " <>
                inspect(activation.entity_type)
    end
  end

  defp check_columns_ready(schema_name, table_name, fields) do
    query = """
    SELECT column_name FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2 AND column_name = ANY($3)
    """

    %Postgrex.Result{rows: rows} = Repo.query!(query, [schema_name, table_name, fields])
    present = MapSet.new(rows, fn [column_name] -> column_name end)
    missing = Enum.reject(fields, &MapSet.member?(present, &1))

    case missing do
      [] -> :ok
      _missing -> {:error, {:columns_not_ready, missing}}
    end
  end

  defp constraint_exists?(schema_name, table_name, constraint_name) do
    query = """
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_schema = $1 AND table_name = $2 AND constraint_name = $3
    """

    case Repo.query!(query, [schema_name, table_name, constraint_name]) do
      %Postgrex.Result{rows: []} -> false
      %Postgrex.Result{rows: [_ | _]} -> true
    end
  end

  defp add_constraint_and_mark(schema_name, table_name, activation) do
    case execute_add_constraint(schema_name, table_name, activation) do
      :ok ->
        mark_constraint_ddl_applied(activation)

      {:error, {:ddl_failed, exception}} ->
        mark_constraint_ddl_failed_and_return(
          activation,
          Exception.message(exception),
          {:ddl_failed, exception}
        )
    end
  end

  # Builds the clause via DDL.unique_constraint_clauses/1 applied to a
  # synthetic, self-sufficient single-constraint Definition.t() (design §4.3
  # step 5) -- one shared source of the clause text with the fresh-CREATE-TABLE
  # path, never two independently hand-written SQL strings.
  defp execute_add_constraint(schema_name, table_name, activation) do
    unless DDL.valid_identifier?(table_name) do
      raise ArgumentError,
            "invalid table_name for ALTER TABLE ADD CONSTRAINT: #{inspect(table_name)}"
    end

    synthetic_definition = %{
      constraints: [
        %{name: activation.constraint_name, type: :unique, fields: activation.fields}
      ]
    }

    case DDL.unique_constraint_clauses(synthetic_definition) do
      {:ok, [clause]} ->
        sql = ~s(ALTER TABLE "#{schema_name}"."#{table_name}" ADD #{clause})
        Repo.query!(sql)
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "invalid constraint identifiers for ALTER TABLE ADD CONSTRAINT: #{inspect(reason)}"
    end
  rescue
    exception -> {:error, {:ddl_failed, exception}}
  end

  defp mark_constraint_ddl_applied(activation) do
    now = naive_now()
    attrs = %{status: "ddl_applied", ddl_applied_at: now, attempted_at: now, last_error: nil}

    case Repo.update(ConstraintActivation.changeset(activation, attrs)) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp mark_constraint_ddl_failed_and_return(activation, message, error_reason) do
    now = naive_now()
    attrs = %{status: "ddl_failed", last_error: message, attempted_at: now}

    case Repo.update(ConstraintActivation.changeset(activation, attrs)) do
      {:ok, _updated} -> {:error, error_reason}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp fetch_constraint_activation(activation_id) do
    case Repo.get(ConstraintActivation, activation_id) do
      nil -> {:error, :activation_not_found}
      %ConstraintActivation{} = row -> {:ok, row}
    end
  end

  @doc """
  Read-only accessor `Letflow.Entities.Query.Allowlist` (REQ-299) calls
  before including a promoted attribute as a `:typed_column` entry. `false`
  for any `(tenant_id, entity_type, attribute)` with no `ColumnPromotion`
  row at all.
  """
  @spec column_promotion_query_eligible?(
          tenant_id :: Ecto.UUID.t(),
          entity_type :: String.t(),
          attribute :: String.t()
        ) :: boolean()
  def column_promotion_query_eligible?(tenant_id, entity_type, attribute) do
    case fetch_column_promotion_by_natural_key(tenant_id, entity_type, attribute) do
      nil -> false
      %ColumnPromotion{query_eligible: query_eligible} -> query_eligible
    end
  end

  @doc """
  Read-only accessor `Letflow.Entities.Records`/`Projector`'s write path
  calls before deciding whether to also write `attribute`'s value into the
  per-entity-type table. `true` while `status` is `"ddl_applied"`,
  `"backfilling"`, or `"backfilled"`; `false` for no row, `"pending"`,
  `"ddl_failed"`, or `"active"`.
  """
  @spec column_promotion_dual_write?(
          tenant_id :: Ecto.UUID.t(),
          entity_type :: String.t(),
          attribute :: String.t()
        ) :: boolean()
  def column_promotion_dual_write?(tenant_id, entity_type, attribute) do
    case fetch_column_promotion_by_natural_key(tenant_id, entity_type, attribute) do
      nil -> false
      %ColumnPromotion{status: status} -> status in ["ddl_applied", "backfilling", "backfilled"]
    end
  end

  @doc """
  Every `ColumnPromotion` row for `(tenant_id, entity_type)` whose
  per-entity-type Postgres table row should be written (inserted/updated) on
  the current create/update, i.e. `status in ["ddl_applied", "backfilling",
  "backfilled", "active"]`. Used by `Letflow.Entities.Records`'s
  `:dual_write_promoted_columns` Multi step (design doc §8) -- the live
  write path does not otherwise know which attributes have a promoted
  column, so it asks for the whole set in one query rather than calling
  `column_promotion_dual_write?/3` once per possible attribute name.

  Deliberately named for what it is used for, not "in flight": `"active"`
  is included on purpose. ISS-0649 fixed a bug where this query excluded
  `"active"`, which made `dual_write_promoted_columns/3` stop writing to the
  promoted per-entity-type table forever once a promotion completed --
  silently dropping that table's own UNIQUE/FK constraint enforcement for
  every later create/update. Decision record
  `docs/migration/decisions/0024-entity-promotion-ddl-execution.md` §3 step
  3 only retires the *`field_values` blob* dual-write on the `backfilled` ->
  `active` transition ("stop dual-writing the attribute into `field_values`
  going forward"); it does not say to stop writing the per-entity-type
  table's own row, which stays a single, unconditional write per §3 step 1
  and this module's own moduledoc note above `write_entity_table_row/3` in
  `records.ex`. Do not narrow this status list back down without re-reading
  that section.

  This is intentionally a different question from `column_promotion_dual_write?/3`
  (which governs the separate, still-`"active"`-excluding decision of
  whether to *also* keep writing this attribute into
  `entity_record_latest.field_values`) and from `query_eligible` (which
  governs `Letflow.Entities.Query.Allowlist`/`Compiler`'s read-path
  `:typed_column` vs `:json_field` dispatch, REQ-299/300's concern) -- all
  three flags move independently off the same `ColumnPromotion` row.

  Rows are returned ordered by `(attribute, id)`: `write_entity_table_row/3`
  builds its INSERT column list in this order, so the statement text must not
  depend on heap/insertion order (GH #2852).
  """
  @spec column_promotions_for_table_write(
          tenant_id :: Ecto.UUID.t(),
          entity_type :: String.t()
        ) :: [ColumnPromotion.t()]
  def column_promotions_for_table_write(tenant_id, entity_type) do
    query =
      from(cp in ColumnPromotion,
        where:
          cp.tenant_id == ^tenant_id and cp.entity_type == ^entity_type and
            cp.status in ["ddl_applied", "backfilling", "backfilled", "active"],
        order_by: [cp.attribute, cp.id]
      )

    Repo.all(query)
  end

  # ISS-0648 fix (design doc §2.4): whether a `ColumnPromotion` row already
  # exists for `(tenant_id, entity_type, attribute)`, regardless of its
  # `status`. A trivial wrapper around the same natural-key lookup
  # `column_promotion_query_eligible?/3`/`column_promotion_dual_write?/3`
  # already use, exposed as a public-but-`@doc false` accessor the same way
  # `entity_table_exists?/2` above is -- so
  # `Letflow.Entities.Definitions.ensure_column_promotions/2` can check for
  # an existing row before calling `register_column_promotion/4` again for
  # an entity type being re-activated, instead of relying on the
  # `entity_column_promotions` unique index to reject the duplicate insert.
  @doc false
  @spec column_promotion_registered?(
          tenant_id :: Ecto.UUID.t(),
          entity_type :: String.t(),
          attribute :: String.t()
        ) :: boolean()
  def column_promotion_registered?(tenant_id, entity_type, attribute) do
    not is_nil(fetch_column_promotion_by_natural_key(tenant_id, entity_type, attribute))
  end

  @doc """
  Shared value-casting helper (design doc §10), used both by
  `Letflow.Entities.Records`'s dual-write Multi step and by
  `Letflow.Entities.Record.Projector`'s backfill write path -- one shared
  cast table, not two independently hand-maintained copies. Mirrors
  `Letflow.Entities.Definition.DDL.field_type_to_pg_type/1`'s own closed
  dispatch.
  """
  @spec cast_promoted_value(raw_value :: term(), pg_type :: String.t()) :: term()
  def cast_promoted_value(nil, _pg_type), do: nil
  def cast_promoted_value(value, "text"), do: value
  def cast_promoted_value(value, "bigint") when is_integer(value), do: value
  def cast_promoted_value(value, "bigint") when is_binary(value), do: String.to_integer(value)
  def cast_promoted_value(value, "boolean") when is_boolean(value), do: value
  def cast_promoted_value(%Date{} = value, "date"), do: value
  def cast_promoted_value(value, "date") when is_binary(value), do: Date.from_iso8601!(value)

  def cast_promoted_value(%NaiveDateTime{} = value, "timestamp(6) without time zone"), do: value

  def cast_promoted_value(value, "timestamp(6) without time zone") when is_binary(value) do
    NaiveDateTime.from_iso8601!(value)
  end

  def cast_promoted_value(%Decimal{} = value, "numeric"), do: value

  def cast_promoted_value(value, "numeric") when is_number(value),
    do: Decimal.new(to_string(value))

  def cast_promoted_value(value, "numeric") when is_binary(value), do: Decimal.new(value)

  def cast_promoted_value(%Decimal{} = value, "numeric(" <> _rest), do: value

  def cast_promoted_value(value, "numeric(" <> _rest = _pg_type) when is_number(value) do
    Decimal.new(to_string(value))
  end

  def cast_promoted_value(value, "numeric(" <> _rest) when is_binary(value),
    do: Decimal.new(value)

  # REQ-298's FK-promoted columns are pg_type "uuid" (a real Postgres
  # `uuid`-typed column, required for a REFERENCES constraint to match its
  # target's own uuid `record_id` column). `raw_value` here is always a
  # 36-character text-form UUID string pulled out of `field_values`'s own
  # jsonb.
  #
  # This does NOT dump to Postgrex's raw 16-byte binary form the way
  # `Ecto.UUID`'s own Ecto type would for a changeset-driven write --
  # `Letflow.Entities.Records.placeholder_list/1` and
  # `Letflow.Entities.Record.Projector`'s own placeholder builder bind every
  # promoted "uuid" column through the SAME `($n::text)::uuid` SQL-level
  # double-cast idiom already established for the structural "id"/
  # "record_id" columns (see those modules' own comments) -- which forces
  # the bind parameter's wire type to `text`, not `uuid`. Handing that path
  # a raw binary would break it a different way (confirmed empirically: a
  # 16-byte binary bound as a `text`-typed parameter fails Postgres's UTF-8
  # validation, `invalid byte sequence for encoding "UTF8"`). `Ecto.UUID.cast!/1`
  # is used instead, purely to reject a malformed value early with a clear
  # error and normalize casing/hyphenation, keeping the value in the same
  # text form the SQL-side cast expects.
  def cast_promoted_value(value, "uuid") when is_binary(value), do: Ecto.UUID.cast!(value)

  def cast_promoted_value(value, _pg_type), do: value

  # ---------------------------------------------------------------------
  # Shared lookups used across this section.
  # ---------------------------------------------------------------------

  defp fetch_column_promotion(promotion_id) do
    case Repo.get(ColumnPromotion, promotion_id) do
      nil -> {:error, :promotion_not_found}
      %ColumnPromotion{} = row -> {:ok, row}
    end
  end

  defp fetch_column_promotion_by_natural_key(tenant_id, entity_type, attribute) do
    Repo.get_by(ColumnPromotion,
      tenant_id: tenant_id,
      entity_type: entity_type,
      attribute: attribute
    )
  end

  defp resolve_schema_name(tenant_id) do
    case Repo.get_by(Registration, tenant_id: tenant_id) do
      nil -> {:error, :tenant_not_provisioned}
      %Registration{schema_name: schema_name} -> {:ok, schema_name}
    end
  end

  defp naive_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  # Converts a persisted, string-keyed `EntityDefinition.definition_json`
  # back into the atom-keyed `Letflow.Entities.Definition.t()` shape
  # `Letflow.Entities.Definition.DDL` expects -- same round-trip concern
  # `Letflow.Entities.Records`'s own private `definition_document/1` already
  # solves for `Letflow.Entities.Record.Validator`'s narrower needs, but
  # extended here to also carry `:queried`, the decimal precision/scale
  # pair, and `:foreign_keys` (`DDL.promoted_columns/1` needs all of these;
  # `Record.Validator` needs none of them) -- not a re-derivation of an
  # identical mapping, a superset for a different consumer. Exposed here
  # (not duplicated in `Letflow.Entities.Record.Projector`) so both this
  # module's own `create_and_populate_entity_table/3` and Projector's
  # backfill write path (design doc §9) share the one conversion.
  @doc false
  @spec document_from_persisted(EntityDefinition.t()) :: Letflow.Entities.Definition.t()
  def document_from_persisted(%EntityDefinition{definition_json: json}) do
    %{
      name: Map.fetch!(json, "name"),
      display_name: Map.get(json, "display_name"),
      fields: json |> Map.get("fields", []) |> Enum.map(&field_from_persisted/1),
      foreign_keys: json |> Map.get("foreign_keys", []) |> Enum.map(&fk_from_persisted/1),
      constraints: json |> Map.get("constraints", []) |> Enum.map(&constraint_from_persisted/1),
      indexes: json |> Map.get("indexes", []) |> Enum.map(&index_from_persisted/1)
    }
  end

  defp field_from_persisted(field) do
    %{
      name: Map.fetch!(field, "name"),
      type: String.to_existing_atom(Map.fetch!(field, "type")),
      queried: Map.get(field, "queried", false),
      decimal_precision: Map.get(field, "decimal_precision"),
      decimal_scale: Map.get(field, "decimal_scale"),
      enum_values: Map.get(field, "enum_values"),
      locales: Map.get(field, "locales"),
      search_strategy: field |> Map.get("search_strategy") |> search_strategy_atom()
    }
    |> put_decimal_strict(field)
  end

  # GH #2654: carried only when present (a key-less definition rebuilds exactly as
  # before). DDL-neutral: `DDL.decimal_pg_type/1` ignores it.
  defp put_decimal_strict(document, field) do
    case Map.fetch(field, "decimal_strict") do
      {:ok, strict} -> Map.put(document, :decimal_strict, strict)
      :error -> document
    end
  end

  # REQ-298: `references_entity` is now needed by DDL.promoted_columns/1 (to
  # populate column_spec.references_entity) and by
  # resolve_fk_target_tables/1 above -- both previously unreachable via this
  # conversion, since the pre-REQ-298 shape only round-tripped `field`.
  defp fk_from_persisted(fk) do
    %{
      name: Map.fetch!(fk, "name"),
      field: Map.fetch!(fk, "field"),
      references_entity: Map.fetch!(fk, "references_entity")
    }
  end

  # REQ-298: constraints (constraint_def(), always type: :unique today) were
  # not part of document_from_persisted/1's round-trip at all before this
  # requirement -- needed so the fresh-CREATE-TABLE path
  # (create_and_populate_entity_table/3) can emit a constraint_def's inline
  # UNIQUE(...) clause via DDL.generate_table_ddl/3.
  defp constraint_from_persisted(constraint) do
    %{
      name: Map.fetch!(constraint, "name"),
      type: String.to_existing_atom(Map.fetch!(constraint, "type")),
      fields: Map.fetch!(constraint, "fields")
    }
  end

  # ISS-0623: `indexes` (index_def(), REQ-225) was not part of
  # document_from_persisted/1's round-trip at all before this fix -- the
  # same gap constraint_from_persisted/1 above was added to close for
  # REQ-298, now closed for `indexes` too so
  # DDL.index_create_statements/2 (called on the `document` this function
  # returns, in create_and_populate_entity_table/3) actually sees the
  # declared indexes for a definition read back from persistence, not just
  # for one built by hand in a unit test.
  defp index_from_persisted(index) do
    %{
      name: Map.fetch!(index, "name"),
      fields: Map.fetch!(index, "fields"),
      unique: Map.get(index, "unique", false)
    }
  end

  # REQ-301: `search_strategy` is persisted as a JSON string ("plain"/
  # "fulltext") in `definition_json`, decoded back to the atom
  # `Letflow.Entities.Definition.DDL.localized_text_column_specs/1` expects.
  # Both atoms are already compiled into this codebase (Validator's Rule 11,
  # DDL's own dispatch), so `String.to_existing_atom/1` is safe here -- same
  # posture as `field_from_persisted/1`'s own `type` decode above.
  defp search_strategy_atom(nil), do: nil
  defp search_strategy_atom(value) when is_binary(value), do: String.to_existing_atom(value)
end
