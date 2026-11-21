defmodule Letflow.PlatformFunctions.Guard do
  @moduledoc """
  The RUN-TIME authority of a platform call (T-2588, pilot gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decisions (b) and (e)).

  Activation proves that the person who switched a version on held the entry's
  permission. This module proves the same thing AGAIN, at the moment the call
  runs, because the world may have changed since: the tenant may no longer be
  the platform tenant, the stored `activated_by` document may have been edited
  in the database, and the activator may have lost the permission.

  ## The four refusals

    * `:platform_call_tenant_not_allowed` -- the call does not run in the
      platform tenant (INV-10). A forged dispatch row in a company schema is
      refused here, whatever it claims.
    * `:platform_call_function_unknown` -- the function is not in the compiled
      catalogue (it cannot be added at run time, so this means a forged row).
    * `:platform_call_signature_invalid` -- the `activated_by` document does not
      verify against the tenant's signing key.
    * `:platform_call_needs_reactivation` -- the activator no longer holds the
      entry's permission. The definition is marked `needs_reactivation` where
      the loss is discovered, so the existing reactivation path (REQ-515) heals
      it.

  ## What it does NOT do

  It does not run the function and it does not decide the result: the step
  library (gap G1) owns the dispatcher. This module is the fence the
  dispatcher calls before it does anything.

  Fail closed: every refusal is an error tuple, never a raise (INV-8).
  """

  alias Letflow.Api.Authorization
  alias Letflow.Definitions.ActivatedBy
  alias Letflow.Definitions.Reactivation
  alias Letflow.Identity
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformTenant

  @typedoc "The stable reason a platform call is refused."
  @type refusal ::
          :platform_call_tenant_not_allowed
          | :platform_call_function_unknown
          | :platform_call_signature_invalid
          | :platform_call_permission_required
          | :platform_call_needs_reactivation

  @doc """
  The authority of one platform call, as `:ok` or `{:error, refusal}`.

  `opts`:

    * `:definition` -- the ACTIVE definition row the call belongs to (its
      `activated_by`, `id`, `version` and `graph` are read);
    * `:prefix` -- the tenant schema the call runs in;
    * `:tenant_id` -- the tenant the INSTANCE runs in (the dispatcher may be
      handed a row forged in another schema, so the instance's own tenant is
      checked too);
    * `:function` -- the catalogue entry name the step calls.
  """
  @spec authorize_dispatch(keyword()) :: :ok | {:error, refusal()}
  def authorize_dispatch(opts) when is_list(opts) do
    definition = Keyword.get(opts, :definition)
    prefix = Keyword.get(opts, :prefix)
    tenant_id = Keyword.get(opts, :tenant_id)
    function = Keyword.get(opts, :function)

    with :ok <- check_tenant(prefix, tenant_id),
         {:ok, entry} <- check_function(function),
         :ok <- check_signature(definition, prefix),
         :ok <- check_permission(definition, entry, prefix) do
      :ok
    end
  end

  defp check_tenant(prefix, tenant_id) do
    if is_binary(prefix) and PlatformTenant.platform_prefix?(prefix) and
         is_binary(tenant_id) and PlatformTenant.platform_tenant?(tenant_id) do
      :ok
    else
      {:error, :platform_call_tenant_not_allowed}
    end
  end

  defp check_function(function) when is_binary(function) do
    case Catalog.fetch(function) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, :platform_call_function_unknown}
    end
  end

  defp check_function(_function), do: {:error, :platform_call_function_unknown}

  defp check_signature(definition, prefix) when is_map(definition) do
    case ActivatedBy.verify(Map.get(definition, :activated_by), definition, prefix) do
      {:ok, :verified} -> :ok
      _unsigned_or_mismatch -> {:error, :platform_call_signature_invalid}
    end
  end

  defp check_signature(_definition, _prefix), do: {:error, :platform_call_signature_invalid}

  # The signed document must prove the activator held the entry's permission,
  # and the activator must STILL hold it: a permission lost since the
  # activation makes the definition stale, and the row is marked so the
  # reactivation path heals it.
  defp check_permission(definition, entry, prefix) do
    activated_by = Map.get(definition, :activated_by) || %{}
    recorded = Map.get(activated_by, "permissions", [])
    permission = Atom.to_string(entry.permission)

    cond do
      permission not in recorded ->
        {:error, :platform_call_permission_required}

      true ->
        case Map.get(activated_by, "user_id") do
          user_id when is_binary(user_id) ->
            check_current_roles(definition, user_id, entry, prefix)

          _no_user ->
            {:error, :platform_call_permission_required}
        end
    end
  end

  defp check_current_roles(definition, user_id, entry, prefix) do
    roles = Identity.list_effective_role_names(user_id, prefix: prefix)

    ctx = %Authorization.AccessContext{
      user_id: user_id,
      roles: Authorization.roles_from_strings(roles),
      platform_tenant?: true
    }

    if Authorization.evaluate_access(ctx, entry.permission).kind == :Allow do
      :ok
    else
      # The permission is gone: the definition is stale from here on. The row is
      # marked where the loss is discovered, so the existing reactivation path
      # (REQ-515) heals it and a new start is refused meanwhile.
      mark_needs_reactivation(definition, prefix)
      {:error, :platform_call_needs_reactivation}
    end
  end

  defp mark_needs_reactivation(definition, prefix) do
    case Map.get(definition, :id) do
      id when is_binary(id) ->
        Reactivation.mark_definition(id, :activator_lost_catalogue_permission, prefix)

      _no_id ->
        :ok
    end
  end
end
