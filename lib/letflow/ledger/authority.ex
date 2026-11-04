defmodule Letflow.Ledger.Authority do
  @moduledoc """
  REQ-685 (slice L3b, decision 0073 note 16.2): the run-time authority check of one ledger
  posting. It runs INSIDE the completion's transaction, after the origin check and BEFORE any
  deferred build-time refusal is released, so a caller who may not post learns nothing about
  its command.

    1. the credential must be exactly `:oidc` (an allowlist: `nil`, `:api_token` and anything
       else are refused, no database read);
    2. the roles are read NOW from the database (`Identity.list_effective_role_names/2`), never
       taken from the activation snapshot or the request, so a role revoked after the task was
       claimed is refused; `PLATFORM_ADMIN` is stripped outside the platform tenant
       (`Authorization.effective_roles/2`);
    3. some role must hold the registration's `post` permission (`reverse` for a reversal);
    4. the principal must be tenant-wide for that permission (`Scope.allowed_set/2` is
       `{:ok, :all}`); a scoped principal is refused (`scoped_principal_unsupported`, OQ-21
       default; scoped posting is slice L6).

  Answers ids and closed atoms only (INV-4, INV-5).
  """

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Identity
  alias Letflow.Ledger.Capability
  alias Letflow.PlatformTenant
  alias Letflow.TenantProvisioning

  @type denial :: :credential_unsupported | :role_denied | :scoped_principal_unsupported

  @spec check(Capability.t()) :: :ok | {:error, denial()}
  def check(cap) when is_struct(cap, Capability) and cap.credential == :oidc do
    prefix = cap.prefix
    names = Identity.list_effective_role_names(cap.subject_id, prefix: prefix)

    with {:ok, tenant_id} <- tenant_id(prefix),
         platform? = PlatformTenant.platform_tenant?(tenant_id),
         roles = Authorization.effective_roles(names, platform?),
         {:ok, atom} <- permission_atom(cap),
         true <- Enum.any?(roles, &Authorization.role_allows?(&1, atom)) do
      check_scope(cap, roles, platform?, atom)
    else
      _denied -> {:error, :role_denied}
    end
  end

  def check(cap) when is_struct(cap, Capability), do: {:error, :credential_unsupported}

  defp tenant_id(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, id} -> {:ok, id}
      {:error, _} -> :error
    end
  end

  defp permission_atom(%{registration: %{permissions: permissions}, posting: posting}) do
    key = if reversal?(posting), do: :reverse, else: :post

    case Map.get(permissions, key) do
      atom when is_atom(atom) and not is_nil(atom) -> {:ok, atom}
      _ -> :error
    end
  end

  defp permission_atom(_cap), do: :error

  defp reversal?(%{cause: "reversal"}), do: true
  defp reversal?(_posting), do: false

  defp check_scope(cap, roles, platform?, atom) do
    principal = %Scope.Principal{
      kind: :user,
      user_id: cap.subject_id,
      prefix: cap.prefix,
      platform_tenant?: platform?,
      roles: roles,
      grants: Scope.load_grants(cap.subject_id, cap.prefix)
    }

    case Scope.allowed_set(principal, atom) do
      {:ok, :all} -> :ok
      _scoped_or_none -> {:error, :scoped_principal_unsupported}
    end
  rescue
    Scope.ScopeSetError -> {:error, :scoped_principal_unsupported}
  end
end
