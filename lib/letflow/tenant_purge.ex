defmodule Letflow.TenantPurge do
  @moduledoc """
  REQ-580 / GH #3292 / REQ-572 / decision 0072 D4 (QA only): the one place that purges a tenant.

  A deactivated provisioned tenant whose retention has run out loses its data: the tenant schema is
  dropped, its registration, login-directory and global-table rows are deleted, the `tenants` row is
  kept (id, slug, `idp_realm_id`, status `:inactive`, `display_name` set to `"purged"`) and its
  `tenant_lifecycles` row is marked `deleted` with `purged_at`. Everything runs in one transaction
  under the per-tenant advisory lock of `Letflow.TenantProvisioner`; a failure rolls it all back and
  answers `{:error, :purge_failed}`.

  ## Eligibility (each failure is `{:error, :not_eligible}` and writes nothing)

  The tenants row is `:inactive`, the lifecycle is `suspended` or `expired`, neither
  `tenants.tenant_type` nor the lifecycle `tier` is `production`, and the retention has run out:
  `now >= reference + retention_days`, where the reference is `expires_at` for an `expired` tenant and
  `deletion_requested_at` otherwise (nil: not eligible). `retention_days` is a setting
  (`LETFLOW_PROVISIONER_RETENTION_DAYS`, default 30, `Letflow.TenantProvisioner.Config`). A platform
  tenant, an unknown id and a tenant without a lifecycle row are all `{:error, :not_found}`. A purged
  tenant answers `{:ok, :already_purged}` and nothing is written (idempotent).

  ## Invariants

  * INV-1/6: the schema name is derived from the id of the LOCKED lifecycle row, never from the
    request. The only interpolation into SQL is that name (`"tenant_" <> 32 hex`, INV-7).
  * INV-2/5: unknown, platform and unprovisioned tenants are the same atom, so HTTP bodies are equal.
  * INV-8: every raise is rescued at the boundary and logged as exception class plus tenant id only.
  * INV-10: the platform route is PLATFORM-scope; the provisioner route is the write credential.
  * The realm is deleted by infra's reaper only when `GET /admin/v1/tenants/:id` shows `purged_at`.
    The row in `tenant_lifecycles` is never deleted, so the slug and hostname stay reserved.

  ## Not designed here

  Backups and replicas (a purge does not erase from them), multi-node, early erasure, production
  tenants. The scheduled sweep is `Letflow.TenantProvisioner.Sweep`, which calls this function with
  `trigger: :sweep` and an injected clock `now:`. QA only.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  require Logger

  alias Letflow.Audit
  alias Letflow.Identity.Tenant
  alias Letflow.PlatformTenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioner
  alias Letflow.TenantProvisioner.Config
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantProvisioning

  @type trigger :: :provisioner | :platform_admin | :sweep
  @type result ::
          {:ok, :purged | :already_purged}
          | {:error, :not_found | :not_eligible | :purge_failed}

  # Global tables holding a tenant's rows, as {table, column}. Fixed at compile time (no names from
  # input). Order: the rollout outcomes reference entity_column_promotions, so they go first.
  # Kept on purpose: tenant_lifecycles, onboarding_registry (reserve slug and hostname),
  # event_history_retirement_outcomes (counts only, no personal data), tenants (by id).
  @removed_tables [
    {"platform_migration_rollout_outcomes", :tenant_id},
    {"entity_column_promotions", :tenant_id},
    {"secrets", :tenant_id},
    {"tenant_memberships", :tenant_id},
    {"public_read_handles", :tenant_id},
    {"entity_constraint_activations", :tenant_id},
    {"solution_pack_installs", :tenant_id},
    {"solution_pack_artefact_bases", :tenant_id},
    {"pack_update_resolutions", :tenant_id},
    {"service_catalog", :owner_tenant_id},
    {"tenant_login_directory", :tenant_id},
    {"tenant_schemas", :tenant_id}
  ]

  @doc false
  @spec removed_tables() :: [{String.t(), atom()}]
  def removed_tables, do: @removed_tables

  @doc "Purges the tenant with `purge/3`'s defaults (`:provisioner`, the real clock)."
  @spec purge(term(), trigger()) :: result()
  def purge(raw_id, trigger), do: purge(raw_id, trigger, [])

  @doc """
  Purges one tenant. `opts`: `now:` (a `DateTime`, the clock for the retention test) and `actor_id:`
  (the PLATFORM_ADMIN user id, for the audit entry of `:platform_admin`).
  """
  @spec purge(term(), trigger(), keyword()) :: result()
  def purge(raw_id, trigger, opts)
      when trigger in [:provisioner, :platform_admin, :sweep] and is_list(opts) do
    with {:ok, id} <- cast_id(raw_id),
         {:ok, platform_prefix} <- platform_prefix() do
      now = Keyword.get(opts, :now) || DateTime.utc_now()
      actor_id = Keyword.get(opts, :actor_id)

      case TenantProvisioner.with_lock(id, fn ->
             run(id, trigger, now, actor_id, platform_prefix)
           end) do
        {:error, :internal} -> {:error, :purge_failed}
        other -> other
      end
    else
      :error -> {:error, :not_found}
      {:error, :internal} -> {:error, :purge_failed}
    end
  end

  @doc "The purge marker of a tenant: `purged_at` as ISO-8601 or nil. For route answers."
  @spec marker(term()) :: String.t() | nil
  def marker(raw_id) do
    case TenantProvisioner.get(raw_id) do
      {:ok, %{purged_at: at}} -> at
      _unknown -> nil
    end
  end

  defp run(id, trigger, now, actor_id, platform_prefix) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '5s'")

        row = Repo.one(from(l in Lifecycle, where: l.tenant_id == ^id, lock: "FOR UPDATE"))

        cond do
          row == nil or PlatformTenant.platform_tenant?(id) -> Repo.rollback(:not_found)
          row.purged_at != nil -> :already_purged
          true -> do_purge(row, trigger, now, actor_id, platform_prefix)
        end
      end)

    case result do
      {:ok, outcome} -> {:ok, outcome}
      {:error, reason} when reason in [:not_found, :not_eligible] -> {:error, reason}
      {:error, _other} -> {:error, :purge_failed}
    end
  rescue
    exception ->
      Logger.error(
        "tenant purge failed (tenant_id=#{inspect(id)}, exception=#{inspect(exception.__struct__)})"
      )

      {:error, :purge_failed}
  end

  defp do_purge(row, trigger, now, actor_id, platform_prefix) do
    tenant = Repo.get(Tenant, row.tenant_id)

    unless eligible?(row, tenant, now), do: Repo.rollback(:not_eligible)

    # The id of the LOCKED row, never the argument (INV-1/6).
    {:ok, schema} = TenantProvisioning.schema_name_for_tenant(row.tenant_id)
    tables = count_tables(schema)

    # The one interpolation: schema_name_for_tenant/1 yields "tenant_" <> 32 hex (INV-7).
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))

    Enum.each(@removed_tables, fn {table, column} ->
      table
      |> Ecto.Queryable.to_query()
      |> where([t], field(t, ^column) == type(^row.tenant_id, :binary_id))
      |> Repo.delete_all()
    end)

    from(t in Tenant, where: t.id == ^row.tenant_id)
    |> Repo.update_all(set: [display_name: "purged"])

    from(l in Lifecycle, where: l.tenant_id == ^row.tenant_id)
    |> Repo.update_all(set: [lifecycle: "deleted", purged_at: now, updated_at: now])

    {:ok, _entry} =
      Audit.insert_entry(
        Repo,
        %{
          actor_id: actor_id,
          action: "platform.tenant.purged",
          resource_type: "tenant",
          resource_id: row.tenant_id,
          trace_id: nil,
          before_state: nil,
          after_state: %{
            "tenant_id" => row.tenant_id,
            "purged_at" => DateTime.to_iso8601(now),
            "trigger" => Atom.to_string(trigger),
            "tables_dropped" => tables
          }
        },
        platform_prefix
      )

    :purged
  end

  defp eligible?(_row, nil, _now), do: false

  defp eligible?(%Lifecycle{} = row, %Tenant{} = tenant, now) do
    reference = if row.lifecycle == "expired", do: row.expires_at, else: row.deletion_requested_at

    tenant.status == :inactive and row.lifecycle in ["suspended", "expired"] and
      tenant.tenant_type != "production" and row.tier != "production" and reference != nil and
      DateTime.compare(now, DateTime.add(reference, Config.retention_days() * 86_400, :second)) !=
        :lt
  end

  defp count_tables(schema) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = $1",
        [schema]
      )

    count
  end

  defp platform_prefix do
    case PlatformTenant.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :internal}
    end
  end

  defp cast_id(raw) when is_binary(raw), do: Ecto.UUID.cast(raw)
  defp cast_id(_raw), do: :error
end
