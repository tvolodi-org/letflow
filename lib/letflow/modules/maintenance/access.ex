defmodule Letflow.Modules.Maintenance.Access do
  @moduledoc """
  REQ-894 (CMMS slice 1 part 2): the guard of the maintenance routes. `check/2` returns
  `{:ok, %{prefix: prefix, actor_id: uuid}}` only when the principal is an interactive OIDC user
  (an API token is a different kind), holds the purpose's permission through one of its roles and
  holds it tenant-wide (`Letflow.Api.ModuleGuard`). Anything else, an org-scoped grant included
  (org-scoped access is a later slice), is `:error`: the router answers the 404 of an unknown
  request on a read by id or a write, and an empty list on a list. The `authz_*` macro has already
  answered 403 to a caller whose roles do not hold the permission at all. The tenant is the
  principal's prefix, never a request value (INV-1, INV-10).
  """

  alias Letflow.Api.ModuleGuard

  @type purpose :: :create | :read | :manage

  @doc "The permission atom of a purpose."
  @spec permission(purpose()) :: atom()
  def permission(:create), do: :MaintenanceRequestCreate
  def permission(:read), do: :MaintenanceRead
  def permission(:manage), do: :MaintenanceOrderManage

  @spec check(Plug.Conn.t(), purpose()) ::
          {:ok, %{prefix: String.t(), actor_id: String.t()}} | :error
  def check(%Plug.Conn{} = conn, purpose) when purpose in [:create, :read, :manage],
    do: ModuleGuard.check(conn, permission(purpose))
end
