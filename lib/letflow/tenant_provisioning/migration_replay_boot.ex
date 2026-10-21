defmodule Letflow.TenantProvisioning.MigrationReplayBoot do
  @moduledoc """
  ISS-0771 (design `lib/letflow/design/iss0771-tenant-migration-replay-on-deploy.md`
  §2.2): a minimal, one-shot boot-time child of `Letflow.Supervisor.Infrastructure`,
  placed immediately after the `{Ecto.Migrator, ...}` child and before
  `Letflow.Oidc.ProviderRegistry` (see that module's `init/1`).

  Not a `GenServer`/`Supervisor` -- no state, no message loop, no registered
  name. `start_link/1` runs synchronously (blocking, matching the
  `Ecto.Migrator` child it sits directly after) and calls
  `Letflow.TenantProvisioning.replay_all_pending/0` once, then **always**
  returns `:ignore` -- never `{:error, _}`, never a raised exception,
  regardless of how many tenants' replay failed. This is deliberately
  absolute (design doc §3, "What could still go wrong"): if this child ever
  propagated a crash to `Supervisor.init/2`, one broken tenant migration
  would take the entire application down on every boot -- strictly worse
  than the silent gap ISS-0771 exists to close. The outer `try/rescue` below
  is intentionally redundant with `replay_all_pending/0`'s own internal
  per-tenant rescue (its "two independent layers" per design doc §4) -- this
  function's exception-safety must not depend on `replay_all_pending/0`
  continuing to catch everything forever either.

  Deliberately NOT gated by the `skip_migrations?()` check
  `{Ecto.Migrator, ...}` uses -- see design doc §2.3's ordering rationale.
  No equivalent local-dev path (`mix ecto.setup`) ever touches a tenant
  schema, so running unconditionally is required to also close the
  local-dev/`iex -S mix` gap, and is safe because `replay_all_pending/0` is
  idempotent (design doc §3): a boot against already-migrated tenants is a
  fast, safe no-op every time.

  Logs one error-level line per failing tenant (GH #2727 raised it from
  warning; the log is the alarm, the queryable signal is
  `Letflow.TenantProvisioning.list_replay_failures/0`) (`tenant_id`, `schema_name`, `reason`)
  plus one always-logged summary line after the loop completes (ok/error
  counts), including the healthy `0 failed` case -- a boot-time step this
  significant logging nothing on the healthy path is exactly the kind of gap
  that let ISS-0771 ship invisibly the first time.

  ISS-0772: `tenant_id`, `schema_name`, and `reason` (and the rescue clause's
  formatted exception) are passed as `Logger` **metadata**, not interpolated
  into the message string. `Letflow.Secrets.LogFilter` (registered in
  `Letflow.Application.start/2`) redacts only `log_event.meta` -- it never
  inspects `log_event.msg` -- so a value baked into the message string via
  interpolation is never covered by that filter, regardless of whether it is
  secret-shaped. None of the values this module logs are secret-shaped today
  (`tenant_id`, `schema_name`, and the tagged reason shapes
  `Letflow.TenantProvisioning.replay_all_pending/0` returns), so this was not
  an exploitable gap -- but passing them as metadata means `LogFilter`'s
  existing redaction mechanism now genuinely applies to this call site going
  forward, rather than relying on a claim that it already did.
  """

  require Logger

  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link(term()) :: {:ok, pid()} | :ignore
  def start_link(_init_arg) do
    try do
      run_replay()
    rescue
      exception ->
        # ISS-0772: variable data (the formatted exception) now passed as Logger
        # metadata, not interpolated into the message string -- see moduledoc
        # note below and `Letflow.Secrets.LogFilter` for why this matters.
        Logger.error(
          "tenant migration replay: boot hook raised unexpectedly, ignoring",
          reason: Exception.format(:error, exception, __STACKTRACE__)
        )
    end

    :ignore
  end

  defp run_replay do
    registrations_by_tenant_id =
      TenantProvisioning.list_registrations()
      |> Map.new(fn %Registration{tenant_id: tenant_id} = registration ->
        {tenant_id, registration}
      end)

    %{ok: ok, error: error} = TenantProvisioning.replay_all_pending()

    Enum.each(error, fn {tenant_id, reason} ->
      schema_name =
        case Map.fetch(registrations_by_tenant_id, tenant_id) do
          {:ok, %Registration{schema_name: schema_name}} -> schema_name
          :error -> "unknown"
        end

      # ISS-0772: tenant_id/schema_name/reason passed as Logger metadata (not
      # string-interpolated) so `Letflow.Secrets.LogFilter`'s existing
      # metadata-redaction mechanism genuinely covers this call site.
      Logger.error(
        "tenant migration replay failed",
        tenant_id: tenant_id,
        schema_name: schema_name,
        reason: reason
      )
    end)

    Logger.info(
      "tenant migration replay: summary",
      ok_count: length(ok),
      error_count: length(error)
    )
  end
end
