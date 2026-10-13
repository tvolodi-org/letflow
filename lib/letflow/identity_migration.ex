defmodule Letflow.IdentityMigration do
  @moduledoc """
  One-time data-copy mechanism for Decision 0006 D1
  (`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`) section 4
  step 3: moves every tenant's `users`/`groups`/`tenant_role` rows out of the
  legacy public tables into that tenant's own already-provisioned Postgres schema.

  Backs `mix letflow.copy_identity_tables` (`Mix.Tasks.Letflow.CopyIdentityTables`)
  — the real logic lives here, not in the Mix task itself, so it is unit-testable
  without going through `Mix.Task.run/1`, matching this project's convention of
  keeping task plumbing thin.

  **Not a migration.** This is an application-level, operator-invoked cutover
  action (reads `Letflow.TenantProvisioning.Registration` and issues normal
  `Repo`/`Ecto.Schema` calls), not a schema change — see
  `lib/letflow/design/req063-identity-tables-schema-per-tenant.md` section 4 for
  the full reasoning this module implements. Must run after the three per-tenant
  `create table` migrations
  (`priv/repo/migrations/20260819000001/2/3_..._tenant_scoped.exs`) have been
  replayed across every tenant schema, and before
  `20260819000004_drop_legacy_public_identity_tables.exs` runs.

  **Idempotent** — every insert uses `on_conflict: :nothing` +
  `conflict_target: :id`, so re-running after a partial failure silently skips
  already-copied rows, matching the `on_conflict: :nothing` idiom this codebase
  already uses in `Letflow.TenantProvisioning.insert_or_fetch_registration/2` and
  `Letflow.Identity.insert_or_fetch/4`.
  """

  import Ecto.Query

  alias Letflow.Api.Authorization
  alias Letflow.Identity.Group
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration

  @typedoc "Aggregate copy counts across every registered tenant."
  @type summary :: %{
          tenants_processed: non_neg_integer(),
          users_copied: non_neg_integer(),
          groups_copied: non_neg_integer(),
          tenant_roles_copied: non_neg_integer()
        }

  @typedoc "Per-tenant copy counts."
  @type tenant_summary :: %{
          users: non_neg_integer(),
          groups: non_neg_integer(),
          tenant_roles: non_neg_integer()
        }

  @doc """
  Copies `users`/`groups`/`tenant_role` rows from the legacy public tables into
  every registered tenant's own schema, one `Repo.transaction/1` per tenant.

  Stops and returns `{:error, {:tenant_copy_failed, tenant_id, reason}}`
  immediately on the first tenant that fails — never silently skips a failed
  tenant and continues, per the design's ordering discipline (an incomplete copy
  for one tenant must not reach the drop migration).

  A tenant with no `Registration` row (never provisioned) is out of scope —
  matches `Letflow.TenantProvisioning.replay_migrations/2`'s own precedent of
  never provisioning on the fly.
  """
  @spec copy_all_tenants() ::
          {:ok, summary()}
          | {:error, {:tenant_copy_failed, tenant_id :: Ecto.UUID.t(), reason :: term()}}
  def copy_all_tenants do
    registrations = Repo.all(Registration)

    Enum.reduce_while(registrations, {:ok, zero_summary()}, fn
      %Registration{tenant_id: tenant_id, schema_name: schema_name}, {:ok, acc} ->
        case Repo.transaction(fn -> copy_tenant(tenant_id, schema_name) end) do
          {:ok, {:ok, tenant_result}} ->
            {:cont, {:ok, accumulate(acc, tenant_result)}}

          {:ok, {:error, reason}} ->
            {:halt, {:error, {:tenant_copy_failed, tenant_id, reason}}}

          {:error, reason} ->
            {:halt, {:error, {:tenant_copy_failed, tenant_id, reason}}}
        end
    end)
  end

  @doc """
  Copies one tenant's `users`/`groups`/`tenant_role` rows into `schema_name`.
  Order: `groups` before `tenant_role` (matches the manifest's own FK-driven
  ordering in `Letflow.TenantProvisioning.tenant_scoped_migrations/0` —
  `tenant_role.group_id` must resolve inside the destination schema). `id` is
  preserved verbatim on every insert (client-generated `binary_id`) so any other
  public-schema data still holding a reference to that row's id by value
  continues to resolve correctly during the transition window.

  `tenant_role` carries no `tenant_id` column, so its rows are selected by
  joining through `groups` (whose `tenant_id` is known) via `group_id`. A
  `tenant_role` row whose `group_id` does not resolve to any `groups` row (an
  orphan — should not exist given the FK constraint on the current public
  schema, but is not silently dropped if one somehow does) aborts this tenant's
  transaction as `{:error, {:orphaned_tenant_role, tenant_role_id}}`.
  """
  @spec copy_tenant(tenant_id :: Ecto.UUID.t(), schema_name :: String.t()) ::
          {:ok, tenant_summary()} | {:error, term()}
  def copy_tenant(tenant_id, schema_name) when is_binary(schema_name) do
    with {:ok, groups_copied} <- copy_groups(tenant_id, schema_name),
         {:ok, users_copied} <- copy_users(tenant_id, schema_name),
         {:ok, tenant_roles_copied} <- copy_tenant_roles(tenant_id, schema_name) do
      {:ok, %{groups: groups_copied, users: users_copied, tenant_roles: tenant_roles_copied}}
    end
  end

  # `g.tenant_id`/`u.tenant_id` below are `fragment/1` references, not the
  # `Letflow.Identity.Group`/`User` Ecto schema's own field -- Decision 0006
  # D2 (REQ-064) removed `tenant_id` from those schema modules, since the
  # per-tenant copies these rows are being copied INTO no longer carry the
  # column. The SOURCE side of this one-time cutover copy still reads from
  # the legacy `public.groups`/`public.users` tables, which retain their
  # `tenant_id` column until `20260819000004_drop_legacy_public_identity_tables.exs`
  # drops them -- so this query must keep filtering on that column via a raw
  # fragment rather than a schema-typed field reference, which would no
  # longer compile once the field left the schema module. This is the one
  # place in the codebase that legitimately still queries a `tenant_id`
  # column post-D2: it targets the about-to-be-dropped legacy public tables,
  # not any of the ten D2 tables.
  # `select: struct(g, [...])` below is deliberately restricted to the four
  # columns the legacy `public.groups` table actually has -- REQ-074 added
  # `display_name`/`description` to the `Letflow.Identity.Group` schema
  # module (for the NEW per-tenant-schema `groups` table only, via its own
  # tenant-scoped migration), and a bare `from(g in Group, ...)` with no
  # `select:` selects every column the schema module declares, which would
  # otherwise query `display_name`/`description` against this legacy source
  # table that was never migrated to carry them (it predates D1/D2 and is
  # frozen -- this whole module only ever reads it, never writes it new
  # columns). Restricting the select here keeps this one-time cutover copy
  # correct against the legacy table's real, frozen shape without touching
  # the destination schema's newer column set at all (those columns simply
  # come across as `nil` for migrated legacy rows, which is fine -- they are
  # nullable and no legacy row ever had a display_name/description value to
  # preserve in the first place).
  defp copy_groups(tenant_id, schema_name) do
    rows =
      Repo.all(
        from(g in Group,
          where: fragment("? = ?", g.tenant_id, type(^tenant_id, Ecto.UUID)),
          select: struct(g, [:id, :name, :inserted_at, :updated_at])
        )
      )

    insert_all_preserving_id(rows, schema_name)
  end

  # `select: struct(u, [...])` below is deliberately restricted to the columns
  # the legacy `public.users` table actually has -- REQ-378 added
  # `role_claims_synced_at` to the `Letflow.Identity.User` schema module (for
  # the NEW per-tenant-schema `users` table only, via
  # `20260921000001_add_role_claims_synced_at_to_users.exs`), and a bare
  # `from(u in User, ...)` with no `select:` selects every column the schema
  # module declares, which would otherwise query `role_claims_synced_at`
  # against this legacy source table that was never migrated to carry it (it
  # predates D1/D2 and is frozen -- this whole module only ever reads it,
  # never writes it new columns). Restricting the select here keeps this
  # one-time cutover copy correct against the legacy table's real, frozen
  # shape without touching the destination schema's newer column set at all
  # (that column simply comes across as `nil` for migrated legacy rows, which
  # is fine -- it is nullable and no legacy row ever had a
  # role_claims_synced_at value to preserve in the first place). Mirrors
  # copy_groups/2's identical guard above for this exact hazard class.
  defp copy_users(tenant_id, schema_name) do
    rows =
      Repo.all(
        from(u in User,
          where: fragment("? = ?", u.tenant_id, type(^tenant_id, Ecto.UUID)),
          select:
            struct(u, [
              :id,
              :username,
              :display_name,
              :email,
              :password_hash,
              :status,
              :auth_source,
              :external_id,
              :external_realm,
              :inserted_at,
              :updated_at
            ])
        )
      )

    insert_all_preserving_id(rows, schema_name)
  end

  defp copy_tenant_roles(tenant_id, schema_name) do
    # An INNER JOIN through groups (below) can only ever return tenant_role rows
    # whose group_id DOES resolve to a groups row -- by construction, an orphan
    # (group_id with no matching groups row anywhere) can never appear in this
    # result set, so it would otherwise be silently excluded from every
    # tenant's copy rather than surfaced as an error. The design requires this
    # case to abort the tenant's transaction, not disappear quietly -- so the
    # orphan check below runs as a genuinely separate query (LEFT JOIN, IS NULL)
    # against the same tenant's tenant_role universe: every tenant_role row
    # reachable transitively from this tenant is exactly the set whose group_id
    # is one of this tenant's own groups' ids OR does not resolve to any group
    # at all. Since a tenant_role row carries no tenant_id of its own, "does not
    # resolve to any group at all" is genuinely tenant-agnostic -- an orphan
    # would be undetectable as belonging to any specific tenant, so it is
    # treated as blocking every tenant's copy uniformly (fail-safe: the copy
    # must not proceed to the drop migration while any orphan exists anywhere).
    case find_orphaned_tenant_role() do
      nil ->
        rows =
          Repo.all(
            from(tr in TenantRole,
              join: g in Group,
              on: tr.group_id == g.id,
              where: fragment("? = ?", g.tenant_id, type(^tenant_id, Ecto.UUID)),
              # ISS-0774: restricted to the legacy public.tenant_role table's
              # actual (frozen) column set -- mirrors copy_groups/2's and
              # copy_users/2's own identical-purpose `select: struct(x, [...])`
              # guard above. ISS-0774's `kind` column was added only to the
              # NEW per-tenant-schema `tenant_role` table (destination side of
              # this copy); the legacy source table was never migrated to
              # carry it and a bare `select: tr` would query a column that
              # does not exist there, raising `Postgrex.Error: undefined_column`
              # (the exact regression this comment documents and this fix
              # closes). `kind` is filled in per-row below, not selected here.
              select: struct(tr, [:id, :name, :group_id, :inserted_at])
            )
          )
          |> Enum.map(&with_legacy_kind/1)

        insert_all_preserving_id(rows, schema_name)

      orphan_id ->
        {:error, {:orphaned_tenant_role, orphan_id}}
    end
  end

  # Classifies a legacy row's `kind` the exact same deterministic way
  # ISS-0774's own migration backfill classifies pre-existing rows (see
  # priv/repo/migrations/20260921000002_add_kind_to_tenant_role.exs):
  # :platform_role iff `name` is one of the recognized literals
  # (`Letflow.Api.Authorization.roles/0`; six at ISS-0774 time), :process_routing_role otherwise. Applied here
  # (Elixir-side, post-query) rather than at the SQL layer because the legacy
  # source table has no `kind` column to select in the first place -- see
  # copy_tenant_roles/2's own comment above.
  @spec with_legacy_kind(TenantRole.t()) :: TenantRole.t()
  defp with_legacy_kind(%TenantRole{name: name} = tenant_role) do
    if name in platform_role_names() do
      %{tenant_role | kind: :platform_role}
    else
      %{tenant_role | kind: :process_routing_role}
    end
  end

  @spec platform_role_names() :: [String.t()]
  defp platform_role_names, do: Enum.map(Authorization.roles(), &Atom.to_string/1)

  defp find_orphaned_tenant_role do
    Repo.one(
      from(tr in TenantRole,
        left_join: g in Group,
        on: tr.group_id == g.id,
        where: is_nil(g.id),
        select: tr.id,
        limit: 1
      )
    )
  end

  defp insert_all_preserving_id(rows, schema_name) do
    count =
      Enum.reduce(rows, 0, fn row, acc ->
        changeset = Ecto.Changeset.change(row)

        case Repo.insert(changeset,
               prefix: schema_name,
               on_conflict: :nothing,
               conflict_target: :id
             ) do
          {:ok, _} -> acc + 1
          {:error, _} -> acc
        end
      end)

    {:ok, count}
  end

  defp zero_summary,
    do: %{tenants_processed: 0, users_copied: 0, groups_copied: 0, tenant_roles_copied: 0}

  defp accumulate(acc, %{users: u, groups: g, tenant_roles: tr}) do
    %{
      tenants_processed: acc.tenants_processed + 1,
      users_copied: acc.users_copied + u,
      groups_copied: acc.groups_copied + g,
      tenant_roles_copied: acc.tenant_roles_copied + tr
    }
  end
end
