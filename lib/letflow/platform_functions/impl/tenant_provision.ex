defmodule Letflow.PlatformFunctions.Impl.TenantProvision do
  @moduledoc """
  The body of `tenant.provision` (T-2590, pilot gap G1b of the "Register a
  tenant" pilot).

  It creates the tenant's Postgres schema, replays its migrations, seeds its
  platform roles and its script HMAC key, and flips the tenant to `:active` --
  the write that today sits in `Letflow.Routers.Tenants` (`POST /tenants`),
  in `Letflow.Routers.Onboarding` (`POST /onboarding`) and in
  `Letflow.TenantProvisioner` (its "ensure provisioned" step). That code moved
  HERE, so the route, the provisioner and the platform step call ONE
  implementation.

  ## It runs DDL, so it must not run inside the engine's transaction

  The dispatcher runs the body OUTSIDE every transaction it owns (see
  `Letflow.PlatformFunctions.Dispatcher`): a schema creation and a migration
  replay cannot share a transaction with the instance's own rows. The route
  and the provisioner have always run it outside a transaction too, so nothing
  about the order of the writes changes.

  ## The idempotency

  The step's key input is the TENANT ID, and provisioning a tenant twice is
  the same provisioning:

    * the schema exists -- `Ecto.Migrator.run/4` skips the migrations that are
      already applied, so the applied set does not grow;
    * the roles are seeded again -- the seeding is an upsert of the same rows;
    * the HMAC key exists -- `Letflow.Scripts.HmacSecret.ensure/1` keeps the
      key it made;
    * the tenant is already `:active` -- the status flip is a write of the
      same value.

  So a second run changes nothing and answers the same `schema_name`. The
  step may therefore be retried after a crash (the dispatcher's lease makes a
  killed run repeatable) without provisioning the tenant twice.

  ## The bounds

  The tenant id is a caller-supplied string, so it is checked BEFORE it
  reaches the database: a value that is not a UUID is refused
  (`platform_call_arg_invalid`), never cast by the database layer (INV-8).

  ## What it never does

  It never raises (INV-8): every failure is an `{:error, code}` with a code
  of this module's own vocabulary.
  """

  alias Letflow.TenantOnboarding
  alias Letflow.TenantProvisioning.Registration

  @typedoc "The stable code of a refused provision."
  @type refusal ::
          :platform_call_arg_invalid
          | :platform_call_tenant_not_found
          | :platform_call_provision_failed

  @doc """
  The shared provisioning sequence, moved out of the routes and the
  provisioner: exactly what `Letflow.TenantOnboarding.provision_and_migrate/1`
  answers, with no change of shape.
  """
  @spec provision_and_migrate(Ecto.UUID.t()) ::
          {:ok, Registration.t()} | {:error, term()}
  def provision_and_migrate(tenant_id) do
    TenantOnboarding.provision_and_migrate(tenant_id)
  end

  @doc """
  Runs the step over the resolved arguments.

  `context` carries the resolved `inputs` (the entry's declared input names
  to their values). Returns `{:ok, %{"schema_name" => schema_name}}` with the
  entry's declared output, or `{:error, refusal}`.
  """
  @spec run(map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    tenant_id = Map.get(inputs, "tenant_id")

    with {:ok, tenant_id} <- cast_uuid(tenant_id),
         {:ok, schema_name} <- provision(tenant_id) do
      {:ok, %{"schema_name" => schema_name}}
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp provision(tenant_id) do
    case provision_and_migrate(tenant_id) do
      {:ok, %Registration{schema_name: schema_name}} ->
        {:ok, schema_name}

      {:ok, _other} ->
        {:error, :platform_call_provision_failed}

      {:error, :tenant_not_found} ->
        {:error, :platform_call_tenant_not_found}

      {:error, _reason} ->
        {:error, :platform_call_provision_failed}
    end
  end

  # The id is checked before it reaches the database: `Repo.get/2` casts it,
  # and a value that is not a UUID would raise out of the body (INV-8).
  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :platform_call_arg_invalid}
    end
  end

  defp cast_uuid(_value), do: {:error, :platform_call_arg_invalid}
end
