defmodule Letflow.Api.ScopeGate do
  @moduledoc """
  The ONLY conn-level entry through which a handler of a `:filter` or `{:resolver, _}` route
  applies the caller's scope (REQ-518 PR 2c-i-b / GH #2535; design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.5, decision 0051 D6).

    * `scope_set/2` -- the caller's expanded allowed node set for the route's permission, as
      `t:Letflow.Entities.Query.Types.scope_set/0`, for `Letflow.Entities.Query.Compiler`;
    * `resource_allowed?/3` -- one resource's allow/deny (`Letflow.Api.Scope.allowed?/3`);
    * `mode/1` -- the per-request scope-enforcement mode.

  ## Not `on` means no read

  `Letflow.Plugs.AuthPipeline` stores the tenant's mode in `auth_context.scope_enforcement`.
  Unless it is `:on` (`:off`, `:shadow`, key absent) the functions return `:all` / `true` and
  issue NO query, so behaviour for a tenant that is not `on` is byte-identical to today.

  ## The "scope applied" marker and the conn

  Every call sets `conn.private[:letflow_scope_applied]`. `Letflow.Api.Scope.Enforce` registers a
  before-send check on `:filter` and `{:resolver, _}` routes that turns a 2xx response sent
  WITHOUT the marker into the detail-free 500 (REQ-518 SEC ruling R-4). That check is DETECTIVE
  only: it detects a handler that omitted the gate; it does not make a response safe, and the
  marker proves "gate called", not "result applied". Handlers must therefore continue with the
  conn these functions RETURN: it is the conn that is finally sent, and a handler that drops it
  loses the marker and gets a (fail-closed) false 500.

  ## Memo

  The set is memoised in `conn.private` per permission, so a request reads the allowed node set
  at most once however often the gate is called (AC 5). Grants themselves are the existing
  per-request memo of `Letflow.Api.Scope.principal_from_conn/1`.

  ## Failure is loud (INV-8, SEC C-1 and F-1)

  A failure while computing the set -- `Letflow.Api.Scope.ScopeSetError` from the node
  expansion, or ANY other raise, exit or throw (for example a database error from the grants or
  node reads) -- is re-raised as `ScopeSetError`, which `Letflow.Plugs.ApiPipeline` answers with
  the detail-free 500. One constant log line `scope_set_failed reason=<atom>` per occurrence (no
  ids, no tenant, no values). Never `:all`, never a partial set, never a silent `:none`.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.ScopeSetError
  alias Letflow.Entities.Query.Types

  require Logger

  @marker :letflow_scope_applied
  @memo :letflow_scope_sets

  @doc """
  Whether a `scope_set/2` or `resource_allowed?/3` call marked this conn. The single owner of the
  marker key; `Letflow.Api.Scope.Enforce` reads it only through this function.
  """
  @spec applied?(Plug.Conn.t()) :: boolean()
  def applied?(%Plug.Conn{} = conn), do: Map.get(conn.private, @marker) == true

  @doc "The per-request scope-enforcement mode (`:off` when the context or key is absent)."
  @spec mode(Plug.Conn.t()) :: :off | :shadow | :on
  def mode(%Plug.Conn{} = conn) do
    case conn.assigns |> Map.get(:auth_context, %{}) |> Map.get(:scope_enforcement) do
      :on -> :on
      :shadow -> :shadow
      _off_or_absent -> :off
    end
  end

  @doc """
  The caller's allowed node set for the permission of `policy_key` (see the moduledoc). Not `on`
  -> `{conn, :all}` with no query. `:on` -> `Letflow.Api.Scope.allowed_set/2` (a request without
  a principal gets `:none`).
  """
  @spec scope_set(Plug.Conn.t(), policy_key :: atom()) :: {Plug.Conn.t(), Types.scope_set()}
  def scope_set(%Plug.Conn{} = conn, policy_key) when is_atom(policy_key) do
    conn = Plug.Conn.put_private(conn, @marker, true)

    case mode(conn) do
      :on -> memoised_set(conn, Authorization.required_permission(policy_key))
      _not_on -> {conn, :all}
    end
  end

  @doc """
  Whether the caller may act on `resource_scope` under the permission of `policy_key`
  (`Letflow.Api.Scope.allowed?/3`). Not `on` -> `{conn, true}` with no query; no principal ->
  `false`.
  """
  @spec resource_allowed?(Plug.Conn.t(), policy_key :: atom(), Scope.resource_scope()) ::
          {Plug.Conn.t(), boolean()}
  def resource_allowed?(%Plug.Conn{} = conn, policy_key, resource_scope)
      when is_atom(policy_key) do
    conn = Plug.Conn.put_private(conn, @marker, true)

    case mode(conn) do
      :on ->
        permission = Authorization.required_permission(policy_key)

        guarded(fn ->
          case Scope.principal_from_conn(conn) do
            {:ok, conn, principal} ->
              decision = Scope.allowed?(principal, permission, resource_scope)
              {conn, match?({:allow, _basis}, decision)}

            {:error, :no_principal} ->
              {conn, false}
          end
        end)

      _not_on ->
        {conn, true}
    end
  end

  defp memoised_set(conn, permission) do
    memo = Map.get(conn.private, @memo, %{})

    case Map.fetch(memo, permission) do
      {:ok, set} ->
        {conn, set}

      :error ->
        {conn, set} = guarded(fn -> compute_set(conn, permission) end)
        {Plug.Conn.put_private(conn, @memo, Map.put(memo, permission, set)), set}
    end
  end

  defp compute_set(conn, permission) do
    case Scope.principal_from_conn(conn) do
      {:ok, conn, principal} ->
        {:ok, set} = Scope.allowed_set(principal, permission)
        {conn, set}

      {:error, :no_principal} ->
        {conn, :none}
    end
  end

  # SEC F-1: a database error (or any raise, exit, throw) while reading grants or nodes must
  # give the Letflow detail-free 500, not the server's crash response, so it is re-raised as the
  # one exception `ApiPipeline.handle_errors/2` maps. `ScopeSetError` already logged its line.
  defp guarded(fun) do
    fun.()
  rescue
    e in ScopeSetError -> reraise e, __STACKTRACE__
    _other -> fail(:read_failed)
  catch
    _kind, _reason -> fail(:read_failed)
  end

  defp fail(reason) do
    Logger.error("scope_set_failed reason=#{reason}")
    raise ScopeSetError, reason: reason
  end
end
