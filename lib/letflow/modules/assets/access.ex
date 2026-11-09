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

  @doc """
  GH #3890 / #3891 (C10): the guard of the document routes, same body as `Stock.Access.check/2`.
  `purpose` is `:read` (`AssetsRead`), `:post` (`AssetsPost`) or `:reverse` (`AssetsReverse`). A
  scoped principal and an API token get `:error` (the 404 of a tenant without the module): scoped
  posting is not built.
  """
  @spec permission(:read | :post | :reverse) :: atom()
  def permission(:read), do: :AssetsRead
  def permission(:post), do: :AssetsPost
  def permission(:reverse), do: :AssetsReverse

  @spec check(Plug.Conn.t(), :read | :post | :reverse) ::
          {:ok, %{prefix: String.t(), actor_id: String.t()}} | :error
  def check(%Plug.Conn{} = conn, purpose) when purpose in [:read, :post, :reverse],
    do: guard(conn, permission(purpose))

  @spec check(Plug.Conn.t()) :: {:ok, %{prefix: String.t(), actor_id: String.t()}} | :error
  def check(%Plug.Conn{} = conn), do: guard(conn, @permission)

  defp guard(conn, permission) do
    with {:ok, _conn, %{kind: :user} = principal} <- Scope.principal_from_conn(conn),
         true <-
           Enum.any?(
             principal.roles,
             &Authorization.role_allows?(&1, permission, principal.role_overlay)
           ),
         {:ok, :all} <- Scope.allowed_set(principal, permission),
         {:ok, actor} <- Ecto.UUID.cast(principal.user_id) do
      {:ok, %{prefix: principal.prefix, actor_id: actor}}
    else
      _refused -> :error
    end
  rescue
    Scope.ScopeSetError -> :error
  end
end
