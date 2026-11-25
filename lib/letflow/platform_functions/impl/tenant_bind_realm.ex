defmodule Letflow.PlatformFunctions.Impl.TenantBindRealm do
  @moduledoc """
  The body of `tenant.bind_realm` (T-2590, pilot gap G1b of the "Register a
  tenant" pilot).

  It binds the identity provider's realm to a tenant -- the write that today
  sits in `Letflow.Routers.Onboarding` (the create route's bind and the
  separate `POST /:id/bind-realm` route) and in `Letflow.TenantProvisioner`
  (its "ensure realm" step). That code moved HERE, so the route, the
  provisioner and the platform step call ONE implementation.

  ## The two audited shapes of one operation

    * `bind_tenant_realm/3` -- the OPERATOR's bind, exactly as the route calls
      it today: the tenant chain records the bind with a nil actor, the
      platform chain records the operator's user id. The route's answers (409
      for a realm that is already bound, 409 for a tenant that is not active,
      404 for an unknown tenant) do not change.
    * `run/1` -- the step's bind. A step runs outside any person's request,
      so it has no operator to name: it binds through the SYSTEM path
      (`Letflow.Identity.bind_provisioned_realm/3`), which writes the same
      tenant-chain entry with a nil actor and a platform-chain entry with a
      nil actor. The person who switched the version on is recorded where it
      belongs, in the definition version's signed `activated_by` document.

  ## The idempotency

  The step's key input is the TENANT ID, and binding the same realm to the
  same tenant twice is the same bind: the tenant row keeps the realm it
  already has (`{:unchanged, tenant}`), no column is written again, and the
  answer is the same. A bind of a DIFFERENT realm to a tenant that already has
  one is refused (`platform_call_realm_already_bound`): the step never
  replaces a realm behind the operator's back.

  ## The bounds

  The realm is a tenant-controlled value (a start variable), so it is
  byte-bounded BEFORE anything else touches it (SF-01): at most 64 bytes,
  the same cap the routes' own request schema applies. The tenant id is
  checked as a UUID before it reaches the database (INV-8).

  ## What it never does

  It never raises (INV-8): every failure is an `{:error, code}` with a code
  of this module's own vocabulary. It writes the tenant's realm column and
  the two audit entries -- nothing else.
  """

  alias Letflow.Identity
  alias Letflow.PlatformFunctions.Impl.SystemCaller

  # The byte cap of the realm value, in bytes: the same cap the routes' own
  # request schema applies (`max_length: 64`).
  @max_realm_bytes 64

  @typedoc "The stable code of a refused bind."
  @type refusal ::
          :platform_call_arg_invalid
          | :platform_call_tenant_not_found
          | :platform_call_tenant_not_active
          | :platform_call_realm_already_bound
          | :platform_call_duplicate_realm
          | :platform_call_realm_bind_failed

  @doc """
  The operator's bind, moved out of the route: exactly what
  `Letflow.Identity.bind_tenant_realm/3` answers, with no change of shape.
  """
  @spec bind_tenant_realm(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Identity.Tenant.t()} | {:error, term()}
  def bind_tenant_realm(tenant_id, realm, opts) do
    Identity.bind_tenant_realm(tenant_id, realm, opts)
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
    realm = Map.get(inputs, "realm_id")

    # v2 (T-2727): `realm_id` is optional. Absent: nothing to bind (an operator tenant
    # without a realm), and the step is a no-op.
    with {:ok, tenant_id} <- cast_uuid(tenant_id),
         :ok <- bind_if_present(tenant_id, realm) do
      {:ok, %{}}
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp bind_if_present(_tenant_id, nil), do: :ok

  defp bind_if_present(tenant_id, realm) do
    with :ok <- bounded(realm),
         {:ok, platform_prefix} <- platform_prefix() do
      bind(tenant_id, realm, platform_prefix)
    end
  end

  # The SYSTEM bind: no operator, so the platform chain records a nil actor.
  defp bind(tenant_id, realm, platform_prefix) do
    case Identity.bind_provisioned_realm(tenant_id, realm, platform_prefix: platform_prefix) do
      {:ok, _tenant} -> :ok
      {:error, :not_found} -> {:error, :platform_call_tenant_not_found}
      {:error, :tenant_not_active} -> {:error, :platform_call_tenant_not_active}
      {:error, :realm_already_bound} -> {:error, :platform_call_realm_already_bound}
      {:error, :duplicate_realm} -> {:error, :platform_call_duplicate_realm}
      {:error, _other} -> {:error, :platform_call_realm_bind_failed}
    end
  end

  defp platform_prefix do
    case SystemCaller.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :platform_call_realm_bind_failed}
    end
  end

  # The BYTE bound comes first: the value is checked before it is compared
  # with anything or written (SF-01).
  defp bounded(value) when is_binary(value) do
    if byte_size(value) <= @max_realm_bytes, do: :ok, else: {:error, :platform_call_arg_invalid}
  end

  defp bounded(_value), do: {:error, :platform_call_arg_invalid}

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
