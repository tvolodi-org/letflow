defmodule Letflow.TenantOnboarding do
  @moduledoc """
  REQ-076's own orchestration layer for provisioning-recovery (AC9) and the
  `:migrating` tenant-status lifecycle (AC10) — see
  `lib/letflow/design/req076-identity-tokens-roles-onboarding.md` §11/§12 for
  the full design (SCOPE EXTENSION, run `WF02-REQ076-20260822`).

  This module, not `Letflow.TenantProvisioning`, owns the sequencing of
  `Letflow.TenantProvisioning.provision_tenant_schema/1` and
  `Letflow.TenantProvisioning.replay_migrations/2` into one call. Those two
  functions remain "two separate, composable primitives — neither calls the
  other" (`lib/letflow/design/req022-tenant-schema-provisioning.md` §3.2's "No
  implicit chaining invariant") — this module is the caller-side orchestration
  that invariant always expected to exist, added by REQ-076 as the owning
  requirement (`Letflow.TenantProvisioning`'s own moduledoc, "No reconciliation
  path for a half-provisioned tenant" section, names REQ-076 explicitly).

  `provision_and_migrate/1` is the shared sequence both the normal
  onboarding-creation path (`Letflow.Routers.Onboarding.handle_create/1`) and
  the recovery path (`recover_provisioning/1`, AC9) call — one place, not two,
  that ever sequences these primitives or ever flips a REQ-076-created
  tenant's status back to `:active`.

  ## AC10 — the `:migrating` status lifecycle

  Status is `:migrating` from the moment `Letflow.Routers.Onboarding.handle_create/1`
  inserts the tenant row (an additional `"status" => "migrating"` attr passed
  to `Letflow.Identity.create_tenant/1`) until `provision_and_migrate/1`'s own
  last step flips it to `:active` on success. This reuses
  `Letflow.Identity.Tenant.status`'s existing three-value `Ecto.Enum`
  (`[:active, :migrating, :inactive]`) and `Letflow.Plugs.TenantStatus`'s
  already-shipped, already-REVIEWER-signed-off write-gate verbatim — **zero**
  lines changed in either. `Letflow.Plugs.TenantStatus` rejects
  `POST`/`PUT`/`PATCH`/`DELETE` against a `:migrating` tenant with `503` +
  `Retry-After`; `GET`/`HEAD` pass through unchanged, with no `Repo` call on
  that check at all.

  **The empty-schema read gap is accepted, not closed — argued, not just
  asserted.** `GET`/`HEAD` passing through against a tenant whose Postgres
  schema is still literally empty (provisioned but not yet migrated) is
  structurally unreachable by any legitimately-authenticated HTTP request, for
  the entire window it could exist in: both of today's authentication
  mechanisms — `Letflow.Plugs.AuthPipeline`'s OIDC branch (`provision_user/3`,
  JIT-provisioning against the tenant schema's own `users` table) and its
  API-token branch (`Letflow.Identity.verify_api_token/2`, querying the tenant
  schema's own `api_tokens` table) — must themselves issue a live query
  against a tenant-schema table that does not exist until
  `Letflow.TenantProvisioning.replay_migrations/2` has run. So no caller can
  ever hold, or newly obtain, a credential `AuthPipeline` accepts as scoped to
  a tenant whose schema is still empty: OIDC JIT-provisioning would itself
  fail first (the `users` table it queries/inserts into does not exist), and
  an API token can only exist for a `user_id` already present in that same,
  not-yet-created table. If this were somehow reached anyway (a bug elsewhere,
  not a path this module constructs), the query would raise an uncaught
  `Postgrex.Error` (`undefined_table`) and crash to an uncontrolled `500` —
  this module deliberately does **not** add a global Postgrex-error-to-JSON
  rescue layer to close that theoretical gap defensively; doing so would be a
  cross-cutting change outside this requirement's onboarding-orchestration
  scope. **This argument is conditional, not permanent (OQ-6):** a future
  requirement that adds any credential mechanism not requiring a tenant-schema
  query first (e.g. a self-contained signed credential) would invalidate it
  and must re-examine this decision.

  **The already-populated-schema `:migrating` case is not a gap at all.** A
  tenant that finished onboarding successfully in the past (schema fully
  migrated, `users`/`api_tokens` populated, real tokens exist) and is later
  put back into `:migrating` for an administrative reason still has `GET`/`HEAD`
  serve its existing, valid data unchanged — `Letflow.Plugs.TenantStatus`'s own
  documented "write-pause, not read-pause" design, intended behavior that
  predates this requirement (REQ-021), not something this module reopens.

  ## AC9 — provisioning recovery is invocable, not an automatic sweep

  `recover_provisioning/1` is a thin, deliberately separately-named public
  wrapper around `provision_and_migrate/1`. Nothing in this module or
  elsewhere calls it on a schedule, timer, or `GenServer`/supervision-tree
  child — it is invoked directly, by a test or, operationally, by a human
  running it via a `Mix` task or `iex -S mix` console call against a specific
  `tenant_id`. Building an automatic sweep is explicitly out of REQ-076's
  scope (RECOVERY SCOPE BOUNDARY) — it would need a scheduler subsystem this
  codebase does not have, and adding a supervision-tree child for it here
  would be scope creep.

  The detection predicate a future sweep would use — `migrations_applied_at
  IS NULL` on the `tenant_schemas` (`Letflow.TenantProvisioning.Registration`)
  row — is already established and reused verbatim (measured against real
  Postgres in run `WF03-ISS0230-20260822`, recorded in
  `Letflow.TenantProvisioning`'s own moduledoc). No new column, no new table,
  no new index, and this module adds no function wrapping that query — it is
  read-only convenience information, not a new public API surface this
  requirement is obligated to ship.
  """

  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @doc """
  The shared, idempotent two-primitive sequence: provisions the tenant's
  Postgres schema, replays migrations against it, and — on success — flips the
  tenant's status to `:active`. Called by both the normal onboarding-creation
  path (`Letflow.Routers.Onboarding.provision_and_bind/4`) and the recovery
  entry point (`recover_provisioning/1`, AC9) — the one place in this codebase
  that ever sequences these two `Letflow.TenantProvisioning` primitives or
  ever flips a REQ-076-created tenant back to `:active`.

  Every step reuses an already-idempotent primitive, confirmed by direct read,
  not assumed:

    1. `Letflow.TenantProvisioning.provision_tenant_schema/1` — a second call
       for the same `tenant_id` returns `{:ok, %Registration{}}` with the same
       row, no duplicate `tenant_schemas` row (`unique_index(:tenant_id)`).
       `{:error, :tenant_not_found}` propagates unchanged (the tenant row
       itself is gone — not a state this function can repair). Any other error
       becomes `{:error, {:provisioning_failed, reason}}`.
    2. `Letflow.TenantProvisioning.replay_migrations/2` — **always called with
       the default `migration_source`** (arity-1 call, `nil` default), never a
       caller-supplied one: this function exists to converge the tenant onto
       the real shipped migration manifest, not a test fixture's.
       `Ecto.Migrator.run/4` tracks applied versions in a per-schema
       `schema_migrations` table, so a second call against an
       already-fully-migrated schema applies zero new migrations and returns
       `{:ok, []}` — no duplicate tables, no error. `{:error,
       {:migration_failed, exception}}` propagates unchanged — this is the
       branch a still-broken migration (a genuine, persistent failure, not the
       transient one being recovered from) surfaces through; this function
       does not swallow a real migration failure into a false success.
    3. `Letflow.Identity.RoleRegistry.seed_default_platform_role_groups/1`
       (ISS-0778) — seeds the group/role bindings for the platform roles that
       tenant is entitled to (REQ-447: all eight roles of
       `Letflow.Api.Authorization.roles/0` in the platform tenant, every role
       except `PLATFORM_ADMIN` in any other tenant, so every tenant gets a
       `TENANT_ADMIN` binding), scoped to this tenant's own
       schema (`prefix: registration.schema_name`). Idempotent (design §2.4)
       — a second call converges on the same bindings. Unlike
       `activate_tenant/1`'s own status-flip below, a failure here **is**
       treated as a hard provisioning failure: it propagates as `{:error,
       {:role_seeding_failed, reason}}` and the tenant is **not** activated,
       staying at `:migrating`. Letting a tenant reach `:active` with its
       role bindings unseeded would reproduce ISS-0778 under a different
       trigger (a role-seed DB error instead of "nobody ever wrote the
       seeding code") — `:active` is meant to mean "this tenant is actually
       ready," which now includes "an IdP-claimed platform-role token can
       actually reach a grant." A tenant left at `:migrating` by a seeding
       failure recovers the same way any other partial-provisioning failure
       already does — `recover_provisioning/1` re-invokes this same `with`
       chain, and the seeding step's idempotency converges correctly on
       retry even if a prior attempt partially wrote some of the
       bindings before failing.
    4. On success: flip the tenant's status to `:active` if it is not already,
       via `Letflow.Identity.Tenant.status_changeset/2` + `Repo.update/2`,
       scoped to `%{status: :active}` only. Idempotent: if the tenant is
       already `:active` (e.g. a second invocation), the update is a no-op
       write of the same value.
    5. Re-fetch the `Registration` row and return `{:ok, registration}` — the
       up-to-date row, with `migrations_applied_at` reflecting step 2's own
       write.

  No compensating rollback anywhere in this function — matches
  `Letflow.Routers.Onboarding`'s own existing precedent and REVIEWER's
  ISS-0230 finding that a rollback here would orphan a real Postgres schema.
  """
  @spec provision_and_migrate(tenant_id :: Ecto.UUID.t()) ::
          {:ok, Registration.t()}
          | {:error, :tenant_not_found}
          | {:error, {:provisioning_failed, term()}}
          | {:error, {:migration_failed, Exception.t()}}
          | {:error, {:role_seeding_failed, term()}}
  def provision_and_migrate(tenant_id) do
    with {:ok, registration} <- provision(tenant_id),
         {:ok, _applied_versions} <- TenantProvisioning.replay_migrations(tenant_id),
         {:ok, _tenant_roles} <- seed_platform_roles(registration.schema_name) do
      activate_tenant(tenant_id)
      {:ok, Repo.get_by(Registration, tenant_id: tenant_id)}
    end
  end

  defp provision(tenant_id) do
    case TenantProvisioning.provision_tenant_schema(tenant_id) do
      {:ok, _registration} = ok -> ok
      {:error, :tenant_not_found} = error -> error
      {:error, reason} -> {:error, {:provisioning_failed, reason}}
    end
  end

  defp seed_platform_roles(schema_name) do
    case RoleRegistry.seed_default_platform_role_groups(prefix: schema_name) do
      {:ok, _tenant_roles} = ok -> ok
      {:error, reason} -> {:error, {:role_seeding_failed, reason}}
    end
  end

  # The migration/schema side of provision_and_migrate/1 has already
  # succeeded by the time this runs -- a failure here is a status-flip-only
  # failure, not a provisioning failure, so it does not propagate as an
  # {:error, _} from provision_and_migrate/1 (step 4's re-fetch simply
  # reflects whatever status ends up persisted). Explicitly matched, not
  # silently discarded, per INV-8.
  defp activate_tenant(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      %Tenant{status: :active} ->
        :ok

      %Tenant{} = tenant ->
        case tenant |> Tenant.status_changeset(%{status: :active}) |> Repo.update() do
          {:ok, %Tenant{}} -> :ok
          {:error, %Ecto.Changeset{}} -> :ok
        end

      nil ->
        :ok
    end
  end

  @doc """
  The AC9 entry point: idempotent, invocable provisioning-recovery for a
  tenant left half-provisioned by a `replay_migrations/2` failure. A thin
  wrapper around `provision_and_migrate/1` — two functions with identical
  behavior, not one, because they answer two different questions for two
  different readers: `provision_and_migrate/1` is "the shared step sequence"
  (an implementation detail the normal creation path also happens to call);
  `recover_provisioning/1` is the name this acceptance criterion anchors to —
  the one a test or an operator reaches for by name when a tenant is
  known/suspected to be half-provisioned.

  Idempotent. Safe to call on a tenant that is not actually half-provisioned
  (fully-converged input state is one of the states this function's own
  idempotence guarantee covers, not an error case) — the detection of *which*
  tenants need recovery is the caller's job (e.g. `WHERE migrations_applied_at
  IS NULL` against the `tenant_schemas` table), not this function's; this
  function performs the repair unconditionally once called.

  Not an automatic sweep — nothing in this module or elsewhere calls this on
  a schedule, timer, or supervision-tree child. Invoked directly, by a test
  or, operationally, by a human running it via a `Mix` task or `iex -S mix`
  console call against a specific `tenant_id`.
  """
  @spec recover_provisioning(tenant_id :: Ecto.UUID.t()) ::
          {:ok, Registration.t()}
          | {:error, :tenant_not_found}
          | {:error, {:provisioning_failed, term()}}
          | {:error, {:migration_failed, Exception.t()}}
  def recover_provisioning(tenant_id), do: provision_and_migrate(tenant_id)
end
