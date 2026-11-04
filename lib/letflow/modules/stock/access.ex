defmodule Letflow.Modules.Stock.Access do
  @moduledoc """
  REQ-712 / GH #3749: the guard of the stock document routes. `Letflow.Ledger.authorize/3` knows only
  the purposes `:read` and `:reconcile`; this module answers the same question for the document routes:
  may this request read or write stock documents, tenant-wide?

  `check/2` returns `{:ok, %{prefix: prefix, actor_id: uuid}}` only when the principal is an interactive
  OIDC user (an API token is a different kind), holds the permission through one of its roles, and the
  permission is granted tenant-wide (`Letflow.Api.Scope.allowed_set/2` is `{:ok, :all}`). Everything
  else, a scope error included (`ScopeSetError` fails closed, INV-8), is `:error`, which the router turns
  into the 404 of a tenant without the module (INV-5). The `authz_*` macro of the router has already
  answered 403 to a caller whose roles do not hold the permission at all. In phase B scoped posting is
  not built (L6), so a scoped principal gets the same 404.

  The tenant is `principal.prefix`, derived from the token by the plug stack, never from the request.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope

  @doc "The permission each purpose needs (the ledger registration names the same atoms)."
  @spec permission(:read | :post | :reverse) :: atom()
  def permission(:read), do: :StockRead
  def permission(:post), do: :StockPost
  def permission(:reverse), do: :StockReverse

  @spec check(Plug.Conn.t(), :read | :post | :reverse) ::
          {:ok, %{prefix: String.t(), actor_id: String.t()}} | :error
  def check(%Plug.Conn{} = conn, purpose) when purpose in [:read, :post, :reverse] do
    permission = permission(purpose)

    with {:ok, _conn, %{kind: :user} = principal} <- Scope.principal_from_conn(conn),
         true <- Enum.any?(principal.roles, &Authorization.role_allows?(&1, permission)),
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
