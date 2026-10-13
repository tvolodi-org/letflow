defmodule Mix.Tasks.Letflow.Seed do
  @shortdoc "Provisions the default bpm-default tenant against a fresh dev database (ISS-0276)"

  @moduledoc """
  Provisions the `bpm-default` tenant that authenticated requests bearing a
  `bpm-default`-realm token resolve against
  (`Letflow.Identity.resolve_tenant_by_realm/1`). No code path creates this
  row automatically on a fresh dev database (ISS-0276) -- this task is the
  supported way to bootstrap it.

  ## Usage

      LETFLOW_DEV_DB_CONFIRMED=1 mix letflow.seed

  No arguments. Targets `letflow_dev` -- `LETFLOW_DEV_DB_CONFIRMED=1` is
  required, same as `mix ecto.setup`/`mix run` (see `Letflow.Repo.init/2`).

  Creates the `bpm-default` tenant row (`idp_realm_id` and `slug` both
  `"bpm-default"`), provisions its Postgres schema, replays that schema's
  migrations, and (ISS-0778) seeds its platform-role group bindings (eight roles in the platform tenant,
  seven elsewhere) --
  the same
  `Letflow.Identity.create_tenant/1` -> `Letflow.TenantOnboarding.provision_and_migrate/1`
  chain `POST /tenants` uses.

  Idempotent -- safe to re-run against a database that already has the
  `bpm-default` tenant; re-running converges rather than erroring.
  """

  use Mix.Task

  alias Letflow.Identity
  alias Letflow.TenantOnboarding

  @attrs %{
    "slug" => "bpm-default",
    "display_name" => "Default Tenant",
    "idp_realm_id" => "bpm-default"
  }

  @impl Mix.Task
  @spec run(args :: [String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.start")

    case Identity.create_tenant(@attrs) do
      {:ok, tenant} ->
        provision_and_replay(tenant.id, "created")

      {:error, :duplicate_slug} ->
        case Identity.resolve_tenant_by_realm("bpm-default") do
          {:ok, tenant} ->
            provision_and_replay(tenant.id, "already present, re-provisioned/re-verified")

          {:error, :not_found} ->
            Mix.raise(
              "mix letflow.seed: FAILED -- a tenant with slug \"bpm-default\" already " <>
                "exists but does not resolve by idp_realm_id \"bpm-default\". This is a " <>
                "genuine slug collision with a differently-configured tenant, not a prior " <>
                "run of this task -- resolve manually."
            )
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise(
          "mix letflow.seed: FAILED -- create_tenant/1 rejected the seed attrs: " <>
            inspect(changeset.errors)
        )
    end
  end

  defp provision_and_replay(tenant_id, verb) do
    case TenantOnboarding.provision_and_migrate(tenant_id) do
      {:ok, registration} ->
        Mix.shell().info(
          "mix letflow.seed: OK -- bpm-default tenant #{verb} (id #{tenant_id}), " <>
            "schema #{registration.schema_name} migrated and role-seeded."
        )

      {:error, {:provisioning_failed, reason}} ->
        Mix.raise(
          "mix letflow.seed: FAILED -- provision_tenant_schema/1 for tenant #{tenant_id}: " <>
            inspect(reason)
        )

      {:error, {:migration_failed, reason}} ->
        Mix.raise(
          "mix letflow.seed: FAILED -- replay_migrations/1 for tenant #{tenant_id}: " <>
            inspect(reason)
        )

      {:error, {:role_seeding_failed, reason}} ->
        Mix.raise(
          "mix letflow.seed: FAILED -- seed_default_platform_role_groups/1 for tenant " <>
            "#{tenant_id}: " <> inspect(reason)
        )

      {:error, reason} ->
        Mix.raise(
          "mix letflow.seed: FAILED -- provision_and_migrate/1 for tenant #{tenant_id}: " <>
            inspect(reason)
        )
    end
  end
end
