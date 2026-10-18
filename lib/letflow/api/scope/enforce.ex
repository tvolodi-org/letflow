defmodule Letflow.Api.Scope.Enforce do
  @moduledoc """
  The enforcing sibling of `Letflow.Api.Scope.Shadow` (REQ-517 PR 2b / GH #2535, decision 0051
  D5, D11; design `lib/letflow/design/req517-scoped-grants-admin-plane.md` section 4.3).

  `Letflow.Plugs.Authorize` calls `check/3` in its allow branch, after the unchanged coarse
  `Letflow.Api.Authorization.evaluate_access/2` allow and after it assigned `scoped_opts`,
  only when the caller's tenant is stored as `on`. It returns the conn unchanged, or a
  HALTED 403 / 500 conn. Decision, in order:

    1. the policy key is `:Unknown`, `:UnmatchedRoute`, `:UnmatchedPlatformPath` or
       `:MetricsRead`: the conn is returned (their own handling is unchanged);
    2. the route's class is `Letflow.Api.RouteScope.class_of/1` of `conn.private`;
    3. `{:resolver, _}`, `:filter` and `:self_service`: the conn is returned (the handler
       applies the scope, REQ-518);
    4. `:admin_plane`, `:tenant_wide` and a default-sourced (unclassified) route:
       `Letflow.Api.Scope.allowed?(principal, permission, :tenant_wide)`. An allow returns the
       conn. A deny, or no principal, emits `[:letflow, :scope, :enforce, :denied]`
       (`%{count: 1}`, metadata `policy` and `reason`; no metrics family), writes the
       attribution line through `Letflow.Api.AuthzDenyLog` and answers the unchanged uniform
       `403 insufficient permissions` (route-level, no resource revealed: no existence
       oracle);
    5. any raise, exit or throw (INV-8, AC 20): one constant line
       `scope_enforcement_failed class=<error|exit|throw> exception=<module|none>` per
       occurrence (no ids, no values) and a halted detail-free 500. NEVER an allow.

  `:admin_plane` and `:tenant_wide` decide identically here; the difference is declarative
  (the D11 inventory, the route walk, and the handlers' own `require_tenant_wide/2`).
  """

  import Plug.Conn, only: [halt: 1]

  require Logger

  alias Letflow.Api.Authorization
  alias Letflow.Api.AuthzDenyLog
  alias Letflow.Api.Response
  alias Letflow.Api.RouteScope
  alias Letflow.Api.Scope

  @skipped_keys [:Unknown, :UnmatchedRoute, :UnmatchedPlatformPath, :MetricsRead]
  @event [:letflow, :scope, :enforce, :denied]

  @doc """
  Enforces the route's scope class for one authorized request of an `on` tenant (see the
  moduledoc). Returns the conn, or a halted 403 / 500 conn.
  """
  @spec check(Plug.Conn.t(), Authorization.AccessContext.t(), policy_key :: atom()) ::
          Plug.Conn.t()
  def check(conn, _ctx, policy_key) when policy_key in @skipped_keys, do: conn

  def check(conn, ctx, policy_key) do
    {class, _source} = RouteScope.class_of(conn.private)

    case class do
      # MUTANT N3: resolver and filter routes are enforced as tenant_wide
      :self_service -> conn
      _admin_or_tenant_wide -> require_tenant_wide(conn, ctx, policy_key)
    end
  rescue
    # MUTANT N5: a raise inside Enforce allows the request
    _e -> conn
  catch
    kind, _reason -> fail_closed(conn, kind, nil)
  end

  defp require_tenant_wide(conn, ctx, policy_key) do
    permission = Authorization.required_permission(policy_key)

    case Scope.principal_from_conn(conn) do
      {:ok, conn, principal} ->
        case Scope.allowed?(principal, permission, :tenant_wide) do
          {:allow, _basis} -> conn
          {:deny, reason} -> deny(conn, ctx, policy_key, reason)
        end

      {:error, :no_principal} ->
        deny(conn, ctx, policy_key, :no_principal)
    end
  end

  defp deny(conn, ctx, policy_key, reason) do
    :telemetry.execute(@event, %{count: 1}, %{policy: policy_key, reason: reason})
    AuthzDenyLog.log_denial(conn, ctx, policy_key)
    conn |> Response.forbidden("insufficient permissions") |> halt()
  end

  # One constant line per occurrence: class and exception module name only (INV-4, INV-8).
  defp fail_closed(conn, class, mod) do
    Logger.error(
      "scope_enforcement_failed class=#{class} exception=#{if mod, do: inspect(mod), else: "none"}"
    )

    conn |> Response.internal_error() |> halt()
  end
end
