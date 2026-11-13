defmodule Letflow.Entities.ModuleReadGate do
  @moduledoc """
  T-1864 (INV-2, INV-5, within one tenant): the generic entity read paths
  (`POST /entities/query`, aggregate, export, `GET /entity-views`) must not hand out a module's
  records to a caller whose only access to the module is a tenant switch that is OFF.

  `EntitiesQuery` is a coarse permission that several roles hold; without this gate a STOREKEEPER
  whose tenant has the assets switch OFF (no `AssetsRead`, `Letflow.Api.TenantGrants`, D-097) still
  read every `assets_*` record through the generic query.

  The rule, role-name-free (D-129): the entity types the Assets module manages are refused to a
  caller when (a) no role of the caller allows `AssetsRead` (with the tenant role overlay,
  `Authorization.role_allows?/3`, the check of the module routes) AND (b) every role of the caller is
  one the tenant switch governs (`Authorization.grantable/0` lists it for that permission). A role the
  switch does not govern keeps the generic read it always had (for example a scoped worker reading
  cards, REQ-748, `card_scope_test`): the switch is the only thing this gate enforces.

  `denied/1` returns the set of refused type names. It is unioned into the `TypeAccess` denial by
  `Letflow.Entities.RequestAccess` and `Letflow.Entities.Views`, so a refused type answers exactly
  like an absent one (same envelope, no oracle). No principal (a context that did not come through
  the plug stack) fails closed: every gated type is denied. The scope filter of the query itself
  (`ScopeGate`) still narrows rows by org unit afterwards.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Modules.Catalog

  # One entry per module whose entity types need a read permission on the generic paths.
  @gated [{"assets", :AssetsRead}]

  @spec denied(Plug.Conn.t()) :: MapSet.t(String.t())
  def denied(%Plug.Conn{} = conn) do
    principal = principal(conn)
    declared = Catalog.managed_name_declarations()

    @gated
    |> Enum.filter(fn {_module_id, permission} -> refused?(principal, permission) end)
    |> Enum.flat_map(fn {module_id, _permission} ->
      for {name, ^module_id} <- declared, do: name
    end)
    |> MapSet.new()
  end

  defp principal(conn) do
    case Scope.principal_from_conn(conn) do
      {:ok, _conn, principal} -> principal
      {:error, _reason} -> nil
    end
  end

  # Refused: no principal, or no role allows the permission and every role is switch-governed.
  defp refused?(nil, _permission), do: true

  defp refused?(%{roles: roles} = principal, permission) do
    governed = for {role, atoms} <- Authorization.grantable(), permission in atoms, do: role

    roles != [] and Enum.all?(roles, &(&1 in governed)) and
      not Enum.any?(roles, &Authorization.role_allows?(&1, permission, principal.role_overlay))
  end
end
