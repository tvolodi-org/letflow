defmodule Letflow.Api.ModuleGuard do
  @moduledoc """
  CORE slice S8: the one permission guard of the module document and card routes, moved out of
  `Letflow.Modules.Assets.Access` and `Letflow.Modules.Stock.Access` (behaviour-neutral).

  `check/2` returns `{:ok, %{prefix: prefix, actor_id: uuid}}` only when the principal is an
  interactive OIDC user (an API token is a different kind), one of its roles allows `permission`
  (with the tenant role overlay, `Authorization.role_allows?/3`), the permission is granted
  tenant-wide (`Letflow.Api.Scope.allowed_set/2` is `{:ok, :all}`) and the user id is a uuid.
  Everything else, a `Scope.ScopeSetError` included (fails closed, INV-8), is `:error`, which the
  router turns into the 404 of a tenant without the module (INV-5).

  The tenant is `principal.prefix`, derived from the token by the plug stack, never from the
  request (INV-1, INV-10). Each module keeps its own `permission/1` and passes its atom.

  The overlay is passed for every module. Stock used to call `role_allows?/2`; the two are equal
  for a Stock atom only because `Authorization.grantable/0` holds no Stock atom (pinned in
  `module_guard_test.exs`).
  """

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope

  @spec check(Plug.Conn.t(), atom()) ::
          {:ok, %{prefix: String.t(), actor_id: String.t()}} | :error
  def check(%Plug.Conn{} = conn, permission) when is_atom(permission) do
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
