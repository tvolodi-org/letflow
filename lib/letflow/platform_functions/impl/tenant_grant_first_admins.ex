defmodule Letflow.PlatformFunctions.Impl.TenantGrantFirstAdmins do
  @moduledoc """
  The body of `tenant.grant_first_admins` (T-2590, pilot gap G1b of the
  "Register a tenant" pilot).

  It stores the PENDING grant of the new tenant's first administrator -- the
  write that today sits in `Letflow.Routers.Onboarding` (the create route's
  pending grant) and in `Letflow.TenantProvisioner` (its "ensure grant" step).
  That code moved HERE, so the route, the provisioner and the platform step
  call ONE implementation.

  A pending grant is a row in the NEW tenant's own schema: it holds the
  administrator's address and nothing else, and it is bound to `TENANT_ADMIN`
  when that person first signs in through the tenant's realm. The address is
  never written to an audit entry and never logged (INV-4).

  ## The two audited shapes of one operation

    * `create_grant/3` -- the OPERATOR's grant, exactly as the route calls it
      today: the platform chain records the operator's user id.
    * `run/1` -- the step's grant. A step runs outside any person's request,
      so it has no operator to name: it stores the grant through the SYSTEM
      path (`Letflow.Identity.PendingAdminGrants.create_provisioned/2`), which
      writes the same tenant-chain entry and a platform-chain entry with a
      nil actor. The person who switched the version on is recorded where it
      belongs, in the definition version's signed `activated_by` document.

  ## The idempotency

  The step's key input is the TENANT ID, and granting the first
  administrator of a tenant twice is the same grant: the address already
  waits in that tenant's schema, so the second run stores nothing and
  answers the same. The step never stores a second grant for another
  address: the dispatcher's own key check refuses that (the same key with
  different arguments) before the body runs.

  ## The bounds

  The address is a tenant-controlled value (a start variable), so it is
  byte-bounded BEFORE anything else touches it (SF-01): at most 254 bytes,
  the RFC's limit in octets, and the same limit the normaliser applies. The
  tenant id is checked as a UUID before it reaches the database (INV-8).

  ## Where the address lands

  The address is never written to an audit entry and never logged (INV-4).
  It IS written to the dispatch row's own `inputs` column: the dispatcher
  stores the resolved arguments of the call it runs, and the row lives in
  the platform tenant's schema. That is a personal datum in the platform's
  own database, so the pilot's threat model names it (gap G6, the step log,
  reads that row).

  ## What it never does

  It never raises (INV-8): every failure is an `{:error, code}` with a code
  of this module's own vocabulary.
  """

  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.PlatformFunctions.Impl.SystemCaller
  alias Letflow.Repo
  alias Letflow.TenantProvisioner.Lifecycle
  alias Letflow.TenantProvisioning

  # The byte cap of the address, in bytes: the RFC's limit is in OCTETS.
  @max_email_bytes 254

  @typedoc "The stable code of a refused grant."
  @type refusal ::
          :platform_call_arg_invalid
          | :platform_call_invalid_email
          | :platform_call_tenant_not_found
          | :platform_call_grant_failed

  @doc """
  The operator's grant, moved out of the route: exactly what
  `Letflow.Identity.PendingAdminGrants.create/3` answers, with no change of
  shape.
  """
  @spec create_grant(String.t(), map(), keyword()) ::
          {:ok, PendingAdminGrants.PendingAdminGrant.t()} | {:error, term()}
  def create_grant(email_key, creator, opts) do
    PendingAdminGrants.create(email_key, creator, opts)
  end

  @doc """
  Runs the step over the resolved arguments.

  `context` carries the resolved `inputs` (the entry's declared input names
  to their values). Returns `{:ok, %{}}` -- the entry declares no output --
  or `{:error, refusal}`.
  """
  @spec run(map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    tenant_id = Map.get(inputs, "tenant_id")
    email = Map.get(inputs, "admin_email")

    # v2 (T-2727): `admin_email` is optional. Absent: no grant to store, a no-op.
    with {:ok, tenant_id} <- cast_uuid(tenant_id),
         :ok <- grant_if_present(tenant_id, email) do
      {:ok, %{}}
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp grant_if_present(_tenant_id, nil), do: :ok

  defp grant_if_present(tenant_id, email) do
    case Repo.get(Lifecycle, tenant_id) do
      # Design section 4 row 7: the marker says the grant was stored (or adopted) once; a repeat
      # after a setting rollback must not create it again.
      %Lifecycle{owner_grant_stored: true} ->
        :ok

      lifecycle ->
        with {:ok, email_key} <- email_key(email),
             {:ok, prefix} <- tenant_prefix(tenant_id),
             {:ok, platform_prefix} <- platform_prefix(),
             :ok <- store(email_key, prefix, platform_prefix) do
          mark_stored(lifecycle)
        end
    end
  end

  # With a lifecycle row (routes 3/4) the marker is set; with none (operator routes) there is
  # nothing to mark. A failed update is a typed refusal: the repeat adopts the grant (duplicate).
  defp mark_stored(nil), do: :ok

  defp mark_stored(%Lifecycle{} = lifecycle) do
    case lifecycle |> Ecto.Changeset.change(owner_grant_stored: true) |> Repo.update() do
      {:ok, _row} -> :ok
      {:error, _changeset} -> {:error, :platform_call_grant_failed}
    end
  rescue
    _error -> {:error, :platform_call_grant_failed}
  end

  # The SYSTEM grant: no operator, so neither chain names one.
  defp store(email_key, prefix, platform_prefix) do
    case PendingAdminGrants.create_provisioned(email_key,
           prefix: prefix,
           platform_prefix: platform_prefix
         ) do
      {:ok, _grant} ->
        :ok

      {:error, :duplicate} ->
        # The same grant already waits in this tenant's schema: the same
        # call, already done. Nothing is written.
        :ok

      {:error, _other} ->
        {:error, :platform_call_grant_failed}
    end
  end

  # The grant lives in the NEW tenant's own schema, so the tenant must be
  # provisioned (INV-1: the prefix is derived from the tenant id, never
  # accepted from the caller).
  defp tenant_prefix(tenant_id) do
    case TenantProvisioning.registered_schema(tenant_id) do
      {:ok, prefix} -> {:ok, prefix}
      {:error, :not_found} -> {:error, :platform_call_tenant_not_found}
    end
  end

  defp platform_prefix do
    case SystemCaller.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :platform_call_grant_failed}
    end
  end

  # The BYTE bound comes FIRST: the address is checked before the normaliser
  # walks it (SF-01). Then the shared normaliser decides whether it is an
  # address at all (one `@`, a dot in the domain, ASCII only).
  defp email_key(value) when is_binary(value) do
    if byte_size(value) > @max_email_bytes do
      {:error, :platform_call_invalid_email}
    else
      case PendingAdminGrants.normalize_email(value) do
        {:ok, key} -> {:ok, key}
        :error -> {:error, :platform_call_invalid_email}
      end
    end
  end

  defp email_key(_value), do: {:error, :platform_call_invalid_email}

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
