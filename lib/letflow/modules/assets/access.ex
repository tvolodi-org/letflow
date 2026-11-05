defmodule Letflow.Modules.Assets.Access do
  @moduledoc """
  GH #3892 / REQ-750: the guard of the asset card write routes. `check/1` returns
  `{:ok, %{prefix: prefix, actor_id: uuid}}` only when the principal is an interactive OIDC user (an
  API token is a different kind), holds `AssetsCardWrite` through one of its roles, and the permission
  is granted tenant-wide (`Letflow.Api.Scope.allowed_set/2` is `{:ok, :all}`). Everything else, a scope
  error included (`ScopeSetError` fails closed, INV-8), is `:error`, which the router turns into the
  404 of a tenant without the module (INV-5). The `authz_*` macro of the router has already answered
  403 to a caller whose roles do not hold the permission at all.

  The tenant is `principal.prefix`, derived from the token by the plug stack, never from the request.
  Same shape as `Letflow.Modules.Stock.Access`, fixed to one permission.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope

  @permission :AssetsCardWrite

  @spec check(Plug.Conn.t()) :: {:ok, %{prefix: String.t(), actor_id: String.t()}} | :error
  def check(%Plug.Conn{} = conn) do
    with {:ok, _conn, %{kind: :user} = principal} <- Scope.principal_from_conn(conn),
         true <- Enum.any?(principal.roles, &Authorization.role_allows?(&1, @permission)),
         {:ok, :all} <- Scope.allowed_set(principal, @permission),
         {:ok, actor} <- Ecto.UUID.cast(principal.user_id) do
      {:ok, %{prefix: principal.prefix, actor_id: actor}}
    else
      _refused -> :error
    end
  rescue
    Scope.ScopeSetError -> :error
  end
end
