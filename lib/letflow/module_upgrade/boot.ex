defmodule Letflow.ModuleUpgrade.Boot do
  @moduledoc """
  REQ-772 (decision 0080 Q3, amending 0055 D5): upgrade on deploy, behind a flag that defaults off.

  A one-shot boot child of `Letflow.Supervisor.Infrastructure`, placed directly after
  `Letflow.TenantProvisioning.MigrationReplayBoot` (so every tenant schema already has the
  `accepted_manifest_hashes` column and the upgrade journal). Shaped like that module:
  `start_link/1` runs synchronously and **always** returns `:ignore`; it never raises, whatever one
  tenant or module does.

  The flag is the config key `:module_upgrade_on_boot` of `:letflow` (env var
  `LETFLOW_MODULE_UPGRADE_ON_BOOT`, exactly `true` or `false`, parsed in `config/runtime.exs`).
  Only the value `true` turns it on. With the flag off the child reads and writes nothing.

  With the flag on, for every registered tenant and every active module whose applied version or
  manifest hash differs from the compiled one, it computes the plan (`Letflow.Modules.UpgradePlan`).
  A plan with `applicable_on_boot: true` (all changes Class A, no step, every stamped definition
  passing the activation check) is applied through `Letflow.ModuleUpgrade.Apply` (the REQ-770 code,
  one transaction) as the system actor with the rationale `"upgrade on deploy to <version>"`. Any other
  plan is applied nowhere and stays for the admin action. This module writes no stamp, definition
  or module row of its own; its only direct writes are two journal bookkeeping writes
  (the planned row of a plan left for the admin gets the system actor and the fixed rationale; a
  `failed` row when no Apply row exists), both under the tenant's own prefix.

  A module whose newest `done` journal row is a rollback (`Letflow.ModuleUpgrade.Rollback`) is held:
  it counts as `left_for_admin` and nothing is written, until an admin applies an upgrade again.

  Outcomes are read with `list_outcomes/0`, backed by the journal rows (actor = system actor and the
  fixed rationale), never by logs: `done` is `:upgraded`, `failed` is `:failed`, a stamped `planned`
  row is `:left_for_admin`.

  Tenancy (INV-1): the schema of every query and call is the `schema_name` of the tenant registry
  row; `tenant_id` only labels an outcome. There is no caller input. Logs carry `tenant_id`,
  `module_id` and `code` as Logger metadata with constant messages (ISS-0772); no exception text is
  logged or stored (INV-4/INV-8).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.ModuleUpgrade.Apply
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.TenantModule
  alias Letflow.Modules.TenantModuleUpgrade
  alias Letflow.Modules.UpgradePlan
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @system_actor "00000000-0000-0000-0000-000000000000"
  @rationale_prefix "upgrade on deploy to "

  @type outcome :: %{
          tenant_id: term(),
          module_id: String.t(),
          outcome: :upgraded | :left_for_admin | :failed,
          error_code: String.t() | nil,
          at: DateTime.t() | nil
        }

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "True only when the config key `:module_upgrade_on_boot` is exactly `true`."
  @spec flag_on?() :: boolean()
  def flag_on?, do: Application.get_env(:letflow, :module_upgrade_on_boot, false) == true

  @spec start_link(term()) :: :ignore
  def start_link(_init_arg) do
    try do
      if flag_on?(), do: run()
    rescue
      _exception ->
        Logger.error("module upgrade on boot: hook raised unexpectedly, ignoring",
          code: "internal_error"
        )
    catch
      _kind, _reason ->
        Logger.error("module upgrade on boot: hook raised unexpectedly, ignoring",
          code: "internal_error"
        )
    end

    :ignore
  end

  # ── the loop ─────────────────────────────────────────────────────────────────────────────

  defp run do
    counts =
      TenantProvisioning.list_registrations()
      |> Enum.reduce(%{upgraded: 0, left_for_admin: 0, failed: 0}, fn registration, acc ->
        registration |> tenant_outcomes() |> Enum.reduce(acc, &bump(&2, &1))
      end)

    Logger.info("module upgrade on boot: summary",
      upgraded_count: counts.upgraded,
      left_count: counts.left_for_admin,
      failed_count: counts.failed
    )
  end

  defp bump(acc, outcome) when is_map_key(acc, outcome), do: Map.update!(acc, outcome, &(&1 + 1))
  defp bump(acc, _other), do: acc

  defp tenant_outcomes(%Registration{tenant_id: tenant_id, schema_name: schema}) do
    rows =
      Repo.all(from(m in TenantModule, where: m.status == :active, select: m), prefix: schema)

    Enum.map(rows, fn row -> module_outcome(tenant_id, schema, row) end)
  rescue
    _exception ->
      Logger.error("module upgrade on boot: tenant unreadable",
        tenant_id: tenant_id,
        code: "tenant_unreadable"
      )

      []
  catch
    _kind, _reason ->
      Logger.error("module upgrade on boot: tenant unreadable",
        tenant_id: tenant_id,
        code: "tenant_unreadable"
      )

      []
  end

  defp module_outcome(tenant_id, schema, %TenantModule{module_id: module_id} = row) do
    cond do
      current?(row) -> :skipped
      rolled_back?(schema, module_id) -> :left_for_admin
      true -> upgrade_one(tenant_id, schema, module_id, row)
    end
  rescue
    _exception -> failed(tenant_id, schema, module_id, row, "internal_error")
  catch
    _kind, _reason -> failed(tenant_id, schema, module_id, row, "internal_error")
  end

  # An admin rolled this module back (the newest finished journal row is a `done` rollback): the
  # tenant stays on the older version until an admin applies an upgrade again. No write.
  defp rolled_back?(schema, module_id) do
    latest =
      from(u in TenantModuleUpgrade,
        where: u.module_id == ^module_id and u.state == :done and not is_nil(u.finished_at),
        order_by: [desc: u.finished_at, desc: u.id],
        limit: 1,
        select: u.kind
      )
      |> Repo.one(prefix: schema)

    latest == :rollback
  end

  defp current?(%TenantModule{module_id: module_id} = row) do
    with {:ok, entry} <- Catalog.fetch(module_id),
         {:ok, hash} <- Catalog.manifest_hash(entry) do
      row.version == entry.manifest().version and row.manifest_hash == hash
    else
      # an unknown module is not ours to upgrade
      _other -> true
    end
  end

  defp upgrade_one(tenant_id, schema, module_id, row) do
    case UpgradePlan.plan(module_id, @system_actor, prefix: schema) do
      {:ok, %{"up_to_date" => true}} ->
        :skipped

      {:ok, %{"applicable_on_boot" => true, "plan_hash" => plan_hash} = report} ->
        params = %{
          "rationale" => @rationale_prefix <> report["to_version"],
          "plan_hash" => plan_hash
        }

        case Apply.apply_upgrade(module_id, @system_actor, params, prefix: schema) do
          {:ok, _body} ->
            :upgraded

          {:error, {:failed, code}} ->
            log_failure(tenant_id, module_id, code)
            :failed

          {:error, _refused} ->
            left(tenant_id, schema, module_id, report)
        end

      {:ok, report} ->
        left(tenant_id, schema, module_id, report)

      {:error, :plan_failed} ->
        failed(tenant_id, schema, module_id, row, "plan_failed")

      {:error, _not_installed_or_unknown} ->
        :skipped
    end
  end

  defp left(_tenant_id, schema, module_id, report) do
    stamp_planned(schema, module_id, report)
    :left_for_admin
  end

  defp failed(tenant_id, schema, module_id, row, code) do
    log_failure(tenant_id, module_id, code)
    insert_failed(schema, module_id, row, code)
    :failed
  end

  defp log_failure(tenant_id, module_id, code) do
    Logger.error("module upgrade on boot: upgrade failed",
      tenant_id: tenant_id,
      module_id: module_id,
      code: code
    )
  end

  # ── journal bookkeeping (tenant-prefixed, never raises) ──────────────────────────────────

  defp stamp_planned(schema, module_id, report) do
    to_version = report["to_version"]
    now = DateTime.utc_now()

    query =
      from(u in TenantModuleUpgrade,
        where:
          u.module_id == ^module_id and u.kind == :upgrade and u.state == :planned and
            u.plan_hash == ^report["plan_hash"] and u.actor_id == ^@system_actor and
            is_nil(u.rationale)
      )

    Repo.update_all(query, [set: [rationale: @rationale_prefix <> to_version, started_at: now]],
      prefix: schema
    )

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp insert_failed(schema, module_id, row, code) do
    to_version =
      case Catalog.fetch(module_id) do
        {:ok, entry} -> entry.manifest().version
        _other -> row.version
      end

    now = DateTime.utc_now()

    # Not inside a transaction of the caller: a failure here must not poison anything.
    {:ok, _row} =
      %TenantModuleUpgrade{}
      |> TenantModuleUpgrade.changeset(%{
        module_id: module_id,
        from_version: row.version,
        to_version: to_version,
        kind: :upgrade,
        state: :failed,
        actor_id: @system_actor,
        rationale: @rationale_prefix <> to_version,
        error_code: code,
        started_at: now,
        finished_at: now
      })
      |> Repo.insert(prefix: schema)

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  # ── outcomes ─────────────────────────────────────────────────────────────────────────────

  @doc """
  The outcomes of upgrades on deploy, read from the journal rows of every registered tenant (actor =
  the system actor, rationale `"upgrade on deploy to ..."`). Read-only; a tenant whose schema cannot
  be read yields no rows. Selected columns are allow-listed (no `touches`, `plan_hash`, cursor or
  lease fields).
  """
  @spec list_outcomes() :: [outcome()]
  def list_outcomes do
    TenantProvisioning.list_registrations()
    |> Enum.flat_map(&tenant_journal/1)
    |> Enum.sort_by(&{&1.at && DateTime.to_unix(&1.at, :microsecond), &1.module_id})
  end

  defp tenant_journal(%Registration{tenant_id: tenant_id, schema_name: schema}) do
    from(u in TenantModuleUpgrade,
      where:
        u.kind == :upgrade and u.actor_id == ^@system_actor and
          like(u.rationale, "upgrade on deploy to %") and u.state in [:done, :failed, :planned],
      select: %{
        module_id: u.module_id,
        state: u.state,
        error_code: u.error_code,
        started_at: u.started_at,
        finished_at: u.finished_at
      }
    )
    |> Repo.all(prefix: schema)
    |> Enum.map(fn r ->
      %{
        tenant_id: tenant_id,
        module_id: r.module_id,
        outcome: outcome_of(r.state),
        error_code: r.error_code,
        at: r.finished_at || r.started_at
      }
    end)
  rescue
    _exception -> []
  catch
    _kind, _reason -> []
  end

  defp outcome_of(:done), do: :upgraded
  defp outcome_of(:failed), do: :failed
  defp outcome_of(:planned), do: :left_for_admin
end
