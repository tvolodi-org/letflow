defmodule Letflow.Ledger.Authority do
  @moduledoc """
  REQ-685 (slice L3b, decision 0073 note 16.2): the run-time authority check of one ledger
  posting. It runs INSIDE the completion's transaction, after the origin check and BEFORE any
  deferred build-time refusal is released, so a caller who may not post learns nothing about
  its command.

    1. the credential must be exactly `:oidc` (an allowlist: `nil`, `:api_token` and anything
       else are refused, no database read), or, for the one module that declares it, `:shared_access`
       (REQ-860: see the clause);
    2. the roles are read NOW from the database (`Identity.list_effective_role_names/2`), never
       taken from the activation snapshot or the request, so a role revoked after the task was
       claimed is refused; `PLATFORM_ADMIN` is stripped outside the platform tenant
       (`Authorization.effective_roles/2`);
    3. some role must hold the registration's `post` permission (`reverse` for a reversal);
    4. scope (REQ-830, slice L6 part 1, decision 0073 OQ-13): `Scope.allowed_set/2` for the
       permission is `{:ok, :all}` (passes), or `{:ok, {:nodes, ids}}` and the registration names a
       `scope_slot`: then the scope slot value of EVERY leg (for a reversal, of the reversed entry,
       read prefix- and ledger-scoped) must be one of `ids` (byte equality on the text), else
       `scope_denied`. Everything else is refused: `scope_denied` for a registration with a
       `scope_slot` (`{:ok, :none}`, `ScopeSetError`, an unreadable posting, an unknown reversal
       target, an empty slot value), `scoped_principal_unsupported` for one without.

  Answers ids and closed atoms only (INV-4, INV-5).
  """

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Api.TenantGrants
  alias Letflow.Identity
  alias Letflow.Ledger
  alias Letflow.Ledger.Capability
  alias Letflow.Ledger.Validate
  alias Letflow.PlatformTenant
  alias Letflow.TenantProvisioning

  @type denial ::
          :credential_unsupported | :role_denied | :scoped_principal_unsupported | :scope_denied

  @spec check(Capability.t()) :: :ok | {:error, denial()}
  def check(cap) do
    case check_with_read(cap) do
      {:ok, _read?} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  `check/1` that also says whether some role of the subject holds the registration's read
  permission (REQ-686: only such a subject is shown `available` in an `insufficient_balance`
  refusal). Computed from the roles the check already read; no extra query.
  """
  @spec check_with_read(Capability.t()) :: {:ok, boolean()} | {:error, denial()}
  def check_with_read(cap) when is_struct(cap, Capability) and cap.credential == :oidc do
    prefix = cap.prefix
    names = Identity.list_effective_role_names(cap.subject_id, prefix: prefix)

    with {:ok, tenant_id} <- tenant_id(prefix),
         platform? = PlatformTenant.platform_tenant?(tenant_id),
         roles = Authorization.effective_roles(names, platform?),
         # T-1570 (D-097): reloaded on every call, so a switch-off between request and post is honoured.
         overlay = TenantGrants.load_for(roles, prefix),
         {:ok, atom} <- permission_atom(cap),
         true <- Enum.any?(roles, &Authorization.role_allows?(&1, atom, overlay)) do
      with :ok <- check_scope(cap, roles, platform?, atom, overlay),
           do: {:ok, read?(cap, roles, overlay)}
    else
      _denied -> {:error, :role_denied}
    end
  end

  # REQ-860 (decision 0091 section 2): the shared access is the one other credential that may post. The
  # rule (its module, its two permissions, the live credential row of the subject) is in
  # the function configured as `:shared_access_authority` (MFA, `config/config.exs`); no role is read, the credential is not a role.
  def check_with_read(cap)
      when is_struct(cap, Capability) and cap.credential == :shared_access do
    with {:ok, atom} <- permission_atom(cap),
         true <- shared_access_may_post?(cap, atom) do
      {:ok, true}
    else
      _denied -> {:error, :role_denied}
    end
  end

  def check_with_read(cap) when is_struct(cap, Capability),
    do: {:error, :credential_unsupported}

  # The rule of the credential kind `:shared_access` lives with the module that owns the credential; the
  # ledger names no module file, so it is found by configuration. No configuration: refused.
  defp shared_access_may_post?(cap, atom) do
    case Application.get_env(:letflow, :shared_access_authority) do
      {module, function} when is_atom(module) and is_atom(function) ->
        apply(module, function, [cap.prefix, cap.module_id, cap.subject_id, atom]) == true

      _unconfigured ->
        false
    end
  end

  defp read?(%{registration: %{permissions: permissions}}, roles, overlay) do
    case Map.get(permissions, :read) do
      atom when is_atom(atom) and not is_nil(atom) ->
        Enum.any?(roles, &Authorization.role_allows?(&1, atom, overlay))

      _none ->
        false
    end
  end

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

  defp check_scope(cap, roles, platform?, atom, overlay) do
    principal = %Scope.Principal{
      kind: :user,
      user_id: cap.subject_id,
      prefix: cap.prefix,
      platform_tenant?: platform?,
      roles: roles,
      grants: Scope.load_grants(cap.subject_id, cap.prefix),
      role_overlay: overlay
    }

    case Scope.allowed_set(principal, atom) do
      {:ok, :all} -> :ok
      {:ok, {:nodes, ids}} when is_list(ids) -> check_legs(cap, ids)
      _none -> scope_refusal(cap)
    end
  rescue
    Scope.ScopeSetError -> scope_refusal(cap)
  end

  defp scope_refusal(cap),
    do:
      {:error,
       if(scope_index(cap) == nil, do: :scoped_principal_unsupported, else: :scope_denied)}

  defp scope_index(%{registration: %{slots: slots} = registration}) when is_list(slots) do
    with name when is_binary(name) <- Map.get(registration, :scope_slot) do
      Enum.find_index(slots, &(is_map(&1) and Map.get(&1, :name) == name))
    else
      _none -> nil
    end
  end

  defp scope_index(_cap), do: nil

  defp check_legs(cap, ids) do
    with idx when is_integer(idx) <- scope_index(cap),
         {:ok, posting} <- Validate.posting(cap.posting, cap.command, cap.registration),
         {:ok, ks} <- leg_keys(cap, posting),
         true <- ks != [] and Enum.all?(ks, &leg_in_scope?(&1, idx, ids)) do
      :ok
    else
      nil -> {:error, :scoped_principal_unsupported}
      _denied -> {:error, :scope_denied}
    end
  end

  defp leg_keys(cap, %{reversal: true} = posting) do
    case Ledger.guard_reversal(cap.prefix, posting.ledger_id, posting.reverses_entry_id) do
      {:ok, %{ks: ks}} -> {:ok, ks}
      :error -> :error
    end
  end

  defp leg_keys(_cap, posting), do: {:ok, Enum.map(posting.legs, & &1.k)}

  defp leg_in_scope?(k, idx, ids) do
    case Enum.at(k, idx) do
      value when is_binary(value) and value != "" -> value in ids
      _empty -> false
    end
  end
end
