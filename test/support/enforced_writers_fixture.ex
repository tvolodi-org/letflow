defmodule Letflow.Support.EnforcedWritersFixture do
  @moduledoc """
  Test support for REQ-519 slice 2e-a (GH #2535; design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 3 and 8.1; spec
  `test/specs/REQ-519-2e-a.md`): provisioned tenants whose STORED scope-enforcement mode is
  set by a direct `UPDATE` (`Letflow.Support.ScopeEnforcementFixture`, no route can set `on`
  yet), a direct `Letflow.Routers.Identity` dispatch, and a few audit readers.

  The tenant fixture leaves the sandbox in `:auto` mode (real commits, cleaned up by the
  fixture teardown), so every caller is `async: false`. Nothing here is compiled outside
  `:test`.
  """

  import Ecto.Query
  import Plug.Conn

  require Logger

  alias Letflow.Audit.Entry
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @modes [:off, :shadow, :on]
  @trace "req519-2ea-trace-0001"
  @stale_after_seconds 600

  @doc "The three stored modes the per-mode tests iterate."
  @spec modes() :: [:off | :shadow | :on]
  def modes, do: @modes

  @doc "The trace id the HTTP helper assigns."
  @spec trace() :: String.t()
  def trace, do: @trace

  @doc """
  A provisioned tenant, NOT seeded, stored in `mode` (the platform pin is cleared first, as
  the REQ-497 writer tests do).
  """
  @spec tenant!(String.t(), :off | :shadow | :on) :: TenantFixture.tenant_fixture()
  def tenant!(slug_prefix, mode) do
    PlatformTenantFixture.unpin!()
    fx = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    set_mode!(fx, mode)
    fx
  end

  @doc """
  A provisioned tenant whose platform roles are seeded WHILE `off` (so every binding has its
  tenant-wide row), then stored in `mode`.
  """
  @spec seeded_tenant!(String.t(), :off | :shadow | :on) :: TenantFixture.tenant_fixture()
  def seeded_tenant!(slug_prefix, mode) do
    fx = tenant!(slug_prefix, :off)
    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: fx.schema_name)
    set_mode!(fx, mode)
    fx
  end

  @doc "Sets the stored mode of the fixture tenant."
  @spec set_mode!(map(), :off | :shadow | :on) :: :ok
  def set_mode!(%{tenant_id: tenant_id}, mode),
    do: ScopeEnforcementFixture.set_stored_mode!(tenant_id, mode)

  @doc """
  Removes the committed leftovers of an earlier KILLED run: every tenant whose slug starts with
  `slug_prefix`, that is stored `on` and was last touched more than ten minutes ago (schema,
  registration and `tenants` row, the same three steps as the fixture teardown). Returns the
  purged slugs.

  Why it exists: a test that runs `mix letflow.backfill_role_scope_grants` in-process commits an
  `on` tenant, and that task calls `System.halt(1)` when a tenant fails. A halt kills the VM
  before any `on_exit` runs, so the tenant stays stored `on` in the shared local test database
  (three such rows, slugs `req519-n5-mix*`, made the two migration-down tests of
  `scope_enforcement_on_test.exs` fail locally: that rollback refuses while any tenant is `on`).
  The suite-boundary reaper does not reclaim them (the registration was removed by
  `TenantAdminMigrationFixture.isolate_registrations!/1`, which only puts it back in an
  `on_exit`). A test calls this in its own setup, so the next run heals the database.
  """
  @spec purge_stale_enforced_tenants!(String.t()) :: [String.t()]
  def purge_stale_enforced_tenants!(slug_prefix) when is_binary(slug_prefix) do
    # the purge must COMMIT, like the tenant fixture it mirrors
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -@stale_after_seconds, :second)

    escaped =
      slug_prefix
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    pattern = escaped <> "%"

    stale =
      Repo.all(
        from(t in Tenant,
          where: like(t.slug, ^pattern) and t.scope_enforcement == :on and t.updated_at < ^cutoff,
          select: {t.id, t.slug}
        )
      )

    # Total over what a killed run can leave (docs/anti-patterns.md, "A self-heal wired into
    # `setup` that is not total"): each leftover is purged on its own and a failure is logged
    # (naming the slug) and skipped, so one unpurgeable row can never fail every test of a file.
    for {tenant_id, slug} <- stale do
      try do
        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
          {:error, _reason} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
        slug
      rescue
        exception ->
          Logger.warning(
            "purge_stale_enforced_tenants!/1 could not purge #{slug}: " <>
              Exception.message(exception)
          )

          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  @doc "The stored mode of the fixture tenant, read raw."
  @spec stored_mode(map()) :: String.t()
  def stored_mode(%{tenant_id: tenant_id}) do
    {:ok, id} = Ecto.UUID.dump(tenant_id)
    %{rows: [[mode]]} = Repo.query!("SELECT scope_enforcement FROM tenants WHERE id = $1", [id])
    mode
  end

  @doc "Dispatches one request into `Letflow.Routers.Identity` as a TENANT_ADMIN of `fx`."
  @spec http(atom(), String.t(), map(), map() | nil) :: Plug.Conn.t()
  def http(method, path, fx, body) do
    method
    |> PlatformTenantFixture.router_conn(path, fx, ["TENANT_ADMIN"], body)
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Identity.call(Letflow.Routers.Identity.init([]))
  end

  @doc "The decoded JSON body of a response."
  @spec body(Plug.Conn.t()) :: map()
  def body(conn), do: Jason.decode!(conn.resp_body)

  @doc "A group with a unique name, through the shipped get-or-create."
  @spec group!(map()) :: Letflow.Identity.Group.t()
  def group!(%{schema_name: schema}), do: RSG.fresh_group!(schema)

  @doc "Every audit entry id of the schema."
  @spec entry_ids(String.t()) :: [Ecto.UUID.t()]
  def entry_ids(schema), do: Repo.all(from(e in Entry, select: e.id), prefix: schema)

  @doc "The audit entries written since `ids_before`, oldest first."
  @spec new_entries(String.t(), [Ecto.UUID.t()]) :: [Entry.t()]
  def new_entries(schema, ids_before) do
    Repo.all(from(e in Entry, where: e.id not in ^ids_before, order_by: [e.timestamp, e.id]),
      prefix: schema
    )
  end

  @doc "The number of `tenant_wide = true` rows in the schema."
  @spec tenant_wide_count(String.t()) :: non_neg_integer()
  def tenant_wide_count(schema) do
    Repo.aggregate(
      from(g in Letflow.Identity.RoleScopeGrant, where: g.tenant_wide == true),
      :count,
      prefix: schema
    )
  end
end
