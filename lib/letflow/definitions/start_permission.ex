defmodule Letflow.Definitions.StartPermission do
  @moduledoc """
  The permission a caller must hold to START an instance of a definition
  (T-2588, pilot gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (e)).

  A definition that calls a platform function may be started only by a caller
  that holds the entry's permission -- `:TenantsManage` for the tenant family.
  The start variables of such a definition are TRUSTED inputs (the person who
  starts it chooses the values the platform function reads), so the start
  needs the same authority the activation does.

  ## Where the requirement comes from

  It is a property of the DEFINITION, not of the route: the permission is
  derived from the catalogue entries the definition's `platform_call` steps
  call. A definition with no such step requires nothing, and starts as it
  always did.

  ## The answer

  A caller without the permission, and every caller outside the platform
  tenant, gets the answer for an UNKNOWN definition (INV-5): the start
  refuses, nothing is written, and the reason never reaches the caller.

  Pure: no query, no clock, never raises.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.PlatformCalls
  alias Letflow.PlatformTenant

  @doc """
  The permission atoms a definition's `platform_call` steps require of the
  person who starts an instance of it. Empty for an ordinary definition.
  """
  @spec required(Graph.t() | term()) :: [atom()]
  def required(graph) when is_list(graph), do: PlatformCalls.required_permissions(graph)

  def required(%Graph{nodes: nodes}) when is_list(nodes),
    do: PlatformCalls.required_permissions(nodes)

  def required(_other), do: []

  @doc """
  The authority of one start: `:ok` when the caller may start `definition`,
  `{:error, :not_found}` when it may not (the INV-5 answer).

  `auth_context` is the server-side request context (`:user_id`, `:tenant_id`,
  `:roles`); nil when the caller is not an HTTP principal (module code, a
  sub-process child), which may not start a definition that calls a platform
  function.
  """
  @spec check(map() | term(), map() | nil) :: :ok | {:error, :not_found}
  def check(definition, auth_context) when is_map(definition) do
    case required_permission_atoms(definition) do
      [] -> :ok
      required -> authorize(auth_context, required)
    end
  end

  def check(_definition, _auth_context), do: :ok

  defp required_permission_atoms(%{graph: graph_map}) do
    case Graph.from_map(graph_map) do
      {:ok, graph} -> required(graph)
      :error -> []
    end
  end

  defp required_permission_atoms(_definition), do: []

  defp authorize(nil, _required), do: {:error, :not_found}

  defp authorize(auth_context, required) when is_map(auth_context) do
    user_id = Map.get(auth_context, :user_id)
    tenant_id = Map.get(auth_context, :tenant_id)
    roles = Map.get(auth_context, :roles) || []

    if is_binary(user_id) and PlatformTenant.platform_tenant?(tenant_id) do
      ctx = %Authorization.AccessContext{
        user_id: user_id,
        roles: Authorization.roles_from_strings(roles),
        platform_tenant?: true
      }

      if Enum.all?(required, &(Authorization.evaluate_access(ctx, &1).kind == :Allow)) do
        :ok
      else
        {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp authorize(_auth_context, _required), do: {:error, :not_found}
end
