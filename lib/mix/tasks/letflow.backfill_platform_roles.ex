defmodule Mix.Tasks.Letflow.BackfillPlatformRoles do
  @shortdoc "Backfills the platform-role group/role bindings for tenants provisioned before ISS-0778 (ISS-0886)"

  @moduledoc """
  Backfills `Letflow.Identity.RoleRegistry.seed_default_platform_role_groups/1`
  (the `Letflow.Api.Authorization.roles/0` platform-role bindings: eight roles in the platform
  tenant, seven elsewhere) for
  every tenant registered in `Letflow.TenantProvisioning.list_registrations/0`.

  ISS-0778 (2026-09-22) started seeding these bindings automatically at
  tenant-creation time, but nothing ever re-ran that seeding for a tenant
  provisioned *before* ISS-0778 shipped — such a tenant has no route to get
  the missing bindings later, and every non-admin OIDC user on it reads
  `roles: []` and gets 403 everywhere (`docs/issues/ISS-0886.yaml`). This
  task closes that gap, once, for every such tenant.

  ## Usage

      mix letflow.backfill_platform_roles

  No arguments. Targets whatever `MIX_ENV`/`Letflow.Repo` config is active —
  no `LETFLOW_DEV_DB_CONFIRMED` guard, unlike `mix letflow.seed`, since this
  task is explicitly meant to be run against QA/staging, not only a dev box
  (same precedent as `mix letflow.backfill_event_type_versions`, which also
  has no such guard).

  Idempotent — safe to re-run against a database where some or all tenants
  already have all of their bindings; re-running converges rather than erroring
  or duplicating rows (`Letflow.Identity.RoleBackfill`'s own moduledoc).

  Exits non-zero if any tenant fails to backfill.
  """

  use Mix.Task

  alias Letflow.Identity.RoleBackfill

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.start")

    case RoleBackfill.run() do
      {:ok, %{seeded: seeded, unchanged: unchanged, role_claims_markers_reset: reset_count}} ->
        Mix.shell().info(
          "ISS-0886 platform-role backfill complete: #{length(seeded)} tenant(s) seeded, " <>
            "#{length(unchanged)} tenant(s) already fully seeded (unchanged), " <>
            "#{reset_count} user role_claims_synced_at marker(s) reset (ISS-0910)"
        )

        if seeded != [] do
          Mix.shell().info("Seeded tenant_ids: #{Enum.join(seeded, ", ")}")
        end

        :ok

      {:error, {:backfill_failed, tenant_id, reason}} ->
        Mix.shell().error(
          "ISS-0886 platform-role backfill failed for tenant #{tenant_id}: #{inspect(reason)}"
        )

        System.halt(1)
    end
  end
end
